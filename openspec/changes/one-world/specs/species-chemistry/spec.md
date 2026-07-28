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

A test SHALL measure the collapse point and assert the shipped bound sits below it.

#### Scenario: Maximum tropism stays stable
- **WHEN** every species sits at the positive tropism bound with the maximum deposit
- **THEN** the field does not diverge and no unbounded concentration forms

#### Scenario: The bound tracks the measurement
- **WHEN** the measured collapse point moves
- **THEN** the bound is lowered to stay beneath it, and the measured value is recorded beside it
