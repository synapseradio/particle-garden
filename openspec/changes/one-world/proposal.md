## Why

The app hands the user a world and a panel to steer it with. Three faults run through that, at three
depths. The world arrives as a choice between three worlds when it only ever was one. A world made of
attraction concentrates without limit and the fluid inside it has no scale of its own. And the panel's
controls make promises that nothing in the build or either test suite checks.

They compound. A mode decides which controls exist, so a broken promise can hide by never appearing;
a world that collapses into blobs makes every force control feel dead at once; and a control whose
effect cannot be measured is a control nobody can use to steer out of either. One change addresses
all three because separating them means calibrating each against a model the next one replaces.

### The mode is the defect

The app asks the user to choose between species forces, a fluid, and a chemistry, and a world is not
one of those things — it is all of them, in whatever proportion. Every fault in this section is that
single choice showing through somewhere different.

The clearest one is what the chemical world cannot do. `buildFrame(skReactionDiffusion)` dispatches
no grid triad and no forces pass (src/sim_registry.nim:246-289), so canvas gestures do nothing and
the Gray-Scott pattern reads as wallpaper unrelated to the particles. Mouse and blast state reaches
the GPU every frame (src/webgpu_compute.nim:728-763, no mode gate) but only forces.wgsl and
forces-sph.wgsl read it, so the clicks have no consumer. Without a forces pass particles never clump,
and src/field_core.nim:74-91 records that isolated deposits cannot ignite Gray-Scott — so the pattern
must be pre-seeded by 48 blobs whose placement hashes only a blob index and a nonce
(src/field_core.nim:161-168), ignoring particle positions entirely. The renderer then draws that
pre-existing pattern as an opaque fullscreen backdrop (src/webgpu_render.nim:584). The particles are
tourists on someone else's painting.

The rest of the mode's cost is spread thinner and is no less real. Controls appear and vanish because
`controlGroupsFor` decides which exist per mode, so a panel offers a different set of promises
depending on a choice made elsewhere. The particle budget is one number under three names
(`SPH_PARTICLE_CEILING`, `RD_PARTICLE_CEILING`, `COUPLING_PARTICLE_CEILING`) held equal by a
`doAssert` at src/config_ranges.nim:337, none of them measured. Glow reads a substitute density
(`RD_GLOW_DENSITY_FLOOR`) because the real one is only computed where forces run. And what a world
*is* gets stored twice — as a `SimKind` and as a coupling triple — free to disagree.

None of that is fixed by making the modes compose better. It is fixed by there being one world.

### A world made of attraction has no upper bound

Both faults here are structural, both are invisible in the source until you look for the missing
thing rather than the wrong thing, and neither is caught by any test.

**Attraction can concentrate without limit, and the spatial hash is what pays.** Nothing in
`forces.wgsl` resists a cluster. The only force in the file that breaks a formation is the
double-click blast (`web/shaders/src/forces.wgsl:370-390`), which is an input, not a mechanism. So a
force world's normal end state is a few hyper-concentrated blobs. That is not merely an aesthetic
outcome: the neighbour sweep is a 3x3 walk of grid cells sized to the interaction radius, so when
most particles occupy few cells the per-particle neighbour count stops being bounded by the radius
and starts being bounded by the population. The frame cost degrades toward the quadratic case
exactly when the world stops being interesting to look at.

**The signal that would prevent it is already computed, and thrown away.** `forces.wgsl:328-339`
accumulates a symmetric per-particle local density, `integrate.wgsl:85-93` applies temporal smoothing
and writes it back to the particle, and the only consumers are visual: dot size and brightness in
`render.wgsl` (`SIZE_DECAY_RATE`, `BRIGHTNESS_GROWTH_RATE`) and the glow radius. No physics reads it.
A world that measures its own crowding every frame, stores it on every particle, and then lets
attraction ignore it is carrying the fix and not applying it.

**SPH has no smoothing radius.** `web/shaders/src/forces-sph.wgsl:104` reads
`let smoothingRadius = params.interactionRadius;`. The fluid kernel is the force kernel, which means
fluid structure is pinned to the same scale as force structure and cannot be tuned apart from it.
With the interaction radius spanning 10 to 150 (`src/config_ranges.nim:35-36`) against particles a
few units across, SPH acts as a large-scale organizing field rather than as local incompressibility —
visible structure at the scale of the whole arrangement, where it was meant to be a near-neighbour
effect that adjusts relative forces and is otherwise not seen. There is no knob to have set wrongly;
the knob does not exist.

One constraint bounds any fix: the neighbour sweep only visits the 3x3 cell block around a particle,
and cells are sized to the interaction radius. An SPH radius **larger** than the interaction radius
would silently drop neighbours outside that block, producing a fluid that is wrong rather than merely
mistuned. Smaller is always safe. Whatever control appears must make exceeding it unrepresentable
rather than merely discouraged.

### A control makes a promise

A control panel makes a promise: move this, and something happens. One world offers one control set,
so nothing hides — every broken promise is on screen. Six defect classes break that promise today,
and nothing in the build or either test suite catches any of them.

**A control can be wired to nothing.** `setParamImpl` dispatches on the descriptor id through a
hand-written `case` ending in `else: discard` (src/web_api.nim:407-508). A descriptor added without
its matching arm clamps its value, writes nowhere, and reports success. The slider moves, the readout
updates, and the simulation never hears it. `tests/test_param_descriptor.nim` pins the descriptor's
range, default, and store routing against `config_ranges` and the state records, but nothing relates
the id to a write, because that dispatch lives on the JS backend where no native test reaches.

**A control can be wired correctly and still do nothing over most of its travel.** `rdFeed` and
`rdKill` span `[0.010, 0.085] × [0.040, 0.075]` (src/config_ranges.nim:83-92), and design D2
derives `F ≥ 4(F+k)²` as the condition for a nontrivial fixed point to exist at all. Most of that
rectangle holds nothing a slider movement can express. The named-regime notches (D4) mark
destinations worth reaching; nothing measures the track between and around them, so the range and the
step remain honest numbers presented in the wrong coordinates. `trailLength` has the same shape of
problem from the opposite direction: the trail decays geometrically (fade.wgsl:109-110, fed by the
trailLength→fadeAmount mapping at src/webgpu_render.nim:1644-1652), so persistence is a steep
function of the slider near one end of the track and flat across the rest.

**A control can write a value nothing reads.** Exposure, Bloom Intensity, Saturation, Contrast, and
Temperature write the tonemap uniform every frame (src/webgpu_render.nim:1673-1681), and the tonemap
pipeline that reads those fields runs only when bloom is on (:1756) — the bloom-off present path
reads only the colormap index and field opacity from that same buffer. Five sliders, in the section
whose first control is the Bloom toggle, do nothing while it is off. The store field is written and
the grading math is correct, so neither a dispatch check nor a pure response probe can see the
failure: the promise breaks between the uniform and the pipeline that would consume it.

**A control can be quiet for a good reason it never states.** Couplings are continuous strengths and
zero is an ordinary value (D7), so whole families of working controls sit quiet whenever a
strength is zero — every fluid slider in a world with no fluid, every secretion share while nothing
deposits — and the field-appearance controls sit quiet while the field rests at its trivial fixed
point with nothing to make opaque. The panel offers no distinction between *"you moved this and it
did nothing because it is broken"* and *"you moved this and it did nothing because the world is not
ready for it yet"*, and those feel identical from the outside.

**A control's guarantee can sit upstream of its promise.** A particle's on-screen size is not the
size parameter — it is that parameter through more multiplications: the density size multiplier
(0.7 to 1.3, web/shaders/src/render.wgsl), the world-to-screen scale, and the camera zoom.
`PARTICLE_SIZE_MIN = 1` (src/config_ranges.nim) bounds one factor of that product, so at the small
end the product can land under a pixel and the fragment coverage test finishes it off: particles
become invisible while every bound holds. (`CAMERA_SIZE_FLOOR`, an earlier floor on the scale
factor alone, was the right idea placed halfway; it went with the D15 camera revision, and the
floor on the composed result replaces it.)
The same shape hides in glow: the halo alpha the screen can show clamps, so the top of the intensity
range `[0.0, 3.0]` (src/config_ranges.nim:49-50) is blown-out travel that an unclamped observable
would call live. A bound on a parameter is not a bound on the observable.

**A control can fight the user's edit.** The attraction matrix cannot be edited through empty: the
cell handler parses the field on commit, an emptied field parses as `NaN`, and the handler re-renders
the cell back to the live value (web-ui/src/components/MatrixEditor.tsx:46-55) — the intermediate
state every retyped number passes through is treated as an error and reverted. The same component
restates the step and the display precision as literals (MatrixEditor.tsx:92-93) that Nim never
served, against the one ownership rule the boundary has.

Underneath all six: **the application ships no user-facing documentation of any kind.** `docs/`
holds a performance report and a research folder, both written for contributors. Nothing tells
someone looking at the window what they are looking at, what the gestures are, or what any control
means.

## What Changes

**One world.**

- **BREAKING** There is one world and no mode anywhere. Species forces, fluid pressure, and chemistry
  each contribute according to a continuous strength; zero is an ordinary value, so "no fluid" is a
  slider position rather than a different world. `SimKind`, the mode selector, and the mode catalog
  are deleted rather than kept as a compatibility layer — a legacy preset's mode is consulted once,
  in the versioned decode, and translated into the strengths it always meant.
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
- Collapse every duplicated fact the mode created: one particle budget instead of three names held
  equal by an assertion, real density instead of a glow substitute, one name for the feed/kill point
  that currently ships as both "Stripes" and "Labyrinth", and one control set instead of a per-mode
  one. An assertion that two constants stay equal is a duplication with an alarm on it, not a safety
  property.
- Clamp particle count in place when a preset lowers it, with no re-randomization of a living world.
- Measure the merged frame's GPU cost against the A0 baseline before the expensive visual work ships.

**A world that cannot collapse, and a fluid with its own scale.**

- **Bound crowding in the force law itself.** Attenuate attraction by the local density each particle
  already carries, on a logarithmic curve so the term is invisible at ordinary densities and only
  asserts itself where a blob is forming. Collapse stops being reachable, which puts a ceiling on
  per-frame neighbour work rather than merely lowering its average.
- **Give SPH its own scale**, as a fraction of the interaction radius in `(0, 1]`. A fraction rather
  than an absolute radius, so the ceiling constraint holds by construction and the fluid keeps its
  relative scale when the interaction radius moves. The default sits well below 1, putting the
  smoothing kernel at near-neighbour scale.
- **Weather for both the chemistry and the forces, from one drifting tour.** `climate_core`
  generalises into a parameterised walk over a waypoint table; the reaction-diffusion regimes are one
  such table and the force parameters are another. One loop, two tables, and its guarantees hold for
  both: in range by convexity, continuous at every handover, bounded per-frame step, written through
  the ordinary `setParam` path so the sliders visibly move. The density cap makes collapse
  impossible; the weather keeps a world that cannot collapse from settling into one static
  arrangement instead.
- **Test the bound as a relation, not a table.** The density attenuation is only worth having if a
  world provably cannot exceed a density ceiling under any reachable attraction; that is the property
  to state, and it is checkable in `physics_core.nim` without a GPU.

**Controls that keep their promise.**

- Add a **response probe** to every descriptor: a pure Nim function returning a scalar the parameter
  demonstrably moves, drawn from the existing reference-oracle family, evaluated in a **declared
  context** that fixes every other parameter at named coordinates. A descriptor with no probe
  carries a written exemption; the pairing is total and enforced natively.
- Test every control for **span, live fraction, and cliff** across its own slider travel — the
  end-to-end effect is non-trivial, most steps of the track change the response, and no single step
  jumps it. These three properties are what "reasonable increments and total ranges" reduces to, and
  they derive the range and step rather than asserting hand-picked numbers.
- Declare a **joint legibility group** where parameters' live region is jointly shaped — `rdFeed`
  and `rdKill` — entered only on slice-measurement evidence, measured on slices through the named
  regimes, and guaranteed by reachability, slice liveness, cliff, and attractor fidelity rather than
  by a per-slider global live fraction no instrument can make true.
- **Measure what the user can see, and floor the visible result rather than a parameter.** A probe's
  observable includes the display-side transformations that can extinguish the effect — a clamp, a
  coverage test — and where a promise concerns a composed observable, the guarantee is placed at the
  end of the transform chain, held in the range authority, and asserted at the reachable corners of
  its inputs. The shipped instance: a pixel floor on particle visibility, so no reachable size and
  zoom renders particles invisible; the glow-intensity range is recalibrated where its clamped
  observable, not its raw math, says the track dies.
- Add a **travel curve** to the descriptor, owned in Nim and served through `descriptor()`, so a
  slider's position maps to its value non-linearly where a linear map wastes the track. Stored
  values, preset keys, and clamping are untouched — the curve maps position to value, nothing else.
- Give every slider optional **labelled notches** marking values known to work, so a user finds the
  interesting settings by reading the slider rather than by knowing the literature, and a **named
  regime selector** where a destination needs more than one coordinate to reach.
- **Generate the parameter dispatch** from the state records' field names, replacing the hand-written
  case. A descriptor id that names no field becomes a compile error instead of `else: discard`.
- Extend the reference-oracle family with **`glow_core.nim` and `trail_core.nim`**, mirroring
  glow.wgsl's falloff and alpha composition and the trail's geometric decay, so the render-side
  sliders become measurable rather than exempt.
- Give every control an **immediate, unconditional acknowledgement** — readout, handle, and a brief
  highlight in the same tick — separated from its **declared response horizon**, so a slow parameter
  reads as slow rather than as broken.
- Mark a control **dormant, with the reason**, when what it acts on is absent right now — a coupling
  strength at zero, a consumer that binds only under another control's setting, a field with nothing
  in it. The predicate is declared per descriptor over named state; a dormant control stays visible,
  stays in place, and stays movable.
- Give the **matrix editor the user's edit**: a cell holds uncommitted intermediate states including
  empty, clamps on commit, and is never overwritten mid-edit by a re-render. The matrix range
  recalibrates to **±0.330 with step 0.001** and three-decimal display, with the bounds, step, and
  precision served through the boundary so the editor restates none of them.
- Draw a **transient world overlay** for the parameters that have a spatial meaning — interaction
  radius and camera zoom; the deposit splat radius is a compile-time constant with no control to
  drag — for as long as the control is being dragged.
- Add **in-app help**: markdown authored under `docs/help/`, `staticRead` into the frontend at
  Nim-compile time, opened by `?` and a button. The same files are the feature documentation, so
  there is one source and no second copy to drift.
- **Generate the gesture and key reference** from the binding table the input handlers use, rather
  than authoring it, so a binding cannot exist without appearing in help.
- Catch **named-field WGSL struct constructors at build time**. WGSL constructors are positional
  only, the structs in question are generated from Nim objects where named fields are correct, and
  the resulting parse error builds green and fails on the device. A pure source lint the bundler
  calls closes that one class.

## Capabilities

### New Capabilities

- `bounded-crowding`: local density attenuates attraction on a logarithmic curve, with a stated and
  natively-tested ceiling on reachable density; the pure oracle mirrors the WGSL term.
- `camera-navigation`: pan and zoom over the toroidal world, wrap-in-light, wheel/keyboard/touch
  input as pure natively-tested handlers.
- `control-legibility`: every visible control has a measured effect, presented in coordinates where
  the effect is distributed across the track, with an acknowledgement the user cannot miss, a stated
  reason when it cannot act now, and edits that belong to the user until committed.
- `in-app-help`: one markdown source serving both the in-app help panel and the feature
  documentation, with native coverage tests in both directions and a generated gesture reference.
- `species-chemistry`: per-species secretion and tropism coupling particles to the chemical field,
  with a bounded-feedback guard.
- `sph-scale`: the SPH smoothing radius as an independent fraction of the interaction radius, clamped
  so it can never exceed the neighbour sweep's reach.
- `weather`: one parameterised tour over a waypoint table, driving both the reaction-diffusion
  regimes and the force parameters — in range by construction, continuous at every handover, bounded
  per-frame step — with the named-regime selector that makes Pearson's territory reachable without
  knowing Pearson.

### Modified Capabilities

- `gpu-frame-registry`: one frame composed from coupling strengths, with a pass skipped only when its
  strength is exactly zero and only where the strength multiplies the pass's entire output; delta
  clears become frame nodes; `controlGroupsFor` is removed along with the mode it existed to serve;
  automatic seeding is retired.
- `gardenapi-boundary`: one particle budget clamping in place without re-initialization; the mode
  surface is deleted and presets become named points in the one world's parameter space; descriptors
  gain labelled notches, a probe id, a travel curve, a response horizon, and a dormancy predicate;
  the parameter dispatch is generated rather than hand-written; help content and the matrix editor's
  coordinates are served from Nim like every other authored number.
- `parameter-range-authority`: camera zoom, species chemistry, the crowding curve's strength, the SPH
  radius fraction, the weather's speed, and notch tables join the authority under the standard static
  assertions; a range and a step are justified by the measurement that produced them, recorded beside
  the constant, rather than by review; a guarantee about a composed observable lives at the end of
  its transform chain, not on one factor; the attraction-matrix bounds join the authority as a
  recorded decision.
- `gpu-buffer-layout`: two new uniform layouts (SpeciesChemistry, Camera) under the existing
  compile-time validation; `SimParams` gains the crowding strength and the SPH radius fraction;
  FieldParams stays at 32 bytes.
- `native-test-strategy`: probe coverage over the descriptor table is total and enforced; new
  reference oracles join the family; joint-group guarantees adopt the suites that already prove
  them; help coverage is a native test in both directions.
- `shader-pipeline`: the bundle step stays a text transformation and no build stage compiles WGSL,
  with one narrow exception — a named-field struct constructor fails the build, because it is
  detectable in the text alone and it is the mistake this codebase invites.

## Impact

- `src/sim_registry.nim`, `src/shader_manifest.nim`, `src/webgpu_compute.nim` — couplings, frame
  composition, bind-group entry counts.
- `web/shaders/src/forces.wgsl`, `forces-sph.wgsl`, `field-force.wgsl`, `field-deposit.wgsl` —
  reset-prologue removal, atomicAdd, splat, chemistry scaling, density attenuation, smoothing radius.
- `web/shaders/src/render.wgsl`, `tonemap.wgsl`, `field-composite.wgsl`, `fade.wgsl`, `glow.wgsl` —
  field-as-light, camera transform, reprojection, the visible-size floor.
- `src/webgpu_render.nim`, `src/webgpu_init.nim` — repeat samplers, glow floor removal.
- `src/physics_core.nim`, `src/sph_core.nim`, `src/climate_core.nim` — the crowding attenuation and
  its density ceiling, the smoothing-radius fraction and its stability bound, the parameterised
  waypoint tour.
- `src/web_api.nim`, `src/canvas_input.nim`, `src/ui/input/`, `src/config_ranges.nim`,
  `src/gpu_types.nim`, `src/field_core.nim`, `src/ui/api/param_descriptor.nim`.
- `src/ui/api/response_probe.nim` (new, pure) — the probe registry, contexts, and the
  span/live/cliff metrics.
- `src/glow_core.nim`, `src/trail_core.nim` (new, pure) — render-side reference oracles.
- `src/ui/api/slider_curve.nim` (new, pure) — position↔value mapping and its inverse.
- `src/ui/api/help_content.nim` (new) — `staticRead` of `docs/help/*.md`, keyed by group id.
- `src/ui/input/binding_table.nim` (new, pure) — the single gesture/key table help renders from.
- `src/wgsl_lint.nim` (new, pure) and `tools/wgsl_bundle.nim` — the named-field constructor check.
- `src/camera_core.nim` — the composed visible-size chain as a pure function, floored at its end.
- `src/ui/state/matrix_state.nim`, `src/preset.nim` — matrix bounds consumed from the range
  authority instead of holding copies.
- `web-ui/src/` — preset row replacing the mode selector, chemistry editor, `ParamSlider` gaining
  notches, curve, highlight, dormancy, and overlay behavior; `MatrixEditor` gaining the
  uncommitted-edit state; a new `HelpPanel`.
- `docs/help/*.md` (new) — the help and feature documentation source.
- `tests/` — `test_field_core.nim`, `test_sim_registry.nim`, `test_param_descriptor.nim`, and new
  `test_camera_core.nim`, `test_response_probe.nim`, `test_slider_curve.nim`, `test_glow_core.nim`,
  `test_trail_core.nim`, `test_help_content.nim`, `test_wgsl_lint.nim`.

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
- Choosing the number the one particle budget settles on. This change collapses three unmeasured
  ceilings into one, which is a structural fix; what that one number should be is a measurement, and
  it belongs with the performance work rather than here.
- A 2D climate pad. Every factor stays a slider; the named-regime selector supplies the coordinates.
- Removing the double-click blast. It stays: it is an input the user aims, not an automatic
  mechanism, and the density cap does not replace the ability to disturb a world on purpose.
- Changing what SPH pressure does. Tait pressure already repels above rest density and is correct;
  the fault is the scale it acts at, not the law.
- Measuring anything through the GPU. Every probe is a pure Nim mirror of shader math, in the
  reference-oracle style the codebase already uses. A probe that disagrees with its shader is a
  reference-oracle defect, and it is caught the same way every other oracle drift is caught: by
  someone editing one side and not the other. This change does not close that gap and does not claim
  to.
- General build-time WGSL validation. The lint added here catches one class detectable in the text.
  A bundled shader that declares a binding the pipeline does not provide, or names a missing entry
  point, still passes the build and fails on the device, exactly as before.
- A registry of which render passes run under which settings. The conditionally-consumed defect
  class is answered here by a declared dormancy predicate the user can read, not by making the
  render path's dispatch conditions data. That stronger guarantee would be its own change; the
  residual is stated in the design rather than papered over.
- A perceptual model. "Noticeable" here means the response metric moves by more than the calibrated
  threshold, not that a human eye resolves it. The thresholds are calibrated against controls whose
  liveness is not in dispute, which is what makes them defensible; they are not psychophysics.
- Tutorials, onboarding tours, or first-run walkthroughs. Help is a panel the user opens.
- Localization. Help and labels are English, authored in one place.

## Sequencing

`tasks.md`'s "Order of work" is the one authority on what happens next, and it carries the reasoning.
Three facts belong here because they shape what this proposal promises rather than merely when.

**The strength collapse comes first.** Both the crowding attenuation and the SPH scale ask how
strongly a coupling acts, and that question only has an answer once strength is a number rather than
a boolean. Dormancy predicates over a coupling strength can only name a strength that exists. So the
one-world break (D7, D13) precedes the work that depends on it, and everything independent of it —
the probes, the curves, the generated dispatch, the matrix editor, the whole help pipeline — is
free to land in any order.

**The force weather adds a table, not a loop.** `climate_core` generalises once into a parameterised
tour, and the force parameters supply a second waypoint table for it. Two loops of the same shape is
exactly the duplication D11 exists to remove.

**Fluid strength is a new multiplier, and this was an open question that closed.** Promoting the
existing stiffness was considered and ruled out: it does not scale the fluid's entire contribution,
since the viscosity and XSPH terms carry no stiffness factor (`forces-sph.wgsl:254-255`), so a world
at stiffness zero still has a fluid acting on it. D14 introduces a strength that multiplies the
pass's whole velocity contribution, which is what makes skip-at-zero honest.
