# species-chemistry

## Purpose

Owns the per-species coupling between the particles and the Gray-Scott field: a signed secretion
that says what a species deposits, a signed tropism that says how it answers the field gradient, the
editor that sets both, and the asymmetric bound that keeps up-gradient feedback from running away.
One capability because the two per-species numbers are one contract — the deposit pass and the
field-force pass read the same packed chemistry uniform, and the safety bound is measured on their
product with the field's own deposit ceiling.

The reaction-diffusion chemistry itself, the field grid, and the deposit ceiling belong to
`field-scale`. Ranges and defaults belong to `parameter-range-authority`. The matrix editor whose
state patterns the chemistry editor follows belongs to the panel. This spec cites those relations
and leaves their detail to them.

## Requirements

### Requirement: Species couple to the field individually

Each species SHALL have a signed secretion — what it deposits into the field — and a signed tropism —
how it responds to the field gradient. The deposit pass scales by that species' secretion
(`web/shaders/src/field-deposit.wgsl:81-85`); the field-force pass scales by its tropism
(`web/shaders/src/field-force.wgsl:70-76`). Both reach their value by the same packed arithmetic
`forces.wgsl` uses for an attraction-matrix entry, four species per `vec4`. speciesCount thereby
affects the chemical world's dynamics and not only its palette.

Enforced by: the reference oracles `speciesDeposit` and `speciesTropismForce`
(`src/field_core.nim:435-448`), which the shader passes mirror; the ranges `SECRETION_MIN/MAX` and
`TROPISM_MIN/MAX` (`src/config_ranges.nim:342-361`) with their static assertions (`:520-528`);
`tests/test_field_core.nim`, suite "Species Chemistry Coupling" (`:911-974`).

#### Scenario: Builder and grazer diverge
- **WHEN** two species carry opposite secretion signs
- **THEN** their deposits push the field in opposite directions at their locations

#### Scenario: Tropism steers
- **WHEN** a species' tropism is negative
- **THEN** its particles accelerate down the field gradient, and up it when positive

#### Scenario: An inert species
- **WHEN** a species has zero secretion and zero tropism
- **THEN** it neither marks the field nor is moved by it

### Requirement: Chemistry has an editor

The panel SHALL offer a per-species chemistry editor beside the attraction matrix
(`web-ui/src/components/ChemistryEditor.tsx`), following the matrix editor's state patterns, writing
through the descriptor-clamped boundary: the editor clamps each entered value with
`api.clampParam(column.id, ...)` and writes it into the shared chemistry array at
`species * stride + column.slot`, which the deposit and field-force passes read on the next frame.

The descriptor side is native-tested: the per-species columns are exactly secretion and tropism,
they fill one species' stride with no slot spare, and one clamp serves both cardinalities
(`tests/test_param_descriptor.nim`, suite "Cardinality Rides On The Descriptor, Not On A Second
Table", `:455-509`).

**agent-checkable** for what the editor does on screen, because the panel components carry no native
test. The procedure: launch the app, open the chemistry editor, set one species' tropism to its
negative bound and another's to its positive bound with a non-zero deposit running, and read that
the two species separate across the pattern within a few seconds. A violation shows as an edit that
leaves the simulation unmoved, or as a value the field reads back different from the one typed.

#### Scenario: Edit lands synchronously
- **WHEN** a secretion or tropism value is edited
- **THEN** the clamped value reaches the chemistry uniform in the same tick

#### Scenario: An out-of-range entry is clamped, not refused
- **WHEN** a value outside the column's range is entered
- **THEN** the editor writes the clamped value and displays it, so the cell reads back what the
  simulation holds

### Requirement: Up-gradient feedback stays bounded

Tropism SHALL be bounded asymmetrically, granting less authority to up-gradient motion than to
down-gradient motion, because agents that climb their own deposited gradient form a positive
feedback loop that admits chemotactic collapse while agents that descend one do not. The shipped
bounds are `TROPISM_MIN = -1.0` and `TROPISM_MAX = 0.5` (`src/config_ranges.nim:353-361`), and a
static assertion holds `TROPISM_MAX < -TROPISM_MIN` so a later tidying to a symmetric range fails
the build instead of shipping unmeasured up-gradient authority (`src/config_ranges.nim:522-524`).

Native tests warrant the bound by bracketing where collapse lives (`tests/test_field_core.nim`,
suite "Chemotactic Collapse Bound", `:975-1176`): inside the deposit range the sliders offer, no
tropism collapses the field — a thousandfold the bound stays finite and bounded — while divergence
needs a deposit bracketed at (10x, 15x] of `RD_DEPOSIT_MAX`, and a frozen-population control at that
same deposit proves the divergence chemotactic and not the deposit's own flooding. The deposit
ceiling therefore carries more of the protection than the tropism bound does, and the tests state
that scope.

#### Scenario: Maximum tropism stays stable
- **WHEN** every species sits at the positive tropism bound with the maximum deposit
- **THEN** the field does not diverge and no unbounded concentration forms

#### Scenario: Collapse stays outside the reachable world
- **WHEN** the deposit ceiling or the tropism bound changes
- **THEN** the bracketing tests still pass: every reachable deposit-tropism combination stays
  finite and bounded, and the frozen-population control still separates chemotaxis from the
  deposit's own flooding
