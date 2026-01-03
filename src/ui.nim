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
  Console, console, log, isUndefined, isJsFunction,
  jsRandom, jsAbs

from bindings/dom_extensions import
  HTMLElement, HTMLInputElement, HTMLCanvasElement,
  domDocument, domWindow,
  addEventListener, forEach, dataset, setClass

from bindings/typed_arrays import Float32Array, `[]`, `[]=`

import config
import buffers

# New reactive state system
import ui/core/observable
import ui/state/input_state
import ui/state/matrix_state
import ui/input/mouse_handler
import ui/input/touch_handler
import ui/controls/slider

# ==============================================================================
# SECTION 2: ADDITIONAL JS FFI BINDINGS
# ==============================================================================
# These supplement the bindings from dom.nim and js_interop.nim

proc parseIntJS(s: cstring, radix: int): int {.importjs: "parseInt(#, #)".}
proc parseFloatJS(s: cstring): float {.importjs: "parseFloat(#)".}
proc isNaN(x: float): bool {.importjs: "isNaN(#)".}
proc toFixed(x: float, digits: int): cstring {.importjs: "#.toFixed(#)".}
proc toLocaleString(x: int): cstring {.importjs: "#.toLocaleString()".}

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
proc updateMatrixRule*(i: int, j: int, el: JsObject) {.exportc.}

# ==============================================================================
# SECTION 7: UI SETUP
# ==============================================================================

proc setupUI*() {.exportc.} =
  ## Bind slider inputs to CONFIG values using Slider components.
  ## Each slider syncs to CONFIG via subscription and triggers callbacks on change.

  # ===========================================================================
  # Simulation sliders
  # ===========================================================================

  # Particle count slider
  let particleCountSlider = newIntSlider(
    "particleCount", "particleValue",
    CONFIG.particleCount,
    minValue = 100, maxValue = MAX_PARTICLES
  )
  discard particleCountSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.particleCount = v.toInt()
    nil
  )
  particleCountSlider.onChange = proc() =
    console.log("[ui] particleCount change, onInitParticles isNil:".toJs, onInitParticles.isNil.toJs)
    if not onInitParticles.isNil:
      onInitParticles()
  particleCountSlider.bindToDOM()

  # Species count slider
  let speciesCountSlider = newIntSlider(
    "speciesCount", "speciesValue",
    CONFIG.speciesCount,
    minValue = 1, maxValue = MAX_SPECIES
  )
  discard speciesCountSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.speciesCount = v.toInt()
    nil
  )
  speciesCountSlider.onChange = proc() =
    randomizeMatrix()
    if not onInitParticles.isNil:
      onInitParticles()
  speciesCountSlider.bindToDOM()

  # Interaction radius slider
  let radiusSlider = newIntSlider(
    "interactionRadius", "radiusValue",
    CONFIG.interactionRadius,
    minValue = 10, maxValue = 200
  )
  discard radiusSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.interactionRadius = v.toInt()
    nil
  )
  radiusSlider.bindToDOM()

  # Force strength slider
  let forceSlider = newFloatSlider(
    "forceStrength", "forceValue",
    CONFIG.forceStrength,
    precision = 1, minValue = 0.1, maxValue = 10.0
  )
  discard forceSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.forceStrength = v.toFloat()
    nil
  )
  forceSlider.bindToDOM()

  # Friction slider
  let frictionSlider = newFloatSlider(
    "friction", "frictionValue",
    CONFIG.friction,
    precision = 2, minValue = 0.0, maxValue = 1.0
  )
  discard frictionSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.friction = v.toFloat()
    nil
  )
  frictionSlider.bindToDOM()

  # Time scale slider
  let timeScaleSlider = newFloatSlider(
    "timeScale", "timeScaleValue",
    CONFIG.timeScale,
    precision = 1, minValue = 0.1, maxValue = 5.0
  )
  discard timeScaleSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.timeScale = v.toFloat()
    nil
  )
  timeScaleSlider.bindToDOM()

  # Max velocity slider
  let velocitySlider = newFloatSlider(
    "maxVelocity", "velocityValue",
    CONFIG.maxVelocity,
    precision = 0, minValue = 10.0, maxValue = 500.0
  )
  discard velocitySlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.maxVelocity = v.toFloat()
    nil
  )
  velocitySlider.bindToDOM()

  # ===========================================================================
  # Render sliders
  # ===========================================================================

  # Trail length slider
  let trailSlider = newFloatSlider(
    "trailLength", "trailValue",
    CONFIG.trailAlpha,
    precision = 2, minValue = 0.0, maxValue = 1.0
  )
  discard trailSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.trailAlpha = v.toFloat()
    nil
  )
  trailSlider.bindToDOM()

  # Glow intensity slider
  let glowSlider = newFloatSlider(
    "glowIntensity", "glowValue",
    CONFIG.glowIntensity,
    precision = 1, minValue = 0.0, maxValue = 3.0
  )
  discard glowSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.glowIntensity = v.toFloat()
    nil
  )
  glowSlider.bindToDOM()

  # Velocity glow scale slider
  let velGlowSlider = newFloatSlider(
    "velocityGlowScale", "velocityGlowValue",
    CONFIG.velocityGlowScale,
    precision = 1, minValue = 0.0, maxValue = 5.0
  )
  discard velGlowSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.velocityGlowScale = v.toFloat()
    nil
  )
  velGlowSlider.bindToDOM()

  # ===========================================================================
  # Force Model sliders
  # ===========================================================================

  # Polynomial: Repulsion End
  let repulsionEndSlider = newFloatSlider(
    "repulsionEnd", "repulsionEndValue",
    CONFIG.repulsionEnd,
    precision = 2, minValue = 0.1, maxValue = 0.9
  )
  discard repulsionEndSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.repulsionEnd = v.toFloat()
    nil
  )
  repulsionEndSlider.bindToDOM()

  # Polynomial: Attraction Peak
  let attractionPeakSlider = newFloatSlider(
    "attractionPeak", "attractionPeakValue",
    CONFIG.attractionPeak,
    precision = 2, minValue = 0.5, maxValue = 0.95
  )
  discard attractionPeakSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.attractionPeak = v.toFloat()
    nil
  )
  attractionPeakSlider.bindToDOM()

  # Exponential: Repulsion Alpha
  let expRepulsionAlphaSlider = newFloatSlider(
    "expRepulsionAlpha", "expRepulsionAlphaValue",
    CONFIG.expRepulsionAlpha,
    precision = 1, minValue = 1.0, maxValue = 15.0
  )
  discard expRepulsionAlphaSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.expRepulsionAlpha = v.toFloat()
    nil
  )
  expRepulsionAlphaSlider.bindToDOM()

  # Exponential: Attraction Beta
  let expAttractionBetaSlider = newFloatSlider(
    "expAttractionBeta", "expAttractionBetaValue",
    CONFIG.expAttractionBeta,
    precision = 1, minValue = 1.0, maxValue = 10.0
  )
  discard expAttractionBetaSlider.value.subscribe(proc(v: SliderValue): proc() =
    CONFIG.expAttractionBeta = v.toFloat()
    nil
  )
  expAttractionBetaSlider.bindToDOM()

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
  canvasEl.addEventListener("mousedown", proc(e: MouseEvent) =
    let eventData = extractMouseData(e)
    currentInput.set(handleMouseDown(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseup", proc(e: MouseEvent) =
    let eventData = extractMouseData(e)
    currentInput.set(handleMouseUp(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mouseleave", proc(e: MouseEvent) =
    currentInput.set(handleMouseLeave(currentInput.get()))
  )

  # Prevent context menu on right-click
  canvasEl.addEventListener("contextmenu", proc(e: Event) =
    preventDefault(e)
  )

  # Double-click triggers blast effect (powerful repellent)
  canvasEl.addEventListener("dblclick", proc(e: MouseEvent) =
    let eventData = extractMouseData(e)
    currentInput.set(handleDoubleClick(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("mousemove", proc(e: MouseEvent) =
    let eventData = extractMouseData(e)
    currentInput.set(handleMouseMove(currentInput.get(), eventData))
  )

  # Touch events - use pure handlers
  canvasEl.addEventListener("touchstart", proc(e: TouchEvent) =
    preventDefault(e)
    let eventData = extractTouchData(e)
    currentInput.set(handleTouchStart(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("touchend", proc(e: TouchEvent) =
    # TouchEvent.touches contains remaining touches after this one ends
    let eventData = extractTouchData(e)
    currentInput.set(handleTouchEnd(currentInput.get(), eventData))
  )

  canvasEl.addEventListener("touchmove", proc(e: TouchEvent) =
    preventDefault(e)
    let eventData = extractTouchData(e)
    currentInput.set(handleTouchMove(currentInput.get(), eventData))
  )

# ==============================================================================
# SECTION 9: UI TOGGLE FUNCTIONS
# ==============================================================================

proc toggleTrails*() {.exportc.} =
  ## Toggle trail rendering mode.
  ## Updates button state and shows/hides trail length slider.

  CONFIG.trails = not CONFIG.trails
  let trailBtn = getElementById("trailBtn")
  discard trailBtn.classList.setClass("active", CONFIG.trails)
  let trailSettings = cast[HTMLElement](getElementById("trailSettings"))
  if CONFIG.trails:
    trailSettings.style.display = "block"
  else:
    trailSettings.style.display = "none"

proc toggleControls*() {.exportc.} =
  ## Toggle controls panel visibility.
  ## Updates collapse button text.

  let controls = cast[HTMLElement](getElementById("controls"))
  controls.classList.toggle("collapsed")
  let btn = controls.querySelector(".collapse-btn")
  if controls.classList.contains("collapsed"):
    btn.textContent = "+"
  else:
    btn.textContent = "-"

proc toggleForceModelSection*() {.exportc.} =
  ## Toggle Force Model section visibility.

  let section = cast[HTMLElement](getElementById("forceModelSection"))
  let content = cast[HTMLElement](section.querySelector(".section-content"))
  let toggle = section.querySelector(".section-toggle")
  if content.style.display == "none":
    content.style.display = "block"
    toggle.textContent = "−"
  else:
    content.style.display = "none"
    toggle.textContent = "+"

proc setForceModel*(model: int) {.exportc.} =
  ## Set the force model and update UI visibility.
  ## @param model - 0 for polynomial, 1 for exponential

  CONFIG.forceModel = model

  let polyBtn = cast[HTMLElement](getElementById("polyModelBtn"))
  let expBtn = cast[HTMLElement](getElementById("expModelBtn"))
  let polyParams = cast[HTMLElement](getElementById("polynomialParams"))
  let expParams = cast[HTMLElement](getElementById("exponentialParams"))

  if model == 0:
    discard polyBtn.classList.setClass("active", true)
    discard expBtn.classList.setClass("active", false)
    polyParams.style.display = "block"
    expParams.style.display = "none"
  else:
    discard polyBtn.classList.setClass("active", false)
    discard expBtn.classList.setClass("active", true)
    polyParams.style.display = "none"
    expParams.style.display = "block"

# ==============================================================================
# SECTION 10: MATRIX UI
# ==============================================================================

proc setMatrixUpdateCallback*(callback: proc()) {.exportc.} =
  ## Set callback for matrix updates.
  ## Called after randomizeMatrix() or updateMatrixRule().
  ##
  ## @param callback - Called when matrix values change
  onMatrixUpdate = callback

proc updateMatrixRule*(i: int, j: int, el: JsObject) {.exportc.} =
  ## Update a single matrix rule value.
  ##
  ## @param i - Row index (species that feels the force)
  ## @param j - Column index (species that exerts the force)
  ## @param el - The input element containing the new value

  let inputEl = cast[HTMLInputElement](el)
  let v = parseFloatJS(inputEl.value)
  if not isNaN(v):
    let clamped = clampMatrixValue(v)
    matrix[matrixIndex(i, j)] = clamped
    if not onMatrixUpdate.isNil:
      onMatrixUpdate()
    # Update background color using extracted function
    let color = cellColorFromValue(clamped)
    let parent = cast[HTMLElement](inputEl.parentElement)
    parent.style.background = cstring(toHslaString(color))

proc updateMatrixDisplay*() {.exportc.} =
  ## Update the matrix display grid to reflect current values.
  ## Creates editable input cells with color-coded backgrounds.
  ## Uses pure functions from matrix_state for color calculations.

  let el = cast[HTMLElement](getElementById("matrixDisplay"))
  let ns = CONFIG.speciesCount
  el.style.gridTemplateColumns = cstring("repeat(" & $(ns + 1) & ", 1fr)")

  var html = "<div class=\"matrix-cell matrix-header\"></div>"

  # Column headers (species colors)
  for j in 0 ..< ns:
    let c = j * 3
    let speciesColor = SpeciesColor(
      r: int(COLORS[c] * 255.0),
      g: int(COLORS[c + 1] * 255.0),
      b: int(COLORS[c + 2] * 255.0),
      alpha: 0.5
    )
    html &= "<div class=\"matrix-cell matrix-header\" style=\"background:" &
            toRgbaString(speciesColor) & "\"></div>"

  # Matrix rows
  for i in 0 ..< ns:
    # Row header (species color)
    let c = i * 3
    let speciesColor = SpeciesColor(
      r: int(COLORS[c] * 255.0),
      g: int(COLORS[c + 1] * 255.0),
      b: int(COLORS[c + 2] * 255.0),
      alpha: 0.5
    )
    html &= "<div class=\"matrix-cell matrix-header\" style=\"background:" &
            toRgbaString(speciesColor) & "\"></div>"

    # Matrix cells
    for j in 0 ..< ns:
      let v = matrix[matrixIndex(i, j)]
      let color = cellColorFromValue(v)
      html &= "<div class=\"matrix-cell\" style=\"background:" & toHslaString(color) & "\">" &
              "<input type=\"number\" step=\"0.1\" value=\"" & $toFixed(v, 2) & "\" " &
              "data-row=\"" & $i & "\" data-col=\"" & $j & "\">" &
              "</div>"

  el.innerHTML = cstring(html)

  # Attach event listeners to inputs
  let inputs = el.querySelectorAll("input[type=\"number\"]")
  inputs.forEach(proc(input: Element) =
    let inputEl = cast[HTMLInputElement](input)
    inputEl.addEventListener("change", proc(e: Event) =
      let target = cast[HTMLElement](e.target)
      let ds = target.dataset()
      let row = parseIntJS(cast[cstring](ds["row"]), 10)
      let col = parseIntJS(cast[cstring](ds["col"]), 10)
      updateMatrixRule(row, col, cast[JsObject](e.target))
    )
  )

proc randomizeMatrix*() {.exportc.} =
  ## Randomize all values in the attraction matrix.
  ## Values range from -1 (repulsion) to +1 (attraction).

  let ns = CONFIG.speciesCount
  for i in 0 ..< ns:
    for j in 0 ..< ns:
      matrix[matrixIndex(i, j)] = jsRandom() * 2.0 - 1.0

  updateMatrixDisplay()
  if not onMatrixUpdate.isNil:
    onMatrixUpdate()
  console.log("Matrix randomized - sample values:".toJs, matrix[0].toJs, matrix[1].toJs, matrix[6].toJs, matrix[7].toJs)

# ==============================================================================
# SECTION 11: STATS DISPLAY
# ==============================================================================

proc updateStats*(fps: int, gridTimeMs: float, workerTimeMs: float) {.exportc.} =
  ## Update the stats display panel.
  ##
  ## @param fps - Current frames per second
  ## @param gridTimeMs - Time spent building spatial grid (ms)
  ## @param workerTimeMs - Time spent in worker physics (ms)

  let fpsEl = getElementById("fps")
  fpsEl.textContent = cstring($fps)
  let gridTimeEl = getElementById("gridTime")
  gridTimeEl.textContent = toFixed(gridTimeMs, 2)
  let workerTimeEl = getElementById("workerTime")
  workerTimeEl.textContent = toFixed(workerTimeMs, 1)

proc updateParticleStats*(count: int) {.exportc.} =
  ## Update the particle count display.
  ##
  ## @param count - Current particle count

  let particleStatsEl = getElementById("particleStats")
  particleStatsEl.textContent = toLocaleString(count)

{.emit: """
window.toggleTrails = toggleTrails;
window.toggleControls = toggleControls;
window.randomizeMatrix = randomizeMatrix;
window.toggleForceModelSection = toggleForceModelSection;
window.setForceModel = setForceModel;
""".}
