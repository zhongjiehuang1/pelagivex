#ifndef PELAGIVEX_AUTO_ORBIT_POLICY_H
#define PELAGIVEX_AUTO_ORBIT_POLICY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    PVAutoOrbitPolicyMinimumPhotos = 20,
    PVAutoOrbitPolicySamplesPerStage = 6,
    PVAutoOrbitPolicyStageCount = 5,
    PVAutoOrbitPolicyAutomaticPhotos = PVAutoOrbitPolicySamplesPerStage * PVAutoOrbitPolicyStageCount
};

typedef struct PVAutoOrbitPolicyState {
    int32_t stage;
    int32_t clockMode;
    double activeSince;
    double pausedAt;
    double accumulatedSeconds;
    double stageStartedAtElapsed;
    double lastAcceptedAtElapsed;
    int64_t lastAcceptedCount;
} PVAutoOrbitPolicyState;

typedef struct PVAutoOrbitPhotoCounts {
    int64_t front;
    int64_t firstSide;
    int64_t back;
    int64_t secondSide;
    int64_t upper;
} PVAutoOrbitPhotoCounts;

typedef enum PVAutoOrbitPolicyDecision {
    PVAutoOrbitPolicyKeepCapturing,
    PVAutoOrbitPolicyReconstruct,
    PVAutoOrbitPolicyNeedsMoreViews
} PVAutoOrbitPolicyDecision;

// State is value-owned and may be zero-initialized. All times are monotonic seconds.
void PVAutoOrbitPolicyStart(PVAutoOrbitPolicyState *state, double now);
void PVAutoOrbitPolicyPause(PVAutoOrbitPolicyState *state, double now);
void PVAutoOrbitPolicyResume(PVAutoOrbitPolicyState *state, double now);
double PVAutoOrbitPolicyElapsed(PVAutoOrbitPolicyState state, double now);
PVAutoOrbitPolicyDecision PVAutoOrbitPolicyUpdate(PVAutoOrbitPolicyState *state,
                                                  int64_t acceptedPhotos,
                                                  PVAutoOrbitPhotoCounts counts,
                                                  double now);

#ifdef __cplusplus
}
#endif

#endif
