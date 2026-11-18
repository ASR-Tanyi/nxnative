# mac15: BOTW on macOS 15 with Xcode 26

**Status: port in progress, not playable on macOS 15 yet.** Prerequisites passed
on the user's M3 Max. This increment adds a Metal 3 submission and binding core
and standalone tests; its Mac run is pending. The existing NVN replay still
requires Metal 4 and does not call the new core. A passing diagnostic does not
mean the host builds or BOTW boots. The production deployment target and
compiler lock have not been lowered before a complete rendering path exists.

## Initial scope

- Apple silicon, macOS Sequoia **15.6 or later within 15.x**, with Xcode **26.x**
  that runs on that system. Apple's [Xcode requirements](https://developer.apple.com/xcode/system-requirements/)
  list Xcode 26 through 26.3 for Sequoia 15.6; later Xcode releases can require Tahoe.
- The existing `scripts/build_ipa_from_nsp.py <folder> -k <keys> --platform mac`
  command, with the user's own BOTW base/update/DLC NSPs.
- Original Switch BOTW, base title ID `01007EF00011E000`, using its existing
  [profile and build-ID rules](../dm/games/01007EF00011E000/README.md). The profile
  records update 1.9.0; another NSP version needs its own boot validation and
  must not inherit fixed-address patches from that build.
- No initial mac-app, IPA, NUP, Switch 2, other-game or Intel Mac support on
  the new compatibility path. Existing supported platforms keep their path.

## What the source audit found

| Area | Current behavior | Work needed |
|---|---|---|
| CLI | `--platform mac` already exists in [the NSP script](../scripts/build_ipa_from_nsp.py) | Keep the command; select and validate the older target internally |
| Deployment target | [min_os.mk](../dm/mac/min_os.mk) sets 26.6; the host and shader tools use it | A coherent 15.6 target for the host, embedded shaders and game libraries, with separate build/cache identities |
| Toolchain | [own_compilers.py](../dm/gfx/tools/own_compilers.py) checks Metal against the Xcode 27.2 lock | An explicit, measured compatibility policy for Xcode 26; check only the Mac SDK on the Mac path |
| Device startup | `mtl_init` in [nvn_mtl.m](../dm/gfx/nvn/nvn_mtl.m) aborts without Metal 4 | Real Metal 3 device and queue initialization |
| GPU execution | Queues, reusable command buffers, allocators, argument tables, encoders and commit feedback use `MTL4*` types | Metal 3 submission, bindings, synchronization and completion/lifetime handling |
| Existing classic path | `mtl_device_classic` allows GL/Vulkan headless capture; `mtl_present` drops its presents | It cannot serve as BOTW's renderer |
| Pipeline toggle | `DM_PSO_MTL4=0` selects `MTLDevice` pipeline creation only | Reuse this pipeline path, but also port command encoding and presentation |
| Shaders | [dmsh_chain.py](../dm/gfx/tools/dmsh_chain.py) emits MSL 3.2; its Mac target is 26.6 | Compile/load BOTW libraries for 15.6, audit generated variants, preserve shader ABI and regenerate the chain header when changed |
| Presentation | Present buffers, snapshots and MetalFX use Metal 4 paths | Classic command-buffer presentation, preserving pacing and snapshot lifetimes; optional upscaling may wait |

Metal 3 and Metal 4 command types have different lifecycles and are not
interchangeable typedefs. Apple's [core API comparison](https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api)
is the porting reference. Keep the shader argument-buffer ABI where possible;
Metal 3 can use direct GPU addresses, with explicit
[resource residency declarations](https://developer.apple.com/documentation/metal/tracking-the-resource-residency-of-argument-buffers).
Do not treat `--allow-other-metal` or a lower deployment flag alone as support.

## Step 1: prerequisite check (passed on the user's Mac)

The user supplied a successful prerequisite log with these versions:

| Component | Reported value |
|---|---|
| Mac / OS | Apple M3 Max, macOS 15.7.5 |
| Xcode | 26.3, build 17C529 |
| macOS SDK | 26.2 |
| Apple Clang | 17.0.0, clang-1700.6.4.2 |
| Metal compiler | 32023.864, metalfe-32023.864 |
| Extractor source SHA | `eb660696a669ac76` |
| Translator source SHA | `e2d3359d2a182f50` |
| SPIRV-Cross | `vulkan-sdk-1.4.363.0`, timestamp `2026-09-16T11:27:19` |

The offline MSL 3.2 library, indirect GPU-address buffers, compute, draw, blit
and shared event passed with Metal validation enabled. The original log's
`argument buffers tier: 1` is the numeric enum for **Tier 2**, not Tier 1; the
diagnostic now prints both the tier name and enum. This is a prerequisite
result, not a host build, extraction, shader-translation or gameplay result.

## Run the diagnostic

Select your installed Xcode 26, download its Metal toolchain if needed, and run
from this checkout. Adjust the example Xcode and game-folder paths:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain
python3 scripts/check_mac15.py --out ~/Games/BOTW/mac15-check.log
```

The check needs only an arm64 Python 3 and Xcode, not NSPs, keys, Python game-tool
packages, an iOS SDK or .NET. It runs the committed extractor and translator
with `--source-sha`, and SPIRV-Cross with `--revision`, to verify they start.
These startup checks do not establish that extraction or translation succeeds.

It compiles the prerequisite probe, the CPU address-range test and the new
backend test below, using MSL 3.2 and a macOS 15.6 deployment target. Both GPU
tests run with Metal validation enabled. Temporary binaries are removed. It
changes no game data, toolchain settings, shader caches, locks or production
host outputs.

Send back `mac15-check.log`, including the first failure. It contains commands,
tool versions, local paths and synthetic-test results, not game data or keys.
An exit code of 0 means only that these prerequisite and backend-core tests
passed. It does not validate NVN replay/barrier translation, presentation,
arena recycling or any game shaders.

## Step 2: execution core (implemented; Mac run and NVN wiring pending)

[nvn_mtl3.h](../dm/gfx/nvn/nvn_mtl3.h) and
[nvn_mtl3.m](../dm/gfx/nvn/nvn_mtl3.m) use classic Metal command buffers and
encoders only. They provide:

- A locked GPU-address registry resolving an entire range to a retained buffer
  and offset, including overlapping aliases. A request cannot span adjacent
  allocations. Removal does not invalidate bindings already resolved.
- Mutable buffer/texture/sampler tables, applied before each draw or dispatch.
  Applying a table clears its unset slots. Every applied object, explicit
  indirect resource and keep-alive object is retained through GPU completion.
  `useResource` declares indirect buffer/texture access per pass; indirect
  samplers need `keepAlive` as well.
- One native command buffer per submission, render/compute/blit encoders,
  conservative fences between all passes, and an explicit compute barrier
  within a pass. A queue's commit order defines execution order, even if its
  submissions were encoded in another order. This follows Metal's
  [fence ordering rules](https://developer.apple.com/documentation/metal/synchronizing-passes-with-a-fence).
- Real GPU event waits/signals, monotonic submission serials, completion errors
  and timestamps, pre-commit cancellation, and bounded completion waits.
  Completion releases retained objects after callbacks. GPU errors latch on
  the queue, so later submissions fail; a timeout reports in-flight work and
  does not cancel it or fabricate completion.

The CPU [range test](../dm/gfx/tests/t_mtl3_range.c) checks boundaries,
overflow, gaps and 32,400 overlapping-range cases against a linear oracle.
The [GPU test](../dm/gfx/tests/t_mtl3_backend.m) compiles the actual core and
checks two untracked-resource submissions encoded in reverse order, binding
replacement, compute-to-render-to-blit readback, indirect texture/sampler
handles, completion timestamps, registry removal, cancellation and event
wait/signal. A CPU-controlled event tests timeout and resource lifetime. The
error-latch test injects a synthetic error; it does not deliberately fault the
GPU and is not proof of real driver-fault recovery.

Each submission and binding table has one encoding thread. The queue and
buffer map serialize their shared state. Retaining a buffer keeps its storage
alive; it does **not** make overwriting an arena slice safe before completion.
The NVN adapter must retain the arena allocation until its completion handler
and reapply mutated tables before draws/dispatches. Those call sites, arena
recycling, NVN barriers and deferred replay are the next part of step 2. The
core has no production callers yet; no new backend selection flag is exposed.

## Implementation sequence

Each step should be a separate commit on `mac15`; do not mark support complete
until the final step passes on the target system.

1. **Prerequisites and design (passed).** Record the exact OS, Xcode,
   SDK, Metal compiler and native-tool startup results. Pass the synthetic
   Metal 3 checks on the user's Mac before relying on these primitives.
2. **Metal 3 execution backend (core added; wiring pending).** Introduce a narrow encoding/submission layer
   around the existing `enc_*`, submission and `nvn_rec.h` boundaries. Use a
   fresh classic command buffer per commit; resolve GPU addresses to retained
   buffers and offsets for direct bindings, including temporary arenas and
   zero buffers. Handle indirect resources explicitly. Port copies/fills to
   blit encoders, preserve pass load/store state, fences, barriers, events,
   completion errors, timestamps and deferred releases. Test two submissions,
   indirect texture/sampler bindings, arena reuse and compute-to-draw ordering
   with synthetic readbacks before game bring-up.
3. **Host and shader build integration.** Build against Xcode 26 with SDK and
   runtime availability guards. Select the Mac 15 target only for the initial
   `--platform mac` / BOTW NSP scope; report unsupported combinations early.
   Include backend, deployment target and compiler in host and shader reuse
   keys. Keep the pinned extractor/translator checks; do not overwrite their
   lock with an unmeasured fingerprint. Update the chain header if chain inputs
   change. Make BOTW's full shader set load on 15.6, and record compiler failures
   before changing shader lowering. A lower-target build must not reuse 26.6
   objects or libraries, nor let the newer path reuse its outputs.
4. **Pipelines and presentation.** Use `MTLDevice` pipelines on Metal 3; skip
   the Metal 4 archive/hybrid prebuild in `mac_run`. Port the present and
   snapshot queues and display-link handoff. Guard optional Metal 4/MetalFX
   features without disabling required BOTW rendering operations. Verify
   window resize, vsync, several frames in flight, clean shutdown and GPU
   error reporting. The existing Metal 4 backend must still pass its checks.
5. **BOTW acceptance.** Run the ordinary NSP command on macOS 15.6/Xcode 26.
   First require extraction, rewrite, shader build and host link to pass; then
   title screen, input, a loaded save, world rendering, audio and save/reload.
   Compare a fixed route (including a shrine and a scene with particles) with
   the existing supported backend, inspect screenshots and red/GPU-error
   lines, and run BOTW's regression route. Rebuild unchanged inputs to verify
   cache reuse, then change toolchains to verify invalidation. Record the
   actual game build, Mac and tool versions in the game note before declaring
   the initial scope supported.

## Validation of this increment

The Python tests mock commands and cover failure propagation from either GPU
test, backend compilation and the CPU test, unsupported environments, log
preservation, temporary-output cleanup and Mac-only SDK use:

```sh
python3 -m unittest dm/tools/tests/test_mac15_check.py dm/tools/tests/test_docs.py dm/tools/tests/test_gfx_tests_makefile.py
```

The development environment for this increment is Linux: no Apple SDK, Metal
device, NSPs or keys are available. The new Objective-C/Metal backend test and
full host have **not** been compiled here. The older prerequisite probe passed
on the user's Mac as recorded above; no BOTW build or gameplay is claimed.

Local results: 54 tests passed across `test_mac15_check`, `test_docs`,
`test_ci_toolchain`, `test_mac_metal`, `test_nsp_chain` and
`test_gfx_tests_makefile`. The CPU range test passed normally and under
ASan/UBSan (leak detection disabled because this executor runs under ptrace).
Its build/run target is also included in CI's CPU graphics subset. The backend
Makefile target was dry-run only; actual Metal compilation remains pending.
The pinned Python lint ratchet reports 305 existing findings and zero new ones.

The C lint compilation database cannot be generated here because `xcrun` is
unavailable. `regress.py check --games 01007EF00011E000` cannot start because
it imports `/usr/lib/libproc.dylib`. BOTW is the intended first consumer; this
unwired core has no game-path callers yet. Mac compilation, GPU checks and
gameplay regression validation remain pending.
