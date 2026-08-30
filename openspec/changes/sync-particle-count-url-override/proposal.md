## Why

The `?n=<count>` boot-time URL override writes `config.CONFIG.particleCount` directly
(`src/app.nim:328-329`) instead of going through `web_api.updateSimulation`, the single write path
`gardenapi-boundary` already requires every mutation to pass through
(`openspec/specs/gardenapi-boundary/spec.md`, "Every parameter write mirrors into CONFIG in the same
tick"). The override never touches `currentSimulation`, the stored state record
(`src/web_api.nim:81`). The next `setParam` call of any kind re-mirrors the whole stored record into
CONFIG (`applySimulationToConfig` at `src/web_api.nim:135-160`), and `currentSimulation.particleCount`
still holds the boot default from `initSimulationState()` (`src/ui/state/simulation_state.nim:87`,
16000), so that call silently overwrites the URL-requested count back to the default.

`gardenAPI.getParam("particleCount")` then answers the stale default while the simulation keeps
running at the requested count: a measurement run on commit `c1e0934` loaded `?n=128000`, issued
four `setParam` calls, and got `getParam("particleCount") = 16000` while every one of 60 `onStats`
samples reported `particleCount: 128000` and GPU physics time roughly eight times a 16000-particle
run's, consistent with 128000 particles actually simulating
(`scratchpad/main/perf-harness/runs/w0-128k.json`; a control run with no `setParam` calls,
`w1-128k.json`, reported the count correctly). The same clobbered CONFIG value would also feed a
particle reinit occurring after any `setParam` call: `initParticles` (`src/app.nim:98`) and
`resizeParticles` (`src/app.nim:138-139`) both read `config.CONFIG.particleCount`, so a reinit at
that point would rebuild the world at the default count rather than the one requested. No reinit
fired during the measurement run above, so this second consequence is reasoned from the code path,
not observed.

The defect surfaced during an unrelated measurement change and belongs in its own change rather than
folded into that one.

## What Changes

- Route the `?n=<count>` boot-time override through the same single write path every other
  simulation-state mutation uses, so `currentSimulation.particleCount` and
  `config.CONFIG.particleCount` never diverge regardless of what triggered the divergence.
- Extend `gardenapi-boundary`'s single-write-path requirement to name machine-interface writes that
  originate outside `gardenAPI` itself (the boot-time override today) as bound by the same
  invariant, closing the gap that let this one write bypass it.
- No change to the override's URL syntax, its clamp range (`1000` to `config.MAX_PARTICLES`), or its
  console-facing behavior: the fix is where the value lands, not what value is accepted.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `gardenapi-boundary`: the single-write-path requirement ("Every parameter write mirrors into
  CONFIG in the same tick") currently scopes its guarantee to `gardenAPI` mutations
  (`updateSimulation` / `updateRender` called from `setParam` and friends). It says nothing about a
  write that lands on CONFIG from outside `gardenAPI`, which is exactly how the boot-time `?n=`
  override currently reaches `config.CONFIG.particleCount`. The delta adds a requirement holding
  every write to a CONFIG field also mirrored from `SimulationState` or `RenderState` to the same
  path, whatever triggers it, so `currentSimulation` cannot go stale behind CONFIG's back.

## Impact

- `src/app.nim`: the `?n=` override in `init()` (`:328-329`) changes its write target.
- `src/web_api.nim`: `updateSimulation` (`:165-179`) gains a caller outside the `gardenAPI` object
  itself, or a narrow wrapper is added for that caller; either way `currentSimulation` and CONFIG
  stay in agreement.
- `gardenAPI.getParam("particleCount")` starts answering the URL-requested count after a `setParam`
  call, matching what the running simulation reports on `onStats`.
- The reasoned-not-observed reinit consequence (`initParticles`, `resizeParticles` reading
  `config.CONFIG.particleCount`) is closed by the same fix, since both read from a CONFIG that can
  no longer diverge from the stored state.
- `particleCount` is one of exactly three probe-exempt descriptor ids
  (`tests/test_response_probe.nim:72-83`); this change touches how its value is written, not its
  descriptor, its exemption, or the probe registry, so that test's assertion is unaffected.
