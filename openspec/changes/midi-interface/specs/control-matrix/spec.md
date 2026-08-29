## Purpose

The one spine every mapped control runs through: rows binding a source to a parameter, an action, or
a gesture, with arbitration, takeover, persistence, and learn. Past delivery the matrix cannot tell
one source family from another, so a family joins by registering sources and touches no matrix code.

## ADDED Requirements

### Requirement: A source family registers the sources it carries

The matrix SHALL accept a registration naming a family id and a set of declarations, each declaration
carrying a source id, a kind of `continuous` or `event`, and a label. A family SHALL prefix every
source id it mints with its own family id and a colon, and the matrix SHALL treat the id as opaque
past that prefix. A second registration from the same family SHALL replace that family's declared set
whole, which is how a family declares lazily and grows as its devices arrive. A registration SHALL
leave every other family's declarations untouched.

Declarations SHALL feed row validation, the mapping editor, and help, and the matrix SHALL serve the
declared set with each source's kind and label so the editor restates none of them.

Enforcement: `tests/test_control_matrix.nim` covers registration, whole-set replacement, and row
resolution against declarations. The prefix obligation is review-enforced, since the matrix reads the
id as opaque and checks no grammar.

#### Scenario: A registered source resolves the rows that name it
- **WHEN** a family registers a declaration whose id a stored row names
- **THEN** that row reports as resolved and takes effect at the next flush

#### Scenario: Re-registration replaces rather than merges
- **WHEN** a family registers a second time with a different set
- **THEN** its declared sources are exactly the second set, and ids present only in the first stop
  resolving

#### Scenario: One family's registration leaves another's alone
- **WHEN** a second family registers its declarations
- **THEN** the first family's declarations and the rows naming them are unchanged

### Requirement: A row admits only legal combinations of source and target

A row SHALL carry exactly one of four kinds and only the fields that kind uses: `Modulate` with a
parameter id, a depth in [-1, 1] and a slew; `Write` with a parameter id, a jump flag and a rank;
`Fire` with an action id and an ordinal; `Touch` with grid columns, grid rows, and a base note.
The row type SHALL admit no action or gesture field on a `Modulate` row, so modulating an action
fails the Nim compile.

Validation SHALL hold four relations against the source declarations and the descriptor table:

- a `Modulate` or `Write` row names a source declared `continuous` and a parameter id the descriptor
  table serves
- a `Fire` or `Touch` row names a source declared `event`, and a `Fire` row names an action id the
  boundary serves
- `particleCount` and `speciesCount` are refused as `Modulate` and `Write` targets, because their
  effect rides the slider-release side effect a matrix write never produces
  (`src/web_api.nim:767-780`)
- a `Modulate` target names a parameter of the simulation or render record store, while a `Write`
  target may name any id `setParam` routes (`src/web_api.nim:585-639`)

Enforcement: the row kinds are typed, so a field belonging to another kind fails the Nim compile.
`tests/test_control_matrix.nim` holds the four relations against the live descriptor table.

#### Scenario: A continuous target driven from an event source is refused
- **WHEN** a `Modulate` or `Write` row names a source declared `event`
- **THEN** validation refuses the row

#### Scenario: A gesture driven from a knob is refused
- **WHEN** a `Fire` or `Touch` row names a source declared `continuous`
- **THEN** validation refuses the row

#### Scenario: The count parameters are refused as targets
- **WHEN** a `Modulate` or `Write` row names `particleCount` or `speciesCount`
- **THEN** validation refuses the row

#### Scenario: A modulate target outside the record stores is refused
- **WHEN** a `Modulate` row names a palette or camera parameter
- **THEN** validation refuses the row, and a `Write` row naming that same parameter is accepted

#### Scenario: An action the boundary does not serve is refused
- **WHEN** a `Fire` row names an action id absent from the served actions
- **THEN** validation refuses the row

### Requirement: Delivery keeps the latest continuous value and queues events in order

A family sets a continuous source's value as often as it likes, and the matrix SHALL keep only the
latest value per source id, clamping a value outside [0, 1] at that entry point. A family SHALL
emit an event carrying a magnitude in [0, 1] and an ordinal locating the event inside the source's
own space, sending ordinal zero where the source has no such space. Events SHALL queue in arrival
order and drain at the next flush.

Enforcement: `tests/test_control_matrix.nim` covers latest-wins coalescing, boundary clamping, and
queue order.

#### Scenario: A sweep collapses to its latest value
- **WHEN** a family sets one source many times between two flushes
- **THEN** the flush reads the last value alone and the intermediate values reach nothing

#### Scenario: An out-of-range value is clamped at delivery
- **WHEN** a family delivers a value outside [0, 1]
- **THEN** the matrix holds the nearer of 0 and 1 and no consumer sees the raw number

#### Scenario: Events keep their arrival order
- **WHEN** a family emits several events between two flushes
- **THEN** the flush consumes them in the order they arrived

#### Scenario: A source with no ordinal space sends zero
- **WHEN** a family emits an event carrying ordinal zero
- **THEN** a `Fire` row selecting ordinal zero matches it and a one-cell `Touch` grid resolves its
  only cell

### Requirement: The flush runs once per frame between the weathers and physics

The matrix SHALL drain staged values and events exactly once per frame, called from the frame loop
after the weather writes and before `physics` (`src/app.nim:257-271`), so within a frame a hand on
hardware lands after ambient drift. Families SHALL neither call the flush nor observe its result.

A frame in which no source delivered and no excursion is live SHALL write nothing and leave the
CONFIG mirror alone.

Enforcement: the call site in `src/app.nim`'s frame loop is build-verified and review-enforced,
alongside the import-order constraint that file already carries (`src/app.nim:8-11`).
`tests/test_control_matrix.nim` covers what one flush consumes and produces from staged input.

#### Scenario: The hand lands after the drift
- **WHEN** a weather and an engaged `Write` row both move one parameter in one frame
- **THEN** the frame runs the row's value

#### Scenario: A queued event fires once
- **WHEN** an event is staged between two frames
- **THEN** exactly one flush consumes it and later frames act on it no further

#### Scenario: An idle frame writes nothing
- **WHEN** no source has delivered since the previous flush and no excursion is live
- **THEN** the flush writes no parameter and re-mirrors nothing

### Requirement: Modulate excursions sum in travel space at the one effect-time clamp site

For each modulated parameter each frame, the base travel SHALL be the stored value's position on the
track, the offset SHALL be the sum over that parameter's `Modulate` rows of depth times the row's
slewed source value, and the effective value SHALL be the value at the base plus the offset clamped
into [0, 1], bounded by the live ceiling where the parameter's bound is derived
(`src/ui/api/slider_curve.nim:42-74`).

Effective values SHALL reach CONFIG through the existing mirror at the one effect-time clamp site
(`src/web_api.nim:135-160`), and the stored record SHALL NOT be written. `getParam`, an exported
preset, and the slider's base value therefore all report what the user last wrote while an excursion
is live.

A depth of zero SHALL be an ordinary value that moves nothing. A row's slew SHALL approach the latest
source value exponentially over wall-clock time with the row's time constant, and a slew of zero
SHALL pass the raw value. The matrix SHALL recompute and re-mirror while any excursion is live and
for the frame after the last one ends, so the return to base lands.

Enforcement: `tests/test_control_matrix.nim` pins the summing, clamping, and slew arithmetic against
real descriptors. Holding the stored record untouched is review-enforced at the mirror site, whose
own comment states the rule (`src/web_api.nim:136-160`). The preset half is review-enforced and
requires the snapshot to read stored state for every modulated field, since `snapshotPreset` reads
CONFIG for all of them but `sphStiffness` (`src/web_api.nim:868-907`) and no gate detects the
difference.

#### Scenario: Two rows on one parameter add
- **WHEN** two `Modulate` rows target one parameter
- **THEN** the frame runs the value at the sum of their travel offsets

#### Scenario: Modulation never moves the user's value
- **WHEN** an excursion is live on a parameter
- **THEN** `getParam` and an exported preset report the value the user last wrote for it

#### Scenario: Release returns the world to the base
- **WHEN** every excursion on a parameter reaches zero
- **THEN** the following frame runs the stored value again

#### Scenario: Zero depth changes nothing
- **WHEN** a row's depth is zero
- **THEN** the parameter's effective value equals its stored value whatever its source does

#### Scenario: An excursion cannot leave the track
- **WHEN** the summed offset would carry travel past either end
- **THEN** the effective value is the value at that end, under the live ceiling where the parameter's
  bound is derived

#### Scenario: A slewed row approaches its source value over its time constant
- **WHEN** a source jumps and its row carries a non-zero slew
- **THEN** the excursion approaches the new value over that time constant, while a row with zero slew
  applies it on the next frame

### Requirement: Write rows write through the path the panel writes through

A `Write` row SHALL read its source value as travel and turn it into a parameter value through the
same served travel pair the panel's slider calls, with no ceiling bound
(`src/web_api.nim:1155-1162`), then write it through the clamped synchronous path every panel write
uses (`src/web_api.nim:585-639`). The stored record therefore takes the envelope value that travel
names, while the effect-time clamp keeps the world under the live ceiling, so a knob resting above a
ceiling means what a slider resting in the shaded region means
(`web-ui/src/components/ParamSlider.tsx:55-68`). The written value SHALL persist where the row left
it, SHALL be what `getParam` answers, and SHALL save into presets. Every write a flush produces SHALL have landed in the typed store and the CONFIG
mirror before the flush returns.

Enforcement: `tests/test_control_matrix.nim` pins travel-to-value mapping against real descriptors.
Routing through the existing write path is build-verified and review-enforced, matching the weather
precedent that writes whole tour points through the same path (`src/app.nim:257-269`).

#### Scenario: A knob means what the panel's own write means
- **WHEN** a `Write` row delivers a source value
- **THEN** the parameter holds the value that travel names on the descriptor's curve and lattice

#### Scenario: A written value survives into a preset
- **WHEN** a preset is exported after a `Write` row moved a parameter
- **THEN** the preset carries the value the row wrote

#### Scenario: A knob above a live ceiling keeps its intent
- **WHEN** a `Write` row's travel names a value above the parameter's live ceiling
- **THEN** the store takes the value that travel names and the frame runs the ceiling

#### Scenario: A row cannot outrun the descriptor
- **WHEN** a `Write` row's value would fall outside the parameter's range
- **THEN** the descriptor's bound is what reaches the store, exactly as it does for a panel write

#### Scenario: The next frame runs what the row wrote
- **WHEN** a `Write` row writes during a flush
- **THEN** the frame dispatched after that flush reads the written value from CONFIG

### Requirement: Soft takeover engages by crossing the live value

Soft takeover SHALL be the default for a `Write` row, with jump selectable per row. A row with soft
takeover SHALL write nothing until its incoming travel crosses the parameter's current travel or
lands within one position step of it, and SHALL keep writing once engaged. A row SHALL disengage when
the parameter moves more than one position step away from the travel that row last wrote, which
covers a slider move, a preset apply, and another row's write. A row with jump SHALL be engaged
permanently.

Enforcement: `tests/test_control_matrix.nim` covers engagement by crossing, engagement inside one
position step, and disengagement across a slider move, a preset apply, and another row's write.

#### Scenario: A resting knob moves nothing
- **WHEN** a soft-takeover row's source sits away from the parameter's current travel and moves
  without crossing it
- **THEN** the parameter does not move

#### Scenario: Crossing hands the parameter over
- **WHEN** a soft-takeover row's source travel crosses the parameter's current travel
- **THEN** the row writes from that delivery onward

#### Scenario: Something else moving the parameter releases the row
- **WHEN** a slider, a preset, or another row moves the parameter more than one position step from
  the engaged row's last written travel
- **THEN** that row disengages and writes nothing until it crosses again

#### Scenario: A row's own writes do not release it
- **WHEN** an engaged row keeps moving its parameter across many frames
- **THEN** it stays engaged, since the parameter tracks the travel that row last wrote

#### Scenario: A jump row writes immediately
- **WHEN** a row carries jump and its source moves
- **THEN** the parameter takes the row's value without any crossing

### Requirement: An engaged Write row suspends a weather on its parameter

While a `Write` row holds engagement on a parameter a weather tours, that weather's per-frame write
SHALL skip that parameter and SHALL keep writing its other axes. On disengagement the axis SHALL
return to the weather, which lands the tour's current point on the next frame.

Enforcement: review-enforced and build-verified at the flush site, which serves both writers, so
neither pure core learns of the other. `tests/test_control_matrix.nim` covers which ids a flush
reports as suspended for a given set of engaged rows.

#### Scenario: The hand holds the parameter alone
- **WHEN** a weather is running and a `Write` row is engaged on one of its axes
- **THEN** that parameter answers only the row while the engagement holds

#### Scenario: The rest of the tour keeps moving
- **WHEN** one axis of a running weather is suspended
- **THEN** its other axes continue to drift

#### Scenario: The weather resumes where its tour stands
- **WHEN** an engaged row disengages from a suspended axis
- **THEN** the next frame writes that axis from the tour's current point rather than from where the
  row left it

### Requirement: Colliding Write rows apply in ascending rank

A `Write` row SHALL carry a user-visible rank ordering it against other `Write` rows targeting the
same parameter. Within a frame, engaged rows with fresh values SHALL apply in ascending rank, so the
highest rank lands last and owns the frame. Rank SHALL order rows without regard to which family
their sources come from, and the matrix SHALL keep no winner state between frames.

Enforcement: `tests/test_control_matrix.nim` covers apply order for colliding rows and the absence of
carried-over ownership.

#### Scenario: The higher rank owns the frame
- **WHEN** two engaged `Write` rows deliver fresh values for one parameter in one frame
- **THEN** the parameter holds the higher-ranked row's value when the flush returns

#### Scenario: A quiet frame carries no ownership forward
- **WHEN** the higher-ranked row delivers nothing in the next frame and the lower-ranked row does
- **THEN** the parameter takes the lower-ranked row's value

#### Scenario: Rank ignores the family
- **WHEN** two colliding rows name sources from different families
- **THEN** rank alone decides which value lands last

### Requirement: Fire rows select an action by ordinal

A `Fire` row SHALL run its action when an event arrives on its source carrying its ordinal, and SHALL
do nothing for an event carrying any other ordinal. Actions SHALL reach the paths the boundary
already serves: the six named regimes (`src/config_ranges.nim:268-277`, applied at
`src/web_api.nim:670-688`), the momentary actions, and the toggles (`src/web_api.nim:1164-1295`).
Several events selecting one regime target within one frame SHALL collapse to the latest.

Enforcement: `tests/test_control_matrix.nim` covers ordinal selection, the non-match, and the regime
collapse. That each action id resolves to a served path is review-enforced through the validation
relation on action ids.

#### Scenario: A matching ordinal fires once
- **WHEN** an event arrives on a `Fire` row's source carrying that row's ordinal
- **THEN** the action runs exactly once

#### Scenario: Another ordinal fires nothing
- **WHEN** an event arrives on the same source carrying a different ordinal
- **THEN** the row's action does not run

#### Scenario: Two different actions in one frame both run
- **WHEN** events in one frame fire two `Fire` rows, one carrying a momentary action and one a toggle
- **THEN** both actions run

#### Scenario: A flurry of regime selections settles on the last
- **WHEN** several events selecting regimes arrive in one frame
- **THEN** the frame applies the last of them alone

### Requirement: Touch rows lay a pad grid over the visible view

A `Touch` row SHALL lay a grid of its declared columns and rows over the visible view. The event's
ordinal minus the row's base note SHALL index the cell, row-major from the bottom left, and an event
indexing outside the grid SHALL be discarded. The cell's center SHALL convert to world coordinates
through the live camera at capture, the conversion and the reason the pointer blast already uses
(`src/canvas_input.nim:152-153`). The event's magnitude SHALL scale the blast's strength, which then
decays on the existing path (`src/canvas_input.nim:70`). Several touch events in one frame SHALL
resolve to the latest, matching a second tap replacing the first.

Enforcement: `tests/test_control_matrix.nim` covers cell indexing, the discard outside the grid, and
strength scaling. The blast entry point gains a strength argument in
`src/ui/state/input_state.nim:60-64`, pinned by `tests/test_input.nim`.

#### Scenario: The bottom-left pad blasts the bottom-left of the view
- **WHEN** an event arrives carrying the row's base note
- **THEN** a blast lands at the center of the grid's bottom-left cell in the visible view

#### Scenario: The next ordinal steps along the bottom row
- **WHEN** an event arrives carrying the row's base note plus one
- **THEN** the blast lands one cell along the bottom row of the grid

#### Scenario: Moving the camera moves the pads
- **WHEN** the camera pans or zooms and the same pad fires again
- **THEN** the blast lands at that cell's place in the new visible view

#### Scenario: An ordinal outside the grid does nothing
- **WHEN** an event's ordinal falls below the base note or beyond the grid's last cell
- **THEN** the event is discarded and no blast is placed

#### Scenario: Magnitude scales the blast
- **WHEN** two events with different magnitudes fire the same cell
- **THEN** the larger magnitude produces the stronger blast

#### Scenario: The latest touch of a frame wins the blast
- **WHEN** two touch events arrive in one frame
- **THEN** the frame places the later event's blast

### Requirement: The mapping document is versioned, dropping malformed rows and keeping unresolved ones

The matrix SHALL own a versioned JSON schema of its own, starting at version 1, decoded
validate-first in the manner of the preset schema (`src/preset.nim:49-68`, `src/preset.nim:567-673`).
Decode SHALL drop a structurally malformed row, SHALL clamp an out-of-range field, and SHALL refuse a
document whose version is newer than the build understands, applying nothing from it. A migration
path SHALL fall through the versions in one call, as the preset schema's does.

A well-formed row whose source id matches no current declaration SHALL keep its place, sit inert at
the flush, and report as unresolved, since a family may declare lazily and a stored mapping must
survive a session without its device.

One user mapping SHALL persist, and mappings SHALL stay out of world presets, since a preset is a
point in the world's parameter space while a mapping configures the instrument, the reasoning that
keeps the camera out (`src/ui/api/param_descriptor.nim:53-59`).

Enforcement: `tests/test_control_matrix.nim` covers round-trip stability, the drop-and-clamp decode
stance, the newer-version refusal, and unresolved rows loading intact. `tests/test_preset.nim` holds
the preset schema unchanged.

#### Scenario: One bad row costs one row
- **WHEN** a stored document carries a structurally malformed row among valid ones
- **THEN** that row is dropped and the rest load

#### Scenario: An out-of-range field clamps
- **WHEN** a stored row carries a depth outside [-1, 1]
- **THEN** the row loads with the depth clamped into range

#### Scenario: A newer document is refused whole
- **WHEN** a stored document declares a schema version above the version this build writes
- **THEN** the load is refused and no row from it is applied

#### Scenario: A row for an absent family survives the session
- **WHEN** a stored row names a source no registered family declares
- **THEN** the row loads, reports as unresolved, and changes nothing at the flush

#### Scenario: A preset carries no mapping
- **WHEN** a preset is exported while a user mapping is active
- **THEN** the preset carries no rows and applying it leaves the mapping untouched

### Requirement: The shipped default mapping loads when storage holds nothing usable

A default mapping SHALL ship as a constant and SHALL load when storage is empty or its stored
document is refused. Its rows lead with the four coupling strengths
(`src/ui/state/sim_config.nim:43-57`):

- four `Write` rows with soft takeover, `midi:cc:1:1` to `forceStrength`, `midi:cc:1:7` to
  `fluidStrength`, `midi:cc:1:74` to `rdFieldForce`, and `midi:cc:1:71` to `rdDeposit`
- six `Fire` rows on `midi:pc:1`, ordinals 0 through 5, selecting the six named regimes in
  `RD_REGIMES` order (`src/config_ranges.nim:268-277`)
- one `Touch` row laying a 4 by 4 grid on `midi:notes:1` from base note 36

Toggles SHALL ship unmapped and SHALL arrive through learn, so a stray note never flips the picture.
Every shipped row SHALL validate at compile time against the live descriptor table and the
compile-time source declarations a family gives its shipped ids, so a shipped row naming an id
nothing serves fails the build.

Enforcement: a static assertion in the matrix module, alongside the descriptor table's own
compile-time gates, plus `tests/test_control_matrix.nim` covering the default mapping's validity and
the fall back to it from empty or refused storage.

#### Scenario: A first run arrives mapped
- **WHEN** the app starts with no stored mapping
- **THEN** the shipped default rows are the active mapping

#### Scenario: A stored mapping keeps the defaults out
- **WHEN** the app starts with a stored mapping that decodes
- **THEN** the stored rows are the active mapping and no shipped row is added to them

#### Scenario: An unusable stored mapping falls back
- **WHEN** the stored document is refused at decode
- **THEN** the shipped default rows load in its place

#### Scenario: A shipped row naming nothing served fails the build
- **WHEN** a shipped row names a parameter id, action id, or source the build does not serve
- **THEN** `just happen` fails at the Nim compile step

#### Scenario: No toggle ships mapped
- **WHEN** the shipped mapping is loaded and a note or program change arrives
- **THEN** no toggle changes state until the user maps one through learn

### Requirement: Learn binds the next qualifying delivery

The matrix SHALL accept an arm request naming the slot to fill, SHALL accept a cancel, and SHALL
serve a learn state the panel renders. While armed, the next qualifying delivery SHALL complete the
row: a continuous source's movement for a `Modulate` or `Write` slot, an event for a `Fire` or
`Touch` slot, where a `Fire` slot takes the event's source id and ordinal and a `Touch` slot takes
the source id and offers the delivered ordinal as its base note.

The binding delivery SHALL be suppressed from ordinary matrix effect, so learning a control does not
also drive whatever that control was mapped to. A completed row SHALL reach the panel and persist
through the ordinary edit path. Learn SHALL carry no timeout: it stays armed until a qualifying
source arrives or the user cancels.

Enforcement: `tests/test_control_matrix.nim` covers qualification per slot kind, the suppression of
the binding delivery, cancel leaving the mapping unchanged, and arming persisting across frames with
no delivery.

#### Scenario: A knob learns a write slot
- **WHEN** learn is armed for a `Write` slot and a continuous source moves
- **THEN** the row binds to that source and the parameter does not move from that delivery

#### Scenario: A pad learns a fire slot with its ordinal
- **WHEN** learn is armed for a `Fire` slot and an event arrives
- **THEN** the row binds to that event's source id and ordinal, and the action does not run from that
  delivery

#### Scenario: A knob does not qualify for a gesture slot
- **WHEN** learn is armed for a `Fire` or `Touch` slot and a continuous source moves
- **THEN** learn stays armed and the row stays unbound

#### Scenario: Cancel leaves the mapping as it was
- **WHEN** learn is armed and the user cancels
- **THEN** no row changes and the learn state reports nothing armed

#### Scenario: Arming waits as long as it takes
- **WHEN** learn is armed and no qualifying source arrives for many frames
- **THEN** learn stays armed

### Requirement: User-facing copy calls a row a mapping

Everything a user reads SHALL call a row a mapping: the panel section, the learn control, and the
help file. The word matrix SHALL stay reserved for the species force matrix in the panel, in help,
and in preset copy, since the same screen exposes an action that randomizes that matrix
(`src/web_api.nim:1280`). The capability name `control-matrix` SHALL live in the spec namespace
alone.

Identifiers for learn SHALL avoid the word mode, keeping the vocabulary the forbidden-identifier
sweep protects for the deleted mode concept (`tests/test_no_modes.nim:17-20`).

Enforcement: review-enforced for the user-facing copy, since no sweep reads panel strings for this
word. `tests/test_help_content.nim` holds the MIDI help file's existence and its coverage of the
shipped mapping's targets, and `tests/test_no_modes.nim` sweeps the source tree for the mode
vocabulary.

#### Scenario: The panel names mappings
- **WHEN** a user opens the MIDI section
- **THEN** the section, its rows, and its learn control all read as mappings

#### Scenario: Help names the species matrix alone as a matrix
- **WHEN** a user reads the MIDI help file
- **THEN** it calls rows mappings and uses the word matrix for nothing but the species force matrix
