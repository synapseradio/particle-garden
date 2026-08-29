## ADDED Requirements

### Requirement: Local density attenuates attraction

Every attractive force contribution SHALL be scaled by `1 / (1 + strength * log(1 + density))`,
where `density` is the receiving particle's smoothed, species-blind crowd density — a dedicated
channel that counts every neighbour, accumulated beside the same-species colony density
(`web/shaders/src/forces.wgsl:388-392`, `:466-467`) and smoothed onto the particle exactly as the
colony channel is (`web/shaders/src/integrate.wgsl:101-107`) — and `strength` is the crowding
strength parameter. The colony channel stays same-species and feeds the renderer; the two signals
are not interchangeable (`src/physics_core.nim:123-128`).

The term applies to attractive contributions only, in both force models — the polynomial attraction
envelope (`src/physics_core.nim:422-445`) and the exponential attraction term
(`web/shaders/src/forces.wgsl:93-96`). Repulsive contributions are untouched at every density: the
short-range zone, and attraction-zone contributions whose matrix entry is negative. Attenuating a
repulsive term would partly cancel the cap it exists to serve.

The oracle for the term lives in `src/physics_core.nim` and the WGSL mirrors it; the properties
below are native tests in `tests/test_physics.nim`.

#### Scenario: An isolated particle feels today's force

- **WHEN** a particle's local density is zero
- **THEN** its forces are identical to the unattenuated force at every crowding strength, because
  `log(1 + 0) = 0`

#### Scenario: Strength zero is exactly today's world

- **WHEN** crowding strength is zero
- **THEN** every force at every density equals the unattenuated oracle, so any regression is
  bisectable to one number

#### Scenario: A legacy preset keeps today's force law

- **WHEN** a preset saved before this change is applied
- **THEN** its crowding strength decodes to exactly zero through the legacy branch of the versioned
  decode — the translate-at-decode boundary D8 establishes — not to the shipped
  default, so no saved world gains a term it was not saved with

#### Scenario: Crowding is never rewarded

- **WHEN** density rises with everything else held fixed
- **THEN** attenuated attraction never rises

#### Scenario: Repulsion survives the crowd

- **WHEN** a pair sits in the repulsion zone, or its matrix entry is negative, at any density
- **THEN** the force contribution equals today's, unattenuated

#### Scenario: The term commutes with force strength

- **WHEN** the attenuated attraction is evaluated at force strength `k`
- **THEN** it equals `k` times the attenuated attraction at force strength 1 — the attenuation is a
  fraction of whatever attraction survives `fMul` (`src/physics_core.nim:60`), never an absolute
  force, so its meaning does not drift across the force-strength range

### Requirement: A density ceiling exists and is computed

`src/physics_core.nim` SHALL provide a companion function returning the density at which attenuated
attraction no longer exceeds repulsion at the equilibrium separation — the density past which a
cluster cannot tighten further. A native test in `tests/test_physics.nim` SHALL assert that this
ceiling is finite for every reachable combination of matrix value, force strength, and non-zero
crowding strength, and that it decreases monotonically in crowding strength. The sweep reads its
bounds from the range-authority and preset constants (`FORCE_STRENGTH_MIN/MAX`,
`MATRIX_MIN_VALUE/MAX_VALUE` at `src/config_ranges.nim:63-64`, and the crowding range) rather than restating
them, so a later range recalibration re-scopes the sweep with no second edit. D13 puts
force strength zero inside that swept range; at that endpoint the cap is vacuous rather than wrong
(design C0 — there is no attraction to attenuate), and the sweep SHALL include the point and
assert the ceiling degenerates there rather than excluding it.

The scope of the claim MUST be stated where the ceiling is defined, so it cannot be over-read:

- The ceiling is an equilibrium property. Momentum can overshoot it transiently; it is not a
  per-frame invariant.
- The density signal is species-blind (`web/shaders/src/forces.wgsl:372-378`,
  `src/physics_core.nim:123-128`): the crowd channel counts every neighbour, so the per-cell
  occupancy bound carries no species factor, and a mixed-species blob attenuates exactly as a
  single-species blob of the same total density does.
- The ceiling bounds what species attraction can concentrate. Forces the term does not scale — the
  mouse attract, the blast, positive field tropism — can concentrate beyond it; the tropism side is
  separately bounded by the measured deposit-tropism product (`tests/test_field_core.nim`,
  "Chemotactic Collapse Bound").

Within that scope, a finite ceiling bounds per-cell occupancy up to geometric constants, because
grid cells are sized to the interaction radius (`src/grid.nim:61`) and the density weight spans that
same radius — which is what puts a ceiling on the per-particle neighbour sweep cost rather than
merely lowering its average.

#### Scenario: The ceiling is finite everywhere reachable

- **WHEN** the native sweep evaluates the ceiling across every reachable combination of matrix
  value, force strength, and non-zero crowding strength
- **THEN** every ceiling is finite

#### Scenario: More crowding strength, lower ceiling

- **WHEN** crowding strength rises with attraction held fixed
- **THEN** the computed ceiling falls

### Requirement: The crowding default is calibrated against attraction alone

The shipped crowding strength default SHALL be measured in a world with SPH off, against the shipped
attraction-matrix bounds and force-strength range, and the measurement conditions SHALL be recorded
beside the constant under the range authority's measured-bound rule. The default is then a property
of the crowding mechanism alone, not a compensation for the fluid — and a later change to the
attraction bounds invalidates the recorded conditions visibly rather than silently.

This requirement is review-enforced for the recording itself, like every measured-bound record.

#### Scenario: The attraction bounds move after calibration

- **WHEN** the matrix value bounds or the force-strength range change
- **THEN** the record beside the crowding default names bounds that no longer exist, and review
  requires the calibration to re-run rather than shipping a default tuned against a vanished range
