## ADDED Requirements

### Requirement: The reference-oracle family covers the render-side sliders

Pure mirrors of the glow and trail shader math SHALL join the reference-oracle family, so the glow and
trail sliders are measured rather than exempted from measurement.

The family currently mirrors force curves, grid arithmetic, SPH kernels, the reaction, the bloom
kernel, and the field colormaps. Glow and trail have no mirror, which is why their sliders would
otherwise take an exemption they do not deserve — both are small closed-form expressions.

#### Scenario: The glow oracle mirrors its shader
- **WHEN** the glow falloff, radius, alpha, or warmth expression changes in the shader
- **THEN** the mirror is updated alongside it, as for every other oracle in the family

#### Scenario: No render slider is exempt for want of an oracle
- **WHEN** the exemption table is read
- **THEN** no entry gives "no oracle exists" as its reason for a glow or trail parameter

### Requirement: Probe coverage over the descriptor table is total

A native test SHALL assert that every descriptor is either probed or exempted and that no descriptor
is both, so the coverage relation cannot silently develop a hole.

This is the same shape as the invariant relating a mode's dispatched passes to the control groups it
offers: a relation between two tables, asserted rather than reviewed.

#### Scenario: Coverage is exact
- **WHEN** the probe registry and the exemption table are compared against the descriptor table
- **THEN** their union is the whole table and their intersection is empty

### Requirement: The legibility sweep is a native test, not a script

The span, live-fraction, and cliff sweep SHALL run inside the native suite so a regression turns
`just check` red, rather than existing as a tool somebody remembers to run.

Its runtime is bounded by the declared per-probe sample budgets. Where the suite slows materially, the
stepped-probe budget is lowered before any parameter is dropped from coverage.

#### Scenario: A regression in a shipped control goes red
- **WHEN** a change makes a previously passing control's track dead over most of its length
- **THEN** `just check` fails naming the control and the metric

### Requirement: New pure modules register in the suite and its documentation

Every pure module added by this work SHALL be registered in the native suite's aggregate module with
its marker constant and added to the test documentation's per-file table and architecture tree.

A module absent from the aggregate compiles but never runs, which is the failure this registration
exists to catch.

#### Scenario: An unregistered module is caught
- **WHEN** a new test module is not added to the aggregate
- **THEN** the omission is visible as a missing marker rather than as silent non-execution
