// =============================================================================
// PARTICLE RENDER SHADER - WebGPU Vertex Pulling with AoS Layout
// =============================================================================
//
// Based on lisyarus's approach:
// https://lisyarus.github.io/blog/posts/particle-life-simulation-in-browser-using-webgpu.html
//
// Key insight: Use vertex_index / 6 to get particle ID, vertex_index % 6 for quad corner.
// No instancing needed - just draw(6 * particleCount) vertices.
//
// AoS BENEFIT:
// With AoS layout, we read all particle data (pos, vel, species, density) from
// one Particle struct instead of 4 separate buffer reads. This reduces binding
// count from 5 to 2 and improves cache locality.
//
// BINDING MANIFEST:
// +-------+---------------------------+-----------------+--------+
// | Bind  | Shader Type               | JS Buffer       | Access |
// +-------+---------------------------+-----------------+--------+
// |   0   | storage array<Particle>   | particles       | read   |
// |   1   | uniform RenderParams      | renderParams    | read   |
// +-------+---------------------------+-----------------+--------+
// =============================================================================

//! import particle

struct RenderParams {
  resolution: vec2f,       // Canvas width, height in pixels
  worldSize: vec2f,        // World width, height (physics domain)
  baseSize: f32,           // Base particle size in pixels
  glowIntensity: f32,      // Base glow multiplier (unused in main shader)
  velocityGlowScale: f32,  // 0=off, 1=full velocity influence (unused in main shader)
  maxVelocity: f32,        // For velocity normalization
  trailLengthScale: f32,   // Motion blur elongation factor (0 = no blur)
  _pad1: f32,
  _pad2: f32,
  _pad3: f32,
};

// Quad corner offsets (2 triangles = 6 vertices)
// Unit quad: corners at distance sqrt(2) from center
const OFFSETS = array<vec2f, 6>(
  vec2f(-1.0, -1.0),  // 0: bottom-left
  vec2f( 1.0, -1.0),  // 1: bottom-right
  vec2f(-1.0,  1.0),  // 2: top-left
  vec2f(-1.0,  1.0),  // 3: top-left
  vec2f( 1.0, -1.0),  // 4: bottom-right
  vec2f( 1.0,  1.0),  // 5: top-right
);

// Density-based sizing: particles shrink smoothly in crowded areas
// Uses exponential decay: sizeMod = MIN + (MAX-MIN) * exp(-density * DECAY_RATE)
// This avoids the hard floor that causes visual "snapping"
//
// SIZE_DECAY_RATE calibration:
// - Controls how quickly particles shrink as local density increases
// - Half-neighbor iteration produces ~50% of full 9-cell density values
// - Rate of 0.07 compensates: exp(-5 * 0.07) ~ 0.70 at "half density"
// - At density=0: sizeMod = MAX_SIZE_MULTIPLIER (3x base size)
// - As density->inf: sizeMod -> MIN_SIZE_MULTIPLIER (2x base size)
const SIZE_DECAY_RATE: f32 = 0.07;
const MIN_SIZE_MULTIPLIER: f32 = 0.7;      // Size multiplier at high density (floor)
const MAX_SIZE_MULTIPLIER: f32 = 1.3;      // Size multiplier at zero density (ceiling)

// Density-based brightness: lonely particles are dimmer
const BRIGHTNESS_GROWTH_RATE: f32 = 0.07;  // Mirrors SIZE_DECAY_RATE
const MIN_BRIGHTNESS: f32 = 0.44;          // Lonely particles at 44% brightness
const MAX_BRIGHTNESS: f32 = 1.0;           // Clustered particles at full brightness

// AoS particle buffer
@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(0) @binding(1) var<uniform> params: RenderParams;
@group(0) @binding(2) var<uniform> colors: array<vec4f, 6>;  // Species colors from config.nim

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) color: vec4f,       // RGBA color with pre-multiplied alpha
  @location(1) offset: vec2f,      // Local offset from particle center (for circle calc)
  @location(2) density: f32,       // Local particle density for glow effect
  @location(3) trailPos: f32,      // Position along trail: -1 (tail) to 1 (head)
};

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;

  // Particle index = vertex_index / 6, quad corner = vertex_index % 6
  let particleId = id / 6u;
  let cornerId = id % 6u;

  // Read particle data from AoS buffer (all data in one read!)
  let p = particles[particleId];

  // Get quad corner offset (unit quad, -1 to 1)
  let cornerOffset = OFFSETS[cornerId];

  // Calculate point size based on density using smooth exponential decay
  // At density=0: sizeMod = 3.0, as density->inf: sizeMod -> 1.3
  let sizeMod = MIN_SIZE_MULTIPLIER + (MAX_SIZE_MULTIPLIER - MIN_SIZE_MULTIPLIER) * exp(-p.density * SIZE_DECAY_RATE);
  let pointSize = params.baseSize * sizeMod;
  let halfSize = pointSize * 0.5;

  // Scale from world to screen space
  let scale = params.resolution / params.worldSize;

  // Motion blur: elongate quad in velocity direction
  let speed = length(p.vel);
  let hasMotion = speed > 0.001 && params.trailLengthScale > 0.0;

  // Compute velocity-aligned coordinate system
  let velDir = select(vec2f(1.0, 0.0), p.vel / speed, hasMotion);
  let velPerp = vec2f(-velDir.y, velDir.x);

  // Trail elongation: how far to extend the tail
  // Scales with velocity and trailLengthScale parameter
  let elongation = select(0.0, speed * params.trailLengthScale, hasMotion);

  // Transform corner offset from axis-aligned to velocity-aligned
  // cornerOffset.x: along velocity axis (positive = head, negative = tail)
  // cornerOffset.y: perpendicular to velocity
  var alongVel: f32;
  var trailPosVal: f32;

  if (cornerOffset.x < 0.0) {
    // Tail vertices: extend backward by elongation
    alongVel = cornerOffset.x * halfSize - elongation;
    // Normalize trail position: more negative = further back in trail
    let totalLength = halfSize + elongation;
    trailPosVal = alongVel / totalLength;  // Will be negative (tail end)
  } else {
    // Head vertices: stay at normal position
    alongVel = cornerOffset.x * halfSize;
    trailPosVal = 1.0;  // Head of trail
  }
  let acrossVel = cornerOffset.y * halfSize;

  // Compute world offset using velocity-aligned axes
  let worldOffset = (velDir * alongVel + velPerp * acrossVel) / scale;
  let worldPos = p.pos + worldOffset;

  // Transform to clip space: world coords -> normalized device coords
  // World (0,0) maps to clip (-1,1), World (worldW, worldH) maps to clip (1,-1)
  let normalizedPos = (worldPos / params.worldSize) * 2.0 - 1.0;

  // Z-ordering: Species-based layers with stable particle hash
  // Each species occupies its own depth band (0.1-0.9 divided into 6 bands)
  // Within a band, particle ID hash provides stable ordering (no flickering)
  let speciesBandSize = 0.8 / 6.0;  // ~0.133 per species
  let speciesBase = 0.1 + f32(p.species) * speciesBandSize;
  let particleHash = fract(f32(particleId) * 0.6180339887);  // Golden ratio hash
  let zDepth = speciesBase + particleHash * speciesBandSize * 0.9;  // Stay within band
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, zDepth, 1.0);

  // Pass offset for circle/capsule shape calculation in fragment shader
  // When elongated, we need to adjust offset to maintain circular ends
  output.offset = cornerOffset;

  // Pass trail position for tapered alpha (-1 = tail, 1 = head)
  output.trailPos = trailPosVal;

  // Pass density for glow intensity calculation
  output.density = p.density;

  // Look up species color from uniform buffer
  let speciesIdx = min(p.species, 5u);
  output.color = vec4f(colors[speciesIdx].rgb, 1.0);

  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  // Determine if this fragment is at the particle head or in the trail tail
  // trailPos = 1.0 at head, < 1.0 in tail region
  let isHead = input.trailPos > 0.99;

  // For head: use radial distance (circle shape)
  // For tail: use perpendicular distance (capsule/band shape)
  let dist = select(abs(input.offset.y), length(input.offset), isHead);

  // Screen-space anti-aliased edge
  let edge = fwidth(dist);
  var shapeAlpha = 1.0 - smoothstep(1.0 - edge, 1.0 + edge, dist);

  if (shapeAlpha <= 0.0) {
    discard;
  }

  // Trail taper: fade from head (1.0) to tail (0.0)
  // trailPos: 1 = head, negative = further back in tail
  // Map to 0-1 range and apply soft falloff
  let t = clamp((input.trailPos + 1.0) * 0.5, 0.0, 1.0);
  let tailFade = sqrt(t);  // Soft falloff curve: sqrt gives gentle fade

  // Combine shape alpha with trail taper
  let alpha = shapeAlpha * tailFade;

  if (alpha <= 0.0) {
    discard;
  }

  // Density-based brightness: lonely (low density) particles are dimmer
  let brightnessMod = MIN_BRIGHTNESS + (MAX_BRIGHTNESS - MIN_BRIGHTNESS) * (1.0 - exp(-input.density * BRIGHTNESS_GROWTH_RATE));

  return vec4f(input.color.rgb * brightnessMod, alpha);
}
