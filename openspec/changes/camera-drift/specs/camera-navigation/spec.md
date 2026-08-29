## ADDED Requirements

### Requirement: The view moves itself while drift is on

With the camera drift switched on, the camera SHALL advance every frame on elapsed wall-clock
seconds, with no input of any kind. The advance SHALL be a displacement applied to the camera the
frame finds, never a position computed from a phase, so the drift holds no view of its own.

The pan SHALL travel at a speed expressed in view widths per minute, which makes the apparent speed
independent of zoom the way `pixelPanDelta` and `panStep` already make gesture travel independent of
zoom. The zoom SHALL breathe through a band derived from the live zoom, so the drift modifies the
framing the user chose without replacing it.

The advance SHALL use elapsed wall-clock seconds and not the time-scaled step, so a speed named in
minutes means minutes at any simulation rate.

Enforced by `tests/test_camera_drift.nim` over the pure advance, and by the constant-time property
below. **Agent-checkable** in the running app: run `just be`, open the Camera section, switch
Drift on, and sample `gardenAPI.getParam("cameraZoom")` at intervals over a minute with no input.
A sequence of distinct values settles that the camera moved on its own. An unchanging value is the
violation.

#### Scenario: A quiet app moves its own view

- **WHEN** the drift is on and no pointer, wheel, key or slider input arrives for a minute
- **THEN** the camera centre and the camera zoom both differ from where they were a minute earlier

#### Scenario: The named speed is the speed delivered

- **WHEN** the pan advance is accumulated over sixty simulated seconds at a given speed, at any
  frame rate
- **THEN** the total travel equals that speed in view widths, and two different frame rates over the
  same elapsed seconds agree

#### Scenario: A stopped clock leaves the camera exactly where it was

- **WHEN** an advance arrives with zero elapsed seconds, as a throttled or backgrounded tab delivers
- **THEN** the camera is unchanged in every component

### Requirement: A camera-moving input yields the drift, which resumes where the user left it

Every user-facing camera write SHALL stamp the camera as touched: the middle-button drag, the wheel
pan, the wheel and pinch zoom, the arrow keys, the zoom keys, the reset key, and the Zoom slider.
The drift SHALL make no advance until the configured quiet interval has elapsed since the last
stamp.

On resuming, the drift SHALL continue from the camera the user left, in position and in zoom, with
no jump in either. It SHALL NOT return to any remembered view of its own, and it SHALL NOT switch
its own toggle off.

The drift's own write SHALL NOT stamp the camera, or the drift would suppress itself.

The stamp SHALL be added to the existing getter and setter pair, not beside it. The single wiring
point stays single: every user-facing write reaches the camera through the stamping wrapper over
those hooks, and the drift reaches it through the unstamped setter, so no input ends up pointed at
a different camera.

Enforced by `tests/test_camera_drift.nim` for the interval and the no-jump property over the pure
state transition, and by a source-reading assertion in the same suite that every camera-moving
handler reaches the camera through the stamping wrapper, on the pattern
`tests/test_panel_reachability.nim` uses to read the panel source. **Agent-checkable** in the running
app: switch Drift on, wait for motion, then drag with the middle button and confirm the grabbed
point stays under the pointer for the whole drag. Then release, wait past the quiet interval, and
confirm motion resumes from the released framing without a jump.

#### Scenario: A drag is not fought

- **WHEN** the drift is running and the user starts a middle-button drag
- **THEN** the camera moves only by the drag, and the world point grabbed at the press stays under
  the pointer until release

#### Scenario: Resuming does not jump

- **WHEN** the quiet interval elapses after any camera-moving input
- **THEN** the first drifted frame differs from the camera the user left by no more than one
  advance's bounded step

#### Scenario: A nudge does not kill the piece

- **WHEN** a single camera-moving input arrives while the drift is on
- **THEN** the drift toggle stays on and the drift resumes after the quiet interval

### Requirement: The drift path does not close

The pan heading SHALL be constant, and its slope SHALL be irrational, so no finite running time
returns the camera to a centre it has already occupied. Because velocity is named in view widths and
view heights before conversion to world units, the closure condition SHALL depend on the heading
slope alone, independent of the world's dimensions and of the live zoom.

This states non-periodicity and nothing more. The view revisits neighbourhoods it has already
crossed, and no path is retraced.

Enforced by `tests/test_camera_drift.nim`, which asserts the shipped slope admits no rational
approximation within the tested denominator bound and records the smallest closure error it found,
so a heading edited to a rational value goes red.

#### Scenario: A rational heading is rejected

- **WHEN** the heading slope is set to a ratio of small integers
- **THEN** the closure sweep reports a closure inside the tested bound and the suite fails

#### Scenario: The path crosses the seam

- **WHEN** the drift runs long enough for the centre to pass a world edge
- **THEN** the centre wraps into the world span and the view shows no discontinuity, because the
  advance goes through the pan mover that rewraps and the render path draws each particle at its
  nearest toroidal image

### Requirement: A single advance moves the view by a bounded amount

At the fastest speed the slider offers and a 1/60 second frame, one advance SHALL move the camera by
no more than the declared pan ceiling in view widths and no more than the declared zoom ceiling in
zoom units. Both ceilings SHALL be constraints the path is held to, never limiters applied to it, so
raising the speed ceiling past what the flow can carry fails the sweep instead of making the view
jump.

The zoom breath SHALL have zero rate at both ends of its band, so a turning point introduces no
velocity discontinuity.

Enforced by a sweep in `tests/test_camera_drift.nim` at the speed ceiling over every band the clamp
produces, on the pattern `tests/test_climate_core.nim:203-215` uses for the tour.

#### Scenario: The sweep bounds every step

- **WHEN** the drift is advanced across a full breath at the speed ceiling in 1/60 second steps, for
  each band the zoom clamp can produce
- **THEN** no single step exceeds the declared pan ceiling or the declared zoom ceiling

#### Scenario: A widened speed ceiling is caught

- **WHEN** the speed ceiling is raised past what the declared per-frame ceilings admit
- **THEN** the sweep fails naming the step that exceeded, and no clamp silently absorbs it

### Requirement: The zoom breath is anchored on the live zoom and re-enters it exactly

The breath band SHALL be derived from the zoom the drift finds, and SHALL always contain that zoom.
The breath phase SHALL be recoverable from a zoom inside its band in closed form, so re-entering the
breath at the user's zoom produces exactly that zoom and no correction step is needed.

The band SHALL lie inside the camera zoom range at every anchor the range admits, including both of
its ends.

Enforced by `tests/test_camera_drift.nim` sweeping anchors across the whole zoom range and checking
that the band contains the anchor, lies inside the range, and that evaluating the breath at the
recovered phase returns the anchor within float tolerance. A static assertion beside the constants
holds the band factor to a value the range can carry.

#### Scenario: Re-entry at any zoom is exact

- **WHEN** the drift re-enters its breath at any zoom the camera range admits
- **THEN** the breath's value at the recovered phase equals that zoom, and the next advance moves it
  by no more than the declared zoom ceiling

#### Scenario: The band never leaves the zoom range

- **WHEN** the anchor sits at either end of the camera zoom range
- **THEN** the band it produces lies inside the range and still contains the anchor

### Requirement: Drift ships off and is inert while off

The camera drift SHALL default to off, and with it off SHALL make no write to the camera and change
no camera behaviour.

Enforced by the default in the render state record and its agreement with the preset default
(`tests/test_preset.nim:59-101` walks every preset key to the state field that owns it), and by
`tests/test_camera_core.nim:20-32`, which pins that the default camera reduces exactly to the
pre-camera clip mapping and states why: a drifted opening framing silently reframes every preset and
every screenshot. **Agent-checkable** in the running app: run `just be`, take no action, and sample
`gardenAPI.getParam("cameraZoom")` twice a minute apart. An unchanging value settles it.

#### Scenario: A fresh launch holds still

- **WHEN** the app starts and nobody touches it
- **THEN** the camera stays at the default framing, the whole world centred at zoom one

#### Scenario: Switching drift off stops the camera where it stands

- **WHEN** the drift is switched off mid-motion
- **THEN** the camera stays exactly where the last advance left it, with no return to any earlier
  framing

### Requirement: The drift speed answers to the whole control contract

The drift speed SHALL be a descriptor in the `camera` group carrying a range from the range
authority, a default from the state record that owns it, labelled notches inside its own range, a
travel curve, a response probe id, a response horizon, and a dormancy predicate naming the toggle it
depends on. It SHALL NOT carry a probe exemption.

The toggle and the speed SHALL both survive a preset round trip. The camera's position SHALL NOT,
which stays as it is.

`docs/help/60-camera.md` SHALL name the speed control and describe the yield-and-resume behaviour,
so the control cannot ship undocumented.

Enforced by `tests/test_param_descriptor.nim` (range against the authority, default against the
state record, notches inside the range, routed id names a field of its store's record),
`tests/test_response_probe.nim` (a probe or a written exemption for every descriptor, and the exempt
set pinned to exactly three ids), `tests/test_dormancy.nim` (the carried predicate id resolves and
every field it names exists), `tests/test_help_content.nim` (all four coverage relations),
`tests/test_panel_reachability.nim` (the panel places the control), and `tests/test_preset.nim`
(the preset default equals the state field that owns it).

#### Scenario: The speed control is reachable and documented

- **WHEN** the native suite runs
- **THEN** the descriptor resolves to a placed control in the panel, to a registered probe, to a
  registered dormancy predicate, and to a help line naming its id

#### Scenario: The speed dims when the drift is off

- **WHEN** the drift toggle is off
- **THEN** the speed control reports dormant, naming the precondition it waits on, and stays movable

#### Scenario: A preset restores the motion, not the view

- **WHEN** a preset saved with drift on is loaded
- **THEN** the drift toggle and speed come back as saved, and the camera stays where the viewer left
  it
