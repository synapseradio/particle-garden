## ADDED Requirements

### Requirement: Pattern Scale sets how big the pattern draws, through the chemistry

A live Pattern Scale control (`rdPatternScale`, group `rd`) SHALL set how big the reaction-diffusion
pattern draws. At scale `s`, the frame SHALL write the activator and inhibitor diffusion rates as
`RD_DIFFUSION_A · s` and `RD_DIFFUSION_B · s`, so their ratio stays exactly `0.5` at every setting.
Both rates are per-frame uniforms (`src/webgpu_compute.nim:1053-1054`), so a change reaches the next
frame's field steps with no pipeline rebuild. The mean spot diameter SHALL follow `√s`:
`patternDiameterCells(RD_DIFFUSION_A · s)` field cells (`src/field_core.nim:248-252`), which is
`patternDiameterWorld` world units at the field's fixed grid (`src/field_core.nim:254-258`).

The control SHALL only shrink the pattern. Its ceiling SHALL be 1, the base rates, because the
activator already runs on the explicit-Euler stability line at scale 1 (`RD_DIFFUSION_A · RD_DELTA_T
== 1`, `src/field_core.nim:88-94`). A scale above 1 would carry the activator past that line. Its
floor SHALL be the larger of two scales:
- the scale at which `patternDiameterCells` reaches `RD_MIN_RESOLVED_DIAMETER_CELLS`
  (`src/field_core.nim:240-246`). Below scale 0.16 the √D law stops holding and the pattern dies
  rather than shrinking (`src/field_core.nim:232-246`); 4.0 cells sits above that cliff.
- the regime floor that "The pattern-scale band is measured before its constants are set" finds

The default SHALL be the band's floor: the smallest scale at which every regime still holds.

The field's resolution SHALL stay `FIELD_W × FIELD_H = 2048 × 1152` (`src/field_core.nim:42,45`, at
`FIELD_PATTERN_SHRINK = 4`), and no control SHALL change it. `FIELD_PATTERN_SHRINK` is the
resolution's multiple of a 512-cell field and not a pattern-size control.

The descriptor SHALL carry a closed-form probe over `patternDiameterWorld`, and no dormancy predicate,
because the scale moves the chemistry, ignition included, while the field is dark. Its help line SHALL
stand in `docs/help/40-rd.md`. A preset written before the control existed SHALL decode at scale 1, the
scale every earlier world ran at.

Enforced by:
- static assertions in `src/config_ranges.nim` (build-asserted): the ceiling is 1; `RD_DIFFUSION_A ·
  ceiling · RD_DELTA_T ≤ 1`; `patternDiameterCells(RD_DIFFUSION_A · floor) ≥
  RD_MIN_RESOLVED_DIAMETER_CELLS`; the default lies in range.
- a pure function in `src/field_core.nim` that returns both rates at a scale.
  `tests/test_field_core.nim`, suite "The Field Draws A Small Pattern On Square Cells", holds its
  ratio at exactly 0.5 at every scale step. It holds the diameter at each step at
  `patternDiameterCells(RD_DIFFUSION_A · s)` (test-held).
- `tests/test_response_probe.nim` probe coverage and `tests/test_help_content.nim` over the
  descriptor table (test-held).
- `tests/test_preset.nim` decodes a previous-version preset and reads scale 1 (test-held).

That `src/webgpu_compute.nim` writes the function's rates is **unenforced**, the standing condition of
the executor. That the pattern redraws at the new size is **agent-checkable**. With the field ignited
and scent at 1, an agent drags Pattern Scale from 1 to the floor. It reads that the spacing of the
particle clusters the scent force gathers shrinks over the following seconds, and that nothing
diverges or blanks.

#### Scenario: Halving the scale shrinks the pattern by √2

- **WHEN** Pattern Scale moves from 1 to 0.5
- **THEN** both diffusion rates halve, their ratio stays 0.5, and the mean spot diameter falls from
  9.30 to about 6.58 field cells

#### Scenario: The control cannot enlarge the pattern

- **WHEN** a preset or a gesture asks for a scale above 1
- **THEN** the value clamps to 1, and the activator stays on or inside its stability line

#### Scenario: The control cannot kill the pattern

- **WHEN** the slider sits at its floor
- **THEN** the spot diameter is at least `RD_MIN_RESOLVED_DIAMETER_CELLS`, and every named regime
  still settles into its own morphology

#### Scenario: An old world keeps its pattern size

- **WHEN** a preset written before the control existed is applied
- **THEN** it decodes at Pattern Scale 1

### Requirement: The pattern-scale band is measured before its constants are set

Every field constant that holds only while the diffusion rates hold SHALL be measured across the
band before it ships. The measurement runs in the `tests/test_field_core.nim` harness, at the scale
steps 1, 0.5, 0.25 and the floor, the steps the diameter sweep measured (`src/field_core.nim:235-239`). At each scale step it measures:
- the regimes' distance to their own attractor. Each named regime, at that step's coordinates and
  deposit floor, SHALL settle nearer its own unforced attractor than any other regime's, under the
  statistic of suite "The Regime Deposit Floor Preserves The Regime". The statistic SHALL still
  separate the regimes from each other at that step.
- deposit ignition. Worms and Coral SHALL ignite at their deposit floor within the ignition budget,
  and SHALL NOT ignite below it. The floor is the smallest deposit that ignites, per
  `RD_REGIME_HIGH_FEED_DEPOSIT`'s rule (`src/config_ranges.nim:305-319`).
- the splat radius. `RD_DEPOSIT_SPLAT_RADIUS` SHALL ignite at the default deposit, and a single-cell
  deposit SHALL NOT ignite at any deposit up to `RD_DEPOSIT_MAX`
  (`src/field_core.nim:289-313`).
- the per-cell deposit cap. A block of cells taking `RD_DEPOSIT_CELL_MAX` every frame for 400 frames,
  across the feed and kill samples, SHALL stay finite. The cap SHALL be at most half the largest
  measured stable cap at that step (`src/field_core.nim:327-354`).
- the scent gain's strength-1 impulse, recorded per step (see "Scent answers in the pair unit at every
  pattern scale").
- the collapse bracket (`species-chemistry`, "Up-gradient feedback stays bounded").

The floor SHALL be the smallest scale at which every regime still settles nearer its own attractor
than any other. Where a regime's coordinates or deposit floor drift across the band, `RD_REGIMES`
SHALL hold one row per scale step for that regime. A regime selection SHALL apply the row for the
step nearest the live scale. The splat radius and the cell cap SHALL each stay one constant
where one value passes at every step. A constant that passes at no single value SHALL follow the
scale as a per-frame value.

Enforced by: `tests/test_field_core.nim` suites "The Regime Deposit Floor Preserves The Regime",
"Ignition From Coherent Deposits", "A Cell's Per-Frame Deposit Is Bounded" and "Chemotactic Collapse
Bound", each run at every scale step (test-held). The static assertions over `RD_REGIMES`
(`src/config_ranges.nim:677-683`) range over every row, so each row's coordinates and deposit floor
stay inside the slider ranges (build-asserted).

#### Scenario: A regime that distorts at a scale raises the floor

- **WHEN** a named regime at some step settles nearer another regime's attractor than its own
- **THEN** the floor sits above that step, or the regime gains a row for that step whose coordinates
  restore it, and the suite fails until one of the two holds

#### Scenario: A regime coordinate outside the sliders fails the build

- **WHEN** a per-step row places a regime's feed or kill outside its slider's range
- **THEN** the build fails at the assertion

### Requirement: The field reaches particles only as force

The reaction-diffusion field SHALL act on particles only through the scent force (`field-force.wgsl`).
Nothing SHALL draw it:
- no shader that `src/webgpu_render.nim` embeds SHALL declare or sample the field texture, or import
  the `field_grid` module. That covers `render`, `glow`, `fade`, `composite`, `blur`, `tonemap` and
  `overlay` (`src/webgpu_render.nim:239-251`).
- `src/webgpu_render.nim` SHALL NOT obtain a field view.
- a particle's colour SHALL be its species colour, with no tint from the field it stands in.
- the trail SHALL NOT drift along the field gradient.
- no backdrop SHALL be drawn, with bloom on or with bloom off.

`web/shaders/src/field-composite.wgsl`, `web/shaders/modules/colormap.wgsl`,
`src/colormap_core.nim`, `tests/test_colormap_core.nim`, `docs/help/41-rd-field.md` and the `rd-field`
descriptor group SHALL NOT exist. No descriptor, `gardenAPI` accessor or preset field SHALL carry a
colormap index, a field opacity or a field-light strength. The `fieldUnlit` dormancy predicate SHALL
NOT be registered, because no descriptor carries it. The field's readers SHALL be the compute passes
that step, seed, deposit into and resolve it, the scent force, and the alive-cell census that the
dormancy signal reads back.

Enforced by:
- `tests/test_wgsl_lint.nim` suite "No Render Shader Reads The Field" (test-held). It reads the
  shader names `src/webgpu_render.nim` embeds from its `staticRead` lines. It holds that no source of
  those shaders imports `field_grid` or `colormap`, and that none names `fieldTexture`. It holds that
  `src/webgpu_render.nim` names neither `activeFieldView` nor `fieldSampledView`. The check reads
  names, so a field texture bound under another name passes it; which resource Nim places at each
  binding stays **unenforced** beyond this, as `shader-pipeline` records.
- the set equality in suite "The Bundled Shaders Declare Their Registered Bindings"
  (`tests/test_wgsl_lint.nim:136-183`). It fails while `ExpectedShaderBindings` keeps a
  `field-composite` entry, or keeps a field binding for `render`, `fade` or `tonemap`, that the
  bundles no longer declare (test-held).
- `tests/test_help_content.nim`: a help file whose group no descriptor carries fails (test-held).
- `tests/test_dormancy.nim:29-40`: a registered predicate with no carrier fails (test-held).
- the Nim build: a remaining importer of `colormap_core` fails to compile once the module is gone
  (build-asserted).

What appears on screen is **agent-checkable**. With the field ignited, scent at 0, and bloom on and
then off, an agent reads that the space between particles is background, and that every particle
draws its species colour. With scent at 1, it reads that the pattern shows only as motion. A violation
shows as a coloured layer under the particles, particles lit off their species colour, or trails
bending where no particle moves.

#### Scenario: An ignited field with scent off is invisible

- **WHEN** the field is ignited and the scent strength is 0
- **THEN** the frame is the frame the same particles draw with the field dark

#### Scenario: A render shader that samples the field fails the suite

- **WHEN** a shader `src/webgpu_render.nim` embeds imports `field_grid` or names `fieldTexture`
- **THEN** `tests/test_wgsl_lint.nim` fails and names the shader

#### Scenario: A saved colour choice is dropped

- **WHEN** a previous-version preset carrying a colormap index and a field opacity is applied
- **THEN** it applies without error and neither value reaches the world (`coupling-contract`, "A
  saved world converts to the contract, then the clamp decides")

### Requirement: Scent answers in the pair unit at every pattern scale

The scent force SHALL be a coupling under `coupling-contract`. Its strength, `rdFieldForce`, SHALL
range from 0 to 1. Its impulse at strength `s` and the reference configuration SHALL be
`s · F_scent · u0`. Its gain SHALL be derived from `F_scent` and its unit function under "A strength of
1 is a coupling's calibrated full effect", and no gain SHALL be set by hand.

`field-force.wgsl` takes the inhibitor gradient per field cell and writes an impulse in world units
(`web/shaders/src/field-force.wgsl:66-76`). The scent unit function SHALL carry that cell-to-world
conversion as its one declared conversion site (`coupling-contract`, "Every size names its space").
It SHALL take the live pattern scale, because the gradient per cell grows as the pattern shrinks.
`F_scent` SHALL be measured at pattern scale 1. The strength-1 impulse at every band step
SHALL be recorded beside the gain. The gain SHALL follow the live scale so that the strength-1 impulse
stays `F_scent · u0` at every step: a strength means the same push at every pattern size.

The chemotaxis harness SHALL derive its world units per field cell from `FIELD_W` and the world
width the field covers, `WORLD_W` (`src/config.nim:127`). It SHALL take the pattern scale, so a
change to any of them reaches the collapse measurements. The harness derives from `FIELD_W` against a
1920-unit reference width (`tests/test_field_core.nim:338-345`). That is 0.94 units per cell, where the
shipped field covers 1.875. The comment there states 3.75 per cell and a 240-unit harness world
(`:325-326`, `:345`), which is the arithmetic of the 512-cell field.

Enforced by: the gain's static assertion in `src/config_ranges.nim` (build-asserted), and
`tests/test_balance_core.nim` suite "Strength Is A Fraction Of The Full Effect" (test-held), both as
`coupling-contract` states them. `tests/test_balance_core.nim` suite "Every Writer Answers In The Pair
Unit" sweeps the scent oracle across the band steps (test-held).

#### Scenario: Half scent is half the push

- **WHEN** scent runs at strength 0.5 at the reference configuration
- **THEN** its impulse is half its impulse at strength 1

#### Scenario: A smaller pattern stays inside the unit function

- **WHEN** scent runs at strength 1 at the band's floor
- **THEN** the swept impulse does not exceed the scent unit function

## MODIFIED Requirements

### Requirement: A legacy field force is rescaled, not clamped

A preset written against an earlier field grid SHALL have its `rdFieldForce` multiplied by
`V1_FIELD_FORCE_SCALE` during migration (`src/preset.nim:635-644`, applied at `:694-705`). The
value then passes through the contract's scent conversion (`coupling-contract`, "A saved world converts
to the contract, then the clamp decides"). The clamp to 0–1 SHALL apply only after the last conversion,
so it restores the world it was saved from.

The value only means what it meant while the cell covered what it covered. Carried over verbatim it
would clamp to the current maximum and land stronger than the world it describes — a silent rewrite
of a saved world instead of a refusal.

`V1_FIELD_FORCE_SCALE` is `1 / FIELD_PATTERN_SHRINK`, mirrored as a literal for the same
dependency-restriction reason `MAX_SPECIES` is one. Enforced by `tests/test_preset.nim:597-605`,
extended to compare the decoded scent strength with the value the two conversions compose to
(test-held). No test relates `V1_FIELD_FORCE_SCALE` to `field_core`'s own constant, though
`src/preset.nim:641-644` says one does. That relation is **unenforced**. A `tests/test_preset.nim`
check that `V1_FIELD_FORCE_SCALE == 1 / FIELD_PATTERN_SHRINK` would close it.

#### Scenario: A schema-version-1 preset at the earlier default

- **WHEN** a preset written under schema version 1 carrying the earlier default field force is
  loaded
- **THEN** its field force arrives scaled to the value that produces the same motion through the
  pattern, converted to the scent strength, and clamped to 0–1 only after both conversions

### Requirement: The deposit ceiling is what bounds chemotactic collapse

The safety claim for particle-field chemotaxis SHALL be stated on the deposit axis, because that is
the axis the measurement brackets.

Collapse occupies a MIDDLE BAND of tropism: at zero there is no aggregation to run away, and at high
values particles overshoot the well and scatter instead of pooling. The band widens downward as the
deposit rises, so it reaches the shipped tropism bound before the bound could sit below it. No bound
on tropism alone can carry this. The claim SHALL hold at every step of the pattern-scale band, with
scent at strength 1.

Enforced by: `RD_DEPOSIT_MAX` (`src/config_ranges.nim:280`), set well below the flood point of the
measured deposit band recorded at `src/field_core.nim:150-156`;
`tests/test_field_core.nim`, suite "Chemotactic Collapse Bound" (`:970-1171`), run at every
pattern-scale step. Its runs report a worst reachable per-cell concentration well under the collapse
threshold. They locate divergence only above `RD_DEPOSIT_MAX`, in a bracket recorded per step, and
separate it from flooding with a frozen-population control.

#### Scenario: Inside the reachable deposit range

- **WHEN** the deposit sits anywhere the slider allows, scent is at strength 1, and Pattern Scale sits
  at any step of the band
- **THEN** the field stays finite at every tropism, including far above the shipped bound

#### Scenario: Far outside the reachable deposit range

- **WHEN** the deposit is raised well past its ceiling
- **THEN** some tropism settings diverge the field while a frozen population at the same deposit
  does not, which is what makes the divergence chemotactic and not a flood

## REMOVED Requirements

### Requirement: One knob sets how big the pattern draws

**Reason**: Pattern size moves to the chemistry, and the field's resolution stays fixed at 2048 ×
1152. `FIELD_PATTERN_SHRINK` no longer sets how big the pattern draws. It remains only as the fixed
resolution's multiple of a 512-cell field.

**Migration**: "Pattern Scale sets how big the pattern draws, through the chemistry" owns pattern
size. "Field cells are square in world units" keeps the square-cell guarantee the removed scenario
carried.

### Requirement: Pattern scale changes the cell, never the chemistry

**Reason**: The diffusion rates become the pattern-size control. The hazard the requirement guarded
is real: at `Da = 0.25`, a floored regime settled 2.5 times further from its own morphology than
from another's (`src/field_core.nim:72-83`). So the hazard becomes a measured band, with a floor and
per-scale regime rows, rather than a ban.

**Migration**: "The pattern-scale band is measured before its constants are set" holds every regime,
ignition, splat, cap and collapse measurement at each scale step.

### Requirement: The field force divides by the knob the grid multiplies by

**Reason**: Scent moves to the 0–1 contract, and its gain is derived from its measured full effect
rather than from `FIELD_PATTERN_SHRINK`. The cell-to-world conversion is still real. It lives in the
scent unit function as the coupling's one declared conversion site.

**Migration**: `coupling-contract`, "A strength of 1 is a coupling's calibrated full effect", and
"Scent answers in the pair unit at every pattern scale". The harness's derivation from `FIELD_W`
moves into the latter.

### Requirement: The field shows itself through the particles by default

**Reason**: Reaction-diffusion acts on particles as a force only. The particle tint, the trail drift,
the backdrop, the colormap and Field Opacity are removed, so the field is seen only through the motion
it causes.

**Migration**: "The field reaches particles only as force". A saved colormap index and field opacity
are dropped on load (`coupling-contract`, "A saved world converts to the contract, then the clamp
decides").
