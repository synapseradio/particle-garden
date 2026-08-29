## RENAMED Requirements

- FROM: `### Requirement: The fraction ships at the whole interaction radius`
- TO: `### Requirement: The fraction ships at the whole interaction radius over a measured floor`

## MODIFIED Requirements

### Requirement: The fraction ships at the whole interaction radius over a measured floor

The shipped fraction default SHALL be `1.0` (`src/ui/state/simulation_state.nim:113-116`, mirrored
in `src/preset.nim:243-248`), the whole interaction radius, which is the kernel every fluid world
already watched has run. That choice is recorded beside the constant, and no comment anywhere states
the default as anything else.

`SPH_RADIUS_FRACTION_MIN` SHALL be strictly positive, because a zero smoothing radius divides by
zero in both kernel normalizations (`src/config_ranges.nim:150-179`), and SHALL be a measured bound
recorded beside itself under the range authority's measured-bound rule. The calibration finds:

- **f_inert**, the fraction at which the fluid computes nothing. Measured with the species force at
  zero and crowding strength at zero, so the result is a property of the fluid alone, and at
  `INTERACTION_RADIUS_MIN`, the narrowest radius the fraction multiplies. `f_inert` is the largest
  swept fraction whose settled lit share is within three standard deviations of the same fixture
  running with the fluid switched off.

`SPH_RADIUS_FRACTION_MIN` SHALL sit above `f_inert` by a stated margin, so the narrowest kernel the
slider offers does something at the narrowest interaction radius the slider offers. The measured
value, the margin, and the conditions SHALL appear beside the constant: both fixtures, the
interaction radii swept, the fluid settings, the canvas dimensions, and the world-seconds of
settling.

The floor decides the worst-case stiffness ceiling, which is linear in the smoothing radius
(`src/sph_core.nim:135-176`), so raising the floor raises that ceiling and can strand no labelled
stiffness notch. The notch sweep in `tests/test_param_descriptor.nim` reads the floor from the range
authority and re-scopes itself.

**agent-checkable** for the floor matching its record: an agent launches the app, sets the
interaction radius to its minimum, switches the fluid to full strength with the species force at
zero, drags the fraction to its floor, and compares the canvas against the same world with the fluid
off. A floor at which the two frames agree within the recorded repeat spread means the fluid
computes nothing at the bottom of its own slider, and the floor rises. No automated gate detects
this, because the native suite executes no GPU.

No saved world is rescaled by a change to the floor or the default. The fraction is carried in the
preset schema and clamped on decode like every schema field (`src/preset.nim:416-418`), and the v1
branch of the versioned decode pins it to exactly `1.0` (`src/preset.nim:639-645`), because `1.0` is
the kernel those worlds ran when they were saved.

#### Scenario: The floor clears the inert region

- **WHEN** the recorded `f_inert` is read beside `SPH_RADIUS_FRACTION_MIN`
- **THEN** the floor exceeds it by the recorded margin, so the fraction's lowest offered position
  produces a fluid that acts

#### Scenario: The floor rises and every stiffness notch survives

- **WHEN** `SPH_RADIUS_FRACTION_MIN` is raised
- **THEN** the derived-bound notch sweep in `tests/test_param_descriptor.nim` re-scopes from the new
  floor and stays green, because the worst-case stiffness ceiling rises with it

#### Scenario: A saved fluid world is reproducible

- **WHEN** a preset carrying a fraction is applied
- **THEN** the fraction it carries is restored and clamped like every schema field, so the world's
  fluid scale survives the round trip

#### Scenario: A schema-version-1 fluid world keeps its kernel

- **WHEN** a preset written under schema version 1 is applied
- **THEN** the fraction decodes to exactly `1.0`, never to the shipped default, so the world looks
  as it did when it was saved
