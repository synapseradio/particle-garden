## 0. Orientation

This change is independent of `one-world` and can land before it, after it, or between its groups. The
coverage relations here are total over whatever the descriptor table holds, so whichever lands second
inherits the other's parameters automatically. Where the two touch the same file — notches and travel
curves both live in `param_descriptor.nim` — they add different fields and do not conflict.

- [ ] 0.1 Read `CLAUDE.md`, then this change's `design.md`. Decisions E1–E11 are settled; you build
      and measure, you do not re-research them.
- [ ] 0.2 `just happen` and `just check` green on a clean tree before changing anything. A
      pre-existing failure is the first task, not a thing to work around.
- [ ] 0.3 Read `src/ui/api/param_descriptor.nim` end to end and `tests/test_param_descriptor.nim`'s
      test names. Every relation this change adds follows the shape those tests already use.

## 1. Render-side reference oracles

Nothing can be measured that has no mirror. These two are the gap in the family.

- [ ] 1.1 `tests/test_glow_core.nim` (new): `halo alpha falls off as a Gaussian in normalized radius`;
      `alpha scales linearly with glowIntensity`; `warmth is bounded above by glowWarmth`;
      `base radius scales with glowRadiusScale`. Write these before the module.
- [ ] 1.2 `src/glow_core.nim` (new, pure): mirror `web/shaders/src/glow.wgsl` — the radius composition
      at :89-92, the velocity factor at :151, the `exp(-glowFalloff * l * l)` falloff at :155, the
      alpha composition at :156, and the warmth ceiling at :160-162. Expose
      `haloAlphaIntegral(params): float` as the probe observable.
- [ ] 1.3 `tests/test_trail_core.nim` (new): `persistence length is 1/e frames at the fade amount`;
      `zero fade amount gives zero persistence`; `persistence rises monotonically with trailLength`.
- [ ] 1.4 `src/trail_core.nim` (new, pure): mirror `web/shaders/src/fade.wgsl:48-49`'s geometric decay
      and the trailLength→fadeAmount mapping that feeds `FadeParamsLayout`. Expose
      `persistenceFrames(trailLength): float`.
- [ ] 1.5 Register both modules in `tests/test_all.nim` with their marker constants and add them to
      `tests/README.md`'s per-file table and architecture tree. Add both to `CLAUDE.md`'s
      reference-oracle table.
- [ ] 1.6 `just happen` and `just check` green.

## 2. Generated parameter dispatch

Independent of everything else here, and the highest-value single fix: it converts a silent no-op into
a build error.

- [ ] 2.1 `tests/test_param_descriptor.nim`: `every simulation-store descriptor id names a field of
      SimulationState` and `every render-store descriptor id names a field of RenderState`, walking
      the records with `fieldPairs`. Expected: passes immediately — it pins the relation the generated
      dispatch will depend on.
- [ ] 2.2 `src/web_api.nim:349-424`: replace the hand-written `case` with a compile-time walk over the
      routed state record's fields, assigning where the name matches and coercing to `int` for
      `pkInt` descriptors. Keep explicit arms for `paletteSaturation` and `paletteLightness` — they
      write editor state and call `applyPaletteToColors()`, which is not a field assignment.
- [ ] 2.3 Confirm the failure mode: temporarily add a descriptor whose id names no field, verify
      `just happen` fails at compile time, then remove it. Record what the error looks like in a
      comment above the generated dispatch, so the next person recognizes it.
- [ ] 2.4 `just happen` and `just check` green; every shipped parameter still writes the same field.

## 3. The probe registry and the sweep

The measurement gate. Task 3.4 is expected to fail for three named parameters — that failure is the
calibration signal, not a defect in the test.

- [ ] 3.1 `src/ui/api/response_probe.nim` (new, pure): the probe registry mapping probe ids to
      `proc(value: float): float`, the budget classes (`pbClosedForm` = 256 samples,
      `pbStepped` = 64), and the three metrics — span, live fraction, cliff — computed over track
      positions per design E2.
- [ ] 3.2 `src/ui/api/param_descriptor.nim`: add `probe: string` and `exemption: string` to
      `ParamDescriptor`, populated per design E1's assignment table. The three exemptions are
      `particleCount`, `speciesCount`, and `particleSize`, each with its written reason.
- [ ] 3.3 `tests/test_response_probe.nim` (new): `every descriptor is either probed or exempted`;
      `no descriptor is both`; `every probe id resolves to a registered function`; `every exemption
      states a reason`. These pin the coverage relation before any metric runs.
- [ ] 3.4 Same file: the sweep — for every probed descriptor, compute span, live fraction, and cliff
      at the provisional thresholds (`SPAN_MIN = 0.05`, `LIVE_FRACTION_MIN = 0.60`,
      `CLIFF_MAX = 0.25`, `RESPONSE_EPSILON = 1e-4`). Expected: `rdFeed`, `rdKill`, and `trailLength`
      fail; `friction`, `glowIntensity`, `exposure`, `contrast`, `sphViscosity` pass.
- [ ] 3.5 Emit the full measured table — every parameter's span, live fraction, cliff, and the
      interval where its response dies — into `docs/control-legibility-report.md` (new), beside the
      existing `docs/perf-report.md`. **This table is the deliverable of this group**; groups 4 and 5
      read it.
- [ ] 3.6 If any must-pass control fails or any must-fail control passes, the probe for it is wrong.
      Fix the probe. Design E3 forbids moving the threshold to resolve this.
- [ ] 3.7 `just happen` and `just check` green — with 3.4 red only for the three predicted parameters,
      quarantined behind an explicit expected-failure marker until group 5 clears them.

## 4. Travel curves

Built before the remedies that use them.

- [ ] 4.1 `tests/test_slider_curve.nim` (new): `position and value round-trip at the descriptor's
      precision`; `a linear curve reproduces the current position mapping exactly`; `position 0 and 1
      map to the range endpoints under every curve`; `a curve preserves monotonicity`.
- [ ] 4.2 `src/ui/api/slider_curve.nim` (new, pure): `valueAt(descriptor, position)` and
      `positionOf(descriptor, value)` for `cLinear`, `cLog`, and `cPower`.
- [ ] 4.3 `src/ui/api/param_descriptor.nim`: add `curve` and its exponent to `ParamDescriptor`,
      defaulting every parameter to `cLinear`. `src/config_ranges.nim`: the exponents as constants
      under static assertions rejecting a value that would invert or flatten the mapping.
- [ ] 4.4 `src/web_api.nim`: serve `curve` and the exponent in `descriptorToJs`; expose `valueAt` and
      `positionOf` through the boundary so the panel computes no mapping.
- [ ] 4.5 `web-ui/src/components/ParamSlider.tsx`: drive the range input by track position, converting
      through the boundary in both directions. The readout keeps showing the value, never the
      position.
- [ ] 4.6 `tests/test_param_descriptor.nim`: `every hint numeral and notch coordinate stays reachable
      under its parameter's curve` — extending the existing reachability test at line 83.
- [ ] 4.7 `just happen` and `just check` green; a `cLinear` parameter must behave identically to
      before this group.

## 5. Calibration and the remedy ladder

- [ ] 5.1 Read `docs/control-legibility-report.md` from task 3.5. Set `RESPONSE_EPSILON`, `SPAN_MIN`,
      `LIVE_FRACTION_MIN`, and `CLIFF_MAX` inside the gap between the must-pass and must-fail sets
      named in design E3. Record the measured distribution beside the constants. If no gap exists,
      return to 3.6.
- [ ] 5.2 Apply design E4's ladder to every failing parameter, in order: re-range, then curve, then
      re-step, then exempt. Record each change's before/after measurement beside the constant it
      touches, in the style `src/config_ranges.nim:90-97` already uses.
- [ ] 5.3 Expected remedies, to be confirmed rather than assumed: `trailLength` takes a curve, because
      geometric decay concentrates its effect at one end of the track. `rdFeed` and `rdKill` take a
      curve or a re-range against the `F >= 4(F+k)^2` boundary, which is where their live region
      begins. Whatever the report actually says wins over this prediction.
- [ ] 5.4 Remove the expected-failure quarantine from task 3.7. The sweep now runs as an ordinary
      assertion over the whole table.
- [ ] 5.5 Update `docs/control-legibility-report.md` with the post-remedy table beside the pre-remedy
      one.
- [ ] 5.6 `just happen` and `just check` green with no quarantined tests.

## 6. Acknowledgement, horizon, and dormancy

- [ ] 6.1 `src/ui/api/param_descriptor.nim`: add `horizon: rhInstant | rhSettling | rhStructural` per
      design E7, and `dormantWhen: string` naming a predicate per design E8. Every render-store
      parameter is `rhInstant`.
- [ ] 6.2 `tests/`: `every field parameter with a stepping oracle moves its observable within its
      declared horizon`; `every horizon without a stepping oracle is marked review-enforced`.
- [ ] 6.3 `src/web_api.nim`: serve `horizon` and `dormantWhen` in `descriptorToJs`; evaluate dormancy
      predicates against the existing pushed stats stream rather than adding a subscription.
- [ ] 6.4 `web-ui/src/components/ParamSlider.tsx`: a brief highlight on every input event, in the same
      tick and unconditionally; a settling indicator while a non-instant horizon has not elapsed; a
      dimmed dormant state showing the precondition line. A dormant control stays in place and stays
      movable.
- [ ] 6.5 `web-ui/src/ui.css`: the highlight, settling, and dormant styles. Keep the highlight short
      enough that a drag does not strobe.
- [ ] 6.6 `bun test`: the dormancy predicate evaluation and the horizon-elapsed timer, as pure
      functions.
- [ ] 6.7 `just happen` and `just check` green.

## 7. Spatial overlays

- [ ] 7.1 `web-ui/src/` and `src/web_api.nim`: a drag-active signal carrying the parameter id, crossing
      the boundary the same way parameter writes do.
- [ ] 7.2 `src/webgpu_render.nim`: draw the transient overlay at world scale while a spatial parameter
      is being dragged — `interactionRadius` as a ring at the cursor, the deposit splat radius as a
      disc, camera zoom as a frame. Clear on release.
- [ ] 7.3 The set stays closed to parameters that are literally a world distance (design E9). Do not
      extend it while implementing.
- [ ] 7.4 Verify in `./main`: dragging interaction radius shows a ring whose size tracks the slider,
      and it disappears on release.
- [ ] 7.5 `just happen` and `just check` green.

## 8. Help content pipeline

- [ ] 8.1 `docs/help/` (new): one file per descriptor group, plus `00-orientation.md` and
      `90-glossary.md`. Each file declares the group id it documents in its front matter. Stub content
      is acceptable in this group; group 10 writes the prose.
- [ ] 8.2 `src/ui/api/help_content.nim` (new): `staticRead` every file in `docs/help/` into a table
      keyed by group id, with the front-matter parse as a pure function.
- [ ] 8.3 `tests/test_help_content.nim` (new): the four coverage relations from design E10 — every
      group has a file; every declared group id exists; every descriptor is named by its group's file;
      no file names a non-existent id. Expected: fails until 8.1's stubs name every control.
- [ ] 8.4 `src/web_api.nim`: `gardenAPI.help()` serving the table.
- [ ] 8.5 `web-ui/src/components/HelpPanel.tsx` (new): the panel, opened by a control and by `?`,
      closed by `Escape`, rendering the restricted markdown subset from design E10.
- [ ] 8.6 `web-ui/src/lib/markdown.ts` (new) and its `bun test`: headings, paragraphs, lists,
      emphasis, code spans, internal links. Markup outside the subset renders as literal text.
- [ ] 8.7 Register `test_help_content` in `tests/test_all.nim` and `tests/README.md`.
- [ ] 8.8 `just happen` and `just check` green.

## 9. The binding table and the generated gesture reference

- [ ] 9.1 `src/ui/input/binding_table.nim` (new, pure): every mouse gesture, touch gesture, and key
      binding as data, each with a description. Include the bindings `src/canvas_input.nim` and
      `src/ui/input/` already implement.
- [ ] 9.2 `tests/test_input.nim`: `every binding carries a non-empty description`; `no two bindings
      claim the same key`.
- [ ] 9.3 `src/canvas_input.nim` and `src/ui/input/`: consume the table rather than declaring bindings
      inline, so the table is the single declaration.
- [ ] 9.4 `src/ui/api/help_content.nim`: render the binding table into the help reference section, so
      a binding cannot exist without appearing in help.
- [ ] 9.5 `just happen` and `just check` green.

## 10. Writing the help

The prose. Everything before this made a place for it that cannot go stale.

- [ ] 10.1 `docs/help/00-orientation.md`: what is on screen, what a pointer does, and one thing worth
      trying — before any control is named, and with no formula (design E10's requirement about
      readers with no background).
- [ ] 10.2 One file per group: what the group governs, what each control in it changes, and what to
      watch for when it changes. Every descriptor in the group must be named, or task 8.3 goes red.
- [ ] 10.3 `docs/help/90-glossary.md`: the named regimes, reactions, and force models, each with its
      cited source. Cite rather than assert — a coordinate from the literature is not the app's own
      claim.
- [ ] 10.4 Read the whole set as someone who has never seen the app. Anything requiring prior
      knowledge to parse gets rewritten, not annotated.
- [ ] 10.5 `just happen` and `just check` green.

## 11. Documentation and close

- [ ] 11.1 `CLAUDE.md`: add `docs/help/` as the feature-documentation source and the in-app help
      source, note the four coverage relations, and add `glow_core`, `trail_core`, `response_probe`,
      `slider_curve`, `help_content`, and `binding_table` to the module inventory. Note that the
      parameter dispatch is generated, so a descriptor id must name a state-record field.
- [ ] 11.2 `tests/README.md`: every new test module in the per-file table and the architecture tree.
- [ ] 11.3 `docs/control-legibility-report.md`: confirm it holds both the pre-remedy and post-remedy
      tables and names the calibration gap the thresholds sit in.
- [ ] 11.4 `openspec validate legible-controls`, then `openspec archive legible-controls`.
- [ ] 11.5 `just happen` and `just check` green.
