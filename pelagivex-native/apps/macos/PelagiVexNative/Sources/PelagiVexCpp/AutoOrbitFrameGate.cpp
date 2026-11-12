#include "AutoOrbitFrameGate.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <new>

#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace {

constexpr int columns = 48;
constexpr int rows = 36;
constexpr size_t historyLimit = 12;
constexpr size_t sampleCount = columns * rows;
static_assert(sampleCount == PVX_AUTO_ORBIT_SAMPLE_COUNT);

using Signature = std::array<float, sampleCount>;

float luma(const uint8_t *bytes, size_t stride, size_t x, size_t y) {
    const uint8_t *pixel = bytes + y * stride + x * 4;
    return (float(pixel[2]) * 54 + float(pixel[1]) * 183 + float(pixel[0]) * 19) / 256;
}

bool isNearDuplicate(const Signature &reference, const float *candidate) {
    constexpr float limit = float(sampleCount) * 0.115f;
    float total = 0;
    for (size_t index = 0; index < sampleCount; ++index) {
        total += std::abs(reference[index] - candidate[index]);
        if (total > limit) {
            return false;
        }
    }
    return true;
}

bool hasVisualOverlap(const Signature &reference, const float *candidate) {
    // Allow modest pans when judging overlap between consecutive accepted views.
    constexpr int shifts[] = {0, -3, 3, -6, 6};
    for (int dy : shifts) {
        for (int dx : shifts) {
            const int startX = std::max(0, -dx);
            const int endX = std::min(columns, columns - dx);
            const int startY = std::max(0, -dy);
            const int endY = std::min(rows, rows - dy);
            float dot = 0;
            float firstEnergy = 0;
            float secondEnergy = 0;
            for (int y = startY; y < endY; ++y) {
                const int firstRow = y * columns;
                const int secondRow = (y + dy) * columns + dx;
                for (int x = startX; x < endX; ++x) {
                    const float first = reference[firstRow + x];
                    const float second = candidate[secondRow + x];
                    dot += first * second;
                    firstEnergy += first * first;
                    secondEnergy += second * second;
                }
            }
            if (dot > 0.35f * std::sqrt(firstEnergy * secondEnergy)) {
                return true;
            }
        }
    }
    return false;
}

} // namespace

struct PVXAutoOrbitGate {
    std::array<Signature, historyLimit> history{};
    size_t next = 0;
    size_t count = 0;
};

PVXAutoOrbitGate *pvxAutoOrbitCreate(void) {
    return new (std::nothrow) PVXAutoOrbitGate;
}

PVXAutoOrbitGate *pvxAutoOrbitClone(const PVXAutoOrbitGate *gate) {
    return new (std::nothrow) PVXAutoOrbitGate(*gate);
}

void pvxAutoOrbitDestroy(PVXAutoOrbitGate *gate) {
    delete gate;
}

void pvxAutoOrbitReset(PVXAutoOrbitGate *gate) {
    gate->next = 0;
    gate->count = 0;
}

PVXAutoOrbitVerdict pvxAutoOrbitEvaluate(const PVXAutoOrbitGate *gate, const uint8_t *bytes,
                                       size_t width, size_t height, size_t stride, float *signature) {
    if (!bytes || width < columns || height < rows || stride / 4 < width) {
        return PVXAutoOrbitUnavailable;
    }

    const size_t insetX = width / 10;
    const size_t insetY = height / 10;
    const size_t detailStepX = std::max<size_t>(1, width / 384);
    const size_t detailStepY = std::max<size_t>(1, height / 288);
    float total = 0;
    float squares = 0;
    float fineDetail = 0;
    float coarseDetail = 0;
    for (int row = 0; row < rows; ++row) {
        const size_t y = insetY + (2 * row + 1) * (height - 2 * insetY) / (2 * rows);
        for (int column = 0; column < columns; ++column) {
            const size_t x = insetX + (2 * column + 1) * (width - 2 * insetX) / (2 * columns);
            const size_t index = row * columns + column;
            const float center = luma(bytes, stride, x, y);
            const float horizontal = luma(bytes, stride, x - detailStepX, y)
                                   + luma(bytes, stride, x + detailStepX, y);
            const float vertical = luma(bytes, stride, x, y - detailStepY)
                                 + luma(bytes, stride, x, y + detailStepY);
            const float value = (center * 4 + horizontal + vertical) / 8;
            if (column > 0) {
                coarseDetail += std::abs(value - signature[index - 1]);
            }
            if (row > 0) {
                coarseDetail += std::abs(value - signature[index - columns]);
            }
            signature[index] = value;
            total += value;
            squares += value * value;
            fineDetail += std::abs(2 * center - horizontal) + std::abs(2 * center - vertical);
        }
    }
    const float mean = total / sampleCount;
    const float deviation = std::sqrt(std::max(0.0f, squares / sampleCount - mean * mean));
    if (mean < 24) {
        return PVXAutoOrbitDark;
    }
    if (deviation < 8 || (fineDetail / (2 * sampleCount) < 1.1f && coarseDetail / (2 * sampleCount) < 5.5f)) {
        return PVXAutoOrbitSoft;
    }

    // Compensate for global brightness and contrast changes before looking for movement.
    for (size_t index = 0; index < sampleCount; ++index) {
        signature[index] = (signature[index] - mean) / deviation;
    }
    for (size_t offset = 0; offset < gate->count; ++offset) {
        const size_t index = (gate->next + historyLimit - 1 - offset) % historyLimit;
        if (isNearDuplicate(gate->history[index], signature)) {
            return PVXAutoOrbitUnchanged;
        }
    }
    if (gate->count > 0 && !hasVisualOverlap(gate->history[(gate->next + historyLimit - 1) % historyLimit], signature)) {
        return PVXAutoOrbitAbrupt;
    }
    return PVXAutoOrbitAccept;
}

void pvxAutoOrbitCommit(PVXAutoOrbitGate *gate, const float *signature) {
    std::copy_n(signature, sampleCount, gate->history[gate->next].begin());
    gate->next = (gate->next + 1) % historyLimit;
    gate->count = std::min(gate->count + 1, historyLimit);
}
