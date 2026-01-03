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
    Element, Event, getElementById, querySelectorAll, forEach, addEventListener

  from std/jsffi import JsObject

  from ../../bindings/dom_extensions import
    HTMLElement, HTMLInputElement, dataset

  from ../../bindings/typed_arrays import Float32Array, `[]`, `[]=`

  from ../../bindings/js_interop import jsRandom, jsAbs

  import ../state/matrix_state

  # ============================================================================
  # SECTION 1: JS FFI
  # ============================================================================

  proc parseFloatJS(s: cstring): float {.importjs: "parseFloat(#)".}
  proc parseIntJS(s: cstring, radix: int): int {.importjs: "parseInt(#, #)".}
  proc isNaN(x: float): bool {.importjs: "isNaN(#)".}
  proc toFixed(x: float, digits: int): cstring {.importjs: "#.toFixed(#)".}

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

  proc updateCell*(editor: MatrixEditor; row, col: int; inputEl: HTMLInputElement) =
    ## Update a single matrix cell from input value.
    let v = parseFloatJS(inputEl.value)
    if not isNaN(v):
      let clamped = clampMatrixValue(v)
      let idx = matrixIndex(row, col)
      editor.matrix[idx] = clamped

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

  proc randomize*(editor: MatrixEditor) =
    ## Randomize all matrix values.
    let ns = editor.speciesCount[]
    for i in 0 ..< ns:
      for j in 0 ..< ns:
        let idx = matrixIndex(i, j)
        editor.matrix[idx] = jsRandom() * 2.0 - 1.0

    # Refresh display and trigger callback
    editor.render()
    if not editor.onUpdate.isNil:
      editor.onUpdate()

  # ============================================================================
  # SECTION 5: RENDER
  # ============================================================================

  proc render*(editor: MatrixEditor) =
    ## Render the matrix grid to DOM.
    let container = cast[HTMLElement](getElementById(cstring(editor.containerId)))
    if container.isNil:
      return

    let ns = editor.speciesCount[]
    container.style.gridTemplateColumns = cstring("repeat(" & $(ns + 1) & ", 1fr)")

    # Build HTML
    var html = "<div class=\"matrix-cell matrix-header\"></div>"

    # Column headers (species colors)
    for j in 0 ..< ns:
      let c = j * 3
      let r = int(editor.colors[c] * 255.0)
      let g = int(editor.colors[c + 1] * 255.0)
      let b = int(editor.colors[c + 2] * 255.0)
      html &= "<div class=\"matrix-cell matrix-header\" style=\"background:rgba(" &
              $r & "," & $g & "," & $b & ",0.5)\"></div>"

    # Matrix rows
    for i in 0 ..< ns:
      # Row header
      let c = i * 3
      let r = int(editor.colors[c] * 255.0)
      let g = int(editor.colors[c + 1] * 255.0)
      let b = int(editor.colors[c + 2] * 255.0)
      html &= "<div class=\"matrix-cell matrix-header\" style=\"background:rgba(" &
              $r & "," & $g & "," & $b & ",0.5)\"></div>"

      # Matrix cells
      for j in 0 ..< ns:
        let idx = matrixIndex(i, j)
        let v = editor.matrix[idx]
        let color = cellColorFromValue(v)
        html &= "<div class=\"matrix-cell\" style=\"background:" & toHslaString(color) & "\">" &
                "<input type=\"number\" step=\"0.1\" value=\"" & $toFixed(v, 2) & "\" " &
                "data-row=\"" & $i & "\" data-col=\"" & $j & "\">" &
                "</div>"

    container.innerHTML = cstring(html)

    # Attach event listeners
    let inputs = container.querySelectorAll("input[type=\"number\"]")
    let editorRef = editor  # Capture for closure
    inputs.forEach(proc(input: Element) =
      let inputEl = cast[HTMLInputElement](input)
      inputEl.addEventListener("change", proc(e: Event) =
        let target = cast[HTMLElement](e.target)
        let ds = target.dataset()
        let row = parseIntJS(cast[cstring](ds["row"]), 10)
        let col = parseIntJS(cast[cstring](ds["col"]), 10)
        editorRef.updateCell(row, col, cast[HTMLInputElement](e.target))
      )
    )
