# Camera drift: the view moves itself while nobody touches it

## Why

The camera can be moved and never moves on its own. Two things in this world already
advance themselves on wall-clock seconds while the app runs unattended: the reaction-diffusion
climate and the force weather, both stepped from `src/app.nim:257-269`. The view they are
watched through holds still until a hand arrives.

An unattended piece needs the view to be part of what plays. Everything the camera needs is
already built and tested: `src/camera_core.nim` wraps a pan across the seam and rewraps the
centre (`panned`, `wrappedCenter`), the render path draws each particle at its nearest toroidal
image (`nearestImageDelta`), the fade pass reprojects the trail between the live and previous
camera (`src/webgpu_render.nim:588`, `:63-73`), and the zoom range runs from the whole world to
creature scale (`src/config_ranges.nim:320-329`). Nothing in `src/` or `web-ui/src/` names a
camera drift.

## What Changes

- A **Drift** toggle and a **Drift Speed** slider join the Camera section. Off by default,
  matching every other self-moving behaviour in this world (`src/ui/state/simulation_state.nim:123-125`
  ships `climateDrift: false` and `forceWeather: false`).
- While drift runs, the camera **pans** along one fixed heading over the torus at a speed
  measured in view widths per minute, crossing the seam wherever the path meets it, and
  **breathes** its zoom through a factor-of-two band around wherever the user last left it.
- Any camera-moving input **yields** the drift: the middle-button drag, the wheel pan, the
  wheel or pinch zoom, the arrow and `+` / `-` / `0` keys, and the Zoom slider each stamp the
  camera as touched, and the drift stays still until a quiet interval has passed. It resumes
  from the camera the user left, never from a remembered position of its own.
- New pure module `src/camera_drift.nim` holds the motion, natively tested at
  `tests/test_camera_drift.nim`, on the terms every other `*_core` module is tested on.
- `src/config_ranges.nim` gains the drift-speed bounds under the existing static assertion
  block at `:419`.
- `docs/help/60-camera.md` gains the control line and the yield-and-resume behaviour, which
  the four coverage relations in `tests/test_help_content.nim` require before the control can
  ship.

No behaviour is removed. With the toggle off, every camera path behaves exactly as it does now.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `camera-navigation`: adds the self-moving view. Who may write the camera and what happens
  when two writers want it at once becomes a stated requirement, where today the camera has
  exactly one class of writer and the question does not arise.

## Impact

**Nim, simulation side**

- `src/camera_drift.nim` (new): the pan flow, the zoom breath, the touch clock.
- `src/config_ranges.nim`: `CAMERA_DRIFT_SPEED_MIN` / `_MAX` plus their static assertions.
- `src/ui/state/render_state.nim`: `cameraDrift: bool`, `cameraDriftSpeed: float`, and their
  defaults.
- `src/config.nim`: the two matching `ConfigObject` fields and their `createConfig` copies.
  The mirror gate at `src/web_api.nim:100-128` fails the `nim js` build without them.
- `src/preset.nim`: the two `PresetSettings` fields, their defaults, their read and their write.
  `tests/test_preset.nim:59-101` holds every preset default to the state field that owns it.
- `src/app.nim`: the drift advance beside the two weathers at `:257-269`.
- `src/canvas_input.nim`: the touched stamp, set by one wrapper every user-facing camera writer
  goes through.
- `src/web_api.nim`: `getCameraDrift` / `setCameraDrift` beside the existing toggle pairs at
  `:1190-1196`, and the `psCamera` arm at `:614-632` routed through the stamping wrapper.

**Nim, control contract**

- `src/ui/api/param_descriptor.nim`: the `cameraDriftSpeed` descriptor in the `camera` group.
- `src/ui/api/response_probe.nim`: the `camera.driftFrameTravel` probe and its registry entry.
  `tests/test_response_probe.nim:72-83` pins the exempt set to exactly three ids, so the new
  control cannot take an exemption.
- `src/ui/api/dormancy.nim`: the `cameraDriftOff` predicate.

**Panel**

- `web-ui/src/components/Panel.tsx`: the toggle and the slider inside `CameraSection` (`:30-38`).
- `web-ui/src/state.ts`: the `cameraDrift` signal beside `climateDrift` (`:36-38`).

**Docs**

- `docs/help/60-camera.md`.

**Untouched**: every WGSL shader, `src/webgpu_render.nim`'s pipelines and bind groups, and
`src/ui/input/binding_table.nim`. The drift moves the camera through the same `camera_core`
movers the input handlers already use, so nothing downstream of the camera learns a new fact.
