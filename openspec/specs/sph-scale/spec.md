# sph-scale

## Purpose

Owns the scale of the SPH fluid: the smoothing radius the kernels span, expressed as a fraction of
the interaction radius, and the stiffness ceiling that scale implies. One capability because the
fraction and the ceiling answer to each other — the ceiling is a function of the smoothing radius in
pixels, and the fraction's floor is what decides the worst-case ceiling every labelled stiffness
notch must sit below.

The kernels themselves, the Tait equation of state and the XSPH blend belong to `src/sph_core.nim`
as reference oracles for `forces-sph.wgsl`. How a derived bound is represented, served and clamped is
`parameter-range-authority`'s mechanism. The neighbour sweep and its cell sizing belong to the
spatial grid. This spec cites those relations and leaves their detail to them.

## Requirements

### Requirement: The smoothing radius is a fraction of the interaction radius

The SPH smoothing radius SHALL be computed as `params.interactionRadius * params.sphRadiusFraction`
(`web/shaders/src/forces-sph.wgsl:115-116`), with the fraction in `(0, 1]`. A fraction makes the
neighbour sweep's ceiling unrepresentable to exceed: the sweep visits only the cell block around a
particle, and cells are sized to the interaction radius (`src/grid.nim`), so a smoothing radius above
the interaction radius would silently drop neighbours. With the fraction capped at 1 by its range
(`SPH_RADIUS_FRACTION_MAX = 1.0`, `src/config_ranges.nim:181`, held there by a static assertion at
`:463`), that fluid cannot be expressed at all.

The kernels take the radius as a parameter and recompute their normalizations from it
(`poly6Weight2d` and `spikyGradientMagnitude2d`, `src/sph_core.nim:56-93`), so the oracle needs no
restructuring: the native tests sweep the fraction range through the same functions the shader
mirrors (`tests/test_sph_core.nim`, suite "The Smoothing Radius Is A Fraction Of The Interaction
Radius", `:138-210`).

#### Scenario: Fraction one is the whole interaction radius

- **WHEN** the fraction is exactly 1
- **THEN** the smoothing radius, both kernel normalizations, and the resulting pressure and XSPH
  terms are those of a fluid whose kernel is the force kernel, so a world running at 1 is unchanged
  by the fraction's existence

#### Scenario: The fluid keeps its relative scale

- **WHEN** the interaction radius changes at a fixed fraction
- **THEN** the smoothing radius scales proportionally, so the interaction radius remains one
  meaningful control instead of two coupled ones

#### Scenario: The sweep cannot be outrun

- **WHEN** any representable fraction is set
- **THEN** the smoothing radius is at most the interaction radius, by construction and not by clamp

### Requirement: The stiffness ceiling derives from the fluid's configuration

The stiffness the fluid honours SHALL be bounded by a pure function in `src/sph_core.nim`
(`stableStiffnessCeiling`, `:153-176`) of the smoothing radius in pixels — the fraction times the
interaction radius, multiplied by the caller the way `forces-sph.wgsl` does — the substep count, and
the effective timestep. The measured law is `SPH_STABILITY_COEFFICIENT * h * substeps / dt`, linear
in each factor and not the Courant square; `src/sph_core.nim:135-143` records why this integrator
sheds both of the textbook's `1/h` factors. The ceiling is clamped against `SPH_STIFFNESS_MAX`,
which survives only as the absolute envelope and reaches the function as an argument, because the
range authority imports this module and hands its own constant to the function it bounds
(`src/sph_core.nim:160-162`). The ceiling bounds the value's effect and never redefines the stored
value, which stays absolute stiffness — the pressure gain (`taitPressure` and
`flooredTaitPressure`, `src/sph_core.nim:94-113`).

The served ceiling reads its timestep against a fixed reference frame
(`SPH_CEILING_REFERENCE_FRAME_SECONDS`, `src/sph_core.nim:144-151`), because a ceiling built from the
delivered frame would move every frame and shrink during a hitch.

The stability coefficient SHALL be fitted from a measured stability sweep of this integrator —
stiffness against radius fraction and substeps — never assumed from literature, and the
measurement's conditions and margin SHALL be recorded beside the coefficient under the range
authority's measured-bound rule. Native tests hold the derived ceiling below the measured stability
boundary across the reachable input box, so re-running the suite re-checks the fit
(`tests/test_sph_core.nim`, suites "The Fluid Has A Measured Stability Boundary" and "The Derived
Stiffness Ceiling Holds Under The Measurement", `:626-816`).

#### Scenario: Shrinking the radius lowers the ceiling

- **WHEN** the radius fraction falls with substeps and timestep held fixed
- **THEN** the derived stiffness ceiling falls, linearly in the fraction — the measured law,
  recorded beside `SPH_STABILITY_COEFFICIENT` in `src/sph_core.nim`

#### Scenario: More substeps buy more stiffness

- **WHEN** the substep count rises with the fraction and timestep held fixed
- **THEN** the derived ceiling rises, linearly in the substep count, under the same measured law

#### Scenario: The ceiling cannot exceed the envelope

- **WHEN** the deriving inputs take any reachable combination
- **THEN** the derived ceiling is at most `SPH_STIFFNESS_MAX`, asserted by a native sweep over the
  whole input box, and the worst-case ceiling is recorded beside the radius-fraction floor that
  decides it (`src/config_ranges.nim:150-179`) — the floor every labelled stiffness notch must sit
  below, held by the notch sweep in `tests/test_param_descriptor.nim` (suite "Notches Mark Only
  Reachable Positions", `:511-617`), which goes red on the first notch that strands

### Requirement: The fraction ships at the whole interaction radius

The shipped fraction default SHALL be `1.0` (`src/ui/state/simulation_state.nim:113-116`, mirrored in
`src/preset.nim:243-248`), the whole interaction radius, which is the kernel every fluid world
already watched has run. That choice is recorded beside the constant.

`SPH_RADIUS_FRACTION_MIN = 0.1` is a working bound, and states so beside itself
(`src/config_ranges.nim:150-179`): it is strictly positive because a zero smoothing radius divides by
zero in both kernel normalizations, and the value 0.1 is the smallest kernel the slider offers,
chosen to leave room below the default while staying clear of that singularity. The record beside it
carries two measurements bearing on raising it — the linear stiffness-ceiling law, and the inert
region below a smoothing radius of about 2.5 px where both kernels see no neighbour at any
separation.

A calibration placing the fraction default at near-neighbour scale SHALL be measured with crowding
strength at zero, so the result is a property of the fluid alone.

**unenforced**: nothing detects a default or a floor sitting where the fluid does not want it,
because no measurement of appearance and stability across the fraction range exists to compare them
against. Running that sweep and recording its conditions beside both constants closes it. Once
recorded, an agent checks the record by launching the app, enabling the fluid, sweeping the fraction
slider across its range, and reading whether the fluid computes anything at the floor and whether it
holds still at the default.

No saved world is rescaled by a change to the default. The fraction is carried in the preset schema
and clamped on decode like every schema field (`src/preset.nim:416-418`), and the v1 branch of the
versioned decode pins it to exactly `1.0` (`src/preset.nim:645`), because 1.0 is the kernel those
worlds ran when they were saved.

#### Scenario: A saved fluid world is reproducible

- **WHEN** a preset carrying a fraction is applied
- **THEN** the fraction it carries is restored and clamped like every schema field, so the world's
  fluid scale survives the round trip

#### Scenario: A schema-version-1 fluid world keeps its kernel

- **WHEN** a preset written under schema version 1 is applied
- **THEN** the fraction decodes to exactly `1.0`, never to the shipped default, so the world looks
  as it did when it was saved
