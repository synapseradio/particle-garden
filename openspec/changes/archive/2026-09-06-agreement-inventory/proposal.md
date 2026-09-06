# agreement-inventory

## Why

Article 3 of `docs/engineering-principles.md` (lines 29-36) requires that where two
representations of one thing must match, either one generates the other or an automated check
fails the build on divergence. The tree honors that in several places and has no record of where
it does not. Three facts are stated twice today with nothing binding the copies at build time,
and no artifact names them, so each is found only by someone reading both sites.

The cost is measurable on the species ceiling. It was widened from 6 to 8 and from 8 to 12
(`src/preset.nim:545,551` carry the two historical strides). `src/ui/state/matrix_state.nim:23`
holds `MATRIX_SIZE = 12` as an independent copy of `src/memory_layout.nim:38`'s
`MAX_SPECIES = 12`. A native test relates them (`tests/test_memory_layout.nim:93-98`), so a
widening that edits one and not the other compiles green and fails only when the suite runs. That
same widening left `tests/test_preset.nim:557` named `"speciesCount clamps into [2, 8]"` while its
assertions check `SPECIES_COUNT_MIN` and `SPECIES_COUNT_MAX`, which resolve to 2 and 12
(`src/config_ranges.nim:29,32`).

The proposed `midi-interface` change introduces a control matrix spanning Nim and TypeScript. It
adds a fourth cross-language agreement to a tree that has no inventory of the three it already
carries.

## What Changes

- **An inventory of two-sided agreements**, as a typed table in `src/agreements.nim`. Each entry
  names the fact, its sites, the tier that holds it, and why it does not sit on a stronger tier.
  The tiers already exist in the tree under three different spellings: derived
  (`src/config_ranges.nim:32`), build-asserted (`src/preset.nim:189`), and test-held
  (`tests/test_memory_layout.nim:93`).
- **Meta-gates over the inventory in both directions**, in `tests/test_agreements.nim`. A site
  whose anchor text has gone fails the suite, so an entry cannot outlive the agreement it records.
  An entry with fewer than two sites fails, so an agreement is two-sided by construction. A cited
  holder that does not exist fails, so a tier cannot be claimed without its gate. A companion
  suite proves each predicate goes red, following `tests/test_help_content.nim:65-73`.
- **A derived detector for one enumerable class**: every key `getPlaceholderMap` emits
  (`src/shader_config.nim:235`) SHALL be consumed by a shader source. The bundler already
  fails on the reverse, an unresolved `{{...}}` (`tools/wgsl_bundle.nim:122-127`). Nothing sees an
  emitted key no shader reads. Measured against the tree today, exactly one key is unconsumed:
  `TUNABLE_BLAST_RANGE_SQ`.
- **The species ceiling becomes derived.** `MATRIX_SIZE` goes; `matrix_state.nim` reads
  `SPECIES_COUNT_MAX`, already in scope through its existing `import ../../config_ranges`
  (`src/ui/state/matrix_state.nim:12`). The drift test at `tests/test_memory_layout.nim:93-98` and
  the comment at `src/memory_layout.nim:190-195` both state an absence the fix removes, and both
  are updated in the same change.
- **The blast radius becomes derived.** `web/shaders/src/forces.wgsl:364` spells the radius as
  `40000.0` and `:367` spells it again as `200.0`, against `src/shader_config.nim:100`'s
  `blastRangeSq: 40000.0`. `getPlaceholderMap` emits `TUNABLE_BLAST_RANGE_SQ`
  (`src/shader_config.nim:304`) and no shader consumes it. The emitter gains
  `TUNABLE_BLAST_RANGE`, the square root of the same field, following the
  `FIXED_POINT_SCALE`/`INV_FIXED_POINT_SCALE` pair at `src/shader_config.nim:306-312`. Both
  literals leave the shader text.
- **Grid dimensions become derived.** `src/grid.nim:40-45` computes cell size and grid extent
  independently of `computeGridDims` in `src/grid_core.nim:22-52`. `grid.nim` calls the oracle
  instead. `src/grid_core.nim:9-13` states that nothing in `src/` imports it, which the fix makes
  false, and that header is updated with it.
- **A stale test name loses its literals.** `tests/test_preset.nim:557` is renamed so it names the
  range by its constants, since a test name restating a range is another copy of that range.
- **`docs/agreements.md`** explains how the inventory works, how to add an entry, and which
  classes of agreement it deliberately does not cover because another mechanism owns them. It
  names no entries, because a document listing entries would be a second copy of the table.

No user-visible behavior is removed. The three derivations preserve the shipped values exactly:
`MAX_SPECIES` is 12 on both sides, `sqrt(40000.0)` is 200.0, and `jsFloor(a / b)` equals `a div b`
for the positive whole-number operands `WORLD_W` and `WORLD_H` carry (`src/config.nim:115-116`).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `native-test-strategy`: adds the inventory and its meta-gates as requirements, and extends the
  existing "A shader value the bundler can substitute MUST NOT be duplicated in WGSL" requirement
  (`openspec/specs/native-test-strategy/spec.md:89-117`) with the reverse direction, an emitted
  key no shader consumes.

The delta goes into this capability because its Purpose
already claims the territory: it owns "what the project tests, what it deliberately leaves
untested, and which mechanism carries each decision"
(`openspec/specs/native-test-strategy/spec.md:6-7`). Its "Divergence between a mirrored expression
and its shader is review-enforced" requirement (`:118-138`) is the inventory's ancestor, recording
one class of unheld agreement in prose. `build-pipeline` owns stage order and embed edges
(`openspec/specs/build-pipeline/spec.md:6-10`), and every gate this change adds is a native test,
so nothing lands there. A separate `agreement-inventory` capability would have to restate
`native-test-strategy`'s ownership sentence, creating exactly the two-sided agreement this change
exists to remove.

## Impact

New files: `src/agreements.nim`, `tests/test_agreements.nim`, `docs/agreements.md`.

Edited: `src/ui/state/matrix_state.nim`, `src/web_api.nim` (line 1274), `src/memory_layout.nim`
(the comment at 185-195), `src/shader_config.nim` (the placeholder map),
`web/shaders/src/forces.wgsl`, `src/grid.nim`, `src/grid_core.nim` (header),
`tests/test_memory_layout.nim`, `tests/test_matrix.nim`, `tests/test_preset.nim` (one test name),
`tests/test_all.nim` (registration).

`web/shaders/forces.wgsl` is bundled output and is regenerated, never edited
(`justfile:22-24`).

### Found and left out of scope

Each is recorded in the inventory as it stands. None is fixed here.

- `src/preset.nim:87` holds `CHEMISTRY_STRIDE = 2` against `src/field_core.nim:418`'s
  `SPECIES_CHEMISTRY_STRIDE = 2`. Nothing relates them: `src/preset.nim:36-38` imports neither
  `field_core` nor `config`, and no test in `tests/` compares the two. `src/preset.nim:88-90`
  states the reason for the copy, that `preset` stays a leaf the storage and UI layers can build
  on. The entry lands in the inventory as unenforced with that reason. Closing it is separate
  work.
- `src/preset.nim:78` holds a third copy of the species ceiling, `MAX_SPECIES = 12`, bound by
  `doAssert MAX_SPECIES == SPECIES_COUNT_MAX` at `src/preset.nim:189`. It survives this change as
  a build-asserted entry, for the leaf reason above.
- Test names that restate range literals. `tests/test_preset.nim:563` reads
  `"friction clamps into [0.01, 0.2]"` while asserting `FRICTION_MIN` and `FRICTION_MAX`, the same
  class as the stale name this change repairs. A sweep of the suite for the class, and a detector
  that parses a bracketed range out of a test name and compares it to the constants the body
  asserts, is separate work.
