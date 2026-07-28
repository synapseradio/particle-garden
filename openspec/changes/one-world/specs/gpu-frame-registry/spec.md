## MODIFIED Requirements

### Requirement: Frame described as data

The GPU frame SHALL be a pure `FrameDescription` returned by
`buildFrame(couplings: WorldCouplings)`, where `WorldCouplings = (forces, sph, field: bool)` composes
one frame: the grid-build triad and scatter run when `forces or sph`; the field passes run when
`field`; `integrate` always runs last. The frame is built once at init or on a couplings change and
walked every frame with symbolic dispatch sizes resolved against live counts. The frame SHALL open
with explicit clear nodes for velocityDelta and densityDelta. The three legacy combinations —
forces-only, sph-only, field-only — SHALL be behavior-identical to their former per-kind frames.

#### Scenario: Chemistry world runs forces and field together
- **WHEN** couplings are (forces: true, sph: false, field: true)
- **THEN** one frame runs the grid triad, forces, the field passes, and integrate, in that order

#### Scenario: Legacy combination unchanged
- **WHEN** couplings match a former mode's triple
- **THEN** the dispatched pass sequence is behavior-identical to that mode's former frame

### Requirement: Frame descriptions are pinned by native tests

Every couplings combination's exact pass list SHALL be pinned by tests/test_sim_registry.nim,
including forces+field and forces+sph+field.

#### Scenario: Unreviewed frame change goes red
- **WHEN** any combination's pass list changes without its pinned test changing
- **THEN** `just test` fails

### Requirement: Control groups live beside the frame

`controlGroupsFor(couplings)` SHALL return the union of each active coupling's descriptor groups,
declared beside buildFrame so the native coverage invariant continues to relate dispatches to knobs.
An inactive coupling contributes none of its groups.

#### Scenario: Union of active couplings
- **WHEN** couplings are (forces: true, field: true)
- **THEN** the panel offers the force-model and matrix groups together with the field groups

### Requirement: Simulation identity serializes by stable id

Presets SHALL keep serializing by the stable string ids (`particle-life`, `sph`,
`reaction-diffusion`); SimKind and simKindId/parseSimKind survive as a compatibility layer mapping
each legacy id to its couplings triple, so presets saved before the merge keep loading.
`parseSimKind` raises on unknown ids; untrusted-input callers catch and fall back explicitly.

#### Scenario: Legacy preset selects couplings
- **WHEN** a preset carrying mode "reaction-diffusion" is applied
- **THEN** the world adopts that id's mapped couplings triple

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
