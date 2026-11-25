# Breath of the Wild and Ocarina of Time on macOS 15 with Xcode 26

An original Switch Breath of the Wild NSP built on an M3 Max using the
`mac15` Metal 3 host. The game loaded its shader library and finished
prewarming. The first reported run aborted when the NVN queue signaled its
submission fence. The player confirmed BOTW runs after the shared-event fix.
The Switch 2 Ocarina of Time profile is enabled for the same host. Its game
build and gameplay still need verification on Sequoia.

## Build on the target Mac

Use Apple silicon, macOS 15.6 or later within Sequoia, and a selected Xcode
26.x that runs on that OS. Xcode 26.3 and SDK 26.2 are the toolchain used in
the hardware check. The Mac needs the Metal toolchain and the normal NSP
builder dependencies, including Python 3.12 or later.
[Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/)

From the repository root, exercise the production replay first. The fixture
needs no game files. The first run compiles the host's shader libraries and the
NVN test executable. The log includes the compiler output and GPU readbacks.

```sh
python3 scripts/check_mac15.py --out mac15-check.log
```

A successful run ends with `PASS: prerequisites, Metal 3 backend and NVN replay
readback.` followed by the reminder about the separate game run. The fixture
uses the same `mtl_sub_begin`, `mtl_exec` and `mtl_sub_commit` that BOTW uses.
It checks clear, draw, texture copy, render-target changes, sampled texture
handles, and direct and indirect indexed draws. A mixed compute/copy pass
checks GPU-written bytes after switching native encoders and changing a table
binding. The check exercises both the driver and the Metal API validation layer.

### Breath of the Wild on original Switch

Build with the NSP command, substituting the paths on your Mac.

```sh
python3 scripts/build_ipa_from_nsp.py "/path/to/BOTW NSPs" -k "/path/to/prod.keys" --platform mac
```

Use a base NSP for title ID `01007EF00011E000` and its matching update and
optional DLC NSPs. The registered profile covers update 1.9.0. The builder
checks the profile and module build IDs before applying version-specific
patches. [BOTW profile](../dm/games/01007EF00011E000/README.md)

### Ocarina of Time on Switch 2

Use your NUP for title `0400486024DEC000` with update 1.1.1 (`v131072`). The command also accepts an extracted dump folder containing the base game and that update. Both formats work without `prod.keys`. [Dump folder layout](../README.md#switch-2-games)

```sh
python3 scripts/build_ipa_from_nsp.py "/path/to/Ocarina of Time.nup" --platform mac --package v131072
```

The default build compiles the full shader map. For a shorter first build, add `--seen-shaders` to compile the shaders recorded during upstream playtests. A scene that uses additional shaders can have missing draws with that option. [Ocarina of Time shaders](../dm/games/0400486024DEC000/README.md#shaders)

To exercise the game's graphics path before building, run the game-file-free check for its title ID. It draws through NVN2 with task payloads, checks depth and colour values, and verifies direct and indirect mesh draws across 3,072 workgroups with Metal validation off and on.

```sh
python3 scripts/check_mac15.py --game 0400486024DEC000 --out oot-mac15-check.log
```

### Launch and controls

The script selects Metal 3 on Sequoia, builds the game libraries as MSL 3.2
for 15.6 and prints the launch command. Build output is under the usual
game build folder's `mac15/` subdirectory. Its `logs/dmsh_build.log` records
shader compilation and `logs/mac_host_build.log` records the host build. The
run directory and saves also live under `mac15/`. For Ocarina of Time the
default run log is `0400486024DEC000_build/mac15/run/host.log` under the game folder.

Press **⌘,** to open **Controls → Controller Mapping…** and choose **Keyboard + Mouse**.
Click a controller button or stick direction, then press the key you want for it.
Mouse or trackpad motion always drives the right stick in this mode. **Escape** releases
the pointer for the menus. Click the game picture to resume.

BOTW saves changes in `mac15/run/controls-01007EF00011E000.tsv` inside its build folder
and reads them on launch. Copy that file alongside the `save` folder to take your controls
with you. [Bindings, mouse clicks and resets](playing.md#keyboard-and-mouse-layout) · [Default mouse controls](playing.md#mouse-and-trackpad)

## Renderer and cache behavior

- NVN submits fresh native command buffers on the host's queue. A logical
  compute/copy pass opens compute or blit encoders as needed and fences each
  transition. A resumed compute dispatch restores its pipeline, threadgroup
  memory and current bindings.
- Direct GPU-address bindings and indirect draw/dispatch argument records
  resolve to retained buffers and byte offsets. Guest argument buffers retain
  their GPU-resource-ID representation. Each command buffer names the host's
  residency sets, including the snapshots' set. The ordinary replay manages
  arena reuse and releases resources on completion.
- Render, compute and mesh pipelines use the existing MTLDevice path. Frame
  presentation uses the drawable's classic command buffer and preserves
  presentation timing and completion callbacks. GPU timestamps use command
  buffer completion times. The Mac uses direct replay. It skips the Metal 4
  pipeline archive prebuild and uses the existing whole-texture path for
  sparse guest textures.
- The host's per-toolchain object directories include the SDK build and clang
  version. Shader cache entries include the compiler, SDK and actual flags.
  The mac15 build accepts the selected Xcode 26.x Metal compiler and checks
  the pinned extractor/translator and SPIRV-Cross as before.
- macOS 15 lacks the per-sampler LOD bias and min/max reduction properties
  used by the newer renderer. The host logs the first requested nonzero bias
  and reduction mode and uses ordinary sampling. Their effect on BOTW's
  rendered image still needs a gameplay comparison.

## Validation record

| Check | Result |
|---|---|
| Target hardware | Apple M3 Max, macOS 15.7.5, unified memory, BC textures and Tier 2 argument buffers |
| Toolchain on the Mac | Xcode 26.3 (17C529), SDK 26.2, Apple clang 17.0.0 (clang-1700.6.4.2), Apple Metal 32023.864 |
| Native tools on the Mac | Extractor source `eb660696a669ac76`, translator source `e2d3359d2a182f50`, SPIRV-Cross `vulkan-sdk-1.4.363.0` |
| Prerequisite and backend core on the Mac | Passed with Metal validation, including 32,400 range cases, two GPU submissions, indirect bindings, draw/blit readbacks, barriers, events, cancellation and completion lifetime |
| Production host and replay fixture | Cross-compiled and linked on Linux against SDK 26.2 headers and framework stubs. The cross build uses the generator's source-only host shader fallback |
| BOTW NSP build and launch on the M3 Max | Build succeeded. Prewarming completed with 1,482 shaders, 960 render pipelines and 10 compute pipelines before the shared-event abort. |
| Launch after the shared-event fix | The M3 Max player confirmed BOTW runs. |

The implementation is in [the NVN renderer](../dm/gfx/nvn/nvn_mtl.m),
[the Metal 3 replay encoders](../dm/gfx/nvn/nvn_mtl3_replay.m) and
[the submission and binding core](../dm/gfx/nvn/nvn_mtl3.m).
