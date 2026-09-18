## Purpose

Owns the balance between the pair force and every force that compresses the world from outside it:
the one impulse unit every coupling is stated in, the long-range potential's unit, the pressure a
crowd builds past an onset measured in the world's own mean crowd density, the words the velocity
impulses accumulate in, and the relations that keep a compressed crowd local and able to relax.

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
checks the unit on one touching neighbour's repulsion, and for each demand function sweeps its oracle
over a grid of configurations inside the ranges and holds that no swept inward impulse exceeds the
demand and that the demand's own configuration attains it (test-held). That each shader carries the
expression its oracle holds is **unenforced**, the standing condition of every reference oracle.

#### Scenario: One touching neighbour's repulsion is one unit

- **WHEN** one neighbour at contact acts on a particle at force strength 1 over the reference frame
- **THEN** the repulsive impulse is exactly `u0`

#### Scenario: A demand is the largest inward impulse

- **WHEN** a compressor's oracle is swept over a grid of configurations inside its ranges
- **THEN** no swept inward impulse exceeds that compressor's demand function, and the demand's own
  configuration attains it within the oracle's floating-point tolerance

### Requirement: The long-range pull is measured in the pair unit and not in mesh cells

The long-range impulse on a particle SHALL equal the strength, times the attraction-matrix entry,
times the unit `U(R) = u0 · R² · (a + R) / a²`, times the gradient of the population's number density
convolved with the screened 2D Green's function, where `R` is the live interaction radius and
`a = √(A_world / (π · x_on))` the reference colony's radius. The mesh's cell area SHALL NOT appear in it, so the
impulse at a point a few cell widths or more from a clump's centre is the same on every declared grid
size. The kernel's shape, its zero at `k = 0`, the unit-charge deposit and the accumulator's fixed
point SHALL stay as `long-range-coupling` states them.

Enforced by: `tests/test_long_range_core.nim` suite "The Pull Does Not Depend On Mesh Size", which
solves one clump on every size in `LR_GRID_SIZES` and compares the sampled impulse 240 and 600 world
units from the clump's centre within the mesh-to-mesh gap the static solve measures under the new unit
(test-held); suite "The Pull Is The Pair Unit Spread By The Green's Function", which at reach
`LONG_RANGE_REACH_MAX` compares the impulse sampled 240 from a clump's centre against
`strength · A · U(R) · M / (2π r)` at radii 10, 50 and 150 within the formula gap the static solve
measured there (test-held); suite "One Long-Range Ceiling Holds At Every Radius" (test-held). Each tolerance is recorded beside its test. That `lr-force.wgsl` and the
`LR_FORCE_SCALE` write in `src/webgpu_compute.nim` apply the same factor is **unenforced**, closed by
the scale reaching the shader as one value computed by the oracle.

#### Scenario: Changing the mesh size does not change the pull

- **WHEN** the same population is solved on 256 × 128 and on 512 × 256 at one strength and reach
- **THEN** the impulse sampled 240 world units from the clump's centre agrees between the two sizes
  within the recorded mesh-to-mesh tolerance

#### Scenario: The pull at long reach is the unscreened formula

- **WHEN** a clump of `M` particles is solved at reach `LONG_RANGE_REACH_MAX`
- **THEN** the impulse 240 from its centre equals `strength · A · U(R) · M / (2π · 240)` within the
  recorded formula tolerance

### Requirement: A crowd denser than the onset pushes itself apart

Inside the neighbour sweep, every pair SHALL receive an equal and opposite repulsive impulse along its
separation, per reference frame and not multiplied by the substep. Its magnitude SHALL be the stiffness
`K`, times the sum of both particles' pressures, times the pair's proximity weight `1 − r/R`, over 120,
saturated at the per-pair maximum `q_max`; the saturated magnitude times the unit separation SHALL be
quantized once to one signed integer per component, added to one particle and subtracted from the
other. The term SHALL carry no viscosity. A particle's
pressure SHALL be `(max(ρ − ρ_on, 0) / ρ_on)²`, where `ρ` is its smoothed crowd density and the onset
`ρ_on` is the larger of `x_on` times the live world's uniform crowd density `N · π · R² / (3 · A)` and
the discrete-contact floor. The term SHALL read the crowd density both particles already carry, SHALL
NOT read their velocities, and SHALL add no pass. It SHALL NOT be scaled by the force strength, the attraction matrix, the
crowding attenuation or the friction, and SHALL NOT read any coupling's strength. It SHALL have no
slider. The force law's own expression and grouping SHALL be unchanged.

Enforced by: `tests/test_physics.nim` suite "Pressure Past The Onset", over the pressure oracle in
`src/physics_core.nim`: the float magnitude zero at and below the onset, strictly increasing above it
up to `q_max` and constant past it; each per-component integer zero at and below the onset and
non-decreasing in magnitude with density; the two particles' integers exactly opposite; unchanged by
force strength, matrix entry, crowding, friction and the pair's relative velocity (test-held). Suite "The Force Law Is Untouched
Below The Onset": at force strengths 0.7, 1 and `FORCE_STRENGTH_MAX` and frame factor 1, a settled
world below the onset writes a bit-identical velocity delta with and without the term (test-held on
the native oracle). `tests/test_sim_registry.nim` holds that no coupling-owned key and no new pipeline
key appears (test-held). That `forces.wgsl` carries the oracle's expression is **unenforced**, the
standing condition of `physics_core`'s mirror; GPU bit identity is **unenforced** because the shader
compiler may regroup under relaxed math.

#### Scenario: A world below the onset keeps its force law exactly at frame factor 1

- **WHEN** both particles of a pair sit at or below the onset, at any force strength, at frame factor 1
- **THEN** the pair's velocity delta on the native oracle is bit-for-bit the delta the force law
  without the term produces

#### Scenario: A saturated pair keeps its direction

- **WHEN** a pair's pressure magnitude passes `q_max`
- **THEN** its integers are the saturated magnitude times the pair's unit separation, quantized per
  component

#### Scenario: Pressure acts with the species force switched off

- **WHEN** force strength is zero and a crowd sits above the onset
- **THEN** the crowd receives the pressure impulse, and particles below the onset pass through each
  other as they did before

#### Scenario: Momentum is conserved exactly by the term

- **WHEN** the pressure integers of every pair in a sweep are summed per component
- **THEN** each sum is exactly zero

#### Scenario: The onset follows the world's size and keeps a contact floor

- **WHEN** the particle count or the interaction radius changes and a world settles
- **THEN** the onset is the larger of `x_on` times the uniform crowd density and the crowd density of
  a hexagonal lattice at the pair law's rest spacing, so a single contact in a sparse world does not
  pass it

### Requirement: The onset and the stiffness are derived and fixed

`src/config_ranges.nim` SHALL hold the onset ratio `x_on` and the stiffness `K`, each with its
derivation beside it under the measured-bound rule, and neither SHALL change with any coupling's live
value:

- `x_on` SHALL sit at the bottom of the band of settled crowd densities, in units of the uniform
  crowd density, that self-attracting worlds reach with no coupling acting, measured past the floor on
  the native binned oracle on a recorded set of calibration seeds from `PARTICLE_COUNT_MIN` to
  `MAX_PARTICLES` and from `INTERACTION_RADIUS_MIN` to `INTERACTION_RADIUS_MAX`. The densest particles
  of dense mixed-matrix settles MAY lie above it and be trimmed.
- The floor SHALL be the crowd density of a hexagonal lattice at the pair law's rest spacing for an
  attracting pair at `MATRIX_MAX_VALUE`, computed from the live pair-law shape by a pure function in
  `src/balance_core.nim`.
- `K` SHALL be 540, the stiffness the user chose from the 128 000-particle trade (design D13),
  confirmed on the calibration seeds. Beside it SHALL stand the friction-0 bound `B_L`: the mean over
  128 000-particle calibration seeds of L, the late-window mean speed at `FRICTION_MIN` with the term
  over the same seed's without it, plus the margin `t · s · √(1/n_cal + 1/n_held)` at a false-fail rate
  of 5%. A self-attracting world at friction 0 MAY settle warmer than without the term, up to `B_L`
  (about 17% at 128 000 particles, an accepted cost).
- The uniform crowd density and the floor SHALL be computed each frame by pure functions in
  `src/balance_core.nim` and written as uniforms.

Enforced by: `tests/test_balance_core.nim` suite "A Settling World Still Settles", which on 16
held-out seeds at 128 000 particles holds the mean L at most `B_L` at `FRICTION_MIN`, one-sided at a 5%
false-fail rate at frame factor 1 against a `B_L` the same recipe re-derives on the calibration seeds
(held by the `just calibrate-balance-128k` recipe, run by the task that lands the term and on a change to `K`, the pressure law, the onset, the fine/coarse word split, or the crowd-density computation's dependence on particle count,
not by every `just check` or `just calibrate-balance`; that the recipe reruns on such a change is
**unenforced**, the standing condition of the recipe's tier); `K = 1728` turns it red. At frame factor
1 it cannot tell a per-step accumulation from a per-reference-frame one; the frame-factor arms of the
next requirement hold that. That the frame writes the functions' values
is **unenforced**, closed by a `tests/test_sim_registry.nim` check on the uniforms' producer.

#### Scenario: A dense crowd at friction 0 settles no warmer than the accepted bound

- **WHEN** a self-attracting world of 128 000 particles settles above the onset at `FRICTION_MIN` on the
  held-out seeds
- **THEN** its late-window mean speed, over the same seed's without the term, averages at most `B_L`

#### Scenario: A stiffness above the chosen one is caught

- **WHEN** `K` is raised to a value whose 128 000-particle L on the calibration seeds passes `B_L`
- **THEN** the held-out seeds' mean L passes `B_L` and the suite fails

### Requirement: A frame past the stability limit substeps

When a frame's frame factor `ff` exceeds `ff_stable`, the executor SHALL run the whole frame
description `max(fluid substeps, ⌈ff / ff_stable⌉)` times, each substep advancing the frame's time over
that count. `src/config_ranges.nim` SHALL hold `ff_stable` with its conditions beside it: the largest
frame factor, held fixed through a run, at which a dense self-attracting world at the recorded `K` and shipped friction settles
no warmer per reference frame than at frame factor 1, on the calibration seeds, one-sided at a 5%
false-fail rate. The time-scale range SHALL NOT be narrowed to avoid substeps.

Enforced by: `tests/test_balance_core.nim` suite "A Settling World Still Settles", which on the
held-out seeds runs frame factors 2, 10 and 30, a frame factor drawn per frame from 8 to 16, and one
alternating 10 and 13, through the substep rule, and holds each no warmer per
reference frame than frame factor 1 at shipped friction, one-sided at a 5% false-fail rate (held by
the `just calibrate-balance` recipe, not by every `just check`). That `src/webgpu_compute.nim` applies
the rule is **unenforced** beyond the oracle, the standing condition of the executor. The added GPU
cost per substep is **agent-checkable** in-app.

#### Scenario: A long frame at a stiffness past its limit substeps

- **WHEN** a frame held at the 0.05 s cap at time scale 5 carries frame factor 30 and `ff_stable` is 12
- **THEN** the frame runs 3 substeps of 10 reference frames each

#### Scenario: A 60 Hz frame at any time scale does not substep

- **WHEN** a frame on a 60 Hz display carries frame factor at most 10 and `ff_stable` is 12
- **THEN** the frame runs 1 step

#### Scenario: A frame factor that straddles the limit settles no warmer than the shipped frame

- **WHEN** a dense self-attracting world settles with its frame factor drawn each frame from 8 to 16
  under the substep rule and `ff_stable` is 12
- **THEN** its late-window mean speed per reference frame is no warmer than the same world's at frame
  factor 1

#### Scenario: A long frame settles no warmer than the shipped frame

- **WHEN** a dense self-attracting world settles at frame factor 30 under the substep rule
- **THEN** its late-window mean speed per reference frame is no warmer than the same world's at frame
  factor 1

### Requirement: Every velocity impulse accumulates per reference frame in words that fit a full crowd

Every shader that writes the velocity delta SHALL accumulate its impulse per reference frame, not
multiplied by the substep, and integrate SHALL multiply the decoded delta by the frame factor once.
The delta SHALL be held in two signed 32-bit words per particle: a fine word at 2^16 and a coarse word
counting `2^k` fine quanta. A writer whose full crowd does not fit the fine word SHALL split each
integer `q` into `q >> k` for the coarse word and `q & (2^k − 1)` for the fine word, which sum back to
`q` exactly. `k` SHALL be the largest value at which every writer's full-crowd contribution to the fine
word fits, and `q_max` the largest per-pair pressure the coarse word admits after SPH's. No user range
SHALL be narrowed to satisfy either word.

Enforced by: static assertions at the bottom of `src/config_ranges.nim` summing every writer's
per-particle maximum per reference frame into each word, each term naming its constants
(build-asserted); `tests/test_physics.nim` suite "A Full Crowd Decodes To Its Impulse", which for
every writer encodes a full crowd at its maxima through the writer's oracle and decodes it through
the integrate oracle at frame factors 1, 2 and 30 (test-held); suite "Today's Low Bits Move By Less
Than The Frame Factor", which compares each contribution with the today-convention oracle
(test-held). That each of the five shaders carries the convention is **unenforced**, the standing
condition of the mirror.

#### Scenario: A full crowd on the largest substep keeps its impulse

- **WHEN** a full crowd at any writer's maxima acts on one particle on a 0.25 s substep
- **THEN** the decoded velocity delta equals the float impulse within one quantum times the frame
  factor, with its sign

#### Scenario: A delta below the onset moves only in its low bits

- **WHEN** a contribution is written at frame factor `ff` under the per-reference-frame convention
- **THEN** its decoded delta differs from the today-convention delta by less than `max(1, ff)` quanta,
  and by zero at frame factor 1

#### Scenario: A budget outgrows a word

- **WHEN** `MAX_PARTICLES`, `MATRIX_MAX_VALUE`, `MAX_VELOCITY_MAX`, `q_max`, `k` or any writer's
  per-particle maximum rises past its word's span
- **THEN** the build fails at the assertion, and the remedy is the words' scale, width or split, never
  a user range

### Requirement: A compressed crowd stays local and below its collapse

With the bodies stacked up to `MAX_BODIES` aligned shells at the bound `parametric-bodies` states, a
held crowd's density SHALL stay below the density the same hold reaches with no pressure, and crowds
beyond the bodies' reach SHALL keep the motion they have with no body acting. With long range, the
field force and the mouse also at the maxima of their ranges, the same SHOULD hold. A held crowd MAY compress past the onset while held and MAY cost
the pair pass more while held. No absolute crowd-density or cost ceiling SHALL be imposed: the ceiling
is relative to the world's own mean crowd density and the contact floor. The pair pass's allotment
SHALL bound the cost the term adds to a settled world at `MAX_PARTICLES`, drawn from the settled
128 000-particle headroom at the shipped radius, not held or dense configurations.

Enforced by: `tests/test_balance_core.nim` suite "A Compressed Crowd Stays Local And Below Its
Collapse", a stepped binned oracle world at 16 000 particles and radius 50 on 16 held-out seeds,
including one self-attracting species, with a stiffness-zero control bounded to 100 held frames,
one-sided at a 5% false-fail rate (held by the `just calibrate-balance` recipe run at change time).
The oracle world models bodies alone, so the hold with long range, the field force and the mouse at
their maxima as well is **unenforced** by any suite; the 128 000-particle hold with long range at its
maximum is **agent-checkable** in-app.

#### Scenario: Every body stacked at its ceiling holds a crowd below its collapse

- **WHEN** `MAX_BODIES` bodies with aligned shells at their ceilings act on a settled world for 100
  frames
- **THEN** the busiest particle's crowd density stays below the stiffness-zero control's at the same
  held frame

#### Scenario: A dense configuration keeps its settle

- **WHEN** a world at `MAX_PARTICLES` and the largest interaction radius settles with no coupling
  acting
- **THEN** no pressure term pushes it apart from its uniform settle, whatever its absolute crowd
  density

#### Scenario: A hold does not heat the far world

- **WHEN** the stacked bodies hold
- **THEN** the mean speed of particles beyond the bodies' reach exceeds a run with no body by no more
  than the recorded margin

### Requirement: A compressed crowd relaxes when the compressor goes

A world of one self-attracting species at the matrix maximum, compressed by the stacked bodies at
their ceilings, SHALL return within 900 frames of their removal to within the ratio `B` of the
neighbourhood a fresh settle of the same seed reaches. At the chosen stiffness it returns fully at
128 000 particles (design D13). At 16 000 particles `B` is the chosen stiffness's own calibration
ratio there plus its margin; at 128 000 particles `B` is 1 (design D10). Clumps of a mixed-matrix world that a
hold merged below the onset MAY stay merged.

Enforced by: `tests/test_balance_core.nim` suite "Compression Is Not Remembered": per held-out seed,
the weighted neighbour count 900 frames after removal over a fresh settle's at the same frame count;
at 16 000 particles the suite holds the mean ratio at most `B`, derived with its margin, and at
128 000 particles at most `1 + t · s / √n`, each one-sided at a 5% false-fail rate. The 16 000-particle
arm is held by the `just calibrate-balance` recipe run at change time. The 128 000-particle arm is held
by the `just calibrate-balance-128k` recipe, run by the task that lands the term and on a change to `K`, the pressure law, the onset, the fine/coarse word split, or the crowd-density computation's dependence on particle count, not by
every `just check`; that the recipe reruns on such a change is **unenforced**, the standing condition
of the recipe's tier.

#### Scenario: A self-attracting clump spreads back

- **WHEN** a one-species world at the matrix maximum is compressed by the stacked bodies at their
  ceilings and the bodies are removed
- **THEN** its mean after-over-fresh neighbour ratio 900 frames later exceeds `B` by no more than the
  recorded margin

### Requirement: Couplings are compared on one scale

The response probes for coupling strengths that write the velocity delta SHALL report an impulse in
`u0` at one shared reference configuration, and a native suite SHALL check each probe against a
one-frame stepped measurement of that compressor in the binned oracle world. The suite SHALL report,
for each compressor at its range maximum, the relative density at which the pressure's capacity meets
its demand, and SHALL assert no bound on it: under the relative ceiling no absolute density exists to
hold it under. `LONG_RANGE_STRENGTH_MAX` SHALL be the strength at which `MAX_PARTICLES` gathered into
one disc at the onset density pull a particle one interaction radius past the disc's edge as hard as
the pair force's peak edge impulse at that density, computed in `src/balance_core.nim` and recorded
beside the constant. Under `U(R)` that strength is the same at every interaction radius, and at a
fixed strength the pull grows about as the square of the radius.

Enforced by: `tests/test_response_probe.nim` suite "Couplings Are Compared On One Scale", which checks
each probe's impulse against the stepped measurement (test-held); the per-slider sweep at calibrated
thresholds, unchanged (test-held); the long-range ceiling's derivation by a static assertion in
`src/config_ranges.nim` (build-asserted). Whether a population visibly gathers within a few seconds at
that ceiling is **agent-checkable**: an agent raises Long Range to its maximum over a settled world at
128 000 particles and watches distant groups draw together.

#### Scenario: A probe drifts from what a step hands a particle

- **WHEN** a probe reports an impulse that one stepped frame of its compressor does not hand a probe
  particle at the same configuration
- **THEN** the cross-coupling suite fails and names the coupling

### Requirement: A saved long-range world converts, then the clamp decides

A preset written under a schema version before the unit change SHALL decode with its long-range
strength multiplied by the saved mesh's cell area over `U` at the saved interaction radius, and the
descriptor clamp SHALL then apply. A preset with a long-range strength of zero SHALL decode to zero.
The onset ratio the current schema's long-range unit was defined at SHALL equal the live onset
constant.

Enforced by (the onset clause): a static assertion in `src/preset.nim` (build-asserted).

Enforced by: `tests/test_preset.nim` suite for the version branch, which decodes a previous-version
preset at each declared grid size and two interaction radii and compares the decoded strength with
the converted value clamped to the range (test-held); the clamp in `validateSettings` (test-held).

#### Scenario: An old long-range preset loads

- **WHEN** a preset of the previous schema version carrying long-range strength 0.001, the 512 × 256
  mesh and interaction radius 50 is applied
- **THEN** the decoded strength is 0.001 times the 512 × 256 cell area over `U(50)`, clamped to the
  strength's range

#### Scenario: A preset without the coupling loads unchanged

- **WHEN** a previous-version preset with long-range strength zero is applied
- **THEN** the decoded strength is exactly zero
