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

func intValue*(value: int): SliderValue =
  SliderValue(kind: svkInt, intVal: value)

func floatValue*(value: float): SliderValue =
  SliderValue(kind: svkFloat, floatVal: value)

func toFloat*(value: SliderValue): float =
  case value.kind
  of svkInt: float(value.intVal)
  of svkFloat: value.floatVal

func toInt*(value: SliderValue): int =
  case value.kind
  of svkInt: value.intVal
  of svkFloat: int(value.floatVal)

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

func parseSliderValue*(text: string, kind: SliderValueKind): SliderValue =
  ## Parse a string to a slider value. Returns 0 on parse error.
  case kind
  of svkInt:
    try:
      result = intValue(parseInt(text))
    except ValueError:
      result = intValue(0)
  of svkFloat:
    try:
      result = floatValue(parseFloat(text))
    except ValueError:
      result = floatValue(0.0)

func clampValue*(value: SliderValue, config: SliderConfig): SliderValue =
  ## Clamp value to config min/max range.
  let rawFloat = value.toFloat()
  let clamped = max(config.minValue, min(config.maxValue, rawFloat))
  case config.valueKind
  of svkInt: intValue(int(clamped))
  of svkFloat: floatValue(clamped)

# ==============================================================================
# SECTION 4: VALUE FORMATTING (pure functions)
# ==============================================================================

func formatValue*(value: SliderValue, precision: int): string =
  ## Format a value for display.
  case value.kind
  of svkInt:
    $value.intVal
  of svkFloat:
    if precision == 0:
      $int(value.floatVal)
    else:
      formatFloat(value.floatVal, ffDecimal, precision)

func formatSliderValue*(value: SliderValue, config: SliderConfig): string =
  ## Format value according to config.
  formatValue(value, config.precision)

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

proc getValue*(slider: Slider): SliderValue =
  slider.value.get()

proc getInt*(slider: Slider): int =
  slider.value.get().toInt()

proc getFloat*(slider: Slider): float =
  slider.value.get().toFloat()

proc setValue*(slider: Slider, value: SliderValue) =
  let clamped = clampValue(value, slider.config)
  slider.value.set(clamped)
  if not slider.onChange.isNil:
    slider.onChange()

proc setInt*(slider: Slider, value: int) =
  slider.setValue(intValue(value))

proc setFloat*(slider: Slider, value: float) =
  slider.setValue(floatValue(value))

proc getDisplayText*(slider: Slider): string =
  formatSliderValue(slider.value.get(), slider.config)

# ==============================================================================
# SECTION 6: DOM BINDING (JS-only)
# ==============================================================================

when defined(js):
  from std/math import pow

  from std/dom import
    Element, Event, getElementById, addEventListener

  from ../../bindings/dom_extensions import
    HTMLInputElement

  proc parseIntJS(text: cstring, radix: int): int {.importjs: "parseInt(#, #)".}
  proc parseFloatJS(text: cstring): float {.importjs: "parseFloat(#)".}
  proc toFixed(num: float, digits: int): cstring {.importjs: "#.toFixed(#)".}

  proc bindToDOM*(slider: Slider) =
    ## Bind slider to DOM elements.
    ## Sets up bidirectional sync: DOM → observable and observable → DOM.
    let inputEl = cast[HTMLInputElement](getElementById(cstring(slider.config.inputId)))
    let displayEl = getElementById(cstring(slider.config.displayId))

    if inputEl.isNil or displayEl.isNil:
      return

    # Set initial DOM state
    case slider.config.valueKind
    of svkInt:
      inputEl.value = cstring($slider.getInt())
      displayEl.textContent = cstring($slider.getInt())
    of svkFloat:
      inputEl.value = cstring($slider.getFloat())
      displayEl.textContent = toFixed(slider.getFloat(), slider.config.precision)

    # Set min/max/step attributes based on slider type
    case slider.config.valueKind
    of svkInt:
      inputEl.min = cstring($int(slider.config.minValue))
      inputEl.max = cstring($int(slider.config.maxValue))
      inputEl.step = cstring("1")
    of svkFloat:
      inputEl.min = cstring($slider.config.minValue)
      inputEl.max = cstring($slider.config.maxValue)
      # Step based on precision: precision=1 → step=0.1, precision=2 → step=0.01
      let stepVal = if slider.config.precision <= 0: 1.0 else: pow(10.0, -float(slider.config.precision))
      inputEl.step = cstring($stepVal)

    # DOM → Observable: update on input
    inputEl.addEventListener("input", proc(event: Event) =
      let target = cast[HTMLInputElement](event.target)
      case slider.config.valueKind
      of svkInt:
        let parsed = parseIntJS(target.value, 10)
        slider.value.set(intValue(parsed))  # Don't trigger onChange yet
      of svkFloat:
        let parsed = parseFloatJS(target.value)
        slider.value.set(floatValue(parsed))

      # Update display
      case slider.config.valueKind
      of svkInt:
        displayEl.textContent = cstring($slider.getInt())
      of svkFloat:
        displayEl.textContent = toFixed(slider.getFloat(), slider.config.precision)
    )

    # Trigger onChange on "change" event (after user releases slider)
    inputEl.addEventListener("change", proc(event: Event) =
      if not slider.onChange.isNil:
        slider.onChange()
    )

    # Observable → DOM: subscribe for external updates
    discard slider.value.subscribe(proc(value: SliderValue): proc() =
      case value.kind
      of svkInt:
        inputEl.value = cstring($value.intVal)
        displayEl.textContent = cstring($value.intVal)
      of svkFloat:
        inputEl.value = cstring($value.floatVal)
        displayEl.textContent = toFixed(value.floatVal, slider.config.precision)
      nil
    )

  proc configSlider*(
    inputId, displayId: string;
    get: proc(): float;
    set: proc(value: float);
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

    discard slider.value.subscribe(proc(value: SliderValue): proc() =
      set(value.toFloat())
      nil
    )

    if not onChange.isNil:
      slider.onChange = onChange

    slider.bindToDOM()
