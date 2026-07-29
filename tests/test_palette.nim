# Unit tests for pure color-generation functions in palette.nim.
# Tests hslToRgb known values, generatePalette count/length behavior, scheme
# distinctness, and channel range invariants.

import std/unittest
import ../src/palette

const PALETTE_TESTS_LOADED* = true

const
  EPSILON = 1e-9

proc approxEq(left, right: float; epsilon: float = EPSILON): bool =
  abs(left - right) <= epsilon

proc approxEqRgb(color: RgbColor, red, green, blue: float;
    epsilon: float = EPSILON): bool =
  approxEq(color.red, red, epsilon) and
    approxEq(color.green, green, epsilon) and
    approxEq(color.blue, blue, epsilon)

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
    let baseColor = hslToRgb(0.0, 0.8, 0.5)
    let wrappedColor = hslToRgb(1.0, 0.8, 0.5)
    check approxEqRgb(wrappedColor, baseColor.red, baseColor.green, baseColor.blue)

  test "hue wraps: negative hue matches its positive equivalent":
    let baseColor = hslToRgb(0.9, 0.8, 0.5)
    let wrappedColor = hslToRgb(-0.1, 0.8, 0.5)
    check approxEqRgb(wrappedColor, baseColor.red, baseColor.green, baseColor.blue)

suite "hslToRgb - Channel Range":
  test "channels stay within [0, 1] across a sweep of hues":
    for step in 0 .. 20:
      let hue = step.float / 20.0
      let color = hslToRgb(hue, 0.7, 0.55)
      check color.red >= 0.0 and color.red <= 1.0
      check color.green >= 0.0 and color.green <= 1.0
      check color.blue >= 0.0 and color.blue <= 1.0

  test "channels stay within [0, 1] across a sweep of saturation and lightness":
    for step in 0 .. 10:
      let saturation = step.float / 10.0
      let lightness = step.float / 10.0
      let color = hslToRgb(0.42, saturation, lightness)
      check color.red >= 0.0 and color.red <= 1.0
      check color.green >= 0.0 and color.green <= 1.0
      check color.blue >= 0.0 and color.blue <= 1.0

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

suite "generatePalette - Scheme Distinctness":
  test "golden scheme produces pairwise-distinct colors":
    let palette = generatePalette(6, psGolden)
    for firstIndex in 0 ..< palette.len:
      for secondIndex in (firstIndex + 1) ..< palette.len:
        check not approxEqRgb(palette[firstIndex], palette[secondIndex].red,
          palette[secondIndex].green, palette[secondIndex].blue, 1e-3)

  test "spectrum scheme produces pairwise-distinct colors":
    let palette = generatePalette(6, psSpectrum)
    for firstIndex in 0 ..< palette.len:
      for secondIndex in (firstIndex + 1) ..< palette.len:
        check not approxEqRgb(palette[firstIndex], palette[secondIndex].red,
          palette[secondIndex].green, palette[secondIndex].blue, 1e-3)

  test "warm and cool schemes are distinct from each other at every index":
    let warmPalette = generatePalette(6, psWarm)
    let coolPalette = generatePalette(6, psCool)
    for colorIndex in 0 ..< 6:
      check not approxEqRgb(warmPalette[colorIndex], coolPalette[colorIndex].red,
        coolPalette[colorIndex].green, coolPalette[colorIndex].blue, 1e-3)

  test "default scheme (no scheme argument) matches psGolden explicitly":
    let defaultPalette = generatePalette(6)
    let goldenPalette = generatePalette(6, psGolden)
    for colorIndex in 0 ..< 6:
      check approxEqRgb(defaultPalette[colorIndex], goldenPalette[colorIndex].red,
        goldenPalette[colorIndex].green, goldenPalette[colorIndex].blue)

suite "generatePalette - Channel Range":
  test "every channel of every color is within [0, 1], for every scheme":
    for scheme in PaletteScheme:
      let palette = generatePalette(16, scheme)
      for color in palette:
        check color.red >= 0.0 and color.red <= 1.0
        check color.green >= 0.0 and color.green <= 1.0
        check color.blue >= 0.0 and color.blue <= 1.0

suite "flattenPalette":
  test "flattens to 3x the palette length":
    let palette = generatePalette(6)
    check flattenPalette(palette).len == 18

  test "empty palette flattens to empty seq":
    check flattenPalette(generatePalette(0)).len == 0

  test "interleaves red, green, blue in order per color":
    let palette = @[
      (red: 0.1, green: 0.2, blue: 0.3),
      (red: 0.4, green: 0.5, blue: 0.6)
    ]
    let flattened = flattenPalette(palette)
    check flattened.len == 6
    check approxEq(flattened[0], 0.1)
    check approxEq(flattened[1], 0.2)
    check approxEq(flattened[2], 0.3)
    check approxEq(flattened[3], 0.4)
    check approxEq(flattened[4], 0.5)
    check approxEq(flattened[5], 0.6)

suite "generatePalette - Open Color Scheme":
  # Default species colors are Open Color swatches
  # (https://yeun.github.io/open-color/), picked bright and ordered to
  # preserve the classic species identities: red, green, blue, yellow, grape
  # (magenta slot), cyan. Hex values verified against the canonical
  # open-color.json (red-5 #ff6b6b, green-5 #51cf66, blue-5 #339af0,
  # yellow-4 #ffd43b, grape-5 #cc5de8, cyan-4 #3bc9db).

  test "psOpenColor returns the six verified Open Color swatches in species order":
    let colors = generatePalette(6, psOpenColor)
    check colors.len == 6
    check approxEqRgb(colors[0], 255.0/255.0, 107.0/255.0, 107.0/255.0)  # red-5
    check approxEqRgb(colors[1],  81.0/255.0, 207.0/255.0, 102.0/255.0)  # green-5
    check approxEqRgb(colors[2],  51.0/255.0, 154.0/255.0, 240.0/255.0)  # blue-5
    check approxEqRgb(colors[3], 255.0/255.0, 212.0/255.0,  59.0/255.0)  # yellow-4
    check approxEqRgb(colors[4], 204.0/255.0,  93.0/255.0, 232.0/255.0)  # grape-5
    check approxEqRgb(colors[5],  59.0/255.0, 201.0/255.0, 219.0/255.0)  # cyan-4

  test "psOpenColor swatches are bright (every swatch peaks at or above 0.8)":
    # Each swatch's dominant channel must carry real luminance against the
    # dark canvas — that's what 'brighter' requires here.
    for color in generatePalette(6, psOpenColor):
      check max(color.red, max(color.green, color.blue)) >= 0.8

  test "psOpenColor ignores saturation and lightness arguments":
    # The swatches are fixed picks, not HSL-generated; the knobs are documented
    # as inert for this scheme.
    check generatePalette(6, psOpenColor, saturation = 0.1, lightness = 0.9) ==
      generatePalette(6, psOpenColor)

  test "psOpenColor wraps around past six colors and truncates below":
    let wrapped = generatePalette(8, psOpenColor)
    check wrapped.len == 8
    check wrapped[6] == wrapped[0]
    check wrapped[7] == wrapped[1]
    check generatePalette(2, psOpenColor).len == 2
