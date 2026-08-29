## MODIFIED Requirements

### Requirement: The crowding and scale ranges

`src/config_ranges.nim` SHALL define these tunables' bounds under the standard static non-emptiness
and default-in-range assertions:

- **Crowding strength.** The range SHALL include zero, and zero SHALL be an ordinary reachable
  slider position, because strength zero is exactly the uncrowded force law and keeping it reachable
  is what makes the term bisectable. Zero is a labelled notch, and a static assertion pins
  `CROWDING_STRENGTH_MIN` at zero. `CROWDING_STRENGTH_MAX` SHALL be a measured bound: it sits above
  the measured strength at which ordinary colonies visibly soften, by a stated margin, and the two
  measured strengths, the margin and the conditions appear beside the constant as the measured-bound
  rule requires. The ceiling sweep in `tests/test_physics.nim` reads the constant from here, so a
  recalibration re-scopes the sweep without a second edit.
- **SPH radius fraction.** The maximum SHALL be exactly 1, so a fluid kernel equal to the force kernel
  stays representable — capped there because a smoothing radius past the neighbour sweep's reach would
  silently drop neighbours instead of gathering more. The minimum SHALL be strictly positive, because
  a zero radius divides by zero in both kernel normalizations (`poly6Weight2d` and
  `spikyGradientMagnitude2d` in `src/sph_core.nim`), and SHALL be a measured bound: it sits above the
  measured fraction at which the fluid computes nothing at `INTERACTION_RADIUS_MIN`, by a stated
  margin recorded beside the constant. The floor decides the worst-case stiffness ceiling, so the
  derived-bound notch sweep re-scopes from it and confirms every labelled stiffness notch stays live.
- **Force weather speed.** Bounded like the climate speed, in the same tours-per-minute unit —
  `FORCE_WEATHER_SPEED_MIN` and `FORCE_WEATHER_SPEED_MAX` alias `CLIMATE_SPEED_MIN` and
  `CLIMATE_SPEED_MAX` rather than restating them. `FORCE_WEATHER_DEFAULT_SPEED` SHALL be derived
  from the measured settling time of the tour's slowest segment and record that derivation beside
  itself, and SHALL stay inside the range; where no speed inside the range dwells long enough, that
  is reported as a finding about the tour.

#### Scenario: A measured range bound arrives without its record

- **WHEN** `CROWDING_STRENGTH_MAX`, `SPH_RADIUS_FRACTION_MIN` or `FORCE_WEATHER_DEFAULT_SPEED` is
  changed without the measured value, its conditions and its margin appearing beside it
- **THEN** review rejects it under the measured-bound rule, which no automated gate enforces

#### Scenario: Crowding can be turned off

- **WHEN** the user drags the crowding strength to its minimum
- **THEN** the stored value is exactly zero and the force law is the uncrowded one

#### Scenario: A zero smoothing radius is unrepresentable

- **WHEN** input drives the radius fraction to its minimum
- **THEN** the stored value is strictly positive, and the reason lives beside the constant
