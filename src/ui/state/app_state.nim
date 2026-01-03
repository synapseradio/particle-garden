# ==============================================================================
# APP STATE - Application runtime state
# ==============================================================================
#
# Pure state type for application runtime (running, timing, profiling).
# Can be wrapped in Observable[AppState] for reactive updates.
#
# Note: This module defines the state type. Full migration of app.nim
# globals to use this is a future step.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: TIMING STATE
# ==============================================================================

type
  TimingState* = object
    ## Per-frame timing measurements.
    gridTimeMs*: float
    physicsTimeMs*: float
    integrationTimeMs*: float
    renderPackTimeMs*: float
    renderUploadTimeMs*: float
    computeTimeMs*: float  # Total compute time
    frameTimeMs*: float    # Actual wall-clock frame time

func initTimingState*(): TimingState =
  TimingState(
    gridTimeMs: 0.0,
    physicsTimeMs: 0.0,
    integrationTimeMs: 0.0,
    renderPackTimeMs: 0.0,
    renderUploadTimeMs: 0.0,
    computeTimeMs: 0.0,
    frameTimeMs: 0.0
  )

func totalTimeMs*(state: TimingState): float =
  state.gridTimeMs + state.physicsTimeMs + state.integrationTimeMs +
    state.renderPackTimeMs + state.renderUploadTimeMs

# ==============================================================================
# SECTION 2: PROFILING STATE
# ==============================================================================

type
  ProfilingState* = object
    ## Accumulated timing for profiling averages.
    frameCount*: int
    gridTimeSum*: float
    physicsTimeSum*: float
    integrationTimeSum*: float
    renderPackTimeSum*: float
    renderUploadTimeSum*: float
    totalTimeSum*: float

func initProfilingState*(): ProfilingState =
  ProfilingState(
    frameCount: 0,
    gridTimeSum: 0.0,
    physicsTimeSum: 0.0,
    integrationTimeSum: 0.0,
    renderPackTimeSum: 0.0,
    renderUploadTimeSum: 0.0,
    totalTimeSum: 0.0
  )

func accumulate*(state: ProfilingState; timing: TimingState): ProfilingState =
  ## Add a frame's timing to profiling sums.
  result = state
  result.frameCount = state.frameCount + 1
  result.gridTimeSum = state.gridTimeSum + timing.gridTimeMs
  result.physicsTimeSum = state.physicsTimeSum + timing.physicsTimeMs
  result.integrationTimeSum = state.integrationTimeSum + timing.integrationTimeMs
  result.renderPackTimeSum = state.renderPackTimeSum + timing.renderPackTimeMs
  result.renderUploadTimeSum = state.renderUploadTimeSum + timing.renderUploadTimeMs
  result.totalTimeSum = state.totalTimeSum + timing.frameTimeMs

func reset*(state: ProfilingState): ProfilingState =
  initProfilingState()

func averageGridTime*(state: ProfilingState): float =
  if state.frameCount > 0: state.gridTimeSum / float(state.frameCount) else: 0.0

func averagePhysicsTime*(state: ProfilingState): float =
  if state.frameCount > 0: state.physicsTimeSum / float(state.frameCount) else: 0.0

func averageTotalTime*(state: ProfilingState): float =
  if state.frameCount > 0: state.totalTimeSum / float(state.frameCount) else: 0.0

# ==============================================================================
# SECTION 3: APP STATE
# ==============================================================================

type
  RenderMode* = enum
    rmWebGL,       ## Legacy WebGL renderer
    rmWebGPU       ## WebGPU compute + render

  AppState* = object
    ## Full application runtime state.
    isRunning*: bool
    renderMode*: RenderMode
    particleCount*: int
    fps*: int
    timing*: TimingState
    profiling*: ProfilingState

func initAppState*(): AppState =
  AppState(
    isRunning: false,
    renderMode: rmWebGL,
    particleCount: 0,
    fps: 0,
    timing: initTimingState(),
    profiling: initProfilingState()
  )

# ==============================================================================
# SECTION 4: IMMUTABLE UPDATES
# ==============================================================================

func withRunning*(state: AppState; running: bool): AppState =
  result = state
  result.isRunning = running

func withRenderMode*(state: AppState; mode: RenderMode): AppState =
  result = state
  result.renderMode = mode

func withParticleCount*(state: AppState; count: int): AppState =
  result = state
  result.particleCount = count

func withFps*(state: AppState; fps: int): AppState =
  result = state
  result.fps = fps

func withTiming*(state: AppState; timing: TimingState): AppState =
  result = state
  result.timing = timing

func accumulateProfiling*(state: AppState): AppState =
  result = state
  result.profiling = state.profiling.accumulate(state.timing)

func resetProfiling*(state: AppState): AppState =
  result = state
  result.profiling = initProfilingState()
