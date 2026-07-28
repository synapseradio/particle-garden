## ADDED Requirements

### Requirement: Camera ranges

config_ranges.nim SHALL define `CAMERA_ZOOM_MIN = 0.25` (four tiles visible — the infinity read) and
`CAMERA_ZOOM_MAX = 8.0` (creature scale), with the standard static non-emptiness assertion, consumed
by the descriptor table and preset clamping like every other range.

#### Scenario: Zoom clamps at the authority's bounds
- **WHEN** input drives zoom beyond either bound
- **THEN** the stored zoom clamps to the config_ranges constant

### Requirement: Species chemistry ranges

Secretion and tropism SHALL have signed, bounded ranges defined in config_ranges.nim with static
non-emptiness and default-in-range assertions. The bounds are asymmetric by design: tropism spans
`[-1.0, +0.5]`, granting full authority to down-gradient motion and half to up-gradient motion,
because climbing a self-deposited gradient is the direction that admits chemotactic collapse while
descending one is stabilizing.

#### Scenario: Tropism cannot escape its bound
- **WHEN** a preset or UI write carries a tropism outside the range
- **THEN** the value clamps at the config_ranges bound

#### Scenario: The bound is measurement-backed
- **WHEN** the tropism bound changes
- **THEN** the stability test asserting the bound sits below the measured collapse point still passes

### Requirement: The feed range reaches every labelled regime

`RD_FEED_MAX` SHALL be at least 0.085 so that every named regime the panel offers is reachable on its
own slider.

#### Scenario: Coral is selectable
- **WHEN** the user picks the Coral regime
- **THEN** its feed value lies inside the slider range and applies without clamping

### Requirement: Notch tables live with the ranges

Where a parameter's labelled notches derive from published or measured values, those values SHALL be
defined alongside the ranges they must satisfy, so a range change and a notch change cannot drift
apart.

#### Scenario: Narrowing a range strands a notch
- **WHEN** a range narrows past one of its own notch values
- **THEN** the notch-in-range test fails at build time rather than shipping an unreachable label
