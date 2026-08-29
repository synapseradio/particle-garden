# Refresh the gardenapi-boundary spec after the one-world refactor

## Why

Four passages in `openspec/specs/gardenapi-boundary/spec.md` describe machinery the one-world
refactor removed or replaced, so the spec contradicts the code and the delta specs the open
interface changes wrote against the current boundary. `tests/test_no_modes.nim` exists to guard
the absence of the very mode machinery one requirement still mandates.

## What Changes

- The parameter-dispatch requirement states the generated field-name walk and its compile-time
  gate. The spec's claim that the dispatch is a hand-written case where "no build step or test
  detects a missing arm" no longer holds: a static probe walks the descriptor table and fails the
  build naming the offending descriptor (`src/web_api.nim:530-583`), and a native suite holds every
  routed id to a field of its store's record (`tests/test_param_descriptor.nim:370`).
- The served-catalog requirement swaps the simulation-mode catalog, which no longer exists, for
  the named reaction-diffusion regime catalog (`src/web_api.nim:644-656`, served at lines
  1200-1202) and drops the per-mode control-groups sentence, since `sim_registry.nim` carries no
  `controlGroupsFor`.
- The preset requirement snapshots the species chemistry in place of an "active mode"
  (`src/web_api.nim:864-865`), and its apply-order scenario lists the steps
  `presetApplySteps()` actually returns (`src/ui/presets/preset_store_core.nim:76-83`).
- The requirement "Mode ceilings clamp the particle count" is removed: `setSimMode`,
  `particleCeiling`, and the two ceiling constants appear nowhere under `src/`. Its one surviving
  behavior, the commit side effect on the count parameters, becomes its own requirement, corrected
  to what the code does: committing `particleCount` resizes the population in place, and committing
  `speciesCount` re-initializes (`src/web_api.nim:767-780`).

No source code changes. The spec text moves; the behavior it describes already shipped.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `gardenapi-boundary`: the dispatch, served-catalog, and preset requirements restate the current
  mechanism, the mode-ceiling requirement is removed, and a commit side-effect requirement replaces
  its surviving tail.

## Impact

- `openspec/specs/gardenapi-boundary/spec.md` at archive time. No `src/`, `web-ui/`, or test edits.
- The open `midi-interface` and `audio-interface` changes touch the same capability on different
  requirement headers, so no archive-order constraint arises among the three.
