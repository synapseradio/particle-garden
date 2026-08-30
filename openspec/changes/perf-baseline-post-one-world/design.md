# Design: measuring the merged frame

## Context

See proposal.md, section Why. What shapes the approach here is that the app exposes no way to select
a world from outside itself. `src/app.nim:327-338` reads `n` and `seed` and nothing else, so
the coupling strengths that decide which nodes `buildFrame` emits (`src/sim_registry.nim:66-87`)
are reachable only through `window.gardenAPI.setParam` (`src/web_api.nim:1141-1142`) once the
page is live. Every configuration below therefore requires driving the page after load, which
the old method never had to do.

Three properties of the running system constrain the harness:

- **Proven.** Headless Chromium at `/Applications/Chromium.app` opens a DevTools endpoint on
  `--remote-debugging-port` and answers `/json/version` and `/json/list` over plain HTTP,
  reporting `Chrome/150.0.7871.46` and protocol 1.3. Verified by launching it against
  `about:blank` and reading both endpoints.
- **Proven.** `src/main.nim:70-77` serves `web/index.html`, `web/app.js`, `web/ui-bundle.*` and
  each `web/shaders/*.wgsl` at paths that are exactly their positions under `web/`, with the two
  cross-origin-isolation headers. A static server rooted at `web/` reproduces the same URL space.
- **Designed, unexercised.** That `Runtime.evaluate` can reach `window.gardenAPI` and that a
  `setParam` call lands in `CONFIG` before the next frame. `src/web_api.nim:1331` installs the
  object on the global, and `setParamImpl` writes the typed store synchronously, but no run has
  demonstrated it from outside the page. Task group 1 exercises it before anything is timed.

## Goals / Non-Goals

**Goals:**

- A per-configuration record of GPU pass times for the frame as composed today, with the
  substep multiplier applied and stated.
- A number for the `crowdDensity` atomic traffic, or an explicit statement that it stayed
  unmeasured and why.
- A record whose every row names a world reachable through the shipped controls.

**Non-Goals:**

- Repairing any instrumentation gap named in the proposal. The Field Force node stays unslotted,
  the console line stays field-less, and timestamps keep attaching on substep 0 only.
- Any judgment about whether a measured cost is acceptable, beyond stating headroom against the
  16.7 ms yardstick the old record used (`docs/perf-report.md:58`).
- CPU-side timing. The app performs no CPU physics and no readback.
- A windowed-Chromium cross-check. The old record flagged headless present-path timing as a
  caveat (`docs/perf-report.md:70,81`). The new record carries the same caveat and spends no
  run on it.

## Decisions

### D1: A throwaway static server in `scratchpad/`, not the app's own server

`./main` serves the right headers but also opens a window that loads the app and runs a second
simulation on the same GPU (`src/main.nim:96-103`), and closing that window ends `wait()` and
kills the server with it. Every timed run would then share the GPU with an untimed one.

Chosen: a Python `ThreadingHTTPServer` rooted at `web/`, adding
`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` to
every response, on a port the harness picks. This is what the old method used
(`docs/perf-report.md:12`), reconstructed, since the file it named is in no commit.

Rejected, run `./main` and point Chromium at 8089: the second simulation contaminates every
number, and there is no flag to suppress the window.
Rejected, serve `web/` with `python3 -m http.server`: no cross-origin isolation, so
`SharedArrayBuffer` is unavailable and `src/buffers.nim:41` cannot allocate.

### D2: Drive parameters over CDP, capture both channels there

A bun script opens the page target's `webSocketDebuggerUrl`, enables `Runtime`, subscribes to
`Runtime.consoleAPICalled` to collect `[gpu-profile]` lines, and evaluates a small expression
that registers a `gardenAPI.onStats` callback appending each stats object to a global array.
At the end of the window it evaluates one expression returning both collections as JSON.

Both channels are needed because neither is complete: the console line omits the field pass
(`src/app.nim:57-58`) and the stats object omits bloom (`src/web_api.nim:849-857`).

Rejected, scrape `--enable-logging=stderr` for console lines, as the old method did
(`docs/perf-report.md:13`): it reaches only one of the two channels, and it cannot set a
parameter at all.
Rejected, seed `localStorage` with a preset so the app boots into a configuration: writing
`localStorage` before first load itself needs CDP, so this buys nothing and adds a dependency
on the preset schema.
Rejected, screenshot the panel and read the numbers: unusable for a settled range across a
150 second window.

`bun` is on PATH and already owns `web-ui/`; its built-in `WebSocket` needs no dependency, so
the harness installs nothing.

### D3: The parameters the harness sets are only the ones that deviate from boot defaults

The shipped state is `particleCount 16000`, `forceStrength 1.0`, `crowdingStrength 0.0`,
`fluidStrength 0.0`, `rdDeposit RD_DEFAULT_DEPOSIT`, `rdFieldForce RD_DEFAULT_FIELD_FORCE`
(`src/ui/state/simulation_state.nim:87-122`), with `sphSubsteps 2` (`:118`), `trails false`
and `bloomEnabled BLOOM_DEFAULT_ENABLED`, which is `false`
(`src/ui/state/render_state.nim:74,81`; `src/bloom_core.nim:38`).

The harness names no numeric default of its own. Where a configuration wants a default, it
sets nothing; where it wants a bound, it reads the bound from `gardenAPI.descriptor()`
(`src/web_api.nim:1131`, which carries `min` and `max` per id at `src/web_api.nim:211-212`).
Nim keeps owning every number, and a later range change moves the measured world with it
instead of leaving the harness stale.

### D4: Four coupling configurations across two particle counts

| id | forceStrength | fluidStrength | rdDeposit | rdFieldForce | n |
|---|---|---|---|---|---|
| W0 floor | 0 | 0 | 0 | 0 | 16000, 128000 |
| W1 shipped | default | 0 | default | default | 16000, 128000 |
| W2 fluid | default | descriptor max | default | default | 16000, 128000 |
| W3 substep ceiling | default | descriptor max | default | default | 128000 |
| W1-bloom | default | 0 | default | default | 128000 |
| W1-nocrowd | default | 0 | default | default | 128000 |

W3 differs from W2 in one setting: `sphSubsteps` at `SPH_MAX_SUBSTEPS`, which is 3
(`src/sph_core.nim:34`), against W2's shipped 2. W1-bloom differs from W1 at n=128000 in
`setBloom(true)` alone (`src/web_api.nim:1168`). W1-nocrowd differs in the build, not the
settings. See D5.

What each answers:

- **W0** is the intrinsic floor. `buildFrame` with every strength at zero still emits six
  buffer clears, Grid Build, the offsets-to-pointers copy, a Physics pass carrying `binScatter`
  and `forces`, a Field (RD) pass carrying `fieldResolve` plus 7 Gray-Scott steps
  (`RD_STEPS_PER_FRAME = 7`, `src/field_core.nim:95`), and Integrate
  (`src/sim_registry.nim:255-351`). This is what a world costs before a single coupling acts,
  and it is the number every future proposal should be held against.
- **W1** is what the app costs as it boots: forces plus chemistry. Against W0 it isolates
  `fieldDeposit` entering the Field pass and the Field Force node entering the frame. That node
  carries no slot, so its cost shows only in the difference between the two totals and never
  in a bucket.
- **W2** adds `forcesSph` to the Physics pass and simultaneously flips `substepCount` from 1 to
  2 (`src/webgpu_compute.nim:717-719`). Its raw numbers are one substep's worth. The record
  reports both the raw per-pass figure and the per-frame figure, which is the raw figure times
  `substepCount` for every node except Field (RD), which carries `fncOncePerFrame`
  (`src/sim_registry.nim:344-345`).
- **W3** raises `sphSubsteps` to its ceiling with nothing else changed, so W3 against W2
  separates the substep multiplier from `forcesSph`'s own per-substep cost: the raw per-pass
  numbers should barely move while the per-frame total rises by half.
- **W1-bloom** settles the gate the old record could not (`docs/perf-report.md:66-70`). The
  `passBloom` span now covers glow-HDR through blur-V (`src/gpu_profiler.nim:24-29`), so
  bloom's cost appears as a number instead of as an unexplained drop in the present bucket.

Rejected, a run at every combination of the four strengths: sixteen worlds at two scales is
the enumeration `buildFrame` exists to refuse, and the four above already bracket the frame.
Rejected, an intermediate `fluidStrength`: the coupling scales a velocity contribution
(`src/sim_registry.nim:76-78`), it does not change which passes run, so a mid value costs what
the max costs and answers less.

### D5: Isolate the crowd-density atomics with a temporary shader variant

No runtime control removes that traffic. `web/shaders/src/forces.wgsl:312-314` and `:385-386`
call `atomicAdd` on `crowdDensityDeltaFixed` unconditionally, inside and after the neighbour
loop; `crowdingStrength` scales only the attenuation those values feed
(`web/shaders/src/forces.wgsl:132,229`). Setting `crowdingStrength` to zero changes what the
number is used for and not whether it is computed.

At `crowdingStrength = 0` the two builds are physically identical. The attenuation is
`1 / (1 + crowdingStrength * ln(1 + density))` (`src/ui/state/simulation_state.nim:22-24`),
which is exactly 1 at zero, and `crowdingStrength` ships at 0
(`src/ui/state/simulation_state.nim:93`). `crowdDensity` reaches nothing else: it is read in
`web/shaders/src/forces.wgsl` for that attenuation and written in
`web/shaders/src/integrate.wgsl:71-74`, and no render shader reads it. Dot size, brightness and
glow radius read the colony `density` channel instead (`src/memory_layout.nim:57-58`).

So the variant is: delete the accumulator and the two `atomicAdd` calls from
`web/shaders/src/forces.wgsl`, rebuild, run W1 at n=128000, and difference the Physics bucket
against the unmodified W1 n=128000 run. Same world, same trajectory, one less atomic stream.
The buffer, its binding and `integrate.wgsl` all stay as they are, so no binding manifest moves
and `wgsl_lint` has nothing to react to.

Rejected, a compile-time flag in the shader bundler for the same effect: a permanent knob in
`tools/wgsl_bundle.nim` to answer one question once.
Rejected, leave the number open: it is the one cost this change exists to find, and the
comparison is exact, where every alternative is inferential.
Rejected, infer it from W0, whose Physics bucket contains the same atomics: W0 gives the
combined cost of the neighbour sweep, not the atomics' share of it.

### D6: Rewrite `docs/perf-report.md` in place

The sibling report `docs/control-legibility-report.md` is one file rewritten over itself
(`docs/control-legibility-report.md:2`), and keeps no superseded copy. A second performance file
marked superseded would be the only artifact of its kind in that tree, and would keep the three
dead mode ids on disk, which is the condition this change exists to end. `git log --follow --
docs/perf-report.md` keeps the old content reachable.

## Risks / Trade-offs

- **`Runtime.evaluate` cannot reach `gardenAPI`, or `setParam` does not take effect before the
  measured window** → Task group 1 is the gate: set one parameter, read it back through
  `getParam` (`src/web_api.nim:1140`), and stop the change if the value does not match. No
  timed run happens before that check passes.
- **A parameter set mid-run resets the world and restarts settling** → each configuration is
  set immediately after `gardenAPI.onReady` fires (`src/web_api.nim:1126`) and before the settle
  window starts, so the whole window observes one world. `particleCount` is set through the
  `?n=` URL parameter, not through `setParam`, because it is a reinit-on-commit parameter.
- **The shader variant is left in the tree** → the variant group's last task reverts
  `web/shaders/src/forces.wgsl` with `git checkout`, rebuilds, and requires
  `git status --porcelain` to print nothing for that path plus `just check` green. If the tree
  cannot be returned clean, the measurement is discarded and the record states the atomic cost
  as unmeasured.
- **W2 and W3 numbers are misread as per-frame** → every fluid row in the record carries its
  `substepCount` in the row, and both the raw and the multiplied figure.
- **Headless present-path timing differs from the window a user sees** → carried forward as a
  caveat, unchanged from the old record (`docs/perf-report.md:81`). The compute buckets, which
  are what the couplings move, are unaffected by the compositor.
- **A run does not settle inside its window** → the old record hit this at n=16000, where the
  physics trace climbed for the full 145 seconds without plateauing (`docs/perf-report.md:56`).
  Each run's full trace is retained, and the record states for each row whether the trace
  flattened inside the window. A row that did not flatten is labelled unsettled, never reported
  as converged.
