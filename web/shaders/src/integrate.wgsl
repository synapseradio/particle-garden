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
// DENSITY_SMOOTH_FACTOR below sets the exponential-moving-average blend.
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
@group(0) @binding(4) var<storage, read> sphDensityDeltaFixed: array<i32>;
@group(0) @binding(5) var<storage, read> crowdDensityDeltaFixed: array<i32>;

const DENSITY_SMOOTH_FACTOR: f32 = {{TUNABLE_DENSITY_SMOOTH_FACTOR}};  // 70% old + 30% new for temporal smoothing

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn integrate(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= params.particleCount) {
    return;
  }

  var p = particles[particleIdx];

  let deltaVxFixed = velocityDeltaFixed[particleIdx * 2u];
  let deltaVyFixed = velocityDeltaFixed[particleIdx * 2u + 1u];
  let deltaVx = f32(deltaVxFixed) * INV_FIXED_POINT_SCALE;
  let deltaVy = f32(deltaVyFixed) * INV_FIXED_POINT_SCALE;

  let deltaDensityFixed = densityDeltaFixed[particleIdx];
  let deltaDensity = f32(deltaDensityFixed) * INV_FIXED_POINT_SCALE;

  let smoothedDensity = p.density * DENSITY_SMOOTH_FACTOR + deltaDensity * (1.0 - DENSITY_SMOOTH_FACTOR);
  p.density = smoothedDensity;

  // Crowd density, resolved exactly the way colony density is: same weight, same
  // smoothing, decoded at its own scale (fixed_point.wgsl says why a neighbour
  // count cannot share the velocity scale). Smoothed rather than raw, because
  // the crowding cap reading a flickering density would make the force law
  // flicker with it — the opposite of what a cap is for.
  let deltaCrowdDensity =
    f32(crowdDensityDeltaFixed[particleIdx]) * CROWD_DENSITY_INV_FIXED_POINT_SCALE;
  p.crowdDensity = p.crowdDensity * DENSITY_SMOOTH_FACTOR +
    deltaCrowdDensity * (1.0 - DENSITY_SMOOTH_FACTOR);

  // The fluid's kernel density, resolved the same way but kept in its own
  // field. Unsmoothed: the Tait equation of state wants this frame's density,
  // and smoothing it lags the pressure behind the compression that caused it.
  //
  // Decoded at the DENSITY scale, not the velocity one. This is a neighbour
  // count reaching MAX_PARTICLES, so forces-sph.wgsl encodes it coarser to keep
  // the whole budget inside an i32; decoding it here with INV_FIXED_POINT_SCALE
  // would still produce a number, wrong by the ratio between the two scales.
  p.sphDensity =
    f32(sphDensityDeltaFixed[particleIdx]) * SPH_DENSITY_INV_FIXED_POINT_SCALE;

  var newVelX = (p.vel.x + deltaVx) * params.friction;
  var newVelY = (p.vel.y + deltaVy) * params.friction;

  // Logarithmic velocity capping reduces jank in high-activity areas.
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

  p.vel.x = newVelX;
  p.vel.y = newVelY;

  var newPosX = p.pos.x + newVelX;
  var newPosY = p.pos.y + newVelY;

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

  p.pos.x = newPosX;
  p.pos.y = newPosY;

  particles[particleIdx] = p;
}
