// =============================================================================
// FIELD DEPOSIT: particles splat inhibitor into the reaction-diffusion field
// =============================================================================
//
// WHY THIS EXISTS:
// Particles are moving sources that seed the inhibitor channel of the
// Gray-Scott field. A uniform (activator=1, inhibitor=0)
// field never reacts on its own; this pass is what injects the perturbation that
// ignites the pattern, tracking wherever the particles happen to be.
//
// FIXED-POINT ATOMICS:
// Many particles can land in the same field cell in one frame, so the deposit
// accumulates as depositAmount * FIXED_POINT_SCALE in atomic i32 (rationale:
// fixed_point.wgsl); field-resolve.wgsl decodes the sum back to f32, folds it
// into the field texture, then zeroes this buffer.
//
// CHANNEL LAYOUT: one i32 per cell, the inhibitor deposit, so a cell index is
// the buffer index directly — here and in field-resolve.wgsl alike.
//
// One channel: the inhibitor deposit. Signed secretion into it already gives
// both roles the ecology needs — positive builds structure, negative erodes it.
// A second (activator) deposit channel would double this buffer and require
// synchronized changes to webgpu_init.createFieldResources,
// webgpu_compute.byteLengthFor, and field-resolve.wgsl.
//
// INDEXING: reads particles[] in ORIGINAL index space (globalId.x), the same space
// integrate.wgsl and field-force.wgsl use. A splat needs no neighbours, so this
// pass never touches the sorted buffer bin-scatter fills.
//
// SPECIES SECRETION:
// The deposit is scaled by the depositing species' signed secretion, so
// speciesCount changes what the chemistry does and not merely how the
// particles are coloured. Positive secretion builds inhibitor structure,
// negative erodes it, zero leaves the field unmarked. The scale multiplies the
// AMPLITUDE only — the splat kernel's normalization is untouched, so a
// particle's total contribution stays conserved whatever its species.
// =============================================================================

//! import particle
//! import fixed_point
//! import grid_params
//! import field_params
//! import species_chemistry
//! import field_grid

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read_write> fieldDeposit: array<atomic<i32>>;
@group(0) @binding(3) var<uniform> params: FieldParams;
@group(0) @binding(4) var<uniform> chemistry: SpeciesChemistry;

// THE SPLAT KERNEL. Mirrors field_core.depositSplatWeight and its normalization,
// both substituted from src/shader_config.nim so the shader and the natively
// tested oracle cannot be given different kernels.
//
// A particle's deposit is spread over a disc rather than dropped in one cell
// because COHERENCE, not magnitude, is what escapes Gray-Scott's trivial fixed
// point — tests/test_field_core.nim measures a single-cell deposit failing to
// ignite at ANY amplitude the slider offers, while this radius ignites at the
// default. The weights are normalized, so a particle contributes the same total
// deposit whatever the radius: widening the kernel redistributes, it never
// amplifies, and so cannot flood the field past the ceiling RD_DEPOSIT_MAX was
// measured against.
const SPLAT_RADIUS: f32 = {{RD_DEPOSIT_SPLAT_RADIUS}};
const SPLAT_EXTENT: i32 = {{RD_DEPOSIT_SPLAT_EXTENT}};
const SPLAT_SIGMA: f32 = {{RD_DEPOSIT_SPLAT_SIGMA}};
const SPLAT_NORMALIZATION: f32 = {{RD_DEPOSIT_SPLAT_NORMALIZATION}};

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn depositField(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  // grid.particleCount carries the active count; threads past it own no
  // particle.
  if (particleIdx >= grid.particleCount) {
    return;
  }

  let particle = particles[particleIdx];

  // This species' signed secretion. Packed four species per vec4, the same
  // arithmetic forces.wgsl uses to reach an attraction-matrix entry.
  let secretion =
    chemistry.secretion[particle.species / 4u][particle.species % 4u];
  let speciesDeposit = params.depositAmount * secretion;

  let cell = fieldCellFor(particle.pos,
    vec2<f32>(grid.canvasWidth, grid.canvasHeight));
  // Splat the deposit across the kernel. The field wraps, so cell offsets wrap
  // with it — a colony sitting on the world edge deposits across the seam
  // exactly as it would anywhere else.
  for (var offsetY: i32 = -SPLAT_EXTENT; offsetY <= SPLAT_EXTENT; offsetY++) {
    for (var offsetX: i32 = -SPLAT_EXTENT; offsetX <= SPLAT_EXTENT; offsetX++) {
      // Squared distance throughout: the cutoff compares against the squared
      // radius and the Gaussian wants the square anyway, so no square root is
      // taken and then undone. Offsets are integers, so the boundary ring lands
      // on exact squares (distSq 25 against radius 25) and the covered cell set
      // is the same one the distance form kept.
      let distSq = f32(offsetX * offsetX + offsetY * offsetY);
      if (distSq > SPLAT_RADIUS * SPLAT_RADIUS) {
        continue;
      }
      let weight = exp(-distSq /
        (2.0 * SPLAT_SIGMA * SPLAT_SIGMA)) / SPLAT_NORMALIZATION;
      let splat = fieldWrap(cell + vec2<i32>(offsetX, offsetY));
      let depositFixed = i32(speciesDeposit * weight * FIXED_POINT_SCALE);
      atomicAdd(&fieldDeposit[fieldCellIndex(splat)], depositFixed);
    }
  }
}
