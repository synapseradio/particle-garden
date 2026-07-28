## Why

Reaction-diffusion mode has two user-visible faults — canvas gestures do nothing, and the Gray-Scott
pattern reads as wallpaper unrelated to the particles — and both trace to one structural fact:
`buildFrame(skReactionDiffusion)` dispatches no grid triad and no forces pass
(src/sim_registry.nim:246-289).

Mouse and blast state reaches the GPU every frame (src/webgpu_compute.nim:728-763, no mode gate) but
only forces.wgsl and forces-sph.wgsl read it, so the clicks have no consumer. Without a forces pass
particles never clump, and src/field_core.nim:74-91 records that isolated deposits cannot ignite
Gray-Scott — so the pattern must be pre-seeded by 48 blobs whose placement hashes only a blob index
and a nonce (src/field_core.nim:161-168), ignoring particle positions entirely. The renderer then
draws that pre-existing pattern as an opaque fullscreen backdrop (src/webgpu_render.nim:584).

The particles are tourists on someone else's painting. Fixing the structural fact opens what the app
is for: one world whose layers combine through the particles.

## What Changes

- **BREAKING** Retire the mode selector. The three modes become presets over a `WorldCouplings`
  (forces, sph, field) frame composition; saved presets keep loading through a SimKind compatibility
  layer.
- Separate delta-buffer reset from accumulation so force and field passes can run in the same frame:
  frame-level clears, accumulate-only contributors, field-force's plain store becomes atomicAdd.
- Delete the automatic 48-blob seed. The field ignites from particle colonies via a radius splat
  deposit, sized by a native measurement gate. field-seed.wgsl survives as a deliberate
  "scatter spores" action.
- Give species chemistry: per-species signed secretion and tropism, with an editor beside the
  attraction matrix.
- Render the field as light, not backdrop: particles lit by the field, coverage following intensity,
  trails displaced by the field gradient.
- Add a camera over the torus: wheel, keyboard, and touch navigation; repeat samplers so light wraps
  like physics; nearest-toroidal-image drawing.
- Add climate drift, and give every slider optional labelled notches marking values that are known
  to work — so a user finds the interesting settings by reading the slider, not by knowing the
  literature.
- Clamp particle count in place when a preset lowers the ceiling, with no re-randomization of a
  living world.
- Measure the merged frame's GPU cost against the A0 baseline before the expensive visual work ships.

## Capabilities

### New Capabilities
- `camera-navigation`: pan and zoom over the toroidal world, wrap-in-light, wheel/keyboard/touch
  input as pure natively-tested handlers.
- `species-chemistry`: per-species secretion and tropism coupling particles to the chemical field,
  with a bounded-feedback guard.
- `climate-drift`: slow autonomous wandering of feed and kill, and the named-regime selector that
  makes Pearson's territory reachable without knowing Pearson.

### Modified Capabilities
- `gpu-frame-registry`: frames compose from WorldCouplings instead of selecting by SimKind; delta
  clears become frame nodes; controlGroupsFor takes couplings; automatic seeding is retired.
- `gardenapi-boundary`: mode ceilings clamp in place without particle re-initialization; the mode
  surface becomes couplings presets; descriptors gain labelled notches.
- `parameter-range-authority`: camera zoom, species chemistry, and notch tables join the range
  authority under the standard static assertions.
- `gpu-buffer-layout`: two new uniform layouts (SpeciesChemistry, Camera) under the existing
  compile-time validation; FieldParams stays at 32 bytes.

## Impact

- `src/sim_registry.nim`, `src/shader_manifest.nim`, `src/webgpu_compute.nim` — couplings, frame
  composition, bind-group entry counts.
- `web/shaders/src/forces.wgsl`, `forces-sph.wgsl`, `field-force.wgsl`, `field-deposit.wgsl` —
  reset-prologue removal, atomicAdd, splat, chemistry scaling.
- `web/shaders/src/render.wgsl`, `tonemap.wgsl`, `field-composite.wgsl`, `fade.wgsl`, `glow.wgsl` —
  field-as-light, camera transform, reprojection.
- `src/webgpu_render.nim`, `src/webgpu_init.nim` — repeat samplers, glow floor removal.
- `src/web_api.nim`, `src/canvas_input.nim`, `src/ui/input/`, `src/config_ranges.nim`,
  `src/gpu_types.nim`, `src/field_core.nim`, `src/ui/api/param_descriptor.nim`.
- `web-ui/src/` — preset row replacing the mode selector, notched sliders, chemistry editor.
- `tests/test_field_core.nim`, `tests/test_sim_registry.nim`, and new `tests/test_camera_core.nim`.

## Non-Goals

- Implementing a second reaction model. A kernel-and-growth reaction such as Lenia is its own future
  change. This change **reserves its slots** — the already-allocated `.b`/`.a` field-texture channels,
  a `ReactionParams` uniform, and a named `reactionKind` enum — because those are layout decisions
  that would otherwise force a sweeping refactor later, but it implements no second reaction and
  claims no readiness beyond an addressable slot.
- Restoring the activator deposit slot removed from field-deposit.wgsl. Signed secretion into the
  inhibitor channel already gives both builders and grazers; the second slot costs 1 MB of VRAM and
  1 MB per frame of traffic for a distinction the ecology does not need. Its channel count becomes a
  named constant so raising it later is a one-line change.
- Raising the 32000 particle ceiling for field-coupled worlds.
- A 2D climate pad. Every factor stays a slider; the named-regime selector supplies the coordinates.
