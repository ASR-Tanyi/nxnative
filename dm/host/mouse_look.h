// Relative Mac pointer input for player one's right stick. AppKit reports deltas to the right and down.
#pragma once
#include <math.h>
#include "dm_input.h"

enum { MOUSE_LEFT, MOUSE_RIGHT, MOUSE_MIDDLE, MOUSE_BUTTONS };   // NSEvent.buttonNumber
typedef struct {
    uint64_t pressed[MOUSE_BUTTONS];  // mapping at press time, one entry per physical button
    double dx, dy, last_dx, last_dy;  // current and previous sampling intervals
    double last_time, last_interval;
    int32_t rx, ry;
} mouse_look;

static inline void mouse_look_click(mouse_look *m, unsigned button, int down, int option, int control,
                                   const uint64_t bindings[MOUSE_BUTTONS]) {
    if (button >= MOUSE_BUTTONS) return;
    unsigned binding = button;
    if (button == MOUSE_LEFT && option) binding = MOUSE_MIDDLE;
    else if (button == MOUSE_LEFT && control) binding = MOUSE_RIGHT;
    m->pressed[button] = down ? bindings[binding] : 0;
}

static inline uint64_t mouse_look_buttons(const mouse_look *m) {
    return m->pressed[MOUSE_LEFT] | m->pressed[MOUSE_RIGHT] | m->pressed[MOUSE_MIDDLE];
}

static inline void mouse_look_merge(const mouse_look *m, uint64_t *buttons, int32_t *rx, int32_t *ry) {
    *buttons |= mouse_look_buttons(m);
    // A Shift-arrow supplies full tilt. Mouse movement can still supply the other axis.
    if (!*rx) *rx = m->rx;
    if (!*ry) *ry = m->ry;
}

// At normal sensitivity 600 points/second is full tilt. Average two 60 Hz intervals so a flick can reach
// a 30 fps game. With no further events both intervals drain and the stick returns to zero.
static inline int mouse_look_sample(mouse_look *m, double now, double sensitivity) {
    double dt = now - m->last_time;
    int32_t x = 0, y = 0;
    if (dt > 0 && dt < 0.2) {
        double scale = sensitivity / (600 * (dt + m->last_interval));
        double vx = (m->dx + m->last_dx) * scale, vy = -(m->dy + m->last_dy) * scale;
        double radius = fmax(1.0, hypot(vx, vy));
        x = (int32_t)lrint(DM_STICK_MAX * vx / radius);
        y = (int32_t)lrint(DM_STICK_MAX * vy / radius);
        m->last_dx = m->dx; m->last_dy = m->dy; m->last_interval = dt;
    } else {
        m->last_dx = m->last_dy = m->last_interval = 0;   // discard motion queued over a pause
    }
    m->dx = m->dy = 0; m->last_time = now;
    int changed = x != m->rx || y != m->ry;
    m->rx = x; m->ry = y;
    return changed;
}
