#ifndef PELAGIVEX_MASK_SAMPLER_H
#define PELAGIVEX_MASK_SAMPLER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PVXMaskSampleBox {
    float x1, y1, x2, y2;
} PVXMaskSampleBox;

typedef struct PVXMaskSampleGrid {
    const uint8_t *pixels;
    size_t pixelCount, imageWidth, imageHeight, rowBytes;
    PVXMaskSampleBox box;
    size_t width, height;
} PVXMaskSampleGrid;

typedef struct PVXMaskSampleOutput {
    uint8_t *silhouette;
    size_t silhouetteCount;
    uint8_t *rgba;
    size_t rgbaCount;
    uint32_t count, red, green, blue;
} PVXMaskSampleOutput;

typedef struct PVXMaskSampleRaster {
    const uint8_t *labels;
    size_t count, width, height;
    uint8_t label;
} PVXMaskSampleRaster;

typedef struct PVXMaskSamplePrototypes {
    const float *values;
    size_t valueCount, width, height, channels;
    float scale, padX, padY, inputSize;
    // Target detection first, then earlier overlapping detections in draw order.
    const PVXMaskSampleBox *boxes;
    size_t boxCount;
    const float *coefficients;
    size_t coefficientCount;
} PVXMaskSamplePrototypes;

bool pvxSampleRasterMask(const PVXMaskSampleGrid *grid, const PVXMaskSampleRaster *raster,
                         PVXMaskSampleOutput *output);
bool pvxSamplePrototypeMask(const PVXMaskSampleGrid *grid, const PVXMaskSamplePrototypes *prototypes,
                            PVXMaskSampleOutput *output);

#ifdef __cplusplus
}
#endif

#endif
