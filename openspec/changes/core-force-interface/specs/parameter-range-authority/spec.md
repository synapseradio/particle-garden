## ADDED Requirements

### Requirement: Every coupling strength ranges from 0 to 1

The six coupling strengths SHALL each have the range `[0, 1]` in `src/config_ranges.nim`: Force
Strength, Fluid, Secretion Rate (`rdDeposit`), Scent-following (`rdFieldForce`), Bodies and Long
Range. What a strength of 1 means, and how the gain behind it is set, belongs to `coupling-contract`
("A strength of 1 is a coupling's calibrated full effect"). This requirement holds only the range.
No coupling SHALL widen its range to reach a stronger effect: a stronger full effect is a new
measurement of `F_c`, never a maximum above 1. Crowding strength is not a coupling strength and is
outside this rule (`bounded-crowding`).

Enforced by: the coupling loop in the static block of `src/config_ranges.nim`
(`src/config_ranges.nim:569-576`). It already holds each coupling strength's floor at exactly 0, and
it SHALL hold each ceiling at exactly 1 (build-asserted). `tests/test_param_descriptor.nim` suite
"Descriptors Agree With The Range Authority" holds each strength descriptor's bounds to those
constants (test-held).

#### Scenario: A coupling ceiling is raised past one

- **WHEN** any of the six coupling strength maxima is set to a value other than 1
- **THEN** the build fails at the coupling loop in `src/config_ranges.nim`

#### Scenario: Every coupling strength reads on one scale

- **WHEN** the panel is served the six coupling strength descriptors
- **THEN** each runs from 0 to 1

## MODIFIED Requirements

### Requirement: One definition site for every user-facing bound

`src/config_ranges.nim` SHALL be the sole definition site for the bounds of every user-facing
tunable. No consumer SHALL restate a bound as a literal. The descriptor table
(`src/ui/api/param_descriptor.nim`) reads the constants, and the preset schema imports and re-exports
the same module (`src/preset.nim:37`, `:43`) so that preset clamping and slider travel cannot
diverge. Bounds with no slider behind them, the force-model index and palette RGB channels, are
defined in `src/preset.nim:202-205` rather than in the range authority, because nothing in the
descriptor table presents them.

The tunable inventory SHALL be closed: exactly one descriptor per id, over a fixed id set. Bounds
that originate in another module are aliased rather than copied. The particle and species ceilings
come from `memory_layout` (`src/config_ranges.nim:30`, `:34`), and the bodies bounds from `body_core`
(`src/config_ranges.nim:484-528`). The substep count has no descriptor and no user-facing bound: the
integrator derives it (`coupling-contract`, "The integrator owns the substep count"). The field has
no visual control and so no colormap or field-opacity bound.

Enforced by: `tests/test_param_descriptor.nim` suite "Descriptors Agree With The Range Authority",
which pins each descriptor bound to its `config_ranges` constant, and suite "Descriptor Table Covers
The Full Tunable Inventory", which pins the id set, without `sphSubsteps` or `fieldOpacity`, and
rejects duplicates (test-held). `src/preset.nim:208-210` asserts statically that the preset array
sizing and the species ceiling agree (build-asserted).

#### Scenario: A bound changes in the authority

- **WHEN** a constant in `config_ranges.nim` changes
- **THEN** the slider range, the preset clamp bound, and the value the control panel is served all
  change with it, because each reads that constant rather than a copy

#### Scenario: A descriptor bound stops matching its constant

- **WHEN** a descriptor is edited to carry a literal bound instead of its `config_ranges` constant
- **THEN** `just test` fails at the descriptor-to-authority comparison naming that parameter

#### Scenario: A substep slider returns

- **WHEN** a descriptor with the id `sphSubsteps` is added
- **THEN** `just test` fails at the id-set check

### Requirement: Ranges are non-empty and defaults lie inside them

Every range MUST satisfy `MIN < MAX`, and every default MUST lie within the range it is the default
of. An inverted range makes clamping invert; an out-of-range default ships a control whose opening
position it cannot reach.

Both properties are enforced twice, at different strengths. Static assertions in the static block of
`src/config_ranges.nim` reject an inverted range at compile time for every range that block names.
They also reject an out-of-range default for every default that originates in a reference-oracle
module (`field_core`, `bloom_core`), and for the bodies defaults. Every range, statically asserted or not, is also covered natively by
`tests/test_param_descriptor.nim` suite "Every Descriptor Is Internally Coherent", which checks
non-emptiness and default-in-range for every descriptor.

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
measurement and the bound. This holds for each coupling's full effect `F_c`, which records the
measurement that set it (`coupling-contract`, "A strength of 1 is a coupling's calibrated full
effect"). It holds for the deposit's full effect in particular, which SHALL sit below the field's
flood point. Beside it stand the flood point, the feed/kill coordinates it was taken at, and the
weakest-corner margin (`src/config_ranges.nim:280-287`). And it holds for the stiffness ceiling's
coefficient (`sph-scale`).

Where the measurement can be re-executed, a native test SHALL assert the bound against it rather than
leaving the comment as the only record. The deposit's full effect has such a test:
`tests/test_field_core.nim` suite "Reaction-Diffusion Ignition" (`:767-785`) sweeps all four feed/kill
corners at deposit strength 1 and asserts the field stays finite and bounded. It states in its own
text that a failure lowers the bound rather than the assertion.

This requirement is **agent-checkable** for the recording itself. No mechanism rejects a new bound
that arrives without a comment. The procedure: read the diff for every measured constant in
`src/config_ranges.nim` and its `*_core.nim` sources, and confirm the comment beside it names the
value, the conditions and the margin. A full effect still marked provisional carries the note
`coupling-contract` requires in their place.

#### Scenario: A measured ceiling is raised

- **WHEN** the deposit's gain at strength 1 is raised past the point where the weakest feed/kill
  corner floods
- **THEN** `just test` fails at the deposit sweep

#### Scenario: A new measured bound is added

- **WHEN** a bound is introduced whose value comes from a stability measurement
- **THEN** review requires the measured value, its conditions, and the margin to appear beside the
  constant

### Requirement: Defaults come from the typed state records

The descriptor table SHALL take every default from the authority that already holds it, never from a
literal: simulation defaults from `initSimulationState()`, render defaults from `initRenderState()`,
and the two palette defaults from `palette.nim`'s `DEFAULT_SATURATION` / `DEFAULT_LIGHTNESS`
(`src/ui/api/param_descriptor.nim:413-414`, `:544-547`). Those state records in turn draw the
reaction-diffusion and bloom defaults from the reference-oracle modules
(`src/ui/state/simulation_state.nim:170-173`, `src/ui/state/render_state.nim:87-92`), so one value
serves as the simulation's starting state, the slider's reset target, and the preset schema's
fallback. The render state carries no field-visualization default, because the field has no visual
control.

Enforced by: `tests/test_param_descriptor.nim` suite "Descriptors Agree With The Default Authority",
which compares every descriptor default against the state record field it must equal (test-held).

#### Scenario: A default changes in the state record

- **WHEN** a field default in `initSimulationState` or `initRenderState` changes
- **THEN** the descriptor default the control panel is served changes with it, with no second edit

#### Scenario: A descriptor default is hardcoded

- **WHEN** a descriptor is given a literal default that differs from its state record
- **THEN** `just test` fails at the default-authority comparison

### Requirement: The crowding and scale ranges

`src/config_ranges.nim` SHALL define these tunables' bounds under the standard static non-emptiness
and default-in-range assertions:

- **Crowding strength.** The range SHALL include zero, and zero SHALL be an ordinary reachable
  slider position, because strength zero is exactly the uncrowded force law and keeping it reachable
  is what makes the term bisectable. Zero is a labelled notch, and a static assertion pins
  `CROWDING_STRENGTH_MIN` at zero. Crowding is a texture control on the species force and bounds no
  compression (`bounded-crowding`; the world pressure bounds it, `world-pressure`). So
  `CROWDING_STRENGTH_MAX` answers only to how far crowding softens colonies. It is a working bound
  rather than a measured one, marked as such beside the constant and pending the in-app calibration
  the measured-bound rule requires.
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

Enforced by: the static block of `src/config_ranges.nim`, which asserts `CROWDING_STRENGTH_MIN == 0`,
`SPH_RADIUS_FRACTION_MIN > 0` and `SPH_RADIUS_FRACTION_MAX == 1` (`:567-568`, `:649-658`)
(build-asserted). That `CROWDING_STRENGTH_MAX` is too high or too low for the softening is
**unenforced** until the calibration `bounded-crowding` names records its conditions beside it.

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
would silently rescale every saved preset each time the coefficient is refitted).

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
whose function and measurement belong to the SPH capability. No ceiling SHALL take the substep count
as an input. The integrator derives that count, and the fluid declares the count its live stiffness
needs (`coupling-contract`, "The integrator owns the substep count"). The stiffness ceiling is
therefore the stiffness the fluid holds at `SUBSTEPS_MAX`, and its deriving inputs are the
interaction radius, the radius fraction and the time scale. The effect-time clamp above is the one
the integrator applies when the fluid's request passes `SUBSTEPS_MAX`.

A limit of the integrator SHALL NOT enter a range as a derived floor. The body band's floor SHALL NOT
read `MAX_VELOCITY_MAX`, its mirror `BODY_PARTICLE_SPEED_CEILING`, the frame cap or the time-scale
ceiling (`src/body_core.nim:136-148`, `:184-193`). The band is a length the bodies' declaration
states it resolves, and the integrator's travel bound holds a particle inside it by raising the
substep count (`coupling-contract`, "No coupling's range reads another coupling's ceiling"). The
floor SHALL stay strictly positive (`src/config_ranges.nim:582`); its value SHALL be the stated
25.0 every saved band was clamped against, so no preset moves. When the travel count passes `SUBSTEPS_MAX`, the effect-time clamp SHALL lower the effective Max
Velocity to the speed that `SUBSTEPS_MAX` substeps hold inside the travel bound; the stored Max
Velocity and its handle stay where the user set them (`coupling-contract`, "The integrator owns the
substep count").

Enforced by: `tests/test_param_descriptor.nim`, suite `A Derived Bound Cites A Registered Ceiling`.
Every `bDerived` descriptor evaluates to a positive ceiling at or below its declared maximum over every
corner of the input box, which has no substep axis, and carries a written reason. `minimumCeiling` is
checked to be the corner it claims. Every notch of a `bDerived` parameter sits below that minimum. A
fluid that cannot hold the stored stiffness is asserted to run at the ceiling with the stored value
intact (test-held). `tests/test_body_core.nim` suite "An Enclosing Body Cannot Be Tunnelled" holds
that a particle at the live Max Velocity lands inside a band at its floor on the substep that carries
it across, at the substep count the integrator's function returns (test-held). That the band floor's
expression names no velocity, frame or time-scale constant is **unenforced**, closed by the lint
`coupling-contract` names.

#### Scenario: An input to the ceiling moves

- **WHEN** a parameter that a derived ceiling reads changes
- **THEN** the effective value recomputes at the CONFIG mirror in the same tick, the stored value is
  untouched, and restoring the input restores the stored value's full effect

#### Scenario: The stored value outlives the ceiling

- **WHEN** a stored value sits above the live ceiling
- **THEN** the simulation runs at the ceiling, the slider shows the excess as dormant with the
  reason, and no write path rewrites the stored value

#### Scenario: A preset lands in a weak fluid

- **WHEN** a preset carries a stiffness above what its own interaction radius, radius fraction and
  time scale support at `SUBSTEPS_MAX`
- **THEN** the stored stiffness applies intact and the effective stiffness is the derived ceiling —
  the preset round-trips unchanged

#### Scenario: A notch strands in the dormant region

- **WHEN** a `bDerived` parameter's notch value exceeds the minimum ceiling over its input box
- **THEN** the notch sweep fails natively rather than shipping a label the fluid cannot honour

#### Scenario: Raising the speed ceiling leaves the band floor alone

- **WHEN** `MAX_VELOCITY_MAX` rises
- **THEN** `BODY_BAND_MIN` is unchanged, and the substep count at the live Max Velocity rises instead

### Requirement: A range or step changed for legibility records the measurement that justified it

Every range bound or precision changed in response to a legibility metric SHALL carry, beside the
constant, the metric that failed and the measured values before and after.

The range authority already documents several bounds this way. The deposit's full effect records the
flood point it sits below and the corner it was measured at, and every coupling's full effect records
the measurement that set it (`coupling-contract`). This extends that practice from the bounds that
happened to get it to all of them.

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
