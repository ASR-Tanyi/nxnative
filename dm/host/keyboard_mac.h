// Mac virtual key codes (HIToolbox Events.h). Keep the binding of each physical key until release:
// two keys may hold the same Switch button, and Shift can change while an arrow is held.
#pragma once
#include <stdbool.h>
#include "dm_input.h"

typedef enum { MAC_KEYS_AUTO, MAC_KEYS_MOUSE, MAC_KEYS_CLASSIC } mac_key_preset;
enum {
    KEY_MOVE_LEFT = 1u << 16, KEY_MOVE_UP = 1u << 17, KEY_MOVE_RIGHT = 1u << 18, KEY_MOVE_DOWN = 1u << 19,
    KEY_LOOK_LEFT = 1u << 20, KEY_LOOK_UP = 1u << 21, KEY_LOOK_RIGHT = 1u << 22, KEY_LOOK_DOWN = 1u << 23,
    KEY_WALK = 1u << 24, KEY_SPRINT = 1u << 25,
    MAC_KEY_COUNT = 128, MAC_SHIFTED = MAC_KEY_COUNT, MAC_CLICK = 2 * MAC_KEY_COUNT, MAC_INPUT_COUNT = MAC_CLICK + 3
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

// Input slots are physical Mac keys, Shift + key, then left/right/middle click.
typedef struct {
    uint64_t keys[2][MAC_CLICK], clicks[3];
    mac_key_preset preset;
    unsigned sensitivity;
} mac_controls;

enum { MAC_SHIFT = 56, MAC_OPTION = 58, MAC_CONTROL = 59, MAC_ESCAPE = 53 };
static inline unsigned mac_key_code(unsigned code) {
    switch (code) {
    case 60: return MAC_SHIFT;
    case 61: return MAC_OPTION;
    case 62: return MAC_CONTROL;
    default: return code;
    }
}
static inline bool mac_modifier(unsigned code) {
    return code == MAC_SHIFT || code == MAC_OPTION || code == MAC_CONTROL;
}
static inline bool mac_bindable(int slot) {
    if (slot < 0 || slot >= MAC_INPUT_COUNT) return false;
    if (slot >= MAC_CLICK) return true;
    unsigned code = (unsigned)slot % MAC_KEY_COUNT;
    return code == mac_key_code(code) && code != MAC_ESCAPE && code != 54 && code != 55 &&
           code != 57 && code != 63 && (slot < MAC_SHIFTED || !mac_modifier(code));
}
static inline uint64_t mac_default_binding(bool mouse, int slot) {
    static const uint64_t clicks[] = {DM_BTN_Y, DM_BTN_ZR, DM_BTN_RS};
    if (!mac_bindable(slot)) return 0;
    if (slot >= MAC_CLICK) return clicks[slot - MAC_CLICK];
    if (slot >= MAC_SHIFTED) return mac_keymap[slot - MAC_SHIFTED].shifted;
    if (mouse && slot == MAC_SHIFT) return KEY_SPRINT;
    return mouse ? mac_keymap[slot].mouse : mac_keymap[slot].classic;
}
static inline uint64_t mac_binding(const mac_controls *p, bool mouse, int slot) {
    if (!mac_bindable(slot)) return 0;
    if (!p) return mac_default_binding(mouse, slot);
    return slot >= MAC_CLICK ? p->clicks[slot - MAC_CLICK] : p->keys[mouse][slot];
}
static inline void mac_set_binding(mac_controls *p, bool mouse, int slot, uint64_t action) {
    if (!mac_bindable(slot)) return;
    if (slot >= MAC_CLICK) p->clicks[slot - MAC_CLICK] = action;
    else p->keys[mouse][slot] = action;
}
static inline void mac_reset_bindings(mac_controls *p) {
    for (int mouse = 0; mouse < 2; mouse++)
        for (int slot = 0; slot < MAC_INPUT_COUNT; slot++)
            mac_set_binding(p, mouse, slot, mac_default_binding(mouse, slot));
}
static inline void mac_controls_init(mac_controls *p) {
    *p = (mac_controls){.preset = MAC_KEYS_AUTO, .sensitivity = 100};
    mac_reset_bindings(p);
}
static inline void mac_reset_action(mac_controls *p, bool mouse, uint64_t action) {
    for (int i = 0; i < MAC_INPUT_COUNT; i++) {
        uint64_t original = mac_default_binding(mouse, i);
        if (original == action || mac_binding(p, mouse, i) == action) mac_set_binding(p, mouse, i, original);
    }
}
static inline void mac_rebind(mac_controls *p, bool mouse, uint64_t action, int old, int slot) {
    if (slot != -1 && !mac_bindable(slot)) return;
    if (old >= 0 && mac_binding(p, mouse, old) == action) mac_set_binding(p, mouse, old, 0);
    mac_set_binding(p, mouse, slot, action);
}

typedef struct {
    const mac_controls *profile;
    uint64_t held[MAC_KEY_COUNT];
    bool mouse_layout;
} mac_keyboard;
typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; } mac_key_report;

static inline uint64_t mac_key_binding(const mac_controls *p, unsigned code, bool mouse, bool shift) {
    code = mac_key_code(code);
    if (code >= MAC_KEY_COUNT) return 0;
    uint64_t shifted = shift ? mac_binding(p, mouse, (int)code + MAC_SHIFTED) : 0;
    return shifted ? shifted : mac_binding(p, mouse, (int)code);
}
static inline void mac_keys_layout(mac_keyboard *k, mac_key_preset preset, bool captured) {
    bool mouse = preset == MAC_KEYS_MOUSE || (preset == MAC_KEYS_AUTO && captured);
    if (mouse == k->mouse_layout) return;
    for (int i = 0; i < MAC_KEY_COUNT; i++)
        if (mac_binding(k->profile, false, i) != mac_binding(k->profile, true, i) ||
            mac_binding(k->profile, false, MAC_SHIFTED + i) != mac_binding(k->profile, true, MAC_SHIFTED + i)) k->held[i] = 0;
    k->mouse_layout = mouse;
}
static inline void mac_keys_clear(mac_keyboard *k) {
    *k = (mac_keyboard){.profile = k->profile, .mouse_layout = k->mouse_layout};
}
static inline bool mac_keys_event(mac_keyboard *k, unsigned code, bool down, bool shift) {
    code = mac_key_code(code);
    if (code >= MAC_KEY_COUNT) return false;
    uint64_t action = down ? mac_key_binding(k->profile, code, k->mouse_layout, shift) : 0;
    if (k->held[code] == action || (down && k->held[code])) return false;
    k->held[code] = action;
    return true;
}
// AppKit reports the aggregate state of both sides of a modifier.
static inline bool mac_keys_modifiers(mac_keyboard *k, unsigned code, bool down, bool command) {
    if (command) {
        bool changed = k->held[MAC_SHIFT] || k->held[MAC_OPTION] || k->held[MAC_CONTROL];
        k->held[MAC_SHIFT] = k->held[MAC_OPTION] = k->held[MAC_CONTROL] = 0;
        return changed;
    }
    code = mac_key_code(code);
    return mac_modifier(code) && mac_keys_event(k, code, down, false);
}
static inline mac_key_report mac_keys_read(const mac_keyboard *k, uint64_t other) {
    uint64_t held = other;
    for (unsigned i = 0; i < MAC_KEY_COUNT; i++) held |= k->held[i];
    int x = !!(held & KEY_MOVE_RIGHT) - !!(held & KEY_MOVE_LEFT);
    int y = !!(held & KEY_MOVE_UP) - !!(held & KEY_MOVE_DOWN);
    int tilt = k->mouse_layout && x && y ? 23170 : DM_STICK_MAX;
    if ((held & KEY_WALK) && !(held & KEY_SPRINT)) tilt /= 2;
    mac_key_report r = {
        .buttons = held & (DM_BTN_SHAKE | 0xffffu),
        .lx = x * tilt, .ly = y * tilt,
        .rx = (!!(held & KEY_LOOK_RIGHT) - !!(held & KEY_LOOK_LEFT)) * DM_STICK_MAX,
        .ry = (!!(held & KEY_LOOK_UP) - !!(held & KEY_LOOK_DOWN)) * DM_STICK_MAX,
    };
    if ((held & KEY_SPRINT) && (x || y)) r.buttons |= DM_BTN_B;
    return r;
}
