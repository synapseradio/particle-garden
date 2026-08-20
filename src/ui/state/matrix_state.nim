# ==============================================================================
# MATRIX STATE - Attraction matrix value management
# ==============================================================================
#
# Pure functions for matrix value calculations and validation.
# The actual matrix storage remains in buffers.nim (Float32Array).
#
# ==============================================================================

import std/math

import ../../config_ranges

# ==============================================================================
# SECTION 1: CONSTANTS
# ==============================================================================
#
# The served value band lives with every other range in config_ranges
# (MATRIX_MIN_VALUE/MATRIX_MAX_VALUE, step, display precision); this module
# reads it like every other consumer.

const
  MATRIX_SIZE* = 8                    ## Maximum species count

func matrixIndex*(row, col: int): int =
  ## Row = species feeling the force
  ## Col = species exerting the force
  row * MATRIX_SIZE + col

func matrixCoords*(index: int): tuple[row, col: int] =
  (row: index div MATRIX_SIZE, col: index mod MATRIX_SIZE)

func isValidIndex*(row, col, speciesCount: int): bool =
  row >= 0 and row < speciesCount and
  col >= 0 and col < speciesCount and
  speciesCount <= MATRIX_SIZE

func clampMatrixValue*(value: float): float =
  max(MATRIX_MIN_VALUE, min(MATRIX_MAX_VALUE, value))

func isAttraction*(value: float): bool =
  value > 0.0

func isRepulsion*(value: float): bool =
  value < 0.0

func isNeutral*(value: float): bool =
  abs(value) < 0.001

type
  CellColor* = object
    ## HSL color representation for matrix cell.
    hue*: int          ## 0=red (repulsion), 120=green (attraction)
    saturation*: int   ## 0-100, intensity of attraction/repulsion
    lightness*: int    ## Fixed at 40
    alpha*: float      ## Fixed at 0.7

func cellColorFromValue*(value: float): CellColor =
  ## Saturation reads strength as a FRACTION of the served bound, so a
  ## full-strength cell saturates fully whatever the band is — a scale
  ## pinned to absolute values goes grey the day the range narrows.
  let hue = if value > 0: 120 else: 0
  let saturation = int(round(abs(value) / MATRIX_MAX_VALUE * 100.0))
  CellColor(
    hue: hue,
    saturation: min(100, saturation),
    lightness: 40,
    alpha: 0.7
  )

func toHslaString*(color: CellColor): string =
  "hsla(" & $color.hue & "," & $color.saturation & "%," & $color.lightness & "%," & $color.alpha & ")"

type
  SpeciesColor* = object
    ## RGB color for species header.
    red*, green*, blue*: int
    alpha*: float

func speciesColorFromIndex*(index: int, colors: openArray[float]): SpeciesColor =
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
  "rgba(" & $color.red & "," & $color.green & "," & $color.blue & "," & $color.alpha & ")"

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

func sampleRuleValue*(sigma: float, nextGaussian: proc(): float): float
    {.effectsOf: nextGaussian.} =
  ## One matrix rule value: standard-normal draws from nextGaussian scaled by
  ## sigma TIMES the served bound, rejecting any product outside
  ## [MATRIX_MIN_VALUE, MATRIX_MAX_VALUE] (boundaries accepted). Sigma is a
  ## fraction of the bound, so a re-ranged matrix re-scales the whole
  ## distribution and a randomized world keeps its character; rejection keeps
  ## the true bell shape instead of piling clamped mass onto the boundaries.
  result = nextGaussian() * sigma * MATRIX_MAX_VALUE
  while result < MATRIX_MIN_VALUE or result > MATRIX_MAX_VALUE:
    result = nextGaussian() * sigma * MATRIX_MAX_VALUE
