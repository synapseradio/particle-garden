# ==============================================================================
# MATRIX STATE - Attraction matrix value management
# ==============================================================================
#
# Pure functions for matrix value calculations and validation.
# The actual matrix storage remains in buffers.nim (Float32Array).
#
# ==============================================================================

import std/strutils

# ==============================================================================
# SECTION 1: CONSTANTS
# ==============================================================================

const
  MATRIX_SIZE* = 6                    ## Maximum species count
  MATRIX_MIN_VALUE* = -1.0            ## Maximum repulsion
  MATRIX_MAX_VALUE* = 1.0             ## Maximum attraction

# ==============================================================================
# SECTION 2: INDEX CALCULATIONS (pure functions)
# ==============================================================================

func matrixIndex*(row, col: int): int =
  ## Convert (row, col) to linear index.
  ## Row = species feeling the force
  ## Col = species exerting the force
  row * MATRIX_SIZE + col

func matrixCoords*(index: int): tuple[row, col: int] =
  ## Convert linear index to (row, col).
  (row: index div MATRIX_SIZE, col: index mod MATRIX_SIZE)

func isValidIndex*(row, col, speciesCount: int): bool =
  ## Check if indices are valid for given species count.
  row >= 0 and row < speciesCount and
  col >= 0 and col < speciesCount and
  speciesCount <= MATRIX_SIZE

# ==============================================================================
# SECTION 3: VALUE OPERATIONS (pure functions)
# ==============================================================================

func clampMatrixValue*(value: float): float =
  ## Clamp value to valid matrix range [-1, 1].
  max(MATRIX_MIN_VALUE, min(MATRIX_MAX_VALUE, value))

func isAttraction*(value: float): bool =
  ## Check if value represents attraction (positive).
  value > 0.0

func isRepulsion*(value: float): bool =
  ## Check if value represents repulsion (negative).
  value < 0.0

func isNeutral*(value: float): bool =
  ## Check if value is neutral (zero or very close).
  abs(value) < 0.001

# ==============================================================================
# SECTION 4: COLOR CALCULATIONS (pure functions)
# ==============================================================================

type
  CellColor* = object
    ## HSL color representation for matrix cell.
    hue*: int          ## 0=red (repulsion), 120=green (attraction)
    saturation*: int   ## 0-100, intensity of attraction/repulsion
    lightness*: int    ## Fixed at 40
    alpha*: float      ## Fixed at 0.7

func cellColorFromValue*(value: float): CellColor =
  ## Calculate cell background color from attraction value.
  ## Positive values → green, negative → red.
  ## Saturation indicates strength.
  let hue = if value > 0: 120 else: 0
  let saturation = int(abs(value) * 100.0)
  CellColor(
    hue: hue,
    saturation: min(100, saturation),
    lightness: 40,
    alpha: 0.7
  )

func toHslaString*(color: CellColor): string =
  ## Convert to CSS hsla() string.
  "hsla(" & $color.hue & "," & $color.saturation & "%," & $color.lightness & "%," & $color.alpha & ")"

# ==============================================================================
# SECTION 5: SPECIES COLOR (for headers)
# ==============================================================================

type
  SpeciesColor* = object
    ## RGB color for species header.
    red*, green*, blue*: int
    alpha*: float

func speciesColorFromIndex*(index: int, colors: openArray[float]): SpeciesColor =
  ## Extract species color from COLORS array.
  ## Colors array is interleaved RGB (3 floats per species).
  let offset = index * 3
  if offset + 2 < colors.len:
    SpeciesColor(
      red: int(colors[offset] * 255.0),
      green: int(colors[offset + 1] * 255.0),
      blue: int(colors[offset + 2] * 255.0),
      alpha: 0.5
    )
  else:
    SpeciesColor(red: 128, green: 128, blue: 128, alpha: 0.5)

func toRgbaString*(color: SpeciesColor): string =
  ## Convert to CSS rgba() string.
  "rgba(" & $color.red & "," & $color.green & "," & $color.blue & "," & $color.alpha & ")"

# ==============================================================================
# SECTION 5b: SPECIES GROWTH
# ==============================================================================

type
  MatrixCell* = tuple[row, col: int]

func newlyExposedCells*(oldCount, newCount: int): seq[MatrixCell] =
  ## The cells visible at newCount that were not visible at oldCount: the
  ## L-shaped band a species-count grow exposes. Shrinks expose nothing —
  ## hidden values persist in the buffer and reappear on re-grow.
  if newCount <= oldCount:
    return @[]
  for row in 0 ..< newCount:
    for col in 0 ..< newCount:
      if row >= oldCount or col >= oldCount:
        result.add((row: row, col: col))

# ==============================================================================
# SECTION 6: RULE RANDOMIZATION (pure core)
# ==============================================================================

proc sampleRuleValue*(sigma: float, nextGaussian: proc(): float): float =
  ## One matrix rule value: standard-normal draws from nextGaussian scaled by
  ## sigma, rejecting any product outside [MATRIX_MIN_VALUE, MATRIX_MAX_VALUE]
  ## (boundaries accepted). Rejection keeps the true bell shape instead of
  ## piling clamped mass onto the boundaries.
  result = nextGaussian() * sigma
  while result < MATRIX_MIN_VALUE or result > MATRIX_MAX_VALUE:
    result = nextGaussian() * sigma

# ==============================================================================
# SECTION 7: GRID HTML (pure builders)
# ==============================================================================
#
# The matrix editor's grid markup as plain strings, so layout and formatting
# are natively testable. matrix_view sets innerHTML and attaches listeners.

const CORNER_CELL_HTML* = "<div class=\"matrix-cell matrix-header\"></div>"

func gridTemplateColumns*(speciesCount: int): string =
  ## CSS grid-template-columns for speciesCount species plus the header column.
  "repeat(" & $(speciesCount + 1) & ", 1fr)"

func headerCellHtml*(swatch: SpeciesColor): string =
  ## A header cell carrying a species color swatch.
  "<div class=\"matrix-cell matrix-header\" style=\"background:" &
    toRgbaString(swatch) & "\"></div>"

func valueCellHtml*(value: float; row, col: int): string =
  ## An editable value cell: two-decimal value, color-coded background,
  ## data-row/data-col coordinates for the change listener.
  let background = toHslaString(cellColorFromValue(value))
  "<div class=\"matrix-cell\" style=\"background:" & background & "\">" &
    "<input type=\"number\" step=\"0.1\" value=\"" &
    formatFloat(value, ffDecimal, 2) & "\" " &
    "data-row=\"" & $row & "\" data-col=\"" & $col & "\">" &
    "</div>"

func matrixGridHtml*(values, colors: openArray[float]; speciesCount: int): string =
  ## The full grid: corner, column headers, then one header + speciesCount
  ## value cells per row. values uses the six-wide matrixIndex stride; colors
  ## is interleaved RGB, three floats per species.
  result = CORNER_CELL_HTML
  for headerCol in 0 ..< speciesCount:
    result &= headerCellHtml(speciesColorFromIndex(headerCol, colors))
  for row in 0 ..< speciesCount:
    result &= headerCellHtml(speciesColorFromIndex(row, colors))
    for col in 0 ..< speciesCount:
      result &= valueCellHtml(values[matrixIndex(row, col)], row, col)
