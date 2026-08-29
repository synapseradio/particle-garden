# weather

## Purpose

Owns the world's autonomous motion: two waypoint tours that walk parameters on a wall clock while
the panel watches. One tour visits the named Gray-Scott regimes and writes feed and kill; the other
visits a force-parameter table and writes force strength, interaction radius and friction. One
capability because both ride a single parameterised advance, share one set of structural guarantees
(convex interpolation over an axis-aligned box, smoothstep easing at handovers, an asserted
per-frame step ceiling), and reach the simulation through the same clamped parameter path a user's
drag takes. The named regimes and the sensory display names belong here too, because they are how
somebody finds and reads the settings the weather tours.

The Gray-Scott chemistry the climate tours belongs to the field. Ranges, defaults, notches and the
clamped `setParam` boundary belong to `parameter-range-authority` and `gardenapi-boundary`. This spec
cites those relations and leaves their detail to them.

## Requirements

### Requirement: The climate can wander

When enabled, the simulation SHALL advance feed and kill along a slow, smooth path inside the
rectangle the range authority bounds, routed through the ordinary parameter path so the sliders
visibly move (`src/app.nim:257-260` calling `web_api.setClimateFromSimulation`,
`src/web_api.nim:713`). Drift is off by default (`climateDrift: false`,
`src/ui/state/simulation_state.nim:123`); nothing resets and nothing pops.

Watching the controls move is how the weather becomes legible instead of mysterious, which is why
drift writes through the same path a user's own edit takes.

The path is `tourAt` over `RD_CLIMATE_TOUR`, which projects `RD_REGIMES`
(`src/climate_core.nim:107-119`), advanced by `tourAdvance` on wall-clock seconds
(`src/climate_core.nim:69-82`). `CLIMATE_MAX_STEP` is a ceiling the path must respect, not a limiter
applied to it (`src/climate_core.nim:126-141`).

Enforced by: `tests/test_climate_core.nim`, suites "Climate Drift Stays Inside The Rectangle",
"Climate Drift Is Continuous" and "Climate Drift Tours The Named Regimes" (`:178-256`).

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

The panel SHALL offer named regimes as a selector that sets feed and kill together
(`web-ui/src/components/RegimeSelector.tsx`, over `gardenAPI.rdRegimes` and `applyRegime`,
`src/web_api.nim:641-712`), and SHALL mark each regime's value as a labelled notch on the individual
sliders (`src/ui/api/param_descriptor.nim:324-333,612-634`).

The parameters that locate a Gray-Scott regime are coupled, and most of their joint range produces
nothing worth looking at. Exposing them as bare numbers leaves a user to find the living settings by
accident; naming the known ones is what lets someone explore without knowing the literature.

`applyRegime` writes through `setParam`, so both axes land clamped and the sliders read back what
landed. Two regimes carry a measured `minDeposit` and it is applied as a floor rather than a set, so
a regime that needs a stronger deposit to ignite does not present as a dead button
(`src/web_api.nim:669-691`; the floors are measured in `tests/test_field_core.nim` and recorded at
`RD_REGIMES`, `src/config_ranges.nim:268-277`).

The table side is native-tested: every notch lies inside its parameter's range and on a position the
slider can land on, feed and kill each carry all six regimes, and each regime's notch values are the
coordinates the range authority holds (`tests/test_param_descriptor.nim`, suite "Notches Mark Only
Reachable Positions", `:511-617`). **agent-checkable** for the selector itself, because the panel
components carry no native test. The procedure: launch the app, click each named regime in turn, and
read that the feed and kill sliders jump to that regime's coordinates, that the button lights as
active, and that the pattern settles into the named morphology within a few seconds. A violation
shows as a button that changes nothing, a button that never lights, or a regime whose field stays
blank.

#### Scenario: Picking a regime
- **WHEN** the user selects a named regime
- **THEN** feed and kill both take that regime's values through the clamped boundary

#### Scenario: Regimes stay honest
- **WHEN** a regime is labelled on the panel
- **THEN** its coordinates come from a cited source, and boundaries between regimes are not drawn
  because no numeric boundaries are published

### Requirement: Field controls read as sensations

Field-group controls SHALL present sensory display names rather than the reaction's variable names:
`rdFeed` reads "Breath In", `rdKill` reads "Breath Out", `rdDeposit` reads "Secretion Rate",
`rdFieldForce` reads "Scent-following" (`src/ui/api/param_descriptor.nim:618-655`). Descriptor ids
are preset storage keys and SHALL NOT change.

Enforced by: the routed-id sweep, which holds every descriptor id to a field of its store's record
(`tests/test_param_descriptor.nim`, suite "Every Routed Id Names A Field Of Its Store", `:372-432`),
and the label check that every descriptor names a non-empty label and group (`:98-102`).

#### Scenario: Rename is presentation-only
- **WHEN** a display label changes
- **THEN** presets saved under the old label still apply, because the id never moved

### Requirement: Force weather is a waypoint table on the one tour

The force weather SHALL be a waypoint table registered with the single parameterised tour, never a
second loop. One advance implementation serves both tables (`tourAt`, `tourPhaseStep`, `tourAdvance`,
`src/climate_core.nim:40-82`), parameterised over the table's arity: the climate has two axes and the
force weather has three (`ForceAxis`, `FORCE_WEATHER_PARAM_IDS`, `FORCE_WEATHER_TOUR`,
`src/climate_core.nim:147-197`). The force table's waypoints live beside the ranges they must
satisfy (`FORCE_WEATHER_WAYPOINTS`, `src/config_ranges.nim:75-90`), under a static in-range assertion
(`src/config_ranges.nim:493-510`), per the range authority's rule that notch tables live with their
ranges.

The waypoints are a constructed spread. Five points, each moving at least two axes away from its
neighbours so no segment reads as a single slider drifting, placed to keep the tour inside every
range with room to spare. No published set of force-parameter regimes exists to draw them from. The
construction is recorded beside the table and marked provisional there: nothing in it has been
watched settle.

**unenforced** for whether a waypoint produces anything worth watching, because no observation of the
tour has been recorded. An in-app calibration closes it: an agent enables the force weather, watches
one full tour, and records beside the table what each waypoint produces, replacing a coordinate that
produces nothing. The single-tour implementation and the static in-range assertion are fully held
meanwhile (`src/climate_core.nim:147-197`; `tests/test_climate_core.nim:162-176,285-332`).

#### Scenario: A second loop cannot appear

- **WHEN** the native tour sweeps run
- **THEN** the same advance and easing code executes for the RD table and the force table,
  parameterised over the table — there is no second implementation for a test to cover

#### Scenario: A range narrows past a waypoint

- **WHEN** a force parameter's range is narrowed past one of the table's coordinates
- **THEN** the static assertion fails the build instead of shipping an unreachable waypoint

### Requirement: The weather inherits the tour's guarantees

The force weather SHALL carry the tour's guarantees unchanged, for the same structural reasons:
every point is a convex combination of in-range waypoints over an axis-aligned box, so it is in-range
with no clamp; segments join with smoothstep easing, so there is no velocity corner at a handover;
the per-frame step ceiling is asserted by a sweep of the whole loop at maximum speed, so a speed the
loop cannot carry goes red in a test instead of making the weather jump; it advances on wall-clock
seconds (`src/app.nim:265-269`); and it writes through the ordinary `setParam` path so the sliders
visibly move (`setForceWeatherFromSimulation`, `src/web_api.nim:744`). It is off by default
(`forceWeather: false`, `src/ui/state/simulation_state.nim:125`) and has its own speed control
(`forceWeatherSpeed`, default `FORCE_WEATHER_DEFAULT_SPEED`), so the RD climate and the force weather
run independently.

The step ceiling is stated per axis (`FORCE_WEATHER_MAX_STEPS`, `src/climate_core.nim:183-197`),
because the three axes span three scales and one shared number would assert nothing about the
narrowest of them.

Enforced by the generalised tour's sweep tests running over the force table
(`tests/test_climate_core.nim`, suite "The Force Weather Rides The Same Tour", `:285-332`).

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
