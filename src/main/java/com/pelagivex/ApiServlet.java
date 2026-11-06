package com.pelagivex;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import javax.servlet.MultipartConfigElement;
import javax.servlet.ServletException;
import javax.servlet.annotation.MultipartConfig;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.Part;

@WebServlet(name = "PelagivexApi", urlPatterns = "/api/*", loadOnStartup = 1)
@MultipartConfig(fileSizeThreshold = ApiServlet.MAX_REQUEST_BYTES, maxFileSize = ApiServlet.MAX_BYTES, maxRequestSize = ApiServlet.MAX_REQUEST_BYTES)
public final class ApiServlet extends HttpServlet {
    private static final ObjectMapper JSON = new ObjectMapper();
    static final long MAX_BYTES = 8_388_608L;
    // Every allowed part fits in memory, so camera frames are not spooled to disk.
    static final int MAX_REQUEST_BYTES = 8_519_680;
    static MultipartConfigElement multipartConfig(String location) {
        return new MultipartConfigElement(location, MAX_BYTES, MAX_REQUEST_BYTES, MAX_REQUEST_BYTES);
    }
    private static final String MODEL_NAME = "Pelagivex underwater gate detector";
    private final Semaphore inferenceSlot = new Semaphore(maxConcurrentInferences(), true);
    private transient RfDetrGateDetector detector;
    private float threshold = 0.2f;

    private static int maxConcurrentInferences() {
        String value = System.getProperty("pelagivex.maxConcurrentInferences", "1");
        int count;
        try { count = Integer.parseInt(value); }
        catch (NumberFormatException e) { throw new IllegalArgumentException("Invalid inference concurrency", e); }
        if (count < 1 || count > 4) throw new IllegalArgumentException("Inference concurrency must be between 1 and 4");
        return count;
    }

    @Override public void init() {
        String path = System.getProperty("pelagivex.model.path", System.getenv().getOrDefault("PELAGIVEX_MODEL_PATH", "/opt/pelagivex/model/gate.onnx"));
        String configuredThreshold = System.getProperty("pelagivex.threshold", System.getenv().getOrDefault("PELAGIVEX_THRESHOLD", "0.2"));
        String configuredClassIndex = System.getProperty("pelagivex.class.index", System.getenv().getOrDefault("PELAGIVEX_CLASS_INDEX", "0"));
        try {
            threshold = Float.parseFloat(configuredThreshold);
            if (!Float.isFinite(threshold) || threshold < 0 || threshold > 1) throw new IllegalArgumentException("Invalid threshold");
            Path file = Path.of(path);
            if (Files.isRegularFile(file) && Files.isReadable(file)) detector = new RfDetrGateDetector(file, Integer.parseInt(configuredClassIndex));
            else getServletContext().log("Pelagivex model is not installed; detection is unavailable.");
        } catch (Exception | LinkageError e) {
            getServletContext().log("Pelagivex model could not be loaded; detection is unavailable.", e);
        }
    }

    @Override protected void doGet(HttpServletRequest request, HttpServletResponse response) throws IOException {
        if (!"/health".equals(request.getPathInfo())) { writeError(response, 404, "Not found."); return; }
        boolean ready = detector != null;
        send(response, ready ? 200 : 503, Map.of("status", ready ? "ok" : "unavailable", "model", modelInfo(ready)));
    }

    @Override protected void doPost(HttpServletRequest request, HttpServletResponse response) throws IOException {
        if (!"/detect".equals(request.getPathInfo())) { writeError(response, 404, "Not found."); return; }
        if (detector == null) { writeError(response, 503, "The detection model is not available yet."); return; }
        try {
            // Zero wait keeps the queue bounded; timed acquisition respects semaphore fairness.
            if (!inferenceSlot.tryAcquire(0, TimeUnit.NANOSECONDS)) { writeError(response, 429, "The detector is busy. Please try again shortly."); return; }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            writeError(response, 503, "Detection was interrupted. Please try again shortly.");
            return;
        }
        Part part = null;
        long start = System.nanoTime();
        try {
            if (request.getContentType() == null || !request.getContentType().toLowerCase(java.util.Locale.ROOT).startsWith("multipart/form-data")) {
                writeError(response, 400, "Please upload a JPEG or PNG image."); return;
            }
            try { part = request.getPart("image"); }
            catch (IllegalStateException tooLarge) { writeError(response, 413, "Image must be 8 MB or smaller."); return; }
            if (part == null || part.getSize() <= 0) { writeError(response, 400, "Please choose an image."); return; }
            if (part.getSize() > MAX_BYTES) { writeError(response, 413, "Image must be 8 MB or smaller."); return; }
            byte[] bytes;
            try (var in = part.getInputStream()) { bytes = in.readNBytes((int) MAX_BYTES + 1); }
            if (bytes.length > MAX_BYTES) { writeError(response, 413, "Image must be 8 MB or smaller."); return; }
            BufferedImage image = ImageDecoder.decode(bytes);
            var detections = detector.detect(image, threshold);
            Map<String,Object> body = new LinkedHashMap<>();
            body.put("width", image.getWidth()); body.put("height", image.getHeight());
            body.put("detections", detections); body.put("model", modelInfo(true));
            body.put("duration_ms", Math.round((System.nanoTime() - start) / 1_000_000.0));
            send(response, 200, body);
        } catch (IllegalStateException e) {
            getServletContext().log("Detector returned an incompatible output.", e);
            writeError(response, 500, "Detection failed. Please try another image.");
        } catch (ServletException e) {
            writeError(response, 400, "The uploaded image could not be processed.");
        } catch (IOException e) {
            writeError(response, 400, "Please upload a valid JPEG or PNG image no larger than 4 megapixels.");
        } catch (Exception e) {
            getServletContext().log("Inference failed.", e);
            writeError(response, 500, "Detection failed. Please try another image.");
        } finally {
            if (part != null) try { part.delete(); } catch (IOException ignored) { }
            inferenceSlot.release();
        }
    }

    @Override public void destroy() {
        if (detector != null) try { detector.close(); } catch (Exception e) { getServletContext().log("Failed to release model.", e); }
    }
    private Map<String,Object> modelInfo(boolean available) { return Map.of("name", MODEL_NAME, "available", available, "threshold", threshold); }
    private static void writeError(HttpServletResponse response, int status, String message) throws IOException { send(response, status, Map.of("error", message)); }
    private static void send(HttpServletResponse response, int status, Object value) throws IOException {
        response.setStatus(status); response.setContentType("application/json"); response.setCharacterEncoding("UTF-8");
        response.setHeader("Cache-Control", "no-store"); JSON.writeValue(response.getOutputStream(), value);
    }
}
