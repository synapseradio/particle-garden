# ==============================================================================
# MATRIX STATE - Attraction matrix value management
# ==============================================================================
#
# Pure functions for matrix value calculations and validation.
# The actual matrix storage remains in buffers.nim (Float32Array).
#
# ==============================================================================

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

func clampMatrixValue*(v: float): float =
  ## Clamp value to valid matrix range [-1, 1].
  max(MATRIX_MIN_VALUE, min(MATRIX_MAX_VALUE, v))

proc randomMatrixValue*(): float =
  ## Generate a random value in [-1, 1].
  ## Note: Caller must provide actual random value, this just documents the range.
  0.0  # Placeholder - actual randomization done in JS with jsRandom()

func isAttraction*(v: float): bool =
  ## Check if value represents attraction (positive).
  v > 0.0

func isRepulsion*(v: float): bool =
  ## Check if value represents repulsion (negative).
  v < 0.0

func isNeutral*(v: float): bool =
  ## Check if value is neutral (zero or very close).
  abs(v) < 0.001

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

func cellColorFromValue*(v: float): CellColor =
  ## Calculate cell background color from attraction value.
  ## Positive values → green, negative → red.
  ## Saturation indicates strength.
  let hue = if v > 0: 120 else: 0
  let saturation = int(abs(v) * 100.0)
  CellColor(
    hue: hue,
    saturation: min(100, saturation),
    lightness: 40,
    alpha: 0.7
  )

func toHslaString*(c: CellColor): string =
  ## Convert to CSS hsla() string.
  "hsla(" & $c.hue & "," & $c.saturation & "%," & $c.lightness & "%," & $c.alpha & ")"

# ==============================================================================
# SECTION 5: SPECIES COLOR (for headers)
# ==============================================================================

type
  SpeciesColor* = object
    ## RGB color for species header.
    r*, g*, b*: int
    alpha*: float

func speciesColorFromIndex*(index: int, colors: openArray[float]): SpeciesColor =
  ## Extract species color from COLORS array.
  ## Colors array is interleaved RGB (3 floats per species).
  let offset = index * 3
  if offset + 2 < colors.len:
    SpeciesColor(
      r: int(colors[offset] * 255.0),
      g: int(colors[offset + 1] * 255.0),
      b: int(colors[offset + 2] * 255.0),
      alpha: 0.5
    )
  else:
    SpeciesColor(r: 128, g: 128, b: 128, alpha: 0.5)

func toRgbaString*(c: SpeciesColor): string =
  ## Convert to CSS rgba() string.
  "rgba(" & $c.r & "," & $c.g & "," & $c.b & "," & $c.alpha & ")"
