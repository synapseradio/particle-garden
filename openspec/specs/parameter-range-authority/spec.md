# parameter-range-authority

## Purpose

Own every number that decides what value a user-facing tunable can take: its bounds, its default, the
step and precision that form the lattice of positions between the bounds, and the clamp that coerces
any write onto that lattice. Bounds and lattice are one capability rather than two because they are
only meaningful together — a bound alone does not say which values inside it are reachable, and a
step alone does not say where travel stops. Splitting them would let a range move without the
positions over it moving with it.

## Requirements

### Requirement: One definition site for every user-facing bound

`src/config_ranges.nim` SHALL be the sole definition site for the bounds of every user-facing
tunable. No consumer SHALL restate a bound as a literal. The descriptor table
(`src/ui/api/param_descriptor.nim`) reads the constants, and the preset schema imports and re-exports
the same module (`src/preset.nim:37`, `:43`) so that preset clamping and slider travel cannot
diverge. Bounds with no slider behind them — the force-model index, matrix cell values, and palette
RGB channels — are defined in `src/preset.nim:144-153` rather than in the range authority, because
nothing in the descriptor table presents them.

The tunable inventory SHALL be closed: exactly one descriptor per id, over a fixed id set. Bounds
that originate in another module are aliased rather than copied — the particle and species ceilings
come from `memory_layout` (`src/config_ranges.nim:29`, `:34`), the SPH substep ceiling from
`sph_core` (`:80`), and the field-opacity and colormap bounds from `colormap_core` (`:125-128`).

Enforced by `tests/test_param_descriptor.nim:140-219`, which pins each descriptor bound to its
`config_ranges` constant, and `tests/test_param_descriptor.nim:33-51`, which pins the id set and
rejects duplicates. `src/preset.nim:155-157` asserts statically that the preset array sizing and the
species ceiling agree.

#### Scenario: A bound changes in the authority

- **WHEN** a constant in `config_ranges.nim` changes
- **THEN** the slider range, the preset clamp bound, and the value the control panel is served all
  change with it, because each reads that constant rather than a copy

#### Scenario: A descriptor bound stops matching its constant

- **WHEN** a descriptor is edited to carry a literal bound instead of its `config_ranges` constant
- **THEN** `just test` fails at the descriptor-to-authority comparison naming that parameter

### Requirement: Ranges are non-empty and defaults lie inside them

Every range MUST satisfy `MIN < MAX`, and every default MUST lie within the range it is the default
of. An inverted range makes clamping invert; an out-of-range default ships a control whose opening
position it cannot reach.

Both properties are enforced twice, at different strengths. Static assertions in
`src/config_ranges.nim:130-180` reject an inverted range at compile time for the particle-count,
species-count, particle-size, glow-halo, SPH, reaction-diffusion, bloom-and-grade, colormap-index,
and field-opacity families, and reject an out-of-range default for the eleven defaults that
originate in the reference-oracle modules (`field_core`, `bloom_core`, `colormap_core`). The
remaining fifteen ranges — interaction radius, force strength, friction, rule temperature, time
scale, trail length, glow intensity, velocity glow scale, max velocity, the two polynomial
force-model bounds, the two exponential force-model bounds, and the two palette bounds — carry no
static assertion and are covered natively instead, by `tests/test_param_descriptor.nim:116-120`,
which checks non-emptiness and default-in-range for every descriptor. The colormap index has no
descriptor, so the static assertion is its only guard.

#### Scenario: A range is edited into an inverted state

- **WHEN** a statically asserted range is edited so that its minimum exceeds its maximum
- **THEN** `just happen` fails at the `config_ranges.nim` static block rather than producing a build

#### Scenario: A default is moved outside its range

- **WHEN** a default in a reference-oracle module moves outside the range it is the default of
- **THEN** the compile fails at the default-in-range assertion in `config_ranges.nim`

#### Scenario: A range with no static assertion inverts

- **WHEN** a range carrying no static assertion is edited into an inverted state
- **THEN** `just test` fails at the descriptor coherence check

### Requirement: A bound derived from a measurement records that measurement beside it

A bound set by a measured stability limit rather than by a natural unit SHALL record, beside the
constant, the measured value, the conditions it was measured under, and the margin between the
measurement and the bound. This holds for the deposit ceiling, which records the flood
point, the feed/kill coordinates it was taken at, and the weakest-corner margin
(`src/config_ranges.nim:90-97`), and for the field-force ceiling, which records the gradient
magnitude it is scaled against and the reason the range is kept non-negative (`:101-108`).

Where the measurement can be re-executed, a native test SHALL assert the bound against it rather than
leaving the comment as the only record. The deposit ceiling has such a test:
`tests/test_field_core.nim:329-347` sweeps all four feed/kill corners at `RD_DEPOSIT_MAX` and asserts
the field stays finite and bounded, and states in its own text that a failure lowers the ceiling
rather than the assertion.

This requirement is `review-enforced` for the recording itself: no mechanism rejects a new bound that
arrives without a comment, and the field-force ceiling carries a comment with no executable
counterpart.

#### Scenario: A measured ceiling is raised

- **WHEN** `RD_DEPOSIT_MAX` is raised past the point where the weakest feed/kill corner floods
- **THEN** `just test` fails at the deposit-ceiling sweep

#### Scenario: A new measured bound is added

- **WHEN** a bound is introduced whose value comes from a stability measurement
- **THEN** review requires the measured value, its conditions, and the margin to appear beside the
  constant

### Requirement: Defaults come from the typed state records

The descriptor table SHALL take every default from the authority that already holds it, never from a
literal: simulation defaults from `initSimulationState()`, render defaults from `initRenderState()`,
and the two palette defaults from `palette.nim`'s `DEFAULT_SATURATION` / `DEFAULT_LIGHTNESS`
(`src/ui/api/param_descriptor.nim:91-92`, `:173-178`). Those state records in turn draw the
reaction-diffusion, bloom, and field-visualization defaults from the reference-oracle modules
(`src/ui/state/simulation_state.nim:73-76`, `src/ui/state/render_state.nim:59-66`), so one value
serves as the simulation's starting state, the slider's reset target, and the preset schema's
fallback.

Enforced by `tests/test_param_descriptor.nim:221-268`, which compares every descriptor default
against the state record field it must equal.

#### Scenario: A default changes in the state record

- **WHEN** a field default in `initSimulationState` or `initRenderState` changes
- **THEN** the descriptor default the control panel is served changes with it, with no second edit

#### Scenario: A descriptor default is hardcoded

- **WHEN** a descriptor is given a literal default that differs from its state record
- **THEN** `just test` fails at the default-authority comparison

### Requirement: Step and precision derive from kind and display precision

A descriptor SHALL NOT declare its step. The step MUST be derived: integer parameters step by 1, and
float parameters step by one unit of their display precision, `10^-precision`
(`src/ui/api/param_descriptor.nim:59-65`). Precision is the only per-parameter declaration, and it
decides both the step and the rounding the readout applies, so a value the readout can display is a
value the slider can land on.

Enforced by `tests/test_param_descriptor.nim:122-131`, which re-derives the step for every descriptor
from its kind and precision, and by `:133-138`, which pins exactly which parameters are integers.

#### Scenario: Precision rises on a float parameter

- **WHEN** a float descriptor's precision increases by one
- **THEN** its step shrinks by a factor of ten and the readout gains a decimal place together

#### Scenario: A step is declared instead of derived

- **WHEN** a descriptor carries a step that does not match `10^-precision` for its kind
- **THEN** `just test` fails at the step-derivation check

### Requirement: Every numeral a hint names is a reachable slider position

A hint rendered under a control SHALL live in the descriptor beside the range, step, and precision
that decide reachability, never in the control panel. Every numeral appearing in a hint MUST lie
inside the descriptor's range, MUST fall on a step boundary measured from the range minimum, and MUST
survive the rounding the readout applies at that precision. A hint naming a value the slider cannot
land on sends the user hunting for a setting that does not exist, and the TypeScript panel — handed
the finished string — has nothing to check it against.

Enforced by `tests/test_param_descriptor.nim:83-100`, which extracts every numeral from every hint
and asserts all three properties, with a guard that the loop checked something. A companion assertion
at `:102-107` pins which hints carry numerals, so deleting a hint cannot quietly empty the check.

#### Scenario: A hint names an off-lattice value

- **WHEN** a hint names a coordinate that is not on its slider's step lattice
- **THEN** `just test` fails at the hint-reachability check

#### Scenario: A range narrows past a hint numeral

- **WHEN** a bound moves so that a value one of its hints names now falls outside the range
- **THEN** `just test` fails at the in-range assertion of the hint-reachability check

### Requirement: Clamping is the descriptor's job on every write path

`clampParamValue` (`src/ui/api/param_descriptor.nim:222-231`) SHALL be the one clamp for parameter
writes: it coerces the value into the descriptor's range and additionally truncates integer
parameters through `int()`, so a drag position lands on a value the parameter's kind admits. Every
parameter write MUST pass through it — the generic write path at `src/web_api.nim:348` and the
species-count path at `:286` both do, and an unknown id is rejected rather than written
(`src/web_api.nim:345-347`).

Loaded presets are clamped against the same constants rather than against the descriptor object,
through `clampInt` / `clampFloat` over the imported `config_ranges` bounds
(`src/preset.nim:286-360`), so a hostile or stale preset file degrades to in-range values instead of
being rejected.

Enforced by `tests/test_param_descriptor.nim:290-308`, which covers clamping below the minimum, above
the maximum, pass-through in range, and integer truncation.

#### Scenario: A write arrives outside the range

- **WHEN** a parameter write carries a value beyond either bound
- **THEN** the stored value is the bound, not the written value

#### Scenario: A fractional value is written to an integer parameter

- **WHEN** a fractional value is written to an integer parameter
- **THEN** the stored value is that value truncated toward zero and inside the range

#### Scenario: A preset carries an out-of-range field

- **WHEN** a loaded preset carries a field outside its range
- **THEN** the field is clamped to the `config_ranges` bound and the rest of the preset still applies
