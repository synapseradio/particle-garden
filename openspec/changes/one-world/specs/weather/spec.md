## ADDED Requirements

### Requirement: The climate can wander

When enabled, the simulation SHALL advance feed and kill along a slow, smooth path inside the
rectangle the range authority bounds, routed through the ordinary parameter path so the sliders
visibly move. Drift is off by default; nothing resets and nothing pops.

Watching the controls move is how the weather becomes legible rather than mysterious, which is why
drift writes through the same path a user's own edit takes.

#### Scenario: Weather changes visibly
- **WHEN** climate drift is enabled
- **THEN** the feed and kill sliders move continuously and the pattern regime shifts without a reset

#### Scenario: Drift respects the range
- **WHEN** drift runs for any length of time
- **THEN** feed and kill remain inside their configured ranges

#### Scenario: Drift is continuous
- **WHEN** drift advances one step
- **THEN** neither parameter moves further than the configured maximum per-step delta

### Requirement: Named regimes make the interesting settings findable

The panel SHALL offer named regimes as a selector that sets feed and kill together, and SHALL mark
each regime's value as a labelled notch on the individual sliders.

The parameters that locate a Gray-Scott regime are coupled, and most of their joint range produces
nothing worth looking at. Exposing them as bare numbers leaves a user to find the living settings by
accident; naming the known ones is what lets someone explore without knowing the literature.

#### Scenario: Picking a regime
- **WHEN** the user selects a named regime
- **THEN** feed and kill both take that regime's values through the clamped boundary

#### Scenario: Regimes stay honest
- **WHEN** a regime is labelled on the panel
- **THEN** its coordinates come from a cited source, and boundaries between regimes are not drawn
  because no numeric boundaries are published

### Requirement: Field controls read as sensations

Field-group controls SHALL present sensory display names rather than the reaction's variable names.
Descriptor ids are preset storage keys and SHALL NOT change.

#### Scenario: Rename is presentation-only
- **WHEN** a display label changes
- **THEN** presets saved under the old label still apply, because the id never moved


### Requirement: Force weather is a waypoint table on the one tour

The force weather SHALL be a waypoint table registered with the single parameterised tour that
task 9.4a generalises `climate_core` into — never a second loop. One advance
implementation serves both tables; the RD regimes are the other table. The force table's waypoints
live beside the ranges they must satisfy in `src/config_ranges.nim`, under a static in-range
assertion, per the range authority's rule that notch tables live with their ranges.

The waypoints themselves are measured choices: no published set of force-parameter regimes exists,
so each waypoint is a settled configuration found worth watching, with the selection recorded beside
the table. That recording is review-enforced.

#### Scenario: A second loop cannot appear

- **WHEN** the native tour sweeps run
- **THEN** the same advance and easing code executes for the RD table and the force table,
  parameterised over the table — there is no second implementation for a test to cover

#### Scenario: A range narrows past a waypoint

- **WHEN** a force parameter's range is narrowed past one of the table's coordinates
- **THEN** the static assertion fails the build rather than shipping an unreachable waypoint

### Requirement: The weather inherits the tour's guarantees

The force weather SHALL carry the tour's guarantees unchanged, for the same structural reasons:
every point is a convex combination of in-range waypoints over an axis-aligned box, so it is
in-range with no clamp; segments join with smoothstep easing, so there is no velocity corner at a
handover; the per-frame step ceiling is asserted by a sweep of the whole loop at maximum speed, so a
speed the loop cannot carry goes red in a test instead of making the weather jump; it advances on
wall-clock seconds; and it writes through the ordinary `setParam` path so the sliders visibly move.
It is off by default and has its own speed control — the RD climate and the force weather can run
independently.

Enforced by the generalised tour's existing sweep tests running over the force table
(`tests/test_climate_core.nim`).

#### Scenario: The weather stays in the box

- **WHEN** the tour advances for any length of time at any speed
- **THEN** every toured parameter remains inside its configured range, with no clamp applied

#### Scenario: No jump at any offerable speed

- **WHEN** the loop is swept at the maximum offerable speed
- **THEN** no per-frame step exceeds the configured maximum delta

#### Scenario: The sliders move

- **WHEN** the force weather is on
- **THEN** the toured parameters' sliders move continuously in the panel, because the writes take
  the same clamped path a drag takes
