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
# Dependency chain: config → buffers → {renderer, grid, ui} → webgpu_*
#

# Layer 1: Configuration (no dependencies)
import config

# Layer 2: Buffers (depends on config)
import buffers

# Layer 3: Browser integration modules
import renderer
import grid
import ui

# Layer 4: WebGPU modules
import webgpu_init
import webgpu_compute
import webgpu_render

# Layer 5: UI state types
import ui/state/app_state

# ==============================================================================
# BINDINGS - Helper procs
# ==============================================================================

from bindings/js_interop import
  console, jsRandom, newJsObject,
  setGlobal, getGlobal, consoleLog, consoleWarn, consoleError, performanceNow

from bindings/dom_extensions import
  HTMLCanvasElement, domDocument, domWindow, addEventListener

import bindings/typed_arrays

# Disambiguate newJsObject (both jsffi and js_interop export it)
proc makeJsObject(): JsObject {.importjs: "({})".}

# Bitwise OR for int truncation
proc bitwiseOr(x: float, y: int): int {.importjs: "(#|#)".}

# ==============================================================================
# APPLICATION STATE
# ==============================================================================

var particleCount* {.exportc.}: int = 0
var isRunning* {.exportc.}: bool = false
var useWebGPU* {.exportc.}: bool = false
var useWebGPURender* {.exportc.}: bool = false  # WebGPU rendering (no readback)

# Canvas dimension helpers - use correct canvas based on active renderer
proc canvasWidth*(): int =
  if useWebGPURender:
    webgpu_render.canvas.width
  else:
    renderer.canvas["width"].to(int)

proc canvasHeight*(): int =
  if useWebGPURender:
    webgpu_render.canvas.height
  else:
    renderer.canvas["height"].to(int)

# Timing and stats
var lastTime {.exportc.}: float = 0
var frameCount {.exportc.}: int = 0
var fps {.exportc.}: int = 0
var lastFpsTime {.exportc.}: float = 0
var computeTimeMs {.exportc.}: float = 0

# Performance profiling using pure state types
var currentTiming* = initTimingState()
var profiling* = initProfilingState()

# ==============================================================================
# PARTICLE INITIALIZATION
# ==============================================================================

proc initParticles*() {.exportc.} =
  ## Initialize particles with random positions and velocities.
  ## Particles are distributed evenly among species, then shuffled.
  ## Positions are in WORLD coordinates (decoupled from canvas).

  # Get config values - direct access via imported module
  let newCount = config.CONFIG.particleCount
  particleCount = newCount
  let ns = config.CONFIG.speciesCount

  # Use WORLD dimensions for particle positions (physics domain)
  let W = config.WORLD_W
  let H = config.WORLD_H

  # Initialize particlesA buffer using AoS layout
  # Struct: pos.x(0), pos.y(1), vel.x(2), vel.y(3), species(4), density(5), pad(6-7)
  for i in 0 ..< particleCount:
    let base = i * buffers.FLOATS_PER_PARTICLE  # 8 floats per particle
    buffers.particlesA[base + buffers.FIELD_POS_X] = jsRandom() * W
    buffers.particlesA[base + buffers.FIELD_POS_Y] = jsRandom() * H
    buffers.particlesA[base + buffers.FIELD_VEL_X] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_VEL_Y] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_SPECIES] = float32(i mod ns)
    buffers.particlesA[base + buffers.FIELD_DENSITY] = 0.0

  # Fisher-Yates shuffle for even species distribution
  # Swap species values within AoS layout
  for i in countdown(particleCount - 1, 1):
    let j = bitwiseOr(jsRandom() * float(i + 1), 0)
    let iBase = i * buffers.FLOATS_PER_PARTICLE + buffers.FIELD_SPECIES
    let jBase = j * buffers.FLOATS_PER_PARTICLE + buffers.FIELD_SPECIES
    let t = buffers.particlesA[iBase]
    buffers.particlesA[iBase] = buffers.particlesA[jBase]
    buffers.particlesA[jBase] = t

  ui.updateParticleStats(particleCount)

  # Upload to GPU if using WebGPU (ensures GPU has current particle data)
  if useWebGPU:
    discard webgpu_compute.uploadInitialData(particleCount)

proc resetParticles*() {.exportc.} =
  ## Reset particles to initial random state.
  initParticles()  # This now handles GPU upload internally

# ==============================================================================
# PHYSICS (WebGPU Compute)
# ==============================================================================

proc physics(dt: float): Future[void] {.async.} =
  ## Run one physics step using WebGPU compute shaders.
  ## All computation (grid building, forces, integration) happens on GPU.

  let t0 = performanceNow()

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
  params["particleCount"] = toJs(particleCount)
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

  computeTimeMs = performanceNow() - t0

# ==============================================================================
# MAIN LOOP
# ==============================================================================

# Forward declaration for loop
proc loop(now: float): Future[void] {.async.}

proc loop(now: float): Future[void] {.async.} =
  ## Main animation loop.

  if not isRunning: return

  let frameStart = performanceNow()

  # Compute delta time, capped to prevent spiral of death
  let rawDt = (now - lastTime) / 1000.0
  let cappedDt = if rawDt > 0.05: 0.05 else: rawDt
  let dt = cappedDt * config.CONFIG.timeScale
  lastTime = now

  await physics(dt)

  # Render using WebGPU (zero readback) or WebGL (requires readback)
  var renderTiming: JsObject
  if useWebGPURender:
    # WebGPU render path - data stays on GPU, no readback needed
    webgpu_render.updateBindGroup()
    renderTiming = webgpu_render.render(particleCount).toJs
  else:
    # WebGL render path - requires CPU data
    renderTiming = renderer.render(particleCount)
  currentTiming.renderPackTimeMs = renderTiming["packTimeMs"].to(float)
  currentTiming.renderUploadTimeMs = renderTiming["uploadTimeMs"].to(float)

  currentTiming.frameTimeMs = performanceNow() - frameStart
  currentTiming.computeTimeMs = computeTimeMs

  # Accumulate profiling data using pure state update
  profiling = profiling.accumulate(currentTiming)

  # Update FPS and stats every 500ms
  frameCount = frameCount + 1
  if now - lastFpsTime > 500.0:
    fps = bitwiseOr(float(frameCount * 1000) / (now - lastFpsTime), 0)
    frameCount = 0
    lastFpsTime = now
    ui.updateStats(fps, 0, computeTimeMs)

  # Reset profiling accumulators every 60 frames
  if profiling.frameCount >= 60:
    profiling = profiling.reset()

  discard domWindow.requestAnimationFrame(proc(t: float) = discard loop(t))

# ==============================================================================
# INITIALIZATION
# ==============================================================================

proc init(): Future[void] {.async, exportc.} =
  ## Initialize the application.
  ## Requires WebGPU - no fallback to WASM workers.

  # Allocate shared memory buffers
  buffers.allocateBuffers()

  # Initialize WebGPU (required - no fallback)
  consoleLog(toJs("Initializing WebGPU..."))
  let webgpuResult = await webgpu_init.initWebGPU()
  if not webgpuResult["success"].to(bool):
    consoleError(toJs("WebGPU initialization failed:"), webgpuResult["error"])
    consoleError(toJs("This application requires WebGPU. Please use a browser with WebGPU support."))
    return

  consoleLog(toJs("WebGPU device acquired:"), webgpuResult["info"])
  consoleLog(toJs("Initializing WebGPU compute pipelines..."))
  let pipelineResult = await webgpu_compute.initPipelines()
  if not pipelineResult["success"].to(bool):
    consoleError(toJs("WebGPU pipeline initialization failed:"), pipelineResult["error"])
    return

  consoleLog(toJs("WebGPU compute pipelines ready:"), pipelineResult["info"])
  useWebGPU = true
  consoleLog(toJs("Physics acceleration: WebGPU compute shaders"))

  # Initialize WebGPU render pipeline (zero-readback rendering)
  consoleLog(toJs("Initializing WebGPU render pipeline..."))
  if webgpu_render.initWebGPURender():
    useWebGPURender = true
    consoleLog(toJs("WebGPU rendering: ENABLED (zero CPU readback)"))
  else:
    # Fall back to WebGL for rendering only (physics still on GPU)
    consoleLog(toJs("WebGPU rendering: DISABLED (will use WebGL fallback)"))
    if not renderer.initGL():
      return

  # Set up callbacks for UI events
  ui.setInitParticlesCallback(initParticles)

  # Use appropriate resize callback and canvas
  if useWebGPURender:
    ui.setResizeCallback(webgpu_render.resize)
    ui.setupEvents(cast[JsObject](webgpu_render.canvas))
  else:
    ui.setResizeCallback(renderer.resize)
    ui.setupEvents(renderer.canvas)

  # Set up UI bindings
  ui.setupUI()

  # Set matrix update callback (no-op since matrix is in shared GPU buffer)
  ui.setMatrixUpdateCallback(proc() = discard)

  # Initialize attraction matrix with random values
  ui.randomizeMatrix()

  # Initialize particles
  initParticles()

  # Upload particle data to GPU
  consoleLog(toJs("Uploading initial particle data to GPU..."))
  let uploadResult = await webgpu_compute.uploadInitialData(particleCount)
  if not uploadResult["success"].to(bool):
    consoleError(toJs("Failed to upload initial data:"), uploadResult["error"])
    return

  consoleLog(toJs("Initial data uploaded to GPU"))

  # Expose resetParticles globally for HTML onclick handler
  setGlobal("resetParticles", toJs(resetParticles))

  # Start animation loop
  lastTime = performanceNow()
  lastFpsTime = lastTime
  isRunning = true
  discard domWindow.requestAnimationFrame(proc(t: float) = discard loop(t))

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
