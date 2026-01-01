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
  test "particle buffers are 4-byte aligned":
    check OFFSETS.particlesA mod 4 == 0
    check OFFSETS.particlesSorted mod 4 == 0

  test "index buffers are 4-byte aligned":
    check OFFSETS.sortedIndices mod 4 == 0
    check OFFSETS.reverseIndices mod 4 == 0

  test "velocity delta buffer is 4-byte aligned":
    check OFFSETS.velocityDeltaFixed mod 4 == 0

  test "grid offsets are 4-byte aligned":
    check OFFSETS.gridCounts mod 4 == 0
    check OFFSETS.gridOffsets mod 4 == 0

  test "sync buffer is 4-byte aligned":
    check OFFSETS.sync mod 4 == 0

  test "matrix is 4-byte aligned":
    check OFFSETS.matrix mod 4 == 0

# ==============================================================================
# NO OVERLAP TESTS
# ==============================================================================

suite "Memory Layout No Overlap":
  const PARTICLE_BUFFER_SIZE = MAX_PARTICLES * PARTICLE_STRIDE
  const GRID_CELLS = MAX_GRID * MAX_GRID

  test "particlesSorted starts after particlesA":
    check OFFSETS.particlesSorted >= OFFSETS.particlesA + PARTICLE_BUFFER_SIZE

  test "sortedIndices starts after particlesSorted":
    check OFFSETS.sortedIndices >= OFFSETS.particlesSorted + PARTICLE_BUFFER_SIZE

  test "grid regions don't overlap":
    check OFFSETS.gridOffsets >= OFFSETS.gridCounts + GRID_CELLS * 4

  test "matrix starts after grid":
    check OFFSETS.matrix >= OFFSETS.gridOffsets + GRID_CELLS * 4

  test "sync buffer starts after matrix":
    check OFFSETS.sync >= OFFSETS.matrix + 36 * 4

# ==============================================================================
# SIZE CONSTRAINT TESTS
# ==============================================================================

suite "Memory Layout Size Constraints":
  test "total size fits in allocated memory":
    let allocatedBytes = WASM_MEMORY_PAGES * 65536
    check OFFSETS.totalSize <= allocatedBytes

  test "total size is reasonable":
    check OFFSETS.totalSize < 64 * 1024 * 1024

  test "data starts at WASM_DATA_OFFSET":
    check OFFSETS.particlesA == WASM_DATA_OFFSET

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

  test "PARTICLE_STRIDE is 32 bytes":
    check PARTICLE_STRIDE == 32

  test "WASM_DATA_OFFSET is 1MB":
    check WASM_DATA_OFFSET == 1024 * 1024

  test "individual offset exports match OFFSETS object":
    check PARTICLES_A_OFFSET == OFFSETS.particlesA
    check PARTICLES_SORTED_OFFSET == OFFSETS.particlesSorted
    check SORTED_INDICES_OFFSET == OFFSETS.sortedIndices
    check REVERSE_INDICES_OFFSET == OFFSETS.reverseIndices
    check VELOCITY_DELTA_FIXED_OFFSET == OFFSETS.velocityDeltaFixed
    check GRID_COUNTS_OFFSET == OFFSETS.gridCounts
    check GRID_OFFSETS_OFFSET == OFFSETS.gridOffsets
    check MATRIX_OFFSET == OFFSETS.matrix
    check SYNC_OFFSET == OFFSETS.sync
