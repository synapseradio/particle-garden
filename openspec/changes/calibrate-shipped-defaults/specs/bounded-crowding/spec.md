## RENAMED Requirements

- FROM: `### Requirement: Crowding ships off, and its ceiling is a working bound`
- TO: `### Requirement: Crowding ships off, and its ceiling is measured`

## MODIFIED Requirements

### Requirement: Crowding ships off, and its ceiling is measured

The shipped crowding strength default SHALL be `0.0` (`src/ui/state/simulation_state.nim:91-93`,
mirrored in `src/preset.nim:217-220`), so a fresh world runs the force law that every other default
was chosen against. The two sites SHALL agree, which the total-relation walk over `PresetSettings`
and `SimulationState` holds (`tests/test_preset.nim:59-104`). `CROWDING_STRENGTH_MIN` SHALL be
exactly zero, so that force law stays reachable from the slider (`src/config_ranges.nim:42-45`,
static assertion at `:436-437`).

`CROWDING_STRENGTH_MAX` SHALL be a measured bound, recorded beside itself under the range
authority's measured-bound rule (`src/config_ranges.nim:46-54`). The calibration finds two
strengths, measured against the shipped attraction-matrix bounds and force-strength range, with the
fluid off and the chemical field off:

- **c_hold**, the strength at which a collapsing world stops tightening. A world whose every matrix
  entry sits at `MATRIX_MAX_VALUE` collapses. `c_hold` is the smallest strength at which the share
  of the canvas its particles light stops shrinking over the second half of a 90 world-second run.
- **c_soften**, the strength at which ordinary colonies visibly soften. Measured on a world at the
  shipped defaults with a pinned attraction matrix. `c_soften` is the smallest strength whose
  settled lit share exceeds the crowding-zero lit share by more than a quarter and by more than
  three standard deviations of the crowding-zero repeats.

`CROWDING_STRENGTH_MAX` SHALL sit above `c_soften` by a stated margin, so a user reaches every
strength past visible softening and the slider ends past the useful region. Both measured values,
the margin, and the conditions they were taken under SHALL appear beside the constant: the two
fixtures in full, particle count, interaction radius, time scale, the matrix bounds, the fluid and
field settings, the canvas dimensions, and the world-seconds of settling.

Where the sweep finds no strength inside the current range satisfying the hold criterion, the range
SHALL be widened and the sweep re-run. The ceiling is never recorded as measured because a sweep
found nothing under it.

The ceiling sweep in `tests/test_physics.nim:186-190` reads the bound from the range authority, so
replacing the constant re-scopes the sweep with no second edit.

**agent-checkable** for the ceiling matching its record: an agent launches the app, applies the
collapsing-world fixture the record names, sweeps crowding strength across its slider travel with
`gardenAPI.paramValueAt`, captures the canvas at the recorded world-time marks, and recovers the two
thresholds. A recovered threshold outside the recorded repeat spread means the record and the
constant have parted, and the calibration re-runs. No automated gate detects this, because the
measurement runs against rendered frames and the native suite executes no GPU.

#### Scenario: The ceiling clears the softening point

- **WHEN** the recorded `c_soften` is read beside `CROWDING_STRENGTH_MAX`
- **THEN** the ceiling exceeds it by the recorded margin

#### Scenario: No strength inside the range holds the world open

- **WHEN** the sweep finds no crowding strength at which the collapsing fixture stops tightening
- **THEN** the range is widened and the sweep re-runs, and the ceiling is not recorded as measured
  against a range that never contained the answer

#### Scenario: The shipped default is one number in two places

- **WHEN** the crowding default is changed in `src/ui/state/simulation_state.nim` alone
- **THEN** the total-relation test in `tests/test_preset.nim` fails, because a preset omitting the
  field would otherwise restore a different world than a fresh session starts in

#### Scenario: A fresh world carries no crowding

- **WHEN** the app starts with no preset applied
- **THEN** crowding strength is zero and every force equals the unattenuated oracle

#### Scenario: The unattenuated force law stays reachable

- **WHEN** the crowding range is narrowed
- **THEN** the static assertion in `src/config_ranges.nim` fails the build unless the floor stays
  exactly zero

#### Scenario: The attraction bounds move after a calibration

- **WHEN** the matrix value bounds or the force-strength range change
- **THEN** the record beside the crowding ceiling names bounds that no longer exist, and the
  calibration has to re-run instead of shipping a bound tuned against a vanished range
