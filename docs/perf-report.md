# GPU frame performance record

Every row below names a world reachable through the shipped controls. The frame is a union of
world-intrinsic passes plus one node per non-zero coupling strength, composed by `buildFrame`
(`src/sim_registry.nim:222-351`), so a configuration is named by its four coupling strengths and
its particle count.

## Machine and build

| | |
|---|---|
| Machine | Apple M5 Max, 128 GB, macOS 26.5.2, arm64 |
| Browser | Chromium 150.0.7871.46, protocol 1.3 |
| Nim | 2.2.10 |
| Commit | `c1e0934` |

## How the runs were driven

The app exposes no way to select a world from outside itself. `src/app.nim:327-338` reads `n` and
`seed` and nothing else, so every coupling strength is reached through `window.gardenAPI.setParam`
once the page is live.

Serve, from the repository root:

```
python3 scratchpad/main/perf-harness/coop_server.py 8891 web
```

The particle buffers are backed by a `SharedArrayBuffer` (`src/buffers.nim:41`), so the page needs
`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`. The
harness server supplies both, and it stands apart from the app's own server on 8089, which also
opens a window running a second simulation on the same GPU.

Launch and drive:

```
bun scratchpad/main/perf-harness/run.ts --run <id> --n <count> --seed 42 --duration <seconds> \
  [--set <paramId>=<value> ...] [--set-max <paramId>] [--bloom]
```

which starts

```
/Applications/Chromium.app/Contents/MacOS/Chromium --headless=new --enable-unsafe-webgpu \
  --use-angle=metal --enable-logging=stderr --remote-debugging-port=<free port> \
  --user-data-dir=scratchpad/main/perf-harness/profiles/<id>
```

at `http://127.0.0.1:8891/index.html?n=<count>&seed=42`.

The client waits for `gardenAPI.isReady()`, applies each setting, reads every applied id back
through `getParam`, and exits nonzero on a mismatch, so no number comes from a world that did not
take. Bounds come from `gardenAPI.descriptor()` through `--set-max`, so the harness restates no
range of its own. Both profiler channels are collected, because neither is complete on its own.

## Settling, and what these numbers therefore are

Physics cost tracks clustering. A dispersed world is cheap and a clustered one is not, so a run
reports the state its window happened to reach.

**No run below reached a settled state.** The two 150-second runs make this concrete. At n=128000
the physics trace climbs through the entire window:

```
w1-128k-150          1.08 1.14 0.96 1.39 ... 2.48 2.42 2.83 4.00 6.24 6.53 7.93 7.07 6.59
w1-nocrowd-128k-150  1.03 1.08 0.88 1.04 ... 3.27 4.81 5.69 5.54 6.47 6.34 6.98 6.25 6.48
```

The steepest rise falls in the last third of a 150-second window. Physics at n=128000 measures
0.851-1.471 ms after 30 seconds and 6.529-7.929 ms after 150, so a 30-second figure sits roughly
five times below the same world's 150-second figure, and the 150-second figure is itself still
rising.

Every row states its window length. Read each physics figure as a lower bound on the settled cost
of that configuration, not as the cost.

The settled sample of each run is the last four `[gpu-profile]` entries, reported as an observed
min-max across those four and never as an average. The line emits about every five seconds, so a
30-second window holds six entries and a 150-second window holds twenty-nine.

## Raw per-pass figures

Timestamps attach on the first substep only, so each figure below covers one substep of the frame
it belongs to. The per-frame arithmetic follows in the next table.

| run | window | `particleCount` | `forceStrength` | `fluidStrength` | `rdDeposit` | `rdFieldForce` | `sphSubsteps` | grid | physics | draw | present | field | bloom |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `w0-16k` | 30 s | 16 000 | 0 | 0 | 0 | 0 | 1 | 0.046-0.047 | 0.125-0.128 | 0.238-0.241 | 0.652-0.658 | 1.572-1.680 | 0 |
| `w0-128k` | 30 s | 128 000 | 0 | 0 | 0 | 0 | 1 | 0.054-0.083 | 0.826-1.104 | 0.505-0.728 | 1.650-2.276 | 0.424-0.789 | 0 |
| `w1-16k` | 30 s | 16 000 | 1.0 | 0 | 0.02 | 7.5 | 1 | 0.046-0.047 | 0.143-0.173 | 0.222-0.232 | 0.664-0.694 | 1.671-1.788 | 0 |
| `w1-128k` | 30 s | 128 000 | 1.0 | 0 | 0.02 | 7.5 | 1 | 0.079-0.089 | 0.851-1.471 | 0.361-0.668 | 1.155-1.977 | 0.515-0.842 | 0 |
| `w1-128k-150` | 150 s | 128 000 | 1.0 | 0 | 0.02 | 7.5 | 1 | 0.018-0.019 | 6.529-7.929 | 0.497-0.512 | 2.901-3.291 | 0.438-1.202 | 0 |
| `w2-16k` | 30 s | 16 000 | 1.0 | 1.0 | 0.02 | 7.5 | 2 | 0.046-0.047 | 0.175-0.177 | 0.219-0.221 | 0.640-0.643 | 1.678-1.791 | 0 |
| `w2-128k` | 30 s | 128 000 | 1.0 | 1.0 | 0.02 | 7.5 | 2 | 0.045-0.078 | 0.813-1.053 | 0.341-0.421 | 1.004-1.303 | 0.449-0.672 | 0 |
| `w3-128k` | 30 s | 128 000 | 1.0 | 1.0 | 0.02 | 7.5 | 3 | 0.047-0.068 | 0.805-0.975 | 0.334-0.384 | 0.986-1.183 | 0.446-0.513 | 0 |
| `w1-bloom-128k` | 30 s | 128 000 | 1.0 | 0 | 0.02 | 7.5 | 1 | 0.068-0.097 | 0.933-1.544 | 0.400-0.730 | 0.737-1.543 | 0.487-0.948 | 0.886-1.779 |
| `w1-nocrowd-128k-150` | 150 s | 128 000 | 1.0 | 0 | 0.02 | 7.5 | 1 | 0.018-0.027 | 6.245-6.984 | 0.479-0.482 | 2.981-3.140 | 0.439-1.318 | 0 |

Every column above is the value read back through `getParam` after the run's settings were applied,
not the value requested.

The `w1-*` rows applied nothing at all. They are the shipped defaults
(`src/ui/state/simulation_state.nim:90-122`), so the shipped world runs the species force, the
Gray-Scott chemistry and its force, and no fluid. The `w0-*` rows set all four coupling strengths
to 0 and so measure the intrinsic floor. The Field pass still runs in those rows, because the
chemistry is world-intrinsic and only its two couplings to the particles are switched off
(`src/sim_registry.nim:307-319`).

`fluidStrength` at 1.0 is the descriptor maximum, read from `gardenAPI.descriptor()` at run time.
`sphSubsteps` is 3 in `w3-128k`, which is `SPH_MAX_SUBSTEPS` (`src/sph_core.nim:34`), and 2
elsewhere, which is the shipped value. `crowdingStrength` is 0 in every run, which is what it ships
at.

## The field bucket runs backwards against particle count

The chemistry grid is `FIELD_W` by `FIELD_H`, both compile-time constants
(`src/field_core.nim:42-45`), so the Field pass does the same work whatever `particleCount` is. It
does not measure that way. At n=16000 the field bucket reads 1.572-1.791 ms across all three
16k rows, and at n=128000 it reads 0.424-1.318 ms across all seven 128k rows, so the pass measures
two to four times slower on the world with eight times fewer particles.

A fixed-size dispatch taking longer in a cheaper frame points at the device and not at the pass.
The likeliest reading is that a 2.75 ms frame leaves the GPU idle enough to drop its clock, so a
constant amount of work takes more wall-clock time to retire. That reading is untested here. Until
it is settled, read the field figure as a property of the frame it sits in and never as a per-pass
constant, and do not carry a 16k field figure into a 128k budget.

## Per-frame figures and headroom

Every pass except the field runs once per substep, so its per-frame cost is the raw figure times
`substepCount`. The Field pass carries `fncOncePerFrame` and runs once whatever the substep count.
Totals use the top of each range.

| run | window | substeps | grid | physics | draw | present | field | bloom | per-frame total | headroom to 16.7 ms |
|---|---|---|---|---|---|---|---|---|---|---|
| `w0-16k` | 30 s | 1 | 0.047 | 0.128 | 0.241 | 0.658 | 1.680 | 0 | 2.75 | 13.95 |
| `w0-128k` | 30 s | 1 | 0.083 | 1.104 | 0.728 | 2.276 | 0.789 | 0 | 4.98 | 11.72 |
| `w1-16k` | 30 s | 1 | 0.047 | 0.173 | 0.232 | 0.694 | 1.788 | 0 | 2.93 | 13.77 |
| `w1-128k` | 30 s | 1 | 0.089 | 1.471 | 0.668 | 1.977 | 0.842 | 0 | 5.05 | 11.65 |
| `w1-128k-150` | 150 s | 1 | 0.019 | 7.929 | 0.512 | 3.291 | 1.202 | 0 | **12.95** | **3.75** |
| `w2-16k` | 30 s | 2 | 0.094 | 0.354 | 0.442 | 1.286 | 1.791 | 0 | 3.97 | 12.73 |
| `w2-128k` | 30 s | 2 | 0.156 | 2.106 | 0.842 | 2.606 | 0.672 | 0 | 6.38 | 10.32 |
| `w3-128k` | 30 s | 3 | 0.204 | 2.925 | 1.152 | 3.549 | 0.513 | 0 | 8.34 | 8.36 |
| `w1-bloom-128k` | 30 s | 1 | 0.097 | 1.544 | 0.730 | 1.543 | 0.948 | 1.779 | 6.64 | 10.06 |

No measured configuration exceeds the 16.7 ms interactive budget. The closest is `w1-128k-150` at
12.95 ms, leaving 3.75 ms, and its physics trace was still climbing when the window closed. Whether
a longer window carries that configuration past the budget is unmeasured. Remediation of any pass
belongs to whoever owns it.

## What the substep multiplier costs

`w3-128k` raises `sphSubsteps` to 3 against `w2-128k`'s 2 with nothing else changed. Its raw
per-pass physics figure, 0.805-0.975 ms, sits inside `w2-128k`'s 0.813-1.053 ms, which is what
timestamps attaching on substep 0 only predicts. The per-frame total moves from 6.38 ms to 8.34 ms,
about half again as large, and that whole movement is the multiplier.

## Bloom

The `passBloom` span covers glow-HDR through blur-V (`src/gpu_profiler.nim:24-29`,
`src/webgpu_render.nim:1850-1891`), and it is written only when bloom is enabled.

| | bloom off (`w1-128k`) | bloom on (`w1-bloom-128k`) |
|---|---|---|
| bloom bucket | 0.000 | 0.886-1.779 |
| present bucket | 1.155-1.977 | 0.737-1.543 |

The bloom bucket reads exactly zero with bloom off and a real figure with it on, so the span closes
and bloom's cost is 0.886-1.779 ms at n=128000. The present bucket falls when bloom is enabled. The
earlier record saw the same direction and could not account for it, and these two runs reproduce it
without explaining it. Both runs sit inside the settling caveat above.

## Crowd-density atomic traffic: unmeasured

`crowdDensity` is accumulated with two unconditional `atomicAdd` calls inside and after the
neighbour loop of `web/shaders/src/forces.wgsl`, and no runtime control removes that traffic:
`crowdingStrength` scales what the value is used for and not whether it is computed. Isolating it
needs a shader variant.

The variant deletes the accumulator and both `atomicAdd` calls and keeps one `atomicLoad`. Dawn
derives the bind group layout from static usage, so a binding declared and never referenced leaves
the layout and bind group creation fails with "In entries[7], binding index 7 not present in the
bind group layout", which stops the Forces pass and yields a run with no timing at all. The static
gates do not reach this: `wgsl_lint` reads declarations, and `just happen` succeeds either way.

Differencing the variant against the unmodified build did not produce a cost.

| | physics, settled tail |
|---|---|
| `w1-128k-150`, atomics present | 6.529-7.929 ms |
| `w1-nocrowd-128k-150`, atomics removed | 6.245-6.984 ms |
| difference of tail means | -0.696 ms, standard error 0.830 ms |

The difference sits within one standard error of zero and carries the wrong sign, since the build
doing less work measured higher. Both traces climb through their whole window, so the two runs were
sampled at different points on their own climbs, and the subtraction reports the gap between those
two points. A comparison of this kind needs both sides settled, and n=128000 does not settle inside
150 seconds. The cost stays open.

The variant was reverted with `git checkout web/shaders/src/forces.wgsl`, rebuilt, and confirmed by
`git status --porcelain` naming nothing under `web/` with both suites green.

## What the instrumentation cannot see

These are properties of the profiler as it stands. Each qualifies every number above.

- **Timestamps attach on the first substep only.** The executor encodes the frame description
  `substepCount` times per rendered frame and attaches the query set only when `substep == 0`
  (`src/webgpu_compute.nim:895-898`). `substepCount` is 1 unless the fluid coupling acts, in which
  case it is `clamp(sphSubsteps, 1, SPH_MAX_SUBSTEPS)` (`src/webgpu_compute.nim:717-719`).
- **The Field Force node carries no slot.** It is built with `PROFILER_SLOT_NONE`
  (`src/sim_registry.nim:336-338`) and the executor skips the attach for that value. Its cost lands
  in no bucket and in no total, so it appears only as a difference between two configurations.
- **Neither capture channel is complete.** The console line carries n, grid, physics, draw, present
  and bloom, and omits the field (`src/app.nim:57-58`). `gardenAPI.onStats` carries grid, physics,
  draw, present and field, and omits bloom (`src/web_api.nim:849-857`). Every row above draws the
  field column from the stats channel and every other column from the console line.
- **Physics is the sum of two slots.** The reported figure is `passPhysics` plus `passIntegrate`
  (`src/app.nim:303-304`).

## Caveats

- **Headless present-path timing differs from the window a user sees.** The compute buckets, which
  are what the couplings move, are unaffected by the compositor. The present bucket is not.
- **`getParam("particleCount")` disagrees with the running simulation after any `setParam` call.**
  The `?n=` override writes `CONFIG` directly (`src/app.nim:328-329`) and any later parameter write
  re-mirrors the stored record over it (`src/web_api.nim:160`). Every run above was checked against
  the live count in the stats channel, which reports the count the simulation actually ran. The
  defect has its own change, `sync-particle-count-url-override`.
- **A zero-error sweep was run over every Chromium log**, excluding infrastructure noise. One run
  reported the bind group failure quoted above, and that run was discarded and repeated.

## Two Web API gates, answered while the client was in hand

`midi-interface` and `audio-interface` each assume a permission-prompting Web API resolves inside
the browser the app launches. `webui` selects Chromium 150.0.7871.46 and passes no debugging port,
so both were answered in a Chromium carrying webui's own flag set with a port added.

| question | answer |
|---|---|
| `typeof navigator.requestMIDIAccess === 'function'` | true |
| `navigator.requestMIDIAccess()` | resolves with a `MIDIAccess` |
| `typeof navigator.mediaDevices?.getUserMedia === 'function'` | true |
| `navigator.mediaDevices.getUserMedia({audio:true})` | resolves with a `MediaStream` |

The page reports `isSecureContext` and `crossOriginIsolated` both true. Whether a permission prompt
appeared and was answered is unobserved, and the launch differs from webui's own window in the
debugging port, the profile directory, the serving port, and four flags webui passes that the
harness did not: `--app`, `--allow-insecure-localhost`, `--disable-component-update`, and
`--window-size`. Neither sibling change opens by reporting unavailability.

## Evidence

Every run's full trace and stderr log is retained under `scratchpad/main/perf-harness/runs/`, one
`<id>.json` and one `<id>.log` per row.
