# Unit tests for the palette editor's pure typed state in
# ui/state/palette_state.nim: determinism, scheme inertness (mirroring
# palette.nim's documented psOpenColor inertness both ways), scheme-id
# round-trip, defaults, and channel range invariants.

import std/unittest
import std/math
import ../src/ui/state/palette_state
import ../src/config_ranges

const PALETTE_STATE_TESTS_LOADED* = true

const
  EPSILON = 1e-9

proc approxEq(left, right: float; epsilon: float = EPSILON): bool =
  abs(left - right) <= epsilon

proc palettesEqual(left, right: seq[RgbColor]): bool =
  if left.len != right.len:
    return false
  for colorIndex in 0 ..< left.len:
    if not approxEq(left[colorIndex].red, right[colorIndex].red) or
       not approxEq(left[colorIndex].green, right[colorIndex].green) or
       not approxEq(left[colorIndex].blue, right[colorIndex].blue):
      return false
  true

suite "PaletteEditorState - Determinism":
  test "equal states produce element-wise equal palettes":
    let stateA = PaletteEditorState(scheme: psGolden, saturation: 0.6, lightness: 0.4)
    let stateB = PaletteEditorState(scheme: psGolden, saturation: 0.6, lightness: 0.4)
    check palettesEqual(paletteFor(stateA), paletteFor(stateB))

suite "PaletteEditorState - Length Invariant":
  test "paletteFor returns MAX_SPECIES colors for every scheme":
    for scheme in PaletteScheme:
      let state = PaletteEditorState(scheme: scheme, saturation: 0.7, lightness: 0.5)
      check paletteFor(state).len == MAX_SPECIES

suite "PaletteEditorState - Species Are Told Apart By Colour":
  # A species the eye cannot separate from its neighbour is a species the world
  # does not show. This holds that at the ceiling, for every scheme, so raising
  # MAX_SPECIES again fails here rather than shipping two species one colour.
  #
  # ORACLE: CIE76 dE in CIE L*a*b*, computed here rather than read from
  # palette.nim, which knows only RGB. Euclidean RGB distance would not serve —
  # it scores a blue pair and a green pair of equal numeric distance the same
  # when the eye separates them very differently.
  #
  # THE FLOOR is 5.0: about twice the ~2.3 dE at which a trained observer first
  # sees two patches differ, which is the margin an untrained one glancing at a
  # moving canvas needs. At MAX_SPECIES = 12 the schemes measure psOpenColor
  # 24.8, psGolden 19.2, psSpectrum 18.4, psWarm 10.9, psCool 6.4 — the two
  # bounded arcs are what a further raise would break first, and widening
  # WARM_HUE_SPREAD / COOL_HUE_SPREAD is what would fix it.
  #
  # AT THE SHIPPED SATURATION AND LIGHTNESS. Saturation is a live control whose
  # range reaches down toward grey, and every hue collapses to one grey there;
  # what this pins is the palette the world starts from.

  const DISTINGUISHABLE_DELTA_E = 5.0

  proc srgbToLinear(channel: float): float =
    if channel <= 0.04045: channel / 12.92
    else: pow((channel + 0.055) / 1.055, 2.4)

  proc labOf(color: RgbColor): tuple[lightness, aStar, bStar: float] =
    ## sRGB (D65) to CIE L*a*b*, by the standard matrix and the CIE nonlinearity.
    let
      red = srgbToLinear(color.red)
      green = srgbToLinear(color.green)
      blue = srgbToLinear(color.blue)
      x = red * 0.4124564 + green * 0.3575761 + blue * 0.1804375
      y = red * 0.2126729 + green * 0.7151522 + blue * 0.0721750
      z = red * 0.0193339 + green * 0.1191920 + blue * 0.9503041
    proc nonlinear(ratio: float): float =
      if ratio > 216.0 / 24389.0: cbrt(ratio)
      else: (841.0 / 108.0) * ratio + 4.0 / 29.0
    let
      fx = nonlinear(x / 0.95047)
      fy = nonlinear(y / 1.00000)
      fz = nonlinear(z / 1.08883)
    (lightness: 116.0 * fy - 16.0, aStar: 500.0 * (fx - fy),
     bStar: 200.0 * (fy - fz))

  proc deltaE(left, right: RgbColor): float =
    let (l1, a1, b1) = labOf(left)
    let (l2, a2, b2) = labOf(right)
    sqrt((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2))

  test "every scheme separates all MAX_SPECIES colours above the visible floor":
    for scheme in PaletteScheme:
      let state = PaletteEditorState(scheme: scheme,
        saturation: DEFAULT_SATURATION, lightness: DEFAULT_LIGHTNESS)
      let colors = paletteFor(state)
      check colors.len == MAX_SPECIES
      for first in 0 ..< colors.len:
        for second in first + 1 ..< colors.len:
          checkpoint($scheme & " species " & $first & " vs " & $second)
          check deltaE(colors[first], colors[second]) >= DISTINGUISHABLE_DELTA_E

  test "the oracle scores two patches under the just-noticeable difference close":
    # Without this the floor could pass on an oracle that returns a large number
    # for everything. 0.5% of one channel is far below any threshold.
    check deltaE((red: 0.5, green: 0.5, blue: 0.5),
      (red: 0.505, green: 0.5, blue: 0.5)) < 2.3

suite "PaletteEditorState - Scheme Inertness":
  test "psOpenColor ignores saturation/lightness differences":
    let stateA = PaletteEditorState(scheme: psOpenColor, saturation: 0.1, lightness: 0.9)
    let stateB = PaletteEditorState(scheme: psOpenColor, saturation: 0.9, lightness: 0.1)
    check palettesEqual(paletteFor(stateA), paletteFor(stateB))

  test "psGolden differs under differing saturation/lightness":
    let stateA = PaletteEditorState(scheme: psGolden, saturation: 0.1, lightness: 0.9)
    let stateB = PaletteEditorState(scheme: psGolden, saturation: 0.9, lightness: 0.1)
    check not palettesEqual(paletteFor(stateA), paletteFor(stateB))

suite "PaletteEditorState - Scheme Id Round-Trip":
  test "parsePaletteScheme inverts schemeId for every scheme":
    for scheme in PaletteScheme:
      check parsePaletteScheme(schemeId(scheme)) == scheme

  test "an unknown id raises ValueError":
    expect ValueError:
      discard parsePaletteScheme("not-a-real-scheme")

suite "PaletteEditorState - Defaults":
  test "initPaletteEditorState defaults to psOpenColor":
    check initPaletteEditorState().scheme == psOpenColor

  test "default saturation/lightness match palette.nim's authoritative constants":
    let state = initPaletteEditorState()
    check approxEq(state.saturation, DEFAULT_SATURATION)
    check approxEq(state.lightness, DEFAULT_LIGHTNESS)

  test "default saturation/lightness fall within the config_ranges bounds":
    let state = initPaletteEditorState()
    check state.saturation >= PALETTE_SATURATION_MIN and
      state.saturation <= PALETTE_SATURATION_MAX
    check state.lightness >= PALETTE_LIGHTNESS_MIN and
      state.lightness <= PALETTE_LIGHTNESS_MAX

# Preset-loaded colors suspend the generated palette.
suite "PaletteEditorState - Custom Flag":
  test "the initial state is not custom":
    check initPaletteEditorState().isCustom == false

  test "withCustom marks the state custom":
    check initPaletteEditorState().withCustom().isCustom == true

  test "withScheme sets the scheme and clears the custom flag":
    let state = initPaletteEditorState().withCustom().withScheme(psGolden)
    check state.scheme == psGolden
    check state.isCustom == false

suite "PaletteEditorState - Channel Range":
  test "every channel of every scheme's palette lies within [0, 1]":
    for scheme in PaletteScheme:
      let state = PaletteEditorState(scheme: scheme, saturation: 0.7, lightness: 0.5)
      for color in paletteFor(state):
        check color.red >= 0.0 and color.red <= 1.0
        check color.green >= 0.0 and color.green <= 1.0
        check color.blue >= 0.0 and color.blue <= 1.0
