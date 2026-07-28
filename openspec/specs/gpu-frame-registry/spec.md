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
values returned by `buildFrame(kind: SimKind)` (`src/sim_registry.nim:192`) — and never a hand-coded
sequence of encoder calls. A node is a buffer clear, a buffer copy, or a compute pass carrying a
label, a profiler slot, and an ordered list of `Dispatch` values naming a pipeline key and a symbolic
`DispatchSize`. `buildFrame` MUST raise `ValueError` for a kind whose frame is not implemented, so a
mode cannot silently run another mode's physics.

The description MUST be free of live counts. Dispatch sizes stay symbolic (`dsParticleWorkgroups`,
`dsScanBlocks`, `dsOne`, `dsFieldWorkgroups`) and the executor resolves them against the frame's
particle count, grid dimensions, and field dimensions during the walk
(`src/webgpu_compute.nim:830-891`). `dsFieldWorkgroups` is the one two-dimensional size and MUST be
dispatched through the `(x, y)` overload; resolving it through the one-integer path raises
(`src/webgpu_compute.nim:835-838`).

The executor SHALL build the active description once — at pipeline init and on a mode switch
(`setActiveSimKind`, `src/webgpu_compute.nim:139-159`) — and walk that stored description every
frame. Substepping is an executor loop, not frame nodes: the executor encodes the whole description
`substepCount` times into one command encoder (`src/webgpu_compute.nim:864-892`), so the description
always holds exactly one substep's work.

Enforced by: `src/sim_registry.nim` (pure module, natively compiled and tested),
`tests/test_sim_registry.nim`.

#### Scenario: Particle count changes

- **WHEN** the particle count changes between frames
- **THEN** the stored frame description is unchanged and the executor resolves
  `dsParticleWorkgroups` against the new count on the next walk

#### Scenario: A new mode is added

- **WHEN** a simulation kind gains a `buildFrame` case
- **THEN** its passes become data in `src/sim_registry.nim` and the executor dispatches them without
  a new branch of its own

#### Scenario: A mode without a frame is selected

- **WHEN** `buildFrame` is called for a kind whose frame is not implemented
- **THEN** it raises `ValueError` rather than returning another kind's passes

### Requirement: Frame descriptions are pinned by native tests

Every implemented simulation kind's exact pass list SHALL be pinned node-by-node by
`tests/test_sim_registry.nim`, so a reordering of GPU work fails `just test` rather than showing up
as changed physics. The pinned shapes are: particle-life, four nodes — clear `sbGridCounts`, the
four-dispatch `Grid Build` pass, the `sbGridOffsets` → `sbFillPointers` copy, and the three-dispatch
`Physics (AoS)` pass (`tests/test_sim_registry.nim:46-99`); SPH, the same four-node shape with
`forcesSph` substituted for `forces` and the label `Physics (SPH)`
(`tests/test_sim_registry.nim:102-147`); reaction-diffusion, three nodes — the `Field (RD)` pass, an
explicit `sbDensityDelta` clear, and a `Physics (RD)` pass dispatching only `integrate`, with no
spatial-hash clear or copy anywhere in the frame (`tests/test_sim_registry.nim:150-207`).

Each compute pass node carries a profiler slot indexing one timestamp query set, and the slots
mirrored from `src/gpu_profiler.nim:24,25,34` MUST be pairwise distinct and MUST be distinct within
any one frame — two passes sharing a slot overwrite each other's timestamps and report a meaningless
duration (`tests/test_sim_registry.nim:210-225`).

Enforced by: `tests/test_sim_registry.nim`, run by `just test` and `just check`.

#### Scenario: Unreviewed frame change goes red

- **WHEN** any mode's pass list changes without its pinned test changing
- **THEN** `just test` fails

#### Scenario: Two passes claim one profiler slot

- **WHEN** a frame's compute passes reuse a profiler slot
- **THEN** `just test` fails

### Requirement: Control groups live beside the frame

The descriptor groups a mode's control panel presents SHALL be declared by
`controlGroupsFor(kind: SimKind)` (`src/sim_registry.nim:74-92`), in the same module as `buildFrame`,
because what a mode's frame dispatches decides which knobs can affect it. A group not listed for a
mode is absent from that mode's panel, not disabled.

The relation between dispatches and groups MUST be asserted natively
(`tests/test_sim_registry.nim:228-293`): the attraction-matrix and force-model groups appear exactly
for modes that dispatch the `forces` pipeline; the `grid` group appears exactly for modes that
dispatch `binCount`; the reaction-diffusion groups appear only for reaction-diffusion; and the
universal groups (`simulation`, `render`, `glow`, `bloom`, `palette`) appear for every mode.

Every group id a mode lists MUST either own at least one descriptor from `buildParamDescriptors()`
or be declared in `SECTION_ONLY_GROUPS` (`src/sim_registry.nim:70`), which names the panel sections
that are not slider lists. Conversely, every descriptor group MUST be listed by at least one mode, so
no slider becomes unreachable. The descriptors themselves belong to `parameter-range-authority`; this
capability owns only which groups each mode presents.

Enforced by: `tests/test_sim_registry.nim:228-293`.

#### Scenario: Group id typo

- **WHEN** a mode lists a group id that owns no descriptor and is not declared section-only
- **THEN** `just test` fails instead of the panel silently hiding a section

#### Scenario: Mode without a force pass

- **WHEN** a mode's frame dispatches no `forces` pipeline
- **THEN** `controlGroupsFor` for that mode offers neither the attraction matrix nor the force-model
  groups

### Requirement: Simulation identity serializes by stable id

A simulation kind SHALL serialize by the stable string ids `particle-life`, `sph`, and
`reaction-diffusion` via `simKindId` / `parseSimKind` (`src/sim_registry.nim:39-52`), never by enum
ordinal, so reordering `SimKind` cannot change what a saved preset means.

`parseSimKind` MUST raise `ValueError` for an unknown id, and every caller reading untrusted input
MUST catch it and fall back explicitly rather than propagate: preset apply keeps the running mode and
warns (`src/web_api.nim:544-552`), the `gardenAPI` mode setter warns and ignores
(`src/web_api.nim:760-763`), and the `?mode=` URL override checks the id against `SimKind` before
parsing (`src/app.nim:379-387`).

Enforced by: `tests/test_sim_registry.nim:31-43` (id values pinned, round-trip over every kind,
unknown id raises).

#### Scenario: Enum reordered

- **WHEN** the `SimKind` enum members are reordered
- **THEN** every previously saved preset still selects the same mode

#### Scenario: Preset carries an unrunnable mode

- **WHEN** a preset naming a mode this build cannot parse is applied
- **THEN** the running mode is kept, a warning is logged, and the rest of the preset still applies

### Requirement: Delta buffers have one reset owner

Every per-frame accumulation buffer SHALL have exactly one reset owner per frame, and the owner is
declared where it can be checked. Two mechanisms exist, and a buffer MUST use one, never both.

A pass that accumulates into a buffer with atomics owns that buffer's reset. `forces.wgsl` and
`forces-sph.wgsl` zero each particle's `velocityDelta` and `densityDelta` slots with `atomicStore`
before accumulating into them (`web/shaders/src/forces.wgsl:130-132`), and `field-resolve.wgsl`
zeroes each field cell's deposit slot as it consumes it (`web/shaders/src/field-resolve.wgsl:74`).
The particle-life and SPH frames therefore carry no clear node for `velocityDelta` or `densityDelta`,
and the reaction-diffusion frame carries none for `sbFieldDeposit`: an encoder-level clear would race
those atomics.

A buffer no pass in the frame writes is reset by an explicit frame node instead. The
reaction-diffusion frame's sole velocity writer, `fieldForce`, performs a plain non-atomic store into
`velocityDelta` in original index space (`web/shaders/src/field-force.wgsl:88-89`) and never touches
`densityDelta`, which `integrate` nevertheless binds unconditionally — so that frame carries an
explicit `clearBufferNode(sbDensityDelta)` (`src/sim_registry.nim:285`), without which `integrate`
would read values left behind by whichever mode ran before.

Grid buffers follow the same rule from the other side: `sbGridCounts` is cleared by an explicit frame
node because `binCount` increments it atomically without initializing it, and `sbFillPointers` is
seeded by a copy node from `sbGridOffsets` because `binScatter` consumes it as a running write cursor
(`src/sim_registry.nim:198-217`).

Enforced by: `tests/test_sim_registry.nim:87-93,142-147,195-207` (each frame's clear targets are
pinned, and no frame clears a delta buffer its passes self-reset).

#### Scenario: A clear is added beside a self-resetting pass

- **WHEN** a frame gains a clear node for `velocityDelta` or `densityDelta` in a mode whose force
  pass self-resets them
- **THEN** `just test` fails

#### Scenario: Reaction-diffusion integrates after a foreign mode

- **WHEN** the mode switches to reaction-diffusion after a mode that wrote `densityDelta`
- **THEN** the explicit clear node zeroes it before `integrate` reads it

### Requirement: Field seeding is a one-shot

The reaction-diffusion field seed SHALL be a one-shot the executor encodes on demand, never a frame
node. `fieldSeed` is registered in the shader manifest so its pipeline and bind group exist
(`src/shader_manifest.nim:89-90`), and no `buildFrame` result dispatches it.

A seed request sets a pending flag and increments a nonce written into `FieldParams`
(`requestFieldSeed`, `src/webgpu_compute.nim:131-137`), so each seed places a different pattern rather
than repeating the last one. The executor consumes the flag at the top of the next encoded frame,
ahead of the frame walk, and only while reaction-diffusion is active
(`src/webgpu_compute.nim:849-857`) — encoded there because both prerequisites hold only at that
point: the bind groups exist and the nonce-carrying uniform has been written. The seed writes the
front texture only, since every frame opens by reading the front and writing the trail
(`src/webgpu_compute.nim:472-485`). It is deliberately excluded from the profiler passes and does not
bump the field generation, because the textures are not recreated.

Seeding is requested on entry to reaction-diffusion, guarded so that re-selecting the already-active
mode does not wipe a grown pattern (`src/webgpu_compute.nim:156-157`); on a particle reset or
particle-count commit while that mode is active (`src/app.nim:145-151`); and through the canvas
reseed callback (`src/canvas_input.nim:63-75`, wired at `src/app.nim:348`).

Enforced by: `tests/test_shader_manifest.nim:116-128` (the seed spec is registered and no frame
dispatches it). The request sites are `review-enforced`: they live in JS-backend modules the native
suite cannot execute, and are verified by the build compiling them.

#### Scenario: Seed is registered but never walked

- **WHEN** the reaction-diffusion frame description is walked
- **THEN** `fieldSeed` appears in no dispatch list, while remaining a loadable pipeline

#### Scenario: Re-selecting the active mode

- **WHEN** the already-active reaction-diffusion mode is selected again
- **THEN** no seed is requested and the existing pattern survives

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
