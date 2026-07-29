// =============================================================================
// GLOW SHADER - species-tinted halos with Gaussian falloff (AoS layout)
// =============================================================================
// Additive-blended halo pass, drawn in the present pass behind the trail
// blit. Reads the same particles/RenderParams/colors bindings as render.wgsl
// so the two pipelines can share one bind group. colors is read in the
// vertex stage only (binding 2 has vertex-only visibility) and the species
// tint is interpolated to the fragment.
// =============================================================================

//! import particle
//! import render_params
//! import camera_transform

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
@group(0) @binding(2) var<uniform> colors: array<vec4f, 6>;  // Species colors (vertex-only visibility)
// Binding 4, not 3: the bind group layout is SHARED with render.wgsl, where
// binding 3 is the field texture used for particle lighting. This shader does
// not read the field, but it cannot reuse its slot — the layout is one object
// and the numbering belongs to it, not to either shader individually.
@group(0) @binding(4) var<uniform> cam: Camera;              // Same view render.wgsl draws through

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) offset: vec2f,
  @location(1) densityVal: f32,
  @location(2) velocityNorm: f32,  // Normalized velocity magnitude [0,1]
  @location(3) tint: vec3f,        // Species color, interpolated to the fragment
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

// Curve constants are substituted by the bundler from shader_config.nim's
// TuningConstants (the TUNABLE_GLOW_ placeholder family). The halo radius
// scale, falloff exponent, and warmth ceiling are runtime uniforms instead
// (params.glowRadiusScale / glowFalloff / glowWarmth - user-facing sliders).

// VELOCITY → GLOW MAPPING
const VELOCITY_LOG_SCALE: f32 = {{TUNABLE_GLOW_VELOCITY_LOG_SCALE}};  // Lower = more room for slow velocities
const VELOCITY_BASE: f32 = {{TUNABLE_GLOW_VELOCITY_BASE}};            // Floor for stationary particles (< 1 = dimmer)

// DENSITY → GLOW MAPPING
const DENSITY_SCALE: f32 = {{TUNABLE_GLOW_DENSITY_SCALE}};
const DENSITY_MIN: f32 = {{TUNABLE_GLOW_DENSITY_MIN}};                // Sparse particles dim but visible
const DENSITY_MAX: f32 = {{TUNABLE_GLOW_DENSITY_MAX}};

// GAUSSIAN FALLOFF
const GLOW_DIVISOR: f32 = {{TUNABLE_GLOW_DIVISOR}};                   // Overall intensity scaling

// COLOR WARMTH (dense → warm, sparse → neutral; ceiling is params.glowWarmth)
const WARMTH_GREEN: f32 = {{TUNABLE_GLOW_WARMTH_GREEN}};
const WARMTH_BLUE: f32 = {{TUNABLE_GLOW_WARMTH_BLUE}};

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

  // Glow radius coupled to velocity, scaled by params.velocityGlowScale.
  // At velocityGlowScale=0 or velocity=0: radius = baseSize * glowRadiusScale.
  // At velocityGlowScale=1 and max velocity: 50% larger.
  let scale = params.resolution / params.worldSize;
  let baseRadius = params.baseSize * params.glowRadiusScale;
  let velocityBoost = velocityNorm * params.velocityGlowScale * 0.5;
  let glowRadius = baseRadius * (1.0 + velocityBoost);
  // Reaches clip space by the same path render.wgsl's offset takes, so glow
  // radius tracks particle size and trail length rather than drifting out of
  // step with them — all three move together or none does.
  let worldOffset = offset * glowRadius / scale;

  // Species tint (colors has vertex-only visibility; interpolate to fragment)
  let speciesIndex = min(p.species, MAX_SPECIES - 1u);
  output.tint = colors[speciesIndex].rgb;

  // Through the camera, at the particle's nearest toroidal image — the image
  // chosen from the centre, exactly as render.wgsl does it. If these two
  // shaders disagreed about which image a particle occupies, its glow would
  // detach and appear on the far side of the world.
  let normalizedPos = cameraToClip(p.pos, cam, params.worldSize) +
    cameraOffsetToClip(worldOffset, cam, params.worldSize);

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

  // Density factor: high density = more glow. glowDensityFloor would lift it to
  // a minimum where density is unavailable; forces.wgsl is world-intrinsic and
  // accumulates colony density on every frame, so webgpu_render writes the floor
  // at 0 and this max is inert.
  let rawDensityFactor = clamp(input.densityVal * DENSITY_SCALE, DENSITY_MIN, DENSITY_MAX);
  let densityFactor = max(rawDensityFactor, params.glowDensityFloor);

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
  let gauss = exp(-params.glowFalloff * l * l);
  let alpha = gauss * circleMask * params.glowIntensity * densityFactor * velocityFactor / GLOW_DIVISOR;

  // Color: the species tint carries the halo. Fast particles bleach toward
  // white; dense particles warm-shift (attenuating green/blue) up to the
  // params.glowWarmth ceiling.
  let whitened = mix(input.tint, vec3f(1.0, 1.0, 1.0), input.velocityNorm);
  let warmth = densityFactor * params.glowWarmth;
  let warmShift = vec3f(1.0, 1.0 - warmth * WARMTH_GREEN, 1.0 - warmth * WARMTH_BLUE);
  return vec4f(whitened * warmShift * alpha, alpha);
}
