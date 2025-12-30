// =============================================================================
// INTEGRATE-VELOCITIES: Apply Velocity Deltas to Original Buffers (Pass 5a)
// =============================================================================
//
// WHY THIS EXISTS (Two-Pass Un-Scatter):
// The forces shader computed velocity deltas indexed by ORIGINAL particle order
// (atomics write to velocityDeltaFixed[originalIdx]). This pass reads velocity
// from SORTED buffers, applies the delta, and writes the result back to the
// ORIGINAL velocity buffers.
//
// Split from integrate-positions due to WebGPU's 8-storage-buffer limit.
// Together these two passes complete the "un-scatter" - writing results back
// from sorted order to original order.
//
// ALGORITHM:
// 1. Each thread processes one particle in SORTED order (sortedIdx)
// 2. Look up the original index via sortedToOriginal[sortedIdx]
// 3. Read velocity from SORTED buffers (sequential read = cache hit)
// 4. Read velocity delta from forces output (indexed by original)
// 5. Apply delta and friction, with soft velocity capping
// 6. Write new velocity to ORIGINAL buffers (random write, unavoidable)
//
// BINDING MANIFEST:
// +-------+---------------------------+------------------+--------+
// | Bind  | Shader Type               | JS Buffer        | Access |
// +-------+---------------------------+------------------+--------+
// |   0   | uniform IntegrationParams | integrationParams| read   |
// |   1   | storage array<f32>        | vxSorted         | read   |
// |   2   | storage array<f32>        | vySorted         | read   |
// |   3   | storage array<u32>        | sortedToOriginal | read   |
// |   4   | storage array<i32>        | velocityDeltaFixed| read  |
// |   5   | storage array<f32>        | velocityX        | write  |
// |   6   | storage array<f32>        | velocityY        | write  |
// +-------+---------------------------+------------------+--------+
// TOTAL: 6 storage buffers (under 8-buffer WebGPU limit)
//
// THREAD MAPPING: One particle per thread (sorted index space)
// =============================================================================

struct IntegrationParams {
  worldWidth: f32,       // World width (offset 0)
  worldHeight: f32,      // World height (offset 4)
  friction: f32,         // Friction coefficient (offset 8)
  maxVelocity: f32,      // Maximum velocity (offset 12)
  particleCount: u32,    // Active particle count (offset 16)
  pad0: u32,             // Padding (offset 20)
  pad1: u32,             // Padding (offset 24)
  pad2: u32,             // Padding (offset 28)
};

@group(0) @binding(0) var<uniform> params: IntegrationParams;

// SORTED velocity buffers (sequential read)
@group(0) @binding(1) var<storage, read> vxSorted: array<f32>;
@group(0) @binding(2) var<storage, read> vySorted: array<f32>;

// Index mapping: sortedIdx -> originalIdx
@group(0) @binding(3) var<storage, read> sortedToOriginal: array<u32>;

// Velocity delta from forces pass (interleaved fixed-point i32, original order)
@group(0) @binding(4) var<storage, read> velocityDeltaFixed: array<i32>;

// ORIGINAL velocity buffers (write destination)
@group(0) @binding(5) var<storage, read_write> velocityX: array<f32>;
@group(0) @binding(6) var<storage, read_write> velocityY: array<f32>;

const FIXED_POINT_SCALE: f32 = 65536.0;
const INV_FIXED_POINT_SCALE: f32 = 0.0000152587890625;  // 1.0 / 65536.0

@compute @workgroup_size(128, 1, 1)
fn main(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let sortedIdx = globalId.x;

  if (sortedIdx >= params.particleCount) {
    return;
  }

  // Get original index for this particle
  let originalIdx = sortedToOriginal[sortedIdx];

  // Read velocity from SORTED buffers (sequential read = L1 cache hit)
  let oldVelX = vxSorted[sortedIdx];
  let oldVelY = vySorted[sortedIdx];

  // Read velocity delta from forces output (indexed by ORIGINAL)
  let deltaVxFixed = velocityDeltaFixed[originalIdx * 2u];
  let deltaVyFixed = velocityDeltaFixed[originalIdx * 2u + 1u];
  let deltaVx = f32(deltaVxFixed) * INV_FIXED_POINT_SCALE;
  let deltaVy = f32(deltaVyFixed) * INV_FIXED_POINT_SCALE;

  // Apply velocity delta and friction
  var newVelX = (oldVelX + deltaVx) * params.friction;
  var newVelY = (oldVelY + deltaVy) * params.friction;

  // Logarithmic velocity capping to reduce jank in high-activity areas
  let speed = sqrt(newVelX * newVelX + newVelY * newVelY);
  let softCapThreshold = params.maxVelocity * 0.5;
  if (speed > softCapThreshold && speed > 0.0) {
    let excess = speed - softCapThreshold;
    let compressedSpeed = softCapThreshold + log(1.0 + excess);
    let cappedSpeed = min(compressedSpeed, params.maxVelocity);
    let scale = cappedSpeed / speed;
    newVelX *= scale;
    newVelY *= scale;
  }

  // Write to ORIGINAL velocity buffers (un-scatter)
  velocityX[originalIdx] = newVelX;
  velocityY[originalIdx] = newVelY;
}
