#ifndef PELAGIVEX_END_TO_END_DECODER_H
#define PELAGIVEX_END_TO_END_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns the number of rows written, or -1 for an invalid tensor or options.
// The caller owns rows and must provide at least limit entries.
int32_t PVSelectEndToEndRows(const float *values, size_t valueCount, size_t classes,
                            size_t channels, size_t proposals, float confidence,
                            size_t limit, size_t *rows);

#ifdef __cplusplus
}
#endif

#endif
