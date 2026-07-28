// =============================================================================
// FIELD DEPOSIT: particles splat inhibitor into the reaction-diffusion field
// =============================================================================
//
// WHY THIS EXISTS:
// The reaction-diffusion mode treats particles as moving sources that seed the
// inhibitor channel of the Gray-Scott field. A uniform (activator=1, inhibitor=0)
// field never reacts on its own; this pass is what injects the perturbation that
// ignites the pattern, tracking wherever the particles happen to be.
//
// FIXED-POINT ATOMICS:
// Many particles can land in the same field cell in one frame, so the deposit is
// accumulated with integer atomics (GPUs have no atomic<f32>). Each particle adds
// depositAmount * FIXED_POINT_SCALE (i32); field-resolve.wgsl decodes the sum back
// to f32 and folds it into the field texture, then zeroes this buffer.
//
// CHANNEL LAYOUT: fieldDeposit is ONE i32 per cell — the inhibitor deposit. It
// carried a second, never-written activator slot as headroom for a future
// activator coupling; nothing used it, so it cost 1 MB of VRAM and 1 MB per frame
// of read/write traffic to reserve. Restoring it is a contained ~20-line change:
// double the allocation in webgpu_init.createFieldResources and byteLengthFor in
// webgpu_compute, index as cellIndex*2 here, and load/store/reset both slots in
// field-resolve.wgsl. Do that when an activator coupling actually exists.
//
// INDEXING: reads particles[] in ORIGINAL index space (globalId.x), the same space
// integrate.wgsl and field-force.wgsl use. Reaction-diffusion runs no bin-scatter,
// so the sorted buffer is stale in this mode and is never referenced.
//
// BINDING MANIFEST:
// +-------+---------------------------+-------------------+--------+
// | Bind  | Shader Type               | JS Buffer         | Access |
// +-------+---------------------------+-------------------+--------+
// |   0   | uniform GridParams        | gridParams        | read   |
// |   1   | storage array<Particle>   | particlesA        | read   |
// |   2   | storage atomic<i32>       | fieldDeposit      | r/w    |
// |   3   | uniform FieldParams       | fieldParams       | read   |
// +-------+---------------------------+-------------------+--------+
// =============================================================================

//! import particle
//! import fixed_point
//! import grid_params
//! import field_params

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read_write> fieldDeposit: array<atomic<i32>>;
@group(0) @binding(3) var<uniform> params: FieldParams;

const FIELD_W: i32 = {{FIELD_W}};
const FIELD_H: i32 = {{FIELD_H}};

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn depositField(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  // grid.particleCount carries the active count (clamped to RD_PARTICLE_CEILING
  // on RD mode entry by the UI); threads past it own no particle.
  if (particleIdx >= grid.particleCount) {
    return;
  }

  let particle = particles[particleIdx];

  // Map the particle's world position to a field cell. The field spans the full
  // world rect, so this is a straight normalize-and-scale.
  let cellFx = particle.pos.x / grid.canvasWidth * f32(FIELD_W);
  let cellFy = particle.pos.y / grid.canvasHeight * f32(FIELD_H);
  let cellX = clamp(i32(cellFx), 0, FIELD_W - 1);
  let cellY = clamp(i32(cellFy), 0, FIELD_H - 1);
  let cellIndex = cellY * FIELD_W + cellX;

  // Fold depositAmount of inhibitor into this cell (fixed-point).
  let depositFixed = i32(params.depositAmount * FIXED_POINT_SCALE);
  atomicAdd(&fieldDeposit[cellIndex], depositFixed);
}
