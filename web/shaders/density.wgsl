// =============================================================================
// PARTICLE DENSITY COMPUTATION SHADER (Pass 4b - runs after forces)
// =============================================================================
//
// Computes local density for each particle based on same-species neighbors.
// Density is used for visual sizing: high density = smaller particles.
//
// Algorithm:
// 1. For each particle i, determine its grid cell
// 2. Iterate 9 neighbor cells (3x3 stencil) with toroidal wrap
// 3. For each particle j in neighbor cells:
//    - If same species and distance < rMax:
//    - Accumulate density: dens += (1.0 - normalized_distance)
// 4. Write density to output buffer
//
// Thread mapping: One particle per thread (@workgroup_size(64, 1, 1))
//
// BINDING MANIFEST:
// ┌─────────┬──────────────────────────┬─────────────────┬────────┐
// │ Binding │ Shader Type              │ JS Buffer       │ Access │
// ├─────────┼──────────────────────────┼─────────────────┼────────┤
// │ 0       │ uniform DensityParams    │ densityParams   │ read   │
// │ 1       │ storage array<f32>       │ pxSrc (active)  │ read   │
// │ 2       │ storage array<f32>       │ pySrc (active)  │ read   │
// │ 3       │ storage array<u32>       │ speciesSrc      │ read   │
// │ 4       │ storage array<u32>       │ sortedIndices   │ read   │
// │ 5       │ storage array<u32>       │ cellOffsets     │ read   │
// │ 6       │ storage array<u32>       │ cellCounts      │ read   │
// │ 7       │ storage array<f32>       │ density         │ write  │
// └─────────┴──────────────────────────┴─────────────────┴────────┘
// STORAGE BUFFER COUNT: 7 (under WebGPU limit of 8)
// =============================================================================

struct DensityParams {
  W: f32,               // World width
  H: f32,               // World height
  rMax: f32,            // Maximum interaction radius
  gridW: u32,           // Grid width (cells)
  gridH: u32,           // Grid height (cells)
  particleCount: u32,   // Active particle count
  _pad0: u32,           // Padding for 16-byte alignment
  _pad1: u32,
};

@group(0) @binding(0) var<uniform> params: DensityParams;

// Particle data - ACTIVE buffer set only
@group(0) @binding(1) var<storage, read> px: array<f32>;
@group(0) @binding(2) var<storage, read> py: array<f32>;
@group(0) @binding(3) var<storage, read> species: array<u32>;

// Spatial grid (output from Pass 2 & 3)
@group(0) @binding(4) var<storage, read> sortedIndices: array<u32>;
@group(0) @binding(5) var<storage, read> cellOffsets: array<u32>;
@group(0) @binding(6) var<storage, read> cellCounts: array<u32>;

// Output buffer
@group(0) @binding(7) var<storage, read_write> density: array<f32>;

@compute @workgroup_size(64, 1, 1)
fn computeDensity(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let i = globalId.x;

  // Bounds check
  if (i >= params.particleCount) {
    return;
  }

  // Read particle i data
  let xi = px[i];
  let yi = py[i];
  let si = species[i];

  // Precomputed constants
  let rMaxSq = params.rMax * params.rMax;
  let invR = 1.0 / params.rMax;

  let invCellW = f32(params.gridW) / params.W;
  let invCellH = f32(params.gridH) / params.H;
  let numCells = i32(params.gridW * params.gridH);

  // Density accumulator
  var dens = 0.0;

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

      let start = i32(cellOffsets[cell]);
      let count = i32(cellCounts[cell]);

      // Validate cell range
      if (start < 0 || start + count > i32(params.particleCount)) {
        continue;
      }

      let fin = start + count;

      // Iterate particles in cell
      for (var j: i32 = start; j < fin; j++) {
        let jIdx = sortedIndices[j];

        // Only count same-species particles for density
        let sj = species[jIdx];
        if (sj != si) {
          continue;
        }

        // Read particle j position
        let xj = px[jIdx];
        let yj = py[jIdx];

        // Toroidal distance
        let dx_val = (xj + wrapX) - xi;
        let dy_val = (yj + wrapY) - yi;

        let d2 = dx_val * dx_val + dy_val * dy_val;

        // Skip self and particles beyond rMax
        if (d2 > 0.0 && d2 < rMaxSq) {
          let d = sqrt(d2);
          let r = d * invR;  // Normalized distance [0, 1]

          // Density contribution: closer = higher density
          dens += 1.0 - r;
        }
      }
    }
  }

  // Write density
  density[i] = dens;
}
