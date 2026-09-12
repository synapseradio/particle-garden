# parametric-bodies design

## Context

See proposal.md for motivation and scope, and `specs/parametric-bodies/spec.md` for the behavior
contract. The mechanics this design stands on, each proven in the running code and its suites:

- A coupling is a strength, `acts` is the only place a strength is compared to anything
  (`src/sim_registry.nim:83-87`), and a coupling-owned pass is skipped at exactly zero. The fourteen
  steps of adding one are written out at `docs/one-world.md:188-284` and `fluidStrength` is the most
  recent walk through all of them.
- Every coupling floor is held at zero by a static loop (`src/config_ranges.nim:451-457`), which this
  change extends from four floors to five.
- A reader pass is one thread per particle, sample, `atomicAdd` into `velocityDelta`
  (`web/shaders/src/field-force.wgsl`). The frame owns every delta buffer's clear
  (`docs/one-world.md:158-186`).
- Uniform layouts are Nim tables with explicit offsets, swept against WGSL's own layout algorithm at
  compile time (`src/gpu_types.nim:684-703`), and their WGSL structs are generated from those tables
  (`tools/wgsl_bundle.nim:245`). `SpeciesChemistryLayout` is the worked example of a coupling with a
  block of its own.
- A frame's dispatch sizes are symbolic and the executor resolves them; `dsOne` already exists for
  the prefix-sum's single-workgroup stage (`src/sim_registry.nim:134`, dispatched at `:272`).
- The weathers are the precedent for a self-mover: a phase advanced on capped wall-clock delta from
  the frame loop, writing through the ordinary clamped path (`src/app.nim:266-269`,
  `src/climate_core.nim`).
- A pointer gesture converts to world space at capture and dispatches to a pure handler
  (`src/canvas_input.nim:172-179`, `src/ui/input/mouse_handler.nim:59`).
- Workgroup sizes are Nim data reaching WGSL by placeholder (`src/shader_config.nim:19-34`,
  `:83-95`, `:142-155`).
- Buffer sizing is an exhaustive `case` (`src/webgpu_compute.nim:841-851`) and bind groups validate
  their entry counts at creation (`:45-58`, `:60-76`, `:204-211`).

Two facts differ from the working assumptions this change was framed under, and the code wins:

1. **Readback is not absent.** Two asynchronous readback paths exist — the field's alive-cell census
   (`src/webgpu_compute.nim:647-660`, `:927-942`) and the profiler's timestamps
   (`src/gpu_profiler.nim:116-142`). Both skip a frame when their previous map is still busy. The
   three "no readback" comments in the tree are each scoped to the render path
   (`src/app.nim:299-301`, `:398`, `src/webgpu_render.nim:1-4`). So the case for GPU-owned pose is
   not "readback is impossible" but "the only readback shape this repo has is late-or-absent
   telemetry, and a pose is neither" (D5).
2. **`src/config_ranges.nim` has no range type.** Bounds are plain `<NAME>_MIN` / `<NAME>_MAX`
   consts (`:35`, `:41`, `:55-56`). The bodies bounds follow that convention; nothing declares a
   record.

Everything under Decisions is designed and unexercised until its tests run. Two things are proven
before any of it: the reader-pass shape, which `field-force.wgsl` ships, and the coupling walk, which
`fluidStrength` ships. Everything specific to bodies — the SDF, the force laws, the rigid step, the
slot allocator, the generator — is designed only, and the feedback loop in particular is gated on a
measurement that has not been taken (D13).

## Goals / Non-Goals

**Goals:**

- A first cut small enough that one person holds all of it: one strength, three buffers, two shaders,
  one pure Nim module, one descriptor group. Nothing here is an abstraction over passes.
- A body that can be pushed, because that is what makes it a coupling rather than an obstacle.
- Every number in Nim, including the ones no slider shows: the ceiling, the fixed-point scales, the
  envelope proportions, the generator's cadence, and the bounds on the three ignition parameters.
- A shape for the generator that can be lifted out whole. It is the last task group, touches
  `src/app.nim`, the generator's own section of `body_core`, and one range, and nothing before it
  depends on it.

**Non-Goals:**

- A second primitive family. The design names where it would go (D3) and builds none.
- Collision between bodies, contact sets, constraint solving, or anything that would make this a
  rigid-body engine. A body is a mood.
- Rasterizing a body into the chemistry or a long-range density. The research doc's "one object acts
  at two ranges" (`docs/research/long-range-coupling.md:218-220`) stays a later composition.
- Links between particles. This design's one obligation toward them is D14.
- Drawing bodies. Settled decision 1: a body shows only through the particles it moves.

## Decisions

### D1. Module layout

One new pure module, two new shaders, and the ordinary coupling wiring.

- `src/body_core.nim` — pure, native, imported by the JS side and by the tests. Holds the SDF, the
  two force laws, the envelope, the slot allocator, the rigid step, the generator's cadence, and
  every constant the shaders read by placeholder. It is a reference oracle in the sense
  `docs/enforcement.md:58-79` records: it mirrors the two shaders, and the pair is held by review.
- `web/shaders/src/body-force.wgsl` — one thread per particle, the shape of `field-force.wgsl`.
- `web/shaders/src/body-integrate.wgsl` — one thread per body.

Rejected: folding the body math into `physics_core.nim`. That module mirrors `forces.wgsl` and
`integrate.wgsl` and its header says so; a second shader pair inside it would make the oracle table's
one-mirror-one-shader relation a lie, and that table is already hand-maintained
(`docs/enforcement.md:58-79`).

Rejected: no pure module at all, with the math living only in WGSL. The measurement gate (D13) needs
to sweep the feedback loop over the whole particle budget, which the native suite can do and the
browser cannot. Without the mirror there is no gate, and the proposal's one unproven claim stays
unproven.

### D2. What a body is, and where each part lives

```nim
# src/body_core.nim — offsets declared in gpu_types.nim, generated into WGSL
Body = object
  centerX, centerY: float32     ## world coordinates, wrapped to the torus
  velX, velY: float32           ## GPU-owned; only body-integrate writes these
  angle, angVel: float32
  radius: float32               ## semi-axis along the body's x
  anisotropy: float32           ## semi-axis along y, as a multiple of radius
  bandWidth: float32            ## proximity's reach either side of the surface
  proximity: float32            ## signed: toward the surface
  enclosure: float32            ## signed: positive holds in, negative keeps out
  invMass, invInertia: float32  ## derived from area at ignition, not stored twice
```

Per-body shaping travels on the body rather than in the uniform block because a body ignited at one
setting keeps that setting while the slider moves on — a body is a thing that happened, and the
slider is the world's disposition at the moment it happened. The pass-wide numbers — body count, the
`bodies` strength, the substep timestep, the impulse cap, the fixed-point scales — sit in a
`BodyParamsLayout` uniform.

Three of a body's numbers reach it from the ignition rather than from a slider:

```nim
BodyShaping = object
  anisotropy: float    ## 1.0 is a circle; above and below are ellipses
  envelopeSkew: float  ## redistributes the fixed proportions between rise and fall
  sustain: float       ## the level decay falls to, held until release
```

`envelopeSkew` and `sustain` together are the envelope's shape; `anisotropy` is the body's. Each is
bounded in `src/config_ranges.nim` like every other number in this repo and clamped against those
bounds at ignition (D11), so the bound holds whether the caller is the panel, the generator, or a
later MIDI row. None of the three is a descriptor, so none draws a slider (D12).

`invMass` and `invInertia` are computed once at ignition in Nim from the body's area rather than
recomputed per frame in WGSL, and stored inverted so the shader divides nothing.

Rejected: putting the shaping parameters in the uniform block and leaving only pose on the body. It
is smaller, and it makes every live body change shape when a slider moves, which makes each body a
view of the panel rather than an event in the world.

Rejected: spending pad words in `SimParamsLayout` (`src/gpu_types.nim:148-204`, total size 688) as
`fluidStrength` does at offset 60. There are too many pass-wide numbers for a pad word, and
`SpeciesChemistryLayout` is the worked example of the second route (`docs/one-world.md:251-258`).

### D3. The SDF: one anisotropic disc, exact in sign, bounded in distance

```
  q = rot(-angle) * minimumImage(p - center)      # into body space, toroidal
  s = vec2(radius, radius * anisotropy)
  d = (length(q / s) - 1) * min(s.x, s.y)         # signed; exact when anisotropy == 1
```

The division by the smaller semi-axis is the standard Lipschitz correction: the returned value is a
lower bound on the true distance, never an overestimate, and it is exactly the true distance for a
circle. The three facts the forces use — the sign, the direction `normalize(q / s²)` rotated back,
and the ordering of distances — are all exact under that scaling. Nothing in this capability reads an
absolute distance, which is why the bound suffices; a requirement in the spec says so, so a later
consumer that does need a true distance is a spec change rather than a silent error.

Rejected: the exact ellipse SDF. It is a quartic root find per particle per body, iterative in every
published form, and it buys a number nothing here reads.

Rejected: a union of primitives per body (a `min` over shapes). The first cut is one shape per body;
a union is a body count away.

Where a second family goes: one more branch on a `kind` field in the record and one more arm in the
evaluation, both in `body_core` and its shader mirror. Nothing else changes — not the buffers, not
the frame, not the forces. That is the extension this design leaves open and does not build.

### D4. Two forces from one evaluation

```
  n     = surface direction at p, pointing outward
  fall  = smoothstep(1, 0, abs(d) / bandWidth)     # 1 at the surface, 0 at the band edge
  Fprox = -sign(d) * n * proximity * fall
  Fencl = -n * enclosure * step(0, d * sign(enclosure)) * saturate(abs(d) / bandWidth)
  F     = (Fprox + Fencl) * envelope[i] * params.bodiesStrength
```

`smoothstep` rather than a linear ramp so the force's derivative is zero at the band edge too — a
particle drifting across the edge feels neither a step in force nor a corner in it. The same choice
`climate_core` makes for its easing, and for the same reason (`docs/one-world.md:319-328`).

Enclosure is one signed number, not a pair of strengths and not an enum. Positive holds particles
inside, negative keeps them out, zero does neither, and zero is an ordinary value reached by moving
a slider — the one-world rule at parameter scale. It ramps over the band rather than acting as a hard
wall, which is what makes the tunnelling bound (D13) a band-width relation rather than an impulse
relation.

Rejected: a hard positional correction (projecting a particle back to the surface). It writes
position, and the only pass that writes position is `integrate`. A force composes with every other
force in the frame; a projection overrules them all and makes the bodies pass unskippable in
practice.

Rejected: separate `holdInside` and `keepOutside` strengths. Two numbers where one sign does, and
they admit a meaningless combination (both non-zero) that nothing could interpret.

### D5. Nim owns time; the GPU owns pose

| Fact | Home | Why |
|---|---|---|
| Which slots are live, and since when | Nim | Computable from the wall clock alone |
| Envelope value per slot | Nim, uploaded per frame | Pure, natively testable, and the one number the lifetime slider shapes |
| Center, angle, both velocities | GPU | Only the integrate writes them, and reading them back would need a synchronization the frame does not have |
| Shape and per-body strengths | Written once at ignition | A body keeps what it was ignited with (D2) |

Nim never reads a body. It knows a body's ignition time and its lifetime, so it knows the
lifetime without observing anything, which is what keeps slot allocation pure and testable. The
envelope upload is one contiguous `writeBuffer` of `MAX_BODIES` floats per frame — 128 bytes at
`MAX_BODIES = 32` — beside the uniform writes the executor already performs in `runPhysicsFrame`
(`src/webgpu_compute.nim:662` onward, uniform writes at `:723-764`).

The upload happens every frame regardless of the `bodies` strength. Skipping it at zero would be a
second site comparing a strength to zero, and 128 bytes is not worth a second site.

Ignition writes one slot's record at a byte offset. `queue.writeBuffer` is ordered against submitted
command buffers on the same queue, so an ignition between frames lands before the next frame's
dispatch rather than racing it.

Rejected: pose on the CPU, with the accumulators read back. That is the only design that makes a body
a Nim value end to end, and it costs a per-frame GPU-to-CPU synchronization. The two readback paths
this repo has are asynchronous and skip a frame when busy (Context, fact 1); a body whose position
arrives late or not at all stutters.

Rejected: the envelope on the GPU, advanced by the integrate. It removes the per-frame upload and
costs Nim its knowledge of when a slot frees, which would then need a readback — the thing this
design is avoiding. Time is the one thing both sides can compute independently, so Nim keeps it.

### D6. Three buffers, and why not two or four

- `sbBodies` — `MAX_BODIES * sizeof(Body)`, storage, read by both passes, written by
  `body-integrate` and by Nim at ignition.
- `sbBodyEnvelope` — `MAX_BODIES * 4`, storage, written by Nim every frame, read by both passes.
- `sbBodyAccum` — `MAX_BODIES * 3 * 4`, atomic `i32`, cleared by the frame, filled by `body-force`,
  consumed by `body-integrate`.

Each gets a `SimBuffer` value and an arm in `byteLengthFor` (`src/webgpu_compute.nim:841-851`), whose
exhaustive `case` makes a missing arm a compile error.

The envelope is separate from the body record because the two have different writers on different
cadences: the record is GPU-written and CPU-written-once, the envelope is CPU-written every frame. A
per-frame `writeBuffer` into a strided field of a GPU-written struct would need `MAX_BODIES` separate
writes and would race the integrate's writes to neighbouring fields of the same struct.

Rejected: folding the accumulator into the body record as atomic fields. A struct cannot hold atomics
and plain floats in the same WGSL binding usefully, and the frame's clear owns a whole buffer
(`fnkClearBuffer` takes a `SimBuffer`, `src/sim_registry.nim:90-127`), so an accumulator sharing a
buffer with pose would have its pose cleared every frame.

### D7. The accumulator's own fixed-point scale

`velocityDelta`'s scale is sized for one particle's own contributions. One body's word can receive a
contribution from every particle in the world in one dispatch — up to `MAX_PARTICLES = 128000`
(`src/memory_layout.nim:37`). A static assertion in `body_core` relates the budget, the largest
per-particle contribution the ranges admit, and the scale, and fails the compile if their product
leaves `int32`:

```nim
static:
  doAssert float(MAX_PARTICLES) * maxBodyForcePerParticle() * BODY_FIXED_POINT_SCALE <
    float(high(int32)), "widening a bodies range overflows the body accumulator"
```

The torque word needs the same treatment with the world's half-diagonal as the lever arm, since
torque is force times distance and the distance is bounded by the minimum image.

Rejected: reusing `FIXED_POINT_SCALE`. It would silently wrap under a full crowd, and wrapping shows
as a body flung across the world — a bug that looks like physics.

Rejected: floating-point accumulation with `atomicCompareExchangeWeak` loops. Fixed point with
`atomicAdd` is what every other accumulator here uses, and a CAS loop under 128 000 contenders on one
word is the worst contention case in the frame.

### D8. Where the passes sit in the frame

One node, two dispatches, per substep, guarded by `acts(couplings.bodies)`:

```nim
if acts(couplings.bodies):
  result.add computePassNode("Bodies", PROFILER_SLOT_NONE, @[
    dispatch("bodyForce", dsParticleWorkgroups),
    dispatch("bodyIntegrate", dsOne),
  ])
```

placed after the Field Force node and before Integrate (`src/sim_registry.nim:341-352`). The pass
reads particle positions and writes `velocityDelta`, exactly like `fieldForce`, so its position among
the contributors is free; last among them means the body's integrate closes on the same substep's
forces rather than the previous one's. `sbBodyAccum`'s clear joins the per-substep clears at the top
(`:258-266`).

Two dispatches in one node rather than two nodes: a node carries one cadence and these share one, and
dispatches inside a compute pass are ordered with the memory barriers WebGPU inserts between them —
the same guarantee `binCount` → `prefixLocal` → `prefixBlocks` → `prefixFinal` already rests on
(`:269-274`). `dsOne` is correct for `bodyIntegrate` because `MAX_BODIES` does not exceed that pass's
workgroup size, which a static assertion holds (D15).

**The skip at zero is exact, and the argument is worth writing down.** A body's own motion is
observable only through forces the `bodies` strength scales. At zero, a frozen body and a drifting
body are indistinguishable, so dropping the integrate removes nothing. This is the opposite of the
field, which evolves visibly and is therefore world-intrinsic (`docs/one-world.md:79-95`). The
argument has one premise: bodies are not drawn. Making them visible makes the integrate intrinsic,
and the landmine is recorded as such.

`sameFrameShape` gains the strength (`src/webgpu_compute.nim:133-141`), or the frame never notices
the crossing.

Rejected: appending `bodyForce` to the Physics node. It would share `PROFILER_SLOT_PHYSICS`, folding
the bodies cost into the number the stats panel shows as physics, and hiding exactly the cost this
change adds.

Rejected: a profiler slot of its own. The slots mirror `gpu_profiler.nim` by hand with no test
holding the pairing (`src/sim_registry.nim:181-186`), so a new slot adds an unenforced two-sided
agreement. `PROFILER_SLOT_NONE` is what Field Force already carries.

### D9. The rigid step: the plainest one that is stable

```
  impulse = accum.force  / BODY_FIXED_POINT_SCALE   # a velocity impulse; the substep's frame is in it
  tau     = accum.torque / BODY_TORQUE_FIXED_SCALE
  frames  = frameFactor(dt)
  dv      = impulse * invMass,  its length capped at BODY_MAX_SPEED_CHANGE * frames
  dw      = tau * invInertia,   clamped to ±BODY_MAX_SPIN_CHANGE * frames
  vel     = (vel    + dv) * pow(linearDamping,  frames)
  angVel  = (angVel + dw) * pow(angularDamping, frames)
  center  = wrapToTorus(center + vel * dt)
  angle   = angle + angVel * dt
```

Semi-implicit Euler: velocity first, then position from the new velocity. It is unconditionally more
forgiving than explicit Euler at the same cost, it is what `integrate.wgsl` already does for
particles, and a body is a mood. The accumulated reaction is the negation of the velocity impulses
the particles received, which already carry the substep's frame, so no timestep multiplies it; a
second `dt` would make a frame's effect scale as the square of the frame length over the substep
count. Damping and the change caps run on the reference-frame count, the unit every force constant
in the repository is measured in, so neither the frame rate nor the substep count changes how fast a
body settles. `src/body_core.nim`'s `bodyRigidStep` is the oracle the shader mirrors and the group 2
sweep measured.

`invMass` scales as `1 / (radius² * anisotropy)`: a big body is hard to push, a small one skitters,
and the relation is the physical one rather than a curve someone drew. `invInertia` follows the
ellipse's `m (a² + b²) / 4`.

The per-substep impulse cap is the mechanism the measurement gate is allowed to reach for (D13). It
bounds what one substep may do to one body without bounding what a user may ask for, which is the
distinction `docs/engineering-principles.md:75-82` draws.

Rejected: velocity Verlet. It needs the force at the new position, which means evaluating the
particle pass twice or storing the previous force — a fourth buffer for a body that is a mood.

Rejected: a body speed cap as the stability mechanism. A cap makes the loop stable by truncating it,
and the truncation is visible as a body that stops accelerating mid-flight. Damping is continuous.
A cap derived from the particle speed cap stays available as a last resort if the sweep demands it.

Rejected: infinite mass for bodies above some size. That is a mode with a floating-point door.

### D10. The envelope: one lifetime, fixed proportions, a shape carried at ignition

One duration reaches the panel — `bodyLifetime` — and the four phases divide it by proportions held
as constants in `src/body_core.nim`:

```nim
const ENVELOPE_PROPORTIONS* = (attack: 0.15, hold: 0.25, decay: 0.25, release: 0.35)
static: doAssert abs(sum(ENVELOPE_PROPORTIONS) - 1.0) < 1e-9
```

so lifetime is exactly the sum of the four phases by construction rather than by a user's arithmetic.
The static assertion is what keeps that true if the proportions are ever retuned. `envelopeSkew`
redistributes weight between the rise (attack, hold) and the fall (decay, release) without changing
the total, so the lifetime stays known at ignition however the shape is skewed — which is the
property slot allocation is built on (D5). `sustain` is the level decay falls to.

Four sliders became one for a reason worth stating: the four durations are not four independent
choices a player makes. A player chooses how long a body lives; the split between rise and fall is
the body's character, which is an ignition-time property like its shape, not a setting of the world.
The curve stays linear within each phase and smoothstep-eased at every junction, so the value is
continuous and its derivative has no corner.

Rejected: four duration sliders. It is what the envelope diagram in the research doc draws
(`docs/research/long-range-coupling.md:204-214`), and on a panel it is four controls whose only
interesting quantity — the total — is not any of them, and which can be set to sum to something
absurd with no single slider being wrong.

Rejected, for this cut: sustain-until-release, where a held gesture extends the hold indefinitely. It
is the musically right answer and it costs the property D5 is built on — Nim would no longer know a
body's lifetime at ignition, and slot allocation would need either a second write path per release or
a readback. The design leaves room: a release-time word written into the slot when a gesture ends
keeps lifetime CPU-computable, and that is one field and one write path, not a restructure.

### D11. Ignition: one entry, two sources, one clock

```nim
proc igniteBody*(state: var BodyState; atX, atY: float; shaping: BodyShaping;
                 nowSeconds: float): bool
```

returns whether a slot was found. `shaping` is clamped against its Nim-owned bounds inside this
proc, not by the caller, so the bound holds for every source at once — the panel's gesture, the
generator, and any later row that calls the boundary. This is the boundary-validation article applied
to a call that is not a parameter write (`docs/engineering-principles.md:11-20`). Every source calls
it:

- `gardenAPI.igniteBody(x, y)` — added beside the other boundary methods
  (`src/web_api.nim:1167`, installed at `:1405`), taking world coordinates and filling `shaping` from
  the generator's current draw so a player's body and the world's own look alike. MIDI and audio,
  when they arrive, are two more callers of this and nothing else.
- A canvas gesture — a modifier-held primary press, converted to world space at capture and
  dispatched through the binding table.
  That is what the blast gestures do (`src/canvas_input.nim:172-179`, `:204-212`) and not what the
  live cursor does: a one-finger press stays in canvas pixels and `app.nim` converts it per frame
  through the current camera (`src/canvas_input.nim:202-203`). An ignition pins a moment to a world
  point, so it belongs with the former.
- The generator — a phase advanced on capped wall-clock delta from the frame loop, beside the
  weathers (`src/app.nim:266-269`).

The generator draws position and shaping from a seeded sequence: one pure `uint64` state advanced per
ignition, mapped onto the world rectangle and onto the shaping bounds. Seeded rather than sampled
from a runtime source, so a sequence of ignitions is reproducible in the native suite — the cadence
tests assert what the world ignites, not merely that it ignited. It is also the only source that
needs nothing else to exist: noise, audio features, and the weather's cadence are the alternatives
the research doc lists (`docs/research/long-range-coupling.md:259-263`), and the audio one would tie
this change to a sibling still in flight.

The generator's rate is its own parameter with a floor of zero; zero means the world ignites none. It
does **not** read the `bodies` strength: `acts` is the only place a strength is compared to anything
(`src/sim_registry.nim:83-87`), and a body ignited into a world at zero strength costs a slot and
moves nothing. A player's ignition resets the generator's phase, so the world does not fire on top of
a gesture.

Rejected: three ignition paths with their own slot logic. The allocator is the one thing that must
not disagree with itself.

Rejected: gating the generator on the coupling strength. It would put a second zero-comparison in the
tree and `tests/test_no_modes.nim` exists because that is how modes come back.

### D12. The `bodies` descriptor group: seven sliders

`bodiesStrength` leads, the way `fluidStrength` leads `fluid` (`docs/one-world.md:206-210`), then
`bodyRadius`, then the forces (`bodyBand`, `bodyProximity`, `bodyEnclosure`), then `bodyLifetime`,
then the world's turn (`bodyIgnitionRate`). Seven, each a `floatParam`
(`src/ui/api/param_descriptor.nim:358-374`). `web-ui/src/components/Panel.tsx` gains a
`groupIds("bodies")` loop, without which `tests/test_panel_reachability.nim` fails the native suite.

The line between a slider and an ignition parameter is what the user holds while the world runs
versus what a body is born with. Strength, size, reach, the two force signs, how long a body lives,
and how often the world makes one are dispositions a player adjusts and hears immediately.
Anisotropy, envelope skew, and sustain are a body's character, fixed when it ignites (D2, D10), so
they are arguments to `igniteBody` and not controls. They keep Nim-owned bounds in
`src/config_ranges.nim` regardless, clamped at ignition (D11) — a number without a slider is still a
number this repo owns.

Rejected: exposing all twelve. Four envelope durations plus sustain plus anisotropy is a panel where
the parameters that decide whether the feature reads at all sit among six that shade it, and the
group stops teaching what a body is. Rejected too: dropping the bounds for the three unexposed
numbers because no slider clamps them — `igniteBody` is a boundary and validates like one.

`docs/help/35-bodies.md` carries one line per descriptor in the shape `docs/help/30-fluid.md` sets,
plus a closing paragraph naming the three ignition parameters in bold, the convention a help file
uses for an id no descriptor resolves. `tests/test_help_content.nim` ranges over the descriptor table,
so the seven are test-held and the three bold names are review-held.

`src/preset.nim` gains the seven settings (`:104-155`, `:214-288`, `:367` onward, `:728-776`) — the
shipped disposition, not a body. No `LEGACY_MODE_COUPLINGS` row: a mode that never existed cannot
have written a preset.

### D13. The measurement gate

The gate is a native sweep in `tests/test_body_core.nim` over the pure mirror, run before any
feedback task is written. It follows the shape `tests/test_field_core.nim:970` onward sets for the
chemotactic-collapse bound: precompute the runs, assert the property, keep the warranting constants
named beside the suite (`:987`, `:1004`, `:1007`).

Swept: crowd size to `MAX_PARTICLES`, `bodiesStrength` across its range, proximity and enclosure
across theirs, band width, body area across its range, substep count. Measured: whether the body's
speed and angular speed settle. Recorded: in `docs/perf-report.md` under the table shape that file
uses (`:86`, `:134`), with the conditions a stranger needs — and the sweep's docstring names the four
premises whose movement re-runs it (budget, ceiling, force law, substep count).

A second bound falls out of the same rig and costs nothing extra: the band's floor. A particle at the
speed cap crossing an enclosing surface must land inside the band on some substep, or it tunnels.
That is `bandWidth >= speedCap * maxSubstepDt`, derived rather than chosen, stated beside the
constant.

The response to instability is ordered: mass from area first (already in D9), then damping, then the
per-substep impulse cap. A lowered user-facing ceiling is not on the list.

Proven versus designed: nothing in this decision is proven. It is the one place in this change where
a measurement, not a reading, settles the question, which is why it precedes the feedback tasks
rather than following them.

### D14. What this design owes to links

Links are deferred (proposal, Out of scope), and the single obligation is that nothing here makes
them impossible. Two properties discharge it, and both are free:

- Bodies exert **forces**, never positional corrections (D4). A future links pass is one more
  `atomicAdd` contributor to the same buffer under the same rule, and it composes with bodies by
  addition. A body that projected particles onto its surface would overrule a link's constraint and
  the two features would fight.
- A body's surface is defined by parameters, not by a particle set, so condensation — a body
  gathering particles onto its surface as links and then letting its own strength fall to zero
  (`docs/research/long-range-coupling.md:198-201`) — reads the body's parameters and writes links,
  touching nothing in this design.

Nothing is built for links here. No hook, no reserved field, no dormant branch (engineering principle
6).

### D15. Sizing and the workgroup relation

`MAX_BODIES` lives in `src/memory_layout.nim` beside `MAX_PARTICLES` and `MAX_SPECIES` (`:37-38`),
which is where the repo keeps its ceilings. `body-integrate` gets a workgroup entry in
`WorkgroupConfig` (`src/shader_config.nim:19-34`, `:83-95`) reaching WGSL by placeholder, and a
static assertion holds `MAX_BODIES <= workgroupSize("bodyIntegrate")`. Without it, a single-workgroup
dispatch silently drops every body past the workgroup's width — a failure with no symptom except
bodies that stop moving once you ignite enough of them.

Cost: the particle pass evaluates `MAX_BODIES` SDFs per particle per substep, with an early-out on
zero envelope. At 128 000 particles and 32 slots that is 4.1 million evaluations of roughly a dozen
arithmetic ops per substep, against a worst-case measured headroom of 3.75 ms in a 16.7 ms frame
(`docs/perf-report.md:140`). That figure is a reading of the perf record, not a measurement of this
pass; the profiler slot question (D8) is what would turn it into one, and the first in-app run is
where the number arrives.

## Risks / Trade-offs

- **A crowd drives a body unstable, or the accumulator overflows.** → The gate (D13) precedes the
  feedback tasks; the overflow is a static assertion (D7). These are the two ways this change fails
  loudly, and both have a detector before the code that could trip them.
- **The per-particle cost is `MAX_BODIES` evaluations whether or not slots are live.** → The
  early-out on zero envelope makes an empty slot a branch rather than an evaluation, and the ceiling
  is small. If the measured cost is worse than the estimate above, the mechanism fix is a
  live-body-count uniform bounding the loop, not a smaller ceiling.
- **The skip-at-zero argument rests on bodies being invisible.** → Recorded as a landmine in
  `docs/enforcement.md` in the same change. Anything that makes a body observable at zero strength
  makes the integrate world-intrinsic.
- **Shader and mirror drift.** → Unenforced, like every oracle here (`docs/enforcement.md:58-79`).
  Mitigated only by changing both in one diff, which is the review flag principle 5 names.
- **Bind-group entry counts are two-sided and unenforced across the pair**
  (`docs/enforcement.md`, Two-sided agreements). → A wrong count fails GPU validation at runtime in
  the browser and nothing earlier catches it, so the in-app run is the detector for the two new
  pipelines.
- **A body ignited at the world's edge.** → Every displacement is minimum-image and the integrate
  wraps, so an edge body behaves like any other. The risk is that one of the several places doing
  this arithmetic forgets; the property tests in `tests/test_body_core.nim` are what catch it.
- **The generator makes the world busy.** → Its rate floor is zero and its default is chosen
  conservatively. The world igniting shapes nobody asked for is the failure mode a player notices
  first.

## Settled decisions

Ten questions this design opened, each answered before the first task. They are recorded rather than
dropped because each one rules out a shape someone will otherwise propose again, and two of them are
premises other decisions rest on.

1. **Bodies are not drawn.** A body shows only through the particles it moves. This is a premise, not
   a preference: the exactness of the skip at zero depends on it (D8), and making a body observable
   by any route the strength does not scale makes the body-side integrate world-intrinsic. Recorded
   as a landmine in `docs/enforcement.md` by task 9.5.
2. **A body's lifetime is fixed at ignition.** No held-gesture sustain in this cut. The property slot
   allocation rests on is that Nim knows a body's lifetime the moment it ignites (D5, D10).
3. **Seven sliders, three ignition parameters.** The panel carries strength, radius, band, proximity,
   enclosure, lifetime and ignition rate; anisotropy, envelope skew and sustain travel on the
   `igniteBody` call with Nim-owned bounds clamped at ignition (D2, D10, D12).
4. **The world's generator draws from a seeded sequence**, which is reproducible in the native suite
   and depends on nothing outside this change (D11).
5. **The generator ships here, as task group 8**, structured so it can be cut to a follow-up by
   deleting the group.
6. **The ignition gesture is a modifier-held primary press.** Double-click and two-finger tap remain
   the blast (`src/canvas_input.nim:172-179`, `:204-212`).
7. **`MAX_BODIES` is 32** — small enough for the per-particle loop, large enough that a player cannot
   exhaust it by hand, and under every plausible workgroup size (D15).
8. **The bodies node carries `PROFILER_SLOT_NONE`**, as Field Force does, and sits after Field Force
   and before Integrate (D8). A slot of its own would measure the pass and would add an unenforced
   two-sided agreement with `gpu_profiler.nim`.
9. **The envelope is its own buffer**, not a field of the body record, because the two have different
   writers on different cadences (D6).
10. **Names:** the capability is `parametric-bodies`, the help file is `docs/help/35-bodies.md`.
