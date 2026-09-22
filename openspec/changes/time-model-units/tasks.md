# Tasks

Groups 2 (oracle), 4 (field), 5 (help) and 6 (trail fade) may run in parallel, each in its own worktree.
Group 3 (GPU) runs after group 2, because it mirrors group 2's clock. Groups 3 and 4 both touch
`src/webgpu_compute.nim` and `src/sim_registry.nim`, and groups 2 and 6 both touch
`src/ui/api/response_probe.nim`, each in the disjoint regions its task names. The second to merge rebases
onto the first. Every spike and run record goes to
`~/.scratchpad/particle-garden/tm-units/`, never into the tree. No run in this change uses 128 000
particles while the machine is shared.

## 1. Preconditions and measurement gates

- [x] 1.1 **Precondition.** `cfi-crowding` (friction per reference frame, the 0.12 default, the step limit
  on the whole velocity) and `cfi-crowding-gpu` (the same on the GPU) are merged to `dev`, and this change
  sits on that `dev`. The rebases rewrote the branch SHAs: on `dev` they are `4fc1543`…`6f92d12` and
  `03247ec`…`e7118bc`. Verify that `git merge-base --is-ancestor 6f92d12 HEAD` and
  `git merge-base --is-ancestor e7118bc HEAD` both exit 0. No other task starts before this one.
- [ ] 1.2 **S15, the shipped map across frame factors** (design.md, Spikes). Build the D1 map with `h`,
  D4's `B` with the species slope, and D5's loop term. Build them in the spike harness
  `~/.scratchpad/particle-garden/cfi-crowding/spike-s7/`, copied into
  `~/.scratchpad/particle-garden/tm-units/spike-s15/`. Run the prediction as written, at 16 000
  particles. Record the readings against the prediction in `spike-s15/result.md`.
  - Kill reached: stop and return D4's `B` to the design. Group 2's green waits.
- [ ] 1.3 **S14, the ff-0.42 residual** (design.md, Spikes). Run the prediction as written (dated 17:25,
  22-09-2026) on S15's harness, and record it in `spike-s14/result.md`.
  - The ratio converges as ff falls: record that the ff-1 reference is the stepper's. Return
    `core-force-interface` 4.5's "no warmer than ff 1" criterion below ff 1 to the user, with the numbers.
  - Kill reached: record the residual as open. Group 2 proceeds.
- [x] 1.4 **S16, the fluid under D1** (design.md, Spikes). Record in `spike-s16/result.md`.
  - Kill reached: the fluid's pressure slope joins `D` in task 2.3 before group 3 starts.
  - Result: kill reached. ff 10 holds, while ff 12 reads p99 about 1690× ff 1's 3× bound, near the cap
    through ff 30, with no NaN (`spike-s16/s16_boundary.log`). The fluid slope moves into task 2.3.
- [ ] 1.5 **S13, the field on world time** (design.md, Spikes). Record in `spike-s13/result.md`.
  - Kill reached: the deposit fold moves to per field step in task 4.2, with its own red test first.
- [x] 1.6 `just happen` and `just check` green on the rebased branch before any tree change.

## 2. Oracle and integrate (Sonnet, own worktree)

Files: `src/physics_core.nim`, `src/balance_core.nim`, `src/config_ranges.nim`,
`src/ui/api/response_probe.nim`, `tests/test_physics.nim`, `tests/test_balance_core.nim`.

- [ ] 2.1 **Red, unit grain, in `tests/test_physics.nim`**, in design.md's writing order, tests 1–12.
  Write them against stubs that compile: `stepClock` returning the landed map's values (`ρ = r^ff`,
  `h = ff`), `speciesRestoringSlope` returning 0, and `loopGainBound` returning 0.009. Each then fails on a
  value, not a missing symbol. The amended suite "Friction Acts Per Reference Frame"
  (`tests/test_physics.nim:530`) keeps its test "ten steps at ff 1 and one step at ff 10 lose the same
  fraction of speed". Run
  `nim c -r` with the `quality_flags` from the `justfile` on `tests/test_physics.nim`, and verify each new
  test fails for the reason its row names.
- [ ] 2.2 **Red, oracle grain, in `tests/test_balance_core.nim`**: test 13 (T5f), test 14, and test 21
  (T7s, integration, 2 000 particles, under the `calibrateBalance` define). Verify each fails for its
  stated reason.
- [ ] 2.3 **Green.**
  - `src/physics_core.nim`:
    - `StepClock` with its three cases and `stepClock(ff, retention)`. It rejects retention outside
      `[0.5, 1]` in the test build.
    - `integrateVelocity` takes the clock, forms `u' = s·(ρ·u + h·Δ)`, and caps `u` directly. The
      `perFrame` lines `:428-434` go.
    - `stepLimit(clock, D, θ)` returns `min(1, B/(2·ff·h·D))` with `B = θ·r·(1 + ρ)/(1 + r)`.
    - `speciesRestoringSlope`, analytic for `polynomialForce` and `exponentialForce` (`:287-321`),
      positive part only.
    - `loopGainBound(ρ, α)` bisects the three-state map's spectral radius. `loopLimit` implements D5's
      `s_C`.
  - `src/balance_core.nim`:
    - `sweepPairs` (`:422`) adds each particle's receiving species slope to its `D` words, and
      accumulates `C` in two more words.
    - `integrateParticles` (`:682`) steps through the clock, smooths with `densitySmoothFactor^ff`
      (`:688`), moves by `ff·u`, and applies `min(s_D, s_C)` to the whole velocity.
  - `src/config_ranges.nim`:
    - Add `LOOP_LIMIT_FLOOR* = 0.1`, with its condition in two lines: 0 violations of 5 643 on retention
      0.5–1, ff 0.2–30, `C` 1e-5–1e2 (`lagmodel8`).
    - `PRESSURE_STEP_BOUND`'s comment (`:681`) states that the bound keeps ff 1's share of the step's
      linear bound at every ff.
  - `src/ui/api/response_probe.nim`: `timeScaleProbe`'s doc (`:205-213`) drops "integrate.wgsl
    advances pos += vel with no dt". The position now carries the frame factor.

  Verify every test from 2.1 and 2.2 passes.
- [ ] 2.4 `just happen` and `just check` green.

## 3. GPU integrate, forces, render and glow (Sonnet, own worktree; after group 2)

Files:
- `web/shaders/src/integrate.wgsl` and `web/shaders/src/forces.wgsl`
- `src/gpu_types.nim`, `src/shader_config.nim` and `src/webgpu_init.nim` (`:174`, `:390`)
- `src/webgpu_compute.nim`, the integration-uniform block beside `:1064-1080` only
- `src/sim_registry.nim`, a new `integrationUniforms` producer only
- `tests/test_gpu_types.nim` and `tests/test_sim_registry.nim`

- [ ] 3.1 **Red.**
  - `tests/test_gpu_types.nim`: test 16, "IntegrationParams Holds Twelve Floats With The Clock's Fields".
  - `tests/test_sim_registry.nim`: test 15, "The Integration Uniforms Come From One Clock", against a
    stub producer that writes `h = ff`.
  - Verify both fail on values.
- [ ] 3.2 **Green.**
  - `src/gpu_types.nim`: IntegrationParams gains h, B, α, θ_c and the floor `λ·min(1, 1/ff)` in the two
    pads and three new slots. `INTEG_PARAMS_F32_COUNT` becomes 12.
  - `src/sim_registry.nim`: `integrationUniforms(ff, retention)` builds the block from `stepClock` and
    `loopGainBound`. `src/webgpu_compute.nim` writes it in place of `:1070-1079`.
  - `web/shaders/src/integrate.wgsl`:
    - Decode the delta without `frameFactor` (`:64`, `:67`), and smooth with `densityCarry`
      (`:72`, `:82-83`).
    - Form `s_D` from `B` and `h` (`:93-94`), and `s_C` from `C`, θ_c and the floor.
    - Compute `newVel = s·(ρ·vel + h·Δ)` (`:110-111`) and cap it directly. `perFrame`, `:123`, goes.
    - Move by `frameFactor · newVel` (`:138-139`).
  - `web/shaders/src/forces.wgsl`:
    - Add the species restoring slope to the stiffness words for the receiving particle.
    - Accumulate `C` in two more words. The stride goes from 3 to 5 at `:46` and every `* 3u` site
      (`:384-491`), and `src/webgpu_init.nim:174` and `:390` follow.
  - `src/shader_config.nim`: `LOOP_LIMIT_FLOOR` reaches the shader by placeholder, if the shader forms the
    floor.
  - `web/shaders/src/render.wgsl:91-97` and `web/shaders/src/glow.wgsl:89-90` keep their formulas. Verify
    they read `p.vel` against `maxVelocity`, with no frame factor.

  Verify 3.1's tests pass.
- [ ] 3.3 **S12, verification in-app at 16 000** (design.md, Spikes). Follow the in-app procedure in
  `CLAUDE.md` (`./main --serve`, a new Claude in Chrome tab, `window.gardenAPI` through
  `javascript_tool`). Read `[gpu-profile]` over 30 s before (the parent commit) and after, at Time Scale
  0.5 and 5 on the 143 Hz display. Read `error|validation` for GPU errors, of which there must be none.
  Hold a frame past 0.05 s at Time Scale 5 and read that streaks keep their length (the time-model spec's
  streak requirement). Record in `~/.scratchpad/particle-garden/tm-units/s12-cost__<DD-MM-YY-HHmm>.md`.
  - Kill reached: stop and return the numbers.
- [ ] 3.4 `just happen` and `just check` green.

## 4. Field clock (Sonnet, own worktree; parallel with group 2)

Files:
- `src/field_core.nim`
- `src/sim_registry.nim`, the frame builder's field block `:425-460` and the doc at `:313-318` only
- `src/webgpu_compute.nim`, the rebuild at `:262-280`, the chain comment at `:516-519`, and the deposit
  fold at `:1097-1098` only
- `tests/test_field_core.nim` and `tests/test_sim_registry.nim`

- [ ] 4.1 **Red.**
  - `tests/test_field_core.nim`: tests 17–19, against a stub `advanceFieldClock` returning today's
    `rdStepsForTimeScale` count and carry 0.
  - `tests/test_sim_registry.nim`: test 20.
  - Verify each fails for its stated reason: test 17 fails at 143 Hz with 10 003 steps, not 4 200.
- [ ] 4.2 **Green.**
  - `src/field_core.nim`:
    - Add `FieldSteps` (an odd int in `[1, FIELD_STEPS_CEILING]`, smart constructor only), `FieldClock`,
      and `advanceFieldClock(clock, ff)` per D6.
    - Rename `RD_STEPS_PER_FRAME` to `FIELD_STEPS_PER_REFERENCE_FRAME` (7) and add
      `FIELD_STEPS_CEILING* = 71` (today's Time Scale 5 count). The parity `doAssert` (`:276`) moves to
      the ceiling.
    - `rdStepsForTimeScale` (`:188-201`) goes. `RD_REFERENCE_TIME_SCALE`'s doc becomes "the Time Scale at
      which a 60 Hz frame spans one reference frame", keeping its readers
      (`tests/test_response_probe.nim:26`, `:281-285`; `tests/test_param_descriptor.nim:886`).
  - `tests/test_field_core.nim`: "the shipped Time Scale runs the shipped step count" (`:1961`) and "the
    step count is always odd" (`:1965`) are replaced by 4.1's tests.
  - `src/sim_registry.nim`: the frame builder takes `FieldSteps`.
  - `src/webgpu_compute.nim`:
    - Hold a `FieldClock`, advance it once per rendered frame by the frame's frame factor, and cache frame
      descriptions per count.
    - The deposit fold reads the frame's count (`:1097-1098`).

  Verify 4.1's tests pass, and that S13's recorded result (1.5) is consistent with the build.
- [ ] 4.3 `just happen` and `just check` green.

## 5. Help (Sonnet, own worktree; parallel with groups 2 and 4)

Files: `docs/help/10-simulation.md`, `docs/help/40-rd.md`, `docs/help/50-render.md`,
`docs/help/51-glow.md`. Anchors are on `cfi-crowding`, and `40-rd.md` on `dev`.

- [ ] 5.1 Replace the lines below. `tests/test_help_content.nim` ("every descriptor is named by its group's
  file", `:53`) holds each id's presence. No test holds the wording, which 5.2 checks.
  - `10-simulation.md:26-30`, `timeScale`: "how much world time passes per second of play. Raising it
    speeds everything up at once, including the field's growth, and the same setting runs the same on any
    display." The Interacts line reads "the field (more steps a second, more cost)" in place of "the
    field (more steps, more cost)".
  - `10-simulation.md:31-32`, `maxVelocity`: "a soft cap on how far any particle may travel per 1/120 s
    of world time." The rest of the entry stands.
  - `40-rd.md:21-22`: "Time Scale (field steps per second of play)" in place of "Time Scale (field steps
    per frame)".
  - `51-glow.md:12-15`, `velocityGlowScale`: "how much speed, measured per 1/120 s of world time,
    brightens a particle and grows its halo, so movers stand out from sitters and swell as they go."
  - `10-simulation.md:20-25`, `friction`: unchanged. It already states the per-1/120 s meaning.
  - `trailLength` (`50-render.md:12-16`) belongs to group 6.
- [ ] 5.2 Read each changed entry in-app through `?` (the help panel) on `./main --serve`. Each must read
  as 5.1 states, with no stale "per frame" wording for these four controls and the field's note.
- [ ] 5.3 `just happen` and `just check` green.

## 6. Trail fade (Sonnet, own worktree; parallel with groups 2, 4 and 5)

Files:
- `src/trail_core.nim` and `tests/test_trail_core.nim`
- `src/webgpu_render.nim`, `render`'s signature (`:1415`) and the fade write at `:1483-1488` only
- `src/app.nim`, the `render` call at `:281` only
- `src/ui/api/response_probe.nim`, `trailPersistenceProbe` (`:622-627`) only
- `docs/help/50-render.md:12-16` and `tests/README.md` (`:76`, `:125`)

It reads `physics_core.frameFactor` (`src/physics_core.nim:37-43`), which group 2 leaves as it is.

- [ ] 6.1 **Red, in `tests/test_trail_core.nim`**, design.md's tests 22–24, against a stub
  `frameFadeFor(trailLength, frameFactor)` that returns `fadeAmountFor(trailLength)`, today's per-frame
  value. Run `nim c -r` with the `quality_flags` from the `justfile` on the suite. Verify test 22 fails on
  sequences whose frame factors are not all 1, and test 24 at ff 0. Test 23 guards the branch order and
  passes against this stub: verify it red once against the body `pow(fadeAmountFor(trailLength),
  frameFactor)`, where it fails at ff 0.
- [ ] 6.2 **Green.**
  - `src/trail_core.nim`:
    - Add `func frameFadeFor*(trailLength, frameFactor: float): float` per D8, with the length branch
      ahead of the power.
    - `TRAIL_FRAMES_PER_DIAMETER`'s doc reads "Reference frames a typical particle takes to cross one of its
      own diameters", with the 60 fps and Time Scale 0.5 condition in one line. Its value stays 2.0.
    - `fadeAmountFor`'s doc names its value per reference frame.
    - Rename `persistenceFrames` to `persistenceReferenceFrames`, and word `persistenceFramesForFade`'s doc
      per reference frame.
  - `src/webgpu_render.nim`: `render*(particleCount: int, frameFactor: float)` writes
    `frameFadeFor(config.CONFIG.trailLength, frameFactor)` into `FADE_AMOUNT`. The comment above it states
    the frame factor is the whole frame's.
  - `src/app.nim:281`: pass `frameFactor(dt)`, the frame's `dt` after the Time Scale, importing
    `frameFactor` from `physics_core`.
  - `src/ui/api/response_probe.nim`: `trailPersistenceProbe` calls `persistenceReferenceFrames`, and its doc
    says "reference frames".
  - `tests/test_trail_core.nim`: the header (`:7-11`), the suite "The Trail Slider Buys Frames" (`:76`),
    and the tests "persistence in frames is linear in trail length" (`:86`) and "a trail decays to the
    residual fraction over the frames it names" (`:100`) say "reference frames". Their assertions stay.
    The per-frame decay the suite "The Trail Decays Geometrically" tests is `fade.wgsl`'s step, which
    stays per rendered frame.
  - `tests/README.md:76` ("the frames of persistence") and `:125` ("persistence in frames") say
    "reference frames".

  Verify 6.1's tests pass, and the rest of the trail suite passes unchanged.
- [ ] 6.3 **Help**, `docs/help/50-render.md:12-16`, `trailLength`: "how long motion lingers, in particle
  diameters of travel, the same on any display. Zero clears every frame; long trails turn fast worlds into
  ribbons. The Trails button above turns the effect on and off." The Interacts line reads "particle speed
  (stretches the dots by the distance each travels per 1/120 s of world time); Time Scale (a faster world
  fades its trails sooner in seconds, over the same travel)", with the Trails button, field and Zoom
  entries as they stand. Read the entry in-app through `?` on `./main --serve`.
- [ ] 6.4 `just happen` and `just check` green.

## 7. Integration

- [ ] 7.1 Merge groups 2–6 onto `tm-units`. The integrator runs `just happen` and `just check` once, green.
- [ ] 7.2 **In-app, once** (the in-app procedure in `CLAUDE.md`), at 16 000 particles on the 143 Hz
  display. Record in `~/.scratchpad/particle-garden/tm-units/in-app__<DD-MM-YY-HHmm>.md`:
  - a settled world at Time Scale 0.5 and at 5
  - frames held past 0.05 s at Time Scale 5, where the crowd stays calm and streaks keep their length
  - the field's pattern speed against wall time at Time Scale 0.5 (slower than the parent commit)
  - with Trails on at length 25, trails at Time Scale 0.5 lasting longer in wall time than the parent
    commit's, and shorter at Time Scale 5 than at 0.5
  - no `error|validation` line

Note, outside the checkboxes: `core-force-interface` tasks that wait on this change, on
`cfi-crowding`'s `openspec/changes/core-force-interface/tasks.md`:
- **4.5** (`:180`): G1.2 and the G1 arms at 128 000, and the `K` 540 vs 1728 table (Q1). They read motion
  and `L` under the step, which D1 and D4 change at every ff but 1. Its "no warmer than ff 1" criterion
  below ff 1 also waits on S14 (1.3).
- **4.6** (`:197`): the 128 000 stacked hold, under the same step.
- **4.7** (`:204`): the recorded constants, read from 4.5 and 4.6.
- **4.9** (`:222`): the in-app cost, G1.4. The crowd buffer stride grows to 5, and IntegrationParams to 12
  floats.
- **12.1** (`:443`): its Time Scale 5 held-frame hold.

Note, outside the checkboxes: the world-pressure requirement "The pressure cannot overshoot at any frame
factor" (`core-force-interface/specs/world-pressure/spec.md:157-166` on `cfi-crowding`) states the landed
bound `ff · λ_max ≤ θ`. Under D4 the bound is `ff · h · λ_max ≤ B`. The requirement is restated to D4
wherever it stands when this change's specs are reconciled.
