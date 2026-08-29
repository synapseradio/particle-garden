## RENAMED Requirements

- FROM: `### Requirement: Force weather is a waypoint table on the one tour`
- TO: `### Requirement: Force weather is a watched waypoint table on the one tour`

## MODIFIED Requirements

### Requirement: Force weather is a watched waypoint table on the one tour

The force weather SHALL be a waypoint table registered with the single parameterised tour, never a
second loop. One advance implementation serves both tables (`tourAt`, `tourPhaseStep`, `tourAdvance`,
`src/climate_core.nim:40-82`), parameterised over the table's arity: the climate has two axes and the
force weather has three (`ForceAxis`, `FORCE_WEATHER_PARAM_IDS`, `FORCE_WEATHER_TOUR`,
`src/climate_core.nim:147-197`). The force table's waypoints live beside the ranges they must
satisfy (`FORCE_WEATHER_WAYPOINTS`, `src/config_ranges.nim:75-90`), under a static in-range assertion
(`src/config_ranges.nim:493-510`), per the range authority's rule that notch tables live with their
ranges.

Every waypoint SHALL name a world somebody has watched, and what it produces SHALL be recorded beside
the table. A waypoint qualifies when the share of the canvas its settled world lights differs from
both of its tour neighbours' by more than three standard deviations of the repeats, so no segment
travels between two worlds a viewer cannot tell apart. A coordinate that fails is replaced and
re-measured.

`FORCE_WEATHER_DEFAULT_SPEED` SHALL be derived from the measured settling time of the slowest
segment, and that derivation SHALL be recorded beside the constant (`src/climate_core.nim:177-182`).
Speed is tours per minute and the tour has five segments, so one segment lasts `60 / (5 × speed)`
wall-clock seconds; the weather advances on wall-clock seconds, not scaled ones
(`src/app.nim:265-269`), while settling is measured in world seconds, so the record states the time
scale the conversion used. The default is the fastest speed at which each segment still lasts at
least as long as its own world takes to settle.

Where the derived speed falls below `FORCE_WEATHER_SPEED_MIN`, the finding is reported with the
measured settling times, and the default is never set below the range it lives in.

The mirrored literal in `src/preset.nim:265` moves with the constant, held by the mirror assertion at
`tests/test_preset.nim:43`. A waypoint edit that widens a segment past what the top speed can carry
goes red at the per-frame step sweep (`tests/test_climate_core.nim:298-300`), and a coordinate
outside its own slider fails the build at the static assertion.

**agent-checkable** for the record matching the table: an agent launches the app, writes each
waypoint's three coordinates through `setParam` and `commitParam` with the weather off, lets each
settle for the recorded world-seconds, captures the canvas, and compares the five lit shares against
the record. Two adjacent waypoints whose shares now agree within the repeat spread mean the record
and the table have parted. No automated gate detects this, because the observation runs against
rendered frames and the native suite executes no GPU.

#### Scenario: A waypoint produces something worth arriving at

- **WHEN** each of the five waypoints is settled and captured
- **THEN** every waypoint's settled world is distinguishable from both of its tour neighbours', and
  what each produces is recorded beside the table

#### Scenario: The tour dwells long enough to be seen

- **WHEN** the force weather runs at the shipped default speed
- **THEN** each segment lasts at least as long as the measured settling time of the world it
  arrives at, so a waypoint becomes visible before the tour leaves it

#### Scenario: No offerable speed dwells long enough

- **WHEN** the derived speed falls below `FORCE_WEATHER_SPEED_MIN`
- **THEN** the measured settling times are reported and the default stays inside its range, rather
  than a speed being written outside the range that bounds it

#### Scenario: A second loop cannot appear

- **WHEN** the native tour sweeps run
- **THEN** the same advance and easing code executes for the RD table and the force table,
  parameterised over the table — there is no second implementation for a test to cover

#### Scenario: A range narrows past a waypoint

- **WHEN** a force parameter's range is narrowed past one of the table's coordinates
- **THEN** the static assertion fails the build instead of shipping an unreachable waypoint
