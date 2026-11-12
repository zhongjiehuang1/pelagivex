#include "EndToEndDecoder.h"

#include <algorithm>
#include <array>
#include <cmath>

int32_t PVSelectEndToEndRows(const float *values, size_t valueCount, size_t classes,
                            size_t channels, size_t proposals, float confidence,
                            size_t limit, size_t *rows) {
    constexpr size_t maximumProposals = 1000;
    if (!values || !rows || classes < 1 || classes > 6000 || channels < 1 || channels > 128
        || proposals < 1 || proposals > maximumProposals || limit < 1 || limit > 100
        || !std::isfinite(confidence) || confidence < 0 || confidence > 1
        || valueCount != proposals * (6 + channels)) {
        return -1;
    }

    const size_t stride = 6 + channels;
    std::array<size_t, maximumProposals> candidates;
    size_t count = 0;
    for (size_t row = 0; row < proposals; ++row) {
        const float *proposal = values + row * stride;
        const float score = proposal[4];
        const float classID = proposal[5];
        if (!std::isfinite(score) || score < confidence || score > 1
            || !std::isfinite(classID) || classID < 0 || classID >= static_cast<float>(classes)
            || std::trunc(classID) != classID || proposal[2] <= proposal[0] || proposal[3] <= proposal[1]) {
            continue;
        }
        const auto finite = [](float value) { return std::isfinite(value); };
        if (!std::all_of(proposal, proposal + 4, finite)
            || !std::all_of(proposal + 6, proposal + stride, finite)) {
            continue;
        }
        candidates[count++] = row;
    }

    const size_t selected = std::min(limit, count);
    std::partial_sort(candidates.begin(), candidates.begin() + selected, candidates.begin() + count,
                      [&](size_t first, size_t second) {
        const float firstScore = values[first * stride + 4];
        const float secondScore = values[second * stride + 4];
        return firstScore == secondScore ? first < second : firstScore > secondScore;
    });
    std::copy_n(candidates.begin(), selected, rows);
    return static_cast<int32_t>(selected);
}
