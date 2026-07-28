## Context

Every user-facing tunable is one `ParamDescriptor` (src/ui/api/param_descriptor.nim:38-57) carrying
id, label, group, kind, range, step, precision, default, store routing, reinit flag, and a free-text
hint. `tests/test_param_descriptor.nim` pins each of those against its authority: ranges against
`config_ranges`, defaults against the state records, steps against the kind-and-precision rule, and
the numerals inside hints against the lattice the slider can actually land on (line 83). What no test
relates is the descriptor to an **effect** — nothing checks that writing the parameter changes
anything, and nothing checks that the range and step present that change in usable coordinates.

The material for such a check already exists. Several pure modules mirror WGSL math for the native
suite and have no importer in `src/` by design — `physics_core`, `sph_core`, `field_core`,
`bloom_core`, `colormap_core` (CLAUDE.md, "Reference oracles"). They are the response functions this
change needs, already written, already tested against their own properties.

*Readiness verdict on that family:* it is a **proven foundation for the parameters it already
covers** — those oracles are imported and exercised by the existing native suite, and in some cases by
`shader_config.nim` for the constants it substitutes into shaders, so their math is live rather than
notional. It is **not a foundation for the render-side sliders**: glow, trail, and particle geometry
have no mirror at all, which is why this change writes two new ones rather than claiming coverage it
does not have. The prerequisite to calling the family complete for this purpose is `glow_core.nim`
and `trail_core.nim` existing and passing (decision E1).

## Goals / Non-Goals

**Goals**
- No visible control that writes nowhere, and no way to add one.
- No visible control whose effect is concentrated in a small fraction of its track.
- A user who moves anything sees something change in the same tick, whether or not the world responds
  immediately.
- A control that cannot act right now says what is missing, in words.
- One place to author what a feature is, serving both the person in the app and the person reading
  the repository.

**Non-Goals** — see the proposal's Non-Goals. Each is a decision, not a deferral.

## Decisions

### E1. Effect is measured through a declared response probe, not asserted by review

Each descriptor names a **response probe**: a pure Nim function `proc(value: float): float` returning
a scalar observable that the parameter is supposed to move. The probe registry
(`src/ui/api/response_probe.nim`) maps probe ids to functions; the descriptor carries the id.

Probes come from the reference-oracle family wherever one exists. The assignment:

| Probe source | Observable | Parameters |
|---|---|---|
| `physics_core` | force magnitude at a fixed separation; post-step speed | forceStrength, ruleTemperature, repulsionEnd, attractionPeak, expRepulsionAlpha, expAttractionBeta, interactionRadius, friction, timeScale, maxVelocity |
| `sph_core` | pressure at rest density; kernel-weighted neighbour contribution | sphRestDensity, sphStiffness, sphViscosity, sphSubsteps |
| `field_core` | `FieldStats.aliveFraction` and the std/mean structure ratio after N frames | rdFeed, rdKill, rdDeposit, rdFieldForce |
| `bloom_core` | graded output luminance for a fixed HDR input | bloomIntensity, exposure, saturation, contrast, temperature |
| `colormap_core` | composited field luminance over background | fieldOpacity |
| `palette` | mean pairwise colour distance across the species palette | paletteSaturation, paletteLightness |
| `glow_core` *(new)* | halo alpha integrated over radius | glowIntensity, velocityGlowScale, glowRadiusScale, glowFalloff, glowWarmth |
| `trail_core` *(new)* | 1/e persistence length in frames | trailLength |

`glow_core.nim` mirrors glow.wgsl's `exp(-glowFalloff * l * l)` falloff, its radius composition at
:89-92, and the alpha and warmth composition at :151-162. `trail_core.nim` mirrors fade.wgsl's
geometric decay at :48-49 and the trailLength→fadeAmount mapping.

**Exemptions are declared, not implied.** A descriptor may carry an exemption instead of a probe id,
with a written reason, and a native test asserts the union of probed and exempted descriptors is the
whole table. Three exemptions ship: `particleCount` and `speciesCount` (the observable is the count
of things drawn — self-evident and structural, and probing it would measure the probe), and
`particleSize` (geometry in pixels, monotone by construction). An exemption is a claim reviewers can
argue with, which is the point; a missing probe is a hole nobody sees.

*Rejected:* a single generic probe that steps a small particle world and measures some aggregate. It
would be uniform and would answer the wrong question — most parameters would move it slightly, and
nothing would distinguish a control that works from one that leaks into an unrelated statistic.

### E2. The unit of measurement is slider travel, not parameter value

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

**Must pass:** `friction`, `glowIntensity`, `exposure`, `contrast`, `sphViscosity`. Each is live
across its whole range by inspection of the math it feeds.

**Must fail:** `rdFeed` and `rdKill` — `F ≥ 4(F+k)²` (one-world design D2) proves most of their
rectangle supports no pattern under any perturbation, so a metric that passes them is measuring the
wrong thing. `trailLength` — fade.wgsl:48-49 decays geometrically, so persistence is a steep function
of the slider near one end of the track and nearly flat across the rest.

Set each threshold inside the gap between those two sets. **If no gap exists, the probe is wrong,
not the threshold** — that is the failure signal, and the response is to fix the probe, never to
loosen the bar until the table goes green. Record the measured distribution beside the constants.

*Starting hypotheses, to be replaced by the measurement:* `SPAN_MIN = 0.05`,
`LIVE_FRACTION_MIN = 0.60`, `CLIFF_MAX = 0.25`, `RESPONSE_EPSILON = 1e-4` of reference magnitude.
These are guesses written down so the first run has something to move, not values to defend.

*Rejected:* setting thresholds from a percentile of the measured distribution. It always passes about
the same number of controls whatever the truth is, which makes the bar unfalsifiable.

### E4. A failing control has a remedy ladder, applied in order

1. **Re-range.** If the dead region is at an end of the track and nothing there is worth reaching,
   move the bound. Record the measurement beside the constant in `config_ranges.nim`, in the style
   `RD_DEPOSIT_MAX` already uses (src/config_ranges.nim:90-97).
2. **Curve.** If the dead region is interior, or the live region is a small interval that is genuinely
   wanted, warp the track (E5).
3. **Re-step.** If cliff fails, raise precision so the step shrinks.
4. **Exempt, with a reason.** Only when the parameter genuinely has no scalar observable.

Re-ranging is first because a bound is one number and a curve is a function; reach for the smaller
change. Exempting is last because it removes the control from the guarantee rather than fixing it.

### E5. The travel curve maps position to value, and lives in Nim

`ParamDescriptor` gains `curve: cLinear | cLog | cPower`, with the power exponent carried beside it.
`src/ui/api/slider_curve.nim` provides `valueAt(descriptor, position)` and
`positionOf(descriptor, value)` as a mutually inverse pair, natively tested for round-tripping at the
descriptor's own precision. The panel asks Nim for both directions like it asks for every other
number; TypeScript computes no mapping.

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

`setParamImpl`'s hand-written `case` (src/web_api.nim:349-424) becomes a compile-time walk over
`SimulationState` and `RenderState` field names, assigning when the descriptor id matches. A
descriptor id that names no field in the store it routes to fails to compile.

This converts the plan's worst silent failure — `else: discard`, a control wired to nothing, reporting
success — into a build error. It also deletes seventy-five lines whose only content is the identity
relation between an id and a field of the same name.

The relation the generated dispatch depends on is already pinned natively:
`tests/test_param_descriptor.nim` asserts store routing, and the state records are pure modules the
native suite imports. The two palette parameters keep an explicit arm — they route to the palette
editor state and trigger `applyPaletteToColors()`, which is not a field assignment.

*Rejected:* a startup self-check that writes each parameter and reads back the CONFIG mirror. It
catches the same class one build later, at runtime, in a place a user might reach first. Prefer the
compile error.

*Residual gap, stated:* the generated dispatch proves the typed store is written. That the flat
GPU-facing CONFIG mirror receives the same value in the same tick remains guaranteed by
`updateSimulation`/`updateRender` and documented in `src/web_api.nim`, not by a test. This change does
not close that and does not claim to.

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

### E8. A control that cannot act says what is missing, and stays visible

The panel already gates whole groups on `controlGroupsFor` — a group belongs to a mode or it does not
appear (src/ui/api/param_descriptor.nim:41-43). That stays. Dormancy is the finer condition *within* a
visible group: `fieldOpacity` when the field is at its trivial fixed point, `rdFieldForce` when
nothing has ignited, species chemistry when the field coupling is off.

A dormant control renders dimmed with one line naming the precondition — *"nothing has ignited yet"* —
and remains fully movable, because setting a value now so it takes effect when the world catches up is
a legitimate thing to want. The predicate is declared in the descriptor and evaluated against pushed
stats, which already stream to the panel on their own cadence (`onStats`).

*Rejected:* hiding dormant controls. Hiding teaches nothing, makes the panel's height jump while the
world evolves, and turns "I do not understand this" into "where did it go".

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
checked against the slider lattice (tests/test_param_descriptor.nim:83); the help file is the
paragraph. Neither restates the other.

*Rejected:* generating the help markdown from Nim string literals. Markdown authored as markdown
reviews better, diffs better, and reads correctly in the repository without a build step.

*Rejected:* fetching help over HTTP from the native server like compute shaders. `staticRead` costs a
few kilobytes in `app.js` and removes a runtime failure mode; help that fails to load is worse than
help that is slightly larger.

### E11. The gesture and key reference is generated, not authored

`src/ui/input/binding_table.nim` becomes the single declaration of every mouse gesture, touch gesture,
and key binding — consumed by the input handlers and rendered into the help panel's reference section.
A binding cannot exist without appearing in help, because both read the same table.

This is the same relation `controlGroupsFor` already establishes between what a frame dispatches and
what the panel offers, applied to input. A native test asserts every entry carries a non-empty
description, since a table row nobody described renders as a blank line in help.

## Risks / Trade-offs

- **A probe can be wrong in the same direction as its shader is wrong.** The oracle family's standing
  weakness: it verifies the Nim mirror, not the WGSL. A probe passing proves the parameter moves the
  mirrored math, not the pixels. Stated, not solved.
- **Stepped probes cost native suite time.** `field_core` probes integrate a grid per sample. The 64
  sample budget for stepped probes is chosen for that; if `just test` slows materially, lower the
  budget for stepped probes before dropping parameters from coverage.
- **Calibration may find more failures than expected.** `rdFeed`, `rdKill`, and `trailLength` are
  predicted failures and are the reason the thresholds are calibratable; others may join them. Each
  failure is a real defect and goes through the E4 ladder. A wave of curve changes is the correct
  outcome, not a reason to relax the bar.
- **`descriptor()` grows.** Probe id, curve, exponent, horizon, and dormancy predicate name join the
  payload. It is built once at module-eval time and cached (src/web_api.nim:168-171), so the cost is
  one array, not per-frame.
- **The markdown renderer is new surface in TypeScript.** Restricted to a documented subset, pinned by
  `bun test`. If it grows past the subset, that is a signal the help is doing something it should not.

## Migration Plan

No stored data changes. Presets store values, not track positions, so E5's curve is invisible to them.
Descriptor ids do not move — E10 and the help coverage tests key on ids, and an id is a preset storage
key. Where E4's ladder re-ranges a parameter, `preset.nim` clamps loaded presets into the new bound
through `config_ranges` exactly as it does for every other bound change.

## Open Questions

None. E1 settles what is measured and by what, E2 settles the unit and the sampling, E3 settles how
the thresholds are set and what to do when they cannot be, E4 settles what to do about a failure, E5
through E9 settle the panel's behaviour, and E10 and E11 settle where documentation lives and how it
stays true.

Two outcomes are measurements rather than decisions, and both name their own procedure: the threshold
values (E3) and which parameters need a curve (E4). Neither requires research — both require running
the sweep the tasks describe and reading the numbers.
