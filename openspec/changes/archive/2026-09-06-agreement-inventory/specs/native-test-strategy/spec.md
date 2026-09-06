## ADDED Requirements

### Requirement: Every two-sided agreement is recorded with the tier that holds it

Where one fact is stated in two places, `src/agreements.nim` SHALL carry an entry naming the fact,
its sites, the tier holding the sites together, and the reason the pair does not sit on a stronger
tier.

The tiers are the ones the tree already uses. `Derived`, where one site computes from the other and
no second copy exists (`src/config_ranges.nim:32`). `BuildAsserted`, where a `static:` block fails
compilation on disagreement (`src/preset.nim:189`). `TestHeld`, where a native test relates the
sites and the build does not. `AgentCheckable`, where no automated gate exists and a named
procedure detects a violation. `Unenforced`, where nothing detects a violation.

A site is a file path and a literal anchor string that occurs in that file, taken from the text the
agreement is made of. A site SHALL NOT carry a line number, which an unrelated edit invalidates.

Every entry below `Derived` SHALL carry a reason it is not derived. Every `Unenforced` entry SHALL
additionally name what would detect a violation.

Enforced by `tests/test_agreements.nim`, which reads the table and asserts each of these
properties, and by the Nim compiler, which type-checks the record.

#### Scenario: An entry records a deliberate copy with its reason
- **WHEN** two modules state one number and a dependency constraint forbids deriving one from the
  other
- **THEN** the entry names both sites, the tier that holds them, and the constraint

#### Scenario: An entry claims a tier it cannot support
- **WHEN** an entry is labelled `BuildAsserted` and cites assertion text no file contains
- **THEN** `just test` fails, naming the entry and the missing citation

#### Scenario: An unenforced entry says nothing about closing the gap
- **WHEN** an entry is labelled `Unenforced` with an empty closing note
- **THEN** `just test` fails, naming the entry

### Requirement: A recorded agreement cannot outlive the code that states it

Each site's anchor SHALL occur in the file the site names. Collapsing a duplication removes the
anchor text, so `just test` fails until the entry is deleted with the fix.

Each entry SHALL name at least two sites, because an agreement is two-sided by construction. A
one-site entry fails the suite.

Each site's path SHALL exist. A file renamed or deleted out from under an entry fails the suite.

Enforced by `tests/test_agreements.nim`.

#### Scenario: A duplication is collapsed and its entry is left behind
- **WHEN** a site's anchor text is removed from the file the entry names
- **THEN** `just test` fails, naming the entry and the anchor it can no longer find

#### Scenario: An entry names one site
- **WHEN** an entry carries fewer than two sites
- **THEN** `just test` fails, naming the entry

### Requirement: The inventory gates are watched failing

`tests/test_agreements.nim` SHALL exercise each inventory predicate against a constructed input
that violates it: a nonexistent path, an absent anchor, a single-site entry, a tier citing text no
file contains, and an unenforced entry with no closing note. The can-fail suite and the live gate
SHALL call the same predicate functions, so a green from the live gate reports on code the can-fail
suite has driven red.

The suite SHALL assert the table is non-empty and that every path it names resolves from the
suite's working directory, so a run from the wrong directory fails and does not pass over an
empty sweep. This is the requirement `tests/test_meta_vacuity.nim:91-105` places on every
filesystem-reading test, and the directory-found pattern at `tests/test_no_modes.nim:104-107`.

Enforced by `tests/test_agreements.nim` and by `tests/test_meta_vacuity.nim`, which sweeps the
suite for filesystem-reading tests that assert only an absence.

#### Scenario: A predicate is driven red
- **WHEN** the can-fail suite runs a predicate against its violating input
- **THEN** the predicate reports the violation, and the test passes on having observed it

#### Scenario: The suite runs from the wrong directory
- **WHEN** `tests/test_all.nim` runs where the inventory's paths do not resolve
- **THEN** `just test` fails on the resolution assertion, having swept nothing

### Requirement: The inventory does not claim to find agreements nobody recorded

No gate detects a duplication absent from `src/agreements.nim`. This residue is labelled
**unenforced**. What closes it for a given class is a detector that enumerates that class from the
code, needing no entry per member, as the placeholder coverage requirement does for the
substitution map.

`docs/agreements.md` SHALL state this limit, and SHALL name the classes another mechanism owns so
the inventory does not restate them: shader binding placement (`src/wgsl_lint.nim`), GPU struct
offsets (`src/gpu_types.nim`), and oracle-to-shader mirrors, which the "Divergence between a
mirrored expression and its shader is review-enforced" requirement already covers.

`docs/agreements.md` SHALL name no inventory entries, because a second list of entries is the
defect the inventory exists to remove.

#### Scenario: A new duplication ships unrecorded
- **WHEN** a constant is copied into a second module and no entry is added
- **THEN** `just check` passes, and only review catches it

#### Scenario: The document restates the table
- **WHEN** `docs/agreements.md` names an entry from `src/agreements.nim`
- **THEN** the two lists can disagree, and nothing detects it, which is why the document names none

## MODIFIED Requirements

### Requirement: A shader value the bundler can substitute MUST NOT be duplicated in WGSL

Where a constant can be computed in Nim and substituted into the shader at bundle time, it SHALL be
single-sourced that way rather than mirrored. `shader_config.getPlaceholderMap`
(`src/shader_config.nim:235`) emits the substitutions, and `tools/wgsl_bundle.nim` inlines them; an
unresolved `{{...}}` aborts the bundle rather than reaching the GPU (`tools/wgsl_bundle.nim:122-127`).
`PlaceholderSources` (`tools/wgsl_bundle.nim:203-216`) lists the Nim modules whose edits must trigger a
shader rebuild, so a tuning change cannot ship stale bundled output.

This is the strongest rung of the strategy: for a substituted value there is no second copy to diverge.
It covers the bloom kernel weights and their count, the colormap ramp coefficients, the field dimensions
and RD seed geometry, the glow curve constants, the SPH XSPH epsilon and density ceiling, the fixed-point
scale and its derived reciprocal, the blast radius and its derived square, and every workgroup size.

Coverage runs in both directions. Every key the map emits SHALL be consumed by a shader source
under `web/shaders/src/` or `web/shaders/modules/`, so a placeholder cannot be emitted against a
shader that spells the value by hand instead. A key of the workgroup family counts as consumed when
the shader it names exists under `web/shaders/src/` and contains `{{WORKGROUP_SIZE}}`, which is the
per-shader rewrite at `tools/wgsl_bundle.nim:114-117`. Every other key is consumed by a literal
`{{KEY}}` occurrence. `tests/test_agreements.nim` enumerates both sets and fails on a key no shader
reads. The check needs no inventory entry, because it derives its subject from the map and the
shader sources.

The key-naming rule that pairs a shader with its workgroup key SHALL have one home,
`shader_config.workgroupKeyFor`, called by both `tools/wgsl_bundle.nim` and the consumption check,
so the check cannot model a rewrite the bundler no longer performs.

Where a value has two homes by necessity, a native test SHALL relate them: `tests/test_shader_config.nim`
checks the emitted reciprocal inverts the emitted scale (lines 54-62), the glow placeholders against
their appearance-preserving defaults (70-98), `SPH_XSPH_EPSILON` against `sph_core`'s constant (101-130),
the emitted bloom weight list against `bloomWeightCount()` (133-149), and the emitted `FIELD_W`/`FIELD_H`
against `field_core`'s (152-178). Each also checks the emitted text is a WGSL float literal, because a
bare integer where `f32` is expected fails shader type-checking.

#### Scenario: An unresolved placeholder stops the build
- **WHEN** a shader references a `{{PLACEHOLDER}}` the map does not emit
- **THEN** `just happen` fails at the shader step with the shader name and the placeholder

#### Scenario: An emitted placeholder no shader consumes fails the suite
- **WHEN** `getPlaceholderMap` emits a key and no shader source under `web/shaders/src/` or
  `web/shaders/modules/` reads it, literally or through the workgroup rewrite
- **THEN** `just test` fails, naming the key

#### Scenario: A duplicated constant is related by test
- **WHEN** a constant necessarily exists in both a pure module and the placeholder map
- **THEN** a test in `tests/test_shader_config.nim` asserts the two are equal
