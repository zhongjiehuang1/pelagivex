#ifndef PELAGIVEX_SINGLE_VIEW_USDZ_H
#define PELAGIVEX_SINGLE_VIEW_USDZ_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Writes packed xyz vertices and triangle index triples as a self-contained USDZ.
/// Returns 0 on success, 1 for invalid geometry, 2 if the path exists, and 3 for other failures.
int32_t PVWriteSingleViewUSDZ(const char *path, const float *positions, uint32_t vertexCount,
                             const uint32_t *indices, uint32_t triangleCount);

#ifdef __cplusplus
}
#endif

#endif
