## RENAMED Requirements

- FROM: `### Requirement: The fraction ships at the whole interaction radius`
- TO: `### Requirement: The fluid's shipped character follows a measurement of each flattening effect`

## MODIFIED Requirements

### Requirement: The stiffness ceiling derives from the fluid's configuration

The stiffness the fluid honours SHALL be bounded by a pure function in `src/sph_core.nim`
(`stableStiffnessCeiling`, `:153-176`). Its inputs are the smoothing radius in pixels (the fraction
times the interaction radius, multiplied by the caller the way `forces-sph.wgsl:115` does), a substep
count, and the effective timestep. The measured law is `SPH_STABILITY_COEFFICIENT * h * substeps / dt`,
linear in each factor and not the Courant square; `src/sph_core.nim:135-143` records why this
integrator sheds both of the textbook's `1/h` factors. The ceiling is clamped against
`SPH_STIFFNESS_MAX`, which survives only as the absolute envelope and reaches the function as an
argument, because the range authority imports this module and hands its own constant to the function
it bounds. The ceiling bounds the value's effect and never redefines the stored value, which stays
absolute stiffness — the pressure gain (`taitPressure` and `flooredTaitPressure`,
`src/sph_core.nim:94-113`).

The substep count is not a user input. The integrator owns it (`coupling-contract`, "The integrator
owns the substep count"). The fluid's declaration SHALL state the substep count its live stiffness
needs: the smallest count at which the law holds the effective stored stiffness at the live smoothing
radius and the frame's timestep. That count SHALL read the delivered frame's timestep, which stability
answers to, so a long frame raises the count for that frame only. The served ceiling SHALL be the
law evaluated at `SUBSTEPS_MAX`, so its deriving inputs are the interaction radius, the radius
fraction and the time scale. When the stored stiffness asks for more than `SUBSTEPS_MAX`, the frame
runs `SUBSTEPS_MAX` and the effect-time clamp lowers the effective stiffness to that ceiling
(`parameter-range-authority`, "A bound may derive from other parameters"). The stored value, the
slider handle and the preset keep the stiffness the user set.

The served ceiling reads its timestep against a fixed reference frame
(`SPH_CEILING_REFERENCE_FRAME_SECONDS`, `src/sph_core.nim:144-151`), because a ceiling built from the
delivered frame would move every frame and shrink during a hitch.

The stability coefficient SHALL be fitted from a measured stability sweep of this integrator —
stiffness against radius fraction and substeps — never assumed from literature, and the
measurement's conditions and margin SHALL be recorded beside the coefficient under the range
authority's measured-bound rule. The sweep keeps its substep axis from 1 to `SUBSTEPS_MAX`, because
the integrator runs any count in that span for reasons of its own. The ceiling's dormant-region reason,
the Stiffness hint and the fluid help line SHALL name the ceiling's inputs, the interaction radius, the
radius fraction and the time scale, and SHALL NOT name a substep control.

Enforced by: `tests/test_sph_core.nim` suites "The Fluid Has A Measured Stability Boundary" and "The
Derived Stiffness Ceiling Holds Under The Measurement" (`:626-816`). They hold the derived ceiling
below the measured stability boundary across the reachable input box, substeps included, so re-running
the suite re-checks the fit (test-held). A suite in `tests/test_sph_core.nim` holds the fluid's
declared count at every corner of the box: it is the smallest count whose ceiling holds the stiffness,
and at that count the harness comes to rest (test-held). `tests/test_sim_registry.nim` suite
"Substeps Follow The Tightest Coupling" holds the cap and the effect-time clamp (test-held). That
the reason, the hint and `docs/help/30-fluid.md` name the three inputs and no substep control is
**agent-checkable**: read the three strings against the ceiling's input list.

#### Scenario: Shrinking the radius lowers the ceiling

- **WHEN** the radius fraction falls with the time scale held fixed
- **THEN** the served stiffness ceiling falls, linearly in the fraction — the measured law,
  recorded beside `SPH_STABILITY_COEFFICIENT` in `src/sph_core.nim`

#### Scenario: More substeps buy more stiffness

- **WHEN** the integrator runs more substeps with the fraction and the timestep held fixed
- **THEN** the law's ceiling rises, linearly in the substep count, under the same measured law, which
  is what the fluid's declared count spends

#### Scenario: A stiffer fluid asks for more substeps

- **WHEN** the stored stiffness rises with the fraction, the interaction radius and the timestep held
  fixed
- **THEN** the fluid's declared substep count never falls, and it rises at each stiffness the law at
  the current count can no longer hold

#### Scenario: A stiffness past the cap lowers the effect, not the stored value

- **WHEN** the stored stiffness needs more than `SUBSTEPS_MAX` substeps at the live radius and
  timestep
- **THEN** the frame runs `SUBSTEPS_MAX` substeps, the fluid runs at the ceiling the law gives at
  `SUBSTEPS_MAX`, and the stored stiffness is unchanged

#### Scenario: The ceiling cannot exceed the envelope

- **WHEN** the deriving inputs take any reachable combination
- **THEN** the derived ceiling is at most `SPH_STIFFNESS_MAX`, asserted by a native sweep over the
  whole input box, and the worst-case ceiling is recorded beside the radius-fraction floor that
  decides it (`src/config_ranges.nim:215-245`) — the floor every labelled stiffness notch must sit
  below, held by the notch sweep in `tests/test_param_descriptor.nim` (suite "Notches Mark Only
  Reachable Positions"), which goes red on the first notch that strands

### Requirement: The fluid's shipped character follows a measurement of each flattening effect

Three effects can flatten a world's species structure under the fluid, and each SHALL be measured one
term at a time before any fluid default that answers to it ships:
- **Velocity smoothing at Viscosity 0.** The velocity blend carries `SPH_XSPH_EPSILON`
  (`src/sph_core.nim:30-33`) beside the viscosity (`web/shaders/src/forces-sph.wgsl:262`), so
  neighbours' velocities are averaged at every viscosity setting, 0 included. The arm compares the
  blend at `SPH_XSPH_EPSILON` against the blend at 0, with Viscosity at 0.
- **Pressure evening out density.** The arm compares the fluid with its pressure term against the same
  fluid with the pressure term's gain at 0 and the velocity blend unchanged.
- **A kernel spanning the whole interaction radius.** The arm compares the radius fraction at 1
  against fractions stepped down to `SPH_RADIUS_FRACTION_MIN`.

Each arm SHALL run over a world whose species force sits at its shipped default, with the fluid at
strength 1, the world pressure acting (`world-pressure`, the pressure as limited by the particle's own
step limit, not the explicit push — the arms wait on that limit landing) and crowding strength at 0. So the result is
a property of the fluid atop the world's own resistance to compression. Each arm SHALL report two
readings against the same world with the fluid at 0: how much species structure survives, and how
even the crowd density becomes. Structure survival SHALL be `σ = (S_arm − 1/n_s) / (S_0 − 1/n_s)`, where `S` is
the mean share of a particle's neighbours of its own species and `n_s` the species count. Evenness
SHALL be the coefficient of variation of crowd density on the arm over that of the fluid-0 world. Constants SHALL be read on
the gate seeds `world-pressure` uses, at 128 000 particles. A step passes when its three-seed mean σ
is not lower than the mean σ it is compared with.

The result gates the defaults. `SPH_XSPH_EPSILON`, and whether any velocity smoothing acts at
Viscosity 0, answer to the first arm. The radius-fraction default answers to the third. The second
arm gates the `sphStiffness` default, the knob that scales that term; its reading is recorded beside
`SPH_FORCE_SCALE`. Each such constant SHALL carry, beside it, the arm that
set it, its conditions and its reading. Until its arm is recorded, it SHALL carry a provisional note, as
`LONG_RANGE_STRENGTH_MAX` does (`src/config_ranges.nim:68-75`). The Viscosity help line SHALL state
whether velocity smoothing acts at Viscosity 0.

`SPH_RADIUS_FRACTION_MIN = 0.1` is a working bound, and states so beside itself
(`src/config_ranges.nim:215-245`). It is strictly positive because a zero smoothing radius divides by
zero in both kernel normalizations. The value 0.1 is the smallest kernel the slider offers, chosen to
leave room below the default while staying clear of that singularity. The record beside it carries
two measurements bearing on raising it: the linear stiffness-ceiling law, and the inert region below
a smoothing radius of about 2.5 px, where both kernels see no neighbour at any separation. The third
arm reads the fraction down to this floor, so its record also says whether the floor still computes
a fluid.

No saved world is rescaled by a change to the default. The fraction is carried in the preset schema
and clamped on decode like every schema field (`src/preset.nim:459-461`), and the v1 branch of the
versioned decode pins it to exactly `1.0` (`src/preset.nim:722`), because 1.0 is the kernel those
worlds ran when they were saved.

Enforced by: the arms' constants are **unenforced** until the arms run. A recipe outside `just
check`, run with the task that records them, closes that. The `just calibrate-fluid` recipe runs them on the native binned oracle world, which
steps the species force and a fluid mirrored from `src/sph_core.nim` together. That a constant still carries its provisional note is **agent-checkable**: read the comments
beside `SPH_XSPH_EPSILON`, `SPH_FORCE_SCALE` and the fraction default. That a recorded default
reads as intended in play is **agent-checkable**. An agent runs `./main --serve`, sets the fluid to 1
over a settled world at the shipped species defaults, steps the arm's control across its values, and
compares the species structure against the fluid at 0. The preset parts are held by
`tests/test_preset.nim` suites "Preset Clamp Behavior Contract" and "A Legacy Preset Loads As The
World It Described" (test-held).

#### Scenario: A default ships ahead of its arm

- **WHEN** `SPH_XSPH_EPSILON` or the radius-fraction default changes and the record beside it names no
  arm, conditions or reading
- **THEN** review rejects the change under the measured-bound rule

#### Scenario: Each effect is read alone

- **WHEN** an arm runs
- **THEN** exactly one of the three terms differs between its two sides, and every other fluid,
  species and world setting is the same

#### Scenario: A saved fluid world is reproducible

- **WHEN** a preset carrying a fraction is applied
- **THEN** the fraction it carries is restored and clamped like every schema field, so the world's
  fluid scale survives the round trip

#### Scenario: A schema-version-1 fluid world keeps its kernel

- **WHEN** a preset written under schema version 1 is applied
- **THEN** the fraction decodes to exactly `1.0`, never to the shipped default, so the world looks
  as it did when it was saved
