## How to read this list

Ids are stable and never renumbered. Every group ends with `just happen` and `just check` green;
a group whose gate stays red is not done. Group 3 is the one exception, since the descriptor it adds
is unreachable until group 4 places it in the panel, so the two groups close as one. Groups run in
order: group 1 builds the motion the rest of the change wires up.

Reds named as "expected red" are the failing tests that must be watched failing before the code
that closes them is written. A commit waits for the suite to be green, whatever the group boundary.

---

## 1. The motion, natively tested

**Tests that must fail first.** `tests/test_camera_drift.nim` does not exist. Write it against a
`src/camera_drift.nim` that does not exist either, and watch `just test` fail to compile before
writing the module.

- [x] 1.1 Write `tests/test_camera_drift.nim`, covering the six properties the spec names: the
  named speed delivers that travel over sixty simulated seconds at two different frame rates; a
  zero-second advance changes nothing; the shipped heading slope admits no rational approximation
  within the tested denominator bound, and the smallest closure error found is recorded in a
  checkpoint; the band the zoom clamp produces contains its anchor and lies inside
  `[CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX]` for anchors swept across the whole range; the breath
  evaluated at the phase recovered from an anchor returns that anchor within float tolerance; and a
  sweep at `CAMERA_DRIFT_SPEED_MAX` in 1/60 second steps across a full breath, for every band the
  clamp produces, exceeds neither `CAMERA_DRIFT_MAX_PAN_STEP` nor `CAMERA_DRIFT_MAX_ZOOM_STEP`.
  Files: `tests/test_camera_drift.nim`. Verify: `nim c -r tests/test_camera_drift.nim` fails to
  compile on the missing module.
- [x] 1.2 Add `CAMERA_DRIFT_SPEED_MIN`, `CAMERA_DRIFT_SPEED_MAX` and
  `CAMERA_DRIFT_SPEED_NOTCH_SCREEN` to `src/config_ranges.nim` with the conditions from design.md
  D9 written beside each, and extend the static block at `:419` with non-emptiness, the notch inside
  the range, and `CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR >= CAMERA_ZOOM_MIN`. Files:
  `src/config_ranges.nim`. Verify: `nim c -r tests/test_camera_core.nim` still compiles, which
  exercises the static block.
- [x] 1.3 Write `src/camera_drift.nim`: the remaining constants from design.md D9, the `DriftState`
  record, the per-frame advance taking elapsed seconds and returning a new state and camera, the
  band derivation, the raised-cosine breath and its closed-form inverse, and the touch clock. Pure,
  importing only `std/math`, `camera_core` and `config_ranges`, with every exported function a
  `func`, since `src/ui/api/response_probe.nim` calls one of them under `noSideEffect`. Files:
  `src/camera_drift.nim`. Verify: task 1.1's suite passes.
- [x] 1.4 Register the suite: add `import test_camera_drift` and the matching
  `discard test_camera_drift.CAMERA_DRIFT_TESTS_LOADED` line to `tests/test_all.nim`. Files:
  `tests/test_all.nim`. Verify: `just test` runs the new suite, visible in its output.

Gate: `just happen` and `just check` green.

## 2. The state record, the CONFIG mirror, and the preset

**Tests that must fail first.** Add the `PresetSettings` keys before the `RenderState` fields.
`tests/test_preset.nim:96-99` then reports `preset key "cameraDrift" names no field of either state
record`. That is the expected red, and it is what proves the walk covers the new keys.

- [x] 2.1 Add `cameraDrift: bool` and `cameraDriftSpeed: float` to `PresetSettings` in
  `src/preset.nim`, with `defaultSettings()` carrying `false` and `CAMERA_DRIFT_DEFAULT_SPEED`, plus
  their `parsePreset` reads and their JSON writes. Files: `src/preset.nim`. Verify: `just test` red
  at `tests/test_preset.nim` with the "names no field" checkpoint.
- [x] 2.2 Add `cameraDrift: bool` and `cameraDriftSpeed: float` to `RenderState` in
  `src/ui/state/render_state.nim`, with `initRenderState()` carrying `false` and
  `CAMERA_DRIFT_DEFAULT_SPEED`. Files: `src/ui/state/render_state.nim`. Verify: task 2.1's red
  clears; `just happen` now red at `nim js` with the mirror-gate message from `src/web_api.nim:100`,
  which is the next expected red.
- [x] 2.3 Add the two matching `ConfigObject` fields and their `createConfig` copies. Files:
  `src/config.nim`. Verify: the mirror-gate red from 2.2 clears and `just happen` completes.
- [x] 2.4 Snapshot and restore the two fields in the preset path: the `settings.` assignments beside
  `src/web_api.nim:916` and the restore beside `:1018`. Files: `src/web_api.nim`. Verify: a preset
  round trip in `tests/test_preset.nim` carries both values, and add the assertion if no existing
  case covers a render-store boolean.

Gate: `just happen` and `just check` green.

## 3. The control contract

**Tests that must fail first.** Add the descriptor before anything that serves it. `just test` then
goes red three ways at once: `tests/test_response_probe.nim:42` for a descriptor with neither probe
nor exemption, `tests/test_help_content.nim` for a descriptor its group's file does not name, and
`tests/test_panel_reachability.nim` for a descriptor the panel never places. Watch all three, then
close them one at a time.

- [x] 3.1 Add the `cameraDriftSpeed` descriptor to `buildParamDescriptors()` with every field from
  design.md D7. Files: `src/ui/api/param_descriptor.nim`. Verify: the three expected reds above,
  each naming `cameraDriftSpeed`.
- [x] 3.2 Add the `camera.driftFrameTravel` probe and its `probeRegistry()` entry at
  `pbClosedForm`, calling the pan-step function from `src/camera_drift.nim` at
  `FRAME_DT_REFERENCE`. Files: `src/ui/api/response_probe.nim`. Verify: the
  `tests/test_response_probe.nim` red clears, and the track-metric sweep reports span, live fraction
  and cliff inside `SPAN_MIN`, `LIVE_FRACTION_MIN` and `CLIFF_MAX`.
- [x] 3.3 Add the `cameraDriftOff` predicate to `dormancyRegistry()`, reading
  `renderFields: @["cameraDrift"]`, with the line `the camera holds still`. Files:
  `src/ui/api/dormancy.nim`. Verify: `tests/test_dormancy.nim` resolves the carried id and finds the
  field it names.
- [x] 3.4 Add the control line and the behaviour prose to `docs/help/60-camera.md`: a
  `` - `cameraDriftSpeed` — … `` list line naming the unit, plus prose covering the Drift toggle,
  that a camera-moving gesture pauses the drift and it resumes shortly after, that it resumes from
  where the gesture left the view, and that a preset carries the motion but never the position.
  Files: `docs/help/60-camera.md`. Verify: the `tests/test_help_content.nim` red clears in both
  directions.

Gate: `just happen` green, and `tests/test_panel_reachability.nim` red on `cameraDriftSpeed` until
group 4 places the control. That red is the expected red group 4 closes, so groups 3 and 4 close
together: the commit carrying either one waits until 4.6 places the control and `just check` is
green over both.

## 4. The frame loop, the boundary, and the panel

**Tests that must fail first.** Extend `tests/test_camera_drift.nim` with the source-reading
assertion first: read `src/canvas_input.nim` and `src/web_api.nim` from disk, assert each file was
found and non-empty on the pattern `tests/test_panel_reachability.nim:44-47` uses, and assert that
every camera write in them goes through the stamping wrapper and not through `cameraSetter`
directly. It fails on the wrapper not existing.

- [x] 4.1 Add the source-reading assertion described above to `tests/test_camera_drift.nim`. Files:
  `tests/test_camera_drift.nim`. Verify: red, naming the absent wrapper.
- [x] 4.2 Add the touch stamp and the stamping wrapper to `src/canvas_input.nim` beside the camera
  hooks at `:40-46`, and route the five existing user-facing camera writes through it: the pan drag
  at `:175`, the wheel zoom at `:245`, the wheel pan at `:249`, and the key handler at `:280`. Leave
  `cameraSetter` itself as the unstamped path, which is what the drift uses. Files:
  `src/canvas_input.nim`. Verify: task 4.1's assertion passes.
- [x] 4.3 Route the Zoom slider's camera write through the same wrapper: the `psCamera` arm at
  `src/web_api.nim:614-632`. Files: `src/web_api.nim`. Verify: task 4.1's assertion covers this file
  and passes.
- [x] 4.4 Add `getCameraDrift` and `setCameraDrift` to the served object beside the existing toggle
  pairs, with a `setCameraDriftImpl` beside `setClimateDriftImpl` at `src/web_api.nim:385` writing
  through `updateRender`. Files: `src/web_api.nim`. Verify: `just happen` builds, and the panel
  task below consumes them.
- [x] 4.5 Advance the drift in the frame loop beside the two weathers at `src/app.nim:257-269`, on
  `cappedDt`, before `await physics(dt)`, gated on `config.CONFIG.cameraDrift`, reading and writing
  the camera through `webgpu_render.camera` / `setCamera`. Hold the `DriftState` as a module-level
  var beside `climatePhase` and `forceWeatherPhase`. Files: `src/app.nim`. Verify: `just happen`
  builds and the app launches.
- [x] 4.6 Place the two controls in the panel: a Drift checkbox and
  `<ParamSlider ctrl={props.ctrl} id="cameraDriftSpeed" />` inside `CameraSection`
  (`web-ui/src/components/Panel.tsx:30-38`), and a `cameraDrift` signal beside `climateDrift` in
  `web-ui/src/state.ts:36-38` with its setter in the returned controller. Files:
  `web-ui/src/components/Panel.tsx`, `web-ui/src/state.ts`. Verify: group 3's remaining
  `tests/test_panel_reachability.nim` red clears.

Gate: `just happen` and `just check` green, with no reds carried forward from group 3.
