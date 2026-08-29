# Tasks

Every anchor string below was read out of the file it names during this change's research, and
each occurs exactly once in that file. An anchor that no longer matches means the code moved, and
the entry is revisited before the task proceeds.

## 1. The inventory and its meta-gates

This group is the measurement gate for groups 2 through 4: each of those removes an entry, and the
anchor gate is what proves the entry went stale.

- [ ] 1.1 Write `tests/test_agreements.nim` with the six predicates as named functions over an
      `Agreement` record: `sitePathsExist`, `siteAnchorsFound`, `hasTwoSites`, `holderCitationFound`,
      `reasonsPresent`, `tableIsPopulated`. Import `../src/agreements`. Run
      `nim c -r tests/test_agreements.nim` and watch it fail to compile, because `src/agreements.nim`
      does not exist. That failure is the gate proving the test reads the real table.
- [ ] 1.2 Write `src/agreements.nim`: an `AgreementTier` enum (`Derived`, `BuildAsserted`,
      `TestHeld`, `AgentCheckable`, `Unenforced`), an `AgreementSite` record (`path`, `anchor`), an
      `Agreement` record (`key`, `statement`, `sites`, `tier`, `holder`, `whyNotStronger`,
      `wouldClose`), and `const AGREEMENTS*` holding the five entries in 1.3. Head the module with
      its consumer, `tests/test_agreements.nim`, following `src/grid_core.nim:6-7`.
- [ ] 1.3 Seed `src/agreements.nim` with five entries, each anchor verified present:
      - `species-ceiling-matrix`: `src/memory_layout.nim` at `MAX_SPECIES* = 12` and
        `src/ui/state/matrix_state.nim` at `MATRIX_SIZE* = 12`. Tier `TestHeld`, holder
        `tests/test_memory_layout.nim` at `MAX_SPECIES agrees with matrix_state.MATRIX_SIZE`.
        `whyNotStronger`: nothing binds the pair at build time.
      - `species-ceiling-preset`: `src/memory_layout.nim` at `MAX_SPECIES* = 12` and
        `src/preset.nim` at `const MAX_SPECIES* = 12`. Tier `BuildAsserted`, holder `src/preset.nim`
        at `doAssert MAX_SPECIES == SPECIES_COUNT_MAX`. `whyNotStronger`: `preset` carries no
        dependency on `memory_layout` or any other `src/` module, to stay a leaf the storage and UI
        layers build on (`src/preset.nim:79-83`).
      - `blast-radius`: `src/shader_config.nim` at `blastRangeSq: 40000.0`,
        `web/shaders/src/forces.wgsl` at `let blastRangeSq = 40000.0;`, and
        `web/shaders/src/forces.wgsl` at `blastDist / 200.0`. Tier `Unenforced`. `wouldClose`:
        emitting radius and square from `shader_config` and having the shader read both.
      - `grid-dimensions`: `src/grid.nim` at `cellSize = max(CONFIG.interactionRadius, 16)` and
        `src/grid_core.nim` at `let cellSize = max(interactionRadius, 16)`. Tier `Unenforced`.
        `wouldClose`: `src/grid.nim` calling `grid_core.computeGridDims`.
      - `chemistry-stride`: `src/field_core.nim` at `SPECIES_CHEMISTRY_STRIDE* = 2` and
        `src/preset.nim` at `const CHEMISTRY_STRIDE* = 2`. Tier `Unenforced`. `wouldClose`: a native
        test in `tests/test_preset.nim` relating the two, since a `doAssert` would need `preset` to
        import `field_core`, which its leaf constraint forbids.
- [ ] 1.4 Add the suite "The Inventory Gate Can Fail" to `tests/test_agreements.nim`, running each
      predicate from 1.1 against a constructed violating input: a nonexistent path, an absent
      anchor, a one-site entry, a `BuildAsserted` entry citing absent text, an `Unenforced` entry
      with an empty `wouldClose`. Each test asserts the predicate reports the violation. Verify by
      temporarily inverting one predicate's return and confirming its can-fail test goes red, then
      restoring it.
- [ ] 1.5 Register the module: add `import test_agreements` to `tests/test_all.nim` and
      `discard test_agreements.AGREEMENTS_TESTS_LOADED` to its `static:` block, matching
      `tests/test_all.nim:38-60`.
- [ ] 1.6 `just happen` and `just check` green.

## 2. The species ceiling becomes derived

- [ ] 2.1 In `tests/test_agreements.nim`, add a test asserting `src/ui/state/matrix_state.nim`
      contains no `MATRIX_SIZE`. Run `nim c -r tests/test_agreements.nim` and watch it fail: the
      constant is at `src/ui/state/matrix_state.nim:23`.
- [ ] 2.2 In `src/ui/state/matrix_state.nim`, delete the `MATRIX_SIZE` const at line 23 and read
      `SPECIES_COUNT_MAX` at lines 28, 31, and 36. The name arrives through the existing
      `import ../../config_ranges` at line 12. No new import is needed, and no cycle forms, because
      the cycle `src/memory_layout.nim:193-195` names runs the other way.
- [ ] 2.3 In `src/web_api.nim`, change line 1274's `matrixStride` proc to return
      `SPECIES_COUNT_MAX`. `config_ranges` is imported at line 53. The API name `matrixStride` does
      not change, so the panel sees the same key and the same value, 12.
- [ ] 2.4 In `tests/test_matrix.nim`, change `MATRIX_SIZE` to `SPECIES_COUNT_MAX` at lines 23 and
      24. `config_ranges` is imported at line 2.
- [ ] 2.5 Delete the test at `tests/test_memory_layout.nim:93-98` with its comment. The comment
      states "Nothing forces them to move together", which the derivation makes false.
- [ ] 2.6 Rewrite the comment at `src/memory_layout.nim:185-195`, dropping the sentences about the
      live copy at `matrix_state` and about the assertion living in the test. Keep what stays true:
      the WGSL side spells no species count by hand, `tools/wgsl_bundle.nim` emits it, and
      `src/gpu_types.nim`'s layout tables assert against it.
- [ ] 2.7 Delete the `species-ceiling-matrix` entry from `src/agreements.nim`. Before deleting,
      run `nim c -r tests/test_agreements.nim` and watch the anchor gate fail on
      `MATRIX_SIZE* = 12`, which is the entry retiring itself.
- [ ] 2.8 `just happen` and `just check` green.
- [ ] 2.9 Agent verification: launch the built app, open the panel, and set the species count to its
      maximum. The matrix grid renders 12 rows by 12 columns and every cell accepts a value. A
      stride disagreement shows as a truncated grid or as cells that write to the wrong species.

## 3. The blast radius becomes derived

- [ ] 3.1 In `tests/test_agreements.nim`, add the placeholder consumption test: every key
      `getPlaceholderMap()` returns is read by a shader source under `web/shaders/src/` or
      `web/shaders/modules/`, either as a literal `{{KEY}}` or, for a workgroup key, by the shader
      it names containing `{{WORKGROUP_SIZE}}`. Assert the key set and the shader file set are both
      non-empty. Run it and watch it fail naming exactly one key, `TUNABLE_BLAST_RANGE_SQ`. That
      count was measured against the tree and any other result means the tree moved.
- [ ] 3.2 In `src/shader_config.nim`, export
      `func workgroupKeyFor*(shaderName: string): string` returning
      `"WORKGROUP_SIZE_" & shaderName.toUpperAscii.replace("-", "_")`, and call it from
      `tools/wgsl_bundle.nim:115` in place of the inline expression. `tools/wgsl_bundle.nim:21`
      imports `shader_config` already. Have the test from 3.1 call the same function, so the naming
      rule has one home.
- [ ] 3.3 In `src/shader_config.nim`, emit `TUNABLE_BLAST_RANGE` beside `TUNABLE_BLAST_RANGE_SQ` at
      line 304, as `sqrt(activeConfig.tuning.blastRangeSq)` formatted as a WGSL float literal, with
      a comment stating that the pair is derived from one field so the radius cannot drift from its
      square. Follow the shape of `src/shader_config.nim:306-312`.
- [ ] 3.4 In `tests/test_shader_config.nim`, add a test that the emitted `TUNABLE_BLAST_RANGE`
      squared equals the emitted `TUNABLE_BLAST_RANGE_SQ` within float tolerance, and that both
      parse as WGSL float literals, matching the reciprocal test at lines 47-56.
- [ ] 3.5 In `web/shaders/src/forces.wgsl`, declare
      `const BLAST_RANGE_SQ: f32 = {{TUNABLE_BLAST_RANGE_SQ}};` and
      `const BLAST_RANGE: f32 = {{TUNABLE_BLAST_RANGE}};` beside `MIN_DISTANCE_SQ` at line 51.
      Replace `let blastRangeSq = 40000.0;` at line 364 with a read of `BLAST_RANGE_SQ`, and
      `blastDist / 200.0` at line 367 with `blastDist / BLAST_RANGE`. Edit only
      `web/shaders/src/forces.wgsl`. The top-level `web/shaders/forces.wgsl` is bundler output.
- [ ] 3.6 Delete the `blast-radius` entry from `src/agreements.nim`. Before deleting, run
      `nim c -r tests/test_agreements.nim` and watch the anchor gate fail on both forces.wgsl
      anchors.
- [ ] 3.7 `just happen` and `just check` green. `just happen` runs the shader stage, so a
      placeholder the map does not emit stops the build here (`tools/wgsl_bundle.nim:122-127`).
- [ ] 3.8 Agent verification: launch the built app and double-click on a dense cluster. Particles
      push outward and the disturbance reaches roughly 200 world units from the click, the same
      extent as before the change. A radius read from the wrong constant shows as a blast that
      barely moves anything or one that clears most of the visible field.

## 4. Grid dimensions become derived

- [ ] 4.1 In `tests/test_agreements.nim`, add a source-sweep test: `src/grid.nim` contains
      `grid_core.computeGridDims` and does not contain `jsFloor(config.WORLD_W`. Run it and watch it
      fail on the first half, because the call does not exist yet. The sweep is the available gate because
      the native suite cannot import `src/grid.nim`, which pulls `std/jsffi` at line 12.
- [ ] 4.2 In `tests/test_grid.nim`, add a case pinning `computeGridDims(3840, 2160, radius)` at the
      default interaction radius to the grid extents and cell size the shipped world produces, so
      the values the derivation must preserve are recorded before it happens. Run it green.
- [ ] 4.3 In `src/grid.nim`, add `import grid_core` and replace lines 40-45 with a call to
      `computeGridDims(int(config.WORLD_W), int(config.WORLD_H), CONFIG.interactionRadius)`,
      assigning its three results to the module vars `cellSize`, `gridW`, `gridH`. `grid_core`
      imports only `memory_layout`, which compiles under `nim js` (`src/memory_layout.nim:30-32`).
      Keep the `GridDimensions` return object and the ignored canvas parameters unchanged, since
      `src/app.nim:176` calls through them.
- [ ] 4.4 Rewrite the header at `src/grid_core.nim:9-13`, which reads "Nothing in src/ imports this
      module, and that is expected". Name `src/grid.nim` as the importer of `computeGridDims` and
      keep the oracle statement for the functions the shaders mirror.
- [ ] 4.5 Delete the `grid-dimensions` entry from `src/agreements.nim`. Before deleting, run
      `nim c -r tests/test_agreements.nim` and watch the anchor gate fail on
      `cellSize = max(CONFIG.interactionRadius, 16)`.
- [ ] 4.6 `just happen` and `just check` green.
- [ ] 4.7 Agent verification: launch the built app and watch the default preset for several seconds.
      Particles form and hold clusters. A grid collapsed to one cell puts every particle in one bin
      and stalls the frame rate. A grid clamped to its maximum scatters neighbours across bins and
      leaves particles drifting without clustering. Then drag the interaction radius slider across
      its range and confirm cluster size tracks it, which exercises the recomputation each frame.

## 5. The document and the stale test name

- [ ] 5.1 Write `docs/agreements.md`: what a two-sided agreement is, the five tiers with the tree's
      example of each, how a site anchor works and how to choose one that cannot match by accident,
      how to add an entry, and the limit that no gate finds an agreement nobody recorded. Name the
      classes another mechanism owns and where each lives: shader binding placement
      (`src/wgsl_lint.nim`), GPU struct offsets (`src/gpu_types.nim`), placeholder substitution
      (`src/shader_config.nim` with the consumption test), and oracle-to-shader mirrors (the table
      in `CLAUDE.md`). Name no entries from `src/agreements.nim`.
- [ ] 5.2 In `tests/test_agreements.nim`, add a test that `docs/agreements.md` exists, is non-empty,
      and contains none of the entry keys in `AGREEMENTS`. Run it and watch it fail before 5.1
      lands, then green after.
- [ ] 5.3 Rename the test named `"speciesCount clamps into [2, 8]"` in `tests/test_preset.nim` so
      the name carries no range literals, since its assertions check `SPECIES_COUNT_MIN` and
      `SPECIES_COUNT_MAX`, which resolve to 2 and 12 (`src/config_ranges.nim:29,32`). The assertions
      do not change.
- [ ] 5.4 Add a `CLAUDE.md` line under "Where authority lives" naming `src/agreements.nim` as the
      home of the agreement inventory, matching the existing one-home-per-fact entries.
- [ ] 5.5 `just happen` and `just check` green.
- [ ] 5.6 Read `src/agreements.nim` and confirm two entries remain, `species-ceiling-preset` and
      `chemistry-stride`, each with a non-empty reason it is not derived. Three entries left during
      groups 2 through 4, each removed by the fix that made its agreement disappear.
