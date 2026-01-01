# ==============================================================================
# PARTICLE GARDEN - MEMORY LAYOUT (Single Source of Truth)
# ==============================================================================
#
# This module defines the memory layout for ArrayBuffer-backed typed arrays.
# It is the ONLY place where memory offsets are computed.
#
# ARCHITECTURE: WebGPU-only physics with AoS (Array of Structures) layout.
#
# AoS PARTICLE STRUCT (32 bytes, cache-aligned):
# ┌─────────┬──────────┬───────┬─────────────────────────────────────────────┐
# │ Offset  │ Field    │ Size  │ Description                                 │
# ├─────────┼──────────┼───────┼─────────────────────────────────────────────┤
# │ 0       │ pos.x    │ 4     │ X position (f32)                            │
# │ 4       │ pos.y    │ 4     │ Y position (f32)                            │
# │ 8       │ vel.x    │ 4     │ X velocity (f32)                            │
# │ 12      │ vel.y    │ 4     │ Y velocity (f32)                            │
# │ 16      │ species  │ 4     │ Species ID (u32)                            │
# │ 20      │ density  │ 4     │ Local density (f32)                         │
# │ 24      │ _pad0    │ 4     │ Padding for 32-byte alignment               │
# │ 28      │ _pad1    │ 4     │ Padding for 32-byte alignment               │
# └─────────┴──────────┴───────┴─────────────────────────────────────────────┘
#
# WHY 32 BYTES:
# - Two particles fit in one 64-byte CPU cache line
# - Four particles fit in one 128-byte GPU cache line
# - Powers-of-two alignment avoids straddling cache line boundaries
# - All fields naturally aligned (f32/u32 at 4-byte boundaries)
#
# BUFFER ORGANIZATION:
# - particlesA: Primary particle buffer (N * 32 bytes)
# - particlesSorted: Spatially-sorted copy for cache-friendly force computation
# - velocityDeltaFixed: Interleaved i32 pairs for atomic Newton's 3rd law
# - Grid buffers: cellCounts, cellOffsets for spatial hashing
# - Index mappings: sortedIndices, reverseIndices
#
# CROSS-COMPILATION:
#   This module compiles for `nim js` (browser).
#   No jsffi, no browser APIs, no DOM - pure Nim with compile-time constants.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: MAXIMUM LIMITS
# ==============================================================================

const
  MAX_PARTICLES* = 64000  ## Maximum supported particle count
  MAX_SPECIES* = 6        ## Maximum species for attraction matrix (6x6 = 36 floats)
  MAX_GRID* = 256         ## Maximum grid cells per dimension (256x256 = 65536 cells)

# ==============================================================================
# SECTION 2: AoS PARTICLE STRUCTURE
# ==============================================================================
#
# The Particle struct is 32 bytes, matching the WGSL struct layout exactly.
# This enables direct memcpy between CPU and GPU buffers.

const
  PARTICLE_STRIDE* = 32  ## Bytes per particle (cache-aligned)

  # Field offsets within Particle struct (in bytes)
  PARTICLE_POS_X_OFFSET* = 0
  PARTICLE_POS_Y_OFFSET* = 4
  PARTICLE_VEL_X_OFFSET* = 8
  PARTICLE_VEL_Y_OFFSET* = 12
  PARTICLE_SPECIES_OFFSET* = 16
  PARTICLE_DENSITY_OFFSET* = 20
  # Offsets 24-31 are padding

# ==============================================================================
# SECTION 3: SHARED BUFFER CONFIGURATION
# ==============================================================================

const
  WASM_MEMORY_PAGES* = 2048      ## 128MB initial (2048 * 64KB)
  WASM_MEMORY_PAGES_MAX* = 8192  ## 512MB maximum
  WASM_DATA_OFFSET* = 1024 * 1024  ## 1MB reserved for initial allocation offset

# ==============================================================================
# SECTION 4: SIZE CALCULATIONS
# ==============================================================================

const
  PARTICLES_BUFFER_SIZE = MAX_PARTICLES * PARTICLE_STRIDE  # 64K * 32 = 2MB per buffer
  GRID_CELLS = MAX_GRID * MAX_GRID  # 256 * 256 = 65536 cells

# ==============================================================================
# SECTION 5: ALIGNMENT HELPER
# ==============================================================================

func align4(x: int): int {.inline.} =
  ## Align to 4-byte boundary for typed array compatibility.
  (x + 3) and (not 3)

# ==============================================================================
# SECTION 6: MEMORY OFFSET TYPES
# ==============================================================================

type
  MemoryOffsets* = object
    ## All memory offsets as byte addresses from start of WASM memory.

    # AoS particle buffers (32 bytes per particle)
    particlesA*: int      ## Primary particle buffer (N * 32 bytes)
    particlesSorted*: int ## Spatially-sorted particles for cache-friendly forces

    # Index mappings for scatter/gather
    sortedIndices*: int   ## Uint32Array: sorted_idx -> original_idx
    reverseIndices*: int  ## Uint32Array: original_idx -> sorted_idx

    # Fixed-point velocity deltas for atomic accumulation (Newton's 3rd law)
    # Layout: [deltaVx_0, deltaVy_0, deltaVx_1, deltaVy_1, ...]
    # Scale: 65536 (16-bit fractional precision)
    velocityDeltaFixed*: int  ## Int32Array: interleaved [vdx, vdy] pairs

    # Spatial grid (for O(n*k) neighbor lookup)
    gridCounts*: int   ## Uint32Array: particles per cell (atomic counters)
    gridOffsets*: int  ## Uint32Array: prefix sum offsets

    # Shared state
    matrix*: int    ## Float32Array[36]: 6x6 attraction matrix
    sync*: int      ## Int32Array[256]: synchronization buffer

    # Total size (for validation)
    totalSize*: int

# ==============================================================================
# SECTION 7: COMPILE-TIME OFFSET COMPUTATION
# ==============================================================================

func computeMemoryOffsets(): MemoryOffsets =
  ## Compute all memory offsets at compile time.

  var offset = WASM_DATA_OFFSET

  # Primary particle buffer (AoS layout)
  let particlesA = offset
  offset += PARTICLES_BUFFER_SIZE

  # Sorted particle buffer (for cache-friendly force computation)
  let particlesSorted = offset
  offset += PARTICLES_BUFFER_SIZE

  # Index mappings
  let sortedIndices = offset
  offset += MAX_PARTICLES * 4  # u32 per particle
  let reverseIndices = offset
  offset += MAX_PARTICLES * 4  # u32 per particle

  # Fixed-point velocity deltas for atomic accumulation
  let velocityDeltaFixed = offset
  offset += MAX_PARTICLES * 2 * 4  # 2 i32s per particle

  # Spatial grid
  let gridCounts = offset
  offset += GRID_CELLS * 4  # u32 per cell (for atomics)
  let gridOffsets = offset
  offset += GRID_CELLS * 4  # u32 per cell

  # Attraction matrix (6x6 = 36 floats)
  let matrix = offset
  offset += 36 * 4

  # Sync buffer
  offset = align4(offset)
  let sync = offset
  offset += 256 * 4

  let totalSize = offset

  result = MemoryOffsets(
    particlesA: particlesA,
    particlesSorted: particlesSorted,
    sortedIndices: sortedIndices,
    reverseIndices: reverseIndices,
    velocityDeltaFixed: velocityDeltaFixed,
    gridCounts: gridCounts,
    gridOffsets: gridOffsets,
    matrix: matrix,
    sync: sync,
    totalSize: totalSize
  )

# ==============================================================================
# SECTION 8: EXPORTED CONSTANTS
# ==============================================================================

const OFFSETS* = computeMemoryOffsets()

# Individual exports for convenience
const
  PARTICLES_A_OFFSET* = OFFSETS.particlesA
  PARTICLES_SORTED_OFFSET* = OFFSETS.particlesSorted
  SORTED_INDICES_OFFSET* = OFFSETS.sortedIndices
  REVERSE_INDICES_OFFSET* = OFFSETS.reverseIndices
  VELOCITY_DELTA_FIXED_OFFSET* = OFFSETS.velocityDeltaFixed
  GRID_COUNTS_OFFSET* = OFFSETS.gridCounts
  GRID_OFFSETS_OFFSET* = OFFSETS.gridOffsets
  MATRIX_OFFSET* = OFFSETS.matrix
  SYNC_OFFSET* = OFFSETS.sync

# ==============================================================================
# SECTION 9: VALIDATION
# ==============================================================================

static:
  # Verify alignment
  assert OFFSETS.particlesA mod 4 == 0, "particlesA must be 4-byte aligned"
  assert OFFSETS.particlesSorted mod 4 == 0, "particlesSorted must be 4-byte aligned"
  assert OFFSETS.velocityDeltaFixed mod 4 == 0, "velocityDeltaFixed must be 4-byte aligned"
  assert OFFSETS.gridOffsets mod 4 == 0, "gridOffsets must be 4-byte aligned"
  assert OFFSETS.sync mod 4 == 0, "sync buffer must be 4-byte aligned"

  # Verify no overlap
  assert OFFSETS.particlesSorted >= OFFSETS.particlesA + PARTICLES_BUFFER_SIZE
  assert OFFSETS.sortedIndices >= OFFSETS.particlesSorted + PARTICLES_BUFFER_SIZE

  # Verify particle stride
  assert PARTICLE_STRIDE == 32, "Particle stride must be 32 bytes for cache alignment"

  # Verify total size fits
  assert OFFSETS.totalSize <= WASM_MEMORY_PAGES * 65536, "Total size exceeds allocated memory"
