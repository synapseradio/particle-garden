## ADDED Requirements

### Requirement: A range or step changed for legibility records the measurement that justified it

Every range bound or precision changed in response to a legibility metric SHALL carry, beside the
constant, the metric that failed and the measured values before and after.

The range authority already documents several bounds this way — the deposit ceiling records the flood
point it was derived from and the corner it was measured at (src/config_ranges.nim:90-97), and the
field-force ceiling records the gradient magnitude it is scaled against (:101-108). This extends that
practice from the bounds that happened to get it to all of them.

#### Scenario: A bound moves with its evidence
- **WHEN** a range bound changes to remove dead travel
- **THEN** the comment beside it names the metric, the parameter's value before, and its value after

#### Scenario: A precision change records its cliff
- **WHEN** a precision rises to shrink a step
- **THEN** the comment beside it records the cliff measurement that required it

### Requirement: A curve exponent is a range-authority constant

Where a descriptor declares a non-linear travel curve, the exponent SHALL live in the range authority
under the same static assertions as every other tunable constant, not inline in the descriptor table.

The exponent decides how much of the track a region of the value space occupies. That is the same kind
of claim a bound makes, and it belongs where a bound belongs.

#### Scenario: A curve exponent is asserted at compile time
- **WHEN** a curve exponent is declared
- **THEN** a static assertion rejects a value that would invert or flatten the mapping

### Requirement: Every notch and hint numeral remains reachable after a range change

Any value a descriptor names — a notch coordinate or a numeral inside a hint — SHALL remain reachable
on its slider's lattice after any range, precision, or curve change, asserted natively.

The descriptor suite already enforces this for hint numerals (tests/test_param_descriptor.nim:83). A
re-range performed to fix dead travel is exactly the change most likely to strand a coordinate outside
the range it was chosen for.

#### Scenario: A re-range that strands a coordinate goes red
- **WHEN** a bound moves past a value the descriptor names
- **THEN** `just test` fails naming the parameter and the stranded value
