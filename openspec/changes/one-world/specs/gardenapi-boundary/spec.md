## MODIFIED Requirements

### Requirement: Mode ceilings clamp the particle count

Applying a world preset whose couplings carry a particle ceiling below the live count SHALL lower the
count in place, keeping the surviving particles' positions, velocities, and species — no
re-randomization. Raising or removing the ceiling does not restore a previous count. The
particleCount slider's own commit path keeps its re-initialization behavior; only the preset and
ceiling path becomes non-destructive.

#### Scenario: Preset click preserves a living world
- **WHEN** a preset lowers the ceiling below the live particle count
- **THEN** the count clamps to the ceiling and the surviving particles continue uninterrupted

#### Scenario: Slider behavior unchanged
- **WHEN** the user commits a new particleCount on the slider
- **THEN** particles re-initialize as before

## ADDED Requirements

### Requirement: Descriptors carry labelled notches

A parameter descriptor SHALL be able to carry a table of labelled notches — values known to produce
something worth seeing — served to the panel through `descriptor(id)` like every other number.
Notches are authored in Nim; the panel renders them and never invents its own.

Every notch value SHALL lie inside its parameter's range, asserted by
tests/test_param_descriptor.nim, because a labelled value the slider cannot reach is the same defect
as an unlabelled range whose interesting parts are unfindable.

#### Scenario: Slider shows where the good values are
- **WHEN** the panel renders a slider whose descriptor declares notches
- **THEN** it draws a labelled tick at each notch value, taken from the descriptor

#### Scenario: Unreachable notch fails the suite
- **WHEN** a notch is declared outside its parameter's range
- **THEN** `just test` fails naming the parameter and the notch

### Requirement: Coupled parameters have a joint selector

Where a regime is located by two or more parameters together, the panel SHALL offer a named selector
that sets them jointly, in addition to the individual sliders. A notch on one axis alone does not
locate a regime, so notches on coupled parameters are informative but not sufficient.

#### Scenario: Choosing a named regime
- **WHEN** the user picks a named regime
- **THEN** every parameter that regime specifies is set together through the clamped boundary
