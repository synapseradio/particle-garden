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
// THE FIELD LIGHTS THE PARTICLES. Binding 3 is the reaction-diffusion field,
// read in the VERTEX stage at each particle's own cell, so a particle standing
// in a bright region of the pattern is lit by it. This is the one stage that
// can do that: the composite stages see the field per screen pixel, long after
// the particles have been coloured, so there they can only ever lie behind or
// in front of the particles rather than illuminate them.
//
// textureLoad, not textureSample: the vertex stage has no implicit derivatives,
// and the read is at an exact cell anyway. Binding 3 holds the bloom view as a
// stand-in while the field view is nil, because the layout declares an entry
// there either way.

//! import particle
//! import render_params
//! import colormap
//! import camera_transform
//! import field_grid

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
// - At density=0: sizeMod = MAX_SIZE_MULTIPLIER
// - As density->inf: sizeMod -> MIN_SIZE_MULTIPLIER
const SIZE_DECAY_RATE: f32 = 0.07;
// Substituted from camera_core.DENSITY_SIZE_FLOOR, which the visibility
// math reads; the two cannot drift.
const MIN_SIZE_MULTIPLIER: f32 = {{DENSITY_SIZE_FLOOR}};
const MAX_SIZE_MULTIPLIER: f32 = 1.3;

// Density-based brightness: lonely particles are dimmer
const BRIGHTNESS_GROWTH_RATE: f32 = 0.07;  // Mirrors SIZE_DECAY_RATE
const MIN_BRIGHTNESS: f32 = 0.44;          // Lonely particles at 44% brightness
const MAX_BRIGHTNESS: f32 = 1.0;           // Clustered particles at full brightness

@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(0) @binding(1) var<uniform> params: RenderParams;
// Sized from memory_layout.MAX_SPECIES by the bundler, not by hand: a WGSL
// out-of-range uniform read is clamped rather than trapped, so a short array
// would render the species past its end in the last species' colour silently.
@group(0) @binding(2) var<uniform> colors: array<vec4f, {{MAX_SPECIES}}>;
@group(0) @binding(3) var fieldTexture: texture_2d<f32>;     // RD field (activator, inhibitor)
@group(0) @binding(4) var<uniform> cam: Camera;              // View over the toroidal world

const FIELD_LIGHT_STRENGTH: f32 = {{FIELD_LIGHT_STRENGTH}};

// Tail length in particle radii at which the motion-blur taper reaches full
// depth. Substituted from trail_core.TRAIL_TAPER_FULL_ELONGATION, which
// tests/test_trail_core.nim measures; the two cannot drift.
const TAPER_FULL_ELONGATION: f32 = {{TRAIL_TAPER_FULL_ELONGATION}};

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) color: vec4f,       // RGBA color with pre-multiplied alpha
  @location(1) offset: vec2f,      // Local offset from particle center (for circle calc)
  @location(2) density: f32,       // Local particle density for glow effect
  @location(3) alongN: f32,        // Along-velocity position in radius units (capsule spine coord)
  @location(4) elongN: f32,        // Tail length in radius units (per-particle constant)
};

@vertex
fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
  var output: VertexOutput;

  let particleId = id / 6u;
  let cornerId = id % 6u;

  let p = particles[particleId];

  let cornerOffset = OFFSETS[cornerId];

  let sizeMod = MIN_SIZE_MULTIPLIER + (MAX_SIZE_MULTIPLIER - MIN_SIZE_MULTIPLIER) * exp(-p.density * SIZE_DECAY_RATE);
  let pointSize = params.baseSize * sizeMod;
  let halfSize = pointSize * 0.5;

  let scale = params.resolution / params.worldSize;

  let speed = length(p.vel);
  let hasMotion = speed > 0.001 && params.trailLengthScale > 0.0;

  let velDir = select(vec2f(1.0, 0.0), p.vel / speed, hasMotion);
  let velPerp = vec2f(-velDir.y, velDir.x);

  let elongation = select(0.0, speed * params.trailLengthScale, hasMotion);

  // Transform corner offset from axis-aligned to velocity-aligned
  // cornerOffset.x: along velocity axis (positive = head, negative = tail)
  // cornerOffset.y: perpendicular to velocity
  //
  // Tail vertices extend backward by the elongation; head vertices stay put.
  // The fragment reads the taper off the spine coordinates below, so nothing
  // here branches on whether the particle is moving.
  let alongVel = select(cornerOffset.x * halfSize,
                        cornerOffset.x * halfSize - elongation,
                        cornerOffset.x < 0.0);
  let acrossVel = cornerOffset.y * halfSize;

  // Compute world offset using velocity-aligned axes. Particle size and trail
  // length both reach clip space through this one offset, so they scale
  // together by construction rather than by a shared factor.
  let worldOffset = (velDir * alongVel + velPerp * acrossVel) / scale;

  // Transform to clip space through the camera, drawing the particle at its
  // nearest toroidal image so the world seam never shows.
  //
  // The image is chosen from the particle CENTRE and the corner offset added
  // afterwards. Wrapping the already-offset corner instead would tear a quad in
  // half whenever its particle sat near the half-world line.
  //
  // glow.wgsl computes this same pair from the same centre. The two must agree
  // on which image a particle occupies, or its glow detaches and lands on the
  // far side of the world.
  let normalizedPos = cameraToClip(p.pos, cam, params.worldSize) +
    cameraOffsetToClip(worldOffset, cam, params.worldSize);

  // Z-ordering: Species-based layers with stable particle hash
  // Each species occupies its own depth band (0.1-0.9 divided into MAX_SPECIES
  // bands). Within a band, particle ID hash provides stable ordering (no
  // flickering). Divided by the ceiling, not the live count, so a species'
  // depth band never moves when the count changes — and the top band stays
  // inside clip space at every count.
  let speciesBandSize = 0.8 / f32(MAX_SPECIES);
  let speciesBase = 0.1 + f32(p.species) * speciesBandSize;
  let particleHash = fract(f32(particleId) * 0.6180339887);  // Golden ratio hash
  let zDepth = speciesBase + particleHash * speciesBandSize * 0.9;  // Stay within band
  output.position = vec4f(normalizedPos.x, -normalizedPos.y, zDepth, 1.0);

  // When elongated, we need to adjust offset to maintain circular ends
  output.offset = cornerOffset;

  // Capsule spine coordinates in radius-normalized units (halfSize > 0 always).
  // alongN interpolates across the quad; elongN is a per-particle constant.
  output.alongN = alongVel / halfSize;
  output.elongN = elongation / halfSize;

  output.density = p.density;

  let speciesIdx = min(p.species, MAX_SPECIES - 1u);
  let speciesColor = colors[speciesIdx].rgb;

  // Light the particle by the field it is standing in. Sampled at the
  // particle's OWN position (p.pos, not the quad corner worldPos) so every
  // vertex of one particle agrees and the quad is lit as one thing rather than
  // gradient-shaded across itself.
  //
  // THE TINT DOES NOT READ fieldOpacity, and that is deliberate. fieldOpacity
  // scales the BACKDROP — the fullscreen layer field-composite.wgsl and the
  // tonemap draw under everything — and it ships at zero, because a backdrop
  // claims whole regions of the frame that colonies and trails then compete
  // with. Lighting the particles is how the field shows itself instead, so
  // gating this on the backdrop's scale would blind the particles the moment
  // the backdrop is turned off, which is its default state.
  //
  // No guard, for the same reason: the pull is already proportional to the
  // field's local intensity, and the field clears to Gray-Scott's trivial fixed
  // point where the inhibitor is 0. A particle standing where no pattern is
  // therefore gets a pull of 0 and mix returns its species colour untouched.
  let fieldCell = fieldCellFor(p.pos, params.worldSize);
  let fieldHere = textureLoad(fieldTexture, fieldCell, 0).xy;
  let colormapIndex = u32(params.colormapIndex + 0.5);
  let fieldPull = colormapFieldIntensity(colormapIndex, fieldHere.x, fieldHere.y) *
    FIELD_LIGHT_STRENGTH;
  let fieldTint = applyColormap(colormapIndex, fieldHere.x, fieldHere.y);
  let particleColor = mix(speciesColor, fieldTint, fieldPull);
  output.color = vec4f(particleColor, 1.0);

  return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
  // Capsule signed-distance: distance from the fragment to the nearest point on
  // the velocity-aligned spine, in radius-normalized units. The spine runs from
  // the head cap center (alongN = 0) back to the tail cap center
  // (alongN = -elongN). When elongN = 0 this reduces to length(offset) — a pure
  // unit circle — so still particles stay clean discs.
  let alongCoord = input.alongN - clamp(input.alongN, -input.elongN, 0.0);
  let capsuleDist = length(vec2f(alongCoord, input.offset.y));

  // Compute the derivative before any discard so it stays defined under uniform
  // control flow. The smoothstep softens the kept edge; the hard discard below
  // is what kills the square quad corners for small / sub-pixel particles.
  let edge = fwidth(capsuleDist);
  let shapeAlpha = 1.0 - smoothstep(1.0 - edge, 1.0, capsuleDist);

  if (capsuleDist > 1.0) {
    discard;
  }

  // Trail taper: the tail fades from head to tip, and its DEPTH grows with the
  // tail rather than switching on with it. Mirrors trail_core.trailTaperAlpha,
  // which tests/test_trail_core.nim measures; the pair is hand-maintained.
  //
  // Depth has to vanish with elongN. Speeds in a settled lattice oscillate
  // across zero, so a taper applied at full depth to any non-zero tail flashes
  // every particle between a flat disc and a half-faded one, frame by frame,
  // while the tail itself stays far too short to see.
  let spineU = clamp((1.0 - input.alongN) / (2.0 + input.elongN), 0.0, 1.0);
  let taperDepth = min(input.elongN / TAPER_FULL_ELONGATION, 1.0);
  let tailFade = 1.0 - taperDepth * (1.0 - sqrt(1.0 - spineU));

  let alpha = shapeAlpha * tailFade;

  if (alpha <= 0.0) {
    discard;
  }

  // Density-based brightness: lonely (low density) particles are dimmer
  let brightnessMod = MIN_BRIGHTNESS + (MAX_BRIGHTNESS - MIN_BRIGHTNESS) * (1.0 - exp(-input.density * BRIGHTNESS_GROWTH_RATE));

  return vec4f(input.color.rgb * brightnessMod, alpha);
}
