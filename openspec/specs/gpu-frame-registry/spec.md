# gpu-frame-registry

## Purpose

Describes how one GPU physics frame is declared, registered, and dispatched: the pure per-mode
description of the compute work a frame performs, the shader manifest that makes each dispatched
pipeline loadable, and the executor that walks the description each frame. It is one capability
because the description, the manifest, and the walk are three views of a single contract — a pass
named in one and missing from another is a runtime failure with no compile-time symptom, and the
native tests that catch that failure relate the three directly.

Buffer struct offsets and uniform layouts belong to `gpu-buffer-layout`; descriptor ranges and
defaults belong to `parameter-range-authority`; the test suite's own organization belongs to
`native-test-strategy`; the JavaScript-facing surface belongs to `gardenapi-boundary`. This spec
cites those relations and leaves their detail to them.

## Requirements

### Requirement: Frame described as data

The GPU work of one physics frame SHALL be a pure `FrameDescription` — a sequence of `FrameNode`
values returned by `buildFrame(couplings: WorldCouplings; rdSteps: int)`
(`src/sim_registry.nim:222`) — describing ONE world, and never a hand-coded sequence of encoder
calls. Species forces, fluid pressure, and chemistry each contribute according to a continuous
strength (`WorldCouplings`, `src/sim_registry.nim:66-82`), and zero SHALL be an ordinary value of
that strength, never a state the world is in. `acts` (`src/sim_registry.nim:83-87`) is the one
place a strength is compared to anything, so a threshold cannot be introduced elsewhere without
deleting that function first.

Passes SHALL divide into two kinds. **World-intrinsic** passes — the grid-build triad and scatter,
the neighbour sweep in `forces`, the field's own Gray-Scott evolution, and `integrate` — run
whenever the world runs and SHALL NOT be skipped by any strength. **Coupling-owned** passes exist
only to make one coupling act on the particles, SHALL be multiplied by that coupling's strength
across their entire output, and MAY be skipped at exactly zero. Forces are the asymmetric case: the
force term is coupling-owned and `forces.wgsl` scales it inside the shader, while its pass also
measures density and applies the mouse and the blast, so no force strength may skip it.

A node is a buffer clear, a buffer copy, or a compute pass carrying a label, a profiler slot, and an
ordered list of `Dispatch` values naming a pipeline key and a symbolic `DispatchSize`. Every node
also carries a `FrameNodeCadence` (`src/sim_registry.nim:154-166`), which is how often the executor
encodes it inside one rendered frame, and a node holds exactly one cadence, since a node is the unit
the executor skips.

The description MUST be free of live counts. Dispatch sizes stay symbolic (`dsParticleWorkgroups`,
`dsScanBlocks`, `dsOne`, `dsFieldWorkgroups`) and the executor resolves them against the frame's
particle count, grid dimensions, and field dimensions during the walk
(`src/webgpu_compute.nim:861-869`). `dsFieldWorkgroups` is the one two-dimensional size and MUST be
dispatched through the `(x, y)` overload; resolving it through the one-integer path raises
(`src/webgpu_compute.nim:866-869`).

The executor SHALL build the description once and walk that stored description every frame.
`setCouplings` (`src/webgpu_compute.nim:143-166`) rebuilds only when a strength crosses zero or the
Gray-Scott step count changes, so a slider moving inside its range rebuilds nothing. Substepping is
an executor loop, not frame nodes: the executor encodes the description `substepCount` times into
one command encoder and skips any node whose cadence is `fncOncePerFrame` after the first substep
(`src/webgpu_compute.nim:895-901`).

Skipping a coupling-owned pass at exactly zero is an OPTIMIZATION derived from that number, never a
selection among worlds. No part of the system SHALL enumerate combinations of couplings.

Enforced by: `src/sim_registry.nim` (pure module, natively compiled and tested),
`tests/test_sim_registry.nim`, and `tests/test_no_modes.nim`, which sweeps `src/` and `web-ui/src/`
for the vocabulary a fixed list of worlds would need.

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
- **THEN** nothing else about the world changes: no reset, no re-initialization, no change to which
  controls exist

#### Scenario: Particle count changes

- **WHEN** the particle count changes between frames
- **THEN** the stored frame description is unchanged and the executor resolves
  `dsParticleWorkgroups` against the new count on the next walk

### Requirement: Frame descriptions are pinned by native tests

The exact pass list for a given set of coupling strengths SHALL be pinned by
`tests/test_sim_registry.nim`, so a reordering of GPU work fails `just test` instead of showing up
as changed physics. The pinning is written as a derivation, not as a table of worlds: stripping the
coupling-owned keys from any frame leaves exactly `WORLD_INTRINSIC_SEQUENCE`
(`tests/test_sim_registry.nim:50-52`, asserted at `:160-168`), so a fifth coupling cannot
reintroduce enumeration by accident. The zero-strength skip and the all-couplings-active frame are
both covered (`:100-158`), together with the case that a strength one part in a billion above zero
dispatches its pass (`:150-158`).

Each compute pass node carries a profiler slot indexing one timestamp query set. Slots that index
the query set MUST be pairwise distinct and MUST be distinct within any one frame — two passes
sharing a slot overwrite each other's timestamps and report a meaningless duration. Passes carrying
`PROFILER_SLOT_NONE` write no timestamps and may share it
(`tests/test_sim_registry.nim:309-332`).

Enforced by: `tests/test_sim_registry.nim`, run by `just test` and `just check`.

#### Scenario: Unreviewed frame change goes red

- **WHEN** the pass list for any pinned set of strengths changes without its test changing
- **THEN** `just test` fails

#### Scenario: Two passes claim one profiler slot

- **WHEN** a frame's compute passes reuse a slot that indexes the query set
- **THEN** `just test` fails

### Requirement: One world offers one control set

No control SHALL appear or disappear as a consequence of a coupling strength, because there is only
one world for the panel to describe. No lookup from a world to a control set exists:
`controlGroupsFor` and the per-group visibility predicate it fed are absent from the source tree,
which `tests/test_no_modes.nim:17-25` holds by sweeping `src/` and `web-ui/src/` for that name
alongside every other name a fixed list of worlds needed.

A control whose coupling is at zero strength still exists and still works; moving it is how a user
brings that coupling back. Hiding it would make the coupling unreachable from the panel and would
reintroduce a fixed list of worlds by another name.

The panel places each group by id (`groupParamIds`, `web-ui/src/components/Panel.tsx`) and consults
no strength when deciding what to render. That relation is **agent-checkable**: run `just be`, note
every group heading and slider the panel shows, drag Force Strength, Fluid Strength, Deposit and
Field Force each to zero and back, and compare the control set after each move; a violation appears
as a section or slider present in one capture and absent in another.

#### Scenario: Controls do not come and go

- **WHEN** any coupling strength changes, including to or from zero
- **THEN** the set of controls the panel offers is unchanged

#### Scenario: No lookup from world to control set exists

- **WHEN** the source tree is searched for a per-world control-group lookup
- **THEN** nothing is found, and `just test` fails if such a name is reintroduced

### Requirement: A world serializes as its strengths

Presets SHALL carry coupling strengths and SHALL NOT carry a mode. A world's identity is the
numbers it holds, so no type, id round-trip, or catalog naming a fixed list of worlds exists in the
live model (`tests/test_no_modes.nim:17-33`, which forbids both the identifiers and the three
quoted ids they serialized as).

Presets written against schema version 1 SHALL be translated once, in the versioned decode's legacy
branch (`migrate`, `src/preset.nim:599-631`), where the file's `mode` field is consulted to zero the
strengths that world excluded. `LEGACY_MODE_COUPLINGS` (`src/preset.nim:526-533`) is the table that
translation reads, and it is the one place in the codebase naming a mode.

Subtraction cannot do this job. Version 1 serializes every scalar unconditionally and parses each
with a nonzero default, so nothing is ever absent to subtract, and a version 1 particle-life file
carries a live `rdDeposit` and `rdFieldForce` from sliders its world hid. The mode id is the only
record of which values that world read.

Consulting `mode` there is versioned-schema history about files written by old builds, reachable
only from a branch guarded on an older schema version. The test that asserts nothing names a mode
SHALL scope itself to the live model with that branch as a stated, justified exemption
(`tests/test_no_modes.nim:38-45`).

Enforced by: `tests/test_no_modes.nim` (the sweep and its exemption) and `tests/test_preset.nim`
suite covering the version 1 translation (`:424-457`).

#### Scenario: An old preset loads as the world it was saved as

- **WHEN** a preset carrying `"mode": "particle-life"` is applied
- **THEN** it loads with chemistry and fluid strengths zeroed, despite carrying nonzero values for
  both, because its mode excluded them

#### Scenario: A current preset never consults a mode

- **WHEN** a preset at the current schema version is applied
- **THEN** it carries its strengths explicitly, has no mode field, and the legacy branch is not
  taken

#### Scenario: Nothing names a mode

- **WHEN** the source tree is searched for a mode type, a mode id, or a list of modes
- **THEN** nothing is found outside the versioned decode's legacy translation table

### Requirement: Delta buffers have one reset owner

Every accumulation buffer SHALL be reset by an explicit frame-level node at that buffer's own
declared cadence, ahead of any pass in the same cadence that writes it, and every contributor pass
SHALL accumulate only. No pass self-resets a shared delta buffer, and every writer to a shared delta
buffer uses atomic accumulation. `fieldResolve`'s consume-and-zero of the deposit buffer remains
that buffer's single reset owner, which is also what makes skipping the deposit at zero strength
exact: the buffer a skipped deposit leaves behind is already zero.

The cadence is part of the declaration. `sbVelocityDelta`, `sbDensityDelta`, `sbSphDensityDelta`,
`sbCrowdDensityDelta` and `sbGridCounts` clear at `fncEverySubstep`, because every substep
accumulates into them afresh and integrates what they hold. `sbFieldAlive` clears at
`fncOncePerFrame`, because it counts the field the chemistry leaves and the chemistry itself runs
once per rendered frame (`src/sim_registry.nim:257-267`).

A buffer cleared per substep and written by a per-frame pass, or the reverse, would either lose
contributions or double them. The frame is the single owner precisely so that two contributors can
run together: if each pass self-reset `velocityDelta` in its own prologue, whichever ran second
would erase the first entirely.

Enforced by: `tests/test_sim_registry.nim` suite "Delta Buffers Have One Reset Owner" (`:171-215`),
which pins that every frame clears `velocityDelta` and `densityDelta` before any pass that writes
them and that no delta buffer is cleared twice, and suite "The Field Chemistry Runs Once Per
Rendered Frame" (`:334-403`), which pins each node's cadence and that no compute pass mixes two.

#### Scenario: Two contributors in one frame

- **WHEN** forces and fieldForce both run in a frame
- **THEN** both accumulate into velocityDelta atomically and integrate sees the sum

#### Scenario: A clear lands on the wrong cadence

- **WHEN** a delta buffer's clear node carries a cadence its writers do not share
- **THEN** `just test` fails

### Requirement: Field seeding is a one-shot

Field seeding SHALL occur only on explicit user action. The executor SHALL NOT seed on a change of
couplings or on a reset: `setCouplings` seeds nothing (`src/webgpu_compute.nim:143-166`), and the
single caller of `requestFieldSeed` is the canvas reseed callback wired at `src/app.nim:375`. The
seed shader and its pure mirror are retained for that action. Ignition in normal play comes from
particle deposits alone.

`fieldSeed` is registered in the shader manifest so its pipeline and bind group exist, and no
`buildFrame` result dispatches it. A seed request sets a pending flag and increments a nonce written
into `FieldParams` (`requestFieldSeed`, `src/webgpu_compute.nim:123-131`), so each seed places a
different pattern instead of repeating the last one. The executor consumes the flag at the top of
the next encoded frame, ahead of the frame walk (`src/webgpu_compute.nim:880-888`) — encoded there
because both prerequisites hold only at that point: the bind groups exist and the nonce-carrying
uniform has been written. The seed writes the front texture only, since every frame opens by reading
the front and writing the trail. It is deliberately excluded from the profiler passes and does not
bump the field generation, because the textures are not recreated.

Enforced by: `tests/test_shader_manifest.nim:82-89` (the seed spec is registered and no frame
dispatches it). That no other site requests a seed is **agent-checkable**: run `just be`, move each
coupling strength to zero and back and press reset, watching whether the pattern is replaced; a
violation appears as a grown pattern vanishing into fresh scattered blobs at a moment the user did
not ask for spores.

#### Scenario: Entering the chemical world

- **WHEN** couplings gain the field with no user seeding
- **THEN** the field starts at the trivial fixed point and ignites only where colonies deposit

#### Scenario: Seed is registered but never walked

- **WHEN** the frame description is walked
- **THEN** `fieldSeed` appears in no dispatch list, while remaining a loadable pipeline

### Requirement: Every dispatched pipeline resolves to a registered shader spec

Every `Dispatch.pipelineKey` a frame emits MUST resolve to a `ShaderSpec` returned by
`shaderSpecsFor(kind)` (`src/shader_manifest.nim:34`), which names the key, the URL the shader is
served at, its debug label, and its WGSL entry point. The relation is a subset, not an equality: a
one-shot such as `fieldSeed` is registered and dispatched by no frame node.

Spec keys MUST be unique within a kind, since they index the shared `pipelines` and `bindGroups`
dictionaries. Paths are deliberately not unique — `rdStepToFront` and `rdStepToTrail` register the
same path and entry point, one WGSL pipeline carrying two bind-group orientations of the field
ping-pong. Every path MUST be a `.wgsl` file under `./shaders/`, the prefix the native server serves
compute shaders from; registration in that server's static-file table belongs to `build-pipeline`.

At pipeline init the executor SHALL collect the specs of every pre-warmed kind, deduplicated by key,
and create every pipeline and bind-group layout up front (`src/webgpu_compute.nim:571-635`), so a mode
switch never waits on a shader load. A kind whose pipelines were not pre-warmed MUST be refused by
`setActiveSimKind`, which keeps the running frame and warns rather than dispatching a pipeline that
was never created (`src/webgpu_compute.nim:147-150`).

Enforced by: `tests/test_shader_manifest.nim:41-63` (dispatch keys are a subset of spec keys, across
every kind whose `buildFrame` does not raise) and `tests/test_shader_manifest.nim:66-158`
(well-formedness and per-kind spec sets).

#### Scenario: Shader registration forgotten

- **WHEN** a frame gains a dispatch whose pipeline key has no `ShaderSpec`
- **THEN** `just test` fails, rather than the pipeline being blank at runtime

#### Scenario: Unrunnable mode requested

- **WHEN** a mode whose shaders this build does not pre-warm is selected
- **THEN** the executor keeps its current frame and logs a warning

### Requirement: The field ping-pong chain closes every frame

The reaction-diffusion frame's field texture ping-pong SHALL end each frame on the front texture —
the one the renderer, `fieldForce`, and the next frame's resolve all read. `fieldResolve` is itself a
swap (front to trail), so a frame performs `1 + RD_STEPS_PER_FRAME` swaps and that total MUST be
even. The substeps therefore start by writing back to the front, alternating `rdStepToFront` and
`rdStepToTrail` (`src/sim_registry.nim:269-273`), and the bind groups are named for their destination
texture so the orientation is readable at the dispatch site
(`src/webgpu_compute.nim:446-470`).

`RD_STEPS_PER_FRAME` MUST be odd. A static assertion in `src/field_core.nim:108-115` fails the
compile otherwise, because an even count leaves the live field on the trailing texture where nothing
looks for it, silently discarding the last substep of every frame.

Enforced by: the compile-time `doAssert` in `src/field_core.nim:115` and
`tests/test_sim_registry.nim:178-190` (the substep dispatches alternate, start `rdStepToFront`, and
end `rdStepToFront`).

#### Scenario: Step count made even

- **WHEN** `RD_STEPS_PER_FRAME` is set to an even value
- **THEN** the build fails at compile time

#### Scenario: Substep sequence reordered

- **WHEN** the substep alternation starts on the trailing texture
- **THEN** `just test` fails

### Requirement: Ignition from colonies

The deposit pass SHALL splat each particle's contribution over a radius with a falloff kernel, sized
by the native ignition sweep in `tests/test_field_core.nim` so that a coherent colony's deposits lift
the field off Gray-Scott's trivial fixed point within seconds. The sweep's minimum igniting
(radius, amplitude) is the kernel's floor, recorded beside the constant it warrants
(`RD_DEPOSIT_SPLAT_RADIUS`, `src/field_core.nim:289-300`).

The kernel SHALL be normalized, so a particle contributes the same total deposit whatever the
radius. Spreading redistributes; it does not amplify, which is why widening the radius cannot flood
the field past the ceiling `RD_DEPOSIT_MAX` is measured against.

Enforced by: `tests/test_field_core.nim` suite "Ignition From Coherent Deposits" (`:792-910`), whose
tests pin that a clustered deposit ignites where a scattered deposit of equal coverage does not
(`:802-831`), that the shipped radius ignites at the shipped deposit (`:833-840`), that a radius
below the critical one relaxes to background (`:842-859`), and that the kernel conserves a
particle's total deposit at every radius (`:880-909`).

#### Scenario: Colony ignites the field

- **WHEN** a settled cluster deposits with the shipped kernel at the default deposit amount
- **THEN** a pattern emerges at the cluster's location without any seed

#### Scenario: Kernel stays measurement-backed

- **WHEN** the splat radius or the deposit ceiling changes
- **THEN** the ignition sweep still passes at the new values, or `just test` fails

### Requirement: The default climate sits where patterns must be nucleated

The default feed and kill SHALL sit in a region where `F < 4*(F+k)^2`, where the trivial state is
the only homogeneous fixed point and is linearly stable, so no pattern can arise without a
supercritical perturbation. This is what makes the field a record of life. `RD_DEFAULT_FEED` is
0.030 and `RD_DEFAULT_KILL` is 0.062 (`src/field_core.nim:132-137`), which puts `4*(F+k)^2` at
0.033856 against a feed of 0.030.

Regions where the field self-starts SHALL remain reachable through the controls; the difference is
that the user chooses them.

Enforced by: `tests/test_field_core.nim` suite "Gray-Scott Fixed-Point Structure" (`:511-577`),
which pins the discriminant's sign at the shipped defaults (`:549-560`) and that some reachable
(feed, kill) pair still lands in the self-starting region (`:562-577`).

#### Scenario: Empty world stays empty

- **WHEN** the field couples with no particles present and no user seeding
- **THEN** the field is analytically at its only stable homogeneous fixed point, and a scattered
  deposit reaches no cell above the alive threshold within `IGNITION_FRAME_BUDGET` frames, which is
  the horizon `tests/test_field_core.nim:802-814` runs

#### Scenario: The self-starting region stays reachable

- **WHEN** a user moves feed and kill into a region where the discriminant is non-negative
- **THEN** the sliders reach it, and `just test` fails if a re-range locks that regime away

### Requirement: A second reaction has reserved slots

The field textures' `.b` and `.a` channels SHALL be preserved instead of overwritten with literals,
and documented as reserved state channels for a multi-channel reaction
(`web/shaders/src/rd-step.wgsl:108-112`, `web/shaders/src/field-resolve.wgsl:59,95`).
`reactionKind` SHALL be a named constant set carried in a `ReactionParams` uniform bound to the
reaction pass (`web/shaders/src/rd-step.wgsl:51,99`).

These reserve addressable slots. No second reaction is implemented, and no readiness beyond
addressability is claimed.

Enforced by: `tests/test_gpu_types.nim` suite "Generated ReactionParams Layout (Reaction Identity)"
(`:335-365`) for the uniform's existence and extent. That the shader text carries the reserved
channels through every advancing pass is **agent-checkable**: run `just be` with chemistry active,
capture the field over successive frames, and confirm the rendered pattern is stable; a pass writing
literals into `.b` and `.a` shows up as the field's reserved state resetting, which a later reaction
would read as its own state being erased. A source lint over the field passes' `textureStore` calls
would close it.

#### Scenario: Reserved channels survive a frame

- **WHEN** the field advances through resolve and the reaction substeps
- **THEN** whatever occupies the `.b` and `.a` channels is carried through unchanged

#### Scenario: Gray-Scott is unaffected

- **WHEN** `reactionKind` holds its Gray-Scott value
- **THEN** the field evolves from the same parameters exactly as it does with no reaction selector
  present, because no reaction parameter lives in that uniform until a reaction reads it
