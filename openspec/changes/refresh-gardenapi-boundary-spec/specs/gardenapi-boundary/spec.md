## MODIFIED Requirements

### Requirement: Parameter writes clamp against the descriptor table

`setParam` SHALL reject an id absent from the descriptor table with a console warning and no
mutation, and SHALL clamp every accepted value with `clampParamValue` against that id's descriptor
before any store sees it (`src/web_api.nim:585-598`). No value outside a parameter's range can reach
CONFIG regardless of what the panel sends. `getParam` likewise answers only known ids and warns on
anything else (`src/web_api.nim:440-461`).

Every routed descriptor id SHALL name an assignable field of its store's record. The dispatch walks
the routed record's field names (`src/web_api.nim:585-604`), and a static probe over the whole table
fails the build naming the offending descriptor when an id lands nowhere, the palette and camera ids
served by an arm apiece included (`src/web_api.nim:530-583`).

Enforcement: the build, through the static probe, plus the native suite holding every routed id to a
field of its store's record (`tests/test_param_descriptor.nim:370`). The clamp itself is pinned by
`tests/test_param_descriptor.nim:435-450`. The table's own content belongs to
`parameter-range-authority`, which this requirement only serves.

#### Scenario: An out-of-range value is clamped, not rejected
- **WHEN** the panel sends a value beyond a parameter's range
- **THEN** the descriptor's bound reaches CONFIG and the write succeeds

#### Scenario: An unknown id mutates nothing
- **WHEN** `setParam` is called with an id absent from the descriptor table
- **THEN** the boundary warns on the console and no store changes

#### Scenario: A descriptor id naming no field fails the build
- **WHEN** a descriptor is added whose id names no assignable field of its routed record
- **THEN** `just happen` fails at the Nim compile step with the descriptor named in the error

### Requirement: The boundary serves every number and catalog the panel displays

The boundary SHALL serve, from Nim, every value the panel renders: the descriptor payload built once
at module-eval time (`src/web_api.nim:286-290`, exposed at line 1131), the named reaction-diffusion
regime catalog carrying each regime's id and label (`src/web_api.nim:644-656`, served at lines
1200-1202, the table itself in `config_ranges.nim`), the palette-scheme catalog
(`src/web_api.nim:1055-1062`), the colormap catalog (`src/web_api.nim:1073-1080`), the preset
storage keys (`src/web_api.nim:1303-1308`), and the species and matrix-cell colors computed by Nim
color math (`src/web_api.nim:1261-1279`). TypeScript SHALL restate none of them:
`web-ui/src/garden-api.ts` declares types and no values.

Enforcement: a compile-time `doAssert` guards the one hand-written catalog, failing the Nim build
when the colormap label list and the index bounds disagree (`src/web_api.nim:1064-1071`). The
descriptor table's agreement with the range and default authorities is pinned by
`tests/test_param_descriptor.nim`. The "restates none" half is review-enforced.

#### Scenario: A slider is drawn entirely from served numbers
- **WHEN** the panel renders a parameter control
- **THEN** its range, step, precision, default, label, group, and hint all come from `descriptor()`

#### Scenario: An unlabelled colormap ramp fails the build
- **WHEN** a colormap ramp is added without a matching label entry
- **THEN** `just happen` fails at the Nim compile step

### Requirement: Presets keep schema, validation, and apply order in Nim

The boundary SHALL own preset serialization, validation, and application, leaving the panel only
storage I/O. `exportPresetJson` and `exportPresetJsonPretty` snapshot the live CONFIG, the
attraction matrix, the species chemistry, and the species palette into the versioned schema
(`src/web_api.nim:863-946, 1312-1315`). `applyPresetJson` SHALL return an `{ok, error}` outcome and
never throw (`src/web_api.nim:1316-1329`): it pre-checks parseability through the `jsonParseable`
FFI helper (`src/web_api.nim:69-70`) because `std/json.parseJson` on the JS backend delegates to
`JSON.parse`, whose SyntaxError is a foreign exception Nim's `except ValueError` cannot catch.
Validation degrades missing or malformed fields to clamped defaults and rejects only a
`schemaVersion` newer than the build understands (`src/preset.nim:356-674`). Application SHALL walk
`presetApplySteps()` in its fixed order (`src/web_api.nim:947-1046`,
`src/ui/presets/preset_store_core.nim:76-83`) and SHALL persist nothing.

The panel SHALL key its localStorage on the strings the boundary serves, the prefix, index key, and
default name (`src/web_api.nim:1303-1308`, `src/ui/presets/preset_store_core.nim:24-27`,
`src/preset.nim:188`), so saved presets stay loadable across panel rewrites. Built-in starter
presets are ordinary preset JSON served as strings and applied through the same `applyPresetJson`
path, never touching localStorage (`src/web_api.nim:1091-1119`).

Enforcement: `tests/test_preset.nim` pins validation, clamping, defaulting, and round-trip
stability, and `tests/test_preset_store_core.nim:38-73` pins the apply-order sequence and the
storage keys. Both run under `just test`.

#### Scenario: Malformed preset text is reported, not thrown
- **WHEN** `applyPresetJson` receives text that is not valid JSON
- **THEN** it returns `{ok: false, error}` and the simulation is unchanged

#### Scenario: A preset from a newer schema is refused
- **WHEN** a preset declares a `schemaVersion` above the version this build writes
- **THEN** the apply is refused with an error and nothing is applied

#### Scenario: Fields land in the pinned order
- **WHEN** a valid preset is applied
- **THEN** species count, particle count, matrix, chemistry, palette, and scalars land in
  `presetApplySteps()` order

## REMOVED Requirements

### Requirement: Mode ceilings clamp the particle count

**Reason**: The one-world refactor removed simulation modes, and every mechanism this requirement
described went with them: no `setSimMode`, no `particleCeiling`, and neither ceiling constant
appears anywhere under `src/`. `tests/test_no_modes.nim` guards the absence.

**Migration**: None for users or code; the machinery already shipped out. The requirement's one
surviving behavior, the commit side effect on the count parameters, moves to the requirement
"Committing a count parameter runs its release side effect", corrected to what the code does.

## ADDED Requirements

### Requirement: Committing a count parameter runs its release side effect

`commitParam` SHALL carry the slider-release side effect for exactly the two count parameters and
for nothing else (`src/web_api.nim:767-780`). Committing `particleCount` SHALL resize the population
in place, preserving the running world rather than re-initializing it. Committing `speciesCount`
SHALL re-initialize the particle field, since changing how many species exist changes what every
particle's species index means, and there is no population to preserve. Every other id SHALL commit
without side effect.

Enforcement: the descriptor table flags the two ids whose commit carries a side effect
(`reinitOnCommit`, `src/ui/api/param_descriptor.nim:418, 425`), and
`tests/test_param_descriptor.nim:365-368` holds the flag to exactly those two. The dispatch itself
is review-enforced and build-verified only, since `web_api.nim` compiles on the JS backend alone
(`src/web_api.nim:29-32`).

#### Scenario: Committing the particle count preserves the world
- **WHEN** the user commits a new `particleCount` on the slider
- **THEN** the population resizes and the world is not re-initialized

#### Scenario: Committing the species count re-initializes
- **WHEN** the user commits a new `speciesCount`
- **THEN** the particle field re-initializes

#### Scenario: Any other commit is inert
- **WHEN** `commitParam` is called with an id other than the two counts
- **THEN** nothing changes beyond what `setParam` already applied
