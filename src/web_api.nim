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
  import field_core
  import preset
  import canvas_input
  import camera_core
  import climate_core
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
    CONFIG.crowdingStrength = simState.crowdingStrength
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
    CONFIG.sphRadiusFraction = simState.sphRadiusFraction
    CONFIG.sphViscosity = simState.sphViscosity
    CONFIG.sphSubsteps = simState.sphSubsteps
    CONFIG.rdFeed = simState.rdFeed
    CONFIG.rdKill = simState.rdKill
    CONFIG.rdDeposit = simState.rdDeposit
    CONFIG.rdFieldForce = simState.rdFieldForce
    CONFIG.climateDrift = simState.climateDrift
    CONFIG.climateSpeed = simState.climateSpeed

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
    ##
    ## The couplings are published here because this is the one write path: a
    ## strength crossing zero has to reach the executor whatever moved it — a
    ## slider, a preset, or the drifting climate. webgpu_compute rebuilds the
    ## frame only when the zeros actually change, so publishing on every write
    ## costs a comparison.
    var simState = currentSimulation
    mutate(simState)
    currentSimulation = simState
    applySimulationToConfig(simState)
    worldCouplings.set(couplingsOf(simState))

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
    of psSpeciesChemistry: cstring"chemistry"
    of psCamera: cstring"camera"

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
    result["hint"] = toJs(cstring(descriptor.hint))
    # Labelled positions worth stopping at. Empty for most parameters; the
    # panel renders whatever arrives and invents none of its own.
    let notchArray = newJsArray()
    for entry in descriptor.notches:
      let notchObj = newJsObject()
      notchObj["value"] = toJs(entry.value)
      notchObj["label"] = toJs(cstring(entry.label))
      notchArray.push(notchObj)
    result["notches"] = toJs(notchArray)
    # Cardinality. The panel branches on it to draw a grid row rather than a
    # slider, and only a per-species entry carries the slot that indexes a
    # species' stride — so the two shapes stay distinguishable on the TS side
    # without a second table to tell them apart.
    case descriptor.arity
    of paScalar:
      result["arity"] = toJs(cstring"scalar")
    of paPerSpecies:
      result["arity"] = toJs(cstring"perSpecies")
      result["slot"] = toJs(descriptor.slot)

  let descriptorArray = block:
    let jsArray = newJsArray()
    for descriptor in paramDescriptors:
      jsArray.push(descriptorToJs(descriptor))
    jsArray

  proc clampParamImpl(id: string; value: float): float =
    ## Clamp a value against its descriptor's range without writing it. The
    ## per-species grid needs this because it writes cells of the live
    ## chemistry array by reference rather than through setParam, and a cell
    ## must still be bounded by the table. An unknown id returns the value
    ## untouched and warns: the panel builds its inputs from the served
    ## descriptors, so an unknown id means the two sides have drifted rather
    ## than that a user typed something odd.
    if id notin paramsById:
      consoleWarn(toJs("[gardenAPI] unknown param id: " & id))
      return value
    clampParamValue(paramsById[id], value)

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
  # SECTION 5: MUTATION IMPLS (toggles, counts)
  # ============================================================================

  proc triggerParticleReinit() =
    if not canvas_input.onInitParticles.isNil:
      canvas_input.onInitParticles()

  proc triggerParticleResize() =
    ## Apply a new particle count while the world keeps running. See
    ## app.resizeParticles for what survives.
    if not canvas_input.onResizeParticles.isNil:
      canvas_input.onResizeParticles()

  proc triggerFieldReseed() =
    if not canvas_input.onReseedField.isNil:
      canvas_input.onReseedField()

  proc setTrailsImpl(enabled: bool) =
    ## Delegates to render_state.withTrails, which is where the "a toggle must
    ## do something" rule lives and where it is natively tested.
    updateRender(proc(renderState: var RenderState) =
      renderState = renderState.withTrails(enabled))

  proc setBloomImpl*(enabled: bool) =
    ## Exported for app.nim's ?bloom= machine override.
    updateRender(proc(renderState: var RenderState) =
      renderState.bloomEnabled = enabled)

  proc setForceModelImpl(model: int) =
    updateSimulation(proc(simState: var SimulationState) =
      simState.forceModel = clamp(model, 0, 1))

  proc setClimateDriftImpl(enabled: bool) =
    updateSimulation(proc(simState: var SimulationState) =
      simState.climateDrift = enabled)

  proc setColormapImpl(index: int) =
    updateRender(proc(renderState: var RenderState) =
      renderState.colormapIndex =
        clamp(index, COLORMAP_INDEX_MIN, COLORMAP_INDEX_MAX))

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
    of "crowdingStrength": CONFIG.crowdingStrength
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
    of "fluidStrength": CONFIG.fluidStrength
    of "sphStiffness": CONFIG.sphStiffness
    of "sphRadiusFraction": CONFIG.sphRadiusFraction
    of "sphViscosity": CONFIG.sphViscosity
    of "sphSubsteps": CONFIG.sphSubsteps.float
    of "rdFeed": CONFIG.rdFeed
    of "rdKill": CONFIG.rdKill
    of "rdDeposit": CONFIG.rdDeposit
    of "rdFieldForce": CONFIG.rdFieldForce
    of "climateSpeed": CONFIG.climateSpeed
    of "fieldOpacity": CONFIG.fieldOpacity
    # Read back from the live camera, not from CONFIG — it is not there. The
    # panel needs this so the slider tracks a zoom the WHEEL performed.
    of "cameraZoom":
      if canvas_input.cameraGetter.isNil: CAMERA_DEFAULT_ZOOM.float
      else: canvas_input.cameraGetter().zoom.float
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
    of "crowdingStrength": updateSimulation(
      proc(simState: var SimulationState) = simState.crowdingStrength = value)
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
    of "fluidStrength": updateSimulation(
      proc(simState: var SimulationState) = simState.fluidStrength = value)
    of "sphRestDensity": updateSimulation(
      proc(simState: var SimulationState) = simState.sphRestDensity = value)
    of "sphStiffness": updateSimulation(
      proc(simState: var SimulationState) = simState.sphStiffness = value)
    of "sphRadiusFraction": updateSimulation(
      proc(simState: var SimulationState) = simState.sphRadiusFraction = value)
    of "sphViscosity": updateSimulation(
      proc(simState: var SimulationState) = simState.sphViscosity = value)
    of "sphSubsteps": updateSimulation(
      proc(simState: var SimulationState) = simState.sphSubsteps = value.int)
    of "rdFeed": updateSimulation(
      proc(simState: var SimulationState) = simState.rdFeed = value)
    of "rdKill": updateSimulation(
      proc(simState: var SimulationState) = simState.rdKill = value)
    of "rdDeposit": updateSimulation(
      proc(simState: var SimulationState) = simState.rdDeposit = value)
    of "rdFieldForce": updateSimulation(
      proc(simState: var SimulationState) = simState.rdFieldForce = value)
    of "climateSpeed": updateSimulation(
      proc(simState: var SimulationState) = simState.climateSpeed = value)
    of "fieldOpacity": updateRender(
      proc(renderState: var RenderState) = renderState.fieldOpacity = value)
    # psCamera: writes the live view, never CONFIG. Reached through a hook
    # because webgpu_render sits a layer above this file in app.nim's import
    # order, the same wiring canvas_input's wheel and key handlers use. Nil
    # until app.nim wires it, so a write arriving before the render pipeline
    # initializes is dropped rather than crashing.
    of "cameraZoom":
      # Reuses canvas_input's camera hooks rather than declaring a second pair:
      # webgpu_render sits a layer above both files, and one wiring point means
      # the slider and the wheel cannot end up pointed at different cameras.
      if not canvas_input.cameraGetter.isNil and
          not canvas_input.cameraSetter.isNil:
        let current = canvas_input.cameraGetter()
        # Anchored at the view CENTRE, like the +/- keys and unlike the wheel.
        # A slider has no cursor position to zoom toward.
        canvas_input.cameraSetter(current.zoomedAt(
          clampZoom(value.float32, CAMERA_ZOOM_MIN.float32,
            CAMERA_ZOOM_MAX.float32),
          0.0'f32, 0.0'f32,
          float32(config.WORLD_W), float32(config.WORLD_H)))
    else:
      # Reached by an id the table serves that this switch does not route: the
      # per-species columns, whose cells the panel writes into the live
      # chemistry array by reference. Silence would read as a dead control, so
      # name the path the caller wanted instead.
      consoleWarn(toJs("[gardenAPI] setParam does not route " & id &
        "; per-species values are written through chemistry()"))

  # The named regimes, and what selecting one does. A regime is a POINT in the
  # feed/kill plane, so both axes move together — a notch on one axis alone
  # does not locate one.
  let regimeArray = block:
    let jsArray = newJsArray()
    for regime in RD_REGIMES:
      let entry = newJsObject()
      entry["id"] = toJs(cstring(regime.id))
      entry["label"] = toJs(cstring(regime.label))
      entry["feed"] = toJs(regime.feed)
      entry["kill"] = toJs(regime.kill)
      entry["minDeposit"] = toJs(regime.minDeposit)
      jsArray.push(entry)
    jsArray

  # The ids the weather writes, served so the panel derives them instead of
  # keeping its own copy. Built once: the list is a constant.
  let climateParamIdArray = block:
    let jsArray = newJsArray()
    for axis in ClimateAxis:
      jsArray.push(toJs(cstring(CLIMATE_PARAM_IDS[axis])))
    jsArray

  proc applyRegimeImpl(id: string) =
    ## Set feed and kill to a named regime's coordinates, through the ordinary
    ## descriptor-clamped setParam path so the sliders read back what landed.
    ##
    ## THE DEPOSIT FLOOR. Two regimes (Worms, Coral) do not ignite at the
    ## default deposit at all — measured in tests/test_field_core.nim and
    ## recorded at RD_REGIMES — so setting only feed and kill would leave the
    ## field blank and the button looking broken. Their `minDeposit` is applied
    ## as a FLOOR, never a set: a user who has deliberately raised the deposit
    ## keeps their value, and a regime that ignites at the default (minDeposit
    ## 0) never touches it.
    for regime in RD_REGIMES:
      if regime.id == id:
        setParamImpl("rdFeed", regime.feed)
        setParamImpl("rdKill", regime.kill)
        if regime.minDeposit > CONFIG.rdDeposit:
          setParamImpl("rdDeposit", regime.minDeposit)
        return
    consoleWarn(toJs("[gardenAPI] unknown regime id: " & id))

  proc activeRegimeImpl(): string =
    ## The regime whose coordinates the current feed and kill both match, or
    ## "" between regimes. Compared at slider precision rather than exactly:
    ## the value that came back from setParam is what the slider holds, and
    ## asking for bit equality against the table would leave every button
    ## unlit.
    const REGIME_EPSILON = 1e-6
    for regime in RD_REGIMES:
      if abs(CONFIG.rdFeed - regime.feed) < REGIME_EPSILON and
          abs(CONFIG.rdKill - regime.kill) < REGIME_EPSILON:
        return regime.id
    ""

  # Resolved once at module scope, off climate_core's list of what the weather
  # writes. A string lookup per axis per frame buys nothing when the set never
  # varies, and resolving here means a climate id with no descriptor raises at
  # startup rather than mid-drift.
  let climateDescriptors: array[ClimateAxis, ParamDescriptor] = block:
    var resolved: array[ClimateAxis, ParamDescriptor]
    for axis in ClimateAxis:
      resolved[axis] = paramsById[CLIMATE_PARAM_IDS[axis]]
    resolved

  proc setClimateFromSimulation*(point: array[ClimateAxis, float]) =
    ## The parameter path for writes the SIMULATION originates rather than the
    ## user — the drifting climate advancing its axes each frame.
    ##
    ## Takes the tour point whole rather than one float per axis, so the frame
    ## loop hands over what climate_core produced without naming the axes on
    ## the way past. An axis added to ClimateAxis reaches this clamp with no
    ## call site to widen.
    ##
    ## Deliberately the same clamped path a slider drag takes, not a shortcut
    ## into CONFIG: the panel reads its values back through getParam, so a
    ## direct CONFIG write would move the simulation while leaving the sliders
    ## showing the old numbers. Watching the controls move is what makes the
    ## weather legible instead of mysterious.
    ##
    ## Every axis lands in ONE mirror cycle. A climate point is a coordinate in
    ## the feed/kill plane, so its halves belong to the same write, and running
    ## the store copy and the CONFIG mirror once per frame instead of once per
    ## axis is what keeps that write off the frame budget.
    let clampedFeed = clampParamValue(climateDescriptors[caFeed], point[caFeed])
    let clampedKill = clampParamValue(climateDescriptors[caKill], point[caKill])
    updateSimulation(proc(simState: var SimulationState) =
      simState.rdFeed = clampedFeed
      simState.rdKill = clampedKill)

  proc commitParamImpl(id: string) =
    ## The slider-release side effect (the DOM "change" event): only the two
    ## count parameters carry one — everything else applies fully on set.
    ##
    ## The particle count RESIZES rather than reinitializes: dragging it does
    ## not destroy the world it is adjusting. The species count still
    ## reinitializes, and that asymmetry is real rather than an oversight —
    ## changing how many species exist changes what every particle's species
    ## index means, so there is no population to preserve.
    case id
    of "particleCount": triggerParticleResize()
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
      gpuPresentMs, gpuFieldMs: float) =
    ## Called from app.nim's frame loop (currently every ~500ms; the cadence
    ## is loop-side). Raw numbers — formatting belongs to the UI.
    ##
    ## `params` carries the parameters the SIMULATION writes on its own, so the
    ## panel learns of a drifting climate by being told rather than by asking.
    ## It rides this channel rather than one of its own because the panel needs
    ## a single subscription for everything the frame loop reports, and a
    ## second weather's axes join by appearing in the loop below.
    ##
    ## Sent on every push, not only while drift is on: the panel then holds the
    ## truth about these parameters whatever moved them, and never has to track
    ## which feature is currently writing which id.
    if statsCallbacks.len == 0:
      return
    let stats = newJsObject()
    let simulationWrites = newJsObject()
    for axis in ClimateAxis:
      let id = CLIMATE_PARAM_IDS[axis]
      simulationWrites[cstring(id)] = toJs(getParamImpl(id))
    stats["params"] = toJs(simulationWrites)
    stats["fps"] = toJs(fps)
    stats["particleCount"] = toJs(particleCount)
    stats["gridTimeMs"] = toJs(gridTimeMs)
    stats["workerTimeMs"] = toJs(workerTimeMs)
    stats["gpuGridMs"] = toJs(gpuGridMs)
    stats["gpuPhysicsMs"] = toJs(gpuPhysicsMs)
    stats["gpuDrawMs"] = toJs(gpuDrawMs)
    stats["gpuPresentMs"] = toJs(gpuPresentMs)
    stats["gpuFieldMs"] = toJs(gpuFieldMs)
    for callback in statsCallbacks:
      callback(stats)

  # ============================================================================
  # SECTION 8: PRESETS (snapshot / apply)
  # ============================================================================

  proc snapshotPreset(name: string): Preset =
    ## Capture the CURRENT live CONFIG, attraction matrix, species chemistry,
    ## and species palette as a Preset named `name`, stamped with the current
    ## wall-clock time.
    var settings: PresetSettings
    settings.particleCount = CONFIG.particleCount
    settings.speciesCount = CONFIG.speciesCount
    settings.interactionRadius = CONFIG.interactionRadius
    settings.forceStrength = CONFIG.forceStrength
    settings.crowdingStrength = CONFIG.crowdingStrength
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
    # Every field, and the fluid and chemistry ones especially: `settings` is
    # zero-initialized, so a field left out here serializes as 0 and reloads
    # clamped up to its range minimum. rdDeposit and rdFieldForce are
    # chemistry's coupling strengths, so an omission there turns chemistry off
    # across a save and load. tests/test_preset.nim pins the whole round trip.
    settings.sphRestDensity = CONFIG.sphRestDensity
    settings.sphStiffness = CONFIG.sphStiffness
    settings.sphRadiusFraction = CONFIG.sphRadiusFraction
    settings.sphViscosity = CONFIG.sphViscosity
    settings.sphSubsteps = CONFIG.sphSubsteps
    settings.rdFeed = CONFIG.rdFeed
    settings.rdKill = CONFIG.rdKill
    settings.rdDeposit = CONFIG.rdDeposit
    settings.rdFieldForce = CONFIG.rdFieldForce
    settings.fluidStrength = CONFIG.fluidStrength
    settings.climateDrift = CONFIG.climateDrift
    settings.climateSpeed = CONFIG.climateSpeed

    var matrixSnapshot: Matrix
    for matrixIdx in 0 ..< preset.MATRIX_LEN:
      matrixSnapshot[matrixIdx] = buffers.matrix[matrixIdx]

    var chemistrySnapshot: preset.Chemistry
    for chemistryIdx in 0 ..< preset.CHEMISTRY_LEN:
      chemistrySnapshot[chemistryIdx] = config.SPECIES_CHEMISTRY[chemistryIdx]

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
      settings: settings,
      matrix: matrixSnapshot,
      chemistry: chemistrySnapshot,
      palette: paletteSnapshot
    )

  proc applyPresetImpl(sourcePreset: Preset) =
    ## Apply every field of `sourcePreset` onto the live simulation, walking
    ## presetApplySteps() in the fixed order that module documents and pins
    ## natively. Never persists anything — storage belongs to the UI side.
    for step in presetApplySteps():
      case step
      of pasSpeciesCount:
        # No re-init here: particleCount is the one step that triggers it,
        # after the matrix bookkeeping is already sized for the target.
        updateSimulation(proc(simState: var SimulationState) =
          simState.speciesCount = sourcePreset.settings.speciesCount)
        applySpeciesCountChange(sourcePreset.settings.speciesCount,
          randomizeNew = false)
      of pasParticleCount:
        # THE ALLOCATION CEILING APPLIES HERE. Slider bounds alone would let a
        # preset — hand-edited, or saved by a build with a different buffer
        # size — leave the world running above what this build's buffers can
        # hold, so the starter presets need no count clamp of their own.
        #
        # A full reinit rather than a resize: applying a preset is adopting a
        # different world, so there is no population the user expects to
        # survive it.
        let clampedCount =
          min(sourcePreset.settings.particleCount, PARTICLE_COUNT_MAX)
        updateSimulation(proc(simState: var SimulationState) =
          simState.particleCount = clampedCount)
        triggerParticleReinit()
      of pasMatrix:
        for matrixIdx in 0 ..< sourcePreset.matrix.len:
          buffers.matrix[matrixIdx] = sourcePreset.matrix[matrixIdx]
      of pasChemistry:
        # Already clamped per channel by validateChemistry, against the same
        # asymmetric bounds the secretion and tropism descriptors enforce on a
        # grid edit — so a hand-edited preset cannot put a secretion or tropism
        # into the uniform that the editor would refuse.
        for chemistryIdx in 0 ..< sourcePreset.chemistry.len:
          config.SPECIES_CHEMISTRY[chemistryIdx] =
            sourcePreset.chemistry[chemistryIdx]
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
          simState.crowdingStrength = settings.crowdingStrength
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
          simState.sphRadiusFraction = settings.sphRadiusFraction
          simState.sphViscosity = settings.sphViscosity
          simState.sphSubsteps = settings.sphSubsteps
          simState.rdFeed = settings.rdFeed
          simState.rdKill = settings.rdKill
          simState.rdDeposit = settings.rdDeposit
          simState.rdFieldForce = settings.rdFieldForce
          simState.fluidStrength = settings.fluidStrength
          simState.climateDrift = settings.climateDrift
          simState.climateSpeed = settings.climateSpeed
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

  static:
    # The label list below is hand-written while the ramps themselves live in
    # colormap_core. A fourth ramp would otherwise be invisible in the panel
    # with nothing failing anywhere; this makes it fail the build instead.
    # Phrased against the index bounds rather than colormap_core's
    # COLORMAP_COUNT because those are what preset re-exports into this scope,
    # and COLORMAP_INDEX_MAX is defined as COLORMAP_COUNT - 1.
    doAssert COLORMAP_INDEX_MAX - COLORMAP_INDEX_MIN + 1 == 3

  let colormapArray = block:
    let jsArray = newJsArray()
    for (index, label) in [(0, "Inferno"), (1, "Viridis"), (2, "Two-Tone")]:
      let entry = newJsObject()
      entry["index"] = toJs(index)
      entry["label"] = toJs(cstring(label))
      jsArray.push(entry)
    jsArray

  # ----------------------------------------------------------------------------
  # Starter presets
  # ----------------------------------------------------------------------------
  #
  # Complete, already-valid presets served as JSON strings and applied through
  # the ordinary applyPresetJson path — no separate apply route, no schema
  # variant, nothing for the panel to interpret. They never touch localStorage,
  # which is the whole separation from the user's saved presets: no key to
  # collide with, no write path to be overwritten through, and "cannot be
  # deleted" holds without any code enforcing it.

  proc regimeStarter(label: string; feed, kill, minDeposit: float): string =
    ## A named point in the one world's parameter space, at one published
    ## Gray-Scott regime. Forces and chemistry both act, so the pattern records
    ## where colonies live rather than sitting behind them.
    ##
    ## The deposit floor comes from the regime: at RD_DEFAULT_DEPOSIT the
    ## high-feed regimes do not ignite at all, so one shared value would load a
    ## blank field for two of the six.
    var starter = defaultPreset()
    starter.name = label
    starter.settings.rdFeed = feed
    starter.settings.rdKill = kill
    starter.settings.rdDeposit = max(RD_DEFAULT_DEPOSIT, minDeposit)
    starter.settings.rdFieldForce = RD_DEFAULT_FIELD_FORCE
    toJsonString(starter)

  let builtinPresetArray = block:
    let jsArray = newJsArray()
    # Built FROM the regime table, not beside it: one set of coordinates, so a
    # starter and its slider notch cannot name the same point differently. The
    # feed and kill notches read the same table, so a starter lands on a tick.
    for regime in RD_REGIMES:
      let entry = newJsObject()
      entry["id"] = toJs(cstring("regime-" & regime.id))
      entry["label"] = toJs(cstring(regime.label))
      entry["json"] = toJs(cstring(regimeStarter(
        regime.label, regime.feed, regime.kill, regime.minDeposit)))
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
    # Bound a value against its descriptor without writing it, for the controls
    # that write their own storage: the per-species grid edits cells of the
    # live chemistry array directly, and this is how those edits meet the same
    # clamp a slider does.
    result["clampParam"] = toJs(proc(id: cstring; value: float): float =
      clampParamImpl($id, value))

    # Toggles
    result["getTrails"] = toJs(proc(): bool = CONFIG.trails)
    result["setTrails"] = toJs(proc(enabled: bool) = setTrailsImpl(enabled))
    result["getBloom"] = toJs(proc(): bool = CONFIG.bloomEnabled)
    result["setBloom"] = toJs(proc(enabled: bool) = setBloomImpl(enabled))

    # There is no world-selection surface here, and none is needed: what a
    # world does is the strengths it runs, and the panel asks for each by name
    # through the ordinary descriptor path, the same way it asks for friction.

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
    # Named reaction-diffusion regimes (feed/kill points, with the measured
    # deposit floor each needs to appear at all)
    result["getClimateDrift"] = toJs(proc(): bool = CONFIG.climateDrift)
    result["setClimateDrift"] = toJs(proc(enabled: bool) =
      setClimateDriftImpl(enabled))
    result["climateParamIds"] = toJs(proc(): JsObject = climateParamIdArray)

    result["rdRegimes"] = toJs(proc(): JsObject = regimeArray)
    result["getRdRegime"] = toJs(proc(): cstring = cstring(activeRegimeImpl()))
    result["applyRdRegime"] = toJs(proc(id: cstring) = applyRegimeImpl($id))

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

    # Species chemistry (live Float32Array, same contract as the matrix: the
    # frame loop copies it into the SpeciesChemistry uniform every frame, so an
    # edit written straight into the array lands on the next frame). Which
    # columns exist, and where each sits inside a species' stride, come from
    # the descriptor table's per-species entries — there is no second table.
    result["chemistry"] = toJs(proc(): Float32Array = config.SPECIES_CHEMISTRY)
    result["chemistryStride"] = toJs(proc(): int = SPECIES_CHEMISTRY_STRIDE)

    # Particles
    result["resetParticles"] = toJs(proc() = triggerParticleReinit())

    # Reaction-diffusion field. Fire-and-forget: the request is synchronous,
    # the seed lands on the next frame, and it is a no-op outside RD.
    result["reseedField"] = toJs(proc() = triggerFieldReseed())

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
    result["builtinPresets"] = toJs(proc(): JsObject = builtinPresetArray)
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
