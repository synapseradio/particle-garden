# PARTICLE GARDEN - MEMORY LAYOUT TESTS

import std/unittest
import ../src/memory_layout
import ../src/ui/state/matrix_state

const MEMORY_LAYOUT_TESTS_LOADED* = true

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

suite "Memory Layout Size Constraints":
  test "total size fits in allocated memory":
    let allocatedBytes = WASM_MEMORY_PAGES * 65536
    check OFFSETS.totalSize <= allocatedBytes

  test "total size is reasonable":
    check OFFSETS.totalSize < 64 * 1024 * 1024

  test "data starts at WASM_DATA_OFFSET":
    check OFFSETS.particlesA == WASM_DATA_OFFSET

suite "Alignment Helper":
  # align4 places every buffer offset; an off-by-one here silently misaligns a
  # TypedArray view and corrupts reads. These pin the rounding contract directly.
  test "align4 returns the input unchanged when it is already a multiple of 4":
    check align4(0) == 0
    check align4(4) == 4
    check align4(8) == 8
    check align4(4096) == 4096

  test "align4 rounds up to the next multiple of 4 when the input is unaligned":
    check align4(1) == 4
    check align4(2) == 4
    check align4(3) == 4
    check align4(5) == 8
    check align4(7) == 8
    check align4(4095) == 4096


suite "Memory Layout Constants":
  # Structural contracts for MAX_PARTICLES, MAX_SPECIES, MAX_GRID, PARTICLE_STRIDE,
  # and WASM_DATA_OFFSET live as compile-time `static: assert`s beside the constants
  # in memory_layout.nim, guarded here by the relationship invariants below plus the
  # totalSize / non-overlap asserts in source.
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

  test "MAX_SPECIES agrees with matrix_state.MATRIX_SIZE":
    # The two are independent copies of the same species ceiling: this one
    # sizes SpeciesChemistryLayout's arrays (gpu_types.nim), matrix_state's
    # sizes the attraction matrix served across the API boundary as
    # matrixStride. Nothing forces them to move together.
    check MAX_SPECIES == MATRIX_SIZE
