// =============================================================================
// BODY FORCE: what the bodies do to the particles
// =============================================================================
//
// WHY THIS EXISTS:
// A body is an invisible shape with a surface. This pass gives every particle a
// velocity impulse from every living body: a pull toward the surface inside a
// band around it, and a hold across it. Nothing here draws anything — the crowd
// moving around a shape is the whole of what a body looks like.
//
// ONE EVALUATION, TWO FORCES. The signed distance and the surface normal come
// out of one evaluation per body per particle, and both force laws read that
// one result. src/body_core.nim is the oracle this mirrors; tests/test_body_core.nim
// holds the sign, the symmetry and the isotropic closed form it must agree with.
//
// THE DISTANCE IS ANISOTROPIC AND LIPSCHITZ-CORRECTED. Dividing by the two
// semi-axes maps the ellipse to a unit circle; multiplying the unit circle's
// distance by the SMALLER semi-axis brings it back as a lower bound on the true
// distance rather than an overestimate. Nothing here reads an absolute distance
// — the laws read the sign, the direction and the ordering, all of which that
// scaling leaves exact.
//
// TWO CLOCKS, AND THE STRENGTH CARRIES ONE. The impulse is measured in reference
// frames, so the substep's frame factor multiplies it here (params.frames), the
// way field-force receives a scale with the frame already folded in. The other
// clock, seconds, belongs to travel and is body-integrate's business.
//
// TWO ACCUMULATORS, ONE EVALUATION. The impulse goes to the particle and its
// negation, with the torque it carries about the body's centre, goes to the
// body's own words in sbBodyAccum. body-integrate reads those without
// resetting them; the frame owns the clear.
//
// INDEXING + OUTPUT:
// Reads particles[] and writes velocityDeltaFixed[] in ORIGINAL index space
// (globalId.x) — the space integrate.wgsl reads back. Contributions ACCUMULATE
// atomically, because forces, the fluid and the field write the same buffer and
// integrate must see the sum; the frame clears it once before any of them
// (sim_registry.buildFrame). A bodies-only world runs no bin-scatter, so the
// sorted buffer is stale and never referenced here.
// =============================================================================

//! import particle
//! import fixed_point
//! import grid_params
//! import body
//! import body_params

@group(0) @binding(0) var<uniform> grid: GridParams;
@group(0) @binding(1) var<storage, read> particles: array<Particle>;
@group(0) @binding(2) var<storage, read> bodies: array<Body>;
@group(0) @binding(3) var<storage, read> envelope: array<f32>;
@group(0) @binding(4) var<storage, read_write> velocityDeltaFixed: array<atomic<i32>>;
@group(0) @binding(5) var<uniform> params: BodyParams;
@group(0) @binding(6) var<storage, read_write> bodyAccum: array<atomic<i32>>;

// The shortest displacement across a torus. A body's reach is not bounded by a
// grid cell, so this takes the full extent rather than the half-size form
// camera_transform's note describes.
fn bodyMinimumImage(delta: f32, size: f32) -> f32 {
  let half = size * 0.5;
  if (delta > half) {
    return delta - size;
  }
  if (delta < -half) {
    return delta + size;
  }
  return delta;
}

@compute @workgroup_size({{WORKGROUP_SIZE}}, 1, 1)
fn applyBodyForce(@builtin(global_invocation_id) globalId: vec3<u32>) {
  let particleIdx = globalId.x;

  if (particleIdx >= grid.particleCount) {
    return;
  }

  let position = particles[particleIdx].pos;
  let world = vec2<f32>(params.worldW, params.worldH);
  // The slider's own value times the substep's share of a frame.
  let strength = params.strength * params.frames;

  var total = vec2<f32>(0.0, 0.0);

  for (var slot = 0u; slot < params.count; slot = slot + 1u) {
    let presence = envelope[slot];
    // Zero is an ordinary value of the envelope and no threshold is compared
    // against it: a free slot and an expired body both carry exactly zero, and
    // a living body contributes whatever it says, however small.
    if (presence == 0.0) {
      continue;
    }

    let body = bodies[slot];
    let toPoint = vec2<f32>(
      bodyMinimumImage(position.x - body.centerX, world.x),
      bodyMinimumImage(position.y - body.centerY, world.y));
    let cosA = cos(body.angle);
    let sinA = sin(body.angle);
    // rot(-angle): into the body's own frame.
    let local = vec2<f32>(
      toPoint.x * cosA + toPoint.y * sinA,
      -toPoint.x * sinA + toPoint.y * cosA);

    let semiX = body.radius;
    let semiY = body.radius * body.anisotropy;
    let unit = vec2<f32>(local.x / semiX, local.y / semiY);
    let unitLength = length(unit);
    let smaller = min(semiX, semiY);
    let distance = (unitLength - 1.0) * smaller;

    // Dividing a second time by each semi-axis is what tilts the normal away
    // from the radius on an ellipse.
    var gradient = vec2<f32>(unit.x / semiX, unit.y / semiY);
    let gradientLength = length(gradient);
    if (gradientLength > 0.0) {
      gradient = gradient / gradientLength;
    } else {
      // Dead centre: no direction is outward. Any unit vector keeps this
      // finite, where a normalize would hand every later term a NaN.
      gradient = vec2<f32>(1.0, 0.0);
    }
    let normal = vec2<f32>(
      gradient.x * cosA - gradient.y * sinA,
      gradient.x * sinA + gradient.y * cosA);

    let spanned = abs(distance) / body.bandWidth;
    // PROXIMITY acts inside the band and pulls toward the surface from either
    // side, easing to zero with zero slope at the band's edge, so a particle
    // drifting across that edge feels neither a step nor a corner.
    let towardSurface = -sign(distance) * body.proximity *
      smoothstep(0.0, 1.0, 1.0 - spanned);
    // ENCLOSURE is one signed strength read against the distance's sign:
    // positive acts on what is outside and pushes it in, negative acts on what
    // is inside and pushes it out. It rises to full at the band's edge and
    // falls to exactly zero at twice the band, with zero slope at the surface,
    // the edge and the reach's end; past that a body hands a particle nothing.
    let actingSide = select(0.0, 1.0, distance * sign(body.enclosure) >= 0.0);
    let holding = -body.enclosure * actingSide *
      smoothstep(0.0, 1.0, 1.0 - abs(spanned - 1.0));

    let contribution = normal * (towardSurface + holding) * presence * strength;
    total = total + contribution;

    // EQUAL AND OPPOSITE, before any damping or cap: the reaction is the
    // negation of what the particle just received, so this pass cannot give a
    // push the body does not feel. The lever arm is the same minimum-image
    // displacement the force was evaluated over, which is what makes the torque
    // finite on a torus.
    let reaction = -contribution;
    atomicAdd(&bodyAccum[slot * 3u],
      i32(reaction.x * params.forceScale));
    atomicAdd(&bodyAccum[slot * 3u + 1u],
      i32(reaction.y * params.forceScale));
    atomicAdd(&bodyAccum[slot * 3u + 2u],
      i32((toPoint.x * reaction.y - toPoint.y * reaction.x) *
        params.torqueScale));
  }

  // ACCUMULATE, never overwrite: three other passes write this buffer and
  // integrate must see the sum of all of them.
  atomicAdd(&velocityDeltaFixed[particleIdx * 2u],
    i32(total.x * FIXED_POINT_SCALE));
  atomicAdd(&velocityDeltaFixed[particleIdx * 2u + 1u],
    i32(total.y * FIXED_POINT_SCALE));
}
