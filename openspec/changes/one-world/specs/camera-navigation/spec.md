## ADDED Requirements

### Requirement: The camera navigates a seamless torus

The renderer SHALL draw each particle at its nearest toroidal image relative to the camera centre,
using the same shortest-path wrap logic the physics already defines, so panning and zooming never
show a hard cut. The view never spans more than one world (`CAMERA_ZOOM_MIN = 1.0`, design D15), so
one nearest image always covers the whole window.

#### Scenario: Crossing the boundary under the camera
- **WHEN** a particle wraps across the world edge while visible
- **THEN** it renders continuously at its nearest image, with no jump

#### Scenario: A full pan returns where it started
- **WHEN** the camera pans by exactly one world width
- **THEN** the view is identical to before the pan

### Requirement: Light wraps like physics

The render-path samplers SHALL use repeat addressing, and the trail SHALL be reprojected through
two cameras — this frame's and the previous frame's, bound as two records of the same Camera layout
(`web/shaders/src/fade.wgsl:28-35`) — so glow, trails, and bloom continue across the world boundary
exactly as positions already do. Two cameras rather than a per-frame UV delta, because an offset is
exact only while zoom is unchanged; during a zoom the correct mapping is a scale about a point.

#### Scenario: Bright cluster at the edge
- **WHEN** a glowing cluster sits on the world boundary
- **THEN** its glow and trail continue on the far side with no seam

### Requirement: Apparent scale moves as one

Particle size, trail length, and glow radius SHALL scale by the same factor at every zoom level.
Legibility at the widest view is held by a floor on the COMPOSED on-screen radius
(`PARTICLE_VISIBLE_RADIUS_FLOOR_PX`, `src/config_ranges.nim:79-86`, computed by
`camera_core.visibleRadiusPx`): a native test asserts the worst reachable corner — minimum size,
the density multiplier's floor, minimum zoom — stays above half a pixel, and a re-range that dips
the corner goes red there, with a clamp at the end of the shader chain as that red's remedy.

Scaling only some of the three is the failure that makes zoom read as broken rather than merely
different, which is why they are specified together.

#### Scenario: Zooming in approaches creatures
- **WHEN** zoom increases
- **THEN** particles, their trails, and their glow all grow by the same factor

#### Scenario: Zoomed out stays legible
- **WHEN** zoom sits at its minimum with size and the density multiplier at their floors
- **THEN** the composed on-screen radius stays at or above the recorded pixel floor, asserted
  natively

### Requirement: Navigation input is pure and natively tested

Wheel and keyboard listeners SHALL live in canvas_input with pure handlers reaching the camera
through nil-checked getter and setter hooks that app.nim wires — one wiring point, shared with the
zoom slider, so no two inputs can end up pointed at different cameras — natively tested like the
existing mouse and touch handlers. Bindings, declared once in `src/ui/input/binding_table.nim`:
plain scroll pans; pinch, or scroll with Ctrl/Cmd held, zooms at the cursor; middle-button drag
pans; arrows pan; `+` and `-` zoom at the view centre; `0` reframes the whole world.

#### Scenario: Zoom at cursor
- **WHEN** a pinch, or the wheel with Ctrl/Cmd held, turns over a world point
- **THEN** that point stays fixed on screen while zoom changes

### Requirement: Touch reaches gesture parity

Touch SHALL support the repel gesture through a two-finger tap and SHALL register a touchcancel
handler, closing the gaps where touch was only a left-drag proxy and cancellation was unhandled.

#### Scenario: Two-finger tap
- **WHEN** two fingers tap the canvas
- **THEN** a blast fires at the tap position

#### Scenario: Interrupted touch
- **WHEN** the browser cancels an in-progress touch
- **THEN** the input state clears rather than leaving a button stuck down
