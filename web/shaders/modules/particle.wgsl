// =============================================================================
// MODULE: particle
// =============================================================================
// Particle struct: 32 bytes, cache-aligned AoS layout.
//
// Source of truth: src/memory_layout.nim
// This definition MUST match the Nim memory layout exactly.
//
// CACHE BEHAVIOR:
// - Two particles fit in one 64-byte CPU cache line
// - Four particles fit in one 128-byte GPU cache line
// - 32-byte alignment avoids straddling cache line boundaries
//
// Field-by-field layout: web/shaders/README.md's Buffer Layout table and the
// inline offsets on the struct below.
//
// THREE DENSITIES, NONE INTERCHANGEABLE. Each answers a different question, and
// a field carrying two of them makes one consumer track the other's parameter.
//
//   density      - same-species neighbours, proximity-weighted. What a COLONY
//                  looks like; dot size, brightness and glow read it.
//   sphDensity   - kernel-weighted and species-blind, unsmoothed, in the units
//                  the Tait equation of state wants. Nothing outside
//                  forces-sph.wgsl reads it.
//   crowdDensity - every neighbour, proximity-weighted, species-blind, smoothed
//                  the same way `density` is. What the crowding cap reads: the
//                  spatial hash a mixed blob fills costs exactly what a
//                  single-species one costs, so the signal bounding that cost
//                  counts neighbours the way the hash does.
// =============================================================================

struct Particle {
  pos: vec2<f32>,    // offset 0, size 8
  vel: vec2<f32>,    // offset 8, size 8
  species: u32,      // offset 16, size 4
  density: f32,      // offset 20, size 4
  sphDensity: f32,   // offset 24, size 4
  crowdDensity: f32, // offset 28, size 4
}

// Maximum species count - MUST match memory_layout.nim:MAX_SPECIES
const MAX_SPECIES: u32 = 6u;
