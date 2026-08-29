# field-scale

## Purpose

Owns how big the chemical pattern draws and how it reaches the eye: the single shrink knob the field
grid derives from, the square-cell aspect that knob must preserve, the field-force constants that
divide by it, the migration that rescales a saved field force written against another grid, and the
decision to light the particles instead of drawing a backdrop. One capability because every one of
those numbers is a consequence of the cell's size in world units — moving the knob moves all of
them, and the tests that catch a drift relate them directly.

The Gray-Scott reaction itself, its regime table and its ignition thresholds live in cell space and
are untouched by the knob. Per-species secretion and tropism belong to `species-chemistry`. Ranges
and defaults belong to `parameter-range-authority`. This spec cites those relations and leaves their
detail to them.

## Requirements

### Requirement: One knob sets how big the pattern draws

The field's on-screen scale SHALL be governed by a single constant, `FIELD_PATTERN_SHRINK`
(`src/field_core.nim:32`), from which the field grid and every constant whose meaning depends on the
cell size are derived. It reads as a multiple of the 512-cell square field it replaced: at 1 a spot
draws the width it drew there, at 4 a quarter of it.

`FIELD_W` and `FIELD_H` SHALL be `512 * shrink` and `288 * shrink` (`src/field_core.nim:42,45`). That
ratio is the world's 16:9, so a field cell is SQUARE in world units at every setting.

Enforced by: `tests/test_field_core.nim`, suite "The Field Draws A Small Pattern On Square Cells"
(`:1402-1496`).

#### Scenario: Turning the knob moves the pattern

- **WHEN** `FIELD_PATTERN_SHRINK` changes
- **THEN** the pattern's diameter in world units changes by exactly that factor, in both directions

#### Scenario: Cells stay square at every setting

- **WHEN** the shrink takes any value
- **THEN** a field cell covers the same world extent horizontally and vertically

### Requirement: Field cells are square in world units

The field grid's aspect SHALL match the world's. `field-deposit.wgsl` maps the whole world rect onto
`FIELD_W x FIELD_H`, and the 9-point Laplacian is isotropic in CELLS, so any mismatch between the two
aspects stretches every pattern the field draws by exactly that mismatch.

Because `field_core` is pure and cannot import `config.nim`, the world's aspect is stated as
`FIELD_WORLD_ASPECT` (`src/field_core.nim:27`) and held against the grid by a compile-time assertion
(`src/field_core.nim:260-264`). The native suite reads `src/config.nim` from source to check that
`WORLD_W / WORLD_H` still equals that constant (`tests/test_field_core.nim:1421-1444`).

#### Scenario: The world is resized without the field

- **WHEN** `WORLD_W` or `WORLD_H` changes so their ratio no longer equals `FIELD_WORLD_ASPECT`
- **THEN** the native suite fails, instead of the stretch reappearing silently in the rendered
  pattern

#### Scenario: The grid is resized off the world's aspect

- **WHEN** `FIELD_W` or `FIELD_H` moves so their ratio no longer equals `FIELD_WORLD_ASPECT`
- **THEN** the compile-time assertion in `src/field_core.nim` fails the build

### Requirement: Pattern scale changes the cell, never the chemistry

The diffusion rates SHALL NOT be used to tune pattern size. Gray-Scott's wavelength scales as
`sqrt(diffusion)` in cells, which makes them look like a size knob, but Pearson's (F, k) phase map —
which `RD_REGIMES` cites, which the feed and kill slider ranges are drawn against, and which every
named regime is a coordinate in — is drawn at the shipped rates. Moving them moves the map
underneath the table.

Every ignition threshold, regime coordinate and collapse bound in `src/field_core.nim` is measured in
cell space and holds only while the diffusion rates hold. Shrinking the cell is what changes what the
eye sees while leaving all of them valid.

Enforced by: `tests/test_field_core.nim:1465-1495`, which pins `RD_DIFFUSION_A`, `RD_DIFFUSION_B`,
their ratio, the pattern diameter in cells, and the explicit-Euler stability line the activator sits
on; the ignition, regime-floor and collapse suites read those same constants.

#### Scenario: The diffusion rates are lowered to shrink the pattern

- **WHEN** the activator and inhibitor rates are scaled down together
- **THEN** the named regimes stop settling into their own morphologies, scattered deposits ignite
  where coherence was required, and the chemotactic collapse the safety bound is measured against
  stops reproducing — each caught by an existing native test

### Requirement: The field force divides by the knob the grid multiplies by

`RD_DEFAULT_FIELD_FORCE` (`src/field_core.nim:157`) and `RD_FIELD_FORCE_MAX`
(`src/config_ranges.nim:226`, derived from the default) SHALL be derived by dividing by
`FIELD_PATTERN_SHRINK`.

`field-force.wgsl` takes a gradient measured PER CELL and writes an impulse in WORLD units. Holding
the scale fixed while the cell shrinks therefore leaves a particle moving the same distance per frame
across a pattern that has itself become smaller, so its response to a feature strengthens by exactly
the shrink. What holds a particle's behaviour fixed is the product `gradient * scale * FIELD_W /
worldWidth`, not the scale alone.

The native chemotaxis harness SHALL derive its world geometry from `FIELD_W` for the same reason, so
that a change to the grid reaches the collapse measurements instead of passing them by. Enforced by
`tests/test_field_core.nim:1455-1464`.

#### Scenario: The shrink changes without the force

- **WHEN** the grid is made finer and the field force constants are left alone
- **THEN** particles cross the pattern faster than they did, and the harness measurements move with
  them

### Requirement: A legacy field force is rescaled, not clamped

A preset written against an earlier field grid SHALL have its `rdFieldForce` multiplied by
`V1_FIELD_FORCE_SCALE` during migration (`src/preset.nim:558-567`, applied at `:617-628`), so it
restores the world it was saved from.

The value only means what it meant while the cell covered what it covered. Carried over verbatim it
would clamp to the current maximum and land stronger than the world it describes — a silent rewrite
of a saved world instead of a refusal.

`V1_FIELD_FORCE_SCALE` is `1 / FIELD_PATTERN_SHRINK`, mirrored as a literal for the same
dependency-restriction reason `MAX_SPECIES` is one, and checked against `field_core`'s own constant
by the native suite. Enforced by `tests/test_preset.nim:440-448`.

#### Scenario: A schema-version-1 preset at the earlier default

- **WHEN** a preset written under schema version 1 carrying the earlier default field force is
  loaded
- **THEN** its field force arrives scaled to the value that produces the same motion through the
  pattern, never clamped to the current ceiling

### Requirement: The field shows itself through the particles by default

`FIELD_OPACITY_DEFAULT` SHALL be zero (`src/colormap_core.nim:43`, reaching the render state at
`src/ui/state/render_state.nim:88`), and `render.wgsl`'s particle tint SHALL NOT read `fieldOpacity`
(`web/shaders/src/render.wgsl:171-194`).

`fieldOpacity` scales the field as a BACKDROP — the fullscreen layer `field-composite.wgsl` and the
tonemap draw under everything. Drawn that way the pattern owns whole regions of the frame, and
colonies, trails and species colour compete with it for the same pixels. Lighting the particles says
the same thing — where the chemistry is, and how strong — without claiming any space of its own.

The tint needs no gate of its own: the pull is already proportional to local field intensity, and the
field clears to Gray-Scott's trivial fixed point, so a particle standing where no pattern is keeps
its species colour exactly.

The backdrop SHALL remain reachable as a slider (`fieldOpacity`, `src/ui/api/param_descriptor.nim:676-677`).
It is the only way to see the field where no particles stand, which is what makes it worth keeping
and worth leaving off.

The default and the range are native-tested (`src/config_ranges.nim:559-560`;
`tests/test_param_descriptor.nim`, suite "Descriptors Agree With The Default Authority").
**agent-checkable** for what appears on screen, because the render passes carry no native test. The
procedure: launch the app, raise the deposit until a pattern forms with `fieldOpacity` at zero, and
read that particles standing in the pattern take its colour while the space between them stays
background. Then raise `fieldOpacity` and read that a fullscreen layer appears under the particles.
A violation shows as an unlit particle field, or as a backdrop drawn at zero opacity.

#### Scenario: The backdrop is turned off

- **WHEN** `fieldOpacity` is zero
- **THEN** no fullscreen field layer is drawn, and particles standing in the pattern are still
  tinted by it

#### Scenario: A particle stands where no pattern is

- **WHEN** the field at a particle's cell sits at the trivial fixed point
- **THEN** that particle renders in its species colour, unmodified

### Requirement: The deposit ceiling is what bounds chemotactic collapse

The safety claim for particle-field chemotaxis SHALL be stated on the deposit axis, because that is
the axis the measurement brackets.

Collapse occupies a MIDDLE BAND of tropism: at zero there is no aggregation to run away, and at high
values particles overshoot the well and scatter instead of pooling. The band widens downward as the
deposit rises, so it reaches the shipped tropism bound before the bound could sit below it. No bound
on tropism alone can carry this.

Enforced by: `RD_DEPOSIT_MAX` (`src/config_ranges.nim:215`), set well below the flood point of the
measured deposit band recorded at `src/field_core.nim:150-156`;
`tests/test_field_core.nim`, suite "Chemotactic Collapse Bound" (`:975-1176`), whose runs report a
worst reachable per-cell concentration well under the collapse threshold, locate divergence only at
(10x, 15x] of `RD_DEPOSIT_MAX`, and separate it from flooding with a frozen-population control.

#### Scenario: Inside the reachable deposit range

- **WHEN** the deposit sits anywhere the slider allows and the field force at its maximum
- **THEN** the field stays finite at every tropism, including far above the shipped bound

#### Scenario: Far outside the reachable deposit range

- **WHEN** the deposit is raised well past its ceiling
- **THEN** some tropism settings diverge the field while a frozen population at the same deposit
  does not, which is what makes the divergence chemotactic and not a flood
