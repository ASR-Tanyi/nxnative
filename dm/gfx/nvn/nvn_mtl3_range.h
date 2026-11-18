// GPU-address lookup for the Metal 3 buffer map. No Apple types: tested on the CPU.
#ifndef NVN_MTL3_RANGE_H
#define NVN_MTL3_RANGE_H
#include <stddef.h>
#include <stdint.h>

typedef struct { uint64_t lo, end, prefix_end; } nvn_mtl3_range;

static inline int nvn_mtl3_range_valid(uint64_t address, uint64_t length) {
    return address && length && length <= UINT64_MAX - address;
}

// Sorted by lo. Recompute after insertion/removal; aliases may overlap.
static inline void nvn_mtl3_range_index(nvn_mtl3_range *ranges, size_t count) {
    uint64_t end = 0;
    for (size_t i = 0; i < count; i++) {
        if (ranges[i].end > end) end = ranges[i].end;
        ranges[i].prefix_end = end;
    }
}

// A binding must fit entirely in one buffer. Prefer the longest available tail,
// including an earlier overlapping allocation; never join two adjacent buffers.
// SIZE_MAX means missing, invalid or empty. End addresses are exclusive.
static inline size_t nvn_mtl3_range_find(const nvn_mtl3_range *ranges, size_t count,
                                        uint64_t address, uint64_t length) {
    if (!nvn_mtl3_range_valid(address, length)) return SIZE_MAX;
    uint64_t end = address + length, best_end = 0;
    size_t low = 0, high = count, best = SIZE_MAX;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if (ranges[mid].lo <= address) low = mid + 1; else high = mid;
    }
    while (low) {
        const nvn_mtl3_range *r = &ranges[--low];
        if (r->prefix_end < end || (best != SIZE_MAX && r->prefix_end <= best_end)) break;
        if (r->end >= end && r->end > best_end) { best = low; best_end = r->end; }
    }
    return best;
}
#endif
