// =============================================================================
// FIELD SEED: write the initial reaction-diffusion state into the field texture
// =============================================================================
//
// WHY THIS EXISTS:
// Gray-Scott's (activator=1, inhibitor=0) state is a fixed point for ANY
// feed/kill/dt — webgpu_init's render-pass clear leaves the field exactly there,
// and it stays there forever. Per-particle deposits cannot lift it off either: an
// isolated cell loses diffusionB * B to the Laplacian every substep with no
// neighbors to replenish it. Only a spatially COHERENT perturbation ignites the
// system. This one-shot pass writes that perturbation.
//
// It is NOT a frame node. webgpu_compute encodes it on demand — on a particle
// reset and on the deliberate "scatter spores" action — ahead of that frame's
// substeps. Nothing seeds the field automatically, which is what makes an
// unseeded pattern a record of where colonies lived.
//
// THIS FILE MIRRORS src/field_core.nim's rdSeedCell EXACTLY, the same
// hand-maintained contract rd-step.wgsl has with grayScottStep. The pair is what
// lets the native test suite make claims about a seed the GPU actually writes.
// Two properties keep the mirror honest across the f32/float64 divide: the hash
// is pure 32-bit integer arithmetic, and blob centers are integer cell
// coordinates. Neither side can round differently.
//
// ONLY THE FRONT TEXTURE IS SEEDED. Each frame opens with field-resolve reading
// the front and writing the trail, so the trail is overwritten before any pass
// reads it. Seeding both would be wasted work, not extra safety.
//
// CHANNELS: .r = activator (A), .g = inhibitor (B).
//
// BINDING MANIFEST:
// +-------+---------------------------------------+-------------+--------+
// | Bind  | Shader Type                           | Resource    | Access |
// +-------+---------------------------------------+-------------+--------+
// |   0   | texture_storage_2d<rgba16float,write> | fieldA view | write  |
// |   1   | uniform FieldParams                   | fieldParams | read   |
// +-------+---------------------------------------+-------------+--------+
// =============================================================================

//! import field_params

@group(0) @binding(0) var dstField: texture_storage_2d<rgba16float, write>;
@group(0) @binding(1) var<uniform> params: FieldParams;

const FIELD_W: u32 = {{FIELD_W}}u;
const FIELD_H: u32 = {{FIELD_H}}u;

const SEED_BLOB_COUNT: u32 = {{RD_SEED_BLOB_COUNT}}u;
const SEED_BLOB_RADIUS: f32 = {{RD_SEED_BLOB_RADIUS}};
const SEED_CORE_ACTIVATOR: f32 = {{RD_SEED_CORE_ACTIVATOR}};
const SEED_CORE_INHIBITOR: f32 = {{RD_SEED_CORE_INHIBITOR}};

// The initial condition for the two reserved state channels a multi-channel
// reaction would occupy. The ping-pong textures are rgba16float because WebGPU
// does not permit rg16float as a write-only storage format, so these channels
// are already allocated at no additional cost. Gray-Scott uses neither.
const RESERVED_CHANNEL_B_INITIAL: f32 = 0.0;
const RESERVED_CHANNEL_A_INITIAL: f32 = 1.0;

// Mirrors field_core.rdSeedHash (the lowbias32 xor-shift/multiply chain).
fn seedHash(value: u32) -> u32 {
  var mixed = value;
  mixed = mixed ^ (mixed >> 16u);
  mixed = mixed * 0x7feb352du;
  mixed = mixed ^ (mixed >> 15u);
  mixed = mixed * 0x846ca68bu;
  mixed = mixed ^ (mixed >> 16u);
  return mixed;
}

// Mirrors field_core.rdSeedBlobCenter. Integer cell coordinates, deliberately.
fn seedBlobCenter(blobIndex: u32, nonce: u32) -> vec2<u32> {
  let stream = seedHash(blobIndex * 2u + 1u) ^ seedHash(nonce);
  return vec2<u32>(
    seedHash(stream) % FIELD_W,
    seedHash(stream ^ 0x9e3779b9u) % FIELD_H);
}

@compute @workgroup_size({{WORKGROUP_SIZE_FIELD_X}}, {{WORKGROUP_SIZE_FIELD_Y}}, 1)
fn seedField(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let cellX = globalId.x;
  let cellY = globalId.y;
  if (cellX >= FIELD_W || cellY >= FIELD_H) {
    return;
  }

  let nonce = u32(params.seedNonce);
  let width = f32(FIELD_W);
  let height = f32(FIELD_H);

  // MAX over blobs, never a sum: overlapping blobs must saturate at the core
  // values rather than stack past them into the flooded regime.
  var coverage = 0.0;
  for (var blobIndex = 0u; blobIndex < SEED_BLOB_COUNT; blobIndex = blobIndex + 1u) {
    let center = seedBlobCenter(blobIndex, nonce);
    // Toroidal distance — the field wraps, exactly as rd-step's neighbor reads do.
    var dx = abs(f32(cellX) - f32(center.x));
    if (dx > width * 0.5) { dx = width - dx; }
    var dy = abs(f32(cellY) - f32(center.y));
    if (dy > height * 0.5) { dy = height - dy; }
    let distance = sqrt(dx * dx + dy * dy);
    // A flat core out to half the radius, falling to background at the edge.
    let falloff = clamp((SEED_BLOB_RADIUS - distance) / (SEED_BLOB_RADIUS * 0.5), 0.0, 1.0);
    coverage = max(coverage, falloff);
  }

  let activator = 1.0 + (SEED_CORE_ACTIVATOR - 1.0) * coverage;
  let inhibitor = SEED_CORE_INHIBITOR * coverage;
  // RESERVED STATE CHANNELS — INITIALIZED, not preserved. field-resolve and
  // rd-step carry .b/.a through untouched because they advance a running
  // field. This pass does the opposite: it is the deliberate "scatter spores"
  // reset, and it binds its target write-only with no source to carry
  // anything from. A multi-channel reaction wants its channels ESTABLISHED
  // here, exactly as the reacting channels are — preserving stale values
  // across a reset would be the bug, not the feature. The values are named so
  // that a reaction adding state has one place to set its initial condition.
  textureStore(dstField, vec2<i32>(i32(cellX), i32(cellY)),
    vec4<f32>(activator, inhibitor,
      RESERVED_CHANNEL_B_INITIAL, RESERVED_CHANNEL_A_INITIAL));
}
