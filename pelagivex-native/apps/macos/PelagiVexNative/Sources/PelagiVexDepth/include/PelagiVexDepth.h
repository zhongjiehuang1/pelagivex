#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the local Core ML model once. Returns 1 on success.
int32_t PVPrepareProximity(const char *modelPath);

// Coordinates are normalized, with a top-left origin. The caller owns the image buffer
// and output storage. Larger output values indicate higher model-estimated proximity.
int32_t PVEstimateProximity(const char *modelPath, const void *pixelBuffer,
                           float x, float y, float width, float height,
                           int32_t columns, int32_t rows, float *output);

#ifdef __cplusplus
}
#endif
