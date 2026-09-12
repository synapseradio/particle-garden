## MODIFIED Requirements

### Requirement: Frame described as data

The GPU work of one physics frame SHALL be a pure `FrameDescription` — a sequence of `FrameNode`
values returned by `buildFrame(couplings: WorldCouplings; rdSteps: int)`
(`src/sim_registry.nim:222`) — describing ONE world, and never a hand-coded sequence of encoder
calls. Species forces, fluid pressure, chemistry and the long-range mesh each contribute according to
a continuous strength (`WorldCouplings`, `src/sim_registry.nim:66-82`), and zero SHALL be an ordinary
value of that strength, never a state the world is in. `acts` (`src/sim_registry.nim:83-87`) is the
one place a strength is compared to anything, so a threshold cannot be introduced elsewhere without
deleting that function first.

Passes SHALL divide into two kinds. **World-intrinsic** passes — the grid-build triad and scatter,
the neighbour sweep in `forces`, the field's own Gray-Scott evolution, and `integrate` — run
whenever the world runs and SHALL NOT be skipped by any strength. **Coupling-owned** passes exist
only to make one coupling act on the particles, SHALL be multiplied by that coupling's strength
across their entire output, and MAY be skipped at exactly zero. Forces are the asymmetric case: the
force term is coupling-owned and `forces.wgsl` scales it inside the shader, while its pass also
measures density and applies the mouse and the blast, so no force strength may skip it.

A coupling MAY own a **chain** of passes rather than a single pass. The rule applies to the chain as
one unit: a chain is coupling-owned when no pass outside it reads any of its intermediate products,
so that the strength multiplies everything the chain as a whole produces, even where an intermediate
pass writes a quantity the strength does not scale. Every pass of a coupling-owned chain SHALL be
guarded by one `acts(...)` test on that coupling's strength, so the chain is dispatched entire or not
at all. The long-range mesh is such a chain: deposit, transforms, kernel and force, whose only output
is the velocity delta its force pass writes.

A node is a buffer clear, a buffer copy, or a compute pass carrying a label, a profiler slot, and an
ordered list of `Dispatch` values naming a pipeline key and a symbolic `DispatchSize`. Every node
also carries a `FrameNodeCadence` (`src/sim_registry.nim:154-166`), which is how often the executor
encodes it inside one rendered frame, and a node holds exactly one cadence, since a node is the unit
the executor skips. A chain MAY span two nodes at two cadences where its parts answer to different
clocks, as the chemistry's does: the solve on the rendered frame's clock, the force on the substep's.

The description MUST be free of live counts. Dispatch sizes stay symbolic and the executor resolves
them against the frame's particle count, grid dimensions, field dimensions and long-range grid
dimensions during the walk (`src/webgpu_compute.nim:861-869`). A symbolic size SHALL declare its
dimensionality, and the executor SHALL dispatch each through the overload of that dimensionality;
resolving a multi-dimensional size through the one-integer path raises
(`src/webgpu_compute.nim:866-869`). `dsFieldWorkgroups` is two-dimensional. The species-batched
long-range sizes are three-dimensional, batching species through the dispatch's z dimension, and the
live species count SHALL be the extent of that dimension, so a world running fewer species dispatches
less work.

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
for the vocabulary a fixed list of worlds would need. That every strength of `WorldCouplings` appears
in `sameFrameShape` (`src/webgpu_compute.nim:133-141`) is **unenforced** — a strength missing from it
crosses zero without the frame noticing; closed by deriving the comparison from the record's fields
rather than writing one line per strength.

#### Scenario: One world runs forces and chemistry together

- **WHEN** force strength and the deposit and field-force strengths are non-zero, and fluid strength
  is zero
- **THEN** one frame runs the grid triad, forces, the field passes, and integrate, in that order

#### Scenario: Zero strength dispatches none of its coupling-owned passes

- **WHEN** a coupling's strength is exactly zero
- **THEN** no coupling-owned pass belonging to it is dispatched

#### Scenario: A coupling-owned chain is skipped entire

- **WHEN** a coupling owning a chain of passes has its strength at exactly zero
- **THEN** every pass of that chain is absent from the frame, and no pass outside the chain changes

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

#### Scenario: Species count changes

- **WHEN** the live species count changes between frames
- **THEN** the stored frame description is unchanged and the executor resolves the z extent of every
  species-batched dispatch against the new count on the next walk

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
every group heading and slider the panel shows, drag Force Strength, Fluid Strength, Deposit, Field
Force and Long Range each to zero and back, and compare the control set after each move; a violation
appears as a section or slider present in one capture and absent in another. The procedure SHALL
range over every strength of `WorldCouplings`, so adding a coupling widens it.

#### Scenario: Controls do not come and go

- **WHEN** any coupling strength changes, including to or from zero
- **THEN** the set of controls the panel offers is unchanged

#### Scenario: No lookup from world to control set exists

- **WHEN** the source tree is searched for a per-world control-group lookup
- **THEN** nothing is found, and `just test` fails if such a name is reintroduced

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
once per rendered frame (`src/sim_registry.nim:257-267`). The long-range density accumulator clears at
`fncOncePerFrame`, because the solve that consumes it runs on the rendered frame's clock; its clear
is unconditional, like every other delta clear, so the buffer a skipped chain leaves behind is
already zero and the skip is exact rather than merely cheap.

A buffer cleared per substep and written by a per-frame pass, or the reverse, would either lose
contributions or double them. The frame is the single owner precisely so that two contributors can
run together: if each pass self-reset `velocityDelta` in its own prologue, whichever ran second
would erase the first entirely.

An accumulator written by one cadence and read by another SHALL declare that split. The long-range
potential is written once per rendered frame and read once per substep, which is sound because the
substeps read it without writing it, exactly as `fieldForce` reads the field texture.

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

#### Scenario: A per-frame accumulator is not cleared per substep

- **WHEN** a world runs more than one substep with the long-range chain acting
- **THEN** the density is deposited and solved once, and every substep reads the same potential
