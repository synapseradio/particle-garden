// =============================================================================
// MODULE: scan_params
// =============================================================================
// ScanParams uniform struct for prefix sum passes.
//
// Used by: prefix-sum, prefix-sum-local, prefix-sum-blocks, prefix-sum-final
//
// ALIGNMENT: 16 bytes
// =============================================================================

struct ScanParams {
  numCells: u32,        // Total number of grid cells (gridW * gridH)
  numBlocks: u32,       // Number of workgroups (ceil(numCells / BLOCK_SIZE))
  padding1: u32,
  padding2: u32,
}
