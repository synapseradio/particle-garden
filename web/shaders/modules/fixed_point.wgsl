// =============================================================================
// MODULE: fixed_point
// =============================================================================
// Fixed-point constants for atomic float accumulation.
//
// WHY FIXED-POINT?
// GPUs don't support atomic operations on floats (yet).
// We can't just write "atomicAdd(&someFloat, 0.5)" - hardware doesn't support it.
//
// SOLUTION:
// Scale floats by 65536, convert to integers, use atomic integer ops,
// then scale back down when reading. Like counting money in cents instead of dollars.
//
// TWO SCALES, BECAUSE THE TWO QUANTITIES WANT OPPOSITE THINGS.
//
// Velocity deltas are small and signed, and want resolution near zero. At 2^16
// they carry 16 fractional bits over a span of +/-32768 — far more range than a
// per-frame impulse ever needs.
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
// INVARIANT: EACH SCALE HAS EXACTLY ONE ENCODER AND ONE DECODER.
// forces.wgsl and integrate.wgsl share the velocity scale; forces-sph.wgsl and
// integrate.wgsl share the density one. Encoding at one scale and decoding at
// the other is silent: the numbers still arrive, wrong by the ratio.
// =============================================================================

const FIXED_POINT_SCALE: f32 = {{TUNABLE_FIXED_POINT_SCALE}};           // Float-to-int conversion factor (2^16)
const INV_FIXED_POINT_SCALE: f32 = {{TUNABLE_INV_FIXED_POINT_SCALE}};  // 1.0 / FIXED_POINT_SCALE (precomputed)

// SPH kernel density only. Derived from MAX_PARTICLES, not chosen.
const SPH_DENSITY_FIXED_POINT_SCALE: f32 = {{SPH_DENSITY_FIXED_POINT_SCALE}};
const SPH_DENSITY_INV_FIXED_POINT_SCALE: f32 = {{SPH_DENSITY_INV_FIXED_POINT_SCALE}};
