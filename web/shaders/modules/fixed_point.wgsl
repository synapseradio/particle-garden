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
// PRECISION:
// 65536 = 2^16 gives us 16-bit fractional precision.
// Range: [-32768, 32767] maps to [-0.5, 0.5] approximately.
// For velocity deltas per frame, this is more than sufficient.
//
// INVARIANT: DO NOT CHANGE THESE VALUES
// Both forces.wgsl and integrate.wgsl depend on these exact values.
// Changing them breaks the fixed-point arithmetic contract.
// =============================================================================

const FIXED_POINT_SCALE: f32 = 65536.0;           // Float-to-int conversion factor (2^16)
const INV_FIXED_POINT_SCALE: f32 = 0.0000152587890625;  // 1.0 / 65536.0 (precomputed)
