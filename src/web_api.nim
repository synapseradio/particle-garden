# ==============================================================================
# PARTICLE GARDEN - WEB API (window.gardenAPI)
# ==============================================================================
#
# The one boundary the TypeScript UI talks through. A single `gardenAPI`
# object is created at module-eval time (before the Solid bundle evaluates)
# and installed on the global object; everything that mutates state routes
# through the same typed update helpers the Nim UI uses.
#
# THE SYNCHRONOUS MIRROR INVARIANT (do not break this from the TS side):
# every parameter write lands in the typed store AND the flat GPU-facing
# CONFIG in the same tick, via ui.nim's updateSimulation/updateRender. The
# mirroring must never become async (no subscriptions, no microtasks): the
# frame loop reads CONFIG fresh every frame, and a deferred mirror would let
# a frame run against a stale value. gardenAPI methods are synchronous for
# exactly this reason.
#
# Parameter writes clamp against the descriptor table
# (ui/api/param_descriptor.nim) — the clamp authority that used to live in
# slider.nim — so no out-of-range value can reach CONFIG regardless of what
# the UI sends.
#
# JS-only: no native test imports this module. The descriptor table it
# serves is natively tested in tests/test_param_descriptor.nim; the wiring
# is verified by `nimble app`.
#
# ==============================================================================

when defined(js):
  import std/tables
  from std/json import pretty
  from std/jsffi import JsObject, toJs, `[]=`

  from bindings/js_interop import newJsObject, newJsArray, push, setGlobal,
    consoleWarn
  from bindings/typed_arrays import Float32Array

  import config
  import buffers
  import sph_core
  import field_core
  import preset
  import ui/api/param_descriptor
  import ui/state/matrix_state
  import ui/state/palette_state
  import ui/state/sim_config
  import ui/controls/slider
  import ui/presets/preset_store_core
  import ui/presets/preset_store
  import ui

  # ============================================================================
  # SECTION 1: DESCRIPTOR TABLE
  # ============================================================================

  let paramDescriptors = buildParamDescriptors()

  let paramsById: Table[string, ParamDescriptor] = block:
    var lookup = initTable[string, ParamDescriptor]()
    for descriptor in paramDescriptors:
      lookup[descriptor.id] = descriptor
    lookup

  proc storeName(store: ParamStore): cstring =
    case store
    of psSimulation: cstring"sim"
    of psRender: cstring"render"
    of psPalette: cstring"palette"

  proc descriptorToJs(descriptor: ParamDescriptor): JsObject =
    result = newJsObject()
    result["id"] = toJs(cstring(descriptor.id))
    result["label"] = toJs(cstring(descriptor.label))
    result["group"] = toJs(cstring(descriptor.group))
    result["kind"] = toJs(
      if descriptor.kind == pkInt: cstring"int" else: cstring"float")
    result["min"] = toJs(descriptor.minValue)
    result["max"] = toJs(descriptor.maxValue)
    result["step"] = toJs(descriptor.step)
    result["precision"] = toJs(descriptor.precision)
    result["defaultValue"] = toJs(descriptor.defaultValue)
    result["store"] = toJs(storeName(descriptor.store))
    result["reinitOnCommit"] = toJs(descriptor.reinitOnCommit)

  let descriptorArray = block:
    let jsArray = newJsArray()
    for descriptor in paramDescriptors:
      jsArray.push(descriptorToJs(descriptor))
    jsArray

  # ============================================================================
  # SECTION 2: PARAMETER GET / SET / COMMIT
  # ============================================================================

  proc triggerParticleReinit() =
    if not ui.onInitParticles.isNil:
      ui.onInitParticles()

  proc getParamImpl(id: string): float =
    case id
    of "particleCount": CONFIG.particleCount.float
    of "speciesCount": CONFIG.speciesCount.float
    of "interactionRadius": CONFIG.interactionRadius.float
    of "forceStrength": CONFIG.forceStrength
    of "friction": CONFIG.friction
    of "timeScale": CONFIG.timeScale
    of "ruleTemperature": CONFIG.ruleTemperature
    of "maxVelocity": CONFIG.maxVelocity
    of "particleSize": CONFIG.particleSize.float
    of "trailLength": CONFIG.trailLength
    of "glowIntensity": CONFIG.glowIntensity
    of "velocityGlowScale": CONFIG.velocityGlowScale
    of "glowRadiusScale": CONFIG.glowRadiusScale
    of "glowFalloff": CONFIG.glowFalloff
    of "glowWarmth": CONFIG.glowWarmth
    of "bloomIntensity": CONFIG.bloomIntensity
    of "exposure": CONFIG.exposure
    of "saturation": CONFIG.saturation
    of "contrast": CONFIG.contrast
    of "temperature": CONFIG.temperature
    of "repulsionEnd": CONFIG.repulsionEnd
    of "attractionPeak": CONFIG.attractionPeak
    of "expRepulsionAlpha": CONFIG.expRepulsionAlpha
    of "expAttractionBeta": CONFIG.expAttractionBeta
    of "paletteSaturation": ui.getPaletteSaturation()
    of "paletteLightness": ui.getPaletteLightness()
    of "sphRestDensity": CONFIG.sphRestDensity
    of "sphStiffness": CONFIG.sphStiffness
    of "sphViscosity": CONFIG.sphViscosity
    of "sphSubsteps": CONFIG.sphSubsteps.float
    of "rdFeed": CONFIG.rdFeed
    of "rdKill": CONFIG.rdKill
    of "fieldOpacity": CONFIG.fieldOpacity
    else:
      consoleWarn(toJs("[gardenAPI] unknown param id: " & id))
      0.0

  proc setParamImpl(id: string; rawValue: float) =
    if id notin paramsById:
      consoleWarn(toJs("[gardenAPI] unknown param id: " & id))
      return
    let value = clampParamValue(paramsById[id], rawValue)
    case id
    of "particleCount": updateSimulation(
      proc(simState: var SimulationState) = simState.particleCount = value.int)
    of "speciesCount": updateSimulation(
      proc(simState: var SimulationState) = simState.speciesCount = value.int)
    of "interactionRadius": updateSimulation(
      proc(simState: var SimulationState) =
        simState.interactionRadius = value.int)
    of "forceStrength": updateSimulation(
      proc(simState: var SimulationState) = simState.forceStrength = value)
    of "friction": updateSimulation(
      proc(simState: var SimulationState) = simState.friction = value)
    of "timeScale": updateSimulation(
      proc(simState: var SimulationState) = simState.timeScale = value)
    of "ruleTemperature": updateSimulation(
      proc(simState: var SimulationState) = simState.ruleTemperature = value)
    of "maxVelocity": updateSimulation(
      proc(simState: var SimulationState) = simState.maxVelocity = value)
    of "particleSize": updateRender(
      proc(renderState: var RenderState) = renderState.particleSize = value.int)
    of "trailLength": updateRender(
      proc(renderState: var RenderState) = renderState.trailLength = value)
    of "glowIntensity": updateRender(
      proc(renderState: var RenderState) = renderState.glowIntensity = value)
    of "velocityGlowScale": updateRender(
      proc(renderState: var RenderState) =
        renderState.velocityGlowScale = value)
    of "glowRadiusScale": updateRender(
      proc(renderState: var RenderState) = renderState.glowRadiusScale = value)
    of "glowFalloff": updateRender(
      proc(renderState: var RenderState) = renderState.glowFalloff = value)
    of "glowWarmth": updateRender(
      proc(renderState: var RenderState) = renderState.glowWarmth = value)
    of "bloomIntensity": updateRender(
      proc(renderState: var RenderState) = renderState.bloomIntensity = value)
    of "exposure": updateRender(
      proc(renderState: var RenderState) = renderState.exposure = value)
    of "saturation": updateRender(
      proc(renderState: var RenderState) = renderState.saturation = value)
    of "contrast": updateRender(
      proc(renderState: var RenderState) = renderState.contrast = value)
    of "temperature": updateRender(
      proc(renderState: var RenderState) = renderState.temperature = value)
    of "repulsionEnd": updateSimulation(
      proc(simState: var SimulationState) = simState.repulsionEnd = value)
    of "attractionPeak": updateSimulation(
      proc(simState: var SimulationState) = simState.attractionPeak = value)
    of "expRepulsionAlpha": updateSimulation(
      proc(simState: var SimulationState) = simState.expRepulsionAlpha = value)
    of "expAttractionBeta": updateSimulation(
      proc(simState: var SimulationState) = simState.expAttractionBeta = value)
    of "paletteSaturation": ui.setPaletteSaturation(value)
    of "paletteLightness": ui.setPaletteLightness(value)
    of "sphRestDensity": updateSimulation(
      proc(simState: var SimulationState) = simState.sphRestDensity = value)
    of "sphStiffness": updateSimulation(
      proc(simState: var SimulationState) = simState.sphStiffness = value)
    of "sphViscosity": updateSimulation(
      proc(simState: var SimulationState) = simState.sphViscosity = value)
    of "sphSubsteps": updateSimulation(
      proc(simState: var SimulationState) = simState.sphSubsteps = value.int)
    of "rdFeed": updateSimulation(
      proc(simState: var SimulationState) = simState.rdFeed = value)
    of "rdKill": updateSimulation(
      proc(simState: var SimulationState) = simState.rdKill = value)
    of "fieldOpacity": updateRender(
      proc(renderState: var RenderState) = renderState.fieldOpacity = value)
    else: discard
    # Keep the legacy panel's slider displays honest while both UIs are
    # served side by side. Removed with slider.nim at cutover.
    refreshRegisteredSliders()

  proc setSpeciesCountImpl(count: int; randomizeNew: bool) =
    ## The species slider's full release behavior: clamp, update the typed
    ## state, resize the matrix grid (randomizing only newly exposed cells
    ## when asked), then re-initialize particles.
    let clamped = clampParamValue(paramsById["speciesCount"], count.float).int
    ui.setSpeciesCount(clamped, randomizeNew)
    refreshRegisteredSliders()
    triggerParticleReinit()

  proc commitParamImpl(id: string) =
    ## The slider-release side effect (the old "change" event): only the two
    ## count parameters carry one — everything else applies fully on set.
    case id
    of "particleCount": triggerParticleReinit()
    of "speciesCount": setSpeciesCountImpl(CONFIG.speciesCount,
      randomizeNew = true)
    else: discard

  # ============================================================================
  # SECTION 3: LIFECYCLE (ready gate + stats push)
  # ============================================================================
  #
  # buffers.matrix exists only after init() has run allocateBuffers, so the
  # TS side must defer matrix/COLORS reads (and stats interest) to onReady.

  var apiReady = false
  var readyCallbacks: seq[proc()] = @[]

  proc signalReady*() =
    ## Called by app.nim at the end of init(): flushes queued onReady
    ## callbacks and answers isReady() with true from now on.
    apiReady = true
    let queued = readyCallbacks
    readyCallbacks = @[]
    for callback in queued:
      callback()

  var statsCallbacks: seq[proc(stats: JsObject)] = @[]

  proc pushStats*(fps, particleCount: int;
      gridTimeMs, workerTimeMs, gpuGridMs, gpuPhysicsMs, gpuDrawMs,
      gpuPresentMs: float) =
    ## Called from app.nim's frame loop (currently every ~500ms; the cadence
    ## is loop-side). Raw numbers — formatting belongs to the UI.
    if statsCallbacks.len == 0:
      return
    let stats = newJsObject()
    stats["fps"] = toJs(fps)
    stats["particleCount"] = toJs(particleCount)
    stats["gridTimeMs"] = toJs(gridTimeMs)
    stats["workerTimeMs"] = toJs(workerTimeMs)
    stats["gpuGridMs"] = toJs(gpuGridMs)
    stats["gpuPhysicsMs"] = toJs(gpuPhysicsMs)
    stats["gpuDrawMs"] = toJs(gpuDrawMs)
    stats["gpuPresentMs"] = toJs(gpuPresentMs)
    for callback in statsCallbacks:
      callback(stats)

  # ============================================================================
  # SECTION 4: MODE / PALETTE / COLORMAP CATALOGS
  # ============================================================================

  proc simKindLabel(kind: SimKind): string =
    case kind
    of skParticleLife: "Particle Life"
    of skSph: "SPH Fluid"
    of skReactionDiffusion: "Reaction-Diffusion"

  proc simKindCeiling(kind: SimKind): int =
    ## The particle-count ceiling entering this mode clamps to (0 = none).
    case kind
    of skParticleLife: 0
    of skSph: SPH_PARTICLE_CEILING
    of skReactionDiffusion: RD_PARTICLE_CEILING

  let simModeArray = block:
    let jsArray = newJsArray()
    for kind in SimKind:
      let mode = newJsObject()
      mode["id"] = toJs(cstring(simKindId(kind)))
      mode["label"] = toJs(cstring(simKindLabel(kind)))
      mode["particleCeiling"] = toJs(simKindCeiling(kind))
      jsArray.push(mode)
    jsArray

  proc paletteSchemeLabel(scheme: PaletteScheme): string =
    case scheme
    of psOpenColor: "Open Color"
    of psGolden: "Golden"
    of psSpectrum: "Spectrum"
    of psWarm: "Warm"
    of psCool: "Cool"

  let paletteSchemeArray = block:
    let jsArray = newJsArray()
    for scheme in [psOpenColor, psGolden, psSpectrum, psWarm, psCool]:
      let entry = newJsObject()
      entry["id"] = toJs(cstring(schemeId(scheme)))
      entry["label"] = toJs(cstring(paletteSchemeLabel(scheme)))
      jsArray.push(entry)
    jsArray

  let colormapArray = block:
    let jsArray = newJsArray()
    for (index, label) in [(0, "Inferno"), (1, "Viridis"), (2, "Two-Tone")]:
      let entry = newJsObject()
      entry["index"] = toJs(index)
      entry["label"] = toJs(cstring(label))
      jsArray.push(entry)
    jsArray

  # ============================================================================
  # SECTION 5: THE gardenAPI OBJECT
  # ============================================================================

  proc buildGardenApi(): JsObject =
    result = newJsObject()

    # Lifecycle
    result["isReady"] = toJs(proc(): bool = apiReady)
    result["onReady"] = toJs(proc(callback: proc()) =
      if apiReady: callback()
      else: readyCallbacks.add(callback))
    result["showWebGPURequired"] = toJs(proc() =
      ui.showWebGPURequiredOverlay())

    # Parameters
    result["descriptor"] = toJs(proc(): JsObject = descriptorArray)
    result["getParam"] = toJs(proc(id: cstring): float = getParamImpl($id))
    result["setParam"] = toJs(proc(id: cstring; value: float) =
      setParamImpl($id, value))
    result["commitParam"] = toJs(proc(id: cstring) = commitParamImpl($id))

    # Toggles
    result["getTrails"] = toJs(proc(): bool = CONFIG.trails)
    result["setTrails"] = toJs(proc(enabled: bool) = ui.setTrails(enabled))
    result["getBloom"] = toJs(proc(): bool = CONFIG.bloomEnabled)
    result["setBloom"] = toJs(proc(enabled: bool) = ui.setBloom(enabled))

    # Simulation mode
    result["simModes"] = toJs(proc(): JsObject = simModeArray)
    result["getSimMode"] = toJs(proc(): cstring =
      cstring(simKindId(activeSimKind.get())))
    result["setSimMode"] = toJs(proc(id: cstring) =
      try:
        discard parseSimKind($id)
        ui.setSimMode(id)
      except ValueError:
        consoleWarn(toJs("[gardenAPI] unknown sim mode id: " & $id)))

    # Force model
    result["getForceModel"] = toJs(proc(): int = CONFIG.forceModel)
    result["setForceModel"] = toJs(proc(model: int) =
      ui.setForceModel(clamp(model, 0, 1)))

    # Palette / colormap (color math stays in Nim)
    result["paletteSchemes"] = toJs(proc(): JsObject = paletteSchemeArray)
    result["getPaletteScheme"] = toJs(proc(): cstring =
      cstring(ui.getPaletteSchemeId()))
    result["isPaletteCustom"] = toJs(proc(): bool = ui.isPaletteCustom())
    result["setPaletteScheme"] = toJs(proc(id: cstring) =
      try:
        discard parsePaletteScheme($id)
        ui.setPaletteScheme(id)
      except ValueError:
        consoleWarn(toJs("[gardenAPI] unknown palette scheme id: " & $id)))
    result["colormaps"] = toJs(proc(): JsObject = colormapArray)
    result["getColormap"] = toJs(proc(): int = CONFIG.colormapIndex)
    result["setColormap"] = toJs(proc(index: int) =
      ui.setColormap(clamp(index, 0, 2)))

    # Attraction matrix (live Float32Array references; valid after onReady)
    result["matrix"] = toJs(proc(): Float32Array = buffers.matrix)
    result["colors"] = toJs(proc(): Float32Array = config.COLORS)
    result["matrixCellColor"] = toJs(proc(value: float): cstring =
      cstring(toHslaString(cellColorFromValue(clampMatrixValue(value)))))
    result["clampMatrixValue"] = toJs(proc(value: float): float =
      clampMatrixValue(value))
    result["speciesCount"] = toJs(proc(): int = CONFIG.speciesCount)
    result["setSpeciesCount"] = toJs(proc(count: int; randomizeNew: bool) =
      setSpeciesCountImpl(count, randomizeNew))
    result["randomizeMatrix"] = toJs(proc() = ui.randomizeMatrix())
    result["refreshMatrixDisplay"] = toJs(proc() = ui.updateMatrixDisplay())

    # Particles
    result["resetParticles"] = toJs(proc() = triggerParticleReinit())

    # Stats
    result["onStats"] = toJs(proc(callback: proc(stats: JsObject)) =
      statsCallbacks.add(callback))

    # Presets (hybrid: Nim owns schema/validation/apply-order; the UI owns
    # localStorage I/O using these keys and strings)
    result["presetKeys"] = toJs(proc(): JsObject =
      let keys = newJsObject()
      keys["prefix"] = toJs(cstring(PRESET_KEY_PREFIX))
      keys["indexKey"] = toJs(cstring(PRESET_INDEX_KEY))
      keys["defaultName"] = toJs(cstring(DEFAULT_PRESET_NAME))
      keys)
    result["normalizePresetName"] = toJs(proc(raw: cstring): cstring =
      cstring(normalizePresetName($raw)))
    result["exportPresetJson"] = toJs(proc(name: cstring): cstring =
      cstring(toJsonString(snapshotPreset($name))))
    result["exportPresetJsonPretty"] = toJs(proc(name: cstring): cstring =
      cstring(pretty(toJson(snapshotPreset($name)))))
    result["applyPresetJson"] = toJs(proc(jsonText: cstring): JsObject =
      let outcome = newJsObject()
      let loadResult = parsePreset($jsonText)
      if loadResult.isOk:
        applyPreset(loadResult.preset)
        outcome["ok"] = toJs(true)
      else:
        outcome["ok"] = toJs(false)
        outcome["error"] = toJs(cstring(loadResult.errorMessage))
      outcome)

  setGlobal("gardenAPI", buildGardenApi())
