package com.pelagivex;

import static org.junit.jupiter.api.Assertions.*;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.CRC32;
import javax.imageio.ImageIO;
import org.apache.catalina.Context;
import org.apache.catalina.startup.Tomcat;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

final class BackendTest {
    @TempDir Path temp;

    @Test void rejectsInvalidAndOversizedImagesBeforeFullDecode() throws Exception {
        assertThrows(java.io.IOException.class, () -> ImageDecoder.decode(new byte[]{1,2,3}));
        var image = new BufferedImage(1, 1, BufferedImage.TYPE_INT_RGB);
        var bytes = new ByteArrayOutputStream();
        ImageIO.write(image, "png", bytes);
        byte[] oversized = bytes.toByteArray();
        // A 2001 x 2001 IHDR exceeds the 4MP limit and is rejected before pixel decoding.
        for (int i = 0; i < 4; i++) { oversized[16+i] = (byte)(2001 >>> (24-8*i)); oversized[20+i] = (byte)(2001 >>> (24-8*i)); }
        CRC32 crc = new CRC32(); crc.update(oversized, 12, 17);
        long value = crc.getValue();
        for (int i = 0; i < 4; i++) oversized[29+i] = (byte)(value >>> (24-8*i));
        assertThrows(java.io.IOException.class, () -> ImageDecoder.decode(oversized));
    }

    @Test void rotatesPhoneOrientationBeforeReturningCoordinates() {
        BufferedImage image = new BufferedImage(2, 3, BufferedImage.TYPE_INT_RGB);
        image.setRGB(0, 0, 0xFF0000); image.setRGB(1, 0, 0x00FF00);
        image.setRGB(0, 2, 0x0000FF); image.setRGB(1, 2, 0xFFFFFF);
        BufferedImage rotated = ImageDecoder.orient(image, 6);
        assertEquals(3, rotated.getWidth()); assertEquals(2, rotated.getHeight());
        assertEquals(0x0000FF, rotated.getRGB(0, 0) & 0xffffff);
        assertEquals(0xFF0000, rotated.getRGB(2, 0) & 0xffffff);
        assertEquals(0xFFFFFF, rotated.getRGB(0, 1) & 0xffffff);
        assertEquals(0x00FF00, rotated.getRGB(2, 1) & 0xffffff);
    }

    @Test void resizesUsingHalfPixelBilinearAndNormalizesRgb() {
        BufferedImage image = new BufferedImage(2, 2, BufferedImage.TYPE_INT_RGB);
        image.setRGB(0,0,0xFF0000); image.setRGB(1,0,0x00FF00);
        image.setRGB(0,1,0x0000FF); image.setRGB(1,1,0xFFFFFF);
        float[] tensor = RfDetrGateDetector.preprocess(image, 1, 1);
        assertEquals((0.5f-0.485f)/0.229f, tensor[0], 1e-6);
        assertEquals((0.5f-0.456f)/0.224f, tensor[1], 1e-6);
        assertEquals((0.5f-0.406f)/0.225f, tensor[2], 1e-6);
    }

    @Test void decodesSingleClassOnnxContractIntoPixelBoxes() throws Exception {
        // This tiny, deterministic fixture tests the ONNX contract only; it is not a trained detector.
        Path model = Path.of(getClass().getResource("/synthetic-contract.onnx").toURI());
        try (var detector = new RfDetrGateDetector(model, 0)) {
            var detections = detector.detect(new BufferedImage(400, 200, BufferedImage.TYPE_INT_RGB), 0.5f);
            assertEquals(1, detections.size());
            assertEquals("gate", detections.get(0).label());
            assertEquals(0.98201376f, detections.get(0).confidence(), 1e-6);
            assertArrayEquals(new float[]{100, 50, 300, 150}, detections.get(0).box(), 1e-5f);
        }
    }

    @Test void apiReturnsUnavailableInsteadOfFakeDetectionWhenModelMissing() throws Exception {
        System.setProperty("pelagivex.model.path", temp.resolve("missing.onnx").toString());
        Tomcat tomcat = new Tomcat();
        tomcat.setBaseDir(temp.resolve("tomcat").toString());
        tomcat.setPort(0); tomcat.getConnector();
        Context context = tomcat.addContext("", temp.toString());
        Tomcat.addServlet(context, "api", new ApiServlet()).setLoadOnStartup(1);
        context.addServletMappingDecoded("/api/*", "api");
        try {
            tomcat.start();
            int port = tomcat.getConnector().getLocalPort();
            var client = HttpClient.newHttpClient();
            var health = client.send(HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/health")).GET().build(), HttpResponse.BodyHandlers.ofString());
            assertEquals(503, health.statusCode()); assertTrue(health.body().contains("unavailable"));
            var detect = client.send(HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/detect")).POST(HttpRequest.BodyPublishers.noBody()).build(), HttpResponse.BodyHandlers.ofString());
            assertEquals(503, detect.statusCode()); assertTrue(detect.body().contains("not available"));
        } finally {
            tomcat.stop(); tomcat.destroy(); System.clearProperty("pelagivex.model.path");
        }
    }
}
