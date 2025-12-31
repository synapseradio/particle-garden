# ==============================================================================
# PARTICLE GARDEN - MEMORY LAYOUT TESTS
# ==============================================================================
#
# Unit tests for memory layout constants and offset calculations.
# Verifies alignment, no overlap, and total size constraints.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/memory_layout

# Export a constant so test_all.nim can reference it
const MEMORY_LAYOUT_TESTS_LOADED* = true

# ==============================================================================
# ALIGNMENT TESTS
# ==============================================================================

suite "Memory Layout Alignment":
  test "all Float32Array offsets are 4-byte aligned":
    check OFFSETS.pxA mod 4 == 0
    check OFFSETS.pyA mod 4 == 0
    check OFFSETS.vxA mod 4 == 0
    check OFFSETS.vyA mod 4 == 0
    check OFFSETS.denA mod 4 == 0
    check OFFSETS.pxB mod 4 == 0
    check OFFSETS.pyB mod 4 == 0
    check OFFSETS.vxB mod 4 == 0
    check OFFSETS.vyB mod 4 == 0
    check OFFSETS.denB mod 4 == 0
    check OFFSETS.vxDelta mod 4 == 0
    check OFFSETS.vyDelta mod 4 == 0

  test "grid offsets are 4-byte aligned":
    check OFFSETS.gridOffsets mod 4 == 0

  test "sync buffer is 4-byte aligned (required for Int32Array)":
    check OFFSETS.sync mod 4 == 0

  test "matrix is 4-byte aligned":
    check OFFSETS.matrix mod 4 == 0

# ==============================================================================
# NO OVERLAP TESTS
# ==============================================================================

suite "Memory Layout No Overlap":
  const FLOAT_SIZE = MAX_PARTICLES * 4
  const UINT8_SIZE = MAX_PARTICLES
  const GRID_CELLS = MAX_GRID * MAX_GRID

  test "buffer A regions don't overlap":
    check OFFSETS.pyA >= OFFSETS.pxA + FLOAT_SIZE
    check OFFSETS.vxA >= OFFSETS.pyA + FLOAT_SIZE
    check OFFSETS.vyA >= OFFSETS.vxA + FLOAT_SIZE
    check OFFSETS.denA >= OFFSETS.vyA + FLOAT_SIZE
    check OFFSETS.speciesA >= OFFSETS.denA + FLOAT_SIZE

  test "buffer B starts at or after buffer A ends":
    check OFFSETS.pxB >= OFFSETS.speciesA + UINT8_SIZE

  test "buffer B regions don't overlap":
    check OFFSETS.pyB >= OFFSETS.pxB + FLOAT_SIZE
    check OFFSETS.vxB >= OFFSETS.pyB + FLOAT_SIZE
    check OFFSETS.vyB >= OFFSETS.vxB + FLOAT_SIZE
    check OFFSETS.denB >= OFFSETS.vyB + FLOAT_SIZE
    check OFFSETS.speciesB >= OFFSETS.denB + FLOAT_SIZE

  test "velocity deltas start after buffer B":
    check OFFSETS.vxDelta >= OFFSETS.speciesB + UINT8_SIZE

  test "velocity deltas don't overlap":
    check OFFSETS.vyDelta >= OFFSETS.vxDelta + FLOAT_SIZE

  test "grid starts after velocity deltas":
    check OFFSETS.gridCounts >= OFFSETS.vyDelta + FLOAT_SIZE

  test "grid regions don't overlap":
    check OFFSETS.gridOffsets >= OFFSETS.gridCounts + GRID_CELLS * 2

  test "matrix starts after grid":
    check OFFSETS.matrix >= OFFSETS.gridOffsets + GRID_CELLS * 4

  test "sync buffer starts after matrix":
    check OFFSETS.sync >= OFFSETS.matrix + 36 * 4

# ==============================================================================
# SIZE CONSTRAINT TESTS
# ==============================================================================

suite "Memory Layout Size Constraints":
  test "total size fits in allocated WASM memory":
    let allocatedBytes = WASM_MEMORY_PAGES * 65536
    check OFFSETS.totalSize <= allocatedBytes

  test "total size is reasonable (less than 64MB for current config)":
    # With 64k particles, we expect roughly:
    # - Buffer A: 6 arrays * 64000 * 4 bytes = ~1.5MB
    # - Buffer B: ~1.5MB
    # - Deltas: 2 arrays * 64000 * 4 = ~0.5MB
    # - Grid: 256*256 * (2+4) bytes = ~400KB
    # - Matrix + sync: negligible
    # Total: ~4MB
    check OFFSETS.totalSize < 64 * 1024 * 1024

  test "data starts at WASM_DATA_OFFSET":
    check OFFSETS.pxA == WASM_DATA_OFFSET

# ==============================================================================
# CONSTANT EXPORT TESTS
# ==============================================================================

suite "Memory Layout Constants":
  test "MAX_PARTICLES is 64000":
    check MAX_PARTICLES == 64000

  test "MAX_SPECIES is 6":
    check MAX_SPECIES == 6

  test "MAX_GRID is 256":
    check MAX_GRID == 256

  test "MAX_WORKERS is 16":
    check MAX_WORKERS == 16

  test "WASM_DATA_OFFSET is 1MB":
    check WASM_DATA_OFFSET == 1024 * 1024

  test "individual offset exports match OFFSETS object":
    check PX_A_OFFSET == OFFSETS.pxA
    check PY_A_OFFSET == OFFSETS.pyA
    check VX_A_OFFSET == OFFSETS.vxA
    check VY_A_OFFSET == OFFSETS.vyA
    check DEN_A_OFFSET == OFFSETS.denA
    check SPECIES_A_OFFSET == OFFSETS.speciesA
    check PX_B_OFFSET == OFFSETS.pxB
    check MATRIX_OFFSET == OFFSETS.matrix
    check SYNC_OFFSET == OFFSETS.sync

# ==============================================================================
# CROSS-COMPILATION COMPATIBILITY TESTS
# ==============================================================================

suite "Memory Layout Cross-Compilation":
  test "OFFSETS values match physics_wasm.nim expectations":
    # These are the exact values that physics_wasm.nim expects
    # If these change, WASM will read/write wrong memory
    check OFFSETS.pxA == 1048576  # 1MB = 0x100000

  test "buffer set sizes are consistent":
    # Each buffer set has same layout
    let bufferASize = OFFSETS.pxB - OFFSETS.pxA
    let expectedSize = MAX_PARTICLES * 4 * 5 + MAX_PARTICLES  # 5 float arrays + 1 uint8 array

    # Buffer A size should be at least expectedSize (may have alignment padding)
    check bufferASize >= expectedSize
