#include "MaskSampler.h"

#include <algorithm>
#include <cmath>

#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace {

bool validGrid(const PVXMaskSampleGrid *grid, const PVXMaskSampleOutput *output) {
    if (!grid || !output || !grid->pixels || !output->silhouette || !output->rgba ||
        grid->width == 0 || grid->height == 0 || grid->width > 64 || grid->height > 64 ||
        grid->imageWidth == 0 || grid->imageHeight == 0 || grid->rowBytes / 4 < grid->imageWidth ||
        grid->imageWidth * 4 > grid->pixelCount ||
        grid->imageHeight - 1 > (grid->pixelCount - grid->imageWidth * 4) / grid->rowBytes) {
        return false;
    }
    const auto box = grid->box;
    return std::isfinite(box.x1) && std::isfinite(box.y1) && std::isfinite(box.x2) && std::isfinite(box.y2) &&
        box.x1 >= 0 && box.y1 >= 0 && box.x2 > box.x1 && box.y2 > box.y1 &&
        box.x2 <= float(grid->imageWidth) && box.y2 <= float(grid->imageHeight) &&
        output->silhouetteCount == grid->width * grid->height &&
        output->rgbaCount == output->silhouetteCount * 4;
}

template<class Foreground>
void sample(const PVXMaskSampleGrid &grid, PVXMaskSampleOutput &output, Foreground contains) {
    std::fill_n(output.silhouette, output.silhouetteCount, uint8_t(0));
    std::fill_n(output.rgba, output.rgbaCount, uint8_t(0));
    output.red = output.green = output.blue = output.count = 0;
    const float stepX = (grid.box.x2 - grid.box.x1) / float(grid.width);
    const float stepY = (grid.box.y2 - grid.box.y1) / float(grid.height);
    for (size_t row = 0; row < grid.height; ++row) {
        const float y = grid.box.y1 + (float(row) + 0.5f) * stepY;
        for (size_t column = 0; column < grid.width; ++column) {
            const float x = grid.box.x1 + (float(column) + 0.5f) * stepX;
            if (!contains(x, y)) {
                continue;
            }
            const size_t source = std::min(grid.imageHeight - 1, size_t(y)) * grid.rowBytes
                                + std::min(grid.imageWidth - 1, size_t(x)) * 4;
            const size_t index = row * grid.width + column;
            const size_t destination = index * 4;
            const uint8_t red = grid.pixels[source + 2];
            const uint8_t green = grid.pixels[source + 1];
            const uint8_t blue = grid.pixels[source];
            output.silhouette[index] = 1;
            output.rgba[destination] = red;
            output.rgba[destination + 1] = green;
            output.rgba[destination + 2] = blue;
            output.rgba[destination + 3] = 255;
            output.red += red;
            output.green += green;
            output.blue += blue;
            ++output.count;
        }
    }
}

} // namespace

bool pvxSampleRasterMask(const PVXMaskSampleGrid *grid, const PVXMaskSampleRaster *raster,
                         PVXMaskSampleOutput *output) {
    if (!validGrid(grid, output) || !raster || !raster->labels || raster->label == 0 ||
        raster->width == 0 || raster->height == 0 || raster->width > 2048 || raster->height > 2048 ||
        raster->count != raster->width * raster->height) {
        return false;
    }
    sample(*grid, *output, [&](float x, float y) {
        const size_t column = std::min(raster->width - 1, size_t(x * float(raster->width) / float(grid->imageWidth)));
        const size_t row = std::min(raster->height - 1, size_t(y * float(raster->height) / float(grid->imageHeight)));
        return raster->labels[row * raster->width + column] == raster->label;
    });
    return true;
}

bool pvxSamplePrototypeMask(const PVXMaskSampleGrid *grid, const PVXMaskSamplePrototypes *prototypes,
                            PVXMaskSampleOutput *output) {
    if (!validGrid(grid, output) || !prototypes || !prototypes->values || !prototypes->boxes ||
        !prototypes->coefficients || prototypes->width == 0 || prototypes->height == 0 ||
        prototypes->channels == 0 || prototypes->width > 256 || prototypes->height > 256 ||
        prototypes->channels > 128 || prototypes->boxCount == 0 || prototypes->boxCount > 100 ||
        !std::isfinite(prototypes->inputSize) || prototypes->inputSize <= 0 ||
        !std::isfinite(prototypes->scale) || prototypes->scale <= 0 ||
        !std::isfinite(prototypes->padX) || !std::isfinite(prototypes->padY)) {
        return false;
    }
    const size_t width = prototypes->width;
    const size_t height = prototypes->height;
    const size_t channels = prototypes->channels;
    const size_t plane = width * height;
    if (prototypes->valueCount != plane * channels ||
        prototypes->coefficientCount != prototypes->boxCount * channels) {
        return false;
    }
    sample(*grid, *output, [&](float x, float y) {
        const float u = (x * prototypes->scale + prototypes->padX) / prototypes->inputSize;
        const float v = (y * prototypes->scale + prototypes->padY) / prototypes->inputSize;
        const size_t column = size_t(std::clamp(u * float(width), 0.0f, float(width - 1)));
        const size_t row = size_t(std::clamp(v * float(height), 0.0f, float(height - 1)));
        const float centerX = (float(column) + 0.5f) * prototypes->inputSize / float(width);
        const float centerY = (float(row) + 0.5f) * prototypes->inputSize / float(height);
        const size_t offset = row * width + column;
        const auto foreground = [&](size_t index) {
            const auto box = prototypes->boxes[index];
            if (!(centerX >= box.x1 && centerX < box.x2 && centerY >= box.y1 && centerY < box.y2)) {
                return false;
            }
            float sum = 0;
            for (size_t channel = 0; channel < channels; ++channel) {
                sum += prototypes->values[channel * plane + offset]
                     * prototypes->coefficients[index * channels + channel];
            }
            return sum > 0;
        };
        if (!foreground(0)) {
            return false;
        }
        // An earlier positive instance owns an overlap pixel.
        for (size_t index = 1; index < prototypes->boxCount; ++index) {
            if (foreground(index)) {
                return false;
            }
        }
        return true;
    });
    return true;
}
