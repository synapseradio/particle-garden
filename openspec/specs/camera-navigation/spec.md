# camera-navigation

## Purpose

This capability owns how a viewer moves through the world: the camera's position and zoom, the
toroidal image each drawable is projected to, and the mouse, wheel, touch and key gestures that
change the view. It is one capability because every part answers the same question — where is the
viewer, and what does the viewer see from there. The pure geometry lives in `src/camera_core.nim`
and is mirrored by `web/shaders/modules/camera_transform.wgsl`; the bindings live as data in
`src/ui/input/binding_table.nim`.

The byte layout of the camera uniform belongs to `gpu-buffer-layout`. The zoom slider's range and
its labelled notches belong to `parameter-range-authority`. Which passes read the camera uniform,
and in what order, belongs to `gpu-frame-registry`. This spec cites those relations and leaves
their detail to them.

## Requirements

### Requirement: The camera navigates a seamless torus

The renderer SHALL draw each particle at its nearest toroidal image relative to the camera centre,
through the same shortest-path wrap the physics defines, so panning and zooming show no hard cut.
`camera_core.nearestImageDelta` (`src/camera_core.nim:81-89`) is the pure statement of that
mapping and `cameraNearestDelta` in `web/shaders/modules/camera_transform.wgsl` is its shader
mirror; `cameraToClip` in the same module chooses one image per particle and `cameraOffsetToClip`
adds each quad corner afterwards, so a quad straddling the half-world line cannot tear.

One nearest image covers the whole window because the view never spans more than one world:
`CAMERA_ZOOM_MIN` is 1.0 (`src/config_ranges.nim:320`), asserted at or below 1.0 against
`CAMERA_ZOOM_MAX` at `src/config_ranges.nim:532-533`.

Enforced by: `tests/test_camera_core.nim` suites "The Nearest Toroidal Image Hides The Seam"
(`:46-81`) and "Panning Is Seamless And Exact" (`:83-155`), which pin the short-way offset, the
half-world bound, clip-space continuity across the boundary, and the identity of a view panned by
exactly one world span.

#### Scenario: Crossing the boundary under the camera

- **WHEN** a particle wraps across the world edge while visible
- **THEN** its clip-space position moves continuously, asserted natively, and what reaches the
  screen shows no jump — **agent-checkable**: run `just be`, press `0` to reframe the world, hold
  an arrow key until the pointer-side edge passes under the view, and capture successive frames;
  a violation appears as particles vanishing at one edge and reappearing displaced

#### Scenario: A full pan returns where it started

- **WHEN** the camera pans by exactly one world width or one world height
- **THEN** the view is identical to before the pan, asserted natively

### Requirement: Light wraps like physics

The render-path samplers SHALL use repeat addressing (`addressModeU` and `addressModeV`,
`src/webgpu_render.nim:529-530`), and the trail SHALL be reprojected through two cameras: this
frame's at `@binding(4)` and the previous frame's at `@binding(5)`, both records of the same
`Camera` layout (`web/shaders/src/fade.wgsl:27-35`). Glow, trails and bloom therefore continue
across the world boundary the way positions already do.

Two cameras carry the previous view because a per-frame UV delta is exact only while zoom holds
still. During a zoom the correct mapping is a scale about a point, which the second record states
and an offset cannot.

Enforced by: `tests/test_camera_core.nim` suite "Screen UV And World Are Exact Inverses"
(`:232-331`), which pins that an unmoved camera reprojects every pixel onto itself, that a pan
shifts the reprojection by a constant across the screen, and that a zoom does not.

#### Scenario: Bright cluster at the edge

- **WHEN** a glowing cluster sits on the world boundary
- **THEN** its glow and trail continue on the far side with no seam — **agent-checkable**: run
  `just be`, raise glow and trail length, pan until a bright cluster straddles the edge, and
  compare the two sides of the boundary in a captured frame; a violation appears as a straight
  line of discontinuity along the wrap

### Requirement: Apparent scale moves as one

Particle size, trail length, and glow radius SHALL scale by the same factor at every zoom level.
Scaling only some of the three is what makes zoom read as broken, which is why they are specified
together.

Legibility at the widest view rests on a floor on the composed on-screen radius:
`PARTICLE_VISIBLE_RADIUS_FLOOR_PX` is 0.5 (`src/config_ranges.nim:116-117`), composed by
`camera_core.visibleRadiusPx` (`src/camera_core.nim:37`) from the size parameter, the density
multiplier and the zoom. A native test asserts the worst reachable corner — minimum size, the
density multiplier's floor, minimum zoom — stays at or above that floor, and a re-range that dips
the corner goes red there. A clamp at the end of the shader chain is that red's remedy.

Enforced by: `tests/test_camera_core.nim` suite "A Floor On What Can Be Seen" (`:378-399`, the last
suite in the file).

#### Scenario: Zooming in approaches creatures

- **WHEN** zoom increases
- **THEN** particles, their trails, and their glow all grow by the same factor —
  **agent-checkable**: run `just be`, capture a frame at zoom 1, press `+` a fixed number of times,
  capture again, and measure a cluster's dot radius, trail length and halo radius in both frames;
  the three ratios agree, and a violation shows one of them fixed or moving at a different rate

#### Scenario: Zoomed out stays legible

- **WHEN** zoom sits at its minimum with size and the density multiplier at their floors
- **THEN** the composed on-screen radius stays at or above the recorded pixel floor, asserted
  natively

### Requirement: Navigation input is pure and natively tested

Wheel and keyboard listeners SHALL live in `src/canvas_input.nim` with pure handlers reaching the
camera through nil-checked getter and setter hooks. `src/app.nim:379-380` wires both hooks, and
that is the one wiring point: the zoom slider reaches the camera through the same pair
(`src/web_api.nim:624-629`), so no two inputs can end up pointed at different cameras. The handlers
are natively tested the way the mouse and touch handlers already are.

Every mouse, wheel, touch and key binding SHALL be declared once, as data, in `InputBindings`
(`src/ui/input/binding_table.nim:34-78`): plain scroll pans; pinch, or scroll with Ctrl or Cmd
held, zooms at the cursor; middle-button drag pans; the arrow keys pan; `+` and `-` zoom at the
view centre; `0` reframes the whole world.

Enforced by: `tests/test_camera_input.nim` (wheel zoom and pan, middle-button drag, key
dispatch and clamping, all native) and `tests/test_input.nim` suite "The Binding Table Is The
Single Declaration" (`:313-344`, the last suite in the file), which holds every row to a description, forbids two rows claiming
one key, and routes every camera-key row through `cameraKeyFor`.

#### Scenario: Zoom at cursor

- **WHEN** a pinch, or the wheel with Ctrl or Cmd held, turns over a world point
- **THEN** that point stays fixed on screen while zoom changes, asserted natively

#### Scenario: A wheel gesture names itself

- **WHEN** a wheel event arrives with no modifier held
- **THEN** it pans, and the same event with Ctrl or Cmd held zooms at the cursor instead

### Requirement: Touch reaches gesture parity

Touch SHALL support the repel gesture through a two-finger tap and SHALL register a touchcancel
handler. `handleTwoFingerTap` (`src/ui/input/touch_handler.nim:53-68`) fires a blast at the two
fingers' midpoint and clears the press the first finger registered; `handleTouchCancel`
(`:50-51`) releases every button.

The midpoint carries the blast because a blast at either finger would sit off to the side of the
gesture, on whichever side the browser's undefined touch order happened to report first.

Enforced by: `tests/test_input.nim` suites "TouchHandler - Touch Cancel" (`:251-260`) and
"TouchHandler - Two Finger Tap" (`:262-311`).

#### Scenario: Two-finger tap

- **WHEN** two fingers tap the canvas
- **THEN** a blast fires at the midpoint between them, and the press the first finger registered is
  cleared

#### Scenario: Interrupted touch

- **WHEN** the browser cancels an in-progress touch
- **THEN** every button in the input state is released, leaving none stuck down

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
