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

### Requirement: Every measurement happens on a declared context slice

Every probe SHALL be evaluated in a declared context that fixes all other parameters at named
coordinates. The default slice is the shipped defaults, with any strength that gates the
observable's own contribution lifted to its reference coordinate, so a control is judged where it
acts rather than in a world that multiplies its output by zero. A parameter SHALL be able to declare
further slices — a joint group's members at each named point, a derived bound's deriving parameters
at the corners of their box — and each metric SHALL be computed and judged per slice, never averaged
across slices.

An average across slices is exactly the flattening that lets a dead slice hide behind a live one.

#### Scenario: A coupling's control is measured where the coupling acts
- **WHEN** a parameter whose contribution is multiplied by a strength is swept
- **THEN** the sweep's context holds that strength at its reference coordinate, and the measured
  metrics describe the control, not the multiplier

#### Scenario: A derived bound stays live at every reachable ceiling
- **WHEN** a parameter's ceiling is a function of other live parameters
- **THEN** the sweep measures the track at the corners of the deriving parameters' box plus the
  default, and a slice whose track collapses or goes dead fails naming the slice

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
be positioned from a measured sweep of the whole descriptor table, inside the gap between a named
must-pass set and a named must-fail set, with the measured distribution recorded beside the
constants (`src/ui/api/response_probe.nim:41-67`). Three of the four sit calibrated inside that
gap; `RESPONSE_EPSILON` stands at its provisional value because neither anchor set separates on it,
so no measurement yet gives it an edge to sit against.

The must-pass set is `friction`, `fieldOpacity`, `exposure`, `contrast`, and `sphViscosity`. The
must-fail anchor is `rdFeed` and `rdKill`, which must fail on the default slice and pass on their
joint group's slices, pinning both that their deadness is two-dimensional geometry and that the
joint remedy repairs it. `trailLength` and `glowIntensity` belong to neither set: the E3.4 sweep
measured both live end to end — trail persistence is linear in the slider by construction of the
shipped mapping (`trail_core.persistenceFrames` records the collapse to a straight line), and
glow's display clamp compresses the top of its track by only 15% at the declared bright coordinate
while still growing every step — so their predicted remedies never fired, and the anchor set holds
two-dimensional deadness without them (design E3.4 carries the measured account).

Where no gap separates the sets, the probe is defective and is fixed. The thresholds are never
loosened to turn the table green.

#### Scenario: A control known to be live passes
- **WHEN** the sweep runs against the shipped thresholds
- **THEN** every must-pass control satisfies span, live fraction, and cliff

#### Scenario: A control known to be dead over most of its default slice fails
- **WHEN** the sweep runs before any remedy is applied
- **THEN** every must-fail control violates at least one metric on its default slice, and the
  violation names which

#### Scenario: The joint remedy is pinned by the same anchor
- **WHEN** the sweep runs with the feed/kill joint group declared
- **THEN** `rdFeed` and `rdKill` satisfy slice liveness on the slices through every named point

### Requirement: A probe measures what the user can see

A probe's observable SHALL include the display-side transformations standing between the
parameter's math and the screen that can extinguish or saturate the effect — clamps, coverage,
compositing — so travel the screen cannot answer measures as dead rather than as live.

An observable that keeps moving where the display has stopped is a wrong probe, and the calibration
rule treats it as one: the probe is fixed, never the threshold.

#### Scenario: A saturating display clamps the observable
- **WHEN** a parameter's raw response keeps rising past the level the display can show
- **THEN** the probe's observable saturates at that level, and the travel above it counts against
  live fraction

#### Scenario: A sub-pixel result measures as extinguished
- **WHEN** a size-like parameter's composed on-screen result falls below what a fragment can cover
- **THEN** the probe reports no response for that travel, on the slice where it happens

### Requirement: A slider's travel may be warped so effect is distributed along it

A descriptor SHALL be able to declare a travel curve, and the position-to-value mapping and its
inverse SHALL be pure Nim functions served through the boundary, so the panel computes no mapping of
its own. Both directions read the bounds the descriptor currently serves, so a derived bound warps
the interval that is live right now and position keeps meaning the fraction of the reachable track.

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
then by joining a measured joint group, and exempted only when it genuinely has no scalar
observable. Every range or step changed this way carries the measurement that justified it in a
comment beside the constant; every joint group carries its entry evidence beside the declaration.

Re-ranging comes first because a bound is one number where a curve is a function. Joining comes
after re-stepping because a group restates every member's promise, and before exempting because it
repairs the control where exempting removes it from the guarantee.

#### Scenario: A re-ranged bound records its measurement
- **WHEN** a range bound moves to remove dead travel
- **THEN** the measured live fraction before and after appears beside the constant

#### Scenario: A joint group cannot be entered by assertion
- **WHEN** a joint group is declared without recorded slice measurements showing a partner-coupled
  live boundary
- **THEN** the declaration is rejected in review, the same way an unjustified exemption is

### Requirement: A joint group restates its members' promise honestly

Parameters whose live region is a product of intervals in no single parameter SHALL be declarable as
a joint legibility group. Entry SHALL rest on slice measurement: moving a member's partner across
the named points shifts the member's live boundary by more than the declared point neighbourhood,
so no partner-independent curve can serve them all. A joint group SHALL guarantee joint
reachability of every named point, per-member liveness within a declared neighbourhood of every
named point measured on the slice through it, and attractor fidelity — each named point settling
into its own attractor, distinct from every other's. A whole-track cliff bound is NOT among the
guarantees: the boundaries between named points are real phase transitions, and promising smooth
travel across them would promise what the physics refuses.

The group's promise is that the set locates living worlds and each member is alive wherever the set
has located one — not that each member is alive everywhere, which no instrument can make true of a
jointly-shaped live region.

#### Scenario: A named point is reachable and live around
- **WHEN** any named point of a joint group is selected
- **THEN** the selection lies on every member's lattice, and each member moved within the declared
  neighbourhood visibly moves the observable

#### Scenario: A selector is not a dropdown in slider clothes
- **WHEN** the joint group's guarantees are checked
- **THEN** destinations are distinct beyond within-point variation, surroundings satisfy slice
  liveness, and every named point lies on each member's lattice — and failing any one of the
  three fails the group

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

### Requirement: A control that cannot act now names what is missing and stays usable

Every control SHALL remain offered at all times, and where a control's effect depends on state that
does not currently exist — a coupling strength at zero, a consumer bound only under another
control's setting, world state that has not yet arisen — the panel SHALL render it dormant with one
line naming the missing precondition, keep it in place, and keep it movable so a value can be set
before the world catches up.

The dormancy predicate is declared per descriptor over named state fields and streamed stats, and a
native check SHALL assert every name it uses resolves, so a renamed field breaks loudly. A control
is never dormant under its own value alone: zero is an ordinary value, and the control sitting at
zero is the way back. A compound predicate MAY read its carriers where their own movement can break
the condition, so the control still holds its own way out.

#### Scenario: The grade sliders under a disabled consumer
- **WHEN** bloom is off
- **THEN** Exposure, Bloom Intensity, Saturation, Contrast, and Temperature render dormant with a
  line naming the Bloom toggle, and enabling bloom wakes all five in the same tick

#### Scenario: A coupling family at zero strength
- **WHEN** a coupling's strength is zero
- **THEN** every control whose effect that strength multiplies renders dormant naming the strength,
  while the strength's own control stays fully live

#### Scenario: The field calibrators before ignition
- **WHEN** the field rests at its trivial fixed point and the current feed and kill sit where no
  nontrivial fixed point exists
- **THEN** the feed and kill controls render dormant with a line saying nothing has ignited yet, and
  leave dormancy when the field ignites or the condition breaks

#### Scenario: Dormancy does not hide
- **WHEN** a control becomes dormant
- **THEN** it remains in place at the same position in the panel and still accepts input

#### Scenario: A predicate cannot rot silently
- **WHEN** a dormancy predicate names a state field that does not exist
- **THEN** the build or the native suite fails naming the predicate and the missing field

### Requirement: An edit in progress belongs to the user

A text-editable control SHALL hold uncommitted intermediate states, including empty, and SHALL apply
parsing and clamping on commit rather than on every change of the field. A re-render caused by
anything other than the user's own commit SHALL NOT overwrite an in-progress edit.

An emptied field is a moment inside an edit, not a value to correct; reverting it steals the edit.

#### Scenario: A cell can be cleared and retyped
- **WHEN** the user empties a matrix cell and types a replacement value, including zero
- **THEN** the field holds each intermediate state and the typed value lands on commit, clamped to
  the served range

#### Scenario: External updates do not steal the edit
- **WHEN** the matrix re-renders while a cell edit is in progress
- **THEN** the in-progress cell keeps the user's text and every other cell shows the live values

### Requirement: Parameters that are a length draw themselves in the world while dragged

A parameter whose value is a distance in the world SHALL draw a transient overlay at world scale for
the duration of a drag, disappearing on release.

The set is closed to parameters that are literally a world distance — interaction radius and camera
zoom; the deposit splat radius is a compile-time constant with no control to drag. Extending the set
further would require inventing a visual metaphor per control.

#### Scenario: Interaction radius shows its reach
- **WHEN** the interaction-radius slider is being dragged
- **THEN** a ring of that world radius draws at the cursor until release
