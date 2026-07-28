## ADDED Requirements

### Requirement: The camera navigates a seamless torus

The renderer SHALL draw each particle at its nearest toroidal image relative to the camera centre,
using the same shortest-path wrap logic the physics already defines, so panning and zooming never
show a hard cut. Zooming out past 1:1 tiles the world seamlessly.

#### Scenario: Crossing the boundary under the camera
- **WHEN** a particle wraps across the world edge while visible
- **THEN** it renders continuously at its nearest image, with no jump

#### Scenario: A full pan returns where it started
- **WHEN** the camera pans by exactly one world width
- **THEN** the view is identical to before the pan

### Requirement: Light wraps like physics

The render-path samplers SHALL use repeat addressing, and the trail SHALL be reprojected by each
frame's camera delta, so glow, trails, and bloom continue across the world boundary exactly as
positions already do.

#### Scenario: Bright cluster at the edge
- **WHEN** a glowing cluster sits on the world boundary
- **THEN** its glow and trail continue on the far side with no seam

### Requirement: Apparent scale moves as one

Particle size, trail length, and glow radius SHALL scale by the same factor at every zoom level,
clamped to a floor that keeps particles legible when zoomed out far enough to tile the world.

Scaling only some of the three is the failure that makes zoom read as broken rather than merely
different, which is why they are specified together.

#### Scenario: Zooming in approaches creatures
- **WHEN** zoom increases
- **THEN** particles, their trails, and their glow all grow by the same factor

#### Scenario: Zoomed out stays legible
- **WHEN** zoom sits at its minimum
- **THEN** particles remain visible at the floor size rather than falling below a pixel

### Requirement: Navigation input is pure and natively tested

Wheel and keyboard listeners SHALL live in canvas_input with pure handlers over a camera observable,
natively tested like the existing mouse and touch handlers. Bindings: the wheel zooms at the cursor,
arrows pan, `+` and `-` zoom, `0` resets the view.

#### Scenario: Zoom at cursor
- **WHEN** the wheel turns over a world point
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
