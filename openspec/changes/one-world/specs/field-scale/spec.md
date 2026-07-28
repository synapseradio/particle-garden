## ADDED Requirements

### Requirement: One knob sets how big the pattern draws

The field's on-screen scale SHALL be governed by a single constant, `FIELD_PATTERN_SHRINK` in
`src/field_core.nim`, from which the field grid and every constant whose meaning depends on the cell
size are derived. It reads as a multiple of the 512-cell square field it replaced: at 1 a spot draws
the width it drew there, at 4 a quarter of it.

`FIELD_W` and `FIELD_H` SHALL be `512 * shrink` and `288 * shrink`. That ratio is the world's 16:9,
so a field cell is SQUARE in world units at every setting.

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
`FIELD_WORLD_ASPECT` and the native suite reads `src/config.nim` from source to check that the two
still agree.

#### Scenario: The world is resized without the field

- **WHEN** `WORLD_W` or `WORLD_H` changes so their ratio no longer equals `FIELD_WORLD_ASPECT`
- **THEN** the native suite fails, rather than the stretch reappearing silently in the rendered
  pattern

### Requirement: Pattern scale changes the cell, never the chemistry

The diffusion rates SHALL NOT be used to tune pattern size. Gray-Scott's wavelength scales as
`sqrt(diffusion)` in cells, which makes them look like a size knob, but Pearson's (F, k) phase map —
which `RD_REGIMES` cites, which the feed and kill slider ranges are drawn against, and which every
named regime is a coordinate in — is drawn at the shipped rates. Moving them moves the map underneath
the table.

Every ignition threshold, regime coordinate and collapse bound in `src/field_core.nim` is measured in
cell space and holds only while the diffusion rates hold. Shrinking the cell is what changes what the
eye sees while leaving all of them valid.

#### Scenario: The diffusion rates are lowered to shrink the pattern

- **WHEN** the activator and inhibitor rates are scaled down together
- **THEN** the named regimes stop settling into their own morphologies, scattered deposits ignite
  where coherence was required, and the chemotactic collapse the safety bound is measured against
  stops reproducing — each caught by an existing native test

### Requirement: The field force divides by the knob the grid multiplies by

`RD_DEFAULT_FIELD_FORCE` and `RD_FIELD_FORCE_MAX` SHALL be derived by dividing by
`FIELD_PATTERN_SHRINK`.

`field-force.wgsl` takes a gradient measured PER CELL and writes an impulse in WORLD units. Holding
the scale fixed while the cell shrinks therefore leaves a particle moving the same distance per frame
across a pattern that has itself become smaller, so its response to a feature strengthens by exactly
the shrink. What holds a particle's behaviour fixed is the product `gradient * scale * FIELD_W /
worldWidth`, not the scale alone.

The native chemotaxis harness SHALL derive its world geometry from `FIELD_W` for the same reason, so
that a change to the grid reaches the collapse measurements rather than passing them by.

#### Scenario: The shrink changes without the force

- **WHEN** the grid is made finer and the field force constants are left alone
- **THEN** particles cross the pattern faster than they did, and the harness measurements move with
  them

### Requirement: A legacy field force is rescaled, not clamped

A preset written against an earlier field grid SHALL have its `rdFieldForce` multiplied by
`V1_FIELD_FORCE_SCALE` during migration, so it restores the world it was saved from.

The value only means what it meant while the cell covered what it covered. Carried over verbatim it
would clamp to the current maximum and land stronger than the world it describes — a silent rewrite
of a saved world rather than a refusal.

#### Scenario: A v1 preset at the old default

- **WHEN** a v1 preset carrying the old default field force is loaded
- **THEN** its field force arrives scaled to the value that produces the same motion through the
  pattern, not clamped to the current ceiling

### Requirement: The field shows itself through the particles by default

`FIELD_OPACITY_DEFAULT` SHALL be zero, and `render.wgsl`'s particle tint SHALL NOT read
`fieldOpacity`.

`fieldOpacity` scales the field as a BACKDROP — the fullscreen layer `field-composite.wgsl` and the
tonemap draw under everything. Drawn that way the pattern owns whole regions of the frame, and
colonies, trails and species colour compete with it for the same pixels. Lighting the particles says
the same thing — where the chemistry is, and how strong — without claiming any space of its own.

The tint needs no gate of its own: the pull is already proportional to local field intensity, and the
field clears to Gray-Scott's trivial fixed point, so a particle standing where no pattern is keeps
its species colour exactly.

The backdrop SHALL remain reachable as a slider. It is the only way to see the field where no
particles stand, which is what makes it worth keeping and worth leaving off.

#### Scenario: The backdrop is turned off

- **WHEN** `fieldOpacity` is zero
- **THEN** no fullscreen field layer is drawn, and particles standing in the pattern are still tinted
  by it

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

#### Scenario: Inside the reachable deposit range

- **WHEN** the deposit sits anywhere the slider allows and the field force at its maximum
- **THEN** the field stays finite at every tropism, including far above the shipped bound

#### Scenario: Far outside the reachable deposit range

- **WHEN** the deposit is raised well past its ceiling
- **THEN** some tropism settings diverge the field while a frozen population at the same deposit does
  not, which is what makes the divergence chemotactic rather than a flood
