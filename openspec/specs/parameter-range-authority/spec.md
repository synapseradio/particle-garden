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

### Requirement: Camera ranges

`src/config_ranges.nim` SHALL define `CAMERA_ZOOM_MIN = 1.0` — the view never spans more than one
world, so zoom 1 frames the whole world to the window — and `CAMERA_ZOOM_MAX = 8.0`, close enough to
watch one particle, both under the standard static non-emptiness assertion and consumed by the
descriptor table like every other range.

The camera is deliberately absent from the preset schema: it is view state, and
`tests/test_param_descriptor.nim` pins `cameraZoom` as the only descriptor routed through the camera
store, so a second one cannot widen that hole silently.

#### Scenario: Zoom clamps at the authority's bounds
- **WHEN** input drives zoom beyond either bound
- **THEN** the stored zoom clamps to the `config_ranges` constant

#### Scenario: A second descriptor joins the camera store
- **WHEN** a descriptor other than `cameraZoom` is routed through the camera store
- **THEN** `just test` fails at the camera-routing assertion, which pins that set to one id

### Requirement: Species chemistry ranges

Secretion and tropism SHALL have signed, bounded ranges defined in `src/config_ranges.nim` with static
non-emptiness and default-in-range assertions. The bounds are asymmetric by design: secretion spans
`[-1.0, +1.0]` because the splat kernel's normalization conserves the deposit's total in either
direction, while tropism spans `[-1.0, +0.5]`, granting full authority to down-gradient motion and
half to up-gradient motion, because climbing a self-deposited gradient is the direction that admits
chemotactic collapse while descending one is stabilizing.

`TROPISM_MAX` records the measured collapse point, the conditions it was taken under, and the bracket,
per the measured-bound rule. `tests/test_field_core.nim`, suite `Chemotactic Collapse Bound`, holds
that measurement executable.

#### Scenario: Tropism cannot escape its bound
- **WHEN** a preset or UI write carries a tropism outside the range
- **THEN** the value clamps at the `config_ranges` bound

#### Scenario: The bound is measurement-backed
- **WHEN** the tropism bound changes
- **THEN** the chemotactic-collapse suite still passes: every reachable deposit-tropism combination
  stays finite and bounded, and collapse still needs a deposit far outside the slider range

### Requirement: The feed range reaches every labelled regime

`RD_FEED_MAX` SHALL be at least the largest feed coordinate the regime table names, so that every
named regime the panel offers is reachable on its own slider. The shipped ceiling is 0.085 against
Coral's 0.082.

A static assertion in `src/config_ranges.nim` walks `RD_REGIMES` and rejects a feed, kill, or minimum
deposit outside its own slider's range, so the next coordinate past the ceiling fails the build rather
than shipping an unreachable label.

#### Scenario: Coral is selectable
- **WHEN** the user picks the Coral regime
- **THEN** its feed value lies inside the slider range and applies without clamping

#### Scenario: A regime coordinate escapes its slider
- **WHEN** a regime's feed or kill moves outside the range that slider serves
- **THEN** `just happen` fails at the regime assertion in `config_ranges.nim`

### Requirement: Notch tables live with the ranges

Where a parameter's labelled notches derive from published or measured values, those values SHALL be
defined alongside the ranges they must satisfy, so a range change and a notch change cannot drift
apart. `RD_REGIMES`, `RD_REGIME_HIGH_FEED_DEPOSIT`, `CAMERA_ZOOM_NOTCH_WORLD`, and
`CAMERA_ZOOM_NOTCH_CREATURE` all sit in `src/config_ranges.nim` beside the bounds they answer to,
under the same static block that checks them.

`tests/test_param_descriptor.nim` carries the native half: every notch lies inside its parameter's
range, sits on a position the slider can land on, carries a label, and is never declared twice for one
parameter.

#### Scenario: Narrowing a range strands a notch
- **WHEN** a range narrows past one of its own notch values
- **THEN** the notch-in-range check fails at build time rather than shipping an unreachable label

### Requirement: The crowding and scale ranges

`src/config_ranges.nim` SHALL define these tunables' bounds under the standard static non-emptiness
and default-in-range assertions:

- **Crowding strength.** The range SHALL include zero, and zero SHALL be an ordinary reachable
  slider position, because strength zero is exactly the uncrowded force law and keeping it reachable
  is what makes the term bisectable. Zero is a labelled notch, and a static assertion pins
  `CROWDING_STRENGTH_MIN` at zero. `CROWDING_STRENGTH_MAX` is a working bound rather than a measured
  one, marked as such beside the constant and pending the in-app calibration the measured-bound rule
  requires; the ceiling sweep in `tests/test_physics.nim` reads the constant from here, so that
  calibration re-scopes the sweep without a second edit.
- **SPH radius fraction.** The maximum SHALL be exactly 1, so a fluid kernel equal to the force kernel
  stays representable — capped there because a smoothing radius past the neighbour sweep's reach would
  silently drop neighbours instead of gathering more. The minimum SHALL be strictly positive, for two
  reasons recorded beside the constant: a zero radius divides by zero in both kernel normalizations
  (`poly6Weight2d` and `spikyGradientMagnitude2d` in `src/sph_core.nim`), and the floor decides the
  worst-case stiffness ceiling, so the derived-bound notch sweep may raise it to keep every labelled
  stiffness notch live.
- **Force weather speed.** Bounded like the climate speed, in the same tours-per-minute unit —
  `FORCE_WEATHER_SPEED_MIN` and `FORCE_WEATHER_SPEED_MAX` alias `CLIMATE_SPEED_MIN` and
  `CLIMATE_SPEED_MAX` rather than restating them.

#### Scenario: Crowding can be turned off

- **WHEN** the user drags the crowding strength to its minimum
- **THEN** the stored value is exactly zero and the force law is the uncrowded one

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
substeps, documented as a stability buy in `src/sph_core.nim`, into a hidden stiffness control).

- **Envelope.** The `config_ranges.nim` constants own everything static: the declared descriptor
  range, the preset schema clamps, curve domains, and the build-time assertions. Derivation changes
  none of it.
- **Ceiling.** A pure function registered under a `ParamCeilingId`, cited by the descriptor through a
  bound variant — `bConstant` or `bDerived(ceilingId)`. `evaluateCeiling` covers the enum exhaustively,
  so an unregistered ceiling does not compile.
- **Effect-time clamp.** The effective value is `min(stored, ceiling(live config))`, applied at the
  CONFIG-mirror write and never at store time. The stored value is never destroyed: shrink a
  ceiling input and the effective value drops; restore it and the stored value returns, with no
  hysteresis — the same non-destructive clamp the particle budget already codified.

Presets clamp against the envelope at load, and the ceiling applies when the value takes effect, which
honours a preset as intent whatever fluid it lands in. The labelled notches of a `bDerived` parameter
MUST sit below the minimum ceiling over the deriving inputs' whole box. The live ceiling reaches the
panel on the existing stats push in `src/web_api.nim`, never a second channel; the slider renders the
envelope with the region above the live ceiling drawn dormant, carrying the reason, and that region is
inert by construction.

The stiffness ceiling is the one shipped derived bound: `sphStiffness` cites `pcStableStiffness`,
whose function and measurement belong to the SPH capability.

Enforced by `tests/test_param_descriptor.nim`, suite `A Derived Bound Cites A Registered Ceiling`:
every `bDerived` descriptor evaluates to a positive ceiling at or below its declared maximum over
every corner of the input box and carries a written reason; `minimumCeiling` is checked to be the
corner it claims; every notch of a `bDerived` parameter sits below that minimum; and a fluid that
cannot hold the stored stiffness is asserted to run at the ceiling with the stored value intact.

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

The range authority already documents several bounds this way — `RD_DEPOSIT_MAX` records the flood
point it was derived from and the corner it was measured at, and `RD_FIELD_FORCE_MAX` records the
gradient magnitude it is scaled against. This extends that practice from the bounds that happened to
get it to all of them.

**agent-checkable.** No mechanism rejects a bound or precision change arriving without its
measurement. The procedure that detects a violation: read the diff for every changed constant in
`src/config_ranges.nim` and every changed `precision` in `src/ui/api/param_descriptor.nim`, and for
each one confirm the comment beside it names the metric, the value before, and the value after; a
changed constant whose comment is unchanged or absent is the violation. An automated gate would need
the failing metric recorded in machine-readable form beside the constant, checked against the sweep's
own output.

#### Scenario: A bound moves with its evidence
- **WHEN** a range bound changes to remove dead travel
- **THEN** the comment beside it names the metric, the parameter's value before, and its value after

#### Scenario: A precision change records its cliff
- **WHEN** a precision rises to shrink a step
- **THEN** the comment beside it records the cliff measurement that required it

### Requirement: The attraction matrix's coordinates are one recorded range decision

The matrix bounds SHALL be `[-0.330, 0.330]` with step `0.001` and three-decimal display precision,
held in `src/config_ranges.nim` as the single source consumed by matrix state, the preset schema, and
the boundary — no copy elsewhere, and no restatement in TypeScript. A static assertion pins the band
symmetric, because `cellColorFromValue` and `sampleRuleValue` both read magnitude against
`MATRIX_MAX_VALUE` alone.

The band is provisional, marked as such beside the constants: the calibration is pending an in-app
judgment to be made together with the crowding ceiling, since both shape same-species pile-up and
either one tuned against the other's old behaviour would leave both wrong.

The matrix random-fill distribution SHALL be calibrated to the bounds: `RULE_WILDNESS_MIN` and
`RULE_WILDNESS_MAX` are sigma as a fraction of `MATRIX_MAX_VALUE`, and `sampleRuleValue` applies that
scale, so the wildness range keeps its meaning across any matrix re-range. `tests/test_matrix.nim`
holds the scaling, the rejection of out-of-range draws, and the inclusive boundaries.

#### Scenario: One authority, no copies
- **WHEN** the source tree is searched for the matrix bounds, step, or precision
- **THEN** exactly one definition exists, in `src/config_ranges.nim`, and every consumer — matrix
  state, preset schema, boundary, editor — reads it from there

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
correction, and `PARTICLE_VISIBLE_RADIUS_FLOOR_PX` is a pixel value asserted where every factor sits
at the corner that minimizes it.

Enforced by `tests/test_camera_core.nim`, suite `A Floor On What Can Be Seen`, which holds the worst
reachable corner above the floor, pins that the check can go red by measuring a lower zoom floor
beneath it, and asserts the composed radius grows with each factor.

#### Scenario: The visibility floor holds at the worst corner
- **WHEN** particle size, zoom, and the density multiplier all sit at the corner that minimizes
  on-screen radius
- **THEN** the composed radius stays at or above the recorded pixel floor, asserted natively

#### Scenario: A factor floor does not impersonate the guarantee
- **WHEN** a floor exists on one factor of a composed observable
- **THEN** it is documented as shaping that factor alone, and the composition's own floor exists at
  the end of the chain

### Requirement: A logarithmic curve pairs only with a positive floor

The descriptor table's static block SHALL reject the pairing of a logarithmic travel curve with a
range whose minimum is zero or negative, so giving a parameter logarithmic travel and giving it a
strictly positive floor are one recorded decision rather than two constants free to disagree. The gate
sits beside the descriptors in `src/ui/api/param_descriptor.nim` rather than in the range authority
because the pairing is per-descriptor: the range authority cannot see which of its constants carries
which curve.

#### Scenario: A log curve over a zero-floored range fails the build
- **WHEN** a descriptor declares a logarithmic curve while its range minimum is zero
- **THEN** `just happen` fails at the static assertion naming the parameter

### Requirement: Every notch and hint numeral remains reachable after a range change

Any value a descriptor names — a notch coordinate or a numeral inside a hint — SHALL remain reachable
on its slider's lattice after any range, precision, or curve change, asserted natively.

`tests/test_param_descriptor.nim` runs every hint numeral and every notch coordinate through
`positionOf` and back through `valueAt`, and requires each to return to itself exactly. A companion
test keeps the check from emptying, pinning that the regime coordinates live in the notches rather
than in the hints and tying the `rdFeed` and `rdKill` notch counts to `RD_REGIMES`. A re-range
performed to fix dead travel is exactly the change most likely to strand a
coordinate outside the range it was chosen for.

#### Scenario: A re-range that strands a coordinate goes red
- **WHEN** a bound moves past a value the descriptor names
- **THEN** `just test` fails naming the parameter and the stranded value
