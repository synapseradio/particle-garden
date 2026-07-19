# ==============================================================================
# MATRIX VIEW - Matrix grid rendering and editing
# ==============================================================================
#
# DOM rendering and event handling for the attraction matrix.
# Uses pure functions from matrix_state for calculations.
#
# JS-only module - DOM operations not available natively.
#
# ==============================================================================

when defined(js):
  from std/dom import
    Element, Event, getElementById, querySelectorAll

  from std/jsffi import `[]`

  from ../../bindings/dom_extensions import
    HTMLElement, HTMLInputElement, dataset, forEach, addEventListener

  from ../../bindings/typed_arrays import Float32Array, `[]`, `[]=`

  from ../../bindings/js_interop import gaussian

  import ../state/matrix_state

  # Callers (ui.nim) speak the state vocabulary too: cells, indices, samplers
  export matrix_state

  # ============================================================================
  # SECTION 1: JS FFI
  # ============================================================================

  proc parseFloatJS(text: cstring): float {.importjs: "parseFloat(#)".}
  proc parseIntJS(text: cstring, radix: int): int {.importjs: "parseInt(#, #)".}
  proc isNaN(value: float): bool {.importjs: "isNaN(#)".}

  # ============================================================================
  # SECTION 2: MATRIX EDITOR
  # ============================================================================

  type
    MatrixEditor* = ref object
      ## Manages the matrix display and editing.
      containerId*: string
      matrix*: Float32Array         ## Reference to shared matrix buffer
      colors*: Float32Array         ## Reference to COLORS array
      speciesCount*: ptr int        ## Pointer to CONFIG.speciesCount
      onUpdate*: proc()             ## Called when matrix values change

  proc newMatrixEditor*(
    containerId: string;
    matrix: Float32Array;
    colors: Float32Array;
    speciesCount: ptr int
  ): MatrixEditor =
    ## Create a new matrix editor.
    MatrixEditor(
      containerId: containerId,
      matrix: matrix,
      colors: colors,
      speciesCount: speciesCount,
      onUpdate: nil
    )

  # ============================================================================
  # SECTION 3: CELL UPDATE
  # ============================================================================

  proc render*(editor: MatrixEditor)

  proc updateCell*(editor: MatrixEditor; row, col: int; inputEl: HTMLInputElement) =
    ## Update a single matrix cell from input value.
    let parsedValue = parseFloatJS(inputEl.value)
    if not isNaN(parsedValue):
      let clamped = clampMatrixValue(parsedValue)
      editor.matrix[matrixIndex(row, col)] = clamped

      # Update cell background color
      let color = cellColorFromValue(clamped)
      let parent = cast[HTMLElement](inputEl.parentElement)
      parent.style.background = cstring(toHslaString(color))

      # Trigger callback
      if not editor.onUpdate.isNil:
        editor.onUpdate()

  # ============================================================================
  # SECTION 4: RANDOMIZE
  # ============================================================================

  proc randomize*(editor: MatrixEditor; sigma: float) =
    ## Randomize all matrix values with the bell-curve rule sampler: gaussian
    ## draws scaled by sigma (CONFIG.ruleTemperature), rejection-sampled into
    ## [-1, 1] by matrix_state.sampleRuleValue.
    let activeSpecies = editor.speciesCount[]
    for row in 0 ..< activeSpecies:
      for col in 0 ..< activeSpecies:
        editor.matrix[matrixIndex(row, col)] = sampleRuleValue(sigma, gaussian)

    # Refresh display and trigger callback
    editor.render()
    if not editor.onUpdate.isNil:
      editor.onUpdate()

  proc randomizeCells*(editor: MatrixEditor; cells: seq[MatrixCell]; sigma: float) =
    ## Randomize only the given cells (a species-count grow randomizes just
    ## the newly exposed band; established rules survive). Re-renders and
    ## fires the update callback even for an empty set, so a shrink still
    ## refreshes the visible grid.
    for cell in cells:
      editor.matrix[matrixIndex(cell.row, cell.col)] = sampleRuleValue(sigma, gaussian)
    editor.render()
    if not editor.onUpdate.isNil:
      editor.onUpdate()

  # ============================================================================
  # SECTION 5: RENDER
  # ============================================================================

  proc render*(editor: MatrixEditor) =
    ## Render the matrix grid to DOM. Markup comes from matrix_state's pure
    ## builders; this proc only copies buffer views, sets innerHTML, and
    ## attaches the change listeners.
    let container = cast[HTMLElement](getElementById(cstring(editor.containerId)))
    if container.isNil:
      return

    let activeSpecies = editor.speciesCount[]
    container.style.gridTemplateColumns = cstring(gridTemplateColumns(activeSpecies))

    var values = newSeq[float](MATRIX_SIZE * MATRIX_SIZE)
    for valueIndex in 0 ..< values.len:
      values[valueIndex] = editor.matrix[valueIndex]
    var colorChannels = newSeq[float](activeSpecies * 3)
    for channelIndex in 0 ..< colorChannels.len:
      colorChannels[channelIndex] = editor.colors[channelIndex]

    container.innerHTML = cstring(matrixGridHtml(values, colorChannels, activeSpecies))

    # Attach event listeners
    let inputs = container.querySelectorAll("input[type=\"number\"]")
    let editorRef = editor  # Capture for closure
    inputs.forEach(proc(input: Element) =
      let inputEl = cast[HTMLInputElement](input)
      inputEl.addEventListener("change", proc(changeEvent: Event) =
        let target = cast[HTMLElement](changeEvent.target)
        let coords = target.dataset()
        let row = parseIntJS(cast[cstring](coords["row"]), 10)
        let col = parseIntJS(cast[cstring](coords["col"]), 10)
        editorRef.updateCell(row, col, cast[HTMLInputElement](changeEvent.target))
      )
    )
