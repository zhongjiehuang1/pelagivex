#ifndef PELAGIVEX_TRACKER_ASSIGNMENT_H
#define PELAGIVEX_TRACKER_ASSIGNMENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// costs contains rows * columns entries in row-major order, and assignments
// has one slot per row. The matrix must have at least as many columns as rows.
// Returns 1 on success, or 0 if no finite assignment can be produced.
int32_t PVTrackerAssign(const double *costs, size_t rows, size_t columns, size_t *assignments);

#ifdef __cplusplus
}
#endif

#endif
