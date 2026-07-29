// =============================================================================
// MODULE: grid_params
// =============================================================================
// GridParams uniform struct for spatial hashing passes.
//
// Used by: bin-count, bin-scatter, field-deposit, field-force
//
// ALIGNMENT: 32 bytes (padded to 16-byte boundary for uniform buffer)
// =============================================================================

struct GridParams {
  gridW: u32,
  gridH: u32,
  canvasWidth: f32,     // World width in pixels
  canvasHeight: f32,    // World height in pixels
  particleCount: u32,
  padding0: u32,
  padding1: u32,
  padding2: u32,
}
