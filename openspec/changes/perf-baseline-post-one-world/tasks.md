# Tasks

Every run below is performed by an agent. No task waits on a person.

Shared run procedure, referenced as **RUN(id)** throughout. It is implemented once in task 1.3
and invoked per row afterwards:

1. From the repository root, start the harness server in the background:
   `python3 scratchpad/main/perf-harness/coop_server.py 8891 web`.
2. `bun scratchpad/main/perf-harness/run.ts --run <id> --n <count> --seed 42 --duration 150
   [--set <paramId>=<value> ...] [--bloom]`, which launches
   `/Applications/Chromium.app/Contents/MacOS/Chromium --headless=new --enable-unsafe-webgpu
   --use-angle=metal --enable-logging=stderr --remote-debugging-port=<free port>
   --user-data-dir=scratchpad/main/perf-harness/profiles/<id>` at
   `http://127.0.0.1:8891/index.html?n=<count>&seed=42`.
3. The script waits for `window.gardenAPI.isReady()`, applies each `--set` through
   `gardenAPI.setParam`, applies `--bloom` through `gardenAPI.setBloom(true)`, reads every
   applied id back through `gardenAPI.getParam`, and exits nonzero on any mismatch.
4. It then registers a `gardenAPI.onStats` collector and subscribes to
   `Runtime.consoleAPICalled`, runs the 150-second window, and writes both collections plus the
   Chromium stderr log to `scratchpad/main/perf-harness/runs/<id>.json` and `<id>.log`.
5. Read `<id>.json`. The settled sample is the last four `[gpu-profile]` entries. Record the
   observed min-max of each field across those four, never a mean, and record whether the full
   trace flattened inside the window or was still climbing at its end.

## 1. Harness and the parameter gate

This group gates every measurement group after it. Nothing is timed until 1.4 passes.

The harness answers three unproven gates, not one. `midi-interface` and `audio-interface` each
carry a measurement gate asking whether a permission-prompting Web API resolves inside the browser
webui launches, and both reduce to a `Runtime.evaluate` call through the same CDP client this group
builds. Task 1.6 answers them while the client is in hand, so neither sibling change opens with an
unproven transport.

- [ ] 1.1 Confirm the pre-state that makes this change necessary: `grep -c 'particle-life\|reaction-diffusion' docs/perf-report.md` returns a nonzero count while `grep -rn 'mode=' src/app.nim` finds no mode parameter. Touches no file. No test fails first here. This group produces a measurement instrument, and the suite has nothing to say about it.
- [ ] 1.2 Write `scratchpad/main/perf-harness/coop_server.py`: a `ThreadingHTTPServer` over a `SimpleHTTPRequestHandler` rooted at the directory named in `argv[2]`, listening on `argv[1]`, adding `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` to every response. Verify by starting it on 8891 against `web` and confirming `curl -sI http://127.0.0.1:8891/index.html` prints both headers with a 200.
- [ ] 1.3 Write `scratchpad/main/perf-harness/run.ts` implementing steps 2 through 4 of RUN, using bun's built-in `WebSocket` against the target `webSocketDebuggerUrl` read from `http://127.0.0.1:<port>/json/list`. It installs no dependency. Verify by running it with `--duration 20 --run smoke --n 16000` and confirming `scratchpad/main/perf-harness/runs/smoke.json` exists and holds at least one `[gpu-profile]` entry.
- [ ] 1.4 **Gate.** Run `bun scratchpad/main/perf-harness/run.ts --run gate --n 16000 --duration 60 --set fluidStrength=0.5`. The observation that settles it: the script's read-back of `fluidStrength` returns `0.5`, and at least one `[gpu-profile]` entry in `runs/gate.json` carries a physics figure above zero, which is what shows the adapter granted `timestamp-query` and the profiler is live (`src/gpu_profiler.nim:2-3,60-62`). A zero-everywhere trace means the profiler is inactive and no configuration below is measurable. Stop the change and report that instead of recording zeros.
- [ ] 1.5 **The two sibling gates**, answered from the client 1.3 built. Launch the app's own server and window (`./main`, port 8089, `src/main.nim:19,62-85`) rather than the headless harness server, since what is under test is the browser webui selects and the permission UI inside that window. Attach over CDP and evaluate each of `typeof navigator.requestMIDIAccess === 'function'` and `typeof navigator.mediaDevices?.getUserMedia === 'function'`, then call each one and record whether the promise resolves, rejects, or hangs on a prompt nobody can answer. Record the browser's `navigator.userAgent` beside the results. The observation that settles each: a resolved promise means the sibling change's transport is buildable as its proposal assumes, and a rejection or a hang means that change opens by reporting unavailability through its affordance instead. Write both results to `scratchpad/main/perf-harness/runs/web-api-gates.json`. This task times nothing and gates no measurement group below. A failure here stops neither this change nor any task in it.
- [ ] 1.6 Confirm the working tree is unchanged outside `scratchpad/`: `git status --porcelain` names no path under `src/`, `web/`, `web-ui/`, `tests/`, or `docs/`. Then `just happen` and `just check` green.

## 2. The intrinsic floor and the shipped world

Depends on group 1. `docs/perf-report.md` holds no row for either world; these two runs produce
the first ones.

- [ ] 2.1 RUN(`w0-16k`): `--n 16000 --set forceStrength=0 --set fluidStrength=0 --set rdDeposit=0 --set rdFieldForce=0`. Record grid, physics, draw, present, field and bloom from `runs/w0-16k.json`. Touches `scratchpad/main/perf-harness/runs/w0-16k.json` only.
- [ ] 2.2 RUN(`w0-128k`): the same four settings at `--n 128000`. Touches `scratchpad/main/perf-harness/runs/w0-128k.json` only.
- [ ] 2.3 RUN(`w1-16k`): `--n 16000` with no `--set` flags, which leaves the shipped boot state (`src/ui/state/simulation_state.nim:87-122`). Touches `scratchpad/main/perf-harness/runs/w1-16k.json` only.
- [ ] 2.4 RUN(`w1-128k`): the same at `--n 128000`. Touches `scratchpad/main/perf-harness/runs/w1-128k.json` only.
- [ ] 2.5 Verify the frame each run executed matches what `buildFrame` predicts, by evaluating `gardenAPI.getParam` for the four coupling ids in each run's JSON and checking them against `src/sim_registry.nim:255-351`: W0 runs must show all four at zero, W1 runs must show `forceStrength`, `rdDeposit` and `rdFieldForce` non-zero with `fluidStrength` zero. A mismatch means the settings did not land and the run is discarded and repeated. Touches no source file.
- [ ] 2.6 `just happen` and `just check` green; `git status --porcelain` names nothing outside `scratchpad/`.

## 3. Fluid, and the substep multiplier

Depends on group 2, whose W1 rows are what these differ against. No row in
`docs/perf-report.md` states a substep count today.

- [ ] 3.1 Read `gardenAPI.descriptor()` for `fluidStrength` and take its `max` (`src/web_api.nim:211-212`). Record the value read; the harness restates no bound of its own.
- [ ] 3.2 RUN(`w2-16k`): `--n 16000 --set fluidStrength=<max from 3.1>`, leaving `sphSubsteps` at its shipped 2. Touches `scratchpad/main/perf-harness/runs/w2-16k.json` only.
- [ ] 3.3 RUN(`w2-128k`): the same at `--n 128000`. Touches `scratchpad/main/perf-harness/runs/w2-128k.json` only.
- [ ] 3.4 RUN(`w3-128k`): `--n 128000 --set fluidStrength=<max from 3.1> --set sphSubsteps=3`, which is `SPH_MAX_SUBSTEPS` (`src/sph_core.nim:34`). Touches `scratchpad/main/perf-harness/runs/w3-128k.json` only.
- [ ] 3.5 For each of the three runs, compute the per-frame figure alongside the raw one: multiply every pass except Field (RD) by that run's substep count, and leave Field (RD) at its raw value because its node carries `fncOncePerFrame` (`src/sim_registry.nim:344-345`, `src/webgpu_compute.nim:899-900`). The observation that settles the multiplier: `w3-128k`'s raw per-pass figures sit within measurement spread of `w2-128k`'s while its per-frame total is about half again as large. A raw figure that instead scales with the substep count would mean timestamps are attaching on more than the first substep, contradicting `src/webgpu_compute.nim:895-898`; report that as a finding and absorb none of it.
- [ ] 3.6 `just happen` and `just check` green; `git status --porcelain` names nothing outside `scratchpad/`.

## 4. Bloom

Depends on group 2, whose `w1-128k` row is the bloom-off comparison. The old record left this
gate unsettled for want of a timestamp bucket (`docs/perf-report.md:66-70`).

- [ ] 4.1 RUN(`w1-bloom-128k`): `--n 128000 --bloom`, everything else at boot defaults. Touches `scratchpad/main/perf-harness/runs/w1-bloom-128k.json` only.
- [ ] 4.2 Settle the bloom question: the `bloom` field of the `[gpu-profile]` line in `runs/w1-bloom-128k.json` is above zero and the `bloom` field in `runs/w1-128k.json` is zero, since the span is written only when bloom is enabled (`src/gpu_profiler.nim:24-29`, `src/webgpu_render.nim:1850-1891`). Record bloom's cost as that figure, and record the bloom-on present figure beside the bloom-off one so the present-bucket shift the old record could not explain is visible as arithmetic. If the bloom bucket reads zero with bloom on, the span is not closing and that is a finding, not a zero cost.
- [ ] 4.3 `just happen` and `just check` green; `git status --porcelain` names nothing outside `scratchpad/`.

## 5. The crowd-density atomic traffic

Depends on group 2's `w1-128k` row, which is the comparison. This group is the only one that
edits a tracked file, and it reverts that file before it ends.

- [ ] 5.1 Confirm the checkpoint before editing: `git status --porcelain` names nothing under `web/`, and `just check` is green. Without both, do not proceed, since the revert in 5.5 has nothing clean to return to.
- [ ] 5.2 Confirm the comparison is valid by reading, not by assumption: `crowdingStrength` ships at 0 (`src/ui/state/simulation_state.nim:93`), its attenuation is 1 at that value (`src/ui/state/simulation_state.nim:22-24`), and `crowdDensity` is read nowhere outside `web/shaders/src/forces.wgsl:132,229` and written nowhere outside `web/shaders/src/integrate.wgsl:71-74`. Verify the last part with `grep -rn crowdDensity web/shaders/src/`. If any render shader reads it, the two builds are not the same world and this group stops.
- [ ] 5.3 In `web/shaders/src/forces.wgsl`, delete the `crowdDensityAccum` declaration at line 118, the `crowdDensityAccum += proximityWeight` and its `atomicAdd` at lines 312-314, and the closing `atomicAdd` at lines 385-386. Leave the binding at line 49 and every `crowdingAttenuation` call untouched, so no binding manifest moves. Then `just happen`, which must succeed, since `tests/test_wgsl_lint.nim` reads the bundled output and a removed binding would fail it.
- [ ] 5.4 RUN(`w1-nocrowd-128k`): `--n 128000`, no `--set` flags, against the variant build. Touches `scratchpad/main/perf-harness/runs/w1-nocrowd-128k.json` only. The crowd-density atomic cost is the physics figure of `w1-128k` minus the physics figure of this run, reported as a range across the two runs' settled samples.
- [ ] 5.5 Revert: `git checkout web/shaders/src/forces.wgsl`, then `just happen`. The observation that settles it: `git status --porcelain` prints nothing for any path under `web/`, and `just check` is green. If the tree cannot be returned clean, discard 5.4's number and record the atomic cost as unmeasured with this reason.

## 6. The record

Depends on groups 2 through 5. Every number is in hand before this group starts.

- [ ] 6.1 Rewrite `docs/perf-report.md` whole. It states: the machine, browser version, Nim version and commit; the serve and launch recipes as run; the 150-second window and the tail-of-run settle discipline with the reason it matters (physics cost tracks clustering); one row per run naming its four coupling strengths, its particle count, its substep count, and its per-pass min-max; both raw and per-frame figures for every fluid row; and the per-frame total against the 16.7 ms interactive budget with headroom stated.
- [ ] 6.2 In the same file, state the four instrumentation limits the numbers carry, each with its citation: timestamps attach on the first substep only (`src/webgpu_compute.nim:895-898`), the Field Force node carries `PROFILER_SLOT_NONE` and appears in no bucket (`src/sim_registry.nim:336-338`), the console line omits the field and the stats object omits bloom (`src/app.nim:57-58`, `src/web_api.nim:849-857`), and the reported physics figure sums `passPhysics` with `passIntegrate` (`src/app.nim:303-304`). Carry forward the headless-versus-windowed caveat.
- [ ] 6.3 State the crowd-density atomic cost from 5.4, or its absence and the reason from 5.5.
- [ ] 6.4 Verify the record names no world the app cannot run: `grep -n 'particle-life\|reaction-diffusion\|mode=' docs/perf-report.md` returns nothing, and every parameter id the record names appears in `gardenAPI.descriptor()`. Check the second part by evaluating `gardenAPI.descriptor().map(d => d.id)` in one short harness run and comparing against the ids the record uses.
- [ ] 6.5 If any measured configuration exceeds 16.7 ms, state the number, the configuration and the headroom as a finding, and name no remedy. The pass that costs too much is another change's subject.
- [ ] 6.6 Delete `scratchpad/main/perf-harness/profiles/` and keep `runs/` as the evidence the record cites. Then `just happen` and `just check` green, with `git status --porcelain` showing `docs/perf-report.md` as the only tracked modification.
