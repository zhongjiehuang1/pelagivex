#include "LiveModelPlacement.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace {

constexpr double deadBand = 0.075;
constexpr double cardWidth = 260;
constexpr double cardHeight = 208;
constexpr double settlingGap = 6;

bool usable(PVLiveRect rect) {
    return std::isfinite(rect.x) && std::isfinite(rect.y) &&
           std::isfinite(rect.width) && std::isfinite(rect.height) &&
           rect.width > 0.0 && rect.height > 0.0;
}

bool intersects(PVLiveRect a, PVLiveRect b) {
    return a.x < b.x + b.width && b.x < a.x + a.width &&
           a.y < b.y + b.height && b.y < a.y + a.height;
}

PVLiveRect padded(PVLiveRect rect, double gap) {
    return {rect.x - gap, rect.y - gap, rect.width + 2 * gap, rect.height + 2 * gap};
}

int32_t oppositeSide(double center, int32_t previous) {
    if (center < 0.5 - deadBand) return 1;
    if (center > 0.5 + deadBand) return -1;
    if (previous != 0) return previous;
    return center <= 0.5 ? 1 : -1;
}

// Only the closest edges to the corner are needed in ordinary scenes. Cap
// each axis so crowded frames cannot make the per-frame search unbounded.
struct AxisCandidates {
    const double lower, upper, anchor;
    std::array<double, 32> values{};
    size_t count = 0;

    void add(double value) {
        value = std::clamp(value, lower, upper);
        const auto end = values.begin() + count;
        if (std::find(values.begin(), end, value) != end) return;
        if (count < values.size()) {
            values[count++] = value;
            return;
        }
        const auto farther = std::max_element(values.begin(), end, [&](double a, double b) {
            return std::abs(a - anchor) < std::abs(b - anchor);
        });
        if (std::abs(value - anchor) < std::abs(*farther - anchor)) *farther = value;
    }

    void order() {
        std::sort(values.begin(), values.begin() + count, [&](double a, double b) {
            return std::abs(a - anchor) < std::abs(b - anchor);
        });
    }
};

} // namespace

PVLivePlacement PVPlaceLiveModel(PVLivePlacementState *state, PVLiveRect image, PVLiveRect target,
                                 const PVLiveRect *otherObjects, size_t objectCount) {
    const PVLivePlacement hidden{{}, -1};
    if (!state || !usable(image) || !usable(target) || !intersects(image, target)) return hidden;
    if (!otherObjects) objectCount = 0;

    const double targetX = (target.x + target.width / 2 - image.x) / image.width;
    const double targetY = (target.y + target.height / 2 - image.y) / image.height;
    const int32_t horizontal = oppositeSide(targetX, state->horizontalSide);
    const int32_t vertical = oppositeSide(targetY, state->verticalSide);
    if (horizontal != state->horizontalSide || vertical != state->verticalSide) state->hasPosition = 0;
    state->horizontalSide = horizontal;
    state->verticalSide = vertical;

    const double margin = std::clamp(image.width * 0.014, 10.0, 22.0);
    const double gap = std::clamp(image.width * 0.013, 8.0, 20.0);
    // Reserve the top edge for window chrome and the invisible video controls.
    const bool right = horizontal > 0;
    const bool bottom = vertical > 0;
    const double centerX = image.x + (image.width - cardWidth) / 2;
    const double centerY = image.y + (image.height - cardHeight) / 2;
    const double minX = image.x + margin;
    const double minY = image.y + 48;
    const double maxX = image.x + image.width - margin - cardWidth;
    const double maxY = image.y + image.height - margin - cardHeight;
    if (minX > maxX || minY > maxY) return hidden;

    const double sideMinX = right ? std::max(minX, centerX) : minX;
    const double sideMaxX = right ? maxX : std::min(maxX, centerX);
    const double sideMinY = bottom ? std::max(minY, centerY) : minY;
    const double sideMaxY = bottom ? maxY : std::min(maxY, centerY);
    const bool verticalFallback = std::abs(targetX - 0.5) <= deadBand &&
                                  std::abs(targetY - 0.5) > deadBand;

    const PVLiveRect protectedTarget = padded(target, gap);
    const auto clear = [&](PVLiveRect card, double clearance) {
        if (intersects(card, padded(protectedTarget, clearance))) return false;
        for (size_t i = 0; i < objectCount; ++i) {
            if (usable(otherObjects[i]) && intersects(card, padded(otherObjects[i], clearance))) return false;
        }
        return true;
    };
    const auto placement = [&](PVLiveRect card) -> PVLivePlacement {
        const bool onRight = card.x == centerX ? right : card.x > centerX;
        const bool onBottom = card.y == centerY ? bottom : card.y > centerY;
        return {card, (onBottom ? 2 : 0) + (onRight ? 1 : 0)};
    };
    const bool heldOnOppositeX = state->cardX >= sideMinX && state->cardX <= sideMaxX;
    const bool heldOnOppositeY = state->cardY >= sideMinY && state->cardY <= sideMaxY;
    if (state->hasPosition && state->cardX >= minX && state->cardX <= maxX &&
        state->cardY >= minY && state->cardY <= maxY &&
        (heldOnOppositeX || (verticalFallback && heldOnOppositeY))) {
        const PVLiveRect held{state->cardX, state->cardY, cardWidth, cardHeight};
        if (clear(held, 0)) return placement(held);
    }

    const auto remember = [&](PVLiveRect card) {
        state->hasPosition = 1;
        state->cardX = card.x;
        state->cardY = card.y;
        return placement(card);
    };
    const auto search = [&](double xMin, double xMax, double yMin, double yMax) -> PVLivePlacement {
        if (xMin > xMax || yMin > yMax) return hidden;
        const double anchorX = right ? xMax : xMin;
        const double anchorY = bottom ? yMax : yMin;
        const PVLiveRect searchArea{xMin, yMin, xMax - xMin + cardWidth, yMax - yMin + cardHeight};
        for (const double clearance : {settlingGap, 0.0}) {
            const PVLiveRect anchor{anchorX, anchorY, cardWidth, cardHeight};
            if (clear(anchor, clearance)) return remember(anchor);
            AxisCandidates xs{xMin, xMax, anchorX}, ys{yMin, yMax, anchorY};
            xs.add(anchorX); ys.add(anchorY);
            const auto addEdges = [&](PVLiveRect obstacle) {
                if (!usable(obstacle)) return;
                obstacle = padded(obstacle, clearance);
                if (!intersects(obstacle, searchArea)) return;
                xs.add(obstacle.x - cardWidth);
                xs.add(obstacle.x + obstacle.width);
                ys.add(obstacle.y - cardHeight);
                ys.add(obstacle.y + obstacle.height);
            };
            addEdges(protectedTarget);
            for (size_t i = 0; i < objectCount; ++i) addEdges(otherObjects[i]);
            xs.order(); ys.order();

            // Test obstacle-edge intersections in order of distance to the anchor.
            PVLiveRect best{};
            double bestDistance = std::numeric_limits<double>::infinity();
            for (size_t x = 0; x < xs.count; ++x) {
                const double dx = xs.values[x] - anchorX;
                if (dx * dx >= bestDistance) break;
                for (size_t y = 0; y < ys.count; ++y) {
                    const double dy = ys.values[y] - anchorY;
                    const double distance = dx * dx + dy * dy;
                    if (distance >= bestDistance) break;
                    const PVLiveRect candidate{xs.values[x], ys.values[y], cardWidth, cardHeight};
                    if (clear(candidate, clearance)) {
                        best = candidate;
                        bestDistance = distance;
                    }
                }
            }
            if (std::isfinite(bestDistance)) return remember(best);
        }
        return hidden;
    };

    auto result = search(sideMinX, sideMaxX, sideMinY, sideMaxY);
    if (result.corner < 0 && (sideMinY != minY || sideMaxY != maxY)) {
        result = search(sideMinX, sideMaxX, minY, maxY);
    }
    if (result.corner < 0 && verticalFallback) {
        result = search(minX, maxX, sideMinY, sideMaxY);
    }
    return result;
}
