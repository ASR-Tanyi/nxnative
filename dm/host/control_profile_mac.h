// Per-game Mac input profile, shared by the editor and the game window.
#pragma once
#include "keyboard_mac.h"

const char *mac_action_label(uint64_t action);
int mac_controls_load(const char *path, mac_controls *out);   // 0 or an errno; out changes only on success
int mac_controls_save(const char *path, const mac_controls *profile);
