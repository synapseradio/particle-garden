# control-legibility

## Purpose

Own the guarantee that every control the panel offers does something the user can see, in coordinates
where the effect is spread along the track. This capability holds the response probes and the metrics
measured over them, the thresholds those metrics are judged against, the travel curve that
redistributes effect along a slider, the acknowledgement the panel gives on every input, the response
horizon a control declares, the dormancy line a control shows when its effect has nothing to act on,
and the overlays a world-distance parameter draws while dragged. Measurement and presentation are one
capability because a metric alone says nothing about what reached the user, and a panel affordance
alone makes a claim no measurement backs.

## Requirements

### Requirement: Every visible control is probed or exempted, with nothing in between

Every parameter descriptor SHALL name either a response probe — a pure function returning a scalar
observable the parameter moves — or a written exemption, and a native test SHALL assert the union of
the two covers the descriptor table exactly.

Probes are drawn from the reference-oracle family, which mirrors WGSL math in pure Nim for the native
suite. A probe therefore measures the mirror, not the pixels; that limit is inherent to the family and
is not claimed away.

Enforced by `tests/test_response_probe.nim`, suite `Every Descriptor Is Probed Or Exempted`: every
descriptor carries one of the two and never both, every carried probe id resolves in
`probeRegistry()`, every registered probe is carried by some descriptor, and the exempt set is pinned
to exactly `particleCount`, `speciesCount`, and `sphSubsteps`, each with the reason it carries in
`src/ui/api/param_descriptor.nim`.

#### Scenario: A new control cannot arrive unprobed
- **WHEN** a descriptor is added with neither a probe id nor an exemption
- **THEN** `just test` fails naming that descriptor

#### Scenario: An exemption states its reason
- **WHEN** a descriptor is exempted
- **THEN** the exemption carries a written reason, and the pinned exempt set turns a fourth exemption
  into a red test rather than a default anyone drifts into

### Requirement: Effect is measured across slider travel, not across parameter value

Control legibility SHALL be measured over positions on the track from 0 to 1, using three unit-free
metrics: span, the end-to-end response change against the observable's reference magnitude; live
fraction, the proportion of adjacent sample pairs whose response change exceeds the response epsilon;
and cliff, the largest single adjacent-sample change as a fraction of the span.

Live fraction and cliff bound the track from opposite sides — a dead tail fails the first, a step too
coarse to be smooth fails the second — so together they derive the range and the step rather than
sanctioning chosen numbers.

`measureSlice` in `src/ui/api/response_probe.nim` computes the three metrics and `passes` applies the
thresholds. `tests/test_response_probe.nim`, suite `The Sweep At Calibrated Thresholds`, runs the whole
descriptor table and requires every probed descriptor outside the joint group to pass on every slice.

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

`defaultProbeContext` and `slicesFor` in `src/ui/api/response_probe.nim` hold the slice declarations:
`particleSize` takes the zoom corners, `sphStiffness` the corners of its deriving box, and the
feed/kill pair the slices through the regime points. `defaultProbeContext` records why no strength
lift fires on the default slice — every strength multiplying a probed observable defaults non-zero
except `crowdingStrength`, whose gated term appears only inside its own probe.
`allSliceMeasurements` produces one measurement row per slice and the sweep judges each row on its
own.

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
the parameter's own step lattice, whichever is coarser. Closed-form probes sample
`ProbeBudgetClosedForm` positions; probes that integrate a simulation sample `ProbeBudgetStepped`, so
the native suite stays fast.

Where the lattice is finer than the budget, the cliff metric bounds deltas between sampled positions
rather than between true adjacent steps. A response oscillating inside one sampled interval could
exceed the measured delta at a true step. No shipped probe is oscillatory by construction; the test
does not prove it.

Enforced by `measureSlice` in `src/ui/api/response_probe.nim`, which replaces the budget with the
lattice point count whenever the lattice is the coarser of the two, and by `ProbeSpec.budget`, which
every registry entry declares.

#### Scenario: Coarse lattices are measured at their true steps
- **WHEN** a parameter's step count is below the sample budget
- **THEN** the sweep evaluates every reachable step rather than an interpolated lattice

### Requirement: Thresholds are calibrated against named controls

The four thresholds — `RESPONSE_EPSILON`, `SPAN_MIN`, `LIVE_FRACTION_MIN`, and `CLIFF_MAX` — SHALL be
positioned from a measured sweep of the whole descriptor table, inside the gap between a named
must-pass set and a named must-fail set, with the measured distribution recorded beside the constants
in `src/ui/api/response_probe.nim`. Three of the four sit calibrated inside that gap;
`RESPONSE_EPSILON` stands at its provisional value because neither anchor set separates on it, so no
measurement yet gives it an edge to sit against.

The must-pass set is `friction`, `fieldOpacity`, `exposure`, `contrast`, and `sphViscosity`, declared
as `MustPass` in `tests/test_response_probe.nim`. The must-fail anchor is `rdFeed` and `rdKill`, which
must fail on the default slice and pass on their joint group's slices, pinning both that their
deadness is two-dimensional geometry and that the joint remedy repairs it. `trailLength` and
`glowIntensity` belong to neither set: the sweep measured both live end to end — trail persistence is
linear in the slider by construction of the shipped mapping (`trail_core.persistenceFrames` records
the collapse to a straight line), and glow keeps growing at every step under its display clamp — so
their predicted remedies never fired, and the anchor set holds two-dimensional deadness without them.

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

### Requirement: A probe measures what the user can see

A probe's observable SHALL include the display-side transformations standing between the
parameter's math and the screen that can extinguish or saturate the effect — clamps, coverage,
compositing — so travel the screen cannot answer measures as dead rather than as live.

An observable that keeps moving where the display has stopped is a wrong probe, and the calibration
rule treats it as one: the probe is fixed, never the threshold.

The shipped instance is `visibleRadiusProbe` in `src/ui/api/response_probe.nim`, which reports the
composed on-screen radius through `camera_core`'s whole chain at the density multiplier's floor,
measured on the two zoom-corner slices.

No shipped parameter reaches the extinguished state below: `tests/test_camera_core.nim`, suite `A
Floor On What Can Be Seen`, holds the worst reachable corner — minimum size, the density multiplier's
floor, minimum zoom — above `PARTICLE_VISIBLE_RADIUS_FLOOR_PX`, and pins that the check can go red by
measuring the retired 0.25 zoom floor beneath it. That scenario governs the next composed-size
observable rather than describing a live one.

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
its own. Both directions read the bounds the descriptor serves at the moment of the call, so a derived
bound warps the interval that is live at that moment and position keeps meaning the fraction of the
reachable track.

The curve changes the handle's position and nothing else. Stored values, preset keys, clamping, notch
coordinates, and the displayed readout are all independent of it.

`valueAt` and `positionOf` in `src/ui/api/slider_curve.nim` are the pair; `src/web_api.nim` serves
both and the curve name across the boundary, and `web-ui/src/components/ParamSlider.tsx` calls
`paramPositionOf` and `paramValueAt` for the handle, the ticks, and the notch magnet.
`tests/test_slider_curve.nim` pins the pair as mutual inverses, the endpoints, monotonicity, and
clamping under `cLinear`, `cLog`, and `cPower`; `tests/test_param_descriptor.nim` re-runs the
round-trip on every shipped hint numeral and notch coordinate.

No shipped descriptor declares `cLog` or `cPower`, so the round-trip guarantee runs against the
constructed descriptors `tests/test_slider_curve.nim` builds for the three curves rather than against
a shipped instance.

#### Scenario: A curve does not move a stored value
- **WHEN** a parameter's curve changes
- **THEN** a preset saved before the change loads to the identical value after it, because the curve
  appears only in the position mapping and its boundary serialization, never in the store, the clamp,
  or the preset schema

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

Joint entry is gated natively: `tests/test_response_probe.nim`, test `entry evidence: the live region
moves with the partner`, requires a measured boundary shift larger than `JointPointNeighbourhood`
across the named-point slices, and a failure there dissolves the group rather than being patched
around. The exempt set is pinned by the same suite.

The order of the ladder is **unenforced** — nothing detects a control curved before anyone tried
re-ranging it, and nothing detects a range moved without the measurement that justified it. A gate
that recorded the failing metric in the descriptor and refused a remedy whose predecessor had not
been measured would close it.

#### Scenario: A re-ranged bound records its measurement
- **WHEN** a range bound moves to remove dead travel
- **THEN** the measured live fraction before and after appears beside the constant

#### Scenario: A joint group cannot be entered by assertion
- **WHEN** a joint group is declared without recorded slice measurements showing a partner-coupled
  live boundary
- **THEN** `just test` fails at the entry-evidence assertion naming the member whose live boundary
  did not move

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

`JointMembers` and `JointPointNeighbourhood` in `src/ui/api/response_probe.nim` declare the one
shipped group, the feed/kill pair over the `RD_REGIMES` points. `tests/test_response_probe.nim`,
suite `The Feed/Kill Joint Group Holds Its Guarantees`, asserts slice alignment with the regime table,
the entry evidence, and per-member liveness within the neighbourhood of every named point. The suite
names where the adopted guarantees are held instead of copying them: joint reachability by the
notch-lattice assertions in `tests/test_param_descriptor.nim`, attractor fidelity by `The Regime
Deposit Floor Preserves The Regime` in `tests/test_field_core.nim`, and continuity of travel between
points by the tour tests in `tests/test_climate_core.nim`.

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

`ParamSlider.tsx` calls `acknowledge()` as the first statement of the range input's `onInput` handler,
before the value is written, and `acknowledge()` sets the `acknowledged` signal unconditionally,
pushing the fade-out timer forward on each further event so a drag holds the highlight instead of
strobing it.

**agent-checkable.** `web-ui/test/acknowledge.test.ts` covers `horizonMs` alone and never mounts the
component, so no automated gate binds the rendered acknowledgement. The procedure that detects a
violation: launch the app, move a control with a structural horizon, and capture the panel on the
frame after the input event; the control group carries the `acknowledged` class and the readout shows
the new value while the canvas has not yet changed. A violation shows as the class or the readout
lagging until the simulation responds.

#### Scenario: A slow parameter still acknowledges instantly
- **WHEN** a parameter whose response horizon is structural is moved
- **THEN** the acknowledgement appears in the same tick as the input event

### Requirement: Every control declares how long its response takes

A descriptor SHALL declare a response horizon — `rhInstant`, `rhSettling`, or `rhStructural` — and the
panel SHALL show a settling indicator while a non-instant horizon has not elapsed.

Where a stepping oracle exists, a test asserts the observable moves past the response epsilon within
the declared horizon. Where none exists, the descriptor SHALL carry `horizonReview`, so the
declaration reads as claimed rather than measured.

`tests/test_dormancy.nim`, suite `Horizons Are Executable Where A Mirror Steps`, holds both halves: it
steps the field probes over the worms regime and requires feed, kill, and deposit to move the alive
fraction inside the stepping window, and its test `every non-instant horizon without the stepping
mirror is review-labelled` binds `horizonReview` in both directions — set on every non-instant horizon
with no stepping mirror, clear on every instant horizon and on the three the suite executes. A
companion test requires every render-store parameter to declare `rhInstant`.
`ParamSlider.tsx` reads `horizonMs(descriptor.horizon)` and renders the settling indicator for that
duration.

**agent-checkable** for a `horizonReview` declaration's truth, since no oracle steps it. The procedure:
launch the app, move the control, and sample the canvas at the declared horizon and again well past
it; a horizon declared too short shows the picture still changing after it elapses, and one declared
too long shows the picture settled well before.

#### Scenario: A declared horizon is measured where it can be
- **WHEN** a parameter's probe integrates a simulation
- **THEN** a test asserts its observable moves within the declared horizon

#### Scenario: An unmeasurable horizon is labelled
- **WHEN** a parameter has no stepping oracle
- **THEN** its descriptor carries `horizonReview`, and `just test` fails if the flag and the mirror
  disagree in either direction

### Requirement: A control that cannot act now names what is missing and stays usable

Every control SHALL remain offered at all times, and where a control's effect depends on state that
does not exist in the running world — a coupling strength at zero, a consumer bound only under another
control's setting, world state that has not yet arisen — the panel SHALL render it dormant with one
line naming the missing precondition, keep it in place, and keep it movable so a value can be set
before the world catches up.

The dormancy predicate is declared per descriptor over named state fields and streamed stats, and a
native check SHALL assert every name it uses resolves, so a renamed field breaks loudly. A control
is never dormant under its own value alone: zero is an ordinary value, and the control sitting at
zero is the way back. A compound predicate MAY read its carriers where their own movement can break
the condition, so the control still holds its own way out.

`src/ui/api/dormancy.nim` holds the registry. `tests/test_dormancy.nim`, suite `Dormancy Predicates
Name Real State`, walks every named simulation field, render field, and world signal against the state
records and the stats push, requires every carried `dormantWhen` to resolve and every registered
predicate to be carried, requires each predicate to carry the line the panel shows, and asserts no
control goes dormant under its own value alone. Suite `Each Predicate Distinguishes Dormant From
Awake` fires each predicate on both sides of its condition, including the compound field predicate in
the supercritical region before ignition.

**agent-checkable** for the rendering half. `ParamSlider.tsx` applies the `control-dormant` class and
renders `descriptor.dormantLine`, and the range input carries no `disabled` attribute, so the control
stays mounted and accepts input; no automated gate covers the mounted component. The procedure: launch
the app, turn bloom off, and confirm the five grade sliders sit at their same positions in the panel,
each showing the line naming the Bloom toggle, and that dragging one still writes its value; then turn
bloom on and confirm all five wake without the panel reordering.

#### Scenario: The grade sliders under a disabled consumer
- **WHEN** bloom is off
- **THEN** Exposure, Bloom Intensity, Saturation, Contrast, and Temperature render dormant with a
  line naming the Bloom toggle, and enabling bloom wakes all five in the same tick

#### Scenario: A coupling family at zero strength
- **WHEN** a coupling's strength is zero
- **THEN** every control whose effect that strength multiplies renders dormant naming the strength,
  while the strength's own control stays fully live

#### Scenario: The field calibrators before ignition
- **WHEN** the field rests at its trivial fixed point and the live feed and kill sit where no
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

`web-ui/src/lib/matrix-cell.ts` is the pure machine: `editText` returns the in-progress text for the
cell under edit and the live value for every other cell, and `commitValue` parses, clamps through the
boundary's clamp, and returns null for text holding no number, which the editor treats as a revert.
`MatrixEditor.tsx` commits on `onChange` and never on `onInput`. Enforced by
`web-ui/test/matrix-cell.test.ts` under `just test-ui`, which covers empty, `-`, and `0.` as held
intermediates, the external-update case cell by cell, clamping on commit, and the null-commit revert.

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

`overlayKindFor` in `src/overlay_core.nim` is the closed set, and `tests/test_overlay_core.nim`, suite
`The Overlay Set Is Closed`, walks the whole descriptor table and fails naming any id that enters it
beyond `interactionRadius` (a ring) and `cameraZoom` (a frame). The same suite pins the coverage math
`overlay.wgsl` mirrors. `ParamSlider.tsx` raises the drag on `onPointerDown` and lowers it on
`onPointerUp`, `onPointerCancel`, and `onChange`, through `gardenAPI.dragOverlay` into
`canvas_input.dragOverlayId`, which `src/webgpu_render.nim` reads when it picks the overlay kind for
the frame.

**agent-checkable** for the drawn overlay. The coverage functions and the closed set are natively
tested; whether a ring appears on screen during a real drag is not. The procedure: launch the app,
press and hold on the Interaction Radius slider, capture the canvas, and confirm a ring of the
parameter's world radius is drawn at the cursor; release and capture again, and confirm it is gone.

#### Scenario: Interaction radius shows its reach
- **WHEN** the interaction-radius slider is being dragged
- **THEN** a ring of that world radius draws at the cursor until release
