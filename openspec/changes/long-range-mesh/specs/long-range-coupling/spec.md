## Purpose

Owns the fifth coupling: a force every particle exerts on every other at any distance, carried by a
coarse grid the particles deposit onto and a spectral solve that turns that density into a potential
each particle reads the gradient of. One capability because the deposit, the solve, the kernel and
the force pass are one chain with one output and one strength — the grid exists only to carry that
force, and every number in it (the screening length, the softening, the fixed-point scale, the
allocation ceiling) is a consequence of what the chain has to produce. The ranges and defaults of
its controls belong to `parameter-range-authority`, its buffers and uniform layout to
`gpu-buffer-layout`, and the frame's composition of its passes to `gpu-frame-registry`.

## ADDED Requirements

### Requirement: The world gains a force that does not stop at the neighbour sweep

The simulation SHALL carry a fifth coupling strength, `longRange`, whose contribution reaches every
particle from every other particle at any separation on the torus, independent of
`INTERACTION_RADIUS_MAX` (`src/config_ranges.nim:34`). Its range SHALL include zero as an ordinary
reachable value, so the coupling turns off through its own slider, and the shipped default SHALL be
zero, so a build carrying this coupling runs the same world as one without it until a control moves.

Enforced by: the static loop over coupling-strength floors at the bottom of
`src/config_ranges.nim:451-457`, which this change extends with `LONG_RANGE_STRENGTH_MIN` and fails
the build on a nonzero floor (build-asserted); `tests/coupling_space.nim`, whose nested loops gain a
fifth level so every "for every world" invariant in `tests/test_sim_registry.nim` and
`tests/test_shader_manifest.nim` widens to thirty-two corner worlds (test-held); the preset
round-trip in `tests/test_preset.nim` for the shipped zero default (test-held).

#### Scenario: Two colonies a world apart answer each other

- **WHEN** the long-range strength is non-zero and two groups of particles sit further apart than the
  interaction radius
- **THEN** each group's motion answers the other's position and mass

#### Scenario: Zero is the world without it

- **WHEN** the long-range strength is exactly zero
- **THEN** every particle's velocity delta is bit-for-bit what a build without this coupling produces

### Requirement: Reach is a screening length, continuous from local to global

The coupling SHALL expose one control, `reach`, that sets the distance past which the long-range
force is suppressed, and SHALL vary continuously over its range with no mode, no kernel selector, and
no discontinuity. The kernel SHALL be screened-Poisson (Yukawa): the response at wavenumber `k` is
proportional to `1 / (|k|² + 1/λ²)` with `λ` the reach in world units, so a small reach confines the
force to a neighbourhood and a reach past the world's width approaches the unscreened 2D
gravitational limit.

Enforced by: the reference oracle `src/long_range_core.nim` (added by this change), which holds the
kernel expression the WGSL kernel pass mirrors, and `tests/test_long_range_core.nim` suite
"Reach Sets The Decay Length", which asserts the potential of a point source falls to a fixed
fraction of its peak at a radius that increases monotonically with `λ` across the shipped range.
That the shader carries the same expression is **unenforced**, the standing condition of every
reference oracle (`docs/enforcement.md:58-64`); closed by the same step that would close it for
`field_core` — a test deriving the pairing from the module headers, or the constant travelling by
`{{PLACEHOLDER}}` from `src/shader_config.nim`.

#### Scenario: A short reach is a local force

- **WHEN** reach sits at its minimum
- **THEN** a particle's long-range contribution from a source many reaches away is negligible against
  its contribution from a source one reach away

#### Scenario: A long reach is world-wide

- **WHEN** reach sits at its maximum
- **THEN** a single dense clump moves particles on the far side of the world

#### Scenario: Reach moves without a step

- **WHEN** reach moves by one slider step anywhere in its range
- **THEN** the resulting force field changes by an amount that goes to zero with the step, with no
  jump at any value

### Requirement: The long-range chain is one coupling-owned unit

The deposit, the forward transforms, the kernel multiply, the inverse transforms and the force pass
SHALL be guarded by one `acts(...)` test on the long-range strength and SHALL be dispatched together
or not at all. No intermediate product of the chain — the density, either spectrum, the potential —
SHALL be read by anything outside the chain, which is what makes the whole chain coupling-owned under
the rule that a strength may skip a pass only when it multiplies everything that pass produces: the
chain's only output is the velocity delta its last pass writes, and the strength multiplies that
output entirely.

Enforced by: `tests/test_sim_registry.nim` suite "A Strength At Zero Skips Its Own Pass And Nothing
Else", extended with the long-range keys, which asserts that stripping them from any frame leaves
exactly `WORLD_INTRINSIC_SEQUENCE` (test-held). That no pass outside the chain binds a long-range
buffer is held by the binding manifest in `src/wgsl_lint.nim`, swept against the bundled shader set
by `tests/test_wgsl_lint.nim` (test-held).

#### Scenario: Zero dispatches none of the five

- **WHEN** the long-range strength is exactly zero
- **THEN** no deposit, transform, kernel or force dispatch belonging to this coupling appears in the
  frame, and every other pass appears exactly as it did

#### Scenario: One part in a billion dispatches all five

- **WHEN** the long-range strength is 1e-9
- **THEN** the frame dispatches exactly what a strength of 1 dispatches

### Requirement: The long-range force accumulates into the shared velocity delta

The force pass SHALL add its per-particle impulse into the shared fixed-point velocity-delta buffer
with `atomicAdd`, never with a store, and SHALL rely on the frame's clear rather than resetting the
buffer itself. It runs alongside the species force, the fluid and the field force, and `integrate`
must see the sum of all four.

Enforced by: `tests/test_sim_registry.nim` suite "Delta Buffers Have One Reset Owner" (`:171-215`),
which pins that the frame clears `sbVelocityDelta` before every pass that writes it (test-held). That
the shader uses `atomicAdd` rather than a store is **unenforced** in the same way it is for the three
existing contributors; closed by a WGSL source lint in `src/wgsl_lint.nim` rejecting a non-atomic
write to a buffer the manifest marks as shared.

#### Scenario: Four contributors in one frame

- **WHEN** forces, forcesSph, fieldForce and the long-range force all run in one frame
- **THEN** `integrate` moves each particle by the sum of all four impulses

### Requirement: The cost of the coupling does not depend on where the particles are

The work the chain dispatches SHALL be a function of the grid's live size, the live species count and
the particle count only, and SHALL NOT vary with particle positions, clustering, or the number of
neighbours any particle has. No pass in the chain performs a neighbour search.

Enforced by: `tests/test_sim_registry.nim`, which pins each long-range dispatch to a symbolic
`DispatchSize` the executor resolves from grid dimensions, species count and particle count alone
(test-held). That the measured cost is in fact flat across a settling run is **unenforced**; closed by
a perf capture of the long-range profiler slot at 30 seconds and at 150 seconds at 128 000 particles,
in the form `docs/perf-report.md` already records, showing the slot's figure within measurement error
of itself while the physics slot climbs.

#### Scenario: A settled world costs what a fresh one costs

- **WHEN** the world runs for 150 seconds and every particle has joined a clump
- **THEN** the long-range profiler slot reads what it read at 30 seconds

### Requirement: A uniform density exerts no long-range force

The zero-wavenumber mode of the potential SHALL be zero at every reach, so the force answers density
contrast and not absolute density. Adding particles uniformly across the world SHALL change no
particle's long-range impulse. In the unscreened limit this is the uniform-background convention a
periodic domain requires, because the unscreened kernel has no finite value at zero wavenumber; at a
finite reach it is a choice, and it is the choice that keeps the force invariant under a uniform
addition.

Enforced by: `tests/test_long_range_core.nim` suite "A Uniform World Pushes Nothing", which solves a
constant density on a small grid through the oracle and asserts every gradient is zero to within the
fixed-point quantum, at both a short and a long reach (test-held).

#### Scenario: A flat world is still

- **WHEN** particles are spread uniformly over the world at any reach
- **THEN** every particle's long-range impulse is zero within the deposit's quantization

#### Scenario: Doubling the population changes nothing

- **WHEN** a uniform population is added to an existing arrangement
- **THEN** the long-range impulse on each original particle is unchanged

### Requirement: The long-range term does not conserve momentum, and says so

Because the attraction matrix is asymmetric, no single potential both species read exists, and the
long-range impulses over the whole population SHALL NOT be required to sum to zero. This is a stated
property of the coupling rather than a defect to be patched: the potential a receiving species reads
is the kernel applied to the matrix-weighted sum of the source species' densities, and an asymmetric
matrix makes that potential different for each receiver. The specification asserts both halves — the
sum is zero when the matrix is symmetric, and is not required to be when it is not — so a later
change cannot quietly restore a symmetry the physics never had.

Enforced by: `tests/test_long_range_core.nim` suite "Momentum Is Conserved Only Under A Symmetric
Matrix", which sums the oracle's impulses over a population under a symmetric matrix and asserts
zero, then under an asymmetric one and asserts the sum is non-zero with the same arrangement
(test-held).

#### Scenario: A symmetric matrix leaves the centre of mass still

- **WHEN** the attraction matrix is symmetric
- **THEN** the long-range impulses over the whole population sum to zero

#### Scenario: An asymmetric matrix moves the world

- **WHEN** the attraction matrix is asymmetric
- **THEN** the long-range impulses need not sum to zero, and the world's centre of mass may drift

### Requirement: Species mix through the attraction matrix the short-range force already reads

The coupling SHALL read the same attraction matrix the species force reads, and SHALL NOT introduce a
second matrix, a second editor, or per-species long-range constants. A matrix entry therefore names
one relationship acting at two ranges: through the neighbour sweep inside the interaction radius and
through the mesh beyond it. The potential a receiving species reads SHALL be linear in the source
densities, weighted by that species' row of the matrix.

Enforced by: the binding manifest entry for the kernel pass in `src/wgsl_lint.nim`, which names
`SimParams` — the uniform carrying `attractionMatrix` at offset 64 (`src/gpu_types.nim:604`) — as the
one matrix source, swept by `tests/test_wgsl_lint.nim` (test-held); `tests/test_long_range_core.nim`
suite "The Solve Is Linear In The Source Densities", which asserts the potential of a sum of two
species' densities equals the sum of their separately-solved potentials (test-held).

#### Scenario: One edit changes both ranges

- **WHEN** a matrix cell is edited
- **THEN** the change appears in the neighbour sweep's force and in the long-range force, with no
  second control to move

#### Scenario: A row governs what a species feels

- **WHEN** species A's row gives species B a positive entry and species C a negative one
- **THEN** A's particles accelerate toward distant concentrations of B and away from distant
  concentrations of C

### Requirement: The kernel is isotropic in world units

The wavenumber a grid bin stands for SHALL be computed from the world's extent along each axis, not
from the bin's index, so that a grid whose cells are not square in world units still produces a force
that depends only on world distance. A grid of 512 by 256 cells over a 3840 by 2160 world has cells
7.5 by 8.4375 units, and indexing the kernel by bin number rather than by physical wavenumber would
stretch the force along one axis by the ratio of the cell's sides with no other symptom.

Enforced by: `tests/test_long_range_core.nim` suite "The Potential Is Isotropic In World Units",
which places a point source on an anisotropic grid and asserts the potential at equal world distances
along x and along y agrees to within the interpolation error the larger cell dimension sets
(test-held).

#### Scenario: A point source pulls equally in every direction

- **WHEN** one dense clump sits on an anisotropic grid
- **THEN** particles at equal world distance from it, in any direction, receive impulses of equal
  magnitude to within one cell's interpolation error

### Requirement: Softening bounds the mesh at the cell scale, and the two force terms overlap

The kernel SHALL be multiplied by a softening factor that suppresses structure at wavelengths near
and below one cell, so the mesh produces no force that varies on the scale of its own grid and no
force from the aliasing its charge assignment introduces. The softening length SHALL be a Nim
constant recorded in cells with its condition beside it.

This bound is at the cell scale and nothing wider. The long-range force is therefore present, and
intended to be present, inside the neighbour sweep's radius, where it adds to the species force
rather than replacing part of it. The specification makes no claim of a particle-particle
particle-mesh split, and none is available: the species force is an authored polynomial, not a
physical law with a long-range tail to subtract.

Enforced by: `tests/test_long_range_core.nim` suite "Softening Attenuates The Cell Scale", which
asserts the kernel's magnitude at the grid's Nyquist wavenumber is below a recorded fraction of its
magnitude at the wavenumber of the reach (test-held). That the result shows no grid-aligned artifact
on screen is **agent-checkable**: launch the app, raise the long-range strength with a short reach
over a settled population, and read the motion for lanes or steps aligned with the grid axes; a
violation shows as particles falling into rows spaced at the cell size.

#### Scenario: No structure below a cell

- **WHEN** the long-range force acts at any reach
- **THEN** the force field carries no feature at a wavelength shorter than a cell

#### Scenario: Both forces act inside the interaction radius

- **WHEN** two particles sit closer than the interaction radius with both strengths non-zero
- **THEN** each feels the species force and the long-range force, added

### Requirement: The grid's live size is a uniform under an allocated ceiling

Every long-range buffer SHALL be allocated once at a maximum grid size that is a Nim constant power
of two, and every shader in the chain SHALL index and bound itself by a live size the uniform
carries. Changing the live size SHALL require no buffer recreation, no texture recreation, and no
bind-group rebuild, because the allocation does not move.

The live size SHALL be chosen from a declared set of power-of-two sizes no larger than the ceiling, so
a size that is not a power of two, or larger than the allocation, is unrepresentable rather than
clamped. Each declared size SHALL satisfy the transform's own bound: one line of the grid must fit the
workgroup the transform runs it in.

Enforced by: static assertions in `src/config_ranges.nim` (added by this change) that the ceiling is a
power of two, that every declared size is a power of two no larger than it, and that the longest line
fits the workgroup limit the transform compiles against (build-asserted); `byteLengthFor` in
`src/webgpu_compute.nim`, whose exhaustive `case` sizes every long-range buffer from the ceiling and
fails to compile on a missing entry (build-asserted); `tests/test_param_descriptor.nim` for the
selector offering exactly the declared sizes (test-held).

#### Scenario: A resize costs no reallocation

- **WHEN** the live grid size changes
- **THEN** no GPU buffer is destroyed or created and no bind group is rebuilt

#### Scenario: An illegal size cannot be written

- **WHEN** any write attempts a grid size that is not one of the declared sizes
- **THEN** the write lands on a declared size, because no other value is representable

#### Scenario: The shader reads the live size

- **WHEN** the live size is smaller than the ceiling
- **THEN** the chain transforms, mixes and samples exactly the live grid, and the allocation beyond it
  is untouched

### Requirement: A long-range world serializes as its numbers

A preset SHALL carry the long-range strength, the reach and the grid size as ordinary settings, and
SHALL name no mode. A preset written without them SHALL decode with each at its default through the
same absent-key path every other setting uses, so no schema version and no migration branch is added.

Enforced by: `tests/test_preset.nim` round trip over `PresetSettings` (test-held), and the clamp in
`validateSettings` reading the ranges from `src/config_ranges.nim` (test-held).

#### Scenario: An older preset loads

- **WHEN** a preset carrying no long-range keys is applied
- **THEN** it loads with the long-range strength at zero and the other two at their defaults, through
  no migration branch

#### Scenario: A saved long-range world returns

- **WHEN** a preset carrying a non-zero long-range strength and a reach is saved and reapplied
- **THEN** both values return exactly, and the world runs the coupling it was saved with
