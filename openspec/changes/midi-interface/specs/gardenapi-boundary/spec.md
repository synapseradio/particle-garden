## MODIFIED Requirements

### Requirement: Stats reach the panel by push on a loop-side cadence

The boundary SHALL expose `onStats(callback)` for subscription (`src/web_api.nim:1298-1299`) and
SHALL push samples from the frame loop rather than answering polls: `pushStats`
(`src/web_api.nim:805-861`) is called by `app.nim` inside the frame loop's cadence window
(`src/app.nim:284, 315`). The cadence belongs to the loop, and a subscriber asks for no rate.

A sample SHALL carry raw numbers with every formatting decision left to the panel: frame rate,
particle count, the per-pass GPU timings, and the field's alive-cell census. Beside them it SHALL
carry records keyed by parameter id, `params`, `ceilings`, and `excursions`, whose id sets the panel
SHALL apply as they arrive rather than from any compiled list of its own
(`web-ui/src/state.ts:101-120`). With no subscriber registered, `pushStats` SHALL return before
allocating anything (`src/web_api.nim:820-821`).

Enforcement: the build. The sample's fields are declared in `web-ui/src/garden-api.ts:121-147` and
checked by `tsc --noEmit`, so a field the Nim side stops writing surfaces at the panel as a typecheck
failure or an undefined value. The cadence's ownership is review-enforced.

#### Scenario: A subscriber receives samples without polling
- **WHEN** the panel has registered an `onStats` callback
- **THEN** the frame loop invokes it with a fresh sample on its own cadence

#### Scenario: An unsubscribed boundary does no stats work
- **WHEN** no `onStats` callback is registered
- **THEN** `pushStats` allocates no sample object

#### Scenario: An id absent from the panel's own source still applies
- **WHEN** a sample's `params`, `ceilings`, or `excursions` record carries an id the panel names
  nowhere in its own source
- **THEN** the panel applies the value by comparison and renders it against the served descriptor

## ADDED Requirements

### Requirement: The stats sample reports every parameter written outside the panel

The `params` record SHALL carry the current value of every parameter id a writer outside the panel
can move, derived from the active mapping: every `Write` row target and every axis of every `Tour`
row's registered tour, recomputed when the mapping changes. The two enumerated weather loops
(`src/web_api.nim:822-828`) go, because the tours that fed them are rows and their axes arrive
through the same derivation. Values SHALL be sent on every push whether or not anything moved them,
so the panel reports what the simulation holds without tracking which writer moved which id
(`src/web_api.nim:811-819`). The record SHALL carry ids and values alone, naming no writer, so a
panel that applies whatever arrives stays correct under a user-editable id set.

Enforcement: the build for the record's declared type (`web-ui/src/garden-api.ts:141`) and the
panel's comparison loop (`web-ui/src/state.ts:107-113`). The id set is review-enforced and
build-verified, since `web_api.nim` compiles only on the JS backend and no native test imports it
(`src/web_api.nim:29-32`), while the row targets it unions come from the mapping that
`tests/test_control_matrix.nim` validates.

#### Scenario: A parameter a mapping moved arrives at the panel
- **WHEN** a `Write` row moves a parameter and a push follows
- **THEN** the sample carries that id's current value and the panel's slider stands where the row
  left it

#### Scenario: Editing the mapping edits the reported set
- **WHEN** a `Write` row's target changes
- **THEN** the next push carries the new target's id, and drops any id no row in the active mapping
  names

#### Scenario: A tour's axes report without being enumerated
- **WHEN** a `Tour` row is present in the active mapping
- **THEN** the push carries every axis of its registered tour, with no axis list written at the
  boundary

#### Scenario: A quiet parameter still reports
- **WHEN** nothing has written a reported id since the previous push
- **THEN** the sample carries that id's current value all the same

### Requirement: The stats sample carries the live excursion of every modulated parameter

The sample SHALL carry an `excursions` record beside `ceilings`, holding the signed travel offset of
every parameter a live excursion moves, and SHALL send it empty when no excursion is live. Offsets
SHALL be travel in [-1, 1], the coordinate the served travel pair already speaks
(`src/web_api.nim:1155-1162`), so the panel shades the span from the handle's base by the offset
through the pattern the derived ceilings use (`web-ui/src/components/ParamSlider.tsx:55-68`,
`web-ui/src/state.ts:114-120`) and computes no curve of its own.

The record SHALL refresh on the push cadence, roughly 500 ms (`src/app.nim:284`), which bounds the
meter alone: the world runs each excursion at frame rate whatever the push reports.

Enforcement: the build for the record's declared type in `web-ui/src/garden-api.ts`, plus
`tests/test_control_matrix.nim`, which pins the travel offsets in the arithmetic that produces them.
The cadence limit is review-enforced: it bounds what the meter shows, and no gate measures it.

#### Scenario: A modulated slider shades from its base
- **WHEN** a `Modulate` row holds a parameter away from its stored value and a push follows
- **THEN** the sample carries that id's signed travel offset and the panel shades that span of the
  track

#### Scenario: Nothing modulated, nothing carried
- **WHEN** no excursion is live
- **THEN** `excursions` arrives empty and the panel shades no modulation

#### Scenario: The handle stays where the user left it
- **WHEN** an excursion is live on a parameter
- **THEN** `params` and `getParam` report the stored value for that id, and the offset arrives only
  in `excursions`

### Requirement: The boundary serves the mapping surface the panel renders

The boundary SHALL serve the active mapping's rows for reading, each row carrying its kind, its
source id, the fields of that kind, its target, its rank where the kind has one, and whether its
source resolves against current declarations. The panel SHALL render a row, mark it unresolved, and
detect two `Write` rows colliding on one parameter from the served rows alone, with no second call
and no value of its own.

The boundary SHALL accept an edit to the mapping's rows, the rank of a `Write` row included, and
SHALL validate every edit by the relations the mapping schema applies at decode, leaving the mapping
unchanged and reporting the refusal when an edit would produce an illegal row.

The boundary SHALL serve the shipped default mapping, so the panel and the help file render it from
one home.

Enforcement: the build, since the served surface is declared in `web-ui/src/garden-api.ts` and
checked by `tsc --noEmit`. Row validity and the default mapping's contents are pinned by
`tests/test_control_matrix.nim` and by the compile-time gate on the shipped rows, and
`tests/test_help_content.nim` holds the help file against the shipped mapping's targets.

#### Scenario: A row is drawn entirely from served fields
- **WHEN** the panel draws a mapping row
- **THEN** its kind, source, target, rank, and resolution state all come from the served row

#### Scenario: A collision is visible without another call
- **WHEN** two `Write` rows target one parameter
- **THEN** the served rows carry both targets and both ranks, so the editor exposes rank where they
  collide

#### Scenario: An illegal edit changes nothing
- **WHEN** the panel submits an edit whose resulting row validation refuses
- **THEN** the mapping is unchanged and the boundary reports the refusal

#### Scenario: The shipped mapping is displayed from one home
- **WHEN** the panel or the help file shows the shipped default mapping
- **THEN** every row it shows comes from the boundary

### Requirement: The boundary serves learn arming, cancelling, and state

The boundary SHALL expose arming learn for a named slot, cancelling learn, and a synchronous read of
the learn state the panel renders. The panel SHALL restate no part of what qualifies as a binding
delivery. When a binding completes, the completed row SHALL reach the panel through the same surface,
and it SHALL persist through the ordinary edit path.

Enforcement: the build for the served methods, checked against `web-ui/src/garden-api.ts` by
`tsc --noEmit`. Qualification and the completed row's contents are pinned by
`tests/test_control_matrix.nim`.

#### Scenario: Arming reports itself
- **WHEN** the panel arms learn for a slot
- **THEN** the served learn state reports that slot armed

#### Scenario: A completed binding reaches the panel
- **WHEN** a qualifying delivery completes the binding
- **THEN** the served rows carry the completed row and the learn state reports nothing armed

#### Scenario: Cancelling clears the arming alone
- **WHEN** the panel cancels learn
- **THEN** the served learn state reports nothing armed and every row is as it was

### Requirement: The panel keys mapping storage on strings the boundary serves

The boundary SHALL own the mapping schema, its validation, its defaults, and the loading of a stored
mapping, leaving the panel localStorage I/O alone, the split presets already use
(`src/web_api.nim:1301-1311`). It SHALL
serve the storage key the user mapping is written under, and the panel SHALL restate no key.

The mapping key SHALL be distinct from every preset key, so a preset save touches no mapping and a
mapping save touches no preset.

Enforcement: `tests/test_control_matrix.nim` pins the schema, its validation, and its defaults. The
served-key relation is review-enforced and build-verified, matching the preset precedent whose
distinct keys are pinned by `tests/test_preset_store_core.nim:71-73`.

#### Scenario: The panel writes where Nim says
- **WHEN** the panel persists an edited mapping
- **THEN** it writes under the served key and composes no key of its own

#### Scenario: Stored text is validated in Nim
- **WHEN** the panel reads stored mapping text
- **THEN** it hands the text to the boundary, which validates it and answers with the mapping to run

#### Scenario: A preset save leaves the mapping alone
- **WHEN** a preset is saved
- **THEN** nothing stored under the mapping key changes
