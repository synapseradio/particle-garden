## Purpose

Owns the world's resistance to compression, a pressure no coupling strength scales. It covers the
onset measured in the world's own mean crowd density, the fixed stiffness, the locality and bound of
a compressed crowd, and its relaxation once the compressor goes.

## ADDED Requirements

### Requirement: A crowd denser than the onset pushes itself apart

Inside the neighbour sweep, every pair SHALL receive an equal and opposite repulsive impulse along its
separation, per reference frame. Its magnitude SHALL be `min(K · (φ_this + φ_other) / 120, q_max) ·
(1 − r/R)`: the stiffness `K` times the sum of both particles' pressures, saturated at the per-pair
maximum `q_max`, times the pair's proximity weight `1 − r/R`. The pair SHALL also add its radial
stiffness, the saturated sum divided by the interaction radius, to both particles' stiffness words. The
saturated magnitude times the unit separation SHALL be quantized once to one signed integer per
component, added to one particle and subtracted from the other. Integrate SHALL scale each particle's
whole decoded delta by its own step limit `s`, a function of the frame factor and its summed stiffness
(`coupling-contract`). The term SHALL carry no viscosity.

A particle's pressure SHALL be `(max(ρ − ρ_on, 0) / ρ_on)²`, where `ρ` is its smoothed crowd density.
The onset `ρ_on` SHALL be the larger of two densities:
- `x_on` times the live world's uniform crowd density `N · π · R² / (3 · A)`
- the discrete-contact floor

The term SHALL read the crowd density both particles already carry, SHALL NOT read their velocities,
and SHALL add no pass. It SHALL NOT be scaled by Force Strength, the attraction matrix, the crowding
attenuation, the friction, or any coupling's strength. It SHALL have no slider. The species term's own
expression and grouping SHALL be unchanged.

Enforced by: `tests/test_physics.nim` suite "Pressure Past The Onset" (T10), over the pressure oracle in
`src/physics_core.nim`, which holds (test-held):
- the float magnitude is zero at and below the onset, strictly increasing above it up to `q_max`, and
  constant past it
- each per-component integer is zero at and below the onset and non-decreasing in magnitude with
  density
- the two particles' integers are exactly opposite
- the term is unchanged by Force Strength, the matrix entry, crowding, friction and the pair's
  relative velocity
- the sum saturates before the proximity weight, so the magnitude is `min(K(φ+φ)/120, q_max) · (1 −
  r/R)` even where `r` sits near `R`

The step limit `s` is enforced by `tests/test_physics.nim` and `tests/test_balance_core.nim` suites T1
"The Step Limit Leaves A Calm Particle Untouched", T2 "A Stiff Particle's Step Stays Inside The Bound",
T3 "A Pair's Stiffness Is Its Radial Slope", T4 "The Stiffness Words Decode To The Summed Slope", T5 "A
Limited Step Cannot Overshoot" and T6 "The Step Limit Scales Every Writer Alike"
(`coupling-contract`).

Suite "The Species Term Is Untouched Below The Onset" runs at Force Strengths 0.2, 0.5 and 1 at frame
factor 1. There, a settled world below the onset writes a bit-identical velocity delta with and
without the term (test-held on the native oracle). That `forces.wgsl` carries the oracle's expression
is **unenforced**, the standing condition of `physics_core`'s mirror. GPU bit identity is
**unenforced**, because the shader compiler may regroup under relaxed math.

#### Scenario: A world below the onset keeps its species term exactly at every frame factor

- **WHEN** both particles of a pair sit at or below the onset, at any Force Strength, at any frame
  factor
- **THEN** the pair's velocity delta on the native oracle is bit-for-bit the delta the species term
  alone produces, because a particle with zero summed stiffness has step limit `s = 1` exactly (T1)

#### Scenario: A saturated pair keeps its direction

- **WHEN** a pair's pressure magnitude passes `q_max`
- **THEN** its integers are the saturated magnitude times the pair's unit separation, quantized per
  component

#### Scenario: Pressure acts with the species force switched off

- **WHEN** Force Strength is 0 and a crowd sits above the onset
- **THEN** the crowd receives the pressure impulse, and particles below the onset pass through each
  other

#### Scenario: Momentum is conserved exactly by the term

- **WHEN** the pressure integers of every pair in a sweep are summed per component
- **THEN** each sum is exactly zero

#### Scenario: A limited particle's writers scale alike

- **WHEN** a particle's summed stiffness gives it step limit `s < 1`, and its decoded delta carries
  species, pressure and body contributions
- **THEN** the decoded delta is `s` times the frame-factor-scaled sum of every contribution, not the
  pressure alone (T6)

#### Scenario: The onset follows the world's size and keeps a contact floor

- **WHEN** the particle count or the interaction radius changes and a world settles
- **THEN** the onset is the larger of `x_on` times the uniform crowd density and the crowd density of
  a hexagonal lattice at the pair law's rest spacing, so a single contact in a sparse world does not
  pass it

### Requirement: The onset and the stiffness are derived and fixed

`src/config_ranges.nim` SHALL hold the onset ratio `x_on` and the stiffness `K`, each with its
derivation beside it under the measured-bound rule. Neither SHALL change with any live value.
- `x_on` SHALL be 6.3, the user's placement, in units of the uniform crowd density. The record beside
  it SHALL name the settles it separates, measured with no coupling but the species force on the
  native binned oracle, on the gate seeds 42, 7 and 1001, at `MAX_PARTICLES` and radius 50 under the
  polynomial force model: it lies below every one-species self-attracting settle and above every
  four-species settle whose species each attract only themselves. The record SHALL state that other
  particle counts, radii, species counts and the exponential model are unmeasured. The densest
  particles of dense mixed-matrix settles MAY lie above it and be trimmed.
- The floor SHALL be the crowd density of a hexagonal lattice at the pair law's rest spacing for an
  attracting pair at `MATRIX_MAX_VALUE`. A pure function in `src/balance_core.nim` SHALL compute it from
  the live pair-law shape.
- `K` SHALL be 540, the stiffness the user chose from the 128 000-particle trade, confirmed on the
  gate seeds under the step limit (`s`, below). Beside it SHALL stand the friction-0 bound `B_L`. `L`
  is the late-window mean speed at `FRICTION_MIN` with the term, over the same seed's without it. `B_L`
  is the mean of `L` over the gate seeds at 128 000 particles, plus the largest single seed's distance
  from that mean, re-derived under the limit. A self-attracting world at friction 0 MAY settle warmer
  than without the term, up to `B_L`, an accepted cost.
- The step limit's bound `θ` (`PRESSURE_STEP_BOUND`) SHALL be 2: half the symplectic bound of 4 at
  retention 1, leaving a factor of 2 for the density lag and the slopes the summed stiffness `D`
  omits.
- Pure functions in `src/balance_core.nim` SHALL compute the uniform crowd density and the floor each
  frame, and the frame SHALL write their maximum as one uniform. `x_on` does not cross to the shader:
  `max(x_on · ρ̄, ρ_floor)` is the shape the pair law reads an onset in, and one value carries it. The
  `x_on` record stands as measured, because G1.1 runs with the pressure off (stiffness 0), so the step
  limit does not enter that measurement.

Enforced by: `tests/test_balance_core.nim` suite "A Settling World Still Settles", under the `just
calibrate-balance` recipe. On the gate seeds at 128 000 particles, it holds the mean `L` at most `B_L`
at `FRICTION_MIN` and frame factor 1. The recipe runs with the task that lands the term, and again on
a change to any of:
- `K`
- the pressure law
- the onset
- the fine/coarse word split
- how the crowd-density computation depends on particle count
- `θ` or the step limit itself

It does not run with every `just check`. That the recipe reruns on such a change is **unenforced**,
the standing condition of the recipe's tier. That the frame writes the
functions' value is **test-held**: `tests/test_sim_registry.nim` suite "The Pressure Onset Comes From
The Density Functions" checks `sim_registry.pressureOnset` against the two `balance_core` functions on
a world where the mean dominates and one where the floor does, and reads `src/webgpu_compute.nim`'s
assignment to the onset slot for a call to that producer.

#### Scenario: A dense crowd at friction 0 settles no warmer than the accepted bound

- **WHEN** a self-attracting world of 128 000 particles settles above the onset at `FRICTION_MIN` on the
  gate seeds
- **THEN** its late-window mean speed, over the same seed's without the term, averages at most `B_L`

#### Scenario: A stiffness above the chosen one is caught

- **WHEN** `K` is raised to 1728
- **THEN** the gate seeds' mean `L` passes `B_L` and the suite fails

  Outcome pending Q1 (crowding-redesign design §11): under the step limit, `K = 1728` may no longer
  exceed the re-derived `B_L`, because the limit caps what extra stiffness can do to the step. Task 4.5
  reruns the trade and returns the table to the user; this scenario's falsifier is then the explicit
  (unlimited) arm at frame factor 2, which reads 3.09× at 128 000
  (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:109`).

### Requirement: The pressure cannot overshoot at any frame factor

For every frame-factor schedule the app produces — sustained, jittered, and held frames past the 0.05 s
cap — a pressure world at 16 000 and 128 000 particles, at `FRICTION_MIN` and shipped friction, SHALL
settle no warmer per reference frame than at frame factor 1, with no more cap contact than a
stiffness-zero control. The step limit (`coupling-contract`) SHALL hold this by construction: `ff ·
λ_max ≤ θ < 4` for every frame factor, radius and particle count, where `λ_max` is a particle's own
pair-Hessian bound, for every restoring mode; and it SHALL never raise a sliding mode's growth per
reference frame above frame factor 1's. No substep count and no recorded stability limit SHALL be
needed for it.

Enforced by: `tests/test_balance_core.nim` suite "Every Frame Factor Settles No Warmer" (G1), under the
`just calibrate-balance` recipe, on 16 000 and 128 000 particles, radius 50 and 150. Four arms hold: A,
sustained schedules at shipped friction; B, sustained schedules at `FRICTION_MIN`, against the
stiffness-zero world's own frame-factor dependence; C, cap contact, no more than the stiffness-zero
world's; D, unsteady schedules (uniform and alternating jitter, and held frames with single ff-30
steps). `tests/test_balance_core.nim` suite "A Limited Step Cannot Overshoot" (T5a–T5d) holds, on the
oracle apart from the recipe: T5a, every restoring mode to `ff · s · λ ≤ θ/2`; T5b, every sliding mode
to the limit's never-amplifies and ff-1 growth clauses; T5c, the coupled Hessian's largest eigenvalue to
`θ` and its most negative mode to T5b's ff-1 clause; T5d, the unlimited control past the restoring bound
at ff 30.

#### Scenario: A sustained frame factor of 30 settles no warmer than frame factor 1

- **WHEN** a self-attracting world at 128 000 particles runs at a fixed frame factor of 30 for 900
  steps
- **THEN** its late-window motion per reference frame is at most that of the same world at frame
  factor 1

#### Scenario: A jittered frame factor settles no warmer than frame factor 1

- **WHEN** the frame factor is drawn per step from 8 to 16, or alternates 10 and 13
- **THEN** the world's late-window motion per reference frame is at most that of frame factor 1

#### Scenario: A held frame past the 0.05 s cap settles no warmer than the shipped schedule

- **WHEN** a world runs frame factor 0.42 with single frame-factor-30 steps at frames 300, 500 and 700
- **THEN** its late-window motion per reference frame is at most that of the fixed 0.42 schedule

### Requirement: A compressed crowd stays local and below its collapse

Under a hold by the bodies stacked up to `MAX_BODIES` aligned shells at the bound `parametric-bodies`
states, two things SHALL hold:
- the held crowd's density stays below the density the same hold reaches with no pressure
- crowds beyond the bodies' reach keep the motion they have with no body acting

The same SHALL hold with long range, scent and the mouse also at strength 1. A held crowd MAY compress
past the onset while held, and MAY cost the neighbour sweep more while held. No absolute
crowd-density or cost ceiling SHALL be imposed: the ceiling is relative to the world's own mean crowd
density and the contact floor. The neighbour sweep's allotment SHALL bound the cost the term adds to
a settled world at `MAX_PARTICLES`. That allotment is drawn from the settled 128 000-particle headroom
at the shipped radius, not from held or dense configurations.

Enforced by: `tests/test_balance_core.nim` suite "A Compressed Crowd Stays Local And Below Its
Collapse" (held by the `just calibrate-balance` recipe, run at change time). It steps a binned oracle
world at 128 000 particles and radius 50 on the gate seeds, against a stiffness-zero control bounded
to 100 held frames, and compares three-seed means. The oracle world models bodies alone. So no suite enforces the hold with long range, scent and the
mouse at strength 1 as well; that hold is **unenforced**. The 128 000-particle hold with long range
at 1 is **agent-checkable** in-app. An agent raises Long Range to 1 over a settled world at 128 000
particles with Force Strength at 0, and reads that the busiest clump stays finite and the frame time
stays under the allotment.

#### Scenario: Every body stacked at its ceiling holds a crowd below its collapse

- **WHEN** `MAX_BODIES` bodies with aligned shells at their ceilings act on a settled world for 100
  frames
- **THEN** the busiest particle's crowd density stays below the stiffness-zero control's at the same
  held frame

#### Scenario: A dense configuration keeps its settle

- **WHEN** a world at `MAX_PARTICLES` and the largest interaction radius settles with no coupling but
  the species force acting
- **THEN** no pressure term pushes it apart from its uniform settle, whatever its absolute crowd
  density

#### Scenario: A hold does not heat the far world

- **WHEN** the stacked bodies hold
- **THEN** the mean speed of particles beyond the bodies' reach exceeds a run with no body by no more
  than the recorded margin

### Requirement: A compressed crowd relaxes when the compressor goes

Take a world of one self-attracting species at the matrix maximum, at 128 000 particles, compressed by
the stacked bodies at their ceilings. Within 900 frames of the bodies' removal, its neighbourhood
SHALL return to at most that of a fresh settle of the same seed: the ratio `B` is 1.

Clumps of a mixed-matrix world that a hold merged below the onset MAY stay merged.

Enforced by: `tests/test_balance_core.nim` suite "Compression Is Not Remembered", under the `just
calibrate-balance` recipe and its rerun conditions above. Per gate seed, it compares the weighted
neighbour count 900 frames after removal with a fresh settle's at the same frame count, and holds the
mean ratio at most 1. That the recipe reruns on such a change is **unenforced**.

#### Scenario: A self-attracting clump spreads back

- **WHEN** a one-species world at the matrix maximum is compressed by the stacked bodies at their
  ceilings, and the bodies are removed
- **THEN** its mean after-over-fresh neighbour ratio 900 frames later is at most 1
