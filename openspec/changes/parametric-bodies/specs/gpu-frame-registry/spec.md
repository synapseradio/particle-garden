## MODIFIED Requirements

### Requirement: Delta buffers have one reset owner

Every accumulation buffer SHALL be reset by an explicit frame-level node at that buffer's own
declared cadence, ahead of any pass in the same cadence that writes it, and every contributor pass
SHALL accumulate only. No pass self-resets a shared delta buffer, and every writer to a shared delta
buffer uses atomic accumulation. `fieldResolve`'s consume-and-zero of the deposit buffer remains
that buffer's single reset owner, which is also what makes skipping the deposit at zero strength
exact: the buffer a skipped deposit leaves behind is already zero.

The cadence is part of the declaration. `sbVelocityDelta`, `sbDensityDelta`, `sbSphDensityDelta`,
`sbCrowdDensityDelta`, `sbBodyAccum` and `sbGridCounts` clear at `fncEverySubstep`, because every
substep accumulates into them afresh and integrates what they hold. `sbFieldAlive` clears at
`fncOncePerFrame`, because it counts the field the chemistry leaves and the chemistry itself runs
once per rendered frame (`src/sim_registry.nim:257-267`).

A buffer cleared per substep and written by a per-frame pass, or the reverse, would either lose
contributions or double them. The frame is the single owner precisely so that two contributors can
run together: if each pass self-reset `velocityDelta` in its own prologue, whichever ran second
would erase the first entirely.

An accumulator's element count and its fixed-point scale belong to the buffer, not to the rule. The
per-particle accumulators hold one or two words per particle and receive only that particle's own
contributions; `sbBodyAccum` holds three words per body — force in two axes and torque — and may
receive a contribution from every particle in the world in one dispatch. A buffer whose worst-case
accumulated magnitude exceeds its element type's range SHALL carry a static assertion relating the
particle budget, the largest contribution its ranges admit, and its scale, so that widening a range
past what the buffer can hold fails the Nim compile rather than wrapping around in the browser.

A pass MAY both fill and consume an accumulator inside one frame, and where it does, the consumer
SHALL run after every contributor and SHALL NOT reset the buffer. `sbBodyAccum` is filled by the
particle-side bodies pass and consumed by the body-side integrate that follows it in the same compute
pass; the frame still owns the clear, so a second contributor to the same accumulator would compose
with the first rather than erasing it.

Enforced by: `tests/test_sim_registry.nim` suite "Delta Buffers Have One Reset Owner" (`:171-215`),
which pins that every frame clears `velocityDelta` and `densityDelta` before any pass that writes
them and that no delta buffer is cleared twice, and suite "The Field Chemistry Runs Once Per
Rendered Frame" (`:334-403`), which pins each node's cadence and that no compute pass mixes two. The
overflow assertion is Build-asserted beside the scale it constrains.

#### Scenario: Two contributors in one frame

- **WHEN** forces and fieldForce both run in a frame
- **THEN** both accumulate into velocityDelta atomically and integrate sees the sum

#### Scenario: A clear lands on the wrong cadence

- **WHEN** a delta buffer's clear node carries a cadence its writers do not share
- **THEN** `just test` fails

#### Scenario: A consumer inside the frame does not reset what it reads

- **WHEN** the body-side integrate consumes the body accumulator
- **THEN** it leaves the buffer alone and the frame's own clear node is still the only reset

#### Scenario: A range that would overflow an accumulator fails the build

- **WHEN** a range change makes an accumulator's worst-case value exceed its element type
- **THEN** `just happen` fails at the Nim compile

## ADDED Requirements

### Requirement: A coupling may dispatch over something that is neither particles nor field cells

A frame's dispatch sizes stay symbolic and the executor resolves each against the live world, and
that set SHALL be open to a coupling whose work is sized by neither the particle count nor the field
dimensions. A coupling owning a fixed-ceiling population of its own MAY dispatch a single workgroup
(`dsOne`) over it, and SHALL hold a static assertion that its ceiling does not exceed that pass's
workgroup size, since a single-workgroup dispatch silently drops everything past the workgroup's
width. The ceiling is a Nim constant and the buffer sized from it appears in `byteLengthFor`'s
exhaustive `case` (`src/webgpu_compute.nim:841-851`), so a buffer without a byte length is a compile
error.

Such a coupling composes exactly like every other: one strength on `WorldCouplings`, `acts` as the
only comparison (`src/sim_registry.nim:83-87`), its passes coupling-owned and skipped at exactly
zero, and no combination named anywhere. Where a coupling contributes two passes that must run in
order — one filling an accumulator, one consuming it — they MAY share one compute pass node, whose
dispatches the executor encodes in sequence.

A coupling-owned pass that advances state of its own across frames is skippable at zero only while
that state is unobservable at zero. Where a later change makes such state observable by any route the
strength does not scale, the pass becomes world-intrinsic and the skip becomes a discontinuity.

Enforced by: `tests/test_sim_registry.nim`, which strips coupling-owned keys from every frame in
`tests/coupling_space.nim`'s `ALL_COUPLINGS` and asserts the intrinsic sequence remains
(`:160-168`), and `tests/test_shader_manifest.nim`, whose world count is derived from the coupling
space rather than written down (`:40-42`). Build-asserted: the workgroup-ceiling assertion and
`byteLengthFor`'s exhaustive case.

#### Scenario: A per-body pass skips at exactly zero like any other

- **WHEN** a coupling dispatching over its own population has strength exactly zero
- **THEN** neither of its passes is dispatched and the rest of the frame is unchanged

#### Scenario: A ceiling past the workgroup width fails the build

- **WHEN** a coupling's population ceiling is raised above its single-workgroup pass's workgroup size
- **THEN** `just happen` fails at the Nim compile

#### Scenario: A fifth coupling widens every world sweep

- **WHEN** a coupling is added to `tests/coupling_space.nim`
- **THEN** every "for every world" invariant in the registry and manifest suites runs over the wider
  space without any of them naming a combination
