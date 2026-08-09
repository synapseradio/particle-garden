# Build with `just happen` (recipe build-app in the justfile).

import std/asyncjs
from std/jsffi import JsObject, toJs, to, `[]`, `[]=`
from std/dom import Window, requestAnimationFrame

# IMPORTANT: These imports MUST remain in layer order. Each layer depends on
# the previous layers. Reordering (e.g., alphabetizing) will break compilation.
#
# Dependency chain: config → buffers → {grid, canvas_input, web_api} → webgpu_*

# Layer 1: Configuration (no dependencies)
import config

# Layer 2: Buffers (depends on config)
import buffers

# Layer 3: Browser integration modules
import grid
import canvas_input
import climate_core
import web_api

# Layer 4: WebGPU modules
import webgpu_init
import gpu_profiler
import webgpu_compute
import webgpu_render

# Layer 5: UI state types
import ui/state/app_state
import ui/state/sim_config

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

# Runtime state aggregate (isRunning, particleCount, fps, timing, profiling).
# The exportc name keeps the JS backend from losing the global's generated
# name when it emits the forward-declared loop body at its call site.
var runtimeState {.exportc: "pgAppState".}: AppState = initAppState()

var useWebGPU* {.exportc.}: bool = false

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
var climatePhase {.exportc.}: float = 0
  ## Position on the closed regime tour, when climate drift is on. Kept here
  ## rather than in the typed state because it is loop bookkeeping like
  ## lastTime: nothing reads it but the loop, no preset saves it, and it wraps
  ## rather than accumulating.
var forceWeatherPhase {.exportc.}: float = 0
  ## Position on the closed force tour, on the same terms. Separate from
  ## climatePhase so each weather holds its own place: sharing one would drag
  ## the forces to wherever the climate had wandered the moment someone switched
  ## the force weather on.

# Per-frame timing staging; folded into runtimeState via withTiming each frame
var currentTiming* = initTimingState()

proc initParticles*() {.exportc.} =
  ## Positions are in WORLD coordinates (decoupled from canvas).

  let newCount = config.CONFIG.particleCount
  runtimeState = runtimeState.withParticleCount(newCount)
  let ns = config.CONFIG.speciesCount

  let worldWidth = config.WORLD_W
  let worldHeight = config.WORLD_H

  # The GPU-owned density channels (sphDensity, crowdDensity) are left at the
  # zero the shared buffer was allocated with — no CPU writer touches either
  # slot, so a fresh world starts uncrowded and the integrate pass fills them
  # from the first frame onward.
  for particleIndex in 0 ..< newCount:
    let base = particleIndex * buffers.FLOATS_PER_PARTICLE
    buffers.particlesA[base + buffers.FIELD_POS_X] = jsRandom() * worldWidth
    buffers.particlesA[base + buffers.FIELD_POS_Y] = jsRandom() * worldHeight
    buffers.particlesA[base + buffers.FIELD_VEL_X] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_VEL_Y] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_SPECIES] = float32(particleIndex mod ns)
    buffers.particlesA[base + buffers.FIELD_DENSITY] = 0.0

  # Fisher-Yates shuffle for even species distribution
  for shuffleIndex in countdown(newCount - 1, 1):
    let swapIndex = bitwiseOr(jsRandom() * float(shuffleIndex + 1), 0)
    let shuffleBase = shuffleIndex * buffers.FLOATS_PER_PARTICLE + buffers.FIELD_SPECIES
    let swapBase = swapIndex * buffers.FLOATS_PER_PARTICLE + buffers.FIELD_SPECIES
    let tempSpecies = buffers.particlesA[shuffleBase]
    buffers.particlesA[shuffleBase] = buffers.particlesA[swapBase]
    buffers.particlesA[swapBase] = tempSpecies

  if useWebGPU:
    discard webgpu_compute.uploadInitialData(newCount)

proc resizeParticles*() {.exportc.} =
  ## Change how many particles the world runs without restarting it, so the
  ## slider can feed a settled world or thin a clogged one. The reset control is
  ## how you ask for a fresh world.
  ##
  ## Lowering the count keeps every survivor where it is — the simulation just
  ## stops iterating past the new count. Raising it seeds and uploads only the
  ## arrivals, leaving the living population untouched.
  let previousCount = runtimeState.particleCount
  let newCount = config.CONFIG.particleCount
  if newCount == previousCount:
    return
  runtimeState = runtimeState.withParticleCount(newCount)
  if newCount < previousCount:
    return

  let ns = config.CONFIG.speciesCount
  for particleIndex in previousCount ..< newCount:
    let base = particleIndex * buffers.FLOATS_PER_PARTICLE
    buffers.particlesA[base + buffers.FIELD_POS_X] = jsRandom() * config.WORLD_W
    buffers.particlesA[base + buffers.FIELD_POS_Y] = jsRandom() * config.WORLD_H
    buffers.particlesA[base + buffers.FIELD_VEL_X] = (jsRandom() - 0.5) * 2.0
    buffers.particlesA[base + buffers.FIELD_VEL_Y] = (jsRandom() - 0.5) * 2.0
    # Species drawn at random rather than round-robin. The arrivals are joining
    # a population whose species balance the user may have already shifted, and
    # a deterministic cycle over a handful of new particles would bias whichever
    # species the cycle happened to start on.
    buffers.particlesA[base + buffers.FIELD_SPECIES] =
      float32(bitwiseOr(jsRandom() * float(ns), 0))
    buffers.particlesA[base + buffers.FIELD_DENSITY] = 0.0

  if useWebGPU:
    webgpu_compute.uploadParticleRange(previousCount, newCount)

proc resetParticles*() {.exportc.} =
  initParticles()  # also triggers the GPU upload

proc physics(dt: float): Future[void] {.async.} =
  let physicsStart = performanceNow()

  if not (useWebGPU and webgpu_compute.isPipelineReady):
    consoleWarn(toJs("WebGPU not ready - skipping physics frame"))
    return

  # Sorting runs in the GPU bin-count/prefix-sum/bin-scatter passes; this only
  # sizes the grid.
  let gridResult = grid.computeGridDimensions(canvasWidth(), canvasHeight())
  currentTiming.gridTimeMs = 0  # Grid built on GPU

  let tPhysics0 = performanceNow()

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
  let mouseScaleX = config.WORLD_W / float(canvasWidth())
  let mouseScaleY = config.WORLD_H / float(canvasHeight())
  params["mouseX"] = toJs(canvas_input.getMouseX() * mouseScaleX)
  params["mouseY"] = toJs(canvas_input.getMouseY() * mouseScaleY)
  params["mouseDown"] = toJs(if canvas_input.getMouseDown(): 1 else: 0)
  params["mouseRightDown"] = toJs(if canvas_input.getMouseRightDown(): 1 else: 0)
  params["blastX"] = toJs(canvas_input.getBlastX() * mouseScaleX)
  params["blastY"] = toJs(canvas_input.getBlastY() * mouseScaleY)
  params["blastStrength"] = toJs(canvas_input.getBlastStrength())
  params["matrix"] = toJs(buffers.matrix)

  await webgpu_compute.runPhysicsFrame(params)

  canvas_input.updateInputState()

  currentTiming.physicsTimeMs = performanceNow() - tPhysics0
  currentTiming.integrationTimeMs = 0  # Integration happens on GPU

  computeTimeMs = performanceNow() - physicsStart

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

  # The weather, when it is switched on. Advanced by WALL-CLOCK seconds
  # (cappedDt) rather than by the timeScale-scaled dt: "one tour of the regimes
  # a minute" should mean a minute, not a minute divided by how fast the
  # simulation happens to be running.
  #
  # It writes through web_api's ordinary setParam path, so the toured sliders
  # visibly move and the panel keeps telling the truth about the state. Writing
  # CONFIG directly here would be a frame cheaper and would leave the UI lying,
  # so the visible path is required.
  #
  # The tour point travels whole. Which parameters it lands on is climate_core's
  # to say (CLIMATE_PARAM_IDS), so this loop never names an axis and an added
  # one needs nothing here.
  if config.CONFIG.climateDrift:
    climatePhase = tourAdvance(
      climatePhase, config.CONFIG.climateSpeed, cappedDt)
    web_api.setClimateFromSimulation(tourAt(RD_CLIMATE_TOUR, climatePhase))

  # The force weather, on the same terms and the same wall clock. Its own phase,
  # so switching one weather on does not move the other's position, and its own
  # speed, so the two can run at rates that suit what each of them changes.
  if config.CONFIG.forceWeather:
    forceWeatherPhase = tourAdvance(
      forceWeatherPhase, config.CONFIG.forceWeatherSpeed, cappedDt)
    web_api.setForceWeatherFromSimulation(
      tourAt(FORCE_WEATHER_TOUR, forceWeatherPhase))

  await physics(dt)

  # Render using WebGPU - data stays on GPU, no readback needed. Render/glow
  # bind groups are built once at init (webgpu_render.initWebGPURender);
  # nothing about them varies per frame, so they are never rebuilt here.
  webgpu_render.render(runtimeState.particleCount)

  currentTiming.frameTimeMs = performanceNow() - frameStart
  currentTiming.computeTimeMs = computeTimeMs

  runtimeState = runtimeState.withTiming(currentTiming).accumulateProfiling()

  frameCount = frameCount + 1
  if now - lastFpsTime > 500.0:
    runtimeState = runtimeState.withFps(
      bitwiseOr(float(frameCount * 1000) / (now - lastFpsTime), 0))
    frameCount = 0
    lastFpsTime = now
    var gpuGridMs = 0.0
    var gpuPhysicsMs = 0.0
    var gpuDrawMs = 0.0
    var gpuPresentMs = 0.0
    var gpuFieldMs = 0.0
    if gpu_profiler.isActive():
      # Grid build and the field are both world-intrinsic, so both slots carry
      # a real number every frame. They stay separate so neither time can
      # stand in for the other.
      gpuGridMs = gpu_profiler.passTimeMs(gpu_profiler.passGridBuild)
      # Force pass plus integrate. They are separate slots because composable
      # frames put the field passes between them, but "physics" means both,
      # and splitting the reported number would silently break every
      # comparison against a recorded baseline.
      gpuPhysicsMs = gpu_profiler.passTimeMs(gpu_profiler.passPhysics) +
        gpu_profiler.passTimeMs(gpu_profiler.passIntegrate)
      gpuDrawMs = gpu_profiler.passTimeMs(gpu_profiler.passDraw)
      gpuPresentMs = gpu_profiler.passTimeMs(gpu_profiler.passPresent)
      gpuFieldMs = gpu_profiler.passTimeMs(gpu_profiler.passField)
      let bloomMs = gpu_profiler.passTimeMs(gpu_profiler.passBloom)
      # Leave a capturable baseline record in the console every ~5s
      gpuLogCounter = gpuLogCounter + 1
      if gpuLogCounter >= 10:
        gpuLogCounter = 0
        logGpuProfile(runtimeState.particleCount, gpuGridMs, gpuPhysicsMs,
          gpuDrawMs, gpuPresentMs, bloomMs)
    web_api.pushStats(runtimeState.fps, runtimeState.particleCount, 0,
      computeTimeMs, gpuGridMs, gpuPhysicsMs, gpuDrawMs, gpuPresentMs,
      gpuFieldMs, webgpu_compute.latestFieldAliveCells())

  if runtimeState.profiling.frameCount >= 60:
    runtimeState = runtimeState.resetProfiling()

  discard domWindow.requestAnimationFrame(proc(timestamp: float) = discard loop(timestamp))

proc init(): Future[void] {.async, exportc.} =
  ## Requires WebGPU; there is no fallback path.

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

  buffers.allocateBuffers()

  consoleLog(toJs("Initializing WebGPU..."))
  let webgpuResult = await webgpu_init.initWebGPU()
  if not webgpuResult["success"].to(bool):
    consoleError(toJs("WebGPU initialization failed:"), webgpuResult["error"])
    consoleError(toJs("This application requires WebGPU. Please use a browser with WebGPU support."))
    web_api.showWebGpuRequiredOverlay()
    return

  consoleLog(toJs("WebGPU device acquired:"), webgpuResult["info"])

  gpu_profiler.initProfiler()

  consoleLog(toJs("Initializing WebGPU compute pipelines..."))
  let pipelineResult = await webgpu_compute.initPipelines()
  if not pipelineResult["success"].to(bool):
    consoleError(toJs("WebGPU pipeline initialization failed:"), pipelineResult["error"])
    web_api.showWebGpuRequiredOverlay()
    return

  consoleLog(toJs("WebGPU compute pipelines ready:"), pipelineResult["info"])
  useWebGPU = true
  consoleLog(toJs("Physics acceleration: WebGPU compute shaders"))

  consoleLog(toJs("Initializing WebGPU render pipeline..."))
  if not webgpu_render.initWebGPURender():
    consoleError(toJs("WebGPU render pipeline initialization failed."))
    web_api.showWebGpuRequiredOverlay()
    return
  consoleLog(toJs("WebGPU rendering: ENABLED (zero CPU readback)"))

  canvas_input.setInitParticlesCallback(initParticles)
  canvas_input.setResizeParticlesCallback(resizeParticles)
  canvas_input.setResizeCallback(webgpu_render.resize)
  canvas_input.setReseedFieldCallback(webgpu_compute.requestFieldSeed)
  # Camera hooks. canvas_input sits a layer below webgpu_render and cannot read
  # the camera directly, so the wheel and key handlers reach it through these.
  # Wired BEFORE setupEvents, so no event can arrive against a nil hook.
  canvas_input.cameraGetter = webgpu_render.camera
  canvas_input.cameraSetter = webgpu_render.setCamera
  canvas_input.setupEvents(cast[JsObject](webgpu_render.canvas))

  # A strength crossing zero drives the compute executor's frame description.
  subscribeSimple(sim_config.worldCouplings, proc(couplings: WorldCouplings) =
    webgpu_compute.setCouplings(couplings))

  web_api.randomizeMatrix()

  initParticles()

  consoleLog(toJs("Uploading initial particle data to GPU..."))
  let uploadResult = await webgpu_compute.uploadInitialData(runtimeState.particleCount)
  if not uploadResult["success"].to(bool):
    consoleError(toJs("Failed to upload initial data:"), uploadResult["error"])
    return

  consoleLog(toJs("Initial data uploaded to GPU"))

  # Optional ?bloom=0|1 URL override for the HDR bloom path (machine interface,
  # like ?n=/?seed= — never a user-facing surface). Routes through
  # web_api.setBloomImpl, the same path gardenAPI's bloom toggle uses.
  if urlParamHas("bloom"):
    web_api.setBloomImpl(urlParamInt("bloom", 0) != 0)

  lastTime = performanceNow()
  lastFpsTime = lastTime
  runtimeState = runtimeState.withRunning(true)
  discard domWindow.requestAnimationFrame(proc(timestamp: float) = discard loop(timestamp))

  # Buffers and pipelines exist now; release gardenAPI consumers waiting on
  # matrix/COLORS/stats access.
  web_api.signalReady()

domDocument.addEventListener("DOMContentLoaded", proc() = discard init())
