# long-range-mesh — design

See `proposal.md` for why. See `specs/` for what the result must do. This document is how.

## Context

The repository already runs a particle-mesh loop. `buildFrame` composes the chemistry as deposit,
solve, gradient force (`src/sim_registry.nim:297-343`): `field-deposit.wgsl` is charge assignment
with a normalized splat and a per-species signed scale, the Gray-Scott substeps are the solve, and
`field-force.wgsl` is force interpolation ending in two `atomicAdd`s into the shared velocity delta
(`web/shaders/src/field-force.wgsl:81-84`). This change is that loop with a spectral solve in the
middle. Nothing here is a new kind of thing; the parts that are new are the transform, the k-space
kernel, and a grid whose size arrives as a uniform.

Three facts shape every decision below.

- **The world is a torus** (`web/shaders/modules/field_grid.wgsl:29-31`). Periodic boundaries are what
  a discrete Fourier solve assumes, and they are the awkward part of this method everywhere else. Here
  they are free and exact.
- **The attraction matrix is asymmetric** (`src/config_ranges.nim:63-64`). No single potential both
  species read exists, so the solve produces one potential per receiving species.
- **The budget is the settled headroom.** 3.75 ms at 128 000 particles (`docs/perf-report.md:140`),
  against a physics trace that was still climbing when the measurement window closed.

## Goals / Non-Goals

**Goals**

- One coupling strength, one reach control, five passes, zero new abstractions over passes.
- Cost that is a function of grid size, live species count and particle count, and of nothing about
  where the particles are.
- A grid whose live size is a uniform below a compile-time allocation ceiling, so the resize seam is
  open for this grid and demonstrably costs no resource recreation.
- Every number in Nim: the ceiling, the declared sizes, the fixed-point scale, the softening width,
  the ranges, the defaults.

**Non-Goals**

- No particle-particle particle-mesh correction. The species force is an authored polynomial with no
  long-range tail to subtract, so the two force terms add inside the interaction radius by design
  (`specs/long-range-coupling/spec.md`, "Softening bounds the mesh at the cell scale").
- No resize of the chemistry grid. That grid's dimensions stay compile-time constants derived from
  `FIELD_PATTERN_SHRINK` (`src/field_core.nim:32-45`), and moving them carries landmines this change
  does not touch (`docs/research/long-range-coupling.md:242-247`).
- No kernel family, no per-body or per-particle charge, no links, no real-input transform.
- No second attraction matrix and no per-species long-range constants.

## Decisions

### D1. Particle-mesh via FFT, not a tree

The force is carried by a grid the particles deposit onto, transformed, multiplied by a kernel, and
transformed back. The research ranks the alternatives and this change adopts its verdict
(`docs/research/long-range-coupling.md:82-103`).

- **FMM — rejected.** No implementation in WebGPU, WebGL or WebAssembly was found; every GPU FMM in
  the literature is CUDA. At this scale it also loses on the evidence: the GROMACS CUDA FMM reached
  about a third of the FFT-based PME solver's performance on a dense 50 000-atom system, winning only
  for large, spatially inhomogeneous ones (`docs/research/long-range-coupling.md:46-50`).
- **Pyramid Barnes-Hut — rejected.** It exists in WGSL with a live demo and reuses the atomic scatter
  this repo already performs, which makes it the closest rival. It is rejected for the one property
  this change exists to buy: a per-particle tree walk diverges across a warp and its cost tracks
  clustering, which is exactly the cost the perf record shows climbing
  (`docs/research/long-range-coupling.md:35-38, 88-92`).
- **Mean field per species — rejected.** No spatial structure at all; a coupling that cannot tell
  where the other colony is.

**Proven vs. designed.** That the method is right for this world is an inference from published
measurements on other machines and other codebases, not a measurement here. That the *solve* is
affordable is now measured, on one machine and one browser build, with the deposit and force passes
excluded (D3). Everything else in this document is designed and unexercised until the code exists.

### D2. Its own grid, not the chemistry's

A separate coarse grid, allocated and indexed independently of the Gray-Scott field.

Reusing the chemistry field is rejected on two counts the research states: at 2048 x 1152 it is eight
times the cells this solve needs, and 1152 is not a power of two, so a radix-2 transform cannot run
on it at all (`docs/research/long-range-coupling.md:142-144`, `src/field_core.nim:42-45`). A third
count is structural: the chemistry field is a ping-pong pair of `rgba16float` textures whose parity
the frame depends on (`src/sim_registry.nim:306-320`), and threading a second consumer through that
parity buys nothing.

### D3. Grid size: 512 x 256, chosen by the measurement

512 x 256 over the 3840 x 2160 world, cells of 7.5 x 8.4375 units, as both the allocation ceiling and
the shipped default live size. The alternatives were 256 x 128 (cells 15 x 16.875) and 1024 x 512
(cells 3.75 x 4.22).

**The measurement** (`openspec/changes/fft-mesh-spike/design.md`). One round trip — forward row,
forward column, per-bin multiply, inverse column, inverse row — at 512 x 256 x 12 with the 12 x 12
asymmetric species mix in k-space costs **0.417 to 0.450 ms of GPU time**. The same round trip with a
scalar per-bin multiply instead of the mix costs 0.262 to 0.263 ms, so the asymmetric matrix costs
about 0.19 ms on top of the transform. At 256 x 128 x 12 with a scalar multiply it costs 0.080 ms.

The conditions, which travel with the figure:

- Apple M5 Max, macOS 26.5.2, Chromium 152.0.7977.82 headless on ANGLE/Metal. The perf record's
  3.75 ms of headroom was taken on Chromium 150, so comparing the two **crosses a build boundary**.
- Roughly three of the machine's cores were busy with unrelated work throughout, so **every figure is
  an upper bound**.
- The span is the observed min-max over the last four samples of a 15-second window, never an average,
  matching how `docs/perf-report.md` reports.
- **The figure covers the solve only.** The deposit and the gradient-force passes are excluded and
  remain unmeasured.
- The transform was verified round-trip to f32 tolerance before any timing was taken.

**The decision.** The rule was fixed before the figure arrived, so it could not be reinterpreted
around it: the chain's allotment out of the 3.75 ms settled headroom is 1.0 ms, leaving the rest to
the still-climbing physics trace; at or under that, 512 x 256 ships; between 1.0 and 4.0 ms the
ceiling stays and 256 x 128 ships as the default; above 4.0 ms the method does not ship. The 4.0 ms
threshold was the point at which one step down still fits, because total transform work scales as
`W·H·(log2 W + log2 H)` and 512 x 256 → 256 x 128 divides it by about 4.5, the kernel pass by 4.

At 0.417 to 0.450 ms the first row applies and **512 x 256 ships**, with about 0.55 ms of the
allotment left for the deposit and force passes the figure excludes. That remainder is where this
decision could still fail: both are per-particle passes, so both scale with the particle count in the
way the solve does not. If they overrun it, 256 x 128 is already a selector position and costs a fifth
of the solve.

**1024 x 512 does not ship, for two measured reasons.** It costs 1.18 to 1.25 ms at batch 12, past
the whole allotment on its own. And its 1024-point line needs 16 384 bytes of workgroup storage, which
fit only because this adapter grants a `maxComputeWorkgroupStorageSize` of 32 768 — twice WebGPU's
default guarantee — so a grid that size would run here and fail to compile on a device at the default
limit. Earlier drafts of this document called 1024 unreachable because a 1024-point line needs 512
butterfly threads past the 256-invocation limit; the spike disproves that, by looping each of 256
threads over several butterflies, and the claim is removed rather than left standing.

### D4. The transform: Stockham radix-2, one line per workgroup, species in z

Two shader files and four pipeline keys. `lr-fft-rows.wgsl` transforms every row, `lr-fft-cols.wgsl`
every column; each file carries a forward and an inverse entry point, which is how the twiddle sign
travels without a uniform and without dynamic offsets.

Each workgroup loads one line into workgroup memory as `2N` complex values, runs every stage there
with one barrier per stage — the two halves never alias, so one barrier suffices — and writes the line
out. One dispatch per pass, not one per stage: a 512-point line is 8 192 bytes of workgroup storage,
inside WebGPU's 16 384-byte default guarantee, and a 256-invocation workgroup covers its 256
butterflies one each. The workgroup stays at 256 invocations whatever the line length; a line longer
than 512 loops each thread over several butterflies, which is how the spike reached 1024.

Species batch through the dispatch's z dimension, whose extent is the **live** species count, so a
world running four species pays for four. This is the frame's first three-dimensional dispatch size;
the executor special-cases two dimensions today (`src/webgpu_compute.nim:920-924`) and gains a third
case. **Measured: the batching is nearly free.** The spike's marginal cost per layer beyond the first
implies a fixed cost of 0.016 to 0.023 ms across a sixty-fold span of work — five dispatch launches —
and twelve single-layer round trips at 512 x 256 would cost about 0.47 ms against the batched
0.263 ms (`openspec/changes/fft-mesh-spike/design.md`).

**Measured: a column pass costs about 45% more than a row pass** at every size, on the same butterfly
count, because the row pass reads and writes contiguously while the column pass strides by `W`. A
transpose pass between them is therefore the first optimization to reach for if this cost ever has to
fall, and it is deliberately not in the first cut: it trades two extra full-buffer passes for
contiguous access, and nothing yet says which side wins.

Rejected: a stage-per-dispatch transform reading and writing global memory between stages. It removes
the workgroup-storage limit and therefore the line-length ceiling, at the cost of `log2(N)` dispatches
per pass and a full round trip to global memory per stage — nine round trips over 12.6 MB where the
workgroup version makes one.

Rejected: one pipeline per axis with the twiddle sign riding a `dir` field in the uniform, which is
what the spike ran and which halves the pipeline count. Our frame encodes the whole chain into one
command encoder from a stored description (`src/sim_registry.nim:222`), so a value that must differ
between two dispatches in one submit cannot ride a single per-frame uniform without dynamic offsets
or a second buffer. Two entry points cost a pipeline each and no runtime machinery.

Rejected: a library. No JavaScript FFT runs on the GPU, and the WGSL kernels that exist are a crate's
internals rather than a dependency this build could pin
(`docs/research/long-range-coupling.md:74-79`).

### D5. Species mix in k-space, and the arithmetic is why

The potential for receiving species `r` is

```
  Phi_r(k) = G(k) * sum over s of A[r][s] * rho_s(k)
```

one kernel pass over the bins, reading all `S` source spectra at a bin and writing all `S` receiver
spectra for it. Cost is `bins · S²` complex multiply-adds — 18.9M at 512 x 256 x 12 — with traffic of
`bins · S` complex reads and the same writes, about 25 MB, because a thread that owns one bin holds
the `S` source values in registers while it writes the `S` outputs.

The alternative is real and was weighed: because the inverse transform is linear, one could instead
solve `psi_s = G * rho_s` per source species, and let each particle of species `r` accumulate
`sum over s of A[r][s] * grad psi_s`. It costs the same transforms and the same storage, and it
deletes the `S²` term from the kernel pass. It is **rejected** because it moves that term onto the
particles: `S` gradient samples per particle instead of one, 128 000 x 12 scattered reads against
128 000 x 1, and scattered per-particle reads are the cost this change exists to stop growing. Mixing
in k-space keeps the `S²` on the grid, where it is flat.

At a species count far above 12 the `S²` term would dominate the transforms (`S²` against `S·log N`
crosses near `S = 17`). `MAX_SPECIES` is 12 (`src/memory_layout.nim:38`), so it does not.

### D6. The kernel is Yukawa, softened, with k = 0 zeroed and the normalization folded in

One expression, evaluated per bin in the kernel pass:

```
  G(k) = exp(-|k|² sigma² / 2) / (|k|² + 1/lambda²) / (W·H)     for k != 0
  G(0) = 0
```

- `lambda` is the reach, in world units, straight from the slider. Small confines the force; large
  approaches the unscreened 2D limit. One control, continuously, with no kernel selector — the k-space
  multiply makes the kernel a formula rather than a pass, which is what keeps a second kernel a
  follow-up rather than an architecture.
- `sigma` is the softening width, a Nim constant recorded in cells and set at 1.5 cells. It suppresses
  the grid's own scale and the aliasing the charge assignment introduces. It does **not** silence the
  mesh inside the neighbour sweep's radius: sigma is under two cells, about 11 units, while the sweep
  reaches 10 to 150 (`src/config_ranges.nim:33-34`). The research's phrase "keeps the mesh from
  competing with the neighbour sweep inside the species force's radius" overstates what a cell-scale
  softening does, and the spec states the narrower claim instead. The overlap inside the sweep's
  radius is a decided property of the instrument, not a gap left open (settled decision 4).
- `G(0) = 0` at every reach. In the unscreened limit it is forced — the kernel has no finite value
  there — and at a finite reach it is the choice that keeps the force answering density contrast
  rather than absolute density, so adding particles uniformly moves nothing.
- The inverse transform's `1/(W·H)` normalization is folded into `G` rather than given a pass or a
  final scaling loop. One multiply already happening, at no cost.

### D7. Wavenumbers come from the world, not from the bin index

For bin `(m, n)` with `m` folded into `[-W/2, W/2)` and `n` into `[-H/2, H/2)`:

```
  k = 2*pi * (m / worldWidth, n / worldHeight)
```

This is a landmine, not a detail. A power-of-two grid over a 16:9 world cannot have square cells —
square would be 512 x 288, and 288 is not a power of two — so the cells are anisotropic by 12.5%.
Indexing the kernel by bin number instead of physical wavenumber would stretch the force along one
axis by exactly that ratio, with no other symptom and nothing to catch it. The oracle test
"The Potential Is Isotropic In World Units" exists for this line.

### D8. Charge assignment: cloud-in-cell, unit charge, its own fixed-point scale

Each particle deposits unit charge into the four cells surrounding its position, bilinearly weighted,
wrapped on the torus, as four `atomicAdd`s into `array<atomic<i32>>` indexed by
`species * liveGridArea + cellIndex`.

- **CIC over nearest-cell**, because the force is a gradient of this field and nearest-cell assignment
  puts a step at every cell boundary. In an instrument that reads as particles falling into lanes
  spaced at the cell size. Four atomics per particle against one, 512 000 per frame at the ceiling, is
  not a cost worth trading the artifact for.
- **Unit charge, and the strength does not multiply here.** The strength multiplies in the force pass
  alone (D9). That is what makes the accumulator's overflow bound a function of `MAX_PARTICLES` only,
  and therefore statically assertable, rather than a function of a slider's ceiling.
- **Its own fixed-point scale**, not the velocity deltas' 65 536, which would saturate at 32 768
  particles in one cell — under the 128 000 the slider offers, and an `i32` past its maximum wraps
  negative, which the kernel would read as a hole where the densest clump is. The scale is a power of
  two satisfying `MAX_PARTICLES * scale < 2^31` with headroom, static-asserted beside the constant.
  A scale of 1024 leaves the accumulator holding 2.1M particle-equivalents per cell and resolves one
  thousandth of a particle, far finer than a density field needs.
- **Species-signed secretion is not read here.** `field-deposit.wgsl` scales by the depositing
  species' chemistry secretion; this pass does not, because the species relationship lives in the
  attraction matrix the kernel pass applies, and applying a sign twice would mean two controls for one
  relationship.

### D9. The strength multiplies in the force pass, and the chain skips as one

`acts(couplings.longRange)` guards all five passes. No pass outside the chain reads the density, either
spectrum, or the potential, so the chain's only output is the velocity delta the force pass writes,
and the strength multiplies that output entirely. This extends the one-world rule from a pass to a
chain, which the `gpu-frame-registry` delta states as a requirement rather than leaving as a reading.

The force pass mirrors `field-force.wgsl`: original index space, sample, scale, two `atomicAdd`s into
`velocityDeltaFixed`. Never a store — the frame has already cleared the buffer and three other passes
write it. The strength arrives with the substep's frame folded in, the way `fieldForceScale` does
(`web/shaders/src/field-force.wgsl:17-21`), so nothing in the shader carries `dt`.

The gradient is a central difference of the bilinearly interpolated potential, one cell apart: four
bilinear samples, sixteen loads per particle. Rejected: taking the gradient in k-space by multiplying
the spectrum by `i·k` and inverse-transforming two components. It is exact and smooth and costs half
the loads per particle, and it is rejected for costing twice the inverse transforms and a second
potential buffer per species — trading flat cost for per-particle cost in the wrong direction.

### D10. Two cadences: the solve on the frame's clock, the force on the substep's

The deposit, transforms and kernel form one node at `fncOncePerFrame`; the force pass is its own node
at `fncEverySubstep`. This is exactly the split the chemistry already makes and for the same reason:
running the solve per substep would multiply its cost by the substep count and make every coupling
that raises that count a second, undeclared control over how hard the long-range force pulls. The
count is `sim_registry.substepPlan`'s, derived per frame from the frame factor, a live body's travel
bound and any coupling's own declared need, so the couplings that would reach the long-range force
this way are not one slider but several (`src/sim_registry.nim:244-245,353-413`).

Substeps read the same potential without writing it, which is sound in the way `fieldForce` reading
the field texture across substeps is sound. The density accumulator therefore clears at
`fncOncePerFrame`, matching the cadence of the pass that writes it.

### D11. The live size is a uniform; the allocation ceiling is a Nim constant

Buffers are allocated once at `LR_GRID_MAX_W x LR_GRID_MAX_H x MAX_SPECIES`. Every shader in the chain
reads `gridW`, `gridH` and `speciesCount` from `LrParams` and bounds itself by them; the species
stride is the **live** grid area, so the used region is compact and the tail of the allocation is
never read. Changing the live size destroys no buffer, creates none, and rebuilds no bind group,
because no resource's size or identity moves. The generation-counter dance
`createFieldResources` performs (`src/webgpu_init.nim:151-158`) has no counterpart here; that landmine
belongs to the chemistry-grid resize and not to this one
(`docs/research/long-range-coupling.md:252-254`).

The live size is a selector over declared sizes rather than a number, so "a power of two, no larger
than the ceiling, with a line that fits the workgroup" is unrepresentable rather than clamped — the
shape `SPH_RADIUS_FRACTION_MAX` uses for the same kind of constraint
(`src/config_ranges.nim:472-478`).

**What the seam moves from compile time to runtime, and what replaces each.**

| Compile-time today | Here | Runtime replacement |
|---|---|---|
| Field dimensions as WGSL consts (`field_grid.wgsl:22-23`) | grid dimensions in a uniform | every pass early-returns on an invocation past the live dims, the way `depositField` returns past `grid.particleCount` (`field-deposit.wgsl:75-77`) |
| Buffer byte length from grid constants (`webgpu_init.nim:197`) | **does not move** — the allocation is the ceiling, still a constant | none needed; `byteLengthFor`'s exhaustive `case` still fails the compile on a missing entry |
| Ping-pong parity asserted from a step count (`field_core`, `sim_registry.nim:306-320`) | **does not move** — the chain's four transform stages are a literal list with an explicit destination each | `tests/test_sim_registry.nim` pins the sequence |
| `dsFieldWorkgroups` raises when resolved through the one-integer path (`webgpu_compute.nim:866-869`) | a third dimensionality joins | the same runtime raise, extended: a size of one dimensionality resolved through another's path raises rather than silently dispatching a wrong shape |
| The grid's dimensions are powers of two by construction | the live size is data | static assertions over the **declared set**: each a power of two, each no larger than the ceiling, the largest line no longer than the compiled workgroup covers |

### D12. Buffers, bindings, pipelines

Four `SimBuffer` values: `sbLrDensity` (`atomic<i32>`), `sbLrSpectrumA` and `sbLrSpectrumB` (pairs of
`f32`), `sbLrPotential` (`f32`). At a 512 x 256 x 12 ceiling: 6.29 + 12.58 + 12.58 + 6.29 MB, about
38 MB.

Two spectra are required, not a convenience, and two are also enough. The kernel pass reads every
source species at a bin to write every receiver at that bin, so its output cannot alias its input; each
transform stage likewise reads one and writes the other. The spike ran exactly this arrangement — an
out-of-place mix ping-ponging A, B, A, B, A, B — and confirms two buffers carry the whole round trip
(`openspec/changes/fft-mesh-spike/design.md`). Aliasing the potential onto the density buffer would
save 6.29 MB out of 38 and was rejected for the reading it costs: one buffer holding two quantities of
two types at two points in the frame.

Seven pipeline keys over five shader files: `lrDeposit`, `lrFftRows`, `lrFftCols`, `lrKernel`,
`lrFftColsInv`, `lrFftRowsInv`, `lrForce`. Two keys share `lr-fft-rows.wgsl` at different entry
points and two share `lr-fft-cols.wgsl`, the arrangement `rdStepToFront`/`rdStepToTrail` already uses
(`src/shader_manifest.nim:89-95`). Every key needs an `EXPECTED_BIND_GROUP_ENTRIES_*` constant, a case
in `getExpectedEntryCount`, and a `validateBindGroupEntryCount` call, because a bind group whose count
disagrees with its shader fails GPU validation at runtime in the browser and nothing earlier catches
it (`docs/one-world.md:242-249`). Every shader needs a `StaticFiles` entry in `src/main.nim` and a
binding-manifest entry in `src/wgsl_lint.nim`.

Frame order, inserted into the sequence `buildFrame` already composes:

```
  clear sbVelocityDelta, ... , sbLrDensity (once per frame)
  Grid Build -> copy offsets -> Physics (binScatter, forces, forcesSph?)
  Long Range Solve   [once per frame]  lrDeposit, lrFftRows, lrFftCols,
                                       lrKernel, lrFftColsInv, lrFftRowsInv
  Field (RD)         [once per frame]
  Field Force        [per substep]
  Long Range Force   [per substep]     lrForce
  Integrate
```

The solve sits after Physics and before the field because it reads particle positions and nothing
else; its placement relative to the field passes is free, and it goes first so the two once-per-frame
nodes are adjacent. The force pass goes with the other delta contributors, before `integrate`.

### D13. Controls, panel, help

A `long-range` descriptor group led by the strength, the ordering `fluidStrength` establishes
(`src/ui/api/param_descriptor.nim:550-564`): the strength says how much of the coupling acts, the two
below say what kind of reach it has. `longRangeStrength`, `longRangeReach`, `longRangeGrid`. The panel
needs a `groupIds("long-range")` loop in `web-ui/src/components/Panel.tsx` or the sliders never reach
the screen and `tests/test_panel_reachability.nim` goes red. Help lands as
`docs/help/35-long-range.md` with `group: long-range`, sitting between the fluid and the chemistry, and
the four coverage relations in `tests/test_help_content.nim` require it to name all three ids.

### D14. The oracle and what the tests actually hold

`src/long_range_core.nim`, pure, compiled on both backends, holding the kernel expression, the
wavenumber mapping, the CIC weights, the fixed-point scale and its bound, and a small
direct-transform reference. It mirrors the WGSL the way `field_core` mirrors `rd-step.wgsl`, and the
mirror is held by review like every other — unenforced, and named as such in `docs/enforcement.md`'s
oracle table when this lands (`docs/enforcement.md:58-77`).

The suites the specs cite, and what each would catch:

| Suite | Catches |
|---|---|
| Reach Sets The Decay Length | a kernel wired to the wrong power of `lambda`, or a reach that does not monotonically lengthen the force |
| A Uniform World Pushes Nothing | a missing `G(0) = 0` |
| Momentum Is Conserved Only Under A Symmetric Matrix | a later "fix" that symmetrizes the matrix in k-space |
| The Solve Is Linear In The Source Densities | a kernel applied per species before mixing rather than after, or a matrix row read as a column |
| The Potential Is Isotropic In World Units | wavenumbers taken from bin indices (D7) |
| Softening Attenuates The Cell Scale | a softening width read in world units where cells were meant, or dropped |
| The Full Particle Budget Encodes Without Saturating | the velocity scale reused for the density |
| A round trip of the reference transform against a direct DFT | every sign, stride and twiddle error in the transform itself |

What no test holds, and what would close each: that the WGSL carries the same expressions as the
oracle (a placeholder-substituted constant, or a test deriving the pairing from module headers); that
the cost is flat across a settling run (a perf capture of the long-range slot at 30 s and 150 s at
128 000 particles); that the result shows no grid-aligned artifact (agent-checkable, procedure in the
spec).

## Risks / Trade-offs

- **The deposit and force passes are unmeasured**, and they carry the part of the chain that scales
  with the particle count. The spike's 0.417 to 0.450 ms covers the solve alone, leaving about 0.55 ms
  of the allotment for them. → The first in-app capture reads the long-range profiler slot at 128 000
  particles; 256 x 128 is already a selector position at a fifth of the solve's cost if they overrun.
- **The measurement crosses a browser build boundary** — Chromium 152 for the spike against
  Chromium 150 for the perf record — and was taken with three cores busy. → Every figure is an upper
  bound, which is the safe direction, and the in-app capture closes the boundary by measuring both in
  one build.
- **A clustered world is a sharp-featured source, exactly where a spectral solve is least accurate**
  (`docs/research/long-range-coupling.md:100-103`). → Accepted. The inaccuracy lives at scales the
  neighbour sweep already resolves, and this is an instrument rather than a simulation of anything.
- **The long-range term does not conserve momentum**, so a world can acquire a net drift. → Stated
  rather than mitigated, and pinned by a test asserting both halves. A drift the user dislikes is a
  reason to symmetrize a matrix row, which is a control they already have.
- **Two forces overlap inside the interaction radius.** → By design (D6). If it reads badly in the
  app, the softening width is the one number to move, and the question of what it should track is
  open below.
- **Bind-group entry counts and binding manifests are two-sided and unenforced across the pair**
  (`docs/enforcement.md:96`). Seven new pipelines is seven new chances to get this wrong, and the
  symptom is a browser-side validation failure with nothing earlier catching it. → No new mechanism;
  the existing `validateBindGroupEntryCount` call per pipeline, and the app launched once before the
  change is called done.
- **38 MB of GPU buffers allocated whether or not the coupling acts.** → Accepted, and the reason is
  the seam: allocating at the ceiling is what makes a resize free. Allocating on first use would make
  a slider leaving zero an asynchronous operation, the same trade `allShaderSpecs` already settles
  (`src/shader_manifest.nim:100-107`).
- **The species-batched dispatch's z extent is the live species count**, so changing the species count
  changes dispatch shape without rebuilding the frame description. → The description stays symbolic;
  this is the executor resolving a size, like `dsParticleWorkgroups`. A scenario in the
  `gpu-frame-registry` delta pins it.

## Settled decisions

Each of these was open while the design was written. Each is now decided, with the alternative it was
chosen over recorded beside it.

**Decided by the user.**

1. **The long-range strength's range is `0.0 .. 1.0`, default `0.0`.** The ceiling is a working bound,
   not a measured one, and is marked as such beside the constant with the conditions its calibration
   must record — the strength at which a settled population visibly gathers toward the world's densest
   region within a few seconds, and the strength at which the long-range term overwhelms the species
   force at the interaction radius. `CROWDING_STRENGTH_MAX` (`src/config_ranges.nim:46-54`) is the
   worked example of that marking. Chosen over holding the range until the calibration runs, which
   would block the coupling on a measurement that needs the coupling to exist.
2. **Reach is `60 .. 4000` world units on a logarithmic slider, default `600`.** The floor sits above a
   few cells and below the sweep's maximum reach of 150; the ceiling sits above the world's width of
   3840, so the unscreened limit is a reachable slider position rather than an asymptote. Chosen over a
   floor at 150, which would have made the coupling long-range-only by construction at the cost of the
   short end of the control's travel.
3. **The grid size is a visible selector in the `long-range` group.** It is the coupling's cost knob
   and the only present consumer of the live-size seam. Chosen over a Nim constant fixed at the
   ceiling with the uniform still carrying it, which would leave the seam open with no consumer and
   sit against article 6.
4. **The softening width stays at 1.5 cells.** The long-range force therefore acts inside the
   neighbour sweep's radius and adds to the species force there, which is by design and is what the
   spec claims — no force structure below a cell, and nothing wider. Chosen over tracking the
   interaction radius, which would make the mesh a genuinely long-range-only term at the cost of a
   softening that moves when an unrelated slider moves.

**Decided by the coordinator.**

5. **The chain's share of the settled headroom is 1.0 ms**, on the reasoning that the physics trace
   was still climbing when the perf window closed and the rest is its margin. Revisited when the spike
   lands, and not before. Chosen over a looser 1.5 to 2.0 ms, which would read that margin as already
   generous.
6. **One profiler slot on the solve node**, mirroring a new `passLongRange` in `gpu_profiler.nim`; the
   force node carries `PROFILER_SLOT_NONE`, as Field Force does. Two passes sharing a slot report a
   meaningless duration, and the solve is the figure anyone will want. Chosen over two slots, which
   costs a second query pair to separate a cost nobody has asked to see apart.
7. **The oracle lives in its own module, `src/long_range_core.nim`.** Chosen over extending
   `field_core`, which already owns the chemistry's scale decisions and shares only a grid shape with
   this one.

The one thing still outstanding is the spike's figure, which D3 holds.
