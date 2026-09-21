## Purpose

Owns the world's resistance to compression, a pressure no coupling strength scales. It covers the
onset measured in the world's own mean crowd density, the fixed stiffness, the locality and bound of
a compressed crowd, and its relaxation once the compressor goes.

## ADDED Requirements

### Requirement: A crowd denser than the onset pushes itself apart

Inside the neighbour sweep, every pair SHALL receive an equal and opposite repulsive impulse along its
separation, per reference frame. Its magnitude SHALL be the stiffness `K`, times the sum of both
particles' pressures, times the pair's proximity weight `1 − r/R`, over 120. That magnitude SHALL
saturate at the per-pair maximum `q_max`. The saturated magnitude times the unit separation SHALL be
quantized once to one signed integer per component, added to one particle and subtracted from the
other. The term SHALL carry no viscosity.

A particle's pressure SHALL be `(max(ρ − ρ_on, 0) / ρ_on)²`, where `ρ` is its smoothed crowd density.
The onset `ρ_on` SHALL be the larger of two densities:
- `x_on` times the live world's uniform crowd density `N · π · R² / (3 · A)`
- the discrete-contact floor

The term SHALL read the crowd density both particles already carry, SHALL NOT read their velocities,
and SHALL add no pass. It SHALL NOT be scaled by Force Strength, the attraction matrix, the crowding
attenuation, the friction, or any coupling's strength. It SHALL have no slider. The species term's own
expression and grouping SHALL be unchanged.

Enforced by: `tests/test_physics.nim` suite "Pressure Past The Onset", over the pressure oracle in
`src/physics_core.nim`, which holds (test-held):
- the float magnitude is zero at and below the onset, strictly increasing above it up to `q_max`, and
  constant past it
- each per-component integer is zero at and below the onset and non-decreasing in magnitude with
  density
- the two particles' integers are exactly opposite
- the term is unchanged by Force Strength, the matrix entry, crowding, friction and the pair's
  relative velocity

Suite "The Species Term Is Untouched Below The Onset" runs at Force Strengths 0.2, 0.5 and 1 at frame
factor 1. There, a settled world below the onset writes a bit-identical velocity delta with and
without the term (test-held on the native oracle). That `forces.wgsl` carries the oracle's expression
is **unenforced**, the standing condition of `physics_core`'s mirror. GPU bit identity is
**unenforced**, because the shader compiler may regroup under relaxed math.

#### Scenario: A world below the onset keeps its species term exactly at frame factor 1

- **WHEN** both particles of a pair sit at or below the onset, at any Force Strength, at frame factor 1
- **THEN** the pair's velocity delta on the native oracle is bit-for-bit the delta the species term
  alone produces

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

#### Scenario: The onset follows the world's size and keeps a contact floor

- **WHEN** the particle count or the interaction radius changes and a world settles
- **THEN** the onset is the larger of `x_on` times the uniform crowd density and the crowd density of
  a hexagonal lattice at the pair law's rest spacing, so a single contact in a sparse world does not
  pass it

### Requirement: The onset and the stiffness are derived and fixed

`src/config_ranges.nim` SHALL hold the onset ratio `x_on` and the stiffness `K`, each with its
derivation beside it under the measured-bound rule. Neither SHALL change with any live value.
- `x_on` SHALL sit at the bottom of the band of settled crowd densities that self-attracting worlds
  reach with no coupling but the species force acting, in units of the uniform crowd density. The band
  SHALL be measured past the floor on the native binned oracle, on the gate seeds 42, 7 and 1001, at `MAX_PARTICLES`
  and radius 50 with one and four species under the polynomial force model. The record beside `x_on`
  SHALL name those conditions and state that other particle counts, radii, species counts and the
  exponential model are unmeasured. The densest particles of dense mixed-matrix settles MAY lie above
  it and be trimmed.
- The floor SHALL be the crowd density of a hexagonal lattice at the pair law's rest spacing for an
  attracting pair at `MATRIX_MAX_VALUE`. A pure function in `src/balance_core.nim` SHALL compute it from
  the live pair-law shape.
- `K` SHALL be 540, the stiffness the user chose from the 128 000-particle trade, confirmed on the
  gate seeds. Beside it SHALL stand the friction-0 bound `B_L`. `L` is the late-window mean speed at
  `FRICTION_MIN` with the term, over the same seed's without it. `B_L` is the mean of `L` over the gate
  seeds at 128 000 particles, plus the largest single seed's distance from that mean. A
  self-attracting world at friction 0 MAY settle warmer than without the term, up to `B_L`, an
  accepted cost.
- Pure functions in `src/balance_core.nim` SHALL compute the uniform crowd density and the floor each
  frame, and the frame SHALL write their maximum as one uniform. `x_on` does not cross to the shader:
  `max(x_on · ρ̄, ρ_floor)` is the shape the pair law reads an onset in, and one value carries it.

Enforced by: `tests/test_balance_core.nim` suite "A Settling World Still Settles", under the `just
calibrate-balance` recipe. On the gate seeds at 128 000 particles, it holds the mean `L` at most `B_L`
at `FRICTION_MIN` and frame factor 1. The recipe runs with the task that lands the term, and again on
a change to any of:
- `K`
- the pressure law
- the onset
- the fine/coarse word split
- how the crowd-density computation depends on particle count

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
