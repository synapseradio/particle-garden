## Context

All three modes' buffers, pipelines, and bind groups are created unconditionally at init
(src/webgpu_init.nim:424, src/webgpu_compute.nim:112-121, 571-582) — nothing is lazy, so merging is
not blocked by allocation. It is blocked by delta-buffer ownership: forces.wgsl and forces-sph.wgsl
self-reset velocityDelta and densityDelta with atomicStore prologues
(forces.wgsl:126-132, forces-sph.wgsl:144-148), and field-force.wgsl writes velocityDelta with a
plain non-atomic store documented as "the sole writer in RD mode" (field-force.wgsl:86-89). Two
contributors in one frame erase each other. `activeFrame` is a single FrameDescription replaced
wholesale (src/webgpu_compute.nim:109, 139-159).

## Goals / Non-Goals

**Goals**
- One frame composing forces, SPH, and field passes per a WorldCouplings value, behavior-identical
  to today for the three legacy combinations.
- Field patterns that record where colonies actually lived; every existing gesture working in every
  coupling.
- A navigable torus with no visible seam in physics or in light.
- Presets saved before the change keep loading.
- A control panel that reveals its own good settings without requiring literature.

**Non-Goals** — see the proposal's Non-Goals section. Each is a decision, not a deferral.

## Decisions

### D1. Delta reset separates from accumulation, using frame nodes

Delta buffers are cleared by explicit `clearBufferNode` entries at frame start; every contributor
accumulates only. forces and forces-sph lose their atomicStore prologues; field-force's store becomes
atomicAdd against an `array<atomic<i32>>` binding.

*Rejected:* per-shader mode flags choosing reset-or-accumulate. That spreads frame knowledge back
into shaders, which the frame-as-data registry exists to prevent.

**The ordering concern is settled, not open.** Comments at src/sim_registry.nim:199-203 and :237-239
claim an encoder-level clear "would race those atomics". They are wrong about the mechanism. The
executor states the contrary at src/webgpu_compute.nim:861-863 — *"passes in a single encoder execute
in order, so the substeps advance sequentially"* — and `clearBuffer` is encoded into that same ordered
stream at :870-872, interleaved with compute passes in one loop. This is exactly how
`clearBufferNode(sbGridCounts)` already works every frame ahead of bin-count's atomic increments. An
encoded clear preceding a dispatch is ordered, not racing. No verification task is required; delete
the two stale comments as part of the work.

### D2. The default climate stays at Pearson's spots, and that is what makes the field honest

Gray-Scott's nontrivial fixed points exist only where `F ≥ 4(F+k)²` (derivation and citations in
docs/research/README.md). At the shipped `F = 0.030`, `k = 0.062`, `4(F+k)² = 0.0339 > 0.030`, so the
trivial state is the only homogeneous fixed point and it is linearly stable.

This is a feature. In this regime a pattern **cannot** arise from the uniform state at all — it must
be nucleated by a supercritical perturbation. Keeping the default here means: no colony, no pattern,
ever. That is the strongest available guarantee that the field is a record of life rather than
decoration, and it is why deleting the seed is safe to commit to.

*Rejected:* moving the default into the Turing-unstable region (`F ≥ 4(F+k)²`, reachable at e.g.
F=0.060, k=0.045). There the field self-starts from noise, which would reintroduce exactly the
"pattern that owes nothing to the particles" problem this change exists to remove. That region stays
reachable through the climate controls for users who want spontaneous chemistry — the difference is
that they choose it.

### D3. Coherence comes from the splat, not from the climate

Since D2 fixes the climate in the nucleation regime, ignition depends entirely on colonies forming a
supercritical nucleus. A single-cell deposit cannot (proven at tests/test_field_core.nim:313); the
retired seed's blob can (radius 6.0 cells at core inhibitor 0.25, src/field_core.nim:140-147).

The deposit therefore splats over a radius with a falloff kernel rather than landing in one cell.
Task group 1 measures the minimum radius and amplitude that ignites; that measurement is the kernel's
floor and the seed blob is its sufficiency yardstick.

**Why this is expected to succeed:** a settled cluster of ~50 particles depositing 0.02 each per
frame over overlapping radius-3 kernels accumulates far more than the 0.25 core inhibitor the seed
needs, within a few frames. The measurement confirms the radius rather than discovering whether the
approach works.

**If the measurement finds no igniting radius in {1,2,3,5,8}**, apply in order: widen the kernel to 12
cells; raise RD_DEPOSIT_MAX, re-running the flood-ceiling sweep that justifies its current 0.08;
reduce RD_DIFFUSION_B. Do not restore automatic seeding and do not move the default climate — D2
explains what would be lost.

### D4. Pearson's regimes ship as named slider notches, not as a 2D pad

Every tunable stays a slider. Sliders gain an optional table of labelled notches — values known to
produce something worth seeing — served through the descriptor like every other number. A
named-regime selector sets feed and kill together, because a notch on either axis alone does not
locate a regime.

This is the direct fix for the failure the current RD panel exhibits: `feed` and `kill` are exposed as
bare numbers over ranges where most of the plane is dead, so a user has no way to find the living
parts except by accident.

Coordinates, from the practitioner source cited in docs/research/README.md:

| Regime | feed | kill |
|---|---|---|
| Waves | 0.014 | 0.054 |
| Mitosis | 0.028 | 0.062 |
| Labyrinth | 0.029 | 0.057 |
| Spots | 0.035 | 0.065 |
| Worms | 0.078 | 0.061 |
| Coral | 0.082 | 0.059 |

These are representative points, **not** region boundaries. Pearson publishes no numeric boundaries —
only a graphical map — so labelling points is honest and drawing borders would be fabrication.

**RD_FEED_MAX rises from 0.080 to 0.085** so Coral is reachable. Shipping a labelled notch outside
its own slider range would be the same class of defect this decision fixes.

*Rejected:* a 2D feed×kill pad. It is the more elegant interface and remains a good later change, but
the instruction for this change is that every factor is a slider.

### D5. Tropism is bounded asymmetrically, because the two signs carry different risk

Keller-Segel gives the 2D chemotactic-collapse threshold `χ·M > 8π` for **positive**
chemosensitivity — agents climbing their own deposited gradient. Negative chemosensitivity is
stabilizing (docs/research/chemotaxis-stability.md). This independently confirms the caution recorded
at src/config_ranges.nim:104-108, which forbids a negative field-force scale for exactly this reason.

Tropism ships bounded to **[-1.0, +0.5]**: full authority to the safe sign, half to the dangerous one.
Task 5.5 measures the collapse point and asserts the bound sits below it; if the assertion fails,
halve the positive bound and record the measured value beside the constant.

*Rejected:* a symmetric [-1, +1]. Symmetry would be aesthetically tidier and physically wrong.

### D6. Headroom is reserved where it is free or structural, and refused where it is allocated

Layout changes propagate: a new uniform means new bind-group layouts, new entry counts, new manifest
entries, and edits to every shader sharing the group. That is the sweeping refactor worth pre-empting
while the bind groups are already open. Allocated memory does not propagate the same way — a buffer
can grow later without touching anything that reads a different buffer.

So the two are treated differently.

**Reserved because it is already allocated and free.** The field ping-pong textures are `rgba16float`
solely because WebGPU does not permit `rg16float` as a write-only storage texture
(field-resolve.wgsl:45-46, webgpu_init.nim:112-120). Gray-Scott uses `.r` and `.g`; `.b` and `.a` are
written as constants `(0.0, 1.0)` at field-resolve.wgsl:77 and field-seed.wgsl:101. **Two half-float
state channels per cell already exist and cost nothing**, which is precisely what a multi-channel
continuous automaton needs. They are documented as reserved state channels, and every shader that
writes the field preserves them rather than clobbering them with literals.

*Readiness verdict:* the channels are **allocated and addressable** — proven, by the texture format
already in use. They are **not exercised**: nothing reads or writes them meaningfully, no test covers
them, and no reaction consumes them. This reserves a slot; it does not deliver a capability.

**Reserved because it is structural and we are already there.** A `ReactionParamsLayout` uniform is
added and bound to rd-step now, carrying `reactionKind` plus the parameters a kernel-and-growth
reaction needs (`kernelRadius`, `growthMu`, `growthSigma`, `growthDt`) and padding to 32 bytes.
Gray-Scott ignores all but `reactionKind`. Adding this uniform later would mean revisiting rd-step's
bind group, its layout, its entry-count constant, and the manifest — while adding it now costs one
layout table and one buffer write, at a moment when those files are open anyway.

This also promotes the existing `reactionKind` pipeline-override constant (rd-step.wgsl:57) from a
bare `u32` default into a named enum with Gray-Scott as 0, so a second reaction is a new case rather
than a new plumbing exercise. **FieldParamsLayout stays at 32 bytes** — gpu_types.nim:209-211
documents it as full, and a ninth field breaks its static assertions.

**Refused: the activator deposit channel.** field-deposit.wgsl:17-23 records that this slot already
existed once, was never written, and cost 1 MB of VRAM plus 1 MB per frame of read/write traffic to
reserve. It also is not needed: signed secretion into the inhibitor channel gives both roles the
ecology requires — positive secretion builds structure, negative erodes it. The deposit buffer's
channel count becomes a named constant (`DEPOSIT_CHANNELS = 1`) so raising it later is a
one-constant change rather than an index audit, which captures the structural benefit without paying
the allocation.

*Rejected:* restoring the channel "for headroom". That is exactly what left it unused the first time,
and the file already documents the restore as contained at roughly twenty lines.

### D7. There is one world. Couplings are strengths, not booleans

**This decision supersedes the boolean-coupling model this change was originally written against,
and it is the change's premise rather than one of its outcomes.**

A world does not have a mode. Species forces, fluid pressure, and chemistry are three things a world
can do at once and in any proportion, and the only honest way to say "in any proportion" is a
continuous number. `WorldCouplings` as three booleans is a mode selector with the labels filed off:
it enumerates eight worlds where there is one, it makes "a little fluid" unrepresentable, and it
forces every downstream question — which controls show, which ceiling applies, which frame to build —
to be answered per combination.

**Decision.** Each coupling contributes according to a strength that is already a parameter of the
simulation, and zero is an ordinary value of that strength rather than a state of the world. A world
with no fluid is a world whose fluid strength is zero, reached by moving a slider, indistinguishable
in kind from a world with a little fluid.

Three properties follow, and each is a test rather than an intention:

- **Continuity.** Every neighbourhood of every setting is reachable. There is no step where a world
  becomes a different world, because there is no second world to become.
- **No enumeration anywhere.** Nothing in the frame path, the control panel, the range authority, or
  the preset schema branches on a combination of couplings. A grep for a list of modes returns
  nothing.
- **Zero is exactly today's behaviour for that coupling.** So the collapse of eight worlds into one
  cannot silently change any of the eight.

**Dispatch is an optimization, not a mode.** A COUPLING-OWNED pass whose strength is exactly zero
contributes nothing, so the frame builder may skip it. That skip is derived from a number the user
set, never selected from a menu, and it is invisible above the executor. World-intrinsic passes are
never skipped by any strength, and what zero actually costs is stated in **D12**, which draws that
split — read it before relying on the sentence above.

*Rejected:* keeping the booleans as an internal representation with a continuous surface over them.
That is the duplication D11 exists to remove — two encodings of one fact, free to disagree, with the
boolean one authoritative in the frame path and the continuous one authoritative in the UI.

### D8. SimKind is deleted

The earlier decision kept `SimKind` alive as a preset compatibility layer, mapping legacy ids to
coupling triples. Under D7 there are no triples to map to, and a compatibility layer for a concept
that no longer exists is a second vocabulary for the same world.

**Decision.** `SimKind`, `simKindId`, `parseSimKind`, `couplingsFor`, `simKindCeiling`, and the
`simModes` catalog are removed. Nothing in the codebase names a mode.

**Old presets still load, and the mechanism is subtraction rather than translation.**
`src/preset.nim:124-130` documents `mode` as deliberately not checked against an allowlist, and
`validate` (`src/preset.nim:444-449`) rejects only a schemaVersion *higher* than the current one — it
never policed mode strings. So a preset carrying `"mode": "sph"` loads today by having that field
ignored, and will load after this change for the same reason. What the field meant is instead carried
by the coupling strengths the preset already stores.

**What this costs, stated plainly — and the first version of this paragraph was wrong.** It claimed a
legacy preset carries no strength for a coupling its mode implied was off, so absent strengths could
simply become zero. Verified false: the schema serializes EVERY scalar unconditionally —
`forceStrength` at `src/preset.nim:490`, `sphStiffness`/`sphViscosity`/`rdDeposit`/`rdFieldForce` at
`:506-515` — and parses each with a nonzero default (`sphStiffness` 8.0, `rdDeposit` 0.02,
`rdFieldForce` 30.0, `src/preset.nim:199-212`, applied at `:344-358`). Force strength could not be
zero at all. Legacy presets carry values for the couplings their mode hid, because the sliders sat at
defaults while `controlGroupsFor` hid them.

So subtraction fails in both directions. A legacy "particle-life" preset carries `rdDeposit` 0.02 and
`rdFieldForce` 30, so nothing is absent and chemistry switches itself on — which is precisely the
failure this decision named as the thing to avoid, with chemistry in place of fluid. And D14's
fluid multiplier is a field legacy `"mode": "sph"` presets lack, so an SPH preset would load
without its fluid.

**Decision — translate once, at the schema decode boundary.** Task 9.1a already forces a
schemaVersion bump for the chemistry arrays. Below that version, the legacy branch of the decode
consults `mode` to zero the strengths that mode excluded, and derives the D14 fluid strength from
the legacy SPH scalars. At or above it, presets carry their strengths explicitly
and no `mode` field exists.

This does not resurrect the mode. The legacy id table is versioned-schema history about files written
by old builds — the same machinery `validate` already carries at `src/preset.nim:444-449` — and it is
reachable only from a decode branch guarded on an older schema version. Task 9.0e's grep test is
therefore scoped to the LIVE model (`sim_registry`, `web_api`'s live paths, the panel) with a stated
exemption for that branch, and the test says why the exemption is honest rather than merely allowed.

### D12. A strength multiplies its coupling's whole output, and the world runs regardless

**D7 as first written was incomplete, and the gap is load-bearing.** It said a pass whose strength is
exactly zero may be skipped. That is only sound when the strength multiplies *everything the pass
produces* — otherwise skipping the pass removes an output the strength never scaled, and the world
jumps at zero. Verified twice, and both are true today:

- **The forces pass produces local density as well as force.** `web/shaders/src/forces.wgsl:334-339`
  accumulates `densityContribution = 1.0 - normalizedDist` with no strength factor, while
  `src/physics_core.nim:60` applies `fMul` only to the force magnitude. Density is consumed by dot
  size, brightness, and glow radius — none of which are force. So skipping forces at strength zero
  would take the world's density with it, which is exactly what D11 assumes still runs when it
  retires `RD_GLOW_DENSITY_FLOOR`.
- **The field evolves whether or not particles couple to it.** Chemistry's strength is the deposit
  and field-force pair; neither scales `rd-step`. Skipping the field passes at zero would freeze a
  visible, lit pattern mid-breath, while any epsilon above zero keeps it alive.

Both are the same error: treating a pass as belonging to a coupling when part of what it computes
belongs to the world.

**Decision — the ownership split.** Passes divide into two kinds, and only the second is
strength-gated:

- **World-intrinsic.** Runs whenever the world runs, at every setting. The spatial grid, local
  density accumulation, the field's own Gray-Scott evolution, and `integrate`. These are what the
  world *is*; no coupling owns them and no strength may skip them.
- **Coupling-owned.** Exists only to make one coupling act on the particles: the force accumulation
  itself, SPH pressure and viscosity, the deposit, and field-force. Each is multiplied by its
  coupling's strength across its entire output, and may be skipped at exactly zero because at zero
  it provably contributes nothing.

**The property this creates, which is the one to test.** For every coupling: as strength approaches
zero the coupling's contribution approaches zero continuously, and at exactly zero the world is
identical to the world with that pass absent. Skip and dispatch become indistinguishable, which is
what makes the skip an optimization rather than the mode returning as a floating-point comparison.

`shader_manifest.nim`'s pass ownership is redrawn by this.

**DENSITY HAS TWO WRITERS, AND THAT IS THE HOLE IN THE FIRST VERSION OF THIS DECISION.** Separating
density from the force term inside `forces.wgsl` is necessary and not sufficient: `forces-sph.wgsl`
also writes `densityDeltaFixed`, species-blind and scaled by `SPH_DENSITY_GLOW_GAIN = 2.5`
(`:276-277` and `:337-338`). So with the fluid pass skipped at zero strength, the density the
renderer and the crowding cap read drops by SPH's entire contribution, discontinuously — the
jump-at-zero this decision exists to forbid, appearing in the density channel instead of the force
channel.

**The two writers are writing different quantities into one buffer.** SPH needs a kernel-weighted
density for its equation of state; the renderer and the crowding cap need a measure of how crowded a
particle is. Those are not the same number, and merging them was convenient rather than correct — a
D11 duplication in buffer form, where one name carries two meanings and their disagreement shows up
as a discontinuity.

**Decision.** The world-intrinsic density accumulator is the SOLE writer of the density that leaves
the physics — the number dot size, brightness, glow radius, and the crowding attenuation all read.
SPH's kernel density becomes private to the pressure computation that needs it. A measurement of the
world does not scale with a coupling's strength, because it is not a contribution; it is an
observation, and an observation that changes when you turn a force off was measuring the force.

What this costs: fluid worlds lose the 2.5x glow lift SPH's contribution gave them. That lift was
compensating for a density signal that is same-species only — see the open question below, which is
now the second argument for settling what that channel measures.

**What it costs, stated.** "A coupling at zero strength costs nothing" (D7) weakens to "costs nothing
beyond what the world intrinsically is". The grid and density still run in a world with no forces —
and the largest intrinsic cost is neither: `RD_STEPS_PER_FRAME` field substeps now run in EVERY
world, including a forces-only one whose field sits at its trivial fixed point. That is the honest
price of the field belonging to the world rather than to a coupling, and group 10 measures it as the
intrinsic floor rather than inheriting an estimate. It is smaller than the alternative, which is a
world that changes shape at zero.

### D13. Zero must be reachable

`FORCE_STRENGTH_MIN = 0.1` (`src/config_ranges.nim:37`). The one coupling D7 claimed already had a
strength cannot be set to zero at all, so "zero is an ordinary value" is currently false for it.

**Decision.** Every coupling strength's range includes zero, under the range authority's existing
static assertions. A property D7 asserts and no range permits is not a property.

**One consequence, because `fMul` scales both force zones** (`src/physics_core.nim:52-60`): force
strength zero removes short-range repulsion along with attraction, so particles at zero force
strength pass through each other freely. That is correct — with no species forces there is nothing
holding them apart — but it interacts with C1, which relies on repulsion as "the
term already fighting collapse". The interaction is noted there rather than resolved here.

### D14. Fluid gets its own strength, because stiffness cannot carry the job

D7 gives every coupling a strength that is already a parameter of the simulation. Forces have
`forceStrength` and chemistry has its deposit and field-force pair, but fluid has three numbers —
stiffness, rest density, viscosity — and none of them means "how much fluid". The question this
decision answers: introduce a fourth number, or promote one of the three.

**Promotion fails, and the reason is D12 rather than taste.** D12 requires a strength to multiply its
coupling's ENTIRE output, because that is what makes the zero-strength skip an optimization instead of
a mode hiding in a floating-point comparison. Stiffness does not.
`web/shaders/src/forces-sph.wgsl:255` computes
`velocitySmoothCoeff = (viscosity + SPH_XSPH_EPSILON) * densityWeight / velocitySmoothDenom`, and the
pair velocity delta at `:262-263` adds that term to the pressure term. Neither the viscosity factor
nor the XSPH epsilon carries stiffness at all, so a pass running at stiffness zero still diffuses
velocities — skipping it at zero would change the world, discontinuously, in exactly the way D12
forbids. Rest density fails harder: it sits inside the Tait equation as a divisor, so zero is not a
quiet setting there but a singularity.

Promotion is rescuable only by making stiffness multiply the smoothing term too, which silently
redefines what the viscosity slider means — the user's viscosity would stop meaning viscosity at low
stiffness. That is a worse cost than a fourth number.

**Decision.** `fluidStrength` multiplies the SPH pass's whole per-pair velocity contribution — the
pressure term and the velocity-smoothing term together, at `forces-sph.wgsl:262-263`, before the
fixed-point encode. One factor at one site, so no future term can be added to that pass and escape the
strength by being written somewhere the multiplier does not reach.

**What the existing sliders keep meaning, stated because a fourth number is exactly where meanings
drift.** Stiffness, rest density, and viscosity are unchanged: they set what KIND of fluid this is —
how hard it resists compression, what spacing it relaxes to, how fast it shears. `fluidStrength` sets
how much of that fluid's verdict on a particle's velocity actually lands. A stiff, thin fluid at
strength 0.3 is the same fluid as at strength 1.0, applied more gently, where a fluid at a third of
the stiffness is a different fluid.

**The kernel density is not part of the scaled contribution**, because it is not a contribution.
`forces-sph.wgsl:277,338` writes density that the renderer and the crowding cap read, and D12 already
moves that measurement to the world-intrinsic accumulator. What stays inside the SPH pass is the
kernel density its own equation of state needs, private to the pressure computation, unscaled and
unobserved from outside.

**Interaction with C7, which is why this is a new slider rather than one slider doing two jobs.** C7
makes the stiffness ceiling derived from radius fraction and substeps, because stiffness sets the
Courant stability boundary. A promoted stiffness would carry both the stability boundary and the
coupling strength, so a user turning the fluid down would be walking the stability boundary at the
same time and could not tell which effect they were seeing. `fluidStrength` has no stability role and
its range is free to include zero under D13 without touching C7's derivation.

**Legacy presets.** D8's translate-at-decode branch derives `fluidStrength` from the legacy SPH
scalars: a preset from before this schema version carries no such field, and its mode decides whether
the fluid was acting at all.

### D11. One name per fact

The user's standing principle, and it was inverted when this codebase began: prefer one
representation, not a duplicate kept in step by an assertion. An assertion that two constants remain
equal is not a safety property — it is a duplication with an alarm on it.

**Decision.** This change collapses the following, each of which is one fact currently stored twice
or more:

| Fact | Stored as | Collapses to |
|------|-----------|--------------|
| What a world does | `SimKind` and `WorldCouplings` | coupling strengths (D7, D8) |
| The particle budget | `SPH_PARTICLE_CEILING`, `RD_PARTICLE_CEILING`, `COUPLING_PARTICLE_CEILING`, held equal by a `doAssert` at `src/config_ranges.nim:337` | one budget for one world |
| Which controls exist | `controlGroupsFor(couplings)` and `shows(group)` in `Panel.tsx` | nothing — one world shows its controls |
| Density for glow | real density, and `RD_GLOW_DENSITY_FLOOR` substituting for it where forces did not run | real density, which now always runs |
| Feed 0.029 / kill 0.057 | `"Stripes"` in `web_api.nim:869` and `"Labyrinth"` in `config_ranges.nim:131` | `Labyrinth` (decided) |
| The attraction matrix bounds | `MATRIX_VALUE_MIN/MAX` in `preset.nim:146-148` and `MATRIX_MIN_VALUE/MAX_VALUE` in `ui/state/matrix_state.nim`, with a comment reading "Duplicated rather than imported" | one source |
| A drifting parameter tour | `climate_core`'s loop, and the force-weather loop the C family proposes | one parameterised loop over a waypoint table |

**The reference oracles are NOT on this list, and the omission is deliberate.** `physics_core`,
`sph_core`, `field_core`, `camera_core` and the rest duplicate WGSL maths in Nim so the native suite
can test physics that never runs natively. That duplication buys something no single representation
offers, and removing it would remove the tests. It is nonetheless hand-maintained with no
compile-time link — the same shape of exposure that let a WGSL parse error ship green — so the
DRY-honest fix is generation, not deletion: `tools/wgsl_bundle.nim` already generates WGSL structs
from `gpu_types.nim`, and generating the constants and small functions the same way would make the
mirror derived rather than copied. **That is out of scope here and is recorded as an open question,
not a decision.**

### D9. Zoom scales particle size, trail length, and glow radius together, with a floor

render.wgsl:135 computes `worldOffset = (…) / scale` and glow.wgsl:95 does the same — radius is
authored in screen units and divided by the world-to-screen scale. Left alone under a camera, zooming
would keep dots the same size and merely spread them apart, which reads as zooming a diagram rather
than approaching something alive.

Size therefore tracks world scale, clamped to a floor: unclamped, particles go sub-pixel when zoomed
out past 1:1 — exactly where the tiled-torus infinity effect lives and where the field most needs
legible inhabitants. Trail length and glow radius scale by the identical factor. Three quantities that
disagree at any zoom other than 1.0 is the specific failure that makes zoom feel broken rather than
merely different.

### D10. The cold start is dark, and dawns

The app opens on particle life alone — already worth watching — and chemistry arrives visibly as the
first colonies tighten. No pre-clumped spawn, no hidden warmup frames.

*Rejected:* both shortcuts. Watching the field come into being is the clearest statement that the
pattern belongs to the particles. If ignition reads as a bug rather than a dawn, D3's ladder applies.

### D15. The viewport never exceeds one world, and the camera answers the pointer

User decision (2026-07-28), reversing part of task 7.9's range and all of task 7.6a's tiling.
`CAMERA_ZOOM_MIN` rises from 0.25 to 1.0: the view never spans more than one world, so below-1x
tiling — built by 7.6a to honor the old constant's comment — was never intended and is deleted
rather than left dormant (engineering principles, article 3). The nearest-toroidal-image logic is
untouched; it is what keeps quads whole across the seam at every remaining zoom.

Camera movement, clipping and zoom are pointer-first and device-adaptive (the user's chosen map):
plain scroll pans; pinch — which reaches the runtime as Ctrl/Cmd+wheel — zooms at the cursor, as
does Ctrl/Cmd+wheel from a mouse; middle-button drag also pans; the task 7.7 keyboard bindings
stay. Left-drag remains the physics interaction. The browser is a portability runtime, not a
website, so handlers `preventDefault` every page gesture they replace, page zoom on Ctrl+wheel
above all.

*Rejected:* keeping the tiling machinery dormant behind the raised floor (dead code teaching a
dead promise), and a mouse-first map that preserves plain-wheel zoom (it would leave touchpad
two-finger scroll zooming, which reads as broken on the device most users hold).

### D16. No cap sits below capability

User decision (2026-07-28), superseding the measured-budget half of task 10.1. `PARTICLE_BUDGET`
(32000, inherited unmeasured from the pre-collapse ceilings) is deleted; the preset-apply clamp
and every other count bound derive from `PARTICLE_COUNT_MAX = memory_layout.MAX_PARTICLES`
(128000), the allocation bound. Performance at high counts is the user's tradeoff on a slider,
never a cap's job. Group 10 still measures — its numbers inform defaults and the perf report, and
place no ceiling below capability.

## Risks / Trade-offs

- **Deposit splat cost** — one atomic per covered cell per particle. Mitigation: keep the kernel at
  the measured minimum; if group 9 shows it dominating, shrink the kernel or lower the field substep
  count before touching particle count.
- **Positive tropism feedback** — bounded by D5 and measured by task 5.5.
- **A living world lost on a preset click** — the ceiling clamp lowers count in place, keeping
  survivors; no Fisher-Yates re-randomization.
- **Bloom passes carry no profiler timestamps** (src/webgpu_render.nim `beginBloomPass`) — a known
  measurement gap in group 9. Noted, not fixed here.
- **Legacy-frame equivalence** — the three settings that used to be modes must dispatch what they
  dispatch today. Pinned by tests before any shader edit; that equivalence is the regression check
  for the whole restructure.
- **One world can cost more than one mode did** — every coupling is always conceptually present, so
  the saving that used to come from picking a cheap mode has to come from D7's zero-strength skip
  instead. If that skip is ever bypassed, a world that used to run forces alone starts paying for
  fluid and chemistry. The skip therefore needs a test asserting that a zero-strength coupling
  dispatches none of its COUPLING-OWNED passes (D12) — not merely that it contributes nothing — and
  the same test asserts the world-intrinsic passes still run, because those are not the skip's to
  take.
- **One budget replaces three ceilings** — collapsing `SPH_PARTICLE_CEILING`, `RD_PARTICLE_CEILING`
  and `COUPLING_PARTICLE_CEILING` (D11) means the surviving number governs worlds none of them was
  measured against. The three were never independently justified — the SPH one cites no measurement
  (`src/sph_core.nim:35-38`) and the field one is that number under another name — so the collapse
  removes a false precision rather than a real bound. What replaces it is a measurement, and until
  that measurement exists the budget is a hypothesis. [?]

## Migration Plan

No data migrates on disk. Old presets are TRANSLATED on read, once, in the legacy branch of the
versioned schema decode: `mode` is consulted there to zero the strengths that mode excluded (D8).
Subtraction cannot do this job — the schema always serialized every scalar with a nonzero default, so
nothing is ever absent to subtract, and D8 records the verification.

The regression check for the restructure is behaviour-identity at the three settings that used to be
modes: forces alone, forces with fluid, and forces with chemistry must each dispatch and look like
what that mode dispatched and looked like. Under D7 those are three points in one space rather than
three worlds, which is what makes them ordinary test fixtures instead of a compatibility surface.

## Open Questions

Two, both recorded rather than answered, and neither blocking.

**Should the reference oracles be generated instead of mirrored?** D11 explains why they are exempt
from the DRY collapse and why generation — not deletion — is the honest fix. The machinery exists:
`tools/wgsl_bundle.nim` already emits WGSL structs from `gpu_types.nim`. Extending it to constants
and small pure functions would make `physics_core` ∥ `forces.wgsl` derived rather than copied, and
would close the same class of exposure that let a WGSL parse error build green. Scoping that is its
own change.

**Where do the coupling strengths come from? — SETTLED, and not the way this question first framed
it.** It asked whether fluid gets a new multiplier or whether stiffness is promoted, and called both
viable. Only one is: **stiffness cannot be promoted**, because it does not scale the fluid's entire
output and D12 requires that it would. `forces-sph.wgsl:254-255` computes
`velocitySmoothCoeff = (viscosity + SPH_XSPH_EPSILON) * densityWeight / velocitySmoothDenom` — the
viscosity and XSPH velocity smoothing carry no stiffness factor at all. A pass running at stiffness
zero still diffuses velocities, so skipping it at zero would change the world. Promotion is rescuable
only by making stiffness also multiply the smoothing term, which silently redefines what the
viscosity slider means.

So D14 introduces a fluid strength that multiplies the pass's whole velocity contribution. D8's
legacy decode already assumes this shape, deriving fluid strength from the legacy SPH scalars.

**What does the density channel measure? — SETTLED: there are TWO quantities, so there are two
channels.** The density every consumer reads is accumulated only between particles of the SAME
species (`forces.wgsl:333`), which makes it colony density, not crowding.

The decisive observation is not that one of those is wrong. It is that **the two consumers want
different numbers**, and one buffer has been serving both:

- The RENDERER wants colony density. Dot size, brightness, and glow radius exist to make a cohesive
  colony read as cohesive, and a particle sitting among strangers is not in a colony. Same-species is
  the right measure and it should keep it.
- The CROWDING CAP wants crowd density. Its whole purpose is bounding per-cell occupancy so the
  spatial hash stays bounded, and the hash does not care about species — a mixed blob costs exactly
  what a single-species one costs. Attenuating on same-species density under-responds in precisely
  the worst case.

This is the same defect as the SPH kernel-density finding above, in a second instance: one buffer
carrying two meanings, where their disagreement surfaces as wrong behaviour rather than as an error.
Splitting it is not a DRY violation, it is the fix — one name per fact, where there turned out to be
two facts.

**Decision.** The world-intrinsic accumulator produces two per-particle values in the same loop it
already runs: colony density, species-gated exactly as today, and crowd density, species-blind. Both
are world-intrinsic under D12; neither scales with any coupling strength, because both are
measurements.

**The cost is real and must be measured, not assumed.** Most pairs are cross-species, so the second
channel roughly doubles the density atomic traffic in the hottest loop in the application.

**THE CROWD CHANNEL SHIPS WITH C1, NOT WITH GROUP 9 — decided by the user during group 9.** Splitting
the two quantities stands; what moved is when the second one gets built. D12 needs only the SPH split
to make the zero-strength skip exact, and group 9 delivers that. Crowd density's sole consumer is C1's
crowding attenuation, which lands after groups 10 and 11, so building it in group 9 would double the
hottest loop's density atomics for several groups with nothing reading the result — and would hand
group 10 a measurement of a channel no shipped code consumes. Task C1 builds it beside the cap, and
measures it there against a baseline group 10 has by then established. The colony channel is untouched
either way, so nothing in this decision's reasoning depends on the ordering.

**If that measurement says the traffic hurts, the fallback is already computed.** `bin-count` fills
`gridCounts` with the per-cell particle count every frame — which is exactly the quantity the cap's
bound is stated over. Reading it costs no new accumulation at all. It is coarser and discontinuous at
cell boundaries, which is why it is the fallback rather than the first choice: attenuation that jumps
as a particle crosses a cell line would be visible. Take it only if measurement forces the trade, and
record the artifact if you do.

The implementer's job is to build and measure, not to research. Where a decision depends on a
measurement, the measurement task is named, the expected outcome is stated, and the fallback ladder is
written out.

---

# Crowding and scale

Decisions in this section are the **C-family** — C0 through C7 — renumbered from a D-prefix on fold-in so they cannot be confused with the D-family above. Their content is unchanged.


## C0. Force strength zero removes the term this change relies on

D13 makes zero reachable for every coupling strength, and `src/physics_core.nim:52-60`
applies `fMul` to BOTH force zones — so force strength zero removes short-range repulsion along with
attraction. C1 below leans on that repulsion as "the term already fighting collapse".

At force strength zero there is nothing to attenuate and nothing collapsing, so the crowding cap is
vacuous rather than wrong. The interaction that matters is at small non-zero strengths, where
repulsion is weak and attraction is weaker still. **The crowding attenuation must therefore be
expressed as a fraction of the attraction that survives `fMul`, never as an absolute force**, or its
effect changes meaning across the force-strength range and the cap stops being a cap.

## C1. The cap is on attraction, not on the whole force

Attenuating the total force would also weaken the short-range repulsion that keeps particles apart,
which is the term already fighting collapse. Damping both means the cap partly cancels itself, and
at high strength it produces a mush that neither clusters nor separates.

**Decision.** The density term multiplies the ATTRACTIVE component only. Repulsion is untouched at
every density. Both force models expose an attraction term to scale — the polynomial's attraction
bump and the exponential's `attraction * exp(-beta * r)` (`web/shaders/src/forces.wgsl:93-96`) — so
this is expressible in each without restructuring either.

## C2. Logarithmic, because the interesting range is the quiet one

A linear attenuation in density is either invisible where it matters or dominant where it does not:
a coefficient tuned to stop a blob at density 200 has already halved the force at density 5, and a
coefficient that leaves density 5 alone does nothing at 200. The dynamic range between "a few
neighbours" and "a collapsing blob" is over two orders of magnitude, which is what a logarithm is
for.

**Decision.** The attenuation is `1 / (1 + strength * log(1 + density))`. Three properties follow by
construction rather than by tuning, and each is a test:

- **Identity at zero.** `log(1 + 0) = 0`, so an isolated particle feels exactly the force it feels
  today. The change is provably invisible in a sparse world, at any strength.
- **Monotone decreasing in density.** Never rewards crowding, at any strength.
- **Strength 0 is exactly today's behaviour.** So the shipped default can be non-zero without the
  old behaviour becoming unreachable, and any regression is bisectable to one number.

## C3. The ceiling is a stated property, not an observed one

"Blobs got smaller when we tried it" is not a bound. What makes the cap worth having is that a
density ceiling EXISTS and can be computed from the parameters, so a claim about worst-case frame
cost has something under it.

**Decision.** `physics_core.nim` gains the attenuation as a pure function and a companion that
returns the density at which attenuated attraction no longer exceeds repulsion at the equilibrium
separation — the density past which a cluster cannot tighten further. The native test asserts that
this ceiling is finite for every reachable combination of attraction strength and crowding strength,
and that it decreases monotonically in crowding strength. That is the claim the performance argument
rests on, and it is checkable without a GPU.

**What this does NOT claim, measured against the source rather than assumed.** The core claim
survives — bounded same-species weighted density does bound cell occupancy up to geometric constants,
since cells are `max(interactionRadius, 16)` (`src/grid.nim:61`) and the grid dimension cap never
binds at the current world extent. Four qualifications scope it, and the first was missed when this
decision was first written:

- **The density signal is SAME-SPECIES ONLY.** `web/shaders/src/forces.wgsl:333` gates the
  accumulation on `otherParticle.species == thisParticle.species`, and `src/physics_core.nim:123-126`
  mirrors that exactly. So the per-cell bound carries a factor of the species count, and a mixed
  blob attenuates later than a single-species one of equal total density. Any worst-case cost claim
  must carry that factor rather than quietly assume density counts every neighbour.
- **The ceiling is an equilibrium property, not a per-frame invariant.** It is where attenuated
  attraction stops exceeding repulsion at the equilibrium separation. Momentum carries particles past
  it transiently; what the ceiling forbids is *settling* tighter, not *arriving* tighter.
- **It bounds what ATTRACTION can concentrate, and nothing else.** Mouse attraction, blast aftermath,
  and positive tropism compress from outside the force law and are outside its reach. Tropism carries
  its own measured bound from task 5.5.
- **It does not bound the number of particles in one REGION**, since a region holds many cells. Global
  clumping stays reachable; what is ruled out is the unbounded per-cell concentration that degrades
  the sweep toward quadratic.

## C4. Weather perturbs, it does not schedule

`climate_core` tours named waypoints because most of the Gray-Scott feed/kill rectangle is dead, so
a random walk would spend its time in parameter space with nothing in it. The force parameters are
not like that — most of their range produces something. The reason for weather here is different: a
world that cannot collapse also cannot be shaken loose by its own dynamics, so it settles.

**Decision.** Force weather reuses `climate_core`'s SHAPE — a closed loop through waypoints, eased
with smoothstep so there is no velocity corner at a handover, advanced by the frame loop, written
through `setParam` so sliders visibly move — and takes its own waypoints over force parameters. The
two guarantees carry over unchanged and for the same reasons: every point is a convex combination of
waypoints inside an axis-aligned box, so in-range needs no clamping; and a per-frame step ceiling is
asserted by a sweep of the whole loop rather than enforced by a limiter, so a speed raised past what
the loop can carry goes red in a test instead of making the weather jump.

**One loop, not two — this is decided, not deferred.** An earlier draft of this decision left the
merge to implementation; that contradicted both this change's own sequencing section and
D11, which names the second loop as a duplication to collapse. Task 9.4a generalises
`climate_core` into a parameterised tour over a waypoint table, and this change supplies a table.
The RD climate's waypoints are the named regimes; the force waypoints are this change's to choose,
and having no published set to draw on is a reason to measure them, not a reason to write a second
loop.

## C5. SPH radius is a fraction, and the constraint is unrepresentable rather than checked

An absolute radius in world units needs a clamp against `interactionRadius`, and a clamp is a runtime
correction of an input that should never have been offerable. It also silently changes meaning when
the interaction radius moves: the same number is near-neighbour at radius 150 and everything-in-range
at radius 20.

**Decision.** The control is a fraction in `(0, 1]`, multiplied by `interactionRadius` in the shader.
Exceeding the neighbour sweep's reach is then not a thing the type can express. The fluid also keeps
its relative scale for free when the interaction radius changes, which is what makes the interaction
radius remain a single meaningful control rather than two coupled ones.

**Why the upper bound is exactly 1 and not less.** The current behaviour is fraction 1. Keeping it
representable means this change cannot silently alter an existing world, and the fraction's default
moving below 1 is a separate, visible decision recorded in the range authority.

**The lower bound is not 0.** A zero radius divides by zero in both kernel normalizations
(`sph_core.nim:62` and `:82` raise the radius to the 8th and 5th power in a denominator). The range
authority's minimum must be strictly positive, and the reason belongs beside the constant.

## C6. Where the crowding term lives relative to SPH

SPH pressure and the crowding cap both resist concentration, and running both at default strength
means two mechanisms fighting the same fight with no way to attribute an outcome to either.

**Decision.** They stay independent and compose, because couplings composing is what this codebase
already is. What the tasks must not do is tune one to compensate for the other: the crowding
strength's default is chosen in a world with `sph` OFF, and the SPH radius fraction's default is
chosen with crowding strength at 0. Each default is then a property of its own mechanism, and a world
running both is the sum of two separately-understood things.

## C7. Shrinking the smoothing radius moves the stiffness stability boundary

**This corrects an omission in C5 as first written.** C5 decided the SPH radius becomes a fraction
defaulting well below 1, and said nothing about what that does to the rest of SPH. It does something
large.

Weakly-compressible SPH carries an artificial speed of sound set by the stiffness. The scheme is
stable only while a pressure wave cannot cross a smoothing radius inside one timestep — the Courant
condition, `dt <= C * h / c`. Since `c` grows like the square root of stiffness, the largest stable
stiffness grows like `(h * substeps / dt)^2`. Two consequences, and the second is the one C5 missed:

- Raising substeps raises the stable ceiling quadratically. `sph_core.nim:39-42` already says this in
  prose — "Higher stiffness needs a smaller effective timestep; substepping buys that" — so the
  coupling is known to the codebase and simply absent from the ranges.
- **Shrinking `h` LOWERS the stable ceiling quadratically.** A radius fraction of 0.35 cuts the
  largest stable stiffness to roughly an eighth of what the same world tolerates today.

So `SPH_STIFFNESS_MAX = 40` (`src/config_ranges.nim:75-76`) is not a constant. It is a function of
the radius fraction and the substep count that has been written down as a constant, and this change
is about to make the discrepancy worse rather than better.

**Decision.** The stiffness ceiling becomes derived rather than chosen: a pure function in
`sph_core.nim` of radius fraction, substeps, and timestep, with `SPH_STIFFNESS_MAX` retained only as
the absolute upper bound the derived value is clamped against. The descriptor serves the derived
maximum, so the slider's own travel shrinks when the fluid is configured somewhere it cannot support
high stiffness — which is the honest presentation, and is what stops most of that slider's range from
being a region where the fluid explodes.

**What needs measuring before the constant `C` is fixed.** The Courant form is standard for
weakly-compressible SPH, but the safe coefficient for THIS integrator — its substep structure, its
XSPH term, its fixed-point velocity accumulation — is not something the literature hands over. The
tasks must find the empirical stability boundary by sweeping stiffness against radius fraction and
substeps, and fit `C` to the measurement. Until that sweep exists, the derived ceiling is a hypothesis
and must be marked as one wherever it is stated. [?]

## Open question: the world's extent is a constant, and zooming out proves it

Raised by running the app once tiling landed. Below zoom 1 the world repeats, and the repetition is
legible — the same arrangement of colonies, four times over. That is correct behaviour for a torus
and it is worth keeping; what it reveals is that three numbers which should be related are
independent:

- **World extent** is fixed at `WORLD_W = 3840`, `WORLD_H = 2160` (`src/config.nim:138-139`).
- **Particle count** is set by its own slider against its own budget.
- **Zoom** ranges over `[0.25, 8.0]` (`src/config_ranges.nim:284-290`) with no relation to either.

Population density — the thing that decides whether a world reads as crowded or empty — is
`count / (WORLD_W * WORLD_H)`, a quantity no control names and every control affects. Zooming out
does not show more world; it shows the same world again, because there is no more world to show.

Three directions, none chosen, and they are not mutually exclusive:

- **Bound the zoom** so the repetition is never reached. Cheapest, and it throws away something the
  user likes.
- **Scale particles with distance** so a tiled view reads as depth rather than as repetition.
  Addresses the symptom; the world is still the same size.
- **Let the world grow, and spawn into the new space** so zooming out enlarges the world at constant
  population density rather than tiling it. This is what the user's "dynamic spawning" names, and it
  is the only one of the three that makes the world feel unbounded rather than looking unbounded.

The third is a substantial design in its own right — it touches the spatial grid's dimensions, the
particle buffer's occupancy, the field's fixed cell grid, and what "particle count" as a slider even
means once population is a density. **It is not in this change.** It is recorded here because this is
the change about scale, and because deciding the SPH radius fraction and the crowding curve while the
world's extent is about to become variable would calibrate both against a constant that moves.

## Risks

- **The crowding term reaches fresh worlds only.** Strength 0 is exactly today's behaviour, and the
  legacy branch of the versioned preset decode — D8's translate-at-decode boundary —
  pins crowding strength to 0 for presets saved before this change, so no saved world gains a term
  it was not saved with and any regression is bisectable to one number. (As first written, this
  risk accepted a feel change to existing presets because no decode mechanism existed;
  D8's revision created it.)
- **The SPH default moving below 1 reaches fresh worlds only.** The fraction is carried in the
  preset schema from this change's schemaVersion onward, and the legacy decode pins it to exactly
  1.0 for older presets — the kernel those worlds ran when they were saved. The release note covers
  the fresh-world default. (Same correction as above: the release-note-only framing predated the
  decode mechanism.)
- **Two weather systems can run at once** (RD climate and force weather), and their combined effect
  on a world running both couplings is not something either one's tests cover.

---

# Legibility

Decisions in this section are the **E-family**. They collide with nothing and keep their numbers.


Every user-facing tunable is one `ParamDescriptor` (src/ui/api/param_descriptor.nim:61) carrying id,
label, group, kind, range, step, precision, default, store routing, reinit flag, a free-text hint,
and labelled notches. `tests/test_param_descriptor.nim` pins each of those against its authority:
ranges against `config_ranges`, defaults against the state records, steps against the
kind-and-precision rule, notches against the slider lattice, and the numerals inside hints against
the positions the slider can actually land on (tests/test_param_descriptor.nim:94). What no test
relates is the descriptor to an **effect** — nothing checks that writing the parameter changes
anything, and nothing checks that the range and step present that change in usable coordinates.

The panel offers every control the simulation has, at all times
("One world offers one control set"). There is one world; couplings contribute by continuous
strengths and zero is an ordinary value (D7); passes are world-intrinsic or
coupling-owned, and a strength multiplies its coupling's entire output (D12). Nothing
gates a control's existence, so everything about a quiet control — why it is quiet, whether it is
broken, what would wake it — must be said by the control itself. That is the weight this change
carries.

The material for measuring effect already exists. Several pure modules mirror WGSL math for the
native suite and have no importer in `src/` by design — `physics_core`, `sph_core`, `field_core`,
`bloom_core`, `colormap_core`, `camera_core`, and `climate_core` beside them (CLAUDE.md, "Reference
oracles"). They are the response functions this change needs, already written, already tested
against their own properties.

*Readiness verdict on that family:* it is a **proven foundation for the parameters it already
covers** — those oracles are imported and exercised by the existing native suite, and in some cases
by `shader_config.nim` for the constants it substitutes into shaders, so their math is live rather
than notional. It is **not a foundation for the render-side sliders**: glow and trail have no mirror
at all, which is why this change writes two new ones rather than claiming coverage it does not have.
The prerequisite to calling the family complete for this purpose is `glow_core.nim` and
`trail_core.nim` existing and passing (decision E1).

## Goals / Non-Goals

**Goals**
- No visible control that writes nowhere, and no way to add one.
- No visible control whose effect is concentrated in a small fraction of its track, measured in the
  context where the control acts.
- A user who moves anything sees something change in the same tick, whether or not the world
  responds immediately.
- A control that cannot act right now says what is missing, in words.
- An edit in progress belongs to the user until committed.
- One place to author what a feature is, serving both the person in the app and the person reading
  the repository.

**Non-Goals** — see the proposal's Non-Goals. Each is a decision, not a deferral.

## Decisions

### E1. Effect is measured through a declared response probe, not asserted by review

Each descriptor names a **response probe**: a pure Nim function
`proc(value: float; ctx: ProbeContext): float` returning a scalar observable that the parameter is
supposed to move. The context fixes every other parameter at named coordinates — which is what every
probe does implicitly the moment it evaluates anything, made explicit so it can be varied (E2). The
probe registry (`src/ui/api/response_probe.nim`) maps probe ids to functions; the descriptor carries
the id.

Probes come from the reference-oracle family wherever one exists. The assignment:

| Probe source | Observable | Parameters |
|---|---|---|
| `physics_core` | force magnitude at a fixed separation; post-step speed | forceStrength, ruleTemperature, repulsionEnd, attractionPeak, expRepulsionAlpha, expAttractionBeta, interactionRadius, friction, timeScale, maxVelocity |
| `sph_core` | pressure at rest density; kernel-weighted neighbour contribution | sphRestDensity, sphStiffness, sphViscosity, sphSubsteps |
| `field_core` | `FieldStats.aliveFraction` and the std/mean structure ratio after N frames | rdFeed, rdKill, rdDeposit, rdFieldForce |
| `bloom_core` | graded output luminance for a fixed HDR input | bloomIntensity, exposure, saturation, contrast, temperature |
| `colormap_core` | composited field luminance over background | fieldOpacity |
| `palette` | mean pairwise colour distance across the species palette | paletteSaturation, paletteLightness |
| `climate_core` | tour period at the declared speed | climateSpeed |
| `camera_core` | apparent scale of a fixed world length; composed on-screen pixel radius (E14) | cameraZoom, particleSize |
| `glow_core` *(new)* | display-clamped halo alpha integrated over radius | glowIntensity, velocityGlowScale, glowRadiusScale, glowFalloff, glowWarmth |
| `trail_core` *(new)* | 1/e persistence length in frames | trailLength |

`glow_core.nim` mirrors glow.wgsl's radius composition (web/shaders/src/glow.wgsl:96-101), its
`exp(-params.glowFalloff * l * l)` falloff (:173), and the warmth composition (:180-181). Its probe
observable is the display-clamped integral: the alpha a screen can show saturates, and a raw
integral keeps rising through travel the display has stopped answering — exactly the deadness the
metric must see (E3, E14). `trail_core.nim` mirrors the trail's geometric decay — the per-frame
`fadeAmount` mix (web/shaders/src/fade.wgsl:109-110) and the trailLength→fadeAmount mapping that
feeds it (src/webgpu_render.nim:1644-1652).

**Exemptions are declared, not implied.** A descriptor may carry an exemption instead of a probe id,
with a written reason, and a native test asserts the union of probed and exempted descriptors is the
whole table. Two exemptions ship: `particleCount` and `speciesCount` — the observable is the count
of things drawn, self-evident and structural, and probing it would measure the probe.
`particleSize` takes a probe rather than the exemption its pixel-geometry simplicity suggests:
monotone in the parameter is not visible on screen, because what the user sees is a composed
observable that can hit zero while the parameter behaves (E14). An exemption is a claim reviewers
can argue with, which is the point; a missing probe is a hole nobody sees.

*Rejected:* a single generic probe that steps a small particle world and measures some aggregate. It
would be uniform and would answer the wrong question — most parameters would move it slightly, and
nothing would distinguish a control that works from one that leaks into an unrelated statistic.

### E2. The unit of measurement is slider travel, in a declared context

Every metric is computed over positions on the track, from 0 to 1, not over the parameter's numeric
range. This is the whole point: the user moves a handle a distance, and what matters is what that
distance buys. Three metrics, all unit-free:

- **Span** — `|r(1) - r(0)|` divided by the observable's reference magnitude. The control does
  something end to end.
- **Live fraction** — the fraction of adjacent sample pairs where `|Δr|` exceeds the response
  epsilon, as a fraction of the span. Most of the track does something.
- **Cliff** — `max |Δr|` between adjacent samples, as a fraction of the span. No single movement
  jumps the world.

Live fraction and cliff bound the track from opposite sides. Together they *derive* the range and the
step rather than sanctioning numbers somebody chose: a range whose tail is dead fails live fraction,
and a step too coarse to be smooth fails cliff.

**Every measurement happens on a declared context slice.** A slice is a `ProbeContext`: every
parameter other than the one under measurement, fixed at named coordinates. The default slice is the
shipped defaults, with one lift: any strength that gates the observable's own passes (D12)
sits at its reference coordinate — the default where the default is non-zero, a named reference
recorded beside the probe where it is not. Measuring a fluid slider in a world whose fluid strength
is zero would measure the multiplier, not the control; the zero-strength story belongs to dormancy
(E8), and the metrics judge the control's coordinates where the control acts.

Three declarations add slices beyond the default:

- A **joint group** (E12) measures each member on slices with its partner fixed at each named
  point's coordinate.
- A **derived bound** — a descriptor whose ceiling is a function of other live parameters, as
  C7 makes the SPH stiffness ceiling — measures on slices at the corners of the
  deriving parameters' box plus the default. The track always spans the interval the descriptor
  currently serves, so position keeps meaning "fraction of what I can reach"; the corner slices are
  what shows the track stays live at every reachable ceiling, including that it never collapses to
  nothing.
- A **composed observable** (E14) — a promise carried by a product of parameters — measures on
  slices at the corners of its co-factors, which is where the composition sits nearest its floor.

A parameter with no declaration is measured on the default slice alone, and its metrics remain the
single numbers they look like. Where slices are declared, each metric is computed and judged per
slice; no average across slices is formed, because an average is exactly the flattening that lets a
dead slice hide behind a live one.

**Sampling.** Probes declare a budget class. Closed-form probes sample 256 positions; probes that
step a simulation sample 64, because `field_core`'s probes integrate a 64×64 grid for N frames per
sample and the native suite has to stay fast. Where a parameter's own step lattice is coarser than
the sample budget, the real lattice is used.

*Declared limit:* where the lattice is finer than the budget, the cliff metric bounds deltas between
sampled positions rather than between true adjacent steps. For a response that oscillates inside one
sampled interval, a true single step could exceed the sampled delta. No shipped parameter is expected
to oscillate at that scale, and none of the probes is oscillatory by construction, but the test does
not prove it and does not claim to.

### E3. The thresholds are calibrated against named controls, not chosen

`RESPONSE_EPSILON`, `SPAN_MIN`, `LIVE_FRACTION_MIN`, and `CLIFF_MAX` are policy numbers, and picking
them by taste would make the whole apparatus a tautology. They are set by measurement, against a
named set of controls whose status is not in dispute.

**Must pass:** `friction`, `fieldOpacity`, `exposure`, `contrast`, `sphViscosity`. Each is live
across its whole range by inspection of the math it feeds — `fieldOpacity` because compositing
opacity scales output luminance linearly end to end.

**Must fail, and how each must fail is part of the anchor:**

- `rdFeed` and `rdKill` must fail on the default slice AND pass on their joint group's slices
  (E12). `F ≥ 4(F+k)²` is the condition for a nontrivial fixed point to exist (D2;
  pinned at tests/test_field_core.nim:509), so most of their rectangle moves nothing on any single
  slice through the default — a metric that passes them unsliced is measuring the wrong thing. That
  they pass sliced pins the second fact: the deadness is two-dimensional geometry, and the joint
  remedy actually repairs it.
- `trailLength` must fail as a purely one-dimensional case — its persistence is geometric in the
  slider (E1), steep at one end and flat elsewhere — and is repaired by a curve, not a group. It is
  what keeps the calibration gap honest for parameters that have no partner.
- `glowIntensity` must fail at the top of its track: the range spans `[0.0, 3.0]`
  (src/config_ranges.nim:49-50) while the display-clamped observable saturates well below the
  ceiling, so the upper travel is blown out and dead — deadness a raw integral would call live,
  which is why the clamped observable is the probe (E1). Its remedy concentrates authorship at the
  low end: a re-range, a curve, or both, with the measurement choosing between a strictly positive
  floor under a log curve and a zero floor under a power curve (E5 binds that choice).

Set each threshold inside the gap between the must-pass and must-fail sets. **If no gap exists, the
probe is wrong, not the threshold** — that is the failure signal, and the response is to fix the
probe, never to loosen the bar until the table goes green. Record the measured distribution beside
the constants.

*Starting hypotheses, to be replaced by the measurement:* `SPAN_MIN = 0.05`,
`LIVE_FRACTION_MIN = 0.60`, `CLIFF_MAX = 0.25`, `RESPONSE_EPSILON = 1e-4` of reference magnitude.
These are guesses written down so the first run has something to move, not values to defend.

*Rejected:* setting thresholds from a percentile of the measured distribution. It always passes about
the same number of controls whatever the truth is, which makes the bar unfalsifiable.

### E4. A failing control has a remedy ladder, applied in order

1. **Re-range.** If the dead region is at an end of the track and nothing there is worth reaching,
   move the bound. Record the measurement beside the constant in `config_ranges.nim`, in the style
   `RD_DEPOSIT_MAX` already uses (src/config_ranges.nim:96-103).
2. **Curve.** If the dead region is interior, or the live region is a small interval that is
   genuinely wanted, warp the track (E5).
3. **Re-step.** If cliff fails, raise precision so the step shrinks.
4. **Join.** If slice measurements prove the live region is jointly shaped — the member's live
   intervals on partner slices do not overlap, so no partner-independent curve can serve them all —
   declare a joint group (E12). Entry is proven by that measurement, never chosen for convenience.
5. **Exempt, with a reason.** Only when the parameter genuinely has no scalar observable.

Re-ranging is first because a bound is one number and a curve is a function; reach for the smaller
change. Joining sits after re-step because it is the larger commitment — a group restates the
promise of every member — and before exempting because it repairs the control where exempting
removes it from the guarantee. Each rung's evidence is recorded where the change lands: a moved
bound beside its constant, a joint group beside its declaration.

### E5. The travel curve maps position to value, and lives in Nim

`ParamDescriptor` gains `curve: cLinear | cLog | cPower`, with the power exponent carried beside it.
`src/ui/api/slider_curve.nim` provides `valueAt(descriptor, position)` and
`positionOf(descriptor, value)` as a mutually inverse pair, natively tested for round-tripping at the
descriptor's own precision. The panel asks Nim for both directions like it asks for every other
number; TypeScript computes no mapping.

Both directions read the bounds the descriptor currently serves. For a derived bound (E2) that means
the curve warps whatever interval is live right now — position keeps meaning "fraction of the
reachable track" at every ceiling, and the curve needs no knowledge of why the ceiling is what it is.

A `cLog` curve requires a strictly positive minimum — a logarithm has no zero — and the range
authority's static assertions reject the pairing of `cLog` with a bound at zero. That ties a curve
choice to a range decision where the two genuinely move together: giving a parameter logarithmic
travel and giving it a positive floor are one decision, made once, recorded beside the constants.

**The curve changes nothing but the handle's position.** The stored value, the preset key, the clamp,
the notch coordinates, and the value the readout displays are all unchanged. A preset written before a
curve changes loads identically after, because presets store values and never positions.

*Rejected:* fixing dead travel by narrowing every range instead. It works for tail-dead parameters
and fails for interior-dead ones, and it silently removes reachable settings — a range is what a user
*can* express, and the curve is only how far they have to move to express it.

*Rejected:* letting TypeScript apply a curve. It is the exact restatement of a Nim-owned number the
`gardenAPI` boundary exists to forbid, and a curve applied on one side only makes `setParam`'s
clamping disagree with the handle.

### E6. The parameter dispatch is generated from the state records' field names

`setParamImpl`'s hand-written `case` (src/web_api.nim:407-508) becomes a compile-time walk over
`SimulationState` and `RenderState` field names, assigning when the descriptor id matches. A
descriptor id that names no field in the store it routes to fails to compile.

This converts the plan's worst silent failure — `else: discard` (src/web_api.nim:508), a control
wired to nothing, reporting success — into a build error. It also deletes roughly a hundred lines
whose only content is the identity relation between an id and a field of the same name.

The relation the generated dispatch depends on is already pinned natively:
`tests/test_param_descriptor.nim` asserts store routing, and the state records are pure modules the
native suite imports. Two routes keep explicit arms, because neither is a field assignment: the
palette pair (`psPalette`) writes editor state and triggers `applyPaletteToColors()`, and the camera
route (`psCamera`) writes the live camera, which is view state deliberately absent from CONFIG and
the preset schema (src/ui/api/param_descriptor.nim, `ParamStore`).

*Rejected:* a startup self-check that writes each parameter and reads back the CONFIG mirror. It
catches the same class one build later, at runtime, in a place a user might reach first. Prefer the
compile error.

*Residual gap, stated:* the generated dispatch proves the typed store is written. That the flat
GPU-facing CONFIG mirror receives the same value in the same tick remains guaranteed by
`updateSimulation`/`updateRender` and documented in `src/web_api.nim`, not by a test. This change
does not close that and does not claim to.

### E7. Acknowledgement is instant and unconditional; response is declared separately

Two different things are owed to someone who moves a control, and conflating them is why a slow
parameter reads as a broken one.

**Acknowledgement** happens in the same tick, always, regardless of what the simulation does: the
handle moves, the readout updates, and the control briefly highlights. It is the panel's own
behaviour and depends on nothing.

**Response** is the world changing, and it has a horizon. The descriptor declares one:

- `rhInstant` — visible in the next frame. Every render-store parameter.
- `rhSettling` — visible over roughly a second as motion redistributes. Friction, force strength, the
  force-model pair, SPH parameters.
- `rhStructural` — visible over many seconds, or on the next commit. Particle count, species count,
  the field parameters, which have to propagate through the reaction before anything looks different.

The panel renders a quiet settling indicator while an `rhSettling` or `rhStructural` control's
horizon has not elapsed. The horizon is a declaration; where a stepping oracle exists —
`field_core` and `physics_core` — a test asserts the observable has moved past the response epsilon
within the declared horizon, and where no stepping oracle exists the declaration is review-enforced
and labelled as such in the descriptor.

*Rejected:* making the acknowledgement conditional on the response. It would give the strongest
feedback exactly where the simulation is slowest, which is backwards.

### E8. A control that cannot act now says what is missing, and never leaves

Every control is offered at all times; nothing appears or disappears with the world's state
("One world offers one control set"). Dormancy is therefore the panel's entire vocabulary
for "working, but not right now": a dormant control renders dimmed with one line naming the missing
precondition — *"nothing has ignited yet"*, *"Bloom is off"*, *"the world has no fluid"* — and
remains fully movable, because setting a value now so it takes effect when the world catches up is a
legitimate thing to want.

**The predicate is declared per descriptor, over named state.** `dormantWhen` names a pure predicate
whose inputs are state fields and streamed stats. A native check walks the named fields against the
state records, so a predicate cannot silently rot when a field is renamed; what the predicate
*means* — that it names the true precondition for this control's consumer — is review-enforced
against D12's ownership split, and that residual is stated below rather than claimed away.

**Families are shared predicates, not a mechanism.** Whole families go dormant together — every
control whose effect is multiplied by a coupling strength (D12) declares dormancy at that
strength's zero, so a world with no fluid dims the fluid family as one visual block. The family is
emergent: many descriptors naming the same predicate. There is no group-level mechanism, because
membership does not follow the panel group — `interactionRadius` sits among the physics controls yet
feeds the world-intrinsic density that always runs, so it declares no coupling dormancy at all — and
because a layer that switches whole sections is a control set that changes with what the world is
doing, which the panel promises never to do. Two rules keep the declarations honest:

- A control never goes dormant under its own value. Zero is an ordinary value (D7), and
  the slider sitting at zero is precisely the control that brings its coupling back; dimming it
  would tell the user the way out is closed.
- A predicate names the strength that multiplies the control's consumer, per D12's split — which
  for chemistry means the deposit and field-force pair govern different controls, since the field's
  own evolution is world-intrinsic and scaled by neither.

**A conditionally-consumed parameter is dormancy's to explain.** Exposure, Bloom Intensity,
Saturation, Contrast, and Temperature are written to the tonemap uniform every frame
(src/webgpu_render.nim:1673-1681) and consumed only when the present path takes the bloom branch
(:1756). The dispatch check (E6) passes — the store field is written — and the probe (E1) passes —
the mirrored grading math moves — so neither mechanism can catch it: what fails is consumption, a
runtime branch in the render path that no native surface sees. The structural alternative — making
the render path's dispatch conditions data and relating every parameter to the conditions under
which its consumer binds — is a render-frame registry that does not exist, and building it is
declared out of scope in the proposal. Dormancy states the truth the user needs: the five sliders
declare dormancy on the same state field the render branch reads, the line says *"Bloom is off"*,
and flipping the toggle wakes all five in the same tick. *Residual, stated:* the predicate and the
render branch agree by review, not by proof; the compile-checked field name makes a rename loud, and
nothing yet makes a logic drift loud.

**The field's calibrators go dormant by mathematics, and the line teaches it.** While the field
rests at its trivial fixed point and the current feed and kill satisfy `F < 4(F+k)²` — where no
nontrivial fixed point exists and the uniform state is linearly stable (D2;
tests/test_field_core.nim:509) — no movement of feed or kill can light the field, because in that
region a pattern must be nucleated by deposits. `rdFeed` and `rdKill` then carry a dormancy line
saying nothing has ignited yet. The predicate is compound — unlit field AND subcritical climate —
and both terms matter: the named regimes themselves sit in the subcritical region, so the line
speaks only while the field is dark, never about the coordinates being barren; and a user who moves
into `F ≥ 4(F+k)²` has chosen a self-starting climate, so the pair leaves dormancy the moment the
condition breaks, before anything ignites. The metric failure E3 predicts for this pair becomes an
explanation the user reads in the panel, which is this change's whole point.

**Dormancy never touches measurement.** The sweep (E2) runs on declared context slices, pure and
native, never against the live world. A control that is dormant in some worlds is measured exactly
like every other control — in the context where it acts.

*Rejected:* hiding dormant controls. Hiding teaches nothing, makes the panel's height jump while the
world evolves, and turns "I do not understand this" into "where did it go".

*Rejected:* a family- or section-level dormancy mechanism. A layer keyed on sections dims by where
a control sits rather than by what consumes it, and the grid counterexample above shows those
disagree.

### E9. Parameters with a spatial meaning draw themselves in the world while dragged

Some parameters are a length, and a number cannot say what that length is. While such a control is
being dragged, the renderer draws a transient overlay at world scale: `interactionRadius` as a ring at
the cursor, the deposit splat radius as a disc, camera zoom as a frame. The overlay disappears on
release.

The set is deliberately closed to parameters that are literally a distance in the world. Extending it
to non-spatial parameters would mean inventing a visual metaphor per control, which is a different and
much larger project.

### E10. One markdown source serves both the help panel and the feature documentation

`docs/help/*.md` is authored as markdown, one file per descriptor group plus an orientation file and a
glossary, each declaring the group id it documents. `src/ui/api/help_content.nim` `staticRead`s them
into a table at Nim-compile time — the mechanism `webgpu_render.nim` already uses for render shaders
and `main.nim` uses for the UI bundle — and `gardenAPI.help()` serves them. The panel renders a
restricted markdown subset: headings, paragraphs, lists, emphasis, code spans, and internal links.

Coverage is native and runs in both directions:

- every descriptor group has a help file;
- every help file's declared group id exists in the descriptor table;
- every descriptor in a group is named by its group's help file;
- no help file names an id that is not a descriptor.

Those four are what keep the documentation true. A control renamed without its documentation
following turns the suite red at the moment of the rename rather than at the moment someone reads it.

The descriptor's existing one-line `hint` stays where it is. Hint and help are different lengths for
different moments: the hint is terse and coupled to the range, which is why its numerals are already
checked against the slider lattice (tests/test_param_descriptor.nim:94); the help file is the
paragraph. Neither restates the other.

*Rejected:* generating the help markdown from Nim string literals. Markdown authored as markdown
reviews better, diffs better, and reads correctly in the repository without a build step.

*Rejected:* fetching help over HTTP from the native server like compute shaders. `staticRead` costs a
few kilobytes in `app.js` and removes a way to fail at runtime; help that fails to load is worse than
help that is slightly larger.

### E11. The gesture and key reference is generated, not authored

`src/ui/input/binding_table.nim` becomes the single declaration of every mouse gesture, touch gesture,
and key binding — consumed by the input handlers and rendered into the help panel's reference section.
A binding cannot exist without appearing in help, because both read the same table.

This is the single-declaration relation the descriptor table already establishes for parameters —
the panel renders what the one table declares, and nothing second exists to drift — applied to
input. A native test asserts every entry carries a non-empty description, since a table row nobody
described renders as a blank line in help.

### E12. The unit of legibility is the smallest parameter set whose live region is a product of intervals

For nearly every control that set is the singleton, and the one-dimensional machinery of E2-E5 is
the whole story. It is not the whole story for `rdFeed` and `rdKill`: the analytic condition
`F ≥ 4(F+k)²` couples them (D2), and the regime geography couples them empirically
(D4). No one-dimensional curve can concentrate travel onto a live set that moves with the
partner, because a curve is a fixed warp of one track. Defining the unit by geometry rather than by
naming feed and kill means a future coupled pair joins by measurement, not by amending this
document.

**Entry is proven, not chosen.** Measure the member's live interval on slices with its partner fixed
at each named point's coordinate (E2). If the live intervals on two slices do not overlap, no
partner-independent curve can serve both — that measurement is the entry evidence, recorded beside
the group declaration, and an implementer reaching for this rung without it is caught by the same
review that catches an unjustified exemption. Slices through regimes that carry a deposit floor fix
deposit at `max(default, minDeposit)` (src/config_ranges.nim:117-124) — a slice through Worms at the
default deposit measures a dead world, for the reason the floor exists.

**What the joint group guarantees**, replacing the members' per-slider global live fraction. Three
of the four adopt tests that already exist rather than duplicating them:

- **Joint reachability** — every named point is reachable through the selector and lies on both
  sliders' lattices. Adopted: the descriptor suite already asserts every notch sits on its slider's
  lattice (src/ui/api/param_descriptor.nim:56, tests/test_param_descriptor.nim).
- **Slice liveness** — each member is individually live within a declared neighbourhood of *every*
  named point, measured on the slice through it. This is the promise that moving one slider near a
  regime visibly moves the world. New; this change builds it.
- **Cliff, unchanged** — a per-slider whole-track property about one step jumping the world. It
  survives one-dimensional and stays global.
- **Attractor fidelity** — each named point settles into its own attractor, distinct from every
  other's. Adopted: `The Regime Deposit Floor Preserves The Regime` (tests/test_field_core.nim:1125)
  already proves exactly this, with a separation check, a negative control, and an aliveness floor.

**What separates a remedy from an admission of defeat.** A selector that teleports between islands
with dead track between them is a dropdown wearing slider clothes. Three conditions discriminate, and
failing any one is the defeat case: destinations are distinct (cross-point separation exceeds
within-point variation); surroundings are live (slice liveness holds, so the selector maps a
landscape the sliders still traverse); and travel between points is continuous and cliff-free —
adopted from the climate tour's continuity, no-jump, and easing tests
(tests/test_climate_core.nim:60-86), which prove it for this exact parameter pair.

Under those three the pair's promise is honestly restated. Not "each slider is alive everywhere",
which was never true of Gray-Scott and no instrument can make true, but **"the pair locates living
worlds, and each slider is alive wherever the pair has located one."**

### E13. An edit in progress belongs to the user, and the matrix is recalibrated to say so

A text-editable cell holds uncommitted intermediate states — including empty — and applies clamping
on commit, never on the keystroke. A re-render caused by anything other than the user's own commit
leaves an in-progress edit untouched. The matrix cell handler violates both today: it parses on
commit, maps an emptied field through `NaN` to a forced re-render back to the live value
(web-ui/src/components/MatrixEditor.tsx:46-55), and redraws every cell from the live buffer whenever
the matrix version bumps, so the intermediate state every retyped number passes through is treated
as an error and reverted.

**The matrix range becomes ±0.100 with step 0.001 and three-decimal display.** An order of magnitude
gentler across the board, calibrated together with the crowding attenuation (C1-C2) rather than
separately — each tuned against the other's old behaviour
would leave both wrong. The recalibration is recorded beside the constants with the same
measurement-comment discipline every other bound carries (parameter-range-authority).

**One authority, no restatements.** The matrix bounds, step, and display precision move into
`config_ranges.nim` as `MATRIX_MIN_VALUE`/`MATRIX_MAX_VALUE` and companions, collapsing the
documented copy the preset schema keeps because it must not import `src/ui`
(src/preset.nim:147-149) — the range authority sits below both, so both read the one fact
(D11). The boundary serves all of them beside the existing matrix surface
(src/web_api.nim:960-964), and the editor restates none — today it hardcodes the step and the
display precision (MatrixEditor.tsx:92-93). The random-fill distribution
(src/ui/state/matrix_state.nim:140-144) is recalibrated to the new range so a randomized world
keeps its character rather than inheriting a sampler tuned for bounds ten times wider.

*Rejected:* clamping on every input event with a smarter parser. However smart, it decides mid-edit
what the user meant, and the empty field proves there are moments where the only honest answer is
"nothing yet".

### E14. A promise about a visible result is guaranteed on the result, not on a parameter

A particle's on-screen radius is a product: the size parameter, the density size multiplier (0.7 to
1.3, web/shaders/src/render.wgsl:65-66 and :110), the world-to-screen scale, the camera zoom, and
the camera size correction (render.wgsl:160, glow.wgsl:105). `PARTICLE_SIZE_MIN = 1`
(src/config_ranges.nim:45) bounds one factor of that product, so at small size and low zoom the
product lands under a pixel and the fragment coverage test removes what remains: particles vanish
while every bound holds. `CAMERA_SIZE_FLOOR = 0.5` (src/camera_core.nim:30-31) is the same
intention placed halfway down the chain — it floors the apparent-scale *factor*, so it protects
against zoom alone and not against zoom compounded with a small size.

**This is its own defect class, not an instance of the others.** The control is wired (E6 passes),
its own math moves (a probe on the parameter's expression passes), its consumer is bound (E8's
conditionally-consumed case is absent), and per slice the track's coordinates can be fine. What
breaks is that the guarantee was attached to a factor of a product while the promise is about the
product — and no re-range, curve, or re-step of the parameter can fix it, because another factor
can always carry the product past the promise. It is kin to E12, since the live region of "visible"
is jointly shaped by size and zoom; the remedy differs because the promise is one-sided. Nobody
needs to navigate the size-zoom plane — the product must simply never cross a line. A one-sided
promise about a composition takes a **floor on the composition**.

**Decision.** The visible-radius chain becomes a pure function in `camera_core.nim` beside the
transform math it extends, and the floor — in pixels, at the end of the chain — becomes a
range-authority constant asserted natively at the worst reachable corner: minimum size, minimum
zoom, the density multiplier at its 0.7 floor. The renderers clamp at the same point in the same
chain, both shaders and the mirror changing together as for every oracle. `particleSize`'s probe
measures this composed observable on slices at the zoom corners (E2), so the sweep, not review,
holds the floor. Whether `CAMERA_SIZE_FLOOR` survives as an aesthetic shaping of the zoom-size
relation or retires into the result floor is the implementer's call from the measurement; if it
stays, its comment says plainly that it is not the visibility guarantee.

The same error shape appears twice more in this change's material: glow's raw alpha integral keeps
rising where the display has clamped (E1, E3), and a stiffness ceiling written as a constant where
it is a function of other live parameters (the derived bounds E2 slices). All three reduce to one
sentence — **the number you bounded is not the thing you promised** — and E2's slices detect the
class wherever an end-of-chain observable exists. This decision is what makes such an observable
exist for visibility.

## Risks / Trade-offs

- **A probe can be wrong in the same direction as its shader is wrong.** The oracle family's standing
  weakness: it verifies the Nim mirror, not the WGSL. A probe passing proves the parameter moves the
  mirrored math, not the pixels. Stated, not solved.
- **A dormancy predicate can be semantically wrong.** The field names are compile-checked; the logic
  is review-enforced against D12's ownership split. A predicate naming the wrong strength
  dims a live control or leaves a quiet one bright, and only review catches it. Stated in E8.
- **Stepped probes cost native suite time.** `field_core` probes integrate a grid per sample, and
  E12's slices multiply the feed/kill sweeps by the named points. The 64-sample budget for stepped
  probes is chosen for that; if `just test` slows materially, lower the stepped budget before
  dropping parameters or slices from coverage.
- **Calibration may find more failures than expected.** `rdFeed`, `rdKill`, and `trailLength` are
  predicted failures and are the reason the thresholds are calibratable; others may join them. Each
  failure is a real defect and goes through the E4 ladder. A wave of curve changes is the correct
  outcome, not a reason to relax the bar.
- **The matrix recalibration changes every saved world's feel.** Loaded presets clamp matrix values
  into ±0.100 through the schema, so a matrix authored at ±1 loses its contrasts. This is the cost
  of calibrating the matrix and the crowding cap together, and it belongs in the release notes.
- **The visibility floor changes what extreme corners look like.** At minimum size and minimum zoom,
  particles render at the floor instead of vanishing — that is the point, and it is a visible change
  for any world that lived at those corners. Release-notes item beside the matrix one.
- **`descriptor()` grows.** Probe id, context, curve, exponent, horizon, and dormancy predicate name
  join the payload. It is built once at module-eval time and cached (src/web_api.nim:181, served at
  :908), so the cost is one array, not per-frame work.
- **The markdown renderer is new surface in TypeScript.** Restricted to a documented subset, pinned by
  `bun test`. If it grows past the subset, that is a signal the help is doing something it should not.

## Migration Plan

Presets store values, not track positions, so E5's curve is invisible to them. Descriptor ids do not
move — E10 and the help coverage tests key on ids, and an id is a preset storage key. Where E4's
ladder re-ranges a parameter, `preset.nim` clamps loaded presets into the new bound through
`config_ranges` exactly as it does for every other bound change, and the reachability suite
(parameter-range-authority) keeps every notch and hint numeral on the lattice through any re-range —
a bound cannot move past a coordinate the descriptor names.

The one stored-data change is the matrix: values saved in `[-1, 1]` clamp into `[-0.100, 0.100]` on
load. Old presets keep loading; their matrix contrast compresses. Release-notes item, priced in E13.

### Ordering within the change

One dependency: a dormancy predicate over a coupling strength can only name a strength that exists,
and the strengths arrive with the strength collapse (D7, D13; task group 9). The strength-family
predicates land after that delivery; every other piece of the legibility work — probes, contexts,
curves, dispatch, horizons, the matrix editor, overlays, help — is independent of it. The legibility
fields join a descriptor payload that already carries notches; it grows once more here, in one
revision of the table, `descriptor()`, and `ParamSlider`.

## Open Questions

None. E1 settles what is measured and by what, E2 settles the unit, the context, and the sampling,
E3 settles how the thresholds are set and what to do when they cannot be, E4 settles what to do
about a failure, E5 through E9 settle the panel's behaviour, E10 and E11 settle where documentation
lives and how it stays true, E12 settles the joint unit and its guarantees, E13 settles who owns an
edit in progress, and E14 settles where a guarantee about a visible result lives.

Four outcomes are measurements rather than decisions, and each names its own procedure: the
threshold values (E3), which parameters need a curve and how glow's track is recentered (E4),
whether a parameter set enters a joint group (E12's entry evidence), and the visibility floor's
pixel value at the worst corner (E14). None requires research — each requires running the sweep the
tasks describe and reading the numbers.
