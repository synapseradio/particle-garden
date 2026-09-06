## Context

See proposal.md for motivation.

Three facts about the existing camera shape everything below.

**The camera has two authors already.** `src/canvas_input.nim:40-46` holds a getter and a setter
that `src/app.nim:379-380` wires to `webgpu_render.camera` / `setCamera`, and both the input
handlers and `web_api`'s `psCamera` arm write through that one pair (`src/web_api.nim:614-632`,
whose comment states the reason: "one wiring point means the slider and the wheel cannot end up
pointed at different cameras"). A drift is a third writer on the same value.

**The pan gesture carries a guarantee.** `src/ui/input/pan_handler.nim`'s `grabPanned` "holds the
grabbed point under the pointer for the whole drag: the centre moves by precisely the world offset
the pointer's travel names, so the two cancel." Anything that also moves the centre during a drag
breaks that cancellation.

**The camera is view state and stays out of the world.** `src/ui/api/param_descriptor.nim:53-62`
keeps `psCamera` out of `CONFIG` and out of the preset schema, because "a preset restores a world,
and should not also seize where the user is standing to look at it."

The existing self-moving machinery is `src/climate_core.nim:40-78`: `smoothstep`, `tourAt`,
`tourPhaseStep`, `tourAdvance`, walking a closed waypoint table indexed by a per-weather axis enum.
Two callers exist, the reaction-diffusion climate and the force weather, and its guarantees are
swept natively at `tests/test_climate_core.nim:178-256`.

## Goals / Non-Goals

**Goals**

- A view that moves itself, continuously, without repeating, for as long as the app runs.
- One toggle and one speed, both answering to the same contract every other control answers to.
- Zero effect on any camera path while the toggle is off.
- The panel keeps telling the truth about the camera while the drift moves it.

**Non-Goals**

- Automatic framing. The drift never decides that some part of the world deserves the view.
  Nothing here reads particle positions, field density, or any world signal.
- A second drift over anything the camera does not own. Feed, kill and the three force parameters
  already have their weathers.
- New bindings. No key, gesture or wheel behaviour is added or changed.
- Presets restoring a camera position. That prohibition stands untouched.

## Decisions

### D1. The drift is a flow integrated from the live camera, not a path the camera is placed on

Each frame the drift reads the camera it finds, adds a displacement proportional to elapsed
wall-clock seconds, and writes the result back through the same `camera_core` movers the input
handlers use. It holds no position of its own and no absolute path.

**Why.** `tourAt(table, phase)` answers with an absolute point for a phase, so a frame loop driving
the camera from it would overwrite whatever the camera holds. For feed and kill that is correct
behaviour and nobody minds: the weather owns those sliders while it runs, and a slider snapping back
under a drag reads as the weather winning. The camera is different, because `grabPanned`'s
guarantee is that the grabbed world point stays under the pointer, and a writer that reasserts an
absolute centre next frame undoes exactly the offset the drag applied. Integrating instead makes
every interaction with the user free of arithmetic: whatever the camera holds at the moment the
drift takes over is where the drift continues from.

**Rejected: a third waypoint table on `climate_core`'s tour**, over `(centerX, centerY, zoom)`.
Three reasons, in the order they bite.

1. The absolute-position problem above. Every resume after a user gesture would snap the view.
2. A waypoint table lives in world coordinates and interpolates linearly between neighbours, so it
   takes the long way round instead of crossing the seam. The seam crossing is the property
   `camera_core.nearestImageDelta` was built to make invisible, and a drift that never uses it
   leaves the one behaviour the toroidal camera exists for untouched.
3. A closed tour repeats. `tests/test_climate_core.nim:218-231` records why that is right for the
   climate: "most of the feed/kill rectangle produces nothing worth looking at, so a drift that
   wandered the box would spend most of its time in dead parameter space. Landing exactly on each
   regime is what makes the weather worth watching." The camera's space has no dead parts. Under
   toroidal wrapping every centre is equivalent to every other, so there is nothing for waypoints
   to name and nothing for the tour to be worth. A piece running unattended for hours gets a fixed
   loop out of the table and a path that never repeats out of the flow.

The tour stays at two callers. A third caller would have tested whether its arity generalises, and
the property that decides this design is not arity. It is that the tour writes positions and the
camera needs increments.

### D2. A camera-moving input yields the drift, which resumes from where the user left it

Every user-facing camera writer passes through one wrapper that stamps the camera as touched. The
drift advances only after `CAMERA_DRIFT_RESUME_SECONDS` of wall-clock quiet. While the stamp is
fresh the drift still runs its own bookkeeping each frame, re-reading the live camera, so the moment
it resumes there is nothing to reconcile.

**Why this over the alternatives.**

- *Keep drifting through the gesture.* Rejected: it breaks `grabPanned`'s cancellation, which a
  user notices inside one drag.
- *Switch the toggle off on touch.* Rejected: an unattended piece that a passer-by nudges would stay
  dead until someone found the panel and switched it back on. The toggle also becomes a control that
  changes state without anybody touching it, which is the defect the drift is otherwise careful to
  avoid.
- *Resume by returning to a remembered view.* Rejected: it discards the framing the user chose and
  contradicts D1's whole mechanism.

**The resume interval is provisional at twelve seconds**, and the measurement that fixes it is named
in tasks.md group 5: drive a pan gesture with a deliberate pause in the middle and observe whether
the drift interrupts it, then leave the app alone and observe when motion returns. If a gesture with
a thinking pause gets interrupted, the interval is too short. If a room left alone stays still long
enough to read as broken, it is too long.

### D3. Panning is a linear flow at constant screen speed on a fixed heading

World velocity is `(worldWidth / zoom, worldHeight / zoom * slope)` normalised and scaled by
`speed / 60` view widths per second, applied through `camera_core.panned`, which rewraps the centre
and so maintains the precondition the nearest-image maths depends on
(`src/camera_core.nim:54-58`).

**Speed is measured in view widths per minute.** The division by zoom is what makes that unit hold,
and the codebase already argues for it twice: `pan_handler.pixelPanDelta` divides by zoom because
"what a user judges is how far the picture moved under their fingers, never how far the centre moved
through the world", and `key_handler.KEY_PAN_FRACTION` is a fraction of the visible span because "at
the zoom ceiling a fixed step would throw the view most of the way across the screen, and at the
floor it would crawl." A drift whose zoom breathes needs this or the apparent speed would halve
every time the view came in.

**The path never closes.** For a linear flow on the torus the orbit is periodic exactly when the
ratio of the two normalised rates is rational. Because velocity is expressed in view widths and
heights before conversion to world units, that ratio is the heading slope alone, independent of the
world's aspect and independent of zoom. The shipped slope is the golden ratio conjugate,
0.6180339887, which is the worst-approximable irrational, so the orbit's shortest closure is as long
as any slope can make it. The claim tested natively is closure, not novelty: the view does revisit
neighbourhoods it has seen, and it never retraces a path.

**Rejected: a heading that turns.** A slowly rotating heading traces an epitrochoid, which closes
whenever the turn rate and the travel rate are commensurate and needs a second incommensurate
constant to avoid it. It buys curvature and costs a constant and a proof.

### D4. Zoom breathes through a factor-of-two band anchored on the live zoom

The band is derived from the zoom the drift finds, never from a fixed pair of endpoints:

```
bandLow  = clamp(zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR)
bandHigh = bandLow * CAMERA_DRIFT_ZOOM_FACTOR
```

`CAMERA_ZOOM_MAX / CAMERA_DRIFT_ZOOM_FACTOR` is 4.0 against a floor of 1.0, so the clamp is
non-empty and the live zoom always lies inside the band it produces. Inside the band the breath runs
in log space, which is the space zoom lives in
(`src/ui/api/param_descriptor.nim:90-91` records that zoom is multiplicative):

```
zoomAt(phase) = bandLow * FACTOR ^ ((1 - cos(2*PI*phase)) / 2)
```

A raised cosine has zero derivative at both turning points, which is the same property `smoothstep`
buys the tour and for the same reason: `src/climate_core.nim:22-26` states that linear interpolation
"would visibly corner at every waypoint." Its inverse over the first half cycle is
`arccos(1 - 2u) / (2*PI)` with `u = ln(zoom / bandLow) / ln(FACTOR)`, closed form and total on
`u` in `[0, 1]`, which is what lets the drift re-seed its phase from the live zoom on every quiet
frame and never snap.

The breath advances on distance travelled, not on its own clock: one full breath per
`1 / CAMERA_DRIFT_BREATHS_PER_WIDTH` view widths of pan. One speed slider therefore governs both
motions, and the two stay in a fixed relation the user can learn.

**Why breathe the zoom at all, when a pan alone would be smaller.** Three things it buys.
The piece moves toward and away from what it is looking at, which a slide across a homogeneous
torus does not. The Zoom slider is the one camera control the panel carries, and `CameraSection`
already re-reads it four times a second (`web-ui/src/components/Panel.tsx:28-38`), so a breathing
zoom keeps the panel truthful with no new sync machinery, the same standard `src/app.nim:249-252`
holds the weathers to. And `gardenAPI.getParam("cameraZoom")` reads the live camera
(`src/web_api.nim:450-454`), which gives an agent a numeric observation that the camera moved on its
own, through surface that already exists.

**Rejected: breathing between two fixed zoom endpoints.** A user who zooms to creature scale and
walks away would be dragged back to the fixed band, either by a snap or by an extra return state.
Anchoring on the live zoom deletes the case instead of handling it, and it makes the drift a
modifier of the user's framing instead of an owner of it.

### D5. `cameraDrift` and `cameraDriftSpeed` live in `RenderState` and travel in presets

Both fields join `src/ui/state/render_state.nim`, route `psRender`, mirror into `ConfigObject`, and
appear in `PresetSettings`.

**Why `RenderState`.** The generated dispatch handles a `psRender` id with no hand-written arm
(`src/web_api.nim:602-604` assigns by field name, and the static gate at `:560-566` proves every
routed id lands), `getParam` reads it from `CONFIG` with no `ReadElsewhere` exception
(`src/web_api.nim:414-419`), and the dormancy registry can read it, since predicates declare
`renderFields` and nothing else reaches the camera
(`src/ui/api/dormancy.nim:17-19`). Routing it `psCamera` would mean a second hand-written arm past
the gate at `src/web_api.nim:575-579`, module-level state in `webgpu_render` with a new hook pair to
reach it, and a dormancy predicate with nothing to read. Precedent for a loop-read value in a state
record already exists: `climateSpeed` and `forceWeatherSpeed` sit in `SimulationState` and are read
by `src/app.nim:257-269`, not by any shader.

**Why presets carry them.** The prohibition at `src/ui/api/param_descriptor.nim:53-62` is about
where the user is standing. A preset that restores `cameraDrift` does not move the camera one pixel
on load, and the drift continues from wherever the view already sits. Whether the piece moves its own
view belongs to the piece, and a saved piece that loses its motion on reload has lost part of itself.
`tests/test_preset.nim:59-101` walks `PresetSettings` against both state records by `fieldPairs`, so
the two new fields have to agree with their `RenderState` defaults or the suite goes red.

### D6. Off by default

`initRenderState()` ships `cameraDrift: false`. Two grounds, one aesthetic and one enforced.

`src/ui/state/simulation_state.nim:123-125` ships both existing weathers off, so every self-moving
behaviour in this world starts still and a third that started moving would be the odd one.

More strictly: `tests/test_camera_core.nim:20-32` pins that the default camera reduces exactly to
the pre-camera clip mapping, with the reason stated in the test, "drift silently reframes every
preset/screenshot." A drift running at startup would leave that framing on the second frame of
every launch.

### D7. The control contract

`cameraDriftSpeed` joins the descriptor table in the `camera` group, beside `cameraZoom`:

| field | value | why |
|---|---|---|
| `id` | `cameraDriftSpeed` | names a `RenderState` field, which `tests/test_param_descriptor.nim` requires of every routed id |
| `label` | `Drift Speed` | `Drift` alone is `climateSpeed`'s label in the `rd` group |
| `group` | `camera` | `CameraSection` places it by id |
| `kind`, `precision`, `step` | `pkFloat`, 2, 0.01 | the `climateSpeed` and `forceWeatherSpeed` precision |
| `minValue`, `maxValue` | `CAMERA_DRIFT_SPEED_MIN`, `CAMERA_DRIFT_SPEED_MAX` | from the range authority |
| `defaultValue` | `initRenderState().cameraDriftSpeed` | the default authority |
| `store` | `psRender` | D5 |
| `hint` | `view widths the camera travels per minute, while Drift is on` | names no numeral, so `tests/test_param_descriptor.nim:128` has nothing to check for reachability |
| `notches` | `default` spliced at position 0 by `withDefaultNotch`, then `a screen a minute` at `CAMERA_DRIFT_SPEED_NOTCH_SCREEN` = 1.0 | 1.0 is the unit's definition, the same kind of claim `CAMERA_ZOOM_NOTCH_WORLD` carries |
| `curve` | `cLinear` | `cLog` needs a measured remedy, per the module's own note at `:80-91`. The floor is above zero, so switching later needs no range change |
| `probe` | `camera.driftFrameTravel` | D8 |
| `horizon`, `horizonReview` | `rhInstant`, `false` | the field declares when the world answers, and `src/camera_drift.nim:65-69` scales the next frame's travel by the new speed with nothing smoothing it. `tests/test_dormancy.nim:188-191` holds every `psRender` id to `rhInstant`, and D5 routes this one there. The second or so a viewer needs to read the new rate is not what the field measures (`src/ui/api/param_descriptor.nim:97-102`) |
| `dormantWhen` | `cameraDriftOff` | D8 |
| `bound` | `bConstant` | no ceiling derives from another parameter |
| `arity` | `paScalar` | one camera |

The toggle is not a descriptor. `trails`, `bloomEnabled`, `climateDrift` and `forceWeather` are all
outside the table and reach the panel through `getX` / `setX` pairs on `gardenAPI`
(`src/web_api.nim:1190-1196`), and `cameraDrift` follows them.

`render_state.withTrails` exists because a toggle that switches on a pass which retains nothing is a
control that visibly does nothing. Camera drift has no such trap: `CAMERA_DRIFT_SPEED_MIN` is above
zero, so switching the toggle on always moves the camera. That is why no `withCameraDrift` helper
appears here.

### D8. The probe and the dormancy predicate

**Probe `camera.driftFrameTravel`**: `driftPanStep(value, FRAME_DT_REFERENCE)`, the view widths the
camera travels in one reference frame. Drawn from the new module the same way `climateSpeedProbe`
draws `tourPhaseStep` from `climate_core` (`src/ui/api/response_probe.nim:430-433`). Zoom
independent by construction, so it needs no context slice. Budget `pbClosedForm`. It is linear in
the parameter, so the three track metrics clear their thresholds with room: span is the whole track
against `SPAN_MIN` 0.15, live fraction is 1.0 against `LIVE_FRACTION_MIN` 0.70, and the cliff is one
sample step against `CLIFF_MAX` 0.25.

An exemption is not available: `tests/test_response_probe.nim:72-83` pins the exempt set to exactly
`particleCount`, `speciesCount`, `sphSubsteps`, and a fourth is a decision that test forces into the
open.

**Predicate `cameraDriftOff`**: reads `renderFields: @["cameraDrift"]`, line `the camera holds
still`, true when the toggle is off. The registry's own rule decides this. It says "a strength's own
control declares none: the slider at zero is the way back", and `CAMERA_DRIFT_SPEED_MIN` sits above
zero for the reason `CLIMATE_SPEED_MIN` records, that "a speed slider that can also stop the drift
would give the same state two controls". The slider at zero is therefore not the way back, the
toggle is, and the general rule applies: name the missing precondition.

**A known inconsistency, left alone.** `climateSpeed` and `forceWeatherSpeed` carry no dormancy
predicate for their own toggles (`src/ui/api/param_descriptor.nim:658-673`), which by the rule above
looks like a gap. Closing it would edit two controls this change does not touch. It is recorded here
and left for whoever decides that scope.

### D9. The constants and the conditions that produced them

Two go to the range authority, under the static assertion block at `src/config_ranges.nim:419`. The
rest live beside the drift maths, the way `KEY_ZOOM_STEP` and `KEY_PAN_FRACTION` live in
`key_handler.nim`.

The window `src/main.nim:97` opens is 1400 by 900, which is what turns a view-width speed into
pixels: `px/s = 1400 * speed / 60`.

| constant | value | condition |
|---|---|---|
| `CAMERA_DRIFT_SPEED_MIN` | 0.05 | One view width every twenty minutes, about 70 px a minute in that window. Motion you find by leaving the room and coming back, never by watching. Not zero, for `CLIMATE_SPEED_MIN`'s reason: the toggle is what stops the drift |
| `CAMERA_DRIFT_SPEED_MAX` | 4.0 | One view width every fifteen seconds, about 93 px a second. **Bounded by legibility, and it says so.** The mechanical ceiling is far above: the fade pass reprojects the trail between consecutive cameras (`src/webgpu_render.nim:63-73`), and that only breaks down where consecutive frames stop overlapping, near 36 view widths a minute. Tasks group 5 names the agent observation that confirms 4.0 still reads as drift and not as a pan somebody is performing |
| `CAMERA_DRIFT_DEFAULT_SPEED` | 0.25 | One view width every four minutes. `CLIMATE_DEFAULT_SPEED` carries the same number for the same reason: slow enough to read as weather and not as something malfunctioning |
| `CAMERA_DRIFT_SPEED_NOTCH_SCREEN` | 1.0 | One view width a minute, which is the unit's definition. A literal, not an alias of a bound, on `CAMERA_ZOOM_NOTCH_WORLD`'s reasoning |
| `CAMERA_DRIFT_HEADING_SLOPE` | 0.6180339887 | The golden ratio conjugate, the worst-approximable irrational, so the orbit's shortest closure is the longest any slope offers |
| `CAMERA_DRIFT_ZOOM_FACTOR` | 2.0 | The breath swings the apparent scale by a factor of two, which is the smallest swing that reads as approach and retreat instead of a wobble. At the shipped particle size 3 and `DENSITY_SIZE_FLOOR` 0.7 it lifts a density-floored particle from 1.4 px of on-screen radius to 2.8 px (`camera_core.visibleRadiusPx`). It stays well below the `creature` notch at 8.0, where the view holds too few particles for a wander to be legible. `CAMERA_ZOOM_MAX / 2.0` is 4.0, above `CAMERA_ZOOM_MIN`, which is what makes D4's band clamp non-empty |
| `CAMERA_DRIFT_BREATHS_PER_WIDTH` | 0.5 | One full breath every two view widths travelled: eight minutes at the default speed, thirty seconds at the ceiling |
| `CAMERA_DRIFT_RESUME_SECONDS` | 12.0 | Provisional. D2 names the observation that fixes it |
| `CAMERA_DRIFT_MAX_PAN_STEP` | 0.002 | The largest fraction of a view width one advance may move, at `CAMERA_DRIFT_SPEED_MAX` and a 1/60 s frame. The path reaches 0.00111 there. A ceiling the sweep holds the path to, on `CLIMATE_MAX_STEP`'s terms: raising the speed ceiling past what the flow can carry goes red in the sweep instead of making the view jump |
| `CAMERA_DRIFT_MAX_ZOOM_STEP` | 0.01 | The largest zoom change one advance may make, over every band the clamp produces, at the speed ceiling and a 1/60 s frame. The widest band is `[4, 8]`, where the per-frame phase step is 0.000556. The figure calculated here was 0.0069 from a peak `d(zoom)/d(phase)` of 12.3; the sweep in `tests/test_camera_drift.nim` measures the worst step at **0.00724**, the peak sitting nearer 13. The ceiling carries the measured number |

`CAMERA_DRIFT_SPEED_MIN < CAMERA_DRIFT_SPEED_MAX`, the default inside the range, and the notch
inside the range, all assert statically beside the existing camera zoom assertions at
`src/config_ranges.nim:529-534`.

### D10. Where the advance runs in the frame

Beside the two weathers in `src/app.nim:257-269`, before `await physics(dt)`, and on `cappedDt`
rather than the timeScale-scaled `dt`, for the reason stated there: a minute should mean a minute
however fast the simulation happens to be running.

Before physics, because `src/app.nim:196-211` reads the live camera to map the cursor into the world
and to shrink the mouse influence radius by zoom. Advancing after physics would leave both reading a
camera one frame stale, which shows as the pull landing slightly behind the cursor while the drift
runs.

## Proven properties

Each of these already holds, with the evidence that holds it.

- **A pan wraps and does not accumulate error.** `camera_core.panned` rewraps through
  `wrappedCenter`, which is written for arbitrary displacement, and panning by exactly one world
  width returns an identical camera value (`src/camera_core.nim:161-187`,
  `tests/test_camera_core.nim`).
- **The seam is invisible under any centre.** `nearestImageDelta` picks the nearest toroidal image,
  and the precondition it needs, a centre inside one world span, is what `panned` maintains.
- **The trail survives a moving camera.** The fade pass binds the live and previous cameras and
  reprojects between them (`src/webgpu_render.nim:63-73`, `:588`). Every existing pan gesture
  already exercises it.
- **The zoom readout follows the live camera.** `getParam("cameraZoom")` reads the camera, not
  `CONFIG` (`src/web_api.nim:450-454`), and the panel polls it every 250 ms
  (`web-ui/src/components/Panel.tsx:28-38`).
- **A raised cosine has zero derivative at its turning points.** Elementary, and the same property
  `smoothstep` supplies the tour.

## Designed but unexercised

- **The flow itself.** No line of the pan flow or the zoom breath exists. Group 2 of tasks.md builds
  it test-first, and the four properties it must carry are D3's non-closure, D4's exact re-seed,
  and the two per-frame ceilings in D9.
- **Twelve seconds as the resume interval.** Reasoned, not measured. D2 names the measurement.
- **4.0 view widths a minute as the speed ceiling.** Bounded by legibility, and no measurement of
  legibility exists. D9 names what would move it and records the mechanical ceiling that does not
  bind here.
- **That a drifting camera leaves the trail intact.** Every pan gesture exercises the reprojection,
  and none of them runs for hours at a constant rate across the seam. Group 5 observes it.

## Risks / Trade-offs

- **The drift writes the camera every frame while it runs, and the Zoom slider follows it four times
  a second.** A user reaching for the slider finds a handle that moves. → The touch stamp covers it:
  the slider write goes through the same stamping wrapper, so the first drag on the handle yields
  the drift and the handle holds still for the rest of the interaction.
- **The touch stamp is a discipline, not a type.** A future camera writer that calls the setter
  directly gets no stamp and fights the drift. → Two mitigations. The drift takes the plain setter
  and every user path takes the stamping wrapper, so the split is visible at each call site. A
  native test asserts the wrapper's call sites cover the handler set, on the source-reading pattern
  `tests/test_panel_reachability.nim` and `tests/test_no_modes.nim` already use.
- **A drifting camera moves the previous-frame camera every frame, so the fade pass reprojects
  continuously.** → The reprojection cost is per-pixel and unconditional already. What changes is
  how often the sampled offset is non-zero. Group 5 watches the frame time and the trail together.
- **Presets now carry two view-behaviour fields.** A preset saved with drift on starts moving the
  view of whoever loads it. → Stated as intended behaviour in D5 and written into the help file, so
  it is documented rather than surprising.
- **The speed ceiling is taste with an argument.** → It is marked as such in the constant's own
  conditions, with the mechanical ceiling recorded beside it so nobody later mistakes 4.0 for a
  measured limit.
