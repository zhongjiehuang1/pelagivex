#include "SingleViewUSDZ.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <fcntl.h>
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
constexpr uint32_t maximumVertices = 200'000;
constexpr uint32_t maximumTriangles = 400'000;
constexpr char layerName[] = "model.usda";
constexpr uint16_t layerNameLength = sizeof(layerName) - 1;
constexpr uint16_t zipVersion = 20;
constexpr uint16_t zipDate = 0x21; // 1980-01-01, the first DOS date.
constexpr uint16_t alignmentExtraFieldID = 0x1986;

using Bytes = std::vector<uint8_t>;

void append16(Bytes &bytes, uint16_t value) {
    bytes.push_back(static_cast<uint8_t>(value));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
}

void append32(Bytes &bytes, uint32_t value) {
    append16(bytes, static_cast<uint16_t>(value));
    append16(bytes, static_cast<uint16_t>(value >> 16));
}

constexpr std::array<uint32_t, 256> makeCRC32Table() {
    std::array<uint32_t, 256> table{};
    for (uint32_t index = 0; index < table.size(); ++index) {
        uint32_t value = index;
        for (int bit = 0; bit < 8; ++bit) {
            value = (value >> 1) ^ ((value & 1) ? 0xedb88320U : 0U);
        }
        table[index] = value;
    }
    return table;
}

uint32_t crc32(const std::string &contents) {
    constexpr auto table = makeCRC32Table();
    uint32_t checksum = 0xffffffffU;
    for (const unsigned char byte : contents) {
        checksum = table[(checksum ^ byte) & 0xffU] ^ (checksum >> 8);
    }
    return checksum ^ 0xffffffffU;
}

struct Bounds {
    std::array<float, 3> minimum;
    std::array<float, 3> maximum;
};

bool validate(const float *positions, uint32_t vertexCount, const uint32_t *indices,
              uint32_t triangleCount, Bounds &bounds) {
    if (!positions || !indices || vertexCount < 4 || vertexCount > maximumVertices ||
        triangleCount < 4 || triangleCount > maximumTriangles) {
        return false;
    }

    bounds.minimum.fill(std::numeric_limits<float>::infinity());
    bounds.maximum.fill(-std::numeric_limits<float>::infinity());
    for (uint32_t vertex = 0; vertex < vertexCount; ++vertex) {
        for (std::size_t axis = 0; axis < 3; ++axis) {
            const float value = positions[3 * vertex + axis];
            if (!std::isfinite(value)) {
                return false;
            }
            bounds.minimum[axis] = std::min(bounds.minimum[axis], value);
            bounds.maximum[axis] = std::max(bounds.maximum[axis], value);
        }
    }
    for (std::size_t axis = 0; axis < 3; ++axis) {
        if (!(bounds.minimum[axis] < bounds.maximum[axis])) {
            return false;
        }
    }
    for (uint32_t triangle = 0; triangle < triangleCount; ++triangle) {
        const uint32_t a = indices[3 * triangle];
        const uint32_t b = indices[3 * triangle + 1];
        const uint32_t c = indices[3 * triangle + 2];
        if (a >= vertexCount || b >= vertexCount || c >= vertexCount || a == b || b == c || c == a) {
            return false;
        }
    }
    return true;
}

void writePoint(std::ostringstream &layer, const float *point) {
    layer << '(' << point[0] << ", " << point[1] << ", " << point[2] << ')';
}

std::string makeLayer(const float *positions, uint32_t vertexCount, const uint32_t *indices,
                      uint32_t triangleCount, const Bounds &bounds) {
    std::ostringstream layer;
    layer.imbue(std::locale::classic());
    layer.exceptions(std::ios::failbit | std::ios::badbit);
    layer << std::setprecision(std::numeric_limits<float>::max_digits10);
    layer << "#usda 1.0\n(\n    defaultPrim = \"Prediction\"\n    metersPerUnit = 1\n    upAxis = \"Y\"\n)\n\n"
             "def Mesh \"Prediction\" {\n    uniform token subdivisionScheme = \"none\"\n"
             "    uniform token orientation = \"rightHanded\"\n    float3[] extent = [";
    writePoint(layer, bounds.minimum.data());
    layer << ", ";
    writePoint(layer, bounds.maximum.data());
    layer << "]\n    point3f[] points = [\n";
    for (uint32_t vertex = 0; vertex < vertexCount; ++vertex) {
        layer << "        ";
        writePoint(layer, positions + 3 * vertex);
        layer << (vertex + 1 == vertexCount ? "\n" : ",\n");
    }
    layer << "    ]\n    int[] faceVertexCounts = [";
    for (uint32_t triangle = 0; triangle < triangleCount; ++triangle) {
        layer << (triangle == 0 ? "3" : ", 3");
    }
    layer << "]\n    int[] faceVertexIndices = [\n";
    for (uint32_t triangle = 0; triangle < triangleCount; ++triangle) {
        const auto *face = indices + 3 * triangle;
        layer << "        " << face[0] << ", " << face[1] << ", " << face[2];
        layer << (triangle + 1 == triangleCount ? "\n" : ",\n");
    }
    layer << "    ]\n    color3f[] primvars:displayColor = [(0.11, 0.44, 0.86)] (\n"
             "        interpolation = \"constant\"\n    )\n}\n";
    return layer.str();
}

Bytes makeLocalHeader(uint32_t byteCount, uint32_t checksum) {
    constexpr uint16_t unpaddedLength = 30 + layerNameLength;
    constexpr uint16_t extraLength = 64 - unpaddedLength % 64;
    static_assert(extraLength >= 4, "USDZ extra field needs a four-byte header");

    Bytes header;
    append32(header, 0x04034b50);
    append16(header, zipVersion);
    append16(header, 0); // Flags and compression are both zero for a stored file.
    append16(header, 0);
    append16(header, 0);
    append16(header, zipDate);
    append32(header, checksum);
    append32(header, byteCount);
    append32(header, byteCount);
    append16(header, layerNameLength);
    append16(header, extraLength);
    header.insert(header.end(), layerName, layerName + layerNameLength);
    append16(header, alignmentExtraFieldID);
    append16(header, extraLength - 4);
    header.resize(unpaddedLength + extraLength, 0);
    return header;
}

Bytes makeDirectory(uint32_t byteCount, uint32_t checksum, uint32_t directoryOffset) {
    Bytes directory;
    append32(directory, 0x02014b50);
    append16(directory, zipVersion); // Version made by.
    append16(directory, zipVersion);
    append16(directory, 0); // Flags.
    append16(directory, 0); // Stored, not compressed.
    append16(directory, 0); // Modification time.
    append16(directory, zipDate);
    append32(directory, checksum);
    append32(directory, byteCount);
    append32(directory, byteCount);
    append16(directory, layerNameLength);
    append16(directory, 0); // Alignment is needed in the local header only.
    append16(directory, 0); // No file comment.
    append16(directory, 0); // First disk.
    append16(directory, 0); // Internal file attributes.
    append32(directory, 0); // External file attributes.
    append32(directory, 0); // The local header starts the archive.
    directory.insert(directory.end(), layerName, layerName + layerNameLength);

    const auto directorySize = static_cast<uint32_t>(directory.size());
    append32(directory, 0x06054b50);
    append16(directory, 0);
    append16(directory, 0);
    append16(directory, 1);
    append16(directory, 1);
    append32(directory, directorySize);
    append32(directory, directoryOffset);
    append16(directory, 0); // No archive comment.
    return directory;
}

bool writeAll(int file, const void *data, std::size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    while (size > 0) {
        const ssize_t written = write(file, bytes, size);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return false;
        }
        bytes += written;
        size -= static_cast<std::size_t>(written);
    }
    return true;
}
} // namespace

int32_t PVWriteSingleViewUSDZ(const char *path, const float *positions, uint32_t vertexCount,
                             const uint32_t *indices, uint32_t triangleCount) {
    if (!path || path[0] == '\0') {
        return 1;
    }
    Bounds bounds{};
    if (!validate(positions, vertexCount, indices, triangleCount, bounds)) {
        return 1;
    }

    try {
        const auto layer = makeLayer(positions, vertexCount, indices, triangleCount, bounds);
        if (layer.size() > std::numeric_limits<uint32_t>::max() - 64) {
            return 3;
        }
        const auto byteCount = static_cast<uint32_t>(layer.size());
        const auto checksum = crc32(layer);
        const auto header = makeLocalHeader(byteCount, checksum);
        const auto directory = makeDirectory(byteCount, checksum, byteCount + static_cast<uint32_t>(header.size()));
        const int file = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (file < 0) {
            return errno == EEXIST ? 2 : 3;
        }
        const bool complete = writeAll(file, header.data(), header.size()) && writeAll(file, layer.data(), layer.size()) &&
                              writeAll(file, directory.data(), directory.size());
        const int closeResult = close(file);
        if (!complete || closeResult != 0) {
            unlink(path);
            return 3;
        }
        return 0;
    } catch (...) {
        return 3;
    }
}
