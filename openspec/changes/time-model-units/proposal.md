# Proposal

## Why

The same world, played for the same world time, reaches a different state depending on the display's
rate, the Time Scale and held frames. The stored particle velocity is travel per step:
`integrate.wgsl` moves a particle by it with no frame factor, and the speed cap divides it by
`frameFactor` to read it per reference frame (`web/shaders/src/integrate.wgsl:138-139`, `:123` on
`cfi-crowding-gpu` at `c09b105`). The decoded force delta adds `ff·Δ` (`:64`, `:67`), where a per-step
velocity needs `ff²·Δ`, so a force accelerates a particle by `Δ/ff` per reference frame.
- Frictionless from rest at world time 60, a constant unit force carries a particle 4 324 at ff 0.42,
  1 830 at ff 1, 210 at ff 10 and 90 at ff 30. The exact value is 1 800.
- At friction 0.12 per reference frame, a unit force's terminal travel per reference frame is 18.1, 7.33,
  0.386 and 0.022 at the same four frame factors. It is 7.33 at every ff under a consistent model.
- The species-only world at ff 10 settles 44× warmer than at ff 1 at matched world time
  (`run_r6c.log`). The world is still settling there, not unstable: it reverses direction on 0.01% of
  steps against ff 1's 0.18%.

The measurements are recorded in `~/.scratchpad/particle-garden/cfi-crowding/spike-s7/prediction.md` (S9,
S10, S11) and the design report `design-decouple-frame-rate__04-40PM_22-09-2026.md` in the same
directory. The user chose to fix the units (approach A of that report), with ff 1 as the reference look.

Two more couplings follow the display:
- The chemistry runs `RD_STEPS_PER_FRAME` (7) steps per rendered frame whatever the frame's length
  (`src/field_core.nim:95`, `:188-201`). At 143 Hz it runs 2.4× faster against the particles than at
  60 Hz.
- Streaks and glow read the per-step speed (`web/shaders/src/render.wgsl:91-97`,
  `web/shaders/src/glow.wgsl:89-90`).
- The trail fades by a fixed share per rendered frame (`src/trail_core.nim:51-62`,
  `src/webgpu_render.nim:1488`). At 143 Hz a trail lasts 0.42× the world time it lasts at 60 Hz.

This change builds on the time model of `core-force-interface` as it stands on two unmerged branches:
- `cfi-crowding` (`4c24c4d`…`3eee226`) holds friction per reference frame, the 0.12 default, and the
  step limit on the whole velocity.
- `cfi-crowding-gpu` (`886bb7a`, `c09b105`) holds the same on the GPU.

## What Changes

- **BREAKING (look):** the particle velocity is stored as travel per reference frame. The position update
  carries the frame factor, and a force's delta enters through a gain `h(ff, r)` that makes terminal speed
  and frictionless acceleration exact at every frame factor. At ff 1 the step equals today's up to f32
  rounding.
  - At 143 Hz (ff 0.42), a unit force's terminal speed falls from 18.1 to 7.33 per reference frame, the
    ff-1 value every constant was measured at. The user may retune by ear later.
- The step limit counts the species force's restoring slope as well as the world pressure's. Its bound
  keeps ff 1's share of the step's stability bound at every frame factor. At ff 1 the bound is the landed
  one, and the species slope is the one addition.
- The density-loop term held pending on `cfi-crowding` lands here, re-derived for the new map. It is the
  lagged-density gain `C` against `θ_c`, λ 0.1.
- Colony and crowd density smoothing retain `0.7^ff` per step, so the smoothing is per reference frame.
- **BREAKING (look):** the field owes steps from world time: 7 per reference frame, run as an odd count
  per frame under a per-frame ceiling.
  - At 143 Hz and Time Scale 0.5 it runs 2.94 steps a frame on average, where it runs 7 today.
  - A frame past the ceiling drops the rest, the way the 0.05 s cap drops wall time.
- **BREAKING (look):** streak length and velocity glow read travel per reference frame, the same on every
  display. At 143 Hz streaks lengthen 2.4×.
- **BREAKING (look):** the trail fades per reference frame of world time. At 60 Hz and Time Scale 0.5
  every trail reads as today. At 143 Hz trails last 2.4× longer in wall time than today, the 60 Hz length.
  A trail now covers the same world travel at any Time Scale, so at Time Scale 5 it lasts a tenth of its
  Time Scale 0.5 wall time.
- Help lines for `timeScale`, `maxVelocity`, `trailLength`, `velocityGlowScale` and the field's Time
  Scale note state the per-reference-frame meaning.

## Capabilities

### New Capabilities

- `time-model`: how one step advances the world. It covers velocity and position units, the force and
  friction gains, density smoothing, the step limit's bound and the density-loop term, the field's clock,
  what a streak measures, and the trail fade.

### Modified Capabilities

- `gpu-frame-registry`: "The field ping-pong chain closes every frame" changes from a fixed
  `RD_STEPS_PER_FRAME` per frame to a per-frame odd step count owed from world time.

## Impact

- `src/physics_core.nim` (the step clock, `integrateVelocity`, `stepLimit`, the species slope, the loop
  bound), `src/balance_core.nim` (`integrateParticles`, `sweepPairs`), `src/config_ranges.nim`,
  `src/shader_config.nim`, `src/gpu_types.nim` (IntegrationParams grows to 12 floats),
  `src/sim_registry.nim`, `src/webgpu_init.nim` (crowd buffer stride 3 to 5), and
  `src/webgpu_compute.nim`.
- `web/shaders/src/integrate.wgsl` and `web/shaders/src/forces.wgsl`. `web/shaders/src/render.wgsl` and
  `glow.wgsl` keep their code: the velocity they read changes unit.
- `src/field_core.nim` (the field clock) and `src/ui/api/response_probe.nim` (two doc comments and
  one call's rename).
- `src/trail_core.nim` (`frameFadeFor`, the persistence rename, `TRAIL_FRAMES_PER_DIAMETER`'s doc),
  `src/webgpu_render.nim` (`render` takes the frame factor) and `src/app.nim` (passes it).
- `tests/README.md`, the trail rows' persistence unit.
- `docs/help/10-simulation.md`, `40-rd.md`, `50-render.md`, `51-glow.md`.
- Tests: `tests/test_physics.nim`, `test_balance_core.nim`, `test_field_core.nim`,
  `test_sim_registry.nim`, `test_gpu_types.nim`, `test_trail_core.nim`.
- `core-force-interface` tasks that wait on this change: 4.5 (G1.2, the K 540 vs 1728 table and the G1
  arms at 128 000), 4.6 (the 128 000 stacked hold), 4.7 (the recorded constants), 4.9 (the in-app
  cost), and 12.1's Time Scale 5 hold.
- **Measurement gates** (specified in design.md, Spikes):
  - S15: the shipped map across frame factors, with the world pressure on.
  - S14: why ff 0.42 reads 1.78× ff 1 under correct units.
  - S16: the fluid under the new gain.
  - S13: whether the field pattern depends on how its steps split across frames.
  - S12: the GPU cost in-app.
