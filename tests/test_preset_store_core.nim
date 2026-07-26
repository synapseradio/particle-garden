# ==============================================================================
# PARTICLE GARDEN - PRESET STORE CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/ui/presets/preset_store_core.nim: the pure
# localStorage-key and index-bookkeeping primitives the JS preset_store glue
# builds on, plus the apply-order contract as data (presetApplySteps).
#
# Run with: nimble test
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
    ## ORDER IS THE CONTRACT: mode must land before speciesCount, and
    ## speciesCount before particleCount, so the matrix grid is sized for
    ## the right species count before particleCount triggers the single
    ## re-init the whole apply performs; matrix/palette then land into
    ## buffers already sized for the new mode/species, and scalars/uiRefresh
    ## close out without touching particle data at all.
    let steps = presetApplySteps()
    check steps.len == 7
    check steps[0] == pasMode
    check steps[1] == pasSpeciesCount
    check steps[2] == pasParticleCount
    check steps[3] == pasMatrix
    check steps[4] == pasPalette
    check steps[5] == pasScalars
    check steps[6] == pasUiRefresh

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
