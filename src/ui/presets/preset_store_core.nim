# ==============================================================================
# PARTICLE GARDEN - PRESET STORE CORE (Pure)
# ==============================================================================
#
# The localStorage key constants and the preset name normalizer the panel
# reaches through gardenAPI, plus the preset-apply order as data — mirroring
# sim_registry's buildFrame idea: the sequence a preset applies in is a value
# tests can pin directly, not an implicit order buried in a proc body.
#
# The index bookkeeping built on these keys lives in TypeScript
# (web-ui/src/lib/presets.ts), which owns localStorage I/O.
#
# Pure module: no FFI, no DOM, std/strutils only. Compiles on both the
# native (just test) and JS backends.
#
# ==============================================================================

import std/strutils

# ==============================================================================
# SECTION 1: STORAGE KEYS
# ==============================================================================

const PRESET_KEY_PREFIX* = "pg.presets."
  ## Prefix for a single saved preset's localStorage key. See presetStorageKey.

const PRESET_INDEX_KEY* = "pg.presets.index"
  ## The localStorage key holding the JSON array of saved preset names.

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
# SECTION 3: APPLY-ORDER CONTRACT
# ==============================================================================
#
# The order a preset's fields must land in, as data. Mirrors sim_registry's
# buildFrame: the sequence is a value a test can pin directly, not an
# implicit order buried in a proc body. ORDER IS THE CONTRACT — speciesCount
# applies before the per-species arrays (matrix and chemistry are sized by it),
# and speciesCount before particleCount (particleCount is the one step that
# triggers a re-init; the matrix grid must already be sized for the target
# species count when that re-init happens, or newly-exposed cells render
# against stale species indices for one frame).

type
  PresetApplyStep* = enum
    pasSpeciesCount   ## setSpeciesCount(n, randomizeNew = false) — no re-init.
    pasParticleCount  ## Write particleCount, then trigger the one re-init.
    pasMatrix         ## Write every attraction-matrix float.
    pasChemistry      ## Write the per-species (secretion, tropism) pairs.
    pasPalette        ## Write the literal species colors into COLORS.
    pasScalars        ## Remaining settings: friction, forceModel, trails, etc.
    pasUiRefresh      ## Refresh slider DOM, matrix legend, button active-states.

func presetApplySteps*(): seq[PresetApplyStep] =
  ## The fixed apply order, as data. See the type's doc comment for why each
  ## step must precede the next.
  ##
  ## No step selects a world, because there is one: a preset's coupling
  ## strengths are ordinary scalars and land with the rest under `pasScalars`.
  @[pasSpeciesCount, pasParticleCount, pasMatrix, pasChemistry, pasPalette,
    pasScalars, pasUiRefresh]
