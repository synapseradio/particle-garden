// =============================================================================
// MODULE: grid_params
// =============================================================================
// GridParams uniform struct for spatial hashing passes.
//
// Used by: bin-count, bin-scatter
//
// ALIGNMENT: 32 bytes (padded to 16-byte boundary for uniform buffer)
// =============================================================================

struct GridParams {
  gridW: u32,           // Grid width in cells
  gridH: u32,           // Grid height in cells
  canvasWidth: f32,     // World width in pixels
  canvasHeight: f32,    // World height in pixels
  particleCount: u32,   // Number of active particles
  padding0: u32,        // Align to 16 bytes
  padding1: u32,
  padding2: u32,
}
