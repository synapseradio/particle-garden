## ADDED Requirements

### Requirement: The long-range mesh buffers are sized by the allocation ceiling

The long-range chain's four buffers — the fixed-point density accumulator, two complex spectra, and
the real potential — SHALL be sized from the Nim constants that hold the maximum grid width, the
maximum grid height and `MAX_SPECIES`, never from the live grid size, and SHALL be allocated once.
`byteLengthFor` (`src/webgpu_compute.nim`) SHALL carry one exhaustive `case` entry per buffer, so a
buffer added without its size is a compile error rather than a silently uncleared allocation.

Two spectra are required rather than one. The kernel pass reads every source species' spectrum at a
bin to write each receiving species' spectrum at that bin, so its output cannot alias its input; each
transform stage likewise reads one buffer and writes the other. The element types differ per binding
and the buffers are not shared with any other pass: the density is `atomic<i32>`, the spectra are
pairs of `f32`, the potential is `f32`.

Enforced by: the `case` in `byteLengthFor`, which the Nim compiler requires to cover every `SimBuffer`
value (build-asserted); static assertions in `src/config_ranges.nim` that the ceiling dimensions are
powers of two (build-asserted); the binding manifest in `src/wgsl_lint.nim` swept against the bundled
shader set by `tests/test_wgsl_lint.nim`, which holds that each buffer is bound only by the passes
that declare it (test-held).

#### Scenario: A buffer added without a size fails the compile

- **WHEN** a `SimBuffer` value is added and `byteLengthFor` gains no case for it
- **THEN** the Nim build fails

#### Scenario: The live size does not move the allocation

- **WHEN** the live grid size changes to any declared size
- **THEN** every long-range buffer keeps the byte length the ceiling gave it

### Requirement: The long-range density accumulator holds the whole particle budget

The long-range density SHALL encode at a fixed-point scale, its own rather than the velocity deltas'
`FIXED_POINT_SCALE`, chosen so that every particle the count slider allows landing in one cell
encodes without saturating: `MAX_PARTICLES * scale` SHALL be strictly less than the maximum of a
signed 32-bit integer, asserted statically beside the constant.

The worst case is exactly `MAX_PARTICLES`. A particle deposits unit charge, spread across the cells
its assignment touches with weights summing to one, so the accumulated value counts particles and
nothing bounds how many occupy one cell. Sharing the velocity scale of 65536 would cap the
accumulator at 32768 particles per cell, which the particle ceiling passes, and an `i32` past its
maximum wraps negative — a density the kernel reads as a hole where the world holds its densest
clump, with the force reversed there and nowhere else. Headroom carries this in place of a check,
because the total is formed by `atomicAdd` across threads and no contribution sees the running total.

The strength SHALL NOT multiply the deposit. It multiplies in the force pass alone, which is what
keeps this bound a function of the particle ceiling only and not of a slider's maximum.

Enforced by: a static assertion in `src/config_ranges.nim` or beside the scale in
`src/long_range_core.nim` relating the scale to `memory_layout.MAX_PARTICLES` (build-asserted);
`tests/test_long_range_core.nim` suite "The Full Particle Budget Encodes Without Saturating", which
pins that the whole budget in one cell encodes as itself, that the scale is a power of two, and that
one particle's smallest assignment weight stays above the accumulator's resolution (test-held).

#### Scenario: Every particle in one cell

- **WHEN** the full particle budget lands in a single grid cell
- **THEN** the encoded density stays inside the signed 32-bit range and decodes to the particle count

#### Scenario: Raising the particle ceiling carries the encoding with it

- **WHEN** `MAX_PARTICLES` changes
- **THEN** the static assertion re-evaluates against the new ceiling and fails the build if the scale
  no longer holds it

### Requirement: Long-range parameters have their own uniform

The long-range chain's per-frame numbers SHALL live in an `LrParamsLayout` table in
`src/gpu_types.nim`, declared and offset-asserted like every other layout and generated into a WGSL
struct module by `tools/wgsl_bundle.nim`, and SHALL NOT extend `SimParamsLayout` or
`FieldParamsLayout`.

It carries the live grid width and height, the live species count, the force scale with the substep's
frame already folded in, the inverse squared screening length the reach maps to, the softening
width, the world extent the wavenumber mapping needs, and the inverse-transform normalization. The
attraction matrix is not among them: the kernel pass binds `SimParams` and reads the matrix already
there (`src/gpu_types.nim:604`), because one matrix acts at both ranges.

A separate uniform rather than spare words in `SimParams`: the chain's five pipelines all bind it and
nothing else does, so the coupling's numbers travel together and a later change to the grid seam
touches one table.

Enforced by: the static offset and size assertions every layout carries in `src/gpu_types.nim`
(build-asserted); `tests/test_gpu_types.nim` suite "Generated LrParams Layout", pinning the field
order, the written size and the allocated size (test-held); the bundler's unresolved-placeholder
failure for the generated module (build-asserted).

#### Scenario: The struct is generated, not written

- **WHEN** a member is added to `LrParamsLayout`
- **THEN** the WGSL struct regenerates from the table and no shader file is hand-edited

#### Scenario: An offset drifts from WGSL's own layout

- **WHEN** a declared offset disagrees with WGSL's layout algorithm for the table
- **THEN** the Nim build fails at the layout's static assertion
