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
