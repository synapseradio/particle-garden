## ADDED Requirements

### Requirement: Parameter writes dispatch from generated field names

The parameter write path SHALL dispatch by walking the typed state records' field names at compile
time rather than through a hand-written case, so a descriptor id naming no field in the store it
routes to fails the build.

This closes the silent-failure class the hand-written case admits through its trailing `else: discard`
(src/web_api.nim:424): a control that clamps its value, writes nowhere, and reports success. The
palette parameters keep explicit arms — they write editor state and trigger a colour regeneration,
which is not a field assignment.

#### Scenario: A misnamed descriptor fails the build
- **WHEN** a descriptor id does not match any field of its routed store
- **THEN** `just happen` fails at compile time naming the id

#### Scenario: Existing writes are unchanged
- **WHEN** any shipped parameter is written after the dispatch is generated
- **THEN** the same field of the same store receives the same clamped value as before

### Requirement: The descriptor payload carries probe, curve, horizon, and dormancy

`descriptor()` SHALL serve the probe id or exemption, the travel curve and its exponent, the response
horizon, and the dormancy predicate's name alongside the existing fields, so the panel restates none
of them.

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

### Requirement: Dormancy state reaches the panel through the existing stats stream

The predicate deciding whether a control can currently act SHALL be evaluated against the pushed stats
the boundary already streams, rather than through a new subscription or a per-frame call.

The stats stream already runs on a loop-side cadence. Adding a second push path for a condition that
changes on the same timescale would duplicate it.

#### Scenario: Dormancy follows the world
- **WHEN** the field ignites while the panel is open
- **THEN** the field-appearance controls leave dormancy on the next stats push
