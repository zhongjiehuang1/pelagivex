#ifndef PELAGIVEX_LIVE_MODEL_PLACEMENT_H
#define PELAGIVEX_LIVE_MODEL_PLACEMENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double x, y, width, height;
} PVLiveRect;

typedef struct {
    int32_t horizontalSide;
    int32_t verticalSide;
    int32_t hasPosition;
    double cardX, cardY;
} PVLivePlacementState;

typedef struct {
    PVLiveRect rect;
    int32_t corner;
} PVLivePlacement;

// Top-left viewport coordinates in points. Initialize the placement state to zero.
// Finds a fixed 260 × 208 point card position on the opposite side, or hides it if obstructed.
// Corner indices: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right, -1 hidden.
PVLivePlacement PVPlaceLiveModel(PVLivePlacementState *state, PVLiveRect image, PVLiveRect target,
                                 const PVLiveRect *otherObjects, size_t objectCount);

#ifdef __cplusplus
}
#endif

#endif
