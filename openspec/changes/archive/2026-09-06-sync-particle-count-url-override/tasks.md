# Tasks

`web_api.nim` and the `?n=` override in `app.nim` compile only on the JS backend and import into no
native test (`src/web_api.nim:29-32`), so the "failing test" this change leads with is an
agent-driven run against the built app, not a native suite. Group 1 is that red step, watched
failing before any source changes; group 2 makes it pass; group 3 re-runs it green and closes the
reasoned-not-observed reinit consequence.

## 1. Watch the defect fail, before any source change

- [x] 1.1 Build and start the app (`just happen`, then run the binary per `docs/` run instructions),
      navigate to `?n=40000&seed=1` (any count away from the 16000 default), wait for
      `gardenAPI.isReady()`, then call `gardenAPI.setParam("friction", gardenAPI.getParam("friction"))`
      (any id other than `particleCount` — value unchanged, since only the write path matters).
      Confirm `gardenAPI.getParam("particleCount")` now answers `16000`, not `40000`. This is the
      expected red: Consequence A from `proposal.md`, reproduced live rather than only cited from
      `scratchpad/main/perf-harness/runs/w0-128k.json`.
- [x] 1.2 From the same session, call `gardenAPI.resetParticles()` and read the next
      `gardenAPI.onStats` sample's `particleCount`. Confirm it reports `16000`. This is Consequence
      B, previously reasoned from `src/app.nim:98, 138-139` but never observed; record whether it
      reproduces as reasoned before changing any code.

## 2. Route the override through the single write path

- [x] 2.1 In `src/app.nim`, replace the direct assignment at `:328-329`
      (`config.CONFIG.particleCount = clamp(requestedCount, 1000, config.MAX_PARTICLES)`) with a
      call to `web_api.updateSimulation` that writes the same clamped value into
      `simState.particleCount`, per `design.md` - Decisions. Keep the existing
      `clamp(requestedCount, 1000, config.MAX_PARTICLES)` floor-and-ceiling call; `updateSimulation`
      does not know the override's own `1000` floor.
      Files: `src/app.nim`.
- [x] 2.2 Confirm the call compiles with `web_api`'s existing export surface (`updateSimulation*`,
      `SimulationState` re-exported through `ui/state/sim_config`) and add no new import path beyond
      what `app.nim` already carries for `web_api`. Files: `src/app.nim`.
- [x] 2.3 `just happen` builds clean.

## 3. Confirm the fix, and close the reinit consequence

- [x] 3.1 Repeat task 1.1 against the rebuilt app: load `?n=40000&seed=1`, call `setParam` for any
      non-`particleCount` id, then confirm `gardenAPI.getParam("particleCount")` answers `40000`.
      Consequence A closed.
- [x] 3.2 Repeat task 1.2 against the rebuilt app: from the same session, call
      `gardenAPI.resetParticles()` and confirm the next `onStats` sample reports `particleCount:
      40000`. Consequence B closed and now observed, not only reasoned.
- [x] 3.3 Repeat 3.1-3.2 with the trigger swapped to a species-count commit
      (`gardenAPI.setParam("speciesCount", <n>)` then `gardenAPI.commitParam("speciesCount")`,
      per `src/web_api.nim:398-405`) in place of `resetParticles()`, confirming the particle count
      still reads `40000` after that reinit path too.
- [x] 3.4 `just check` passes, including `tests/test_response_probe.nim`'s "the exemptions are
      exactly the three declared ones" assertion (`:72-83`), confirming this change left
      `particleCount`'s probe exemption untouched.
