# ==============================================================================
# STATS VIEW - Performance statistics display
# ==============================================================================
#
# Pure types and functions for performance statistics.
# Separates stats data model from DOM rendering.
#
# ==============================================================================

from std/strutils import formatFloat, ffDecimal, insertSep

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

func initStatsState*(): StatsState =
  StatsState(
    fps: 0,
    gridTimeMs: 0.0,
    workerTimeMs: 0.0,
    particleCount: 0
  )

# ==============================================================================
# SECTION 2: IMMUTABLE UPDATES
# ==============================================================================

func withFps*(state: StatsState; fps: int): StatsState =
  result = state
  result.fps = fps

func withTiming*(state: StatsState; gridTimeMs, workerTimeMs: float): StatsState =
  result = state
  result.gridTimeMs = gridTimeMs
  result.workerTimeMs = workerTimeMs

func withParticleCount*(state: StatsState; count: int): StatsState =
  result = state
  result.particleCount = count

func withStats*(state: StatsState; fps: int; gridTimeMs, workerTimeMs: float): StatsState =
  result = state
  result.fps = fps
  result.gridTimeMs = gridTimeMs
  result.workerTimeMs = workerTimeMs

# ==============================================================================
# SECTION 3: FORMATTING
# ==============================================================================

func formatFps*(fps: int): string =
  ## Format FPS for display.
  $fps

func formatGridTime*(ms: float): string =
  ## Format grid time (2 decimal places).
  formatFloat(ms, ffDecimal, 2)

func formatWorkerTime*(ms: float): string =
  ## Format worker time (1 decimal place).
  formatFloat(ms, ffDecimal, 1)

func formatGpuTime*(ms: float): string =
  ## Format a per-pass GPU timing (2 decimal places).
  formatFloat(ms, ffDecimal, 2)

func formatParticleCount*(count: int): string =
  ## Format particle count with comma thousands separators. Deterministic
  ## replacement for JS toLocaleString: identical visible output in the
  ## default locale, but pure and locale-independent.
  insertSep($count, ',')
