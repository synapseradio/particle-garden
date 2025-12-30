# ==============================================================================
# EMERGENT GARDEN - SPATIAL GRID CONSTRUCTION
# ==============================================================================
#
# Spatial partitioning grid for Goober Garden particle simulation.
#
# This module handles the spatial grid used for efficient neighbor queries.
# The grid enables O(n) physics by limiting particle interactions to nearby cells.
#
# Key algorithm:
# 1. Count particles per cell using source buffer positions
# 2. Compute prefix sum to get cell offsets
# 3. Scatter particles into destination buffer in sorted cell order
# 4. Flip buffer parity so workers read from newly sorted buffer
#
# This "sort by cell" approach ensures particles in the same spatial region
# are contiguous in memory, enabling cache-friendly iteration in workers.
#
# Compile with: nim js -o:web/grid.js src/grid.nim
#
# ==============================================================================

from std/jsffi import JsObject
import bindings/typed_arrays
import bindings/js_interop
import config
import buffers

# ==============================================================================
# SECTION 1: TYPE DEFINITIONS
# ==============================================================================

type
  GridDimensions* = ref object of JsObject
    gridW* {.exportc.}: int
    gridH* {.exportc.}: int
    cellSize* {.exportc.}: int

# ==============================================================================
# SECTION 2: MODULE STATE
# ==============================================================================

# Grid dimensions - updated each frame based on canvas size and interaction radius
var gridW* {.exportc.}: int = 0
var gridH* {.exportc.}: int = 0
var cellSize* {.exportc.}: int = 0

# Performance timing
var gridTimeMs* {.exportc.}: float = 0.0

# ==============================================================================
# SECTION 3: GRID DIMENSION COMPUTATION
# ==============================================================================

proc computeGridDimensions*(canvasWidth: int, canvasHeight: int): GridDimensions {.exportc.} =
  ## Compute grid dimensions without doing any sorting.
  ## Used by WebGPU path which builds the grid on the GPU.
  ##
  ## canvasWidth - Canvas width in pixels
  ## canvasHeight - Canvas height in pixels
  ## Returns object with gridW, gridH, cellSize

  cellSize = CONFIG.interactionRadius

  gridW = jsFloor(canvasWidth.float / cellSize.float)
  gridH = jsFloor(canvasHeight.float / cellSize.float)
  gridW = int(jsMax(1.0, jsMin(gridW.float, MAX_GRID.float)))
  gridH = int(jsMax(1.0, jsMin(gridH.float, MAX_GRID.float)))

  result = GridDimensions()
  result.gridW = gridW
  result.gridH = gridH
  result.cellSize = cellSize

# ==============================================================================
# SECTION 4: GRID BUILDING AND PARTICLE SORTING
# ==============================================================================

proc buildGrid*(particleCount: int, canvasWidth: int, canvasHeight: int): GridDimensions {.exportc.} =
  ## Build the spatial partitioning grid and sort particles by cell.
  ##
  ## This function:
  ## 1. Determines grid dimensions from canvas size and interaction radius
  ## 2. Counts particles per cell
  ## 3. Computes prefix sums for cell offsets
  ## 4. Scatters particles into destination buffer in sorted order
  ## 5. Flips the active parity so workers read from sorted data
  ##
  ## particleCount - Number of active particles
  ## canvasWidth - Canvas width in pixels
  ## canvasHeight - Canvas height in pixels
  ## Returns object with gridW, gridH, cellSize

  let t0 = performanceNow()
  let n = particleCount

  cellSize = CONFIG.interactionRadius

  # Compute grid dimensions - perfect division of domain
  gridW = jsFloor(canvasWidth.float / cellSize.float)
  gridH = jsFloor(canvasHeight.float / cellSize.float)
  gridW = int(jsMax(1.0, jsMin(gridW.float, MAX_GRID.float)))
  gridH = int(jsMax(1.0, jsMin(gridH.float, MAX_GRID.float)))

  let numCells = gridW * gridH
  let invCellW = gridW.float / canvasWidth.float
  let invCellH = gridH.float / canvasHeight.float

  # ---------------------------------------------------------------------------
  # SCATTER DIRECTION & PARITY:
  # The scatter operation copies particles from buffer[parity] to buffer[1-parity]
  # in sorted order (grouped by grid cell for cache-friendly neighbor iteration).
  #
  # Before scatter:  buffer[activeParity] = valid unsorted state
  # After scatter:   buffer[1-activeParity] = valid SORTED state
  #
  # We then flip parity (see line ~198), so:
  #   - activeParity now points to the sorted buffer
  #   - Workers/renderer read from the newly-sorted data
  #   - The old buffer becomes "stale" (will be overwritten next frame)
  #
  # This is the key difference from WebGPU path, which does in-place updates
  # and never flips parity.
  # ---------------------------------------------------------------------------
  var pxSrc, pySrc, vxSrc, vySrc: Float32Array
  var sSrc: Uint8Array
  var pxDst, pyDst, vxDst, vyDst: Float32Array
  var sDst: Uint8Array

  if activeParity == 0:
    pxSrc = pxA
    pySrc = pyA
    vxSrc = vxA
    vySrc = vyA
    sSrc = speciesA
    pxDst = pxB
    pyDst = pyB
    vxDst = vxB
    vyDst = vyB
    sDst = speciesB
  else:
    pxSrc = pxB
    pySrc = pyB
    vxSrc = vxB
    vySrc = vyB
    sSrc = speciesB
    pxDst = pxA
    pyDst = pyA
    vxDst = vxA
    vyDst = vyA
    sDst = speciesA

  # Clear counts - clear entire buffer to prevent stale data access
  # WASM might access cells beyond numCells if particle positions are out of bounds
  let maxCells = gridCounts.len
  for i in 0 ..< maxCells:
    gridCounts[i] = 0

  # Count particles per cell using source positions
  for i in 0 ..< n:
    var cx = int(pxSrc[i] * invCellW)
    var cy = int(pySrc[i] * invCellH)

    if cx >= gridW:
      cx = gridW - 1
    elif cx < 0:
      cx = 0

    if cy >= gridH:
      cy = gridH - 1
    elif cy < 0:
      cy = 0

    let cellIdx = cy * gridW + cx
    gridCounts[cellIdx] = gridCounts[cellIdx] + 1

  # Prefix sum for offsets
  var off = 0
  for i in 0 ..< numCells:
    gridOffsets[i] = off
    fillOffsets[i] = off  # Keep a copy for filling
    off = off + gridCounts[i]

  # SCATTER: Reorder particles into destination buffers
  # This is the sort - particles are copied to contiguous positions by cell
  for i in 0 ..< n:
    var cx = int(pxSrc[i] * invCellW)
    var cy = int(pySrc[i] * invCellH)

    if cx >= gridW:
      cx = gridW - 1
    elif cx < 0:
      cx = 0

    if cy >= gridH:
      cy = gridH - 1
    elif cy < 0:
      cy = 0

    let cell = cy * gridW + cx
    let dstIdx = fillOffsets[cell]
    fillOffsets[cell] = fillOffsets[cell] + 1

    # Copy all particle data to sorted position
    pxDst[dstIdx] = pxSrc[i]
    pyDst[dstIdx] = pySrc[i]
    vxDst[dstIdx] = vxSrc[i]
    vyDst[dstIdx] = vySrc[i]
    sDst[dstIdx] = sSrc[i]

  # Flip the buffer parity
  # Workers will now read from destination buffer (which is sorted)
  setActiveParity(1 - activeParity)

  gridTimeMs = performanceNow() - t0

  result = GridDimensions()
  result.gridW = gridW
  result.gridH = gridH
  result.cellSize = cellSize

