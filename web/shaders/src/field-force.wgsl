// =============================================================================
// FIELD FORCE: push particles along the reaction-diffusion field gradient
// =============================================================================
//
// WHY THIS EXISTS:
// Closes the feedback loop: particles deposit inhibitor (field-deposit), the field
// reacts (rd-step), and here the field pushes back on the particles. Each particle
// samples the field gradient at its cell and gets a velocity impulse, so it drifts
// along the evolving pattern instead of ignoring it.
//
// GRADIENT + DIRECTION:
// Central difference of the inhibitor channel (.g). Particles are pushed DOWN the
// inhibitor gradient (away from their own deposits), which spreads them across the
// pattern rather than piling them onto a single seed. fieldForceScale sets the
// magnitude; flipping its sign (a future knob) would pull them up-gradient instead.
//
// INDEXING + OUTPUT:
// Reads particles[] and writes velocityDeltaFixed[] in ORIGINAL index space
// (globalId.x) — the exact space integrate.wgsl reads back. Each particle owns its
// two velocity-delta slots and no other pass writes them in RD mode, so a plain
// store (no atomics) is race-free. This mirrors the fixed-point contract forces.wgsl
// and integrate.wgsl share. RD runs no bin-scatter, so the sorted buffer is stale
// and never referenced.
//
// BINDING MANIFEST:
// +-------+---------------------------+-------------------+--------+
// | Bind  | Shader Type               | JS Buffer/View    | Access |
// +-------+---------------------------+-------------------+--------+
// |   0   | uniform GridParams        | gridParams        | read   |
// |   1   | storage array<Particle>   | particlesA        | read   |
// |   2   | texture_2d<f32>           | fieldA view       | sample |
// |   3   | storage array<i32>        | velocityDelta     | r/w    |
// |   4   | uniform FieldParams       | fieldParams       | read   |
// +-------+---------------------------+-------------------+--------+
// =============================================================================

//! import particle
//! import fixed_point
//! import grid_params
//! import field_params

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var field: texture_2d<f32>;
@group(0) @binding(3) var<storage, read_write> velocityDeltaFixed: array<i32>;
@group(0) @binding(4) var<uniform> params: FieldParams;

const FIELD_DIMS: vec2<i32> = vec2<i32>({{FIELD_W}}, {{FIELD_H}});

fn wrap(coord: vec2<i32>) -> vec2<i32> {
  return (coord + FIELD_DIMS) % FIELD_DIMS;
}

fn inhibitorAt(coord: vec2<i32>) -> f32 {
  return textureLoad(field, wrap(coord), 0).y;
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn applyFieldForce(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= grid.particleCount) {
    return;
  }

  let particle = particles[particleIdx];

  // Particle world position -> field cell (field spans the full world rect).
  let cellFx = particle.pos.x / grid.canvasWidth * f32(FIELD_DIMS.x);
  let cellFy = particle.pos.y / grid.canvasHeight * f32(FIELD_DIMS.y);
  let cellX = clamp(i32(cellFx), 0, FIELD_DIMS.x - 1);
  let cellY = clamp(i32(cellFy), 0, FIELD_DIMS.y - 1);

  // Central-difference gradient of the inhibitor channel.
  let east = inhibitorAt(vec2<i32>(cellX + 1, cellY));
  let west = inhibitorAt(vec2<i32>(cellX - 1, cellY));
  let north = inhibitorAt(vec2<i32>(cellX, cellY - 1));
  let south = inhibitorAt(vec2<i32>(cellX, cellY + 1));
  let gradX = (east - west) * 0.5;
  let gradY = (south - north) * 0.5;

  // Push down-gradient (away from high inhibitor), scaled to velocity units.
  let forceX = -gradX * params.fieldForceScale;
  let forceY = -gradY * params.fieldForceScale;

  // Overwrite this particle's velocity delta (this pass is the sole writer in RD
  // mode; densityDelta is cleared by the frame before integrate reads it).
  velocityDeltaFixed[particleIdx * 2u] = i32(forceX * FIXED_POINT_SCALE);
  velocityDeltaFixed[particleIdx * 2u + 1u] = i32(forceY * FIXED_POINT_SCALE);
}
