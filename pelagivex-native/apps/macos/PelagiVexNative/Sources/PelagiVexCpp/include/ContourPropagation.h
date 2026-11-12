#ifndef PELAGIVEX_CONTOUR_PROPAGATION_H
#define PELAGIVEX_CONTOUR_PROPAGATION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float x1, y1, x2, y2;
} PVContourBox;

typedef struct {
    float width, height, scale, padX, padY;
} PVContourGeometry;

typedef struct {
    int64_t trackID, classID;
    PVContourBox box;
} PVContourDetection;

typedef struct {
    size_t sourceIndex, currentIndex;
    PVContourBox sourceBox, currentBox;
} PVContourWarp;

int32_t PVContourNormalizedBox(PVContourBox box, PVContourGeometry geometry, PVContourBox *normalized);

// Outputs follow current detection order. Allocate at least min(sourceCount, currentCount, 255) entries.
size_t PVContourMatch(const PVContourDetection *source, size_t sourceCount, PVContourGeometry sourceGeometry,
                      const PVContourDetection *current, size_t currentCount, PVContourGeometry currentGeometry,
                      PVContourWarp *warps);

#ifdef __cplusplus
}
#endif

#endif
