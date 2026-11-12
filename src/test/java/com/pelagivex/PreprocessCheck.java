package com.pelagivex;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

/** Offline byte-for-byte tensor comparison helper. */
public final class PreprocessCheck {
    public static void main(String[] args) throws Exception {
        if (args.length != 4) throw new IllegalArgumentException("Usage: PreprocessCheck image output.bin width height");
        var image = ImageDecoder.decode(Files.readAllBytes(Path.of(args[0])));
        float[] data = RfDetrGateDetector.preprocess(image, Integer.parseInt(args[2]), Integer.parseInt(args[3]));
        ByteBuffer buffer = ByteBuffer.allocate(data.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (float value : data) buffer.putFloat(value);
        Files.write(Path.of(args[1]), buffer.array());
    }
}
