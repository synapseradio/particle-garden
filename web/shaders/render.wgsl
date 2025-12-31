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

// AoS Particle struct: 32 bytes, cache-aligned
struct Particle {
  pos: vec2<f32>,    // offset 0, size 8
  vel: vec2<f32>,    // offset 8, size 8
  species: u32,      // offset 16, size 4
  density: f32,      // offset 20, size 4
  _pad0: u32,        // offset 24, size 4
  _pad1: u32,        // offset 28, size 4
}

struct RenderParams {
  resolution: vec2f,   // Canvas width, height in pixels
  worldSize: vec2f,    // World width, height (physics domain)
  baseSize: f32,       // Base particle size in pixels
  padding0: f32,
  padding1: f32,
  padding2: f32,
};

// Species colors (matches WebGL renderer COLORS array)
const COLORS = array<vec3f, 6>(
  vec3f(1.0, 0.4, 0.4),   // Species 0: Red
  vec3f(0.4, 1.0, 0.4),   // Species 1: Green
  vec3f(0.4, 0.7, 1.0),   // Species 2: Blue
  vec3f(1.0, 1.0, 0.4),   // Species 3: Yellow
  vec3f(1.0, 0.4, 1.0),   // Species 4: Magenta
  vec3f(0.4, 1.0, 1.0),   // Species 5: Cyan
);

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
const MIN_SIZE_MULTIPLIER: f32 = 0.5;      // Size multiplier at high density (floor)
const MAX_SIZE_MULTIPLIER: f32 = 2.0;      // Size multiplier at zero density (ceiling)

// AoS particle buffer
@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(0) @binding(1) var<uniform> params: RenderParams;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) color: vec4f,       // RGBA color with pre-multiplied alpha
  @location(1) offset: vec2f,      // Local offset from particle center (for circle calc)
  @location(2) density: f32,       // Local particle density for glow effect
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

  // Scale offset by half point size to get world position
  // offset is -1 to 1, so multiply by halfSize to get pixel offset
  // Scale point size by canvas/world ratio to maintain visual size
  let scale = params.resolution / params.worldSize;
  let halfSize = pointSize * 0.5;
  let worldPos = p.pos + cornerOffset * halfSize / scale;

  // Transform to clip space: world coords -> normalized device coords
  // World (0,0) maps to clip (-1,1), World (worldW, worldH) maps to clip (1,-1)
  let normalizedPos = (worldPos / params.worldSize) * 2.0 - 1.0;

  // Z-ordering: high density (small particles) = closer to camera (lower Z)
  // Low density (large particles) = further back (higher Z)
  // Position-based hash prevents Z-fighting between particles with similar density
  let posHash = fract(sin(dot(p.pos, vec2f(12.9898, 78.233))) * 43758.5453);
  let zDepth = 1.0 - clamp(p.density * 0.1 + posHash * 0.001, 0.0, 0.99);
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, zDepth, 1.0);

  // Pass offset for circle calculation in fragment shader
  // Scale offset by glowScale so fragment shader sees normalized -1 to 1 range
  output.offset = cornerOffset;

  // Pass density for glow intensity calculation
  output.density = p.density;

  // Look up species color
  let speciesIdx = min(p.species, 5u);
  output.color = vec4f(COLORS[speciesIdx], 1.0);

  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  let dist = length(input.offset);

  // Circle with soft edge (known working)
  if (dist > 1.0) {
    discard;
  }

  let alpha = 1.0 - smoothstep(0.9, 1.0, dist);
  return vec4f(input.color.rgb, alpha);
}
