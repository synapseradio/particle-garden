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


### Requirement: The kernel-density accumulator holds the whole particle budget

The SPH kernel-density accumulator SHALL encode at a fixed-point scale derived from `MAX_PARTICLES`,
separate from the `FIXED_POINT_SCALE` the velocity deltas use, such that the largest density the
world can produce encodes without saturating.

That largest density is exactly `MAX_PARTICLES`. `forces-sph.wgsl` divides each neighbour's poly6
weight by the self-weight, so a neighbour contributes at most 1.0 and the accumulated value counts
neighbours; nothing bounds how many particles share a smoothing radius. Sharing the velocity scale
would cap the accumulator at 32768, which the particle ceiling passes, and an i32 past its maximum
wraps NEGATIVE — a density the equation of state reads as maximal expansion and answers with force in
the wrong direction.

The scale SHALL be a power of two leaving at least `SPH_DENSITY_HEADROOM` of the signed range free,
derived in `src/sph_core.nim` and substituted into the shaders rather than written as a literal.
Headroom rather than a check, because the total is formed by `atomicAdd` across threads: no
contribution sees the running total, so no contribution can test it before adding.

Saturating the encode is not an acceptable alternative. The particle ceiling is a setting the slider
offers, so the density it produces has to encode as itself.

#### Scenario: The whole budget encodes as itself

- **WHEN** every particle the count slider allows sits inside one smoothing radius
- **THEN** the encoded density stays inside the signed 32-bit range and decodes to what was written

#### Scenario: Raising the particle ceiling carries the encoding with it

- **WHEN** `MAX_PARTICLES` changes
- **THEN** the density scale re-derives from it, and no other constant needs editing for the new
  ceiling to encode

#### Scenario: A decoder reading the wrong scale

- **WHEN** a pass decodes the density accumulator with the velocity scale's inverse
- **THEN** the value is wrong by the ratio between the two scales rather than absent, which is why
  each scale has exactly one encoder and one decoder and the module says so

### Requirement: Crowding and scale parameters ride SimParams

The crowding strength and the SPH radius fraction SHALL be members of the `SimParamsLayout` table in
`src/gpu_types.nim`, reaching the shaders that read them (`forces.wgsl`, `forces-sph.wgsl`) through
the generated struct module and the generated write indices, with the written and allocated size
assertions updated in the same edit. Neither value reaches a shader by any second route, and neither
gets a uniform of its own — they are ordinary simulation parameters in the struct the force passes
already bind.

#### Scenario: The members are added through the table

- **WHEN** the two fields are appended to `SimParamsLayout`
- **THEN** their write indices, the struct's element count, the buffer allocation size, and the
  generated WGSL struct all follow from that one table edit, and the size assertions pin the new
  totals

#### Scenario: A shader reads a member the table does not declare

- **WHEN** a shader references a SimParams member absent from the table
- **THEN** the shader fails to compile against the generated struct at bundle time
