# ==============================================================================
# SLIDER - Reusable slider component
# ==============================================================================
#
# Pure slider configuration and value handling.
# DOM binding is JS-only; core logic is testable natively.
#
# ==============================================================================

from std/strutils import parseInt, parseFloat, formatFloat, ffDecimal

import ../core/observable

# ==============================================================================
# SECTION 1: VALUE TYPES
# ==============================================================================

type
  SliderValueKind* = enum
    svkInt    ## Integer values (particleCount, speciesCount, radius)
    svkFloat  ## Floating point values (force, friction, etc.)

  SliderValue* = object
    ## Unified slider value - either int or float
    case kind*: SliderValueKind
    of svkInt:
      intVal*: int
    of svkFloat:
      floatVal*: float

func intValue*(v: int): SliderValue =
  SliderValue(kind: svkInt, intVal: v)

func floatValue*(v: float): SliderValue =
  SliderValue(kind: svkFloat, floatVal: v)

func toFloat*(v: SliderValue): float =
  case v.kind
  of svkInt: float(v.intVal)
  of svkFloat: v.floatVal

func toInt*(v: SliderValue): int =
  case v.kind
  of svkInt: v.intVal
  of svkFloat: int(v.floatVal)

# ==============================================================================
# SECTION 2: SLIDER CONFIGURATION
# ==============================================================================

type
  SliderConfig* = object
    ## Configuration for a slider control.
    ## Pure data - no DOM references.
    inputId*: string       ## DOM id of the input element
    displayId*: string     ## DOM id of the display element
    valueKind*: SliderValueKind
    precision*: int        ## Decimal places for float display (ignored for int)
    minValue*: float       ## Minimum allowed value
    maxValue*: float       ## Maximum allowed value

func initSliderConfig*(
  inputId, displayId: string;
  valueKind: SliderValueKind;
  precision: int = 0;
  minValue: float = 0.0;
  maxValue: float = 100.0
): SliderConfig =
  SliderConfig(
    inputId: inputId,
    displayId: displayId,
    valueKind: valueKind,
    precision: precision,
    minValue: minValue,
    maxValue: maxValue
  )

# ==============================================================================
# SECTION 3: VALUE PARSING (pure functions)
# ==============================================================================

func parseSliderValue*(s: string, kind: SliderValueKind): SliderValue =
  ## Parse a string to a slider value. Returns 0 on parse error.
  case kind
  of svkInt:
    try:
      result = intValue(parseInt(s))
    except ValueError:
      result = intValue(0)
  of svkFloat:
    try:
      result = floatValue(parseFloat(s))
    except ValueError:
      result = floatValue(0.0)

func clampValue*(v: SliderValue, config: SliderConfig): SliderValue =
  ## Clamp value to config min/max range.
  let f = v.toFloat()
  let clamped = max(config.minValue, min(config.maxValue, f))
  case config.valueKind
  of svkInt: intValue(int(clamped))
  of svkFloat: floatValue(clamped)

# ==============================================================================
# SECTION 4: VALUE FORMATTING (pure functions)
# ==============================================================================

func formatValue*(v: SliderValue, precision: int): string =
  ## Format a value for display.
  case v.kind
  of svkInt:
    $v.intVal
  of svkFloat:
    if precision == 0:
      $int(v.floatVal)
    else:
      formatFloat(v.floatVal, ffDecimal, precision)

func formatSliderValue*(v: SliderValue, config: SliderConfig): string =
  ## Format value according to config.
  formatValue(v, config.precision)

# ==============================================================================
# SECTION 5: SLIDER STATE
# ==============================================================================

type
  Slider* = ref object
    ## A slider bound to an observable value.
    config*: SliderConfig
    value*: Observable[SliderValue]
    onChange*: proc()  ## Called after value changes (for side effects)

proc newSlider*(config: SliderConfig, initial: SliderValue): Slider =
  ## Create a new slider with initial value.
  Slider(
    config: config,
    value: newObservable(initial),
    onChange: nil
  )

proc newIntSlider*(
  inputId, displayId: string;
  initial: int;
  minValue: int = 0;
  maxValue: int = 100
): Slider =
  ## Convenience constructor for integer sliders.
  let config = initSliderConfig(
    inputId, displayId,
    svkInt,
    precision = 0,
    minValue = float(minValue),
    maxValue = float(maxValue)
  )
  newSlider(config, intValue(initial))

proc newFloatSlider*(
  inputId, displayId: string;
  initial: float;
  precision: int = 1;
  minValue: float = 0.0;
  maxValue: float = 10.0
): Slider =
  ## Convenience constructor for float sliders.
  let config = initSliderConfig(
    inputId, displayId,
    svkFloat,
    precision = precision,
    minValue = minValue,
    maxValue = maxValue
  )
  newSlider(config, floatValue(initial))

proc getValue*(s: Slider): SliderValue =
  s.value.get()

proc getInt*(s: Slider): int =
  s.value.get().toInt()

proc getFloat*(s: Slider): float =
  s.value.get().toFloat()

proc setValue*(s: Slider, v: SliderValue) =
  let clamped = clampValue(v, s.config)
  s.value.set(clamped)
  if not s.onChange.isNil:
    s.onChange()

proc setInt*(s: Slider, v: int) =
  s.setValue(intValue(v))

proc setFloat*(s: Slider, v: float) =
  s.setValue(floatValue(v))

proc getDisplayText*(s: Slider): string =
  formatSliderValue(s.value.get(), s.config)

# ==============================================================================
# SECTION 6: DOM BINDING (JS-only)
# ==============================================================================

when defined(js):
  from std/math import pow

  from std/dom import
    Element, Event, getElementById, addEventListener

  from ../../bindings/dom_extensions import
    HTMLInputElement

  proc parseIntJS(s: cstring, radix: int): int {.importjs: "parseInt(#, #)".}
  proc parseFloatJS(s: cstring): float {.importjs: "parseFloat(#)".}
  proc toFixed(x: float, digits: int): cstring {.importjs: "#.toFixed(#)".}

  proc bindToDOM*(s: Slider) =
    ## Bind slider to DOM elements.
    ## Sets up bidirectional sync: DOM → observable and observable → DOM.
    let inputEl = cast[HTMLInputElement](getElementById(cstring(s.config.inputId)))
    let displayEl = getElementById(cstring(s.config.displayId))

    if inputEl.isNil or displayEl.isNil:
      return

    # Set initial DOM state
    case s.config.valueKind
    of svkInt:
      inputEl.value = cstring($s.getInt())
      displayEl.textContent = cstring($s.getInt())
    of svkFloat:
      inputEl.value = cstring($s.getFloat())
      displayEl.textContent = toFixed(s.getFloat(), s.config.precision)

    # Set min/max/step attributes based on slider type
    case s.config.valueKind
    of svkInt:
      inputEl.min = cstring($int(s.config.minValue))
      inputEl.max = cstring($int(s.config.maxValue))
      inputEl.step = cstring("1")
    of svkFloat:
      inputEl.min = cstring($s.config.minValue)
      inputEl.max = cstring($s.config.maxValue)
      # Step based on precision: precision=1 → step=0.1, precision=2 → step=0.01
      let stepVal = if s.config.precision <= 0: 1.0 else: pow(10.0, -float(s.config.precision))
      inputEl.step = cstring($stepVal)

    # DOM → Observable: update on input
    inputEl.addEventListener("input", proc(e: Event) =
      let target = cast[HTMLInputElement](e.target)
      case s.config.valueKind
      of svkInt:
        let v = parseIntJS(target.value, 10)
        s.value.set(intValue(v))  # Don't trigger onChange yet
      of svkFloat:
        let v = parseFloatJS(target.value)
        s.value.set(floatValue(v))

      # Update display
      case s.config.valueKind
      of svkInt:
        displayEl.textContent = cstring($s.getInt())
      of svkFloat:
        displayEl.textContent = toFixed(s.getFloat(), s.config.precision)
    )

    # Trigger onChange on "change" event (after user releases slider)
    inputEl.addEventListener("change", proc(e: Event) =
      if not s.onChange.isNil:
        s.onChange()
    )

    # Observable → DOM: subscribe for external updates
    discard s.value.subscribe(proc(v: SliderValue): proc() =
      case v.kind
      of svkInt:
        inputEl.value = cstring($v.intVal)
        displayEl.textContent = cstring($v.intVal)
      of svkFloat:
        inputEl.value = cstring($v.floatVal)
        displayEl.textContent = toFixed(v.floatVal, s.config.precision)
      nil
    )

  proc configSlider*(
    inputId, displayId: string;
    get: proc(): float;
    set: proc(v: float);
    min, max: float;
    precision: int = 0;
    onChange: proc() = nil
  ) =
    ## Bind a slider directly to a value with minimal boilerplate.
    ## Uses float internally; caller handles int conversion in get/set.
    let slider = newFloatSlider(
      inputId, displayId,
      get(),
      precision = precision,
      minValue = min,
      maxValue = max
    )

    discard slider.value.subscribe(proc(v: SliderValue): proc() =
      set(v.toFloat())
      nil
    )

    if not onChange.isNil:
      slider.onChange = onChange

    slider.bindToDOM()
