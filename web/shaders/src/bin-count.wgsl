//! import particle
//! import grid_params
//! import cell_index

@group(0) @binding(0) var<uniform> params: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read_write> cellCounts: array<atomic<u32>>;

@compute @workgroup_size({{WORKGROUP_SIZE}})
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
  let particleIdx = global_id.x;

  if (particleIdx >= params.particleCount) {
    return;
  }

  let p = particles[particleIdx];

  let cellIdx = computeCellIndex(p.pos, params);

  atomicAdd(&cellCounts[cellIdx], 1u);
}
