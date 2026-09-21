## Purpose

Bodies are the first thing in the garden that is neither a particle nor the chemistry particles
secrete: a handful of numbers whose analytic signed distance gives every particle, in one evaluation,
how far it is from a surface, which way that surface lies, and which side of it the particle is on.
From those three facts come proximity and enclosure. A body is ephemeral — its strength is an
envelope and zero means absent — and it is pushed by whatever it pushes, so a shape ignited into a
crowd is something the crowd answers rather than a wall the crowd obeys.

## ADDED Requirements

### Requirement: A body is a few numbers with an analytic surface

A body SHALL be a fixed-size record of scalars: a center in world coordinates, a radius, an
anisotropic scale, an angle, linear and angular velocity, and the shaping parameters its forces read.
Its surface SHALL be defined by an analytic signed distance function of a world point and those
scalars, evaluated per particle in the pass, with no distance texture, no bake, no jump flood, and no
per-body spatial structure of any kind.

The primitive family SHALL be the anisotropic disc: the particle is carried into body space by the
body's angle and per-axis radii, and the unit circle's distance is scaled back out. One family covers
the circle and the ellipse. The evaluation SHALL return an exact sign on both sides of the surface at
every scale, and a distance that is exact when the two radii are equal and a scaled bound otherwise.
The forces in this capability read the sign, the direction, and the ordering of distances, never an
absolute distance, which is what the bound is sufficient for.

Displacement from a particle to a body center SHALL be the toroidal minimum image over the world
size, so a body near a world edge acts on the particles on the far side exactly as it acts on the
particles beside it.

Enforcement — Test-held: `tests/test_body_core.nim` holds the properties rather than pinned scalars:
the sign is negative strictly inside and positive strictly outside for isotropic and anisotropic
bodies alike; the returned value is zero on the surface to within tolerance; rotating the body and
the sample point together leaves the value unchanged; and the isotropic case equals
`length(p - c) - r` exactly. The toroidal relation is held by the same suite's wrap tests, mirroring
`physics_core`'s (`docs/enforcement.md:58-79`). The shader half is Unenforced across the pair, as
every oracle is: `src/body_core.nim` is the mirror `web/shaders/src/body-force.wgsl` is written
against, and the pair drifts if a diff changes one without the other. Raised by a generated
comparison, which no oracle in this repo has yet.

#### Scenario: The sign is exact where the distance is a bound

- **WHEN** an anisotropic body is evaluated at points either side of its surface
- **THEN** the sign is negative for every interior point and positive for every exterior point,
  however elongated the body

#### Scenario: A body at the world edge reaches across it

- **WHEN** a body sits within its own reach of a world edge and a particle sits just past that edge
- **THEN** the particle's distance and direction are the same as if neither had been near an edge

### Requirement: A body's presence is an envelope, and zero means absent

Each body SHALL carry an envelope value in [0, 1] that multiplies its own contribution to every force
it exerts and every reaction it receives. The envelope SHALL run attack, hold, decay, release, and
SHALL be zero before ignition and zero again after release. A body whose envelope is zero SHALL
contribute exactly nothing and SHALL occupy no part of the world's behavior; its slot is free for the
next ignition.

A body's lifetime SHALL be a single duration, and the four phases SHALL divide it by proportions held
as Nim constants that sum to one. Lifetime is therefore the sum of the phases by construction rather
than by a user's arithmetic, and it is known at the instant a body ignites, which is what lets slot
allocation run on the clock alone. A body MAY be ignited with an envelope shape — a skew between the
rising phases and the falling ones, and the level decay falls to — and that shape SHALL redistribute
the proportions without changing their total, so lifetime stays known however a body is shaped.

The envelope SHALL be continuous across every phase boundary, so a body fades in and out rather than
appearing. Zero is an ordinary value of the envelope and no threshold SHALL be compared against it
anywhere on the force path; a body contributes what its envelope says it contributes, down to
arbitrarily small values.

Enforcement — Test-held: `tests/test_body_core.nim` holds continuity at each phase boundary, the two
zero endpoints, monotonicity within attack and within decay, and that a body's realized lifetime
equals its lifetime parameter at every admissible skew. Build-asserted: a static assertion that the
four proportions sum to one, and the lifetime range in `src/config_ranges.nim` is non-empty with its
default inside it under the checks that file already applies
(`openspec/specs/parameter-range-authority/spec.md`, "Ranges are non-empty and defaults lie inside
them").

#### Scenario: A body fades rather than appearing

- **WHEN** a body is ignited
- **THEN** its envelope rises from zero continuously, and no frame shows a step from no contribution
  to full contribution

#### Scenario: A finished body frees its slot

- **WHEN** a body's lifetime has elapsed since its ignition
- **THEN** its envelope is zero, it contributes nothing, and its slot accepts a new ignition

#### Scenario: Shaping the envelope does not change how long a body lives

- **WHEN** two bodies are ignited with the same lifetime and different envelope shapes
- **THEN** both reach zero at the same moment, having risen and fallen differently in between

### Requirement: One evaluation yields both proximity and enclosure

The particle-side pass SHALL derive both forces from the single signed distance and its direction,
and SHALL evaluate each body at most once per particle per dispatch.

*Proximity* SHALL act inside a band around the surface, pulling a particle toward the surface from
either side, with a falloff that reaches zero at the band's edge so no particle feels a step as it
enters or leaves the band.

*Enclosure* SHALL be one signed strength read against the distance's sign: it resists crossing the
surface rather than pulling from within. Positive acts only on particles outside and pushes them
back in, negative acts only on particles inside and pushes them back out, and zero does neither. It SHALL NOT be expressed as a mode, a
flag, or a pair of separate strengths, because zero is an ordinary value of it and the two behaviors
are one quantity's two signs.

Enclosure SHALL have a finite reach. On the side its sign names, it SHALL rise from zero at the
surface to its full strength at the band's edge. It SHALL then fall back to exactly zero at twice
the band's width from the surface, and SHALL contribute exactly zero at every distance beyond. The
reach SHALL be derived from the band and SHALL NOT be a separate control. Both the rise and the fall
SHALL be continuous with a continuous first derivative at the surface, at the band's edge and at the
reach's end, so no particle feels a step or a corner anywhere it crosses. Distance for the reach is
the same evaluation and the same toroidal minimum image as for the sign, so a body near a world edge
reaches across it exactly as far as it reaches elsewhere.

Both SHALL be multiplied by the body's envelope and by the `bodies` coupling strength before they
reach the velocity accumulator, and SHALL be accumulated with `atomicAdd`, never stored
(`docs/one-world.md:158-186`).

Enforcement — Test-held: `tests/test_body_core.nim` holds that proximity is zero at and beyond the
band edge, that it points toward the surface from both sides, that enclosure is zero at zero strength
for every distance, and that flipping the enclosure sign flips the force direction and nothing else.
The same suite holds the reach: at and beyond twice the band, a body at the force ceiling in both
proximity and enclosure gives exactly zero, for either enclosure sign, for a round and an elongated
body, and across a world edge. It also holds that the enclosure's slope vanishes at the surface, at
the band's edge and at the reach's end. The shader half is Unenforced across the pair, as for every
law here.
`tests/test_sim_registry.nim` holds that the bodies pass accumulates into `sbVelocityDelta` rather
than clearing it, through the suite that pins every delta buffer's single reset owner (`:171-215`).

#### Scenario: A particle crossing the band edge feels no step

- **WHEN** a particle moves from just outside a body's band to just inside it
- **THEN** the proximity force it receives grows from zero continuously

#### Scenario: Zero enclosure is an ordinary setting

- **WHEN** enclosure strength is zero
- **THEN** particles pass through the surface freely and feel proximity alone

#### Scenario: The two signs are one quantity

- **WHEN** enclosure strength is negated
- **THEN** the same particles are pushed the opposite way with the same magnitude, and no other
  behavior changes

#### Scenario: A positive hold moves no particle beyond its reach

- **WHEN** a body holds particles in at the enclosure ceiling and a particle lies outside it at twice
  the band's width from the surface or farther, anywhere in the wrapped world
- **THEN** the body gives that particle exactly zero impulse, and the body receives exactly zero
  reaction from it

#### Scenario: An escapee near the body is drawn back

- **WHEN** a particle held in by a positive enclosure has escaped to between the surface and twice
  the band's width
- **THEN** it receives an impulse toward the surface, strongest at the band's edge and fading
  continuously to zero at the reach's end

#### Scenario: A crowd beyond every reach leaves the bodies where they are

- **WHEN** two holding bodies sit apart and a crowd lies beyond both of their reaches
- **THEN** neither body moves, the distance between them is unchanged, and the crowd receives
  nothing from either

### Requirement: A body's pull on a particle is bounded in size and in region

What one body can do to one particle SHALL be stated, as an interface other couplings may rely on.
A coupling that must out-push every outside pull, such as a density-rising pressure term, reads this
interface.

The impulse one body hands one particle SHALL NOT exceed the body force ceiling times the `bodies`
strength times the body's envelope, per reference frame. That bound SHALL hold at every point and
for every combination of proximity and enclosure signs, including where the two act the same way.
The largest admissible per-particle contribution the accumulator bound reads SHALL be that same
single ceiling scaled by the largest substep's frame factor.

The impulse SHALL be non-zero only within the shell where the body's evaluated distance lies within
twice the band's width of the surface. Every particle outside that shell SHALL receive exactly zero
from that body. Contributions from several bodies SHALL add, so a particle inside `k` shells
receives at most `k` times the per-body bound, and at most `MAX_BODIES` times it anywhere.

The reaction a body receives SHALL come only from particles inside its shell. The body's response
to that reaction is bounded per substep by the change caps the stability gate warrants.

No normalization by crowd size SHALL be applied to either the impulse or the reaction: each
particle feels its own bounded force, and reaction stays the exact negation of action.

Enforcement — Test-held: `tests/test_body_core.nim` sweeps sample points across and beyond the
shell over both force signs at their ceilings, several bands, radii and anisotropies. It holds that
the force's magnitude never exceeds the per-body bound. It holds that the force is exactly zero
wherever the evaluated distance is at least twice the band. It holds that along an elongated body's
long axis the force is zero past twice the band times the ratio of its semi-axes, on a body small
enough that its shell does not wrap the torus. Its test "overlapping bodies add and a body out of
reach adds nothing" holds the overlap scenario: a body whose shell excludes the particle contributes
exactly zero, and the particle's slot-order total equals the in-shell bodies' separate forces added.
Unenforced across the pair: the summing loop itself lives in the shader, and the mirror has no
multi-body entry. Build-asserted: the accumulator overflow assertion reads the same single-ceiling
contribution.

#### Scenario: Proximity and enclosure at their ceilings never sum past one ceiling

- **WHEN** a body carries proximity and enclosure both at the force ceiling and a particle lies
  anywhere within its band on the side both act
- **THEN** the impulse it receives is at most one force ceiling times strength and envelope per
  reference frame

#### Scenario: Overlapping bodies add, and nothing else does

- **WHEN** a particle lies inside the shells of several live bodies
- **THEN** its impulse is the sum of each body's bounded contribution, and bodies whose shells it
  lies outside contribute exactly nothing

### Requirement: The bodies strength scales the whole coupling and skips both passes at exactly zero

`bodies` SHALL be a coupling strength on `WorldCouplings` whose range reaches zero
(`src/config_ranges.nim:451-457` gains a fifth floor), and SHALL multiply the entire output of both
bodies passes: the forces particles receive and the reaction bodies receive. Both passes are
therefore coupling-owned and SHALL be skipped at exactly zero, tested by `acts` and by nothing else
(`src/sim_registry.nim:83-87`).

The bodies' own motion SHALL be observable only through forces the strength scales. That is what
makes skipping the body-side integrate at zero exact rather than merely cheap: a frozen body and a
drifting body are indistinguishable while nothing they touch is moved by them. A change that made a
body observable by any other route — drawing it, rasterizing it into a field, reporting its pose —
would make the integrate world-intrinsic, and the skip would become a discontinuity at zero.

Enforcement — Test-held: `tests/test_sim_registry.nim` gains `bodies` to the strip list in "no world
enumerates" and a skip case in "A Strength At Zero Skips Its Own Pass And Nothing Else" (`:100-158`),
and `tests/coupling_space.nim` gains a fifth level so every "for every world" invariant widens from
16 worlds to 32 (`tests/coupling_space.nim:25-33`, `tests/test_shader_manifest.nim:40-42`).
Build-asserted: the floor is covered by the static loop at `src/config_ranges.nim:451-457`.

#### Scenario: Zero bodies strength dispatches neither bodies pass

- **WHEN** `bodies` is exactly zero and every other strength is non-zero
- **THEN** the frame contains neither the particle-side bodies dispatch nor the body-side integrate,
  and is otherwise unchanged

#### Scenario: A strength barely above zero dispatches both

- **WHEN** `bodies` is one part in a billion above zero
- **THEN** the frame dispatches exactly what it dispatches at full strength

### Requirement: A body is pushed by the particles it pushes

For every impulse the particle-side pass gives a particle, it SHALL accumulate the equal and opposite
impulse into that body's force accumulator and the corresponding torque, taken about the body's
center over the toroidal minimum-image displacement, into its torque accumulator. Both SHALL be
accumulated with `atomicAdd` in fixed point, and the frame SHALL own the accumulator's reset
(`docs/one-world.md:158-186`).

A one-thread-per-body integrate SHALL consume those accumulators and advance each body's pose by the
plainest semi-implicit step: linear and angular acceleration from the accumulated impulse divided by
a mass and a moment of inertia derived from the body's area, damping applied to both velocities, then
position and angle advanced and the position wrapped to the torus. A body is a mood, not a physics
benchmark: no constraint solver, no contact set, no collision between bodies.

Reaction SHALL be exactly the negation of action before any damping, so the pass has no way to give
particles a push the body does not feel.

Enforcement — Test-held: `tests/test_body_core.nim` holds equal-and-opposite as a property over
random particle placements — the summed particle impulse plus the accumulated body impulse is zero to
within fixed-point resolution — and holds that a body with symmetric particles around it receives
zero net force and zero net torque. `tests/test_sim_registry.nim` holds that the accumulator is
cleared by a frame node ahead of the pass that writes it and consumed by the integrate in the same
frame.

#### Scenario: A one-sided crowd moves the body

- **WHEN** particles gather on one side of a body and are attracted to its surface
- **THEN** the body accumulates a net impulse toward them and its center moves that way

#### Scenario: A symmetric crowd leaves the body still

- **WHEN** particles surround a body symmetrically at equal distance
- **THEN** the accumulated force and torque are zero to within fixed-point resolution and the body's
  pose is unchanged

### Requirement: A crowd cannot drive a body unstable

The bounds on body mass, damping, and the maximum impulse one substep may deliver to one body SHALL
be derived from a measurement, not guessed, and the measurement SHALL be recorded beside the
constants it warrants along with the conditions a stranger needs to re-run it
(`openspec/specs/parameter-range-authority/spec.md`, "A bound derived from a measurement records that
measurement beside it").

The sweep SHALL cover the whole reachable space of the feedback loop: crowd size up to the particle
budget (`MAX_PARTICLES = 128000`, `src/memory_layout.nim:37`), `bodies` strength across its whole
range, enclosure and proximity across theirs, band width, body area across its range, and the substep
count. The measured quantity is whether the body's speed and angular speed settle rather than grow
without bound over a run long enough to show the trend.

Where the sweep finds instability, the response SHALL be a change to the mechanism — a mass that
scales with area, a damping constant, a per-substep impulse cap — chosen so the whole shipped range
is stable. A user-facing ceiling SHALL NOT be lowered to fit an implementation limit
(`docs/engineering-principles.md:75-82`).

Any change to the particle budget, the body force law, the substep count, or the strength ceiling
re-runs this sweep, and the recorded conditions SHALL name it so.

Enforcement — Test-held: `tests/test_body_core.nim` suite over the pure mirror, run by `just test`
and `just check`; the recorded conditions live beside the constants in `src/config_ranges.nim` and
the run itself in `docs/perf-report.md` under the table shape that file already uses (`:86`, `:134`).

#### Scenario: The full budget pushing one body settles

- **WHEN** the whole particle budget is placed across one body's reach, from inside its band to
  twice the band outside it, at the strength ceiling
- **THEN** the body's speed and angular speed settle to bounded values rather than growing

#### Scenario: A premise moves and the bound is re-earned

- **WHEN** the particle budget, the strength ceiling, the force law, or the substep count changes
- **THEN** the sweep passes at the new values or `just test` fails

### Requirement: An enclosing body cannot be tunnelled

An enclosing body's band SHALL be at least as wide as the distance a particle at the speed cap
travels in one substep, so no particle can cross the surface without a substep placing it on the
rising part of the enclosure, inside the band. That floor SHALL be derived from the speed cap and
the substep timestep rather than chosen, and the derivation SHALL be stated beside the constant.

Because enclosure's reach is finite, whether an escaping particle is turned back depends on the hold's
strength as well as the band: a weak hold lets a fast particle through its reach. The floor
guarantees the particle meets the hold, not that every hold stops it.

Enforcement — Test-held: `tests/test_body_core.nim` holds that a particle launched at the speed cap
across an enclosing surface lands on the rising part of the hold, at the narrowest band the range
allows and the largest timestep the substep range allows. At half that floor the same crossing lands
at the end of the reach, where the hold is zero.

#### Scenario: The fastest particle is still contained

- **WHEN** a particle at the speed cap travels straight out through an enclosing body's wall, with
  enclosure at its ceiling, the band at its narrowest and the timestep at its largest
- **THEN** the particle is turned back and does not leave the body's reach

### Requirement: The body accumulator cannot overflow its fixed-point range

The per-body accumulator SHALL use a fixed-point scale of its own, distinct from the per-particle
velocity accumulator's, because up to the whole particle budget contributes to one body's word while
each particle's word receives only its own contributions. A static assertion SHALL hold that the
particle budget times the largest per-particle contribution the ranges admit, times that scale, fits
the accumulator's integer type.

Enforcement — Build-asserted: the assertion sits beside the scale's definition in the pure core and
fails the Nim compile on any range, budget, or scale change that breaks it.

#### Scenario: Widening a range that would overflow fails the build

- **WHEN** a range change makes the worst-case accumulated value exceed the accumulator's type
- **THEN** `just happen` fails at the Nim compile

### Requirement: Nim owns ignition, the envelope, and slots; the GPU owns pose

Body pose — center, angle, and both velocities — SHALL live in GPU memory and be advanced only by the
body-side integrate. Nim SHALL NOT read a body back. Ignition SHALL write one slot's initial record,
and each frame Nim SHALL write one contiguous array of envelope values, one per slot.

Slot allocation SHALL be computable from the wall clock alone: Nim knows a body's ignition time and
its lifetime, so it knows when the slot frees without observing anything the GPU holds. This is
what keeps the coupling free of a per-frame synchronization. The two readback paths this repository
has — the field's alive-cell census (`src/webgpu_compute.nim:647-660`, `:927-942`) and the profiler's
timestamps (`src/gpu_profiler.nim:116-142`) — are both asynchronous telemetry that skips a frame when
its previous map is still busy, and a body's pose tolerates neither lateness nor absence.

Igniting into an occupied slot SHALL be refused rather than silently overwriting a live body, and the
refusal SHALL be observable to the caller.

Enforcement — Test-held: `tests/test_body_core.nim` holds the allocator's properties — a slot is
reused only after its full lifetime has elapsed, a full table refuses a new ignition, and the free
count is exactly the ceiling minus the live count at every clock value. Unenforced: that no code adds
a body-pose readback; nothing detects one. Raised by a sweep for `mapAsyncRead` outside the two
telemetry sites, which no test performs.

#### Scenario: A slot is reused only when its body has finished

- **WHEN** ignition is requested while every slot holds a body still inside its envelope
- **THEN** the ignition is refused and no live body's record is overwritten

#### Scenario: Nim tracks the population without reading the GPU

- **WHEN** bodies have been ignited and their envelopes have expired
- **THEN** Nim reports the correct free-slot count having performed no buffer map

### Requirement: The body count has a compile-time ceiling

`MAX_BODIES` SHALL be a Nim constant, and the bodies buffer, the accumulator buffer, and the envelope
buffer SHALL all be sized from it. The body record and the bodies uniform block SHALL be declared as
layout tables carrying explicit offsets, validated at compile time against WGSL's own layout
algorithm by the sweep `src/gpu_types.nim:684-703` already runs over every uniform layout, and their
WGSL structs SHALL be generated from those tables rather than written by hand
(`tools/wgsl_bundle.nim:245`).

A static assertion SHALL hold that `MAX_BODIES` does not exceed the body-integrate pass's workgroup
size, which is what makes a single-workgroup dispatch (`dsOne`) correct for that pass.

Enforcement — Build-asserted: the offset sweep at `src/gpu_types.nim:684-703`, the ceiling assertion
beside `MAX_BODIES`, and `byteLengthFor`'s exhaustive `case` (`src/webgpu_compute.nim:841-851`),
which makes a buffer added without a byte length a compile error rather than a silently uncleared
buffer. Derived: the WGSL structs, generated from the Nim tables.

#### Scenario: A declared offset that disagrees with WGSL fails the build

- **WHEN** a field is added to the body record without correcting the declared offsets
- **THEN** `just happen` fails at the Nim compile

#### Scenario: Raising the ceiling past the workgroup fails the build

- **WHEN** `MAX_BODIES` is raised above the body-integrate workgroup size
- **THEN** `just happen` fails at the Nim compile

### Requirement: Bodies ignite from a player and from the world through one entry

Ignition SHALL have exactly one entry point in Nim, taking a world position and the shaping the new
body carries, and every source SHALL reach the world through it.

Shaping that no slider exposes — the body's anisotropy and its envelope shape — SHALL travel on that
call, and the entry point SHALL clamp each against bounds owned in `src/config_ranges.nim` before the
body is written. Clamping SHALL happen inside the entry point rather than in any caller, so one bound
holds for the player's gesture, the world's generator, and every later source at once. A number
without a slider is still a number this repository owns, and the boundary that admits it validates it
(`docs/engineering-principles.md:11-20`).

The boundary SHALL expose that entry
on `gardenAPI` beside its other methods (`src/web_api.nim:1167`, installed at `:1405`), and a canvas
gesture SHALL reach the same entry through the binding table. The gesture SHALL convert to world
coordinates at capture, as the gestures that pin a moment to a world point already do
(`src/canvas_input.nim:172-179`, `:204-212`), rather than staying in canvas pixels like the live
cursor: an ignition places a body where the player pressed, and a camera move afterward must not drag
it with the screen.

The world's own generator SHALL ignite bodies on a wall-clock cadence advanced from the frame loop,
the way the climate tour advances (`src/app.nim:266-269`). Its rate SHALL be its own parameter with a
floor of zero, and zero SHALL mean the world ignites none. The generator SHALL NOT read the `bodies`
coupling strength: a strength is compared to zero in exactly one place (`src/sim_registry.nim:83-87`)
and igniting a body that pushes nothing costs a slot and nothing else.

A player's ignition SHALL take precedence over the generator's for the slot it claims, and SHALL
reset the generator's cadence so the world does not ignite on top of a player's gesture.

Enforcement — Test-held: `tests/test_body_core.nim` holds the cadence's advance and its zero rate, and
that a player ignition resets the phase. Build-asserted: the panel typecheck, since a `gardenAPI`
method the panel calls but the boundary does not declare fails `tsc --noEmit`
(`openspec/specs/gardenapi-boundary/spec.md`, "One object carries the whole boundary").
Agent-checkable: that the canvas gesture reaches the entry in the running app — an agent launches
`./main --serve`, drives the gesture through Claude in Chrome, and watches particles gather where it pressed.

#### Scenario: A rate of zero silences the world's generator

- **WHEN** the generator's rate is zero and no player input arrives
- **THEN** no body is ignited, however long the world runs

#### Scenario: The generator runs whatever the coupling strength is

- **WHEN** the generator's rate is non-zero and `bodies` is zero
- **THEN** bodies still ignite, occupy slots, expire on schedule, and move nothing

#### Scenario: A player's gesture displaces the world's turn

- **WHEN** a player ignites a body
- **THEN** the generator's cadence restarts from that moment rather than firing immediately after

#### Scenario: Out-of-range shaping is clamped at the entry, not refused at the caller

- **WHEN** any source calls the ignition entry with an anisotropy or an envelope shape outside its
  bounds
- **THEN** the body is created carrying the nearest admissible value, and no caller had to know the
  bound

### Requirement: A preset carries the bodies settings and never a live body

Presets SHALL carry every descriptor of the bodies group among their ordinary settings, and SHALL
carry no body. A preset records a point in parameter space; a body has a lifetime, and restoring one
would restore a moment rather than a world. The ignition parameters are likewise absent, having no
stored value to record — each is drawn at the moment a body is made.

Loading a preset SHALL leave the live bodies alone: they continue their envelopes under the new
settings and expire on their own schedule.

Enforcement — Test-held: `tests/test_preset.nim` round-trips the new fields and holds that no body
state appears in the serialized form. Build-asserted for the clamp, through the validation the
preset decode already applies to every field.

#### Scenario: A saved world restores its bodies settings and no bodies

- **WHEN** a preset is saved while bodies are alive and then loaded into a still world
- **THEN** the group's settings are restored and no body appears

### Requirement: The bodies group is one control group led by its strength

The bodies parameters SHALL form one descriptor group whose strength is its first member, the
arrangement `fluidStrength` sets for `fluid` (`docs/one-world.md:206-210`). The group SHALL carry
exactly what a player adjusts while the world runs: the coupling strength, the body's size, the band,
the two force signs, how long a body lives, and how often the world ignites one. A number that is
fixed when a body is born rather than adjusted while it lives SHALL NOT be a descriptor, and SHALL
reach the world as an ignition parameter instead.

Every member SHALL remain present and usable at any strength including zero; no control appears or
disappears as a consequence of a coupling strength
(`openspec/specs/gpu-frame-registry/spec.md`, "One world offers one control set"). The group SHALL
have a help file naming each of its ids and, in prose, the ignition parameters no descriptor
resolves, written in the same change as the controls.

Enforcement — Test-held: `tests/test_panel_reachability.nim` fails the native suite for any
descriptor the panel places by neither its id nor its group (`:41-63`), and
`tests/test_help_content.nim` holds help coverage in both directions over the descriptor table
(`docs/enforcement.md:45`), so a bodies control without a help line is a red build.

#### Scenario: A control with no help line goes red

- **WHEN** a bodies descriptor is added without its line in the group's help file
- **THEN** `just test` fails

#### Scenario: A descriptor the panel does not place goes red

- **WHEN** a bodies descriptor exists and the panel places neither its id nor its group
- **THEN** `just test` fails

### Requirement: A body is visible only through the particles it moves

Bodies SHALL NOT be drawn. The world shows a body by what the particles around it do: a ring gathering
on a surface, a crowd held inside one, a shape drifting because the crowd pushed it. No render pass,
no overlay, and no debug outline belongs to this capability.

Enforcement — Agent-checkable: an agent launches `./main --serve` with a Claude in Chrome connection
already established, ignites a body into a settled population, and observes that particles gather at the
surface while nothing else is drawn. The procedure that detects a violation is that observation; no
automated gate exists. Raised by a render-pass inventory test, which this repository does not have.

#### Scenario: An ignited body shows as a gathering

- **WHEN** a body is ignited into a settled population with proximity non-zero
- **THEN** particles gather along a surface that is itself never drawn
