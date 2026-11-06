package com.pelagivex;

import com.drew.imaging.ImageMetadataReader;
import com.drew.metadata.Metadata;
import com.drew.metadata.exif.ExifIFD0Directory;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.Iterator;
import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.stream.ImageInputStream;
import javax.imageio.stream.MemoryCacheImageInputStream;

/** Decodes bounded JPEG/PNG images before they reach the model. */
final class ImageDecoder {
    static final long MAX_PIXELS = 4_000_000;
    static final int MAX_SIDE = 4000;

    static BufferedImage decode(byte[] bytes) throws IOException {
        try (ImageInputStream stream = new MemoryCacheImageInputStream(new ByteArrayInputStream(bytes))) {
            Iterator<ImageReader> readers = ImageIO.getImageReaders(stream);
            if (!readers.hasNext()) throw new IOException("Please choose a valid JPEG or PNG image.");
            ImageReader reader = readers.next();
            try {
                String format = reader.getFormatName().toLowerCase(java.util.Locale.ROOT);
                if (!(format.equals("jpeg") || format.equals("jpg") || format.equals("png")))
                    throw new IOException("Please choose a JPEG or PNG image.");
                reader.setInput(stream, true, true);
                int width = reader.getWidth(0), height = reader.getHeight(0);
                if (width < 1 || height < 1 || width > MAX_SIDE || height > MAX_SIDE || (long) width * height > MAX_PIXELS)
                    throw new IOException("Image dimensions are too large (maximum 4 megapixels). ");
                BufferedImage image = reader.read(0);
                if (image == null) throw new IOException("The image could not be read.");
                return orient(image, format.equals("png") ? 1 : exifOrientation(bytes));
            } finally { reader.dispose(); }
        } catch (IllegalArgumentException e) {
            throw new IOException("The image could not be read.", e);
        }
    }

    private static int exifOrientation(byte[] bytes) {
        try {
            Metadata metadata = ImageMetadataReader.readMetadata(new ByteArrayInputStream(bytes));
            ExifIFD0Directory directory = metadata.getFirstDirectoryOfType(ExifIFD0Directory.class);
            return directory == null ? 1 : directory.getInteger(ExifIFD0Directory.TAG_ORIENTATION) == null
                    ? 1 : directory.getInteger(ExifIFD0Directory.TAG_ORIENTATION);
        } catch (Exception ignored) { return 1; }
    }

    static BufferedImage orient(BufferedImage src, int orientation) {
        if (orientation < 2 || orientation > 8) return src;
        int w = src.getWidth(), h = src.getHeight();
        int outW = orientation >= 5 ? h : w, outH = orientation >= 5 ? w : h;
        BufferedImage out = new BufferedImage(outW, outH, BufferedImage.TYPE_INT_RGB);
        for (int y = 0; y < outH; y++) for (int x = 0; x < outW; x++) {
            int sx, sy;
            switch (orientation) {
                case 2 -> { sx = w - 1 - x; sy = y; }
                case 3 -> { sx = w - 1 - x; sy = h - 1 - y; }
                case 4 -> { sx = x; sy = h - 1 - y; }
                case 5 -> { sx = y; sy = x; }
                case 6 -> { sx = y; sy = h - 1 - x; }
                case 7 -> { sx = w - 1 - y; sy = h - 1 - x; }
                case 8 -> { sx = w - 1 - y; sy = x; }
                default -> throw new IllegalStateException();
            }
            out.setRGB(x, y, src.getRGB(sx, sy));
        }
        return out;
    }
    private ImageDecoder() { }
}
