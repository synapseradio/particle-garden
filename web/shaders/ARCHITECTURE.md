# GPU Compute Pipeline Architecture

This document describes the four-pass GPU compute architecture for particle life simulation, with focus on Pass 4 (force computation).

## Pipeline Overview

```
Pass 1: Grid Assignment
  Input:  particles[]
  Output: gridAssignments[] (cell index per particle)

Pass 2: Cell Counting & Prefix Sum
  Input:  gridAssignments[]
  Output: cellCounts[], cellOffsets[]

Pass 3: Particle Sorting
  Input:  gridAssignments[], cellOffsets[], cellCounts[]
  Output: sortedIndices[] (particles ordered by cell)

Pass 4: Force Computation ← THIS SHADER
  Input:  particles[], sortedIndices[], cellOffsets[], cellCounts[], matrix[]
  Output: vxDelta[], vyDelta[], densityOut[]

Pass 5: Integration (not yet implemented)
  Input:  particles[], vxDelta[], vyDelta[]
  Output: particles[] (updated positions/velocities)
```

## Pass 4 Details: Force Computation

### Algorithm Complexity
- **Time:** O(n × k) where n = particle count, k = avg neighbors per cell × 9 cells
- **Space:** O(n) for output buffers
- **Parallelism:** Perfect - each particle computed independently

### Memory Access Pattern

#### Reads (per particle)
1. **Particle i data:** 1 coalesced read (6 floats)
2. **Grid cell lookup:** 2 reads (cellOffsets[cell], cellCounts[cell]) × 9 cells
3. **Sorted indices:** k scattered reads (where k = avg particles per 9-cell neighborhood)
4. **Particle j data:** k scattered reads (6 floats each)
5. **Matrix lookup:** Up to 6 reads (attraction coefficients)

**Estimated:** ~50-200 reads per particle (depends on particle density)

#### Writes (per particle)
1. **vxDelta[i]:** 1 write
2. **vyDelta[i]:** 1 write
3. **densityOut[i]:** 1 write

**Total:** 3 writes per particle (perfectly coalesced within workgroup)

### Performance Characteristics

#### Best Case: Low Particle Density
- Few neighbors per cell → fewer j-particle reads
- Good cache locality if particles are spatially coherent
- **Expected:** 0.1-0.5ms for 64K particles

#### Worst Case: Uniform High Density
- Many neighbors per cell → more j-particle reads
- Poor cache locality due to scattered access
- **Expected:** 1-3ms for 64K particles

#### Optimization Strategy
The shader is optimized for **memory bandwidth** rather than compute:
1. All force calculations use single-precision math (f32)
2. Constants precomputed (INV_03, INV_07) to avoid divisions
3. Distance clamping prevents NaN/Inf propagation
4. No branching in inner loops (beyond distance checks)

### Buffer Layout Considerations

#### Struct-of-Arrays (SoA) vs Array-of-Structs (AoS)

**Current shader assumes AoS:**
```wgsl
struct Particle {
  px: f32, py: f32, vx: f32, vy: f32, density: f32, species: u32
}
var<storage> particlesA: array<Particle>;
```

**WASM uses SoA:**
```nim
let px = pxA()  # Separate array
let py = pyA()  # Separate array
let species = speciesA()  # Separate array
```

**Why this matters:**
- **AoS:** Better cache locality when accessing all fields of one particle
- **SoA:** Better vectorization when processing one field across many particles

**For this shader, AoS is optimal** because we read all 6 fields of particle j in the inner loop. If you're using SoA in your implementation, modify the shader to use separate buffers:

```wgsl
@group(0) @binding(1) var<storage, read> pxA: array<f32>;
@group(0) @binding(2) var<storage, read> pyA: array<f32>;
@group(0) @binding(3) var<storage, read> speciesA: array<u32>;
// ... etc
```

### Grid Resolution Trade-offs

Grid resolution affects performance through two competing factors:

#### Coarse Grid (e.g., 32×32 = 1024 cells)
- **Pro:** Fewer cell lookups (smaller overhead)
- **Con:** More particles per cell → more j-particle iterations
- **Con:** Neighbor cells cover larger area → more false positives

#### Fine Grid (e.g., 256×256 = 65536 cells)
- **Pro:** Fewer particles per cell → fewer j-particle iterations
- **Pro:** Tighter spatial bounds → fewer false positives
- **Con:** More cell lookups (higher overhead)
- **Con:** More memory for cellOffsets/cellCounts

**Optimal grid resolution:** Cell size ≈ rMax (interaction radius)
- For rMax = 50, world size = 800×600 → grid should be ~16×12 = 192 cells
- Round up to power-of-2 for better GPU alignment → 32×32 = 1024 cells

### Toroidal Topology

The shader implements **toroidal wrapping** (both X and Y wrap around):

```
 ┌─────────────┐
 │ ╔═════════╗ │
 │ ║         ║ │  ← Particle near right edge
 │ ║    •───▶║─┼─▶ sees neighbors on left edge
 │ ╚═════════╝ │
 └─────────────┘
```

**Implementation:**
1. When checking neighbor cells, if cell index < 0 or >= gridSize, wrap it
2. Apply position offset (-W or +W for X, -H or +H for Y) to particle coordinates
3. Distance calculation automatically uses wrapped coordinates

**Why this matters:**
- Prevents edge artifacts (particles repelling at world boundaries)
- Maintains energy conservation (no "walls" that absorb momentum)
- Simplifies physics (no special-case boundary conditions)

### Double Buffering (Parity)

The shader reads from either `particlesA` or `particlesB` based on `params.bufferParity`:

```
Frame N (even):
  Read:  particlesA
  Write: vxDelta, vyDelta
  Integrate into: particlesB

Frame N+1 (odd):
  Read:  particlesB
  Write: vxDelta, vyDelta
  Integrate into: particlesA
```

**Why this matters:**
- Prevents read-write hazards (can't read and write same buffer in parallel)
- Allows GPU to execute force computation and integration in parallel (if pipelined)

## Integration with WebGPU Pipeline

### Required Passes Before Force Computation

#### Pass 1: Grid Assignment
```wgsl
@compute @workgroup_size(64)
fn assignCells(@builtin(global_invocation_id) id: vec3<u32>) {
  let i = id.x;
  let cx = u32(particles[i].px * invCellW);
  let cy = u32(particles[i].py * invCellH);
  gridAssignments[i] = cy * gridW + cx;
}
```

#### Pass 2: Cell Counting
Use parallel reduction or atomic operations:
```wgsl
@compute @workgroup_size(64)
fn countCells(@builtin(global_invocation_id) id: vec3<u32>) {
  let i = id.x;
  let cell = gridAssignments[i];
  atomicAdd(&cellCounts[cell], 1u);
}
```

Then run prefix sum (can use GPU parallel scan or CPU fallback for small grids).

#### Pass 3: Particle Sorting
```wgsl
@compute @workgroup_size(64)
fn sortParticles(@builtin(global_invocation_id) id: vec3<u32>) {
  let i = id.x;
  let cell = gridAssignments[i];
  let offset = atomicAdd(&cellOffsets[cell], 1u);
  sortedIndices[offset] = i;
}
```

### Synchronization Points

WebGPU provides **automatic pass-level synchronization**:
- All writes from Pass N complete before any reads in Pass N+1
- No manual barriers needed between passes

**Within a pass:** Use workgroup memory barriers if sharing data:
```wgsl
workgroupBarrier();
```

But this shader doesn't need barriers - each thread is independent.

## Blind Spots & Limitations

### What This Architecture Assumes

1. **Fixed maximum particle count** - buffers are pre-allocated at MAX_PARTICLES
2. **Fixed grid resolution** - changing grid size requires buffer reallocation
3. **Uniform distribution** - worst-case is all particles in one region
4. **Single species interaction model** - 6×6 matrix is hardcoded

### What This Architecture Does Not Handle

1. **Variable-radius interactions** - rMax is uniform for all species
2. **Three-body forces** - only pairwise interactions
3. **Collision resolution** - force model is soft (no hard constraints)
4. **Adaptive grid refinement** - grid resolution is static

### Extension Points

To add features:

#### Variable Interaction Radius
Replace uniform rMax with per-species array:
```wgsl
let rMaxI = rMaxPerSpecies[si];
let rMaxJ = rMaxPerSpecies[sj];
let rMax = max(rMaxI, rMaxJ);
```

#### Spatial Hashing (Instead of Grid)
Replace grid lookups with hash table:
```wgsl
let hash = spatialHash(xi, yi, cellSize);
let bucket = hashTable[hash];
```

#### Multi-Scale Grid
Use hierarchy of grids (quadtree/octree):
```wgsl
if (count > threshold) {
  // Recurse into finer grid
} else {
  // Use coarse grid
}
```

## Testing Strategy

### Unit Tests (Compute-Only)

1. **Single particle, no neighbors**
   - Input: 1 particle at center, empty grid
   - Expected: vxDelta = vyDelta = 0

2. **Two particles, attraction**
   - Input: 2 particles of same species, distance = rMax * 0.5
   - Expected: Forces point toward each other

3. **Two particles, repulsion**
   - Input: 2 particles, distance < 0.3 * rMax
   - Expected: Forces point away from each other

4. **Toroidal wrap**
   - Input: Particle at (W-1, 0), neighbor at (1, 0)
   - Expected: Distance = 2 (not W-2)

5. **Mouse attraction**
   - Input: Particle at (400, 300), mouse at (450, 300), mouseDown = 1
   - Expected: Force points toward (450, 300)

### Integration Tests (Full Pipeline)

1. **Stability test**
   - Run 1000 frames with random initial conditions
   - Expected: No NaN/Inf, energy remains bounded

2. **Conservation test**
   - Disable friction, run 100 frames
   - Expected: Total kinetic energy conserved (within tolerance)

3. **Performance benchmark**
   - 64K particles, uniform distribution
   - Expected: < 2ms per frame on modern GPU

### Validation Against WASM

Run identical simulation on both WASM and GPU:
1. Same initial conditions (positions, velocities, species)
2. Same parameters (dt, rMax, fMul, etc.)
3. Same random seed for matrix generation
4. Compare outputs frame-by-frame

**Expected difference:** < 0.01% due to floating-point rounding

## Performance Tuning

### Workgroup Size

Current: `@workgroup_size(64, 1, 1)`

**Trade-offs:**
- **32 threads:** Better occupancy on older GPUs, worse memory coalescing
- **64 threads:** Balanced (current choice)
- **128 threads:** Better coalescing, may reduce occupancy
- **256 threads:** Maximum coalescing, requires high register pressure

**Recommendation:** Profile on target hardware. 64 is a safe default.

### Shared Memory Optimization

**Potential optimization:** Cache grid cells in workgroup shared memory:

```wgsl
var<workgroup> sharedParticles: array<Particle, 256>;

// Load cell into shared memory
let localIdx = localId.x;
if (localIdx < cellCount) {
  sharedParticles[localIdx] = particles[sortedIndices[cellStart + localIdx]];
}
workgroupBarrier();

// Read from shared memory instead of global
let pj = sharedParticles[j];
```

**Expected speedup:** 1.5-2× if particles per cell > 64

### Memory Layout Optimization

**Current:** Particle struct (24 bytes) = 6 floats

**Alternative:** Pack species as u8, density as f16:
```wgsl
struct ParticlePacked {
  px: f32, py: f32,      // 8 bytes
  vx: f32, vy: f32,      // 8 bytes
  density: f16,          // 2 bytes
  species: u16,          // 2 bytes
  padding: u32           // 4 bytes (alignment)
}  // Total: 24 bytes (same as before)
```

No savings due to alignment. Stick with current layout for clarity.

## Conclusion

This shader is a **faithful, performance-optimized port** of the WASM physics algorithm to WebGPU compute. It assumes:

1. Passes 1-3 populate sorted indices and grid structures
2. Particle buffers use array-of-structs layout (or can be modified for SoA)
3. Toroidal topology (wrapping at world edges)
4. Double-buffered particle state (parity-based read selection)

Expected performance: **2-10× faster than WASM** for 16K-64K particles on modern GPU.

Next steps: Implement Passes 1-3 and integration pass to complete the pipeline.
