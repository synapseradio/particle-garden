// =============================================================================
// INTEGRATE-POSITIONS: Update Positions from Velocities (Pass 5b)
// =============================================================================
//
// WHY THIS EXISTS (Two-Pass Un-Scatter):
// This is the second pass of the integration un-scatter. Pass 5a updated
// velocities from sorted order back to original buffers. This pass reads
// positions from SORTED buffers, applies the newly-updated velocities from
// ORIGINAL buffers, and writes positions back to ORIGINAL buffers.
//
// Split from integrate-velocities due to WebGPU's 8-storage-buffer limit.
//
// ALGORITHM:
// 1. Each thread processes one particle in SORTED order (sortedIdx)
// 2. Look up the original index via sortedToOriginal[sortedIdx]
// 3. Read position from SORTED buffers (sequential read = cache hit)
// 4. Read NEW velocity from ORIGINAL buffers (written by Pass 5a)
// 5. Update position: newPos = oldPos + newVel
// 6. Apply toroidal wrapping
// 7. Write new position to ORIGINAL buffers (un-scatter)
//
// BINDING MANIFEST:
// +-------+---------------------------+------------------+--------+
// | Bind  | Shader Type               | JS Buffer        | Access |
// +-------+---------------------------+------------------+--------+
// |   0   | uniform IntegrationParams | integrationParams| read   |
// |   1   | storage array<f32>        | pxSorted         | read   |
// |   2   | storage array<f32>        | pySorted         | read   |
// |   3   | storage array<u32>        | sortedToOriginal | read   |
// |   4   | storage array<f32>        | velocityX        | read   |
// |   5   | storage array<f32>        | velocityY        | read   |
// |   6   | storage array<f32>        | positionX        | write  |
// |   7   | storage array<f32>        | positionY        | write  |
// +-------+---------------------------+------------------+--------+
// TOTAL: 7 storage buffers (under 8-buffer WebGPU limit)
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

// SORTED position buffers (sequential read)
@group(0) @binding(1) var<storage, read> pxSorted: array<f32>;
@group(0) @binding(2) var<storage, read> pySorted: array<f32>;

// Index mapping: sortedIdx -> originalIdx
@group(0) @binding(3) var<storage, read> sortedToOriginal: array<u32>;

// ORIGINAL velocity buffers (read - updated by integrate-velocities)
@group(0) @binding(4) var<storage, read> velocityX: array<f32>;
@group(0) @binding(5) var<storage, read> velocityY: array<f32>;

// ORIGINAL position buffers (write destination)
@group(0) @binding(6) var<storage, read_write> positionX: array<f32>;
@group(0) @binding(7) var<storage, read_write> positionY: array<f32>;

@compute @workgroup_size(128, 1, 1)
fn main(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let sortedIdx = globalId.x;

  if (sortedIdx >= params.particleCount) {
    return;
  }

  // Get original index for this particle
  let originalIdx = sortedToOriginal[sortedIdx];

  // Read position from SORTED buffers (sequential read = L1 cache hit)
  let oldPosX = pxSorted[sortedIdx];
  let oldPosY = pySorted[sortedIdx];

  // Read velocity from ORIGINAL buffers (written by integrate-velocities)
  let velX = velocityX[originalIdx];
  let velY = velocityY[originalIdx];

  // Update position
  var newPosX = oldPosX + velX;
  var newPosY = oldPosY + velY;

  // Toroidal wrap
  if (newPosX < 0.0) {
    newPosX += params.worldWidth;
  } else if (newPosX >= params.worldWidth) {
    newPosX -= params.worldWidth;
  }

  if (newPosY < 0.0) {
    newPosY += params.worldHeight;
  } else if (newPosY >= params.worldHeight) {
    newPosY -= params.worldHeight;
  }

  // Write to ORIGINAL position buffers (un-scatter)
  positionX[originalIdx] = newPosX;
  positionY[originalIdx] = newPosY;
}
