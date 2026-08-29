# Design

## Context

See proposal.md, "Why", for the motivation.

The design question this change turns on: an inventory whose entries are hand-listed is itself an
agreement nobody holds, which is the failure mode it exists to fix. Every decision below answers
one part of that. Which entries can be derived instead of declared? What can a meta-gate actually
detect? Where does the inventory fall back to a declared entry, and what does that entry have to
carry to be worth writing?

Three facts about the tree bound the answers.

**The tree already holds agreements at three different strengths, and knows all three.**
`src/config_ranges.nim:32` writes `SPECIES_COUNT_MAX* = memory_layout.MAX_SPECIES`, so there is no
second copy to diverge. `src/preset.nim:189` writes `doAssert MAX_SPECIES == SPECIES_COUNT_MAX`
inside a `static:` block, so a disagreement fails compilation. `tests/test_memory_layout.nim:93-98`
writes `check MAX_SPECIES == MATRIX_SIZE`, so a disagreement fails the suite and not the build.
All three describe one number, the species ceiling. The tiers come from the tree.

**Bidirectional coverage between a document tree and a code registry already ships.**
`tests/test_help_content.nim` holds four relations between `docs/help/` and the descriptor table
(`:41-63`), guards the directory listing against the declared file list (`:29-36`), and carries a
suite named "The Coverage Sweep Can Fail" (`:65-73`) that exercises the predicates against a bogus
id and malformed front matter. `tests/test_meta_vacuity.nim:91-105` requires every
filesystem-reading test to assert something beyond an absence. `tests/test_no_modes.nim:104-107`
sweeps `src/` and `web-ui/src/` and asserts the roots were found. The mechanism this change needs
has a working precedent in each of its parts.

**One class of agreement is enumerable from the code with no declaration at all.**
`getPlaceholderMap` returns a table (`src/shader_config.nim:235`) and the shader sources
under `web/shaders/src/` and `web/shaders/modules/` contain `{{KEY}}` occurrences. Comparing the
two sets needs nothing written down. The bundler already fails on a shader key the map does not
emit (`tools/wgsl_bundle.nim:122-127`). The reverse has no gate.

## Goals / Non-Goals

**Goals:**

- Record every two-sided agreement this change touches or finds, with the tier that holds it and
  the reason it is not on a stronger tier.
- Make a stale entry fail the suite, so collapsing an agreement forces its entry out.
- Derive wherever a class of agreement can be enumerated from the code, and declare only what no
  enumeration reaches.
- Move each of the three named duplications to the derived tier, since derivation is available for
  all three at no structural cost.

**Non-Goals:**

- Detecting an agreement nobody wrote down. No gate here does that, and the specs label the
  residue unenforced with what would close it.
- Covering classes another mechanism owns: shader binding placement (`src/wgsl_lint.nim`), GPU
  struct offsets (`src/gpu_types.nim`), oracle-to-shader mirrors (the table in `CLAUDE.md`, labelled
  review-enforced at `openspec/specs/native-test-strategy/spec.md:118-138`). `docs/agreements.md`
  names where each is owned and restates none of them.
- Sweeping the tree for further duplications. Three found during this work are named in
  proposal.md under "Found and left out of scope" and recorded in the inventory as they stand.

## Decisions

### The inventory is a typed table in `src/agreements.nim`, and the document names no entries

`docs/agreements.md` explains the mechanism, the tiers, and how to add an entry. The entries live
only in `src/agreements.nim`, as a `const` sequence of records the compiler type-checks and
`tests/test_agreements.nim` reads.

*Why:* a markdown table of entries and a code table of entries would be two copies of one list,
which is this change's own defect. One list, in the language that can hold a record type, read by
the gate.

*Rejected:* the entries as a markdown table in `docs/agreements.md`, parsed by the test. It puts
the inventory in a format with no type to check, and the parse becomes another agreement between
a column order and a reader.

*Rejected:* placing the table in `tests/`. `CLAUDE.md`'s "Where authority lives" section names
`src/` modules as the homes of facts, and the tiers and reasons an entry carries are facts about
the source, which the suite only reads. `src/agreements.nim` has no importer in `src/`, matching the
established pattern for pure modules that exist to be tested (`src/grid_core.nim:9-13`,
`src/physics_core.nim`). Its consumer is `tests/test_agreements.nim`, which satisfies article 6.

### A site is a path plus an anchor string, never a line number

Each site records the file path and a literal substring that must occur in that file, taken from
the text the agreement is made of: `MATRIX_SIZE* = 12`, `blastRangeSq: 40000.0`,
`const CHEMISTRY_STRIDE* = 2`.

*Why:* this is what makes an entry self-retiring. Collapse the duplication and the anchor text
goes, so the gate reports the entry as stale and the entry is deleted with the fix. The inventory
cannot name an agreement that has gone. It also survives every edit that does not touch the
agreement, which a line number does not.

*Proven:* every anchor named in tasks.md was read out of the file it cites during this change's
research. The gate's behavior on a stale anchor is designed and unexercised until the can-fail
suite runs it.

*Rejected:* line numbers. `src/memory_layout.nim:190-195` already carries a prose reference to
`matrix_state.MATRIX_SIZE` with no line, and every line number in a comment in this tree is one
edit away from pointing at the wrong thing.

*Rejected:* marker comments at each site, such as `# @agreement:species-ceiling`, swept out of the
tree. Markers buy a direction anchors lack, a marker naming no entry, but they do not close the
gap that matters: an unmarked new duplication stays invisible either way. They cost a comment at
every site, against `CLAUDE.md`'s rule that a comment states only what the code cannot show, and
they require editing files this change otherwise does not touch.

### Each entry carries its tier and why it is not on a stronger one

The tier is an enum over what the tree does:

- `Derived`, where one site computes from the other and no second copy exists.
- `BuildAsserted`, where a `static:` block or `doAssert` fails compilation on disagreement.
- `TestHeld`, where a native test relates the sites and the build does not.
- `AgentCheckable`, where no automated gate exists and a named procedure detects a violation.
- `Unenforced`, where nothing detects a violation.

`Derived` entries need no `whyNotStronger`, since nothing is stronger. Every other tier carries
one, and `Unenforced` additionally carries `wouldClose`, naming what would detect a violation.

*Why:* recording that two copies exist says nothing a reader could act on. Recording why the pair
is not derived separates a deliberate copy from an oversight. `src/preset.nim:79-83` gives the
deliberate case in prose: `preset` carries no dependency on `memory_layout` or any other `src/`
module, to stay a leaf the storage and UI layers can build on. `src/ui/state/matrix_state.nim:23`
gives the oversight case, a bare `MATRIX_SIZE* = 12` with the comment "Maximum species count" and
no reason for its independence.

*Rejected:* a flat list of duplications with no tier. It cannot distinguish the two cases above,
so every reading of it re-derives the reasoning from the source.

*Rejected:* a boolean, enforced or not. The species ceiling alone occupies three of the five tiers
today, and collapsing them loses the information that a test-held pair fails later than a
build-asserted one.

### Six meta-gates, each naming what it detects

In `tests/test_agreements.nim`, over the table in `src/agreements.nim`:

1. Every site's path exists on disk. Detects a file renamed or deleted out from under an entry.
2. Every site's anchor occurs in that file. Detects a stale entry, the strongest of the six, and
   the one that makes a collapse self-reporting.
3. Every entry has at least two sites. An agreement is two-sided by construction, so a one-site
   entry records a note about one place.
4. Every entry above `Unenforced` cites a holder whose file exists and contains the cited text:
   the assertion's own text for `BuildAsserted`, the test's name for `TestHeld`. Detects a tier
   claimed without its gate, including a gate deleted while the entry stayed.
5. Every `Unenforced` entry has a non-empty `wouldClose`, and every entry below `Derived` has a
   non-empty `whyNotStronger`. Required by the specs rule that an unenforced label says what would
   close it.
6. The table is non-empty and every path it names resolves from the suite's working directory.
   Required by `tests/test_meta_vacuity.nim:91-105`, and matching the directory-found assertion at
   `tests/test_no_modes.nim:104-107`, so a run from the wrong directory fails loudly instead of
   passing on an empty sweep.

A companion suite, "The Inventory Gate Can Fail", runs the same predicate functions against
constructed inputs: an entry with a nonexistent path, an entry whose anchor is absent, an entry
with one site, a `BuildAsserted` entry citing text no file contains, an `Unenforced` entry with an
empty `wouldClose`. Article 4 of `docs/engineering-principles.md:38-45` requires a gate be watched
failing before its green counts, and `tests/test_help_content.nim:65-73` is the pattern.

*Why the predicates are separate functions:* the can-fail suite and the real gate must exercise the
same code, or the can-fail suite proves nothing about the gate.

*Rejected:* asserting the inventory covers every duplication in the tree. Nothing can compute that
set. Claiming it would be the vacuous gate article 4 forbids.

### The one derived detector: every emitted placeholder is consumed

A native test enumerates `getPlaceholderMap()`'s keys and the `{{KEY}}` occurrences across
`web/shaders/src/*.wgsl` and `web/shaders/modules/*.wgsl`, and fails on a key no shader reads. The
workgroup family is consumed through the per-shader rewrite at `tools/wgsl_bundle.nim:114-117`,
which replaces `{{WORKGROUP_SIZE}}` with the value under the key named for that shader, so such a
key counts as consumed when the shader it names exists under `web/shaders/src/`
and contains `{{WORKGROUP_SIZE}}`. Keys the shaders read literally, including
`WORKGROUP_SIZE_FIELD_X` and `WORKGROUP_SIZE_FIELD_Y` at `web/shaders/src/rd-step.wgsl:69`, are
covered by the literal comparison.

*Proven:* running exactly this comparison over the tree returns one unconsumed key,
`TUNABLE_BLAST_RANGE_SQ`. Every other emitted key is consumed by a shader source, literally or
through the workgroup rewrite. The detector's subject is enumerated from the code, so it needs no
inventory entry and cannot go stale.

*Why this matters to the central question:* where a class of agreement can be enumerated, a
detector beats a declaration outright. It covers members nobody thought to list, it costs no entry
per member, and it cannot record an agreement that has gone. Sixty-four placeholder pairs are
covered by one test and zero entries. The declared entry is the fallback for a pair no enumeration
reaches.

*Rejected:* one inventory entry per placeholder. Sixty-four entries, all derivable, all stale the
moment a constant is renamed.

*Rejected:* a general duplicate-literal detector over the tree. `40000.0` appearing twice is an
agreement; `0` appearing a thousand times is not, and no threshold separates them without reading
intent. The false-positive rate makes it a gate people learn to silence.

### `matrix_state` derives the ceiling, and the test that held it is deleted

`src/ui/state/matrix_state.nim:12` already imports `../../config_ranges`, which exports
`SPECIES_COUNT_MAX* = memory_layout.MAX_SPECIES` (`src/config_ranges.nim:32`). The name is in scope
now. `MATRIX_SIZE` is deleted and its four uses (`:28`, `:31`, `:36`, plus
`src/web_api.nim:1274`) read `SPECIES_COUNT_MAX`; `src/web_api.nim:53` imports `config_ranges`
already, and `tests/test_matrix.nim:2` does too.

No cycle blocks this. The cycle `src/memory_layout.nim:193-195` names runs the other way: importing
`matrix_state` **from** `memory_layout` would close the loop
`matrix_state -> config_ranges -> memory_layout`. Importing in the direction of that arrow is what
already happens.

`tests/test_memory_layout.nim:93-98` and the comment at `src/memory_layout.nim:185-195` both state
that nothing forces the two to move together. The fix makes both false, and both go in the same
diff: the test is deleted, and the comment loses its sentences about the live copy at
`matrix_state` and about the assertion living in the test.

*Rejected:* promoting the test to a `doAssert` beside one of the definitions. It moves the failure
from suite time to build time and leaves two copies standing. Article 2 of
`docs/engineering-principles.md:21-27` reads: "Two copies held equal by an assertion are still two
copies", and calls for collapsing them. Derivation costs one import that is already there, so the stronger tier
is free here in a way it is not for `src/preset.nim:78`, where the leaf constraint at
`src/preset.nim:79-83` pays for the assertion.

*Rejected:* keeping the name as `const MATRIX_SIZE* = SPECIES_COUNT_MAX`. An alias is one home, so
it satisfies article 2, and it leaves two names for one number across the boundary where
`matrixStride` is served (`src/web_api.nim:1274`). The API name stays `matrixStride`, and the Nim
name does not need a third spelling.

### The blast radius is emitted twice from one field, and the shader reads both

`src/shader_config.nim` keeps `blastRangeSq` as the stored value (`:45` declares it, `:100` sets
it to `40000.0`) and emits two placeholders from it: `TUNABLE_BLAST_RANGE_SQ`, which already exists
at `:304`, and `TUNABLE_BLAST_RANGE`, its square root. `web/shaders/src/forces.wgsl` declares both
as module-level consts beside `MIN_DISTANCE_SQ` at `:51` and reads them at `:364` and `:367`.

This is the pattern `src/shader_config.nim:306-312` already uses and documents for
`FIXED_POINT_SCALE` and its reciprocal: "Deriving it here is what keeps the pair consistent: a
hand-written inverse can drift from the scale it is supposed to invert."

*Rejected:* renaming the field to `blastRange` and deriving the square. It reads better in
isolation and it breaks step with `mouseRangeSq` (`src/shader_config.nim:40-45`), which stores the
square for a documented reason, and it changes the key set `getTunableFloat` answers
(`src/shader_config.nim:161`). The gain is a name. The cost is a second edit with no gate behind
it.

*Rejected:* leaving `200.0` in the shader and emitting only the square. That is the agreement, not
a fix for it.

### `grid.nim` calls the oracle, and the failing test is structural

`src/grid.nim:40-45` is replaced by a call to `grid_core.computeGridDims`. `src/grid_core.nim`
imports only `memory_layout`, which is written to compile under `nim js`
(`src/memory_layout.nim:30-32`), so the JS-backend compilation unit `src/grid.nim` belongs to
(`src/grid.nim:7`) can reach it.

The arithmetic is preserved. `src/grid.nim:42-43` computes `jsFloor(WORLD_W / cellSize)` on floats
where `src/grid_core.nim:39-40` computes `canvasW div cellSize` on ints, and the two agree for
positive operands. `WORLD_W` and `WORLD_H` are whole-number floats, 3840.0 and 2160.0
(`src/config.nim:115-116`). `src/grid.nim:44-45` clamps with `jsMax(1.0, jsMin(x, MAX_GRID))` where
`src/grid_core.nim:42-50` clamps with an if/elif chain, and both yield `min(max(x, 1), MAX_GRID)`.
`MAX_GRID` is 256 on both sides, since `src/grid_core.nim:20` re-exports
`src/memory_layout.nim:41`.

The native suite cannot import `src/grid.nim`: it imports `std/jsffi` and `bindings/js_interop`
(`:12-13`), and every module the suite reaches must compile natively
(`openspec/specs/native-test-strategy/spec.md:13-20`). The test that fails first is therefore a
source sweep in `tests/test_agreements.nim`: `src/grid.nim` contains `grid_core.computeGridDims`
and does not contain `jsFloor(config.WORLD_W`. It fails today for the absence of the call, and goes
green on the fix. `tests/test_no_modes.nim:133-150` establishes source sweeps as this suite's
answer for code it cannot execute.

A behavioral observation backs it, and it is agent-checkable: build with `just happen`, launch,
and watch particles form clusters. A grid collapsed to 1x1 or clamped to 256x256 puts every
particle in one bin or scatters neighbors across bins, and neither produces the clustering the
default preset shows.

*Rejected:* pinning `computeGridDims(3840, 2160, radius)` in `tests/test_grid.nim` as the failing
test. It passes today, because it exercises `grid_core` and `grid_core` is already right. The
defect is that `src/grid.nim` does not call it, and only a sweep of `src/grid.nim` sees that.

*Rejected:* moving the arithmetic the other way, deleting `grid_core.computeGridDims` and testing
`grid.nim`. The native suite cannot reach `grid.nim`, so this deletes the only testable copy.

`src/grid_core.nim:9-13` reads "Nothing in src/ imports this module, and that is expected." The fix
makes that false for `computeGridDims`, and the header is corrected in the same diff.

## Risks / Trade-offs

**The inventory records only what someone wrote in it.** No gate detects a duplication absent from
the table, so the table's completeness rests on review. → The specs label this unenforced and name
what closes it: a derived detector for the class, which this change ships once for placeholders as
the worked example. Nothing in the specs claims coverage the gates do not deliver.

**An anchor is a substring, so a coincidental match keeps a stale entry green.** An anchor like
`= 12` would match many lines. → Anchors are the declaration text, long enough to be unique in
their file. The review question when adding an entry is whether the anchor could match anything
else in that file.

**The placeholder detector would encode the bundler's workgroup rewrite in a second place.** The
key-naming rule, `"WORKGROUP_SIZE_" & shaderName.toUpperAscii.replace("-", "_")`, lives at
`tools/wgsl_bundle.nim:115`, and a test restating it creates a new two-sided agreement while
removing another. → The rule moves into `src/shader_config.nim` as an exported
`workgroupKeyFor(shaderName: string): string`, which the bundler calls at `:116` and the test calls
to check consumption. `tools/wgsl_bundle.nim:21` imports `shader_config` already, so the pair is
derived and needs no entry. This is the same judgment the placeholder detector rests on: where
derivation is available, take it before writing anything down.

**Deriving grid dimensions moves JS-backend arithmetic onto integer division.** The two forms agree
for the shipped world size, which is a claim about the current values of `WORLD_W` and `WORLD_H`
(`src/config.nim:115-116`), and no property of the code holds it. → A fractional world size would floor
differently. `computeGridDims` takes ints, so a fractional world would not type-check its way in
silently. It would require a signature change, which is where the question would be asked.

**`src/agreements.nim` has no importer in `src/`.** A reader may take it for dead code under
article 6. → Its header names `tests/test_agreements.nim` as its consumer, matching
`src/grid_core.nim:6-7`'s "Used by" convention.
