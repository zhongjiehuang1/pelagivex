#include "TrackerAssignment.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

int32_t PVTrackerAssign(const double *costs, size_t rows, size_t columns, size_t *assignments) {
    const auto maximum = std::numeric_limits<size_t>::max();
    if (!costs || !assignments || rows == 0 || columns < rows || columns == maximum || rows > maximum / columns) {
        return 0;
    }
    try {
        std::vector<double> rowPotential(rows + 1);
        std::vector<double> columnPotential(columns + 1);
        std::vector<size_t> owner(columns + 1);
        std::vector<size_t> previousColumn(columns + 1);
        std::vector<double> minimum(columns + 1);
        std::vector<uint8_t> used(columns + 1);
        const double infinity = std::numeric_limits<double>::infinity();

        for (size_t row = 1; row <= rows; ++row) {
            owner[0] = row;
            size_t column = 0;
            std::fill(minimum.begin(), minimum.end(), infinity);
            std::fill(used.begin(), used.end(), 0);
            do {
                used[column] = 1;
                const size_t currentRow = owner[column];
                double delta = infinity;
                size_t nextColumn = 0;
                for (size_t j = 1; j <= columns; ++j) {
                    if (used[j]) continue;
                    const double cost = costs[(currentRow - 1) * columns + j - 1]
                        - rowPotential[currentRow] - columnPotential[j];
                    if (cost < minimum[j]) {
                        minimum[j] = cost;
                        previousColumn[j] = column;
                    }
                    // Iterate in column order and keep the first equal minimum.
                    if (minimum[j] < delta) {
                        delta = minimum[j];
                        nextColumn = j;
                    }
                }
                if (!std::isfinite(delta)) return 0;
                for (size_t j = 0; j <= columns; ++j) {
                    if (used[j]) {
                        rowPotential[owner[j]] += delta;
                        columnPotential[j] -= delta;
                    } else {
                        minimum[j] -= delta;
                    }
                }
                column = nextColumn;
            } while (owner[column] != 0);
            do {
                const size_t previous = previousColumn[column];
                owner[column] = owner[previous];
                column = previous;
            } while (column != 0);
        }

        std::fill_n(assignments, rows, columns);
        for (size_t column = 1; column <= columns; ++column) {
            if (owner[column] != 0) assignments[owner[column] - 1] = column - 1;
        }
        return 1;
    } catch (...) {
        return 0;
    }
}
