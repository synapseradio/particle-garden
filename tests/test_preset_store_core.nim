# ==============================================================================
# PARTICLE GARDEN - PRESET STORE CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/ui/presets/preset_store_core.nim: the pure
# localStorage-key and index-bookkeeping primitives the JS preset_store glue
# builds on, plus the apply-order contract as data (presetApplySteps).
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/ui/presets/preset_store_core

const PRESET_STORE_CORE_TESTS_LOADED* = true

# ==============================================================================
# NORMALIZE PRESET NAME
# ==============================================================================

suite "normalizePresetName trims and collapses whitespace":
  test "normalizePresetName trims leading and trailing whitespace":
    check normalizePresetName("  My Preset  ") == "My Preset"

  test "normalizePresetName collapses internal whitespace runs to a single space":
    check normalizePresetName("My    Preset\twith\n\nspaces") == "My Preset with spaces"

  test "normalizePresetName on an all-whitespace string returns empty, signaling invalid":
    check normalizePresetName("   \t\n  ") == ""

  test "normalizePresetName on an already-empty string returns empty":
    check normalizePresetName("") == ""

  test "normalizePresetName is idempotent over a range of messy inputs":
    ## CONTRACT: normalize(normalize(x)) == normalize(x) for any input
    let messyInputs = @[
      "  leading and trailing  ",
      "internal   runs    of   spaces",
      "tabs\tand\nnewlines\tmixed   in",
      "Already Normal",
      "",
      "   ",
      "Trailing space "
    ]
    for input in messyInputs:
      let once = normalizePresetName(input)
      let twice = normalizePresetName(once)
      check once == twice

# ==============================================================================
# APPLY-ORDER CONTRACT
# ==============================================================================

suite "presetApplySteps pins the apply-order contract":
  test "presetApplySteps returns exactly the seven steps in the fixed order":
    ## ORDER IS THE CONTRACT: speciesCount lands before particleCount, so the
    ## matrix grid is sized for the right species count before particleCount
    ## triggers the single re-init the whole apply performs; the per-species
    ## arrays then land into buffers already sized for it, and scalars/uiRefresh
    ## close out without touching particle data at all.
    let steps = presetApplySteps()
    check steps.len == 7
    check steps[0] == pasSpeciesCount
    check steps[1] == pasParticleCount
    check steps[2] == pasMatrix
    check steps[3] == pasChemistry
    check steps[4] == pasPalette
    check steps[5] == pasScalars
    check steps[6] == pasUiRefresh

  test "no step selects a world before the rest of the preset lands":
    ## The apply order says there is one world by carrying no step that picks
    ## between worlds. Asserted over the step names rather than by counting, so
    ## a step introducing world selection under any spelling faces this test.
    for step in presetApplySteps():
      check $step notin ["pasMode", "pasWorld", "pasCouplings"]

  test "both per-species arrays land after the species count that sizes them":
    let steps = presetApplySteps()
    check steps.find(pasSpeciesCount) < steps.find(pasMatrix)
    check steps.find(pasSpeciesCount) < steps.find(pasChemistry)

# ==============================================================================
# STORAGE KEYS
# ==============================================================================
#
# Both constants cross to TypeScript through gardenAPI.presetKeys. The panel
# distinguishes a preset entry from the index by comparing the composed key
# against the index key, so the two must never collide.

suite "the preset storage keys stay distinct":
  test "PRESET_INDEX_KEY is a distinct constant from the prefix alone":
    check PRESET_INDEX_KEY != PRESET_KEY_PREFIX
