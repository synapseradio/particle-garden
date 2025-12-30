/**
 * Particle Render Shader - WebGPU Vertex Pulling
 *
 * Based on lisyarus's approach: https://lisyarus.github.io/blog/posts/particle-life-simulation-in-browser-using-webgpu.html
 *
 * Key insight: Use vertex_index / 6 to get particle ID, vertex_index % 6 for quad corner.
 * No instancing needed - just draw(6 * particleCount) vertices.
 *
 * BINDING MANIFEST:
 * ┌─────────┬──────────────────────────┬─────────────────┬────────┐
 * │ Binding │ Shader Type              │ Buffer          │ Access │
 * ├─────────┼──────────────────────────┼─────────────────┼────────┤
 * │ 0       │ storage array<f32>       │ px (positions)  │ read   │
 * │ 1       │ storage array<f32>       │ py (positions)  │ read   │
 * │ 2       │ storage array<u32>       │ species         │ read   │
 * │ 3       │ storage array<f32>       │ density         │ read   │
 * │ 4       │ uniform RenderParams     │ renderParams    │ read   │
 * └─────────┴──────────────────────────┴─────────────────┴────────┘
 */

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
// Unit quad: corners at distance sqrt(2) ≈ 1.41 from center
const OFFSETS = array<vec2f, 6>(
  vec2f(-1.0, -1.0),  // 0: bottom-left
  vec2f( 1.0, -1.0),  // 1: bottom-right
  vec2f(-1.0,  1.0),  // 2: top-left
  vec2f(-1.0,  1.0),  // 3: top-left
  vec2f( 1.0, -1.0),  // 4: bottom-right
  vec2f( 1.0,  1.0),  // 5: top-right
);

// Density-based sizing: particles shrink in crowded areas
// sizeMod = max(1.0, MAX_SIZE_MULTIPLIER - density * DENSITY_SIZE_SCALE)
const DENSITY_SIZE_SCALE: f32 = 0.4;       // How much density reduces size
const MAX_SIZE_MULTIPLIER: f32 = 3.2;      // Size multiplier at zero density

// Particle data buffers (shared with compute shaders)
@group(0) @binding(0) var<storage, read> px: array<f32>;
@group(0) @binding(1) var<storage, read> py: array<f32>;
@group(0) @binding(2) var<storage, read> species: array<u32>;
@group(0) @binding(3) var<storage, read> density: array<f32>;
@group(0) @binding(4) var<uniform> params: RenderParams;

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

  // Read particle data from storage buffers
  let particleX = px[particleId];
  let particleY = py[particleId];
  let particleSpecies = species[particleId];
  let particleDensity = density[particleId];

  // Get quad corner offset (unit quad, -1 to 1)
  let offset = OFFSETS[cornerId];

  // Calculate point size based on density
  let sizeMod = max(1.0, MAX_SIZE_MULTIPLIER - particleDensity * DENSITY_SIZE_SCALE);
  let pointSize = params.baseSize * sizeMod;

  // Scale offset by half point size to get world position
  // offset is -1 to 1, so multiply by halfSize to get pixel offset
  // Scale point size by canvas/world ratio to maintain visual size
  let scale = params.resolution / params.worldSize;
  let halfSize = pointSize * 0.5;
  let worldPos = vec2f(particleX, particleY) + offset * halfSize / scale;

  // Transform to clip space: world coords -> normalized device coords
  // World (0,0) maps to clip (-1,1), World (worldW, worldH) maps to clip (1,-1)
  let normalizedPos = (worldPos / params.worldSize) * 2.0 - 1.0;
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, 0.0, 1.0);

  // Pass offset for circle calculation in fragment shader
  // Scale offset by glowScale so fragment shader sees normalized -1 to 1 range
  output.offset = offset;

  // Pass density for glow intensity calculation
  output.density = particleDensity;

  // Look up species color
  let speciesIdx = min(particleSpecies, 5u);
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

  let alpha = 1.0 - smoothstep(0.7, 1.0, dist);
  return vec4f(input.color.rgb, alpha);
}
