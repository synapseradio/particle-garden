# Long-range coupling: which fast method fits this world, and what else the hope reaches

Gathered 2026-09-12 while exploring long-range particle coupling. It answers three questions: has
the fast multipole method (FMM) or a relative been run on GPUs and in browser GPU compute; which
method fits a 2D toroidal WGSL world of up to 128 000 particles; and how three further hopes (a
grid that resizes, cheap coupling between arbitrary particles, and generative structures with
proximity and enclosure) land on the same architecture.

## Executive summary

- No FMM implementation in WebGPU, WebGL or WebAssembly was found. Every GPU FMM in the literature
  is native CUDA or a CUDA-backed framework. FMM is set aside for a separate project.
- Barnes-Hut in WebGPU exists several times over. One tutorial builds the quadtree as a pyramid of
  grids filled by atomic scatter, the same primitive `field-deposit.wgsl` already uses.
- At this world's scale the FFT-based particle-mesh method wins on the evidence: FFT is the method
  of choice for smooth sources at uniform resolution, a production GPU FMM reaches only a third of
  the FFT solver's speed on a dense 50 000 atom system, and the FFT's cost does not rise as the
  world clusters, which is the one cost the perf record shows climbing.
- The repo already runs a particle-mesh loop for chemistry: deposit, solve, gradient force. The
  long-range coupling is that loop with a Poisson or screened-Poisson solve in the middle.
- The three further hopes all read as sources feeding fields and readers sampling them. Generative
  structures land as parametric bodies with an analytic signed distance and a strength envelope.

## The world the method has to fit

| Fact | Value | Where |
|---|---|---|
| Particle ceiling | 128 000 | `src/memory_layout.nim` |
| Species ceiling | 12 | `src/memory_layout.nim` |
| World | 3840 x 2160, toroidal | `src/config.nim` |
| Species force reach | 10 to 150 units | `src/config_ranges.nim` |
| Chemistry grid | 2048 x 1152, compile-time | `src/field_core.nim` |
| Settled headroom at 128k | about 3.75 ms of a 16.7 ms frame | `docs/perf-report.md` |

Nothing reaches past 150 units today, which is 4% of the world's width. The physics pass at 128k
particles measures about 1 ms after 30 seconds and 6.5 to 7.9 ms after 150 seconds, still rising,
because the neighbour sweep's cost tracks clustering (`docs/perf-report.md`, "Settling"). Any
long-range pass whose cost also tracks clustering spends the headroom exactly when it is scarcest.

## Literature

### FMM on GPUs, and the absence of a browser one

Gumerov and Duraiswami pioneered GPU FMM in 2008 with speedups of 30 to 70 over a single CPU core,
as cited in Kohnke et al. [1]; the 2008 paper itself was not fetched, so that figure stands one
citation removed. Goude and Engblom published a 2D adaptive FMM entirely on CUDA, the closest match
to this world's dimensionality [2]. The GROMACS CUDA FMM is the sharpest datum on whether FMM pays
at this scale: on a dense system of about 50 000 atoms it reached about a third of the performance
of the FFT-based PME solver, and outperformed PME only for large, spatially inhomogeneous systems
[3]. Gholami, Malhotra, Sundar and Biros compared FFT, FMM and multigrid Poisson solvers and found
FFT the method of choice for smooth sources at uniform resolution, with FMM and multigrid winning
only for sources with sharp localized features [4]. Yokota and Barba measured the crossover where
fast methods beat direct summation on a GPU at about 2 x 10^4 particles for a treecode and 4 x 10^4
for FMM, an order of magnitude above the CPU crossovers, and found no clear treecode-versus-FMM
crossover on the GPU in their range [5].

Searches for FMM in WebGPU, WebGL, GLSL and WebAssembly returned nothing on topic. The gap is
consistent with the GraphPU authors' account of a WebGPU Barnes-Hut, a simpler cousin: about a
thousand lines of compute shader, made hard by tree construction without recursion [6].

### Barnes-Hut in WebGPU

Three independent WebGPU Barnes-Hut implementations were found. A tutorial with a live demo builds
the quadtree as a pyramid of grids: particles atomically scatter mass into a fine grid, log2
reduction passes build coarser levels, and each body walks the implicit tree with the usual opening
criterion. The page claims twenty thousand bodies at about a hundred frames per second and three
hundred thousand in its final demo; that is the page's own statement, not an independent
measurement [7]. GraphWaGu is a peer-reviewed WebGPU compute-shader Barnes-Hut for 2D graph layout
with public source [8]. GraphPU is a blog-documented 3D one [6]. A counterexample, GraphGPU, keeps
Barnes-Hut on the CPU and runs brute force on its GPU path [9].

### FFT in WGSL and GLSL

The wgsl-fft crate embeds Stockham radix-4 and radix-2 WGSL kernels run through wgpu; its browser
reach is inferred from wgpu's backend list, not demonstrated [10]. A GLSL compute-shader 2D FFT
exists [11]. Tessendorf ocean demos run a 512 x 512 inverse FFT every frame in WebGPU compute at
interactive rates [12]. No JavaScript FFT library runs on the GPU; WebFFT's members are JavaScript
and WebAssembly [13]. For this codebase the FFT is therefore a bounded piece of WGSL to write or
lift, not a dependency.

## The method ladder

Each rung is the one above it with the hierarchy collapsed.

```
  rung  method                  proven where              for this world
  ----  ----------------------  ------------------------  --------------------------------------
   3    FMM                     CUDA only, never browser  slower than FFT at this scale [3][4],
                                                          most code, no WGSL precedent
   2    pyramid Barnes-Hut      WGSL, live demo, 2D [7]   reuses atomic scatter; per-particle
                                                          tree walk diverges; cost tracks
                                                          clustering
   1    particle-mesh via FFT   WebGPU ocean demos [12];  reuses deposit and gradient passes;
                                WGSL kernels exist [10]   cost flat under clustering; exact on
                                                          the torus; the kernel is a free choice
   0    mean field per species  trivial                   no spatial structure
```

Rung 1 is the choice. The toroidal world is the periodic boundary condition an FFT solve wants,
which is the awkward part elsewhere. The Gholami caveat applies: a clustered world is a
sharp-featured source, so the mesh is inaccurate near clumps. That inaccuracy lives inside the
neighbour sweep's range, which already resolves the near field, so the split is the standard
particle-particle particle-mesh one: pairs inside 150 units, mesh beyond.

## The repo already runs a particle-mesh loop

`src/sim_registry.nim` composes the chemistry as deposit, solve, gradient force:

```
  particles --> field-deposit --> [ Gray-Scott, the field clock's steps ] --> field-force --> particles
               (Gaussian splat,       (the solve)                             (gradient sample,
                per-species sign)                                              per-species sign)
```

Deposit is charge assignment. Gradient sampling is force interpolation. The per-species secretion
and tropism tables in `field-deposit.wgsl` and `field-force.wgsl` are already the per-species charge
and response a multi-species long-range force needs. The long-range coupling is the same loop with
a spectral solve in the middle, coupling-owned and skipped at exactly zero:

```
  clear lrDensity[species]
  lrDeposit      particles -> lrDensity[species]     (atomic splat, like field-deposit)
  lrFftRows      lrDensity -> spectrum                (all species in one dispatch)
  lrFftCols
  lrKernel       spectrum -> potential spectrum per receiving species
  lrIfftCols
  lrIfftRows     -> potential[receiving species]
  lrForce        particle reads grad potential[its species]  (atomicAdd, like field-force)
```

The asymmetric attraction matrix is handled in k-space by linearity: the potential for receiving
species r is the kernel times the sum over source species s of a[r][s] times the density of s. No
shared potential exists under an asymmetric matrix, so Newton's third law does not hold for the
long-range term, which the mesh tolerates and a true FMM would not.

The kernel is a multiplication in k-space, so it is free to choose. A Yukawa kernel,
1 / (k^2 + 1/lambda^2), makes lambda a reach control: small lambda is local, large lambda is 2D
gravity, and every value between is a continuous reach. Softening at the cell scale removes force
structure below a cell; it does not keep the mesh out of the neighbour sweep's range, since a cell
is about 7.5 units and the sweep reaches 10 to 150, so inside that radius the two terms overlap.
Whether the softening width tracks the cell or the interaction radius is a design choice, recorded
in the `long-range-mesh` change. The k = 0 mode is zeroed for the Poisson limit, which is the
usual uniform-background convention on a periodic domain.

A separate coarse grid, 512 x 256 over the 3840 x 2160 world, gives cells of 7.5 x 8.4 units,
anisotropic but fine for a spectral solve. Reusing the chemistry grid would cost eight times the
work and is not a power of two.

## How the three further hopes land

### A grid that resizes

A Stockham transform runs at any power of two below its allocation, so the mesh resizes by
allocating for the largest size and passing the live size as a uniform. The same seam serves the
chemistry field. `createFieldResources` in `src/webgpu_init.nim` is already idempotent, destroys
prior textures and bumps a generation counter so bind groups rebuild; the missing half is the shader
side, where `field_grid.wgsl` holds the field dimensions as compile-time constants.

### Cheap coupling between arbitrary particles

Two features hide under "arbitrary", and one pass should not carry the other.

- Everyone feels everyone, aggregated: the mesh. After the solve any particle reads the whole
  world's influence in one fetch at any distance.
- Chosen pairs at any distance: a link buffer. Each link is two indices, a rest length and a
  stiffness; one thread per link; both ends receive an atomicAdd into the velocity delta. Cost is
  the link count, independent of distance.

Links are deferred from the first cut. Their isolation is structural: a links pass is one buffer,
one shader and one more accumulating contributor under the delta-buffer rule in `docs/one-world.md`,
so deferring them changes nothing elsewhere. The one thing a first cut should not do is design
parametric bodies in a way that assumes links can never exist, because condensation (below) needs
them.

### Generative, ephemeral structures with proximity and enclosure

A signed distance field gives each particle, in one evaluation, its distance to a surface, the
direction to it, and which side it is on. Enclosure is the sign. Two representations compose:

```
  A. parametric bodies             B. structures made of particles
  ---------------------------      ---------------------------------
  state: a few numbers each        state: particles plus links
         (center, radius, angle,
          deformation, strength)
  surface: analytic SDF            surface: the linked particles
  moving: animate the numbers      moving: free, they are particles
  pushed back: touching            pushed back: free
     particles atomicAdd force
     and torque into a small
     per-body accumulator,
     integrated like a rigid body
  enclosure: the SDF sign          enclosure: needs an inside test
                                     against a closed ring
  ephemeral: strength envelope     ephemeral: links dissolve
  cost: K evaluations/particle     cost: link count
```

A is the first cut. It gives enclosure for free, needs no texture, and has no resolution. Baking a
body set into a distance texture is an optimization for a body count too large to evaluate per
particle, and it needs no image input: a compute pass evaluates the same procedural shapes cell by
cell. B is the emergent version. The composition worth keeping reachable: a body condenses particles
onto its surface as links, lets its own strength fall to zero, and leaves a living membrane the
world now owns.

A body's presence is a strength, zero is an ordinary value, and a life is an envelope over it:

```
  strength
    |        ____________
    |       /            \
    |      /              \___
    |     /                   \____
    |____/                         \______
    +-----------------------------------------> time
      attack   hold     decay   release
```

Bodies ignite from either source: a player's input where one is present, or the world's own
generator on its own cadence when the feature is active and no input overrules it, the way the
climate tours the named regimes. A body can also rasterize into the long-range density as a charge,
so one object acts at two ranges: it pulls from across the world through the potential and shapes
motion up close through the distance.

## One picture

```
  SOURCES                    FIELDS                          READERS
  particles  --deposit-->    chemistry (exists)   --grad-->  particles (exists)
  particles  --deposit-->    density per species
                                 |  FFT solve
                                 v
                             potential per species --grad--> particles   (long range)
  bodies     --rasterize-->  density                             ^
                             (a body can be a charge) -----------+
  bodies     --evaluate-->   signed distance      --dist, side--> particles (proximity, enclosure)
  links      -------------------------------------  pairs  -----> particles (deferred)
```

Every reader pass has the shape of `field-force.wgsl`: one thread per particle, sample, accumulate a
velocity delta atomically. Every new pass is coupling-owned and skippable at exactly zero.

## Landmines

- **Resizing the chemistry grid rescales the pattern.** Gray-Scott's wavelength is set in cells, so
  a resize moves the pattern's world-unit size (a pattern-scale control) and changes deposit per
  cell. The chemotactic collapse bounds in `tests/test_field_core.nim` were measured at one cell
  size, so a resize moves the measured bound and the suite must re-run.
- **Compile-time assertions move to runtime only where allocation moves.** A mesh that allocates
  at a Nim ceiling and carries the live size in a uniform keeps buffer sizing and parity static.
  The chemistry-grid resize is the change that recreates textures, and it is the one that moves
  assertions to runtime and must record the tier change in `docs/enforcement.md`.
- **1024 x 512 runs but does not fit.** The spike ran it by looping 256 threads over several
  butterflies, measuring 1.18 to 1.25 ms at batch 12 (`openspec/changes/fft-mesh-spike/design.md`),
  and its 16 384-byte line fits only because this adapter grants twice WebGPU's default workgroup
  storage. It is out on cost and portability, not on a shader limit.
- **The mesh cost is unmeasured.** No figure for a batched 512 x 256 x 12 transform on the perf
  record's machine exists. A spike that runs one in the frame and reads the profiler gates every
  budget claim.
- **The generation counter is the resize seam, and bind-group entry counts are validated at
  creation.** A resize that recreates textures must rebuild every bind group that names them, or
  the browser rejects the frame at runtime, which nothing earlier catches.

## Open questions

- Whether bodies can be pushed by particles in the first cut, or only move by their own animation,
  with feedback a later stage.
- Whether the mesh and the resize seam ship together, since the FFT needs a runtime size anyway, or
  the resize seam ships first on the chemistry field alone.
- What the body generator draws from when no input overrules it: noise, the audio features, the
  weather's cadence, or a seeded sequence.

## Sources

1. Kohnke, Kutzner, Beckmann, Lube, Kabadshow, Dachsel, Grubmüller (2021), *A CUDA fast multipole
   method with highly efficient M2L far field evaluation*, IJHPCA.
   https://www.mpinat.mpg.de/634623/Kohnke_2021_IJHPCA.pdf
   Cites Gumerov and Duraiswami (2008), *Fast multipole methods on graphics processors*, J. Comput.
   Phys. 227(18).
2. Goude and Engblom (2012), *Adaptive fast multipole methods on the GPU*, J. Supercomputing.
   https://uu.diva-portal.org/smash/get/diva2:528056/FULLTEXT01.pdf
3. Kohnke, Kutzner, Grubmüller (2020), *A GPU-Accelerated Fast Multipole Method for GROMACS:
   Performance and Accuracy*, J. Chem. Theory Comput.
   https://www.mpinat.mpg.de/634305/Kohnke_2020_JCTC.pdf
4. Gholami, Malhotra, Sundar, Biros (2016), *FFT, FMM, or Multigrid? A comparative Study of
   State-Of-the-Art Poisson Solvers for Uniform and Nonuniform Grids in the Unit Cube*, SIAM J. Sci.
   Comput. 38(3). https://arxiv.org/abs/1408.6497
5. Yokota and Barba (2010), *Treecode and fast multipole method for N-body simulation with CUDA*.
   https://arxiv.org/abs/1010.1482
6. Latent Cat, *Building GraphPU: A Large-scale 3D GPU Graph Visualization Tool*.
   https://latentcat.com/en/blog/building-graphpu
7. Algorythmic Explorations, *Two Falling Dots*, Barnes-Hut in WebGPU as a pyramid of grids.
   https://algorythmic-explorations.vercel.app/pages/particle-worlds/part1.html
8. Dyken et al. (2022), *GraphWaGu: GPU Powered Large Scale Graph Layout Computation and Rendering
   for the Web*, EGPGV. https://stevepetruzza.io/pubs/graphwagu-2022.pdf and
   https://github.com/harp-lab/GraphWaGu
9. GraphGPU. https://github.com/drkameleon/GraphGPU
10. wgsl-fft. https://github.com/larsjoost/wgsl-fft
11. OpenGLFFT, 2D FFT in GLSL compute shaders. https://github.com/bane9/OpenGLFFT
12. Paleologue, *Ocean Simulation with FFT and WebGPU*.
    https://barthpaleologue.github.io/Blog/posts/ocean-simulation-webgpu
13. WebFFT. https://github.com/IQEngine/WebFFT
