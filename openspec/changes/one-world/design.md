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

### D7. Simultaneous forces + SPH + field is permitted, and one preset uses it

Couplings are independent booleans, so the combination falls out structurally rather than needing
support. It is also genuinely interesting — SPH pressure with species affinity gives cohesive blobs
that still sort by species. It ships as the "Fluid Chemistry" preset.

If task group 9 measures it over budget, the fix is that preset's default particle count, not the
removal of the capability.

### D8. SimKind survives as a preset compatibility layer

`buildFrame` takes WorldCouplings; simKindId/parseSimKind map legacy ids to couplings triples so
preset.nim's `mode` field keeps meaning what it meant.

**No migration is needed and none should be written.** src/preset.nim:124-130 documents `mode` as
deliberately **not** restricted to a known-mode allowlist, precisely so a v1 preset written by a
future build round-trips. `validate` rejects only a schemaVersion *higher* than
CURRENT_SCHEMA_VERSION (src/preset.nim:444-449); it does not police mode strings.

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

## Risks / Trade-offs

- **Deposit splat cost** — one atomic per covered cell per particle. Mitigation: keep the kernel at
  the measured minimum; if group 9 shows it dominating, shrink the kernel or lower the field substep
  count before touching particle count.
- **Positive tropism feedback** — bounded by D5 and measured by task 5.5.
- **A living world lost on a preset click** — the ceiling clamp lowers count in place, keeping
  survivors; no Fisher-Yates re-randomization.
- **Bloom passes carry no profiler timestamps** (src/webgpu_render.nim `beginBloomPass`) — a known
  measurement gap in group 9. Noted, not fixed here.
- **Legacy-frame equivalence** — the three legacy couplings triples must dispatch what they dispatch
  today. Pinned by tests before any shader edit; that equivalence is the regression check for the
  whole restructure.

## Migration Plan

Behavior-identity for the three legacy triples is the group 2 regression check, pinned in
tests/test_sim_registry.nim. Legacy preset ids map through the D8 compatibility layer. No data
migrates.

## Open Questions

None. Every question raised during design is resolved above: D1 settles the atomics ordering, D2 and
D3 settle ignition and the default climate, D4 settles the regime interface and the feed ceiling, D5
settles the tropism bound, D6 settles the activator slot, and D7 settles the triple coupling.

The implementer's job is to build and measure, not to research. Where a decision depends on a
measurement, the measurement task is named, the expected outcome is stated, and the fallback ladder is
written out.
