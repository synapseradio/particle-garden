# Spec Delta

## MODIFIED Requirements

### Requirement: The field ping-pong chain closes every frame

The reaction-diffusion frame's field texture ping-pong SHALL end each frame on the front texture: the one
the renderer, `fieldForce`, and the next frame's resolve all read. `fieldResolve` is itself a swap (front
to trail), so a frame performs `1 + steps` swaps, where `steps` is the frame's field step count, and that
total MUST be even. The substeps therefore start by writing back to the front, alternating
`rdStepToFront` and `rdStepToTrail` (`src/sim_registry.nim:452-456`). The bind groups are named for their
destination texture, so the orientation is readable at the dispatch site (`src/webgpu_compute.nim:565-568`).

The field step count changes from frame to frame as the field clock pays off the steps world time owes.
Every count the clock hands the frame builder MUST be odd and lie between 1 and the ceiling. The clock's
step type admits no other value through its constructor, and the ceiling is odd by static assertion in
`src/field_core.nim`. An even count would leave the live field on the trailing texture where nothing
looks for it, silently discarding that frame's last step.

Enforced by: the compile-time `doAssert` on the ceiling's parity in `src/field_core.nim`;
`tests/test_field_core.nim` "Every Field Step Count Is Odd And Within Its Bounds"; and
`tests/test_sim_registry.nim` "The Frame Description Follows The Clock's Count" (for every odd count from 1
to the ceiling, the substep dispatches alternate, start `rdStepToFront`, and end `rdStepToFront`).

#### Scenario: Step count made even

- **WHEN** the field step ceiling is set to an even value
- **THEN** the build fails at compile time

#### Scenario: Substep sequence reordered

- **WHEN** the substep alternation starts on the trailing texture
- **THEN** `just test` fails

#### Scenario: A frame at any frame factor

- **WHEN** the field clock advances by any frame factor from 0 to 30
- **THEN** the frame runs an odd step count and its chain ends on the front texture
