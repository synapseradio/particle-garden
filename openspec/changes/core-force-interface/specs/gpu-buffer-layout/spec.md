## MODIFIED Requirements

### Requirement: Camera uniform layout

The camera SHALL be a `CameraLayout` uniform (`src/gpu_types.nim:287-300`) — `centerX`, `centerY`,
`zoom`, `worldWidth`, `worldHeight` plus three pad words, 32 bytes — declared in `gpu_types.nim`
under the standard compile-time validation, written every frame, and consumed by the render, glow,
fade, tonemap and overlay shaders.

The world extent rides the camera, so every consumer reads one number for how big the world is. A
pass wanting a second view binds a second record of this layout: `fade.wgsl` takes this frame's
camera at `@binding(4)` and the previous frame's at `@binding(5)`, and spells those fields out
nowhere else.

Enforced by: the offset-agreement sweep and the size assertions at `src/gpu_types.nim:684-703`, and
`tests/test_gpu_types.nim` suite "The Camera Uniform Carries The World It Looks At" (`:238-284`),
which pins 8 floats and 32 bytes, the generated `CAMERA_` index order, that the world extent sits in
the camera and in neither pass's params, and that the previous frame's view is a Camera record and
not a set of FadeParams fields.

#### Scenario: Camera layout validates like the others

- **WHEN** the `CameraLayout` table changes
- **THEN** the offset-agreement assertions and generated indices update from that one table

#### Scenario: The world extent is restated elsewhere

- **WHEN** a pass's own params struct regains a world-width or world-height member
- **THEN** `just test` fails, because two structs holding one number are two chances to disagree
  about how big the world is inside a single frame
