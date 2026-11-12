#include "ContourPropagation.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <unordered_map>

#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace {
constexpr size_t ambiguous = std::numeric_limits<size_t>::max();
using TrackIndex = std::unordered_map<int64_t, size_t>;

TrackIndex indexTracks(const PVContourDetection *detections, size_t count) {
    TrackIndex indices;
    indices.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const int64_t trackID = detections[i].trackID;
        if (trackID <= 0) continue;
        const auto [entry, inserted] = indices.emplace(trackID, i);
        if (!inserted) entry->second = ambiguous;
    }
    return indices;
}

bool validBox(PVContourBox box) {
    return std::isfinite(box.x1) && std::isfinite(box.y1) &&
        std::isfinite(box.x2) && std::isfinite(box.y2) && box.x2 > box.x1 && box.y2 > box.y1;
}

float overlap(PVContourBox source, PVContourBox current) {
    const float intersect =
        std::max(0.f, std::min(source.x2, current.x2) - std::max(source.x1, current.x1)) *
        std::max(0.f, std::min(source.y2, current.y2) - std::max(source.y1, current.y1));
    const float sourceArea = (source.x2 - source.x1) * (source.y2 - source.y1);
    const float currentArea = (current.x2 - current.x1) * (current.y2 - current.y1);
    return intersect / std::max(sourceArea + currentArea - intersect, 1e-9f);
}

bool acceptableScale(float ratio) {
    return ratio >= 0.7f && ratio <= 1.4f;
}
}

int32_t PVContourNormalizedBox(PVContourBox box, PVContourGeometry geometry, PVContourBox *normalized) {
    if (!normalized || !validBox(box) || !(geometry.width > 0 && geometry.height > 0 && geometry.scale > 0)) return 0;
    const PVContourBox bounds {
        std::max((box.x1 - geometry.padX) / geometry.scale / geometry.width, 0.f),
        std::max((box.y1 - geometry.padY) / geometry.scale / geometry.height, 0.f),
        std::min(1.f, (box.x2 - geometry.padX) / geometry.scale / geometry.width),
        std::min(1.f, (box.y2 - geometry.padY) / geometry.scale / geometry.height)
    };
    if (!validBox(bounds)) return 0;
    *normalized = bounds;
    return 1;
}

size_t PVContourMatch(const PVContourDetection *source, size_t sourceCount, PVContourGeometry sourceGeometry,
                      const PVContourDetection *current, size_t currentCount, PVContourGeometry currentGeometry,
                      PVContourWarp *warps) {
    if (!source || !current || !warps || sourceCount == 0 || currentCount == 0) return 0;
    try {
        const auto sourceIndices = indexTracks(source, sourceCount);
        const auto currentIndices = indexTracks(current, currentCount);
        size_t matched = 0;
        for (size_t i = 0; i < currentCount; ++i) {
            const auto &next = current[i];
            const auto nextIndex = currentIndices.find(next.trackID);
            if (nextIndex == currentIndices.end() || nextIndex->second != i) continue;
            const auto previous = sourceIndices.find(next.trackID);
            if (previous == sourceIndices.end() || previous->second >= 255) continue;
            const size_t sourceIndex = previous->second;
            const auto &old = source[sourceIndex];
            if (old.classID != next.classID) continue;
            PVContourBox oldBox, newBox;
            if (!PVContourNormalizedBox(old.box, sourceGeometry, &oldBox) ||
                !PVContourNormalizedBox(next.box, currentGeometry, &newBox)) continue;
            const float widthRatio = (newBox.x2 - newBox.x1) / (oldBox.x2 - oldBox.x1);
            const float heightRatio = (newBox.y2 - newBox.y1) / (oldBox.y2 - oldBox.y1);
            if (!acceptableScale(widthRatio) || !acceptableScale(heightRatio) || overlap(oldBox, newBox) < 0.45f) continue;
            warps[matched++] = {sourceIndex, i, oldBox, newBox};
        }
        return matched;
    } catch (...) {
        return 0;
    }
}
