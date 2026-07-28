## ADDED Requirements

### Requirement: SpeciesChemistry uniform layout

Per-species chemistry SHALL live in a new SpeciesChemistryLayout — MAX_SPECIES × (secretion, tropism)
f32 pairs, padded to 64 bytes — in gpu_types.nim with the same compile-time offset validation and
generated WGSL struct module as every layout. FieldParamsLayout SHALL remain 32 bytes; its static
assertions continue to reject a ninth field.

#### Scenario: Chemistry layout validates like the others
- **WHEN** the SpeciesChemistryLayout table changes
- **THEN** the WGSL-computed-offset assertions and generated indices update from that one table

#### Scenario: FieldParams stays closed
- **WHEN** a change attempts to grow FieldParamsLayout past 32 bytes
- **THEN** its static assertions fail the build

### Requirement: Camera uniform layout

The camera SHALL be a CameraLayout uniform — centerX, centerY, zoom, pad — declared in gpu_types.nim
under the standard compile-time validation, written every frame, and consumed by the render, glow,
fade, tonemap, and field-composite shaders.

#### Scenario: Camera layout validates like the others
- **WHEN** the CameraLayout table changes
- **THEN** the offset-agreement assertions and generated indices update from that one table

### Requirement: Reaction parameters have their own uniform

Reaction selection and the parameters a kernel-and-growth reaction needs SHALL live in a
ReactionParamsLayout — reactionKind, kernelRadius, growthMu, growthSigma, growthDt, padded to 32
bytes — bound to the reaction pass, rather than extending FieldParamsLayout.

This uniform exists so that adding a second reaction is a new case in one shader rather than a
revision of bind-group layouts, entry counts, and the shader manifest. It reserves a structural slot;
the parameters beyond reactionKind are unexercised until a reaction reads them.

#### Scenario: Gray-Scott ignores the reserved parameters
- **WHEN** reactionKind holds its Gray-Scott value
- **THEN** the field evolves identically regardless of the other members' values

### Requirement: Reserved field-texture channels are preserved

Every pass that writes the field SHALL carry through the two channels beyond activator and inhibitor
rather than overwriting them with literals, so a multi-channel reaction can occupy them without a
format change. Those channels are already allocated at no additional cost: the ping-pong textures are
`rgba16float` because WebGPU does not permit `rg16float` as a write-only storage texture.

#### Scenario: Channels survive a full frame
- **WHEN** the field advances through resolve and every reaction substep
- **THEN** the reserved channels arrive at the renderer holding what was written into them

### Requirement: Deposit channel count is named

The deposit buffer's per-cell channel count SHALL be a named constant that every index derives from,
so that adding a channel is one constant change rather than an audit of every index expression. The
constant's value reflects what is actually written; unused channels are not allocated.

#### Scenario: Adding a deposit channel
- **WHEN** the channel-count constant increases
- **THEN** allocation, indexing, and reset all follow from it without separate edits
