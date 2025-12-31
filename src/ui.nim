# ==============================================================================
# EMERGENT GARDEN - UI MODULE
# ==============================================================================
#
# UI and DOM interaction module for Goober Garden.
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
# SECTION 3: MOUSE STATE (exported for physics calculations)
# ==============================================================================

var mouseX* {.exportc.}: float = 0
var mouseY* {.exportc.}: float = 0
var mouseDown* {.exportc.}: bool = false
var mouseRightDown* {.exportc.}: bool = false

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
  ## Bind slider inputs to CONFIG values.
  ## Updates display values in real-time, triggers callbacks on change.
  ## Syncs slider values to CONFIG defaults on initialization.

  # Particle count slider
  let particleCountEl = cast[HTMLInputElement](getElementById("particleCount"))
  let particleValueEl = getElementById("particleValue")
  # Sync slider to CONFIG value on init
  particleCountEl.value = cstring($CONFIG.particleCount)
  particleValueEl.textContent = cstring($CONFIG.particleCount)
  particleCountEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.particleCount = parseIntJS(target.value, 10)
    particleValueEl.textContent = cstring($CONFIG.particleCount)
  )
  particleCountEl.addEventListener("change", proc(e: Event) =
    console.log("[ui] particleCount change, onInitParticles isNil:".toJs, onInitParticles.isNil.toJs)
    if not onInitParticles.isNil:
      onInitParticles()
  )

  # Species count slider
  let speciesCountEl = cast[HTMLInputElement](getElementById("speciesCount"))
  let speciesValueEl = getElementById("speciesValue")
  # Sync slider to CONFIG value on init
  speciesCountEl.value = cstring($CONFIG.speciesCount)
  speciesValueEl.textContent = cstring($CONFIG.speciesCount)
  speciesCountEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.speciesCount = parseIntJS(target.value, 10)
    speciesValueEl.textContent = cstring($CONFIG.speciesCount)
  )
  speciesCountEl.addEventListener("change", proc(e: Event) =
    randomizeMatrix()
    if not onInitParticles.isNil:
      onInitParticles()
  )

  # Interaction radius slider
  let radiusEl = cast[HTMLInputElement](getElementById("interactionRadius"))
  let radiusValueEl = getElementById("radiusValue")
  # Sync slider to CONFIG value on init
  radiusEl.value = cstring($CONFIG.interactionRadius)
  radiusValueEl.textContent = cstring($CONFIG.interactionRadius)
  radiusEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.interactionRadius = parseIntJS(target.value, 10)
    radiusValueEl.textContent = cstring($CONFIG.interactionRadius)
  )

  # Force strength slider
  let forceEl = cast[HTMLInputElement](getElementById("forceStrength"))
  let forceValueEl = getElementById("forceValue")
  # Sync slider to CONFIG value on init
  forceEl.value = cstring($CONFIG.forceStrength)
  forceValueEl.textContent = toFixed(CONFIG.forceStrength, 1)
  forceEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.forceStrength = parseFloatJS(target.value)
    forceValueEl.textContent = toFixed(CONFIG.forceStrength, 1)
  )

  # Friction slider
  let frictionEl = cast[HTMLInputElement](getElementById("friction"))
  let frictionValueEl = getElementById("frictionValue")
  # Sync slider to CONFIG value on init
  frictionEl.value = cstring($CONFIG.friction)
  frictionValueEl.textContent = toFixed(CONFIG.friction, 2)
  frictionEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.friction = parseFloatJS(target.value)
    frictionValueEl.textContent = toFixed(CONFIG.friction, 2)
  )

  # Time scale slider
  let timeScaleEl = cast[HTMLInputElement](getElementById("timeScale"))
  let timeScaleValueEl = getElementById("timeScaleValue")
  # Sync slider to CONFIG value on init
  timeScaleEl.value = cstring($CONFIG.timeScale)
  timeScaleValueEl.textContent = toFixed(CONFIG.timeScale, 1)
  timeScaleEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.timeScale = parseFloatJS(target.value)
    timeScaleValueEl.textContent = toFixed(CONFIG.timeScale, 1)
  )

  # Trail length slider
  let trailEl = cast[HTMLInputElement](getElementById("trailLength"))
  let trailValueEl = getElementById("trailValue")
  # Sync slider to CONFIG value on init
  trailEl.value = cstring($CONFIG.trailAlpha)
  trailValueEl.textContent = toFixed(CONFIG.trailAlpha, 2)
  trailEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.trailAlpha = parseFloatJS(target.value)
    trailValueEl.textContent = toFixed(CONFIG.trailAlpha, 2)
  )

  # Glow intensity slider
  let glowEl = cast[HTMLInputElement](getElementById("glowIntensity"))
  let glowValueEl = getElementById("glowValue")
  # Sync slider to CONFIG value on init
  glowEl.value = cstring($CONFIG.glowIntensity)
  glowValueEl.textContent = toFixed(CONFIG.glowIntensity, 1)
  glowEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.glowIntensity = parseFloatJS(target.value)
    glowValueEl.textContent = toFixed(CONFIG.glowIntensity, 1)
  )

  # Max velocity slider
  let velocityEl = cast[HTMLInputElement](getElementById("maxVelocity"))
  let velocityValueEl = getElementById("velocityValue")
  # Sync slider to CONFIG value on init
  velocityEl.value = cstring($CONFIG.maxVelocity)
  velocityValueEl.textContent = toFixed(CONFIG.maxVelocity, 0)
  velocityEl.addEventListener("input", proc(e: Event) =
    let target = cast[HTMLInputElement](e.target)
    CONFIG.maxVelocity = parseFloatJS(target.value)
    velocityValueEl.textContent = toFixed(CONFIG.maxVelocity, 0)
  )

# ==============================================================================
# SECTION 8: EVENT SETUP
# ==============================================================================

proc setupEvents*(canvas: JsObject) {.exportc.} =
  ## Set up mouse, touch, and resize event handlers.
  ##
  ## @param canvas - The canvas element for mouse/touch events

  let canvasEl = cast[HTMLCanvasElement](canvas)

  # Window resize
  domWindow.addEventListener("resize", proc() =
    if not onResize.isNil:
      onResize()
  )

  # Mouse events
  canvasEl.addEventListener("mousedown", proc(e: MouseEvent) =
    if e.button == 0:  # Left button
      mouseDown = true
    elif e.button == 2:  # Right button
      mouseRightDown = true
    mouseX = e.clientX.float
    mouseY = e.clientY.float
  )

  canvasEl.addEventListener("mouseup", proc(e: MouseEvent) =
    if e.button == 0:  # Left button
      mouseDown = false
    elif e.button == 2:  # Right button
      mouseRightDown = false
  )

  canvasEl.addEventListener("mouseleave", proc(e: MouseEvent) =
    mouseDown = false
    mouseRightDown = false
  )

  # Prevent context menu on right-click
  canvasEl.addEventListener("contextmenu", proc(e: Event) =
    preventDefault(e)
  )

  canvasEl.addEventListener("mousemove", proc(e: MouseEvent) =
    mouseX = e.clientX.float
    mouseY = e.clientY.float
  )

  # Touch events
  canvasEl.addEventListener("touchstart", proc(e: TouchEvent) =
    preventDefault(e)
    mouseDown = true
    let touch = e.touches[0]
    mouseX = touch.clientX.float
    mouseY = touch.clientY.float
  )

  canvasEl.addEventListener("touchend", proc(e: TouchEvent) =
    mouseDown = false
  )

  canvasEl.addEventListener("touchmove", proc(e: TouchEvent) =
    preventDefault(e)
    let touch = e.touches[0]
    mouseX = touch.clientX.float
    mouseY = touch.clientY.float
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
    matrix[i * MAX_SPECIES + j] = v
    if not onMatrixUpdate.isNil:
      onMatrixUpdate()
    # Calculate background color based on value
    let hue = if v > 0: 120 else: 0
    let saturation = int(jsAbs(v) * 100.0)
    let bg = "hsla(" & $hue & "," & $saturation & "%,40%,0.7)"
    let parent = cast[HTMLElement](inputEl.parentElement)
    parent.style.background = cstring(bg)

proc updateMatrixDisplay*() {.exportc.} =
  ## Update the matrix display grid to reflect current values.
  ## Creates editable input cells with color-coded backgrounds.

  let el = cast[HTMLElement](getElementById("matrixDisplay"))
  let ns = CONFIG.speciesCount
  el.style.gridTemplateColumns = cstring("repeat(" & $(ns + 1) & ", 1fr)")

  var html = "<div class=\"matrix-cell matrix-header\"></div>"

  # Column headers (species colors)
  for j in 0 ..< ns:
    let c = j * 3
    let r = int(COLORS[c] * 255.0)
    let g = int(COLORS[c + 1] * 255.0)
    let b = int(COLORS[c + 2] * 255.0)
    html &= "<div class=\"matrix-cell matrix-header\" style=\"background:rgba(" &
            $r & "," & $g & "," & $b & ",0.5)\"></div>"

  # Matrix rows
  for i in 0 ..< ns:
    # Row header (species color)
    let c = i * 3
    let r = int(COLORS[c] * 255.0)
    let g = int(COLORS[c + 1] * 255.0)
    let b = int(COLORS[c + 2] * 255.0)
    html &= "<div class=\"matrix-cell matrix-header\" style=\"background:rgba(" &
            $r & "," & $g & "," & $b & ",0.5)\"></div>"

    # Matrix cells
    for j in 0 ..< ns:
      let v = matrix[i * MAX_SPECIES + j]
      let hue = if v > 0: 120 else: 0
      let saturation = int(jsAbs(v) * 100.0)
      let bg = "hsla(" & $hue & "," & $saturation & "%,40%,0.7)"
      html &= "<div class=\"matrix-cell\" style=\"background:" & bg & "\">" &
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
      matrix[i * MAX_SPECIES + j] = jsRandom() * 2.0 - 1.0

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
""".}
