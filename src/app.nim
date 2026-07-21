# ==============================================================================
# PARTICLE GARDEN - CONSOLIDATED WEB APPLICATION
# ==============================================================================
#
# Single compilation unit for the web frontend.
# All modules compile together, eliminating duplicate variable problems.
#
# ARCHITECTURE: WebGPU-only physics and rendering.
# The WASM worker path has been removed; all computation runs on GPU.
#
# Compile with: nim js -d:release --out:web/app.js src/app.nim
#
# ==============================================================================

import std/asyncjs
from std/jsffi import JsObject, toJs, to, `[]`, `[]=`
from std/dom import Window, requestAnimationFrame

# ==============================================================================
# CORE MODULES - Import in dependency order
# ==============================================================================
#
# IMPORTANT: These imports MUST remain in layer order. Each layer depends on
# the previous layers. Reordering (e.g., alphabetizing) will break compilation.
#
# Dependency chain: config → buffers → {grid, ui} → webgpu_*
#

# Layer 1: Configuration (no dependencies)
import config

# Layer 2: Buffers (depends on config)
import buffers

# Layer 3: Browser integration modules
import grid
import ui

# Layer 4: WebGPU modules
import webgpu_init
import gpu_profiler
import webgpu_compute
import webgpu_render

# Layer 5: UI state types
import ui/state/app_state
import ui/state/sim_config

# ==============================================================================
# BINDINGS - Helper procs
# ==============================================================================

from bindings/js_interop import
  console, jsRandom, newJsObject, setRandomSeed,
  setGlobal, getGlobal, consoleLog, consoleWarn, consoleError, performanceNow

from bindings/dom_extensions import
  HTMLCanvasElement, domDocument, domWindow, addEventListener

import bindings/typed_arrays

# Disambiguate newJsObject (both jsffi and js_interop export it)
proc makeJsObject(): JsObject {.importjs: "({})".}

# Bitwise OR for int truncation
proc bitwiseOr(value: float, mask: int): int {.importjs: "(#|#)".}
proc logGpuProfile(particleCount: int, gridMs: float, physicsMs: float, drawMs: float,
                   presentMs: float, bloomMs: float) {.importjs: "console.log('[gpu-profile] n=' + # + ' grid=' + #.toFixed(3) + 'ms physics=' + #.toFixed(3) + 'ms draw=' + #.toFixed(3) + 'ms present=' + #.toFixed(3) + 'ms bloom=' + #.toFixed(3) + 'ms')".}
proc urlParamInt(name: cstring, fallback: int): int {.importjs: "(parseInt(new URLSearchParams(location.search).get(#)) || #)".}
proc urlParamHas(name: cstring): bool {.importjs: "(new URLSearchParams(location.search).has(#))".}
proc urlParamStr(name: cstring): cstring {.importjs: "(new URLSearchParams(location.search).get(#) || '')".}

# ==============================================================================
# APPLICATION STATE
# ==============================================================================

# Runtime state aggregate (isRunning, particleCount, fps, timing, profiling).
# The exportc name keeps the JS backend from losing the global's generated
# name when it emits the forward-declared loop body at its call site.
var runtimeState {.exportc: "pgAppState".}: AppState = initAppState()

var useWebGPU* {.exportc.}: bool = false

# Canvas dimension helpers
proc canvasWidth*(): int =
  webgpu_render.canvas.width

proc canvasHeight*(): int =
  webgpu_render.canvas.height

# Loop-local timing accumulators (not part of the AppState model)
var lastTime {.exportc.}: float = 0
var frameCount {.exportc.}: int = 0
var lastFpsTime {.exportc.}: float = 0
var computeTimeMs {.exportc.}: float = 0
var gpuLogCounter {.exportc.}: int = 0

# Per-frame timing staging; folded into runtimeState via withTiming each frame
var currentTiming* = initTimingState()

# ==============================================================================
# PARTICLE INITIALIZATION
# ==============================================================================

proc initParticles*() {.exportc.} =
  ## Initialize particles with random positions and velocities.
  ## Particles are distributed evenly among species, then shuffled.
  ## Positions are in WORLD coordinates (decoupled from canvas).

  # Get config values - direct access via imported module
  let newCount = config.CONFIG.particleCount
  runtimeState = runtimeState.withParticleCount(newCount)
  let ns = config.CONFIG.speciesCount

  # Use WORLD dimensions for particle positions (physics domain)
  let worldWidth = config.WORLD_W
  let worldHeight = config.WORLD_H

  # Initialize particlesA buffer using AoS layout
  # Struct: pos.x(0), pos.y(1), vel.x(2), vel.y(3), species(4), density(5), pad(6-7)
  for particleIndex in 0 ..< newCount:
    let base = particleIndex * buffers.FLOATS_PER_PARTICLE  # 8 floats per particle
    buffers.particlesA[base + buffers.FIELD_POS_X] = jsRandom() * worldWidth
    buffers.particlesA[base + buffers.FIELD_POS_Y] = jsRandom() * worldHeight
    buffers.particlesA[base + buffers.FIELD_VEL_X] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_VEL_Y] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_SPECIES] = float32(particleIndex mod ns)
    buffers.particlesA[base + buffers.FIELD_DENSITY] = 0.0

  # Fisher-Yates shuffle for even species distribution
  # Swap species values within AoS layout
  for shuffleIndex in countdown(newCount - 1, 1):
    let swapIndex = bitwiseOr(jsRandom() * float(shuffleIndex + 1), 0)
    let shuffleBase = shuffleIndex * buffers.FLOATS_PER_PARTICLE + buffers.FIELD_SPECIES
    let swapBase = swapIndex * buffers.FLOATS_PER_PARTICLE + buffers.FIELD_SPECIES
    let tempSpecies = buffers.particlesA[shuffleBase]
    buffers.particlesA[shuffleBase] = buffers.particlesA[swapBase]
    buffers.particlesA[swapBase] = tempSpecies

  ui.updateParticleStats(newCount)

  # Upload to GPU if using WebGPU (ensures GPU has current particle data)
  if useWebGPU:
    discard webgpu_compute.uploadInitialData(newCount)

proc resetParticles*() {.exportc.} =
  ## Reset particles to initial random state.
  initParticles()  # This now handles GPU upload internally

# ==============================================================================
# PHYSICS (WebGPU Compute)
# ==============================================================================

proc physics(dt: float): Future[void] {.async.} =
  ## Run one physics step using WebGPU compute shaders.
  ## All computation (grid building, forces, integration) happens on GPU.

  let physicsStart = performanceNow()

  if not (useWebGPU and webgpu_compute.isPipelineReady):
    # WebGPU not available - cannot run physics
    consoleWarn(toJs("WebGPU not ready - skipping physics frame"))
    return

  # ═══════════════════════════════════════════════════════════════════════
  # WebGPU Compute Path (ALL computation on GPU)
  # ═══════════════════════════════════════════════════════════════════════

  # Only compute grid dimensions - no CPU sorting
  let gridResult = grid.computeGridDimensions(canvasWidth(), canvasHeight())
  currentTiming.gridTimeMs = 0  # Grid built on GPU

  let tPhysics0 = performanceNow()

  # Build physics params object
  # NOTE: Physics uses WORLD dimensions, not canvas dimensions
  let params = makeJsObject()
  params["dt"] = toJs(dt)
  params["particleCount"] = toJs(runtimeState.particleCount)
  params["width"] = toJs(config.WORLD_W)
  params["height"] = toJs(config.WORLD_H)
  params["gridW"] = gridResult["gridW"]
  params["gridH"] = gridResult["gridH"]
  params["rMax"] = toJs(config.CONFIG.interactionRadius)
  params["fMul"] = toJs(config.CONFIG.forceStrength)
  params["friction"] = toJs(1.0 - config.CONFIG.friction)
  # Scale mouse from canvas to world coordinates
  let mouseScaleX = config.WORLD_W / float(canvasWidth())
  let mouseScaleY = config.WORLD_H / float(canvasHeight())
  params["mouseX"] = toJs(ui.getMouseX() * mouseScaleX)
  params["mouseY"] = toJs(ui.getMouseY() * mouseScaleY)
  params["mouseDown"] = toJs(if ui.getMouseDown(): 1 else: 0)
  params["mouseRightDown"] = toJs(if ui.getMouseRightDown(): 1 else: 0)
  params["blastX"] = toJs(ui.getBlastX() * mouseScaleX)
  params["blastY"] = toJs(ui.getBlastY() * mouseScaleY)
  params["blastStrength"] = toJs(ui.getBlastStrength())
  params["matrix"] = toJs(buffers.matrix)

  await webgpu_compute.runPhysicsFrame(params)

  # Decay blast effect in observable (single source of truth)
  ui.updateInputState()

  currentTiming.physicsTimeMs = performanceNow() - tPhysics0
  currentTiming.integrationTimeMs = 0  # Integration happens on GPU

  computeTimeMs = performanceNow() - physicsStart

# ==============================================================================
# MAIN LOOP
# ==============================================================================

# Forward declaration for loop
proc loop(now: float): Future[void] {.async.}

proc loop(now: float): Future[void] {.async.} =
  ## Main animation loop.

  if not runtimeState.isRunning: return

  let frameStart = performanceNow()

  # Compute delta time, capped to prevent spiral of death
  let rawDt = (now - lastTime) / 1000.0
  let cappedDt = if rawDt > 0.05: 0.05 else: rawDt
  let dt = cappedDt * config.CONFIG.timeScale
  lastTime = now

  await physics(dt)

  # Render using WebGPU - data stays on GPU, no readback needed. Render/glow
  # bind groups are built once at init (webgpu_render.initWebGPURender);
  # nothing about them varies per frame, so they are never rebuilt here.
  let renderTiming = webgpu_render.render(runtimeState.particleCount).toJs
  currentTiming.renderPackTimeMs = renderTiming["packTimeMs"].to(float)
  currentTiming.renderUploadTimeMs = renderTiming["uploadTimeMs"].to(float)

  currentTiming.frameTimeMs = performanceNow() - frameStart
  currentTiming.computeTimeMs = computeTimeMs

  # Fold this frame's timing into the aggregate and accumulate profiling
  runtimeState = runtimeState.withTiming(currentTiming).accumulateProfiling()

  # Update FPS and stats every 500ms
  frameCount = frameCount + 1
  if now - lastFpsTime > 500.0:
    runtimeState = runtimeState.withFps(
      bitwiseOr(float(frameCount * 1000) / (now - lastFpsTime), 0))
    frameCount = 0
    lastFpsTime = now
    ui.updateStats(runtimeState.fps, 0, computeTimeMs)
    if gpu_profiler.isActive():
      let gridMs = gpu_profiler.passTimeMs(gpu_profiler.passGridBuild)
      let physicsMs = gpu_profiler.passTimeMs(gpu_profiler.passPhysics)
      let drawMs = gpu_profiler.passTimeMs(gpu_profiler.passDraw)
      let presentMs = gpu_profiler.passTimeMs(gpu_profiler.passPresent)
      let bloomMs = gpu_profiler.passTimeMs(gpu_profiler.passBloom)
      ui.updateGpuTimes(gridMs, physicsMs, drawMs, presentMs)
      # Leave a capturable baseline record in the console every ~5s
      gpuLogCounter = gpuLogCounter + 1
      if gpuLogCounter >= 10:
        gpuLogCounter = 0
        logGpuProfile(runtimeState.particleCount, gridMs, physicsMs, drawMs,
          presentMs, bloomMs)

  # Reset profiling accumulators every 60 frames
  if runtimeState.profiling.frameCount >= 60:
    runtimeState = runtimeState.resetProfiling()

  discard domWindow.requestAnimationFrame(proc(timestamp: float) = discard loop(timestamp))

# ==============================================================================
# INITIALIZATION
# ==============================================================================

proc init(): Future[void] {.async, exportc.} =
  ## Initialize the application.
  ## Requires WebGPU - no fallback to WASM workers.

  # Optional ?n=<count> URL override for profiling runs at a chosen scale
  let requestedCount = urlParamInt("n", config.CONFIG.particleCount)
  config.CONFIG.particleCount = clamp(requestedCount, 1000, config.MAX_PARTICLES)

  # Optional ?seed=<int> URL override for deterministic init: routes
  # jsRandom() (matrix randomization, particle init/shuffle) through a
  # seeded PRNG instead of Math.random(), so two loads with the same seed
  # produce an identical matrix and identical initial particle state. Set
  # before any randomness is drawn below. Absent: unchanged Math.random()
  # behavior. This is a machine interface (test harness) - no UI surface.
  if urlParamHas("seed"):
    setRandomSeed(urlParamInt("seed", 0))

  # Allocate shared memory buffers
  buffers.allocateBuffers()

  # Initialize WebGPU (required - no fallback)
  consoleLog(toJs("Initializing WebGPU..."))
  let webgpuResult = await webgpu_init.initWebGPU()
  if not webgpuResult["success"].to(bool):
    consoleError(toJs("WebGPU initialization failed:"), webgpuResult["error"])
    consoleError(toJs("This application requires WebGPU. Please use a browser with WebGPU support."))
    ui.showWebGPURequiredOverlay()
    return

  consoleLog(toJs("WebGPU device acquired:"), webgpuResult["info"])

  # GPU pass profiling (no-op when timestamp-query is unavailable)
  gpu_profiler.initProfiler()

  consoleLog(toJs("Initializing WebGPU compute pipelines..."))
  let pipelineResult = await webgpu_compute.initPipelines()
  if not pipelineResult["success"].to(bool):
    consoleError(toJs("WebGPU pipeline initialization failed:"), pipelineResult["error"])
    ui.showWebGPURequiredOverlay()
    return

  consoleLog(toJs("WebGPU compute pipelines ready:"), pipelineResult["info"])
  useWebGPU = true
  consoleLog(toJs("Physics acceleration: WebGPU compute shaders"))

  # Initialize WebGPU render pipeline (zero-readback rendering)
  consoleLog(toJs("Initializing WebGPU render pipeline..."))
  if not webgpu_render.initWebGPURender():
    consoleError(toJs("WebGPU render pipeline initialization failed."))
    ui.showWebGPURequiredOverlay()
    return
  consoleLog(toJs("WebGPU rendering: ENABLED (zero CPU readback)"))

  # Set up callbacks for UI events
  ui.setInitParticlesCallback(initParticles)
  ui.setResizeCallback(webgpu_render.resize)
  ui.setupEvents(cast[JsObject](webgpu_render.canvas))

  # Set up UI bindings
  ui.setupUI()

  # Mode selector drives the compute executor's frame description
  # (qualified: webgpu_compute also exports a var named activeSimKind)
  subscribeSimple(sim_config.activeSimKind, proc(kind: SimKind) =
    webgpu_compute.setActiveSimKind(kind))

  # Set matrix update callback (no-op since matrix is in shared GPU buffer)
  ui.setMatrixUpdateCallback(proc() = discard)

  # Initialize attraction matrix with random values
  ui.randomizeMatrix()

  # Initialize particles
  initParticles()

  # Upload particle data to GPU
  consoleLog(toJs("Uploading initial particle data to GPU..."))
  let uploadResult = await webgpu_compute.uploadInitialData(runtimeState.particleCount)
  if not uploadResult["success"].to(bool):
    consoleError(toJs("Failed to upload initial data:"), uploadResult["error"])
    return

  consoleLog(toJs("Initial data uploaded to GPU"))

  # Optional ?mode=<sim-kind-id> URL override (machine interface, like ?n=/?seed=
  # — never a user-facing surface). Routes through ui.setSimMode, the same path
  # the mode buttons use, so the compute executor swaps to the requested frame.
  # Runs after setup so the activeSimKind subscription and pipelines are live.
  # An unknown id is ignored with a warning rather than crashing the loop.
  if urlParamHas("mode"):
    let requestedMode = urlParamStr("mode")
    var isKnownMode = false
    for kind in SimKind:
      if simKindId(kind) == $requestedMode:
        isKnownMode = true
    if isKnownMode:
      consoleLog(toJs("[app] ?mode= override:"), toJs(requestedMode))
      ui.setSimMode(requestedMode)
    else:
      consoleWarn(toJs("[app] unknown ?mode= value, ignoring:"), toJs(requestedMode))

  # Optional ?bloom=0|1 URL override for the HDR bloom path (machine interface,
  # like ?n=/?seed=/?mode= — never a user-facing surface). Routes through
  # ui.setBloom, the same path the bloom toggle button uses.
  if urlParamHas("bloom"):
    ui.setBloom(urlParamInt("bloom", 0) != 0)

  # Expose resetParticles globally for HTML onclick handler
  setGlobal("resetParticles", toJs(resetParticles))

  # Start animation loop
  lastTime = performanceNow()
  lastFpsTime = lastTime
  runtimeState = runtimeState.withRunning(true)
  discard domWindow.requestAnimationFrame(proc(timestamp: float) = discard loop(timestamp))

# ==============================================================================
# ENTRY POINT
# ==============================================================================

# Register DOMContentLoaded handler
domDocument.addEventListener("DOMContentLoaded", proc() = discard init())

# ==============================================================================
# WINDOW GLOBALS FOR HTML ONCLICK HANDLERS
# ==============================================================================

# These must be exposed on window for HTML onclick attributes to work
{.emit: """
window.toggleTrails = toggleTrails;
window.toggleControls = toggleControls;
window.randomizeMatrix = randomizeMatrix;
window.resetParticles = resetParticles;
""".}
