## ADDED Requirements

### Requirement: Every visible control is probed or exempted, with nothing in between

Every parameter descriptor SHALL name either a response probe — a pure function returning a scalar
observable the parameter moves — or a written exemption, and a native test SHALL assert the union of
the two covers the descriptor table exactly.

Probes are drawn from the reference-oracle family, which mirrors WGSL math in pure Nim for the native
suite. A probe therefore measures the mirror, not the pixels; that limit is inherent to the family and
is not claimed away.

#### Scenario: A new control cannot arrive unprobed
- **WHEN** a descriptor is added with neither a probe id nor an exemption
- **THEN** `just test` fails naming that descriptor

#### Scenario: An exemption states its reason
- **WHEN** a descriptor is exempted
- **THEN** the exemption carries a written reason a reviewer can disagree with

### Requirement: Effect is measured across slider travel, not across parameter value

Control legibility SHALL be measured over positions on the track from 0 to 1, using three unit-free
metrics: span, the end-to-end response change against the observable's reference magnitude; live
fraction, the proportion of adjacent sample pairs whose response change exceeds the response epsilon;
and cliff, the largest single adjacent-sample change as a fraction of the span.

Live fraction and cliff bound the track from opposite sides — a dead tail fails the first, a step too
coarse to be smooth fails the second — so together they derive the range and the step rather than
sanctioning chosen numbers.

#### Scenario: Most of the track does something
- **WHEN** a probed parameter's live fraction falls below the calibrated minimum
- **THEN** `just test` fails naming the parameter, its live fraction, and the dead interval

#### Scenario: No single movement jumps the world
- **WHEN** a probed parameter's cliff exceeds the calibrated maximum
- **THEN** `just test` fails naming the parameter and the offending interval

#### Scenario: The control does something end to end
- **WHEN** a probed parameter's span falls below the calibrated minimum
- **THEN** `just test` fails naming the parameter

### Requirement: Sampling budget and its stated limit

Probes SHALL declare a budget class, and the sweep SHALL sample the track at the declared budget or at
the parameter's own step lattice, whichever is coarser. Closed-form probes sample 256 positions;
probes that integrate a simulation sample 64, so the native suite stays fast.

Where the lattice is finer than the budget, the cliff metric bounds deltas between sampled positions
rather than between true adjacent steps. A response oscillating inside one sampled interval could
exceed the measured delta at a true step. No shipped probe is oscillatory by construction; the test
does not prove it.

#### Scenario: Coarse lattices are measured at their true steps
- **WHEN** a parameter's step count is below the sample budget
- **THEN** the sweep evaluates every reachable step rather than an interpolated lattice

### Requirement: Thresholds are calibrated against named controls

The four thresholds — response epsilon, span minimum, live-fraction minimum, and cliff maximum — SHALL
be set from a measured sweep of the whole descriptor table, positioned inside the gap between a named
must-pass set and a named must-fail set, with the measured distribution recorded beside the constants.

The must-pass set is `friction`, `glowIntensity`, `exposure`, `contrast`, and `sphViscosity`. The
must-fail set is `rdFeed` and `rdKill`, whose rectangle is mostly a region where no pattern exists
under any perturbation, and `trailLength`, whose persistence decays geometrically.

Where no gap separates the two sets, the probe is defective and is fixed. The thresholds are never
loosened to turn the table green.

#### Scenario: A control known to be live passes
- **WHEN** the sweep runs against the shipped thresholds
- **THEN** every must-pass control satisfies span, live fraction, and cliff

#### Scenario: A control known to be dead over most of its track fails
- **WHEN** the sweep runs before any remedy is applied
- **THEN** every must-fail control violates at least one metric, and the violation names which

### Requirement: A slider's travel may be warped so effect is distributed along it

A descriptor SHALL be able to declare a travel curve, and the position-to-value mapping and its
inverse SHALL be pure Nim functions served through the boundary, so the panel computes no mapping of
its own.

The curve changes the handle's position and nothing else. Stored values, preset keys, clamping, notch
coordinates, and the displayed readout are all independent of it.

#### Scenario: A curve does not move a stored value
- **WHEN** a parameter's curve changes
- **THEN** a preset saved before the change loads to the identical value after it

#### Scenario: Position and value round-trip
- **WHEN** a value is converted to a track position and back
- **THEN** it returns to itself at the descriptor's own precision

### Requirement: A remedy ladder applies in order to a failing control

A control failing any metric SHALL be repaired by re-ranging, then by curving, then by re-stepping,
and exempted only when it genuinely has no scalar observable. Every range or step changed this way
carries the measurement that justified it in a comment beside the constant.

Re-ranging comes first because a bound is one number where a curve is a function. Exempting comes last
because it removes the control from the guarantee instead of repairing it.

#### Scenario: A re-ranged bound records its measurement
- **WHEN** a range bound moves to remove dead travel
- **THEN** the measured live fraction before and after appears beside the constant

### Requirement: Acknowledgement is immediate and independent of the world's response

Moving any control SHALL produce a panel-side acknowledgement in the same tick — the handle moves, the
readout updates, and the control briefly highlights — regardless of whether the simulation changes
visibly.

#### Scenario: A slow parameter still acknowledges instantly
- **WHEN** a parameter whose response horizon is structural is moved
- **THEN** the acknowledgement appears in the same tick as the input event

### Requirement: Every control declares how long its response takes

A descriptor SHALL declare a response horizon — instant, settling, or structural — and the panel SHALL
show a settling indicator while a non-instant horizon has not elapsed.

Where a stepping oracle exists, a test asserts the observable moves past the response epsilon within
the declared horizon. Where none exists, the declaration is review-enforced and labelled as such in
the descriptor.

#### Scenario: A declared horizon is measured where it can be
- **WHEN** a parameter's probe integrates a simulation
- **THEN** a test asserts its observable moves within the declared horizon

#### Scenario: An unmeasurable horizon is labelled
- **WHEN** a parameter has no stepping oracle
- **THEN** its horizon declaration is marked review-enforced rather than presented as verified

### Requirement: A control that cannot act names what is missing and stays usable

Where a control's effect depends on world state that does not exist, the panel SHALL render it dormant
with one line naming the missing precondition, and SHALL keep it movable so a value can be set before
the world catches up.

Group-level gating on the active couplings is unchanged; dormancy is the finer condition inside a
group that is already shown.

#### Scenario: Field opacity before anything has ignited
- **WHEN** the field sits at its trivial fixed point
- **THEN** the field-appearance controls render dormant with the reason, and still accept input

#### Scenario: Dormancy does not hide
- **WHEN** a control becomes dormant
- **THEN** it remains in place at the same position in the panel

### Requirement: Parameters that are a length draw themselves in the world while dragged

A parameter whose value is a distance in the world SHALL draw a transient overlay at world scale for
the duration of a drag, disappearing on release.

The set is closed to parameters that are literally a world distance — interaction radius, deposit
splat radius, camera zoom. Extending it further would require inventing a visual metaphor per control.

#### Scenario: Interaction radius shows its reach
- **WHEN** the interaction-radius slider is being dragged
- **THEN** a ring of that world radius draws at the cursor until release
