## ADDED Requirements

### Requirement: Camera ranges

config_ranges.nim SHALL define `CAMERA_ZOOM_MIN = 0.25` (four tiles visible — the infinity read) and
`CAMERA_ZOOM_MAX = 8.0` (creature scale), with the standard static non-emptiness assertion, consumed
by the descriptor table and preset clamping like every other range.

#### Scenario: Zoom clamps at the authority's bounds
- **WHEN** input drives zoom beyond either bound
- **THEN** the stored zoom clamps to the config_ranges constant

### Requirement: Species chemistry ranges

Secretion and tropism SHALL have signed, bounded ranges defined in config_ranges.nim with static
non-emptiness and default-in-range assertions. The bounds are asymmetric by design: tropism spans
`[-1.0, +0.5]`, granting full authority to down-gradient motion and half to up-gradient motion,
because climbing a self-deposited gradient is the direction that admits chemotactic collapse while
descending one is stabilizing.

#### Scenario: Tropism cannot escape its bound
- **WHEN** a preset or UI write carries a tropism outside the range
- **THEN** the value clamps at the config_ranges bound

#### Scenario: The bound is measurement-backed
- **WHEN** the tropism bound changes
- **THEN** the stability test asserting the bound sits below the measured collapse point still passes

### Requirement: The feed range reaches every labelled regime

`RD_FEED_MAX` SHALL be at least 0.085 so that every named regime the panel offers is reachable on its
own slider.

#### Scenario: Coral is selectable
- **WHEN** the user picks the Coral regime
- **THEN** its feed value lies inside the slider range and applies without clamping

### Requirement: Notch tables live with the ranges

Where a parameter's labelled notches derive from published or measured values, those values SHALL be
defined alongside the ranges they must satisfy, so a range change and a notch change cannot drift
apart.

#### Scenario: Narrowing a range strands a notch
- **WHEN** a range narrows past one of its own notch values
- **THEN** the notch-in-range test fails at build time rather than shipping an unreachable label


### Requirement: The crowding and scale ranges

`src/config_ranges.nim` SHALL define the new tunables' bounds under the standard static
non-emptiness and default-in-range assertions:

- **Crowding strength.** The range SHALL include zero, and zero SHALL be an ordinary reachable
  slider position, because strength zero is exactly today's force law and keeping it reachable is
  what makes the term bisectable. Zero is a labelled notch.
- **SPH radius fraction.** The maximum SHALL be exactly 1, so today's behaviour — fluid kernel equal
  to the force kernel — stays representable. The minimum SHALL be strictly positive, for two reasons
  recorded beside the constant: a zero radius divides by zero in both kernel normalizations
  (`src/sph_core.nim:62`, `:82`), and the floor decides the worst-case stiffness ceiling — the
  derived-bound notch sweep may raise it so every labelled stiffness notch stays live.
- **Force weather speed.** Bounded like the climate speed, in the same tours-per-minute unit.

#### Scenario: Crowding can be turned off

- **WHEN** the user drags the crowding strength to its minimum
- **THEN** the stored value is exactly zero and the force law is today's

#### Scenario: A zero smoothing radius is unrepresentable

- **WHEN** input drives the radius fraction to its minimum
- **THEN** the stored value is strictly positive, and the reason lives beside the constant

### Requirement: A bound may derive from other parameters

A derived bound SHALL be represented as three separated parts — envelope, ceiling, and effect-time
clamp — and which bounds may derive at all follows one rule, stated here so the next derived bound
does not relitigate it: a bound that is an exact structural fact of the discretisation folds into
the parameterisation and becomes unrepresentable (the SPH radius fraction is that kind); a bound
that is a fitted empirical estimate stays a named clamp and never redefines the value it bounds
(the stiffness ceiling is that kind — re-parameterising stiffness as a fraction of a fitted ceiling
would silently rescale every saved preset each time the coefficient is refitted, and would turn
substeps, documented as a stability buy at `src/sph_core.nim:39-42`, into a hidden stiffness
control).

- **Envelope.** The `config_ranges.nim` constants own everything static, exactly as today: the
  declared descriptor range, the preset schema clamps, curve domains, and the build-time
  assertions. Derivation changes none of it.
- **Ceiling.** A pure function registered under a name, cited by the descriptor through a bound
  variant — `bConstant` or `bDerived(ceilingId)` — growing the descriptor by table the way
  `notches` already did. A native test asserts every `bDerived` descriptor cites a registered
  function.
- **Effect-time clamp.** The effective value is `min(stored, ceiling(live config))`, applied at the
  CONFIG-mirror write and never at store time. The stored value is never destroyed: shrink a
  ceiling input and the effective value drops; restore it and the stored value returns, with no
  hysteresis — the same non-destructive clamp the particle budget already codified.

Presets clamp against the envelope at load, exactly as today, and the ceiling applies when the
value takes effect, which honours a preset as intent whatever fluid it lands in. The labelled
notches of a `bDerived` parameter MUST sit below the minimum ceiling over the deriving inputs'
whole box, asserted by a native sweep, so no label ever names a dormant position. The live ceiling
reaches the panel on the existing stats push (`src/web_api.nim:989-990`), never a second channel;
the slider renders the envelope with the region above the live ceiling drawn dormant, carrying the
reason, and that region is inert by construction.

The stiffness ceiling is the one derived bound this mechanism serves; its function and measurement
belong to `sph-scale`.

#### Scenario: An input to the ceiling moves

- **WHEN** a parameter that a derived ceiling reads changes
- **THEN** the effective value recomputes at the CONFIG mirror in the same tick, the stored value is
  untouched, and restoring the input restores the stored value's full effect

#### Scenario: The stored value outlives the ceiling

- **WHEN** a stored value sits above the live ceiling
- **THEN** the simulation runs at the ceiling, the slider shows the excess as dormant with the
  reason, and no write path rewrites the stored value

#### Scenario: A preset lands in a weak fluid

- **WHEN** a preset carries a stiffness above what its own radius fraction and substeps support
- **THEN** the stored stiffness applies intact and the effective stiffness is the derived ceiling —
  the preset round-trips unchanged

#### Scenario: A notch strands in the dormant region

- **WHEN** a `bDerived` parameter's notch value exceeds the minimum ceiling over its input box
- **THEN** the notch sweep fails natively rather than shipping a label the fluid cannot honour


### Requirement: A range or step changed for legibility records the measurement that justified it

Every range bound or precision changed in response to a legibility metric SHALL carry, beside the
constant, the metric that failed and the measured values before and after.

The range authority already documents several bounds this way — the deposit ceiling records the flood
point it was derived from and the corner it was measured at (src/config_ranges.nim:96-103), and the
field-force ceiling records the gradient magnitude it is scaled against (:104-112). This extends that
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

### Requirement: The attraction matrix's coordinates are one recorded range decision

The matrix bounds SHALL be `[-0.100, 0.100]` with step `0.001` and three-decimal display precision,
held in the range authority as the single source consumed by the matrix state, the preset schema,
and the boundary — no copy elsewhere, and no restatement in TypeScript. The calibration is recorded
beside the constants and is made together with the crowding attenuation (design C1-C2), because
each of the two tuned against the other's old behaviour would leave both
wrong. The matrix random-fill distribution SHALL be recalibrated to the bounds so a randomized world
keeps its character.

#### Scenario: One authority, no copies
- **WHEN** the source tree is searched for the matrix bounds, step, or precision
- **THEN** exactly one definition exists, in the range authority, and every consumer — matrix state,
  preset schema, boundary, editor — reads it from there

#### Scenario: The fill distribution matches the bounds
- **WHEN** a random matrix is generated
- **THEN** its values land inside the served bounds with a spread calibrated to them, not to bounds
  ten times wider

### Requirement: A bound on a parameter is not a bound on an observable

Where a promise concerns an observable composed from several parameters, the guarantee SHALL be a
bound on the composition, placed at the end of the transform chain, held in the range authority
with its reasoning recorded, and asserted natively at the worst reachable corner of its inputs. A
bound on a single factor SHALL NOT be presented as the guarantee of the composition.

The shipped instance is particle visibility: the on-screen radius is the size parameter through the
density size multiplier, the world-to-screen scale, the camera zoom, and the camera size
correction, and its floor is a pixel value asserted where every factor sits at the corner that
minimizes it.

#### Scenario: The visibility floor holds at the worst corner
- **WHEN** particle size, zoom, and the density multiplier all sit at the corner that minimizes
  on-screen radius
- **THEN** the composed radius stays at or above the recorded pixel floor, asserted natively

#### Scenario: A factor floor does not impersonate the guarantee
- **WHEN** a floor exists on one factor of a composed observable
- **THEN** it is documented as shaping that factor alone, and the composition's own floor exists at
  the end of the chain

### Requirement: A logarithmic curve pairs only with a positive floor

The range authority's static assertions SHALL reject the pairing of a logarithmic travel curve with
a range whose minimum is zero or negative, so giving a parameter logarithmic travel and giving it a
strictly positive floor are one recorded decision rather than two constants free to disagree.

#### Scenario: A log curve over a zero-floored range fails the build
- **WHEN** a descriptor declares a logarithmic curve while its range minimum is zero
- **THEN** the build fails at the static assertion naming the parameter

### Requirement: Every notch and hint numeral remains reachable after a range change

Any value a descriptor names — a notch coordinate or a numeral inside a hint — SHALL remain reachable
on its slider's lattice after any range, precision, or curve change, asserted natively.

The descriptor suite already enforces this for hint numerals (tests/test_param_descriptor.nim:94)
and for notches (src/ui/api/param_descriptor.nim:56). A re-range performed to fix dead travel is
exactly the change most likely to strand a coordinate outside the range it was chosen for.

#### Scenario: A re-range that strands a coordinate goes red
- **WHEN** a bound moves past a value the descriptor names
- **THEN** `just test` fails naming the parameter and the stranded value
