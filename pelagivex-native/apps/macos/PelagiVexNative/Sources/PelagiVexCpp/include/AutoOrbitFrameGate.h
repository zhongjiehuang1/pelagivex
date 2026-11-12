#ifndef PELAGIVEX_AUTO_ORBIT_FRAME_GATE_H
#define PELAGIVEX_AUTO_ORBIT_FRAME_GATE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PVX_AUTO_ORBIT_SAMPLE_COUNT 1728

typedef struct PVXAutoOrbitGate PVXAutoOrbitGate;

typedef enum PVXAutoOrbitVerdict {
    PVXAutoOrbitAccept,
    PVXAutoOrbitDark,
    PVXAutoOrbitSoft,
    PVXAutoOrbitUnchanged,
    PVXAutoOrbitAbrupt,
    PVXAutoOrbitUnavailable
} PVXAutoOrbitVerdict;

PVXAutoOrbitGate *pvxAutoOrbitCreate(void);
PVXAutoOrbitGate *pvxAutoOrbitClone(const PVXAutoOrbitGate *gate);
void pvxAutoOrbitDestroy(PVXAutoOrbitGate *gate);
void pvxAutoOrbitReset(PVXAutoOrbitGate *gate);

// The caller owns the BGRA buffer and provides PVX_AUTO_ORBIT_SAMPLE_COUNT output floats.
PVXAutoOrbitVerdict pvxAutoOrbitEvaluate(const PVXAutoOrbitGate *gate, const uint8_t *bytes,
                                       size_t width, size_t height, size_t stride, float *signature);
void pvxAutoOrbitCommit(PVXAutoOrbitGate *gate, const float *signature);

#ifdef __cplusplus
}
#endif

#endif
