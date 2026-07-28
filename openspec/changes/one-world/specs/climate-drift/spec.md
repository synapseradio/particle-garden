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
