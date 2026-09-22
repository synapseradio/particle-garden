# Spec Delta

## Purpose

How one step advances the world: which units the particle velocity carries, how a force, friction and
density smoothing act over a step of any length, how the step stays stable, how the field keeps world time,
and what a streak measures. The goal is that the same world played for the same world time reaches the
same state on any display, at any Time Scale, and through held frames.

## ADDED Requirements

### Requirement: Velocity is travel per reference frame

A particle's stored velocity SHALL be its travel per reference frame (1/120 s of world time). A step
spanning frame factor `ff` SHALL move the particle by `ff` times its new velocity. Every writer's delta
SHALL enter the velocity through one force gain `h = r·(1 − r^ff)/(1 − r)` (`h = ff` at `r = 1`) applied to
the delta per reference frame, and friction SHALL retain `r^ff` of the carried velocity. At frame factor 1
the step SHALL equal `r·s·(v + Δ)` up to f32 rounding.

**agent-checkable** at the unit grain. Enforced by `tests/test_physics.nim`: "A Damped Clock At Frame
Factor 1 Is The Landed Step", "A Constant Force Moves A Frictionless Particle The Same Distance At Every
Frame Factor", "Terminal Speed Per Reference Frame Is r/(1−r) Times The Force At Every Frame Factor" and
"A Held Frame Carries Speed Unchanged". The shader's mirror is `web/shaders/src/integrate.wgsl`. No native
test runs WGSL, so the shader is held by `tests/test_sim_registry.nim` "The Integration Uniforms Come From
One Clock" for its inputs, and by the in-app procedure for its effect.

#### Scenario: A constant force at two frame factors

- **WHEN** a frictionless particle takes a constant force for 60 reference frames, once in steps of frame
  factor 1 and once in steps of frame factor 10
- **THEN** each travels `Δ·T·(T + ff)/2` for its own `ff`, which is 1 830Δ and 2 100Δ

#### Scenario: Terminal speed under friction

- **WHEN** a constant force acts under retention `r` until the speed stops changing, at any frame factor
  from 0.05 to 30
- **THEN** the speed per reference frame is `r/(1 − r)` times the force

#### Scenario: A held frame

- **WHEN** a particle moving with no force and no friction takes a step at frame factor 0.42 and then one at
  frame factor 3
- **THEN** its velocity is unchanged, and the second step moves it 3/0.42 times as far as the first

### Requirement: The speed cap bounds speed per reference frame

The soft cap SHALL act on the velocity per reference frame and hold it at or below `maxVelocity`, whatever
the frame factor, the stopped clock (frame factor 0) included.

**agent-checkable.** Enforced by `tests/test_physics.nim` "The Cap Bounds Speed Per Reference Frame At
Every Frame Factor".

#### Scenario: A capped particle on a long step

- **WHEN** a particle beyond the cap steps at frame factor 30
- **THEN** its stored speed is at most `maxVelocity` and its travel that step at most `30 · maxVelocity`

### Requirement: Density smoothing is per reference frame

The smoothed colony and crowd densities SHALL carry `0.7^ff` of their previous value per step, so the
smoothing's time constant is fixed in world time. The 0.7 is `densitySmoothFactor`.

**agent-checkable.** Enforced by `tests/test_physics.nim` "Density Smoothing Is Per Reference Frame".

#### Scenario: Two half steps and one whole step

- **WHEN** a density is smoothed toward the same target by two steps at frame factor 0.5, and separately by
  one step at frame factor 1
- **THEN** both results are equal to f32 rounding

### Requirement: The step stays stable at every frame factor

A particle's step SHALL be scaled by a limit `s ≤ 1`, applied to its carried velocity and its delta
alike. `s` SHALL hold every restoring contact mode inside the stability bound of the step, at the share of
that bound frame factor 1 uses, for the summed restoring slope of the species force and the world pressure
the particle receives. It SHALL also hold the lagged density loop no less stable per reference frame than
at frame factor 1. At frame factor 1, with no species slope, `s` SHALL equal `min(1, θ/(2D))`.

**agent-checkable** at the unit grain, and at matched world time in the oracle. Enforced by
`tests/test_physics.nim`: "The Step Limit At Frame Factor 1 Is The Landed Bound", "The Resized Limit
Keeps Every Contact Mode Decaying", "A Species Pair's Restoring Slope Is Its Radial Derivative", "Theta C
Follows Friction And Smoothing", "The Loop Limit Never Lets A Frame Factor Outgrow Frame Factor 1" and "A
Limited Step Scales The Carried Velocity". Also `tests/test_balance_core.nim` "The Species-Only World Stays
Settled At Every Frame Factor", under `just calibrate-balance`.

#### Scenario: A species-only world at a large frame factor

- **WHEN** a species-only world of 2 000 particles runs at shipped friction to reference frame 9 000 at
  frame factors 1, 10 and 30
- **THEN** the motion per reference frame read over reference frames 7 500–9 000 at 10 and 30 is at most 3×
  that at 1

#### Scenario: A stiff contact at every frame factor

- **WHEN** a particle's summed restoring slope is anywhere from 1e-4 to 100, at retention 0.5 to 1 and
  frame factor 0.05 to 30
- **THEN** the limited step's contact mode decays

### Requirement: The field keeps world time

The reaction-diffusion field SHALL run 7 steps per reference frame of world time, carried across rendered
frames. Each frame SHALL run an odd count of at least 1 and at most 71. Steps owed past 71 in one frame
SHALL be dropped, and below one owed step per frame the field SHALL run 1 step.

**agent-checkable.** Enforced by `tests/test_field_core.nim`: "The Field Runs Seven Steps Per Reference
Frame On Any Display", "Every Field Step Count Is Odd And Within Its Bounds" and "A Held Frame Drops The
Field Steps Past The Ceiling".

#### Scenario: Two displays

- **WHEN** 600 reference frames of world time pass at Time Scale 0.5, once on a 60 Hz display and once on a
  143 Hz display
- **THEN** the field runs 4 200 steps on each, within 2

#### Scenario: A held frame at Time Scale 5

- **WHEN** one frame spans 30 reference frames
- **THEN** the field runs 71 steps that frame and carries fewer than 2 into the next

### Requirement: Streaks and velocity glow read travel per reference frame

Streak length and velocity glow SHALL read the particle's speed per reference frame against
`maxVelocity`, so a particle moving at the same world speed draws the same streak on any display and
through held frames.

**agent-checkable.** The render passes carry no native test. The procedure runs the app with
`./main --serve` at 143 Hz, per the in-app order in `CLAUDE.md`. It reads through `window.gardenAPI` a
settled world at Time Scale 0.5, then at Time Scale 5, then with a frame held past 0.05 s. A streak that
lengthens with the held frame fails the check.

#### Scenario: A held frame

- **WHEN** a frame is held past 0.05 s at Time Scale 5
- **THEN** streak lengths stay those of the frames around it
