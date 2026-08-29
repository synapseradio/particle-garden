# Calibrate the shipped defaults

## Why

Three constants ship with a comment admitting nobody measured them. Each sits on a mechanism that is
built, tested and reachable from a slider, so what is missing is one number chosen by watching the
app run.

- `CROWDING_STRENGTH_MAX = 2.0` calls itself "PROVISIONAL, pending the calibration ... a working
  bound, not a measured one" (`src/config_ranges.nim:46-54`). The attenuation it bounds is complete
  (`src/physics_core.nim:68-107`, mirrored in `web/shaders/src/forces.wgsl`), its density ceiling is
  computed (`src/physics_core.nim:146-224`), and both carry native sweeps
  (`tests/test_physics.nim:96-170` and `:192-243`). The control ships with a probe, a hint and an
  "off" notch (`src/ui/api/param_descriptor.nim:453-460`).
- `SPH_RADIUS_FRACTION_MIN = 0.1` is marked "PROVISIONAL ... a working bound, not a measured one"
  (`src/config_ranges.nim:150-179`). The fraction reaches the kernel
  (`web/shaders/src/forces-sph.wgsl:105-115`), the stiffness ceiling derives from it
  (`src/sph_core.nim:153-176`), and the sweeps run (`tests/test_sph_core.nim:138-210`, `:626-816`).
  Its own record names an inert region the floor may sit inside: below a smoothing radius of about
  2.5 px both kernels see no neighbour at any separation, because the shader floors every pair
  distance at `minDistanceSq = 4.0`, that is 2 px (`src/shader_config.nim:98`), and `0.1 ×
  INTERACTION_RADIUS_MIN` reaches 1 px (`src/config_ranges.nim:33`).
- `FORCE_WEATHER_WAYPOINTS` states of itself "PROVISIONAL, chosen by construction rather than by
  watching ... nothing here has been watched settle" (`src/config_ranges.nim:75-90`), and
  `FORCE_WEATHER_DEFAULT_SPEED = 0.5` carries a `[?]` on its own reasoning
  (`src/climate_core.nim:177-182`). The tour is complete and swept
  (`src/climate_core.nim:147-197`, `src/config_ranges.nim:493-510`,
  `tests/test_climate_core.nim:162-176,285-332`). The in-app help already tells the user the weather
  walks "a closed loop of settled configurations" (`docs/help/10-simulation.md:24-26`), a claim only
  a measurement can make true.

Two comments in `src/preset.nim` assert that the shipped SPH fraction default "sits below 1"
(`:245`, `:642`). The shipped default is exactly `1.0` (`src/preset.nim:248`,
`src/ui/state/simulation_state.nim:116`), so both statements are false today.

## What Changes

- Measure the crowding strength at which a collapsing world stops tightening and the strength at
  which ordinary colonies visibly soften, then set `CROWDING_STRENGTH_MAX` above the second with a
  stated margin and record both measurements, their conditions and that margin beside the constant
  (`src/config_ranges.nim:46-54`).
- Leave the shipped crowding default at `0.0` (`src/ui/state/simulation_state.nim:93`, mirrored at
  `src/preset.nim:220`), which is what the delta spec states today. Whether the measurement should
  move it is the open question below, and it is the one user-visible behavior change this proposal
  could carry.
- Measure the fraction at which the fluid stops computing anything at the narrowest offered
  interaction radius, then raise `SPH_RADIUS_FRACTION_MIN` above it with a stated margin and record
  the measurement beside the constant (`src/config_ranges.nim:150-179`). The shipped fraction
  default stays `1.0`; only the floor carries a provisional marker, and the default carries a reason
  (`src/ui/state/simulation_state.nim:113-116`).
- Correct the two false comments in `src/preset.nim` (`:245`, `:642`) so each states what the code
  does: the v1 branch pins `1.0` because that is the kernel a v1 world ran, and the shipped default
  is also `1.0`.
- Watch each force weather waypoint settle, replace any coordinate that produces a world
  indistinguishable from its tour neighbours, and record what each produces beside the table
  (`src/config_ranges.nim:75-90`).
- Derive `FORCE_WEATHER_DEFAULT_SPEED` from the measured settling time of the slowest segment, so
  the tour dwells long enough for each waypoint to become visible before it leaves
  (`src/climate_core.nim:177-182`, mirrored as a literal at `src/preset.nim:265` under the mirror
  assertion at `tests/test_preset.nim:43`).
- Remove the word "provisional" and the matching **unenforced** labels from the four main specs
  named below, replacing each with the recorded measurement and the agent procedure that re-checks
  it.

No mechanism changes. No control is added or removed. No test's structure changes. Recalibrating
`CROWDING_STRENGTH_MAX` re-scopes the existing ceiling sweep by construction, because
`tests/test_physics.nim:187-190` reads the bound from the range authority instead of restating it,
and the same holds for the notch sweep that reads `SPH_RADIUS_FRACTION_MIN`.

**BREAKING** if and only if the crowding default moves off zero: a fresh world would then run a
force law the other defaults were not chosen against. Saved worlds are unaffected either way,
because the v1 branch pins crowding at `0.0` unconditionally (`src/preset.nim:632-638`) and every
later schema version carries the field explicitly (`src/preset.nim:723`).

## Open question

**Should the calibrated crowding default be nonzero?** The code contradicts itself on this, so the
change cannot settle it from evidence.

- `src/config_ranges.nim:46-54` says the calibration "sets the default between them", between the
  strength that holds a collapsing world open and the strength that softens ordinary colonies. Both
  are strictly positive, so that instruction produces a nonzero default and turns the world's
  anti-collapse property on out of the box.
- `src/ui/state/simulation_state.nim:91-93` says crowding starts off "so the shipped world is the
  force law every other default was chosen against", and `openspec/specs/bounded-crowding/spec.md`
  holds a scenario asserting a fresh world carries no crowding.

The options:

1. **Nonzero, between the two measured strengths.** A fresh world resists collapse. Every other
   shipped default was tuned against the uncrowded law, so each would want re-checking against the
   new one, and the bounded-crowding scenario "A fresh world carries no crowding" is deleted.
2. **Stay at zero, record the measured pair beside the ceiling.** The shipped world is unchanged and
   every other default keeps its warrant. The measurement still lands, as the ceiling's record and
   as a documented setting a user reaches by dragging one slider.

Nothing on disk decides between them: this is a question about what a fresh world should be. The
delta spec ships option 2, the status quo, so the artifacts stay internally consistent while the
question is open. Answering "nonzero" adds exactly one edit to the delta: the scenario "A fresh world
carries no crowding" in `specs/bounded-crowding/spec.md` is rewritten to state the measured default,
and the requirement's opening sentence with it. The measurement itself runs either way and produces
both strengths either way.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `bounded-crowding`: the requirement "Crowding ships off, and its ceiling is a working bound"
  becomes a measured ceiling with its record and an agent-checkable re-check, and its **unenforced**
  label is removed.
- `sph-scale`: the requirement "The fraction ships at the whole interaction radius" gains the
  measured inert boundary the floor clears, and its **unenforced** label is removed.
- `weather`: the requirement "Force weather is a waypoint table on the one tour" gains the recorded
  observation of each waypoint and the measured dwell the default speed provides, and its
  **unenforced** label is removed.
- `parameter-range-authority`: the requirement "The crowding and scale ranges" states
  `CROWDING_STRENGTH_MAX` as a working bound pending calibration, which stops being true, so its
  crowding and SPH-fraction bullets are restated against the measurements.

## Impact

Source, five files: `src/config_ranges.nim` (crowding ceiling, SPH fraction floor, waypoint table
and their records), `src/climate_core.nim` (default speed and its record),
`src/ui/state/simulation_state.nim` (crowding default), `src/preset.nim` (the mirrored crowding
default, the mirrored force weather speed literal, and the two false comments).

Tests: none restructured. `tests/test_physics.nim`, `tests/test_sph_core.nim`,
`tests/test_climate_core.nim` and `tests/test_param_descriptor.nim` re-scope themselves from the
range authority. `tests/test_preset.nim:30-43` and `:59` hold the two mirrors that must move with a
default.

Docs: `docs/help/` needs no edit. Its statements about crowding, fluid scale and force weather are
qualitative (`docs/help/12-species.md:14-16`, `docs/help/30-fluid.md:15-17`,
`docs/help/10-simulation.md:21-26`), and the measurement is what makes the force weather sentence
true.

Out of scope: the attraction matrix band (`MATRIX_MIN_VALUE`/`MATRIX_MAX_VALUE`,
`src/config_ranges.nim:63-67`) is also marked provisional and its comment asks to be tuned together
with crowding. The crowding calibration is run against the shipped matrix bounds and records them as
a condition, so moving the band in the same pass would leave neither measurable against a fixed
reference. `openspec/specs/bounded-crowding/spec.md` already holds the scenario that a later band
change invalidates the crowding record.

## Measurement gate

Every number this change writes comes from a procedure an agent executes against the running app.
`design.md` specifies the observation channel, the fixtures, the thresholds and the rejection
criteria; `tasks.md` orders the measurements before the constants they set. A measurement that finds
no qualifying value inside a current range raises that range and re-runs, and never narrows a
user-facing bound to fit what was measured.
