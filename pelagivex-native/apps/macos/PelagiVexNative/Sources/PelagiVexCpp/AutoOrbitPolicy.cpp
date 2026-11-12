#include "AutoOrbitPolicy.h"

#include <algorithm>
#include <array>
#include <cmath>

namespace {

constexpr double minimumStageSeconds = 6;
constexpr double minimumAutomaticSeconds = 36;
constexpr double sampleStallSeconds = 6;

enum ClockMode : int32_t { idle, active, paused };

bool timeAtOrAfter(double now, double then) {
    return std::isfinite(now) && now >= then;
}

}  // namespace

void PVAutoOrbitPolicyStart(PVAutoOrbitPolicyState *state, double now) {
    if (!state) return;
    *state = {};
    if (timeAtOrAfter(now, 0)) {
        state->clockMode = active;
        state->activeSince = now;
    }
}

void PVAutoOrbitPolicyPause(PVAutoOrbitPolicyState *state, double now) {
    if (!state || state->clockMode != active || !timeAtOrAfter(now, state->activeSince)) return;
    state->accumulatedSeconds += now - state->activeSince;
    state->clockMode = paused;
    state->pausedAt = now;
}

void PVAutoOrbitPolicyResume(PVAutoOrbitPolicyState *state, double now) {
    if (!state || state->clockMode != paused || !timeAtOrAfter(now, state->pausedAt)) return;
    state->activeSince = now;
    state->clockMode = active;
}

double PVAutoOrbitPolicyElapsed(PVAutoOrbitPolicyState state, double now) {
    if (state.clockMode != active || !timeAtOrAfter(now, state.activeSince)) return state.accumulatedSeconds;
    return state.accumulatedSeconds + now - state.activeSince;
}

PVAutoOrbitPolicyDecision PVAutoOrbitPolicyUpdate(PVAutoOrbitPolicyState *state,
                                                  int64_t acceptedPhotos,
                                                  PVAutoOrbitPhotoCounts counts,
                                                  double now) {
    if (!state || state->clockMode != active || !timeAtOrAfter(now, state->activeSince) ||
        state->stage < 0 || state->stage >= PVAutoOrbitPolicyStageCount) return PVAutoOrbitPolicyKeepCapturing;
    const double activeSeconds = PVAutoOrbitPolicyElapsed(*state, now);
    if (acceptedPhotos > state->lastAcceptedCount) {
        state->lastAcceptedCount = acceptedPhotos;
        state->lastAcceptedAtElapsed = activeSeconds;
    }

    const std::array<int64_t, PVAutoOrbitPolicyStageCount> photos{
        counts.front, counts.firstSide, counts.back, counts.secondSide, counts.upper
    };
    const auto enoughSamples = [](int64_t count) { return count >= PVAutoOrbitPolicySamplesPerStage; };
    const bool currentStageReady = activeSeconds - state->stageStartedAtElapsed >= minimumStageSeconds
        && enoughSamples(photos[state->stage]);
    if (currentStageReady) {
        if (state->stage + 1 < PVAutoOrbitPolicyStageCount) {
            ++state->stage;
            state->stageStartedAtElapsed = activeSeconds;
            return PVAutoOrbitPolicyKeepCapturing;
        }
        if (activeSeconds >= minimumAutomaticSeconds && acceptedPhotos >= PVAutoOrbitPolicyAutomaticPhotos &&
            std::all_of(photos.begin(), photos.end(), enoughSamples)) return PVAutoOrbitPolicyReconstruct;
    }

    return activeSeconds - state->lastAcceptedAtElapsed >= sampleStallSeconds
        ? PVAutoOrbitPolicyNeedsMoreViews : PVAutoOrbitPolicyKeepCapturing;
}
