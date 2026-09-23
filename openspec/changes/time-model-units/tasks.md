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
- [x] 1.2 **S15, the shipped map across frame factors** (design.md, Spikes). Build the D1 map with `h`,
  D4's `B` with the species slope, and D5's loop term. Build them in the spike harness
  `~/.scratchpad/particle-garden/cfi-crowding/spike-s7/`, copied into
  `~/.scratchpad/particle-garden/tm-units/spike-s15/`. Run the prediction as written, at 16 000
  particles. Record the readings against the prediction in `spike-s15/result.md`.
  - Kill reached: stop and return D4's `B` to the design. Group 2's green waits.
  - Result: kill reached. K 540 at ff 30 reads 3.12× ff 1's bound (K 0 2.17×); ff 10 holds in both
    (`spike-s15/result.md`). `s_D` is the majority binder at ff 30 in both worlds (72.51% at K 540,
    99.77% at K 0). D4's `B` returns to the design.
  - Returned: D4's `B` gained the `B∞` term (1.7, S17). K 540 at ff 30 reads 2.48×. Group 2's green waits
    on S18 (1.8).
- [x] 1.3 **S14, the ff-0.42 residual** (design.md, Spikes). Run the prediction as written (dated 17:25,
  22-09-2026) on S15's harness, and record it in `spike-s14/result.md`.
  - The ratio converges as ff falls: record that the ff-1 reference is the stepper's. Return
    `core-force-interface` 4.5's "no warmer than ff 1" criterion below ff 1 to the user, with the numbers.
  - Kill reached: record the residual as open. Group 2 proceeds.
  - Result: kill reached. 0.25/0.42 reads 2.13, and 0.42/1 grows 1.72 → 2.26 from reference frame 9 000
    to 18 000 (`spike-s14/result.md`). The residual stands open.
  - Followed up (S17 P): with positions summed in float64, ff 0.42 read 0.000062 against ff 1's
    0.000077 (`spike-s17/contact/p_k0_posf64.log`). The residual is the f32 position sum, and design.md,
    "What the design claims below ff 1", states what holds.
- [x] 1.4 **S16, the fluid under D1** (design.md, Spikes). Record in `spike-s16/result.md`.
  - Kill reached: the fluid's pressure slope joins `D` in task 2.3 before group 3 starts.
  - Result: kill reached. ff 10 holds, while ff 12 reads p99 about 1690× ff 1's 3× bound, near the cap
    through ff 30, with no NaN (`spike-s16/s16_boundary.log`). The fluid slope moves into task 2.3.
  - Superseded: the slope in `D` left ff 12–30 unsettled (`spike-s16/s16_slope.log`). S17 found the channel
    in the smoothing term, and D9's clamp takes the slope's place in 2.3 and 3.2. The slope joins no limit.
- [x] 1.5 **S13, the field on world time** (design.md, Spikes). Record in `spike-s13/result.md`.
  - Kill reached: the deposit fold moves to per field step in task 4.2, with its own red test first.
- [x] 1.6 `just happen` and `just check` green on the rebased branch before any tree change.
- [x] 1.7 **S17, the revision's spikes** (design.md, Spikes). Recorded in `spike-s17/prediction.md`, each
  prediction ahead of its result.
  - Result: `B∞` 1.2 clears 3× at ff 30 in K 0, K 540 and K 4320 (D4's table). The fluid's channel is the
    smoothing term, and the plan's clamp settles ff 10–30 at both viscosities (D9).
- [x] 1.8 **S18, `B∞` at friction 0.02 and 0.5** (design.md, Spikes), on S17's harness, at 16 000
  particles. Record in `spike-s18/result.md`.
  - Kill reached: `B∞` becomes a function of `r`. Return D4 to the design, and group 2's green waits.
  - Result: kill not reached. K 540 at ff 30 reads 0.50× ff 1's bound at friction 0.02 and 0.70× at
    friction 0.5; ff 10 reads 0.44× and 0.75×, both under the 1.2× line (`spike-s18/result.md`). At both
    range ends motion falls as ff grows, the reverse of friction 0.12's rise. `B∞` 1.2 holds at every
    measured friction; group 2's green proceeds.

## 2. Oracle and integrate (Sonnet, own worktree)

Files: `src/physics_core.nim`, `src/balance_core.nim`, `src/config_ranges.nim`,
`src/ui/api/response_probe.nim`, `tests/test_physics.nim`, `tests/test_balance_core.nim`.

- [x] 2.1 **Red, unit grain, in `tests/test_physics.nim`**, in design.md's writing order, tests 1–12, 25 and
  26. Write them against stubs that compile: `stepClock` returning the landed map's values (`ρ = r^ff`,
  `h = ff`), `speciesRestoringSlope` returning 0, `loopGainBound` returning 0.009, and `smoothingGain`
  returning 1. Test 25 passes against that stub, so verify it red once against the body `(B/θ)/h` with
  no `min(1, …)`, which reads above 1 below ff 1. Each then fails on a
  value, not a missing symbol. The amended suite "Friction Acts Per Reference Frame"
  (`tests/test_physics.nim:530`) keeps its test "ten steps at ff 1 and one step at ff 10 lose the same
  fraction of speed". Run
  `nim c -r` with the `quality_flags` from the `justfile` on `tests/test_physics.nim`, and verify each new
  test fails for the reason its row names.
  - Result: rows 1-12, 25 and 26 landed red against the stubs and turned green across
    `8e2fb6a`/`cfd9b4c` (D9, rows 25-26), `a54da4b`/`71a3a53`/`86591f8` (D4, rows 8-9) and
    `cd39907`/`0b544e3` (D5's `loopGainBound`/`loopLimit`, rows 10-11); `7f5dddf` amended D9's
    `smoothingGain` for the `r/h` clamp and turned row 26's second branch green. `nim c -r` with the
    justfile's `quality_flags` on `tests/test_physics.nim`: all suites `[OK]`.
- [x] 2.2 **Red, oracle grain, in `tests/test_balance_core.nim`**: test 13 (T5f), test 14, test 21 (T7s,
  integration, 2 000 particles, under the `calibrateBalance` define), and test 28 (the fluid, under the
  same define). Verify each fails for its stated reason.
  - Result: test 13 (T5f) and its mean-field-only control, and tests 21 (T7s) and 28 (the fluid gate),
    passed on their first genuine run against the already-landed `crowdLoopSlope`/`crowdLoopMeanField`
    and the D5/D9 wiring, under `-d:release -d:calibrateBalance -d:calibrateSmoke`; the control's
    `check violated` (the mean-field-only candidate under-counting `C_i`) is the genuine discriminating
    evidence in place of a stub-then-green cycle, since the production functions it calls already
    existed. Test 14 ("The Oracle Step Matches The Clock At Every Frame Factor") predates this
    worktree's scoped items and passed on the same run: `[OK] one particle's velocity and position
    through stepFrame match rho=r^ff and x'=x+ff*u'`.
- [x] 2.3 **Green.**
  - `src/physics_core.nim`:
    - `StepClock` with its three cases and `stepClock(ff, retention)`. It rejects retention outside
      `[0.5, 1]` in the test build.
    - `integrateVelocity` takes the clock, forms `u' = s·(ρ·u + h·Δ)`, and caps `u` directly. The
      `perFrame` lines `:428-434` go.
    - `stepLimit(clock, D, θ)` returns `min(1, B/(2·ff·h·D))` with `B = θ·ρ + LONG_STEP_BOUND·(1 − ρ/r)`,
      and `B = θ` frictionless.
    - `speciesRestoringSlope`, analytic for `polynomialForce` and `exponentialForce` (`:287-321`),
      positive part only.
    - `loopGainBound(ρ, α)` bisects the three-state map's spectral radius over κ ∈
      [0, `LOOP_GAIN_SEARCH_CEILING`]. `loopLimit` implements D5's `s_C`. Add
      `LOOP_GAIN_SEARCH_CEILING* = 10.0` beside it, its condition in two lines: caps θ_c at 5 from ff 19 at
      0.12; lifting it moved K 540 ff 30 motion under 1% (`q2_k540_ff30_thetatrue.log`).
    - `smoothingGain(clock, nuMax)` returns D9's `g`, clamped by `r/h` (`clock.r / clock.h`) as well as
      `(B/θ)/(h·min(1, 2ν_max))`, so `h·g ≤ r` holds by construction: `B/θ` alone passes `r` whenever
      `r < 0.6` and `ff > 1`.
  - `src/balance_core.nim`:
    - `sweepPairs` (`:422`) adds each particle's receiving species slope to its `D` words, and
      accumulates `C` in two more words.
    - `integrateParticles` (`:682`) steps through the clock, smooths with `densitySmoothFactor^ff`
      (`:688`), moves by `ff·u`, and applies `min(s_D, s_C)` to the whole velocity.
    - `sweepFluid` (`:539`) multiplies each pair's `smoothCoefficient` (`:600`) by `smoothingGain` of the
      substep's clock and `strength·(viscosity + SPH_XSPH_EPSILON)`. `sph_core.sphPressureSlope` enters
      no limit.
  - `src/config_ranges.nim`:
    - Add `LOOP_LIMIT_FLOOR* = 0.1`, with its condition in two lines: 0 violations of 5 643 on retention
      0.5–1, ff 0.2–30, `C` 1e-5–1e2 (`lagmodel8`).
    - Add `LONG_STEP_BOUND* = 1.2` beside `PRESSURE_STEP_BOUND` (`:705`), its condition in two lines:
      `B`'s value as ρ → 0; at 0.12 it read K 540 ff 30 at 2.48× where S15's 0.936 read 3.12×, and 1.5 and
      1.8 read no lower with more reversals (`spike-s17/prediction.md`, section B).
    - `PRESSURE_STEP_BOUND`'s comment (`:705`) states θ as `B`'s value at ρ 1, which ff 1 meets as `θ·r`,
      the landed limit.
  - `src/ui/api/response_probe.nim`: `timeScaleProbe`'s doc (`:205-213`) drops "integrate.wgsl
    advances pos += vel with no dt". The position now carries the frame factor.
  - Result: all bullets landed, `src/balance_core.nim`'s three across `0accff6` (this worktree's
    final commit, after `7f5dddf`'s D9 `r/h` clamp, `cd39907`/`0b544e3`'s D5 rows 10-11, and
    `a54da4b`/`71a3a53`/`86591f8`'s D4 rows 8-9). `nim c -r -d:release -d:calibrateBalance
    -d:calibrateSmoke` on `tests/test_balance_core.nim` (command recorded under core-force-interface
    tasks.md 4.5): every test from 2.1 and 2.2 passed, including test 14, which predates this
    worktree's scope. The same run's three other `calibrateBalance` suites are open
    core-force-interface gate readings (4.5/4.6/4.9, all `[ ]`), recorded there rather than gating
    this change.

  Verify every test from 2.1 and 2.2 passes.
- [ ] 2.4 `just happen` and `just check` green.

## 3. GPU integrate, forces, render and glow (Sonnet, own worktree; after group 2)

Files:
- `web/shaders/src/integrate.wgsl` and `web/shaders/src/forces.wgsl`
- `src/gpu_types.nim`, `src/shader_config.nim` and `src/webgpu_init.nim` (`:174`, `:390`)
- `src/webgpu_compute.nim`, the integration-uniform block beside `:1064-1080` only
- `src/sim_registry.nim`, a new `integrationUniforms` producer, and `LiveValues` and `substepPlan`
  (`:667-774`)
- `web/shaders/src/forces-sph.wgsl`, the smoothing coefficient at `:273` only
- `tests/test_gpu_types.nim` and `tests/test_sim_registry.nim`

- [x] 3.1 **Red.**
  - `tests/test_gpu_types.nim`: test 16, "IntegrationParams Holds Twelve Floats With The Clock's Fields".
  - `tests/test_sim_registry.nim`: test 15, "The Integration Uniforms Come From One Clock", against a
    stub producer that writes `h = ff`, and test 27, "The Plan Hands The Fluid The Clock's Smoothing
    Gain", against a plan whose `effSmoothGain` is 1.
  - Verify both fail on values.
  - Result: `nim c -r tests/test_gpu_types.nim` failed test 16 on `INTEG_PARAMS_F32_COUNT was 8` against
    a stub, and `nim c -r tests/test_sim_registry.nim` failed test 15 on `uniforms.forceGain ==
    forceGain(clock)` against a stubbed `forceGain: ff` and failed test 27 on `plan.effSmoothGain ==
    expected` against a stubbed `1.0`, both on values.
- [x] 3.2 **Green.**
  - `src/gpu_types.nim`: IntegrationParams gains h, B, α, θ_c and the floor `λ·min(1, 1/ff)` in the two
    pads and three new slots. `INTEG_PARAMS_F32_COUNT` becomes 12.
  - `src/sim_registry.nim`: `integrationUniforms(ff, retention)` builds the block from `stepClock` and
    `loopGainBound`. `src/webgpu_compute.nim` writes it in place of `:1070-1079`.
  - `src/sim_registry.nim`: `LiveValues` gains `friction` and `sphViscosity`, and `SubstepPlan` gains
    `effSmoothGain`, `smoothingGain` of the substep's clock at `ff / count`.
  - `src/gpu_types.nim`: SimParams gains `sphSmoothGain` at offset 692, inside the 704 allocated bytes;
    the size assert (`:738`) reads 696. `src/webgpu_compute.nim` writes `effSmoothGain` beside `:1068`.
  - `web/shaders/src/forces-sph.wgsl:273`: `velocitySmoothCoeff` is multiplied by `params.sphSmoothGain`.
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
  - Result: `nim c -r <quality_flags> tests/test_gpu_types.nim`, `tests/test_sim_registry.nim`,
    `tests/test_body_core.nim`, `tests/test_sph_core.nim` and `tests/test_balance_core.nim` all green;
    `just shaders` regenerated `web/shaders/modules/sim_params.wgsl` and every bundle with no diff
    failure; `nim c -r tests/test_wgsl_lint.nim` green; `nim js -d:release <quality_flags>
    --out:/tmp/app.unminified.js src/app.nim` typechecked clean.
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

- [x] 4.1 **Red.**
  - `tests/test_field_core.nim`: tests 17–19, against a stub `advanceFieldClock` returning today's
    `rdStepsForTimeScale` count and carry 0.
  - `tests/test_sim_registry.nim`: test 20.
  - Verify each fails for its stated reason: test 17 fails at 143 Hz with 10 003 steps, not 4 200.
- [x] 4.2 **Green.**
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
- [x] 4.3 `just happen` and `just check` green.
  - Green on `dev` at `5f186a4` after the field merge: 1 314 native tests, 101 shell tests, shellcheck clean
    (`~/.scratchpad/particle-garden/tm-units/check-after-field__22-09-2026.log`).

## 5. Help (Sonnet, own worktree; parallel with groups 2 and 4)

Files: `docs/help/10-simulation.md`, `docs/help/40-rd.md`, `docs/help/50-render.md`,
`docs/help/51-glow.md`. Anchors are on `cfi-crowding`, and `40-rd.md` on `dev`.

- [x] 5.1 Replace the lines below. `tests/test_help_content.nim` ("every descriptor is named by its group's
  file", `:53`) holds each id's presence. No test holds the wording, which 5.2 checks.
  - `10-simulation.md:26-30`, `timeScale`: "how much world time passes per second of play. Raising it
    speeds everything up at once, including the field's growth, and the same setting runs the same on any
    display." The Interacts line reads "the field (more steps a second, more cost)" in place of "the
    field (more steps, more cost)". The crowd-dense sentence ("In a crowd dense enough to push back,
    pushing Time Scale higher slows how quickly it answers the mouse, a blast or a body — it still
    settles to the same balance, just more gradually.") stays: it is `core-force-interface` 4.10's
    required line, and the step limit still slows a dense crowd's answer at high frame factors.
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
- [x] 5.3 `just happen` and `just check` green.
  - Green on `dev` at `5f186a4` after the field merge: 1 314 native tests, 101 shell tests, shellcheck clean
    (`~/.scratchpad/particle-garden/tm-units/check-after-field__22-09-2026.log`).

## 6. Trail fade (Sonnet, own worktree; parallel with groups 2, 4 and 5)

Files:
- `src/trail_core.nim` and `tests/test_trail_core.nim`
- `src/webgpu_render.nim`, `render`'s signature (`:1415`) and the fade write at `:1483-1488` only
- `src/app.nim`, the `render` call at `:281` only
- `src/ui/api/response_probe.nim`, `trailPersistenceProbe` (`:622-627`) only
- `docs/help/50-render.md:12-16` and `tests/README.md` (`:76`, `:125`)

It reads `physics_core.frameFactor` (`src/physics_core.nim:37-43`), which group 2 leaves as it is.

- [x] 6.1 **Red, in `tests/test_trail_core.nim`**, design.md's tests 22–24, against a stub
  `frameFadeFor(trailLength, frameFactor)` that returns `fadeAmountFor(trailLength)`, today's per-frame
  value. Run `nim c -r` with the `quality_flags` from the `justfile` on the suite. Verify test 22 fails on
  sequences whose frame factors are not all 1, and test 24 at ff 0. Test 23 guards the branch order and
  passes against this stub: verify it red once against the body `pow(fadeAmountFor(trailLength),
  frameFactor)`, where it fails at ff 0.
- [x] 6.2 **Green.**
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
- [x] 6.4 `just happen` and `just check` green.
  - Green on `dev` at `5f186a4` after the field merge: 1 314 native tests, 101 shell tests, shellcheck clean
    (`~/.scratchpad/particle-garden/tm-units/check-after-field__22-09-2026.log`).

## 7. Integration

- [ ] 7.1 Merge groups 2–6 onto `dev`, each rebased onto the last. The integrator runs `just happen` and `just check` once, green.
- [ ] 7.2 **In-app, once** (the in-app procedure in `CLAUDE.md`), at 16 000 particles on the 143 Hz
  display. Record in `~/.scratchpad/particle-garden/tm-units/in-app__<DD-MM-YY-HHmm>.md`:
  - a settled world at Time Scale 0.5 and at 5
  - frames held past 0.05 s at Time Scale 5, where the crowd stays calm and streaks keep their length
  - the field's pattern speed against wall time at Time Scale 0.5 (slower than the parent commit)
  - with Trails on at length 25, trails at Time Scale 0.5 lasting longer in wall time than the parent
    commit's, and shorter at Time Scale 5 than at 0.5
  - no `error|validation` line
  - no flicker in streaks or glow of a settled crowd at Time Scale 5 (D4's reversal note)
  - with the fluid on, its look at Time Scale 0.5 and 5 on 60 Hz and 143 Hz, where D9's clamp weakens the
    smoothing

Note, outside the checkboxes: `core-force-interface` tasks that wait on this change, on
`cfi-crowding`'s `openspec/changes/core-force-interface/tasks.md`:
- **4.5** (`:180`): G1.2 and the G1 arms at 128 000, and the `K` 540 vs 1728 table (Q1). They read motion
  and `L` under the step, which D1 and D4 change at every ff but 1. Its "no warmer than ff 1" criterion
  below ff 1 does not hold in f32: the f32 position sum adds 5e-5 to 7e-5 of travel per step, read as
  that amount over ff (ff 0.42 0.000131 in f32, 0.000062 with a float64 sum, ff 1 0.000077). Design.md,
  "What the design claims below ff 1", states what holds; the restated criterion is the coordinator's.
- **4.6** (`:197`): the 128 000 stacked hold, under the same step.
- **4.7** (`:204`): the recorded constants, read from 4.5 and 4.6.
- **4.9** (`:222`): the in-app cost, G1.4. The crowd buffer stride grows to 5, and IntegrationParams to 12
  floats.
- **12.1** (`:443`): its Time Scale 5 held-frame hold.

Note, outside the checkboxes: the world-pressure requirement "The pressure cannot overshoot at any frame
factor" (`core-force-interface/specs/world-pressure/spec.md:157-166` on `cfi-crowding`) states the landed
bound `ff · λ_max ≤ θ`. Under D4 the bound is `ff · h · λ_max ≤ B`, with `B = θ·ρ + B∞·(1 − ρ/r)` and
`B∞ = LONG_STEP_BOUND` 1.2, which is `θ·r` at ff 1. The requirement is restated to D4 wherever it stands
when this change's specs are reconciled.
