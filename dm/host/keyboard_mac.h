// Mac virtual key codes (HIToolbox Events.h). Keep the binding of each physical key until release:
// two keys may hold the same Switch button, and Shift can change while an arrow is held.
#pragma once
#include <stdbool.h>
#include "dm_input.h"

typedef enum { MAC_KEYS_AUTO, MAC_KEYS_MOUSE, MAC_KEYS_CLASSIC } mac_key_preset;
enum {
    KEY_MOVE_LEFT = 1u << 16, KEY_MOVE_UP = 1u << 17, KEY_MOVE_RIGHT = 1u << 18, KEY_MOVE_DOWN = 1u << 19,
    KEY_LOOK_LEFT = 1u << 20, KEY_LOOK_UP = 1u << 21, KEY_LOOK_RIGHT = 1u << 22, KEY_LOOK_DOWN = 1u << 23,
    KEY_WALK = 1u << 24,
    MAC_KEY_COUNT = 128
};

// Columns are Classic, Keyboard + Mouse, and the Shift binding shared by both layouts (arrow keys).
static const struct { uint64_t classic, mouse, shifted; } mac_keymap[MAC_KEY_COUNT] = {
    [0x00] = {KEY_MOVE_LEFT, KEY_MOVE_LEFT, 0},   // A
    [0x01] = {KEY_MOVE_DOWN, KEY_MOVE_DOWN, 0},   // S
    [0x02] = {KEY_MOVE_RIGHT, KEY_MOVE_RIGHT, 0}, // D
    [0x03] = {DM_BTN_LS, DM_BTN_L, 0},            // F
    [0x05] = {DM_BTN_RS, DM_BTN_RS, 0},           // G
    [0x06] = {DM_BTN_ZL, KEY_WALK, 0},            // Z
    [0x07] = {0, DM_BTN_B, 0},                    // X
    [0x08] = {DM_BTN_ZR, DM_BTN_LS, 0},           // C
    [0x0b] = {0, DM_BTN_ZR, 0},                   // B
    [0x0c] = {DM_BTN_L, DM_BTN_ZL, 0},            // Q
    [0x0d] = {KEY_MOVE_UP, KEY_MOVE_UP, 0},       // W
    [0x0e] = {DM_BTN_R, DM_BTN_A, 0},             // E
    [0x0f] = {0, DM_BTN_R, 0},                    // R
    [0x11] = {0, DM_BTN_SHAKE, 0},                // T
    [0x12] = {0, DM_BTN_RIGHT, 0},                // 1
    [0x13] = {0, DM_BTN_LEFT, 0},                 // 2
    [0x14] = {0, DM_BTN_UP, 0},                   // 3
    [0x15] = {0, DM_BTN_DOWN, 0},                 // 4
    [0x20] = {DM_BTN_X, DM_BTN_X, 0},             // U
    [0x22] = {DM_BTN_Y, DM_BTN_Y, 0},             // I
    [0x24] = {DM_BTN_PLUS, DM_BTN_A, 0},          // Return
    [0x26] = {DM_BTN_A, DM_BTN_A, 0},             // J
    [0x28] = {DM_BTN_B, DM_BTN_B, 0},             // K
    [0x2e] = {0, DM_BTN_MINUS, 0},                // M
    [0x30] = {DM_BTN_MINUS, DM_BTN_PLUS, 0},      // Tab
    [0x31] = {DM_BTN_SHAKE, DM_BTN_X, 0},         // Space
    [0x7b] = {DM_BTN_LEFT, DM_BTN_LEFT, KEY_LOOK_LEFT},
    [0x7c] = {DM_BTN_RIGHT, DM_BTN_RIGHT, KEY_LOOK_RIGHT},
    [0x7d] = {DM_BTN_DOWN, DM_BTN_DOWN, KEY_LOOK_DOWN},
    [0x7e] = {DM_BTN_UP, DM_BTN_UP, KEY_LOOK_UP},
};

typedef struct {
    uint64_t held[MAC_KEY_COUNT];
    bool mouse_layout, sprint;
} mac_keyboard;

typedef struct {
    uint64_t buttons;
    int32_t lx, ly, rx, ry;
} mac_key_report;

static inline uint64_t mac_key_binding(unsigned code, bool mouse_layout, bool shift) {
    if (code >= MAC_KEY_COUNT) return 0;
    if (shift && mac_keymap[code].shifted) return mac_keymap[code].shifted;
    return mouse_layout ? mac_keymap[code].mouse : mac_keymap[code].classic;
}

static inline void mac_keys_layout(mac_keyboard *k, mac_key_preset preset, bool captured) {
    bool mouse = preset == MAC_KEYS_MOUSE || (preset == MAC_KEYS_AUTO && captured);
    if (mouse == k->mouse_layout) return;
    // WASD and other unchanged holds continue. A key that changes meaning requires a fresh press.
    for (unsigned i = 0; i < MAC_KEY_COUNT; i++)
        if (mac_keymap[i].classic != mac_keymap[i].mouse) k->held[i] = 0;
    k->mouse_layout = mouse;
    k->sprint = false;
}

static inline void mac_keys_clear(mac_keyboard *k) {
    *k = (mac_keyboard){.mouse_layout = k->mouse_layout};
}

static inline bool mac_keys_event(mac_keyboard *k, unsigned code, bool down, bool shift) {
    if (code >= MAC_KEY_COUNT) return false;
    uint64_t action = down ? mac_key_binding(code, k->mouse_layout, shift) : 0;
    if (k->held[code] == action || (down && k->held[code])) return false;
    k->held[code] = action;
    return true;
}

// AppKit flagsChanged reports whether either Shift is down. Command chords release sprint, and the
// Command key-up after the mouse-look shortcut cannot turn it back on.
static inline bool mac_keys_modifiers(mac_keyboard *k, unsigned code, bool shift, bool command) {
    if (!k->mouse_layout || (!command && code != 0x38 && code != 0x3c)) return false;
    bool sprint = shift && !command;
    if (sprint == k->sprint) return false;
    k->sprint = sprint;
    return true;
}

static inline mac_key_report mac_keys_read(const mac_keyboard *k) {
    uint64_t held = 0;
    for (unsigned i = 0; i < MAC_KEY_COUNT; i++) held |= k->held[i];
    int x = !!(held & KEY_MOVE_RIGHT) - !!(held & KEY_MOVE_LEFT);
    int y = !!(held & KEY_MOVE_UP) - !!(held & KEY_MOVE_DOWN);
    int tilt = k->mouse_layout && x && y ? 23170 : DM_STICK_MAX;   // round(32767 / sqrt(2))
    if ((held & KEY_WALK) && !k->sprint) tilt /= 2;
    mac_key_report r = {
        .buttons = held & (DM_BTN_SHAKE | 0xffffu),
        .lx = x * tilt, .ly = y * tilt,
        .rx = (!!(held & KEY_LOOK_RIGHT) - !!(held & KEY_LOOK_LEFT)) * DM_STICK_MAX,
        .ry = (!!(held & KEY_LOOK_UP) - !!(held & KEY_LOOK_DOWN)) * DM_STICK_MAX,
    };
    if (k->sprint && (x || y)) r.buttons |= DM_BTN_B;
    return r;
}
