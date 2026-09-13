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

### Requirement: The default matrix ships six audio rows

The shipped default matrix SHALL carry six audio rows, each touching exactly one target, and the six
targets SHALL be distinct from one another so each source's effect reads alone. Three rows SHALL ship
live and three SHALL ship at zero depth, so the first listen moves only the three whose cause and
effect share a kind and a clock:

| Source | Kind | Target | Depth |
|---|---|---|---|
| `audio:onset` | Touch | a one-cell grid over the visible view | the event's energy as blast strength |
| `audio:bass` | Modulate | `fluidStrength` | +0.30 |
| `audio:loudness` | Modulate | `forceStrength` | +0.25 |
| `audio:high` | Modulate | `glowIntensity` | 0 |
| `audio:mid` | Modulate | `rdDeposit` | 0 |
| `audio:brightness` | Modulate | `rdFieldForce` | 0 |

> 2026-09-12: the `audio:mid` → `rdDeposit` and `audio:brightness` → `rdFieldForce` rows above no
> longer ship; reaction-diffusion is decoupled from audio.

> 2026-09-12: the `audio:onset` row above ships as a Modulate impulse on `forceStrength`, depth
> +0.40 and a 300 ms release, so a hit reaches every particle rather than a disc of them; its
> target is the one `audio:loudness` holds, so the shipped targets are no longer all distinct and
> the two rows sum on that parameter. The blast stays available to Touch rows, which is what the
> shipped MIDI pad grid uses.

Every Modulate row SHALL ship with a zero attack constant and an 80 ms release constant, starting
values a test pins.

The four simulation targets are the four couplings the world reads off its own parameters
(`src/ui/state/sim_config.nim:43-57`). `audio:high` lands on `glowIntensity`, which is in the picture
whenever particles are (`src/ui/api/param_descriptor.nim:488-490`), rather than on `bloomIntensity`,
which sits dormant while bloom is off (`src/ui/api/param_descriptor.nim:507-509`). Every depth SHALL
have zero inside its range, so any shipped row can be neutralized without deleting it. Depths are
shipped starting values a test pins, refined against the running world.

Enforcement: the static gate on the shipped default matrix, which fails the Nim build when a shipped
row names a descriptor id or a source id no declaration covers, plus a native test under `just test`
pinning each row's source, kind, target, and depth.

#### Scenario: A drum hit shoves the world where the eye rests
- **WHEN** an onset event arrives with the shipped Touch row in place
- **THEN** a blast lands at the center of the visible view, its strength taken from the event's
  energy

> 2026-09-12: the shipped onset row is a Modulate impulse on `forceStrength`, so a hit lifts the
> force every particle reads and releases to base over 300 ms. This scenario holds for a Touch row
> a user places on an onset source.

#### Scenario: A shipped row naming an absent target fails the build
- **WHEN** a shipped audio row names a descriptor id or a source id no declaration covers
- **THEN** the Nim build fails at the static gate, rather than the row failing silently at flush

#### Scenario: Silence leaves the authored world
- **WHEN** no audio source has delivered a value
- **THEN** all six rows displace nothing and the world runs at its stored parameter values

#### Scenario: A shipped row is neutralized without deletion
- **WHEN** a user sets a shipped audio row's depth to zero
- **THEN** the row keeps its place in the matrix and displaces nothing

#### Scenario: A first listen moves three targets
- **WHEN** listening starts with the shipped default matrix and sound arrives
- **THEN** `fluidStrength`, `forceStrength`, and the blast answer, while `glowIntensity`,
  `rdDeposit`, and `rdFieldForce` hold their stored values until their rows' depths are raised

> 2026-09-12: `rdDeposit` and `rdFieldForce` no longer name shipped rows; the `audio:mid` and
> `audio:brightness` rows that once held their stored values here are decoupled from audio.

> 2026-09-12: the blast named in this scenario is now a lift of `forceStrength`, the onset row
> having shipped as a Modulate impulse on that parameter; the three answering targets are
> `fluidStrength` and `forceStrength`, which onset and loudness share.

#### Scenario: A dormant row is offered in the editor
- **WHEN** the user opens the mapping editor having never edited it
- **THEN** the three zero-depth audio rows appear with their targets, ready to raise

> 2026-09-12: one zero-depth row ships, `audio:high` into `glowIntensity`; the mid and brightness
> rows no longer ship.

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
