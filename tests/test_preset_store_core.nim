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
# INDEX OPERATIONS
# ==============================================================================

suite "preset index add/remove operations":
  test "addToIndex appends a new name to the end":
    check addToIndex(@["a", "b"], "c") == @["a", "b", "c"]

  test "addToIndex of a name already present returns the index unchanged":
    check addToIndex(@["a", "b"], "b") == @["a", "b"]

  test "addToIndex on an empty index starts a new one":
    check addToIndex(newSeq[string](), "a") == @["a"]

  test "removeFromIndex removes the named entry":
    check removeFromIndex(@["a", "b", "c"], "b") == @["a", "c"]

  test "removeFromIndex of a name not present returns the index unchanged":
    check removeFromIndex(@["a", "b"], "not-there") == @["a", "b"]

  test "add then remove of the same name is the identity":
    let original = @["a", "b"]
    check removeFromIndex(addToIndex(original, "c"), "c") == original

  test "a duplicate add is the identity":
    let original = @["a", "b"]
    check addToIndex(original, "b") == original

  test "removing an absent name is the identity":
    let original = @["a", "b"]
    check removeFromIndex(original, "not-there") == original

# ==============================================================================
# INDEX JSON ROUND-TRIP
# ==============================================================================

suite "preset index JSON round-trip":
  test "an empty index round-trips through indexToJson/parseIndexJson":
    let index: seq[string] = @[]
    check parseIndexJson(indexToJson(index)) == index

  test "names with spaces and embedded quotes round-trip exactly":
    let index = @["My Preset", "quote\"inside\"here", "another one", "trailing space "]
    check parseIndexJson(indexToJson(index)) == index

  test "a single-entry index round-trips":
    check parseIndexJson(indexToJson(@["only"])) == @["only"]

  test "malformed JSON text decodes to an empty seq rather than raising":
    check parseIndexJson("{not: valid json,,,") == newSeq[string]()

  test "empty string input decodes to an empty seq rather than raising":
    check parseIndexJson("") == newSeq[string]()

  test "a JSON object root (not an array) decodes to an empty seq":
    check parseIndexJson("""{"a": 1}""") == newSeq[string]()

  test "a JSON scalar root decodes to an empty seq":
    check parseIndexJson("\"just a string\"") == newSeq[string]()

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
# STORAGE KEY COMPOSITION
# ==============================================================================

suite "presetStorageKey composes the prefix constant with the name":
  test "presetStorageKey prefixes the name with PRESET_KEY_PREFIX":
    check presetStorageKey("My Preset") == PRESET_KEY_PREFIX & "My Preset"

  test "presetStorageKey of the empty name is just the prefix":
    check presetStorageKey("") == PRESET_KEY_PREFIX

  test "PRESET_INDEX_KEY is a distinct constant from the prefix alone":
    check PRESET_INDEX_KEY != PRESET_KEY_PREFIX
