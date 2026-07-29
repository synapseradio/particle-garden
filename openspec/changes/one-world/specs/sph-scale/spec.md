## ADDED Requirements

### Requirement: The smoothing radius is a fraction of the interaction radius

The SPH smoothing radius SHALL be computed as `params.interactionRadius * params.sphRadiusFraction`,
with the fraction in `(0, 1]`, replacing the aliasing at `web/shaders/src/forces-sph.wgsl:104` where
the fluid kernel is the force kernel. A fraction rather than an absolute radius makes the neighbour
sweep's ceiling unrepresentable to exceed — the sweep visits only the cell block around a particle,
and cells are sized to the interaction radius (`src/grid.nim:61`), so a smoothing radius above the
interaction radius would silently drop neighbours. With the fraction capped at 1 by its range, that
fluid cannot be expressed at all.

The kernels already take the radius as a parameter and recompute their normalizations from it
(`src/sph_core.nim:11-13`), so the oracle needs no restructuring: the native tests sweep the
fraction range through the same functions the shader mirrors.

#### Scenario: Fraction one is today's fluid

- **WHEN** the fraction is exactly 1
- **THEN** the smoothing radius, both kernel normalizations, and the resulting pressure and XSPH
  terms equal today's values, so this change cannot silently alter an existing world

#### Scenario: The fluid keeps its relative scale

- **WHEN** the interaction radius changes at a fixed fraction
- **THEN** the smoothing radius scales proportionally, so the interaction radius remains one
  meaningful control rather than two coupled ones

#### Scenario: The sweep cannot be outrun

- **WHEN** any representable fraction is set
- **THEN** the smoothing radius is at most the interaction radius, by construction rather than by
  clamp

### Requirement: The stiffness ceiling derives from the fluid's configuration

The stiffness the fluid honours SHALL be bounded by a pure function in `src/sph_core.nim`
(`stableStiffnessCeiling`, `:199-221`) of the smoothing radius in pixels — the fraction times the
interaction radius, multiplied by the caller the way `forces-sph.wgsl` does — the substep count,
and the effective timestep. The measured law is `SPH_STABILITY_COEFFICIENT * h * substeps / dt`,
linear in each factor rather than the Courant square; `src/sph_core.nim:178-189` records why this
integrator sheds both of the textbook's `1/h` factors. The ceiling is clamped against
`SPH_STIFFNESS_MAX`, which survives only as the absolute envelope and reaches the function as an
argument, because the range authority imports this module and hands its own constant to the
function it bounds (`src/sph_core.nim:206-208`). The ceiling bounds the value's effect; it never
redefines the stored value, which stays absolute stiffness — the pressure gain
(`src/sph_core.nim:108-113`). `src/sph_core.nim:39-42` already records the stiffness-timestep
coupling in prose; this requirement makes it arithmetic.

The stability coefficient in that function SHALL be fitted from a measured stability sweep of this
integrator — stiffness against radius fraction and substeps — never assumed from literature, and the
measurement's conditions and margin SHALL be recorded beside the coefficient under the range
authority's measured-bound rule. A native test SHALL hold the derived ceiling below the measured
stability boundary across the reachable input box, so re-running the suite re-checks the fit.

How the derived ceiling is represented, served, and clamped is the range authority's mechanism (see
the `parameter-range-authority` delta); this capability owns the function and its measurement.

#### Scenario: Shrinking the radius lowers the ceiling

- **WHEN** the radius fraction falls with substeps and timestep held fixed
- **THEN** the derived stiffness ceiling falls, linearly in the fraction — the measured law,
  recorded beside `SPH_STABILITY_COEFFICIENT` in `src/sph_core.nim`

#### Scenario: More substeps buy more stiffness

- **WHEN** the substep count rises with the fraction and timestep held fixed
- **THEN** the derived ceiling rises, linearly in the substep count, under the same measured law

#### Scenario: The ceiling cannot exceed the envelope

- **WHEN** the deriving inputs take any reachable combination
- **THEN** the derived ceiling is at most `SPH_STIFFNESS_MAX`, asserted by a native sweep over the
  whole input box, and the worst-case ceiling is recorded beside the radius-fraction floor that
  decides it (`src/config_ranges.nim`) — the floor every labelled stiffness notch must sit below,
  held by the notch sweep in `tests/test_param_descriptor.nim`, which goes red on the first notch
  that strands

### Requirement: The fraction default is calibrated with crowding off

The shipped fraction default SHALL sit strictly below 1, placing the smoothing kernel at
near-neighbour scale, and SHALL be measured with crowding strength at zero so it is a property of
the fluid alone — the companion of the crowding default's SPH-off calibration. The measurement
conditions are recorded beside the constant; the record is review-enforced like every measured
bound.

No saved world is silently rescaled by the new default. The fraction is carried in the preset
schema from this change's schemaVersion onward, and the legacy branch of the versioned decode —
the translate-at-decode boundary D8 establishes — SHALL pin the fraction to exactly
1.0 for presets older than that version, because 1.0 is the kernel those worlds ran when they were
saved. The release note covers fresh worlds only, whose default moves below 1.

#### Scenario: A saved fluid world is reproducible

- **WHEN** a preset saved after this change is applied
- **THEN** the fraction it carries is restored and clamped like every schema field, so the world's
  fluid scale survives the round trip

#### Scenario: A legacy fluid world keeps its kernel

- **WHEN** a preset saved before this change is applied
- **THEN** the fraction decodes to exactly 1.0 rather than to the shipped default, so the world
  looks as it did when it was saved
