# ==============================================================================
# PARTICLE GARDEN - PRESET STORE (JS glue)
# ==============================================================================
#
# The browser-side half of the preset store: localStorage persistence, DOM
# glue for the Presets control-panel section, and applying a loaded/imported
# Preset back onto the live simulation. Builds on preset.nim's pure schema
# (validation, serialization) and preset_store_core.nim's pure key/index/
# apply-order primitives.
#
# ui.nim owns particleCount/speciesCount re-initialization, the matrix
# editor, and the typed CONFIG mutation helpers (updateSimulation/
# updateRender) — all ui.nim-private state. Rather than import ui.nim here
# (which would be circular: ui.nim imports this module), applyPreset calls
# out through a small set of hooks that ui.nim registers once at setup, the
# same callback pattern ui.nim already uses for onInitParticles/onResize/
# onMatrixUpdate. Everything this module CAN do without ui.nim (writing the
# matrix/palette buffers directly, switching modes, refreshing sliders,
# syncing DOM button state) it does directly, importing the same low-level
# modules ui.nim imports.
#
# JS-only: no native test imports this module (see the sibling
# preset_store_core.nim for the pure, natively-tested primitives). Verified
# by `nimble app`.
#
# ==============================================================================

when defined(js):
  import std/json

  from std/dom import Element, getElementById
  from std/jsffi import toJs

  from ../../bindings/dom_extensions import HTMLInputElement
  from ../../bindings/js_interop import consoleWarn
  from ../../bindings/typed_arrays import Float32Array, `[]`, `[]=`
  import ../../bindings/window

  import ../../config
  import ../../buffers
  import ../../preset
  import ./preset_store_core
  import ../state/sim_config
  import ../controls/slider
  import ../controls/sim_mode_buttons

  # ============================================================================
  # SECTION 1: ISO TIMESTAMP
  # ============================================================================

  proc isoTimestampNow(): cstring {.importjs: "new Date().toISOString()".}
    ## Wall-clock ISO-8601 timestamp for a preset's createdAt. preset.nim has
    ## no clock access (pure, no FFI) by design; this is the one place a
    ## real value gets stamped in.

  # ============================================================================
  # SECTION 2: APPLY HOOKS (registered once by ui.nim's setupPresetStoreHooks)
  # ============================================================================
  #
  # See the file header: these cover the three apply steps that touch
  # ui.nim-private state (the matrix editor's re-init ordering, the typed
  # CONFIG mutation helpers). Every other step (mode, matrix, palette,
  # slider/DOM refresh) this module performs directly.

  var speciesCountApplyHook: proc(newCount: int) = nil
  var particleCountApplyHook: proc(newCount: int) = nil
  var scalarsApplyHook: proc(settings: PresetSettings) = nil
  var matrixDisplayRefreshHook: proc() = nil
  var paletteApplyHook: proc(loadedPalette: Palette) = nil

  proc onPaletteApply*(callback: proc(loadedPalette: Palette)) {.exportc.} =
    ## Registers how to apply a preset's palette (ui.nim writes the colors
    ## into COLORS AND marks its palette editor state custom, so the editor's
    ## generated palette cannot clobber the loaded colors on its next touch).
    ## Without a registered hook, pasPalette falls back to writing COLORS
    ## directly.
    paletteApplyHook = callback

  proc onSpeciesCountApply*(callback: proc(newCount: int)) {.exportc.} =
    ## Registers how to apply a preset's speciesCount without re-initializing
    ## particles (ui.nim's setSpeciesCount(n, randomizeNew = false)).
    speciesCountApplyHook = callback

  proc onParticleCountApply*(callback: proc(newCount: int)) {.exportc.} =
    ## Registers how to apply a preset's particleCount AND trigger the one
    ## re-init the whole apply performs (ui.nim's updateSimulation + the
    ## particleCount slider's own onInitParticles path).
    particleCountApplyHook = callback

  proc onScalarsApply*(callback: proc(settings: PresetSettings)) {.exportc.} =
    ## Registers how to apply every remaining scalar setting (friction,
    ## timeScale, forceModel, trails, glow knobs, ...) via ui.nim's
    ## updateSimulation/updateRender/setForceModel/setTrails.
    scalarsApplyHook = callback

  proc onMatrixDisplayRefresh*(callback: proc()) {.exportc.} =
    ## Registers ui.nim's updateMatrixDisplay (re-renders the matrix legend
    ## from the matrix editor, which is ui.nim-private state).
    matrixDisplayRefreshHook = callback

  # ============================================================================
  # SECTION 3: LOCALSTORAGE HELPERS
  # ============================================================================

  proc storage(): Storage =
    localStorage(windowObj)

  proc readIndex(): seq[string] =
    ## The saved-preset-name index, or an empty seq if none has been saved
    ## yet (or the stored value is missing/malformed — parseIndexJson never
    ## raises).
    let raw = storage().getItem(cstring(PRESET_INDEX_KEY))
    if raw.isNil: newSeq[string]()
    else: parseIndexJson($raw)

  proc escapeHtml(text: string): string =
    ## Escape a preset name for safe interpolation into the presetList
    ## <option> markup built via innerHTML below. A name is user-supplied
    ## (typed at Save, or hand-edited in an imported/localStorage value), so
    ## it must not be able to break out of the surrounding markup.
    result = ""
    for character in text:
      case character
      of '&': result.add("&amp;")
      of '<': result.add("&lt;")
      of '>': result.add("&gt;")
      of '"': result.add("&quot;")
      of '\'': result.add("&#39;")
      else: result.add(character)

  # ============================================================================
  # SECTION 4: SNAPSHOT (live state -> Preset)
  # ============================================================================

  proc snapshotPreset*(name: string): Preset =
    ## Capture the CURRENT live CONFIG, attraction matrix, species palette,
    ## and active mode as a Preset named `name`, stamped with the current
    ## wall-clock time.
    var settings: PresetSettings
    settings.particleCount = config.CONFIG.particleCount
    settings.speciesCount = config.CONFIG.speciesCount
    settings.interactionRadius = config.CONFIG.interactionRadius
    settings.forceStrength = config.CONFIG.forceStrength
    settings.friction = config.CONFIG.friction
    settings.ruleTemperature = config.CONFIG.ruleTemperature
    settings.timeScale = config.CONFIG.timeScale
    settings.particleSize = config.CONFIG.particleSize
    settings.trails = config.CONFIG.trails
    settings.trailLength = config.CONFIG.trailLength
    settings.glowIntensity = config.CONFIG.glowIntensity
    settings.velocityGlowScale = config.CONFIG.velocityGlowScale
    settings.maxVelocity = config.CONFIG.maxVelocity
    settings.repulsionEnd = config.CONFIG.repulsionEnd
    settings.attractionPeak = config.CONFIG.attractionPeak
    settings.forceModel = config.CONFIG.forceModel
    settings.expRepulsionAlpha = config.CONFIG.expRepulsionAlpha
    settings.expAttractionBeta = config.CONFIG.expAttractionBeta
    settings.glowRadiusScale = config.CONFIG.glowRadiusScale
    settings.glowFalloff = config.CONFIG.glowFalloff
    settings.glowWarmth = config.CONFIG.glowWarmth
    settings.bloomEnabled = config.CONFIG.bloomEnabled
    settings.bloomIntensity = config.CONFIG.bloomIntensity
    settings.exposure = config.CONFIG.exposure
    settings.saturation = config.CONFIG.saturation
    settings.contrast = config.CONFIG.contrast
    settings.temperature = config.CONFIG.temperature
    settings.colormapIndex = config.CONFIG.colormapIndex
    settings.fieldOpacity = config.CONFIG.fieldOpacity

    var matrixSnapshot: Matrix
    for matrixIndex in 0 ..< preset.MATRIX_LEN:
      matrixSnapshot[matrixIndex] = buffers.matrix[matrixIndex]

    var paletteSnapshot: Palette
    for speciesIndex in 0 ..< preset.MAX_SPECIES:
      paletteSnapshot[speciesIndex] = [
        config.COLORS[speciesIndex * 3],
        config.COLORS[speciesIndex * 3 + 1],
        config.COLORS[speciesIndex * 3 + 2]
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

  # ============================================================================
  # SECTION 5: APPLY (Preset -> live state)
  # ============================================================================

  proc applyPreset*(sourcePreset: Preset) =
    ## Apply every field of `sourcePreset` onto the live simulation, walking
    ## presetApplySteps() in the fixed order that module documents. Never
    ## persists anything — Load and Import both call this, and only Save
    ## writes to localStorage.
    for step in presetApplySteps():
      case step
      of pasMode:
        try:
          let kind = parseSimKind(sourcePreset.mode)
          activeSimKind.set(kind)
          syncSimModeButtons(kind)
        except ValueError:
          # Forward-compatible: a preset from a future build may carry a
          # mode this build cannot run yet (see preset.nim's "an
          # unrecognized mode string is preserved, not rejected"). Keep
          # running the current mode rather than crashing the apply.
          consoleWarn(("[preset] unknown mode id \"" & sourcePreset.mode &
            "\" - keeping the current mode").toJs)
      of pasSpeciesCount:
        if not speciesCountApplyHook.isNil:
          speciesCountApplyHook(sourcePreset.settings.speciesCount)
      of pasParticleCount:
        if not particleCountApplyHook.isNil:
          particleCountApplyHook(sourcePreset.settings.particleCount)
      of pasMatrix:
        for matrixIndex in 0 ..< sourcePreset.matrix.len:
          buffers.matrix[matrixIndex] = sourcePreset.matrix[matrixIndex]
      of pasPalette:
        if not paletteApplyHook.isNil:
          paletteApplyHook(sourcePreset.palette)
        else:
          for speciesIndex in 0 ..< sourcePreset.palette.len:
            let color = sourcePreset.palette[speciesIndex]
            config.COLORS[speciesIndex * 3] = color[0]
            config.COLORS[speciesIndex * 3 + 1] = color[1]
            config.COLORS[speciesIndex * 3 + 2] = color[2]
      of pasScalars:
        if not scalarsApplyHook.isNil:
          scalarsApplyHook(sourcePreset.settings)
      of pasUiRefresh:
        refreshRegisteredSliders()
        if not matrixDisplayRefreshHook.isNil:
          matrixDisplayRefreshHook()

  # ============================================================================
  # SECTION 6: PRESET LIST DOM
  # ============================================================================

  proc refreshPresetListDom*() =
    ## Repopulate #presetList's <option> entries from the saved-name index.
    let selectEl = getElementById(cstring("presetList"))
    if selectEl.isNil:
      return
    var optionsHtml = ""
    for name in readIndex():
      let escaped = escapeHtml(name)
      optionsHtml.add("<option value=\"" & escaped & "\">" & escaped & "</option>")
    selectEl.innerHTML = cstring(optionsHtml)

  # ============================================================================
  # SECTION 7: SAVE / LOAD
  # ============================================================================

  proc savePreset*(rawName: string) {.exportc.} =
    ## Normalize `rawName`, confirm before overwriting an existing preset,
    ## persist the current live state under it, and update the index.
    let name = normalizePresetName(rawName)
    if name.len == 0:
      windowAlert(cstring("Preset name cannot be empty."))
      return
    let key = presetStorageKey(name)
    if key == PRESET_INDEX_KEY:
      # presetStorageKey(name) == PRESET_INDEX_KEY only when name literally
      # composes to the index's own key; guard generically (not against the
      # literal "index") so a saved preset can never overwrite the index
      # that lists it.
      windowAlert(cstring("The name \"" & name & "\" is reserved; please choose a different name."))
      return
    let existingRaw = storage().getItem(cstring(key))
    if not existingRaw.isNil:
      if not windowObj.confirm(cstring("A preset named \"" & name & "\" already exists. Overwrite it?")):
        return
    let snapshot = snapshotPreset(name)
    storage().setItem(cstring(key), cstring(toJsonString(snapshot)))
    let updatedIndex = addToIndex(readIndex(), name)
    storage().setItem(cstring(PRESET_INDEX_KEY), cstring(indexToJson(updatedIndex)))
    refreshPresetListDom()

  proc loadPresetByName*(name: string) {.exportc.} =
    ## Load and apply the preset saved under `name`. Alerts (without
    ## applying anything) on a missing or unparseable preset.
    let raw = storage().getItem(cstring(presetStorageKey(name)))
    if raw.isNil:
      windowAlert(cstring("No preset named \"" & name & "\" was found."))
      return
    let loadResult = parsePreset($raw)
    if loadResult.isOk:
      applyPreset(loadResult.preset)
    else:
      windowAlert(cstring("Could not load preset \"" & name & "\": " & loadResult.errorMessage))

  # ============================================================================
  # SECTION 8: BUTTON HANDLERS (exposed to web/index.html onclick attributes)
  # ============================================================================

  proc selectedPresetName(): string =
    let selectEl = cast[HTMLInputElement](getElementById(cstring("presetList")))
    if selectEl.isNil: ""
    else: $selectEl.value

  proc selectedPresetNameOrDefault(): string =
    let name = selectedPresetName()
    if name.len > 0: name else: DEFAULT_PRESET_NAME

  proc presetSaveClicked*() {.exportc.} =
    ## Save button: prompt for a name (defaulting to the current selection,
    ## or the schema default), then save. A cancelled prompt saves nothing.
    let entered = windowObj.prompt(cstring("Preset name:"), cstring(selectedPresetNameOrDefault()))
    if entered.isNil:
      return
    savePreset($entered)

  proc presetLoadClicked*() {.exportc.} =
    ## Load button: load whichever preset #presetList currently has selected.
    let name = selectedPresetName()
    if name.len == 0:
      windowAlert(cstring("Select a preset to load first."))
      return
    loadPresetByName(name)

  proc presetExportClicked*() {.exportc.} =
    ## Export button: pretty-print the current live state into the JSON
    ## textarea (does not touch localStorage).
    let snapshot = snapshotPreset(selectedPresetNameOrDefault())
    let textAreaEl = cast[HTMLInputElement](getElementById(cstring("presetJsonArea")))
    if not textAreaEl.isNil:
      textAreaEl.value = cstring(pretty(toJson(snapshot)))

  proc presetImportClicked*() {.exportc.} =
    ## Import button: parse and apply the JSON textarea's contents. Never
    ## auto-saves — Save is a separate, explicit step. A structurally
    ## invalid textarea alerts with the parse error rather than applying a
    ## silently repaired preset.
    let textAreaEl = cast[HTMLInputElement](getElementById(cstring("presetJsonArea")))
    if textAreaEl.isNil:
      return
    let loadResult = parsePreset($textAreaEl.value)
    if loadResult.isOk:
      applyPreset(loadResult.preset)
    else:
      windowAlert(cstring("Could not import preset: " & loadResult.errorMessage))
