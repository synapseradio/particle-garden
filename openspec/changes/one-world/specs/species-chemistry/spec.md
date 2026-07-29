## ADDED Requirements

### Requirement: Species couple to the field individually

Each species SHALL have a signed secretion — what it deposits into the field — and a signed tropism —
how it responds to the field gradient. The deposit pass scales by that species' secretion; the
field-force pass scales by its tropism. speciesCount thereby affects the chemical world's dynamics
rather than only its palette.

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

The panel SHALL offer a per-species chemistry editor beside the attraction matrix, following the
matrix editor's state patterns, writing through the descriptor-clamped boundary.

#### Scenario: Edit lands synchronously
- **WHEN** a secretion or tropism value is edited
- **THEN** the clamped value reaches the chemistry uniform in the same tick

### Requirement: Up-gradient feedback stays bounded

Tropism SHALL be bounded asymmetrically, granting less authority to up-gradient motion than to
down-gradient motion, because agents that climb their own deposited gradient form a positive feedback
loop that admits chemotactic collapse while agents that descend one do not.

Native tests SHALL warrant the bound by bracketing where collapse lives
(`tests/test_field_core.nim:1054-1145`): inside the deposit range the sliders offer, no tropism
collapses the field — a thousandfold the bound stays finite and bounded — while divergence needs a
deposit bracketed at (10x, 15x] of `RD_DEPOSIT_MAX`, and a frozen-population control at that same
deposit proves the divergence chemotactic rather than the deposit's own flooding. The deposit
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
