// GPU range lookup: bounds, overlapping aliases and gaps; no Metal device needed.
#include "../nvn/nvn_mtl3_range.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    nvn_mtl3_range r[] = {{100, 200, 0}, {120, 140, 0}, {200, 240, 0}, {300, 400, 0}};
    nvn_mtl3_range_index(r, 4);
    assert(nvn_mtl3_range_find(r, 4, 125, 1) == 0);   // longer tail wins over the nested alias
    assert(nvn_mtl3_range_find(r, 4, 125, 75) == 0);
    assert(nvn_mtl3_range_find(r, 4, 199, 1) == 0);
    assert(nvn_mtl3_range_find(r, 4, 199, 2) == SIZE_MAX);   // cannot span adjacent buffers
    assert(nvn_mtl3_range_find(r, 4, 200, 40) == 2);
    assert(nvn_mtl3_range_find(r, 4, 240, 1) == SIZE_MAX);
    assert(nvn_mtl3_range_find(r, 4, 299, 2) == SIZE_MAX);
    assert(nvn_mtl3_range_find(r, 4, 300, 100) == 3);
    assert(nvn_mtl3_range_find(r, 4, 400, 1) == SIZE_MAX);
    assert(nvn_mtl3_range_find(r, 4, 0, 1) == SIZE_MAX);
    assert(nvn_mtl3_range_find(r, 4, 100, 0) == SIZE_MAX);
    assert(nvn_mtl3_range_find(NULL, 0, 100, 1) == SIZE_MAX);
    assert(!nvn_mtl3_range_valid(UINT64_MAX, 1));
    assert(!nvn_mtl3_range_valid(UINT64_MAX - 2, 3));
    nvn_mtl3_range edge[] = {{UINT64_MAX - 4, UINT64_MAX, 0}};
    nvn_mtl3_range_index(edge, 1);
    assert(nvn_mtl3_range_find(edge, 1, UINT64_MAX - 1, 1) == 0);
    assert(nvn_mtl3_range_find(edge, 1, UINT64_MAX - 1, 2) == SIZE_MAX);

    // Exhaustively compare with an independent linear containment oracle. This
    // catches prefix maxima mistakes when earlier aliases contain a later hit.
    nvn_mtl3_range overlaps[] = {{1, 99, 0}, {4, 12, 0}, {4, 110, 0}, {20, 30, 0}, {70, 160, 0}, {150, 155, 0}};
    nvn_mtl3_range_index(overlaps, 6);
    unsigned checks = 0;
    for (uint64_t address = 0; address < 180; address++) for (uint64_t bytes = 0; bytes < 180; bytes++) {
        size_t got = nvn_mtl3_range_find(overlaps, 6, address, bytes);
        uint64_t furthest = 0;
        for (size_t i = 0; i < 6; i++) {
            if (address && bytes && address >= overlaps[i].lo && address < overlaps[i].end &&
                bytes <= overlaps[i].end - address && overlaps[i].end > furthest) furthest = overlaps[i].end;
        }
        if (!furthest) assert(got == SIZE_MAX);
        else { assert(got < 6); assert(overlaps[got].end == furthest); }
        checks++;
    }
    printf("PASS: Metal 3 GPU range boundaries and %u overlapping-range checks\n", checks);
    return 0;
}
