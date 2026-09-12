// =============================================================================
// LONG RANGE DEPOSIT: spread the population onto the mesh
// =============================================================================
//
// WHY THIS EXISTS:
// The long-range force is solved on a grid, so the particles have to become a
// grid first. Each particle lays down one unit of charge into its species'
// slice of the mesh, spread over the four cells whose centres bracket it.
//
// UNIT CHARGE, AND THE STRENGTH DOES NOT MULTIPLY HERE. lr-force applies the
// strength, once, at the end of the chain. That is what keeps this
// accumulator's overflow bound a function of MAX_PARTICLES alone — and so
// statically assertable beside LR_DENSITY_SCALE in src/long_range_core.nim —
// rather than a function of where a slider's ceiling happens to sit.
//
// THE SPECIES' SECRETION IS NOT READ HERE EITHER, unlike field-deposit. The
// relationship between species lives in the attraction matrix the kernel pass
// applies; applying a sign here as well would give one relationship two
// controls.
//
// ITS OWN FIXED-POINT SCALE, not the velocity deltas' 65 536, which would
// saturate at 32 768 particles in one cell — under the count the slider offers,
// and an i32 past its maximum wraps negative, which the kernel would read as a
// hole where the densest clump is.
//
// Mirrors src/long_range_core.nim's lrAssign and lrEncodeDensity, which
// tests/test_long_range_core.nim measures.
// =============================================================================

//! import particle
//! import grid_params
//! import lr_params
//! import lr_grid

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read_write> lrDensity: array<atomic<i32>>;
@group(0) @binding(3) var<uniform> params: LrParams;

const LR_DENSITY_SCALE: f32 = {{LR_DENSITY_SCALE}};

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn depositCharge(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  // grid.particleCount carries the active count; threads past it own no
  // particle.
  if (particleIdx >= grid.particleCount) {
    return;
  }

  let particle = particles[particleIdx];
  if (particle.species >= params.speciesCount) {
    return;
  }

  let assignment = lrAssign(particle.pos, params);
  let base = lrSpeciesBase(particle.species, params);

  // Four atomics, one per bracketing cell, the weights summing to one. The
  // mesh wraps, so a particle at the world's edge deposits across the seam
  // exactly as it would anywhere else — lrAssign already wrapped the cells.
  atomicAdd(&lrDensity[base + assignment.cells.x],
    i32(assignment.weights.x * LR_DENSITY_SCALE));
  atomicAdd(&lrDensity[base + assignment.cells.y],
    i32(assignment.weights.y * LR_DENSITY_SCALE));
  atomicAdd(&lrDensity[base + assignment.cells.z],
    i32(assignment.weights.z * LR_DENSITY_SCALE));
  atomicAdd(&lrDensity[base + assignment.cells.w],
    i32(assignment.weights.w * LR_DENSITY_SCALE));
}
