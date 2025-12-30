# ==============================================================================
# EMERGENT GARDEN - MEMORY LAYOUT (Single Source of Truth)
# ==============================================================================
#
# This module defines the memory layout for ArrayBuffer-backed typed arrays.
# It is the ONLY place where memory offsets are computed.
#
# ARCHITECTURE: WebGPU-only physics.
# The layout defines CPU-side buffer structure for:
#   - Initial particle data generation
#   - Upload to GPU buffers
#   - WebGL fallback rendering (reading positions for display)
#
# CROSS-COMPILATION:
#   This module compiles for `nim js` (browser).
#   No jsffi, no browser APIs, no DOM - pure Nim with compile-time constants.
#
# IMPORTED BY:
#   - config.nim (JS compilation)
#   - buffers.nim (JS compilation)
#   - grid_core.nim (JS compilation)
#   - tests/* (native compilation)
#
# INVARIANTS:
#   - All offsets are 4-byte aligned for typed array compatibility
#   - Buffer A and B have identical layouts at different offsets
#   - Total size fits within WASM_MEMORY_PAGES * 64KB
#
# ==============================================================================

# ==============================================================================
# SECTION 1: MAXIMUM LIMITS
# ==============================================================================
#
# These constants determine buffer allocation sizes.
# Changing them affects memory layout - all consumers must be recompiled.

const
  MAX_PARTICLES* = 64000  ## Maximum supported particle count
  MAX_SPECIES* = 6        ## Maximum species for attraction matrix (6x6 = 36 floats)
  MAX_GRID* = 256         ## Maximum grid cells per dimension (256x256 = 65536 cells)
  MAX_WORKERS* = 16       ## Maximum Web Workers for parallel physics

# ==============================================================================
# SECTION 2: WASM MEMORY CONFIGURATION
# ==============================================================================
#
# WebAssembly linear memory is measured in 64KB pages.
# We allocate enough for all particle data + grid + sync buffers.

const
  WASM_MEMORY_PAGES* = 2048      ## 128MB initial (2048 * 64KB)
  WASM_MEMORY_PAGES_MAX* = 8192  ## 512MB maximum
  WASM_DATA_OFFSET* = 1024 * 1024  ## 1MB - skip WASM stack/heap

# ==============================================================================
# SECTION 3: SIZE CALCULATIONS
# ==============================================================================
#
# Intermediate size values used for offset computation.

const
  FLOAT_SIZE = MAX_PARTICLES * 4  # Float32 = 4 bytes per particle
  UINT8_SIZE = MAX_PARTICLES      # Uint8 = 1 byte per particle
  GRID_CELLS = MAX_GRID * MAX_GRID  # Total grid cells

# ==============================================================================
# SECTION 4: ALIGNMENT HELPER
# ==============================================================================

func align4(x: int): int {.inline.} =
  ## Align to 4-byte boundary for typed array compatibility.
  ## Int32Array and Float32Array require 4-byte aligned offsets.
  (x + 3) and (not 3)

# ==============================================================================
# SECTION 5: MEMORY OFFSET TYPES
# ==============================================================================

type
  MemoryOffsets* = object
    ## All memory offsets as byte addresses from start of WASM memory.
    ## These are used to create typed array views in JS and pointer casts in WASM.

    # Buffer set A (source when parity=0)
    pxA*: int       ## Float32Array: particle X positions
    pyA*: int       ## Float32Array: particle Y positions
    vxA*: int       ## Float32Array: particle X velocities
    vyA*: int       ## Float32Array: particle Y velocities
    denA*: int      ## Float32Array: particle densities
    speciesA*: int  ## Uint8Array: particle species (0..MAX_SPECIES-1)

    # Buffer set B (source when parity=1)
    pxB*: int
    pyB*: int
    vxB*: int
    vyB*: int
    denB*: int
    speciesB*: int

    # Velocity deltas (written by physics, applied by integration)
    vxDelta*: int   ## Float32Array: X velocity deltas (legacy, kept for compatibility)
    vyDelta*: int   ## Float32Array: Y velocity deltas (legacy, kept for compatibility)

    # Fixed-point interleaved velocity deltas for atomic accumulation
    # Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
    # Scale: 65536 (16-bit fractional precision)
    velocityDeltaFixed*: int  ## Int32Array: interleaved [vdx, vdy] pairs

    # Spatial grid (for O(n*k) neighbor lookup)
    gridCounts*: int   ## Uint16Array: particles per cell
    gridOffsets*: int  ## Uint32Array: prefix sum offsets

    # Shared state
    matrix*: int    ## Float32Array[36]: 6x6 attraction matrix
    sync*: int      ## Int32Array[256]: worker synchronization buffer

    # Total size (for validation)
    totalSize*: int

# ==============================================================================
# SECTION 6: COMPILE-TIME OFFSET COMPUTATION
# ==============================================================================
#
# All offsets are computed at compile time.
# The layout matches the JS MEMORY_LAYOUT object exactly.

func computeMemoryOffsets(): MemoryOffsets =
  ## Compute all memory offsets at compile time.
  ## This function is evaluated by the compiler, not at runtime.

  var offset = WASM_DATA_OFFSET

  # Buffer A (source during even frames / parity=0)
  let pxA = offset
  offset += FLOAT_SIZE
  let pyA = offset
  offset += FLOAT_SIZE
  let vxA = offset
  offset += FLOAT_SIZE
  let vyA = offset
  offset += FLOAT_SIZE
  let denA = offset
  offset += FLOAT_SIZE
  let speciesA = offset
  offset += UINT8_SIZE

  # Buffer B (source during odd frames / parity=1) - align after uint8
  offset = align4(offset)
  let pxB = offset
  offset += FLOAT_SIZE
  let pyB = offset
  offset += FLOAT_SIZE
  let vxB = offset
  offset += FLOAT_SIZE
  let vyB = offset
  offset += FLOAT_SIZE
  let denB = offset
  offset += FLOAT_SIZE
  let speciesB = offset
  offset += UINT8_SIZE

  # Velocity deltas (workers write here) - align after uint8
  offset = align4(offset)
  let vxDelta = offset
  offset += FLOAT_SIZE
  let vyDelta = offset
  offset += FLOAT_SIZE

  # Fixed-point interleaved velocity deltas for atomic accumulation
  # Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
  # Size: 2 * MAX_PARTICLES * sizeof(int32) = 2 * MAX_PARTICLES * 4 bytes
  let velocityDeltaFixed = offset
  offset += MAX_PARTICLES * 2 * 4  # 2 int32s per particle

  # Spatial grid
  let gridCounts = offset
  offset += GRID_CELLS * 2  # Uint16Array = 2 bytes per cell
  offset = align4(offset)
  let gridOffsets = offset
  offset += GRID_CELLS * 4  # Uint32Array = 4 bytes per cell

  # Attraction matrix (6x6 = 36 floats)
  let matrix = offset
  offset += 36 * 4

  # Sync buffer for Atomics (must be 4-byte aligned for Int32Array)
  offset = align4(offset)
  let sync = offset
  offset += 256 * 4  # 256 int32s for worker synchronization

  let totalSize = offset

  result = MemoryOffsets(
    pxA: pxA, pyA: pyA, vxA: vxA, vyA: vyA, denA: denA, speciesA: speciesA,
    pxB: pxB, pyB: pyB, vxB: vxB, vyB: vyB, denB: denB, speciesB: speciesB,
    vxDelta: vxDelta, vyDelta: vyDelta,
    velocityDeltaFixed: velocityDeltaFixed,
    gridCounts: gridCounts, gridOffsets: gridOffsets,
    matrix: matrix, sync: sync,
    totalSize: totalSize
  )

# ==============================================================================
# SECTION 7: EXPORTED CONSTANTS
# ==============================================================================
#
# OFFSETS is the single source of truth for all memory layout information.
# Both JS and WASM code should reference these values.

const OFFSETS* = computeMemoryOffsets()

# ==============================================================================
# SECTION 8: INDIVIDUAL OFFSET EXPORTS (for WASM convenience)
# ==============================================================================
#
# WASM code uses raw pointer arithmetic and benefits from named constants.
# These are aliases into OFFSETS for cleaner WASM code.

const
  PX_A_OFFSET* = OFFSETS.pxA
  PY_A_OFFSET* = OFFSETS.pyA
  VX_A_OFFSET* = OFFSETS.vxA
  VY_A_OFFSET* = OFFSETS.vyA
  DEN_A_OFFSET* = OFFSETS.denA
  SPECIES_A_OFFSET* = OFFSETS.speciesA

  PX_B_OFFSET* = OFFSETS.pxB
  PY_B_OFFSET* = OFFSETS.pyB
  VX_B_OFFSET* = OFFSETS.vxB
  VY_B_OFFSET* = OFFSETS.vyB
  DEN_B_OFFSET* = OFFSETS.denB
  SPECIES_B_OFFSET* = OFFSETS.speciesB

  VX_DELTA_OFFSET* = OFFSETS.vxDelta
  VY_DELTA_OFFSET* = OFFSETS.vyDelta
  VELOCITY_DELTA_FIXED_OFFSET* = OFFSETS.velocityDeltaFixed

  GRID_COUNTS_OFFSET* = OFFSETS.gridCounts
  GRID_OFFSETS_OFFSET* = OFFSETS.gridOffsets

  MATRIX_OFFSET* = OFFSETS.matrix
  SYNC_OFFSET* = OFFSETS.sync

# ==============================================================================
# SECTION 9: VALIDATION HELPERS
# ==============================================================================
#
# These compile-time checks ensure the memory layout is valid.

static:
  # Verify alignment
  assert OFFSETS.pxB mod 4 == 0, "Buffer B must be 4-byte aligned"
  assert OFFSETS.vxDelta mod 4 == 0, "vxDelta must be 4-byte aligned"
  assert OFFSETS.velocityDeltaFixed mod 4 == 0, "velocityDeltaFixed must be 4-byte aligned"
  assert OFFSETS.gridOffsets mod 4 == 0, "gridOffsets must be 4-byte aligned"
  assert OFFSETS.sync mod 4 == 0, "sync buffer must be 4-byte aligned"

  # Verify no overlap between buffer sets (species arrays are MAX_PARTICLES bytes each)
  # Use >= because align4 may place next region exactly at end of previous
  assert OFFSETS.pxB >= OFFSETS.speciesA + MAX_PARTICLES, "Buffer B must not overlap Buffer A"
  assert OFFSETS.vxDelta >= OFFSETS.speciesB + MAX_PARTICLES, "vxDelta must not overlap Buffer B"
  assert OFFSETS.velocityDeltaFixed >= OFFSETS.vyDelta + MAX_PARTICLES * 4, "velocityDeltaFixed must not overlap vyDelta"

  # Verify total size fits in allocated memory
  assert OFFSETS.totalSize <= WASM_MEMORY_PAGES * 65536, "Total size exceeds allocated WASM memory"
