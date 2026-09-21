## Why

Every system that moves particles was built as its own pass. Each strength is a gain in that pass's units and time convention, and the systems meet only when their outputs are summed into one velocity buffer. The consequences:
- No strength means the same thing in two systems.
- A calibration done in one system does not carry to another.
- The species force secretly owns the world's resistance to compression.

**Observed:**
- **The user, 2026-09-18.** Long range "runs expensive when particle force is also on". Reaction-diffusion "doesn't have enough interaction". There "are forces on particles that don't seem to relate to each other". The effect of fluid, reaction-diffusion and long range on particles needs to be "taken down to a fraction of what they are". SPH "seems like a 2D tape-over". Particle colour should not come from reaction-diffusion. RD dots and worms are too large.
- **Three time conventions across five velocity writers.**
  - The species force multiplies by `dt` in seconds (`web/shaders/src/forces.wgsl:297,377`).
  - SPH multiplies pressure by `dt` and viscosity by the frame factor (`web/shaders/src/forces-sph.wgsl:274-278`).
  - The field force and long range take the frame factor on the CPU (`src/webgpu_compute.nim:1064-1066,1126`).
  - Bodies take it in the shader (`web/shaders/src/body-force.wgsl:81`, `src/webgpu_compute.nim:1098`).
- **No shared strength scale.**
  - Force Strength runs 0–5 (`src/config_ranges.nim:37-43`).
  - Fluid, Long Range and Bodies run 0–1 (`src/config_ranges.nim:57-67,481-484`).
  - Scent-following runs 0–37.5 (`src/config_ranges.nim:291`, `src/field_core.nim:157`).
  - Deposit runs 0–0.08 (`src/config_ranges.nim:280`).
  - Behind them sit unmeasured gains: the pair bump ×4.0 (`forces.wgsl:257-258`), `SPH_FORCE_SCALE` 3.0 (`src/sph_core.nim:38`) and `BODY_FORCE_CEILING` 10 (`src/body_core.nim:156-160`).
  - At a clump edge, the pair force hands a particle about 1 unit of velocity per reference frame, while Long Range 0.50 hands it 26–112 (`openspec/changes/archive/2026-09-18-coupling-balance/proposal.md`, "No shared unit").
- **Incompressibility is the species force's repulsion.** The only short-range push is the pair law's core, and Force Strength multiplies push and pull together (`forces.wgsl:243-247,282`). Crowding is a factor inside the attraction branch only (`forces.wgsl:261-262`).
- **Measured cost of compression.** Headless (Chromium 152, Apple M5 Max; runs in `scratchpad/cost-graph/runs/`), Long Range 0.5 raised the physics time 25× at 16 000 particles and 35–80× at 128 000, with Force Strength on or off. At 128 000 one run climbed to 162 ms and stalled. The cause is the always-on neighbour sweep, whose inner loop runs over cell occupancy (`forces.wgsl:141,193`). The long-range solve itself took 0.14–0.32 ms.
- **Integrator limits leak into unrelated ranges.**
  - Substeps belong to the fluid but replay every per-substep pass (`src/webgpu_compute.nim:984-988`, `src/sim_registry.nim:459-480`).
  - Body Reach's floor is Max Velocity's ceiling × the longest substep (`src/body_core.nim:135-139,184-193`).
  - Long Range Force and Field Force have no profiler slot (`src/sim_registry.nim:478`).
- **Sizes live in three spaces.**
  - The field pattern is measured in field cells: 9.3 cells per spot (`src/field_core.nim:232-239`).
  - Particles and halos are measured in canvas pixels (`web/shaders/modules/camera_transform.wgsl:97-100`, `web/shaders/src/glow.wgsl:94-103`).
  - The world is a fixed 3840 × 2160 units (`src/config.nim:127-128`), which was meant to be pixels.

**Stake:** the user is calibrating an instrument for live play. While these hold, every system is tuned alone in its own units. A change to one (substeps, the time convention, the grid) silently moves the others. The long-range cost can stall the frame at the particle counts the app offers.

This change supersedes `coupling-balance`. Its unit, pressure term, velocity words, substep rule and measurements become part of the contract below.

## What Changes

- **A coupling contract.** Every link between matter and fields runs through one declared interface. That covers the species force, fluid, scent (field → particles), deposit (particles → field), long range (particles → mesh → particles) and bodies (body ↔ particles). Each coupling declares:
  - its impulse in `u0`: one touching neighbour's repulsion at unit strength over the reference frame, `FRAME_DT_REFERENCE` (`src/physics_core.nim:23-26`)
  - one time convention, applied at one site
  - a strength from 0 to 1, where 1 is that coupling's calibrated full effect
  - its gate (skipped at exactly 0, as `acts()` does now, `src/sim_registry.nim:110-114`)
  - its cadence, per frame or per substep
  - its cost, including the density it can induce
  - a profiler slot
  - its dimming predicate
  - the cross-coupling bounds it reads
  - the space each of its sizes is measured in: world units, field cells or screen pixels
- **The species force is a coupling like the others.** Its neighbour sweep, which also measures density and carries mouse and blast input, becomes a world-intrinsic pass the couplings read. **BREAKING:** Force Strength moves from 0–5 to the 0–1 contract. Saved worlds convert through a preset schema migration.
- **Incompressibility belongs to the world.** A pressure term with an onset in the world's own mean crowd density resists compression at every strength setting, including Force Strength 0. This is coupling-balance D3–D6, D11 and D13–D14, with `K = 540`. Crowding becomes a texture control only. **BREAKING** for worlds that settle above the onset.
- **Strengths rescale to a calibrated fraction.** Each coupling's internal gain is set so that 1.0 means a measured full effect, well below today's. Scent-following moves from 0–37.5 to 0–1. **BREAKING** for saved strengths; the migration converts them.
- **The integrator owns stepping.**
  - Substeps are set by the integrator, not by the fluid. The count is the largest of three: the measured frame-factor limit (coupling-balance D15), the travel bound, and each active coupling's declared need. **BREAKING:** the Substeps slider goes. A stiff fluid asks for its substeps through its declaration.
  - One per-substep travel bound replaces the limits that leak today, such as Body Reach's velocity floor and the fluid's substep term in the stiffness ceiling.
  - Every velocity writer accumulates per reference frame into the fine and coarse words (coupling-balance D8).
- **Long range in a radius-scaled unit** (coupling-balance D2): its pull stops depending on mesh size. **BREAKING**, converted by migration.
- **Pattern scale moves to the chemistry.** A live Pattern Scale control sets both diffusion rates together, at their fixed ratio; they are already a per-frame uniform (`src/webgpu_compute.nim:1053-1054`). Its floor is measured: diameter follows √D down to 0.16, below which the pattern dies (`src/field_core.nim:235-244`). Interpolating the measured diameters puts the 4-cell resolution margin near scale 0.19, and the regime measurements may raise it further. The regime coordinates, the Worms/Coral deposit floor, the splat radius, the per-cell deposit cap, the tropism collapse bound and the scent gain are re-measured across that band. The regime table becomes a table per scale where the coordinates drift.
- **The fluid's character is re-examined against three effects:**
  - velocity smoothing that stays on at Viscosity 0 (`SPH_XSPH_EPSILON`, `src/sph_core.nim:30-33`, `forces-sph.wgsl:262`)
  - pressure evening out density
  - a kernel spanning the whole interaction radius, which overwrites species structure
- **Reaction-diffusion acts on particles as a force only.** Every visual path from the field is removed, so the field shows only through the motion it causes. **BREAKING.** The paths are:
  - the particle tint (`web/shaders/src/render.wgsl:188-194`) and `FIELD_LIGHT_STRENGTH`, which its comment calls a "blind visual pick" (`src/colormap_core.nim:61-84`)
  - the trail drift along the field gradient (`web/shaders/src/fade.wgsl:88-94`, `FIELD_DRIFT_SCALE`)
  - the colormap backdrop, with bloom on (`web/shaders/src/tonemap.wgsl:74-86`) and with bloom off (`web/shaders/src/field-composite.wgsl`)
  - the colormap selector (`src/web_api.nim:384-387`) and its ramps (`web/shaders/modules/colormap.wgsl`, `src/colormap_core.nim`)
  - Field Opacity, its `fieldUnlit` dimming, and both fields in the preset schema
- **Defects the interaction trace found are fixed here.** Several of them touch dimming and help lines this change rewrites anyway:
  - `docs/help/10-simulation.md:9` says a particle-count commit rebuilds; the code resizes (`src/web_api.nim:895-901`).
  - `docs/one-world.md:168` says "Four passes" and lists five, and `src/sim_registry.nim:126` leaves out `bodyForce`.
  - The bloom-off dimming greys out Exposure, Saturation, Contrast and Temperature (`src/ui/api/param_descriptor.nim:504-521`, `docs/help/52-bloom.md:9`), though `field-composite.wgsl:68` still grades with them. Removing the backdrop makes the dimming true.
  - Palette Saturation and Lightness have no effect under the default scheme (`src/palette.nim:140-164`), and nothing dims them.
  - The Velocity Sweep help leaves out halo growth (`docs/help/51-glow.md:10-11`, `web/shaders/src/glow.wgsl:98-99`).
  - `docs/help/30-fluid.md:20-22` leaves out Interaction Radius as a stiffness-ceiling input.
  - The three `audio-interface` artifact findings: its fresh-state test cannot catch a room level that survives reinitialisation (`openspec/changes/audio-interface/tasks.md:197`). Its "same wall-clock time at any frame rate" claim is false below 20 fps, where the 0.05 s frame cap (`src/app.nim:240`) starts clipping the delta (`openspec/changes/audio-interface/specs/audio-input/spec.md:160`). Its gain cost quotes stale figures (`openspec/changes/audio-interface/design.md:188`).

## Capabilities

### New Capabilities

- `coupling-contract`: the declared interface every coupling satisfies. It covers the unit, time convention, strength meaning, gate, cadence, cost and induced density, profiler slot, dimming, cross bounds and size spaces. It also holds the probe relation that compares couplings with one another in `u0`.
- `world-pressure`: compression resistance as a world-intrinsic term, independent of any strength. It covers the onset in the world's mean crowd density, the fixed stiffness, the finiteness and locality of a compressed crowd, and relaxation after release.

### Modified Capabilities

- `field-scale`:
  - "Pattern scale changes the cell, never the chemistry" and "One knob sets how big the pattern draws" are replaced by a measured chemistry-scale control.
  - "The field shows itself through the particles by default" is removed, and so is every visual path from the field.
  - "The field force divides by the knob the grid multiplies by" moves to the contract's gain.
- `gpu-frame-registry`:
  - "A world serializes as its strengths" gains the migration.
  - "Delta buffers have one reset owner" gains the two-word accumulator.
  - Every contributor carries a profiler slot and the contract's declaration.
- `parameter-range-authority`:
  - Coupling strength ranges become 0–1.
  - "A bound may derive from other parameters" gains the integrator's travel bound in place of per-system floors.
- `bounded-crowding`: crowding becomes a texture control, and bounding collapse moves to `world-pressure`.
- `sph-scale`: the fluid's smoothing and kernel defaults follow the re-examination.
- `species-chemistry`: "Up-gradient feedback stays bounded" is re-measured across the chemistry-scale band.
- `build-pipeline` and `gpu-buffer-layout`: `field-composite` leaves the requirements that name it.
- `control-legibility`, `gardenapi-boundary`, `shader-pipeline` and `native-test-strategy`: `fieldOpacity`, the colormap catalog, the colormap module and its oracle leave the requirements that name them.

## Impact

- **Shaders:**
  - `forces.wgsl`, `forces-sph.wgsl`, `field-force.wgsl`, `field-deposit.wgsl`, `rd-step.wgsl`, `body-force.wgsl`, `lr-force.wgsl` and `integrate.wgsl`.
  - `render.wgsl`, `fade.wgsl` and `tonemap.wgsl` lose their field reads.
  - `field-composite.wgsl` and `modules/colormap.wgsl` are deleted.
  - The render bind-group layouts lose the field texture.
- **Nim:**
  - `src/sim_registry.nim`: the contract, profiler slots and substep ownership.
  - `src/webgpu_compute.nim`: scale sites and substeps.
  - `src/config_ranges.nim`, `src/field_core.nim`, `src/sph_core.nim`, `src/body_core.nim`, `src/long_range_core.nim` and `src/physics_core.nim`.
  - New: `src/balance_core.nim`.
  - `src/ui/api/param_descriptor.nim`, `src/ui/api/dormancy.nim`, `src/ui/api/response_probe.nim`.
  - `src/preset.nim`: a new schema version.
- **Tests:** `tests/test_field_core.nim` (re-measured across the band), `tests/test_physics.nim`, `tests/test_sph_core.nim`, `tests/test_body_core.nim` and `tests/test_preset.nim`. New: `tests/test_balance_core.nim` and a contract test.
- **Docs:** `docs/one-world.md`, `docs/enforcement.md`, `docs/help/` for every coupling group, and `docs/slider-interactions.md` (the interaction graph this change was framed from).
- **Other changes:**
  - `coupling-balance` is superseded. Its design decisions and measurements move into this change's design, and it closes once they have moved.
  - `long-range-mesh`, `calibrate-shipped-defaults` and `parametric-bodies` are amended where coupling-balance named them.

## Measurement gate

Each gate orders ahead of the constants it sets:

1. **coupling-balance's five gates,** carried over, each native gate run on three gate seeds at 128 000 particles: the onset, the stiffness trade, the stacked hold, the pressure's in-app cost, and `ff_stable`.
2. **Each coupling's calibrated full effect in `u0`,** measured in-app, before its gain is set. Until then a strength range carries a provisional note, as `LONG_RANGE_STRENGTH_MAX` does now (`src/config_ranges.nim:68-75`).
3. **The chemistry-scale band.** At each scale step: the regimes' distance to their own attractor, deposit ignition, the splat radius, and the collapse bracket. This runs in the existing `tests/test_field_core.nim` harness. The floor is the smallest scale at which every regime still settles nearer its own attractor than any other.
4. **The long-range cost with pressure on.** Coupled time (the `physics=` figure plus every coupling's slot) at 128 000 particles and Long Range 1 in the four Long Range × Force Strength corners, one run each, read in-app. Scent and bodies are declared and unmeasured. The frame must stay under the pair pass's allotment (coupling-balance gate 4).

## Falsifier

Running a native contract test over every coupling answers true while the problem holds and false once it is gone: "some coupling's strength-1 impulse is not returned in `u0` by the one scale function the frame uses". Today it answers true for all six, because no such function exists and the five velocity writers scale at five sites. A second check: at Force Strength 0 and Long Range 1, the settled crowd density is unbounded today, and bounded by the onset afterwards.

## Doing nothing

**Case for doing nothing:** coupling-balance alone already supplies the unit, the pressure and the substep rule. The rest could be per-system calibration under `calibrate-shipped-defaults`. That case fails against three measured facts:
- Per-system calibration keeps three time conventions and six strength scales, so no calibration carries between systems. That is the user's stated need.
- The chemistry-scale, colour and fluid-character decisions are outside coupling-balance.
- The 162 ms stall is reachable today at the offered particle count.

**Case for deleting the fluid:** the user reads it as flat, and the world pressure would provide incompressibility without it. That case doesn't win yet. The fluid's viscosity and flow have no replacement, and all three flattening effects can be tested one term at a time.

## Decisions the user took

- **Reaction-diffusion is a force only.** No tint, drift, backdrop, colormap or Field Opacity. The field is seen only through the motion it causes.
- **Particle and halo sizes stay in screen pixels.** The contract declares each size's space, and no size moves between spaces.
- **Field resolution stays at 2048 × 1152.** A Field Detail selector is outside this change. If the chemistry band (gate 3) shows the regimes distorting at the scales wanted, it becomes its own change.
- **The defects the trace found are fixed in this change.**
- **The shipped particle count is 32 000.** 16 000 is too few for a default.
