## ADDED Requirements

### Requirement: The audio family joins the matrix without a matrix edit

Registering the audio family SHALL cost no new row kind, no new schema version, no arbitration
change, and no edit to the row model. The one exception to "without a matrix edit" is the refusal
of an audio source's row on the Room Gate, which the requirement below states. The six audio sources
the `audio-input` capability defines, five continuous and one event, arrive through the same registration entry point every family uses,
and audio rows use the Modulate and Touch kinds already defined. A stored matrix naming audio
sources SHALL decode under the same schema version as one naming none, through no migration branch.

Row validation SHALL resolve audio source ids against the family's declarations exactly as it
resolves any other family's. Audio relies on a row naming an absent family staying inert and
visible, so removing the family registration leaves stored rows in place rather than destroying a
mapping the user made.

Enforcement: the static gate that validates the shipped default matrix against the descriptor table
and the registered source declarations at compile time, plus the `control-matrix` validation tests
under `just test`. That no matrix module was edited beyond the Room Gate refusal is review-enforced
against this change's diff.

#### Scenario: A second family costs no matrix code
- **WHEN** the audio family registers its six sources
- **THEN** row validation, the mapping editor, and help offer them with no change to the row model,
  the arbitration, or the schema version

#### Scenario: Audio rows decode under the shipped schema version
- **WHEN** a stored matrix carrying audio rows is decoded
- **THEN** it decodes under the same schema version as one carrying none, with no migration branch

#### Scenario: A row outlives the family that named it
- **WHEN** a stored matrix names audio sources in a build where the audio family declares nothing
- **THEN** every row keeps its place and displaces nothing

### Requirement: The default matrix ships four audio rows

The shipped default matrix SHALL carry four audio rows. Three SHALL ship live on two targets and one
SHALL ship at zero depth, so the first listen moves only the rows whose cause and effect share a kind
and a clock:

| Source | Kind | Target | Depth | Attack | Release |
|---|---|---|---|---|---|
| `audio:onset` | Modulate | `forceStrength` | +0.40 | 0 | 300 ms |
| `audio:bass` | Modulate | `fluidStrength` | +0.30 | 0 | 80 ms |
| `audio:loudness` | Modulate | `forceStrength` | +0.25 | 0 | 80 ms |
| `audio:high` | Modulate | `glowIntensity` | 0 | 0 | 80 ms |

`audio:onset` and `audio:loudness` share `forceStrength` and sum there, so a hit rides on the
room's energy and reaches every particle. Every other row touches a target no other audio row
touches. All six audio source declarations SHALL still register, so the two sources without a
shipped row stay mappable.

Both simulation targets are couplings the world reads off its own parameters
(`src/ui/state/sim_config.nim:43-57`). `audio:high` lands on `glowIntensity`, which is in the picture
whenever particles are (`src/ui/api/param_descriptor.nim:488-490`), rather than on `bloomIntensity`,
which sits dormant while bloom is off (`src/ui/api/param_descriptor.nim:507-509`). Every depth SHALL
have zero inside its range, so any shipped row can be neutralized without deleting it. Depths and
envelopes are shipped starting values a test pins, refined against the running world.

History, kept as recorded:

> 2026-09-12: the `audio:mid` → `rdDeposit` and `audio:brightness` → `rdFieldForce` rows, which
> once shipped at zero depth, no longer ship; reaction-diffusion is decoupled from audio.

> 2026-09-12: the `audio:onset` row, first specified as a Touch blast at the center of the visible
> view, ships as a Modulate impulse on `forceStrength`, depth +0.40 and a 300 ms release, so a hit
> reaches every particle rather than a disc of them; its target is the one `audio:loudness` holds,
> and the two rows sum on that parameter. The blast stays available to Touch rows, which is what the
> shipped MIDI pad grid uses.

Enforcement: the static gate on the shipped default matrix, which fails the Nim build when a shipped
row names a descriptor id or a source id no declaration covers, plus "the four audio rows ship
pinned by source, kind, target and depth" in `tests/test_control_matrix.nim` under `just test`.

#### Scenario: A hit lifts the force every particle reads
- **WHEN** an onset event arrives with the shipped rows in place
- **THEN** `forceStrength` lifts in proportion to the event's energy and the onset row's depth,
  summed with any lift loudness holds, and releases toward base on the row's 300 ms release

#### Scenario: A shipped row naming an absent target fails the build
- **WHEN** a shipped audio row names a descriptor id or a source id no declaration covers
- **THEN** the Nim build fails at the static gate, rather than the row failing silently at flush

#### Scenario: Silence leaves the authored world
- **WHEN** no audio source has delivered a value
- **THEN** all four audio rows displace nothing and the world runs at its stored parameter values

#### Scenario: A shipped row is neutralized without deletion
- **WHEN** a user sets a shipped audio row's depth to zero
- **THEN** the row keeps its place in the matrix and displaces nothing

#### Scenario: A first listen moves two targets
- **WHEN** listening starts with the shipped default matrix and sound arrives
- **THEN** `fluidStrength` and `forceStrength` answer, while `glowIntensity` holds its stored value
  until the `audio:high` row's depth is raised

#### Scenario: The dormant row is offered in the editor
- **WHEN** the user opens the mapping editor having never edited it
- **THEN** the `audio:high` row appears at zero depth with its target, ready to raise

#### Scenario: An audio row shares a target with a written value
- **WHEN** the default matrix also carries a Write row on one of the four coupling strengths
- **THEN** the Write row moves the stored base and the audio row displaces from that base, neither
  disabling the other

### Requirement: The Room Gate is a controller's Write target and never an audio row's

A Write row from a source outside the audio family SHALL be able to target `audioRoomGate`, so a
controller knob sets how far above the room a sound must rise, through the same validation and
ranked-write path every routed store uses.

A Modulate row naming `audioRoomGate` SHALL be refused at validation with a reason naming its store,
because the Room Gate has no stored value apart from an effective one for an excursion to displace.
The store confinement in `targetRefusal` (`src/ui/input/control_matrix.nim`) already refuses it.

A row of any kind whose source id carries the `audio:` prefix and whose target routes through the
audio store SHALL be refused, with a reason naming the feedback loop. An audio feature writing its
own room edge would raise the gate on a loud passage and then silence that passage a frame later.
The check reads the source id alone, so it holds at decode too, and a stored row of that shape drops
on load with its reason. `targetRefusal` gains the row's source id for this one arm, the one matrix
edit the audio family makes.

Enforcement: agent-checkable by `tests/test_control_matrix.nim` under `just test`:
- The case that refuses a Modulate row outside the simulation and render stores while a Write row
  takes it, extended to `audioRoomGate`.
- A case refusing an `audio:loudness` Write row on `audioRoomGate` while a MIDI source's Write row on
  it validates.
- A decode case dropping a stored row of that shape.

The exhaustive store cases in `src/web_api.nim` fail the build until the audio store has an arm in
the matrix write path (`just build-app`).

#### Scenario: A knob writes the Room Gate
- **WHEN** a Write row maps a controller's continuous source to `audioRoomGate`
- **THEN** the row validates, and moving the knob sets the Room Gate inside its range

#### Scenario: An audio row writing the Room Gate is refused
- **WHEN** a Write row maps `audio:loudness` to `audioRoomGate`, whether added in the editor or found
  in a stored matrix on load
- **THEN** validation refuses it with a reason naming the feedback loop, and the Room Gate is not
  written

#### Scenario: A Modulate row on the Room Gate is refused
- **WHEN** a Modulate row names `audioRoomGate` as its target
- **THEN** validation refuses it with a reason naming the audio store, and the stored matrix is
  unchanged
