# One world

There is one world. Species forces, fluid pressure, and chemistry all run in it,
at once and in any proportion, so each arrives as a continuous **strength**
rather than a switch. Zero counts as an ordinary value of a strength. A world
with no fluid runs its fluid strength at zero, reached by moving a slider, and
differs in no kind from a world running a little fluid.

This document guides adding a coupling. Read `src/sim_registry.nim` alongside it
— that file holds the authority, this holds the map.

## The four strengths

`WorldCouplings` in `src/sim_registry.nim` holds four floats. Each names a live
simulation parameter the panel writes through the ordinary descriptor path, and
`couplingsOf` in `src/ui/state/sim_config.nim` reads all four off
`SimulationState` on demand, so nothing keeps a second copy that could disagree.

| Strength | Parameter | What it scales | Shader |
|---|---|---|---|
| `forces` | `forceStrength` | species attraction and repulsion, reaching the shader as `params.forceMultiplier` | `forces.wgsl` |
| `fluid` | `fluidStrength` | the SPH pass's whole per-pair velocity contribution, pressure and smoothing together | `forces-sph.wgsl` |
| `deposit` | `rdDeposit` | how much each particle secretes into the chemical field | `field-deposit.wgsl` |
| `fieldForce` | `rdFieldForce` | how hard the field's gradient steers particles | `field-force.wgsl` |

Every one of those four ranges reaches zero. A static loop at the bottom of
`src/config_ranges.nim` fails the build if a coupling strength's floor sits
anywhere else, so each coupling can be switched off through its own slider.

`sim_config.worldCouplings` carries the derived value to the executor, and
`webgpu_compute.setCouplings` adopts it: it rebuilds the frame description when a
strength crosses zero, and does nothing when a slider moves within its range.

## The frame asks exactly one question of a strength: is it zero

`acts` in `sim_registry.nim` holds the only comparison in the frame path.
Nothing reads a magnitude, tests a threshold, or branches on a combination. A
strength one part in a billion above zero dispatches exactly what a strength of
one dispatches, and `tests/test_sim_registry.nim` asserts that directly, so a
`> 0.001` cannot slip back in as a mode with a floating-point door.

## Which passes a strength may skip

A strength may skip a pass only when it multiplies **everything** that pass
produces. Where a pass also produces something no strength scales, skipping it
removes an output the strength never owned and the world jumps at zero. Passes
therefore divide in two.

**World-intrinsic passes run at every setting of every strength.** The grid
triad (`binCount` and the three prefix-sum stages) with `binScatter`, the
neighbour sweep in `forces.wgsl`, `fieldResolve`, the `RD_STEPS_PER_FRAME`
Gray-Scott substeps, and `integrate`. These make up what the world is.

**Coupling-owned passes drop out at exactly zero.** `forcesSph` under `fluid`,
`fieldDeposit` under `deposit`, and `fieldForce` under `fieldForce`. Each
strength multiplies its pass's entire output.

### Forces are the asymmetric case

`forces.wgsl` carries three things: the species force, scaled inside the shader
by `params.forceMultiplier`; the per-particle colony density the renderer reads
for dot size, brightness and glow radius; and the mouse and blast input. Only the
first belongs to a coupling. So the pass runs world-intrinsic, no force strength
may skip it, and the neighbour sweep runs even in a world where no forces act.
The frame pays that price rather than paying a discontinuity, and the test suite
asserts the arrangement instead of leaving it assumed.

Three densities keep that split clean. `density` at particle offset 20 measures
same-species proximity and leaves the physics through the intrinsic sweep alone;
`sphDensity` at offset 24 is the fluid's kernel-weighted, species-blind reading,
private to its equation of state; `crowdDensity` at offset 28 counts every
neighbour the spatial hash counts, and the crowding cap reads it. One field
carrying two of them would make the glow track the fluid, and zeroing the fluid
would then drop the density the renderer needs — the jump-at-zero reappearing in
the density channel. The crowd channel splits off the colony one for a different
reason: a cell filled by a mixed blob costs exactly what a cell filled by one
species costs, so a cap on that cost cannot read a species-gated signal.

### The field belongs to the world

`fieldResolve` and the Gray-Scott substeps run unguarded. A field frozen
mid-pattern at zero deposit and breathing again one epsilon above it would be a
mode, and a visible one. What chemistry's strengths own is the two couplings
*between* particles and field: the deposit going in, the gradient force coming
out.

The ping-pong parity sharpens this. `fieldResolve` is itself one stage of the
field's texture swap, so a frame performs `1 + RD_STEPS_PER_FRAME` swaps in
total. `field_core.nim` statically asserts that total comes out even — that
`RD_STEPS_PER_FRAME` stays odd — because the live field must land back on the
texture the renderer, `fieldForce`, and the next frame's resolve all read.
Skipping `fieldResolve` at zero deposit would remove one swap and strand the
field on the texture nothing looks at.

## The frame is data

`buildFrame(couplings)` returns a `FrameDescription` — a `seq[FrameNode]`, where
a node takes one of three shapes:

- `fnkClearBuffer` — zero a `SimBuffer` at the encoder level.
- `fnkCopyBuffer` — copy one `SimBuffer` into another.
- `fnkComputePass` — a labelled, profiler-slotted group of dispatches.

`webgpu_compute.nim` walks that sequence and encodes it. The description carries
no GPU handles, which lets the whole pass list be asserted in a native test with
no GPU present.

Read it as a union over independent strengths, never as a table of worlds. The
intrinsic sequence always appears and always in the same order; each `acts(...)`
guard inserts one coupling's pass into it. Strip the coupling-owned keys from any
frame and exactly the intrinsic sequence remains, and
`tests/test_sim_registry.nim` states it that way — as a derivation rather than a
list — so a fifth coupling cannot reintroduce enumeration by accident.

Dispatch sizes stay symbolic (`DispatchSize`), resolved by the executor each
frame, so particle-count and grid-size changes never rebuild the description.

**Substepping is an executor loop, not frame nodes.** The executor encodes the
same description N times into one command encoder, and only a world running fluid
asks for more than one pass. A frame description always holds one substep's worth
of work.

### The order a frame composes in

1. Clear `sbVelocityDelta`, `sbDensityDelta` and `sbGridCounts`.
2. **Grid Build** — `binCount`, then `prefixLocal`, `prefixBlocks`,
   `prefixFinal`.
3. Copy `sbGridOffsets` into `sbFillPointers`, which `binScatter` consumes as
   its running write cursors.
4. **Physics** — `binScatter`, then `forces`, then `forcesSph` where `fluid`
   acts.
5. **Field (RD)** — `fieldDeposit` where `deposit` acts, then `fieldResolve`,
   then `RD_STEPS_PER_FRAME` substeps alternating `rdStepToFront` and
   `rdStepToTrail`, then `fieldForce` where `fieldForce` acts.
6. **Integrate** — `integrate`.

`integrate` closes every frame because it reads the summed deltas and moves
particles, so every contributor must already have run. It sits in its own compute
pass because the field passes have to come between it and the force pass, and one
pass cannot be in two places.

## One pipeline set

`allShaderSpecs()` in `src/shader_manifest.nim` registers every compute shader at
init, with no per-world subset. Timing decides this rather than tidiness.
Rebuilding the frame description is pure sequence construction and costs nothing;
creating a pipeline means fetching WGSL over HTTP and compiling it. Registering
only the couplings currently acting would turn a slider leaving zero into an
asynchronous operation, and the frames between the slider moving and the pipeline
arriving would dispatch against a missing dictionary entry. One compile per
shader at startup buys every strength change synchronously.

It also keeps the manifest free of enumeration. No per-world list exists to fall
out of step with `buildFrame`, and `tests/test_shader_manifest.nim` asserts the
relation that remains: every key any frame dispatches is registered, and no key
is registered twice.

## Delta buffers have one reset owner

`velocityDelta` accumulates per-particle velocity impulses as fixed-point
integers, two `i32` per particle. Three passes contribute to it: `forces`,
`forcesSph` and `fieldForce`.

`buildFrame` clears both delta buffers once at the top of the frame, and every
contributor accumulates only. The rule for any new pass that writes a delta
buffer:

> Use `atomicAdd`. Never `atomicStore`, never a plain store. The frame has
> already cleared the buffer; a store erases whatever ran before you.

A pass that self-resets in its own prologue works while exactly one contributor
runs per frame, and breaks the moment two do — whichever runs second erases the
first. That is why the reset lives in the frame.

The clears are encoder-level operations interleaved into the same ordered command
stream as the compute passes, so a clear preceding a dispatch is ordered before
it rather than racing it.

Both delta buffers get cleared every frame even when nothing writes them. One
encoder operation removes a whole class of question about what the previous frame
left behind.

`sbFieldDeposit` stays self-resetting: `fieldResolve` zeroes each cell as it
consumes it. That is also what makes skipping the deposit at zero exact rather
than merely cheap — the buffer a skipped deposit leaves behind already holds
zero.

## Adding a fifth coupling

Every step below has an existing example to copy. `fluidStrength` is the most
recent coupling to arrive and touches all of them.

Settle the multiplier question before writing any guard. Does your strength scale
everything its pass produces? If it does, the pass is coupling-owned and may be
skipped at zero. If the pass also writes something no strength scales — a
measurement, a user input, a texture the renderer samples — the pass is
world-intrinsic, the strength acts inside the shader, and the frame never changes
shape.

**1. `src/config_ranges.nim` — give the strength a range whose floor is zero.**
The static loop at the bottom of that file fails the build otherwise.

**2. `src/ui/state/simulation_state.nim` — add the field and its default** to
`SimulationState` and `initSimulationState`.

**3. `src/ui/api/param_descriptor.nim` — add a `floatParam` in the right group.**
That table is the whole panel surface: `gardenAPI.descriptor()` serves it and the
panel builds the slider from it. Lead the section with the strength and put the
parameters describing the coupling's character below it, the way `fluidStrength`
leads the `fluid` group.

A descriptor promises a control; `web-ui/src/components/Panel.tsx` decides where
it sits. A new group needs a `groupIds("<your-group>")` loop there, or its
sliders never reach the screen. `tests/test_panel_reachability.nim` reads that
file and fails the native suite for any descriptor the panel places by neither
its id nor its group, so forgetting this is a red build rather than a control
nobody can find.

**4. `src/ui/state/sim_config.nim` — read it in `couplingsOf`.** The couplings
are derived on demand, never stored.

**5. `src/sim_registry.nim` — declare it and dispatch it.** Add the float to
`WorldCouplings`, then guard its dispatch in `buildFrame` with `acts(...)`. Place
it before `integrate`, and relative to the force and field passes according to
what it reads. Add a `PROFILER_SLOT_*` constant mirroring `gpu_profiler.nim` if
it needs a compute pass of its own.

**6. `src/webgpu_compute.nim` — add it to `sameFrameShape`.** That function
decides whether a write to the simulation state rebuilds the frame. A strength
missing from it crosses zero without the frame noticing.

**7. `src/shader_manifest.nim` — name its shaders.** Add a `ShaderSpec` array and
append it in `allShaderSpecs`. Every key any frame dispatches must appear exactly
once, and `tests/test_shader_manifest.nim` checks both halves of that.

**8. `src/main.nim` — serve them.** Every compute shader is fetched over HTTP at
pipeline-init time and must be registered in the `StaticFiles` table.
Unregistered means unserved means a failed fetch. Render shaders take a different
route and are deliberately absent from that table — see CLAUDE.md's shader
section.

**9. `src/webgpu_compute.nim` — bind it.** For each new pipeline add an
`EXPECTED_BIND_GROUP_ENTRIES_*` constant, a case for its pipeline key in
`getExpectedEntryCount`, and bind-group creation in `createBindGroups` ending in
a `validateBindGroupEntryCount` call. The entry-count constant is not decoration:
a bind group whose count disagrees with its shader's bindings fails GPU
validation at runtime in the browser, and nothing earlier catches it.
`getExpectedEntryCount` returns `-1` for an unregistered key, which is how a
pipeline nobody gave a count announces itself.

**10. Uniforms, if it needs any.** The cheap route spends a pad word in an
existing layout: `fluidStrength` sits at offset 60 of `SimParamsLayout` in
`src/gpu_types.nim` and gets written beside the other per-frame uniforms. A
coupling needing its own block adds a layout table with the standard compile-time
offset validation, a `generateStructModule` call in `tools/wgsl_bundle.nim`,
buffer creation in `initPipelines`, and a per-frame write.
`SpeciesChemistryLayout` is a complete worked example of the second route.

**11. New buffers, if it needs any.** Add the enum value to `SimBuffer` and a
case to `byteLengthFor` in `webgpu_compute.nim`. That function is what the
executor consults to size a clear or a copy, and its `case` is exhaustive — a
missing entry is a compile error rather than a silently uncleared buffer. Get the
element size right: `sbVelocityDelta` is `particleCount * 8`, not `* 4`, because
it holds two `i32` per particle.

**12. Accumulate, never store.** See the rule above.

**13. `src/preset.nim` — carry it.** Add the field to `PresetSettings`, its
default to `defaultSettings`, its clamp to `validateSettings`, and its line to
`toJson`. `LEGACY_MODE_COUPLINGS` gains no row: a mode that never existed cannot
have written a preset.

**14. Tests.** `tests/coupling_space.nim` builds `ALL_COUPLINGS` from nested
loops over `COUPLING_OFF` and `COUPLING_ON`; add a level and every "for every
world" invariant in `tests/test_sim_registry.nim` and
`tests/test_shader_manifest.nim` widens to cover your coupling. Then pin the
coupling itself: add its pipeline key to the `KNOWN` list, and either to
`WORLD_INTRINSIC_SEQUENCE` if the pass is intrinsic, or — if it is
coupling-owned — to the strip list in "no world enumerates" plus a skip test in
"A Strength At Zero Skips Its Own Pass And Nothing Else". The range floor is
covered for free by `config_ranges`'s loop.

Nothing in that list opens a mode. The panel gains a slider at step 3 and the
world gains a pass at step 5, and no code anywhere names the combination.

## Presets are points in this world

A preset records a point in the one world's parameter space. Schema v2 carries
the four strengths among its ordinary settings and names no mode.

`LEGACY_MODE_COUPLINGS` in `src/preset.nim` is the only table in the codebase
that names a mode, and it describes files rather than the model: the v1 branch of
`migrate` reads it to translate a pre-2.0 preset's mode into the strengths that
mode meant. Translation rather than subtraction, because v1 serialized every
scalar unconditionally — a v1 "particle-life" preset carries a nonzero
`rdDeposit` from a slider that sat at its default while the mode hid it, so
loading it untranslated would switch chemistry on in a world that never ran any.

The starter presets are the six named Gray-Scott regimes, built in `web_api.nim`
from `config_ranges.RD_REGIMES` so a starter lands exactly on a notch the feed
and kill sliders already draw. Each runs forces and chemistry together at the
default force strength, carrying the deposit its own morphology needs — Worms and
Coral do not ignite at the default deposit at all.

## Facts about the field that are easy to get wrong

These are measured, and each is the opposite of what first-principles reasoning
suggests. The measurements live in `tests/test_field_core.nim`.

**Chemotactic collapse lives in the product of tropism and deposit, not in either
alone.** Sweeping tropism with the deposit at its ceiling finds no collapse at a
thousand times the shipped bound. Widening the deposit axis finds the boundary
immediately. `RD_DEPOSIT_MAX` is what keeps the reachable range safe;
`TROPISM_MAX` is the second line. Because the two multiply, anything that raises
the deposit ceiling spends the tropism margin too and must re-run the collapse
suite.

**Gray-Scott saturates against deposit amplitude but not against concentration.**
Its `(feed+kill)*B` sink grows linearly in B, so raising a *uniform* deposit
tenfold barely moves the field's peak. Concentrating the same deposit is a
different matter: that raises the rate per cell, and past a threshold the
autocatalytic `A*B^2` term outruns the sink and the peak runs away. Reasoning
from "Gray-Scott bounds its own inhibitor" to "no collapse is possible" is the
specific mistake this sentence exists to prevent.

**Three of the six named regimes are deposit-sustained by nature.** Spots,
Mitosis and Waves have no unforced attractor at all — at their low feed a nucleus
cannot sustain itself without continuous deposit, so those patterns exist
*because* particles feed them. Worms and Coral do have unforced attractors, but
their basin is narrow enough that a weak nucleus dies at those coordinates and
the deposit's strength, not the reaction, decides whether they appear.

**Coherence, not magnitude, ignites the field.** A single-cell deposit fails to
ignite at any amplitude the slider offers; the same total deposit spread over a
splat radius succeeds at the default. That is why the deposit splats over a
kernel and why the kernel is normalized — widening it redistributes, it never
amplifies.
