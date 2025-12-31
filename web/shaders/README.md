# WebGPU Compute Shaders for Particle Life Simulation

This guide is for developers modifying GPU physics. For running the app, see the [main README](../../README.md). For building from source, see the [Developer Guide](../../src/README.md).

---

This directory contains the GPU code that makes particles move.

## Before You Start

If you've never worked with GPU programming, work through [Your First WebGPU App](https://codelabs.developers.google.com/your-first-webgpu-app) (Google Codelabs). It covers GPU vs CPU fundamentals, parallel processing, shaders, and buffers — all using JavaScript with no prior graphics experience required.

For reference material: [WebGPU Fundamentals](https://webgpufundamentals.org) and [MDN WebGPU API](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API).

## Overview

**What this does:** Every frame, the GPU calculates forces between thousands of particles in parallel. Doing this efficiently requires organizing particles by location so each one only checks nearby neighbors instead of all 16,000+ others.

**GPU Terms for JS Developers:**
| Term | Meaning |
|------|---------|
| **Pass** | Sequential step (like `Promise.then()` — each must complete before the next starts) |
| **Buffer** | GPU memory array (like typed array, but lives on GPU — can't console.log it) |
| **Atomic** | Thread-safe operation (like mutex for `++` — prevents race conditions) |
| **Workgroup** | Batch of 64 threads processed together |

The simulation uses a **five-pass GPU compute pipeline**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          GPU COMPUTE PIPELINE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐                                                        │
│  │  particlesA[]   │ ← 32-byte Particle structs (Array-of-Structs layout)    │
│  └────────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────┐                    │
│  │ PASS 1: bin-count.wgsl                              │                    │
│  │ Count particles per grid cell (thread-safe counting)│                    │
│  └────────┬────────────────────────────────────────────┘                    │
│           │ cellCounts[] (scratch)                                              │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────┐                    │
│  │ PASS 2: prefix-sum (3 shaders)                      │                    │
│  │ Running total: [3,5,2] → [0,3,8]                    │                    │
│  │ (where each cell starts in the sorted array)        │                    │
│  └────────┬────────────────────────────────────────────┘                    │
│           │ cellOffsets[] (scratch)                                             │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────┐                    │
│  │ PASS 3: bin-scatter.wgsl                            │                    │
│  │ Scatter particles into sorted order by grid cell    │                    │
│  └────────┬────────────────────────────────────────────┘                    │
│           │ particlesSorted[] (scratch, sorted by grid cell for GPU cache)      │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────┐                    │
│  │ PASS 4: forces.wgsl                                 │                    │
│  │ Calculate attraction/repulsion between particles    │                    │
│  │   • Checks only half the neighbor pairs (A→B also   │                    │
│  │     applies B→A via Newton's 3rd law)               │                    │
│  │   • Species-based attraction matrix lookup          │                    │
│  └────────┬────────────────────────────────────────────┘                    │
│           │ velocityDeltaFixed[] (scratch, integers → floats in pass 5)       │
│           ▼                                                                 │
│  ┌─────────────────────────────────────────────────────┐                    │
│  │ PASS 5: integrate.wgsl                              │                    │
│  │ Apply velocity deltas, friction, toroidal wrap      │                    │
│  └────────┬────────────────────────────────────────────┘                    │
│           │                                                                 │
│           ▼                                                                 │
│  ┌─────────────────┐                                                        │
│  │  particlesA[]   │ ← Updated in-place (no buffer swap)                    │
│  └─────────────────┘                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow Summary

| Pass | Reads | Writes | Role |
|------|-------|--------|------|
| 1: bin-count | particlesA | cellCounts | Count particles per grid cell |
| 2: prefix-sum | cellCounts | cellOffsets | Compute where each cell starts |
| 3: bin-scatter | particlesA, cellOffsets | particlesSorted | Reorder by grid cell |
| 4: forces | particlesSorted, cellOffsets | velocityDeltaFixed | Calculate forces |
| 5: integrate | velocityDeltaFixed, particlesA | particlesA | Apply forces, update positions |

**particlesA** is both input and output — it persists between frames.
**All other buffers** are scratch space, overwritten every frame.

## Files

### Shaders
- **`bin-count.wgsl`** - Pass 1: Count particles per grid cell using atomics
- **`forces.wgsl`** - Pass 4: Compute inter-particle forces (COMPLETE)

### Documentation
- **`README.md`** - This file

## forces.wgsl - Force Computation Shader

### What It Does

Computes inter-particle forces using spatial grid acceleration. For each particle:

1. **Find grid cell** - Determine which cell the particle occupies
2. **Iterate 5 half-neighbor cells** - Same cell + 4 neighbors below/right (avoids double-counting pairs)
3. **Compute forces** - For each nearby particle:
   - Calculate toroidal distance
   - Apply species-based attraction/repulsion
   - Accumulate force into velocity delta
4. **Mouse attraction** - Add force toward mouse cursor (if mouse is down)
5. **Write output** - Store velocity deltas and density

### Algorithm Parity

This shader implements particle life force computation in WGSL. Every force calculation, distance clamp, and toroidal wrap follows the standard particle life algorithm.

### Buffer Layout

Each particle is stored as a single 32-byte block containing all its data. This "Array-of-Structs" layout keeps each particle's position, velocity, and species together in memory, which is faster than scattering the data across separate arrays:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Particle Struct (32 bytes)                          │
├──────────┬──────────┬───────┬───────────────────────────────────────────────┤
│  Offset  │  Field   │ Size  │ Description                                   │
├──────────┼──────────┼───────┼───────────────────────────────────────────────┤
│    0     │  pos.x   │  4    │ X position (f32)                              │
│    4     │  pos.y   │  4    │ Y position (f32)                              │
│    8     │  vel.x   │  4    │ X velocity (f32)                              │
│   12     │  vel.y   │  4    │ Y velocity (f32)                              │
│   16     │  species │  4    │ Species ID (u32, 0-5)                         │
│   20     │  density │  4    │ Local density (f32)                           │
│   24     │  _pad0   │  4    │ Padding for 32-byte alignment                 │
│   28     │  _pad1   │  4    │ Padding for 32-byte alignment                 │
└──────────┴──────────┴───────┴───────────────────────────────────────────────┘

Why 32 bytes:
  • Two particles fit in one 64-byte CPU cache line
  • Four particles fit in one 128-byte GPU cache line
  • All fields naturally aligned (f32/u32 at 4-byte boundaries)
  • Reading one particle brings all its data into cache at once

Buffer Bindings (forces.wgsl):
┌───────┬──────────────────────────┬──────────────────────────────────────────┐
│ Bind  │ Type                     │ Purpose                                  │
├───────┼──────────────────────────┼──────────────────────────────────────────┤
│   0   │ uniform SimParams        │ dt, world size, mouse, attraction matrix │
│   1   │ storage Particle[]       │ particlesSorted (read)                   │
│   2   │ storage u32[]            │ sortedToOriginal (read)                  │
│   3   │ storage u32[]            │ cellStartOffsets (read)                  │
│   4   │ storage u32[]            │ cellParticleCounts (read)                │
│   5   │ storage atomic<i32>[]    │ velocityDeltaFixed (read/write)          │
│   6   │ storage atomic<i32>[]    │ densityDeltaFixed (read/write)           │
└───────┴──────────────────────────┴──────────────────────────────────────────┘

Fixed-Point Atomics (why integers instead of floats?):
  When multiple GPU threads update the same particle's velocity simultaneously,
  we need "atomic" operations that don't corrupt data. GPUs only support atomic
  integers, so we store velocities as integers (×65536), then convert back to
  floats in the integrate pass. This is a common GPU programming pattern.
```

### Performance

**Expected:** < 1ms for 64K particles on modern GPU

**Workgroup size:** 64 threads per workgroup (configurable)

**Memory bandwidth:** ~50-200 reads per particle (depends on density)

Profile with:
```javascript
const querySet = device.createQuerySet({
  type: 'timestamp',
  count: 2,
});
```

## Integration

### Prerequisites

Before running force computation:

1. **Pass 1** — `bin-count.wgsl` populates `cellCounts[]`
2. **Pass 2** — `prefix-sum*.wgsl` computes `cellOffsets[]` via parallel scan
3. **Pass 3** — `bin-scatter.wgsl` copies particles into `particlesSorted[]`

### After Force Computation

**Pass 5** — See `integrate.wgsl`

Key operations:
- Convert fixed-point deltas (i32) back to floats (scale factor 65536)
- Apply velocity deltas and friction
- Euler integration for position update
- Toroidal wrap at world boundaries

## Constants

Shader constants for the particle life algorithm:

```wgsl
const MAX_SPECIES: u32 = 6u;         // Maximum species count
const MIN_DIST_SQ: f32 = 4.0;        // Min distance² (prevents division by zero)
const INV_03: f32 = 3.333333333;     // 1.0 / 0.3 (repulsion threshold)
const INV_07: f32 = 1.428571429;     // 1.0 / 0.7 (attraction falloff)
const MD2_LIMIT: f32 = 90000.0;      // Mouse distance² limit
```

## Toroidal Topology

The simulation world wraps around like Pac-Man — particles leaving the right edge reappear on the left:

- Particles near the right edge see neighbors on the left edge
- No boundary artifacts or edge repulsion
- Maintains energy conservation

Implementation:
- Grid cells wrap: if `cellY < 0`, wrap to `cellY + gridH`
- Position offset applied: `wrapY = -H` when wrapping top→bottom
- Distance calculation uses wrapped coordinates

## Debugging

### Common Issues

**1. No forces computed**
- Check `cellCounts[]` is non-zero after Pass 1
- Verify `cellOffsets[]` and `particlesSorted[]` from Pass 2/3
- Ensure all five passes dispatch in sequence each frame

**2. Particles explode**
- Check `dt` is reasonable (0.001 - 0.05)
- Verify `fMul` isn't too large (typically 0.1 - 2.0)
- Ensure `MIN_DIST_SQ` clamps minimum distance

**3. Uniform density / no attraction**
- Check attraction matrix has non-zero values
- Verify species indices are valid (0-5)
- Ensure `rMax` matches expected interaction radius

### Validation

Verify GPU output against expected physics behavior:

```javascript
const tolerance = 1e-4;

for (let i = 0; i < particleCount; i++) {
  const vx = vxDeltaGPU[i];

  if (!Number.isFinite(vx)) {
    console.error(`NaN/Inf at particle ${i}: vx=${vx}`);
  }
}
```

Check for NaN/Inf propagation and energy conservation.

## Future Optimizations

### Shared Memory Caching
Load grid cells into workgroup shared memory to reduce global memory bandwidth:

```wgsl
var<workgroup> sharedParticles: array<vec2<f32>, 256>;
```

**Expected speedup:** 1.5-2× for dense particle distributions

### Adaptive Grid Resolution
Switch to finer grid when particles cluster:

```wgsl
if (density > threshold) {
  gridSize *= 2;
}
```

### Multi-Scale Grid (Quadtree)
Use hierarchical grid for variable-density simulations.

## References

- **Memory Layout:** `src/memory_layout.nim` (single source of truth for buffer offsets)
- **Particle Struct:** `web/shaders/forces.wgsl` lines 54-64
- **WebGPU Spec:** https://www.w3.org/TR/webgpu/
- **WGSL Spec:** https://www.w3.org/TR/WGSL/

## Learn More

### WebGPU Fundamentals

- [GPUComputePassEncoder (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/GPUComputePassEncoder) — Interface for encoding compute pass commands; explains passes as sequential GPU execution steps
- [GPUBuffer (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/GPUBuffer) — GPU memory blocks for storing data; covers mapping, usage flags, and lifecycle
- [dispatchWorkgroups (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/GPUComputePassEncoder/dispatchWorkgroups) — How workgroup counts and sizes determine total thread invocations
- [WebGPU Compute Shader Basics](https://webgpufundamentals.org/webgpu/lessons/webgpu-compute-shaders.html) — Comprehensive tutorial covering workgroups, thread IDs, and parallel execution

### WGSL Reference

- [Atomic Types (Tour of WGSL)](https://google.github.io/tour-of-wgsl/types/atomics/atomic-types/) — Thread-safe integer operations; explains `atomic<i32>` and `atomic<u32>` usage restrictions
- [Atomic Functions (WebGPU.rocks)](https://webgpu.rocks/wgsl/functions/synchronization-atomic/) — Quick reference for `atomicAdd`, `atomicLoad`, barriers, and other synchronization primitives

### GPU Programming Concepts

- [Parallel Prefix Sum (GPU Gems 3)](https://developer.nvidia.com/gpugems/gpugems3/part-vi-gpu-computing/chapter-39-parallel-prefix-sum-scan-cuda) — Canonical reference for scan algorithms; covers work-efficient implementation and bank conflict avoidance
- [AoS and SoA Memory Layouts (NVIDIA Forums)](https://forums.developer.nvidia.com/t/structures-of-arrays-vs-arrays-of-structures/13581) — Trade-offs between Array-of-Structs and Struct-of-Arrays for GPU memory coalescing
- [Atomic Float Workarounds](https://unlimited3d.wordpress.com/2020/01/06/atomic-float-arithmetic-on-gpu/) — Why GPUs lack native float atomics and common workarounds including fixed-point scaling
- [Periodic Boundary Conditions (Oregon State)](http://sites.science.oregonstate.edu/~landaur/CPUG/CPlab/MoleDynam/periodic.html) — Toroidal wrap-around for particle simulations; explains the torus topology used in molecular dynamics

## License

Same as parent project (see root LICENSE file).
