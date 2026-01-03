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

import std/unittest
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
        let (r, c) = matrixCoords(idx)
        check r == row
        check c == col


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
    let c = cellColorFromValue(0.5)
    check c.hue == 120  # Green
    check c.saturation == 50
    check c.lightness == 40
    check abs(c.alpha - 0.7) < 0.001

  test "cellColorFromValue negative (repulsion)":
    let c = cellColorFromValue(-0.5)
    check c.hue == 0  # Red
    check c.saturation == 50

  test "cellColorFromValue max attraction":
    let c = cellColorFromValue(1.0)
    check c.hue == 120
    check c.saturation == 100

  test "cellColorFromValue max repulsion":
    let c = cellColorFromValue(-1.0)
    check c.hue == 0
    check c.saturation == 100

  test "cellColorFromValue neutral":
    let c = cellColorFromValue(0.0)
    check c.saturation == 0  # No saturation at zero


suite "Cell Color - String Conversion":
  test "toHslaString format":
    let c = CellColor(hue: 120, saturation: 50, lightness: 40, alpha: 0.7)
    check toHslaString(c) == "hsla(120,50%,40%,0.7)"

  test "toHslaString red":
    let c = cellColorFromValue(-1.0)
    let s = toHslaString(c)
    check s == "hsla(0,100%,40%,0.7)"


suite "Species Color - From Index":
  test "speciesColorFromIndex valid":
    let colors = [1.0, 0.5, 0.0, 0.0, 1.0, 0.5]  # 2 species
    let c = speciesColorFromIndex(0, colors)
    check c.r == 255
    check c.g == 127  # 0.5 * 255 ≈ 127
    check c.b == 0

  test "speciesColorFromIndex second species":
    let colors = [1.0, 0.5, 0.0, 0.0, 1.0, 0.5]
    let c = speciesColorFromIndex(1, colors)
    check c.r == 0
    check c.g == 255
    check c.b == 127

  test "speciesColorFromIndex out of bounds":
    let colors = [1.0, 0.5, 0.0]  # Only 1 species
    let c = speciesColorFromIndex(5, colors)
    check c.r == 128  # Default gray
    check c.g == 128
    check c.b == 128


suite "Species Color - String Conversion":
  test "toRgbaString format":
    let c = SpeciesColor(r: 255, g: 128, b: 0, alpha: 0.5)
    check toRgbaString(c) == "rgba(255,128,0,0.5)"
