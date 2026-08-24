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
// Central difference of the inhibitor channel (.g). fieldForceScale sets the
// magnitude and the species' signed TROPISM sets the direction: negative
// descends the gradient (away from its own deposits, spreading the species
// across the pattern), positive climbs it.
//
// fieldForceScale arrives with the substep's frame already folded in
// (src/field_core.nim's frameScaledFieldForce, written by webgpu_compute):
// nothing here carries dt, and FieldParams holds no timestep to read, so the
// frame reaches this pass through the scale or not at all. At the reference
// frame the factor is 1 and the value is the slider's own.
//
// THE TWO SIGNS ARE NOT SYMMETRIC. Climbing a self-deposited gradient closes a
// positive feedback loop — the deposit raises the peak, the peak steepens the
// gradient, the gradient pulls harder — which is the Keller-Segel chemotactic
// collapse mechanism. Descending one does not. config_ranges bounds tropism
// asymmetrically for that reason (TROPISM_MAX is half of |TROPISM_MIN|), and
// tests/test_field_core.nim measures the collapse point the bound sits below.
// The shipped default is -1.0: full down-gradient.
//
// INDEXING + OUTPUT:
// Reads particles[] and writes velocityDeltaFixed[] in ORIGINAL index space
// (globalId.x) — the exact space integrate.wgsl reads back. Contributions
// ACCUMULATE atomically: a world can couple the field alongside forces or SPH,
// and integrate has to see the sum of every contributor rather than whichever
// pass happened to run last. The frame clears the buffer once before any of them
// (sim_registry.buildFrame). This mirrors the fixed-point contract forces.wgsl and
// integrate.wgsl share. A field-only world runs no bin-scatter, so the sorted
// buffer is stale and never referenced.
// =============================================================================

//! import particle
//! import fixed_point
//! import grid_params
//! import field_params
//! import species_chemistry
//! import field_grid

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var field: texture_2d<f32>;
@group(0) @binding(3) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;
@group(0) @binding(4) var<uniform> params: FieldParams;
@group(0) @binding(5) var<uniform> chemistry: SpeciesChemistry;

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn applyFieldForce(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= grid.particleCount) {
    return;
  }

  let particle = particles[particleIdx];

  let cell = fieldCellFor(particle.pos,
    vec2<f32>(grid.worldWidth, grid.worldHeight));
  let gradient = fieldInhibitorGradient(field, cell);

  // This species' signed tropism. Packed four species per vec4, the same
  // arithmetic forces.wgsl uses to reach an attraction-matrix entry.
  let tropism =
    chemistry.tropism[particle.species / 4u][particle.species % 4u];

  // Direction lives in the tropism sign; magnitude in fieldForceScale.
  let force = gradient * params.fieldForceScale * tropism;

  // ACCUMULATE, never overwrite. forces.wgsl and forces-sph.wgsl write the same
  // buffer, and integrate must see the sum of all three. The frame clears
  // velocityDelta once at the top, before any contributor runs.
  atomicAdd(&velocityDeltaFixed[particleIdx * 2u],
    i32(force.x * FIXED_POINT_SCALE));
  atomicAdd(&velocityDeltaFixed[particleIdx * 2u + 1u],
    i32(force.y * FIXED_POINT_SCALE));
}
