# ==============================================================================
# EMERGENT GARDEN - WORKER SYNC BUFFER PROTOCOL
# ==============================================================================
#
# This module defines the sync buffer format used for worker coordination.
# It is the ONLY place where sync buffer offsets are computed.
#
# SYNC BUFFER LAYOUT:
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ [0]     Frame counter (Atomics.wait/notify target)                          │
# │ [1]     Worker count                                                        │
# │ [2..2+W*2-1]  Worker assignment pairs: [startIdx, endIdx] × W workers       │
# │                                                                             │
# │ [configOffset + 0]   canvasWidth (float as int bits)                        │
# │ [configOffset + 1]   canvasHeight (float as int bits)                       │
# │ [configOffset + 2]   interactionRadius (float as int bits)                  │
# │ [configOffset + 3]   gridW (int)                                            │
# │ [configOffset + 4]   gridH (int)                                            │
# │ [configOffset + 5]   cellSize (float as int bits)                           │
# │ [configOffset + 6]   forceStrength (float as int bits)                      │
# │ [configOffset + 7]   dt (float as int bits)                                 │
# │ [configOffset + 8]   mouseX (float as int bits)                             │
# │ [configOffset + 9]   mouseY (float as int bits)                             │
# │ [configOffset + 10]  mouseDown (0 or 1)                                     │
# │ [configOffset + 11]  mouseRightDown (0 or 1)                                │
# │ [configOffset + 12]  activeParity (0 or 1)                                  │
# │ [configOffset + 13]  particleCount (int)                                    │
# │ [configOffset + 14]  (reserved)                                             │
# │ [configOffset + 15]  (reserved)                                             │
# │                                                                             │
# │ [doneOffset + 0..W-1]  Done flags (one per worker)                          │
# └─────────────────────────────────────────────────────────────────────────────┘
#
# WHERE:
#   W = workerCount (runtime value, read from [1])
#   configOffset = 2 + W * 2
#   doneOffset = configOffset + 16
#
# PROTOCOL:
#   1. Main thread writes config, clears done flags, increments [0]
#   2. Main thread calls Atomics.notify([0])
#   3. Workers wake from Atomics.wait([0])
#   4. Workers read config, process particle range, set done flag
#   5. Main thread awaits all done flags via Atomics.waitAsync
#
# CROSS-COMPILATION:
#   This module compiles for both `nim js` and `nim c`.
#   No jsffi or browser APIs - pure Nim.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: SYNC BUFFER INDICES
# ==============================================================================
#
# Fixed indices at the start of the sync buffer.

const
  SYNC_FRAME_COUNTER* = 0     ## Index for frame counter (Atomics target)
  SYNC_WORKER_COUNT* = 1      ## Index for worker count
  SYNC_WORKER_PAIRS_START* = 2  ## Start of worker [startIdx, endIdx] pairs

# ==============================================================================
# SECTION 2: CONFIG FIELD ENUMERATION
# ==============================================================================
#
# Named fields within the config section for type-safe access.

type
  SyncConfigField* = enum
    ## Config fields within the sync buffer, relative to configOffset.
    ## Use with configFieldIndex() to get absolute index.
    scfWidth = 0          ## Canvas width (float as int bits)
    scfHeight = 1         ## Canvas height (float as int bits)
    scfRadius = 2         ## Interaction radius (float as int bits)
    scfGridW = 3          ## Grid width in cells (int)
    scfGridH = 4          ## Grid height in cells (int)
    scfCellSize = 5       ## Cell size in pixels (float as int bits)
    scfForceStrength = 6  ## Force multiplier (float as int bits)
    scfDt = 7             ## Delta time (float as int bits)
    scfMouseX = 8         ## Mouse X position (float as int bits)
    scfMouseY = 9         ## Mouse Y position (float as int bits)
    scfMouseDown = 10     ## Left mouse button (0 or 1)
    scfMouseRightDown = 11  ## Right mouse button (0 or 1)
    scfParity = 12        ## Active buffer parity (0 or 1)
    scfParticleCount = 13  ## Number of particles (int)
    scfReserved1 = 14     ## Reserved for future use
    scfReserved2 = 15     ## Reserved for future use

# Size of config section (including reserved slots)
const SYNC_CONFIG_SIZE* = 16

# ==============================================================================
# SECTION 3: OFFSET CALCULATION FUNCTIONS
# ==============================================================================
#
# Pure functions to compute sync buffer indices.

func workerRangeOffset*(workerIndex: int): tuple[startIdx, endIdx: int] {.inline.} =
  ## Get sync buffer indices for a worker's particle range.
  ## Returns (startIdx index, endIdx index) tuple.
  let base = SYNC_WORKER_PAIRS_START + workerIndex * 2
  result = (startIdx: base, endIdx: base + 1)

func configOffset*(workerCount: int): int {.inline.} =
  ## Get sync buffer index where config section starts.
  ## Config section immediately follows worker assignment pairs.
  SYNC_WORKER_PAIRS_START + workerCount * 2

func configFieldIndex*(workerCount: int, field: SyncConfigField): int {.inline.} =
  ## Get sync buffer index for a specific config field.
  configOffset(workerCount) + ord(field)

func doneOffset*(workerCount: int): int {.inline.} =
  ## Get sync buffer index where done flags section starts.
  configOffset(workerCount) + SYNC_CONFIG_SIZE

func doneFlagIndex*(workerCount: int, workerIndex: int): int {.inline.} =
  ## Get sync buffer index for a specific worker's done flag.
  doneOffset(workerCount) + workerIndex

# ==============================================================================
# SECTION 4: HELPER FUNCTIONS
# ==============================================================================
#
# Utility functions for working with the sync protocol.

func divideParticles*(particleCount: int, workerCount: int): seq[tuple[startIdx, endIdx: int]] =
  ## Divide particles evenly among workers.
  ## Returns a sequence of (startIdx, endIdx) tuples.
  result = newSeq[tuple[startIdx, endIdx: int]](workerCount)
  let perWorker = (particleCount + workerCount - 1) div workerCount  # Ceiling division

  for i in 0 ..< workerCount:
    let startIdx = i * perWorker
    let endIdx = min(startIdx + perWorker, particleCount)
    result[i] = (startIdx: startIdx, endIdx: endIdx)

func totalSyncBufferSize*(maxWorkers: int): int =
  ## Calculate minimum sync buffer size needed for given max workers.
  ## Used for buffer allocation.
  # Frame counter (1) + worker count (1) + pairs (maxWorkers * 2) + config (16) + done flags (maxWorkers)
  1 + 1 + maxWorkers * 2 + SYNC_CONFIG_SIZE + maxWorkers

# ==============================================================================
# SECTION 5: COMPILE-TIME VALIDATION
# ==============================================================================

static:
  # Verify enum values match expected indices
  assert ord(scfWidth) == 0, "scfWidth must be index 0"
  assert ord(scfParticleCount) == 13, "scfParticleCount must be index 13"

  # Verify config size matches enum
  assert SYNC_CONFIG_SIZE == 16, "Config section must be 16 slots"
