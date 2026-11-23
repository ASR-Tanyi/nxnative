#include <assert.h>
#include <stdio.h>
#include "../keyboard_mac.h"
#include "../mouse_look.h"

enum { A = 0, D = 2, F = 3, Z = 6, X = 7, C = 8, Q = 12, W = 13, E = 14, R = 15,
       ONE = 18, TWO = 19, THREE = 20, FOUR = 21, U = 32, RETURN = 36, J = 38, M = 46,
       TAB = 48, SPACE = 49, COMMAND = 55, SHIFT = 56, RIGHT_SHIFT = 60, RIGHT = 124, UP = 126 };

static void layouts(void) {
    mac_keyboard k = {0};
    const struct { unsigned code; uint64_t classic, mouse; } map[] = {
        {SPACE, DM_BTN_SHAKE, DM_BTN_X}, {E, DM_BTN_R, DM_BTN_A}, {Q, DM_BTN_L, DM_BTN_ZL},
        {C, DM_BTN_ZR, DM_BTN_LS}, {F, DM_BTN_LS, DM_BTN_L}, {R, 0, DM_BTN_R},
        {RETURN, DM_BTN_PLUS, DM_BTN_A}, {TAB, DM_BTN_MINUS, DM_BTN_PLUS}, {M, 0, DM_BTN_MINUS},
        {X, 0, DM_BTN_B}, {ONE, 0, DM_BTN_RIGHT}, {TWO, 0, DM_BTN_LEFT},
        {THREE, 0, DM_BTN_UP}, {FOUR, 0, DM_BTN_DOWN},
    };
    for (int captured = 0; captured <= 1; captured++) {
        mac_keys_layout(&k, MAC_KEYS_AUTO, captured);
        for (unsigned i = 0; i < sizeof map / sizeof map[0]; i++) {
            mac_keys_event(&k, map[i].code, true, false);
            assert(mac_keys_read(&k).buttons == (captured ? map[i].mouse : map[i].classic));
            mac_keys_event(&k, map[i].code, false, true);
            assert(!mac_keys_read(&k).buttons);
        }
    }
    mac_keys_event(&k, W, true, false);
    mac_keys_event(&k, SPACE, true, false);
    mac_keys_layout(&k, MAC_KEYS_AUTO, false);
    assert(!k.mouse_layout && mac_keys_read(&k).ly == DM_STICK_MAX && !mac_keys_read(&k).buttons);
    assert(!mac_keys_event(&k, SPACE, false, false));   // the release cannot turn jump into shake
    mac_keys_layout(&k, MAC_KEYS_MOUSE, false); assert(k.mouse_layout);
    mac_keys_layout(&k, MAC_KEYS_CLASSIC, true); assert(!k.mouse_layout);
    mac_keys_event(&k, A, true, false);
    assert(mac_keys_read(&k).lx == -DM_STICK_MAX && mac_keys_read(&k).ly == DM_STICK_MAX);
    assert(!mac_keys_event(&k, 128, true, false));
}

static void movement(void) {
    mac_keyboard k = {0};
    mac_keys_layout(&k, MAC_KEYS_MOUSE, true);
    mac_keys_modifiers(&k, SHIFT, true, false);
    assert(!mac_keys_read(&k).buttons);   // Shift at rest does not cancel a menu
    mac_keys_event(&k, W, true, true);
    assert(mac_keys_read(&k).buttons == DM_BTN_B && mac_keys_read(&k).ly == DM_STICK_MAX);
    mac_keys_event(&k, D, true, true);
    mac_keys_event(&k, SPACE, true, true);
    mac_key_report r = mac_keys_read(&k);
    assert(r.lx == 23170 && r.ly == 23170 && r.buttons == (DM_BTN_B | DM_BTN_X));
    mac_keys_event(&k, A, true, true);   // opposing horizontal directions cancel, W stays full
    assert(mac_keys_read(&k).lx == 0 && mac_keys_read(&k).ly == DM_STICK_MAX);
    mac_keys_event(&k, A, false, true);
    mac_keys_modifiers(&k, RIGHT_SHIFT, true, false);
    mac_keys_modifiers(&k, SHIFT, true, false);   // left Shift lifted with right Shift still down
    assert(mac_keys_read(&k).buttons & DM_BTN_B);
    mac_keys_modifiers(&k, RIGHT_SHIFT, false, false);
    mac_keys_event(&k, Z, true, false);
    assert(mac_keys_read(&k).lx == 11585 && mac_keys_read(&k).buttons == DM_BTN_X);
    mac_keys_event(&k, D, false, false);
    assert(mac_keys_read(&k).ly == DM_STICK_MAX / 2);
    mac_keys_modifiers(&k, SHIFT, true, false);   // sprint takes precedence over slow walking
    assert(mac_keys_read(&k).ly == DM_STICK_MAX && (mac_keys_read(&k).buttons & DM_BTN_B));
    mac_keys_modifiers(&k, COMMAND, true, true);
    mac_keys_modifiers(&k, COMMAND, true, false);   // releasing the mouse-look shortcut does not start sprinting
    assert(!(mac_keys_read(&k).buttons & DM_BTN_B));
    mac_keys_clear(&k);   // focus loss, minimization, text input or controller prompt
    r = mac_keys_read(&k);
    assert(k.mouse_layout && !r.buttons && !r.lx && !r.ly && !r.rx && !r.ry);
}

static void combined_input(void) {
    mac_keyboard k = {0};
    mac_keys_layout(&k, MAC_KEYS_AUTO, true);
    mac_keys_event(&k, E, true, false);
    mac_keys_event(&k, J, true, false);
    mac_keys_event(&k, E, false, false);
    assert(mac_keys_read(&k).buttons == DM_BTN_A);   // releasing one confirm key leaves the other held
    mac_keys_event(&k, UP, true, true);
    assert(!mac_keys_event(&k, UP, true, false));   // a repeat after lifting Shift keeps its original binding
    assert(mac_keys_read(&k).ry == DM_STICK_MAX);
    mac_keys_event(&k, UP, false, false);
    mac_keys_event(&k, RIGHT, true, false);
    mac_keys_event(&k, ONE, true, false);
    mac_keys_event(&k, RIGHT, false, true);
    assert(mac_keys_read(&k).buttons == (DM_BTN_A | DM_BTN_RIGHT));

    const uint64_t bindings[MOUSE_BUTTONS] = {DM_BTN_Y, DM_BTN_ZR, DM_BTN_A};
    mouse_look mouse = {.rx = -3700, .ry = 1800};
    mouse_look_click(&mouse, MOUSE_RIGHT, true, false, false, bindings);
    mouse_look_click(&mouse, MOUSE_MIDDLE, true, false, false, bindings);
    mac_keys_event(&k, J, false, false);
    mac_keys_event(&k, W, true, false);
    mac_keys_event(&k, SPACE, true, false);
    mac_key_report r = mac_keys_read(&k);
    mouse_look_merge(&mouse, &r.buttons, &r.rx, &r.ry);
    assert(r.buttons == (DM_BTN_A | DM_BTN_RIGHT | DM_BTN_X | DM_BTN_ZR));
    assert(r.ly == DM_STICK_MAX && r.rx == -3700 && r.ry == 1800);
}

int main(void) {
    layouts(); movement(); combined_input();
    puts("PASS: Mac keyboard presets, sprint, walking speed, focus reset and simultaneous keyboard/mouse input");
    return 0;
}
