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
  bandWidth: float32            ## proximity's reach either side of the surface; enclosure's is twice it
  proximity: float32            ## signed: toward the surface
  enclosure: float32            ## signed: resists crossing; positive pushes escapees back in, negative pushes intruders out
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

### D4. Two forces from one evaluation, both with a finite reach

```
  n     = surface direction at p, pointing outward
  u     = abs(d) / bandWidth
  fall  = smoothstep(0, 1, 1 - u)                  # 1 at the surface, 0 at the band edge
  hold  = smoothstep(0, 1, 1 - abs(u - 1))         # 0 at the surface, 1 at the band edge, 0 at 2 bands
  Fprox = -sign(d) * n * proximity * fall
  Fencl = -n * enclosure * step(0, d * sign(enclosure)) * hold
  F     = (Fprox + Fencl) * envelope[i] * params.bodiesStrength
```

Summary: proximity reaches one band from the surface, enclosure reaches two bands, and past two
bands a body hands a particle exactly nothing.

`smoothstep` rather than a linear ramp so the force's derivative is zero at the band edge too. A
particle drifting across the edge feels neither a step in force nor a corner in it. `climate_core`
makes the same choice for its easing, for the same reason (`docs/one-world.md:319-328`).

Enclosure is one signed number, not a pair of strengths and not an enum. It resists crossing
rather than pulling from within. Positive pushes back what has got out and gives exactly zero
everywhere inside, which is the step gate above. Negative pushes back out what has got in. Zero does
neither. Zero is an ordinary value reached by moving
a slider, which is the one-world rule at parameter scale. The hold rises over the band rather than
acting as a hard wall, which makes the tunnelling bound (D13) a band-width relation rather than an
impulse relation. It peaks at the band edge and falls off over a second band past it.

**Reversal.** This decision first specified `saturate(abs(d) / bandWidth)`: a ramp over the band and
full strength beyond it, "so an escaped particle is always brought back". That law never falls off,
so a positive hold pulled every particle outside the body at full strength across the whole torus.
The diagnosis probe measured 10.000 at 400, 1000 and 1800 from the centre at Hold 10
(`scratchpad/parametric-bodies/diagnosis__13-09-26-report.md`, section 2).

The reaction then drags each body toward everything it pulls. The drag is capped per substep
(`web/shaders/src/body-integrate.wgsl:75-83`), so every body converges on the population. In the
running app, Wild Bodies 1/s at Hold 10 gathered all 128 000 particles into one mass within six
seconds at 7 FPS (`scratchpad/parametric-bodies/in-app__13-09-26-1616.md`, observation 3). The law
also contradicted the spec's local reading of enclosure and the Body Reach help line. The old law
was C0 only, with corners at the surface and at the band edge. The user chose a falloff past the
band over the two alternatives below.

**The profile.** `hold` is one smoothstep bump over `u ∈ [0, 2]`:

- Its slope is zero at the surface, where the inside is identically zero.
- Its slope is zero from both sides at the band edge, where it peaks.
- Its slope is zero at two bands, where it meets zero.

So the force is C1 at every point a particle can cross, and it has compact support. At half a band,
`hold` equals the old linear ramp exactly (`smoothstep(0.5) = 0.5`). That is why the `bodies.netHold`
probe, which samples there, never saw the reach.

**The handoff.** `smoothstep(x) + smoothstep(1 - x) = 1`. Inside the band, where proximity and
enclosure push the same way, their sum is `|P|·fall + |E|·hold ≤ max(|P|, |E|)`, and at `P = E` it is
flat across the band. Past the band only the hold acts. So one body's impulse on one particle never
exceeds `BODY_FORCE_CEILING · bodiesStrength · envelope` per reference frame, at any point and any
sign combination. The earlier `2 · BODY_FORCE_CEILING` in `BODY_MAX_FORCE_PER_PARTICLE` was an
over-count, and D16 states the tighter bound as an interface.

**The length: one band past the band, derived from `bodyBand`.** The reach is set by the control
whose help line already says "how far the forces carry". It adds no slider, no preset field, no
probe and no record field. It scales with the one number a player already uses to say how far a
body carries.

**Torus.** Distance is the minimum image (D3), so the reach is measured to the nearest image and a
particle feels at most one image of a body. A body whose reach shell spans more than half the world
on an axis covers that axis. That is a size a player chose, and nothing clamps it.

**Anisotropy.** The shell is `d < 2·bandWidth` in the evaluation's own distance. Outside an ellipse
that distance satisfies `t · s_short / s_long ≤ d ≤ t` against the true distance `t`, because the
scaling is bi-Lipschitz with those two constants. So the shell reaches at most
`2 · bandWidth · s_long / s_short` in true distance along the long axis, four times the round
body's reach at `BODY_ANISOTROPY_CEILING`. A scratch probe restating the law marched outward over
3600 bearings on a body at anisotropy 4, radius 100 and band 50. The farthest non-zero force sat
399.8 from the surface, against the bound of 400 (`scratchpad/parametric-bodies/falloff_probe.nim`,
section 2). So the bound holds and is attained. The first red test of task group 10 holds it in the
suite.

The probe met a second fact on the way. At radius 240 the long semi-axis plus the reach passes half
the world's height, and the minimum image wraps the shell onto the far side of the body. That is the
torus paragraph above, reached at a size a player can pick.

**What a player gives up: capture has a speed.** In continuous time, with every other force set
aside, a particle leaving the surface outward at speed `v` is stopped inside the shell iff
`v² < 240 · |E| · bodiesStrength · envelope · bandWidth`. That comes from integrating
`120 · |E| · hold` over `[0, 2·bandWidth]`, whose integral is `bandWidth`. The 120 is
`1 / FRAME_DT_REFERENCE` (`src/physics_core.nim:23`).

| Hold | Band | Escape speed |
|---|---|---|
| ceiling | shipped default 120 | about 537 |
| ceiling | floor | about 245 |
| 1 | shipped default 120 | about 170 |
| about 0.35 | shipped default 120 | about 100, the particle speed ceiling |

So a strong hold recaptures every particle the speed cap admits, and a weak hold lets the fastest
escapees go for good. A scratch probe stepped a one-dimensional particle at reference-frame
substeps, with no friction, cap or pair force, and bisected the largest speed that stops inside the
reach. It matched the formula to the first decimal at all four rows: 536.7, 244.9, 169.7 and 100.4
(`scratchpad/parametric-bodies/falloff_probe.nim`, section 1). Friction and the speed cap both help
capture. The pair force and the app's longer substeps are outside that check.

Options for enclosure's reach, each with what it sacrifices:

| Option | Sacrifice | Verdict |
|---|---|---|
| Full strength past the band (the original law) | Every body pulls the whole world; bodies converge; measured collapse | Rejected by the user |
| Zero at the band edge, the ramp ending where proximity ends | An escapee past the band is never recaptured, and a positive hold becomes a wall met only on the way out | Rejected by the user |
| **Smoothstep bump, falloff length = `bodyBand`** | Capture has an escape speed (above); reach is tied to Body Reach and cannot be set apart from it | **Chosen** |
| Falloff length = body radius | Reach grows with size and not with the control named for reach, so the help line is wrong again; a large body at the radius ceiling reaches 800 past its band | Rejected |
| Falloff length = the pair-force interaction radius | Couples a body to an unrelated control; `body_core` sits upstream of that state and would need one more uniform | Rejected |
| A new `bodyHoldReach` slider | An eighth descriptor, help line, probe, preset field and record field against D12's seven. Its zero would put a step at the band edge (ramp to one, fall over nothing), so zero stops being an ordinary value unless the profile is redrawn around it | Rejected for this cut; the route stays open as one field |
| A fixed world-unit constant | A number derived from nothing; a small body and a large one reach the same distance | Rejected (article 8) |
| Exponential or Gaussian tail | Never reaches zero, so the world is still reached, only more quietly, and "no particle past the reach moves" cannot be stated | Rejected |
| Inverse-square tail | Sums the world's mass; convergence stays | Rejected |
| Linear falloff | Corners at the band edge and at the reach edge | Rejected |
| Smootherstep (C2) | Nothing reads a second derivative; semi-implicit Euler is content with C1 | Rejected |

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

The largest per-particle contribution is one `BODY_FORCE_CEILING`, not two. D4's handoff identity
means proximity and enclosure never sum past the larger of the two. `BODY_MAX_FORCE_PER_PARTICLE`
is restated at one ceiling, and a sweep test holds `bodyForceAt` under it (D16). That loosens the
assertion's headroom and moves no user-facing range.

Rejected: reusing `FIXED_POINT_SCALE`. It would silently wrap under a full crowd, and wrapping shows
as a body flung across the world — a bug that looks like physics.

Rejected: floating-point accumulation with `atomicCompareExchangeWeak` loops. Fixed point with
`atomicAdd` is what every other accumulator here uses, and a CAS loop under 128 000 contenders on one
word is the worst contention case in the frame.

### D8. Where the passes sit in the frame

One node, two dispatches, per substep, guarded by `acts(couplings.bodies)`:

```nim
if acts(couplings.bodies):
  result.add computePassNode("Bodies", PROFILER_SLOT_BODIES, @[
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

Chosen: a profiler slot of its own, `PROFILER_SLOT_BODIES`, mirroring `gpu_profiler.passBodies`.
This reverses the original choice of `PROFILER_SLOT_NONE`, which left task 9.3's per-frame cost
unreadable: no other instrument separates this pass from the frame. The slots still mirror
`gpu_profiler.nim` by hand, and no test holds that pairing (`src/sim_registry.nim:252-257`), so the
slot adds one more unenforced two-sided agreement. `tests/test_sim_registry.nim` holds the Nim-side
slots distinct, which long-range-mesh added for `PROFILER_SLOT_LONG_RANGE`. The figure reaches the
`[gpu-profile]` console record and the stats push.

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

The band's floor, `BODY_BAND_MIN`, is a stated literal, `25.0`, in `src/config_ranges.nim`, not
derived from this rig. Containment falls to the substep plan instead: a live body's `bodyBand` sets
the travel bound `T`, and the plan raises the substep count to `⌈speedCap · ff / T⌉`. At
`SUBSTEPS_MAX` the count stops and the effective speed cap drops to `T · 3 / ff`, so per-step travel
stays inside the band either way, with no stored value touched.

The response to instability is ordered: mass from area first (already in D9), then damping, then the
per-substep impulse cap. A lowered user-facing ceiling is not on the list.

Proven versus designed: nothing in this decision is proven. It is the one place in this change where
a measurement, not a reading, settles the question, which is why it precedes the feedback tasks
rather than following them.

**The gate's blind spot, and its correction.** The sweep measures one body under one crowd
pre-placed in a wedge spanning ±0.9 of a band about the surface (`tests/test_body_core.nim`,
`runCrowdPush`). It passed with world-reaching enclosure, and it would pass again, because its
question is whether a body's speed stays bounded. The in-app collapse was not a speed failure. It
was a reach failure: particles far outside every band were pulled in, and bodies were dragged across
the world toward them. No crowd outside the band existed in the rig, and no second body did either.

So the gate gains two relations, both in task group 10:

- A reach relation: past `2 · bandWidth` the force is exactly zero, for either sign, round or
  elongated, including across a world edge.
- A two-body relation: two holding bodies with a crowd lying beyond both reaches stay exactly where
  they were. A control with the crowd moved inside one body's reach shows that body moving, so the
  test can see motion.

The sweep's wedge widens to span `[-0.9, +1.9]` bands so the falloff is inside the measured space.
The force law is premise 3, so the sweep re-runs.

The tunnelling suite's note ("enclosure saturates … an escaped particle is always brought back")
is corrected in the same group. At half the derived floor the crossing now lands at the reach's
end, where the hold is zero, rather than at a wall at full strength. The spec scenario that the
fastest particle is turned back is restated at the enclosure ceiling, where the escape speed of D4
exceeds the speed cap.

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
pass; the bodies profiler slot (D8) turns it into one, and the first in-app run is where the number
arrives.

### D16. What bounds a body's pull, stated as an interface

Once the reach is finite, three numbers bound what a body does. Another change needs them. A
density-rising pressure term that must out-push every outside pull (`coupling-balance`, not yet
scaffolded) reads them as its input, so they are a spec requirement rather than prose.

**Per particle, per body.** The impulse one body hands one particle is at most
`BODY_FORCE_CEILING · bodiesStrength · envelope` velocity units per reference frame. Per substep
that is `frameFactor(dt)` times as much, bounded overall by `BODY_MAX_FORCE_PER_PARTICLE`. At the
ceilings it is 10 per reference frame, in either direction, inward or outward. The handoff identity
of D4 is what makes this one ceiling rather than two.

**Region.** The impulse is non-zero only where the evaluation's distance satisfies
`|d| < 2 · bandWidth`, and additionally `d ≥ 0` for positive enclosure's part and `d ≤ 0` for
negative enclosure's part. In true world distance that shell is at most
`2 · bandWidth · max(anisotropy, 1/anisotropy)` from the surface (D4, Anisotropy; measured at 399.8 against 400 in
`scratchpad/parametric-bodies/falloff_probe.nim`). Everywhere
else the body contributes exactly zero, not a small value.

**Per particle, all bodies.** Contributions add across slots, so a particle inside `k` overlapping
shells receives at most `k` times the per-body bound. The worst case is `MAX_BODIES = 32` shells
overlapping with aligned normals, which is 320 per reference frame at the ceilings. The bound is
stated at its worst.

**Per body, reaction.** A body's reaction is the negated sum over the particles inside its shell. It
is bounded by the population in the shell times the per-particle bound. The body's response to it is
capped per substep by `BODY_MAX_SPEED_CHANGE` and settles under the D13 ceiling
`cap · frames · d / (1 − d)`. Only particles inside the shell can pull a body. So a body drifts
toward a one-sided crowd within `2 · bandWidth` of its surface and is blind to everything farther
away.

Normalization considered and rejected, each with its sacrifice:

| Option | Sacrifice | Verdict |
|---|---|---|
| **None: per-particle bound, finite region, reaction capped per substep (D9)** | Total pull on a crowd grows with the crowd inside the shell, and density inside a held body is bounded by nothing in this change | **Chosen** |
| Divide each particle's pull by the count in reach | Needs a counting pass or a previous-substep count buffer, so evaluation is no longer one per body per particle. One particle's force would depend on the whole crowd: a lone escapee feels the full hold and a dense crowd is barely held, which inverts what a hold is for | Rejected |
| Divide the reaction by the count in reach | Breaks "reaction is exactly the negation of action" (spec), so a pass could push particles a body does not feel. The per-substep cap already bounds what the reaction can do | Rejected |
| Divide by the envelope integrated over a lifetime | A long-lived body becomes a quieter one, against D10's "a longer life buys more of this, never a louder body" | Rejected |

What this change does not bound: density. A body at ceiling hold still gathers everything inside its
shell into its interior. Several bodies near one crowd can drift together through it. In a scratch
closed loop, two holding bodies 1200 apart, at Hold 10 with Skin Pull 6, drew together to 465.8
over 600 frames at 60 Hz. They shared a 128 000-weighted clump reaching into both shells. With the
clump kept beyond both shells their separation stayed exactly 1200
(`scratchpad/parametric-bodies/falloff_probe.nim`, section 3). The global convergence D4's reversal names is gone. Whether local gathering still costs
the pair-force pass what observation 3 recorded is unmeasured until 9.2 re-runs. A bound on
concentration belongs to the pressure term, which consumes this interface.

**Probe.** `bodies.netHold` sums the outward-signed force at ±half a band
(`src/ui/api/response_probe.nim`, `bodyEnclosureProbe`). There the new hold equals the old ramp, so
the probe cannot tell a finite reach from an infinite one. It becomes an integral of the
outward-signed force over a window symmetric about the surface, `w = min(2 · bandWidth, radius)`
each side, sampled at `RefBodySamples`:

- Symmetry keeps proximity's antisymmetric contribution cancelling.
- The inside half keeps the sign dead-free across the whole track.
- At the shipped slice (radius 240, band 120) the window is exactly the reach.

`bodies.band`'s fixed path lengthens from `BODY_BAND_MAX` to `2 · BODY_BAND_MAX` so the widest
reach fits on it. Both probes stay linear in their slider. `tests/test_response_probe.nim` rewrites
`docs/control-legibility-report.md` on every run, so the report follows.

**Help.** `docs/help/35-bodies.md` today says of `bodyBand` "this says how far the forces carry from
it", and the old hold contradicted that. The line becomes true once it says both reaches: the pull
toward the surface carries one band, and the hold is strongest one band out and gone at two. The
`bodyEnclosure` line gains that a particle carried farther than that is let go.

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
- **A held body still gathers what its shell holds.** → The reach is finite (D4) and the pull is
  bounded per particle and per region (D16), but concentration inside a body is not bounded here.
  The interface D16 states is what a density-rising pressure term reads. Task 9.2 re-observes
  Hold 10 under Wild Bodies after group 10 lands.
- **A weak hold lets fast particles go.** → By design (D4, capture has a speed). The escape speed
  exceeds the particle speed ceiling for any hold above about 0.35 at the default band (100.4 at
  0.35, `scratchpad/parametric-bodies/falloff_probe.nim`, section 1).
- **A body ignited at the world's edge.** → Every displacement is minimum-image and the integrate
  wraps, so an edge body behaves like any other. The risk is that one of the several places doing
  this arithmetic forgets; the property tests in `tests/test_body_core.nim` are what catch it.
- **The generator makes the world busy.** → Its rate floor is zero and its default is chosen
  conservatively. The world igniting shapes nobody asked for is the failure mode a player notices
  first.

## Settled decisions

Eleven questions this design opened. The first ten were answered before the first task, and the
eleventh after the in-app run. They are recorded rather than
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
8. **The bodies node carries its own profiler slot, `PROFILER_SLOT_BODIES`**, and sits after Field
   Force and before Integrate (D8). The slot is what makes the pass's cost measurable, at the price
   of one more unenforced two-sided agreement with `gpu_profiler.nim`.
9. **The envelope is its own buffer**, not a field of the body record, because the two have different
   writers on different cadences (D6).
10. **Names:** the capability is `parametric-bodies`, the help file is `docs/help/35-bodies.md`.
11. **Enclosure falls off past the band** (13-09-26, the user's decision after the in-app collapse).
    It keeps recapturing near escapees and does not reach the world: a smoothstep bump peaking at the
    band edge and reaching zero at twice the band, with the length derived from `bodyBand` (D4). The
    user rejected both zero at the band edge and world reach. No range was clamped to get here.
