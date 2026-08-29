## MODIFIED Requirements

### Requirement: One world has one particle budget

There SHALL be exactly one particle budget, named once. `SPH_PARTICLE_CEILING`,
`RD_PARTICLE_CEILING`, and `COUPLING_PARTICLE_CEILING` — three names for one number, held equal by a
`doAssert` at `src/config_ranges.nim:337` — collapse into it. None of the three was measured: the SPH
one cites reasoning rather than a benchmark (`src/sph_core.nim:35-38`) and the field one is that
number under another name, so the collapse removes a false precision rather than a real bound.

Applying a preset SHALL enforce that budget, closing the gap where the preset path validates the
count against the slider bounds alone. The two count paths differ deliberately
(`src/web_api.nim:701-714`, `:895-908`): the particleCount slider RESIZES in place — dragging it
does not destroy the world it is adjusting, so the surviving particles keep their positions,
velocities, and species — while applying a preset re-initializes, because a preset is a different
world and there is no population the user expects to survive adopting it. Raising the budget does
not restore a previous count.

#### Scenario: Preset click adopts a different world
- **WHEN** a preset is applied over a living world
- **THEN** the count clamps to the budget and the population re-initializes as the preset's own

#### Scenario: A preset cannot exceed the budget
- **WHEN** a preset carries a count above the budget
- **THEN** the applied count is the budget, whether or not the preset was constructed in Nim

#### Scenario: The budget does not depend on what the world is doing
- **WHEN** any coupling strength changes
- **THEN** the particle budget is unchanged

#### Scenario: The slider resizes without destroying the world
- **WHEN** the user commits a new particleCount on the slider
- **THEN** the population resizes in place, keeping the survivors — while a speciesCount commit
  still re-initializes, because changing how many species exist changes what every particle's
  species index means

## ADDED Requirements

### Requirement: Descriptors carry labelled notches

A parameter descriptor SHALL be able to carry a table of labelled notches — values known to produce
something worth seeing — served to the panel through `descriptor(id)` like every other number.
Notches are authored in Nim; the panel renders them and never invents its own.

Every notch value SHALL lie inside its parameter's range, asserted by
tests/test_param_descriptor.nim, because a labelled value the slider cannot reach is the same defect
as an unlabelled range whose interesting parts are unfindable.

#### Scenario: Slider shows where the good values are
- **WHEN** the panel renders a slider whose descriptor declares notches
- **THEN** it draws a labelled tick at each notch value, taken from the descriptor

#### Scenario: Unreachable notch fails the suite
- **WHEN** a notch is declared outside its parameter's range
- **THEN** `just test` fails naming the parameter and the notch

### Requirement: Coupled parameters have a joint selector

Where a regime is located by two or more parameters together, the panel SHALL offer a named selector
that sets them jointly, in addition to the individual sliders. A notch on one axis alone does not
locate a regime, so notches on coupled parameters are informative but not sufficient.

#### Scenario: Choosing a named regime
- **WHEN** the user picks a named regime
- **THEN** every parameter that regime specifies is set together through the clamped boundary


### Requirement: Parameter writes dispatch from generated field names

The parameter write path SHALL dispatch by walking the typed state records' field names at compile
time rather than through a hand-written case, so a descriptor id naming no field in the store it
routes to fails the build.

This closes the silent-failure class the hand-written case admits through its trailing
`else: discard` (src/web_api.nim:508): a control that clamps its value, writes nowhere, and reports
success. Three routes keep explicit arms because none is a field assignment — the palette pair
writes editor state and triggers a colour regeneration; the camera route writes the live camera,
which is view state deliberately absent from CONFIG; and the species-chemistry route refuses with a
console warning naming `chemistry()` as the write path, because per-species values are written by
reference through the chemistry surface and silence would read as a dead control
(`src/web_api.nim:603-608`).

#### Scenario: A misnamed descriptor fails the build
- **WHEN** a descriptor id does not match any field of its routed store
- **THEN** `just happen` fails at compile time naming the id

#### Scenario: Existing writes are unchanged
- **WHEN** any shipped parameter is written after the dispatch is generated
- **THEN** the same field of the same store receives the same clamped value as before

### Requirement: The descriptor payload carries curve, horizon, and dormancy

`descriptor()` SHALL serve the travel curve and its exponent, the response horizon, and the
dormancy predicate's name with its resolved line alongside the existing fields, so the panel
restates none of them. Probe ids and exemptions stay native machinery: the legibility suite
consumes them in Nim, and the panel has no use for them (design E1).

The payload is built once at module-eval time and cached, so its growth costs one array rather than
per-frame work.

#### Scenario: The panel computes no mapping of its own
- **WHEN** the panel positions a handle for a curved parameter
- **THEN** it obtains the position from the boundary rather than computing the curve

### Requirement: Help content is served from Nim like every other authored string

The boundary SHALL expose the help content keyed by group id, sourced from the markdown files
`staticRead` at Nim-compile time, so TypeScript authors no help prose and stores none.

This is the same ownership rule that already places labels, hints, and notch tables in Nim: the panel
renders what the boundary serves.

#### Scenario: Help arrives through the boundary
- **WHEN** the help panel requests a group's content
- **THEN** it receives the markdown the boundary holds, with no fallback text in the panel

### Requirement: Dormancy evaluates where its state already lives

The boundary SHALL evaluate a dormancy predicate over panel-visible state (a strength, a toggle,
another parameter's value) synchronously against the state the panel already mirrors, and SHALL
evaluate a predicate over world state against the pushed stats it already streams. It SHALL NOT add
a new subscription or a per-frame call for either.

The stats stream already runs on a loop-side cadence, and the panel already holds every value it
sets; a second push path for either would duplicate a channel that exists.

#### Scenario: A config-conditioned control wakes in the same tick
- **WHEN** the user enables bloom
- **THEN** the grade controls leave dormancy in the same tick as the toggle, with no stats push in
  between

#### Scenario: A world-conditioned control follows the stats cadence
- **WHEN** the field ignites while the panel is open
- **THEN** the field-appearance controls leave dormancy on the next stats push

### Requirement: The matrix editor's coordinates come through the boundary

The boundary SHALL serve the attraction matrix's bounds, step, and display precision beside its
existing matrix surface — the stride, the clamp, and the cell colour — so the editor restates none
of them and a recalibration of the matrix is a Nim-side change alone.

#### Scenario: The editor holds no matrix literals
- **WHEN** the matrix cell input is rendered
- **THEN** its step, its display precision, and the clamp applied on commit all come from the
  boundary, and no numeric bound, step, or precision for the matrix appears in TypeScript

#### Scenario: A recalibration needs no TypeScript edit
- **WHEN** the matrix bounds or step change in the range authority
- **THEN** the editor reflects them after a rebuild with no change under `web-ui/`
