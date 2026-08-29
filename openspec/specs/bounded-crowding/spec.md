# bounded-crowding

## Purpose

Owns the crowding term: the local-density factor that scales species attraction down as a crowd
tightens, the density ceiling that factor implies, and the strength parameter that sets how hard it
bites. One capability because the three are views of a single force-law modification — the ceiling
is derived from the attenuation's own arithmetic, and the strength's range decides which ceilings
are reachable at all.

The force curve the term multiplies, the neighbour sweep it bounds, and the spatial grid that sweep
walks belong to the physics core around it. Ranges, defaults and served bounds belong to
`parameter-range-authority`. The preset schema that carries the strength across a save lives in
`src/preset.nim`. This spec cites those relations and leaves their detail to them.

## Requirements

### Requirement: Local density attenuates attraction

Every attractive force contribution SHALL be scaled by `1 / (1 + strength * log(1 + density))`,
where `density` is the receiving particle's smoothed, species-blind crowd density — a dedicated
channel that counts every neighbour, accumulated beside the same-species colony density
(`web/shaders/src/forces.wgsl`, the `crowdDensityDeltaFixed` atomics in the neighbour loop) and
smoothed onto the particle exactly as the colony channel is (`web/shaders/src/integrate.wgsl`,
`p.crowdDensity`) — and `strength` is the crowding strength parameter. The colony channel stays
same-species and feeds the renderer; the two signals are not interchangeable.

The term applies to attractive contributions only, in both force models: the polynomial attraction
envelope (`polynomialForce`, `src/physics_core.nim:398-421`) and the exponential attraction term
(`exponentialForce`, `src/physics_core.nim:423-431`, mirroring the same-named function in
`web/shaders/src/forces.wgsl`). Repulsive contributions are untouched at every density — the
short-range zone, and attraction-zone contributions whose matrix entry is negative. Attenuating a
repulsive term would partly cancel the cap it exists to serve.

The oracle for the term lives in `src/physics_core.nim` (`crowdingAttenuation` and
`calculateAttenuatedForce`, `:68-107`) and the WGSL mirrors it. The properties below are native
tests in `tests/test_physics.nim`, suite "Crowding Attenuation" (`:96-170`).

#### Scenario: An isolated particle feels the unattenuated force

- **WHEN** a particle's local density is zero
- **THEN** its forces are identical to the unattenuated force at every crowding strength, because
  `log(1 + 0) = 0`

#### Scenario: Strength zero is exactly the unattenuated force law

- **WHEN** crowding strength is zero
- **THEN** every force at every density equals the unattenuated oracle, so any regression is
  bisectable to one number

#### Scenario: A schema-version-1 preset keeps the unattenuated force law

- **WHEN** a preset written under schema version 1 is applied
- **THEN** its crowding strength decodes to exactly zero through the v1 branch of the versioned
  decode (`src/preset.nim:632-638`), never to the shipped default, so no saved world gains a term
  it was not saved with (`tests/test_preset.nim:459-470`)

#### Scenario: Crowding is never rewarded

- **WHEN** density rises with everything else held fixed
- **THEN** attenuated attraction never rises

#### Scenario: Repulsion survives the crowd

- **WHEN** a pair sits in the repulsion zone, or its matrix entry is negative, at any density
- **THEN** the force contribution is unattenuated

#### Scenario: The term commutes with force strength

- **WHEN** the attenuated attraction is evaluated at force strength `k`
- **THEN** it equals `k` times the attenuated attraction at force strength 1 — the attenuation is a
  fraction of whatever attraction survives `fMul` (`src/physics_core.nim:39-65`), never an absolute
  force, so its meaning does not drift across the force-strength range

### Requirement: A density ceiling exists and is computed

`src/physics_core.nim` SHALL provide a companion function returning the density at which attenuated
attraction no longer exceeds repulsion at the equilibrium separation — the density past which a
cluster cannot tighten further (`densityCeiling`, `:197-224`, over `crowdingBalance` and
`packingSeparation`, `:177-195`). A native test in `tests/test_physics.nim` SHALL assert that this
ceiling is finite for every reachable combination of matrix value, force strength, and non-zero
crowding strength, and that it decreases monotonically in crowding strength (suite "The Density
Ceiling", `:192-243`). The sweep reads its bounds from the range-authority constants
(`FORCE_STRENGTH_MIN/MAX` at `src/config_ranges.nim:35,41`, `MATRIX_MIN_VALUE/MAX_VALUE` at `:63-64`,
and `CROWDING_STRENGTH_MIN/MAX` at `:42,46`) instead of restating them, so a later range
recalibration re-scopes the sweep with no second edit. `FORCE_STRENGTH_MIN` is zero, which puts
force strength zero inside the swept range; at that endpoint no attraction remains to attenuate, so
the cap is vacuous. The sweep SHALL include the point and assert the ceiling degenerates there.

The scope of the claim MUST be stated where the ceiling is defined, so it cannot be over-read
(`src/physics_core.nim:110-144`):

- The ceiling is an equilibrium property. Momentum can overshoot it transiently; it is not a
  per-frame invariant.
- The density signal is species-blind: the crowd channel counts every neighbour, so the per-cell
  occupancy bound carries no species factor, and a mixed-species blob attenuates exactly as a
  single-species blob of the same total density does.
- The ceiling bounds what species attraction can concentrate. Forces the term does not scale — the
  mouse attract, the blast, positive field tropism — can concentrate beyond it; the tropism side is
  separately bounded by the measured deposit-tropism product (`tests/test_field_core.nim`, suite
  "Chemotactic Collapse Bound", `:975-1176`).
- The ceiling bounds a cell, not a region. A region holds many cells, so global clumping stays
  reachable.

Within that scope, a finite ceiling bounds per-cell occupancy up to geometric constants, because
grid cells are sized to the interaction radius (`src/grid.nim`) and the density weight spans that
same radius — which is what puts a ceiling on the per-particle neighbour sweep cost instead of
merely lowering its average.

#### Scenario: The ceiling is finite everywhere reachable

- **WHEN** the native sweep evaluates the ceiling across every reachable combination of matrix
  value, force strength, and non-zero crowding strength
- **THEN** every ceiling is finite

#### Scenario: More crowding strength, lower ceiling

- **WHEN** crowding strength rises with attraction held fixed
- **THEN** the computed ceiling falls

### Requirement: Crowding ships off, and its ceiling is a working bound

The shipped crowding strength default SHALL be `0.0` (`src/ui/state/simulation_state.nim:91-93`,
mirrored in `src/preset.nim:217-220`), so a fresh world runs the force law that every other default
was chosen against. `CROWDING_STRENGTH_MIN` SHALL be exactly zero, so that force law stays reachable
from the slider (`src/config_ranges.nim:42-45`, static assertion at `:436-437`).

`CROWDING_STRENGTH_MAX = 2.0` is a working bound, and states so beside itself
(`src/config_ranges.nim:46-54`). The measurement that would replace it finds the strength at which a
collapsing single-species world stops tightening and the strength at which ordinary colonies visibly
soften, sets the default between them and the ceiling above the second, and records those conditions
beside the constant under the range authority's measured-bound rule. The ceiling sweep in
`tests/test_physics.nim` reads the bound from the range authority, so replacing the constant
re-scopes the sweep with no second edit.

**unenforced**: nothing detects a ceiling too high or too low for the mechanism, because no
measurement of the mechanism exists to compare it against. Running that calibration with SPH off,
against the shipped attraction-matrix bounds and force-strength range, and recording its conditions
beside the constant, closes it. Once recorded, an agent checks the record by launching the app,
setting crowding strength to the ceiling in a single-species world, and reading whether colonies
still hold form.

#### Scenario: A fresh world carries no crowding

- **WHEN** the app starts with no preset applied
- **THEN** crowding strength is zero and every force equals the unattenuated oracle

#### Scenario: The unattenuated force law stays reachable

- **WHEN** the crowding range is narrowed
- **THEN** the static assertion in `src/config_ranges.nim` fails the build unless the floor stays
  exactly zero

#### Scenario: The attraction bounds move after a calibration

- **WHEN** the matrix value bounds or the force-strength range change
- **THEN** the record beside the crowding default names bounds that no longer exist, and the
  calibration has to re-run instead of shipping a default tuned against a vanished range
