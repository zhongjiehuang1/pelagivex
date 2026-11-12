package com.pelagivex;

import ai.onnxruntime.NodeInfo;
import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtException;
import ai.onnxruntime.OrtSession;
import ai.onnxruntime.TensorInfo;
import ai.onnxruntime.providers.CoreMLFlags;
import java.awt.image.BufferedImage;
import java.nio.FloatBuffer;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;

/** Decoder for a single-class RF-DETR ONNX detection export. */
final class RfDetrGateDetector implements AutoCloseable {
    private static final float[] MEAN = {0.485f, 0.456f, 0.406f};
    private static final float[] STD = {0.229f, 0.224f, 0.225f};
    private final OrtEnvironment env;
    private final OrtSession.SessionOptions options;
    private final OrtSession session;
    private final String inputName;
    private final int width, height;
    private final int gateClassIndex;

    RfDetrGateDetector(Path model, int gateClassIndex) throws OrtException {
        if (gateClassIndex < 0 || gateClassIndex > 1) throw new IllegalArgumentException("Invalid gate class index");
        this.gateClassIndex = gateClassIndex;
        env = OrtEnvironment.getEnvironment();
        options = new OrtSession.SessionOptions();
        int threads = Integer.getInteger("pelagivex.threads", 1);
        if (threads < 1 || threads > 32) throw new IllegalArgumentException("Invalid inference thread count");
        options.setIntraOpNumThreads(threads);
        options.setInterOpNumThreads(1);
        options.addConfigEntry("session.intra_op.allow_spinning", "0");
        options.addConfigEntry("session.inter_op.allow_spinning", "0");
        String provider = System.getProperty("pelagivex.provider", "cpu");
        if (provider.equalsIgnoreCase("coreml")) {
            options.addCoreML(EnumSet.of(CoreMLFlags.CREATE_MLPROGRAM));
        } else if (!provider.equalsIgnoreCase("cpu")) {
            throw new IllegalArgumentException("Invalid inference provider");
        }
        OrtSession created = null;
        try {
            created = env.createSession(model.toString(), options);
            if (created.getInputInfo().size() != 1 || !created.getOutputNames().contains("dets") || !created.getOutputNames().contains("labels"))
                throw new IllegalArgumentException("Unsupported model interface");
            NodeInfo input = created.getInputInfo().values().iterator().next();
            if (!(input.getInfo() instanceof TensorInfo info)) throw new IllegalArgumentException("Invalid input tensor");
            long[] shape = info.getShape();
            if (shape.length != 4 || (shape[0] != 1 && shape[0] != -1) || shape[1] != 3 || shape[2] < 1 || shape[2] > 2048 || shape[3] < 1 || shape[3] > 2048)
                throw new IllegalArgumentException("Unsupported input shape");
            long[] labelShape = ((TensorInfo)created.getOutputInfo().get("labels").getInfo()).getShape();
            // RF-DETR versions may emit one slot or include an extra slot; class index comes from training.
            if (labelShape.length != 3 || (labelShape[2] != 1 && labelShape[2] != 2 && labelShape[2] != -1)
                    || (labelShape[2] > 0 && gateClassIndex >= labelShape[2]))
                throw new IllegalArgumentException("Expected a compatible single-class gate export");
            inputName = created.getInputNames().iterator().next();
            height = Math.toIntExact(shape[2]); width = Math.toIntExact(shape[3]);
            session = created;
        } catch (RuntimeException | OrtException e) {
            if (created != null) created.close();
            options.close();
            throw e;
        }
    }

    List<Detection> detect(BufferedImage image, float threshold) throws OrtException {
        float[] pixels = preprocess(image, width, height);
        try (OnnxTensor input = OnnxTensor.createTensor(env, FloatBuffer.wrap(pixels), new long[]{1, 3, height, width});
             OrtSession.Result result = session.run(Map.of(inputName, input))) {
            float[][][] boxes = (float[][][]) result.get("dets").orElseThrow().getValue();
            float[][][] logits = (float[][][]) result.get("labels").orElseThrow().getValue();
            if (boxes.length != 1 || logits.length != 1 || boxes[0].length != logits[0].length)
                throw new IllegalStateException("Model returned unexpected shapes");
            List<Detection> detections = new ArrayList<>();
            for (int i = 0; i < boxes[0].length; i++) {
                if (boxes[0][i].length != 4 || (logits[0][i].length != 1 && logits[0][i].length != 2)
                        || gateClassIndex >= logits[0][i].length)
                    throw new IllegalStateException("Model returned unsupported class layout");
                float logit = logits[0][i][gateClassIndex];
                float score = (float)(1.0 / (1.0 + Math.exp(-logit)));
                float[] box = boxes[0][i];
                if (!Float.isFinite(score) || score <= threshold || !finite(box)) continue;
                float x1 = clamp((box[0] - box[2] / 2) * image.getWidth(), image.getWidth());
                float y1 = clamp((box[1] - box[3] / 2) * image.getHeight(), image.getHeight());
                float x2 = clamp((box[0] + box[2] / 2) * image.getWidth(), image.getWidth());
                float y2 = clamp((box[1] + box[3] / 2) * image.getHeight(), image.getHeight());
                if (x2 > x1 && y2 > y1) detections.add(new Detection("gate", score, new float[]{x1,y1,x2,y2}));
            }
            detections.sort(Comparator.comparingDouble(Detection::confidence).reversed());
            return detections.size() > 25 ? List.copyOf(detections.subList(0, 25)) : detections;
        }
    }

    // Match RF-DETR 1.4: torchvision tensor resize with bilinear antialias=True,
    // half-pixel centers, and ImageNet normalization. Normalization is linear.
    static float[] preprocess(BufferedImage image, int targetW, int targetH) {
        int w = image.getWidth(), h = image.getHeight(), plane = targetW * targetH;
        float[] data = new float[3 * plane];
        int[] pixels = image.getRGB(0, 0, w, h, null, 0, w);
        AxisWeights xAxis = axisWeights(w, targetW), yAxis = axisWeights(h, targetH);
        for (int y = 0; y < targetH; y++) {
            for (int x = 0; x < targetW; x++) {
                int offset = y * targetW + x;
                double red = 0, green = 0, blue = 0;
                for (int yi = 0; yi < yAxis.indices[y].length; yi++) {
                    int sy = yAxis.indices[y][yi]; double wy = yAxis.weights[y][yi];
                    for (int xi = 0; xi < xAxis.indices[x].length; xi++) {
                        int rgb = pixels[sy * w + xAxis.indices[x][xi]];
                        double weight = wy * xAxis.weights[x][xi];
                        red += ((rgb >>> 16) & 255) * weight;
                        green += ((rgb >>> 8) & 255) * weight;
                        blue += (rgb & 255) * weight;
                    }
                }
                data[offset] = ((float)(red / 255.0) - MEAN[0]) / STD[0];
                data[plane + offset] = ((float)(green / 255.0) - MEAN[1]) / STD[1];
                data[2 * plane + offset] = ((float)(blue / 255.0) - MEAN[2]) / STD[2];
            }
        }
        return data;
    }
    private static AxisWeights axisWeights(int source, int target) {
        int[][] indices = new int[target][];
        double[][] weights = new double[target][];
        double scale = (double)source / target, support = Math.max(1.0, scale);
        for (int i = 0; i < target; i++) {
            double center = (i + 0.5) * scale - 0.5;
            int start = Math.max(0, (int)Math.ceil(center - support));
            int end = Math.min(source - 1, (int)Math.floor(center + support));
            indices[i] = new int[end - start + 1]; weights[i] = new double[end - start + 1];
            double total = 0;
            for (int j = start; j <= end; j++) {
                indices[i][j-start] = j;
                weights[i][j-start] = Math.max(0, 1 - Math.abs(j-center) / support);
                total += weights[i][j-start];
            }
            for (int j = 0; j < weights[i].length; j++) weights[i][j] /= total;
        }
        return new AxisWeights(indices, weights);
    }
    private record AxisWeights(int[][] indices, double[][] weights) { }
    private static boolean finite(float[] box) { for (float v : box) if (!Float.isFinite(v)) return false; return true; }
    private static float clamp(float v, int max) { return Math.max(0, Math.min(v, max)); }
    @Override public void close() throws OrtException { try { session.close(); } finally { options.close(); } }
    record Detection(String label, float confidence, float[] box) { }
}
