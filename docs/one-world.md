# The couplings model

One world, composed. A simulation is not one of several modes; it is a set of
independent **couplings** switched on together, and the GPU frame is built from
whichever are active.

This document is the guide to adding a coupling. It assumes you will read
`src/sim_registry.nim` alongside it — that file is the authority, this is the
map.

## What a coupling is

A coupling is one way particles interact with something. Three exist:

| Coupling | What it does | Shader |
|---|---|---|
| `forces` | Species attraction and repulsion over the spatial hash | `forces.wgsl` |
| `sph` | Smoothed-particle pressure and viscosity | `forces-sph.wgsl` |
| `field` | The Gray-Scott chemical field particles secrete into and follow | `field-*.wgsl`, `rd-step.wgsl` |

They live in `WorldCouplings` as three independent booleans. Independent is the
whole design: all eight combinations are meaningful and none needs to be
enumerated anywhere. A world running `forces` and `field` together gives
colonies that build a chemical pattern and then navigate it — that combination
is not a fourth mode someone added, it falls out of two booleans being true.

This is why the couplings are booleans rather than an enum. An enum of modes
has to name every combination, and the count doubles with each new coupling; a
set of booleans names none of them.

`SimKind` still exists, and is **only** a preset compatibility layer. Presets
serialize stable mode ids, and `couplingsFor` maps each id to the triple it
always meant. Nothing in the frame path consults it.

## The frame is data

`buildFrame(couplings)` returns a `FrameDescription` — a `seq[FrameNode]`,
where a node is one of:

- `fnkClearBuffer` — zero a `SimBuffer` at the encoder level.
- `fnkCopyBuffer` — copy one `SimBuffer` into another.
- `fnkComputePass` — a labelled, profiler-slotted group of dispatches.

`webgpu_compute.nim` walks that sequence and encodes it. The description is
pure data with no GPU handles in it, which is what lets the whole pass list be
asserted in a native test without a GPU present — `tests/test_sim_registry.nim`
pins each legacy combination's exact pass list.

Dispatch sizes are symbolic (`DispatchSize`), resolved by the executor each
frame. The description never rebuilds when the particle count or grid size
changes.

**Substepping is an executor loop, not frame nodes.** The executor encodes the
same description N times into one command encoder. A frame description is
always one substep's worth of work.

### The order a frame composes in

1. Clear `sbVelocityDelta` and `sbDensityDelta` — always, whatever is coupled.
2. If `forces or sph`: clear `sbGridCounts`, run the Grid Build pass
   (bin-count, the three prefix-sum stages), copy `sbGridOffsets` into
   `sbFillPointers`, then one force pass containing bin-scatter followed by
   whichever of `forces` and `forcesSph` are active.
3. If `field`: one pass containing `fieldDeposit`, `fieldResolve`,
   `RD_STEPS_PER_FRAME` alternating `rdStepToFront` / `rdStepToTrail`
   substeps, and `fieldForce`.
4. `integrate`, always last.

`integrate` closes every frame because it is the one pass that reads the summed
deltas and moves particles, so every contributor must already have run. It sits
in its own compute pass rather than joining the force pass because the field
passes have to come between the two, and one pass cannot be in two places.

## Why delta-buffer ownership moved to the frame

This is the constraint that made composition possible, and the one most likely
to be broken by a well-meaning edit.

`velocityDelta` accumulates per-particle velocity impulses as fixed-point
integers, two `i32` per particle. Several passes contribute to it: `forces`,
`forcesSph`, and `fieldForce`.

Each of those passes used to **reset** the buffer in its own prologue and then
write into it. That works when exactly one of them runs per frame, and it is
why the pre-composition build could only offer one coupling at a time: with two
contributors, whichever ran second zeroed the first one's work and the first
coupling silently did nothing.

So the reset moved to the frame. `buildFrame` clears both delta buffers once at
the top, and **every contributor accumulates only, atomically**. The rule for
any new pass that writes a delta buffer:

> Use `atomicAdd`. Never `atomicStore`, never a plain store. The frame has
> already cleared the buffer; a store erases whatever ran before you.

The clears are encoder-level operations interleaved into the same ordered
command stream as the compute passes, so a clear that precedes a dispatch is
ordered before it, not racing it.

Both delta buffers are cleared every frame even when nothing writes them. One
encoder operation removes a whole class of question about what the previous
couplings left behind.

`sbFieldDeposit` is the exception and stays self-resetting: `fieldResolve`
zeroes each cell as it consumes it, so nothing else needs to.

## Adding a fourth coupling

Every step below has an existing example to copy. Working through them in order
produces a coupling that composes with the three that exist.

**1. `src/sim_registry.nim` — declare it.** Add a `bool` to `WorldCouplings`.
If your coupling searches for neighbours, add it to `buildsSpatialHash` so the
grid triad runs; if its particles read a texture or a uniform instead, leave it
out and the grid is skipped.

**2. `src/sim_registry.nim` — dispatch it.** Add a branch to `buildFrame`.
Decide where in the order it belongs: before `integrate` always, and relative
to the force and field passes according to what it reads. If it needs its own
profiler slot, add a `PROFILER_SLOT_*` constant mirroring `gpu_profiler`.

**3. `src/sim_registry.nim` — give it controls.** Add a `*_GROUPS` constant and
a branch in `controlGroupsFor`. That function unions rather than concatenates,
because group ids are shared — `grid` belongs to both force couplings. Any
group id that keys a panel section rather than a slider list must also be
listed in `SECTION_ONLY_GROUPS`, or the coverage test will read it as a typo.

**4. `src/shader_manifest.nim` — name its shaders.** Add a branch to
`shaderSpecsFor(couplings)`. It deduplicates by key: registering a key twice
would create the same pipeline twice under one dictionary entry.

**5. `src/main.nim` — serve them.** Every **compute** shader is fetched over
HTTP at pipeline-init time and must be registered in the `StaticFiles` table.
Unregistered means unserved means a failed fetch. Render shaders take a
different route and are deliberately absent from that table — see CLAUDE.md's
shader section.

**6. `src/webgpu_compute.nim` — bind it.** For each new pipeline add an
`EXPECTED_BIND_GROUP_ENTRIES_*` constant, a case for its pipeline key in
`getExpectedEntryCount`, and bind-group creation in `createBindGroups` ending
in a `validateBindGroupEntryCount` call. The entry-count constant is not
decoration: a bind group whose entry count disagrees with its shader's bindings
fails GPU validation at runtime in the browser, and nothing earlier catches it —
`getExpectedEntryCount` returns `-1` for an unregistered key, which is how a
pipeline that was never given a count announces itself.

**7. Uniforms, if it needs any.** Add a layout table to `src/gpu_types.nim`
with the standard compile-time offset validation, register a generated WGSL
struct module in `tools/wgsl_bundle.nim`, create the buffer in `initPipelines`,
and write it per frame under a guard on your coupling's flag.
`SpeciesChemistryLayout` is a complete worked example.

**8. Accumulate, never store.** If your pass writes `velocityDelta` or
`densityDelta`, use `atomicAdd`. See the section above for why.

**9. New buffers, if it needs any.** Add the enum value to `SimBuffer` and a
case to `byteLengthFor` in `webgpu_compute.nim`. That function is what the
executor consults to size a clear or a copy, and its `case` is exhaustive — a
missing entry is a compile error rather than a silently unclear buffer. Get the
element size right: `sbVelocityDelta` is `particleCount * 8`, not `* 4`,
because it holds two `i32` per particle.

**10. Tests.** Add a pass-list assertion in `tests/test_sim_registry.nim` — the
existing ones pin each legacy combination exactly, and yours should pin the new
combination the same way. The control-group coverage invariant and the
ping-pong parity check pick up new couplings automatically.

### The one step this guide cannot give you

Everything above builds a coupling and dispatches it. **Switching it on from
the panel is not yet possible**, and that is a real gap rather than an omission
here.

`setCouplings(couplings)` accepts any triple and is the executor's actual
entry point, so a coupling is reachable from code the moment you write it. But
the only caller is `setActiveSimKind`, which maps a legacy `SimKind` id through
`couplingsFor` — and there are exactly three of those. The control panel offers
the same three. So a fourth coupling can be built, dispatched, and tested, and
still has no user-facing switch.

Until the panel exposes couplings directly, reach a new combination by calling
`setCouplings` from `app.nim` or by widening `couplingsFor`. Both are stopgaps,
and both are honest ones — neither pretends to be the design.

## What each starter preset dispatches

Three starter presets ship, all reaction-diffusion: **Spots**, **Stripes** and
**Worms**. Each carries a `mode` of the reaction-diffusion id, which
`couplingsFor` maps to `field` alone — so each dispatches the field frame:
`fieldDeposit`, `fieldResolve`, the Gray-Scott substeps, `fieldForce`, then
`integrate`. No grid build, because a field-only world searches no neighbours.

They differ only in their feed and kill coordinates.

## Facts about the field that are easy to get wrong

These are measured, and each is the opposite of what first-principles reasoning
suggests. The measurements live in `tests/test_field_core.nim`.

**Chemotactic collapse lives in the product of tropism and deposit, not in
either alone.** Sweeping tropism with the deposit at its ceiling finds no
collapse at a thousand times the shipped bound. Widening the deposit axis finds
the boundary immediately. `RD_DEPOSIT_MAX` is what keeps the reachable range
safe; `TROPISM_MAX` is the second line. Because the two multiply, anything that
raises the deposit ceiling spends the tropism margin too and must re-run the
collapse suite.

**Gray-Scott saturates against deposit amplitude but not against
concentration.** Its `(feed+kill)*B` sink grows linearly in B, so raising a
*uniform* deposit tenfold barely moves the field's peak. Concentrating the same
deposit is a different matter: that raises the rate per cell, and past a
threshold the autocatalytic `A*B^2` term outruns the sink and the peak runs
away. Reasoning from "Gray-Scott bounds its own inhibitor" to "no collapse is
possible" is the specific mistake this sentence exists to prevent.

**Three of the six named regimes are deposit-sustained by nature.** Spots,
Mitosis and Waves have no unforced attractor at all — at their low feed a
nucleus cannot sustain itself without continuous deposit, so those patterns
exist *because* particles feed them. Worms and Coral do have unforced
attractors, but their basin is narrow enough that a weak nucleus dies at those
coordinates and the seed's strength, not the physics, decides whether they
appear.

**Coherence, not magnitude, ignites the field.** A single-cell deposit fails to
ignite at any amplitude the slider offers; the same total deposit spread over a
splat radius succeeds at the default. That is why the deposit splats over a
kernel and why the kernel is normalized — widening it redistributes, it never
amplifies.
