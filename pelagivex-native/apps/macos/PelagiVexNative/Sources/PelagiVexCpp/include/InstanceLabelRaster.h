#ifndef PELAGIVEX_INSTANCE_LABEL_RASTER_H
#define PELAGIVEX_INSTANCE_LABEL_RASTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Writes one byte per possible label into a 256-byte table owned by the caller.
bool pvxDiscoverInstanceLabels(const uint8_t *pixels, size_t count, uint8_t maximumLabel,
                               uint8_t *present);

#ifdef __cplusplus
}
#endif

#endif
