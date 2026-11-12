#include "InstanceLabelRaster.h"

#include <algorithm>

bool pvxDiscoverInstanceLabels(const uint8_t *pixels, size_t count, uint8_t maximumLabel,
                               uint8_t *present) {
    if (!pixels || count == 0 || !present) return false;
    std::fill_n(present, 256, uint8_t{0});
    for (size_t i = 0; i < count; ++i) {
        present[pixels[i]] = 1;
    }
    return std::none_of(present + maximumLabel + 1, present + 256, [](uint8_t flag) {
        return flag != 0;
    });
}
