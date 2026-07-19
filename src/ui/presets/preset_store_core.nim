# ==============================================================================
# PARTICLE GARDEN - PRESET STORE CORE (Pure)
# ==============================================================================
#
# The pure localStorage-key and index-bookkeeping primitives the JS
# preset_store glue (src/ui/presets/preset_store.nim, when defined(js)) is
# built on, plus the preset-apply order as data — mirroring sim_registry's
# buildFrame idea: the sequence a preset applies in is a value tests can pin
# directly, not an implicit order buried in a proc body.
#
# Pure module: no FFI, no DOM, std/json and std/strutils only. Compiles on
# both the native (nimble test) and JS backends.
#
# ==============================================================================

import std/json
import std/strutils

# ==============================================================================
# SECTION 1: STORAGE KEYS
# ==============================================================================

const PRESET_KEY_PREFIX* = "pg.presets."
  ## Prefix for a single saved preset's localStorage key. See presetStorageKey.

const PRESET_INDEX_KEY* = "pg.presets.index"
  ## The localStorage key holding the JSON array of saved preset names.

func presetStorageKey*(name: string): string =
  ## The localStorage key a preset named `name` is stored under.
  PRESET_KEY_PREFIX & name

# ==============================================================================
# SECTION 2: PRESET NAME NORMALIZATION
# ==============================================================================

func normalizePresetName*(raw: string): string =
  ## Trim outer whitespace and collapse internal whitespace runs to a single
  ## space. Idempotent: normalizePresetName(normalizePresetName(x)) ==
  ## normalizePresetName(x). An all-whitespace (or empty) input normalizes
  ## to "", which the caller treats as an invalid name and rejects.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return ""
  result = newStringOfCap(trimmed.len)
  var previousWasSpace = false
  for character in trimmed:
    if character in Whitespace:
      if not previousWasSpace:
        result.add(' ')
      previousWasSpace = true
    else:
      result.add(character)
      previousWasSpace = false

# ==============================================================================
# SECTION 3: PRESET NAME INDEX
# ==============================================================================
#
# The index is the list of saved preset names, persisted separately (under
# PRESET_INDEX_KEY) from the presets themselves so the preset list can
# populate without reading every individual preset's JSON.

func addToIndex*(index: seq[string]; name: string): seq[string] =
  ## Append `name` if absent. A duplicate add returns the index unchanged.
  if name in index:
    index
  else:
    index & @[name]

func removeFromIndex*(index: seq[string]; name: string): seq[string] =
  ## Drop `name` from the index. Removing an absent name returns the index
  ## unchanged (by value).
  result = newSeq[string]()
  for entry in index:
    if entry != name:
      result.add(entry)

proc indexToJson*(index: seq[string]): string =
  ## Serialize the index to a JSON array of strings.
  var arrayNode = newJArray()
  for name in index:
    arrayNode.add(%name)
  $arrayNode

proc parseIndexJson*(text: string): seq[string] =
  ## Parse a JSON array of strings back into an index. Malformed JSON, a
  ## non-array root, or a non-string element degrades to an empty seq
  ## rather than raising — a corrupted or hand-edited index value must
  ## never crash the preset list, only appear empty.
  var node: JsonNode
  try:
    node = parseJson(text)
  except ValueError:
    return newSeq[string]()
  if node.kind != JArray:
    return newSeq[string]()
  result = newSeq[string]()
  for element in node.getElems():
    if element.kind != JString:
      return newSeq[string]()
    result.add(element.getStr())

# ==============================================================================
# SECTION 4: APPLY-ORDER CONTRACT
# ==============================================================================
#
# The order a preset's fields must land in, as data. Mirrors sim_registry's
# buildFrame: the sequence is a value a test can pin directly, not an
# implicit order buried in a proc body. ORDER IS THE CONTRACT — mode must
# apply before speciesCount (the species count a mode allows may differ),
# and speciesCount before particleCount (particleCount is the one step that
# triggers a re-init; the matrix grid must already be sized for the target
# species count when that re-init happens, or newly-exposed cells render
# against stale species indices for one frame).

type
  PresetApplyStep* = enum
    pasMode           ## Switch simulation mode (parseSimKind + setSimMode path).
    pasSpeciesCount   ## setSpeciesCount(n, randomizeNew = false) — no re-init.
    pasParticleCount  ## Write particleCount, then trigger the one re-init.
    pasMatrix         ## Write all 36 attraction-matrix floats.
    pasPalette        ## Write the 6 literal species colors into COLORS.
    pasScalars        ## Remaining settings: friction, forceModel, trails, etc.
    pasUiRefresh      ## Refresh slider DOM, matrix legend, button active-states.

func presetApplySteps*(): seq[PresetApplyStep] =
  ## The fixed apply order, as data. See the type's doc comment for why each
  ## step must precede the next.
  @[pasMode, pasSpeciesCount, pasParticleCount, pasMatrix, pasPalette,
    pasScalars, pasUiRefresh]
