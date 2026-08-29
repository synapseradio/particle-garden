## Purpose

Brings MIDI hardware into the garden as the first control-source family: transport acquired behind a
user affordance, raw messages parsed in a pure core, and every knob, pad, and program button
normalized into control-matrix sources that carry no trace of the wire format.

## ADDED Requirements

### Requirement: MIDI access is acquired only through a user affordance

The panel SHALL carry a connect control, and MIDI access SHALL be requested only when the user
activates it. Launch, preset apply, and matrix load SHALL request nothing, so the browser's
permission prompt answers a gesture the user made (`docs/engineering-principles.md`, article 11).

When the request is refused, or the launched browser exposes no MIDI access at all, the affordance
SHALL report MIDI unavailable and everything else SHALL keep running. Rows naming MIDI sources stay
in the matrix, inert and visible, and no other control loses function.

Enforcement: build-verified and review-enforced. Transport code compiles on the JS backend and is
never mocked (`openspec/config.yaml`, testing context), and the proposal's measurement gate confirms
`navigator.requestMIDIAccess` resolves inside the webui-launched window before transport work
proceeds.

#### Scenario: Nothing asks for MIDI before the user does
- **WHEN** the app launches and the user activates no connect control
- **THEN** no MIDI access request is issued and the panel reports MIDI as disconnected

#### Scenario: The connect gesture carries the request
- **WHEN** the user activates the connect control
- **THEN** MIDI access is requested once and the affordance reports the outcome the browser returns

#### Scenario: Refusal leaves the world intact
- **WHEN** the access request is refused or the launched browser exposes no MIDI access
- **THEN** the affordance reports MIDI unavailable and every mapping row naming a MIDI source stays
  listed, inert, and editable

### Requirement: Connected input ports are tracked through device state changes

Once access is granted, every input port the transport reports SHALL be subscribed, and the
transport's state-change events SHALL be followed for the life of the session. A device plugged in
after the connect gesture SHALL deliver without a second gesture, and a device removed SHALL stop
delivering. Removal SHALL leave the mapping alone: rows naming that device's controls keep their
place and change nothing at the flush.

Enforcement: build-verified and review-enforced. Transport code compiles on the JS backend and is
never mocked (`openspec/config.yaml`, testing context).

#### Scenario: A device arriving after connect delivers
- **WHEN** a MIDI device connects after access was granted
- **THEN** its messages reach the matrix without another connect gesture

#### Scenario: A device leaving keeps its mappings
- **WHEN** a device is removed
- **THEN** rows naming its controls keep their place and change nothing at the flush

### Requirement: The declared source set holds the shipped ids and every control that has sent

The shipped mapping's source ids SHALL be declared at wiring time as compile-time constants, so a
shipped row resolves before any hardware has spoken and the compile-time gate on the shipped mapping
has a declaration set to check. Every other control SHALL declare the first time it sends a message,
and that arrival SHALL re-register the family with the grown set, replacing the previous declarations
under the registration rule the `control-matrix` capability states.

The editor's MIDI source list therefore holds the shipped ids plus what the connected hardware has
used. A stored row naming a MIDI source neither of those covers SHALL keep its place and report as
unresolved.

Enforcement: the compile-time gate on the shipped mapping checks the shipped ids against these
declarations, and `tests/test_control_matrix.nim` covers resolution and re-registration at run time.
Declaration on first message is build-verified and review-enforced with the rest of the wiring.

#### Scenario: A shipped row resolves before any hardware speaks
- **WHEN** the app starts on the shipped mapping and no MIDI message has arrived
- **THEN** every shipped row reports as resolved

#### Scenario: A knob declares itself by moving
- **WHEN** a control sends a message for the first time
- **THEN** its source id joins the declared set and the editor lists it as a source to map

#### Scenario: A mapping learned on another controller stays visible
- **WHEN** a stored row names a MIDI source that neither the shipped declarations nor any control
  that has sent covers
- **THEN** the row keeps its place, reports as unresolved, and changes nothing at the flush

### Requirement: A pure core parses raw MIDI messages and drops what it cannot name

Parsing SHALL live in a module that imports no transport, compiles natively, and is tested natively
(`src/ui/input/midi_core.nim`, `tests/test_midi_core.nim`). It SHALL turn a raw MIDI byte triple
into one of four typed messages, control change, note on, note off, and program change, each
carrying its channel and its numbers. A triple whose status names none of those four SHALL be
rejected at that boundary and SHALL produce no delivery.

Enforcement: `tests/test_midi_core.nim` covers parsing and rejection, and the module's native
compilation holds it free of transport imports.

#### Scenario: A control-change triple parses
- **WHEN** the core receives the bytes of a control change on channel 1
- **THEN** it reports a control-change message carrying channel 1, the control number, and the value

#### Scenario: Bytes naming no consumed message produce nothing
- **WHEN** the core receives a triple whose status names none of the four messages
- **THEN** it reports no message and nothing reaches the matrix

### Requirement: MIDI messages normalize into matrix sources

The family SHALL mint one source id per control it carries, each prefixed `midi:`, and SHALL
normalize every wire number into [0, 1] before delivery, so no consumer past delivery learns the
wire format:

- a control change delivers as a continuous value on `midi:cc:<channel>:<number>`, the wire value
  divided by 127
- a note on carrying a non-zero velocity delivers as an event on `midi:notes:<channel>`, the note
  number as its ordinal and the velocity divided by 127 as its magnitude
- a program change delivers as an event on `midi:pc:<channel>`, the program number as its ordinal
  and magnitude 1.0
- a note off delivers nothing, and a note on carrying velocity 0 delivers nothing with it, since the
  MIDI 1.0 specification defines that message as a note off
  (https://musicproductionwiki.com/bible/velocity)

Every channel SHALL be listened to, and the channel SHALL live inside the source id, so channel
selection lives in the mapping and needs no configuration on the device.

Enforcement: `tests/test_midi_core.nim` pins the normalization arithmetic and the channel's place in
each source id.

#### Scenario: A control change arrives as travel
- **WHEN** control 74 on channel 1 sends its maximum wire value
- **THEN** the matrix receives the value 1.0 on `midi:cc:1:74`

#### Scenario: A note carries its number and its velocity
- **WHEN** a note on arrives on channel 1 carrying a non-zero velocity
- **THEN** the matrix receives an event on `midi:notes:1` whose ordinal is the note number and whose
  magnitude is the velocity divided by 127

#### Scenario: A program change carries its program number
- **WHEN** program change 3 arrives on channel 1
- **THEN** the matrix receives an event on `midi:pc:1` with ordinal 3 and magnitude 1.0

#### Scenario: A note off changes nothing
- **WHEN** a note off arrives on any channel
- **THEN** no value and no event reach the matrix

#### Scenario: A note on at velocity 0 is a note off
- **WHEN** a note on arrives carrying velocity 0
- **THEN** no event reaches the matrix, so no `Fire` row runs and no blast is placed

#### Scenario: Channels stay apart
- **WHEN** the same control number arrives on two channels
- **THEN** two source ids hold values and neither overwrites the other

### Requirement: MIDI reaches the matrix only as a source family

MIDI SHALL register under the family id `midi` and SHALL reach the matrix through the two delivery
entry points alone. It SHALL neither run the per-frame flush nor observe its result. Row semantics,
arbitration, takeover, gestures, and persistence SHALL stay outside this capability, so past
delivery nothing distinguishes MIDI from any other family.

Enforcement: the module split is review-enforced, one pure core beside JS wiring with no matrix
logic in either. `tests/test_control_matrix.nim` exercises the matrix against declared sources
without importing anything MIDI.

#### Scenario: Delivery is the whole interface
- **WHEN** a parsed MIDI message is normalized
- **THEN** the only matrix calls it makes are source registration and the two delivery entry points

#### Scenario: The frame loop owns the flush
- **WHEN** several messages arrive between two frames
- **THEN** each is delivered as it arrives and the flush runs on the frame loop's own call
