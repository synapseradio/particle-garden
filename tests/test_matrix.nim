# ==============================================================================
# PARTICLE GARDEN - MATRIX STATE TESTS
# ==============================================================================
#
# Unit tests for matrix state pure functions.
# Tests index calculations, value operations, and color generation.
#
# Run with: nimble test
#
# ==============================================================================

import std/[sets, unittest]
import ../src/ui/state/matrix_state

# Exported symbol for test_all.nim to reference
const MATRIX_STATE_TESTS_LOADED* = true

# ==============================================================================
# INDEX CALCULATION TESTS
# ==============================================================================

suite "Matrix Index - Calculations":
  test "matrixIndex at origin":
    check matrixIndex(0, 0) == 0

  test "matrixIndex first row":
    check matrixIndex(0, 1) == 1
    check matrixIndex(0, 5) == 5

  test "matrixIndex second row":
    check matrixIndex(1, 0) == 6
    check matrixIndex(1, 1) == 7

  test "matrixIndex last cell":
    check matrixIndex(5, 5) == 35

  test "matrixCoords inverse of matrixIndex":
    for row in 0 ..< 6:
      for col in 0 ..< 6:
        let idx = matrixIndex(row, col)
        let (gotRow, gotCol) = matrixCoords(idx)
        check gotRow == row
        check gotCol == col


suite "Matrix Index - Validation":
  test "isValidIndex within bounds":
    check isValidIndex(0, 0, 4) == true
    check isValidIndex(3, 3, 4) == true

  test "isValidIndex at boundary":
    check isValidIndex(3, 3, 4) == true
    check isValidIndex(4, 3, 4) == false
    check isValidIndex(3, 4, 4) == false

  test "isValidIndex negative indices":
    check isValidIndex(-1, 0, 4) == false
    check isValidIndex(0, -1, 4) == false

  test "isValidIndex exceeds MAX_SPECIES":
    check isValidIndex(0, 0, 7) == false
    check isValidIndex(0, 0, 6) == true


# ==============================================================================
# VALUE OPERATION TESTS
# ==============================================================================

suite "Matrix Values - Clamping":
  test "clampMatrixValue within range":
    check abs(clampMatrixValue(0.5) - 0.5) < 0.001
    check abs(clampMatrixValue(-0.5) - (-0.5)) < 0.001

  test "clampMatrixValue at boundaries":
    check abs(clampMatrixValue(1.0) - 1.0) < 0.001
    check abs(clampMatrixValue(-1.0) - (-1.0)) < 0.001

  test "clampMatrixValue exceeds max":
    check abs(clampMatrixValue(1.5) - 1.0) < 0.001
    check abs(clampMatrixValue(100.0) - 1.0) < 0.001

  test "clampMatrixValue exceeds min":
    check abs(clampMatrixValue(-1.5) - (-1.0)) < 0.001
    check abs(clampMatrixValue(-100.0) - (-1.0)) < 0.001


suite "Matrix Values - Classification":
  test "isAttraction positive values":
    check isAttraction(0.5) == true
    check isAttraction(1.0) == true
    check isAttraction(0.001) == true

  test "isAttraction non-positive values":
    check isAttraction(0.0) == false
    check isAttraction(-0.5) == false

  test "isRepulsion negative values":
    check isRepulsion(-0.5) == true
    check isRepulsion(-1.0) == true
    check isRepulsion(-0.001) == true

  test "isRepulsion non-negative values":
    check isRepulsion(0.0) == false
    check isRepulsion(0.5) == false

  test "isNeutral at zero":
    check isNeutral(0.0) == true
    check isNeutral(0.0001) == true
    check isNeutral(-0.0001) == true

  test "isNeutral non-zero":
    check isNeutral(0.01) == false
    check isNeutral(-0.01) == false


# ==============================================================================
# COLOR CALCULATION TESTS
# ==============================================================================

suite "Cell Color - From Value":
  test "cellColorFromValue positive (attraction)":
    let color = cellColorFromValue(0.5)
    check color.hue == 120  # Green
    check color.saturation == 50
    check color.lightness == 40
    check abs(color.alpha - 0.7) < 0.001

  test "cellColorFromValue negative (repulsion)":
    let color = cellColorFromValue(-0.5)
    check color.hue == 0  # Red
    check color.saturation == 50

  test "cellColorFromValue max attraction":
    let color = cellColorFromValue(1.0)
    check color.hue == 120
    check color.saturation == 100

  test "cellColorFromValue max repulsion":
    let color = cellColorFromValue(-1.0)
    check color.hue == 0
    check color.saturation == 100

  test "cellColorFromValue neutral":
    let color = cellColorFromValue(0.0)
    check color.saturation == 0  # No saturation at zero

  test "cellColorFromValue clamps saturation to 100 when magnitude exceeds 1.0":
    # CONTRACT: saturation = min(100, int(abs(v)*100)). Values beyond +/-1.0 must
    # not produce a >100 saturation (an invalid CSS percentage). The existing
    # v=1.0 cases land exactly on 100 and never exercise the clamp branch.
    check cellColorFromValue(2.0).saturation == 100
    check cellColorFromValue(-3.5).saturation == 100
    check cellColorFromValue(1.5).hue == 120
    check cellColorFromValue(-1.5).hue == 0


suite "Cell Color - String Conversion":
  test "toHslaString format":
    let color = CellColor(hue: 120, saturation: 50, lightness: 40, alpha: 0.7)
    check toHslaString(color) == "hsla(120,50%,40%,0.7)"

  test "toHslaString red":
    let color = cellColorFromValue(-1.0)
    let hsla = toHslaString(color)
    check hsla == "hsla(0,100%,40%,0.7)"


suite "Species Color - From Index":
  test "speciesColorFromIndex valid":
    let colors = [1.0, 0.5, 0.0, 0.0, 1.0, 0.5]  # 2 species
    let color = speciesColorFromIndex(0, colors)
    check color.red == 255
    check color.green == 127  # 0.5 * 255 ≈ 127
    check color.blue == 0

  test "speciesColorFromIndex second species":
    let colors = [1.0, 0.5, 0.0, 0.0, 1.0, 0.5]
    let color = speciesColorFromIndex(1, colors)
    check color.red == 0
    check color.green == 255
    check color.blue == 127

  test "speciesColorFromIndex out of bounds":
    let colors = [1.0, 0.5, 0.0]  # Only 1 species
    let color = speciesColorFromIndex(5, colors)
    check color.red == 128  # Default gray
    check color.green == 128
    check color.blue == 128


suite "Species Color - String Conversion":
  test "toRgbaString format":
    let color = SpeciesColor(red: 255, green: 128, blue: 0, alpha: 0.5)
    check toRgbaString(color) == "rgba(255,128,0,0.5)"

# ==============================================================================
# RULE RANDOMIZATION - REJECTION SAMPLING
# ==============================================================================
#
# sampleRuleValue is the pure core of the matrix randomizer: it scales draws
# from an injected standard-normal source by sigma (CONFIG.ruleTemperature)
# and rejects any product outside [-1, 1], preserving the bell shape instead
# of piling clamped mass onto the boundaries.

proc scriptedSampler(draws: seq[float]): proc(): float =
  ## Deterministic stand-in for gaussian(): yields the scripted draws in
  ## order and fails the test if the code under test over-draws.
  var cursor = 0
  let captured = draws
  result = proc(): float =
    doAssert cursor < captured.len, "sampler over-drawn"
    let draw = captured[cursor]
    inc cursor
    draw

suite "Rule Randomization - Rejection Sampling":
  test "sampleRuleValue scales the first in-range draw by sigma":
    check sampleRuleValue(0.3, scriptedSampler(@[0.5])) == 0.5 * 0.3

  test "sampleRuleValue rejects draws that scale outside the matrix range":
    # 5.0 * 0.5 and -4.0 * 0.5 both leave [-1, 1]; the third draw lands.
    check sampleRuleValue(0.5, scriptedSampler(@[5.0, -4.0, 0.2])) == 0.2 * 0.5

  test "sampleRuleValue accepts the range boundaries inclusively":
    # The ui.nim loop rejected only strictly-outside products; pin that.
    check sampleRuleValue(1.0, scriptedSampler(@[1.0])) == 1.0
    check sampleRuleValue(1.0, scriptedSampler(@[-1.0])) == -1.0

  test "sampleRuleValue result always lies within the matrix range":
    let pattern = @[3.2, -7.7, 0.9, -0.4, 1.4, 0.05]
    var cursor = 0
    let cycling = proc(): float =
      result = pattern[cursor mod pattern.len]
      inc cursor
    for sampleIndex in 0 ..< 20:
      let sampled = sampleRuleValue(0.7, cycling)
      check sampled >= MATRIX_MIN_VALUE
      check sampled <= MATRIX_MAX_VALUE

# ==============================================================================
# SPECIES GROWTH - NEWLY EXPOSED CELLS
# ==============================================================================
#
# When the species count grows interactively, only the newly exposed matrix
# cells get randomized; established rules survive. Shrinking preserves the
# hidden values in the buffer so they reappear on re-grow.

suite "Species Growth Exposes Exactly The New Cells":
  test "shrinking or keeping the species count exposes nothing":
    check newlyExposedCells(4, 4).len == 0
    check newlyExposedCells(6, 2).len == 0

  test "growing exposes exactly the L-shaped band of new cells":
    let cells = newlyExposedCells(2, 3)
    check cells.len == 3 * 3 - 2 * 2
    for cell in cells:
      check cell.row < 3
      check cell.col < 3
      check cell.row >= 2 or cell.col >= 2

  test "growing from zero exposes the full grid":
    check newlyExposedCells(0, 2).len == 4

  test "every exposed cell appears exactly once":
    let cells = newlyExposedCells(3, 5)
    check cells.len == 5 * 5 - 3 * 3
    check toHashSet(cells).len == cells.len
