# ==============================================================================
# PARTICLE GARDEN - PALETTE TESTS
# ==============================================================================
#
# Unit tests for pure color-generation functions in palette.nim.
# Tests hslToRgb known values, generatePalette count/length behavior, scheme
# distinctness, and channel range invariants.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/palette

# Exported symbol for test_all.nim to reference
const PALETTE_TESTS_LOADED* = true

const
  EPSILON = 1e-9

proc approxEq(a, b: float; epsilon: float = EPSILON): bool =
  ## Epsilon-based float comparison for testing.
  abs(a - b) <= epsilon

proc approxEqRgb(c: tuple[r, g, b: float], r, g, b: float; epsilon: float = EPSILON): bool =
  approxEq(c.r, r, epsilon) and approxEq(c.g, g, epsilon) and approxEq(c.b, b, epsilon)

# ==============================================================================
# HSL -> RGB KNOWN VALUES
# ==============================================================================

suite "hslToRgb - Known Values":
  test "zero saturation is gray at any hue":
    check approxEqRgb(hslToRgb(0.0, 0.0, 0.5), 0.5, 0.5, 0.5)
    check approxEqRgb(hslToRgb(0.37, 0.0, 0.5), 0.5, 0.5, 0.5)

  test "lightness 0 is always black":
    check approxEqRgb(hslToRgb(0.0, 1.0, 0.0), 0.0, 0.0, 0.0)
    check approxEqRgb(hslToRgb(0.5, 1.0, 0.0), 0.0, 0.0, 0.0)

  test "lightness 1 is always white":
    check approxEqRgb(hslToRgb(0.0, 1.0, 1.0), 1.0, 1.0, 1.0)
    check approxEqRgb(hslToRgb(0.5, 1.0, 1.0), 1.0, 1.0, 1.0)

  test "hue 0, full saturation, mid lightness is pure red":
    check approxEqRgb(hslToRgb(0.0, 1.0, 0.5), 1.0, 0.0, 0.0)

  test "hue 1/3, full saturation, mid lightness is pure green":
    check approxEqRgb(hslToRgb(1.0 / 3.0, 1.0, 0.5), 0.0, 1.0, 0.0)

  test "hue 2/3, full saturation, mid lightness is pure blue":
    check approxEqRgb(hslToRgb(2.0 / 3.0, 1.0, 0.5), 0.0, 0.0, 1.0)

  test "hue wraps: h=1.0 matches h=0.0":
    let a = hslToRgb(0.0, 0.8, 0.5)
    let b = hslToRgb(1.0, 0.8, 0.5)
    check approxEqRgb(b, a.r, a.g, a.b)

  test "hue wraps: negative hue matches its positive equivalent":
    let a = hslToRgb(0.9, 0.8, 0.5)
    let b = hslToRgb(-0.1, 0.8, 0.5)
    check approxEqRgb(b, a.r, a.g, a.b)

# ==============================================================================
# HSL -> RGB RANGE INVARIANTS
# ==============================================================================

suite "hslToRgb - Channel Range":
  test "channels stay within [0, 1] across a sweep of hues":
    for i in 0 .. 20:
      let h = i.float / 20.0
      let c = hslToRgb(h, 0.7, 0.55)
      check c.r >= 0.0 and c.r <= 1.0
      check c.g >= 0.0 and c.g <= 1.0
      check c.b >= 0.0 and c.b <= 1.0

  test "channels stay within [0, 1] across a sweep of saturation and lightness":
    for i in 0 .. 10:
      let s = i.float / 10.0
      let l = i.float / 10.0
      let c = hslToRgb(0.42, s, l)
      check c.r >= 0.0 and c.r <= 1.0
      check c.g >= 0.0 and c.g <= 1.0
      check c.b >= 0.0 and c.b <= 1.0

# ==============================================================================
# GENERATEPALETTE - LENGTH / COUNT BEHAVIOR
# ==============================================================================

suite "generatePalette - Length and Count":
  test "zero count returns an empty palette":
    check generatePalette(0).len == 0

  test "negative count returns an empty palette":
    check generatePalette(-3).len == 0

  test "count returns exactly that many colors, default scheme":
    check generatePalette(1).len == 1
    check generatePalette(6).len == 6
    check generatePalette(16).len == 16

  test "count returns exactly that many colors, for every named scheme":
    for scheme in PaletteScheme:
      check generatePalette(6, scheme).len == 6

# ==============================================================================
# GENERATEPALETTE - SCHEME DISTINCTNESS
# ==============================================================================

suite "generatePalette - Scheme Distinctness":
  test "golden scheme produces pairwise-distinct colors":
    let pal = generatePalette(6, psGolden)
    for i in 0 ..< pal.len:
      for j in (i + 1) ..< pal.len:
        check not approxEqRgb(pal[i], pal[j].r, pal[j].g, pal[j].b, 1e-3)

  test "spectrum scheme produces pairwise-distinct colors":
    let pal = generatePalette(6, psSpectrum)
    for i in 0 ..< pal.len:
      for j in (i + 1) ..< pal.len:
        check not approxEqRgb(pal[i], pal[j].r, pal[j].g, pal[j].b, 1e-3)

  test "warm and cool schemes are distinct from each other at every index":
    let warm = generatePalette(6, psWarm)
    let cool = generatePalette(6, psCool)
    for i in 0 ..< 6:
      check not approxEqRgb(warm[i], cool[i].r, cool[i].g, cool[i].b, 1e-3)

  test "default scheme (no scheme argument) matches psGolden explicitly":
    let defaultPal = generatePalette(6)
    let goldenPal = generatePalette(6, psGolden)
    for i in 0 ..< 6:
      check approxEqRgb(defaultPal[i], goldenPal[i].r, goldenPal[i].g, goldenPal[i].b)

# ==============================================================================
# GENERATEPALETTE - CHANNEL RANGE
# ==============================================================================

suite "generatePalette - Channel Range":
  test "every channel of every color is within [0, 1], for every scheme":
    for scheme in PaletteScheme:
      let pal = generatePalette(16, scheme)
      for c in pal:
        check c.r >= 0.0 and c.r <= 1.0
        check c.g >= 0.0 and c.g <= 1.0
        check c.b >= 0.0 and c.b <= 1.0

# ==============================================================================
# FLATTENPALETTE
# ==============================================================================

suite "flattenPalette":
  test "flattens to 3x the palette length":
    let pal = generatePalette(6)
    check flattenPalette(pal).len == 18

  test "empty palette flattens to empty seq":
    check flattenPalette(generatePalette(0)).len == 0

  test "interleaves r, g, b in order per color":
    let pal = @[(r: 0.1, g: 0.2, b: 0.3), (r: 0.4, g: 0.5, b: 0.6)]
    let flat = flattenPalette(pal)
    check flat.len == 6
    check approxEq(flat[0], 0.1)
    check approxEq(flat[1], 0.2)
    check approxEq(flat[2], 0.3)
    check approxEq(flat[3], 0.4)
    check approxEq(flat[4], 0.5)
    check approxEq(flat[5], 0.6)
