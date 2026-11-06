package com.pelagivex;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

/** Offline inference/benchmark helper. Output is based only on the supplied model and image. */
public final class ModelCheck {
    public static void main(String[] args) throws Exception {
        if (args.length < 2 || args.length > 5) {
            throw new IllegalArgumentException("Usage: ModelCheck model.onnx image [class-index=0] [threshold=0.2] [runs=1]");
        }
        int classIndex = args.length > 2 ? Integer.parseInt(args[2]) : 0;
        float threshold = args.length > 3 ? Float.parseFloat(args[3]) : 0.2f;
        int runs = args.length > 4 ? Integer.parseInt(args[4]) : 1;
        if (runs < 1 || runs > 100) throw new IllegalArgumentException("runs must be between 1 and 100");
        var image = ImageDecoder.decode(Files.readAllBytes(Path.of(args[1])));
        try (var detector = new RfDetrGateDetector(Path.of(args[0]), classIndex)) {
            long[] times = new long[runs];
            java.util.List<RfDetrGateDetector.Detection> detections = null;
            for (int i = 0; i < runs; i++) {
                long start = System.nanoTime();
                detections = detector.detect(image, threshold);
                times[i] = Math.round((System.nanoTime() - start) / 1_000_000.0);
            }
            Map<String,Object> result = new LinkedHashMap<>();
            result.put("width", image.getWidth()); result.put("height", image.getHeight());
            result.put("detections", detections); result.put("run_ms", times);
            System.out.println(new ObjectMapper().writeValueAsString(result));
        }
    }
}
