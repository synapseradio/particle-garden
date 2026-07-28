# gpu-buffer-layout

## Purpose

This capability owns the byte-level agreement between Nim, WGSL, and the GPU: where each field of a
shared struct sits, how large each buffer and uniform allocation is, and which mechanism keeps the two
languages from disagreeing. It is one capability rather than two because every part answers the same
question — where does a byte live, and which file is allowed to say so. It excludes which passes read
those buffers (`gpu-frame-registry`) and which values are legal to write into them
(`parameter-range-authority`).

## Requirements

### Requirement: Memory offsets are computed in one module

`src/memory_layout.nim` SHALL be the only place that computes a byte offset into the shared
particle memory. Every offset MUST be derived at compile time from a single arithmetic pass
(`computeMemoryOffsets`, `src/memory_layout.nim:134-191`) and exported both as the `OFFSETS` object and
as individual constants (`src/memory_layout.nim:194-203`). Consumers MUST read those exports rather
than restate a number: `src/buffers.nim:88-129` builds every typed-array view from them, and
`calculateBufferSizes` (`src/webgpu_init.nim:137-166`) sizes every GPU buffer from the same constants.

Alignment and non-overlap MUST hold. `align4` (`src/memory_layout.nim:92-96`) is the rounding
contract, tested directly in `tests/test_memory_layout.nim:86-101`. The `static:` block at
`src/memory_layout.nim:209-225` asserts 4-byte alignment of the particle, velocity-delta, grid-offset
and sync buffers, asserts that `particlesSorted` and `sortedIndices` each begin past the end of the
region before them, and asserts that `totalSize` fits the allocated WebAssembly memory. That block
covers two of the buffer boundaries; `tests/test_memory_layout.nim:48-65` extends the same
non-overlap relation to the grid, matrix and sync regions, so the full chain is enforced by the
static assertions and the native suite together.

#### Scenario: A buffer is resized without moving the ones after it

- **WHEN** a size constant grows so that one region would begin inside the region before it
- **THEN** the `static:` assertions in `src/memory_layout.nim` fail the compile, or the non-overlap
  tests in `tests/test_memory_layout.nim` fail `just test`

#### Scenario: A consumer needs the address of a buffer

- **WHEN** any module needs the byte offset of a shared buffer
- **THEN** it reads an export of `src/memory_layout.nim` and MUST NOT recompute the arithmetic

### Requirement: The Particle struct and MAX_SPECIES are a hand-mirrored cross-language contract

The AoS Particle struct SHALL be 32 bytes with fields at the offsets declared in
`src/memory_layout.nim:59-69` — position at 0, velocity at 8, species at 16, density at 20, padding
through 31 — so that two particles occupy one 64-byte cache line and no field straddles an alignment
boundary. `PARTICLE_STRIDE == 32` is asserted at `src/memory_layout.nim:222`, and `ParticleLayout`
in `src/gpu_types.nim:80-91` restates the same offsets under the assertions at
`src/gpu_types.nim:432-436`.

The WGSL side (`web/shaders/modules/particle.wgsl:27-34`) is hand-maintained and imported by every
shader that touches a particle. `MAX_SPECIES` is the same kind of contract: `src/memory_layout.nim:49`
declares it and `web/shaders/modules/particle.wgsl:37` declares it again as `const MAX_SPECIES: u32 =
6u`.

The agreement between the Nim declarations and this WGSL module is **review-enforced**. The
assertions on both Nim sides compare a Nim table against Nim constants; the assertion at
`src/memory_layout.nim:233` compares `MAX_SPECIES` against the literal `6`, which is a tripwire that
fires when the constant is edited, not a check that reads the WGSL file. No build step parses
`particle.wgsl` and compares it to `ParticleLayout`.

#### Scenario: A Particle field is added or moved

- **WHEN** a field is added to `ParticleLayout` or an offset changes in `src/memory_layout.nim`
- **THEN** the `static:` assertions in both modules fail the compile, and the matching edit to
  `web/shaders/modules/particle.wgsl` MUST be made by the author, because no automated check will
  catch its absence

#### Scenario: MAX_SPECIES changes

- **WHEN** `MAX_SPECIES` is given a value other than 6
- **THEN** the assertion at `src/memory_layout.nim:233` fails the compile, naming
  `web/shaders/modules/particle.wgsl` as the file that must change with it

### Requirement: Every GPU uniform struct is declared as a layout table

Each uniform struct the simulation writes SHALL be declared once as a `GpuStruct` table in
`src/gpu_types.nim:78-263` — name, ordered fields, each field's WGSL type, byte offset and size, and
the struct's `totalSize`. The tables cover `Particle`, `GridParams`, `ScanParams`, `SimParams`,
`RenderParams`, `FadeParams`, `FieldParams`, `BloomParams` and `TonemapParams`.

Everything downstream MUST be derived from the table rather than written by hand. The `genFieldIndices`
macro (`src/gpu_types.nim:399-424`) emits the f32/u32 write indices from the field offsets — a scalar
field yields one constant, a `vec2` yields `_X` and `_Y`, an array yields `_START` and `_END`, and a
trailing `_PARAMS_F32_COUNT` gives the element count. `src/webgpu_compute.nim:702-783` and
`src/webgpu_render.nim:1165-1336` write their uniform staging arrays through exactly those constants,
and size the arrays with the generated count. Buffer allocation MUST use `wgslUniformSize`
(`src/gpu_types.nim:339-342`), as at `src/webgpu_compute.nim:599-607` and
`src/webgpu_render.nim:214,397,859,871`.

Two uniform structs stand outside the table mechanism and are **review-enforced**: `IntegrationParams`
is declared inline in `web/shaders/src/integrate.wgsl:50-59` with a hand-written `INTEG_*` index block
at `src/gpu_types.nim:498-507`, and `GridParams`/`ScanParams` have layout tables but hand-written
index blocks at `src/gpu_types.nim:472-492`. `tests/test_gpu_types.nim:111-156` pins the generated
`SIM_*` indices against their field offsets, and `tests/test_gpu_types.nim:159-301` does the same for
the render, field, bloom and tonemap indices.

#### Scenario: A uniform member is added

- **WHEN** a field is appended to a layout table in `src/gpu_types.nim`
- **THEN** its write index, the struct's element count, and the buffer allocation size all follow from
  that one edit, with no second place to update

#### Scenario: A write index is read from the wrong place

- **WHEN** uniform-writing code uses a literal index instead of a generated constant
- **THEN** nothing fails automatically, and the reviewer MUST reject it — this is the enforcement gap
  the generated constants exist to close

### Requirement: Declared offsets must equal WGSL's own layout algorithm

Every layout table's declared field offsets SHALL equal the offsets WGSL's uniform address-space
layout rules would assign the same field sequence. `wgslComputedOffsets`
(`src/gpu_types.nim:328-338`) walks the fields, rounding a cursor up to each field's alignment —
4 for scalars, 8 for `vec2`, 16 for `vec3`, `vec4` and arrays (`src/gpu_types.nim:66-72`) — and
`static:` blocks assert equality field by field for `SimParams` (`src/gpu_types.nim:451-455`),
`RenderParams` and `FadeParams` (`src/gpu_types.nim:520-527`), `FieldParams`
(`src/gpu_types.nim:543-547`), and `BloomParams` and `TonemapParams` (`src/gpu_types.nim:565-569`).
`toWgslStruct` (`src/gpu_types.nim:344-364`) re-checks the same equality plus each field's own
alignment and each array's `size == elemSize * count`, as `doAssert`s that abort the shader bundle.

What this proves and what it does not MUST be stated precisely. The comparison is between a declared
offset and a Nim implementation of the WGSL layout rules, both reached from the same table. It proves
that the declared offsets are the ones a WGSL compiler would choose for that field sequence, so a
hand-edited offset, a forgotten pad, or a member inserted ahead of an aligned one fails the build. It
does not read any `.wgsl` file, and it does not observe what a GPU driver computed. For the layouts
whose WGSL text is generated, the remaining gap is closed by construction rather than by this
assertion.

#### Scenario: A pad field is deleted

- **WHEN** a padding member is removed from a layout table, leaving a following member at an offset
  WGSL would not assign
- **THEN** the `static:` offset-agreement assertion for that layout fails the compile

#### Scenario: An array field is given an inconsistent size

- **WHEN** an array field's `size` no longer equals its element size times its count
- **THEN** `toWgslStruct` raises and `just shaders` fails before any shader is written

### Requirement: A layout's WGSL struct is generated from its table

The WGSL declaration of a uniform struct SHALL be emitted from its Nim layout table rather than
maintained separately. `toWgslStruct` (`src/gpu_types.nim:344-364`) renders a table as a WGSL struct
declaration, and `generateStructModules` (`tools/wgsl_bundle.nim:280-299`) writes one module per
generated layout into `web/shaders/modules/` before import resolution
(`tools/wgsl_bundle.nim:320`), so a shader reaches the struct through `//! import`. Six layouts are
generated this way: `sim_params`, `render_params`, `fade_params`, `field_params`, `bloom_params` and
`tonemap_params`. Those six modules are build output and MUST NOT be edited or committed; `.gitignore`
lists them at lines 12-17.

For a generated layout, the Nim byte-writer and the WGSL struct cannot disagree, because both are
produced from one table — agreement is structural, not asserted. The three hand-written modules
(`particle.wgsl`, `grid_params.wgsl`, `scan_params.wgsl`) and the inline `IntegrationParams` do not
have this property and are **review-enforced**, as stated in the requirements above.

The bundling machinery itself — `//! import` resolution, `{{PLACEHOLDER}}` substitution, incremental
rebuild — belongs to the shader-pipeline capability. Only the generation of struct modules from layout
tables is in scope here.

#### Scenario: A layout table changes

- **WHEN** a generated layout's fields change and `just shaders` runs
- **THEN** the corresponding module under `web/shaders/modules/` is rewritten from the table, and
  every shader that imports it picks up the new struct on the next bundle

#### Scenario: A generated module is edited by hand

- **WHEN** someone edits one of the six generated modules directly
- **THEN** the next `just shaders` overwrites it, because `generateStructModule`
  (`tools/wgsl_bundle.nim:264-271`) rewrites the file whenever its content differs from the table's
  rendering

### Requirement: Each layout's written and allocated size is pinned

Every layout SHALL have its written size and its 16-byte-rounded allocation size asserted at compile
time, so that a struct cannot silently grow past what its uniform buffer allocates or what its staging
array holds. The assertions are: `SimParams` 248 bytes written and 256 allocated
(`src/gpu_types.nim:456`), `RenderParams` 64 (`src/gpu_types.nim:528`), `FadeParams` 16
(`src/gpu_types.nim:529`), `FieldParams` 32 written and 32 allocated (`src/gpu_types.nim:548-549`),
`BloomParams` 16 and `TonemapParams` 32 (`src/gpu_types.nim:570-571`). `Particle`, `GridParams` and
`ScanParams` have their `totalSize` asserted at `src/gpu_types.nim:432,439,442`.

`FieldParams` is therefore closed at eight f32 members: a ninth field with `totalSize` raised to 36
fails the assertion at `src/gpu_types.nim:548`, and raising it to 48 fails
`src/gpu_types.nim:549` as well. A new reaction-diffusion uniform member MUST be added as a separate
layout rather than by growing `FieldParams`.

One case escapes the assertions and is **review-enforced**: a ninth field appended while `totalSize`
is left at 32. `wgslComputedOffsets` checks offsets, not the struct's declared extent, and the
"totalSize covers its final field" test at `tests/test_gpu_types.nim:50-53` runs only over
`ParticleLayout`, `GridParamsLayout`, `ScanParamsLayout` and `SimParamsLayout`. Such a field would
generate a write index past the end of the staging array `FIELD_PARAMS_F32_COUNT` sizes. A reviewer
MUST check that a layout's `totalSize` covers its last field.

#### Scenario: A ninth FieldParams member is added with the size updated

- **WHEN** a field is appended to `FieldParamsLayout` and `totalSize` is raised to match
- **THEN** the size assertions at `src/gpu_types.nim:548-549` fail the compile

#### Scenario: A struct grows past its allocation

- **WHEN** a layout's `totalSize` changes without its size assertion being updated
- **THEN** the compile fails before any code can write past the allocated uniform buffer

### Requirement: The reaction-diffusion field resources have a declared channel layout

The reaction-diffusion field SHALL live in two `rgba16float` ping-pong storage textures of
`FIELD_W` x `FIELD_H` (`src/field_core.nim:31-38`), created at `src/webgpu_init.nim:179-195`. The
format is forced rather than chosen: WebGPU does not list `rg16float` as a storage-capable format, so
a write-only storage texture cannot use it, and `rgba16float` is the nearest format that is
simultaneously storage-capable, sampled and filterable (`src/webgpu_init.nim:112-116`,
`web/shaders/src/field-resolve.wgsl:45-48`). Two of the four channels therefore exist as a consequence
of that constraint.

Channel meaning MUST be uniform across every pass: `.r` is the activator, `.g` is the inhibitor. The
two remaining channels carry no meaning — every pass that writes the field stores the literal pair
`0.0, 1.0` into them (`web/shaders/src/field-seed.wgsl:100-101`,
`web/shaders/src/field-resolve.wgsl:77`, `web/shaders/src/rd-step.wgsl:105`), and every reader takes
only `.xy` (`web/shaders/src/field-composite.wgsl:50`, `web/shaders/src/rd-step.wgsl:64`).

The deposit buffer SHALL hold one fixed-point `i32` per field cell, indexed as `cellY * FIELD_W +
cellX`, sized `FIELD_W * FIELD_H * 4` bytes (`src/webgpu_init.nim:209-212`) and indexed identically in
`web/shaders/src/field-deposit.wgsl:71` and `web/shaders/src/field-resolve.wgsl:68`. One channel is
allocated because only the inhibitor is deposited.

All of this is **review-enforced**. The texture format, the channel assignments and the deposit index
expression live in WGSL text and in JS-interop descriptor objects; no compile-time assertion or native
test compares them. `src/field_core.nim` supplies `FIELD_W`/`FIELD_H` to both sides through
`{{PLACEHOLDER}}` substitution, which is the only automated link.

#### Scenario: The field dimensions change

- **WHEN** `FIELD_W` or `FIELD_H` changes in `src/field_core.nim`
- **THEN** the texture size, the deposit-buffer byte count and the shader-side constants all follow
  from that one edit, because the shaders take the value through placeholder substitution

#### Scenario: A pass writes the field

- **WHEN** the seed, resolve, or reaction pass stores a texel
- **THEN** it writes activator into `.r` and inhibitor into `.g`, and readers MUST take only those two
  channels
