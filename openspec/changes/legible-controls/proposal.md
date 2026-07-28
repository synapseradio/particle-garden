## Why

A control panel makes a promise: move this, and something happens. Three defect classes break that
promise today, and nothing in the build or either test suite catches any of them.

**A control can be wired to nothing.** `setParamImpl` dispatches on the descriptor id through a
hand-written `case` ending in `else: discard` (src/web_api.nim:349-424). A descriptor added without
its matching arm clamps its value, writes nowhere, and reports success. The slider moves, the readout
updates, and the simulation never hears it. `tests/test_param_descriptor.nim` pins the descriptor's
range, default, and store routing against `config_ranges` and the state records, but nothing relates
the id to a write, because that dispatch lives on the JS backend where no native test reaches.

**A control can be wired correctly and still do nothing over most of its travel.** `rdFeed` and
`rdKill` span `[0.010, 0.080] × [0.040, 0.075]` (src/config_ranges.nim:83-86), and the one-world
design derives `F ≥ 4(F+k)²` as the condition for a nontrivial fixed point to exist at all
(openspec/changes/one-world/design.md D2). Most of that rectangle has no pattern in it under any
perturbation. The current mitigation is a string of coordinates the user is expected to decode —
`hint = "spots .035, stripes .029, coral .055, worms .078"` (src/ui/api/param_descriptor.nim:204).
`trailLength` has the same shape of problem from the opposite direction: the trail decays
geometrically (fade.wgsl:48-49), so persistence is a steep function of the slider near one end of the
track and flat across the rest. In both cases the range and the step are honest numbers presented in
the wrong coordinates.

**A control can be visible while nothing it acts on exists.** `fieldOpacity` and `rdFieldForce` are
shown whenever their group shows, including when the field is at its trivial fixed point and there is
nothing to make opaque or to push with. The panel offers no distinction between *"you moved this and
it did nothing because it is broken"* and *"you moved this and it did nothing because the world is
not ready for it yet"*, and those feel identical from the outside.

Underneath all three: **the application ships no user-facing documentation of any kind.** `docs/`
holds a performance report and a research folder, both written for contributors. Nothing tells
someone looking at the window what they are looking at, what the gestures are, or what any control
means.

## What Changes

- Add a **response probe** to every descriptor: a pure Nim function returning a scalar the parameter
  demonstrably moves, drawn from the existing reference-oracle family. A descriptor with no probe
  carries a written exemption; the pairing is total and enforced natively.
- Test every control for **span, live fraction, and cliff** across its own slider travel — the
  end-to-end effect is non-trivial, most steps of the track change the response, and no single step
  jumps it. These three properties are what "reasonable increments and total ranges" reduces to, and
  they derive the range and step rather than asserting hand-picked numbers.
- Add a **travel curve** to the descriptor, owned in Nim and served through `descriptor()`, so a
  slider's position maps to its value non-linearly where a linear map wastes the track. Stored values,
  preset keys, and clamping are untouched — the curve maps position to value, nothing else.
- **Generate the parameter dispatch** from the state records' field names, replacing the hand-written
  case. A descriptor id that names no field becomes a compile error instead of `else: discard`.
- Extend the reference-oracle family with **`glow_core.nim` and `trail_core.nim`**, mirroring
  glow.wgsl's falloff and alpha composition and fade.wgsl's geometric decay, so the render-side
  sliders become measurable rather than exempt.
- Give every control an **immediate, unconditional acknowledgement** — readout, handle, and a brief
  highlight in the same tick — separated from its **declared response horizon**, so a slow parameter
  reads as slow rather than as broken.
- Mark a control **dormant, with the reason**, when the state it acts on does not exist. A dormant
  control stays visible and stays movable; it says what is missing.
- Draw a **transient world overlay** for the parameters that have a spatial meaning — interaction
  radius, deposit splat radius, camera zoom — for as long as the control is being dragged.
- Add **in-app help**: markdown authored under `docs/help/`, `staticRead` into the frontend at
  Nim-compile time, opened by `?` and a button. The same files are the feature documentation, so
  there is one source and no second copy to drift.
- **Generate the gesture and key reference** from the binding table the input handlers use, rather
  than authoring it, so a binding cannot exist without appearing in help.

## Capabilities

### New Capabilities
- `control-legibility`: every visible control has a measured effect, presented in coordinates where
  the effect is distributed across the track, with an acknowledgement the user cannot miss and a
  stated reason when it cannot act.
- `in-app-help`: one markdown source serving both the in-app help panel and the feature
  documentation, with native coverage tests in both directions and a generated gesture reference.

### Modified Capabilities
- `gardenapi-boundary`: descriptors gain a probe id, a travel curve, a response horizon, and a
  dormancy predicate; the parameter dispatch is generated rather than hand-written; help content is
  served from Nim like every other authored string.
- `parameter-range-authority`: a range and a step are justified by the measurement that produced
  them, recorded beside the constant, rather than by review.
- `native-test-strategy`: probe coverage over the descriptor table is total and enforced; two new
  reference oracles join the family; help coverage is a native test in both directions.

## Impact

- `src/ui/api/param_descriptor.nim` — probe id, curve, horizon, dormancy predicate, exemption table.
- `src/ui/api/response_probe.nim` (new, pure) — the probe registry and the span/live/cliff metrics.
- `src/glow_core.nim`, `src/trail_core.nim` (new, pure) — render-side reference oracles.
- `src/ui/api/slider_curve.nim` (new, pure) — position↔value mapping and its inverse.
- `src/ui/api/help_content.nim` (new) — `staticRead` of `docs/help/*.md`, keyed by group id.
- `src/ui/input/binding_table.nim` (new, pure) — the single gesture/key table help renders from.
- `src/web_api.nim` — generated dispatch, `descriptor()` payload growth, `help()`, dormancy state.
- `src/config_ranges.nim` — ranges and steps revised where the measurement says the track is dead.
- `web-ui/src/components/` — `ParamSlider` gains curve, notch, highlight, dormancy, and overlay
  behavior; a new `HelpPanel`.
- `docs/help/*.md` (new) — the help and feature documentation source.
- `tests/test_response_probe.nim`, `tests/test_slider_curve.nim`, `tests/test_glow_core.nim`,
  `tests/test_trail_core.nim`, `tests/test_help_content.nim` (new), and
  `tests/test_param_descriptor.nim`.

## Non-Goals

- Measuring anything through the GPU. Every probe is a pure Nim mirror of shader math, in the
  reference-oracle style the codebase already uses. A probe that disagrees with its shader is a
  reference-oracle defect, and it is caught the same way every other oracle drift is caught: by
  someone editing one side and not the other. This change does not close that gap and does not claim
  to.
- A perceptual model. "Noticeable" here means the response metric moves by more than the calibrated
  threshold, not that a human eye resolves it. The thresholds are calibrated against controls whose
  liveness is not in dispute, which is what makes them defensible; they are not psychophysics.
- Tutorials, onboarding tours, or first-run walkthroughs. Help is a panel the user opens.
- Localization. Help and labels are English, authored in one place.
- Replacing the notch and named-regime work. Those belong to `one-world` (design D4) and this change
  builds on them where they exist; the two are order-independent.
