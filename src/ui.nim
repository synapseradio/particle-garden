# ==============================================================================
# PARTICLE GARDEN - UI MODULE
# ==============================================================================
#
# UI and DOM interaction module for Particle Garden.
#
# Handles:
# - Slider/input bindings to CONFIG values
# - Mouse and touch event handling
# - Window resize events
# - UI toggle functions (trails, controls panel)
# - Attraction matrix display and editing
# - Stats display updates
#
# Compile with: nim js -o:web/ui.js src/ui.nim
#
# ==============================================================================

from std/dom import
  Element, Node, Event, MouseEvent, TouchEvent, Window, ClassList,
  getElementById, querySelector, querySelectorAll, contains, preventDefault,
  toggle

from std/jsffi import JsObject, toJs, `[]`, `[]=`

from bindings/js_interop import
  Console, console, log, isUndefined, isJsFunction

from bindings/dom_extensions import
  HTMLElement, HTMLInputElement, HTMLCanvasElement,
  domDocument, domWindow,
  addEventListener, forEach, dataset, setClass

from bindings/typed_arrays import Float32Array, `[]`, `[]=`

import config
import config_ranges
import preset
import buffers

# New reactive state system
import ui/core/observable
import ui/state/input_state
import ui/state/sim_config
import ui/state/palette_state
import ui/matrix/matrix_view
import ui/input/mouse_handler
import ui/input/touch_handler
import ui/controls/slider
import ui/controls/control_panel
import ui/stats/stats_view
import ui/dom_helpers
# ui/presets depends on ui/state/sim_config, ui/dom_helpers, and
# ui/controls/slider (refreshRegisteredSliders) above; it must import after
# all three, so it is the last import here rather than immediately after
# the ui/state group.
import ui/presets/preset_store

# ==============================================================================
# SECTION 2: ADDITIONAL JS FFI BINDINGS
# ==============================================================================
# These supplement the bindings from dom.nim and js_interop.nim


# ==============================================================================
# SECTION 3: INPUT STATE (reactive + legacy shims)
# ==============================================================================
#
# The canonical input state is now in currentInput (Observable[InputState]).
# The exported vars below are shims for backward compatibility with app.nim.
# They are synced automatically when currentInput changes.

# Observable holding the true input state
var currentInput* = newObservable(initInputState())

# Accessor procs - read directly from observable (no shims)
proc getMouseX*(): float = currentInput.get().mouseX
proc getMouseY*(): float = currentInput.get().mouseY
proc getMouseDown*(): bool = currentInput.get().mouseDown
proc getMouseRightDown*(): bool = currentInput.get().mouseRightDown
proc getBlastX*(): float = currentInput.get().blastX
proc getBlastY*(): float = currentInput.get().blastY
proc getBlastStrength*(): float = currentInput.get().blastStrength

# Frame update - decays blast in the observable
const BLAST_DECAY_FACTOR = 0.85
proc updateInputState*() =
  let current = currentInput.get()
  if current.hasActiveBlast():
    currentInput.set(current.withBlastDecay(BLAST_DECAY_FACTOR))

# ==============================================================================
# SECTION 3b: TYPED CONFIG STATE
# ==============================================================================
#
# The typed tunable records are the mutation surface; CONFIG stays the flat
# GPU-facing mirror the hot paths read. Every mutation goes through the
# update helpers below, which write the observable AND the mirror in the
# same tick — a subscription-based mirror would flush on a microtask, and
# programmatic setValue calls onChange synchronously, which would then read
# a stale CONFIG.

var currentSimulation* = newObservable(initSimulationState())
var currentRender* = newObservable(initRenderState())

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

proc applyRenderToConfig(renderState: RenderState) =
  CONFIG.particleSize = renderState.particleSize
  CONFIG.trails = renderState.trails
  CONFIG.trailLength = renderState.trailLength
  CONFIG.glowIntensity = renderState.glowIntensity
  CONFIG.velocityGlowScale = renderState.velocityGlowScale
  CONFIG.glowRadiusScale = renderState.glowRadiusScale
  CONFIG.glowFalloff = renderState.glowFalloff
  CONFIG.glowWarmth = renderState.glowWarmth

proc updateSimulation*(mutate: proc(simState: var SimulationState)) =
  ## Mutate a copy of the simulation state, publish it, and mirror it into
  ## CONFIG synchronously.
  var simState = currentSimulation.get()
  mutate(simState)
  currentSimulation.set(simState)
  applySimulationToConfig(simState)

proc updateRender*(mutate: proc(renderState: var RenderState)) =
  ## Mutate a copy of the render state, publish it, and mirror it into
  ## CONFIG synchronously.
  var renderState = currentRender.get()
  mutate(renderState)
  currentRender.set(renderState)
  applyRenderToConfig(renderState)

# ==============================================================================
# SECTION 4: CALLBACK REFERENCES
# ==============================================================================

# Set via setInitParticlesCallback - called when particle/species count changes
var onInitParticles* {.exportc.}: proc() = nil

# Set via setResizeCallback - called on window resize
var onResize* {.exportc.}: proc() = nil

# Callback for when matrix is updated
var onMatrixUpdate* {.exportc.}: proc() = nil

# ==============================================================================
# SECTION 5: CALLBACK SETTERS
# ==============================================================================

proc setInitParticlesCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for particle reinitialization.
  console.log("[ui] setInitParticlesCallback called, callback isNil:".toJs, callback.isNil.toJs)
  onInitParticles = callback
  console.log("[ui] onInitParticles set, now isNil:".toJs, onInitParticles.isNil.toJs)

proc setResizeCallback*(callback: proc()) {.exportc.} =
  ## Set the callback for window resize.
  onResize = callback

# ==============================================================================
# SECTION 6: FORWARD DECLARATIONS
# ==============================================================================

# Forward declarations for procs used before they are defined
proc randomizeMatrix*() {.exportc.}
proc updateMatrixDisplay*() {.exportc.}
proc applySpeciesCountChange(newCount: int, randomizeNew: bool)
proc applyPaletteToColors()
proc setupPresetStoreHooks*() {.exportc.}

# The matrix editor instance (delegates live in Section 10). The exportc
# name forces the JS backend to assign the global its generated name up
# front; without it, codegen of the forward-declared delegates dies with
# "symbol has no generated name".
var matrixEditor {.exportc: "pgMatrixEditor".}: MatrixEditor = nil

# The species count the matrix grid last rendered with; lets a grow
# distinguish newly exposed cells from established ones.
var lastSpeciesCount {.exportc: "pgLastSpeciesCount".}: int = 0

# The palette editor's live scheme/saturation/lightness (Section 10b).
# setupUI's palette sliders read/write this before Section 10b's proc
# bodies appear in the file, so it is declared here alongside the other
# module globals setupUI depends on.
var paletteEditorState {.exportc: "pgPaletteEditorState".}: PaletteEditorState =
  initPaletteEditorState()

proc initMatrixEditor() =
  ## Create the matrix editor over the shared buffers. Runs first in setupUI,
  ## so the editor exists before any slider callback can randomize or render.
  matrixEditor = newMatrixEditor(
    "matrixDisplay", matrix, COLORS, addr CONFIG.speciesCount)
  matrixEditor.onUpdate = proc() =
    if not onMatrixUpdate.isNil:
      onMatrixUpdate()
  lastSpeciesCount = CONFIG.speciesCount

# ==============================================================================
# SECTION 7: UI SETUP
# ==============================================================================

proc setupUI*() {.exportc.} =
  ## Bind slider inputs to CONFIG values. Every range comes from
  ## config_ranges.nim — the same constants preset.nim clamps with, so the
  ## UI and the preset schema cannot drift apart.

  initMatrixEditor()

  # Simulation sliders
  configSlider("particleCount", "particleValue",
    get = proc(): float = CONFIG.particleCount.float,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.particleCount = value.int),
    min = PARTICLE_COUNT_MIN.float, max = PARTICLE_COUNT_MAX.float,
    onChange = proc() =
      if not onInitParticles.isNil: onInitParticles()
  )

  configSlider("speciesCount", "speciesValue",
    get = proc(): float = CONFIG.speciesCount.float,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.speciesCount = value.int),
    min = SPECIES_COUNT_MIN.float, max = SPECIES_COUNT_MAX.float,
    onChange = proc() =
      # Interactive grow randomizes only the newly exposed matrix cells;
      # shrink preserves values (they reappear on re-grow).
      applySpeciesCountChange(CONFIG.speciesCount, randomizeNew = true)
      if not onInitParticles.isNil: onInitParticles()
  )

  configSlider("interactionRadius", "radiusValue",
    get = proc(): float = CONFIG.interactionRadius.float,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.interactionRadius = value.int),
    min = INTERACTION_RADIUS_MIN.float, max = INTERACTION_RADIUS_MAX.float
  )

  configSlider("forceStrength", "forceValue",
    get = proc(): float = CONFIG.forceStrength,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.forceStrength = value),
    min = FORCE_STRENGTH_MIN, max = FORCE_STRENGTH_MAX, precision = 1
  )

  configSlider("friction", "frictionValue",
    get = proc(): float = CONFIG.friction,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.friction = value),
    min = FRICTION_MIN, max = FRICTION_MAX, precision = 2
  )

  configSlider("timeScale", "timeScaleValue",
    get = proc(): float = CONFIG.timeScale,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.timeScale = value),
    min = TIME_SCALE_MIN, max = TIME_SCALE_MAX, precision = 1
  )

  configSlider("ruleTemperature", "ruleTemperatureValue",
    get = proc(): float = CONFIG.ruleTemperature,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.ruleTemperature = value),
    min = RULE_TEMPERATURE_MIN, max = RULE_TEMPERATURE_MAX, precision = 2
  )

  configSlider("maxVelocity", "velocityValue",
    get = proc(): float = CONFIG.maxVelocity,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.maxVelocity = value),
    min = MAX_VELOCITY_MIN, max = MAX_VELOCITY_MAX
  )

  # Render sliders
  configSlider("particleSize", "particleSizeValue",
    get = proc(): float = CONFIG.particleSize.float,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.particleSize = value.int),
    min = PARTICLE_SIZE_MIN.float, max = PARTICLE_SIZE_MAX.float
  )

  configSlider("trailLength", "trailValue",
    get = proc(): float = CONFIG.trailLength,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.trailLength = value),
    min = TRAIL_LENGTH_MIN, max = TRAIL_LENGTH_MAX, precision = 0
  )

  configSlider("glowIntensity", "glowValue",
    get = proc(): float = CONFIG.glowIntensity,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.glowIntensity = value),
    min = GLOW_INTENSITY_MIN, max = GLOW_INTENSITY_MAX, precision = 1
  )

  configSlider("velocityGlowScale", "velocityGlowValue",
    get = proc(): float = CONFIG.velocityGlowScale,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.velocityGlowScale = value),
    min = VELOCITY_GLOW_SCALE_MIN, max = VELOCITY_GLOW_SCALE_MAX, precision = 1
  )

  configSlider("glowRadiusScale", "glowRadiusScaleValue",
    get = proc(): float = CONFIG.glowRadiusScale,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.glowRadiusScale = value),
    min = GLOW_RADIUS_SCALE_MIN, max = GLOW_RADIUS_SCALE_MAX, precision = 1
  )

  configSlider("glowFalloff", "glowFalloffValue",
    get = proc(): float = CONFIG.glowFalloff,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.glowFalloff = value),
    min = GLOW_FALLOFF_MIN, max = GLOW_FALLOFF_MAX, precision = 1
  )

  configSlider("glowWarmth", "glowWarmthValue",
    get = proc(): float = CONFIG.glowWarmth,
    set = proc(value: float) = updateRender(
      proc(renderState: var RenderState) = renderState.glowWarmth = value),
    min = GLOW_WARMTH_MIN, max = GLOW_WARMTH_MAX, precision = 2
  )

  # Force Model sliders
  configSlider("repulsionEnd", "repulsionEndValue",
    get = proc(): float = CONFIG.repulsionEnd,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.repulsionEnd = value),
    min = REPULSION_END_MIN, max = REPULSION_END_MAX, precision = 2
  )

  configSlider("attractionPeak", "attractionPeakValue",
    get = proc(): float = CONFIG.attractionPeak,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.attractionPeak = value),
    min = ATTRACTION_PEAK_MIN, max = ATTRACTION_PEAK_MAX, precision = 2
  )

  configSlider("expRepulsionAlpha", "expRepulsionAlphaValue",
    get = proc(): float = CONFIG.expRepulsionAlpha,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.expRepulsionAlpha = value),
    min = EXP_REPULSION_ALPHA_MIN, max = EXP_REPULSION_ALPHA_MAX, precision = 2
  )

  configSlider("expAttractionBeta", "expAttractionBetaValue",
    get = proc(): float = CONFIG.expAttractionBeta,
    set = proc(value: float) = updateSimulation(
      proc(simState: var SimulationState) = simState.expAttractionBeta = value),
    min = EXP_ATTRACTION_BETA_MIN, max = EXP_ATTRACTION_BETA_MAX, precision = 2
  )

  # Palette sliders. Unlike the sliders above, these do NOT write CONFIG:
  # they read/write paletteEditorState directly and are not part of
  # SimConfig or the preset store (see palette_state.nim). Regenerating a
  # 6-color palette is cheap (unlike a particle re-init), so `set` applies
  # it on every drag tick for live color feedback rather than waiting for
  # `onChange` on release.
  configSlider("paletteSaturation", "paletteSaturationValue",
    get = proc(): float = paletteEditorState.saturation,
    set = proc(value: float) =
      paletteEditorState.saturation = value
      applyPaletteToColors(),
    min = PALETTE_SATURATION_MIN, max = PALETTE_SATURATION_MAX, precision = 2
  )

  configSlider("paletteLightness", "paletteLightnessValue",
    get = proc(): float = paletteEditorState.lightness,
    set = proc(value: float) =
      paletteEditorState.lightness = value
      applyPaletteToColors(),
    min = PALETTE_LIGHTNESS_MIN, max = PALETTE_LIGHTNESS_MAX, precision = 2
  )

  setupPresetStoreHooks()

# ==============================================================================
# SECTION 8: EVENT SETUP
# ==============================================================================

proc setupEvents*(canvas: JsObject) {.exportc.} =
  ## Set up mouse, touch, and resize event handlers.
  ##
  ## Event handlers use pure functions from mouse_handler/touch_handler
  ## to compute new state, then update the currentInput observable.
  ## Legacy shims are synced automatically via subscription.
  ##
  ## @param canvas - The canvas element for mouse/touch events

  let canvasEl = cast[HTMLCanvasElement](canvas)

  # Window resize
  domWindow.addEventListener("resize", proc() =
    if not onResize.isNil:
      onResize()
  )

  # Mouse events - use pure handlers
  canvasEl.addEventListener("mousedown", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseDown(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseup", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseUp(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseleave", proc(event: MouseEvent) =
    currentInput.set(handleMouseLeave(currentInput.get()))
  )

  # Prevent context menu on right-click
  canvasEl.addEventListener("contextmenu", proc(event: Event) =
    preventDefault(event)
  )

  # Double-click triggers blast effect (powerful repellent)
  canvasEl.addEventListener("dblclick", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleDoubleClick(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mousemove", proc(event: MouseEvent) =
    let eventData = extractMouseData(event)
    currentInput.set(handleMouseMove(currentInput.get(), eventData))
  )

  # Touch events - use pure handlers
  canvasEl.addEventListener("touchstart", proc(event: TouchEvent) =
    preventDefault(event)
    let eventData = extractTouchData(event)
    currentInput.set(handleTouchStart(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("touchend", proc(event: TouchEvent) =
    # TouchEvent.touches contains remaining touches after this one ends
    let eventData = extractTouchData(event)
    currentInput.set(handleTouchEnd(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("touchmove", proc(event: TouchEvent) =
    preventDefault(event)
    let eventData = extractTouchData(event)
    currentInput.set(handleTouchMove(currentInput.get(), eventData))
  )

# ==============================================================================
# SECTION 9: UI TOGGLE FUNCTIONS
# ==============================================================================

# Panel visibility/toggle state; transitions live in control_panel and are
# natively tested. CONFIG.trails mirrors panelState for the GPU-facing path.
var panelState {.exportc: "pgPanelState".}: PanelState = initPanelState()

proc toggleTrails*() {.exportc.} =
  ## Toggle trail rendering mode.
  ## Updates button state and shows/hides trail length slider.
  panelState = control_panel.toggleTrails(panelState)
  let trailsOn = control_panel.hasTrails(panelState)
  updateRender(proc(renderState: var RenderState) = renderState.trails = trailsOn)
  setActive("trailBtn", trailsOn)
  setVisible("trailSettings", trailsOn)

proc setTrails*(enabled: bool) {.exportc.} =
  ## Set trail rendering to an explicit value (preset apply): unlike
  ## toggleTrails, this does not flip the current state — it lets a preset
  ## land on its exact saved value regardless of what trails was before.
  panelState = control_panel.withTrailsEnabled(panelState, enabled)
  updateRender(proc(renderState: var RenderState) = renderState.trails = enabled)
  setActive("trailBtn", enabled)
  setVisible("trailSettings", enabled)

proc showWebGPURequiredOverlay*() {.exportc.} =
  ## Show the "WebGPU required" overlay. Called when WebGPU init or the
  ## render/compute pipeline setup fails; WebGPU is the only pipeline.
  show("webgpu-required")

proc toggleControls*() {.exportc.} =
  ## Toggle controls panel visibility.
  ## Updates collapse button text.

  panelState = toggleCollapsed(panelState)
  let controls = cast[HTMLElement](getElementById("controls"))
  discard controls.classList.setClass("collapsed", panelState.isCollapsed())
  let btn = controls.querySelector(".collapse-btn")
  btn.textContent = cstring(collapseButtonText(panelState))

proc toggleSection(sectionId: string) =
  ## Toggle a collapsible section's visibility.
  let section = cast[HTMLElement](getElementById(cstring(sectionId)))
  let content = cast[HTMLElement](section.querySelector(".section-content"))
  let toggle = section.querySelector(".section-toggle")
  let isHidden = content.style.display == "none"
  content.style.display = if isHidden: cstring"block" else: cstring"none"
  toggle.textContent = if isHidden: cstring"−" else: cstring"+"

proc toggleForceModelSection*() {.exportc.} =
  ## Toggle Force Model section visibility.
  toggleSection("forceModelSection")

proc toggleGlowSection*() {.exportc.} =
  ## Toggle Glow section visibility.
  toggleSection("glowSection")

proc togglePaletteSection*() {.exportc.} =
  ## Toggle Palette section visibility.
  toggleSection("paletteSection")

proc togglePresetsSection*() {.exportc.} =
  ## Toggle Presets section visibility.
  toggleSection("presetsSection")

proc setForceModel*(model: int) {.exportc.} =
  ## Set the force model and update UI visibility.
  ## @param model - 0 for polynomial, 1 for exponential
  updateSimulation(proc(simState: var SimulationState) = simState.forceModel = model)
  setActive("polyModelBtn", model == 0)
  setActive("expModelBtn", model == 1)
  setVisible("polynomialParams", model == 0)
  setVisible("exponentialParams", model == 1)

proc setSimMode*(modeId: cstring) {.exportc.} =
  ## Switch the active simulation mode (mode-selector buttons). Modes are
  ## addressed by sim_registry's stable string ids, never enum ordinals;
  ## app.nim subscribes activeSimKind to the compute executor.
  let kind = parseSimKind($modeId)
  activeSimKind.set(kind)
  setActive("modeParticleLifeBtn", kind == skParticleLife)

# ==============================================================================
# SECTION 10: MATRIX UI
# ==============================================================================
#
# The matrix editor lives in ui/matrix/matrix_view (DOM glue) on top of
# ui/state/matrix_state (pure grid markup + rule sampling). The exported
# procs below are the stable entry points app.nim and index.html call.

proc setMatrixUpdateCallback*(callback: proc()) {.exportc.} =
  ## Set callback for matrix updates.
  ## Called after randomizeMatrix() or an in-grid cell edit.
  ##
  ## @param callback - Called when matrix values change
  onMatrixUpdate = callback

proc updateMatrixDisplay*() {.exportc.} =
  ## Re-render the matrix editor grid from current values and colors.
  matrixEditor.render()

proc randomizeMatrix*() {.exportc.} =
  ## Randomize all values in the attraction matrix.
  ## Values range from -1 (repulsion) to +1 (attraction).
  matrixEditor.randomize(CONFIG.ruleTemperature)
  console.log("Matrix randomized - sample values:".toJs, matrix[0].toJs, matrix[1].toJs, matrix[6].toJs, matrix[7].toJs)

proc applySpeciesCountChange(newCount: int, randomizeNew: bool) =
  ## React to a species-count change: a grow randomizes only the newly
  ## exposed matrix band (when randomizeNew), a shrink just re-renders —
  ## hidden values persist in the buffer and reappear on re-grow.
  let exposed = newlyExposedCells(lastSpeciesCount, newCount)
  lastSpeciesCount = newCount
  if randomizeNew:
    matrixEditor.randomizeCells(exposed, CONFIG.ruleTemperature)
  else:
    matrixEditor.render()

proc setSpeciesCount*(newCount: int, randomizeNew: bool = false) {.exportc.} =
  ## Programmatic species-count change (preset apply): updates the typed
  ## state and the matrix grid without re-initializing particles — the
  ## caller owns that ordering.
  updateSimulation(proc(simState: var SimulationState) =
    simState.speciesCount = newCount)
  applySpeciesCountChange(newCount, randomizeNew)

# ==============================================================================
# SECTION 10b: PALETTE UI
# ==============================================================================
#
# The palette editor: five scheme buttons plus saturation/lightness sliders.
# Changing any of them regenerates the six species colors via
# palette_state's pure paletteFor/flatPaletteFor and writes them into COLORS
# in place. webgpu_render.nim repacks COLORS into the GPU colors uniform
# every frame, so no explicit GPU upload is needed here — the matrix legend
# is the only thing that needs an explicit re-render.
#
# paletteEditorState (declared in Section 6, alongside the other globals
# setupUI depends on) is deliberately not part of SimConfig or the preset
# store (see palette_state.nim): it is session-only UI state.

proc applyPaletteToColors() =
  ## Regenerate the six species colors from paletteEditorState and write
  ## them into COLORS in place, then re-render the matrix legend swatches.
  let flatPalette = flatPaletteFor(paletteEditorState)
  for colorIndex in 0 ..< flatPalette.len:
    COLORS[colorIndex] = flatPalette[colorIndex]
  updateMatrixDisplay()

proc setPaletteScheme*(schemeIdValue: cstring) {.exportc.} =
  ## Switch the active palette scheme (palette-selector buttons). Schemes
  ## are addressed by palette_state's stable string ids, never enum
  ## ordinals.
  let scheme = parsePaletteScheme($schemeIdValue)
  paletteEditorState.scheme = scheme
  applyPaletteToColors()
  setActive("paletteOpenColorBtn", scheme == psOpenColor)
  setActive("paletteGoldenBtn", scheme == psGolden)
  setActive("paletteSpectrumBtn", scheme == psSpectrum)
  setActive("paletteWarmBtn", scheme == psWarm)
  setActive("paletteCoolBtn", scheme == psCool)

# ==============================================================================
# SECTION 10c: PRESET STORE WIRING
# ==============================================================================
#
# preset_store.nim (JS glue, ui/presets/preset_store.nim) cannot import
# ui.nim — ui.nim imports it, and Nim forbids the cycle — so it exposes a
# handful of apply hooks for the three preset-apply steps that touch
# ui.nim-private state (setSpeciesCount's re-init ordering, the typed
# updateSimulation/updateRender/setForceModel/setTrails helpers, and the
# matrix editor). Everything else (mode switching, writing the matrix/
# palette buffers, refreshing sliders) preset_store does directly. Called
# once from setupUI.

proc setupPresetStoreHooks*() {.exportc.} =
  ## Register this module's apply hooks with preset_store, then refresh the
  ## saved-preset list from whatever localStorage already holds.
  preset_store.onSpeciesCountApply(proc(newCount: int) =
    setSpeciesCount(newCount, randomizeNew = false))

  preset_store.onParticleCountApply(proc(newCount: int) =
    updateSimulation(proc(simState: var SimulationState) = simState.particleCount = newCount)
    if not onInitParticles.isNil: onInitParticles()
  )

  preset_store.onScalarsApply(proc(settings: PresetSettings) =
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
    )
    updateRender(proc(renderState: var RenderState) =
      renderState.particleSize = settings.particleSize
      renderState.trailLength = settings.trailLength
      renderState.glowIntensity = settings.glowIntensity
      renderState.velocityGlowScale = settings.velocityGlowScale
      renderState.glowRadiusScale = settings.glowRadiusScale
      renderState.glowFalloff = settings.glowFalloff
      renderState.glowWarmth = settings.glowWarmth
    )
    setForceModel(settings.forceModel)
    setTrails(settings.trails)
  )

  preset_store.onMatrixDisplayRefresh(proc() = updateMatrixDisplay())

  preset_store.refreshPresetListDom()

# ==============================================================================
# SECTION 11: STATS DISPLAY
# ==============================================================================

proc updateStats*(fps: int, gridTimeMs: float, workerTimeMs: float) {.exportc.} =
  ## Update the stats display panel. Formatting lives in the natively-tested
  ## stats_view module; this proc only writes the DOM.
  ##
  ## @param fps - Current frames per second
  ## @param gridTimeMs - Time spent building spatial grid (ms)
  ## @param workerTimeMs - Time spent in worker physics (ms)

  getElementById("fps").textContent = cstring(formatFps(fps))
  getElementById("gridTime").textContent = cstring(formatGridTime(gridTimeMs))
  getElementById("workerTime").textContent = cstring(formatWorkerTime(workerTimeMs))

proc updateGpuTimes*(gridMs: float, physicsMs: float, drawMs: float, presentMs: float) {.exportc.} =
  ## Update the per-pass GPU timing readout (timestamp-query measurements).
  ##
  ## @param gridMs - Grid build compute pass (bin-count + prefix-sum)
  ## @param physicsMs - Physics compute pass (scatter + forces + integrate)
  ## @param drawMs - Offscreen render pass (trails + particles)
  ## @param presentMs - Present render pass (glow + blit)

  getElementById("gpuGrid").textContent = cstring(formatGpuTime(gridMs))
  getElementById("gpuPhysics").textContent = cstring(formatGpuTime(physicsMs))
  getElementById("gpuDraw").textContent = cstring(formatGpuTime(drawMs))
  getElementById("gpuPresent").textContent = cstring(formatGpuTime(presentMs))

proc updateParticleStats*(count: int) {.exportc.} =
  ## Update the particle count display.
  ##
  ## @param count - Current particle count

  getElementById("particleStats").textContent = cstring(formatParticleCount(count))

{.emit: """
window.toggleTrails = toggleTrails;
window.toggleControls = toggleControls;
window.randomizeMatrix = randomizeMatrix;
window.toggleForceModelSection = toggleForceModelSection;
window.toggleGlowSection = toggleGlowSection;
window.togglePaletteSection = togglePaletteSection;
window.togglePresetsSection = togglePresetsSection;
window.setForceModel = setForceModel;
window.setSimMode = setSimMode;
window.setPaletteScheme = setPaletteScheme;
window.presetSaveClicked = presetSaveClicked;
window.presetLoadClicked = presetLoadClicked;
window.presetExportClicked = presetExportClicked;
window.presetImportClicked = presetImportClicked;
""".}
