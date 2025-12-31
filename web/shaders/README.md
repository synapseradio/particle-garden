# WebGPU Compute Shaders for Particle Life Simulation

This directory contains WebGPU compute shaders for the Particle Garden particle life simulation.

## Overview

The simulation uses a **five-pass GPU compute pipeline** for spatial grid-accelerated physics:

```
Pass 1: Grid Assignment (bin-count.wgsl)
  ├─ Input:  Particle positions
  └─ Output: Cell counts per grid cell

Pass 2: Prefix Sum (TODO)
  ├─ Input:  Cell counts
  └─ Output: Cell offsets (cumulative sum)

Pass 3: Particle Sorting (TODO)
  ├─ Input:  Particle positions, cell offsets
  └─ Output: Sorted particle indices

Pass 4: Force Computation (forces.wgsl) ← IMPLEMENTED
  ├─ Input:  Particles, sorted indices, grid, attraction matrix
  └─ Output: Velocity deltas, density

Pass 5: Integration (TODO)
  ├─ Input:  Particles, velocity deltas
  └─ Output: Updated positions/velocities
```

## Files

### Shaders
- **`bin-count.wgsl`** - Pass 1: Count particles per grid cell using atomics
- **`forces.wgsl`** - Pass 4: Compute inter-particle forces (COMPLETE)

### Documentation
- **`README.md`** - This file
- **`forces_verification.md`** - Algorithm verification against WASM implementation
- **`forces_usage.js`** - JavaScript integration example for forces.wgsl
- **`ARCHITECTURE.md`** - Deep dive into GPU pipeline architecture

## forces.wgsl - Force Computation Shader

### What It Does

Computes inter-particle forces using spatial grid acceleration. For each particle:

1. **Find grid cell** - Determine which cell the particle occupies
2. **Iterate 9 neighbor cells** - Check 3×3 neighborhood with toroidal wrapping
3. **Compute forces** - For each nearby particle:
   - Calculate toroidal distance
   - Apply species-based attraction/repulsion
   - Accumulate force into velocity delta
4. **Mouse attraction** - Add force toward mouse cursor (if mouse is down)
5. **Write output** - Store velocity deltas and density

### Algorithm Parity

This shader is a **1:1 port** of `src/physics_wasm.nim::physicsStepRange()` to WGSL. Every force calculation, distance clamp, and toroidal wrap matches the WASM implementation exactly.

See `forces_verification.md` for line-by-line comparison.

### Buffer Layout

The shader uses **Struct-of-Arrays (SoA)** layout matching `webgpu-init.js`:

```
Buffer Set A (read when bufferParity == 0):
  pxA[]:      Float32Array (particle X positions)
  pyA[]:      Float32Array (particle Y positions)
  speciesA[]: Uint32Array  (particle species indices)

Buffer Set B (read when bufferParity == 1):
  pxB[]:      Float32Array
  pyB[]:      Float32Array
  speciesB[]: Uint32Array

Spatial Grid (from Pass 2 & 3):
  sortedIndices[]: Uint32Array (particle indices ordered by cell)
  cellOffsets[]:   Uint32Array (starting index per cell)
  cellCounts[]:    Uint32Array (particle count per cell)

Attraction Matrix:
  matrix[]:   Float32Array (6×6 row-major, species interactions)

Outputs:
  vxDelta[]:    Float32Array (velocity change X)
  vyDelta[]:    Float32Array (velocity change Y)
  densityOut[]: Float32Array (local particle density)
```

### Performance

**Expected:** < 1ms for 64K particles on modern GPU (2-10× faster than WASM)

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

### Quick Start

```javascript
import { device, buffers } from './webgpu-init.js';
import { setupForcePipeline, computeForces, createUniformData } from './shaders/forces_usage.js';

// Initialize pipeline (once)
const { pipeline, uniformBuffer, sortedIndices } = await setupForcePipeline(device, buffers);

// Each frame:
const params = {
  dt: 0.016,
  W: 800,
  H: 600,
  rMax: 50,
  fMul: 1.0,
  gridW: 32,
  gridH: 24,
  mouseX: 400,
  mouseY: 300,
  mouseDown: 0,
  particleCount: 16000,
  bufferParity: frameCount % 2,
};

computeForces(device, pipeline, { ...buffers, uniformBuffer, sortedIndices }, params);
```

See `forces_usage.js` for full example.

### Prerequisites

Before running force computation:

1. **Pass 1 (bin-count.wgsl)** - Populate `cellCounts[]`
2. **Pass 2 (TODO)** - Compute `cellOffsets[]` via prefix sum
3. **Pass 3 (TODO)** - Populate `sortedIndices[]` by sorting particles into cells

### Next Steps After Force Computation

**Pass 5 (Integration)** - Apply velocity deltas to particle positions:

```wgsl
@compute @workgroup_size(64)
fn integrate(@builtin(global_invocation_id) id: vec3<u32>) {
  let i = id.x;
  if (i >= params.particleCount) { return; }

  // Read from Set A, write to Set B (or vice versa based on parity)
  let vx = vxA[i] + vxDelta[i];
  let vy = vyA[i] + vyDelta[i];
  let px = pxA[i] + vx * params.dt;
  let py = pyA[i] + vy * params.dt;

  // Apply friction
  vxB[i] = vx * (1.0 - params.friction);
  vyB[i] = vy * (1.0 - params.friction);

  // Toroidal wrap
  pxB[i] = (px + params.W) % params.W;
  pyB[i] = (py + params.H) % params.H;
}
```

## Constants

All constants match `src/physics_wasm.nim`:

```wgsl
const MAX_SPECIES: u32 = 6u;         // Maximum species count
const MIN_DIST_SQ: f32 = 4.0;        // Min distance² (prevents division by zero)
const INV_03: f32 = 3.333333333;     // 1.0 / 0.3 (repulsion threshold)
const INV_07: f32 = 1.428571429;     // 1.0 / 0.7 (attraction falloff)
const MD2_LIMIT: f32 = 90000.0;      // Mouse distance² limit
```

## Toroidal Topology

The simulation uses **toroidal wrapping** (both X and Y wrap around):

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
- Verify `cellOffsets[]` and `sortedIndices[]` from Pass 2/3
- Ensure `bufferParity` toggles each frame

**2. Particles explode**
- Check `dt` is reasonable (0.001 - 0.05)
- Verify `fMul` isn't too large (typically 0.1 - 2.0)
- Ensure `MIN_DIST_SQ` clamps minimum distance

**3. Uniform density / no attraction**
- Check attraction matrix has non-zero values
- Verify species indices are valid (0-5)
- Ensure `rMax` matches expected interaction radius

### Validation

Run WASM and GPU in parallel with identical inputs:

```javascript
// Initialize both WASM and GPU with same state
const tolerance = 1e-4;

for (let i = 0; i < particleCount; i++) {
  const wasmVx = vxDeltaWASM[i];
  const gpuVx = vxDeltaGPU[i];
  const diff = Math.abs(wasmVx - gpuVx);

  if (diff > tolerance) {
    console.error(`Mismatch at particle ${i}: WASM=${wasmVx}, GPU=${gpuVx}`);
  }
}
```

Expected difference: < 0.01% due to floating-point rounding.

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

- **WASM Implementation:** `src/physics_wasm.nim`
- **Buffer Layout:** `web/config.js` (MEMORY_LAYOUT)
- **GPU Initialization:** `web/webgpu-init.js`
- **WebGPU Spec:** https://www.w3.org/TR/webgpu/
- **WGSL Spec:** https://www.w3.org/TR/WGSL/

## License

Same as parent project (see root LICENSE file).
