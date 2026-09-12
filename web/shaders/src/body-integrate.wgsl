// =============================================================================
// BODY INTEGRATE: the crowd moves the body back
// =============================================================================
//
// WHY THIS EXISTS:
// body-force.wgsl gives every particle an impulse and folds the negation of
// each one into the body's own words. This pass turns that sum into motion:
// one thread per body, semi-implicit Euler, the same step integrate.wgsl takes
// for a particle. Without it a body is a fixed obstacle; with it a crowd can
// carry one, which is the whole of the feedback.
//
// src/body_core.nim's bodyRigidStep is the oracle this mirrors, and
// tests/test_body_core.nim's stability sweep is what warrants the three
// mechanisms below — the mass from the body's own area, the exponential
// damping, and the per-substep change caps.
//
// TWO CLOCKS, AND THEY ARE NOT THE SAME ONE. Position advances over
// params.dtSeconds, the substep's own timestep. Damping and the change caps run
// on params.frames, the substep as a multiple of the reference frame every
// force constant in this repository was measured in, so a body settles over the
// same wall clock at any frame rate and any substep count.
//
// THE ACCUMULATED REACTION IS AN IMPULSE, NOT A FORCE, so no timestep
// multiplies it here. body-force hands each particle a velocity impulse with
// the substep's frame already folded in and accumulates that impulse's
// negation; multiplying by a timestep again would make a frame's effect on a
// body scale as the square of the frame length over the substep count, which no
// substep count leaves invariant.
//
// THE ACCUMULATOR IS READ, NEVER RESET. The frame clears it, exactly as it
// clears velocityDelta, because one buffer with two reset owners loses whichever
// contribution ran first.
// =============================================================================

//! import body
//! import body_params

@group(0) @binding(0) var<storage, read_write> bodies: array<Body>;
@group(0) @binding(1) var<storage, read> envelope: array<f32>;
@group(0) @binding(2) var<storage, read> bodyAccum: array<i32>;
@group(0) @binding(3) var<uniform> params: BodyParams;

// Back onto the torus, matching body_core.wrapToTorus: a body leaving one edge
// arrives at the other, the way a particle does in integrate.wgsl.
fn wrapToTorus(position: f32, size: f32) -> f32 {
  var wrapped = position % size;
  if (wrapped < 0.0) {
    wrapped = wrapped + size;
  }
  return wrapped;
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn integrateBodies(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let slot = globalId.x;

  if (slot >= params.count) {
    return;
  }

  // A free slot and an expired body both read exactly zero presence, and
  // neither has a pose worth advancing: the record a slot holds after its body
  // ends is what the next ignition overwrites.
  if (envelope[slot] == 0.0) {
    return;
  }

  var body = bodies[slot];

  let force = vec2<f32>(
    f32(bodyAccum[slot * 3u]) / params.forceScale,
    f32(bodyAccum[slot * 3u + 1u]) / params.forceScale);
  let torque = f32(bodyAccum[slot * 3u + 2u]) / params.torqueScale;

  // The caps bound what ONE substep may do to one body, without bounding what a
  // player may ask for: a larger crowd still pushes harder, it just cannot
  // teleport the body it is pushing.
  var change = force * body.invMass;
  let allowance = params.maxSpeedChange * params.frames;
  let asked = length(change);
  if (asked > allowance) {
    change = change * allowance / asked;
  }
  let spinAllowance = params.maxSpinChange * params.frames;
  let changeSpin = clamp(torque * body.invInertia,
    -spinAllowance, spinAllowance);

  let velocity = (vec2<f32>(body.velX, body.velY) + change) *
    pow(params.linearDamping, params.frames);
  let spin = (body.angVel + changeSpin) *
    pow(params.angularDamping, params.frames);

  body.velX = velocity.x;
  body.velY = velocity.y;
  body.angVel = spin;
  body.centerX = wrapToTorus(body.centerX + velocity.x * params.dtSeconds,
    params.worldW);
  body.centerY = wrapToTorus(body.centerY + velocity.y * params.dtSeconds,
    params.worldH);
  body.angle = body.angle + spin * params.dtSeconds;

  bodies[slot] = body;
}
