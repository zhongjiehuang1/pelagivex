#include "SingleViewVolume.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <memory>
#include <unordered_map>
#include <vector>

namespace {

constexpr int maximumDimension = 256;
constexpr size_t minimumForeground = 4;
constexpr uint32_t noVertex = std::numeric_limits<uint32_t>::max();

struct Grid {
    int stride;
    int rows;
    std::vector<uint8_t> inside;
    std::vector<float> distance;
    std::vector<float> proximity;
    int left;
    int right = 0;
    int top;
    int bottom = 0;

    Grid(int width, int height)
        : stride(width + 2), rows(height + 2), inside(stride * rows),
          distance(stride * rows), left(stride), top(rows) {}
};

// Suppress disconnected fragments from the segmentation. The padding guarantees
// that every foreground pixel has a complete neighborhood, including at the edge.
std::vector<int> largestComponent(const uint8_t *mask, int width, int height, Grid &grid) {
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            grid.inside[(y + 1) * grid.stride + x + 1] = mask[y * width + x] != 0;
        }
    }
    std::vector<int> best, component;
    const std::array<int, 4> neighbors{-1, 1, -grid.stride, grid.stride};
    for (int y = 1; y <= height; ++y) {
        for (int x = 1; x <= width; ++x) {
            const int seed = y * grid.stride + x;
            if (!grid.inside[seed]) continue;
            component.clear();
            component.push_back(seed);
            grid.inside[seed] = 0;
            for (size_t i = 0; i < component.size(); ++i) {
                for (const int offset : neighbors) {
                    const int next = component[i] + offset;
                    if (grid.inside[next]) {
                        grid.inside[next] = 0;
                        component.push_back(next);
                    }
                }
            }
            if (component.size() > best.size()) best.swap(component);
        }
    }
    for (const int cell : best) {
        grid.inside[cell] = 1;
        const int x = cell % grid.stride, y = cell / grid.stride;
        grid.left = std::min(grid.left, x);
        grid.right = std::max(grid.right, x);
        grid.top = std::min(grid.top, y);
        grid.bottom = std::max(grid.bottom, y);
    }
    return best;
}

float distanceToSilhouette(Grid &grid, const std::vector<int> &component, float aspect) {
    const int stride = grid.stride;
    for (const int cell : component) grid.distance[cell] = std::numeric_limits<float>::infinity();
    const float diagonal = std::hypot(aspect, 1.0f);
    auto &d = grid.distance;
    for (int y = grid.top; y <= grid.bottom; ++y) {
        for (int x = grid.left; x <= grid.right; ++x) {
            const int i = y * stride + x;
            if (grid.inside[i]) {
                d[i] = std::min({d[i], d[i - 1] + aspect, d[i - stride] + 1,
                                 d[i - stride - 1] + diagonal, d[i - stride + 1] + diagonal});
            }
        }
    }
    float maximum = 0;
    for (int y = grid.bottom; y >= grid.top; --y) {
        for (int x = grid.right; x >= grid.left; --x) {
            const int i = y * stride + x;
            if (grid.inside[i]) {
                d[i] = std::min({d[i], d[i + 1] + aspect, d[i + stride] + 1,
                                 d[i + stride - 1] + diagonal, d[i + stride + 1] + diagonal});
                maximum = std::max(maximum, d[i]);
            }
        }
    }
    return maximum;
}

bool loadProximity(Grid &grid, const std::vector<int> &component, const float *depth, int width) {
    if (!depth) return false;
    const int stride = grid.stride;
    const auto sourceIndex = [stride, width](int cell) {
        return (cell / stride - 1) * width + cell % stride - 1;
    };
    std::vector<float> values;
    values.reserve(component.size());
    for (const int cell : component) {
        const float value = depth[sourceIndex(cell)];
        if (std::isfinite(value)) values.push_back(value);
    }
    if (values.size() < std::max<size_t>(8, (component.size() + 1) / 2)) return false;
    std::sort(values.begin(), values.end());
    const double low = values[(values.size() - 1) / 10];
    const double high = values[(values.size() - 1) * 9 / 10];
    if (high - low <= std::max({1.0, std::abs(low), std::abs(high)}) * 1e-5) return false;

    grid.proximity.assign(grid.inside.size(), std::numeric_limits<float>::quiet_NaN());
    for (const int cell : component) {
        const float value = depth[sourceIndex(cell)];
        if (std::isfinite(value)) {
            grid.proximity[cell] = static_cast<float>(2 * std::clamp((value - low) / (high - low), 0.0, 1.0) - 1);
        }
    }
    return true;
}

float smoothedProximity(const Grid &grid, int cell) {
    if (grid.proximity.empty()) return 0;
    float sum = 0;
    int weight = 0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            const float value = grid.proximity[cell + y * grid.stride + x];
            if (!std::isfinite(value)) continue;
            const int sampleWeight = (2 - std::abs(x)) * (2 - std::abs(y));
            sum += value * sampleWeight;
            weight += sampleWeight;
        }
    }
    return weight > 0 ? sum / weight : 0;
}

// Clip a shared triangular grid at the silhouette. Front/back vertices are
// paired, and each contour segment gets a side wall with shared indices. A
// distance-to-contour profile rounds the body; even at the rim it stays thick.
class Builder {
public:
    Builder(const Grid &grid, float aspect, float maximumDistance)
        : grid_(grid), aspect_(aspect),
          scale_(1 / std::max((grid.right - grid.left + 1) * aspect, static_cast<float>(grid.bottom - grid.top + 1))),
          centerX_((grid.left + grid.right) * 0.5f), centerY_((grid.top + grid.bottom) * 0.5f),
          boundaryOffset_(0.5f * std::min(aspect, 1.0f)), maximumDistance_(maximumDistance),
          halfDepth_(std::max(0.07f, 0.39f * scale_ * std::min((grid.right - grid.left + 1) * aspect,
                                                               static_cast<float>(grid.bottom - grid.top + 1)))),
          gridVertices_(grid.inside.size(), noVertex) {}

    void build() {
        const int stride = grid_.stride;
        for (int y = grid_.top - 1; y <= grid_.bottom; ++y) {
            for (int x = grid_.left - 1; x <= grid_.right; ++x) {
                const int a = y * stride + x, b = a + 1;
                const int c = a + stride, d = c + 1;
                if ((x + y) % 2 == 0) {
                    clip({a, c, b});
                    clip({b, c, d});
                } else {
                    clip({a, c, d});
                    clip({a, d, b});
                }
            }
        }
    }

    std::vector<float> positions;
    std::vector<uint32_t> indices;

private:
    struct Corner { uint32_t front; bool contour; };

    uint32_t append(float x, float y, float profile, float relief) {
        const uint32_t index = static_cast<uint32_t>(positions.size() / 3);
        x = (x - centerX_) * aspect_ * scale_;
        y = (centerY_ - y) * scale_;
        const float halfThickness = halfDepth_ * profile;
        positions.insert(positions.end(), {x, y, halfThickness * (1 + 0.48f * relief), x, y, -halfThickness});
        return index;
    }

    uint32_t interior(int cell) {
        auto &index = gridVertices_[cell];
        if (index == noVertex) {
            const float t = std::clamp((grid_.distance[cell] - boundaryOffset_) / (maximumDistance_ - boundaryOffset_), 0.0f, 1.0f);
            const float taper = std::max(0.18f, std::sqrt(t * (2 - t)));
            index = append(static_cast<float>(cell % grid_.stride), static_cast<float>(cell / grid_.stride), taper,
                           smoothedProximity(grid_, cell));
        }
        return index;
    }

    uint32_t crossing(int a, int b) {
        const auto lo = static_cast<uint32_t>(std::min(a, b));
        const auto hi = static_cast<uint32_t>(std::max(a, b));
        const uint64_t key = (uint64_t{lo} << 32) | hi;
        const auto found = crossingVertices_.find(key);
        if (found != crossingVertices_.end()) return found->second;
        const int stride = grid_.stride;
        const float x = (a % stride + b % stride) * 0.5f;
        const float y = (a / stride + b / stride) * 0.5f;
        const auto index = append(x, y, 0.18f, 0);
        crossingVertices_.emplace(key, index);
        return index;
    }

    void clip(const std::array<int, 3> &triangle) {
        std::array<Corner, 4> polygon{};
        size_t count = 0;
        for (size_t i = 0; i < triangle.size(); ++i) {
            const int a = triangle[i], b = triangle[(i + 1) % triangle.size()];
            if (grid_.inside[a]) polygon[count++] = {interior(a), false};
            if (grid_.inside[a] != grid_.inside[b]) polygon[count++] = {crossing(a, b), true};
        }
        for (size_t i = 1; i + 1 < count; ++i) {
            const uint32_t a = polygon[0].front, b = polygon[i].front, c = polygon[i + 1].front;
            indices.insert(indices.end(), {a, b, c, a + 1, c + 1, b + 1});
        }
        for (size_t i = 0; i < count; ++i) {
            const Corner a = polygon[i], b = polygon[(i + 1) % count];
            if (a.contour && b.contour) {
                indices.insert(indices.end(), {a.front, a.front + 1, b.front + 1, a.front, b.front + 1, b.front});
            }
        }
    }

    const Grid &grid_;
    float aspect_;
    float scale_;
    float centerX_;
    float centerY_;
    float boundaryOffset_;
    float maximumDistance_;
    float halfDepth_;
    std::vector<uint32_t> gridVertices_;
    std::unordered_map<uint64_t, uint32_t> crossingVertices_;
};

}  // namespace

int32_t PVSingleViewVolumeBuild(const uint8_t *mask, size_t maskCount,
                               int32_t width, int32_t height,
                               const float *relativeDepth, size_t depthCount,
                               float pixelAspect, PVSingleViewMesh *outMesh) {
    if (!outMesh || outMesh->positions || outMesh->triangleIndices || !mask ||
        width <= 0 || height <= 0 || width > maximumDimension || height > maximumDimension ||
        maskCount != static_cast<size_t>(width * height) || !std::isfinite(pixelAspect) ||
        pixelAspect < 0.0625f || pixelAspect > 16.0f ||
        (relativeDepth ? depthCount != maskCount : depthCount != 0)) return 0;

    try {
        Grid grid(width, height);
        const auto component = largestComponent(mask, width, height, grid);
        if (component.size() < minimumForeground) return 0;
        const float maximumDistance = distanceToSilhouette(grid, component, pixelAspect);
        const bool usedDepth = loadProximity(grid, component, relativeDepth, width);
        Builder builder(grid, pixelAspect, maximumDistance);
        builder.build();
        if (builder.indices.empty()) return 0;

        auto positions = std::make_unique<float[]>(builder.positions.size());
        auto indices = std::make_unique<uint32_t[]>(builder.indices.size());
        std::copy(builder.positions.begin(), builder.positions.end(), positions.get());
        std::copy(builder.indices.begin(), builder.indices.end(), indices.get());
        *outMesh = {positions.release(), builder.positions.size() / 3,
                    indices.release(), builder.indices.size(), usedDepth ? 1 : 0};
        return 1;
    } catch (...) {
        return 0;
    }
}

void PVSingleViewVolumeFree(PVSingleViewMesh *mesh) {
    if (!mesh) return;
    delete[] mesh->positions;
    delete[] mesh->triangleIndices;
    *mesh = {};
}
