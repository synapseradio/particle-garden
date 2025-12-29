# ==============================================================================
# EMERGENT GARDEN - CONSOLIDATED WEB APPLICATION
# ==============================================================================
#
# Single compilation unit for the web frontend.
# All modules compile together, eliminating duplicate variable problems.
#
# This replaces the 9 separate JS files with a single app.js.
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

# Layer 1: Configuration (no dependencies)
import config
export config

# Layer 2: Buffers (depends on config)
import buffers
export buffers

# Layer 3: Browser integration modules
import renderer
export renderer

import grid
export grid

import workers
export workers

import ui
export ui

# Layer 4: WebGPU modules
import webgpu_init
export webgpu_init

import webgpu_compute
export webgpu_compute

# ==============================================================================
# BINDINGS - Helper procs
# ==============================================================================

from bindings/js_interop import
  console, jsRandom, newJsObject,
  setGlobal, getGlobal, consoleLog, consoleWarn, performanceNow

from bindings/dom_extensions import
  HTMLCanvasElement, domDocument, domWindow, addEventListener

# JsObject arithmetic operators - use explicit procs to avoid polluting native float/int types
proc jsAdd(a, b: JsObject): JsObject {.importjs: "(# + #)".}
proc jsSub(a, b: JsObject): JsObject {.importjs: "(# - #)".}
proc jsMul(a, b: JsObject): JsObject {.importjs: "(# * #)".}
proc jsLt(a, b: JsObject): JsObject {.importjs: "(# < #)".}
proc jsGe(a, b: JsObject): JsObject {.importjs: "(# >= #)".}

# Disambiguate newJsObject (both jsffi and js_interop export it)
proc makeJsObject(): JsObject {.importjs: "({})".}

# Number formatting
proc toFixed(x: float, digits: int): cstring {.importjs: "#.toFixed(#)".}

# Bitwise OR for int truncation
proc bitwiseOr(x: float, y: int): int {.importjs: "(#|#)".}

# ==============================================================================
# APPLICATION STATE
# ==============================================================================

var particleCount* {.exportc.}: int = 0
var isRunning* {.exportc.}: bool = false
var useWebGPU* {.exportc.}: bool = false

# Timing and stats
var lastTime {.exportc.}: float = 0
var frameCount {.exportc.}: int = 0
var fps {.exportc.}: int = 0
var lastFpsTime {.exportc.}: float = 0
var workerTimeMs {.exportc.}: float = 0

# Performance profiling - per-frame measurements
var gridTimeMs {.exportc.}: float = 0
var physicsTimeMs {.exportc.}: float = 0
var integrationTimeMs {.exportc.}: float = 0
var renderPackTimeMs {.exportc.}: float = 0
var renderUploadTimeMs {.exportc.}: float = 0

# Performance profiling - rolling averages
var profilingFrameCount {.exportc.}: int = 0
var gridTimeSum {.exportc.}: float = 0
var physicsTimeSum {.exportc.}: float = 0
var integrationTimeSum {.exportc.}: float = 0
var renderPackTimeSum {.exportc.}: float = 0
var renderUploadTimeSum {.exportc.}: float = 0
var totalTimeSum {.exportc.}: float = 0

# ==============================================================================
# PARTICLE INITIALIZATION
# ==============================================================================

proc initParticles*() {.exportc.} =
  ## Initialize particles with random positions and velocities.
  ## Particles are distributed evenly among species, then shuffled.

  # Get config values - direct access via imported module
  let newCount = config.CONFIG.particleCount
  particleCount = newCount
  let ns = config.CONFIG.speciesCount

  # Get canvas dimensions
  let W = float(renderer.canvas.width)
  let H = float(renderer.canvas.height)

  # Initialize buffer A as starting point
  for i in 0 ..< particleCount:
    buffers.pxA[i] = jsRandom() * W
    buffers.pyA[i] = jsRandom() * H
    buffers.vxA[i] = (jsRandom() - 0.5) * 2.0
    buffers.vyA[i] = (jsRandom() - 0.5) * 2.0
    buffers.speciesA[i] = i mod ns

  # Fisher-Yates shuffle for even species distribution
  for i in countdown(particleCount - 1, 1):
    let j = bitwiseOr(jsRandom() * float(i + 1), 0)
    let t = buffers.speciesA[i]
    buffers.speciesA[i] = buffers.speciesA[j]
    buffers.speciesA[j] = t

  ui.updateParticleStats(particleCount)

  # Upload to GPU if using WebGPU (ensures GPU has current particle data)
  if useWebGPU:
    discard webgpu_compute.uploadInitialData(particleCount)

proc resetParticles*() {.exportc.} =
  ## Reset particles to initial random state.
  buffers.activeParity = 0  # Reset to buffer A
  initParticles()  # This now handles GPU upload internally

# ==============================================================================
# PHYSICS (DUAL PATH: WebGPU or WASM)
# ==============================================================================

proc physics(dt: float): Future[void] {.async.} =
  ## Run one physics step using WebGPU compute shaders (if available) or WASM workers.

  let t0 = performanceNow()

  if useWebGPU and webgpu_compute.isPipelineReady:
    # ═══════════════════════════════════════════════════════════════════════
    # WebGPU Compute Path (ALL computation on GPU)
    # ═══════════════════════════════════════════════════════════════════════

    # Only compute grid dimensions - no CPU sorting
    let gridResult = grid.computeGridDimensions(renderer.canvas.width, renderer.canvas.height)
    gridTimeMs = 0  # Grid built on GPU

    let tPhysics0 = performanceNow()

    # Build physics params object
    let params = makeJsObject()
    params["dt"] = toJs(dt)
    params["particleCount"] = toJs(particleCount)
    params["width"] = toJs(renderer.canvas.width)
    params["height"] = toJs(renderer.canvas.height)
    params["gridW"] = gridResult["gridW"]
    params["gridH"] = gridResult["gridH"]
    params["rMax"] = toJs(config.CONFIG.interactionRadius)
    params["fMul"] = toJs(config.CONFIG.forceStrength)
    params["friction"] = toJs(1.0 - config.CONFIG.friction)
    params["mouseX"] = toJs(ui.mouseX)
    params["mouseY"] = toJs(ui.mouseY)
    params["mouseDown"] = toJs(if ui.mouseDown: 1 else: 0)
    params["mouseRightDown"] = toJs(if ui.mouseRightDown: 1 else: 0)
    params["parity"] = toJs(buffers.activeParity)  # Use current parity
    params["matrix"] = toJs(buffers.matrix)

    await webgpu_compute.runPhysicsFrame(params)

    physicsTimeMs = performanceNow() - tPhysics0
    integrationTimeMs = 0  # Integration happens on GPU

    workerTimeMs = performanceNow() - t0
  else:
    # ═══════════════════════════════════════════════════════════════════════
    # WASM Worker Path (CPU parallel)
    # ═══════════════════════════════════════════════════════════════════════

    # Phase 1: Build spatial grid - sorts particles by cell and flips parity
    let tGrid0 = performanceNow()
    let gridResult = grid.buildGrid(particleCount, renderer.canvas.width, renderer.canvas.height)
    gridTimeMs = performanceNow() - tGrid0

    # Phase 2: Dispatch to WASM workers - they compute velocity deltas
    let tPhysics0 = performanceNow()
    await workers.dispatchPhysicsShared(
      dt,
      particleCount,
      float(renderer.canvas.width),
      float(renderer.canvas.height),
      gridResult["gridW"].to(int),
      gridResult["gridH"].to(int),
      float(gridResult["cellSize"].to(int)),
      ui.mouseX,
      ui.mouseY,
      ui.mouseDown,
      ui.mouseRightDown
    )
    physicsTimeMs = performanceNow() - tPhysics0

    # Phase 3: Integration - apply velocity deltas and integrate positions
    let tIntegration0 = performanceNow()

    # Select active buffer (buildGrid flipped parity)
    let currentParity = buffers.activeParity
    let pxActive = if currentParity == 1: buffers.pxB else: buffers.pxA
    let pyActive = if currentParity == 1: buffers.pyB else: buffers.pyA
    let vxActive = if currentParity == 1: buffers.vxB else: buffers.vxA
    let vyActive = if currentParity == 1: buffers.vyB else: buffers.vyA
    let vxDeltaArr = buffers.vxDelta
    let vyDeltaArr = buffers.vyDelta

    let W = toJs(renderer.canvas.width)
    let H = toJs(renderer.canvas.height)
    let friction = toJs(1.0 - config.CONFIG.friction)
    let zero = toJs(0)

    # Apply velocity deltas and integrate positions
    for i in 0 ..< particleCount:
      # Apply delta and friction
      vxActive[i] = jsMul(jsAdd(vxActive[i], vxDeltaArr[i]), friction)
      vyActive[i] = jsMul(jsAdd(vyActive[i], vyDeltaArr[i]), friction)

      # Update position
      var x = jsAdd(pxActive[i], vxActive[i])
      var y = jsAdd(pyActive[i], vyActive[i])

      # Toroidal wrap
      if jsLt(x, zero).to(bool): x = jsAdd(x, W)
      elif jsGe(x, W).to(bool): x = jsSub(x, W)
      if jsLt(y, zero).to(bool): y = jsAdd(y, H)
      elif jsGe(y, H).to(bool): y = jsSub(y, H)

      pxActive[i] = x
      pyActive[i] = y

    integrationTimeMs = performanceNow() - tIntegration0

    workerTimeMs = performanceNow() - t0

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

  let renderTiming = renderer.render(particleCount)
  renderPackTimeMs = renderTiming["packTimeMs"].to(float)
  renderUploadTimeMs = renderTiming["uploadTimeMs"].to(float)

  let frameTotal = performanceNow() - frameStart

  # Accumulate profiling data
  gridTimeSum = gridTimeSum + gridTimeMs
  physicsTimeSum = physicsTimeSum + physicsTimeMs
  integrationTimeSum = integrationTimeSum + integrationTimeMs
  renderPackTimeSum = renderPackTimeSum + renderPackTimeMs
  renderUploadTimeSum = renderUploadTimeSum + renderUploadTimeMs
  totalTimeSum = totalTimeSum + frameTotal
  profilingFrameCount = profilingFrameCount + 1

  # Update FPS and stats every 500ms
  frameCount = frameCount + 1
  if now - lastFpsTime > 500.0:
    fps = bitwiseOr(float(frameCount * 1000) / (now - lastFpsTime), 0)
    frameCount = 0
    lastFpsTime = now
    ui.updateStats(fps, 0, workerTimeMs)

  # Reset profiling accumulators every 60 frames
  if profilingFrameCount >= 60:
    profilingFrameCount = 0
    gridTimeSum = 0
    physicsTimeSum = 0
    integrationTimeSum = 0
    renderPackTimeSum = 0
    renderUploadTimeSum = 0
    totalTimeSum = 0

  discard domWindow.requestAnimationFrame(proc(t: float) = discard loop(t))

# ==============================================================================
# INITIALIZATION
# ==============================================================================

proc init(): Future[void] {.async, exportc.} =
  ## Initialize the application.

  # Allocate shared memory buffers
  buffers.allocateBuffers()

  # Initialize WebGL
  if not renderer.initGL():
    return

  # Set up callbacks for UI events
  ui.setInitParticlesCallback(initParticles)
  ui.setResizeCallback(renderer.resize)

  # Set up UI bindings
  ui.setupUI()

  # Set up event handlers (pass canvas from renderer)
  ui.setupEvents(renderer.canvas)

  # Try to initialize WebGPU (optional acceleration)
  consoleLog(toJs("Attempting WebGPU initialization..."))
  let webgpuResult = await webgpu_init.initWebGPU()
  if webgpuResult["success"].to(bool):
    consoleLog(toJs("WebGPU device acquired:"), webgpuResult["info"])
    consoleLog(toJs("Initializing WebGPU compute pipelines..."))
    let pipelineResult = await webgpu_compute.initPipelines()
    if pipelineResult["success"].to(bool):
      consoleLog(toJs("WebGPU compute pipelines ready:"), pipelineResult["info"])
      useWebGPU = true
      consoleLog(toJs("Physics acceleration: WebGPU compute shaders"))
    else:
      consoleWarn(toJs("WebGPU pipeline initialization failed:"), pipelineResult["error"])
      consoleLog(toJs("Falling back to WASM workers"))
  else:
    consoleWarn(toJs("WebGPU not available:"), webgpuResult["error"])
    consoleLog(toJs("Using WASM workers for physics"))

  # Set matrix update callback
  ui.setMatrixUpdateCallback(proc() = workers.updateWorkersMatrix())

  # Initialize attraction matrix with random values
  ui.randomizeMatrix()

  # Initialize particles
  initParticles()

  # Upload particle data to GPU if using WebGPU
  if useWebGPU:
    consoleLog(toJs("Uploading initial particle data to GPU..."))
    let uploadResult = await webgpu_compute.uploadInitialData(particleCount)
    if uploadResult["success"].to(bool):
      consoleLog(toJs("Initial data uploaded to GPU"))
    else:
      consoleWarn(toJs("Failed to upload initial data:"), uploadResult["error"])
      consoleLog(toJs("Falling back to WASM workers"))
      useWebGPU = false

  # Only create worker pool if WebGPU is not available
  if not useWebGPU:
    workers.createWorkers()

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
