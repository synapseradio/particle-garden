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
// │ 7       │ storage array<vec2<f32>> │ velocityDelta   │ write  │
// └─────────┴──────────────────────────┴─────────────────┴────────┘
// STORAGE BUFFER COUNT: 7 (1 slot available)
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

// Output buffer (packed vec2 for velocity delta)
@group(0) @binding(7) var<storage, read_write> velocityDelta: array<vec2<f32>>;

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

      // Exact particle-by-particle iteration for all cells
      // (LOD approximation disabled - immediate neighbors are too close for centroid approximation)
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
