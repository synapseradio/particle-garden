// =============================================================================
// INTEGRATE: Apply Velocity/Density Deltas and Update Positions (Pass 5 - AoS)
// =============================================================================
//
// WHY THIS EXISTS:
// Final integration step - applies all changes computed by the forces pass:
// - Velocity deltas (from inter-particle forces and mouse interaction)
// - Density deltas (symmetric accumulation from half-neighbor pairs)
// - Position updates (velocity integration with toroidal wrapping)
//
// WHY DENSITY IS HERE (not in forces):
// Forces pass uses half-neighbor iteration - each pair processed once.
// Both particles in a pair receive density via atomics (fixed-point i32).
// This shader converts the accumulated fixed-point values back to float,
// applies temporal smoothing, and writes the final density to particle.
//
// TEMPORAL SMOOTHING:
// Raw density can flicker frame-to-frame as particles move in/out of range.
// We use exponential moving average: 70% previous + 30% new.
// Think of it like your eyes adjusting to light - smooth transitions.
//
// ALGORITHM:
// 1. Read particle from ORIGINAL buffer (in-place update)
// 2. Read velocity delta (fixed-point i32 pair) → convert to float
// 3. Read density delta (fixed-point i32) → convert to float
// 4. Apply velocity delta with friction
// 5. Apply velocity capping (logarithmic soft cap)
// 6. Apply density temporal smoothing
// 7. Update position: newPos = oldPos + newVel
// 8. Apply toroidal wrapping
// 9. Write updated particle back (in-place)
//
// BINDING MANIFEST:
// +-------+---------------------------+-------------------+--------+
// | Bind  | Shader Type               | JS Buffer         | Access |
// +-------+---------------------------+-------------------+--------+
// |   0   | uniform IntegrationParams | integrationParams | read   |
// |   1   | storage array<Particle>   | particles         | r/w    |
// |   2   | storage array<i32>        | velocityDelta     | read   |
// |   3   | storage array<i32>        | densityDelta      | read   |
// +-------+---------------------------+-------------------+--------+
// TOTAL: 3 storage buffers (well under 8-buffer limit)
//
// THREAD MAPPING: One particle per thread (original index space)
// =============================================================================

//! import particle
//! import fixed_point

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
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
@group(0) @binding(2) var<storage, read> velocityDeltaFixed: array<i32>;
@group(0) @binding(3) var<storage, read> densityDeltaFixed: array<i32>;

const DENSITY_SMOOTH_FACTOR: f32 = 0.7;  // 70% old + 30% new for temporal smoothing

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn integrate(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= params.particleCount) {
    return;
  }

  // Read current particle state (AoS: all data in one read)
  var p = particles[particleIdx];

  // Read velocity delta from fixed-point interleaved buffer
  let deltaVxFixed = velocityDeltaFixed[particleIdx * 2u];
  let deltaVyFixed = velocityDeltaFixed[particleIdx * 2u + 1u];
  let deltaVx = f32(deltaVxFixed) * INV_FIXED_POINT_SCALE;
  let deltaVy = f32(deltaVyFixed) * INV_FIXED_POINT_SCALE;

  // Read density delta from fixed-point buffer (symmetric accumulation from forces)
  // Both particles in each pair received contributions via atomics
  let deltaDensityFixed = densityDeltaFixed[particleIdx];
  let deltaDensity = f32(deltaDensityFixed) * INV_FIXED_POINT_SCALE;

  // Apply density temporal smoothing
  // Prevents flickering as particles move in/out of interaction radius
  let smoothedDensity = p.density * DENSITY_SMOOTH_FACTOR + deltaDensity * (1.0 - DENSITY_SMOOTH_FACTOR);
  p.density = smoothedDensity;

  // Apply velocity delta and friction
  var newVelX = (p.vel.x + deltaVx) * params.friction;
  var newVelY = (p.vel.y + deltaVy) * params.friction;

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

  // Update velocity
  p.vel.x = newVelX;
  p.vel.y = newVelY;

  // Update position
  var newPosX = p.pos.x + newVelX;
  var newPosY = p.pos.y + newVelY;

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

  // Update position
  p.pos.x = newPosX;
  p.pos.y = newPosY;

  // Write back updated particle (AoS: all data in one write)
  particles[particleIdx] = p;
}
