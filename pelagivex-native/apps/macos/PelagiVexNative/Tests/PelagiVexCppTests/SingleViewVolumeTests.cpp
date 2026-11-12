#include "SingleViewVolume.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <vector>

namespace {

struct Inspection {
    float width;
    float height;
    float depth;
    double volume;
    int eulerCharacteristic;
};

Inspection inspectClosedMesh(const PVSingleViewMesh &mesh) {
    assert(mesh.vertexCount > 0 && mesh.indexCount > 0 && mesh.indexCount % 3 == 0);
    std::array<float, 3> low{}, high{};
    for (size_t i = 0; i < mesh.vertexCount; ++i) {
        for (size_t axis = 0; axis < 3; ++axis) {
            const float coordinate = mesh.positions[3 * i + axis];
            assert(std::isfinite(coordinate));
            low[axis] = std::min(low[axis], coordinate);
            high[axis] = std::max(high[axis], coordinate);
        }
    }
    struct Edge { int uses = 0; int orientation = 0; };
    std::map<std::pair<uint32_t, uint32_t>, Edge> edges;
    double volume = 0;
    for (size_t i = 0; i < mesh.indexCount; i += 3) {
        const uint32_t *indices = mesh.triangleIndices + i;
        for (size_t side = 0; side < 3; ++side) {
            const uint32_t a = indices[side], b = indices[(side + 1) % 3];
            assert(a < mesh.vertexCount && b < mesh.vertexCount && a != b);
            auto &edge = edges[std::minmax(a, b)];
            ++edge.uses;
            edge.orientation += a < b ? 1 : -1;
        }
        const auto a = mesh.positions + 3 * indices[0];
        const auto b = mesh.positions + 3 * indices[1];
        const auto c = mesh.positions + 3 * indices[2];
        const std::array<float, 3> u{b[0] - a[0], b[1] - a[1], b[2] - a[2]};
        const std::array<float, 3> v{c[0] - a[0], c[1] - a[1], c[2] - a[2]};
        const std::array<float, 3> normal{u[1] * v[2] - u[2] * v[1],
                                          u[2] * v[0] - u[0] * v[2],
                                          u[0] * v[1] - u[1] * v[0]};
        assert(normal[0] != 0 || normal[1] != 0 || normal[2] != 0);
        volume += (a[0] * (b[1] * c[2] - b[2] * c[1]) +
                   a[1] * (b[2] * c[0] - b[0] * c[2]) +
                   a[2] * (b[0] * c[1] - b[1] * c[0])) / 6.0;
    }
    for (const auto &[key, edge] : edges) {
        (void)key;
        assert(edge.uses == 2 && edge.orientation == 0);
    }
    assert(volume > 0);
    return {high[0] - low[0], high[1] - low[1], high[2] - low[2], volume,
            static_cast<int>(mesh.vertexCount) - static_cast<int>(edges.size()) + static_cast<int>(mesh.indexCount / 3)};
}

}  // namespace

int main() {
    constexpr int size = 26;
    std::vector<uint8_t> mask(size * size);
    PVSingleViewMesh mesh{};
    assert(!PVSingleViewVolumeBuild(mask.data(), mask.size(), size, size, nullptr, 0, 1, &mesh));
    assert(!PVSingleViewVolumeBuild(mask.data(), mask.size() - 1, size, size, nullptr, 0, 1, &mesh));

    // A solid silhouette reaching the input border has a closed, rounded body.
    for (int y = 0; y < 18; ++y) for (int x = 0; x < 12; ++x) mask[y * size + x] = 255;
    mask.back() = 255; // Disconnected segmentation noise must not stretch the object.
    assert(PVSingleViewVolumeBuild(mask.data(), mask.size(), size, size, nullptr, 0, 1, &mesh));
    assert(!mesh.usedDepth);
    const auto box = inspectClosedMesh(mesh);
    assert(std::abs(box.width - 12.0f / 18) < 1e-5 && std::abs(box.height - 1) < 1e-5);
    assert(box.depth > 0.45f && box.volume > 0.15 && box.eulerCharacteristic == 2);
    const std::vector<float> silhouettePositions(mesh.positions, mesh.positions + 3 * mesh.vertexCount);
    assert(!PVSingleViewVolumeBuild(mask.data(), mask.size(), size, size, nullptr, 0, 1, &mesh));
    PVSingleViewVolumeFree(&mesh);
    assert(!mesh.positions && !mesh.triangleIndices && mesh.vertexCount == 0 && mesh.indexCount == 0);

    // A varying proximity field modifies the observed face and preserves the rear prediction.
    std::vector<float> depth(mask.size(), std::numeric_limits<float>::quiet_NaN());
    for (int y = 0; y < 18; ++y) for (int x = 0; x < 12; ++x) depth[y * size + x] = static_cast<float>(x);
    assert(PVSingleViewVolumeBuild(mask.data(), mask.size(), size, size, depth.data(), depth.size(), 1, &mesh));
    assert(mesh.usedDepth && silhouettePositions.size() == 3 * mesh.vertexCount);
    bool faceChanged = false;
    for (size_t i = 0; i < mesh.vertexCount; i += 2) {
        faceChanged |= std::abs(mesh.positions[i * 3 + 2] - silhouettePositions[i * 3 + 2]) > 0.01f;
        assert(mesh.positions[i * 3 + 5] == silhouettePositions[i * 3 + 5]);
    }
    assert(faceChanged);
    inspectClosedMesh(mesh);
    PVSingleViewVolumeFree(&mesh);

    // A hollow silhouette keeps its opening, including the inside side wall.
    std::fill(mask.begin(), mask.end(), 0);
    for (int y = 2; y < 24; ++y) for (int x = 2; x < 24; ++x) {
        if (x < 8 || x >= 18 || y < 8 || y >= 18) mask[y * size + x] = 1;
    }
    std::fill(depth.begin(), depth.end(), 7);
    assert(PVSingleViewVolumeBuild(mask.data(), mask.size(), size, size, depth.data(), depth.size(), 0.8f, &mesh));
    assert(!mesh.usedDepth);
    const auto ring = inspectClosedMesh(mesh);
    assert(ring.eulerCharacteristic == 0 && ring.depth > 0.5f);
    PVSingleViewVolumeFree(&mesh);

    // A one-sample-wide connected feature still has a well-formed solid cross section.
    std::fill(mask.begin(), mask.end(), 0);
    std::fill_n(mask.begin(), size, 1);
    assert(PVSingleViewVolumeBuild(mask.data(), mask.size(), size, size, nullptr, 0, 1, &mesh));
    const auto line = inspectClosedMesh(mesh);
    assert(line.depth >= 0.14f && line.eulerCharacteristic == 2);
    PVSingleViewVolumeFree(&mesh);
    std::puts("PASS closed volume, normalized dimensions, depth relief, holes, thin silhouettes, invalid inputs");
}
