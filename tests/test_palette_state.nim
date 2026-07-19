# ==============================================================================
# PARTICLE GARDEN - PALETTE EDITOR STATE TESTS
# ==============================================================================
#
# Unit tests for the palette editor's pure typed state in
# ui/state/palette_state.nim: determinism, scheme inertness (mirroring
# palette.nim's documented psOpenColor inertness both ways), scheme-id
# round-trip, defaults, and channel range invariants.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/ui/state/palette_state
import ../src/config_ranges

# Exported symbol for test_all.nim to reference
const PALETTE_STATE_TESTS_LOADED* = true

const
  EPSILON = 1e-9

proc approxEq(left, right: float; epsilon: float = EPSILON): bool =
  ## Epsilon-based float comparison for testing.
  abs(left - right) <= epsilon

proc palettesEqual(left, right: seq[RgbColor]): bool =
  ## Element-wise epsilon comparison of two palettes.
  if left.len != right.len:
    return false
  for colorIndex in 0 ..< left.len:
    if not approxEq(left[colorIndex].red, right[colorIndex].red) or
       not approxEq(left[colorIndex].green, right[colorIndex].green) or
       not approxEq(left[colorIndex].blue, right[colorIndex].blue):
      return false
  true

# ==============================================================================
# DETERMINISM
# ==============================================================================

suite "PaletteEditorState - Determinism":
  test "equal states produce element-wise equal palettes":
    let stateA = PaletteEditorState(scheme: psGolden, saturation: 0.6, lightness: 0.4)
    let stateB = PaletteEditorState(scheme: psGolden, saturation: 0.6, lightness: 0.4)
    check palettesEqual(paletteFor(stateA), paletteFor(stateB))

# ==============================================================================
# LENGTH INVARIANT
# ==============================================================================

suite "PaletteEditorState - Length Invariant":
  test "paletteFor returns MAX_SPECIES colors for every scheme":
    for scheme in PaletteScheme:
      let state = PaletteEditorState(scheme: scheme, saturation: 0.7, lightness: 0.5)
      check paletteFor(state).len == MAX_SPECIES

# ==============================================================================
# SCHEME INERTNESS (psOpenColor ignores saturation/lightness; others don't)
# ==============================================================================

suite "PaletteEditorState - Scheme Inertness":
  test "psOpenColor ignores saturation/lightness differences":
    let stateA = PaletteEditorState(scheme: psOpenColor, saturation: 0.1, lightness: 0.9)
    let stateB = PaletteEditorState(scheme: psOpenColor, saturation: 0.9, lightness: 0.1)
    check palettesEqual(paletteFor(stateA), paletteFor(stateB))

  test "psGolden differs under differing saturation/lightness":
    let stateA = PaletteEditorState(scheme: psGolden, saturation: 0.1, lightness: 0.9)
    let stateB = PaletteEditorState(scheme: psGolden, saturation: 0.9, lightness: 0.1)
    check not palettesEqual(paletteFor(stateA), paletteFor(stateB))

# ==============================================================================
# SCHEME ID ROUND-TRIP
# ==============================================================================

suite "PaletteEditorState - Scheme Id Round-Trip":
  test "parsePaletteScheme inverts schemeId for every scheme":
    for scheme in PaletteScheme:
      check parsePaletteScheme(schemeId(scheme)) == scheme

  test "an unknown id raises ValueError":
    expect ValueError:
      discard parsePaletteScheme("not-a-real-scheme")

# ==============================================================================
# DEFAULTS
# ==============================================================================

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

# ==============================================================================
# CHANNEL RANGE
# ==============================================================================

suite "PaletteEditorState - Channel Range":
  test "every channel of every scheme's palette lies within [0, 1]":
    for scheme in PaletteScheme:
      let state = PaletteEditorState(scheme: scheme, saturation: 0.7, lightness: 0.5)
      for color in paletteFor(state):
        check color.red >= 0.0 and color.red <= 1.0
        check color.green >= 0.0 and color.green <= 1.0
        check color.blue >= 0.0 and color.blue <= 1.0
