# ==============================================================================
# STATS VIEW - Performance statistics display
# ==============================================================================
#
# Pure types and functions for performance statistics.
# Separates stats data model from DOM rendering.
#
# ==============================================================================

from std/strutils import formatFloat, ffDecimal

# ==============================================================================
# SECTION 1: STATS STATE
# ==============================================================================

type
  StatsState* = object
    ## Performance statistics.
    fps*: int
    gridTimeMs*: float
    workerTimeMs*: float
    particleCount*: int

proc initStatsState*(): StatsState =
  StatsState(
    fps: 0,
    gridTimeMs: 0.0,
    workerTimeMs: 0.0,
    particleCount: 0
  )

# ==============================================================================
# SECTION 2: IMMUTABLE UPDATES
# ==============================================================================

proc withFps*(state: StatsState; fps: int): StatsState =
  result = state
  result.fps = fps

proc withTiming*(state: StatsState; gridTimeMs, workerTimeMs: float): StatsState =
  result = state
  result.gridTimeMs = gridTimeMs
  result.workerTimeMs = workerTimeMs

proc withParticleCount*(state: StatsState; count: int): StatsState =
  result = state
  result.particleCount = count

proc withStats*(state: StatsState; fps: int; gridTimeMs, workerTimeMs: float): StatsState =
  result = state
  result.fps = fps
  result.gridTimeMs = gridTimeMs
  result.workerTimeMs = workerTimeMs

# ==============================================================================
# SECTION 3: FORMATTING
# ==============================================================================

proc formatFps*(fps: int): string =
  ## Format FPS for display.
  $fps

proc formatGridTime*(ms: float): string =
  ## Format grid time (2 decimal places).
  formatFloat(ms, ffDecimal, 2)

proc formatWorkerTime*(ms: float): string =
  ## Format worker time (1 decimal place).
  formatFloat(ms, ffDecimal, 1)

proc formatParticleCount*(count: int): string =
  ## Format particle count with locale separators.
  ## Note: Actual locale formatting requires JS runtime.
  $count
