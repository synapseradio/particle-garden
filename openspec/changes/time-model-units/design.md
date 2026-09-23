# Design

## Context

See proposal.md, Why, for the defect. This design builds on the time model as it stands on two unmerged
branches. Anchors below name the branch they were read on.

- **`cfi-crowding` at `3eee226`** (the oracle and the host):
  - `physics_core.integrateVelocity` (`src/physics_core.nim:404-438`) computes
    `v' = r^ff · (v + s · ff · Δ)` and caps the speed read per reference frame (`perFrame`, `:428`).
  - `stepLimit` (`:493-497`) returns `s = min(1, θ / (2 · ff · D))`, with `θ = PRESSURE_STEP_BOUND = 2`
    (`src/config_ranges.nim:681`). `D` is the particle's summed world-pressure slope.
  - `balance_core.integrateParticles` (`src/balance_core.nim:682`) is the oracle's mirror.
  - The retention `r` arrives as `1 − friction` (`src/app.nim:193` on `cfi-crowding-gpu`), with friction
    in `[0, 0.5]` (`src/config_ranges.nim:129-130`), so `r ∈ [0.5, 1]`.
- **`cfi-crowding-gpu` at `c09b105`** (the shaders):
  - `web/shaders/src/integrate.wgsl` decodes the delta times `frameFactor` (`:64`, `:67`), smooths both
    densities by `DENSITY_SMOOTH_FACTOR` per step (`:72`, `:82-83`), and applies the step limit
    (`:93-94`).
  - It forms `newVel = (vel + Δ) · s · friction` (`:110-111`), caps through `perFrame` (`:123`), and moves
    by `newVel` with no frame factor (`:138-139`).
  - `INTEG_FRICTION` carries `retention^ff` (`src/webgpu_compute.nim:1070-1071`). IntegrationParams has two
    pads, `INTEG_PAD2` and `INTEG_PAD3` (`src/gpu_types.nim:781-782`).
  - The crowd buffer has stride 3: crowd, stiffness fine, stiffness coarse (`web/shaders/src/forces.wgsl:46`,
    `src/webgpu_init.nim:174`).
- **`dev` at `7ca5d7a`** (the field):
  - `field_core.rdStepsForTimeScale` (`src/field_core.nim:188-201`) returns an odd count per rendered
    frame from the Time Scale alone.
  - `webgpu_compute` rebuilds the frame description when that count changes (`src/webgpu_compute.nim:272-280`).
  - The deposit fold scales by `depositFrameScale(steps)` (`src/field_core.nim:203-211`,
    `src/webgpu_compute.nim:1097-1098`), which holds the deposit rate per field step.
  - The trail fade keeps `fadeAmountFor(trailLength)` of the previous frame on every rendered frame
    (`src/trail_core.nim:51-62`, written at `src/webgpu_render.nim:1488`). `TRAIL_FRAMES_PER_DIAMETER`
    (2.0, `src/trail_core.nim:33-36`) was set in frames at 60 fps.
  - The run loop computes `dt = min(rawDt, 0.05) · timeScale` (`src/app.nim:241-243`) and calls
    `webgpu_render.render(runtimeState.particleCount)` with no frame factor (`src/app.nim:281`).

Measurements this design rests on are in `~/.scratchpad/particle-garden/cfi-crowding/spike-s7/`:
`prediction.md` (each prediction written before its run), `s9_*.log`, `s10_*.log`, `s11*.log` and
`lagmodel8.log`. The design report is `design-decouple-frame-rate__04-40PM_22-09-2026.md` in the parent
directory.

Measurements behind D4's bound, D5's search ceiling, D9 and the claim below ff 1 are in
`~/.scratchpad/particle-garden/tm-units/`: `spike-s14/result.md`, `spike-s15/result.md`,
`spike-s16/result.md`, and `spike-s17/prediction.md` with its logs in `spike-s17/contact/` and
`spike-s17/fluid/`. Each prediction there was written before its run. All ran at 16 000 particles, seeds
42, 7 and 1001, friction 0.12.

## Goals / Non-Goals

**Goals:**
- A force, friction, density smoothing, the field and the trail fade each advance the same amount per
  reference frame of world time, whatever the frame factor.
- The step at ff 1 is the step landed on `cfi-crowding`, up to f32 rounding. There is one exception: `D`
  now counts the species slope. Every ff-1 gate on file keeps its meaning.
- The explicit step stays stable at every frame factor the app produces, 0.084 to 30. The lower end is
  143 Hz at `TIME_SCALE_MIN` 0.1 (`src/config_ranges.nim:180`); the upper end is a held frame at Time
  Scale 5.

**Non-Goals:**
- **Retuning the 143 Hz look.** Every constant keeps its ff-1 meaning (the user's decision). Retuning by
  ear is later work.
- **The explicit step's accuracy at large ff.** One step at ff 30 still spans 30 reference frames. This
  change bounds its stability, not its truncation error.
- **The fluid's substep count and stiffness clamp** (`src/sim_registry.nim:725-774`). They keep their form.
  The plan gains one output, the smoothing gain (D9).

## Decisions

### D1. Velocity is stored as travel per reference frame

The position update carries the frame factor, and every force enters through one gain.

```text
x' = x + ff · u'
u' = s · (ρ · u + h · Δ)          Δ the decoded delta per reference frame, s the step limit
ρ  = r^ff                          retention over this step
h  = r · (1 − ρ) / (1 − r)         h = ff when r = 1
```

- **Why this `h`.**
  - The fixed point is `u* = h·Δ/(1 − ρ) = r/(1 − r) · Δ` at every ff, which is ff 1's terminal speed on
    the landed map.
  - Frictionless, `h = ff`, so a constant force moves a particle `Δ·T·(T + ff)/2` in world time `T`. That
    is exact up to the semi-implicit `ff/2` term.
  - At ff 1, `ρ = h = r`, so `u' = s·(r·u + r·Δ)` equals the landed `r·s·(v + Δ)` with one multiply
    distributed.
- **`h ≤ ff` for every `r ∈ [0.5, 1]` and `ff ≥ 0`.**
  - At ff 0 the difference `ff − h` is 0.
  - Its slope in ff is `1 − r·γ·r^ff/(1 − r)`, with `γ = −ln r`, and that slope never falls below its
    value at ff 0.
  - At ff 0 the slope is non-negative, because `−r·ln r ≤ 1 − r`.
- **Alternative: the exact exponential gain `(1 − ρ)/γ`.** S10 and S11 ran it. It differs from `h` by the
  constant factor `γ·r/(1 − r)`, which is 0.9375 at friction 0.12. The factor rescales every force 6% at
  ff 1 and moves every ff-1 gate, so it was rejected.
- **Alternative: keep velocity per step and fix the delta to `ff²·Δ`.** It fixes acceleration, but the cap,
  the streaks and a held frame's carried velocity still read per step. A velocity carried from an
  ff-0.42 step into an ff-3 step would move 7× too slowly per reference frame. Rejected.

**The cap** reads `u` directly: `min(softCap(|u|), maxVelocity)`. The `perFrame` division and its
frame-factor guard go, in the oracle (`src/physics_core.nim:428-434`) and the shader
(`integrate.wgsl:123-129`). Travel per step stays bounded by `ff · maxVelocity`, as the landed cap bounds
it, so the fluid plan's travel count `n_T` is unchanged.

### D2. The step clock is one value per substep, parsed once on the host

```text
type StepClock                               physics_core; built from (ff, r) at the host boundary
  Stopped       stopped()                    ff 0: no travel, no drain, no gain (ρ 1, h 0)
  Frictionless  frictionless(ff)             r = 1, ff > 0: ρ 1, h ff
  Damped        damped(ff, r)                r < 1, ff > 0: ρ r^ff, h r(1 − ρ)/(1 − r)
accessors: travel (ff), retention (ρ), forceGain (h), densityCarry (0.7^ff)
removed by construction:
  - a gain computed at a different ff than its retention
  - the (1 − ρ)/(1 − r) division at r = 1
  - a cap guard against ff 0
precision: deletes `select(1.0, params.frameFactor, params.frameFactor > 0.0)` (integrate.wgsl:123) and
  `if frameFactor > 0.0'f32: frameFactor else: 1.0'f32` (physics_core.nim:428)
```

- The producer is `stepClock(ff, retention)`, a pure function in `src/physics_core.nim`. The oracle and
  `integrationUniforms` (`src/sim_registry.nim`, whose block `src/webgpu_compute.nim` writes beside
  `:1070`) both call it.
- The shader receives the accessors as uniforms and never branches on the case.
- A runtime check stays in the producer: `retention ∈ [0.5, 1]`. The type does not delete it, because
  friction arrives as a float from the range authority and weather. A value out of range panics in the
  test build. The range clamp in `src/preset.nim:427-428` holds it in play.

### D3. Density smoothing is per reference frame

Both smoothed densities (`integrate.wgsl:72`, `:82-83`; oracle `src/balance_core.nim:688`) carry
`α = DENSITY_SMOOTH_FACTOR^ff`, uploaded as the clock's `densityCarry`. At ff 1, `α` is 0.7, the shipped
`densitySmoothFactor` (`src/shader_config.nim:118`). S9-b1 and S9-b2 read no effect on motion from this
change at ff 10 (`spike-s7/prediction.md`, S9 results). The change is made for units, not for warmth.

### D4. The step limit counts the species slope and loosens toward a long-step bound

```text
D    = Σ pressure slope (landed) + Σ species restoring slope (new)
s_D  = min(1, B / (2 · ff · h · D))
B    = θ · ρ + B∞ · (1 − ρ / r)          θ  = PRESSURE_STEP_BOUND = 2
                                          B∞ = LONG_STEP_BOUND = 1.2
```

- **The contact mode under D1.** With `s` scaling the whole update, a mode of stiffness `k` has the
  characteristic `μ² − (1 + sρ − s·ff·h·k)·μ + sρ`. A pair's relative mode has `k = 2D`, and Gershgorin's
  bound puts every crowd mode at `k ≤ 2D`, so a limited step holds `s·ff·h·k ≤ B`. Both roots sit inside
  the unit circle while `sρ < 1` and `B < 2(1 + sρ)`, and any `B < 2` meets that for every `s`.
- **`B` stays in [0.8, 2] on the whole range.** `B` is linear in `ρ`. It runs from `B∞` at `ρ → 0` to
  `θ − B∞·(1/r − 1)` at `ρ = 1`, which is 0.8 at r 0.5 and 2 at r 1. It reaches 2 only frictionless,
  where it equals the landed frictionless bound `θ`. Wherever `r < 1` and `ff > 0` it sits under 2.
- **At ff 1, `B = θ·r`**, because `ρ = r` there, so `s_D = min(1, θ/(2D))`, the landed limit (test 8).
  Below ff 1 at 0.12 it sits within 2% of S15's `B` (1.803 against 1.823 at ff 0.42), where S14 read the
  limit binding on 0.00% of particle-steps (`spike-s14/result.md`).
- **Why `B` rises past ff 1's share at long steps.** As `ρ → 0` the carried velocity drops out, and a mode
  of stiffness `k` keeps `1 − B·k/(2D)` of its displacement per step. The stiffest mode keeps `1 − B`.
  Every softer mode relaxes by a share proportional to `B`, and the crowd's slow rearrangement is made of
  softer modes. S15's `B`, `θ·r·(1 + ρ)/(1 + r)`, falls to 0.936 as `ρ → 0`: it left the stiffest mode
  near deadbeat and relaxed every softer mode more slowly per step than a larger `B` would. The
  matched-time window caught that crowd still relaxing. K 540 at ff 30 read 0.000346 at reference frame
  9 000 (`spike-s15/s15_k540_f0.12.log`). Under `B∞` 1.2 the same world reads 0.000275 at 9 000 and
  0.000107 at 18 000 (`spike-s17/contact/b_k540_binf1.2.log`, `t_k540_binf1.2_w18000.log`). Over the
  same span ff 1 falls from 0.000105 to 0.000061, so the ratio falls from 2.48× to 1.70×: the excess is a
  crowd relaxing more slowly, not a floor.
- **`B∞` is sized by measurement** (S17, `spike-s17/prediction.md`, sections B and S). Each ratio is the
  arm's mean over the same world's ff 1 bound: 0.000076 at K 0, 0.000111 at K 540
  (`spike-s15/s15_split_k*_f0.12.log`), 0.000122 at K 4320 (`spike-s17/contact/s_k4320_binf1.2.log`).
  ff 1 does not move with `B∞`, because `B = θ·r` there for every `B∞`.

  | `B` as ρ → 0 | K 0 ff 10 | K 0 ff 30 | K 540 ff 10 | K 540 ff 30 | K 4320 ff 10 | K 4320 ff 30 | reversals ff 10, K 540 |
  |---|---|---|---|---|---|---|---|
  | 0.936 (S15's `B`) | 0.95× | 2.17× | 1.00× | 3.12× | 1.34× | 2.78× | 4.36% |
  | 1.2 | 0.79× | 1.08× | 0.84× | 2.48× | 1.16× | 2.40× | 5.09% |
  | 1.5 | 1.12× | 1.13× | 1.11× | 2.38× | – | – | 5.93% |
  | 1.8 | 0.89× | 1.13× | 0.91× | 2.37× | – | – | 6.42% |

  Every `B∞` from 1.2 up brings K 540 at ff 30 inside the 3× line. Above 1.2 the reading stops falling
  while reversals keep rising, and at 1.5 seed 42 reads 1.70× (K 0) and 1.56× (K 540) at ff 10. 1.2 is the
  smallest measured value that clears the line in all three worlds. The logs are
  `spike-s17/contact/b_k{0,540}_binf{1.2,1.5,1.8}.log` and `s_k4320_{binf1.2,d4}.log`.
- **The sacrifice.** `B∞` 1.2 brings K 540 at ff 30 from 3.12× to 2.48× and K 0 from 2.17× to 1.08×. It
  gives up monotone settling of the stiffest mode at long steps: `1 − B` is −0.2 as `ρ → 0`, so that mode
  changes sign each step, and reversals at ff 30 rise from 0.57% to 1.07% (K 540). Undoing it costs one
  constant and the one line of `stepLimit` that forms `B`.
- **The species restoring slope** is the positive part of the radial derivative of the species impulse on
  this particle: `forceMultiplier · FRAME_DT_REFERENCE · invRadius · ∂F/∂(r/R)`.
  - It is analytic for both force models: `polynomialForce` and `exponentialForce`,
    `src/physics_core.nim:287-321` on `cfi-crowding`.
  - S9-1 and S11 used a central difference, polynomial model only (`spike-s7/src/balance_core.nim:541-555`).
  - Each particle counts its own receiving slope, because the species matrix is asymmetric.
- **This is the one change at ff 1 (Q-B3).** S9-1 read it limiting 0.00% of particle-steps in the
  species-only world at ff 1, bit-identical to the unlimited run (`spike-s7/prediction.md`, S9 results).
  With the world pressure on, S15 read the ff 1 limited share at 26.68% against the landed limit's
  26.67% at K 540, and `s_D` binds on none of those steps: the loop term `s_C` carries all of them
  (`spike-s15/s15_split_k540_f0.12.log`).
- **Alternative: S15's `B = θ·r·(1 + ρ)/(1 + r)`.** It kept ff 1's share `r/(1 + r)` of the linear bound
  at every ff. Rejected: K 540 at ff 30 read 3.12×, over S15's kill.
- **Alternative: S11's form `s = min(1, (1 + ρ)/(ff·h·D))`.** It sits on the linear bound for `k = 2D`,
  and it is looser than the landed limit at ff 1 by about `(1 + r)/r`. S11 read it at 1.14× and 0.92× of
  S10's ff-1 bound at ff 10 and 30, but with 5–12% of moving particle-steps reversing
  (`spike-s7/s11.log`). Rejected, because it changes ff 1 and sits at the margin.
- **The limit stays a runtime value.** It is a per-particle function of that particle's neighbours this
  step, so no type deletes it.

#### Reversals at ff 10 are a measured note

The ruling: the design takes no action on them, and task 7.2 watches for them.

- **The reading.** Under `B∞` 1.2, 5.09% (K 540), 6.53% (K 0) and 5.10% (K 4320) of moving particle-steps
  at ff 10 reverse direction. Under S15's `B` the share was 4.36% and 5.45%.
- **Where they come from.** At ff 10, `B` is 1.377. With `s` 1 the stiffest mode's roots are a complex pair
  of modulus 0.53 turning 95° per step. As `s` falls they approach 0 and `1 − B = −0.38`. Either way that
  mode changes sign within one or two steps. Real positive roots need `B ≤ (1 − √(sρ))²`, which is 0.22 at
  `s` 1: six times tighter than 1.377, and tighter than S15's `B`, which the table shows relaxing the crowd
  too slowly.
- **What they cost the eye.** The reversing particles are limited particles in a settled crowd, whose mean
  motion is about 1e-4 per reference frame (the motion column in the logs above). Streaks and glow scale
  with `|u|/maxVelocity` (D7), which is 2e-6 at that speed against the shipped `maxVelocity` 50
  (`src/preset.nim:247`). A reversal at that speed draws no visible change.
- **When they become a design input.** If task 7.2 sees streaks or glow flicker in a settled crowd at Time
  Scale 5, the limit needs a damping term per mode, which this design does not carry.

### D5. The density-loop term (form F) lands here, re-derived for D1

The term was designed on `cfi-crowding` (the crowding report, "The final limit (form F)") and held there
pending this derivation. `cfi-crowding`'s task 4.4b covers `D` only. Under D1 and D3, the lagged-density
loop is the same three-state map with retention `ρ`, carried `α = 0.7^ff` and loop gain
`ff·h·C/ρ`.

```text
C_i     = Σ_j K · FRAME_DT_REFERENCE · (6/R) · (1 − d/R) · (φ'(ρ_i)·ρ_i + φ'(ρ_j)·ρ_j),
          φ'(x) = 2·max(x − x_on, 0)/x_on², raised in integrate to at least the mean-field term
reach   = ff · h · C / ρ
θ_c     = κ_max(α, ρ) / 2            κ_max: the largest gain at which the three-state map has radius ≤ 1
s_C     = 1                                   if reach ≤ θ_c
          max(θ_c / reach, λ · min(1, 1/ff))  otherwise
s       = min(s_D, s_C)                        applied to the carried velocity too (D1's s)
λ       = LOOP_LIMIT_FLOOR = 0.1
```

- **M8 held** (`spike-s7/lagmodel8.log`, model `lagmodel8.py`). On retention {1, 0.995, 0.99, 0.98, 0.95,
  0.88, 0.84, 0.7, 0.5}, `C` from 1e-5 to 1e2 and ff from 0.2 to 30, there are 0 violations of 5 643 at
  λ 0.1 and at λ 0. The criterion is T5e's: the loop stays stable wherever ff 1's is, and grows no
  faster per reference frame wherever ff 1's grows.
- **θ_c** at friction 0.12, 0.05 and 0.02 (`lagmodel8.log:4-6`):

  | ff | 0.12 | 0.05 | 0.02 |
  |---|---|---|---|
  | 0.42 | 0.00508 | 0.00171 | 0.00062 |
  | 1 | 0.02618 | 0.00882 | 0.0032 |
  | 4.2 | 0.30891 | 0.09853 | 0.03518 |
  | 10 | 1.28514 | 0.32942 | 0.10936 |
  | 30 | 5.0 (search ceiling; 22.64673 uncapped) | 1.82949 | 0.41661 |

  At ff 1, θ_c equals the value derived for the landed map (0.02618 at 0.12, `lagmodel7`).
- **`loopGainBound` searches κ in [0, `LOOP_GAIN_SEARCH_CEILING`], 10, so θ_c never exceeds 5.**
  - At 0.12 the ceiling binds from ff 19. The uncapped value is 5.94602 at ff 20 and 22.64673 at ff 30. At
    friction 0.5 it binds from ff 3.5 (`spike-s17/thetac_ceiling.log`, `thetac_t5h_grid.log`).
  - A capped θ_c is smaller than the derived one, so the ceiling only tightens `s_C`. M8 read its 0
    violations with the ceiling in place.
  - Lifting the ceiling moved K 540 at ff 30 from 0.000346 to 0.000345
    (`spike-s17/contact/q2_k540_ff30_thetatrue.log`). T5h's grid sits under the ceiling everywhere
    (`thetac_t5h_grid.log`).
- **The loop term carries its own share at every ff.**
  - At K 540 it binds on 26.68% of particle-steps at ff 1, which is all of ff 1's limiting. It binds on
    27–35% at ff 10 and 30 (`spike-s15/s15_split_k540_f0.12.log`, `spike-s17/contact/b_k540_binf1.2.log`).
  - With it off, K 540 at ff 30 reads 0.012094, 35× the limited reading
    (`spike-s17/contact/q3_k540_ff30_loopoff.log`).
  - At K 0, `C` is 0 because each term carries `K`, so the loop term never binds there.
- **θ_c depends on ff through both `α` and `ρ`.** The crowding report's one-dimensional table read at
  the next retention does not cover it. `loopGainBound(ρ, α)` bisects the 3×3 spectral radius on the CPU
  once per substep. Its cost is unmeasured and rides on S12.
- **`C` travels in two more words** beside `D`'s. The crowd buffer's stride grows from 3 to 5
  (`src/webgpu_init.nim:174`, `:390`; `forces.wgsl:46`, and the `* 3u` sites at `:384-491`).
- **λ's margin under D1 is unmeasured.** The landed-map margin (λ ≤ 0.173, `spike-s7/lagmodel6.log`) was
  read on the old map. M8 read only λ 0.1 and 0. The constant's comment states the M8 condition alone.
- **Alternative: drop the term.** The simmer returns: 0.031 without carried-velocity scaling, crowding
  report "What undoing it costs". Rejected.

### D6. The field owes steps from world time

```text
type FieldClock                              host, carried across frames (webgpu_compute)
  carry: float in [−1, 2)                    field steps owed and not yet run
advance(clock, ff) -> (steps: FieldSteps, clock')
  owed   = carry + FIELD_STEPS_PER_REFERENCE_FRAME · ff       7 per reference frame
  steps  = clamp(largest odd ≤ owed, 1, FIELD_STEPS_CEILING)  ceiling 71
  carry' = max(owed − steps, −1)     below the ceiling, where owed − steps < 2
         = min(owed − steps, 1)      at the ceiling, dropping the rest
type FieldSteps                              odd int in [1, FIELD_STEPS_CEILING]; smart constructor only
removed by construction: an even count reaching the frame builder
```

- **Unit and reference.** At ff 1 (60 Hz, Time Scale 0.5) it runs 7 every frame, today's
  `RD_STEPS_PER_FRAME`. At 143 Hz and Time Scale 0.5 (ff 0.42) it runs 3 on most frames and 1 on the
  rest, averaging 2.94.
- **The ceiling, 71, is today's Time Scale 5 count**, `rdStepsForTimeScale(5, 0.5)`. The field's
  per-frame cost therefore never exceeds what ships. A held frame at Time Scale 5 owes 210 and runs 71;
  the rest is dropped, the way the 0.05 s cap drops wall time.
- **Where it runs ahead.** Below 1 owed step per frame (ff < 1/7: Time Scale below 0.17 at 143 Hz), the
  floor of 1 runs the field ahead of world time. The carry clamps at −1, so the field never stalls later
  to pay the lead back. Today's `rdStepsForTimeScale` floors at 1 the same way
  (`src/field_core.nim:201`).
- **The deposit fold stays per frame by count.** `depositFrameScale(steps)` holds the deposit rate per
  field step at whatever count the frame runs. S13 checks that the split across frames leaves the
  pattern unchanged.
- **Frame descriptions are cached per count.** The count now changes frame to frame, and the executor
  rebuilds on a change (`src/webgpu_compute.nim:276`). The cache holds at most 36 descriptions (the odd
  counts 1–71).
- **`rdStepsForTimeScale` goes.** `RD_STEPS_PER_FRAME` is renamed `FIELD_STEPS_PER_REFERENCE_FRAME`.
  `RD_REFERENCE_TIME_SCALE` keeps its readers (`tests/test_response_probe.nim:26`, `:281-285`;
  `tests/test_param_descriptor.nim:886`), and its doc states it as the Time Scale at which a 60 Hz frame
  spans one reference frame.
- **Alternative: track the live texture, so any count is legal.** The renderer, `fieldForce` and the next
  resolve would each bind by parity: two bind groups per reader, and the reader side coupled to the
  clock. The odd rounding costs a carry of under 2 steps and keeps the chain rule as specified.
  Rejected.
- **Alternative: skip the field on frames owing under one step.** `fieldResolve` folds that frame's
  deposit, and what skipping it does to that deposit is unmeasured. Rejected for the case it serves, Time
  Scale below 0.17 at 143 Hz.

### D7. Streaks and glow read travel per reference frame

`render.wgsl:91-97` and `glow.wgsl:89-90` read `p.vel` against `maxVelocity`. Under D1 that ratio is per
reference frame, so neither shader's formula changes. At 143 Hz, streaks lengthen 2.4× against today's
(0.42× before); on a held frame at Time Scale 5 they no longer draw 30× long. This is the user's Q-B2
answer.

### D8. The trail fades per reference frame

```text
fadeRef   = fadeAmountFor(trailLength)     unchanged; now read per reference frame: the trail falls to
                                           TRAIL_RESIDUAL_FRACTION over trailLength · TRAIL_FRAMES_PER_DIAMETER
                                           reference frames
frameFade = frameFadeFor(trailLength, ff)
          = 0              if trailLength ≤ 0
          = fadeRef^ff     otherwise        ff: the rendered frame's whole frame factor
```

- **The constant keeps its value.** `TRAIL_FRAMES_PER_DIAMETER` 2.0 is documented in frames at 60 fps
  (`src/trail_core.nim:34-35`). At the shipped Time Scale 0.5 (`src/preset.nim:241`) a 60 Hz frame spans
  one reference frame (`src/physics_core.nim:23-26`). Its doc becomes "reference frames", and every trail
  at 60 Hz and Time Scale 0.5 fades as it does today.
- **Frames compose exactly.** The frame fades multiply to `fadeRef^(Σ ff)`, so a trail keeps the same share
  over the same world time however that time splits into frames. No approximation enters.
- **Why the fade must follow D1.** Under D1 a particle travels the same distance per reference frame on
  any display. A fade per rendered frame spends each frame's share in 0.42 reference frames at 143 Hz,
  so a trail would cover 0.42× the travel, in diameters, that it covers at 60 Hz.
- **The zero trail at ff 0.** `pow(0.0, 0.0)` is 1 in Nim's `std/math`, so `fadeAmountFor(0)^0` would keep
  a zero-length trail whole. `frameFadeFor` branches on the length before the power. A frame with ff 0 and
  a positive length keeps the trail whole (`fadeRef^0 = 1`), because the world did not move. ff 0 reaches
  the renderer only when two frames carry the same timestamp: the loop returns before rendering while
  stopped (`src/app.nim:236`), and `TIME_SCALE_MIN` is 0.1 (`src/config_ranges.nim:180`).
- **A held frame** spans up to ff 30 (0.05 s · 5 · 120). At the Trails button's length 25
  (`src/ui/state/render_state.nim:41`), `fadeRef` is 0.9418, and the held frame keeps 0.166 of the trail,
  the share 30 reference frames keep.
- **The frame factor is the whole frame's.** The fade pass runs once per rendered frame, after every
  substep, so it takes `frameFactor(dt)` (`src/physics_core.nim:37-43`) of the frame's `dt`, never a
  substep's. `render` gains a `frameFactor: float` parameter, and `src/app.nim:281` passes it.
- **Persistence reads in reference frames.** `persistenceFrames` becomes `persistenceReferenceFrames` in
  `src/trail_core.nim`, the trail suite and `trailPersistenceProbe` (`src/ui/api/response_probe.nim:622-627`).
  Its value is unchanged. The probe key `render.trailPersistence` stays.
- **Declined type: `TrailFade = Clears | Decays(fadeRef)`.** The zero case already branches once, in
  `fadeAmountFor` (`src/trail_core.nim:59`), and `frameFadeFor` keeps its own branch ahead of the power, so
  the sum type deletes no check beyond it. Test 23 holds the ff-0 case instead.
- **Alternative: fade per wall second.** The trail length is in particle diameters of travel. A wall-time
  fade would change the trail's world length with the Time Scale. The user chose the reference frame.
- **Alternative: standing still.** Trails at 143 Hz would last 0.42× the world time they last at 60 Hz, as
  they do today, and the time-model spec would hold for every consumer of world time except the trail.

### D9. The fluid's smoothing gain is clamped per substep

```text
ν_max = fluidStrength · (sphViscosity + SPH_XSPH_EPSILON)      bounds every particle's ν_i
ν_i   = Σ_j fluidStrength · (sphViscosity + SPH_XSPH_EPSILON) · w_ij / max(ρ_i, ρ_j)
g     = min(1, (B/θ) / (h · min(1, 2 · ν_max)), r/h)            per substep, from the substep's clock
every pair's smoothing coefficient is multiplied by g; pressure and the carried velocity are not
```

`ν_i` stays under `ν_max`, because `Σ_j w_ij / ρ_i = (ρ_i − 1)/ρ_i < 1` with the self weight 1 in `ρ_i`.

- **The channel.** Under D1 the smoothing term `Δ = ν_i·(ū − u)` multiplies a relative-velocity mode by
  `ρ − κ·h·ν` per step, where `κ` is the mode factor, at most 2 by Gershgorin. The mode grows once
  `κ·h·ν > 1 + ρ`.
  - The plan runs three substeps from ff 1 up at `SPH_STIFFNESS_MAX` (`count 3` in
    `spike-s16/s16_full.log`). S16's onset between ff 10 and 12 therefore sits between substep ff 3.33 and
    4, where `h` is 2.54 and 2.94.
  - That puts `κ·ν` between 0.545 and 0.651: `κ` about 1.5 at the shipped `ν` near 0.4.
- **Two runs separate the channel from the pressure** (S17, section F, predictions written first).
  - At ff 12 with viscosity and the XSPH blend scaled 0.75, the fluid settles: p99 0.0030–0.0039
    (`spike-s17/fluid/f1_ff12_v075.log`).
  - At ff 10 scaled 1.3, it does not: p99 26.4–26.6 (`f2_ff10_v130.log`).
  - The pressure's own candidate, the lagged equation of state's loop, has a stable gain flat from ff 4.2
    to 30 (`spike-s17/fluid_loop.log`), so it predicts neither reading.
  - The pressure slope in `D`, S16's kill arm, left ff 12–30 unsettled: p99 10.2–27.3
    (`spike-s16/s16_slope.log`). It joins no limit in this design.
- **Why this `g`.**
  - At a substep of ff ≤ 1, `g = 1` at every viscosity: the landed step. `B/θ` and `h` are both linear
    in `ρ` and equal at `ρ = r`. At `ρ = 1`, `B/θ − h` is `1 − 0.6·(1 − r)/r ≥ 0.4`, so `B/θ ≥ h` for
    every `r ∈ [0.5, 1]`. The plan runs three substeps of ff 1/3 at an ff-1 frame at
    `SPH_STIFFNESS_MAX`.
  - Where `ν_max ≤ 1/2`, `2·h·g·ν_i ≤ B/θ`. `B/θ` applies D4's share `B/(2(1 + ρ))` to this mode's bound
    `1 + ρ`. The multiplier `ρ − κ·h·g·ν_i` then stays above `ρ − B/θ > −1` for every mode with `κ ≤ 2`,
    so the step is stable by construction.
  - Where `ν_max > 1/2`, `g`'s third term clamps `h·g ≤ r` by construction, so the smoothing's reach per
    step never exceeds ff 1's `r·ν_i`. `B/θ` alone does not hold `h·g` under `r`: `B/θ` passes `r`
    whenever `r < B∞/θ = 0.6` (friction above 0.4) and `ff > 1`, so the `r/h` term was added on the
    user's choice on 23-09-2026. Stability there rests on the mode factor. With `κ` 1.5 it holds up to
    `ν_i` 1.1, and the run below at the viscosity ceiling settles.
- **Measured** (S17, section V''). p99 reads 0.0032–0.0041 at ff 10, 12, 15 and 30 at the harness's
  viscosity, and 0.0030–0.0039 at ff 12 and 30 at the range's ceiling, `sphViscosity` + blend 1.5
  (`spike-s17/fluid/v3_*.log`). ff 1 reads 0.0066–0.0067 (`spike-s16/s16_full.log`).
- **`g` clamps the smoothing alone,** so the fluid keeps its flow at long steps. Max speed at ff 10 reads
  5.0–5.5, against 3.5–4.6 unlimited (`fluid/v3_ff10_v1.0.log`, `spike-s16/s16_full.log`).
- **The sacrifice.** The clamp buys a fluid that settles at every ff. It gives up smoothing past a substep
  of ff 1, everywhere, including sparse spots whose own `ν_i` would allow more.
  - At the shipped `sphStiffness` 8 and radius 50 (`src/preset.nim:233`, `:260`), with no live body
    (`travelBound`, `src/sim_registry.nim:715-723`), a frame between ff 1 and 1.875 runs one substep. On
    the 143 Hz display that spans Time Scale 1.19 to 2.23, where `g` falls to 0.54 at `ν_max ≥ 1/2`.
  - Estimated at `κ` 1.5 and `ν` 0.4, a substep of ff 2 at `g` 0.51 keeps 0.27 of a relative velocity.
    Unclamped it keeps 0.22 with a sign flip, and two ff-1 steps keep 0.12.
  - Undoing it costs the plan field, one uniform and one multiply per pair.
- **Where it lives.**
  - `physics_core.smoothingGain(clock, nuMax)` computes `g`.
  - `sim_registry.substepPlan` adds `effSmoothGain` beside `effStiffness`, from the substep's clock at
    `ff / count`. `LiveValues` gains `friction` and `sphViscosity` for it.
  - The host writes it into one more `SimParams` word. SimParams writes 692 of its 704 allocated bytes
    (`src/gpu_types.nim:738-739`), so the word fits the allocation.
  - `forces-sph.wgsl:273` multiplies `velocitySmoothCoeff` by it. The oracle's `sweepFluid` multiplies
    its `smoothCoefficient` (`src/balance_core.nim:600`) the same way.
- **Alternative: a limit on the whole update from each particle's own `ν_i`, folded into `s`:
  `s_V = min(1, (B/θ)/(h·min(1, 2ν_i)))`.** It settles too: p99 0.0030–0.0036 at ff 10–30
  (`spike-s17/fluid/v2_ff*_v1.0.log`, section V'). But it binds on 99.98–100% of particle-steps and holds
  max speed at ff 30 to 0.48–0.54, against the clamp's 2.9–3.4. At the range's viscosity ceiling it
  leaves ff 12 and 30 unsettled (p99 2.75–2.88 and 0.73–0.75, `v2_ff{12,30}_v2.5.log`), where the clamp
  reads 0.0030–0.0039. Scaling the carried velocity removes `ρ`'s positive share of the multiplier. It
  also needs `ν_i` in one more word per particle beside `sphDensityDeltaFixed` (`forces-sph.wgsl:68`).
  Rejected.
- **Alternative: the pressure slope in `D`.** It left ff 12–30 unsettled. Rejected.
  `sph_core.sphPressureSlope`, committed on `tmu-oracle` (`702306f`), serves no limit under this design.

### What the design claims below ff 1

Below ff 1 the design claims the map's stability and its matched-time motion. It does not claim the f32
position sum.
- **Stability.** `ρ` lies in (r, 1], so `B` lies between `θ·r` and `θ − B∞·(1/r − 1)` (1.76 to 1.836 at
  r 0.88), inside D4's condition `B < 2(1 + sρ)`.
- **The map is no warmer below ff 1.** With each position summed in float64 and stored rounded to f32,
  ff 0.42 reads 0.000062 against ff 1's 0.000077 in the same run (`spike-s17/contact/p_k0_posf64.log`,
  S17 P). The run's ff 1 matches S15's 0.000074 within 4%.
- **What the f32 sum adds.** Both the oracle and the shader sum `x + ff·u'` in f32
  (`src/balance_core.nim:305`, `integrate.wgsl:138-139`). Below ff 0.7 the sum adds 5.2e-5 to 6.5e-5 of
  travel per step, flat in ff (S14), so per reference frame it reads as that amount over ff and rises as
  ff falls. At ff 0.42 the f32 run reads 0.000131 at all three seeds (`spike-s14/s14_window7500.log:3`).
  Its median particle moves 0.00011 per reference frame, against 0.00001–0.00002 with the float64 sum.
  The median particle's f32 reading is the rounding.
- **Sacrifice.** The design keeps the floor. At ff 0.42 it adds under 7e-5 world units per reference
  frame, against an interaction radius of 50, and a gate that compares matched-time motion below ff 1 in
  f32 reads it. Undoing that is compensated summation.
- **Alternative: compensated summation.** A second f32 per particle carries each sum's rounding
  remainder. It removes the floor at 8 bytes a particle (1 MB at 128 000) and one more read and write
  per step. Not taken.

### Rejected approaches (the design report, "Approaches, ordered by fit")

| Approach | What it would have bought | Why not |
|---|---|---|
| B: an ff ceiling through substeps (`FF_MAX` 1) | Removes every step above ff 1 | Leaves ff 0.42's 2.5× mobility, and D3, D6, D7. Time Scale 5 at 128k keeps 61% (30 s figures) to 17% (150 s) of its requested speed (`docs/perf-report.md:142-143` arithmetic) |
| A + B | D1 with a bounded step | Needed only if the limit fails. S11 did not reach its kill (ff 30 at 0.92×) |
| C: fixed step with interpolated rendering | Every step exactly ff 1 | A 1 MB previous-position buffer at 128k, torus unwrap in the blend, displayed positions one reference frame late, frame-time jitter of one full step, and B's Time Scale 5 figures |
| Semi-implicit contact step | Unconditional contact stability | It is a stability scheme, not a units fix, and overlaps D4 |
| Standing still | No work | Mobility spreads 820× from ff 0.42 to ff 30, and the species-only world at ff 10 reads 44× its ff-1 bound (`spike-s7/run_r6c.log`) |

### Boundaries

| Boundary | What crosses, which way | Guarantee | Why each side changes |
|---|---|---|---|
| Host clock → integrate | ff, ρ, h, B, α, θ_c, the floor `λ·min(1, 1/ff)`; host to shader, one uniform block per substep | Every value derives from one `(ff, r)` through `stepClock` | The host with the time model, the shader with the per-particle map |
| forces → integrate | `D` (two words) and `C` (two words) per particle, in the crowd buffer | Both are summed restoring slopes per reference frame, fixed point | forces with the pair laws, integrate with the limit |
| Integrate → render and glow | `p.vel` through the particle buffer | Travel per reference frame | Render with the look, integrate with the physics |
| Host → field | `FieldSteps` and the cached frame description | Σ steps = 7 × reference frames elapsed, within the carry, below the ceiling and above the floor | The field with the chemistry, the clock with the time model |
| Plan → forces-sph | `g` per substep, host to shader in `SimParams` | `g` derives from the substep's clock and the live fluid values through `smoothingGain` | The plan with the frame's substeps, forces-sph with the pair law |
| Run loop → fade pass | the frame's whole frame factor, app to `webgpu_render.render`; `frameFadeFor`'s value in `FADE_AMOUNT` | The product of the frame fades over any span is `fadeRef^(reference frames elapsed)` | The loop with the clock, the renderer with the look |

IntegrationParams grows from 8 to 16 f32s, declared as `IntegrationParamsLayout` in `src/gpu_types.nim`
and generated into `web/shaders/modules/integration_params.wgsl` like the other uniforms. h, B, α, θ_c,
the floor, the pressure onset and D5's mean-field gain `K·FRAME_DT_REFERENCE·12/R` take the two pads and
five new slots, and three pads keep 16-byte alignment. No new binding or pass is added.

### Tests, in writing order

Each test fails for one reason and takes its expected value from the algebra here, not from the code
under test.

| # | Name | File | Grain | Oracle | Fails only if |
|---|---|---|---|---|---|
| 1 | "A Damped Clock At Frame Factor 1 Is The Landed Step" | `tests/test_physics.nim` | unit | `ρ = h = r`; `u'` within 1 ulp of `r·s·(v + Δ)` | `h` is wrong at ff 1 |
| 2 | "A Constant Force Moves A Frictionless Particle The Same Distance At Every Frame Factor" | `tests/test_physics.nim` | unit | `Δ·T·(T + ff)/2`, T 60, ff ∈ {0.42, 1, 10, 30} | the position omits ff or the delta keeps it |
| 3 | "Terminal Speed Per Reference Frame Is r/(1−r) Times The Force At Every Frame Factor" | `tests/test_physics.nim` | property | the map's fixed point; ff ∈ [0.05, 30], r ∈ [0.5, 1) | `h` breaks the terminal value |
| 4 | "A Held Frame Carries Speed Unchanged" | `tests/test_physics.nim` | unit | r 1, Δ 0: `u` equal after ff 0.42 then ff 3 | velocity is stored per step |
| 5 | "The Cap Bounds Speed Per Reference Frame At Every Frame Factor" | `tests/test_physics.nim` | unit | `|u'| ≤ maxVelocity`, travel ≤ `ff·maxVelocity`, ff ∈ {0, 0.42, 1, 30} | the cap still divides by ff |
| 6 | "Density Smoothing Is Per Reference Frame" | `tests/test_physics.nim` | unit | two steps at ff 0.5 equal one at ff 1: `(0.7^0.5)² = 0.7` | smoothing stays per step |
| 7 | "A Species Pair's Restoring Slope Is Its Radial Derivative" | `tests/test_physics.nim` | unit | central difference ε 1e-4, both force models, 50 distances | the analytic derivative is wrong |
| 8 | "The Step Limit At Frame Factor 1 Is The Landed Bound" | `tests/test_physics.nim` | unit | `min(1, θ/(2D))` | `B` breaks ff 1 |
| 9 | "The Resized Limit Keeps Every Contact Mode Decaying" | `tests/test_physics.nim` | property | with `s = s_D`, roots of `μ² − (1 + sρ − s·ff·h·2D)·μ + sρ` have modulus ≤ 1, and < 1 wherever r < 1; ff ∈ [0.05, 30], D ∈ [1e-4, 100], r ∈ [0.5, 1] | `B`, its `h` or its `B∞` term leaves the contact bound |
| 10 | T5h "Theta C Follows Friction And Smoothing" | `tests/test_physics.nim` | unit | the three-state radius computed in the test: ≤ 1 at `2·θ_c`, > 1 at `2·θ_c + 1e-4`; ρ ∈ {0.95, 0.88, 0.5}, α ∈ {0.7, 0.7^0.42, 0.7^10}, all under the ceiling (`spike-s17/thetac_t5h_grid.log`). At ρ `0.88^30`, α `0.7^30`, θ_c is `LOOP_GAIN_SEARCH_CEILING / 2` and the radius there is ≤ 1 | `loopGainBound` is wrong |
| 11 | T5e "The Loop Limit Never Lets A Frame Factor Outgrow Frame Factor 1" | `tests/test_physics.nim` | property | M8's grid and criterion, map built in the test; control fails at θ_c 0.009 held | form F's reach or floor is wrong |
| 12 | T5g "A Limited Step Scales The Carried Velocity" | `tests/test_physics.nim` | unit | Δ 0, s 0.25: `u' = 0.25·ρ·u` | `s` leaves the carried velocity |
| 13 | T5f "The Loop Gain Bounds The Measured One" | `tests/test_balance_core.nim` | unit | finite difference over a 200-particle crowd | `C` under-counts |
| 14 | "The Oracle Step Matches The Clock At Every Frame Factor" | `tests/test_balance_core.nim` | unit | one particle, tests 2 and 3's values through `integrateParticles` | the oracle mirrors the old map |
| 15 | "The Integration Uniforms Come From One Clock" | `tests/test_sim_registry.nim` | unit | `stepClock(ff, r)` accessors equal the written block, ff ∈ {0, 0.42, 1, 30}, r ∈ {1, 0.88} | the producer computes a value apart from the clock |
| 16 | "Generated IntegrationParams Layout" | `tests/test_gpu_types.nim` | unit | 16 floats, 64 bytes; field offsets are checked at build time by `toWgslStruct` | the layout or its allocation drifts |
| 17 | "The Field Runs Seven Steps Per Reference Frame On Any Display" | `tests/test_field_core.nim` | unit | 600 reference frames at ff 1 (600 frames) and ff 0.42 (1 429 frames): Σ steps 4 200 within 2 | steps stay per rendered frame |
| 18 | "Every Field Step Count Is Odd And Within Its Bounds" | `tests/test_field_core.nim` | property | ff ∈ [0, 30] sequences: `steps` odd, 1 ≤ steps ≤ 71, carry ∈ [−1, 2) | the rounding or clamp is wrong |
| 19 | "A Held Frame Drops The Field Steps Past The Ceiling" | `tests/test_field_core.nim` | unit | ff 30: 71 steps, carry ≤ 1 | the ceiling is missing |
| 20 | "The Frame Description Follows The Clock's Count" | `tests/test_sim_registry.nim` | unit | for each odd count 1–71: chain alternates, starts and ends `rdStepToFront` | a cached description holds a stale count |
| 21 | T7s "The Species-Only World Stays Settled At Every Frame Factor" | `tests/test_balance_core.nim`, `just calibrate-balance` | integration, 2 000 particles | matched world time (reference frames 7 500–9 000); ff 10 and 30 ≤ 3× the same run's ff 1 | the map or the limit leaves warmth |
| 22 | "A Trail Keeps The Same Share Over The Same World Time At Every Frame Factor" | `tests/test_trail_core.nim` | property | `TRAIL_RESIDUAL_FRACTION^(Σ ff / (L · TRAIL_FRAMES_PER_DIAMETER))` against the product of `frameFadeFor(L, ff_i)`; L over the slider sweep above 0, ff sequences drawn from [0, 30], spans of 1, 120 and 600 reference frames | the frame fade ignores ff |
| 23 | "A Zero-Length Trail Clears At Every Frame Factor" | `tests/test_trail_core.nim` | unit | 0 at L 0, ff ∈ {0, 0.084, 0.42, 1, 30} | the power runs before the zero branch |
| 24 | "A Frame That Advances No World Time Keeps The Trail Whole" | `tests/test_trail_core.nim` | unit | 1 at ff 0, L ∈ {1, 25, 200} | a stopped frame fades |
| 25 | "The Smoothing Gain Is Whole At Or Below A Substep Of Frame Factor 1" | `tests/test_physics.nim` | property | `g = 1`; substep ff ∈ (0, 1], r ∈ [0.5, 1], `ν_max` ∈ [0, 1.5] | the clamp touches the landed step |
| 26 | "The Clamped Smoothing Keeps Every Velocity Mode Decaying" | `tests/test_physics.nim` | property | `ν_max ≤ 1/2`: `ρ − κ·h·g·ν` ∈ (−1, 1] for κ ∈ [0, 2], ν ∈ [0, ν_max]; `ν_max > 1/2`: `h·g ≤ r` from ff 1 up; ff ∈ [0.05, 30], r ∈ [0.5, 1) | `g`'s bound is wrong |
| 27 | "The Plan Hands The Fluid The Clock's Smoothing Gain" | `tests/test_sim_registry.nim` | unit | `effSmoothGain = smoothingGain(stepClock(ff/count, r), strength·(viscosity + SPH_XSPH_EPSILON))`, ff ∈ {0.42, 1, 12, 30}, count from the same plan | the plan computes `g` apart from the clock |
| 28 | "The Fluid Stays Settled At Every Frame Factor" | `tests/test_balance_core.nim`, under `calibrateBalance` | integration, 2 000 particles | S16's gate: p99 speed at ff 12 and 30 ≤ 3× the same run's ff 1, at `SPH_STIFFNESS_MAX` and `SPH_VISCOSITY_MAX` | the smoothing reaches the oracle unclamped |

The trail suite's existing tests keep their assertions. The names and docs that say "frames" for
persistence say "reference frames", following the rename in D8.

The help lines follow D7, D8 and the proposal. `tests/test_help_content.nim` ("every descriptor is named by
its group's file", `:53`) holds each id's presence, and no test holds the wording.

### Spikes

Each is run by whoever implements the group it gates. Each prediction is written here before any
build.

**S12, GPU cost in-app at 16 000 (128 000 waits for a free machine).**
- Question: do D1–D6 change the frame time?
- Prediction: the per-frame GPU total is within the run-to-run spread of today's at Time Scale 0.5 and 5.
  The field bucket falls by about half at 143 Hz (2.94 steps against 7). Physics per substep rises by
  under 0.05 ms from the two extra words and five uniforms.
- Observation: `[gpu-profile]` lines over 30 s, before and after, at 143 Hz, Time Scale 0.5 and 5.
- Budget: one hour.
- Kill: physics per substep up by more than 0.1 ms. The stride-5 buffer then gets its own measurement
  before 4.9 reads it.

**S13, the field on world time, oracle only.**
- Question: does the pattern depend on how its steps split across frames?
- Prediction: after 600 reference frames, the field from 7 steps a frame at ff 1 and from the clock at
  ff 0.42 (1 and 3 steps, 2.94 on average) differs only by the deposit's frame boundary. With deposits
  off the two are bit-identical, since the chemistry sees the same step sequence.
- Observation: a field hash with deposits off, and the ignited area with deposits on.
- Budget: 30 minutes.
- Kill: deposits off differ, or the ignited area differs by more than 5%. The fold is then per frame and
  must move to per field step before D6 lands.

**S14, why ff 0.42 is warmer under correct units, oracle only.**
- Question: is S10's 1.78× at ff 0.42 (`spike-s7/s10_042.log`) the explicit step damping ff 1 more than
  the continuous system, or the matched-time window catching an unsettled world?
- Prediction, written 22-09-2026 17:25: the step damps stiff contact modes more at ff 1 than at ff 0.42,
  so the reading converges as ff falls.
  - Motion orders ff 0.25 ≥ 0.42 ≥ 0.7 ≥ 1.
  - The 0.25/0.42 ratio is under 1.2, which is closer to 1 than 0.42/1.
  - The 0.42/1 ratio holds within 20% at reference frame 18 000.
  - If this holds, ff 1's reading is the stepper's, and "no warmer than ff 1" is the wrong reference below
    ff 1.
- Observation: the D1 map with `h` and D4's limit, species only, 16 000 particles, seeds 42, 7 and 1001.
  Read at ff 0.25, 0.42, 0.7 and 1 over reference frames 7 500–9 000, and at ff 0.42 and 1 over 16 500–18 000.
- Budget: 90 minutes wall in three lanes.
- Kill: the ratio is flat in ff below 1 and flat in time. That leaves no candidate here, and the residual
  stands open.
- Result: kill reached. 0.25/0.42 reads 2.13, and 0.42/1 grows from 1.72 to 2.26 between reference frames
  9 000 and 18 000 (`spike-s14/result.md`). S17's section P follows it up (What the design claims below
  ff 1).

**S15, the shipped map across frame factors, oracle only, 16 000.**
- Question: do D1, D4 and D5 together (with `h`, `B` and the species slope) hold every ff at ff 1's level,
  with the world pressure on?
- Prediction:
  - Species-only (K 0) and K 540 at friction 0.12: ff 10 and 30 each within 2× of the same run's ff 1,
    with reversals under 1%, because `B` is 0.468× as loose as S11's limit.
  - ff 1 limited share within 2 points of the landed limit's in the K 540 world (`run_r5_k540_f0.12.log`).
- Observation: the gate convention (reference frames 7 500–9 000, seeds 42, 7 and 1001), the limited
  share, and reversals.
- Budget: two hours wall in three lanes.
- Kill: ff 30 above 3× ff 1, or ff 1 limited share up by more than 5 points. D4's `B` then returns to
  design before the oracle group closes.
- Result: kill reached. K 540 at ff 30 reads 3.12× (K 0 2.17×); ff 10 holds in both; the ff 1 limited
  share reads 26.68% against 26.67% (`spike-s15/result.md`). D4's `B` gained its `B∞` term (S17).

**S16, the fluid under D1, oracle only.**
- Question: does the fluid's stiffness clamp still hold at ff above 1, now that a pressure impulse moves a
  particle by `ff·h` per step where the landed map moved it by `ff·r^ff`?
- Prediction: at `SPH_STIFFNESS_MAX` (`src/config_ranges.nim:268`) and the shipped fluid radius, ff 4.2,
  10 and 30 under the plan's substeps stay bounded (max speed ≤ `maxVelocity`, no NaN) over 3 000
  reference frames. A frame at ff 30 runs at most 3 substeps (`SUBSTEPS_MAX`,
  `src/config_ranges.nim:182`), so each spans ff 10 or more, where `h` is 5.29 at 0.12.
- Observation: max and p99 speed, NaN count, against ff 1.
- Budget: one hour.
- Kill: any NaN, or p99 above 3× ff 1. The fluid's pressure slope then joins `D` (D4) before D1 lands on
  the GPU.
- Result: kill reached between ff 10 and 12 (`spike-s16/result.md`). The kill arm's pressure slope in `D`
  did not settle ff 12–30 (`spike-s16/s16_slope.log`). S17 found the channel in the smoothing term, and
  D9 clamps it.

**S17, the revision's spikes, oracle only, 16 000, run.** Each prediction is in `spike-s17/prediction.md`,
written before its run, with its result beneath it.
- **Q, which term binds at K 540, ff 30.** Predicted `s_C` binding most, from θ_c's search ceiling.
  Result: false. `s_D` binds 72.5% and `s_C` 27.3%; lifting the ceiling left motion at 0.000345; loop off
  read 0.012094.
- **B, `B∞` at 1.2, 1.5 and 1.8, ff 10 and 30, K 0 and K 540.** Kill: K 540 ff 30 above 3× at 1.8. Result:
  kill not reached; every value clears 3× (D4's table).
- **S, the stiffer world, K 4320.** Kill: `B∞` 1.2 at ff 30 above 3×. Result: 2.40×, and ff 10 1.16×.
- **T, relaxation or floor at K 540, ff 30.** Kill: the ff 30 / ff 1 ratio at reference frame 18 000 at or
  above its 9 000 value, 2.48. Result: 1.70× (ff 30 0.000107 over ff 1's bound 0.000063); kill not
  reached.
- **F, the fluid's channel.** Kill for the smoothing channel: ff 12 at 0.75× smoothing above p99 1, or
  ff 10 at 1.3× under 0.02. Result: kill not reached (D9).
- **V'', the plan's smoothing clamp.** Kill: any of ff 10–30 above p99 0.02 at the harness's viscosity.
  Result: kill not reached; 0.0030–0.0041 at every seed, at both viscosities (D9).
- **P, f32 position rounding below ff 1.** Kill: ff 0.42 at or above 0.000118 with positions summed in
  float64. Result: kill not reached. ff 0.42 read 0.000062 against its f32 0.000131, and ff 1 0.000077
  against 0.000074 (`spike-s17/contact/p_k0_posf64.log`; the claim below ff 1).

**S18, `B∞` at the friction range's ends, oracle only, 16 000.** Runs on S17's harness
(`spike-s17/contact/`, flag `bInf1.2`), before task 2.3's green.
- Question: does `B∞` 1.2 hold ff 10 and 30 at friction 0.02 and 0.5, where only 0.12 was measured?
- Prediction: K 540 at ff 30 within 3× of the same run's ff 1 bound at both frictions, and ff 10 within
  1.2×. At 0.5, `B` is already 1.2 at ff 10 (ρ 0.001), so ff 10 and 30 read alike. At 0.02, `B` at ff 30 is
  1.62, near S15's 1.53, so the reading sits near S15's shape.
- Observation: the gate convention (reference frames 7 500–9 000, seeds 42, 7 and 1001), ff 1, 10 and 30,
  friction passed as `0.02` and `0.5` explicitly.
- Budget: 40 minutes wall, two lanes.
- Kill: ff 30 above 3× at either friction. `B∞` then becomes a function of `r`, and D4 returns to design.

## Risks / Trade-offs

- **[The 143 Hz look changes]** → Mobility falls 2.5×, the field slows 2.4× in wall time, and streaks
  lengthen 2.4×. The user chose ff 1 as the reference and may retune by ear. Constants keep their ff-1
  meaning, so no existing constant's value moves in this change.
- **[Below ff 1 the f32 matched-time reading is warmer than ff 1]** (0.000131 against 0.000062 with a
  float64 sum at ff 0.42) → Accepted: the map is no warmer (S17 P), and the floor is the f32 position
  sum. `core-force-interface` 4.5's comparison below ff 1 needs restating; tasks.md's foot note carries
  it.
- **[ff 30 reads 2.4–2.5× ff 1 at matched time in pressured worlds]** (K 540 2.48×, K 4320 2.40×) → The
  crowd is still relaxing at reference frame 9 000; at 18 000 K 540 reads 1.70× (S17 T). T7s gates at 3×.
- **[`B∞` is measured at friction 0.12 only]** → S18 reads 0.02 and 0.5 before task 2.3's green.
- **[5–6.5% of moving particle-steps reverse at ff 10]** → Accepted as a measured note (D4). Task 7.2
  watches for flicker at Time Scale 5.
- **[The smoothing clamp weakens the fluid's smoothing past a substep of ff 1]** → Accepted at every ff,
  Time Scale 1.19–2.23 on 143 Hz included (D9's sacrifice, the user's choice on 22-09-2026). Task 7.2
  reads the fluid's look at Time Scale 5.
- **[The clamp's stability above `ν_max` 1/2 rests on the mode factor, not on a bound]** → S17 V'' read the
  range's ceiling settled at ff 12 and 30. Test 28 holds it at `SPH_VISCOSITY_MAX`.
- **[θ_c's search ceiling caps it at 5 from ff 19 at 0.12]** → Accepted. The cap only tightens `s_C`, and
  lifting it moved motion by under 1% (D5).
- **[The world-pressure requirement states the landed bound]** (`ff·λ_max ≤ θ` in
  `core-force-interface/specs/world-pressure/spec.md:157-166` on `cfi-crowding`) → a note in tasks.md
  records the restatement under D4 for whoever reconciles the two changes' specs.
- **[Field steps run ahead of world time below Time Scale 0.17 at 143 Hz]** → Accepted. Today's floor
  behaves the same, and the carry clamp keeps the field from stalling afterward.
- **[θ_c's bisection runs on the CPU per substep]** → Unmeasured; S12 reads frame time.
- **[Trails change length in wall time with the Time Scale and the display]** → At 143 Hz a trail lasts
  2.4× longer in wall time than today, matching 60 Hz. At Time Scale 5 it lasts a tenth of its Time Scale
  0.5 wall time, and at 0.1 five times as long, since it covers the same world travel. `render.wgsl`'s
  elongation (`trailLength · TRAIL_ELONGATION_PER_DIAMETER`) is per diameter and does not move.

## Migration Plan

- **Preconditions.** Both `cfi-crowding` (`4c24c4d`…`3eee226`) and `cfi-crowding-gpu` (`886bb7a`,
  `c09b105`) merge to `dev`, and `tm-units` rebases onto that `dev`. Neither branch contains the other,
  and both fork from `ea5fff5`.
- **Order.** The groups land as D2/D1/D3 (oracle), then D4/D5 (limit), then GPU, then the field, then
  help, then the trail fade (D8). Each group ends green on `just happen` and `just check`.
- **Rollback.** Revert the group's commits. At ff 1 every gate on file holds either way, apart from D4's
  species slope, whose ff 1 limited share S15 read at 26.68% against the landed 26.67%.

## Readiness

| Guarantee | Rung | Evidence |
|---|---|---|
| F1 exists as described | specified | the reading of `integrate.wgsl:64-67`, `:110-139` on `cfi-crowding-gpu`, and the Python check in `spike-s7/prediction.md`, S10 section |
| D1's step at ff 1 is the landed step | realized but untested in the tree | S15's port reads ff 1 at 0.000074 / 0.000076, equal to `s10_fast.log` (`spike-s15/result.md`); tests 1 and 8 unwritten |
| D1 with D4's `B∞` 1.2 holds ff 10 and 30 within 3× of ff 1 | realized but untested, in a spike port at friction 0.12 | `spike-s17/contact/b_*_binf1.2.log`, `s_k4320_binf1.2.log`: 0.79–1.16× at ff 10, 1.08–2.48× at ff 30; other frictions wait on S18 |
| Below ff 1, the map's matched-time motion no warmer than ff 1 | realized but untested, in a spike port at K 0, friction 0.12, ff 0.42 | `spike-s17/contact/p_k0_posf64.log`: 0.000062 against ff 1's 0.000077 with a float64 position sum; the f32 reading stays 0.000131 (`spike-s14/s14_window7500.log:3`) |
| D5 keeps the loop stable at every ff | specified, with the term realized in the spike port | `lagmodel8.log` (model); the port's loop term on in S15 and S17, off reading 35× (`q3_k540_ff30_loopoff.log`) |
| D9 settles the fluid at ff 10–30 | realized but untested, in a spike port at `SPH_STIFFNESS_MAX` | `spike-s17/fluid/v3_*.log`; test 28 unwritten |
| D6 keeps the pattern | realized, tested at unit grain | S13's kill not reached (`spike-s13/result.md`); tests 17–20 (tasks 4.1–4.2) |
| No GPU cost | asserted | S12 |
| D8 keeps a trail's share per world time on any display | realized, tested at unit grain | tests 22–24 (`tests/test_trail_core.nim:228-260`); the wiring through `render` has no native test |

Readiness is **asserted**, the lowest rung among these, held there by S12. S18 moves the contact row to
every friction, tests 1, 8, 9 and 21 move D1 and D4 into the tree, test 28 does the same for D9, and S12
moves the cost row.
