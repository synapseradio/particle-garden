## MODIFIED Requirements

### Requirement: Thresholds are calibrated against named controls

The four thresholds — `RESPONSE_EPSILON`, `SPAN_MIN`, `LIVE_FRACTION_MIN`, and `CLIFF_MAX` — SHALL be
positioned from a measured sweep of the whole descriptor table, inside the gap between a named
must-pass set and a named must-fail set, with the measured distribution recorded beside the constants
in `src/ui/api/response_probe.nim`. Three of the four sit calibrated inside that gap;
`RESPONSE_EPSILON` stands at its provisional value because neither anchor set separates on it, so no
measurement yet gives it an edge to sit against.

The must-pass set is `friction`, `rdFieldForce`, `exposure`, `contrast`, and `sphViscosity`, declared
as `MustPass` in `tests/test_response_probe.nim`. `rdFieldForce`, the scent strength, is live across
its whole range by the math it feeds: under `coupling-contract`, "A strength of 1 is a coupling's
calibrated full effect", its impulse is linear in the slider from 0 to its full effect. It measured
span 1.0000, live 1.000 and cliff 0.004 on the default slice in the pre-calibration table
(`tests/test_response_probe.nim:243`),
and it sits at neither edge of any threshold, so no threshold moves with it. The must-fail anchor is
`rdFeed` and `rdKill`, which must fail on the default slice and pass on their joint group's slices,
pinning both that their deadness is two-dimensional geometry and that the joint remedy repairs it.
`trailLength` and `glowIntensity` belong to neither set: the sweep measured both live end to end —
trail persistence is linear in the slider by construction of the shipped mapping
(`trail_core.persistenceFrames` records the collapse to a straight line), and glow keeps growing at
every step under its display clamp — so their predicted remedies never fired, and the anchor set holds
two-dimensional deadness without them.

The measured table before the remedies is frozen as `PreCalibrationTable` in
`tests/test_response_probe.nim`, and `legibilityReportMarkdown` emits the calibrated table beside it
into `docs/control-legibility-report.md`.

Where no gap separates the sets, the probe is defective and is fixed. The thresholds are never
loosened to turn the table green.

#### Scenario: A control known to be live passes
- **WHEN** the sweep runs against the shipped thresholds
- **THEN** every must-pass control satisfies span, live fraction, and cliff

#### Scenario: A control known to be dead over most of its default slice fails
- **WHEN** the sweep runs before any remedy is applied
- **THEN** every must-fail control violates at least one metric on its default slice, and the frozen
  pre-calibration table records which

#### Scenario: The joint remedy is pinned by the same anchor
- **WHEN** the sweep runs with the feed/kill joint group declared
- **THEN** `rdFeed` and `rdKill` satisfy slice liveness on the slices through every named point
