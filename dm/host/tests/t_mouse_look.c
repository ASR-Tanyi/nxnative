#include <assert.h>
#include <stdio.h>
#include "../mouse_look.h"

static const double tick = 1.0 / 60;

static void clicks(void) {
    mouse_look m = {0};
    uint64_t bindings[MOUSE_BUTTONS] = {DM_BTN_Y, DM_BTN_ZR, DM_BTN_RS};
    mouse_look_click(&m, MOUSE_RIGHT, 1, 0, 0, bindings);
    mouse_look_click(&m, MOUSE_LEFT, 1, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == (DM_BTN_Y | DM_BTN_ZR));
    mouse_look_click(&m, MOUSE_RIGHT, 0, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == DM_BTN_Y);
    mouse_look_click(&m, MOUSE_LEFT, 0, 0, 0, bindings);

    // Option-click and a physical middle click can overlap. Lifting Option first must preserve the physical middle click.
    mouse_look_click(&m, MOUSE_LEFT, 1, 1, 0, bindings);
    mouse_look_click(&m, MOUSE_MIDDLE, 1, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == DM_BTN_RS);
    mouse_look_click(&m, MOUSE_LEFT, 0, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == DM_BTN_RS);
    mouse_look_click(&m, MOUSE_MIDDLE, 0, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == 0);
    mouse_look_click(&m, MOUSE_LEFT, 1, 0, 1, bindings);
    assert(mouse_look_buttons(&m) == DM_BTN_ZR);
    mouse_look_click(&m, MOUSE_LEFT, 0, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == 0);

    bindings[MOUSE_LEFT] = bindings[MOUSE_RIGHT] = DM_BTN_ZL;
    bindings[MOUSE_MIDDLE] = 0;
    mouse_look_click(&m, MOUSE_RIGHT, 1, 0, 0, bindings);
    mouse_look_click(&m, MOUSE_LEFT, 1, 0, 0, bindings);
    mouse_look_click(&m, MOUSE_LEFT, 0, 0, 0, bindings);
    mouse_look_click(&m, MOUSE_MIDDLE, 1, 0, 0, bindings);
    mouse_look_click(&m, 3, 1, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == DM_BTN_ZL);
    mouse_look_click(&m, MOUSE_RIGHT, 0, 0, 0, bindings);
    assert(mouse_look_buttons(&m) == 0);
}

static void keyboard_and_mouse(void) {
    const uint64_t bindings[MOUSE_BUTTONS] = {DM_BTN_Y, DM_BTN_ZR, DM_BTN_RS};
    mouse_look m = {.rx = -2000, .ry = 3000};
    mouse_look_click(&m, MOUSE_LEFT, 1, 0, 0, bindings);
    mouse_look_click(&m, MOUSE_RIGHT, 1, 0, 0, bindings);
    uint64_t keyboard = DM_BTN_Y;
    int32_t rx = DM_STICK_MAX, ry = 0;
    keyboard |= mouse_look_buttons(&m);
    mouse_look_axes(&m, 0, &rx, &ry);
    assert(keyboard == (DM_BTN_Y | DM_BTN_ZR) && rx == DM_STICK_MAX && ry == 3000);

    // While the mouse moves in combined mode both axes come from the pointer, independent of bound keys.
    rx = DM_STICK_MAX; ry = -DM_STICK_MAX;
    mouse_look_axes(&m, 1, &rx, &ry);
    assert(rx == -2000 && ry == 3000);
    m.ry = 0; mouse_look_axes(&m, 1, &rx, &ry);
    assert(rx == -2000 && ry == 0);
    // Capture ends during a drag. The keyboard still holds Y and Shift-Up.
    m = (mouse_look){0};
    keyboard = DM_BTN_Y; rx = 0; ry = DM_STICK_MAX;
    keyboard |= mouse_look_buttons(&m);
    mouse_look_axes(&m, 0, &rx, &ry);
    assert(keyboard == DM_BTN_Y && rx == 0 && ry == DM_STICK_MAX);
}

static void motion(void) {
    mouse_look m = {.last_interval = tick};
    // Five points across two events, then no movement. A short flick survives two samples and recentres.
    m.dx += 2; m.dx += 3; m.dy -= 2;
    assert(mouse_look_sample(&m, tick, 1));
    assert(m.rx == 8192 && m.ry == 3277);
    assert(!mouse_look_sample(&m, 2 * tick, 1));
    assert(mouse_look_sample(&m, 3 * tick, 1));
    assert(m.rx == 0 && m.ry == 0);
    assert(!mouse_look_sample(&m, 4 * tick, 1));

    // The same velocity gives the same tilt across different sampling intervals and event counts.
    mouse_look steady = {0}, uneven = {0};
    for (int i = 1; i <= 6; i++) {
        steady.dx = -4; steady.dy = 2;
        mouse_look_sample(&steady, i * tick, 1);
        double dt = i % 2 ? tick / 2 : tick * 1.5;
        for (int j = 0; j < 4; j++) { uneven.dx -= dt * 60; uneven.dy += dt * 30; }
        mouse_look_sample(&uneven, uneven.last_time + dt, 1);
        assert(uneven.rx == steady.rx && uneven.ry == steady.ry);
    }
    assert(steady.rx < 0 && steady.ry < 0);
    m = (mouse_look){.dx = 5};
    mouse_look_sample(&m, tick, 2);
    assert(m.rx == DM_STICK_MAX && m.ry == 0);
    m.dx = 1000; m.dy = -1000;
    mouse_look_sample(&m, 2 * tick, 1);
    assert(m.rx > 0 && m.ry > 0 && fabs(hypot(m.rx, m.ry) - DM_STICK_MAX) < 1);
    m.dx = 500;
    assert(mouse_look_sample(&m, 1, 1));   // main thread stalled
    assert(m.rx == 0 && m.ry == 0);
    assert(!mouse_look_sample(&m, 1 + tick, 1));
}

int main(void) {
    clicks();
    keyboard_and_mouse();
    motion();
    puts("PASS: mouse bindings, trackpad clicks, camera direction, sensitivity, sampling and idle release");
    return 0;
}
