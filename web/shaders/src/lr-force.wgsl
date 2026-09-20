// =============================================================================
// LONG RANGE FORCE: the mesh pushes back on the particles
// =============================================================================
//
// WHY THIS EXISTS:
// Closes the chain the deposit opened. Each particle reads the gradient of its
// own species' solved potential and takes a velocity impulse along it, so one
// clump can pull on another across the whole world — a distance the neighbour
// sweep's radius cannot reach at any setting.
//
// THE GRADIENT IS A CENTRAL DIFFERENCE OF THE INTERPOLATED POTENTIAL, ONE CELL
// APART. Four bilinear samples, sixteen loads. The step is exactly one cell and
// that exactness carries weight: shifting the sample point by a whole cell is
// the same as shifting the cell index by one, so summed over a population the
// sampled gradients equal the grid's own difference contracted with the
// deposited density — the step in the momentum argument. Half a cell, or a
// fixed number of world units, loses it.
//
// THE SIGN IS POSITIVE. The kernel is positive, so a positive matrix entry
// raises the potential where the source species is dense, and a receiver
// following +grad(Phi) accelerates TOWARD it. Attraction is a positive entry at
// both ranges.
//
// The impulse is per reference frame; integrate applies the substep's frame
// factor to the summed delta.
//
// OUTPUT: two atomicAdds into velocityDeltaFixed in ORIGINAL index space, the
// space integrate.wgsl reads back. Never a store — the frame cleared the buffer
// once at the top and forces, forces-sph and field-force all write it too, so
// integrate has to see the sum rather than whichever pass ran last.
//
// Mirrors src/long_range_core.nim's lrSamplePotential and lrGradient.
// =============================================================================

//! import particle
//! import fixed_point
//! import grid_params
//! import lr_params
//! import lr_grid

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read> lrPotential: array<f32>;
@group(0) @binding(3) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;
@group(0) @binding(4) var<uniform> params: LrParams;

// The potential at a world position, from the SAME four cells and the SAME
// four weights the deposit wrote with.
fn lrSamplePotential(pos: vec2<f32>, base: u32, params: LrParams) -> f32 {
  let assignment = lrAssign(pos, params);
  return assignment.weights.x * lrPotential[base + assignment.cells.x] +
    assignment.weights.y * lrPotential[base + assignment.cells.y] +
    assignment.weights.z * lrPotential[base + assignment.cells.z] +
    assignment.weights.w * lrPotential[base + assignment.cells.w];
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn applyLongRangeForce(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= grid.particleCount) {
    return;
  }

  let particle = particles[particleIdx];
  if (particle.species >= params.speciesCount) {
    return;
  }

  let base = lrSpeciesBase(particle.species, params);
  let cellSize = vec2<f32>(params.worldWidth / f32(params.gridW),
                           params.worldHeight / f32(params.gridH));

  let right = lrSamplePotential(
    particle.pos + vec2<f32>(cellSize.x, 0.0), base, params);
  let left = lrSamplePotential(
    particle.pos - vec2<f32>(cellSize.x, 0.0), base, params);
  let above = lrSamplePotential(
    particle.pos + vec2<f32>(0.0, cellSize.y), base, params);
  let below = lrSamplePotential(
    particle.pos - vec2<f32>(0.0, cellSize.y), base, params);

  let gradient = vec2<f32>((right - left) / (2.0 * cellSize.x),
                           (above - below) / (2.0 * cellSize.y));
  let force = gradient * params.forceScale;

  atomicAdd(&velocityDeltaFixed[particleIdx * 2u],
    i32(force.x * FIXED_POINT_SCALE));
  atomicAdd(&velocityDeltaFixed[particleIdx * 2u + 1u],
    i32(force.y * FIXED_POINT_SCALE));
}
