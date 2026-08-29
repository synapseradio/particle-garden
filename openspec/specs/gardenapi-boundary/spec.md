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

Every routed descriptor id SHALL name an assignable field of its store's record. The dispatch walks
the routed record's field names through `assignParamField` (`src/web_api.nim:507-528, 585-604`), and
a static block writes every routed descriptor's default into a throwaway copy of its store's record
at compile time, calling `error()` with the offending id where one lands nowhere
(`src/web_api.nim:530-583`). The matching read gate holds every scalar descriptor to a CONFIG field
or to a named `ReadElsewhere` exemption, and drops an exemption no descriptor claims
(`src/web_api.nim:463-505`).

Three routes keep an explicit arm, because none of them is a field assignment. The palette pair
writes the palette editor state and regenerates the species colours from it
(`src/web_api.nim:605-613`). The camera route writes the live camera through `canvas_input`'s hooks,
view state deliberately absent from CONFIG (`src/web_api.nim:614-633`). The species-chemistry route
refuses with a console warning naming `chemistry()` as the write path, since per-species values are
written by reference through the chemistry surface and silence would read as a dead control
(`src/web_api.nim:634-639`).

Enforcement: the build, through the two static gates, plus the native suite.
`tests/test_param_descriptor.nim:372-433` holds every routed id to a field of its store's record,
holds the field's kind to the descriptor's declared kind, and holds the palette and camera arms to
exactly the ids they are written against; the two field-name tests are `:382-390` and `:392-399`,
each naming the offending descriptor. The clamp itself is pinned by
`tests/test_param_descriptor.nim:434-452`. The table's own content belongs to
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

#### Scenario: A descriptor nothing can read fails the build
- **WHEN** a scalar descriptor names no CONFIG field and no `ReadElsewhere` exemption
- **THEN** `just happen` fails at the Nim compile step naming the id and what to give it

### Requirement: One world has one particle budget

There SHALL be exactly one particle budget: `MAX_PARTICLES` (`src/memory_layout.nim:37`), the
allocation the particle buffers are sized for, re-exported as the slider ceiling
`PARTICLE_COUNT_MAX` (`src/config_ranges.nim:28`). No coupling carries a ceiling of its own.

Applying a preset SHALL enforce that budget. The `pasParticleCount` step clamps with
`min(..., PARTICLE_COUNT_MAX)` before the value reaches the store (`src/web_api.nim:969-972`), so a
hand-edited preset, or one saved by a build with a different buffer size, cannot leave the world
running above what this build can hold.

The two count paths differ deliberately (`src/web_api.nim:767-780`, `:960-973`): the particleCount
slider RESIZES in place, so dragging it does not destroy the world it is adjusting and the surviving
particles keep their positions, velocities, and species, while applying a preset re-initializes,
because a preset is a different world and there is no population the user expects to survive
adopting it. Raising the budget does not restore a previous count.

Enforcement: the native suite holds the slider ceiling to the one budget
(`tests/test_param_descriptor.nim:588-593`), and `tests/test_no_modes.nim` fails on any per-mode
ceiling identifier reappearing under `src/` or `web-ui/src/`. The preset clamp itself is
**agent-checkable**, since `web_api.nim` compiles on the JS backend alone and no native test imports
it (`src/web_api.nim:29-32`): launch the app, apply a preset JSON whose `particleCount` exceeds
`PARTICLE_COUNT_MAX`, and confirm the count reported on the stats push is the budget.

#### Scenario: Preset click adopts a different world
- **WHEN** a preset is applied over a living world
- **THEN** the count clamps to the budget and the population re-initializes as the preset's own

#### Scenario: A preset cannot exceed the budget
- **WHEN** a preset carries a count above the budget
- **THEN** the applied count is the budget, whether or not the preset was constructed in Nim

#### Scenario: The budget does not depend on what the world is doing
- **WHEN** any coupling strength changes
- **THEN** the particle budget is unchanged

### Requirement: Committing a count parameter runs its release side effect

`commitParam` SHALL carry the slider-release side effect for exactly the two count parameters and
for nothing else (`src/web_api.nim:767-780`). Committing `particleCount` SHALL resize the population
in place, preserving the running world. Committing `speciesCount` SHALL re-initialize the particle
field, since changing how many species exist changes what every particle's species index means, and
there is no population to preserve. Every other id SHALL commit without side effect.

Enforcement: the descriptor table flags the two ids whose commit carries a side effect
(`reinitOnCommit`, `src/ui/api/param_descriptor.nim:418, 425`), and
`tests/test_param_descriptor.nim:367-370` holds the flag to exactly those two. The dispatch itself
is **agent-checkable**, since `web_api.nim` compiles on the JS backend alone
(`src/web_api.nim:29-32`): launch the app, raise `particleCount` on the slider and confirm the
existing particles hold their positions while the new ones appear, then commit a new `speciesCount`
and confirm the whole field re-initializes.

#### Scenario: Committing the particle count preserves the world
- **WHEN** the user commits a new `particleCount` on the slider
- **THEN** the population resizes and the world is not re-initialized

#### Scenario: Committing the species count re-initializes
- **WHEN** the user commits a new `speciesCount`
- **THEN** the particle field re-initializes

#### Scenario: Any other commit is inert
- **WHEN** `commitParam` is called with an id other than the two counts
- **THEN** nothing changes beyond what `setParam` already applied

### Requirement: Descriptors carry labelled notches

A parameter descriptor SHALL be able to carry a table of labelled notches, values known to produce
something worth seeing, served to the panel through `descriptor()` like every other number
(`ParamNotch` at `src/ui/api/param_descriptor.nim:144-156`, carried at `:178`, served at
`src/web_api.nim:250-258`). Notches are authored in Nim; the panel renders what arrives and invents
none of its own (`web-ui/src/components/ParamSlider.tsx:73-82, 152-173`).

Every notch value SHALL lie inside its parameter's range, SHALL sit on a position the parameter's
own step lattice can land on, SHALL carry a label, and SHALL be unique within its parameter, because
a labelled value the slider cannot reach is the same defect as an unlabelled range whose interesting
parts are unfindable.

Snapping is a magnet, never a hard stop. A notch's pull is capped against the travel distance to its
nearest neighbour, so some value between every adjacent pair stays reachable
(`web-ui/src/lib/notches.ts:35-57, 105-111`), and the pull is measured in track position obtained
from the boundary, so a notch is reached exactly where its tick is drawn on any curve.

Enforcement: `tests/test_param_descriptor.nim:511-609` under `just test`, and
`web-ui/test/notches.test.ts:92-125` under `just check` for the reachability property. That the
panel draws one labelled tick per served notch is **agent-checkable**: launch the app, open the
Reaction-Diffusion section, and confirm the Feed slider carries one labelled tick per named regime,
each at the position `paramPositionOf` answers for its value.

#### Scenario: Slider shows where the good values are
- **WHEN** the panel renders a slider whose descriptor declares notches
- **THEN** it draws a labelled tick at each notch value, taken from the descriptor

#### Scenario: Unreachable notch fails the suite
- **WHEN** a notch is declared outside its parameter's range
- **THEN** `just test` fails at "every notch value lies inside its parameter's range", reporting the
  assertion's line without naming the parameter or the notch

#### Scenario: A notch between two others stays reachable
- **WHEN** two notches sit close enough that a flat pull would span the gap
- **THEN** each pull is capped against the neighbour distance and the midpoint snaps to neither

### Requirement: Coupled parameters have a joint selector

Where a regime is located by two or more parameters together, the boundary SHALL serve a named
selector that sets them jointly, alongside the individual sliders. A notch on one axis alone does
not locate a regime, so notches on coupled parameters are informative without being sufficient.

The feed/kill plane is the case in hand. `rdRegimes()` serves each named regime's id, label,
coordinates, and deposit floor (`src/web_api.nim:644-654`, served at `:1200`). `applyRdRegime` sets
feed and kill through the ordinary descriptor-clamped `setParam` path and raises the deposit to the
regime's floor where the regime declares one, never lowering a deposit the user has raised
(`src/web_api.nim:670-688`, served at `:1202`). `getRdRegime` answers which regime the live
coordinates match, or the empty string between regimes (`src/web_api.nim:690-700`, served at
`:1201`). The panel sends an id and restates no coordinate
(`web-ui/src/components/RegimeSelector.tsx:17-52`).

Enforcement: `tests/test_param_descriptor.nim:555-586` holds both axes to the same named set, holds
each notch value to the coordinate the range authority declares, and holds the deposit notch to the
floor the regime table measured. That the row appears and lights the matching button is
**agent-checkable**: launch the app, click each named regime, and confirm the feed and kill sliders
land on that regime's coordinates and its button lights.

#### Scenario: Choosing a named regime
- **WHEN** the user picks a named regime
- **THEN** every parameter that regime specifies is set together through the clamped boundary

#### Scenario: Between regimes
- **WHEN** the live coordinates match no named regime
- **THEN** the boundary answers the empty string and no button reads as active

### Requirement: The descriptor payload carries curve, horizon, and dormancy

`descriptor()` SHALL serve the travel curve and its exponent, the uniform position step, the
response horizon with its review flag, the dormancy predicate's name with its resolved line, the
notch table, the value's bound, and its arity, alongside the range, step, precision, default, label,
group, store, and hint (`src/web_api.nim:221-284`), so the panel restates none of them. Probe ids
and exemptions stay native machinery: the legibility suite consumes them in Nim and the panel has no
use for them.

A derived bound carries the ceiling's name and the reason it exists, so the panel prints a claim
about the simulation it never authored (`src/web_api.nim:259-274`). A per-species entry carries the
slot that indexes a species' stride, which a scalar entry omits, so the two cardinalities stay
distinguishable on the TypeScript side without a second table (`src/web_api.nim:275-284`).

The payload is built once at module-eval time and cached (`src/web_api.nim:286-290`, exposed at
`:1131`), so its growth costs one array and no per-frame work.

Enforcement: `web-ui/src/garden-api.ts` declares the payload's types and no values, checked by
`tsc --noEmit` under `just happen`. That the panel computes no mapping of its own is
**agent-checkable**: launch the app, drag a curved slider, and confirm the handle position round
trips through `paramValueAt` and `paramPositionOf` (`src/web_api.nim:1155-1162`, passed through
untouched at `web-ui/src/state.ts:176-181`, called at
`web-ui/src/components/ParamSlider.tsx:129-143`), with no curve arithmetic under `web-ui/src/`.

#### Scenario: The panel computes no mapping of its own
- **WHEN** the panel positions a handle for a curved parameter
- **THEN** it obtains the position from the boundary rather than computing the curve

### Requirement: Dormancy evaluates where its state already lives

The boundary SHALL evaluate a dormancy predicate over panel-visible state (a strength, a toggle,
another parameter's value) synchronously against the state the panel already mirrors, and SHALL
evaluate a predicate over world state against the pushed stats it already streams. It SHALL add
neither a new subscription nor a per-frame call for either. `dormantParams()` answers id to verdict
in one synchronous call, reading the live simulation and render records field by field and the world
signals from the last stats push (`src/web_api.nim:1208-1249`), and the panel calls it on its own
writes and on each stats push (`web-ui/src/state.ts:65-69, 96, 126, 174, 203`).

The stats stream already runs on a loop-side cadence and the panel already holds every value it
sets; a second push path for either would duplicate a channel that exists.

Enforcement: `tests/test_dormancy.nim:29-40` holds every carried `dormantWhen` to a registered
predicate and every registered predicate to a carrier, and the suite walks each predicate's named
fields against the state records, so a renamed field breaks loudly. What a predicate means, and the
promise of no new subscription and no per-frame call, are **agent-checkable**: launch the app,
toggle bloom off, and confirm the grade controls dim in the same tick as the toggle with no stats
push in between; then let the field ignite and confirm the field-appearance controls wake on the
next stats push and no sooner.

#### Scenario: A config-conditioned control wakes in the same tick
- **WHEN** the user enables bloom
- **THEN** the grade controls leave dormancy in the same tick as the toggle, with no stats push in
  between

#### Scenario: A world-conditioned control follows the stats cadence
- **WHEN** the field ignites while the panel is open
- **THEN** the field-appearance controls leave dormancy on the next stats push

### Requirement: The boundary serves every number and catalog the panel displays

The boundary SHALL serve, from Nim, every value the panel renders: the descriptor payload built once
at module-eval time (`src/web_api.nim:286-290`, exposed at `:1131`), the named reaction-diffusion
regime catalog carrying each regime's id, label, coordinates, and deposit floor
(`src/web_api.nim:644-654`, served at `:1200-1202`, the table itself in `config_ranges.nim`), the
palette-scheme catalog (`src/web_api.nim:1055-1062`), the colormap catalog
(`src/web_api.nim:1073-1080`), the preset storage keys (`src/web_api.nim:1303-1308`), and the
species and matrix-cell colors computed by Nim color math (`src/web_api.nim:1261-1279`). TypeScript
SHALL restate none of them: `web-ui/src/garden-api.ts` declares types and no values.

Enforcement: a compile-time `doAssert` guards the one hand-written catalog, failing the Nim build
when the colormap label list and the index bounds disagree (`src/web_api.nim:1064-1071`). The
descriptor table's agreement with the range and default authorities is pinned by
`tests/test_param_descriptor.nim`. That TypeScript restates none of the served numbers is
**agent-checkable**: search `web-ui/src/` for a numeric or string literal standing in for a served
range, default, coordinate, label, or storage key, and confirm each candidate arrives from the
boundary instead.

#### Scenario: A slider is drawn entirely from served numbers
- **WHEN** the panel renders a parameter control
- **THEN** its range, step, precision, default, label, group, and hint all come from `descriptor()`

#### Scenario: An unlabelled colormap ramp fails the build
- **WHEN** a colormap ramp is added without a matching label entry
- **THEN** `just happen` fails at the Nim compile step

### Requirement: The matrix editor's coordinates come through the boundary

The boundary SHALL serve the attraction matrix's bounds, step, and display precision beside its
existing matrix surface, the stride, the clamp, and the cell colour, so the editor restates none of
them and a recalibration of the matrix is a Nim-side change alone. `matrixSpec()` answers the served
band, step, and precision from the range authority (`src/web_api.nim:1265-1273`), `matrixStride()`
the stride (`:1274`), `clampMatrixValue` the commit clamp (`:1263-1264`), and `matrixCellColor` the
cell background (`:1261-1262`).

The editor reads all four and holds no numeric bound of its own: the cell input's `min`, `max`, and
`step` come from the served spec and the cell text from its precision
(`web-ui/src/components/MatrixEditor.tsx:35, 48, 102-104`), and a commit parses through the
handed-in clamp (`web-ui/src/lib/matrix-cell.ts:25-31`, called at
`web-ui/src/components/MatrixEditor.tsx:57-65`).

Enforcement: `web-ui/test/matrix-cell.test.ts:10-40` pins the edit machine, including that a commit
routes through whatever clamp it is handed and that a commit holding no number is a revert; it
supplies its own clamp as a stand-in, so it proves the routing and never the bounds. That no numeric
bound, step, or precision for the matrix appears in TypeScript is **agent-checkable**: search
`web-ui/src/` for numeric literals in the matrix band and confirm all four values arrive from
`matrixSpec()` and `clampMatrixValue`.

#### Scenario: The editor holds no matrix literals
- **WHEN** the matrix cell input is rendered
- **THEN** its step, its display precision, and the clamp applied on commit all come from the
  boundary, and no numeric bound, step, or precision for the matrix appears in TypeScript

#### Scenario: A recalibration needs no TypeScript edit
- **WHEN** the matrix bounds or step change in the range authority
- **THEN** the editor reflects them after a rebuild with no change under `web-ui/`

### Requirement: Help content is served from Nim like every other authored string

The boundary SHALL expose the help content keyed by group id, sourced from the markdown files
`staticRead` at Nim-compile time, so TypeScript authors no help prose and stores none. `help()`
serves each entry's key and body from `HelpEntries` (`src/web_api.nim:1132-1139`, built at
`src/ui/api/help_content.nim:79-87`).

This is the same ownership rule that already places labels, hints, and notch tables in Nim: the
panel renders what the boundary serves.

Enforcement: the coverage relations between help files and descriptors belong to `in-app-help`,
which this requirement only serves. That the panel holds no fallback text is **agent-checkable**:
launch the app, open help, and confirm each section's text matches its file under `docs/help/`;
`HelpPanel` parses only what `ctrl.api.help()` returns
(`web-ui/src/components/HelpPanel.tsx:75-77`).

#### Scenario: Help arrives through the boundary
- **WHEN** the help panel requests a group's content
- **THEN** it receives the markdown the boundary holds, with no fallback text in the panel

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
storage I/O. `exportPresetJson` and `exportPresetJsonPretty` snapshot the live CONFIG, the
attraction matrix, the species chemistry, and the species palette into the versioned schema
(`src/web_api.nim:863-946, 1312-1315`; the chemistry channels are copied at `:925-927`).
`applyPresetJson` SHALL return an `{ok, error}` outcome and never throw
(`src/web_api.nim:1316-1329`): it pre-checks parseability through the `jsonParseable` FFI helper
(`src/web_api.nim:69-70`) because `std/json.parseJson` on the JS backend delegates to `JSON.parse`,
whose SyntaxError is a foreign exception Nim's `except ValueError` cannot catch. Validation degrades
missing or malformed fields to clamped defaults and rejects only a `schemaVersion` newer than the
build understands (`src/preset.nim:356-674`). Application SHALL walk `presetApplySteps()` in its
fixed order (`src/web_api.nim:947-1046`, `src/ui/presets/preset_store_core.nim:76-83`) and SHALL
persist nothing.

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
