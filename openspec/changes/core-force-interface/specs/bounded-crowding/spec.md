## MODIFIED Requirements

### Requirement: Local density attenuates attraction

Every attractive force contribution SHALL be scaled by `1 / (1 + strength * log(1 + density))`,
where `density` is the receiving particle's smoothed, species-blind crowd density — a dedicated
channel that counts every neighbour, accumulated beside the same-species colony density
(`web/shaders/src/forces.wgsl`, the crowd word of the three-word crowd buffer — crowd density,
stiffness fine, stiffness coarse (`world-pressure`) — in the neighbour loop) and smoothed onto the
particle exactly as the colony channel is (`web/shaders/src/integrate.wgsl:72-73`,
`p.crowdDensity`) — and `strength` is the crowding strength parameter. The colony channel stays
same-species and feeds the renderer; the two signals are not interchangeable.

The term applies to attractive contributions only, in both force models: the polynomial attraction
envelope (`polynomialForce`, `src/physics_core.nim:397-421`, and the attraction bump in
`web/shaders/src/forces.wgsl:261-262`) and the exponential attraction term (`exponentialForce`,
`src/physics_core.nim:422-431`, mirroring the same-named function in `web/shaders/src/forces.wgsl`).
Repulsive contributions are untouched at every density — the short-range zone, and attraction-zone
contributions whose matrix entry is negative. Attenuating a repulsive term would partly cancel the
repulsion that keeps particles apart.

Crowding is a texture control. It shapes how tightly colonies pack and bounds no compression. The
world pressure bounds compression, and crowding does not scale it (`world-pressure`, "A crowd denser
than the onset pushes itself apart"). Crowding shapes only the species force, so its slider dims
while Force Strength is 0 (`dormantWhen = "forceOff"`, `src/ui/api/param_descriptor.nim:453-459`), under
`coupling-contract`, "A coupling's controls dim with its strength".

The oracle for the term lives in `src/physics_core.nim` (`crowdingAttenuation` and
`calculateAttenuatedForce`, `:67-107`) and the WGSL mirrors it. The properties below are native
tests in `tests/test_physics.nim`, suite "Crowding Attenuation" (`:96-191`) (test-held). That the
attenuation leaves the world pressure unscaled is held by `tests/test_physics.nim` suite "Pressure
Past The Onset" (test-held). That `forces.wgsl` carries the oracle's expression is **unenforced**, the
standing condition of `physics_core`'s mirror.

#### Scenario: An isolated particle feels the unattenuated force

- **WHEN** a particle's local density is zero
- **THEN** its forces are identical to the unattenuated force at every crowding strength, because
  `log(1 + 0) = 0`

#### Scenario: Strength zero is exactly the unattenuated force law

- **WHEN** crowding strength is zero
- **THEN** every force at every density equals the unattenuated oracle, so any regression is
  bisectable to one number

#### Scenario: A schema-version-1 preset keeps the unattenuated force law

- **WHEN** a preset written under schema version 1 is applied
- **THEN** its crowding strength decodes to exactly zero through the v1 branch of the versioned
  decode (`src/preset.nim:715`), never to the shipped default, so no saved world gains a term
  it was not saved with (`tests/test_preset.nim`, "a preset saved before this change applies with
  crowding strength zero")

#### Scenario: Crowding is never rewarded

- **WHEN** density rises with everything else held fixed
- **THEN** attenuated attraction never rises

#### Scenario: Repulsion survives the crowd

- **WHEN** a pair sits in the repulsion zone, or its matrix entry is negative, at any density
- **THEN** the force contribution is unattenuated

#### Scenario: The term commutes with force strength

- **WHEN** the attenuated attraction is evaluated at force strength `k`
- **THEN** it equals `k` times the attenuated attraction at force strength 1 — the attenuation is a
  fraction of whatever attraction survives the species coupling's strength and gain, never an
  absolute force, so its meaning does not drift across the force-strength range

#### Scenario: Crowding leaves the world pressure alone

- **WHEN** crowding strength moves across its range with a crowd above the onset
- **THEN** the pressure impulse on each pair is unchanged

### Requirement: Crowding ships off, and its ceiling is a working bound

The shipped crowding strength default SHALL be `0.0` (`src/ui/state/simulation_state.nim:135`,
mirrored in `src/preset.nim:237-240`), so a fresh world runs the force law that every other default
was chosen against. `CROWDING_STRENGTH_MIN` SHALL be exactly zero, so that force law stays reachable
from the slider (`src/config_ranges.nim:42-45`, static assertion at `:567-568`).

`CROWDING_STRENGTH_MAX = 2.0` is a working bound, and states so beside itself
(`src/config_ranges.nim:46-54`). Crowding bounds no compression, so its calibration measures the look
alone. The measurement finds the crowding strength at which ordinary colonies visibly soften, with the
world pressure acting. It sets the default and the ceiling against that strength and records the
conditions beside the constant under the range authority's measured-bound rule. No collapse
measurement enters it.

**unenforced**: nothing detects a ceiling too high or too low for the look, because no measurement
of the softening exists to compare it against. Running that calibration with SPH off, at the shipped
attraction-matrix bounds and the species coupling's full effect, and recording its conditions beside
the constant, closes it. Once recorded, the record is **agent-checkable**. An agent launches the app,
sets crowding strength to the ceiling in a single-species world, and reads whether colonies still
hold form.

#### Scenario: A fresh world carries no crowding

- **WHEN** the app starts with no preset applied
- **THEN** crowding strength is zero and every force equals the unattenuated oracle

#### Scenario: The unattenuated force law stays reachable

- **WHEN** the crowding range is narrowed
- **THEN** the static assertion in `src/config_ranges.nim` fails the build unless the floor stays
  exactly zero

#### Scenario: The attraction bounds move after a calibration

- **WHEN** the matrix value bounds or the species coupling's full effect change
- **THEN** the record beside the crowding default names bounds that no longer exist, and the
  calibration has to re-run instead of shipping a default tuned against a vanished range

## REMOVED Requirements

### Requirement: A density ceiling exists and is computed

**Reason**: The ceiling was crowding's claim to bound collapse, and crowding no longer bounds
collapse. The world pressure does, at every crowding strength, including 0, the shipped default, where
this ceiling was infinite. The ceiling also covered only what attraction concentrates, leaving out the
long range, the bodies, the mouse and the blast, the compressors that collapse the world. A finite
ceiling that exists only at non-zero crowding and only against one compressor bounds nothing the
world relies on.

**Migration**: Bounding collapse moves to `world-pressure`: "A crowd denser than the onset pushes
itself apart" and "A compressed crowd stays local and below its collapse". The neighbour sweep's cost
under compression is bounded there, relative to the world's own mean crowd density. `densityCeiling`,
`crowdingBalance` and `packingSeparation` (`src/physics_core.nim:176-224`), the scope block above
them (`:108-144`), and `tests/test_physics.nim` suite "The Density Ceiling" (`:192-245`) are deleted
with this requirement. `CROWD_PACKING_CONSTANT` (`src/physics_core.nim:150-162`) is the hexagonal-lattice
conversion from a separation to the crowd-density signal. That is the relation the world pressure's
contact floor computes (`world-pressure`, "The onset and the stiffness are derived and fixed"), so it
moves to that floor's function in `src/balance_core.nim` rather than being deleted. The floor SHALL read it as it stands.
