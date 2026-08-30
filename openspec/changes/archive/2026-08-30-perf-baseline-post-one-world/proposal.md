# Measure the merged frame and replace the performance record

## Why

`docs/perf-report.md` measures a build the repository no longer contains. It times the app
under `?mode=particle-life`, `?mode=sph` and `?mode=reaction-diffusion`
(`docs/perf-report.md:19,40-46`) and issues a gate verdict per mode
(`docs/perf-report.md:52-60`). The app now reads two URL parameters, `n` and `seed`, and no
third (`src/app.nim:327-338`), and `tests/test_no_modes.nim:17-32` sweeps `src/` and
`web-ui/src/` to keep those three mode ids out of the tree. Every row of the record names a
world the app cannot be asked to run.

The frame the app does run has never been timed in its present composition. A frame is now a
union of world-intrinsic passes plus one node per non-zero coupling strength
(`src/sim_registry.nim:66-87`, `buildFrame` at `:222-351`), and it carries per-particle work
the old record never saw. A third density channel, `crowdDensity` at particle offset 28
(`src/memory_layout.nim:65`, `src/gpu_types.nim:83`), is accumulated with two unconditional
`atomicAdd` calls inside the neighbour loop of `web/shaders/src/forces.wgsl:312-314,385-386`
and resolved in `web/shaders/src/integrate.wgsl:71-74`. Its added atomic traffic is an open
number.

Two proposed changes, `audio-interface` and `midi-interface`, each add per-frame work to a
frame whose cost nobody has measured.

## What Changes

- An agent-driven measurement harness lands in `scratchpad/`: a COOP/COEP static server over
  `web/`, and a Chrome DevTools Protocol client that sets coupling strengths through
  `window.gardenAPI.setParam` and collects both profiler channels. Nothing under `src/`,
  `web/`, `web-ui/`, or `tests/` changes.
- Eight measurement runs across two particle counts and four coupling configurations, plus one
  bloom-on run, produce the numbers.
- One further run measures the `crowdDensity` atomic traffic against a temporary
  `web/shaders/src/forces.wgsl` variant, reverted before the change closes.
- `docs/perf-report.md` is rewritten in place with the resulting record.

Nothing user-visible changes. No behavior is added or removed.

### What survives of the old method, and what died with the modes

Survives:

- The launch recipe. Chromium at `/Applications/Chromium.app`, `--headless=new
  --enable-unsafe-webgpu --use-angle=metal`, a fresh `--user-data-dir` per run,
  `--enable-logging=stderr`, output captured per run (`docs/perf-report.md:16-21`). The
  installed browser still reports `Chrome/150.0.7871.46`, the version that record names
  (`docs/perf-report.md:9`), so the browser axis holds constant between the two records.
- The COOP/COEP requirement. `web/index.html` is served with
  `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`
  because the particle buffers are backed by a `SharedArrayBuffer` (`src/buffers.nim:41`,
  `src/main.nim:72-76`).
- The run length and the settle discipline. A ~150 second window with the settled sample taken
  from its tail, reported as an observed min-max across the sampled lines, never an
  average (`docs/perf-report.md:23`). The reason still holds: physics cost tracks clustering
  (`docs/perf-report.md:32`), so a short run reports a dispersed world.
- The `[gpu-profile]` console line as one capture channel (`src/app.nim:57-58`, emitted every
  tenth FPS refresh at `src/app.nim:311-314`).
- The zero-error log sweep (`docs/perf-report.md:26`).

Died:

- Every configuration. `?mode=` reaches nothing (`src/app.nim:327-338`), and `?bloom=1` reaches
  nothing either. The only URL parameters are `n` and `seed`.
- The serve recipe. `coop_server.py` is not in the repository and appears in no commit; the
  headers now come from the app's own server on port 8089 (`src/main.nim:19,62-85`), which also
  opens a window that runs a second simulation.
- The per-mode gate verdicts G1 through G3 (`docs/perf-report.md:52-60`). No mode exists to
  pass or fail one.
- The recorded prior baseline the verdicts compared against
  (`docs/perf-report.md:30-31`), which is stated per mode.
- G4's premise. That gate could not be settled because the three bloom passes wrote no
  timestamps (`docs/perf-report.md:64`). They do now: `passBloom` is a single span opened by
  `attachBeginTimestamp` on the glow-HDR pass and closed by `attachEndTimestamp` on blur-V
  (`src/gpu_profiler.nim:24-29`, `src/webgpu_render.nim:1850-1891`), and `src/app.nim:308,313`
  reports it. One bloom-on run settles what G4 left open.

### Instrumentation gaps the record must state

These are facts about the profiler as it stands. This change works around each and does not
repair any; a repair is a source change and belongs to a different proposal.

- **Timestamps attach on the first substep only.** The executor encodes the whole frame
  description `substepCount` times per rendered frame and attaches the query set only when
  `substep == 0` (`src/webgpu_compute.nim:895-914`). `substepCount` is `1` unless the fluid
  coupling acts, in which case it is `clamp(sphSubsteps, 1, SPH_MAX_SUBSTEPS)`
  (`src/webgpu_compute.nim:717-719`; `SPH_MAX_SUBSTEPS = 3` at `src/sph_core.nim:34`, shipped
  `sphSubsteps = 2` at `src/ui/state/simulation_state.nim:118`). Every reported per-pass number
  in a fluid world therefore covers one substep, and the per-frame cost of a per-substep node is
  that number times `substepCount`. Nodes carrying `fncOncePerFrame`, which is the Field (RD)
  pass, run once whatever the substep count (`src/sim_registry.nim:344-345`,
  `src/webgpu_compute.nim:899-900`).
- **The Field Force node carries no slot.** It is built with `PROFILER_SLOT_NONE`
  (`src/sim_registry.nim:336-338`), and the executor skips the timestamp attach for that value
  (`src/webgpu_compute.nim:913`). Its cost lands in no bucket and no total.
- **Neither capture channel is complete.** The console line carries n, grid, physics, draw,
  present and bloom, and omits the field (`src/app.nim:57-58`). `gardenAPI.onStats` carries
  grid, physics, draw, present and field, and omits bloom
  (`src/web_api.nim:849-857`, `src/web_api.nim:1298`). The record needs both.
- **Physics is a sum of two slots.** The reported physics figure is `passPhysics` plus
  `passIntegrate` (`src/app.nim:303-304`), which is what "physics" means in both the old record
  and the new one.

### The measurement gate

The harness driving parameters through CDP is unproven against this app. CDP itself answers on
this machine: headless Chromium at `--remote-debugging-port` served `/json/version` and
`/json/list` on request, reporting protocol 1.3. Reaching `window.gardenAPI` through
`Runtime.evaluate` and having a `setParam` call land in `CONFIG` is not proven. Task group 1
is that gate: it sets one parameter, reads it back through `getParam`, and confirms the value
before any timed run happens. If the gate fails, no configuration below is measurable as
specified and the change stops there. It reports no number from a world it could not set.

## Capabilities

### New Capabilities

None. This change takes measurements and rewrites one document. No requirement changes, so
`.openspec.yaml` sets `skip_specs: true`.

The requirements this record leans on already exist: profiler slots must be pairwise distinct
and distinct within one frame (`openspec/specs/gpu-frame-registry/spec.md:73-87`), which is
what makes a per-pass number attributable at all. A requirement worded "the performance record
describes the frame the app runs" would have no gate. `tests/test_no_modes.nim:34` sweeps
`src` and `web-ui/src` and does not read `docs/`, which is exactly why the dead vocabulary
survived there. Writing that requirement without extending the sweep produces an unenforced
line, so this change writes neither.

### Modified Capabilities

None.

## Impact

- `docs/perf-report.md`, rewritten in place. The old content goes; no superseded copy stays. The
  sibling report `docs/control-legibility-report.md` is a single file regenerated over itself
  (`docs/control-legibility-report.md:2` states edits there are overwritten), so a second,
  superseded performance file would be the only artifact of its kind in that directory. `git log
  --follow` keeps the old content reachable.
- `scratchpad/main/`, holding the server and CDP harness scripts.
- `web/shaders/src/forces.wgsl`, edited and reverted within one task group, verified clean by
  `git status --porcelain`.
- No change to `src/`, `web-ui/`, `tests/`, or any `openspec/specs/` file.

## Open questions

- **The dead vocabulary can return to `docs/`.** `tests/test_no_modes.nim` sweeps `src` and
  `web-ui/src` only (`tests/test_no_modes.nim:34`). Extending `SWEEP_ROOTS` to `docs` would
  make a mode id in a document fail the suite the way one in source does, and would have caught
  this record a month ago. Doing it means editing `tests/test_no_modes.nim`, which is outside
  what this change claims. Options: extend the sweep here, open a separate change for it, or
  leave `docs/` unswept.
- **Whether the frame is over budget is a finding, not this change's work.** If a measured
  configuration exceeds the 16.7 ms interactive budget the old record used as its yardstick
  (`docs/perf-report.md:58`), the new record states the number and the headroom and stops.
  Remediation belongs to whoever owns the pass that costs too much.
