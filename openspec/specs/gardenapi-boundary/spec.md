# gardenapi-boundary

## Purpose

The one language boundary between the Nim simulation and the SolidJS control panel: the
`window.gardenAPI` object built in `src/web_api.nim`, through which every parameter read, parameter
write, catalog lookup, buffer reference, stats sample, and preset operation crosses. It is one
capability rather than several because one invariant governs all of it — a synchronous surface whose
numbers are authored in Nim — and every method on the object exists to honor that invariant.

## Requirements

### Requirement: One object carries the whole boundary

`app.js` SHALL install exactly one `gardenAPI` object on the global object at module-eval time,
before the control-panel bundle evaluates: `setGlobal("gardenAPI", buildGardenApi())` runs at
`src/web_api.nim:1331` as the last statement of the module, and `web/index.html` loads `app.js`
(line 73) ahead of `ui-bundle.js` (line 75). The panel SHALL reach the simulation through no other
channel — no direct CONFIG access, no second global, no DOM-mediated side channel.

Enforcement: the build. `just build-app` compiles the Nim frontend, and `just build-ui` typechecks
the panel with `tsc --noEmit` (`justfile:26-30`) against the declared surface in
`web-ui/src/garden-api.ts`, so a call the boundary does not expose fails the typecheck rather than
the browser. The "no other channel" half is review-enforced: nothing mechanically prevents the panel
from reaching elsewhere.

#### Scenario: The panel finds the boundary already installed
- **WHEN** the control-panel bundle evaluates
- **THEN** `window.gardenAPI` is present with its full method set

#### Scenario: A call the boundary does not declare fails the build
- **WHEN** the panel calls a method absent from `web-ui/src/garden-api.ts`
- **THEN** `just happen` fails at the TypeScript typecheck step

### Requirement: Every parameter write mirrors into CONFIG in the same tick

Every mutation SHALL pass through `updateSimulation` or `updateRender`
(`src/web_api.nim:165-194`), which write the typed state record and then call
`applySimulationToConfig` / `applyRenderToConfig` (`src/web_api.nim:135-164`) to mirror it into the
flat GPU-facing CONFIG before returning. The mirror SHALL NOT be rebuilt on a subscription, a
promise, or a microtask: the frame loop reads CONFIG fresh every frame, so a deferred flush would
let a frame render against a stale value. Every `gardenAPI` method is synchronous for this reason.

Enforcement: review-enforced. The invariant is stated at both ends of the boundary —
`src/web_api.nim:8-16` and `web-ui/src/garden-api.ts:7-9` — and no test or compile-time assertion
checks it, because `web_api.nim` compiles only on the JS backend and no native test imports it
(`src/web_api.nim:29-32`).

#### Scenario: A write has landed by the time the call returns
- **WHEN** the panel calls `setParam` and the call returns
- **THEN** both the typed state record and CONFIG hold the new value

#### Scenario: The next frame sees the write
- **WHEN** a frame is dispatched after a parameter write
- **THEN** it reads the written value from CONFIG, never the previous one

### Requirement: Parameter writes clamp against the descriptor table

`setParam` SHALL reject an id absent from the descriptor table with a console warning and no
mutation, and SHALL clamp every accepted value with `clampParamValue` against that id's descriptor
before any store sees it (`src/web_api.nim:585-598`). No value outside a parameter's range can reach
CONFIG regardless of what the panel sends. `getParam` likewise answers only known ids and warns on
anything else (`src/web_api.nim:440-461`).

Every descriptor id SHALL have an explicit write arm in the dispatch. The dispatch is a hand-written
case ending in `else: discard` (`src/web_api.nim:424`), so an id present in the table with no arm
would clamp its value, write nowhere, and report success. That agreement between the table and the
dispatch is review-enforced: no build step or test detects a missing arm. The clamp itself is pinned
by `tests/test_param_descriptor.nim:435-450`; the table's own content belongs to
`parameter-range-authority`, which this requirement only serves.

#### Scenario: An out-of-range value is clamped, not rejected
- **WHEN** the panel sends a value beyond a parameter's range
- **THEN** the descriptor's bound reaches CONFIG and the write succeeds

#### Scenario: An unknown id mutates nothing
- **WHEN** `setParam` is called with an id absent from the descriptor table
- **THEN** the boundary warns on the console and no store changes

### Requirement: The boundary serves every number and catalog the panel displays

The boundary SHALL serve, from Nim, every value the panel renders: the descriptor payload built once
at module-eval time (`src/web_api.nim:286-290`, exposed at line 1131), the simulation-mode catalog
carrying each mode's id, label, particle ceiling, and control groups (`src/web_api.nim:631-647`), the
palette-scheme catalog (`src/web_api.nim:1055-1062`), the colormap catalog
(`src/web_api.nim:1073-1080`), the preset storage keys (`src/web_api.nim:1303-1308`), and the species and
matrix-cell colors computed by Nim color math (`src/web_api.nim:1261-1279`). TypeScript SHALL restate
none of them: `web-ui/src/garden-api.ts` declares types and no values.

Enforcement: a compile-time `doAssert` guards the one hand-written catalog — the colormap label list
fails the Nim build if the ramp count and the index bounds disagree (`src/web_api.nim:1064-1071`). The
descriptor table's agreement with the range and default authorities is pinned by
`tests/test_param_descriptor.nim`. Per-mode control groups come from `sim_registry.controlGroupsFor`,
owned by `gpu-frame-registry`. The "restates none" half is review-enforced.

#### Scenario: A slider is drawn entirely from served numbers
- **WHEN** the panel renders a parameter control
- **THEN** its range, step, precision, default, label, group, and hint all come from `descriptor()`

#### Scenario: An unlabelled colormap ramp fails the build
- **WHEN** a colormap ramp is added without a matching label entry
- **THEN** `just happen` fails at the Nim compile step

### Requirement: Buffer-backed accessors are valid only after the ready gate

Accessors returning live views over the SharedArrayBuffer SHALL be read only after the boundary
signals ready, because the buffers do not exist until `init()` has allocated them — and `matrix()`
returns the Float32Array itself, not a copy (`src/web_api.nim:1260`). The boundary SHALL provide
`isReady()` and `onReady(callback)`, queueing callbacks registered early and invoking a callback
registered late immediately (`src/web_api.nim:787-804, 1125-1128`). `app.nim` calls `signalReady()` at
the end of `init()` (`src/app.nim:412`), which flushes the queue and answers `isReady()` true from
then on.

Enforcement: review-enforced, plus the build — the accessor signatures are checked by the TypeScript
typecheck, but nothing prevents the panel from reading `matrix()` before ready.

#### Scenario: An early subscriber is deferred
- **WHEN** the panel registers an `onReady` callback before initialization finishes
- **THEN** the callback runs once, after the buffers are allocated

#### Scenario: A late subscriber runs immediately
- **WHEN** the panel registers an `onReady` callback after initialization has finished
- **THEN** the callback runs synchronously during registration

### Requirement: Stats reach the panel by push on a loop-side cadence

The boundary SHALL expose `onStats(callback)` for subscription (`src/web_api.nim:1298-1299`) and
SHALL push samples from the frame loop rather than answering polls: `pushStats`
(`src/web_api.nim:805-861`) is called by `app.nim` inside the frame loop's cadence window
(`src/app.nim:284, 315`). The cadence is the loop's decision, not the panel's. A sample
SHALL carry raw numbers only — frame rate, particle count, and the per-pass GPU timings — with all
formatting left to the panel. With no subscriber registered, `pushStats` SHALL return before
allocating anything (`src/web_api.nim:820-821`).

Enforcement: the build. The sample shape is declared in `web-ui/src/garden-api.ts:121-147` and checked
by `tsc --noEmit`; a field the Nim side stops writing surfaces as a typecheck or runtime-undefined
mismatch rather than silently. The cadence's ownership is review-enforced.

#### Scenario: A subscriber receives samples without polling
- **WHEN** the panel has registered an `onStats` callback
- **THEN** the frame loop invokes it with a fresh sample on its own cadence

#### Scenario: An unsubscribed boundary does no stats work
- **WHEN** no `onStats` callback is registered
- **THEN** `pushStats` allocates no sample object

### Requirement: Presets keep schema, validation, and apply order in Nim

The boundary SHALL own preset serialization, validation, and application, leaving the panel only
storage I/O. `exportPresetJson` and `exportPresetJsonPretty` snapshot the live CONFIG, attraction
matrix, species palette, and active mode into the versioned schema
(`src/web_api.nim:863-946, 1312-1315`). `applyPresetJson` SHALL return an `{ok, error}` outcome and
never throw (`src/web_api.nim:1316-1329`): it pre-checks parseability through the `jsonParseable` FFI
helper (`src/web_api.nim:69-70`) because `std/json.parseJson` on the JS backend delegates to
`JSON.parse`, whose SyntaxError is a foreign exception Nim's `except ValueError` cannot catch.
Validation degrades missing or malformed fields to clamped defaults and rejects only a
`schemaVersion` newer than the build understands (`src/preset.nim:356-674`). Application SHALL walk
`presetApplySteps()` in its fixed order (`src/web_api.nim:947-1046`,
`src/ui/presets/preset_store_core.nim:76-80`) and SHALL persist nothing.

The panel SHALL key its localStorage on the strings the boundary serves — prefix, index key, and
default name (`src/web_api.nim:1303-1308`, `src/ui/presets/preset_store_core.nim:24-27`, `src/preset.nim:188`) — so saved
presets stay loadable across panel rewrites. Built-in starter presets are ordinary preset JSON
served as strings and applied through the same `applyPresetJson` path, never touching localStorage
(`src/web_api.nim:1091-1119`).

Enforcement: `tests/test_preset.nim` pins validation, clamping, defaulting, and round-trip
stability; `tests/test_preset_store_core.nim:38-73` pins the apply-order sequence and the storage
keys. Both run under `just test`.

#### Scenario: Malformed preset text is reported, not thrown
- **WHEN** `applyPresetJson` receives text that is not valid JSON
- **THEN** it returns `{ok: false, error}` and the simulation is unchanged

#### Scenario: A preset from a newer schema is refused
- **WHEN** a preset declares a `schemaVersion` above the version this build writes
- **THEN** the apply is refused with an error and nothing is applied

#### Scenario: Fields land in the pinned order
- **WHEN** a valid preset is applied
- **THEN** mode, species count, particle count, matrix, palette, and scalars land in
  `presetApplySteps()` order

### Requirement: Mode ceilings clamp the particle count

Each simulation mode SHALL carry a particle ceiling, served to the panel as that mode's
`particleCeiling` (`src/web_api.nim:637`): none for particle life, `SPH_PARTICLE_CEILING` for SPH,
`RD_PARTICLE_CEILING` for reaction-diffusion (`src/web_api.nim:261-268`, constants at
`src/sph_core.nim:35` and `src/field_core.nim:63`).

Entering a capped mode through `setSimMode` SHALL lower the live particle count to that mode's
ceiling when the count exceeds it, and that clamp SHALL re-initialize the particle field: the path
runs `updateSimulation` and then `triggerParticleReinit()` (`src/web_api.nim:270-281`), so positions,
velocities, and species are regenerated rather than preserved. Leaving the mode does not restore the
previous count.

The preset apply path SHALL apply no mode ceiling. Its `pasMode` step sets `activeSimKind` directly
rather than through `setSimModeImpl` (`src/web_api.nim:543-551`), and its `pasParticleCount` step
writes the preset's count as validated — against the slider bounds only — before triggering the same
re-initialization (`src/web_api.nim:559-562`). A preset may therefore leave a capped mode running
above its ceiling; the built-in starters avoid this by clamping their own count against the ceiling
when they are constructed (`src/web_api.nim:704-707`).

The `particleCount` slider's commit path SHALL re-initialize particles: `commitParamImpl` triggers
the re-initialization on commit (`src/web_api.nim:426-433`), matching that descriptor's
`reinitOnCommit` flag (`src/ui/api/param_descriptor.nim:95-97`).

Enforcement: the ceiling constants are pinned natively by `tests/test_sph_core.nim:180` and
`tests/test_field_core.nim:358`, and the `reinitOnCommit` routing by
`tests/test_param_descriptor.nim:285-288`. The clamp path itself is review-enforced and
build-verified only: `web_api.nim` compiles on the JS backend alone and no native test imports it
(`src/web_api.nim:29-32`).

#### Scenario: Entering a capped mode above its ceiling
- **WHEN** the panel switches to a mode whose ceiling is below the live particle count
- **THEN** the count is set to the ceiling and the particle field is re-initialized from scratch

#### Scenario: A preset carries a count above the target mode's ceiling
- **WHEN** an applied preset names a capped mode and a particle count above that mode's ceiling
- **THEN** the count is applied unchanged, clamped only against the slider bounds

#### Scenario: Committing the particle-count slider
- **WHEN** the user commits a new `particleCount` on the slider
- **THEN** the particles re-initialize
