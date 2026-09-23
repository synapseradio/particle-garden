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
//! import integration_params

@group(0) @binding(0) var<uniform> params: IntegrationParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
@group(0) @binding(2) var<storage, read> velocityDeltaFixed: array<i32>;
@group(0) @binding(3) var<storage, read> densityDeltaFixed: array<i32>;
@group(0) @binding(4) var<storage, read> sphDensityDeltaFixed: array<i32>;
// Stride 5 per particle: [crowd, stiffnessFine, stiffnessCoarse, cFine,
// cCoarse]. See forces.wgsl's binding 7 for what each word carries.
@group(0) @binding(5) var<storage, read> crowdDensityDeltaFixed: array<i32>;
@group(0) @binding(6) var<storage, read> velocityCoarseFixed: array<i32>;

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
    f32(crowdDensityDeltaFixed[particleIdx * 5u]) * CROWD_DENSITY_INV_FIXED_POINT_SCALE;
  let crowdDensityMax = max(deltaCrowdDensity, p.crowdDensity);
  p.crowdDensity = p.crowdDensity * params.densityCarry +
    deltaCrowdDensity * (1.0 - params.densityCarry);

  // This particle's summed pair stiffness D, decoded from the crowd buffer's
  // two stiffness words the way the velocity words are rejoined above. s_D
  // is 1 unless one step would carry frameFactor * 2 * forceGain * D past
  // params.stepBound (B, D4's long-step bound, folded in on the host).
  // Mirrored by physics_core.stepLimit.
  let stiffness = (f32(crowdDensityDeltaFixed[particleIdx * 5u + 1u]) +
    f32(crowdDensityDeltaFixed[particleIdx * 5u + 2u]) * STIFFNESS_COARSE_UNIT) *
    STIFFNESS_INV_FIXED_POINT_SCALE;
  let stiffnessReach = 2.0 * params.frameFactor * params.forceGain * stiffness;
  let stepLimit = select(1.0, params.stepBound / stiffnessReach,
    stiffnessReach > params.stepBound);

  // The density-lag loop's own source C, decoded from the crowd buffer's two
  // loop words. s_C is 1 unless the loop's reach per substep, ff*h*C/rho,
  // would carry the loop past its stable gain theta_c, where it falls to
  // theta_c/reach or params.loopFloor, whichever holds more (design.md D5).
  // Mirrored by physics_core.loopLimit, minus its internal theta_c and alpha
  // (both folded into params.loopGainBound on the host).
  let loopPairSum = (f32(crowdDensityDeltaFixed[particleIdx * 5u + 3u]) +
    f32(crowdDensityDeltaFixed[particleIdx * 5u + 4u]) * STIFFNESS_COARSE_UNIT) *
    STIFFNESS_INV_FIXED_POINT_SCALE;
  // C raised to D5's mean-field floor, rho_max the larger of the raw and the
  // lagged crowd density. Mirrored by physics_core.crowdLoopMeanField.
  let onset = params.pressureOnset;
  let crowdSlope = 2.0 * max(crowdDensityMax - onset, 0.0) / (onset * onset);
  let loopMeanField = params.loopMeanFieldGain *
    crowdDensityMax * crowdDensityMax * crowdSlope;
  let loopSource = max(loopPairSum, loopMeanField);
  let loopReach = params.frameFactor * params.forceGain * loopSource /
    params.friction;
  let loopLimit = select(
    max(params.loopGainBound / loopReach, params.loopFloor),
    1.0,
    loopReach <= params.loopGainBound);

  // D1's s: the smaller of the two limits, applied to the whole velocity
  // below, carried term included.
  let s = min(stepLimit, loopLimit);

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
  // (params.friction) and h its force gain. s, the smaller of the two
  // limits, scales the carried velocity too, or a limited particle coasts
  // through the crowd.
  var newVelX = s * (params.friction * p.vel.x + params.forceGain * deltaVx);
  var newVelY = s * (params.friction * p.vel.y + params.forceGain * deltaVy);

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
