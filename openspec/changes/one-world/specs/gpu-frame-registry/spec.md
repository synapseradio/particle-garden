## MODIFIED Requirements

### Requirement: Frame described as data

The GPU frame SHALL be a pure `FrameDescription` describing ONE world. Species forces, fluid
pressure, and chemistry each contribute according to a continuous strength, and zero SHALL be an
ordinary value of that strength rather than a state the world is in.

Passes SHALL divide into two kinds. **World-intrinsic** passes — the grid-build triad and scatter,
local density accumulation, the field's own Gray-Scott evolution, and `integrate` — run whenever the
world runs and SHALL NOT be skipped by any strength. **Coupling-owned** passes exist only to make one
coupling act on the particles, SHALL be multiplied by that coupling's strength across their entire
output, and MAY be skipped at exactly zero. The frame is walked every frame with symbolic dispatch
sizes resolved against live counts, and SHALL open with explicit clear nodes for velocityDelta and
densityDelta.

Skipping a coupling-owned pass at exactly zero is an OPTIMIZATION derived from that number, never a
selection among worlds. No part of the system SHALL enumerate combinations of couplings.

#### Scenario: One world runs forces and chemistry together
- **WHEN** force strength and the deposit and field-force strengths are non-zero, and fluid strength
  is zero
- **THEN** one frame runs the grid triad, forces, the field passes, and integrate, in that order

#### Scenario: Zero strength dispatches none of its coupling-owned passes
- **WHEN** a coupling's strength is exactly zero
- **THEN** no coupling-owned pass belonging to it is dispatched

#### Scenario: The world runs even when every strength is zero
- **WHEN** every coupling strength is zero
- **THEN** the grid triad, density accumulation, the field's evolution, and integrate all still run,
  because the world is what they are

#### Scenario: Turning a coupling down is continuous
- **WHEN** a coupling's strength moves from a small positive value to zero
- **THEN** nothing else about the world changes — no reset, no re-initialization, no change to which
  controls exist

#### Scenario: The former modes still behave as they did
- **WHEN** strengths are set to the values that used to constitute forces-only, forces-with-fluid, or
  forces-with-chemistry
- **THEN** the world BEHAVES as that former frame did, with two stated exceptions and no others: the
  dispatch list gains exactly the world-intrinsic passes that mode did not run, and glow reads real
  density where it formerly read a substitute floor

#### Scenario: Dispatch identity is not claimed, behaviour identity is
- **WHEN** a former field-only setting is compared against its old frame
- **THEN** the new frame additionally dispatches the grid and density passes, which is intended —
  behaviour is what is pinned, and the added passes are world-intrinsic by definition

### Requirement: Frame descriptions are pinned by native tests

The exact pass list for a given set of coupling strengths SHALL be pinned by
tests/test_sim_registry.nim, including the zero-strength skip and the all-couplings-active frame.

#### Scenario: Unreviewed frame change goes red
- **WHEN** the pass list for any pinned set of strengths changes without its test changing
- **THEN** `just test` fails

### Requirement: One world offers one control set

The panel SHALL offer every control the simulation has, at all times. No control appears or
disappears as a consequence of what the world is currently doing, because there is only one thing it
can be. `controlGroupsFor` and the per-group visibility predicate it feeds SHALL be removed.

A control whose coupling is at zero strength still exists and still works; moving it is how a user
brings that coupling back. Hiding it would make the coupling unreachable from the panel and would
reintroduce the mode by another name.

#### Scenario: Controls do not come and go
- **WHEN** any coupling strength changes, including to or from zero
- **THEN** the set of controls the panel offers is unchanged

### Requirement: A world serializes as its strengths

Presets SHALL carry coupling strengths and SHALL NOT carry a mode. `SimKind`, `simKindId`,
`parseSimKind`, `couplingsFor`, and the mode catalog SHALL be removed rather than retained as a
compatibility layer.

Presets written before this change SHALL be translated once, in the legacy branch of the versioned
schema decode, where `mode` is consulted to zero the strengths that mode excluded. Subtraction cannot
do this job: the schema serializes every scalar unconditionally (`src/preset.nim:490`, `:506-515`)
with nonzero defaults (`:199-212`), so nothing is ever absent to subtract, and a legacy particle-life
preset carries a live `rdDeposit` and `rdFieldForce`.

Consulting `mode` there is versioned-schema history about files written by old builds, reachable only
from a branch guarded on an older schema version. It is not a live mode concept, and the test that
asserts nothing names a mode SHALL scope itself to the live model with that branch as a stated,
justified exemption.

#### Scenario: An old preset loads as the world it was saved as
- **WHEN** a preset carrying `"mode": "particle-life"` is applied
- **THEN** it loads with chemistry and fluid strengths zeroed, despite carrying nonzero values for
  both, because its mode excluded them

#### Scenario: A current preset never consults a mode
- **WHEN** a preset at the current schema version is applied
- **THEN** it carries its strengths explicitly, has no mode field, and the legacy branch is not taken

#### Scenario: Nothing names a mode
- **WHEN** the source tree is searched for a mode type, a mode id, or a list of modes
- **THEN** nothing is found

### Requirement: Delta buffers have one reset owner

Every accumulation buffer SHALL be reset exactly once per frame by an explicit frame-level node, and
every contributor pass SHALL accumulate only — no pass self-resets a shared delta buffer, and every
writer to a shared delta buffer uses atomic accumulation. fieldResolve's consume-and-zero of the
deposit buffer remains that buffer's single reset owner.

#### Scenario: Two contributors in one frame
- **WHEN** forces and fieldForce both run in a frame
- **THEN** both accumulate into velocityDelta atomically and integrate sees the sum

### Requirement: Field seeding is a one-shot

Field seeding SHALL occur only on explicit user action; the executor SHALL NOT seed automatically on
couplings entry or reset. The seed shader and its pure mirror are retained for that action. Ignition
in normal play comes from particle deposits alone.

#### Scenario: Entering the chemical world
- **WHEN** couplings gain the field without user seeding
- **THEN** the field starts at the trivial fixed point and ignites only where colonies deposit

## ADDED Requirements

### Requirement: Ignition from colonies

The deposit pass SHALL splat each particle's contribution over a radius with a falloff kernel, sized
by the native ignition sweep in tests/test_field_core.nim so that a coherent colony's deposits lift
the field off Gray-Scott's trivial fixed point within seconds. The sweep's minimum igniting
(radius, amplitude) is the kernel's floor; the retired automatic seed is its sufficiency yardstick.

#### Scenario: Colony ignites the field
- **WHEN** a settled cluster deposits with the shipped kernel at the default deposit amount
- **THEN** a pattern emerges at the cluster's location without any seed

#### Scenario: Kernel stays measurement-backed
- **WHEN** the splat radius or the deposit ceiling changes
- **THEN** the ignition sweep still passes at the new values

### Requirement: The default climate sits where patterns must be nucleated

The default feed and kill SHALL sit in a region where `F < 4*(F+k)^2` — where the trivial state is
the only homogeneous fixed point and is linearly stable — so no pattern can arise without a
supercritical perturbation. This is what makes the field a record of life rather than decoration.
Regions where the field self-starts remain reachable through the controls; the difference is that
the user chooses them.

#### Scenario: Empty world stays empty
- **WHEN** the field couples with no particles present and no user seeding
- **THEN** the field remains at its trivial fixed point indefinitely

### Requirement: A second reaction has reserved slots

The field textures' `.b` and `.a` channels SHALL be preserved rather than overwritten with literals,
and documented as reserved state channels for a multi-channel reaction. `reactionKind` SHALL be a
named constant set carried in a `ReactionParams` uniform bound to the reaction pass. These reserve
addressable slots; no second reaction is implemented and no readiness beyond addressability is
claimed.

#### Scenario: Reserved channels survive a frame
- **WHEN** the field advances through resolve and the reaction substeps
- **THEN** whatever occupies the `.b` and `.a` channels is carried through unchanged

#### Scenario: Gray-Scott is unaffected
- **WHEN** reactionKind holds its Gray-Scott value
- **THEN** the field evolves byte-identically to the same parameters before the uniform existed
