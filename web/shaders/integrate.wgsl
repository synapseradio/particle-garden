// =============================================================================
// VELOCITY INTEGRATION AND POSITION UPDATE SHADER (Pass 5)
// =============================================================================
//
// Applies velocity deltas computed by the forces pass and updates positions.
// Mirrors physics_wasm.nim physics() for exact algorithm parity.
//
// Algorithm:
// 1. Read velocity and position from active buffer (in-place update)
// 2. Read velocity delta from forces output (fixed-point interleaved i32)
// 3. Convert fixed-point to float and apply delta with friction
// 4. Apply velocity capping (logarithmic soft cap)
// 5. Update position: newPos = oldPos + newVel
// 6. Apply toroidal wrapping
// 7. Write back to same buffer (in-place)
//
// NOTE: This shader does IN-PLACE updates on the active buffer.
// The caller determines which buffer set (A or B) is active by binding
// the appropriate buffers. No parity branching needed in shader.
//
// Thread mapping: One particle per thread (@workgroup_size(128, 1, 1))
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

// Active particle buffers (in-place read/write)
@group(0) @binding(1) var<storage, read_write> positionX: array<f32>;
@group(0) @binding(2) var<storage, read_write> positionY: array<f32>;
@group(0) @binding(3) var<storage, read_write> velocityX: array<f32>;
@group(0) @binding(4) var<storage, read_write> velocityY: array<f32>;

// Velocity delta from forces pass (interleaved fixed-point i32)
// Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
// Scale factor must match forces.wgsl FIXED_POINT_SCALE
@group(0) @binding(5) var<storage, read> velocityDeltaFixed: array<i32>;

const FIXED_POINT_SCALE: f32 = 65536.0;
const INV_FIXED_POINT_SCALE: f32 = 0.0000152587890625;  // 1.0 / 65536.0

@compute @workgroup_size(128, 1, 1)
fn integrate(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= params.particleCount) {
    return;
  }

  // Read current state
  let oldVelX = velocityX[particleIdx];
  let oldVelY = velocityY[particleIdx];
  let oldPosX = positionX[particleIdx];
  let oldPosY = positionY[particleIdx];

  // Read velocity delta from fixed-point interleaved buffer
  let deltaVxFixed = velocityDeltaFixed[particleIdx * 2u];
  let deltaVyFixed = velocityDeltaFixed[particleIdx * 2u + 1u];
  let deltaVx = f32(deltaVxFixed) * INV_FIXED_POINT_SCALE;
  let deltaVy = f32(deltaVyFixed) * INV_FIXED_POINT_SCALE;

  // Apply velocity delta and friction
  // Matches physics_wasm.nim: vxActive[i] = (vxActive[i] + vxDelta[i]) * friction
  var newVelX = (oldVelX + deltaVx) * params.friction;
  var newVelY = (oldVelY + deltaVy) * params.friction;

  // Logarithmic velocity capping to reduce jank in high-activity areas
  // Soft cap: velocities above threshold are compressed logarithmically
  let speed = sqrt(newVelX * newVelX + newVelY * newVelY);
  let softCapThreshold = params.maxVelocity * 0.5;  // Start compressing at half max
  if (speed > softCapThreshold && speed > 0.0) {
    let excess = speed - softCapThreshold;
    // log(1 + x) gives smooth compression
    let compressedSpeed = softCapThreshold + log(1.0 + excess);
    // Cap at maxVelocity as hard limit
    let cappedSpeed = min(compressedSpeed, params.maxVelocity);
    let scale = cappedSpeed / speed;
    newVelX *= scale;
    newVelY *= scale;
  }

  // Update position
  // Matches physics_wasm.nim: let x = pxActive[i] + vxActive[i]
  var newPosX = oldPosX + newVelX;
  var newPosY = oldPosY + newVelY;

  // Toroidal wrap
  // Matches physics_wasm.nim toroidal wrapping
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

  // Write back (in-place)
  velocityX[particleIdx] = newVelX;
  velocityY[particleIdx] = newVelY;
  positionX[particleIdx] = newPosX;
  positionY[particleIdx] = newPosY;
}
