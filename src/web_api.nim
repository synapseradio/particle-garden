# ==============================================================================
# PARTICLE GARDEN - WEB API (window.gardenAPI)
# ==============================================================================
#
# The one boundary the TypeScript UI talks through, and the home of the
# typed-state -> CONFIG bridge. A single `gardenAPI` object is created at
# module-eval time (before the Solid bundle evaluates) and installed on the
# global object.
#
# THE SYNCHRONOUS MIRROR INVARIANT (do not break this from the TS side):
# the typed tunable records are the mutation surface; CONFIG stays the flat
# GPU-facing mirror the hot paths read fresh every frame. Every mutation
# goes through updateSimulation/updateRender below, which write the typed
# store AND the mirror in the same tick — the mirror is deliberately
# synchronous, not subscription-based (a subscription would flush on a
# microtask, letting a frame run against a stale CONFIG). gardenAPI methods
# are synchronous for exactly this reason; never rebuild this boundary on
# deferred plumbing.
#
# Parameter writes clamp against the descriptor table
# (ui/api/param_descriptor.nim) — the clamp authority — so no out-of-range
# value can reach CONFIG regardless of what the UI sends.
#
# Presets are hybrid: this module owns snapshot -> JSON and JSON ->
# validated preset -> apply (walking preset_store_core's presetApplySteps in
# order); the UI owns localStorage I/O under preset_store_core's keys.
#
# JS-only: no native test imports this module. The descriptor table it
# serves is natively tested in tests/test_param_descriptor.nim; preset
# schema and apply order are natively tested via preset.nim and
# preset_store_core.nim; the wiring is verified by `nimble app`.
#
# ==============================================================================

when defined(js):
  import std/tables
  from std/json import pretty
  from std/jsffi import JsObject, toJs, `[]=`
  from std/dom import getElementById

  from bindings/js_interop import newJsObject, newJsArray, push, setGlobal,
    consoleWarn, gaussian
  from bindings/typed_arrays import Float32Array, `[]`, `[]=`
  from bindings/dom_extensions import HTMLElement

  import config
  import buffers
  import sph_core
  import field_core
  import preset
  import canvas_input
  import ui/api/param_descriptor
  import ui/state/matrix_state
  import ui/state/palette_state
  import ui/state/sim_config
  import ui/presets/preset_store_core

  proc jsonParseable(text: cstring): bool {.importjs:
    "(() => { try { JSON.parse(#); return true; } catch { return false; } })()".}
    ## On the JS backend std/json's parseJson delegates to JSON.parse, whose
    ## SyntaxError is a foreign exception Nim's `except ValueError` cannot
    ## catch (and the build bans bare except). Pre-checking here keeps
    ## applyPresetJson's {ok, error} contract instead of leaking a throw.

  proc isoTimestampNow(): cstring {.importjs: "new Date().toISOString()".}
    ## Wall-clock ISO-8601 timestamp for a preset's createdAt. preset.nim has
    ## no clock access (pure, no FFI) by design; this is the one place a
    ## real value gets stamped in.

  # ============================================================================
  # SECTION 1: TYPED CONFIG STATE (the synchronous mirror)
  # ============================================================================

  var currentSimulation* = initSimulationState()
  var currentRender* = initRenderState()

  proc applySimulationToConfig(simState: SimulationState) =
    CONFIG.particleCount = simState.particleCount
    CONFIG.speciesCount = simState.speciesCount
    CONFIG.interactionRadius = simState.interactionRadius
    CONFIG.forceStrength = simState.forceStrength
    CONFIG.friction = simState.friction
    CONFIG.ruleTemperature = simState.ruleTemperature
    CONFIG.timeScale = simState.timeScale
    CONFIG.maxVelocity = simState.maxVelocity
    CONFIG.repulsionEnd = simState.repulsionEnd
    CONFIG.attractionPeak = simState.attractionPeak
    CONFIG.forceModel = simState.forceModel
    CONFIG.expRepulsionAlpha = simState.expRepulsionAlpha
    CONFIG.expAttractionBeta = simState.expAttractionBeta
    CONFIG.sphRestDensity = simState.sphRestDensity
    CONFIG.sphStiffness = simState.sphStiffness
    CONFIG.sphViscosity = simState.sphViscosity
    CONFIG.sphSubsteps = simState.sphSubsteps
    CONFIG.rdFeed = simState.rdFeed
    CONFIG.rdKill = simState.rdKill

  proc applyRenderToConfig(renderState: RenderState) =
    CONFIG.particleSize = renderState.particleSize
    CONFIG.trails = renderState.trails
    CONFIG.trailLength = renderState.trailLength
    CONFIG.glowIntensity = renderState.glowIntensity
    CONFIG.velocityGlowScale = renderState.velocityGlowScale
    CONFIG.glowRadiusScale = renderState.glowRadiusScale
    CONFIG.glowFalloff = renderState.glowFalloff
    CONFIG.glowWarmth = renderState.glowWarmth
    CONFIG.bloomEnabled = renderState.bloomEnabled
    CONFIG.bloomIntensity = renderState.bloomIntensity
    CONFIG.exposure = renderState.exposure
    CONFIG.saturation = renderState.saturation
    CONFIG.contrast = renderState.contrast
    CONFIG.temperature = renderState.temperature
    CONFIG.colormapIndex = renderState.colormapIndex
    CONFIG.fieldOpacity = renderState.fieldOpacity

  proc updateSimulation*(mutate: proc(simState: var SimulationState)) =
    ## Mutate a copy of the simulation state, store it, and mirror it into
    ## CONFIG synchronously.
    var simState = currentSimulation
    mutate(simState)
    currentSimulation = simState
    applySimulationToConfig(simState)

  proc updateRender*(mutate: proc(renderState: var RenderState)) =
    ## Mutate a copy of the render state, store it, and mirror it into
    ## CONFIG synchronously.
    var renderState = currentRender
    mutate(renderState)
    currentRender = renderState
    applyRenderToConfig(renderState)

  # ============================================================================
  # SECTION 2: DESCRIPTOR TABLE
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
  # SECTION 3: PALETTE EDITOR STATE
  # ============================================================================
  #
  # Session-only UI state, deliberately not part of SimConfig or the preset
  # store (see palette_state.nim). Changing any knob regenerates the six
  # species colors into COLORS in place; webgpu_render repacks COLORS into
  # the GPU colors uniform every frame, so no explicit upload is needed.

  var paletteEditorState = initPaletteEditorState()

  proc applyPaletteToColors() =
    ## Regenerate species colors from paletteEditorState into COLORS.
    ## Inert while the state is custom (a preset load set COLORS directly):
    ## regenerating would clobber the loaded colors, so the saturation/
    ## lightness knobs stay inert until a scheme is explicitly chosen.
    if paletteEditorState.isCustom:
      return
    let flatPalette = flatPaletteFor(paletteEditorState)
    for colorIndex in 0 ..< flatPalette.len:
      COLORS[colorIndex] = flatPalette[colorIndex]

  proc setPaletteSchemeImpl(scheme: PaletteScheme) =
    ## An explicit scheme pick clears the custom flag — it is the intended
    ## overwrite of preset-loaded colors.
    paletteEditorState = paletteEditorState.withScheme(scheme)
    applyPaletteToColors()

  # ============================================================================
  # SECTION 4: MATRIX STATE
  # ============================================================================

  # The species count the matrix bookkeeping last saw; lets a grow
  # distinguish newly exposed cells from established ones.
  var lastSpeciesCount = CONFIG.speciesCount

  proc randomizeMatrix*() =
    ## Randomize all active matrix cells with the bell-curve rule sampler
    ## (gaussian draws scaled by CONFIG.ruleTemperature, rejection-sampled
    ## into [-1, 1] by matrix_state.sampleRuleValue).
    let activeSpecies = CONFIG.speciesCount
    for row in 0 ..< activeSpecies:
      for col in 0 ..< activeSpecies:
        buffers.matrix[matrixIndex(row, col)] =
          sampleRuleValue(CONFIG.ruleTemperature, gaussian)

  proc applySpeciesCountChange(newCount: int; randomizeNew: bool) =
    ## React to a species-count change: a grow randomizes only the newly
    ## exposed matrix band (when randomizeNew); hidden values persist in the
    ## buffer through a shrink and reappear on re-grow.
    let exposed = newlyExposedCells(lastSpeciesCount, newCount)
    lastSpeciesCount = newCount
    if randomizeNew:
      for cell in exposed:
        buffers.matrix[matrixIndex(cell.row, cell.col)] =
          sampleRuleValue(CONFIG.ruleTemperature, gaussian)

  # ============================================================================
  # SECTION 5: MUTATION IMPLS (mode, toggles, counts)
  # ============================================================================

  proc triggerParticleReinit() =
    if not canvas_input.onInitParticles.isNil:
      canvas_input.onInitParticles()

  proc setTrailsImpl(enabled: bool) =
    updateRender(proc(renderState: var RenderState) =
      renderState.trails = enabled)

  proc setBloomImpl*(enabled: bool) =
    ## Exported for app.nim's ?bloom= machine override.
    updateRender(proc(renderState: var RenderState) =
      renderState.bloomEnabled = enabled)

  proc setForceModelImpl(model: int) =
    updateSimulation(proc(simState: var SimulationState) =
      simState.forceModel = clamp(model, 0, 1))

  proc setColormapImpl(index: int) =
    updateRender(proc(renderState: var RenderState) =
      renderState.colormapIndex = clamp(index, 0, 2))

  proc simKindCeiling(kind: SimKind): int =
    ## The particle-count ceiling entering this mode clamps to (0 = none).
    ## SPH's neighbor pressure loop and RD's field passes are heavier than
    ## particle-life's forces, hence the caps.
    case kind
    of skParticleLife: 0
    of skSph: SPH_PARTICLE_CEILING
    of skReactionDiffusion: RD_PARTICLE_CEILING

  proc setSimModeImpl*(kind: SimKind) =
    ## Switch the active simulation mode. app.nim subscribes activeSimKind
    ## to the compute executor, so the set swaps the frame description.
    ## Entering a capped mode clamps the particle count through the same
    ## update + re-init path the particleCount slider uses; leaving does not
    ## restore the previous count.
    activeSimKind.set(kind)
    let modeCeiling = simKindCeiling(kind)
    if modeCeiling > 0 and CONFIG.particleCount > modeCeiling:
      updateSimulation(proc(simState: var SimulationState) =
        simState.particleCount = modeCeiling)
      triggerParticleReinit()

  proc setSpeciesCountImpl(count: int; randomizeNew: bool) =
    ## The species slider's full release behavior: clamp, update the typed
    ## state, resize the matrix bookkeeping, then re-initialize particles.
    let clamped = clampParamValue(paramsById["speciesCount"], count.float).int
    updateSimulation(proc(simState: var SimulationState) =
      simState.speciesCount = clamped)
    applySpeciesCountChange(clamped, randomizeNew)
    triggerParticleReinit()

  proc showWebGpuRequiredOverlay*() =
    ## Show the "WebGPU required" overlay (the one panel-shaped DOM node the
    ## shell page keeps). Called when WebGPU init or pipeline setup fails.
    let overlay = cast[HTMLElement](getElementById(cstring("webgpu-required")))
    if not overlay.isNil:
      overlay.style.display = cstring"block"

  # ============================================================================
  # SECTION 6: PARAMETER GET / SET / COMMIT
  # ============================================================================

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
    of "paletteSaturation": paletteEditorState.saturation
    of "paletteLightness": paletteEditorState.lightness
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
    of "paletteSaturation":
      paletteEditorState.saturation = value
      applyPaletteToColors()
    of "paletteLightness":
      paletteEditorState.lightness = value
      applyPaletteToColors()
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

  proc commitParamImpl(id: string) =
    ## The slider-release side effect (the old "change" event): only the two
    ## count parameters carry one — everything else applies fully on set.
    case id
    of "particleCount": triggerParticleReinit()
    of "speciesCount": setSpeciesCountImpl(CONFIG.speciesCount,
      randomizeNew = true)
    else: discard

  # ============================================================================
  # SECTION 7: LIFECYCLE (ready gate + stats push)
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
  # SECTION 8: PRESETS (snapshot / apply)
  # ============================================================================

  proc snapshotPreset(name: string): Preset =
    ## Capture the CURRENT live CONFIG, attraction matrix, species palette,
    ## and active mode as a Preset named `name`, stamped with the current
    ## wall-clock time.
    var settings: PresetSettings
    settings.particleCount = CONFIG.particleCount
    settings.speciesCount = CONFIG.speciesCount
    settings.interactionRadius = CONFIG.interactionRadius
    settings.forceStrength = CONFIG.forceStrength
    settings.friction = CONFIG.friction
    settings.ruleTemperature = CONFIG.ruleTemperature
    settings.timeScale = CONFIG.timeScale
    settings.particleSize = CONFIG.particleSize
    settings.trails = CONFIG.trails
    settings.trailLength = CONFIG.trailLength
    settings.glowIntensity = CONFIG.glowIntensity
    settings.velocityGlowScale = CONFIG.velocityGlowScale
    settings.maxVelocity = CONFIG.maxVelocity
    settings.repulsionEnd = CONFIG.repulsionEnd
    settings.attractionPeak = CONFIG.attractionPeak
    settings.forceModel = CONFIG.forceModel
    settings.expRepulsionAlpha = CONFIG.expRepulsionAlpha
    settings.expAttractionBeta = CONFIG.expAttractionBeta
    settings.glowRadiusScale = CONFIG.glowRadiusScale
    settings.glowFalloff = CONFIG.glowFalloff
    settings.glowWarmth = CONFIG.glowWarmth
    settings.bloomEnabled = CONFIG.bloomEnabled
    settings.bloomIntensity = CONFIG.bloomIntensity
    settings.exposure = CONFIG.exposure
    settings.saturation = CONFIG.saturation
    settings.contrast = CONFIG.contrast
    settings.temperature = CONFIG.temperature
    settings.colormapIndex = CONFIG.colormapIndex
    settings.fieldOpacity = CONFIG.fieldOpacity

    var matrixSnapshot: Matrix
    for matrixIdx in 0 ..< preset.MATRIX_LEN:
      matrixSnapshot[matrixIdx] = buffers.matrix[matrixIdx]

    var paletteSnapshot: Palette
    for speciesIndex in 0 ..< preset.MAX_SPECIES:
      paletteSnapshot[speciesIndex] = [
        COLORS[speciesIndex * 3],
        COLORS[speciesIndex * 3 + 1],
        COLORS[speciesIndex * 3 + 2]
      ]

    Preset(
      schemaVersion: preset.CURRENT_SCHEMA_VERSION,
      name: name,
      createdAt: $isoTimestampNow(),
      mode: simKindId(activeSimKind.get()),
      settings: settings,
      matrix: matrixSnapshot,
      palette: paletteSnapshot
    )

  proc applyPresetImpl(sourcePreset: Preset) =
    ## Apply every field of `sourcePreset` onto the live simulation, walking
    ## presetApplySteps() in the fixed order that module documents and pins
    ## natively. Never persists anything — storage belongs to the UI side.
    for step in presetApplySteps():
      case step
      of pasMode:
        try:
          activeSimKind.set(parseSimKind(sourcePreset.mode))
        except ValueError:
          # Forward-compatible: a preset from a future build may carry a
          # mode this build cannot run yet. Keep running the current mode
          # rather than crashing the apply.
          consoleWarn(("[preset] unknown mode id \"" & sourcePreset.mode &
            "\" - keeping the current mode").toJs)
      of pasSpeciesCount:
        # No re-init here: particleCount is the one step that triggers it,
        # after the matrix bookkeeping is already sized for the target.
        updateSimulation(proc(simState: var SimulationState) =
          simState.speciesCount = sourcePreset.settings.speciesCount)
        applySpeciesCountChange(sourcePreset.settings.speciesCount,
          randomizeNew = false)
      of pasParticleCount:
        updateSimulation(proc(simState: var SimulationState) =
          simState.particleCount = sourcePreset.settings.particleCount)
        triggerParticleReinit()
      of pasMatrix:
        for matrixIdx in 0 ..< sourcePreset.matrix.len:
          buffers.matrix[matrixIdx] = sourcePreset.matrix[matrixIdx]
      of pasPalette:
        for speciesIndex in 0 ..< sourcePreset.palette.len:
          let color = sourcePreset.palette[speciesIndex]
          COLORS[speciesIndex * 3] = color[0]
          COLORS[speciesIndex * 3 + 1] = color[1]
          COLORS[speciesIndex * 3 + 2] = color[2]
        # Mark COLORS externally set so the palette editor's next touch
        # cannot regenerate over the loaded colors (see applyPaletteToColors).
        paletteEditorState = paletteEditorState.withCustom()
      of pasScalars:
        let settings = sourcePreset.settings
        updateSimulation(proc(simState: var SimulationState) =
          simState.interactionRadius = settings.interactionRadius
          simState.forceStrength = settings.forceStrength
          simState.friction = settings.friction
          simState.ruleTemperature = settings.ruleTemperature
          simState.timeScale = settings.timeScale
          simState.maxVelocity = settings.maxVelocity
          simState.repulsionEnd = settings.repulsionEnd
          simState.attractionPeak = settings.attractionPeak
          simState.expRepulsionAlpha = settings.expRepulsionAlpha
          simState.expAttractionBeta = settings.expAttractionBeta
          simState.sphRestDensity = settings.sphRestDensity
          simState.sphStiffness = settings.sphStiffness
          simState.sphViscosity = settings.sphViscosity
          simState.sphSubsteps = settings.sphSubsteps
          simState.rdFeed = settings.rdFeed
          simState.rdKill = settings.rdKill
        )
        updateRender(proc(renderState: var RenderState) =
          renderState.particleSize = settings.particleSize
          renderState.trailLength = settings.trailLength
          renderState.glowIntensity = settings.glowIntensity
          renderState.velocityGlowScale = settings.velocityGlowScale
          renderState.glowRadiusScale = settings.glowRadiusScale
          renderState.glowFalloff = settings.glowFalloff
          renderState.glowWarmth = settings.glowWarmth
          renderState.bloomIntensity = settings.bloomIntensity
          renderState.exposure = settings.exposure
          renderState.saturation = settings.saturation
          renderState.contrast = settings.contrast
          renderState.temperature = settings.temperature
          renderState.fieldOpacity = settings.fieldOpacity
        )
        setForceModelImpl(settings.forceModel)
        setTrailsImpl(settings.trails)
        setBloomImpl(settings.bloomEnabled)
        setColormapImpl(settings.colormapIndex)
      of pasUiRefresh:
        # Display refresh belongs to the Solid UI: the controller re-reads
        # everything through gardenAPI after a successful apply.
        discard

  # ============================================================================
  # SECTION 9: CATALOGS
  # ============================================================================

  proc simKindLabel(kind: SimKind): string =
    case kind
    of skParticleLife: "Particle Life"
    of skSph: "SPH Fluid"
    of skReactionDiffusion: "Reaction-Diffusion"

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
  # SECTION 10: THE gardenAPI OBJECT
  # ============================================================================

  proc buildGardenApi(): JsObject =
    result = newJsObject()

    # Lifecycle
    result["isReady"] = toJs(proc(): bool = apiReady)
    result["onReady"] = toJs(proc(callback: proc()) =
      if apiReady: callback()
      else: readyCallbacks.add(callback))

    # Parameters
    result["descriptor"] = toJs(proc(): JsObject = descriptorArray)
    result["getParam"] = toJs(proc(id: cstring): float = getParamImpl($id))
    result["setParam"] = toJs(proc(id: cstring; value: float) =
      setParamImpl($id, value))
    result["commitParam"] = toJs(proc(id: cstring) = commitParamImpl($id))

    # Toggles
    result["getTrails"] = toJs(proc(): bool = CONFIG.trails)
    result["setTrails"] = toJs(proc(enabled: bool) = setTrailsImpl(enabled))
    result["getBloom"] = toJs(proc(): bool = CONFIG.bloomEnabled)
    result["setBloom"] = toJs(proc(enabled: bool) = setBloomImpl(enabled))

    # Simulation mode
    result["simModes"] = toJs(proc(): JsObject = simModeArray)
    result["getSimMode"] = toJs(proc(): cstring =
      cstring(simKindId(activeSimKind.get())))
    result["setSimMode"] = toJs(proc(id: cstring) =
      try:
        setSimModeImpl(parseSimKind($id))
      except ValueError:
        consoleWarn(toJs("[gardenAPI] unknown sim mode id: " & $id)))

    # Force model
    result["getForceModel"] = toJs(proc(): int = CONFIG.forceModel)
    result["setForceModel"] = toJs(proc(model: int) = setForceModelImpl(model))

    # Palette / colormap (color math stays in Nim)
    result["paletteSchemes"] = toJs(proc(): JsObject = paletteSchemeArray)
    result["getPaletteScheme"] = toJs(proc(): cstring =
      cstring(schemeId(paletteEditorState.scheme)))
    result["isPaletteCustom"] = toJs(proc(): bool = paletteEditorState.isCustom)
    result["setPaletteScheme"] = toJs(proc(id: cstring) =
      try:
        setPaletteSchemeImpl(parsePaletteScheme($id))
      except ValueError:
        consoleWarn(toJs("[gardenAPI] unknown palette scheme id: " & $id)))
    result["colormaps"] = toJs(proc(): JsObject = colormapArray)
    result["getColormap"] = toJs(proc(): int = CONFIG.colormapIndex)
    result["setColormap"] = toJs(proc(index: int) = setColormapImpl(index))

    # Attraction matrix (live Float32Array references; valid after onReady)
    result["matrix"] = toJs(proc(): Float32Array = buffers.matrix)
    result["matrixCellColor"] = toJs(proc(value: float): cstring =
      cstring(toHslaString(cellColorFromValue(clampMatrixValue(value)))))
    result["clampMatrixValue"] = toJs(proc(value: float): float =
      clampMatrixValue(value))
    result["matrixStride"] = toJs(proc(): int = MATRIX_SIZE)
    result["speciesColor"] = toJs(proc(index: int): cstring =
      var channels = newSeq[float](config.MAX_SPECIES * 3)
      for channelIndex in 0 ..< channels.len:
        channels[channelIndex] = COLORS[channelIndex]
      cstring(toRgbaString(speciesColorFromIndex(index, channels))))
    result["randomizeMatrix"] = toJs(proc() = randomizeMatrix())

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
      if not jsonParseable(jsonText):
        outcome["ok"] = toJs(false)
        outcome["error"] = toJs(cstring"malformed JSON")
        return outcome
      let loadResult = parsePreset($jsonText)
      if loadResult.isOk:
        applyPresetImpl(loadResult.preset)
        outcome["ok"] = toJs(true)
      else:
        outcome["ok"] = toJs(false)
        outcome["error"] = toJs(cstring(loadResult.errorMessage))
      outcome)

  setGlobal("gardenAPI", buildGardenApi())
