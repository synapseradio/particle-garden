# Design: the calibration procedure

Every constant this change writes comes from a run of the app. This document fixes the observation
channel, the fixtures, the thresholds and the rejection criteria, so the agent executing the tasks
researches nothing.

## Decision 1: the observation channel is the rendered canvas, measured as lit fraction

The app has no physics readback. Physics lives entirely in compute shaders, and the stats the
boundary pushes carry frame rate, particle count, GPU pass timings and the field's alive-cell count,
nothing spatial (`src/web_api.nim:805-861`). So a spatial property has to be read off the pixels.

**Lit fraction** `L` is the share of canvas pixels whose luminance reaches a threshold. It is
computed from a captured PNG, needs no code change, and has the two properties the calibration
needs. It is invariant under toroidal wrapping, because it never forms a centroid, and it falls
monotonically as particles pile onto each other, because overlapping discs light fewer pixels than
separated ones. Every threshold below is expressed as a ratio of two `L` values measured in the same
session, so the absolute scale never enters.

Rejected: **reading positions back from the GPU.** It would need a readback path the architecture
forbids, and the change would then be a mechanism change.

Rejected: **judging the frames by eye.** A judgement no second reader can reproduce cannot be
recorded beside a constant as a condition, and the range authority's measured-bound rule asks for a
measured value, its conditions and its margin
(`openspec/specs/parameter-range-authority/spec.md:78-107`).

Rejected: **frame rate as a proxy for clumping.** A collapsed world and a spread world both run at
the display's refresh rate on hardware that keeps up, so the signal is absent exactly where the
measurement matters.

### Suppressing what would confound L

Every fixture below sets these, so `L` measures occupancy alone:

- `velocityGlowScale` to its slider minimum. Velocity-scaled brightness would make a collapsing
  world brighter as it accelerates, and `L` would then read speed.
- `glowRadiusScale` to its slider minimum, `bloomEnabled` false, `trails` false, `trailLength` 0.
  Each spreads light away from the particle that emitted it.
- `fieldOpacity` 0, `rdDeposit` 0, `rdFieldForce` 0. The chemical field lights pixels and pushes
  particles, and neither belongs in a force measurement.
- `climateDrift` false, `forceWeather` false, except in the weather fixture.

`glowIntensity` stays at its shipped default, because a particle still has to be visible.

Every numeric bound the procedure needs is read from `gardenAPI.descriptor()` at run time, never
restated in the run script. Nim owns those numbers.

## Decision 2: the app is driven through gardenAPI in a Chrome tab

`./main` serves the app over HTTP on `127.0.0.1:8089` with the COOP and COEP headers the page needs
(`src/main.nim:19,60-85`), and separately opens its own native window. Any Chrome instance at that
URL is a full second instance of the app, drivable through the Chrome DevTools Protocol, which
`window.gardenAPI` then exposes to `Runtime.evaluate`.

The relevant boundary calls, all present today (`src/web_api.nim:1125-1320`):

| Call | Use |
|---|---|
| `onReady(cb)`, `isReady()` | wait for the buffers before touching anything |
| `exportPresetJsonPretty(name)` | read a complete, current-schema fixture out of a live session |
| `applyPresetJson(json)` | apply one back, matrix and chemistry and palette included |
| `setParam(id, v)`, `commitParam(id)` | move one control the way a drag does |
| `getParam(id)`, `descriptor()` | read values and every bound, step and curve |
| `paramValueAt(id, position)` | the value at a slider travel position, so a sweep is even in travel |
| `resetParticles()` | reseed the world between repeats |
| `randomizeMatrix()` | draw a colony matrix once, then pin it by export |
| `onStats(cb)` | frame rate, for the rejection gate below |

The fixture is always built by exporting from a live session and editing the parsed JSON. Writing
one by hand would restate the schema, and the schema is `src/preset.nim`'s.

Two app instances share one GPU. That is handled by a stated gate, not by a guess: a run whose mean
frame rate over its window falls below 30 is rejected, and the fixture's particle count is halved
and recorded as a condition.

### The world clock

Frame rate varies, so every window below is measured in **world seconds**, accumulated in the page
exactly as the frame loop does: `min(rawDt, 0.05) * timeScale` (`src/app.nim:240-241`). The run
script installs its own `requestAnimationFrame` hook to accumulate it and captures at world-time
marks. The driving window stays visible and focused, because a hidden tab throttles
`requestAnimationFrame` and the world clock stops advancing with it.

The force weather is the exception. It advances on wall-clock seconds, not scaled ones
(`src/app.nim:265-269`), so its dwell arithmetic converts between the two and records the time scale
it converted at.

### Capture and reduction

Capture with the DevTools Protocol's `Page.captureScreenshot`, clipped to the canvas element's
bounding box. Reduce with a throwaway script: convert to luminance, count pixels at or above
`16/255`, divide by the pixel count. Record the canvas dimensions in the conditions.

A capture is valid only if the baseline frame it is compared against gives `L` strictly between
0.01 and 0.35. Zero means the capture composited nothing, and a value near saturation means `L` has
stopped discriminating. Both indicate a broken capture, not a wrong constant.

All run records go to `scratchpad/main/calibrate-shipped-defaults__<DD-MM-YY-HHmm>.md`, one row per
run: fixture, swept value, repeat index, the `L` values at each mark, mean frame rate, canvas
dimensions.

## Decision 3: the two crowding thresholds are ratios, not absolute occupancies

The constant's own record names what to find: the strength at which a collapsing world stops
tightening, and the strength at which ordinary colonies visibly soften
(`src/config_ranges.nim:46-54`). Both are stated below as a comparison between `L` values from the
same session, so neither depends on canvas size, particle count or the luminance threshold.

**Fixture C, the collapsing world.** Export a fresh session, then set: `speciesCount` to
`SPECIES_COUNT_MIN`, which is 2 because a one-species world is unrepresentable
(`src/config_ranges.nim:29`); every matrix entry to `MATRIX_MAX_VALUE`, so every pair attracts at
the strongest authorable value and the whole world collapses regardless of species;
`fluidStrength` 0; the confound suppressions above; everything else at its shipped default.

**Fixture D, ordinary colonies.** Export a fresh session after one `randomizeMatrix()` at the
shipped `ruleWildness`, and reuse that exported matrix for every run so the colony world is fixed.
Apply the same suppressions. Everything else stays at its shipped default.

**Per run.** Apply the fixture with `crowdingStrength` set to the swept value, `resetParticles()`,
then capture at world-time 2 s, 20 s and 90 s.

**The sweep.** Six values, `paramValueAt('crowdingStrength', p)` for `p` in 0.0, 0.2, 0.4, 0.6, 0.8,
1.0, so the sweep is even in slider travel and honours the control's curve. Two repeats per value,
differing only in the reseed. A run costs 90 world-seconds, which is 180 wall seconds at the shipped
time scale, so the coarse pass over both fixtures takes about 70 minutes and the refinement below
about another hour.

**Validity gate on fixture C.** At crowding 0, require `L(90) <= L(2) / 3`. A world that does not
collapse cannot show a strength that stops it collapsing, and a failure here means the fixture is
wrong.

**c_hold**, the strength at which a collapsing world stops tightening: the smallest swept value
whose mean `L(90)` reaches `0.9 × ` its own mean `L(20)`. Occupancy has stopped shrinking over the
last 70 world-seconds. If the repeat standard deviation straddles that line at the chosen value, add
repeats up to nine before accepting it.

**c_soften**, the strength at which ordinary colonies visibly soften: the smallest swept value on
fixture D whose mean `L(90)` exceeds the crowding-zero mean `L(90)` by more than 25% and by more
than three standard deviations of the crowding-zero repeats.

**Refinement.** Bisect three times between the two adjacent sweep values that bracket each
threshold, three repeats per bisection point, which locates each threshold to a fortieth of the
slider's travel.

**Setting the ceiling.** `CROWDING_STRENGTH_MAX` becomes the smallest value representable at the
control's step that reaches `1.5 × c_soften`. Half again as much strength as visible softening
needs, so the top of the slider is past the useful region without being unreachable nonsense.

**If no swept value satisfies the hold criterion**, the range is too narrow, not the mechanism too
weak. Double `CROWDING_STRENGTH_MAX`, re-run the sweep over the widened range, and repeat. Never
declare the current ceiling measured because the sweep found nothing inside it.

**What gets recorded beside the constant**: `c_hold`, `c_soften`, the `1.5 ×` margin, and the
conditions. Both fixtures in full, particle count, interaction radius, time scale, the matrix bounds
they were measured against, fluid off, field off, canvas dimensions, and the world-seconds of
settling.

## Decision 4: the SPH fraction floor is set from where the fluid stops computing

Only the floor carries a provisional marker. The shipped default of `1.0` carries a reason: it is
the kernel every fluid world already watched has run (`src/ui/state/simulation_state.nim:113-116`),
and the v1 preset branch pins the same value for the same reason (`src/preset.nim:639-645`). This
change leaves the default at `1.0` and measures the floor.

Rejected: **moving the default down in this pass.** No evidence on disk says a narrower kernel makes
a better shipped world, and moving it would change every fluid world a user reaches by loading a
current-schema preset that omits the field.

**Fixture F.** Export a fresh session, then: `fluidStrength` at its slider maximum; `forceStrength`
0, so nothing but the fluid moves particles and the measurement is of the fluid alone
(`src/config_ranges.nim:35-40`); `crowdingStrength` 0, which `openspec/specs/sph-scale/spec.md`
already requires of this calibration; `sphStiffness`, `sphSubsteps`, `sphViscosity` and
`sphRestDensity` at their shipped defaults; the confound suppressions above.

**The sweep.** `interactionRadius` at `INTERACTION_RADIUS_MIN` and at its shipped default, crossed
with six fraction values at slider travel 0.0, 0.2, 0.4, 0.6, 0.8, 1.0. Three repeats each. Capture
at world-time 60 s. For each interaction radius also run the null: the same fixture with
`fluidStrength` 0. Bisect three times around the boundary the coarse pass brackets.

**f_inert**, the fraction at which the fluid computes nothing: the largest swept fraction at the
minimum interaction radius whose mean `L(60)` differs from the null's mean `L(60)` by less than
three standard deviations of the null repeats.

**Setting the floor.** `SPH_RADIUS_FRACTION_MIN` becomes the smallest value representable at the
control's step that reaches `1.5 × f_inert`, so the narrowest offered kernel does something at the
narrowest offered interaction radius.

**The prediction that makes this falsifiable.** The shader floors every pair distance at 2 px
(`src/shader_config.nim:98`) and both kernels return zero at and beyond their own radius, so a
kernel narrower than that floor sees no neighbour at any separation. Against
`INTERACTION_RADIUS_MIN` of 10 px that puts `f_inert` near 0.2 and the floor near 0.3. A measurement
far from this means the reasoning above is wrong somewhere, and the finding goes in the record.

**Cross-check after raising the floor.** Raising it raises the worst-case stiffness ceiling, since
that ceiling is linear in the smoothing radius (`src/sph_core.nim:135-143`,
`stableStiffnessCeiling` at `:153-176`), so no labelled stiffness notch can be stranded by this
direction of change. The notch sweep in `tests/test_param_descriptor.nim` re-scopes itself from the
constant and confirms it.

## Decision 5: the weather speed is derived from the measured settling time

A waypoint the tour leaves before its world becomes visible is not a place the weather visits. So
the waypoints and the speed are one measurement in two parts.

**Fixture W.** Export a fresh session with the confound suppressions, fluid off, field off,
`crowdingStrength` 0 so the weather is measured against the plain force law, and the matrix pinned
the way fixture D pins it.

**Part 1, the waypoints as destinations.** For each of the five waypoints, with `forceWeather` off,
write `forceStrength`, `interactionRadius` and `friction` through `setParam` and `commitParam`,
`resetParticles()`, run to world-time 60 s, capture. Three repeats each. Require every waypoint's
mean `L(60)` to differ from both of its tour neighbours' by more than three standard deviations of
the repeats. A waypoint that fails is replaced by another coordinate inside the three ranges and
re-measured, and what each of the five produces is recorded beside the table.

**Part 2, the settling time per segment.** For each of the five segments, settle at waypoint `i` for
60 world-seconds, write waypoint `i+1`'s three values in one commit, then capture every 2
world-seconds for 60 world-seconds. `T_settle(i)` is the earliest world-time after which `L` stays
within 5% of its value at the end of the window.

**Part 3, the speed.** Speed is tours per minute (`src/climate_core.nim:70-72`), the tour has five
segments, and the weather advances on wall-clock seconds (`src/app.nim:265-269`). One segment
therefore lasts `60 / (5 × speed)` wall seconds, and a world second costs `1 / timeScale` wall
seconds at the shipped time scale. `FORCE_WEATHER_DEFAULT_SPEED` becomes the largest value
representable at the control's step satisfying

```
60 / (5 * speed)  >=  max_i T_settle(i) / timeScale_default
```

**If the derived speed falls below `FORCE_WEATHER_SPEED_MIN`**, no offerable speed lets the tour
dwell long enough. That is a finding about the tour, reported with the measured settling times, and
never a default set below the range it lives in. The tour needing fewer waypoints, or the speed
range needing a lower floor, is the user's call and outside this change.

**What gets recorded**: each waypoint's produced world, each segment's settling time, the time scale
the conversion used, and the resulting dwell margin.

**The mirror that moves with it.** `src/preset.nim` carries the speed as a literal `0.5` (`:265`)
because its imports are restricted, and `tests/test_preset.nim:43` asserts that literal equals
`FORCE_WEATHER_DEFAULT_SPEED`. Changing one without the other goes red there.

## What is proven and what is designed

Proven, and exercised by the existing suites: the crowding attenuation and its density ceiling
(`tests/test_physics.nim:96-170`, `:192-243`), the SPH kernels and the stiffness ceiling's linear
law (`tests/test_sph_core.nim:138-210`, `:626-816`), the tour's in-range, no-jump, easing and
landing guarantees over the force table (`tests/test_climate_core.nim:285-332`), and the two default
mirrors between the state records and the preset schema (`tests/test_preset.nim:30-43`, `:59`).

Designed and unexercised: the lit-fraction channel itself. No run of it exists. The first task
group's validity gate is what turns it from a designed measure into one that has discriminated a
known collapse from a known spread, and until that gate passes no threshold below it means anything.

## Open question

Whether the calibrated crowding default should be nonzero. Stated with its options and its evidence
in `proposal.md`. The measurement tasks do not depend on the answer: they produce `c_hold` and
`c_soften` either way, and only the single task that writes the default waits on it.
