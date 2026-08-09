# Unit tests for the palette editor's pure typed state in
# ui/state/palette_state.nim: determinism, scheme inertness (mirroring
# palette.nim's documented psOpenColor inertness both ways), scheme-id
# round-trip, defaults, and channel range invariants.

import std/unittest
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
