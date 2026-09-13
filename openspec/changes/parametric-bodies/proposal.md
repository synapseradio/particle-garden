# parametric-bodies

## Why

Every force in this world runs between a particle and either another particle or the chemistry those
particles secrete. `WorldCouplings` holds four strengths and all four are of that kind
(`src/sim_registry.nim:67-82`): species attraction between particles, fluid pressure between
particles, the deposit particles write, the gradient that deposit steers them by. Nothing in the
garden is *other* than the population. A player who wants to draw a shape into the world has only the
blast and the mouse, and both are impulses at a point.

A parametric body is a few numbers — a center, a radius, an anisotropic scale, an angle, a strength —
whose surface is an analytic signed distance function evaluated per particle. One evaluation yields
the distance to that surface, the direction to it, and which side the particle is on. Proximity and
enclosure both fall out: attraction toward the surface inside a band, containment from the sign. The
exploration that found this calls the same shape out of the same picture as chemistry — sources,
fields, readers — and places it as the cheapest reader of all, needing no texture, no bake, and no
resolution (`docs/research/long-range-coupling.md:172-220`, "One picture" at `:222-235`).

Bodies are ephemeral by construction. A body's strength follows an attack, hold, decay, release
envelope; zero strength means the body is absent, which is the one-world rule applied one level down
(`docs/one-world.md:3-7`). And bodies are pushed back by what they touch, so a body ignited into a
crowd is a thing the crowd answers rather than a wall the crowd obeys. That is what makes this a
coupling rather than an obstacle map.

## What Changes

- **A fifth coupling strength, `bodies`.** A float on `WorldCouplings` whose range reaches zero like
  the other four, guarded by the static loop at the bottom of `src/config_ranges.nim` that fails the
  build on any coupling floor other than zero (`docs/enforcement.md:49`). At exactly zero the frame
  dispatches neither bodies pass; above it, the strength multiplies the entire output of both.
- **One SDF primitive family: the anisotropic disc.** Rotate a particle into body space, divide by
  the per-axis radii, and the unit circle's distance comes back scaled. One family covers the circle
  and the ellipse. A second primitive family — a rounded box, a ring — is a listed future extension
  and no task here builds one.
- **Two forces from one evaluation.** *Proximity*: inside a band around the surface, a pull toward
  the surface, from either side. *Enclosure*: a signed strength that resists crossing the surface.
  Positive pushes particles that have got out back in and does nothing to those inside. Negative
  pushes particles that have got in back out. Zero does neither. One signed parameter rather than
  an inside/outside switch, because zero is an ordinary value of it. Both are local. Proximity
  reaches one band from the surface. Enclosure peaks at the band's edge and falls to nothing at twice
  the band, so a body recaptures near escapees and never pulls the world. What one body can hand one
  particle, and where, is stated as a bound other couplings can rely on.
- **Bodies move and are moved.** Each body carries linear and angular velocity integrated on the GPU
  by the plainest semi-implicit step with damping. Particles that feel a body push back on it:
  the bodies pass accumulates the equal and opposite force and its torque into a per-body atomic
  accumulator, and a one-thread-per-body integrate consumes it. **This is the first pass in the
  repository dispatched per body rather than per particle or per field cell**, and the first
  accumulator whose element count is neither.
- **Body pose lives on the GPU; the envelope lives in Nim.** Readback exists in this repo, but only
  in the shape this change must not use: `readFieldAlive` maps a one-word census asynchronously and
  skips the frame entirely when the previous map is still busy (`src/webgpu_compute.nim:647-660`,
  `:927-942`), and the profiler does the same for its timestamps (`src/gpu_profiler.nim:116-142`).
  Both are telemetry that tolerates being late or missing; a body's position does not. So the GPU
  owns pose and this change adds no readback. Nim owns ignition, the envelope, and slot allocation —
  all computable from the wall clock, so Nim knows when a slot frees without ever reading the body
  back. Each frame Nim writes one small contiguous array of envelope values; at ignition it writes
  one slot's initial pose.
- **A compile-time body ceiling.** `MAX_BODIES` in Nim, with the bodies buffer, the accumulator, and
  the uniform block declared as layout tables under the compile-time offset validation that
  `src/gpu_types.nim` already applies to every GPU struct (`openspec/specs/gpu-buffer-layout/spec.md`,
  "Every GPU uniform struct is declared as a layout table").
- **Ignition from the player.** `gardenAPI.igniteBody` and a canvas gesture put a body at a world
  point. MIDI and audio are separate changes in flight (`openspec/changes/midi-interface`,
  `openspec/changes/audio-interface`) and are named here only as later sources of the same call; this
  change builds neither.
- **Ignition from the world.** When no player input arrives, a generator in Nim ignites bodies on a
  wall-clock cadence, the way `climate_core` tours the named regimes from the frame loop
  (`docs/one-world.md:305-318`). It is the last task group and is cuttable to a follow-up change
  without unpicking anything before it.
- **A `bodies` descriptor group of seven sliders, and its help file.** The strength leads the group,
  the way `fluidStrength` leads `fluid` (`docs/one-world.md:206-210`), followed by the body's size,
  the band, the two force signs, how long a body lives, and how often the world ignites one. Numbers
  that are fixed when a body is born rather than adjusted while it lives — its anisotropy and its
  envelope shape — travel on the ignition call instead, keeping Nim-owned bounds clamped at the entry.
  `docs/help/35-bodies.md` is written with the feature and names both kinds.
- **Presets carry the bodies settings and never a live body.** A preset is a point in parameter
  space; a body is a thing with a lifetime, and reloading one would be reloading a moment rather than
  a world.

No user-visible behavior is removed. Nothing here is **BREAKING**.

Out of scope, deliberately: links between particles (the research doc's representation B,
`docs/research/long-range-coupling.md:176-200`), body rasterization into a long-range density,
distance-texture baking, a second primitive family, drawing the bodies themselves, and any new
abstraction layer over passes. The design is required only not to assume links can never exist,
because condensing a body's surface into linked particles is the composition worth keeping reachable.

## Capabilities

### New Capabilities

- `parametric-bodies`: the body model (state, the SDF family, proximity and enclosure forces, the
  envelope, slot allocation), the reaction that pushes a body and the rigid integrate that consumes
  it, the ignition sources, and the measured bounds that keep a pushed body stable and an enclosing
  body untunnelable.

### Modified Capabilities

- `gpu-frame-registry`: the frame gains a fifth coupling strength and its first dispatch sized by
  neither particle count nor field cells; "Delta buffers have one reset owner" extends to an
  accumulator that is per body, carries a different fixed-point scale, and is consumed by a pass in
  the same frame that fills it; "A world serializes as its strengths" states that the bodies strength
  and its shaping parameters serialize while the live body set does not.

## Impact

- **Nim, pure.** A new `src/body_core.nim`: the SDF, the two force laws, the envelope, the slot
  allocator, and the rigid step, natively tested in `tests/test_body_core.nim`. It is the reference
  oracle for the two new shaders and registers in `docs/enforcement.md`'s oracle table
  (`docs/enforcement.md:58-79`) and in `tests/README.md`.
- **Nim, numbers.** `src/config_ranges.nim` gains the bodies ranges and the loop at its bottom gains
  a fifth floor. `src/memory_layout.nim` gains `MAX_BODIES`. `src/gpu_types.nim` gains the body and
  body-params layout tables; `tools/wgsl_bundle.nim` generates their WGSL structs.
  `src/ui/state/simulation_state.nim`, `src/ui/state/sim_config.nim` (`couplingsOf`),
  `src/ui/api/param_descriptor.nim`, `web-ui/src/components/Panel.tsx` and `src/preset.nim` take the
  ordinary fifth-coupling walk of `docs/one-world.md:188-284`.
- **Nim, frame and executor.** `src/sim_registry.nim` gains `bodies` on `WorldCouplings`, three
  `SimBuffer` values and one guarded node. `src/webgpu_compute.nim` gains `sameFrameShape`,
  `byteLengthFor`, two bind-group entry counts and the per-frame envelope write.
  `src/shader_manifest.nim` and `src/main.nim` register and serve the two shaders.
- **WGSL.** `web/shaders/src/body-force.wgsl` has the shape of `web/shaders/src/field-force.wgsl`:
  one thread per particle, sample, `atomicAdd` into `velocityDelta`. `web/shaders/src/body-integrate.wgsl`
  is one thread per body. Both obey the delta-buffer rule: accumulate, never store; the frame clears
  (`docs/one-world.md:158-186`).
- **Boundary and input.** `src/web_api.nim` gains `igniteBody`; `src/ui/input/binding_table.nim` and
  `src/canvas_input.nim` gain the gesture; `src/app.nim` gains the generator's per-frame advance
  beside the weathers it already runs.
- **Help and records.** `docs/help/35-bodies.md`, plus entries in `docs/one-world.md` (the fifth
  coupling and the new delta buffer), `docs/enforcement.md` (tier for each new guarantee) and
  `docs/perf-report.md` (the gate below).
- **Dependencies.** None added.

## Measurement gate

**A crowd cannot drive a body unstable.** Feedback is the part of this change whose feasibility is
unproven, and it is unproven in a specific way: up to 128 000 particles
(`docs/research/long-range-coupling.md:28`) may touch one body in one frame, each contributing an
impulse and a torque into one accumulator. Three failures are possible and none is visible in a
reading of the code — the accumulator overflowing its fixed-point range, the body accelerating away
under a crowd it is itself attracting, and the loop closing at the frame rate into an oscillation.

The gate is a native sweep in `tests/test_body_core.nim` over the pure mirror, run before any
feedback task: crowd size across the whole particle budget, bodies strength across its whole range,
band width, body area, and the substep count, measuring where the body's speed or angular speed
fails to settle. It follows the pattern `tests/test_field_core.nim` sets for the chemotactic-collapse
bound — sweep to the boundary, then record the conditions beside the constant the boundary warrants
(`docs/one-world.md:329-340`, `openspec/specs/parameter-range-authority/spec.md`, "A bound derived
from a measurement records that measurement beside it") — and its result is recorded in
`docs/perf-report.md` with the conditions a stranger needs to re-run it.

The response to an unstable finding is a mechanism, never a lowered ceiling: body mass derived from
its area, a damping constant, or a cap on the impulse one frame may deliver to one body, chosen so
that the whole shipped strength range is stable (engineering principle 8,
`docs/engineering-principles.md:75-82`). A second, cheaper bound comes out of the same sweep: an
enclosing body's band must be at least as wide as a capped particle's travel in one substep, or a
fast particle tunnels through the wall. Both bounds are derived from capability, and both name the
suite that re-runs when a premise moves.
