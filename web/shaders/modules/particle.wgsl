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
// FIELD LAYOUT:
// ┌─────────┬──────────┬───────┬─────────────────────────────────────────────┐
// │ Offset  │ Field    │ Size  │ Description                                 │
// ├─────────┼──────────┼───────┼─────────────────────────────────────────────┤
// │ 0       │ pos      │ 8     │ Position (vec2<f32>)                        │
// │ 8       │ vel      │ 8     │ Velocity (vec2<f32>)                        │
// │ 16      │ species  │ 4     │ Species ID (u32, 0-5)                       │
// │ 20      │ density  │ 4     │ Local density (f32)                         │
// │ 24      │ _pad0    │ 4     │ Padding for 32-byte alignment               │
// │ 28      │ _pad1    │ 4     │ Padding for 32-byte alignment               │
// └─────────┴──────────┴───────┴─────────────────────────────────────────────┘
// =============================================================================

struct Particle {
  pos: vec2<f32>,    // offset 0, size 8
  vel: vec2<f32>,    // offset 8, size 8
  species: u32,      // offset 16, size 4
  density: f32,      // offset 20, size 4
  _pad0: u32,        // offset 24, size 4
  _pad1: u32,        // offset 28, size 4
}

// Maximum species count - MUST match memory_layout.nim:MAX_SPECIES
const MAX_SPECIES: u32 = 6u;
