## ADDED Requirements

### Requirement: The audio family joins the matrix without a matrix edit

Registering the audio family SHALL cost no new row kind, no new schema version, no arbitration
change, and no edit to the row model: the six audio sources the `audio-input` capability defines,
five continuous and one event, arrive through the same registration entry point every family uses,
and audio rows use the Modulate and Touch kinds already defined. A stored matrix naming audio
sources SHALL decode under the same schema version as one naming none, through no migration branch.

Row validation SHALL resolve audio source ids against the family's declarations exactly as it
resolves any other family's. Audio relies on a row naming an absent family staying inert and
visible, so removing the family registration leaves stored rows in place rather than destroying a
mapping the user made.

Enforcement: the static gate that validates the shipped default matrix against the descriptor table
and the registered source declarations at compile time, plus the `control-matrix` validation tests
under `just test`. That no matrix module was edited is review-enforced against this change's diff.

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
targets SHALL be distinct from one another so each source's effect reads alone:

| Source | Kind | Target | Depth |
|---|---|---|---|
| `audio:loudness` | Modulate | `forceStrength` | +0.25 |
| `audio:bass` | Modulate | `fluidStrength` | +0.30 |
| `audio:mid` | Modulate | `rdDeposit` | +0.20 |
| `audio:brightness` | Modulate | `rdFieldForce` | +0.25 |
| `audio:high` | Modulate | `glowIntensity` | +0.25 |
| `audio:onset` | Touch | a one-cell grid over the visible view | the event's energy as blast strength |

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

#### Scenario: A shipped row naming an absent target fails the build
- **WHEN** a shipped audio row names a descriptor id or a source id no declaration covers
- **THEN** the Nim build fails at the static gate, rather than the row failing silently at flush

#### Scenario: Silence leaves the authored world
- **WHEN** no audio source has delivered a value
- **THEN** all six rows displace nothing and the world runs at its stored parameter values

#### Scenario: A shipped row is neutralized without deletion
- **WHEN** a user sets a shipped audio row's depth to zero
- **THEN** the row keeps its place in the matrix and displaces nothing

#### Scenario: An audio row shares a target with a written value
- **WHEN** the default matrix also carries a Write row on one of the four coupling strengths
- **THEN** the Write row moves the stored base and the audio row displaces from that base, neither
  disabling the other
