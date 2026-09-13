## Why

Two couplings compress the world far past what the pair force can answer, and nothing pushes back.
At 128 000 particles, Long Range 0.50 at 12 species collapsed particle-life cells into filaments and
dense masses within 5 s while GPU physics rose 0.60 → 17 ms and FPS fell 143 → 32
(`scratchpad/long-range-mesh/in-app__13-09-26-1625.md`). Body Hold 10 gathered the whole population
into one mass at FPS 7 and ~100 ms physics (`scratchpad/parametric-bodies/in-app__13-09-26-1616.md`).
With both removed, physics kept climbing 3.5 → 6.5 ms because the clumps did not spread back apart.
Both in-app runs of the coupling changes (`long-range-mesh` task 6.2, `calibrate-shipped-defaults`
group 3) wait on this change.

The measured causes (`scratchpad/parametric-bodies/diagnosis__13-09-26-report.md`, and the probes in
`scratchpad/coupling-balance/`):

- **No shared unit.** At a clump edge the pair force hands a particle about 1 unit of velocity per
  reference frame; Long Range 0.50 hands it 26–112 and Hold 10 hands it 10 everywhere. The pair force
  multiplies by dt in seconds (`web/shaders/src/forces.wgsl:297,377`), the mesh by the frame factor
  (`src/webgpu_compute.nim:1125-1126`), and no probe compares one coupling with another
  (`src/ui/api/response_probe.nim:291-296`).
- **The long-range potential is measured in mesh cell areas.** Each particle deposits unit charge
  (`web/shaders/src/lr-deposit.wgsl:63-70`) and the kernel divides only by the cell count
  (`src/long_range_core.nim:162-172`), so the impulse is `strength · A · cellArea · M / (2πr)` for a
  mass `M` at distance `r` inside the reach. The same slider therefore pulls 4.0× harder on the
  256 × 128 mesh than on 512 × 256 (`lr_unit_probe.nim`, offsets 240 and 600), and its ceiling is
  still provisional (`src/config_ranges.nim:67-75`).
- **Compression builds no pressure.** Pair repulsion is bounded at −1 per neighbour and linear in
  the neighbour count (`forces.wgsl:243-247`). Crowding only scales positive attraction
  (`forces.wgsl:73-93,261-262`), so at its maximum it removes about 1.2 against a pull of 26–112. The
  density-ceiling analysis says of itself that it bounds what attraction concentrates and nothing
  else (`src/physics_core.nim:133-136`). Only tropism carries a collapse bound
  (`tests/test_field_core.nim:970-993`).
- **A self-attracting clump never relaxes.** One self-attracting species compressed by Hold 10 stays
  at 1 499 of 1 500 neighbours 900 frames after the body goes (`collapse_probe.nim`).

## What Changes

- **A shared impulse unit.** Every coupling's velocity impulse is stated in multiples of `u0`, the
  impulse one touching neighbour's repulsion gives at force strength 1 over the reference frame
  (`FRAME_DT_REFERENCE`, `src/physics_core.nim:23`). A new pure module `src/balance_core.nim` owns
  the unit, the pressure law's oracle, and one demand function per compressor in that unit.
- **BREAKING: the long-range potential changes unit.** The mesh's cell area is replaced by
  `u0 · interactionRadius`, so the pull stops depending on mesh size, and at strength 1 a clump's pull
  is the pair force's own unit spread by the 2D Green's function. The kernel's shape, `G(0) = 0`, the
  deposit and its fixed point stay as they are. A saved world with a non-zero long-range strength
  loads through a new preset schema version whose migration converts the strength exactly into the
  new unit; the descriptor clamp then decides what survives.
- **A pressure term in the pair force.** Inside the existing neighbour loop, every pair whose smoothed
  crowd density lies above an onset pushes apart. The density is read in units of the live world's
  own uniform crowd density, `N · π · R² / (3 · A)`, so the onset follows the particle count and the
  interaction radius. The push grows with the square of the excess, at one fixed stiffness: it
  answers a crowd by that crowd's own density and never by what a coupling does elsewhere. It reads
  the `crowdDensity` field the loop already loads, accumulates apart from the force law into its own
  fixed-point word sized for a full crowd, and is exactly zero below the onset. **BREAKING** for
  worlds that settle above the onset: a self-attracting species settles looser (app-scale probe: crowd
  peak 456 → 308), and a world at force strength 0 still resists compression past the onset (a
  recorded decision with its reopen conditions).
- **Derived constants, not clamps.** The onset comes from settled worlds on calibration seeds at two
  particle counts and two radii; the stiffness is the largest at which a world still settles as it
  does without the term; the pressure word's scale and per-pair saturation come from the
  full-crowd bound. A static assertion fails the build when a budget grows past what the word holds.
  Gates run held-out seeds. `LONG_RANGE_STRENGTH_MAX` loses its provisional note and gains its
  derivation.
- **Decisions the user took.** A strong stacked hold compresses a finite, local crowd that relaxes
  after release and costs more while held; no density gate, higher stiffness or projection. The
  ceiling is relative: every world keeps its own settled look, and dense configurations cost what they
  cost. At friction 0 dense crowds shimmer; the pressure is not scaled by friction.
- **The velocity word fits a full crowd.** Every writer of the shared velocity delta accumulates per
  reference frame and integrate multiplies by the frame factor, so a full crowd at force strength 5
  on the largest substep fits the existing 2^16 word (today it overflows, unasserted). A summed
  full-crowd assertion fails the build when a budget outgrows it. No range is narrowed.
- **Crowding keeps its place as a look control.** It shapes clump texture; the pressure is what
  bounds collapse.
- **Cross-coupling probes.** `longRange.impulseShare` reports its impulse in `u0` at a reference
  colony. A new native suite checks every compressor's probe against its demand function and reports
  each demand over the pressure's capacity, so couplings are compared with one another as well as
  along their own slider.

## Capabilities

### New Capabilities

- `coupling-balance`: the shared impulse unit, the long-range potential's unit, the pressure term,
  its onset in the world's own mean crowd density, its fixed stiffness and its accumulator, the
  finiteness and locality of a compressed crowd, relaxation after a compressor is removed, and the
  cross-coupling probe relations.

### Modified Capabilities

None in `openspec/specs/`. Two in-flight changes hold requirements this change contradicts, and
neither is archived, so no delta can target them. This change lands first and amends their
artifacts directly (tasks 3.4 and 4.4):

- `long-range-mesh`, `specs/long-range-coupling/spec.md`, "A long-range world serializes as its
  numbers", states that no schema version and no migration branch is added, and "Reach is a screening
  length" and the parameter-range-authority delta state the strength's provisional ceiling.
- `calibrate-shipped-defaults`, group 3 and design decision 3: fixture C is a world that collapses at
  crowding 0, and under this change it no longer collapses.

`design.md` D7 and D12 name the amendment each needs.

## Impact

- Shaders: `web/shaders/src/forces.wgsl` (the pressure term and word), `web/shaders/src/integrate.wgsl`
  (its decode), the `LR_FORCE_SCALE` write in `src/webgpu_compute.nim` (the unit), the header comments
  of `web/shaders/modules/fixed_point.wgsl` and `web/shaders/src/forces-sph.wgsl`.
- Buffers: one per-particle pressure word pair (1 MB at `MAX_PARTICLES`); the frame factor in a pad
  slot of `IntegrationParams`.
- Velocity-word writers: `forces.wgsl`, `forces-sph.wgsl`, `body-force.wgsl`, `field-force.wgsl`,
  `lr-force.wgsl` and the frame-factor multiplies for them in `src/webgpu_compute.nim`.
- Oracles and ranges: `src/balance_core.nim` (new), `src/physics_core.nim` (pressure mirror),
  `src/long_range_core.nim` (unit), `src/config_ranges.nim` (constants, balance assertion),
  `src/shader_config.nim` (placeholders).
- Presets: `src/preset.nim` (`CURRENT_SCHEMA_VERSION` 4 → 5, a `fromVersion < 5` branch).
- Probes and tests: `src/ui/api/response_probe.nim`, `tests/test_balance_core.nim` (new),
  `tests/test_long_range_core.nim`, `tests/test_physics.nim`, `tests/test_preset.nim`,
  `tests/test_response_probe.nim`.
- Docs: `docs/one-world.md`, `docs/enforcement.md`, `docs/help/` for the long-range and species
  groups (the crowding help line).
- Other changes: `long-range-mesh` (its migration sentence and provisional ceiling),
  `calibrate-shipped-defaults` (fixture C and `c_hold`); `parametric-bodies` 9.2 and 9.3 measure after
  this change.

## Measurement gate

Feasibility rests on measurements ordered before the constants they set in `tasks.md`:

1. The settled crowd density over the uniform crowd density, on calibration seeds at two particle
   counts and two radii. It sets the onset.
2. The largest stiffness at which a world still settles as it does without the term, at
   `FRICTION_MIN` and at the shipped friction. It sets the stiffness.
3. The coarsest pressure scale that keeps that criterion and relaxation, and the per-pair saturation
   the full-crowd bound admits, with the app-scale stacked hold rerun at that saturation.
4. The pressure word's and the term's cost in-app on the settled shipped world at `MAX_PARTICLES`,
   against the pair pass's provisional 2.67 ms allotment (3.75 ms headroom less long range's 1.0 ms
   less the bodies' idle 0.076 ms). A cost over it sends the design back. Held and dense
   configurations cost what they cost (relative ceiling).

The native probes (`scratchpad/coupling-balance/`) already show, at 128 000 particles in the app's
3840 × 2160 world: 32 stacked D16 bodies collapsing a crowd to 6 305 in 24 frames with no pressure,
and a fixed square-law pressure holding it finite at about 600 with crowds beyond the bodies' reach
unchanged in speed, then relaxing within 50 frames of removal. No fixed stiffness a calm settle
tolerates holds that column near the onset; the user accepted the finite, local held crowd. The small
probe world is 1.69× the app's number density at 128 000 particles and 13.5× at 16 000; every probe is
a CPU model, not the GPU, and none sets a constant.
