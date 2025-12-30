// =============================================================================
// PARTICLE FORCE COMPUTATION SHADER (Pass 4)
// =============================================================================
//
// Computes inter-particle forces using spatial grid acceleration.
// Mirrors src/physics_wasm.nim::physicsStepRange for exact algorithm parity.
//
// Algorithm:
// 1. For each particle i, determine its grid cell
// 2. Iterate 9 neighbor cells (3x3 stencil) with toroidal wrap
// 3. For each particle j in neighbor cells:
//    - Compute toroidal distance
//    - If distance < rMax: compute force based on species attraction
//    - Accumulate force into velocity delta
// 4. Apply mouse attraction (if mouse is down)
// 5. Write velocity deltas to output buffer
//
// Thread mapping: One particle per thread (@workgroup_size(64, 1, 1))
//
// ARCHITECTURAL NOTE:
// This shader uses indirect indexing via sortedIndices to achieve spatial
// locality without physical scattering. The JS side binds only the active
// buffer set (A or B) based on parity - the shader doesn't select at runtime.
// This keeps us at exactly 8 storage buffers (the WebGPU per-stage limit).
//
// BINDING MANIFEST:
// ┌─────────┬──────────────────────────┬─────────────────┬────────┐
// │ Binding │ Shader Type              │ JS Buffer       │ Access │
// ├─────────┼──────────────────────────┼─────────────────┼────────┤
// │ 0       │ uniform SimParams        │ simParams       │ read   │
// │         │ (includes 6x6 matrix)    │                 │        │
// │ 1       │ storage array<f32>       │ pxSrc (active)  │ read   │
// │ 2       │ storage array<f32>       │ pySrc (active)  │ read   │
// │ 3       │ storage array<u32>       │ speciesSrc      │ read   │
// │ 4       │ storage array<u32>       │ sortedIndices   │ read   │
// │ 5       │ storage array<u32>       │ cellOffsets     │ read   │
// │ 6       │ storage array<u32>       │ cellCounts      │ read   │
// │ 7       │ storage array<f32>       │ cellStats       │ read   │
// │ 8       │ storage array<vec2<f32>> │ velocityDelta   │ write  │
// └─────────┴──────────────────────────┴─────────────────┴────────┘
// STORAGE BUFFER COUNT: 8 (at WebGPU per-stage limit)
//
// LOD (Level of Detail) APPROXIMATION (5x5 neighborhood):
// Cells beyond the immediate 3x3 neighborhood use centroid approximation
// instead of per-particle iteration. This is Barnes-Hut-style hierarchical
// force computation: treat distant particle groups as single point masses
// at their center of mass, weighted by species counts.
//
//   ┌───┬───┬───┬───┬───┐
//   │ L │ L │ L │ L │ L │  L = LOD centroid approximation (outer ring)
//   ├───┼───┼───┼───┼───┤
//   │ L │ E │ E │ E │ L │  E = Exact per-particle iteration (inner 3x3)
//   ├───┼───┼───┼───┼───┤
//   │ L │ E │ i │ E │ L │  i = particle i's cell (center)
//   ├───┼───┼───┼───┼───┤
//   │ L │ E │ E │ E │ L │
//   ├───┼───┼───┼───┼───┤
//   │ L │ L │ L │ L │ L │
//   └───┴───┴───┴───┴───┘
//
// For LOD cells, force = Σ (count[species_j] × force(centroid, species_j, species_i))
// =============================================================================

// Simulation parameters including embedded attraction matrix
struct SimParams {
  dt: f32,              // Delta time
  W: f32,               // World width
  H: f32,               // World height
  rMax: f32,            // Maximum interaction radius
  fMul: f32,            // Force multiplier
  gridW: u32,           // Grid width (cells)
  gridH: u32,           // Grid height (cells)
  mouseX: f32,          // Mouse X position
  mouseY: f32,          // Mouse Y position
  mouseDown: f32,       // Mouse left button state (> 0.5 = down)
  mouseRightDown: f32,  // Mouse right button state (> 0.5 = down)
  particleCount: u32,   // Active particle count
  // Attraction matrix embedded in uniform (6x6 = 36 floats, packed as 9 vec4s)
  // WGSL uniform arrays require 16-byte aligned elements, so we use vec4<f32>
  // Row-major: to get matrix[i][j], use matrix[(i*6+j)/4][(i*6+j)%4]
  matrix: array<vec4<f32>, 9>,
};

// Uniform buffer (includes attraction matrix to save storage buffer slot)
@group(0) @binding(0) var<uniform> params: SimParams;

// Particle data - ACTIVE buffer set only (JS binds correct set based on parity)
@group(0) @binding(1) var<storage, read> px: array<f32>;
@group(0) @binding(2) var<storage, read> py: array<f32>;
@group(0) @binding(3) var<storage, read> species: array<u32>;

// Spatial grid (output from Pass 2 & 3)
@group(0) @binding(4) var<storage, read> sortedIndices: array<u32>;
@group(0) @binding(5) var<storage, read> cellOffsets: array<u32>;
@group(0) @binding(6) var<storage, read> cellCounts: array<u32>;

// Cell statistics for LOD approximation (output from cell-stats pass)
// Layout per cell (8 floats): centroidX, centroidY, species_counts[0..5]
@group(0) @binding(7) var<storage, read> cellStats: array<f32>;

// Output buffer (packed vec2 for velocity delta)
@group(0) @binding(8) var<storage, read_write> velocityDelta: array<vec2<f32>>;

const STATS_PER_CELL: u32 = 8u;  // 2 centroid + 6 species counts

// Constants matching physics_wasm.nim
const MAX_SPECIES: u32 = 6u;
const MIN_DIST_SQ: f32 = 4.0;        // Minimum distance squared (2.0²)
const INV_03: f32 = 3.333333333;     // 1.0 / 0.3
const INV_07: f32 = 1.428571429;     // 1.0 / 0.7
const MD2_LIMIT: f32 = 90000.0;      // Mouse distance squared limit

@compute @workgroup_size(64, 1, 1)
fn computeForces(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let i = globalId.x;

  // Bounds check
  if (i >= params.particleCount) {
    return;
  }

  // Read particle i data from active buffer set
  let xi = px[i];
  let yi = py[i];
  let si = species[i];

  // Precomputed constants
  let rMaxSq = params.rMax * params.rMax;
  let invR = 1.0 / params.rMax;
  let halfW = params.W * 0.5;
  let halfH = params.H * 0.5;

  let invCellW = f32(params.gridW) / params.W;
  let invCellH = f32(params.gridH) / params.H;
  let numCells = i32(params.gridW * params.gridH);

  let rowOffset = si * MAX_SPECIES;

  // Force accumulators
  var fx = 0.0;
  var fy = 0.0;

  // Find grid cell for particle i
  var cx = i32(xi * invCellW);
  var cy = i32(yi * invCellH);

  // Clamp to grid bounds
  cx = clamp(cx, 0, i32(params.gridW) - 1);
  cy = clamp(cy, 0, i32(params.gridH) - 1);

  // Iterate 3x3 neighborhood with toroidal wrap
  for (var dy: i32 = -1; dy <= 1; dy++) {
    var ny = cy + dy;
    var wrapY = 0.0;

    // Toroidal Y wrap
    if (ny < 0) {
      ny += i32(params.gridH);
      wrapY = -params.H;
    } else if (ny >= i32(params.gridH)) {
      ny -= i32(params.gridH);
      wrapY = params.H;
    }

    let nyIdx = ny * i32(params.gridW);

    for (var dx: i32 = -1; dx <= 1; dx++) {
      var nx = cx + dx;
      var wrapX = 0.0;

      // Toroidal X wrap
      if (nx < 0) {
        nx += i32(params.gridW);
        wrapX = -params.W;
      } else if (nx >= i32(params.gridW)) {
        nx -= i32(params.gridW);
        wrapX = params.W;
      }

      let cell = nyIdx + nx;

      // Bounds check
      if (cell < 0 || cell >= numCells) {
        continue;
      }

      let count = i32(cellCounts[cell]);
      if (count <= 0) {
        continue;
      }

      // Exact particle-by-particle iteration for immediate 3x3 neighborhood
      // (centroid approximation is too inaccurate for nearby cells; see LOD loop below for outer ring)
      let start = i32(cellOffsets[cell]);

      // Validate cell range
      if (start < 0 || start + count > i32(params.particleCount)) {
        continue;
      }

      let fin = start + count;

      for (var j: i32 = start; j < fin; j++) {
        let jIdx = sortedIndices[j];

        // Read particle j data (same active buffer set)
        let xj = px[jIdx];
        let yj = py[jIdx];
        let sj = species[jIdx];

        // Toroidal distance
        let dx_val = (xj + wrapX) - xi;
        let dy_val = (yj + wrapY) - yi;

        let d2 = dx_val * dx_val + dy_val * dy_val;

        // Skip self and particles beyond rMax
        if (d2 > 0.0 && d2 < rMaxSq) {
          // Clamp minimum distance to avoid division issues
          let d2Clamped = max(d2, MIN_DIST_SQ);
          let d = sqrt(d2Clamped);
          let invD = 1.0 / d;
          let r = d * invR;  // Normalized distance [0, 1]

          // Fetch attraction coefficient from embedded matrix (packed as vec4s)
          let matIdx = rowOffset + sj;
          let attr = params.matrix[matIdx / 4u][matIdx % 4u];

          // Force calculation (piecewise function)
          var f: f32;
          if (r < 0.3) {
            // Repulsion region
            f = r * INV_03 - 1.0;
          } else {
            // Attraction/repulsion region
            let t = 2.0 * r - 1.3;
            let abs_t = abs(t);
            f = attr * (1.0 - abs_t * INV_07);
          }

          // Apply force multiplier and normalize by distance
          f = f * params.fMul * invD;
          fx += dx_val * f;
          fy += dy_val * f;
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // LOD OUTER RING (5x5 minus inner 3x3)
  // For cells 2 steps away, use centroid approximation instead of per-particle
  //
  // EARLY-OUT: Only process if rMax can actually reach the outer ring.
  // Outer ring starts at ~1.5 cells away. If rMax < 1.5 * cellSize, skip entirely.
  // ---------------------------------------------------------------------------
  let cellSizeX = params.W / f32(params.gridW);
  let cellSizeY = params.H / f32(params.gridH);
  let minCellSize = min(cellSizeX, cellSizeY);
  let lodThreshold = minCellSize * 1.5;  // Minimum distance to outer ring
  let useLod = params.rMax >= lodThreshold;

  if (useLod) {
  for (var dy_lod: i32 = -2; dy_lod <= 2; dy_lod++) {
    for (var dx_lod: i32 = -2; dx_lod <= 2; dx_lod++) {
      // Skip inner 3x3 (already handled with exact iteration)
      if (abs(dx_lod) <= 1 && abs(dy_lod) <= 1) {
        continue;
      }

      var ny_lod = cy + dy_lod;
      var wrapY_lod = 0.0;

      // Toroidal Y wrap
      if (ny_lod < 0) {
        ny_lod += i32(params.gridH);
        wrapY_lod = -params.H;
      } else if (ny_lod >= i32(params.gridH)) {
        ny_lod -= i32(params.gridH);
        wrapY_lod = params.H;
      }

      var nx_lod = cx + dx_lod;
      var wrapX_lod = 0.0;

      // Toroidal X wrap
      if (nx_lod < 0) {
        nx_lod += i32(params.gridW);
        wrapX_lod = -params.W;
      } else if (nx_lod >= i32(params.gridW)) {
        nx_lod -= i32(params.gridW);
        wrapX_lod = params.W;
      }

      let cell_lod = ny_lod * i32(params.gridW) + nx_lod;

      // Bounds check
      if (cell_lod < 0 || cell_lod >= numCells) {
        continue;
      }

      let count_lod = cellCounts[cell_lod];
      if (count_lod == 0u) {
        continue;
      }

      // Read cell centroid from cellStats
      let statsBase = u32(cell_lod) * STATS_PER_CELL;
      let centX = cellStats[statsBase + 0u] + wrapX_lod;
      let centY = cellStats[statsBase + 1u] + wrapY_lod;

      // Distance from particle i to cell centroid
      let dx_cent = centX - xi;
      let dy_cent = centY - yi;
      let d2_cent = dx_cent * dx_cent + dy_cent * dy_cent;

      // Only compute force if centroid is within interaction radius
      if (d2_cent > 0.0 && d2_cent < rMaxSq) {
        let d2_clamped = max(d2_cent, MIN_DIST_SQ);
        let d_cent = sqrt(d2_clamped);
        let invD_cent = 1.0 / d_cent;
        let r_cent = d_cent * invR;

        // Sum force contributions from all species in this cell
        for (var sj_lod: u32 = 0u; sj_lod < MAX_SPECIES; sj_lod++) {
          let speciesCount = cellStats[statsBase + 2u + sj_lod];
          if (speciesCount < 0.5) {
            continue;  // No particles of this species in cell
          }

          // Fetch attraction coefficient
          let matIdx_lod = rowOffset + sj_lod;
          let attr_lod = params.matrix[matIdx_lod / 4u][matIdx_lod % 4u];

          // Force calculation (same piecewise function)
          var f_lod: f32;
          if (r_cent < 0.3) {
            f_lod = r_cent * INV_03 - 1.0;
          } else {
            let t_lod = 2.0 * r_cent - 1.3;
            let abs_t_lod = abs(t_lod);
            f_lod = attr_lod * (1.0 - abs_t_lod * INV_07);
          }

          // Scale by particle count and apply force
          f_lod = f_lod * params.fMul * invD_cent * speciesCount;
          fx += dx_cent * f_lod;
          fy += dy_cent * f_lod;
        }
      }
    }
  }
  }  // end if (useLod)

  // Mouse attraction/repulsion (5x strength for strong gravity feel)
  if (params.mouseDown > 0.5 || params.mouseRightDown > 0.5) {
    var mdx = params.mouseX - xi;
    var mdy = params.mouseY - yi;

    // Toroidal wrap for mouse distance
    if (mdx > halfW) {
      mdx -= params.W;
    } else if (mdx < -halfW) {
      mdx += params.W;
    }

    if (mdy > halfH) {
      mdy -= params.H;
    } else if (mdy < -halfH) {
      mdy += params.H;
    }

    let md2 = mdx * mdx + mdy * mdy;
    if (md2 > 0.0 && md2 < MD2_LIMIT) {
      let md = sqrt(md2);
      let mf = 50.0 * (1.0 - md / 300.0) / md;

      // Combine left (attraction) and right (repulsion)
      var sign = 0.0;
      if (params.mouseDown > 0.5) {
        sign += 1.0;
      }
      if (params.mouseRightDown > 0.5) {
        sign -= 1.0;
      }

      fx += mdx * mf * sign;
      fy += mdy * mf * sign;
    }
  }

  // Write velocity delta (packed vec2)
  velocityDelta[i] = vec2f(fx, fy) * params.dt;
}
