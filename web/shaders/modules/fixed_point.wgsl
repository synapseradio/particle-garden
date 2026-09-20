// =============================================================================
// MODULE: fixed_point
// =============================================================================
// Fixed-point constants for atomic float accumulation.
//
// GPUs lack float atomics: scale by 2^16, accumulate as atomic i32, rescale on read.
//
// TWO SCALES, BECAUSE THE TWO QUANTITIES WANT OPPOSITE THINGS.
//
// Velocity deltas are signed and want resolution near zero. Every writer adds
// its impulse per reference frame, and integrate.wgsl applies the frame factor
// once. One word at 2^16 spans +/-32768, and a full crowd of fluid pairs
// exceeds that 1 335 times over, so forces-sph.wgsl splits each integer into
// this fine word and a coarse word counting 2^VELOCITY_COARSE_SHIFT fine
// quanta; every other writer adds to the fine word alone. src/config_ranges.nim
// asserts that both words hold a full crowd at the range maxima.
//
// Kernel density is a large positive count: forces-sph.wgsl normalizes each
// neighbour's weight by the self-weight, so a neighbour adds at most 1.0 and
// the total counts neighbours. Nothing bounds how many particles share a
// smoothing radius, so the total reaches MAX_PARTICLES, which 2^16 cannot hold
// — and an i32 past its maximum wraps NEGATIVE, which the equation of state
// reads as maximal expansion and answers with force in the wrong direction.
// The density accumulator therefore takes a coarser scale, derived in
// src/sph_core.nim from the particle budget with headroom to spare.
//
// INVARIANT: EACH SCALE HAS EXACTLY ONE DECODER.
// The five velocity writers and integrate.wgsl share the velocity scale;
// forces-sph.wgsl and integrate.wgsl share the density one. Encoding at one
// scale and decoding at the other is silent: the numbers still arrive, wrong
// by the ratio.
// =============================================================================

const FIXED_POINT_SCALE: f32 = {{TUNABLE_FIXED_POINT_SCALE}};           // Float-to-int conversion factor (2^16)
const INV_FIXED_POINT_SCALE: f32 = {{TUNABLE_INV_FIXED_POINT_SCALE}};  // 1.0 / FIXED_POINT_SCALE (precomputed)

// The time a velocity writer accumulates its impulse over.
const FRAME_DT_REFERENCE: f32 = {{FRAME_DT_REFERENCE}};

// The coarse velocity word counts 2^VELOCITY_COARSE_SHIFT fine quanta.
const VELOCITY_COARSE_SHIFT: u32 = {{VELOCITY_COARSE_SHIFT}}u;
const VELOCITY_FINE_MASK: i32 = (1i << VELOCITY_COARSE_SHIFT) - 1i;
const VELOCITY_COARSE_UNIT: f32 = f32(1i << VELOCITY_COARSE_SHIFT);

// SPH kernel density only. Derived from MAX_PARTICLES, not chosen.
const SPH_DENSITY_FIXED_POINT_SCALE: f32 = {{SPH_DENSITY_FIXED_POINT_SCALE}};
const SPH_DENSITY_INV_FIXED_POINT_SCALE: f32 = {{SPH_DENSITY_INV_FIXED_POINT_SCALE}};

// Crowd density only: forces.wgsl encodes, integrate.wgsl decodes. Same value
// as the pair above and the same derivation from MAX_PARTICLES, because both
// count neighbours contributing at most 1.0 each. It carries its own name
// because a scale with two encoders is a scale nobody owns — and this is the
// channel where wrapping costs most, since a negative density hands log(1 + d)
// a negative argument and the NaN spreads through every force in the frame.
const CROWD_DENSITY_FIXED_POINT_SCALE: f32 = {{CROWD_DENSITY_FIXED_POINT_SCALE}};
const CROWD_DENSITY_INV_FIXED_POINT_SCALE: f32 = {{CROWD_DENSITY_INV_FIXED_POINT_SCALE}};
