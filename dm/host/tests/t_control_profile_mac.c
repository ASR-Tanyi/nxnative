#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../control_profile_mac.h"

static void mapping(mac_controls *p) {
    const int w = 13, e = 14, f = 3, j = 38, up = 126;
    mac_controls_init(p);
    assert(mac_binding(p, true, e) == DM_BTN_A && mac_binding(p, true, f) == DM_BTN_L);
    mac_rebind(p, true, DM_BTN_A, e, f);
    assert(!mac_binding(p, true, e) && mac_binding(p, true, f) == DM_BTN_A);
    assert(mac_binding(p, true, j) == DM_BTN_A && mac_binding(p, false, e) == DM_BTN_R);
    mac_rebind(p, true, KEY_LOOK_UP, up + MAC_SHIFTED, w + MAC_SHIFTED);
    assert(mac_key_binding(p, w, true, false) == KEY_MOVE_UP && mac_key_binding(p, w, true, true) == KEY_LOOK_UP);
    assert(mac_key_binding(p, up, true, true) == DM_BTN_UP && mac_key_binding(p, up, false, true) == KEY_LOOK_UP);
    mac_rebind(p, true, KEY_SPRINT, MAC_SHIFT, MAC_CONTROL);
    mac_keyboard k = {.profile = p, .mouse_layout = true};
    mac_keys_event(&k, w, true, false);
    mac_keys_modifiers(&k, 62, true, false);
    assert(mac_keys_read(&k, 0).buttons == DM_BTN_B);
    mac_keys_modifiers(&k, MAC_CONTROL, false, false);
    assert(!mac_keys_read(&k, 0).buttons);
    mac_rebind(p, true, DM_BTN_SHAKE, -1, MAC_CLICK);
    assert(mac_keys_read(&k, p->clicks[0]).buttons == DM_BTN_SHAKE);
    mac_set_binding(p, true, MAC_CLICK + 2, KEY_WALK);
    assert(mac_keys_read(&k, p->clicks[2]).ly == DM_STICK_MAX / 2);
    mac_rebind(p, true, DM_BTN_A, f, MAC_ESCAPE);
    assert(mac_binding(p, true, f) == DM_BTN_A);
    mac_rebind(p, true, DM_BTN_A, j, -1);
    mac_keys_clear(&k);
    assert(!mac_keys_read(&k, 0).buttons && !mac_keys_read(&k, 0).ly && k.profile == p);
    p->preset = MAC_KEYS_MOUSE; p->sensitivity = 200;
}
static void equal(const mac_controls *a, const mac_controls *b) {
    assert(a->preset == b->preset && a->sensitivity == b->sensitivity);
    for (int layout = 0; layout < 2; layout++)
        for (int slot = 0; slot < MAC_INPUT_COUNT; slot++) assert(mac_binding(a, layout, slot) == mac_binding(b, layout, slot));
}
int main(void) {
    mac_controls edited, loaded, other, defaults;
    mac_controls_init(&defaults); loaded = other = defaults; mapping(&edited);
    char dir[1024], path[1200], other_path[1200];
    snprintf(dir, sizeof dir, "%s/nx-controls-XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    assert(mkdtemp(dir));
    snprintf(path, sizeof path, "%s/controls-BOTW.tsv", dir);
    snprintf(other_path, sizeof other_path, "%s/controls-other.tsv", dir);
    assert(mac_controls_load(path, &loaded) == ENOENT);
    assert(!mac_controls_save(path, &edited) && !mac_controls_save(other_path, &other));
    assert(!mac_controls_load(path, &loaded)); equal(&edited, &loaded);
    assert(!mac_controls_load(other_path, &other)); equal(&other, &defaults);
    mac_reset_action(&loaded, true, DM_BTN_A);
    assert(mac_binding(&loaded, true, 14) == DM_BTN_A && mac_binding(&loaded, true, 3) == DM_BTN_L);
    assert(mac_binding(&loaded, true, MAC_CONTROL) == KEY_SPRINT);
    mac_reset_bindings(&loaded); defaults.preset = MAC_KEYS_MOUSE; defaults.sensitivity = 200;
    equal(&loaded, &defaults); assert(!mac_controls_save(path, &loaded));
    mac_controls broken = loaded; broken.clicks[1] = UINT64_MAX;
    assert(mac_controls_save(path, &broken) != 0);
    assert(!mac_controls_load(path, &other)); equal(&other, &loaded);
    FILE *f = fopen(path, "w"); assert(f);
    fputs("nxnative-controls\t1\nlayout\tclassic\nclick\t9\tA\n", f); assert(!fclose(f));
    assert(mac_controls_load(path, &other) == EINVAL); equal(&other, &loaded);
    assert(!unlink(path) && !unlink(other_path) && !rmdir(dir));
    puts("PASS: remapping, modifier chords, duplicate keys, mouse buttons, resets and atomic per-game round trips");
}
