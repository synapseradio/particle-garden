## 1. Correct the two false comments

- [ ] 1.1 Read `src/preset.nim:243-248` and confirm `sphRadiusFraction: 1.0` is the shipped default,
      matching `src/ui/state/simulation_state.nim:116`; the check is that both literals read `1.0`
- [ ] 1.2 Rewrite the comment at `src/preset.nim:244-247` so it states what the code does: the
      shipped default is the whole interaction radius, and the v1 branch pins `1.0` because that is
      the kernel a v1 fluid ran. Remove the claim that the default sits below 1 and the reference to
      a superseded change. Verify no sentence beside the field contradicts `:248`
- [ ] 1.3 Rewrite the comment at `src/preset.nim:639-644` the same way: drop "not the shipped
      default, which sits below 1", keep the pinning rationale, which stands on its own. Verify by
      reading `:645` against the new comment
- [ ] 1.4 `just happen` builds and `just check` is green; `grep -n 'below 1' src/preset.nim` returns
      nothing

## 2. Build and prove the measurement rig

The rig is designed and unexercised. Nothing after this group means anything until 2.5 passes.

- [ ] 2.1 Build and start the app: `just happen`, then `./main` in the background. Confirm
      `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8089/` returns 200. Touches no source
      file
- [ ] 2.2 Launch a visible Chrome window with `--remote-debugging-port=9222` at
      `http://127.0.0.1:8089`, and confirm through the DevTools Protocol that
      `Runtime.evaluate` on `typeof window.gardenAPI` returns `"object"` and that
      `gardenAPI.isReady()` becomes true. A hidden or minimized window throttles
      `requestAnimationFrame`, so leave it visible. Touches no source file
- [ ] 2.3 Write the run script under `scratchpad/main/` (throwaway, not shipped): it applies a
      preset JSON, calls `resetParticles()`, accumulates the world clock as
      `min(rawDt, 0.05) * timeScale` in a `requestAnimationFrame` hook mirroring
      `src/app.nim:240-241`, records mean frame rate from `gardenAPI.onStats`, captures the canvas
      through `Page.captureScreenshot` clipped to its bounding box at named world-time marks, and
      reduces each capture to a lit fraction at luminance threshold `16/255`. Every bound it needs
      comes from `gardenAPI.descriptor()`, never a restated constant. Verify by capturing one frame
      of the shipped world and reading a lit fraction strictly between 0.01 and 0.35
- [ ] 2.4 Build fixture C by calling `gardenAPI.exportPresetJsonPretty` on a fresh session and
      editing the parsed JSON per `design.md` decision 3: `speciesCount` at `SPECIES_COUNT_MIN`,
      every matrix entry at `MATRIX_MAX_VALUE`, fluid off, field off, and the confound suppressions.
      Verify by applying it and reading every edited field back through `gardenAPI.getParam`
- [ ] 2.5 **The red step.** Run fixture C at crowding strength zero and confirm the world collapses:
      `L(90) <= L(2) / 3`. This is the failing observation the whole change exists to bound. If it
      does not collapse, the fixture is wrong and 2.4 repeats; nothing below runs until it holds.
      Record the run in `scratchpad/main/calibrate-shipped-defaults__<DD-MM-YY-HHmm>.md`
- [ ] 2.6 Build fixture D: export a fresh session after one `randomizeMatrix()` at the shipped
      `ruleWildness`, apply the same suppressions, and pin that exported matrix for every later run.
      Verify by applying it twice and confirming `gardenAPI.matrix()` reads identically both times
- [ ] 2.7 `just happen` builds and `just check` is green; no file under `src/`, `web/`, `web-ui/` or
      `tests/` changed in this group

## 3. Calibrate the crowding ceiling

Budget about two hours of wall clock. Runs are sequential: one app instance, one GPU.

- [ ] 3.1 Sweep fixture C over `gardenAPI.paramValueAt('crowdingStrength', p)` for `p` in 0.0, 0.2,
      0.4, 0.6, 0.8, 1.0, two repeats each, capturing at world-time 2 s, 20 s and 90 s. Reject and
      re-run any run whose mean frame rate falls below 30, halving the fixture's particle count and
      recording that as a condition. Append every run to the scratchpad record. Touches no source
      file
- [ ] 3.2 Sweep fixture D the same way. Touches no source file
- [ ] 3.3 Locate `c_hold` from the fixture C rows: the smallest value whose mean `L(90)` reaches
      `0.9 × ` its own mean `L(20)`. Bisect three times between the bracketing sweep values, three
      repeats per point. If no swept value qualifies, double `CROWDING_STRENGTH_MAX` in
      `src/config_ranges.nim:46`, rebuild with `just happen`, and re-run 3.1 over the widened range
      before continuing. The observation that settles it: two consecutive bisection points agreeing
      on which side of the criterion they fall, outside the repeat spread
- [ ] 3.4 Locate `c_soften` from the fixture D rows: the smallest value whose mean `L(90)` exceeds
      the crowding-zero mean `L(90)` by more than 25% and by more than three standard deviations of
      the crowding-zero repeats. Bisect the same way. Same settling observation
- [ ] 3.5 Set `CROWDING_STRENGTH_MAX` in `src/config_ranges.nim:46` to the smallest value
      representable at the control's step reaching `1.5 × c_soften`. Replace the PROVISIONAL comment
      at `:47-54` with the record: `c_hold`, `c_soften`, the margin, both fixtures, particle count,
      interaction radius, time scale, the matrix bounds, fluid and field settings, canvas
      dimensions, and the settling window. Keep it to the few lines `CLAUDE.md` allows, and carry no
      `[?]`. Verify with `just happen`, whose static assertions reject an empty range or an
      out-of-range default, then `nim c -r tests/test_physics.nim`, whose ceiling sweep re-scopes
      itself from the new bound
- [ ] 3.6 Re-run the fixture C sweep at the new `CROWDING_STRENGTH_MAX` and confirm `c_hold` and
      `c_soften` land where the record says, inside the recorded repeat spread. This is the
      agent-checkable procedure the delta spec names, run once against its own record
- [ ] 3.7 `just happen` builds and `just check` is green

## 4. Calibrate the SPH radius fraction floor

- [ ] 4.1 **The red step.** Build fixture F per `design.md` decision 4 by export and edit: fluid at
      full strength, `forceStrength` 0, `crowdingStrength` 0, `interactionRadius` at
      `INTERACTION_RADIUS_MIN`, fraction at the current `SPH_RADIUS_FRACTION_MIN` of 0.1, plus the
      confound suppressions. Capture at world-time 60 s, and capture the null with `fluidStrength`
      0. Confirm the two lit fractions agree within three standard deviations of the null repeats:
      the fluid computes nothing at the bottom of its own slider. Record it. Touches no source file
- [ ] 4.2 Sweep the fraction at slider travel 0.0, 0.2, 0.4, 0.6, 0.8, 1.0, at
      `INTERACTION_RADIUS_MIN` and at the shipped interaction radius, three repeats each, with the
      null at each radius. Bisect three times around the boundary the coarse pass brackets. Append
      every run to the scratchpad record. Touches no source file
- [ ] 4.3 Read `f_inert` off the minimum-radius rows: the largest fraction whose mean `L(60)` is
      within three standard deviations of the null. Compare it against the prediction in `design.md`
      decision 4, near 0.2, and record any disagreement as a finding about the reasoning behind that
      prediction
- [ ] 4.4 Set `SPH_RADIUS_FRACTION_MIN` in `src/config_ranges.nim:150` to the smallest value
      representable at the control's step reaching `1.5 × f_inert`. Replace the PROVISIONAL wording
      at `:151-179` with the record: `f_inert`, the margin, the fixture, both interaction radii, the
      fluid settings, canvas dimensions, and the settling window. Keep the strictly-positive
      reasoning, which stands. Carry no `[?]`. Verify with `just happen`, then
      `nim c -r tests/test_param_descriptor.nim`, whose notch sweep re-scopes from the new floor,
      and `nim c -r tests/test_sph_core.nim`
- [ ] 4.5 Re-run 4.1 at the new floor and confirm the fluid now acts: the lit fraction differs from
      the null by more than three standard deviations. This is the agent-checkable procedure the
      delta spec names, run once against its own record
- [ ] 4.6 `just happen` builds and `just check` is green

## 5. Calibrate the force weather waypoints and speed

- [ ] 5.1 Build fixture W per `design.md` decision 5 by export and edit, with the matrix pinned as
      fixture D pins it. Verify by applying it and reading the three toured parameters back. Touches
      no source file
- [ ] 5.2 **The red step.** With the weather off, write each of the five `FORCE_WEATHER_WAYPOINTS`
      triples through `setParam` and `commitParam`, `resetParticles()`, settle 60 world-seconds,
      capture, three repeats each. Confirm at least one adjacent pair produces lit fractions
      agreeing within three standard deviations, which is the tour travelling between two worlds a
      viewer cannot tell apart. Record all five. If every pair already separates, record that and
      skip 5.3. Touches no source file
- [ ] 5.3 Replace each failing coordinate with another triple inside `FORCE_STRENGTH_MIN/MAX`,
      `INTERACTION_RADIUS_MIN/MAX` and `FRICTION_MIN/MAX`, moving at least two axes from both
      neighbours, and re-measure until all five separate. Write the surviving table into
      `src/config_ranges.nim:75-90` and replace the PROVISIONAL paragraph at `:81-90` with one line
      per waypoint naming what it produces. Verify with `just happen`, whose static assertion at
      `:493-510` rejects a coordinate outside its own slider, then
      `nim c -r tests/test_climate_core.nim`, whose per-frame step sweep at maximum speed rejects a
      segment the tour cannot carry
- [ ] 5.4 Measure the settling time of each segment: settle at waypoint `i` for 60 world-seconds,
      commit waypoint `i+1`'s three values, capture every 2 world-seconds for 60 world-seconds, and
      take `T_settle(i)` as the earliest world-time after which the lit fraction stays within 5% of
      its end-of-window value. Five segments, three repeats each. Touches no source file
- [ ] 5.5 Derive the default speed: the largest value representable at the control's step satisfying
      `60 / (5 * speed) >= max_i T_settle(i) / timeScale_default`. If it falls below
      `FORCE_WEATHER_SPEED_MIN`, stop, leave the constant alone, and report the measured settling
      times as a finding about the tour's length; the range is not narrowed and no value is written
      outside it
- [ ] 5.6 Write the derived speed into `FORCE_WEATHER_DEFAULT_SPEED` at `src/climate_core.nim:177`
      and the mirrored literal at `src/preset.nim:265`. Replace the `[?]` comment at
      `src/climate_core.nim:178-182` with the record: each segment's settling time, the time scale
      the conversion used, and the resulting dwell margin. Verify red-then-green by editing
      `src/climate_core.nim` alone first and running `nim c -r tests/test_preset.nim`, which must
      fail at the mirror assertion (`:43`), then editing `src/preset.nim` and confirming it passes
- [ ] 5.7 Run one full tour with `gardenAPI.setForceWeather(true)` at the new default speed,
      capturing every 5 wall seconds for the tour's full period, and confirm the lit fraction visits
      five distinguishable plateaus. This is the agent-checkable procedure the delta spec names
- [ ] 5.8 `just happen` builds and `just check` is green

## 6. Close the records

- [ ] 6.1 Read `src/config_ranges.nim:42-90` and `:150-181` and `src/climate_core.nim:177-182` and
      confirm no `[?]`, no "PROVISIONAL", and no "working bound" remains on the three calibrated
      constants, and that each carries its measured value, conditions and margin
- [ ] 6.2 Read `docs/help/10-simulation.md:24-26`, `docs/help/12-species.md:14-16` and
      `docs/help/30-fluid.md:15-17` and confirm each still states what the code does after the
      calibration. Edit only a sentence the measurement made false; the help carries no numerals
      from these three constants today
- [ ] 6.3 If the open question in `proposal.md` resolved to a nonzero crowding default, set it at
      `src/ui/state/simulation_state.nim:93`, run `nim c -r tests/test_preset.nim` and confirm it
      fails at the total-relation walk, then mirror it at `src/preset.nim:220` and confirm it
      passes, and rewrite the scenario "A fresh world carries no crowding" in
      `specs/bounded-crowding/spec.md`. If it resolved to zero, this task is a no-op and says so
- [ ] 6.4 `openspec validate calibrate-shipped-defaults --strict` reports the change valid
- [ ] 6.5 `just happen` builds and `just check` is green on a clean tree
