## MODIFIED Requirements

### Requirement: Frame descriptions are pinned by native tests

The exact pass list for a given set of coupling strengths SHALL be pinned by
`tests/test_sim_registry.nim`, so a reordering of GPU work fails `just test` instead of showing up
as changed physics. The pinning is written as a derivation, not as a table of worlds: stripping the
coupling-owned keys from any frame leaves exactly `WORLD_INTRINSIC_SEQUENCE`
(`tests/test_sim_registry.nim:50`, asserted by the test "no world enumerates: every frame is the
intrinsic sequence plus its couplings"), so a further coupling cannot reintroduce enumeration by
accident. The zero-strength skip and the all-couplings-active frame are both covered (suite "A
Strength At Zero Skips Its Own Pass And Nothing Else"), together with the case that a strength one
part in a billion above zero dispatches its pass.

Each compute pass node carries a profiler slot indexing one timestamp query set. Slots that index
the query set MUST be pairwise distinct and MUST be distinct within any one frame — two passes
sharing a slot overwrite each other's timestamps and report a meaningless duration. Passes carrying
`PROFILER_SLOT_NONE` write no timestamps and may share it.

Every pass that writes the velocity delta SHALL carry a slot that indexes the query set, and no such
pass SHALL share its node with another coupling's writer. The velocity-delta writers are five:
`forces` (the world-intrinsic neighbour sweep, which also carries the species term and the world
pressure), `forcesSph`, `fieldForce`, `lrForce` and `bodyForce`. The deposit, which writes the field,
SHALL likewise sit in a node whose slot no world-intrinsic field pass shares. So the fluid's cost is
read apart from the sweep's, the long-range force apart from its solve, and the deposit apart from the
chemistry's own evolution (`coupling-contract`, "Every coupling's cost is declared and measured").
Every such pass SHALL belong to exactly one coupling declaration, or be the neighbour sweep
(`coupling-contract`, "Every coupling is declared once"). Each slot in `src/sim_registry.nim` SHALL
equal its mirror in `src/gpu_profiler.nim`, and the `[gpu-profile]` line SHALL report each slot under
its own name. The `physics=` figure SHALL keep its meaning, the neighbour sweep plus integrate
(`src/app.nim:308-309`), so a reading taken before the split compares with one taken after.

Enforced by: `tests/test_sim_registry.nim`, run by `just test` and `just check`. Suite "Profiler Slot
Constants" holds the slots distinct and every timestamped pass in every frame on its own slot
(test-held). The same suite, walking every coupling mask, holds that each of the five velocity-delta
writers and the deposit sits in a node whose slot is not `PROFILER_SLOT_NONE`, and that the node
holds no other coupling's writer (test-held). That each registry slot equals its `gpu_profiler`
mirror is **unenforced**: `src/gpu_profiler.nim` does not compile natively
(`src/sim_registry.nim:255-257`). Moving the pass constants into a pure module that both import would
close it.

#### Scenario: Unreviewed frame change goes red

- **WHEN** the pass list for any pinned set of strengths changes without its test changing
- **THEN** `just test` fails

#### Scenario: Two passes claim one profiler slot

- **WHEN** a frame's compute passes reuse a slot that indexes the query set
- **THEN** `just test` fails

#### Scenario: A velocity writer runs untimed

- **WHEN** `lrForce`, `fieldForce` or any other velocity-delta writer sits in a node carrying
  `PROFILER_SLOT_NONE`
- **THEN** `just test` fails and names the pipeline key

#### Scenario: The fluid's cost hides inside the sweep's

- **WHEN** `forcesSph` is dispatched in the same node as `forces`
- **THEN** `just test` fails, because the fluid's time would be reported as the sweep's

### Requirement: A world serializes as its strengths

Presets SHALL carry coupling strengths and SHALL NOT carry a mode. A world's identity is the
numbers it holds, so no type, id round-trip, or catalog naming a fixed list of worlds exists in the
live model (`tests/test_no_modes.nim:17-29`, which forbids both the identifiers and the three
quoted ids they serialized as).

Presets written against schema version 1 SHALL be translated once, in the versioned decode's legacy
branch (`migrate`, `src/preset.nim:676`), where the file's `mode` field is consulted to zero the
strengths that world excluded. `LEGACY_MODE_COUPLINGS` (`src/preset.nim:603-612`) is the table that
translation reads, and it is the one place in the codebase naming a mode.

Subtraction cannot do this job. Version 1 serializes every scalar unconditionally and parses each
with a nonzero default, so nothing is ever absent to subtract, and a version 1 particle-life file
carries a live `rdDeposit` and `rdFieldForce` from sliders its world hid. The mode id is the only
record of which values that world read.

Consulting `mode` there is versioned-schema history about files written by old builds, reachable
only from a branch guarded on an older schema version. The test that asserts nothing names a mode
SHALL scope itself to the live model with that branch as a stated, justified exemption
(`tests/test_no_modes.nim:38-50`).

`CURRENT_SCHEMA_VERSION` SHALL move from 4 (`src/preset.nim:49`) to 5, and `migrate` SHALL gain a
`fromVersion < 5` branch. That branch converts every coupling strength to the contract's 0–1 scale
before the clamp, and drops the substep count, the colormap index and the field opacity. It follows
`coupling-contract`, "A saved world converts to the contract, then the clamp decides". The branches
fall through, so a version 1 file is translated from its mode first and then converted. The strength
the conversion reads is the one the earlier branches left. The version 5 schema SHALL carry no
`sphSubsteps`, `colormapIndex` or `fieldOpacity` field. The long-range unit reads the onset ratio
`x_on` (`coupling-contract`, "The long-range pull is measured in the pair unit and not in mesh
cells"), so `src/preset.nim` SHALL record the `x_on` that version 5's long-range unit was defined at.
A static assertion SHALL hold that record equal to the live onset constant, so a re-derived onset
fails the build until a further version branch converts.

Enforced by: `tests/test_no_modes.nim` (the sweep and its exemption) and `tests/test_preset.nim` suite
"A Legacy Preset Loads As The World It Described", which covers the version 1 translation
(test-held). The version 5 branch is held by the `tests/test_preset.nim` suite `coupling-contract`
names (test-held). A version 1 fixture carrying Force Strength through both branches decodes to the
converted value (test-held). The `x_on` record is held by a static assertion in `src/preset.nim`
(build-asserted).

#### Scenario: An old preset loads as the world it was saved as

- **WHEN** a preset carrying `"mode": "particle-life"` is applied
- **THEN** it loads with chemistry and fluid strengths zeroed, despite carrying nonzero values for
  both, because its mode excluded them

#### Scenario: A current preset never consults a mode

- **WHEN** a preset at the current schema version is applied
- **THEN** it carries its strengths explicitly, has no mode field, and neither the legacy branch nor
  the contract conversion is taken

#### Scenario: Nothing names a mode

- **WHEN** the source tree is searched for a mode type, a mode id, or a list of modes
- **THEN** nothing is found outside the versioned decode's legacy translation table

#### Scenario: A version 4 world loads on the contract's scale

- **WHEN** a version 4 preset carrying Force Strength, a substep count, a colormap index and a field
  opacity is applied
- **THEN** its Force Strength is the converted value clamped to 0–1, and the other three fields are
  absent from the decoded preset without error

#### Scenario: The onset moves without a conversion

- **WHEN** the live onset ratio is changed and no new schema branch converts the long-range strength
- **THEN** the build fails at the `x_on` assertion in `src/preset.nim`

### Requirement: Delta buffers have one reset owner

Every accumulation buffer SHALL be reset by an explicit frame-level node at that buffer's own
declared cadence, ahead of any pass in the same cadence that writes it, and every contributor pass
SHALL accumulate only. No pass self-resets a shared delta buffer, and every writer to a shared delta
buffer uses atomic accumulation. `fieldResolve`'s consume-and-zero of the deposit buffer remains
that buffer's single reset owner, which is also what makes skipping the deposit at zero strength
exact: the buffer a skipped deposit leaves behind is already zero.

The velocity delta SHALL be held in two words per particle, a fine word and a coarse word, under the
split `coupling-contract` states ("Every velocity impulse accumulates per reference frame in words
that fit a full crowd"). Both words are delta buffers under this requirement. Each SHALL be cleared
once per substep by a frame-level node ahead of every one of the five velocity-delta writers:
`forces`, `forcesSph`, `fieldForce`, `lrForce` and `bodyForce`. Integrate is the one pass that reads
both words. Every document that lists the velocity-delta contributors SHALL list those five, the
`sbVelocityDelta` doc in `src/sim_registry.nim` among them.

The cadence is part of the declaration. `sbVelocityDelta`, the coarse velocity word, `sbDensityDelta`,
`sbSphDensityDelta`, `sbCrowdDensityDelta`, `sbBodyAccum` and `sbGridCounts` clear at
`fncEverySubstep`, because every substep accumulates into them afresh and integrates what they hold.
`sbFieldAlive` and `sbLrDensity` clear at `fncOncePerFrame`, because the chemistry and the long-range
deposit that fill them run once per rendered frame (`src/sim_registry.nim:355-371`).

A buffer cleared per substep and written by a per-frame pass, or the reverse, would either lose
contributions or double them. The frame is the single owner precisely so that two contributors can
run together: if each pass self-reset a velocity word in its own prologue, whichever ran second
would erase the first entirely.

Enforced by: `tests/test_sim_registry.nim` suite "Delta Buffers Have One Reset Owner". It pins that
every frame clears both velocity words and `densityDelta` before any pass that writes them, walking
all five velocity-delta pipeline keys, and that no delta buffer is cleared twice (test-held). Suite
"The Field Chemistry Runs Once Per Rendered Frame" pins each node's cadence and that no compute pass
mixes two (test-held). That the `sbVelocityDelta` doc lists five writers is **agent-checkable**: read
the doc against the suite's list of velocity-delta keys.

#### Scenario: Two contributors in one frame

- **WHEN** forces and fieldForce both run in a frame
- **THEN** both accumulate into the velocity words atomically and integrate sees the sum

#### Scenario: A clear lands on the wrong cadence

- **WHEN** a delta buffer's clear node carries a cadence its writers do not share
- **THEN** `just test` fails

#### Scenario: A writer precedes the coarse word's clear

- **WHEN** any of `forces`, `forcesSph`, `fieldForce`, `lrForce` or `bodyForce` is dispatched in a
  frame ahead of the clear of either velocity word
- **THEN** `just test` fails and names the pipeline key
