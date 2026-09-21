## Purpose

Owns the one interface every link between matter and fields satisfies: the unit its impulse is
stated in, the time convention it accumulates under, what its strength means, when it runs and how
often, what it costs, how its controls dim, which other parameters bound it, and which space each of
its sizes is measured in. The couplings are the species force, the fluid, scent (field → particles),
deposit (particles → field), long range (particles → mesh → particles) and bodies (body ↔ particles).

## ADDED Requirements

### Requirement: Every coupling is declared once

`src/sim_registry.nim` SHALL hold exactly one declaration per coupling, in a table indexed by an
enumeration of the couplings. A declaration SHALL name:
- the strength parameter
- the unit function that returns its impulse
- its cadence, per frame or per substep
- its gate
- its profiler slots
- its dimming predicate
- the parameters its bounds read
- the space of each size it owns
- the substep count it requires at the live values

Every pass in the frame description that writes the velocity delta or the field SHALL belong to
exactly one declaration, or to the world-intrinsic neighbour sweep, which belongs to none.

Enforced by: the table's index type, so a coupling added to the enumeration without a declaration
fails to compile (build-asserted). `tests/test_sim_registry.nim` suite "Every Writer Belongs To One
Coupling" walks the frame descriptions for every coupling mask. It holds that each velocity-delta or
field writer maps to one declaration, or is the neighbour sweep (test-held).

#### Scenario: A writer with no declaration

- **WHEN** a pass that writes the velocity delta is added to the frame description without a
  declaration naming it
- **THEN** the registry suite fails and names the pass

#### Scenario: A coupling with no declaration

- **WHEN** a coupling is added to the enumeration and the table has no entry for it
- **THEN** the build fails

### Requirement: Every velocity impulse is stated in one unit

`u0` SHALL be the velocity that one touching neighbour's repulsion core hands a particle at pair gain
1 over one reference frame, `FRAME_DT_REFERENCE` (`src/physics_core.nim:23-26`). It SHALL NOT depend
on any slider. Every writer of the velocity delta SHALL have a pure function in
`src/balance_core.nim` that returns its largest per-particle impulse at a stated configuration, in
multiples of `u0`. The writers are each coupling that moves particles, the world pressure, the mouse
and the blast. Each function SHALL name the shader it mirrors under the reference-oracle rule
(`docs/enforcement.md`, Reference oracles). Deposit, which writes the field, SHALL state its output in
field concentration per cell per field step.

Enforced by: `tests/test_balance_core.nim` suite "Every Writer Answers In The Pair Unit". It checks
`u0` on one touching neighbour's repulsion. For each unit function, it sweeps that function's oracle
over a grid of configurations inside the ranges. It holds that no swept impulse exceeds the function's
value, and that the function's own configuration attains it (test-held). That each shader carries the
expression its oracle holds is **unenforced**, the standing condition of every reference oracle.

#### Scenario: One touching neighbour's repulsion is one unit

- **WHEN** one neighbour at contact acts on a particle at pair gain 1 over the reference frame
- **THEN** the repulsive impulse is exactly `u0`

#### Scenario: A unit function is the largest impulse

- **WHEN** a writer's oracle is swept over a grid of configurations inside its ranges
- **THEN** no swept impulse exceeds that writer's unit function, and the function's own
  configuration attains it within the oracle's floating-point tolerance

### Requirement: A strength of 1 is a coupling's calibrated full effect

Every coupling strength SHALL range from 0 to 1. At strength `s` and the shared reference
configuration, a coupling's impulse SHALL be `s · F_c · u0`, where `F_c` is that coupling's full effect.
`F_c` SHALL be recorded beside the coupling's gain constant in `src/config_ranges.nim`, with the
measurement that set it, under the measured-bound rule. The gain SHALL be derived from `F_c` and the
unit function, never set on its own. A full effect not yet measured SHALL carry a provisional note, as
`LONG_RANGE_STRENGTH_MAX` does (`src/config_ranges.nim:68-75`). No coupling SHALL carry a hidden gain
outside its declared one. The pair bump's ×4.0, `SPH_FORCE_SCALE` and `BODY_FORCE_CEILING` SHALL be
folded into their couplings' gains or recorded as that coupling's measured shape.

Enforced by: a static assertion per coupling in `src/config_ranges.nim` that its gain equals the value
derived from `F_c` and the unit function at the reference configuration (build-asserted).
`tests/test_balance_core.nim` suite "Strength Is A Fraction Of The Full Effect" holds, per coupling,
that the stepped oracle's impulse at strengths 0.25, 0.5 and 1 is that fraction of `F_c · u0` within
the oracle's tolerance (test-held). Whether each `F_c` reads as the intended full effect in play is
**agent-checkable**. An agent sets one coupling to 1 with the others at 0 over a settled world at the
default particle count, and watches the motion for the effect named beside `F_c`.

#### Scenario: Half strength is half the effect

- **WHEN** any coupling runs at strength 0.5 at the reference configuration
- **THEN** its impulse is half its impulse at strength 1

#### Scenario: A gain set by hand fails the build

- **WHEN** a coupling's gain constant is edited to a value other than the one its `F_c` derives
- **THEN** the build fails at the assertion

### Requirement: The species force is a coupling like the others

Force Strength SHALL range from 0 to 1 under the full-effect rule. The neighbour sweep SHALL run at
every Force Strength, because it measures the crowd density, applies the world pressure and carries
the mouse and the blast. At Force Strength 0, the species term SHALL add exactly zero to the velocity
delta, and the world pressure SHALL still act. Force Strength SHALL NOT scale the world pressure, and
crowding SHALL NOT bound compression (`world-pressure`).

Enforced by: `tests/test_physics.nim` suite "The Species Term Is Zero At Strength Zero". It holds that
the pair oracle's species contribution is exactly zero at strength 0 for every matrix entry and
distance, while the pressure contribution above the onset is non-zero (test-held). That `forces.wgsl`
carries the oracle's expression is **unenforced**, the standing condition of `physics_core`'s mirror.

#### Scenario: Force Strength 0 still resists compression

- **WHEN** Force Strength is 0 and a crowd sits above the onset
- **THEN** the crowd receives the world pressure and no species impulse

#### Scenario: Force Strength does not change how hard a crowd resists

- **WHEN** Force Strength moves between 0.2 and 1 with a crowd above the onset
- **THEN** the pressure impulse on each pair is unchanged

### Requirement: Every velocity impulse accumulates per reference frame in words that fit a full crowd

Every shader that writes the velocity delta SHALL accumulate its impulse per reference frame, not
multiplied by the substep, and integrate SHALL multiply the decoded delta by the frame factor once. No
writer SHALL apply its own time factor, on the CPU or in its shader. The delta SHALL be held in two
signed 32-bit words per particle: a fine word at 2^16 and a coarse word counting `2^k` fine quanta. A
writer whose full crowd does not fit the fine word SHALL split each integer `q` into `q >> k` for the
coarse word and `q & (2^k − 1)` for the fine word, which sum back to `q` exactly. `k` SHALL be the
largest value at which every writer's full-crowd contribution to the fine word fits. `q_max` SHALL be
the largest per-pair pressure the coarse word admits after SPH's. No user range SHALL be narrowed to
satisfy either word.

Enforced by: static assertions at the bottom of `src/config_ranges.nim`. They sum every writer's
per-particle maximum per reference frame into each word, and each term names its constants
(build-asserted). `tests/test_physics.nim` suite "A Full Crowd Decodes To Its Impulse" encodes a full
crowd at each writer's maxima through that writer's oracle, and decodes it through the integrate
oracle at frame factors 1, 2 and 30 (test-held). `tests/test_sim_registry.nim` holds that the frame
factor reaches only the particle and body integrate passes' parameters (test-held). That each shader carries the
convention is **unenforced**, the standing condition of the mirror.

#### Scenario: A full crowd on the largest substep keeps its impulse

- **WHEN** a full crowd at any writer's maxima acts on one particle on the largest substep
- **THEN** the decoded velocity delta equals the float impulse within one quantum times the frame
  factor, with its sign

#### Scenario: A writer applies its own frame factor

- **WHEN** a coupling's parameter block carries the frame factor
- **THEN** the registry suite fails and names the coupling

#### Scenario: A budget outgrows a word

- **WHEN** `MAX_PARTICLES`, `MATRIX_MAX_VALUE`, `MAX_VELOCITY_MAX`, `q_max`, `k` or any writer's
  per-particle maximum rises past its word's span
- **THEN** the build fails at the assertion, and the remedy is the words' scale, width or split, never
  a user range

### Requirement: The integrator owns the substep count

Each frame SHALL run `n` substeps, each advancing the frame's time over `n`, where `n` is the largest
of three counts:
- `⌈ff / ff_stable⌉`
- the count that keeps a particle at the live Max Velocity from travelling farther than the travel
  bound `T` in one substep
- the count each active coupling declares at the live values

A coupling is active while its strength is nonzero; bodies are active while a body is alive. `T`
SHALL be the smallest length that any active coupling declares it resolves. When
`n` would pass `SUBSTEPS_MAX`, the effect-time clamp SHALL lower the requesting coupling's effective
value, or the effective Max Velocity where the travel count requests it, never a stored value, and the
frame SHALL run `SUBSTEPS_MAX`. `SUBSTEPS_MAX` SHALL live in `src/config_ranges.nim`, replacing
`SPH_MAX_SUBSTEPS`, with the per-substep cost it was measured at beside it. The substep count SHALL have no
slider. `src/config_ranges.nim` SHALL hold `ff_stable` with its conditions beside it. `ff_stable` is
the largest frame factor, held fixed through a run, at which a dense self-attracting world at the
recorded `K` and shipped friction settles no warmer per reference frame than at frame factor 1. It is
measured on the gate seeds at 128 000 particles (`world-pressure`). The time-scale range SHALL NOT
be narrowed to avoid substeps.

Enforced by: `tests/test_balance_core.nim` suite "A Settling World Still Settles". On the gate
seeds at 128 000 particles it runs frame factors 2, 10 and 30, a frame factor drawn per frame from 8
to 16, and one alternating 10 and 13, through the substep rule. It holds each arm's three-seed mean no
warmer per reference frame than frame factor 1 at shipped friction (held by the `just
calibrate-balance` recipe, not by every `just check`). `tests/test_sim_registry.nim` suite "Substeps
Follow The Tightest Coupling" holds the count's function over the declarations, including the cap and
the effect-time clamp (test-held). That `src/webgpu_compute.nim` runs the count the function returns
is **unenforced** beyond the oracle, the standing condition of the executor. The GPU cost per substep
is **agent-checkable** in-app.

#### Scenario: A long frame substeps

- **WHEN** a frame held at the 0.05 s cap at time scale 5 carries frame factor 30, `ff_stable` is 12,
  and no other count exceeds 3
- **THEN** the frame runs 3 substeps of 10 reference frames each

#### Scenario: A 60 Hz frame with a calm world does not substep

- **WHEN** a frame on a 60 Hz display carries frame factor at most 10, `ff_stable` is 12, and no
  coupling or travel count exceeds 1
- **THEN** the frame runs 1 step

#### Scenario: A stiff fluid substeps without a substep slider

- **WHEN** the fluid's declared count at the live stiffness is 3, `SUBSTEPS_MAX` is at least 3, and every
  other count is lower
- **THEN** the frame runs 3 substeps

#### Scenario: A request past the cap lowers the effect, not the stored value

- **WHEN** a coupling's declared count at its stored value passes `SUBSTEPS_MAX`
- **THEN** the frame runs `SUBSTEPS_MAX` substeps, the coupling runs at the largest value that count
  admits, and the stored value and the slider handle stay where the user set them

### Requirement: No coupling's range reads another coupling's ceiling

A range bound SHALL read another parameter only as a registered derived ceiling
(`parameter-range-authority`, "A bound may derive from other parameters"), and the reading coupling's
declaration SHALL list that parameter. No range constant SHALL be computed from another group's range
ceiling. The body band's floor SHALL be a stated length, not derived from `MAX_VELOCITY_MAX` or any other
range's ceiling; the travel bound holds a particle inside a band at that floor by raising the
substep count.

Enforced by: `tests/test_sim_registry.nim` suite "Bounds Read Only Declared Parameters". For each
registered ceiling, it holds that the ceiling's inputs equal the inputs its coupling's declaration
lists (test-held). That no range constant reads another group's ceiling is **unenforced**. A lint
over `src/config_ranges.nim` and the `*_core.nim` modules, rejecting a `*_MIN`, `*_MAX` or `*_FLOOR`
whose expression names another group's `*_MAX`, would close it.

#### Scenario: Raising the velocity ceiling leaves Body Reach alone

- **WHEN** `MAX_VELOCITY_MAX` rises
- **THEN** the body band's floor is unchanged, and the substep count rises where a particle at the
  live Max Velocity would pass `T`

### Requirement: Every coupling's cost is declared and measured

Each declaration SHALL state the coupling's GPU cost: its passes, whether each scales per particle,
per field cell or per mesh cell, and whether the coupling can raise the crowd density the neighbour
sweep iterates over. Every coupling's writing pass and the neighbour sweep SHALL each have its own
profiler slot, the long-range force and the field force included; passes of one pipeline share its
slot. Coupled time, the `coupled=` figure, is the `physics=` figure (the neighbour sweep plus integrate)
plus every coupling's slot. Long Range SHALL record the coupled time measured at `MAX_PARTICLES` at
strength 1, in the four corners of Long Range × Force Strength, one run each. The coupled time of the
other couplings that can raise the crowd density, scent and bodies, is declared and **unmeasured**.

Enforced by: `tests/test_sim_registry.nim` holds that every velocity-delta and field writer's pipeline
key maps to a profiler slot no other pipeline shares (test-held). The recorded Long Range cost is
**agent-checkable** in-app. An agent sets Long Range to 1 at 128 000 particles in each corner and reads
`coupled=` from the `[gpu-profile]` lines against the pair pass's allotment.

#### Scenario: A writer with no profiler slot

- **WHEN** a velocity-delta writer's pipeline key maps to no profiler slot, or shares one with another
  pass
- **THEN** the registry suite fails and names the key

#### Scenario: Long range with pressure on stays inside the allotment

- **WHEN** Long Range runs at 1 over 128 000 particles at each Force Strength corner
- **THEN** the measured coupled time stays under the pair pass's allotment in every corner

### Requirement: A coupling's controls dim with its strength

Each declaration SHALL name one dimming predicate that is true exactly when its strength is 0. Every
slider that shapes only that coupling SHALL cite that predicate. A slider that shapes more than one
coupling SHALL NOT dim unless all of them are at 0.

Enforced by: `tests/test_dormancy.nim` holds that each declaration's predicate is registered, reads
only that coupling's strength, and is cited by every descriptor the declaration lists as its own
(test-held).

#### Scenario: A fluid-only slider dims with the fluid

- **WHEN** Fluid Strength is 0
- **THEN** every slider the fluid's declaration lists as its own reads dormant, and Interaction Radius
  does not

### Requirement: Every size names its space

Each coupling's declaration SHALL name the space of every length it owns:
- world units: Interaction Radius, Body Reach and the long-range reach
- field cells: the field pattern and the deposit splat
- screen pixels: Particle Size and the glow halo

A size SHALL NOT be converted between spaces except at one declared site per pair of spaces. Particle
and halo sizes SHALL stay in screen pixels.

Enforced by: `tests/test_sim_registry.nim` holds that every length-valued descriptor a declaration
lists carries exactly one space (test-held). That shaders convert only at the declared sites is
**unenforced**, closed by a grep gate over `web/shaders/src/` for the conversion factors.

#### Scenario: A length without a space

- **WHEN** a length-valued descriptor is added to a coupling without naming its space
- **THEN** the registry suite fails and names the descriptor

### Requirement: Couplings are compared on one scale

The response probe for each coupling strength SHALL report an impulse in `u0` at one shared reference
configuration. A native suite SHALL check each probe against a one-frame stepped measurement of that
coupling in the binned oracle world. The suite SHALL report, for each coupling at strength 1, the
relative density at which the world pressure's capacity meets that coupling's demand. It SHALL assert
no bound on that density: under the relative ceiling, no absolute density exists to hold it under.

Enforced by: `tests/test_response_probe.nim` suite "Couplings Are Compared On One Scale", which checks
each probe's impulse against the stepped measurement (test-held). The per-slider sweep at calibrated
thresholds is unchanged (test-held).

#### Scenario: A probe drifts from what a step hands a particle

- **WHEN** a probe reports an impulse that one stepped frame of its coupling does not hand a probe
  particle at the same configuration
- **THEN** the cross-coupling suite fails and names the coupling

### Requirement: The long-range pull is measured in the pair unit and not in mesh cells

The long-range impulse on a particle SHALL be the product of:
- the strength and the coupling's gain
- the attraction-matrix entry
- the unit `U(R) = u0 · R² · (a + R) / a²`
- the gradient of the population's number density convolved with the screened 2D Green's function

`R` is the live interaction radius, and `a = √(A_world / (π · x_on))` is the reference colony's
radius. The mesh's cell area SHALL NOT appear in the impulse. The impulse at a point a few cell widths
or more from a clump's centre SHALL therefore be the same on every declared grid size. The kernel's
shape, its zero at `k = 0`, the unit-charge deposit and the accumulator's fixed point SHALL stay as
`long-range-coupling` states them. The long-range full effect `F_LR` SHALL be the pull that
`MAX_PARTICLES`, gathered into one disc at the onset density, exerts on a particle one interaction
radius past the disc's edge. The requirement is that this pull equals the pair force's peak edge
impulse at that density, computed in `src/balance_core.nim` and recorded beside the gain.

Enforced by: `tests/test_long_range_core.nim` suite "The Pull Does Not Depend On Mesh Size". It solves
one clump on every size in `LR_GRID_SIZES`. It compares the impulse sampled 240 and 600 world units
from the clump's centre, within the mesh-to-mesh gap the static solve measures under the unit
(test-held). Suite "The Pull Is The Pair Unit Spread By The Green's Function" runs at reach
`LONG_RANGE_REACH_MAX`. It compares the impulse sampled 240 from a clump's centre against
`gain · A · U(R) · M / (2π r)` at radii 10, 50 and 150 (test-held). The full effect's derivation is
held by a static assertion in `src/config_ranges.nim` (build-asserted). That `lr-force.wgsl` applies
the same factor is **unenforced**, closed by the factor reaching the shader as one value the oracle
computes.

#### Scenario: Changing the mesh size does not change the pull

- **WHEN** the same population is solved on 256 × 128 and on 512 × 256 at one strength and reach
- **THEN** the impulse sampled 240 world units from the clump's centre agrees between the two sizes
  within the recorded mesh-to-mesh tolerance

### Requirement: A saved world converts to the contract, then the clamp decides

A preset written under a schema version before the contract SHALL decode each coupling strength as
its saved value times the old effective gain, over the new gain. The clamp to 0–1 SHALL apply after
that conversion. The old effective gain for long range SHALL include the saved mesh's cell area and
`U` at the saved interaction radius. Scent-following SHALL convert from its field-force scale.
Force-weather waypoints SHALL be stated in the new Force Strength scale. A saved strength of zero SHALL
decode to zero. The saved substep count, colormap index and field opacity SHALL be dropped without
error. Control rows that map a source to a strength in travel units SHALL carry over unchanged.

Enforced by: `tests/test_preset.nim` suite for the version branch. It decodes a previous-version preset
at each declared grid size and two interaction radii. It compares every decoded strength with its
converted value, clamped (test-held). A static assertion in `src/config_ranges.nim` holds every
force-weather waypoint inside the new range (build-asserted).

#### Scenario: An old Force Strength loads

- **WHEN** a previous-version preset carrying Force Strength 2.5 is applied
- **THEN** the decoded Force Strength is 2.5 times the old pair gain over the new one, clamped to 0–1

#### Scenario: A preset without a coupling loads unchanged

- **WHEN** a previous-version preset with a coupling strength of zero is applied
- **THEN** that strength decodes to exactly zero

#### Scenario: A preset carrying removed fields loads

- **WHEN** a previous-version preset carries a substep count, a colormap index and a field opacity
- **THEN** it applies without error and none of the three reaches the world
