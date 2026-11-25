#define _POSIX_C_SOURCE 200809L
#include "control_profile_mac.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const struct { uint64_t action; const char *token, *label; } actions[] = {
    {0, "none", "Unassigned"}, {DM_BTN_A, "A", "A button"}, {DM_BTN_B, "B", "B button"},
    {DM_BTN_X, "X", "X button"}, {DM_BTN_Y, "Y", "Y button"},
    {DM_BTN_L, "L", "Left shoulder (L)"}, {DM_BTN_R, "R", "Right shoulder (R)"},
    {DM_BTN_ZL, "ZL", "Left trigger (ZL)"}, {DM_BTN_ZR, "ZR", "Right trigger (ZR)"},
    {DM_BTN_PLUS, "plus", "Plus"}, {DM_BTN_MINUS, "minus", "Minus"},
    {DM_BTN_LS, "LS", "Left stick press"}, {DM_BTN_RS, "RS", "Right stick press"},
    {DM_BTN_UP, "dpad-up", "D-pad up"}, {DM_BTN_DOWN, "dpad-down", "D-pad down"},
    {DM_BTN_LEFT, "dpad-left", "D-pad left"}, {DM_BTN_RIGHT, "dpad-right", "D-pad right"},
    {KEY_MOVE_UP, "left-up", "Left stick up"}, {KEY_MOVE_DOWN, "left-down", "Left stick down"},
    {KEY_MOVE_LEFT, "left-left", "Left stick left"}, {KEY_MOVE_RIGHT, "left-right", "Left stick right"},
    {KEY_LOOK_UP, "right-up", "Right stick up"}, {KEY_LOOK_DOWN, "right-down", "Right stick down"},
    {KEY_LOOK_LEFT, "right-left", "Right stick left"}, {KEY_LOOK_RIGHT, "right-right", "Right stick right"},
    {KEY_WALK, "walk", "Walk slowly"}, {KEY_SPRINT, "sprint", "Sprint while moving"}, {DM_BTN_SHAKE, "shake", "Shake"},
};
#define ACTION_COUNT (sizeof actions / sizeof actions[0])
static int action_index(uint64_t value) {
    for (unsigned i = 0; i < ACTION_COUNT; i++) if (actions[i].action == value) return (int)i;
    return -1;
}
const char *mac_action_label(uint64_t value) {
    int i = action_index(value);
    return i >= 0 ? actions[i].label : "Unknown control";
}

static const char *const presets[] = {"auto", "keyboard-mouse", "classic"};
static bool parse_line(mac_controls *p, char *line) {
    char *state, *kind = strtok_r(line, "\t\r\n", &state);
    if (!kind || *kind == '#') return true;
    char *value = strtok_r(NULL, "\t\r\n", &state), *token = strtok_r(NULL, "\t\r\n", &state);
    if (!value || strtok_r(NULL, "\t\r\n", &state)) return false;
    if (!strcmp(kind, "layout") && !token) {
        for (int i = MAC_KEYS_AUTO; i <= MAC_KEYS_CLASSIC; i++)
            if (!strcmp(value, presets[i])) { p->preset = (mac_key_preset)i; return true; }
        return false;
    }
    char *end; long n = strtol(value, &end, 10);
    if (end == value || *end) return false;
    if (!strcmp(kind, "sensitivity") && !token && (n == 50 || n == 100 || n == 200)) {
        p->sensitivity = (unsigned)n; return true;
    }
    bool mouse = !strcmp(kind, "keyboard-mouse"), click = !strcmp(kind, "click");
    if (!token || (!mouse && !click && strcmp(kind, "classic"))) return false;
    if (n < 0 || n >= (click ? 3 : MAC_CLICK)) return false;
    int slot = (int)n + (click ? MAC_CLICK : 0);
    if (!mac_bindable(slot)) return false;
    for (unsigned i = 0; i < ACTION_COUNT; i++) if (!strcmp(token, actions[i].token)) {
        mac_set_binding(p, mouse, slot, actions[i].action); return true;
    }
    return false;
}
int mac_controls_load(const char *path, mac_controls *out) {
    FILE *f = fopen(path, "r");
    if (!f) return errno;
    mac_controls p; mac_controls_init(&p);
    char line[256];
    int error = !fgets(line, sizeof line, f) || strcmp(line, "nxnative-controls\t1\n") ? EINVAL : 0;
    while (!error && fgets(line, sizeof line, f)) {
        if ((!strchr(line, '\n') && !feof(f)) || !parse_line(&p, line)) error = EINVAL;
    }
    if (ferror(f)) error = EIO;
    fclose(f);
    if (!error) *out = p;
    return error;
}
static int write_profile(FILE *f, const mac_controls *p) {
    if ((unsigned)p->preset > MAC_KEYS_CLASSIC || (p->sensitivity != 50 && p->sensitivity != 100 && p->sensitivity != 200)) return EINVAL;
    if (fprintf(f, "nxnative-controls\t1\nlayout\t%s\nsensitivity\t%u\n", presets[p->preset], p->sensitivity) < 0) return EIO;
    for (int layout = 0; layout < 2; layout++) {
        for (int slot = 0; slot < (layout ? MAC_CLICK : MAC_INPUT_COUNT); slot++) {
            uint64_t value = mac_binding(p, layout, slot);
            if (value == mac_default_binding(layout, slot)) continue;
            int i = action_index(value);
            if (i < 0) return EINVAL;
            bool click = slot >= MAC_CLICK;
            if (fprintf(f, "%s\t%d\t%s\n", click ? "click" : layout ? "keyboard-mouse" : "classic",
                        click ? slot - MAC_CLICK : slot, actions[i].token) < 0) return EIO;
        }
    }
    return 0;
}
int mac_controls_save(const char *path, const mac_controls *p) {
    size_t len = strlen(path) + sizeof ".XXXXXX";
    char *tmp = malloc(len);
    if (!tmp) return ENOMEM;
    snprintf(tmp, len, "%s.XXXXXX", path);
    int fd = mkstemp(tmp), error = fd < 0 ? errno : 0;
    if (!error) {
        FILE *f = fdopen(fd, "w");
        if (!f) { error = errno; close(fd); }
        else {
            error = write_profile(f, p);
            if (fclose(f) && !error) error = errno;
        }
        if (!error && rename(tmp, path)) error = errno;
        if (error) unlink(tmp);
    }
    free(tmp);
    return error;
}
