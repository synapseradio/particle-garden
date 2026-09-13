## Purpose

Owns the balance between the pair force and every force that compresses the world from outside it:
the one impulse unit every coupling is stated in, the long-range potential's unit, the pressure a
crowd builds past an onset measured in the world's own mean crowd density, the accumulator that
pressure writes, and the relations that keep a compressed crowd finite, local and able to relax.

## ADDED Requirements

### Requirement: Every coupling states its impulse in one unit

Every force that writes the shared velocity delta SHALL have a pure function in
`src/balance_core.nim` that returns its largest per-particle inward impulse at a stated
configuration, in multiples of `u0`. `u0` is the velocity one touching neighbour's repulsion hands a
particle at force strength 1 over one reference frame, which is `FRAME_DT_REFERENCE`
(`src/physics_core.nim:23`). The functions cover the pair force, the long-range coupling, the bodies
coupling, the field force and the mouse. Each names the shader it mirrors under the reference-oracle
rule (`docs/enforcement.md`, Reference oracles). No demand function SHALL feed the pressure's
stiffness.

Enforced by: `tests/test_balance_core.nim` suite "Every Compressor Answers In The Pair Unit", which
checks each demand function against a direct evaluation of its own oracle (`physics_core`,
`long_range_core`, `body_core`, `field_core`) at the same configuration (test-held). That each
shader carries the expression its oracle holds is **unenforced**, the standing condition of every
reference oracle.

#### Scenario: One touching neighbour is one unit

- **WHEN** the pair demand is evaluated for one neighbour at contact, at force strength 1, over the
  reference frame
- **THEN** it returns exactly 1

#### Scenario: A demand agrees with its own oracle

- **WHEN** a compressor's demand function and a direct evaluation of its oracle are taken at the same
  configuration
- **THEN** they agree to within the oracle's floating-point tolerance

### Requirement: The long-range pull is measured in the pair unit and not in mesh cells

The long-range impulse on a particle SHALL equal the strength, times the attraction-matrix entry,
times `u0`, times the interaction radius, times the gradient of the population's number density
convolved with the screened 2D Green's function. The mesh's cell area SHALL NOT appear in it, so the
impulse at a point a few cell widths or more from a clump's centre is the same on every declared grid
size. The kernel's shape, its zero at `k = 0`, the unit-charge deposit and the accumulator's fixed
point SHALL stay as `long-range-coupling` states them.

Enforced by: `tests/test_long_range_core.nim` suite "The Pull Does Not Depend On Mesh Size", which
solves one clump on every size in `LR_GRID_SIZES` and compares the sampled impulse 240 and 600 world
units from the clump's centre (test-held); suite "The Pull Is The Pair Unit Spread By The Green's
Function", which at reach `LONG_RANGE_REACH_MAX` compares the impulse sampled 240 from a clump's
centre against `strength · A · u0 · R · M / (2π r)` (test-held). Both use the tolerance recorded
beside the tests from the static solve's measured gap. That `lr-force.wgsl` and the `LR_FORCE_SCALE`
write in `src/webgpu_compute.nim` apply the same factor is **unenforced**, closed by the scale
reaching the shader as one value computed by the oracle.

#### Scenario: Changing the mesh size does not change the pull

- **WHEN** the same population is solved on 256 × 128 and on 512 × 256 at one strength and reach
- **THEN** the impulse sampled 240 world units from the clump's centre agrees between the two sizes
  within the recorded tolerance

#### Scenario: The pull at long reach is the unscreened formula

- **WHEN** a clump of `M` particles is solved at reach `LONG_RANGE_REACH_MAX`
- **THEN** the impulse 240 from its centre equals `strength · A · u0 · R · M / (2π · 240)` within the
  recorded tolerance

### Requirement: A crowd denser than the onset pushes itself apart

Inside the neighbour sweep, every pair SHALL receive an equal and opposite repulsive impulse along its
separation. Its magnitude SHALL be the stiffness `K`, times the sum of both particles' pressures, times
the pair's proximity weight `1 − r/R`, times the frame's dt, quantized once to one signed integer that
is added to one particle and subtracted from the other. A particle's pressure SHALL be
`(max(x − x_on, 0) / x_on)²`, where `x` is its smoothed crowd density over the live world's uniform
crowd density `N · π · R² / (3 · A)`, and `x_on` is the onset. The term SHALL read the crowd density
both particles already carry and add no pass. It SHALL NOT be scaled by the force strength, the
attraction matrix, the crowding attenuation or the friction, and SHALL NOT read any coupling's
strength. It SHALL
have no slider. The force law's own expression and grouping SHALL be unchanged.

Enforced by: `tests/test_physics.nim` suite "Pressure Past The Onset", over the oracle
`pressurePairImpulse` in `src/physics_core.nim`: zero at and below the onset, strictly increasing
above it, equal and opposite as one integer, unchanged by force strength, matrix entry and crowding
(test-held). Suite "The Force Law Is Untouched Below The Onset": at force strengths 0.7, 1 and
`FORCE_STRENGTH_MAX`, a settled world below the onset writes a bit-identical velocity delta with and
without the term (test-held on the native oracle). `tests/test_sim_registry.nim` holds that no
coupling-owned key and no new pipeline key appears (test-held). That `forces.wgsl` carries the
oracle's expression is **unenforced**, the standing condition of `physics_core`'s mirror; GPU bit
identity is **unenforced** because the shader compiler may regroup under relaxed math.

#### Scenario: A world below the onset keeps its force law exactly

- **WHEN** both particles of a pair sit at or below the onset, at any force strength
- **THEN** the pair's velocity delta on the native oracle is bit-for-bit the delta the force law
  without the term produces

#### Scenario: Pressure acts with the species force switched off

- **WHEN** force strength is zero and a crowd sits above the onset
- **THEN** the crowd receives the pressure impulse, and particles below the onset pass through each
  other as they did before

#### Scenario: Momentum is conserved exactly by the term

- **WHEN** the pressure integers of every pair in a sweep are summed
- **THEN** the sum is exactly zero

#### Scenario: A dense crowd at friction 0 shimmers and does not collapse

- **WHEN** friction is zero and a crowd sits above the onset
- **THEN** the crowd receives the same pressure impulse as at any other friction, and its members keep
  moving below the soft speed cap's threshold rather than collapsing

#### Scenario: The onset follows the world's size

- **WHEN** the particle count or the interaction radius changes and a uniform world settles
- **THEN** the uniform crowd density the term divides by changes with `N · R²`, and the uniform world
  stays below the onset

### Requirement: The onset and the stiffness are derived and fixed

`src/config_ranges.nim` SHALL hold the onset `x_on` and the stiffness `K`, each with its derivation
beside it under the measured-bound rule, and neither SHALL change with any coupling's live value:

- `x_on` SHALL lie above the highest settled crowd density, in units of the uniform crowd density,
  that worlds of mixed matrices reach with no coupling acting, measured on the native binned oracle
  on a recorded set of calibration seeds at two particle counts and two interaction radii.
- `K` SHALL be the largest stiffness at which worlds on the calibration seeds, at `FRICTION_MIN` and
  at the shipped friction, still settle as they do without the term: the ratio of a late window's
  mean speed to an earlier window's lies within the spread of that ratio without the term.
- The uniform crowd density SHALL be computed each frame by a pure function in `src/balance_core.nim`
  from the live particle count, interaction radius and world area, and written as one uniform.

Enforced by: `tests/test_balance_core.nim` suite "A Settling World Still Settles", which on a
disjoint recorded set of held-out seeds, self-attracting worlds included, holds that speed ratio
within its no-term spread at `FRICTION_MIN` and at the shipped friction (test-held). That the frame
writes the uniform crowd density function's value is **unenforced**, closed by a
`tests/test_sim_registry.nim` check on the uniform's producer.

#### Scenario: A body appears and distant crowds keep their motion

- **WHEN** bodies' envelopes rise from zero to one at their ceilings in a two-frame attack
- **THEN** crowds beyond the bodies' reach keep their mean speed within the spread of a run with no
  body

#### Scenario: A stiffness above the derivation is caught

- **WHEN** `K` is raised to a value at which the calibration seeds' speed ratio leaves its no-term
  spread
- **THEN** the held-out seeds' speed ratio leaves it too and the suite fails

### Requirement: Every velocity impulse accumulates per reference frame and fits a full crowd

Every shader that writes the shared velocity delta SHALL accumulate its impulse per reference frame,
not multiplied by the substep, and integrate SHALL multiply the decoded delta by the frame factor
once. The sum of every writer's largest per-particle impulse per reference frame, each bounded by a
full crowd of `MAX_PARTICLES`, times the velocity scale, SHALL fit a signed 32-bit word. No user range
SHALL be narrowed to satisfy it.

Enforced by: a static assertion at the bottom of `src/config_ranges.nim` summing every writer's
per-particle maximum (build-asserted); `tests/test_physics.nim` suite "A Full Crowd Decodes To Its
Impulse", which encodes a full crowd at contact at `FORCE_STRENGTH_MAX` and frame factor 30 through
the writer oracle and decodes it through the integrate oracle (test-held). That each of the six
shaders carries the convention is **unenforced**, the standing condition of the mirror.

#### Scenario: A full crowd on the largest substep keeps its impulse

- **WHEN** `MAX_PARTICLES` neighbours at contact act on one particle at `FORCE_STRENGTH_MAX` on a
  0.25 s substep
- **THEN** the decoded velocity delta equals the float impulse within one quantum times the frame
  factor, with its sign

#### Scenario: A budget outgrows the velocity word

- **WHEN** `MAX_PARTICLES`, `FORCE_STRENGTH_MAX` or any writer's per-particle maximum rises past the
  word's span
- **THEN** the build fails at the assertion, and the remedy is the word's scale, width or
  accumulation, never a user range

### Requirement: The pressure's accumulator holds a full crowd

The pressure SHALL accumulate per reference frame into its own fixed-point word with its own scale.
The largest per-pair integer, times `MAX_PARTICLES`, SHALL fit a signed 32-bit word. The scale SHALL
be the coarsest at which the calibration seeds keep the stiffness criterion and the relaxation of a
compressed crowd, and the per-pair saturation the largest the word then admits.

Enforced by: a static assertion at the bottom of `src/config_ranges.nim` holding
`q_max · MAX_PARTICLES · scale < 2^31 − 1` (build-asserted). That `forces.wgsl` saturates each pair at
`q_max` is **unenforced**, the standing condition of the mirror.

#### Scenario: A budget grows past what the word holds

- **WHEN** `MAX_PARTICLES`, the scale or the per-pair saturation rises so the full-crowd sum passes the
  word's span
- **THEN** the build fails at the assertion, and the remedy is the word's scale or width, never a
  user range

### Requirement: A compressed crowd stays finite and local

With every compressor at the maximum of its ranges, the bodies stacked up to `MAX_BODIES` aligned
shells at the bound `parametric-bodies` states, a held crowd's density SHALL stay finite, and crowds
beyond every compressor's reach SHALL keep the motion they have with no compressor acting. A held
crowd MAY compress past the onset while held and MAY cost the pair pass more while held. No absolute
crowd-density or cost ceiling SHALL be imposed: the ceiling is relative to the world's own mean crowd
density, so every configuration keeps its own settled look and a dense configuration costs what its
settle costs. The pair pass's allotment SHALL gate the settled shipped world at `MAX_PARTICLES`, not
held or dense configurations.

Enforced by: `tests/test_balance_core.nim` suite "A Compressed Crowd Stays Finite And Local", a
stepped binned oracle world at `MAX_PARTICLES` on the held-out seeds, including one self-attracting
species, with a negative control at stiffness zero whose held crowd collapses (test-held).

#### Scenario: Every body stacked at its ceiling holds a crowd without collapsing it

- **WHEN** `MAX_BODIES` bodies with aligned shells at their ceilings act on a settled world for 300
  frames
- **THEN** the busiest particle's crowd density stays finite and below the stiffness-zero control's

#### Scenario: The control collapses

- **WHEN** the same run uses stiffness zero
- **THEN** the busiest particle's crowd density exceeds every value the pressured run reached, which
  proves the suite can see a collapse

#### Scenario: A dense configuration keeps its settle

- **WHEN** a world at `MAX_PARTICLES` and the largest interaction radius settles with no coupling
  acting
- **THEN** no pressure term pushes it apart from its uniform settle, whatever its absolute crowd
  density

#### Scenario: A hold does not heat the far world

- **WHEN** the stacked bodies hold
- **THEN** the mean speed of particles beyond the bodies' reach stays within the spread of a run with
  no body

### Requirement: A compressed crowd relaxes when the compressor goes

A crowd compressed by any compressor SHALL, once that compressor stops acting, return within 900
frames to the neighbourhood a fresh settle of the same world reaches, including a world of one
self-attracting species at the matrix maximum.

Enforced by: `tests/test_balance_core.nim` suite "Compression Is Not Remembered", comparing the mean
neighbour count 900 frames after the stacked bodies at their ceilings are removed against fresh
settles of the same held-out seeds at the same frame count, within the spread of those fresh settles
(test-held).

#### Scenario: A self-attracting clump spreads back

- **WHEN** a one-species world at the matrix maximum is compressed by the stacked bodies at their
  ceilings and the bodies are removed
- **THEN** its mean neighbour count 900 frames later lies within the spread of its fresh settles

### Requirement: Couplings are compared on one scale

The response probes for coupling strengths that write the velocity delta SHALL report an impulse in
`u0` at one shared reference configuration, and a native suite SHALL check each probe against its
compressor's demand function. The suite SHALL report, for each compressor at its range maximum, the
relative density at which the pressure's capacity meets its demand, and SHALL assert no bound on it:
under the relative ceiling no absolute density exists to hold it under.
`LONG_RANGE_STRENGTH_MAX` SHALL be the strength at which `MAX_PARTICLES` gathered into one disc at the
onset density pull a particle one interaction radius past the disc's edge as hard as the pair force's
peak edge impulse at that density, computed in `src/balance_core.nim` and recorded beside the
constant.

Enforced by: `tests/test_response_probe.nim` suite "Couplings Are Compared On One Scale", which checks
each probe's impulse against its demand function evaluated directly (test-held); the per-slider sweep
at calibrated thresholds, unchanged (test-held); the long-range ceiling's derivation by a static
assertion in `src/config_ranges.nim` (build-asserted). Whether a population visibly gathers within a
few seconds at that ceiling is **agent-checkable**: an agent raises Long Range to its maximum over a
settled world at 128 000 particles and watches distant groups draw together.

#### Scenario: A demand function drifts from its oracle

- **WHEN** a compressor's demand function returns a value its oracle does not produce at the same
  configuration
- **THEN** the cross-coupling suite fails and names the coupling

### Requirement: A saved long-range world converts, then the clamp decides

A preset written under a schema version before the unit change SHALL decode with its long-range
strength multiplied by the saved mesh's cell area over `u0` times the saved interaction radius, and
the descriptor clamp SHALL then apply. A preset with a long-range strength of zero SHALL decode to
zero.

Enforced by: `tests/test_preset.nim` suite for the version branch, which decodes a previous-version
preset at each declared grid size and two interaction radii and compares the decoded strength with
the converted value clamped to the range (test-held); the clamp in `validateSettings` (test-held).

#### Scenario: An old long-range preset loads

- **WHEN** a preset of the previous schema version carrying long-range strength 0.001, the 512 × 256
  mesh and interaction radius 50 is applied
- **THEN** the decoded strength is 0.001 times the 512 × 256 cell area over `u0 · 50`, clamped to the
  strength's range

#### Scenario: A preset without the coupling loads unchanged

- **WHEN** a previous-version preset with long-range strength zero is applied
- **THEN** the decoded strength is exactly zero
