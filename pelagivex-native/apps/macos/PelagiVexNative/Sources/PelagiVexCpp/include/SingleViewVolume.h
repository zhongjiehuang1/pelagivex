#ifndef PELAGIVEX_SINGLE_VIEW_VOLUME_H
#define PELAGIVEX_SINGLE_VIEW_VOLUME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PVSingleViewMesh {
    float *positions;            // XYZ, tightly packed: vertexCount * 3 floats.
    size_t vertexCount;
    uint32_t *triangleIndices;   // Counter-clockwise triangles with outward normals.
    size_t indexCount;
    int32_t usedDepth;
} PVSingleViewMesh;

// Top-down row-major mask; any nonzero sample is foreground. The optional depth
// grid has the same layout, with larger values closer and NaN for missing values.
// pixelAspect is the width/height of one sample. The mesh is normalized to unit
// maximum silhouette extent, with +Y up and +Z toward the observed face.
// Pass an empty (zero-initialized) output. On success, release its buffers with
// PVSingleViewVolumeFree. A return of zero leaves the output unchanged.
int32_t PVSingleViewVolumeBuild(const uint8_t *mask, size_t maskCount,
                               int32_t width, int32_t height,
                               const float *relativeDepth, size_t depthCount,
                               float pixelAspect, PVSingleViewMesh *outMesh);

void PVSingleViewVolumeFree(PVSingleViewMesh *mesh);

#ifdef __cplusplus
}
#endif

#endif
