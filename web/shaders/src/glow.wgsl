// =============================================================================
// GLOW SHADER - larger particles with Gaussian falloff (AoS layout)
// =============================================================================
// Additive-blended halo pass, drawn in the present pass behind the trail
// blit. Reads the same particles/RenderParams/colors bindings as render.wgsl
// (colors is bound but unused here - required for the shared bind group
// layout) so the two pipelines can share one bind group.
// =============================================================================

//! import particle
//! import render_params

const OFFSETS = array<vec2f, 6>(
  vec2f(-1.0, -1.0),
  vec2f( 1.0, -1.0),
  vec2f(-1.0,  1.0),
  vec2f(-1.0,  1.0),
  vec2f( 1.0, -1.0),
  vec2f( 1.0,  1.0),
);

// AoS particle buffer
@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(0) @binding(1) var<uniform> params: RenderParams;
@group(0) @binding(2) var<uniform> colors: array<vec4f, 6>;  // Unused by glow, required for shared layout

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) offset: vec2f,
  @location(1) densityVal: f32,
  @location(2) velocityNorm: f32,  // Normalized velocity magnitude [0,1]
};

// ==========================================================================
// GLOW TUNING CONSTANTS
// ==========================================================================
//
// Particles exist on two axes: community (density) and motion (velocity).
//
//                     slow ←── VELOCITY ──→ fast
//                       │
//          sparse       │   DARK          DIM WHITE
//             ↑         │   lonely        lone wanderer
//    DENSITY  │         │
//             ↓         │   WARM          BRIGHT WHITE
//          dense        │   settled       community in motion
//
// ==========================================================================

// VELOCITY → GLOW MAPPING
const VELOCITY_LOG_SCALE: f32 = 5.0;  // Lower = more room for slow velocities
const VELOCITY_BASE: f32 = 0.5;       // Floor for stationary particles (< 1 = dimmer)

// DENSITY → GLOW MAPPING
const DENSITY_SCALE: f32 = 0.15;
const DENSITY_MIN: f32 = 0.05;        // Sparse particles dim but visible
const DENSITY_MAX: f32 = 1.0;

// GAUSSIAN FALLOFF
const GLOW_FALLOFF: f32 = 6.0;        // Higher = tighter halo
const GLOW_DIVISOR: f32 = 24.0;       // Overall intensity scaling

// COLOR WARMTH (dense → warm orange, sparse → neutral)
const WARMTH_MAX: f32 = 0.4;
const WARMTH_GREEN: f32 = 0.3;
const WARMTH_BLUE: f32 = 0.6;

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;
  let particleId = id / 6u;
  let cornerId = id % 6u;

  // Read particle data from AoS buffer
  let p = particles[particleId];
  let offset = OFFSETS[cornerId];

  // Compute normalized velocity BEFORE using it for radius
  let speed = length(p.vel);
  let velocityNorm = clamp(speed / max(params.maxVelocity, 0.0001), 0.0, 1.0);
  output.velocityNorm = velocityNorm;

  // Glow radius coupled to velocity and sweep
  // At sweep=0 or velocity=0: radius = 12.0
  // At sweep=1 and max velocity: radius = 18.0 (50% boost)
  let scale = params.resolution / params.worldSize;
  let baseRadius = 12.0;
  let velocityBoost = velocityNorm * params.velocityGlowScale * 0.5;
  let glowRadius = baseRadius * (1.0 + velocityBoost);
  let worldPos = p.pos + offset * glowRadius / scale;

  let normalizedPos = (worldPos / params.worldSize) * 2.0 - 1.0;

  // Z-ordering: FAST particles go BEHIND (higher Z), SLOW in front (lower Z)
  // Position hash prevents z-fighting between similar particles
  let posHash = fract(sin(dot(p.pos, vec2f(12.9898, 78.233))) * 43758.5453);
  let velZ = velocityNorm * 0.8;  // Fast = 0.8, slow = 0
  let densityZ = clamp(p.density * 0.1, 0.0, 0.19);
  let zDepth = clamp(velZ + densityZ + posHash * 0.001, 0.01, 0.99);
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, zDepth, 1.0);
  output.offset = offset;
  output.densityVal = p.density;

  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let l = length(input.offset);

  // Crisp circular edge: anti-alias the disc boundary with a one-pixel smoothstep,
  // then discard everything outside the unit circle so the square billboard never
  // shows. fwidth is computed before the discard so the derivative stays defined
  // under uniform control flow.
  let edge = fwidth(l);
  let circleMask = 1.0 - smoothstep(1.0 - edge, 1.0, l);
  if (l > 1.0) {
    discard;
  }

  // Density factor: high density = more glow
  let densityFactor = clamp(input.densityVal * DENSITY_SCALE, DENSITY_MIN, DENSITY_MAX);

  // Velocity factor: stationary = dim (VELOCITY_BASE), moving = bright
  //
  // QUADRATIC COUPLING — velocity contribution grows as glow²:
  //
  //   glow=1     glow=2       glow=3          velocity contribution
  //    ┌─┐       ┌───┐       ┌─────┐          is the AREA of the
  //    └─┘       │   │       │     │          square, not just
  //     1        └───┘       │     │          the side length.
  //                4         └─────┘
  //                             9
  //
  //   Turning up glow makes velocity differences more visible.
  //
  let logVel = log(1.0 + input.velocityNorm * VELOCITY_LOG_SCALE) / log(1.0 + VELOCITY_LOG_SCALE);
  let velocityFactor = VELOCITY_BASE + logVel * (1.0 - VELOCITY_BASE + params.velocityGlowScale * params.glowIntensity);

  // Gaussian falloff gives the soft interior gradient; the circle mask gives the
  // crisp anti-aliased disc edge so nothing renders outside the circular boundary.
  let gauss = exp(-GLOW_FALLOFF * l * l);
  let alpha = gauss * circleMask * params.glowIntensity * densityFactor * velocityFactor / GLOW_DIVISOR;

  // Color shift: dense particles glow warm, fast particles glow white
  let warmth = densityFactor * WARMTH_MAX;
  let r = alpha;
  let g = alpha * (1.0 - warmth * WARMTH_GREEN);
  let b = alpha * (1.0 - warmth * WARMTH_BLUE);
  return vec4f(r, g, b, alpha);
}
