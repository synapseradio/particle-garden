// =============================================================================
// INTEGRATE: Apply Velocity/Density Deltas and Update Positions (Pass 5 - AoS)
// =============================================================================
//
// WHY THIS EXISTS:
// Final integration step - applies all changes computed by the forces pass:
// - Velocity deltas (from every velocity writer, per reference frame)
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
// params.densityCarry sets the exponential-moving-average blend, raised to
// this substep's frame factor on the host (D3).
// =============================================================================

//! import particle
//! import fixed_point

struct IntegrationParams {
  worldWidth: f32,       // World width (offset 0)
  worldHeight: f32,      // World height (offset 4)
  friction: f32,         // The clock's retention, rho = r^ff (offset 8)
  maxVelocity: f32,      // Maximum velocity (offset 12)
  particleCount: u32,    // Active particle count (offset 16)
  frameFactor: f32,      // The substep as a multiple of the reference frame (offset 20)
  forceGain: f32,        // The clock's force gain, h (offset 24)
  stepBound: f32,        // B; unread until the loop term lands (offset 28)
  densityCarry: f32,     // alpha = densitySmoothFactor^ff (offset 32)
  loopGainBound: f32,    // theta_c; unread until the loop term lands (offset 36)
  loopFloor: f32,        // the loop's floor; unread until it lands (offset 40)
  pad0: u32,             // Padding (offset 44)
};

@group(0) @binding(0) var<uniform> params: IntegrationParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
@group(0) @binding(2) var<storage, read> velocityDeltaFixed: array<i32>;
@group(0) @binding(3) var<storage, read> densityDeltaFixed: array<i32>;
@group(0) @binding(4) var<storage, read> sphDensityDeltaFixed: array<i32>;
// Stride 3 per particle: [crowd, stiffnessFine, stiffnessCoarse]. See
// forces.wgsl's binding 7 for what each word carries.
@group(0) @binding(5) var<storage, read> crowdDensityDeltaFixed: array<i32>;
@group(0) @binding(6) var<storage, read> velocityCoarseFixed: array<i32>;

const PRESSURE_STEP_BOUND: f32 = {{PRESSURE_STEP_BOUND}};

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn integrate(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= params.particleCount) {
    return;
  }

  var p = particles[particleIdx];

  // Both words rejoined into the delta per reference frame, D1's Delta: every
  // writer accumulates at that unit, and the clock's force gain below is the
  // one place ff enters the velocity.
  let deltaVx = (f32(velocityDeltaFixed[particleIdx * 2u]) +
    f32(velocityCoarseFixed[particleIdx * 2u]) * VELOCITY_COARSE_UNIT) *
    INV_FIXED_POINT_SCALE;
  let deltaVy = (f32(velocityDeltaFixed[particleIdx * 2u + 1u]) +
    f32(velocityCoarseFixed[particleIdx * 2u + 1u]) * VELOCITY_COARSE_UNIT) *
    INV_FIXED_POINT_SCALE;

  let deltaDensityFixed = densityDeltaFixed[particleIdx];
  let deltaDensity = f32(deltaDensityFixed) * INV_FIXED_POINT_SCALE;

  let smoothedDensity = p.density * params.densityCarry + deltaDensity * (1.0 - params.densityCarry);
  p.density = smoothedDensity;

  // Crowd density, resolved exactly the way colony density is: same weight, same
  // smoothing, decoded at its own scale (fixed_point.wgsl says why a neighbour
  // count cannot share the velocity scale). Smoothed rather than raw, because
  // the crowding cap reading a flickering density would make the force law
  // flicker with it — the opposite of what a cap is for.
  let deltaCrowdDensity =
    f32(crowdDensityDeltaFixed[particleIdx * 3u]) * CROWD_DENSITY_INV_FIXED_POINT_SCALE;
  p.crowdDensity = p.crowdDensity * params.densityCarry +
    deltaCrowdDensity * (1.0 - params.densityCarry);

  // This particle's summed pair stiffness D, decoded from the crowd buffer's
  // two stiffness words the way the velocity words are rejoined above. The
  // factor the whole decoded delta is scaled by below: 1 unless one step
  // would carry frameFactor * 2 * forceGain * D past PRESSURE_STEP_BOUND.
  // Mirrored by physics_core.stepLimit.
  let stiffness = (f32(crowdDensityDeltaFixed[particleIdx * 3u + 1u]) +
    f32(crowdDensityDeltaFixed[particleIdx * 3u + 2u]) * STIFFNESS_COARSE_UNIT) *
    STIFFNESS_INV_FIXED_POINT_SCALE;
  let stiffnessReach = 2.0 * params.frameFactor * params.forceGain * stiffness;
  let stepLimit = select(1.0, PRESSURE_STEP_BOUND / stiffnessReach,
    stiffnessReach > PRESSURE_STEP_BOUND);

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

  // D1: newVel = s . (rho . vel + h . delta), rho the clock's retention
  // (params.friction) and h its force gain. The step limit scales the
  // carried velocity too, or a limited particle coasts through the crowd.
  var newVelX = stepLimit * (params.friction * p.vel.x + params.forceGain * deltaVx);
  var newVelY = stepLimit * (params.friction * p.vel.y + params.forceGain * deltaVy);

  // Logarithmic velocity capping reduces jank in high-activity areas.
  //
  // The cap bounds travel per reference frame; newVel already carries that
  // unit (D1), so the curve acts on the speed directly, with no frame-factor
  // rescale either side.
  // Mirrored by physics_core.integrateVelocityFromDelta.
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

  // D1: x' = x + ff . u'. The stored velocity is travel per reference frame;
  // a substep spanning frameFactor of them moves the particle that many.
  var newPosX = p.pos.x + params.frameFactor * newVelX;
  var newPosY = p.pos.y + params.frameFactor * newVelY;

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
