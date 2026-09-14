## Context

See `proposal.md` (Why) for the in-app evidence and the four measured causes. The facts the approach
rests on:

- **The pair pass already carries a species-blind crowd signal.** Every pair adds
  `proximityWeight = 1 − r/R` to both particles' `crowdDensity` accumulators
  (`web/shaders/src/forces.wgsl:312-316,386-387`), and integrate smooths it with
  `DENSITY_SMOOTH_FACTOR` 0.7 (`web/shaders/src/integrate.wgsl:72-74`). The loop already loads the
  whole neighbour record, `crowdDensity` included (`forces.wgsl:231`). The particle record is 32 bytes
  and has no spare field (`web/shaders/modules/particle.wgsl`). The loop visits each pair once: this
  particle's share sums in a register and is converted to fixed point once, the other's is converted
  and atomically added per pair (`forces.wgsl:282-300,377-382`).
- **The crowd unit grows with the world.** A uniform world's crowd density is `ρ̄ = N·π·R²/(3·A)`:
  5.1 at 16 000 particles and radius 50, 40.4 at 128 000 and 50, 364 at 128 000 and 150, in the
  3840 × 2160 world. No coupling acting, settled peaks at radii 50 and 100 run 11.6 to 721 (721 at
  radius 100), and divided by `ρ̄` they fall in one band, 2.2–6.6 for mixed matrices and 9.7–11.3 for
  a self-attracting species (design notes, batch A).
- **The band does not hold at small `N · R²`.** Crowd density is a sum over discrete neighbours, so
  one contact reads `1 − r/R` however small `ρ̄` is. At 1 000 particles and radius 10 one pair reads
  `x = 40`; at 16 000 and radius 10 mixed worlds peak at `x` 10.4–15.8, above the self-attracting band
  measured at radius 50 (critique N-B2; design notes, second critique, batch G: 10 worlds from 100
  to 128 000 particles and radius 10 to 150, 3 seeds, 600 frames).
- **Units.** The pair force is multiplied by `params.dt` in seconds (`forces.wgsl:297,377`). One
  touching neighbour at force strength 1 hands `FRAME_DT_REFERENCE = 1/120` velocity per reference
  frame. That is `u0` here. The largest substep is 0.25 s, a frame factor of 30
  (`src/body_core.nim:139-148`). The frame factor is not usually 1: `src/app.nim:239-241` sets
  `dt = min(rawDt, 0.05) · timeScale` before any substep split, so one substep on a 60 Hz display at
  time scale 1 runs at frame factor 2 (critique N-M10). The shipped time scale is 0.5
  (`src/ui/state/simulation_state.nim:138`), so a 60 Hz display at shipped settings runs at 1
  (`src/physics_core.nim:23-26`); a 120 Hz display at time scale 1 does too.
- **Fixed point.** The velocity word holds ±32 768 at 2^16 (`web/shaders/modules/fixed_point.wgsl`).
  In WGSL concrete `i32` arithmetic wraps and a float-to-integer conversion clamps to the target's
  range (https://www.w3.org/TR/WGSL/), so each per-pair conversion and each particle's final sum must
  fit, and intermediate wraps are exact. The body accumulator already asserts a full-crowd bound,
  `MAX_PARTICLES ×` the per-particle maximum (`src/body_core.nim:262-269`).
- **Crowding** attenuates positive attraction only and ships at 0 (`forces.wgsl:73-93,261`,
  `src/config_ranges.nim:48`). It stays a look control (D9).
- **Bodies.** `parametric-bodies` D16 and its requirement "A body's pull on a particle is bounded in
  size and in region": at most `BODY_FORCE_CEILING · bodiesStrength · envelope` per reference frame per
  body (10 at the ceilings), inside a shell reaching at most `2 · bandWidth · max(anisotropy,
  1/anisotropy)` from the surface, a smoothstep bump peaking one band out; contributions add across up
  to `MAX_BODIES = 32` bodies; no normalization (`openspec/changes/parametric-bodies/design.md:652-699`,
  `specs/parametric-bodies/spec.md:170-212`). The push stays uncapped (the lead's answer).
- **Frame budget.** Headroom is the 16.7 ms budget less the whole frame (`docs/perf-report.md:132-147`),
  so an allotment taken from it bounds the **cost the term adds**, `physics=` with the term less
  `physics=` without it, not the absolute `physics=` (critique N-M1). Two headrooms are on record:
  - `w1-128k`, 128 000 particles at the shipped radius, 30 s window: 11.65 ms.
  - `w1-128k-150`, the same shipped world (no settings applied) over a 150 s window, physics
    6.529–7.929 ms and "still climbing when the window closed": 3.75 ms. Its `-150` is the window
    length, not the radius (`scratchpad/main/perf-harness/runs/w1-128k-150.json`: `"durationSeconds":
    150`, `"requestedSets": []`); an earlier revision and the second critique read it as radius 150.
    `src/config_ranges.nim:112-114` calls this figure "the settled 128k headroom", which the report
    does not support; long range allots itself 1.0 ms of it.

  The bodies passes read 0.066–0.076 ms at 128 000 with no live body (`docs/perf-report.md:322-325`).
  **The allotment is drawn from `w1-128k`'s 11.65 ms** (the lead's answer, 13-09-26), given on the
  reading that the other run was a radius-150 world still climbing. That reading is wrong: it is the
  same shipped world 120 s later, and the report reads every physics figure as a lower bound on the
  settled cost (`docs/perf-report.md:69-75`), so the settled shipped headroom is at most 3.75 ms, not
  11.65. **The allotment is provisional** (the lead's answer, 14-09-26): 11.65 ms stays the working
  figure, labelled a lower bound on the headroom, and task 4.5's in-app settled reading with the term
  decides the allotment before the task that lands the term can close; the added-cost bound (the proposal's
  measurement gate 4, task 1.5) waits on that reading. The pair pass's working added-cost allotment is 11.65 − 1.0 (long range) − 0.076 (bodies,
  idle) ≈ **10.57 ms, provisional** on that reading and on `parametric-bodies` 9.3's live-body reading
  of the bodies figure. It bounds the cost the term and the coarse word add to a settled world at
  `MAX_PARTICLES`, not a
  held one (D6). The shipped count is 16 000 (`src/ui/state/simulation_state.nim:129`); task 6.2
  compares the shipped world separately. The first draft's 2.67 ms, taken from the 150 s row, is
  withdrawn with it unless the lead's answer above returns to that row.
- **Two in-flight changes wait on this one.** `long-range-mesh` task 6.2 and
  `calibrate-shipped-defaults` group 3. `parametric-bodies` 9.2 and 9.3 wait on the density term (the
  user's decision).

Scratch evidence lives in `scratchpad/coupling-balance/`: `design-notes__13-09-26-1642.md` (every
probe table), `lr_unit_probe.nim` (a static mesh solve of the long-range unit), `pressure_probe.nim`
(1 500 all-pairs particles in 320 × 180 with a whole-world hold), and `app_scale_probe.nim` (binned
neighbours on the 3840 × 2160 torus at any particle count, a D16-law body stacked up to 32 times, the
laws, the gate, quantization, viscosity). Every probe is a native CPU model of the shader's
expressions; none is the GPU.

## Goals / Non-Goals

**Goals:**

- One unit in which every compressor's largest push is written and compared.
- A long-range pull independent of mesh size, with one ceiling derived from that unit at every
  interaction radius.
- A pressure that is local: a crowd's resistance depends on that crowd's own density, never on what
  a coupling does elsewhere.
- Onset and stiffness derived from the world's own configuration and measured behaviour, with no
  hand-set constant and no range clamped.
- A compressed crowd that stays local and below its collapse while compressed, and a self-attracting
  crowd that relaxes toward the neighbourhood a fresh settle reaches once the compressor goes: at the
  chosen stiffness, fully at 128 000 particles (D13). Mixed worlds keep what a hold
  merged below the onset, a consequence of the onset's placement (D3).
- Below the onset, the force law's delta changes only in its low bits: under the reference-frame
  convention (D8) a contribution quantized today as `trunc(ff · x · 2^16)` is quantized as
  `trunc(x · 2^16)` and scaled by `ff` after decoding, which moves it by less than `⌈ff⌉` quanta of
  2^−16 velocity (the difference of two truncations). At frame factor 1 the delta is bit-identical.
  Whether the low-bit change at frame factor 2 is visible is unmeasured (task 6.2 compares).

**Non-Goals:**

- The bodies falloff (owned by `parametric-bodies`).
- Choosing new shipped defaults (owned by `calibrate-shipped-defaults`).
- Transient impulses: blast is a one-frame impulse and is not a compressor that settles.
- Bounding the heat of a held world (a finding for `parametric-bodies`, D6).

## Decisions

### D1. The shared unit is one touching neighbour over one reference frame

`u0 = FRAME_DT_REFERENCE` velocity per reference frame: the contact repulsion of one neighbour at
force strength 1. `src/balance_core.nim` owns it and one demand function per compressor, each
returning the largest inward impulse per particle at a stated configuration in multiples of `u0`:

| Compressor | Demand at range maxima | Source of the figure |
|---|---|---|
| Pair attraction | `FORCE_STRENGTH_MAX · MATRIX_MAX_VALUE · 4 ·` edge neighbour sum | `physics_core.polynomialForce` |
| Long range | `LONG_RANGE_STRENGTH_MAX · MATRIX_MAX_VALUE · A · (U(R)/u0) · M/(2πr)` at the reference colony (D2) | `long_range_core` |
| Bodies | `Σ bodies BODY_FORCE_CEILING · strength · envelope / u0` per particle, up to `MAX_BODIES` | `parametric-bodies` D16 |
| Field force (tropism) | `RD_FIELD_FORCE_MAX · |TROPISM_MIN|` times the gradient bound | `field_core` |
| Mouse | the pointer force at its maximum over a reference frame, while held | `physics_core` |

The demands are compared with the pressure's capacity (D6) and with each other. No demand feeds any
stiffness: the stiffness is fixed (D5), so a mouse press, a slider move or a body's attack changes
nothing in the pressure term.

`balance_core` imports the oracles and never `config_ranges`, so `config_ranges` can import it and
assert against it.

Alternatives: a unit of "one reference frame at max speed" (the speed cap) was rejected because the
cap is a soft log curve, not a force. A unit per coupling with conversion tables was rejected: it is
the status quo that let the couplings drift 26–112× apart.

Evidence: a static mesh solve (`lr_unit_probe.nim`) agrees with the long-range formula to 4% at 60
from the clump centre and reach 600 (55.4 formula, 53.1 solved), and to 0.7% at 240 and reach 4000
(critique M5). The tropism and mouse demand functions are designed, not exercised.

### D2. The long-range potential is measured in a radius-scaled pair unit, not in cell area

The impulse today is `s · A · cellArea · M/(2πr)` inside the reach. The coarse mesh pulls 4.006× and
4.004× harder at 240 and 600 from the centre of a 1 000-particle clump (`lr_unit_probe.nim`); at 60
the ratio is 3.19, so mesh independence holds only a few cell widths out. The factor `cellArea`
becomes `U(R) = u0 · R² · (a + R) / a²`, with `R` the live interaction radius and `a` the reference
colony's radius below. The kernel shape, `G(0) = 0`, the unit-charge deposit and the fixed point stay.

The one site is the force scale written to `LR_FORCE_SCALE` (`src/webgpu_compute.nim:1125`), computed
by a `long_range_core` function the test calls, so the shader receives one oracle-computed number.

| Option | Sacrifice | Verdict |
|---|---|---|
| Stand still | The slider pulls 4× harder on one mesh; no unit to derive a ceiling from | Rejected |
| Normalize by `N` (a contrast potential) | Long range against pair scales as `1/N` at fixed local structure, so small worlds collapse | Rejected |
| Unit-integral Yukawa kernel `κ²/(k² + κ²)` | The far pull falls to about `M/r³`; distant groups stop answering, a navigability loss | Rejected |
| Normalize by mean particles per cell | Same `1/N` dependence | Rejected |
| `u0 · R` in place of cell area (the second draft) | The derived ceiling moves 18.4× across the radius range (below), so one constant is either weak at radius 150 or past the out-pull point at radius 10 | Rejected by the user, 13-09-26 |
| **`U(R) = u0 · R² · (a + R) / a²` in place of cell area** | At a fixed slider value the pull grows with the radius slider, by `R²(a + R)`: 273× from radius 10 to 150, which is `R²` times at most 1.21; moving the radius changes long range's share of a world. Every saved long-range world changes unit (D7), and the unit carries `x_on` through `a` | **Chosen by the user, 13-09-26** |

**The reference colony (critique M8).** `LONG_RANGE_STRENGTH_MAX` is the strength at which the whole
population, `MAX_PARTICLES`, gathered into one disc at the onset density (D3), pulls a particle one
interaction radius past the disc's edge as hard as the pair force's peak edge impulse at that
density. The colony's mass and radius are fixed by recorded numbers: `M = MAX_PARTICLES`, radius
`a = √(M / (π · n_on))`, where `n_on = x_on · M / A_world` is the number density at the onset, so
`a = √(A_world / (π · x_on))`, independent of `R`. Beyond that strength long range out-pulls the pair
force at the scale of the largest colony the world can hold, the regime the in-app filaments came
from. `balance_core` computes the value at the recorded onset. `longRange.impulseShare` reports its
impulse in `u0` at the same colony.

**Why this unit (critique N-M6).** The pair force's edge impulse at the onset density grows with the
onset's crowd density, `x_on · ρ̄ ∝ R²` at `N = MAX_PARTICLES`, while the pull one radius past the
colony's edge is `s · A · U(R) · M / (2π(a + R))`. Under the second draft's `U = u0 · R` the ceiling
went as `R(a + R)`: at an illustrative `x_on = 7`, `a = 614` and `R(a + R)` is 6 241 at radius 10,
33 207 at 50 and 114 621 at 150, an 18.4× spread (python arithmetic). With
`U(R) = u0 · R² · (a + R) / a²` the ratio `P(R) · 2π(a + R) / (A · U(R) · M)` loses every `R`, so one
ceiling holds at every radius. The `a²` keeps the unit's dimension that of `u0 · R` and adds no
constant: at `x_on = 6.3` and the 3840 × 2160 world, `a = 647.4`, and `U(50)` is 0.083 of `u0 · 50`.

The option list the user chose from wrote this unit as `u0 · R² / (a + R)`. That form was an algebra
slip: it has the dimension of a velocity and leaves the ceiling going as `(a + R)²`. The form above is
the one with the property the option described, a single ceiling at every radius, and its cost is the
one the option stated, a pull growing about as `R²` at a fixed slider value (up to 1.21× more at
radius 150). The corrected formula is recorded without a second ask (the lead's answer, 13-09-26): the
user chose the unit for its meaning, a radius-independent ceiling, and the consequence they were shown
still holds.

The diagnosis report's red test "scaling deposits leaves the gradient unchanged" is rejected: it
would hold a contrast potential. Two relations take its place: mesh-size independence and the
Green's-function formula (D10, tests 1 and 2).

### D3. The density the pressure reads is measured in the world's own mean

The pressure reads `x = ρ / ρ̄`, the smoothed crowd density over the uniform crowd density of the live
world, `ρ̄ = N · π · R² / (3 · A)` from the live particle count, the live interaction radius and the
world's area. `ρ̄` is one number per frame, computed by a `balance_core` function and written as one
uniform. It changes only when `N`, `R` or the world size changes, which already changes every crowd.

Why: batch A (design notes) settled worlds with no coupling acting at 16 000 and 128 000 particles and
radii 50 and 100. Their peaks spread 60× in `ρ` and sit in one band in `x`. An onset in `ρ` either
leaves small worlds unbounded or pushes a 128 000-particle radius-150 world apart from its own uniform
settle, where `ρ̄ = 364` (critique B3).

| Option | Sacrifice | Verdict |
|---|---|---|
| Onset and ceiling in `ρ` (the first draft) | A world with no coupling sits above them at high `N · R²`; small worlds never reach them | Rejected by batch A |
| Per unit of `n · R^k` with `k ≠ 2` fitted from batch A | One more fitted number; batch A's two radii cannot fix `k` better than the 2 a uniform world gives exactly | Not chosen |
| `x = ρ / ρ̄` from live `N`, `R` and area, alone (the second draft) | At small `N · R²` one or two contacts read far above any onset in `x` (critique N-B2, batch G) | Rejected by batch G |
| **`ρ_on = max(x_on · ρ̄, ρ_floor)`: a ratio of the world's mean, floored by a discrete-contact density** | A second uniform term; the floor follows the live pair-law shape; the self-attracting band and the mixed peaks still overlap in `x` (below) | **Chosen** |

**The floor.** `ρ_floor` is the crowd density of a hexagonal lattice at the pair law's rest spacing
for an attracting pair: every particle at rest against six neighbours, the densest arrangement a
settle reaches without compression. For the polynomial model the rest spacing is `repulsionEnd · R`,
where the Hermite ramp lands at zero force (`physics_core.nim:397-414`), so the floor depends only on
`repulsionEnd`. Lattice sums (python, design notes batch G): spacing 0.1 → 120.0, 0.2 → 29.3,
0.3 → 12.6, 0.4 → 6.64, 0.5 → 3.80, 0.6 → 2.40, 0.75 → 1.50, 0.9 → 0.60. For the exponential
model the rest spacing is `ln(1/(2 · MATRIX_MAX_VALUE)) / (α − β)` where `α > β` and it falls inside
`R` (`physics_core.nim:427-434`); elsewhere an exponential pair has no rest spacing inside the radius,
and the floor that model needs is unprobed [?] (task 1.2 measures it). `balance_core` computes the
floor by the lattice sum, and it is written beside `ρ̄`. At the preset default `repulsionEnd` 0.5 the
floor is 3.80: above every mixed peak at 16 000 particles and radius 10 (3.2) and below every
self-attracting peak there (5.4), so there it separates the two where `x` could not.

**What the floor and ratio do not separate** (batch G, mixed peaks whose `ρ` passes the floor, in
`x`): 128 000 at radius 10 reaches 9.1, 16 000 at 20 reaches 8.0, 1 000 at 50 reaches 7.9. Self-attracting
settles at 1 000 and radius 150 read 6.3–7.9, and at 1 000 and radius 50 8.9–13. So `x_on` either
sits above the densest mixed peak, leaving some self-attracting settles below the onset, or below it,
trimming those mixed peaks. Batch I-a measured the trim: at 128 000 and radius 10 with `x_on = 6` the
densest particle's crowd fell from 14.7 to 11.8, while p99, weighted neighbours and mean speed stayed
unchanged to the printed digit.

**The placement: the bottom of the self-attracting band, `x_on ≈ 6.3` (the user's decision,
13-09-26).** Task 1.2 records the value on the calibration seeds at the band's measured bottom.

| Placement of `x_on` | Mixed worlds | Self-attracting worlds | Verdict |
|---|---|---|---|
| Above every calibration mixed peak past the floor (about 9.1 on batch G) | Unchanged at every measured `N` and `R` | Settles below it (1 000 at radius 150, low end of 1 000 at 50) get no pressure of their own and keep a hold's compression | Rejected |
| **At the self-attracting band's bottom (about 6.3)** | The densest particles of dense mixed settles are trimmed about 20% (128 000 at radius 10: 14.7 → 11.8 at `x_on = 6`) | Every measured self-attracting settle lies above the onset | **Chosen** |
| Lower still, `x ≈ 3`, to separate clumps a hold merged | Merged mixed clumps' memory halves (after-over-fresh neighbours 1.16–1.28 against 1.37–1.71, batch L); ordinary mixed settles at 1 000 at radius 50 and 16 000 at 20 lie above it and change | As above | Rejected with the 6.3 placement |

**The consequence for mixed worlds.** A mixed world's fresh settle sits below `x_on ≈ 6.3`, and
clumps a hold pushed together stay merged after release: below the onset nothing in the pair law
separates two clumps pushed into one (D13). This follows from the placement, and the `x ≈ 3` option
that would have halved it is rejected with it. The densest particles fall back to about the onset.

### D4. Where the pressure term lives

Per pair, inside the existing loop, alongside the force law and not inside its expression:

```
φ(ρ)   = (max(ρ − ρ_on, 0) / ρ_on)²                          ρ_on = max(x_on · ρ̄, ρ_floor)  (D3)
m      = min(K · (φ_this + φ_other) · (1 − r/R) / 120, q_max)  velocity per reference frame, no dt
qx, qy = trunc(−m · (separation/r) · 2^16)                    one signed integer per component
this  += (qx, qy)        other −= (qx, qy)                    split across the fine and coarse words (D8)
```

`φ_this` is hoisted beside `attenuationOnThis`. The magnitude saturates at `q_max` before the
direction is applied, so a saturated pair keeps its direction. The law has no ceiling parameter: its
scale is the onset itself, so the only measured numbers it carries are `x_on` and `K` (D5). The
contribution carries no `dt`: every writer accumulates per reference frame and integrate applies the
frame factor once (D8, critique N-B4).

**Bit identity below the onset (critique M7).** The force law keeps its grouping,
`forceMagnitudeOnThis *= params.forceMultiplier * invDistance` (`forces.wgsl:282`). The pressure is
formed and accumulated separately, so below the onset the velocity delta the force law writes is the
same expression it is today at every force strength, not only at 1 (the critic measured 35 207 of
100 000 products changed by the first draft's regrouping at 0.7). On the GPU this holds only if the
shader compiler does not regroup. The first critic read Dawn's Metal backend
(https://raw.githubusercontent.com/google/dawn/main/src/dawn/native/metal/ShaderModuleMTL.mm, lines
460-469 and 564) and reported that it compiles with relaxed math unless strict math is requested; this
design has not re-read those lines. Whether Chromium requests strict math is unread (task 1.6). GPU
bit identity is therefore **unenforced**; the native oracle holds it.

**Momentum (critique M6, N-M4).** The pair's impulse is quantized once per component, to one integer
pair `(qx, qy)`, which is added to one particle and subtracted from the other. Momentum in the pressure
term is then conserved exactly, not to within a quantum per pair. The force law's own truncation
asymmetry (the critic's −394 to −643 quanta per frame) is today's and unchanged.

| Placement | Sacrifice | Verdict |
|---|---|---|
| Stand still | Collapse under every compressor, no relaxation (1 499/1 500 neighbours stuck) | Rejected |
| Integrate pass, along `∇ρ` | Integrate has no neighbour direction; a gradient needs a second neighbour pass | Rejected on cost |
| A grid pressure (density to mesh, gradient back) | A deposit, a stencil and a gather per frame; one cell is coarser than `R` on the shipped mesh | Rejected on cost |
| Onset-shifted Tait law on `sphDensity` (critique M11) | `sphDensity` belongs to the fluid pass, which is skipped at fluid 0 (`docs/one-world.md:52-60`), so the pressure would vanish with the fluid slider or need a second writer; and a Tait law's slope at its onset is `γ/ρ_on`, not zero: at the same stiffness it boiled the self-attracting settle at mean speed 4.02 against 1.47 for the square, and 2.34 at a tenth of the stiffness (design notes, batch B) | Rejected on ownership and on the onset step |
| Onset-shifted Tait law on the crowd density | Keeps ownership; keeps the onset step (batch B) | Rejected |
| Unsmoothed crowd density for the pressure | Linear stability of a lagged pressure is 3× higher without the smoothing (design notes, stability table); but crowding reads the same field, so crowding's look would change, and at a fixed high stiffness it did not stop the boil (run 5, mean 6.41) | Not chosen; reopens if the in-app run shows onset jitter |
| A density gate: outside pushes and a particle's own attraction fade between onset and ceiling | Zero extra pair cost. Lowered the app-scale stacked hold's peak 35% (394 against 608 at the same stiffness) but did not hold it under 2× the onset, and in the small world it added nothing and failed with weak pressure (design notes, g0, g1, app scale). A dense crowd would stop hearing bodies, long range, tropism and the mouse: a new behaviour | Rejected by the user (D6) |
| Pair viscosity 0.5 on relative velocity along the separation, above the onset | One dot product per pair and 1 600 coarse units per pair (D8). At 128 000 particles and `K = 540` (batch M, 3 seeds): L at friction 0 0.864–0.890 against 1.163–1.175 without it; after-release over fresh 0.901–0.972 against 0.971–0.976; settled speed at shipped friction 0.107–0.125 against 0.028–0.115; held crowd peak 567–573 against 618–630; friction-0 neighbours 61.8–64.7 against 62.7–67.1. At 16 000 and `K = 54` it removed the shipped-friction simmer (0.020–0.022 against 0.083–0.135), at `K = 540` it did not (0.117–0.163 against 0.100–0.135, batch N). Its exact per-pair decay form overshot at frame factor 30 (15–18) | Chosen on 13-09-26, **rejected by the user on 14-09-26** with the choice of `K = 540` without it (D13) |
| Implicit density projection (position-based, iterated) | Unconditionally stable and a hard bound, at one extra neighbour sweep per iteration | Rejected by the user on performance, the top priority (D6) |
| **Pair term on the smoothed crowd density, split across the fine and coarse words** | A coarse per-particle word and one more atomic add per pair (D8), cost unmeasured; the smoothed signal lags, which bounds the stiffness (D5) | **Chosen** |

### D5. The stiffness is fixed, and the law's stiffness rises with the crowd's own density

The first draft made the stiffness live: a uniform that followed every coupling's demand. The critic
showed it blasting every crowd above the onset when it stepped (critique B1), and the probes confirm
the non-locality survives a ramp:

| Stiffness schedule, 54 → 1728 with no body (1 self-attracting species) | First frame mean speed | Mean speed in sampled frames once at 1728 |
|---|---|---|
| Step | 9.61 (from 1.47) | 1.3–8.7 |
| Ramp over 60 frames | 1.61 | 1.5–5.7 |
| Ramp over 240 frames | 1.55 | 2.6–4.4 |

A ramp removes the blast and keeps the boil: while the stiffness is high a crowd above the onset runs
up to 3–4× hotter than at 54, with no body anywhere. A ramp slower than a body's two-frame attack also lags the push it
answers. Any stiffness that moves with a coupling breaks locality, and `docs/one-world.md:58-60` has
each strength act only through its own pass.

| Option | Sacrifice | Verdict |
|---|---|---|
| Live stiffness, stepped | Blasts every crowd above the onset (critique B1) | Rejected |
| Live stiffness, ramped | Boils every crowd above the onset while high (table above); lags a two-frame attack | Rejected |
| Fixed stiffness, square law | Holds only as much column as a calm stiffness answers (D6) | **Chosen** |
| Fixed stiffness, barrier law `t²/(1 − t)` (stiffness diverges toward a ceiling) | Needs a saturation to stay in any accumulator: in the small world single frames wrote 38 284 and 31 870 against a 32 768 span, and at app scale 481 635 per particle per reference frame; it held the stacked column only 7–12% lower than the square (812 against 918 at frame 49 of the hold) | Rejected on the saturation it needs and the little it buys |
| Fixed stiffness, onset-shifted Tait | Onset step (D4) | Rejected |

The square law's local stiffness is `2K · (x − x_on)/x_on²`: zero at the onset and rising
continuously with the crowd's own excess. That is the continuously rising stiffness, carried by the
law rather than by a schedule, so it answers a compressed crowd harder exactly where and while it is
compressed. At app scale the far crowds' mean speed stayed 0.27–0.32 through a 32-body hold and its
removal (design notes, app scale).

**The settle statistic (critique N-B3).** The second draft's late-over-early speed ratio is withdrawn.
It could not see level: a world boiling steadily from the first window reads 1, as does a world at
rest; at shipped friction it divided by no-term speeds of 0.000–0.005; and the critic's run ranked the
chosen law furthest from the no-term ratio while Tait sat closer. Its replacement:

`L = (late-window mean speed with the term) / (late-window mean speed without it, same seed)`, at
`FRICTION_MIN` (retention 1), on a self-attracting world that settles above the onset. The late window
is the mean of frames 749, 799, 849 and 899.

- **Why friction 0.** There a world without the term keeps moving at 1.28–1.32 across 8 seeds, so the
  denominator is well conditioned. At shipped friction it is 0.000–0.005, and no ratio to it is
  (design notes, batch H).
- **Why the bound is no longer 1.** At friction 0 nothing removes energy but the soft cap, so
  `L ≤ 1` meant "the term does not heat the settle". The user chose `K = 540` at 128 000 particles
  knowing it reads L 1.163–1.175 there (D13, 14-09-26): friction-0 settles run about 17% warmer, an
  accepted cost. A bound of 1 would fail the chosen arm on every seed, so it no longer states the
  decision. The bound now holds the accepted warmth and no more: `B_L`, the chosen arm's own L
  measured at 128 000 particles, with its margin (below).
- **It can fail, and was run failing.** Across 8 seeds at 16 000: square `K = 54`, L = 0.963 (sd
  0.0068); Tait `K = 54`, L = 1.221 (sd 0.0257). Across 3 seeds: square 173 → 0.984, 540 → 1.036,
  1728 → 1.117, 5400 → 1.249; Tait 5.4 → 1.012, 17 → 1.078 (batch H). L rises monotonically with `K`
  for the square law. At 128 000 particles, 3 seeds (batch M): `K = 540` → 1.163–1.175; `K = 1728`
  with viscosity → 1.220–1.261; `K = 1728` without viscosity → 1.360–1.393 (one-sided lower bound
  1.347); Tait `K = 54` → 1.525–1.605 (lower bound 1.500) (batch R). Both lie past `B_L ≈ 1.177`.

**`K` and the bound `B_L` (critique N-M2).** `K = 540` is the user's choice among measured arms (D13),
not a value this design sets. Task 1.3 confirms it on 16 calibration seeds at 128 000 particles and
derives the bound gate 7 holds from the same runs:

`B_L = mean_cal(L at K) + t_{0.95, n_cal + n_held − 2} · s · √(1/n_cal + 1/n_held)`

- `s` is the sample standard deviation of per-seed L at `K` on the calibration seeds.
- `t` is the one-sided Student-t quantile at the pooled degrees of freedom for `α = 5%` (the lead's
  answer, 13-09-26).

If the held-out seeds come from the same distribution, their mean passes `B_L` with probability at
most about `α`. Provisional, from batch M's 3 seeds with 16 held-out seeds: mean 1.170, `s` 0.0062,
`t` 1.740 at 17 degrees of freedom, margin 0.007, **`B_L ≈ 1.177`** (python; design notes). Task 1.3
replaces it.

**The margin, stated once for every gate.** A gate whose bound is derived from calibration runs (gate
7's `B_L`) takes `B = mean_cal + t_{0.95, df} · s · √(1/n_cal + 1/n_held)` and passes when
`mean_held ≤ B`. A gate that holds a relation against a fixed bound `B` with no derived constant passes
when `mean_held ≤ B + t_{0.95, df} · s / √n_held`. `s` is the sample standard deviation per seed recorded
beside the gate from its calibration runs, and `df` the pooled degrees of freedom. Each gate in D10
names its bound, its side and `α = 5%`.

The first form, "the settled mean speed lies within the no-term spread", stays withdrawn (batch F).
The number 54 in the probes is a probe setting, not this derivation, which task 1.3 runs.

**At the shipped friction the square law alone adds a simmer that no `K` removes.** Self-attracting
clumps above the onset keep moving at 0.05–0.10 per reference frame at every square `K` probed,
against 0.000–0.005 without the term; Tait `K = 54` reads 0.025–0.040. Mixed 12-species worlds are
identical to no term (batch H). A per-pair quantum of 0.0005, the fine quantum times frame factor 30,
left it unchanged, and so did dropping the smoothing (0.033–0.055). A pair viscosity of 0.5 removed it
at `K = 54` (batch K) but not at `K = 540` (batch N), and the user rejected it (D4, D13). At 128 000
particles and the chosen `K = 540` the simmer reads 0.028–0.115 against 0.000–0.003 without the term
(batch M), a cost the user accepted. No statistic at shipped friction is conditioned enough to derive
`K` from, so this criterion does not gate the simmer; task 6.1 observes it in-app.

**At 16 000 particles the criterion and relaxation do not share a `K`** (design notes, batches H, J,
L; 3 seeds each; onset `x = 7`):

| Law | L at friction 0 | After-release neighbours over fresh settle |
|---|---|---|
| square `K = 173` | 0.984 | 1.096–1.106 |
| square `K = 540` | 1.036 | 1.018–1.037 |
| square `K = 1728` | 1.117 | 0.968–0.991 |
| square `K = 540`, viscosity 0.5 | 0.956–0.970 | 1.075–1.106 |
| square `K = 1728`, viscosity 0.5 | 1.048–1.089 | 0.972–0.995 |

The user asked for the trade to be measured at 128 000 particles before choosing (13-09-26). D13
records that run and the user's choice: `K = 540` without viscosity, which relaxes fully there (after
over fresh 0.971–0.976) and warms friction-0 settles about 17% (L 1.163–1.175).

**Why a stability derivation alone does not serve.** A pressure read through a smoothed, one-frame
lagged density is linearly stable only for a gain below a limit set by the smoothing and the velocity
retention: 0.018 per frame at smoothing 0.7 and retention 0.95, 0.65 at retention 0.5, and zero at
retention 1, which is friction 0 (`FRICTION_MIN`) (design notes, stability table; a linear model, not
measured against the app). At friction 0 every fixed stiffness is linearly unstable, and only the soft
speed cap bounds the motion. In the small probe world at friction 0 the settle ran at mean speed 4.5
with `K = 54` against 3.9 without the term (batch D); at 16 000 particles it ran cooler than without
the term up to `K = 173` (batch H). The settle criterion above is measured, so it holds where the
linear bound is zero; what it permits at friction 0 is the shimmer D14 accepts, bounded on average by
`B_L`, about 17% above the no-term world's own motion at 128 000 particles.

### D6. What the fixed pressure holds, and the column it cannot

**The input.** The bound in Context. It is designed, not built: today's code still holds at full
strength past the band (`tests/test_body_core.nim:358`).

**The demand is a column.** A body pushes every particle inside its shell, and the held crowd carries
the weight of every particle pushed toward it. For a constant inward push `F` on every particle of a
disc of mass `M` at number density `n`, `dP/dr = −nF`, so the pressure at the centre is
`F · √(M · n / π)` (critique M3 corrected the first draft's factor 2). The virial pressure of a pair
push `p(1 − r/R)` in 2D is `3ρ²p / (8πR)`, so the contact push that answers it is
`p = 8F√(3M) / (3ρ^1.5)`: 15.8 per pair per reference frame in the small probe world, where
`K = 1728` supplied about 23 and held; and 138 at 128 000 particles with 32 stacked bodies at crowd
density 250. D16's smoothstep bump pushes weakly near the surface where the crowd gathers, so this
uniform-push figure overstates D16's demand (critique M3); the app-scale probe measures the real one.

**Measured at app scale** (128 000 particles, radius 50, 12 species, seed 42, 32 aligned D16 bodies at
the ceilings, D16 bump law, onset 120 and 270 in `ρ`, design notes):

| Pressure | Held crowd peak (p99) | Largest pressure delta per particle, per reference frame | Far crowds' mean speed | After removal |
|---|---|---|---|---|
| None | 6 305 (5 238) by frame 24 of the hold, and still collapsing | 0 | 0.27 | not reached (the neighbour count stalled the run) |
| Square, `K = 54`, onset 120 | 602–629 (523–579) | 4 103 | 0.27–0.30 | 132–139 within 50 frames |
| Square, `K = 54`, gate | 383–505 (341–446), 394 once settled into the hold | 1 526 | 0.27–0.30 | 111–129 |
| Square, `K = 54`, onset 270 | 894–935 (780–846), frames 24–99 of the hold | 2 275 | 0.27–0.28 | unmeasured (run unfinished) |
| Barrier `t²/(1 − t)`, saturation 1 000, `K = 54`, onset 270 | 812–875 (683–756), frames 24–124 | **481 635** | 0.27–0.29 | unmeasured (run unfinished) |
| Square, `K = 540`, onset 270 | 638 (552) at frame 24 | 2 676 | 0.27 | unmeasured (run unfinished) |
| Square, `K = 1728`, onset 270 | 589 (502) at frame 24 | 6 527 | 0.27 | unmeasured (run unfinished) |

**Capacity (critique M2).** The pressure's capacity at crowd density `x` is the column pressure the
fixed law supplies there: the 2D virial pressure `3ρ²p / (8πR)` at `ρ = x ρ̄` with the contact push
per pair `p = min(2K · φ(x) / 120, q_max)` velocity per reference frame, so below saturation
`C(x) = 3 (x ρ̄)² · K · φ(x) / (480 · 3.14159… · R)`, with `φ` the pressure function of D4 and the
constant written out. A compressor's demand is the column pressure `F · √(M n / π)` it builds, with `F` its push per
particle in the same unit, `M` the particles it reaches and `n` their number density. D10 test 9
reports, for each compressor at its range maximum, the relative density `x*` at which capacity meets
demand. Under the relative ceiling that figure is a report, not a gate (D10).

A fixed pressure turns the collapse into a finite held crowd that stays where the bodies are and
relaxes after (measured at onset 120). Raising the stiffness 32× lowered the held peak from 894 to 589
at the same frame, still past 2× the onset of 270, while the pressure delta rose to 6 527 per particle
per reference frame. No stiffness in the probed range holds the stacked column within 2× the onset.
The held world runs at mean speed 16–19 in every row, so the balance is dynamic, not the static one
the capacity formula describes.

**The decision: a strong hold compresses a finite, local crowd (the user's decision, 13-09-26).**
Under strong stacked bodies the held crowd compresses past the onset, stays finite, stays where the
bodies are, relaxes after release, and costs more while held: mean weighted neighbours 245 against 41
settled in the probe. In-app, whole-world compression under Hold 10 raised GPU physics from 0.99 to
101.89 ms while the bodies slot stayed at 0.07 ms (`scratchpad/parametric-bodies/in-app__13-09-26-1616.md`,
observations 1 and 3); the pair pass's share of that is not isolated, and the cost of a finite held
crowd under this change is unmeasured (task 6.1 records it and does not gate on the allotment). The options not taken, and
what each would have cost:

| Option | What it would have cost | Verdict |
|---|---|---|
| **Accept a finite, local held crowd** | Held crowds pass the onset while held; the pair pass costs more for as long as the hold lasts | **Chosen** |
| Density gate on outside pushes and own attraction | A new behaviour: a dense crowd stops answering bodies, long range, tropism and the mouse. Bought 35% lower held peak (394 against 608), still past 2× the onset | Rejected |
| Higher fixed stiffness | 32× the stiffness bought a third lower peak; warmed a self-attracting settle with no body present (mean speed 0.47 against 0.26 at frame 199) and multiplied the pressure delta the accumulator must hold (2 275 → 6 527) | Rejected |
| Implicit density projection | A hard ceiling, at one extra neighbour sweep per iteration while any crowd sits above the onset, against performance as the top priority | Rejected |

**The ceiling is relative (the user's decision, 13-09-26).** No absolute crowd-density or cost
ceiling is imposed. The onset is measured in the world's own mean crowd density, floored by the
discrete-contact density (D3). Batch G measured mixed settles from 100 to 128 000 particles and radius
10 to 150 (3 seeds, 600 frames), and each keeps its settled look under an onset placed above its
peak; D3 records where the placement trims one. A configuration whose settle is dense costs what that
settle costs: a 128 000-particle world at radius 150 sits at `ρ̄ = 364` with nothing acting, and no
term pushes it apart. The pair pass's allotment bounds the cost the term adds to a settled world at
`MAX_PARTICLES` (Context, tasks 1.5, 6.2), not dense configurations and not held crowds.

Asking `parametric-bodies` to saturate the per-particle push is not an option this design takes: the
body push stays uncapped (the lead's answer, 13-09-26).

**Finite at every setting (critique N-M4).** Every push is bounded per particle and
`N ≤ MAX_PARTICLES`. Below `q_max` the contact push grows with the square of the excess. Past `q_max`
the per-pair push is constant, but the virial pressure `3ρ² · q_max / (8πR)` still grows with the
square of the density, because the number of pairs does. So a static balance exists at a finite
density on either side of the saturation. That argument is static; the held world is dynamic, so the
held peak is checked by the stepped gate (D10 test 5) against the stiffness-zero control, not by the
argument.

**A finding for `parametric-bodies`, outside this change.** Under 32 stacked bodies the whole-world
mean speed ran 16–17 at app scale with or without pressure, and in the small world 23.2–25.2 without
pressure and 29.7–31.3 with `K = 1728` (critique M12). The soft cap's threshold is 25
(`integrate.wgsl:92`, shipped `maxVelocity` 50). A stacked hold without pressure runs at the
threshold, and pressure pushes it above. Nothing in either change bounds a hold's heat.

### D7. Presets: a conversion, then the clamp decides

`CURRENT_SCHEMA_VERSION` 4 → 5 with a `fromVersion < 5` branch that multiplies the long-range
strength by `cellArea(savedGridIndex) / U(savedInteractionRadius)`, with
`U(R) = u0 · R² · (a + R) / a²` (D2), the grid index and radius read from the preset itself and `a`
from the build's recorded `x_on`, before `validateSettings` clamps. Zero stays exactly zero. At
`x_on = 6.3` (`a = 647.4`) the factor runs from 177.4 (512 × 256, radius 150) to 193 645 (256 × 128,
radius 10), and is 1 825 at the shipped mesh and radius 50 (python; under the second draft's `u0 · R`
it ran 50.6 to 3 037.5). The conversion keeps the saved world's pull exactly at its saved radius.
Where the converted strength exceeds the derived `LONG_RANGE_STRENGTH_MAX` the clamp decides: the pull
the saved world had is kept only below the new ceiling. With a factor above 1 000 at small radii, a
saved small-radius world at any appreciable strength is likely to clamp; how often is unknown, because
no saved long-range world is on file (below). The alternative, loading the old number unconverted,
changes every saved long-range world by that factor and was rejected.

Two consequences of the chosen unit reach presets and help:

- **After loading, the radius moves long range.** A converted world keeps its pull at its saved radius;
  if the player then moves the radius slider, long range's pull at the same strength grows about as
  `R²` (D2), where under today's unit it did not move with the radius. The long-range help line says
  so (task 5.2): at a fixed strength, a larger interaction radius strengthens the long-range pull
  about as its square.
- **`x_on` is part of the long-range unit.** `a` comes from `x_on`, so re-deriving `x_on` later changes
  every saved and live long-range pull at a fixed strength by `a_old² (a_new + R) / (a_new² (a_old + R))`.
  A later change to `x_on` therefore needs its own schema bump and conversion. `src/preset.nim` records
  the `x_on` the current schema's long-range unit was defined at, and a static assertion holds it
  equal to the live onset constant, so changing `x_on` fails the build until a new version branch
  converts (build-asserted). Catches: an onset re-derived with no conversion.

Nothing shipped carries a non-zero long-range strength: the default is 0.0
(`src/preset.nim:276`) and the repo ships no preset files. Presets in a player's localStorage are
unknown, and the conversion covers them.

`long-range-mesh`'s spec says "no schema version and no migration branch is added"
(`openspec/changes/long-range-mesh/specs/long-range-coupling/spec.md:300,309`), and its
parameter-range-authority delta states the provisional ceiling. This change lands first and amends
both in the same pass as the conversion (tasks 3.4).

### D8. Every velocity impulse accumulates per reference frame, in a fine word and a coarse word

**The relation (critique B4).** Each per-pair integer and each particle's final sum must fit its
word. In WGSL concrete `i32` arithmetic wraps modulo 2^32, and a float-to-integer conversion clamps
to the target's range and then rounds toward zero (https://www.w3.org/TR/WGSL/, "Integer Types" and
"Floating Point Conversion"). So the bound is on each conversion and on the final sum, and
intermediate wraps are exact. It is a full-crowd bound, as the body accumulator's is
(`src/body_core.nim:262-269`): `MAX_PARTICLES` contributions, each at its maximum.

**Who writes the word, and when.** Five shaders write `velocityDeltaFixed`: `forces.wgsl`,
`forces-sph.wgsl`, `body-force.wgsl`, `field-force.wgsl` and `lr-force.wgsl` (grep). The frame
clears it once per substep before any writer runs (`src/sim_registry.nim:355-356`). One "Physics"
node dispatches `forces` and then, when the fluid acts, `forcesSph` (`src/sim_registry.nim:389-395`).
The executor repeats the whole description once per substep (`src/webgpu_compute.nim:1243-1276`), so
the pair force and SPH add into the same word in the same substep before integrate reads it. Each
writer multiplies by the substep today: the pair force by `params.dt` (`forces.wgsl:297,377`), SPH by
`params.dt` and `frameFactor` (`forces-sph.wgsl:277-280`), and the others by the frame factor
(`src/webgpu_compute.nim:1066,1098,1126`). `integrate.wgsl:55-58` decodes the word at 2^16.

**The word fails the bound today (this change owns it: the lead's answer, 13-09-26).** Per reference
frame, and times the largest frame factor 30 (`src/body_core.nim:139-148`) where the writer
multiplies by the substep:

| Writer | Per-contribution maximum per reference frame | Contributions per particle | Full crowd times 2^16, at frame factor 1 | Source |
|---|---|---|---|---|
| Pair force | `FORCE_STRENGTH_MAX 5 · 1.66 / 120 = 0.0692`. 1.66 is the exponential model at contact with the matrix minimum, `1 + 2 · MATRIX_MAX_VALUE`; the polynomial model peaks at `max(1, 4 · MATRIX_MAX_VALUE) = 1.32` (critique N-M5) | `MAX_PARTICLES` | 5.80 × 10⁸ (fits; 1.74 × 10¹⁰ at frame factor 30, which does not) | `physics_core.nim:397-430`, `config_ranges.nim:43,129,201-204` |
| Mouse, in the pair force's own register | `300 / 120 = 2.5` | 1 | 1.64 × 10⁵ | `forces.wgsl:344` |
| Blast, in the same register | `3000 · blastStrength / 120 = 25`, strength at most 1 | 1 | 1.64 × 10⁶ | `forces.wgsl:368`; `control_matrix.nim:463` clamps it, the pointer handlers pass 1.0 |
| SPH | pressure `SPH_MAX_PRESSURE_ACCEL 5000 · FLUID_STRENGTH_MAX 1 / 120 = 41.7`, plus the velocity blend `(SPH_VISCOSITY_MAX 1 + SPH_XSPH_EPSILON 0.5) · 2 · MAX_VELOCITY_MAX 100 = 300` | `MAX_PARTICLES` | **2.87 × 10¹², 1 335× the span** (the pressure clamp alone is 163×, critique N-B1) | `sph_core.nim:29,48`, `config_ranges.nim:58,196,262`, `forces-sph.wgsl:254,277-289` |
| Bodies | `MAX_BODIES 32 · BODY_FORCE_CEILING 10 = 320` | 1 | 2.10 × 10⁷ | `body_core.nim:262-269` |
| Field force, long range | not yet derived: `field-force.wgsl:76` is `gradient · fieldForceScale · tropism` with no stated gradient bound; `long_range_core.nim:238` bounds the deposit, not the force | 1 | recorded by task 2.3 | |

The SPH clamp "bounds one interaction but not the number of them" (`forces-sph.wgsl:86`). Nothing
asserts any of this, and the `fixed_point.wgsl` header's "far more range than a per-frame impulse ever
needs" is false. No user range is narrowed to fit.

| Remedy | What it costs | Verdict |
|---|---|---|
| Narrow `FORCE_STRENGTH_MAX`, `FLUID_STRENGTH_MAX`, `SPH_MAX_PRESSURE_ACCEL` or the largest substep | User ranges clamped to fit an implementation limit, and SPH would still need a factor of 1 335 | Rejected (fix the mechanism, never the ceiling) |
| A neighbour cap in the SPH loop | A dense crowd's fluid would stop counting neighbours past the cap in sorted order: an order-dependent, anisotropic fluid, a limit players would see, and no source states the cap | Rejected |
| One coarser scale for the whole word, as the SPH density word derives its own (`sph_core.nim:195-215`) | SPH alone needs 2^16 / 1 335, a scale of 2^5: a quantum of 1/32 velocity per contribution at every frame length, for every writer | Rejected |
| A word per writer at 2^16 | SPH's own word is still 1 335× over | Rejected |
| SPH as a gather (full neighbour stencil, each particle writes only its own slot, as a float) | Doubles SPH's pair evaluations (the loop is half-neighbour, `forces.wgsl:192-195`); the pressure's scatter still needs a bound | Rejected on performance |
| **Accumulate per reference frame; split each SPH and pressure integer across a fine word and a coarse word** | One more 8-byte word pair per particle (1 MB at `MAX_PARTICLES`); one more atomic add per pair in SPH and one in the pressure, for their coarse parts; `forces.wgsl` reaches 8 storage bindings, the WebGPU default `maxStorageBuffersPerShaderStage` (https://www.w3.org/TR/webgpu/, limits table), which `webgpu_init.nim:351-358` does not raise; integrate decodes two words; the velocity quantum grows with the frame factor (D8 below, N-M10) | **Chosen** |

**The convention.** Every writer accumulates its impulse per reference frame, with no substep
multiply. Integrate multiplies the decoded delta by the frame factor once, carried in an
`IntegrationParams` pad slot (`integrate.wgsl:25-34`). This removes the frame factor from every bound.

**The split.** The existing word stays the fine word at 2^16. A new coarse word counts in units of
2^k fine quanta. A writer whose full crowd does not fit the fine word forms each contribution as one
signed integer per component, `q`, and adds `q >> k` to the coarse word and `q & (2^k − 1)` to the
fine word. For a signed `i32`, `>>` inserts copies of the sign bit (WGSL, "Bit Expressions"), so
`(q >> k) · 2^k + (q & (2^k − 1)) = q` exactly. The coarse part carries the magnitude, and every fine
part lies in `[0, 2^k)`. Integrate decodes `f32(coarse) · 2^k / 2^16 + f32(fine) / 2^16`. Where the
coarse word is zero, which it is with the fluid off and every crowd below the onset, the decode is
today's expression on today's fine word. The pair force keeps its single fine contribution, which
fits, so its hot path gains no atomic add. The pressure's fine part joins the pair force's integer in
the same atomic add. SPH and the pressure are the two split writers. On the "this" side, which sums in
a float register and converts once (`forces.wgsl:282-300`, `forces-sph.wgsl:304-305`), the register is
split by `coarse = floor(sum / 2^k)` and `fine = sum − coarse · 2^k`, so each side of a split writer
adds one fine part per particle, not one per pair; the register's float precision at large sums is
today's.

**The derived constants.** No constant here is hand-set. Each follows from the table above.

- `k` is the largest value at which the fine word's full-crowd sum fits: the pair force, plus
  `2 · MAX_PARTICLES · (2^k − 1)` for the two split writers' fine parts, plus the one-slot writers.
  At `k = 12` that is 1.651 × 10⁹, headroom 1.30, leaving 7 571 velocity per reference frame for the
  field force and long range. At `k = 13` it is 2.70 × 10⁹ and does not fit (design notes, second
  critique, python). Task 2.3 fixes `k` once the field-force and long-range maxima are recorded. If
  they need more than 7 571, `k` falls to 11.
- The coarse word holds SPH's `⌈341.7 · 2^16 / 2^k⌉ = 5 467` coarse units per contribution at
  `k = 12`. That leaves `⌊(2^31 − 1)/MAX_PARTICLES⌋ − 5 467 = 11 310` for the pressure term.
  The coarse word therefore carries no headroom by construction: `MAX_PARTICLES · (5 467 + 11 310) =
  2 147 456 000` against `2^31 − 1 = 2 147 483 647`, a margin of 27 647 (0.0013%), against the fine
  word's 1.30×. Any new coarse writer, or a raised SPH bound, fails the coarse assertion until `k` or
  `q_max` is derived again.
- The pressure's per-pair saturation `q_max` is that remainder, 11 310 coarse units: 706.9 velocity per
  reference frame per pair at `k = 12` (python; the rejected viscosity's 1 600 units no longer come
  out of it). It is applied to the pair's magnitude before the per-component integers are
  formed, so saturation keeps the direction. It is the words' capability, not a user range, and it
  stands above the 138 the uniform column estimate asks for (D6).

The first draft's pressure word with its own coarse scale `S_p` is withdrawn. The pressure now keeps
the fine word's resolution, so batch E's quantization calibration and the critic's quantum at frame
factor 30 (N-M9) no longer set anything. A per-pair quantum of 0.0005 velocity per reference frame,
the fine quantum times 30, left the self-attracting settle's late speed at 0.060–0.082 against
0.053–0.083 unquantized (design notes, second critique, batch K).

**The assertions** (bottom of `src/config_ranges.nim`): the fine word's full-crowd sum over every
writer `< 2^31 − 1`, and the coarse word's `MAX_PARTICLES · (SPH coarse maximum + q_max coarse) < 2^31 − 1`. Each term names its constant, so raising `MATRIX_MAX_VALUE`, `MAX_VELOCITY_MAX` or any
writer's maximum moves the sum (critique N-M5).

**Cost.** One word pair per particle, two atomic adds per pair in SPH and in the pressure (the
pressure's only above the onset if the shader branches; which is cheaper is measured, not assumed),
and one decode and one multiply per particle in integrate. All of it is unmeasured; task 1.5 measures
it.

### D9. Classification: part of the pair law, and crowding stays a look control

| Classification | Sacrifice | Verdict |
|---|---|---|
| A new coupling strength | At zero the collapse returns, so zero would be the broken world a slider reaches | Rejected |
| An extension of crowding | Crowding ships at 0 and its zero must be the old law; a pressure that vanishes at crowding 0 bounds nothing in the shipped world | Rejected |
| **Part of the pair law, world-intrinsic, no slider** | See D11 for force strength 0 | **Chosen** |

The onset is not a mode: it is a zero of a continuous function, as `max(·, 0)` in the density
ceiling already is, and `test_no_modes` sweeps identifiers and mode strings (`tests/test_no_modes.nim`)
of which this adds neither. The term is the same expression at every setting.

Crowding stays a look control (the user's decision). The pressure bounds collapse; crowding shapes
clump texture. Its help line says so (task 5.2), and `calibrate-shipped-defaults` calibrates it by
`c_soften` alone (D12).

### D10. Red tests first, each able to fail

**Seeds.** Every number derived from a run (`x_on`, `K`) is derived on a recorded set of calibration
seeds. Every gate that checks behaviour runs a disjoint recorded set of held-out seeds. No margin is
fitted to a gate (critique B2). Where a gate compares a mean over seeds with a bound, its margin is
the one D5 states once, from the statistic's own per-seed spread at a false-fail rate `α = 5%` (the
lead's answer, 13-09-26; critique N-M2). The seed count stays at 16 held-out seeds.

**Size (critique N-M3).** Gates 5–7 run the binned oracle world at 16 000 particles and radius 50, not
at `MAX_PARTICLES`: on one core a 128 000-particle frame took 0.31 s (the critic's run), and a
16 000-particle seed of gates 5–7 takes about 72 s, with the stiffness-zero control, bounded to 100
held frames, about 52 s once per suite (design notes, gate sizing). At 16 held-out seeds that is about
20 minutes on one core. **Gates 5–7 run in a separate recipe, `just calibrate-balance`, that `just
check` does not call** (the lead's answer, 13-09-26); it carries every 16 000-particle arm, the
frame-factor arms included. **The 128 000-particle checks run in a second, slower recipe,
`just calibrate-balance-128k`, that neither `just check` nor `just calibrate-balance` calls** (the
lead's answers, 14-09-26). It carries three parts, costed from batch M's 900-step run at 1 171–1 275 s
on one core (about 1.3 s per step):

| Part | Runs | Core-hours |
|---|---|---|
| Re-deriving `B_L` on the 16 calibration seeds (task 1.3's run), with and without the term | 32 × 900 steps | about 10.7 |
| Gate 7's friction-0 check on the 16 held-out seeds, with and without the term | 32 × 900 steps | about 10.7 |
| Gate 6's 128 000-particle relaxation arm on the 16 held-out seeds, fresh settle and stacked hold | 32 × 1 600 steps | about 18.5 |
| **Total per run of the recipe** | | **about 40** |

The relaxation arm uses the fixed bound 1, so it needs no calibration run. **The rerun trigger**: the
recipe runs when the term lands and again on a change to `K`, the pressure law, the onset, the fine/coarse word split (`k`, `q_max`), or the crowd-density computation's dependence on particle count (`ρ̄`, the floor, the smoothing). Each of these can move relaxation or warmth at
128 000 particles without moving them at 16 000. `just calibrate-balance` re-derives `B_r` on the same
trigger. The task that lands the term runs both recipes green (task 4.3), and `docs/enforcement.md`
records both at the same tier: held by a recipe run at change time, not by every check, with the
trigger itself unenforced (task 5.2). Every other test here runs in `just check`. The 128 000-particle
hold with long range at its maximum is observed in-app (task 6.1), not gated.

**Oracles before tests (critique N-M9).** No encode or decode oracle for the velocity word exists
today (`grep FIXED_POINT_SCALE src/physics_core.nim` finds nothing). Task 2.3 first writes today's
convention as oracles, each writer's encode with its substep multiply and integrate's single-word
decode, so the red steps of tests 4b and 11 are wrong values, not compile errors.

1. `tests/test_long_range_core.nim`, "The Pull Does Not Depend On Mesh Size": the impulse sampled 240
   and 600 from the clump centre agrees across `LR_GRID_SIZES` within the mesh-to-mesh gap the static
   solve measures under the new unit, recorded beside the test (critique K3). Today's ratios 4.006 and
   4.004 against the exact cell-area ratio of 4 put that gap at 0.15% at 240 and 0.10% at 600; the
   solve is deterministic, so it carries no sampling margin. Catches: `cellArea` left in the scale
   (a 300% gap), or a grid-dependent factor anywhere in the kernel above 0.15%.
2. `tests/test_long_range_core.nim`, "The Pull Is The Pair Unit Spread By The Green's Function": at
   `LONG_RANGE_REACH_MAX` (4000), 240 from the centre of a clump, the sampled impulse equals
   `s · A · U(R) · M/(2πr)` within the formula gap the static solve measured there, 0.7%, at radii 10,
   50 and 150. At reach 600 screening alone opens a 12.4% gap, so the test runs at the reach where the
   unscreened formula is the right oracle. Catches: `cellArea` in place of `U(R)` (1 825× at shipped
   settings), the second draft's `u0 · R` (off by `R(a + R)/a²`, 0.083 at radius 50), `a + R`
   dropped (off by 1.21 at radius 150), a `2π` slip.
   2b. Same file, "One Long-Range Ceiling Holds At Every Radius": `LONG_RANGE_STRENGTH_MAX`'s
   derivation, evaluated at radii 10, 50 and 150, returns the same strength within float tolerance.
   Catches: a unit whose ceiling still moves with the radius (the second draft's 18.4×, the slipped
   form's 1.47×).
3. `tests/test_physics.nim`, "Pressure Past The Onset" (critique N-M4): the pressure oracle's float
   magnitude is zero at and below the onset, strictly increasing above it up to `q_max`, and constant
   past it; each per-component integer is zero at and below the onset and non-decreasing in magnitude
   along a ray of increasing density; the two particles receive exactly opposite integers; the result
   is unchanged by force strength, matrix entry, crowding, friction and the pair's relative velocity.
   Catches: pressure scaled by
   `fMul` (D11) or by friction (D14), a sign flip, a law with a step in value at the onset (non-zero
   just past it; Tait's step in slope is gate 7's), a per-side quantization that
   breaks the symmetry, a saturation applied per component (the direction turns). Fails to compile
   today.
4. `tests/test_physics.nim`, "The Force Law Is Untouched Below The Onset": at force strengths 0.7, 1
   and `FORCE_STRENGTH_MAX`, at frame factor 1, the velocity delta of a settled world below the onset
   is bit-identical with and without the term compiled in, both under the reference-frame convention.
   Catches: the first draft's regrouping (35 207 of 100 000 products differ at 0.7), a `−0.0` leaking
   into the force register, pressure integers routed into the fine word below the onset.
   4b. Same file, "Today's Low Bits Move By Less Than The Frame Factor" (critique N-M10): at frame
   factors 1, 2 and 30, each contribution's decoded delta under the new convention differs from the
   today-convention oracle's by less than `max(1, ff)` quanta, and by zero at frame factor 1.
   Catches: the frame factor applied twice or not at all (a difference of about `ff · x`), a writer's
   substep multiply left in place.
Gates 5, 6 and 7 are one-sided at `α = 5%` with the D5 margin. They run in `just calibrate-balance`,
except gate 7's friction-0 check, which runs in `just calibrate-balance-128k`.

5. `tests/test_balance_core.nim`, "A Compressed Crowd Stays Local And Below Its Collapse": on the
   held-out seeds, 32 aligned D16 bodies at the ceilings hold the 16 000-particle binned world for 100
   frames. The held crowd's peak stays below the stiffness-zero control's at the same held frame, and
   the mean over seeds of far-crowd mean speed exceeds a no-body run of the same seeds by no more than
   the D5 margin (one-sided, `α = 5%`). Measured: the pressured peak was 95–171, the control 1 558–6 116 within 100 held frames
   (batches I-b, J). "Finite" alone could not fail short of NaN (the critic's table), so the control
   comparison replaces it. Catches: a term that vanishes above some density, a pressure too weak to
   bound the column, a live stiffness (far crowds heat), a pressure that reads a coupling's strength.
   The oracle world models bodies alone, so the spec's local-collapse SHALL is narrowed to the bodies;
   the same hold with long range, the field force and the mouse at their maxima is a SHOULD, unenforced
   by a suite, and task 6.1 observes it in-app with long range (third critique, F4).
6. `tests/test_balance_core.nim`, "Compression Is Not Remembered": on the held-out seeds, per seed, the
   weighted neighbour count 900 frames after the bodies go is divided by a fresh settle's at the same
   frame count, one self-attracting species, one-sided at `α = 5%`, because a remembered compression
   reads above 1. The chosen `K = 540` relaxes fully at 128 000 particles (0.971–0.976, batch M) and
   reads 1.000–1.014 at 16 000 with onset `x = 6.3` (batch R, 3 seeds; neighbours logged to 0.1). A
   bound of 1 at 16 000 would fail the chosen arm about as often as not. The gate runs at 16 000
   particles (the lead's answer, 14-09-26): `B_r` is derived like `B_L` from the chosen arm's ratio on
   the calibration seeds plus the D5 margin at `α = 5%` (task 1.3), and the gate passes when
   `mean_held(r) ≤ B_r`, in `just calibrate-balance`. A second arm at 128 000 particles, where the
   chosen arm relaxes below 1, holds `mean_held(r) ≤ 1 + t · s_r / √n_held` in
   `just calibrate-balance-128k`, about 18.5 core-hours for 16 seeds (two 1 600-step runs per seed at
   about 1.3 s per step; an earlier revision's 21 overstated it). The 16 000-particle arm does not stand
   in for it: the two counts sit on opposite sides of 1, and a fault in `ρ̄` or the floor, which scale
   with the particle count, need not show at 16 000. It reruns on the D10 rerun trigger. Measured
   falsifiers at 16 000, 3 seeds: 1.16–1.19 at `K = 54`, 1.10 at 173 (onset `x = 7`, batches I-b, J,
   L). Mixed worlds are not gated here: under the
   chosen onset they keep what a hold merged (D3). Catches: a pressure too weak to separate a
   self-attracting clump (today 1 499 against 502 in the small world), a hysteresis in the term.
7. `tests/test_balance_core.nim`, "A Settling World Still Settles" (critique N-B3, N-M7). Two checks.
   - **Friction 0, at 128 000 particles, at frame factor 1.** On the held-out seeds, a self-attracting world at
     `FRICTION_MIN` settles with `mean_held(L) ≤ B_L`, where `B_L` is the chosen `K`'s L on the
     calibration seeds plus the D5 margin (provisional 1.177, from batch M; task 1.3 derives it). It
     runs at 128 000 because that is where the user accepted the cost: at 16 000 the same `K` reads
     1.036 (batch H), so a 128 000-particle bound there would pass stiffnesses well above the chosen
     one. Measured falsifiers at 128 000: `K = 1728` with viscosity 1.220–1.261 (batch M); `K = 1728`
     without viscosity 1.360–1.393 and Tait `K = 54` 1.525–1.605 (batch R, 3 seeds), each past
     `B_L`. Catches: a stiffness above the chosen one, a law
     with a step at the onset. This check holds the spec's friction-0 scenario. Cost: a 900-step
     128 000-particle run took 1 171–1 275 s on one core with 3–6 others busy (batch M, seed 1001), so
     32 runs (16 held-out seeds, with and without the term) are about 10.7 core-hours; batch M's 33
     longer runs took 4 h 33 min on 18 cores. It runs in `just calibrate-balance-128k` (the lead's
     answer, 14-09-26) on the D10 rerun trigger. It runs at frame factor 1, where accumulating per
     step and per reference frame coincide, so it cannot catch a writer left accumulating per step;
     the frame-factor arms below and tests 4b and 11 catch that.
   - **Frame factors, at shipped friction and 16 000 particles.** Arms at frame factors 1, 2, 10 and 30
     through the substep rule (D15), and two jittered arms: a frame factor drawn per rendered frame
     uniformly from 8 to 16, and one alternating 10 and 13 (D15); at each the late-window mean speed
     per reference frame is no warmer than at frame factor 1, one-sided at `α = 5%`. These arms, not
     the 128 000-particle check, catch a writer that accumulates per step: at frame factors past 1 its
     impulse is off by the frame factor. Measured falsifier: `K = 1728`
     with viscosity and no substeps reads 2.13× the shipped frame at 10 and 2.01× at 30 (batch P). At
     the chosen `K = 540` without substeps frame factor 30 read 1.25× on 3 seeds with a one-sided
     lower bound of −0.002 (batches N, Q), borderline; on 8 seeds it reads 1.33× with lower bound 0.022
     and fails, while through 3 substeps of 10 it reads 0.91× and passes (batch S, D15). The uniform
     8–16 arm without substeps reads 1.18× with lower bound 0.0035 and fails; with them it reads 0.59×
     (batch T). Catches: a missing substep trigger, a per-step accumulation, `ff_stable` recorded above its measurement, a substep that advances `ff` rather
     than `ff / n`.
8. `tests/test_preset.nim`: a version-4 long-range preset decodes to the converted strength, then the
   clamp. Catches: no branch (decodes unconverted), a factor inverted, zero not kept zero.
9. `tests/test_response_probe.nim`, "Couplings Are Compared On One Scale" (critique N-M8): each
   response probe's impulse at its range maximum, in `u0` at the reference configuration, agrees with
   a one-frame stepped measurement of that compressor in the binned oracle world: the velocity change
   one step hands a probe particle. It is not compared with the oracle the probe calls. Catches: a
   probe still reporting in mesh cells, a probe sampled at a different configuration, a probe that
   calls the right oracle with the wrong neighbour sum. Under the relative ceiling the suite also
   reports each compressor's `x*` (D6) and asserts nothing about it: `x*` is finite by the law's form,
   so an assertion there could not fail (critique B2).
10. The static assertions in `src/config_ranges.nim` for D8: the fine word's summed full-crowd bound
    over every writer and the coarse word's. Each term names its constants (`FORCE_STRENGTH_MAX`,
    `MATRIX_MAX_VALUE`, `MAX_PARTICLES`, `SPH_MAX_PRESSURE_ACCEL`, `FLUID_STRENGTH_MAX`,
    `SPH_VISCOSITY_MAX`, `MAX_VELOCITY_MAX`, `MAX_BODIES`, `BODY_FORCE_CEILING`, `q_max`, `k`). Raising
    any one locally past the bound fails the build. On today's code the single-word assertion fails
    the build (SPH alone 1 335× the span), which is its red step.
11. `tests/test_physics.nim`, "A Full Crowd Decodes To Its Impulse" (critique N-M9): for every writer
    (pair force, mouse, blast, SPH, bodies, field force, long range, pressure), a full crowd at that
    writer's maxima (field force and long range once task 2.3 records theirs), encoded by its oracle and decoded by the integrate oracle, gives the float impulse
    within one quantum times the frame factor, with its sign, at frame factors 1, 2 and 30. Against
    the today-convention oracles it fails on values: the pair force at frame factor 30 needs about 265 600
    against 32 767, so the once-converted share saturates to about an eighth, and SPH's per-pair adds
    wrap and can decode with the wrong sign. Catches: the substep multiplied in before accumulation,
    the frame factor applied twice or not at all, `k` or `q_max` raised past its word, a split whose
    parts do not sum to the integer (an arithmetic `>>` replaced by division, which rounds negative
    values toward zero), a writer left on the old convention.
12. `tests/test_balance_core.nim`, "Every Compressor Answers In The Pair Unit" (critique N-M8, missing
    from the second draft's list): one touching neighbour at force strength 1 over the reference frame
    hands exactly `u0` of contact repulsion; and for each demand function, a sweep of the oracle over a
    grid of configurations inside the ranges (distance, matrix entry, radius, band, body count) finds
    no inward impulse above the demand, and the demand's own configuration attains it. The pair
    demand is attraction, inward, and the unit is repulsion, outward, so the two are asserted
    separately. Catches: a demand evaluated at a configuration that is not the largest (the sweep
    finds a larger one), a wrong edge-neighbour sum, a sign that counts repulsion as demand, a demand
    doubled or halved.

The diagnosis report's three red tests map as: its bodies-beyond-band test belongs to
`parametric-bodies`; its deposit-scaling test is replaced by 1 and 2 (D2); its collapse test is 5.

### D11. Force strength 0 still resists compression above the onset

**The choice.** The pressure is not scaled by force strength. At force strength 0 a crowd above the
onset pushes itself apart; below the onset particles pass through each other as before.

**Why.** A pressure scaled by force strength would let Hold collapse a world at force strength 0 with
nothing answering. The probe showed it: with the pair law off, a gated world with no pressure held at
618–658 and stayed at 602 after the body went, and the same world with pressure relaxed to 105 (design
notes, g0).

**The cost.** Force strength 0 no longer means "particles ignore each other" everywhere. A player
cannot turn the incompressibility off, and a dense crowd at force strength 0 visibly holds its size.

**What would reopen it.** Any of: a player-facing need for pass-through dense crowds at force strength
0; a bound on the per-particle push in `parametric-bodies` that makes a collapse at force strength 0
impossible without the pressure; an in-app run at force strength 0 showing pressure artefacts a
player reads as a bug.

The user accepted this on 13-09-26 and asked for it to stay visible here.

### D12. Interaction with `calibrate-shipped-defaults`

That change's group 3 waits on this one. Two of its pieces change meaning, and this change rewrites
them (task 4.4):

- Fixture C is a world that collapses at crowding 0 (`openspec/changes/calibrate-shipped-defaults/design.md:110-131`).
  Under the pressure it no longer collapses, so its red step 2.5 no longer goes red. The fixture
  becomes a world that settles above the onset, and its validity gate becomes "its crowd rises past
  the onset at crowding 0".
- The `c_hold` constraint (`design.md:133`), crowding strong enough to stop a collapse, becomes vacuous.
  Crowding is calibrated by `c_soften` alone.

### D13. Relaxation is history independence, and as measured it holds only in part

After a compressor is removed, the mean neighbour count should converge to a fresh settle from the
same seed. The small probe measured it failing today: one self-attracting species stays at 1 499
neighbours against a fresh settle of 502. With a pressure the same world returned to 235 against 277
(run 2), and at app scale the held crowd fell from 629 to 132–139 within 50 frames of removal (design
notes). A crowd above the onset has a repulsive term that grows with the excess, so the compressed
state is not a fixed point once the push is gone.

A self-attracting species settles looser than today: 456 → 308 crowd peak at app scale with onset
270 (design notes, batch C), 502 → 277 neighbours in the small world. Its own settle lies above an
onset that leaves mixed worlds untouched. That is the collapse the pressure bounds.

**What the second round measured** (16 000 particles, radius 50, 32 stacked bodies held 300 frames,
900 frames after release against a fresh 1 600-frame settle, 3 seeds; batches I-b, J, L):

- **Self-attracting, onset below its settle.** Relaxation completes only at high stiffness: after
  over fresh neighbours 1.16–1.19 at `K = 54`, 1.10 at 173, 1.02–1.04 at 540, 0.97–0.99 at 1728. The
  settle criterion (D5) caps `K` between 173 and 540.
- **Self-attracting, onset at or above its settle** (`x_on = 12`). The clump stays near the onset
  after release: 1.39–1.45.
- **Mixed matrix, 4 species.** The fresh settle sits below the onset; clumps the hold merged stay
  merged at every `K` probed (1.37–1.71), because below the onset nothing in the pair law separates
  two clumps pushed into one. An onset at `x = 3` halves the memory (1.16–1.28) and trims ordinary
  mixed settles at small `N · R²` (D3).

Mixed clumps a hold merged stay merged below the onset; that follows from the onset's placement and
is recorded in D3, not returned as a trade. Gate 6 gates self-attracting relaxation only (D10).

**The stiffness trade at 128 000 particles** (the user asked for it before choosing, 13-09-26; design
notes, batch M). The app's 3840 × 2160 world, radius 50, one self-attracting species, onset `x = 6.3`
(`ρ̄ = 40.4`, `ρ_on = 254.4`), native binned oracle, seeds 42, 7 and 1001. Per arm and seed: a
900-step settle at `FRICTION_MIN` (L, steps 749–899, over the same seed with no term); a fresh
1 600-step settle at shipped friction (settled speed over steps 1449–1599; neighbours at 1599); and
32 aligned stacked bodies held for 300 steps after a 400-step settle, then 900 steps after release
(neighbours at 1599 over the fresh settle's). The runs were made at full count, 14 at a time on 18
cores; wall time per run was 865–15 090 s, the spread from sharing the machine. Ranges over seeds;
one-sided 95% bounds from `t = 2.920` (df 2).

| Arm | L at friction 0 | Friction-0 neighbours (no term 193–199) | After release over fresh | Settled speed, shipped friction (no term 0.000–0.003) | Fresh neighbours (no term 186.4–186.6) | Held crowd peak / neighbours | `ff_stable` (D15, 16 000) |
|---|---|---|---|---|---|---|---|
| `K = 540`, `ν = 0.5` | 0.864–0.890, upper bound 0.902 | 61.8–64.7 | 0.901–0.972, upper bound 0.998 | 0.107–0.125 | 167.6–169.8 | 567–573 / 309–313 | ≥ 30, no substeps |
| `K = 1728`, `ν = 0.5` | 1.220–1.261, lower bound 1.208 | 60.2–62.6 | 0.987–1.024, upper bound 1.047 | 0.950–1.120 | 141.9–149.5 | 472–478 / 272–275 | 5 |
| `K = 540`, no viscosity | 1.163–1.175, lower bound 1.159 | 62.7–67.1 | 0.971–0.976, upper bound 0.978 | 0.028–0.115 | 170.6–173.2 | 618–630 / 323–353 | 12 on 8 seeds (≥ 30 on the first 3, borderline) |

**The user's choice (14-09-26): `K = 540` without viscosity.** It reverses the earlier choice of pair
viscosity 0.5 (D4 records the viscosity as rejected, with its effect at this count). The costs the
user accepted with it, as measured above:

- **Friction-0 settles run about 17% warmer** than without the term (L 1.163–1.175). That fails the
  earlier bound `L ≤ 1`; gate 7 now holds the chosen arm's own measured L with its margin (D5, D10).
- **A simmer at shipped friction**: settled speed 0.028–0.115 against 0.000–0.003 without the term.
- **A held crowd peak of 618–630** under 32 stacked bodies (323–353 weighted neighbours), the densest
  of the three arms.
- **Relaxation completes at 128 000**: after over fresh 0.971–0.976 (upper bound 0.978). At 16 000,
  onset `x = 6.3`, the same arm reads 1.000–1.014 (batch R, 3 seeds), so gate 6 runs at 16 000 with a
  bound derived there, and a second arm holds this 128 000 relaxation below 1 in
  `just calibrate-balance-128k` (D10).
- **`ff_stable` is 12** on 8 seeds at 16 000 particles: at frame factor 30 without substeps the arm
  reads 1.33× the shipped frame, warmer at the 5% level (D15).

What the rejected arms would have given: `K = 540` with viscosity kept friction-0 settles cooler
(L 0.864–0.890) and relaxed at least as far (0.901–0.972) but simmered at 0.107–0.125 and held at
567–573; `K = 1728` with viscosity held lowest (472–478) but warmed friction-0 settles about 25%,
simmered at 0.950–1.120 and needed substeps from frame factor 6.

### D14. Friction 0 and shipped friction: what the chosen term costs

**The choices.** The pressure is not scaled by friction (the user's decision, 13-09-26, kept). The term
carries no viscosity (the user's decision, 14-09-26; D4, D13).

**Why no friction scaling.** A pressure read through a smoothed, one-frame lagged density is linearly
unstable at velocity retention 1 for every stiffness above zero (design notes, stability table), so no
fixed stiffness removes the friction-0 shimmer. Scaling the stiffness with friction would remove the
pressure at friction 0 and reopen the collapse there, the way D11's alternative would at force
strength 0. Gate 7 holds the friction-0 settle no warmer on average than the chosen arm measured,
`B_L` (D5).

**The accepted cost: friction-0 settles run warmer and looser** (the user's decisions, 13-09-26 and
14-09-26). The cost was first put to the user as "a third of the motion and twice the neighbours";
both halves were wrong for the term as chosen. At 128 000 particles, one self-attracting species,
friction 0, 900 steps, `K = 540` without viscosity, 3 seeds (batch M):

- **Motion**: about 17% more than without the term (L 1.163–1.175), not a third.
- **Neighbours**: about a third of today's (62.7–67.1 weighted neighbours against 193.4–198.9), not
  twice. The user accepted the looser settle on these figures (14-09-26).

At 16 000 particles the same `K` reads L 1.036 (batch H, onset `x = 7`); the no-term settle there has
20.8–21.8 weighted neighbours (batches K, L; an earlier 14.5 appears in no log).

**At shipped friction** the term leaves dense self-attracting clumps simmering: settled speed 0.028–0.115
at 128 000 against 0.000–0.003 without it (batch M). Pair viscosity did not remove it at this `K`
(0.107–0.125 with it), and the user took the simmer over the viscosity.

**What would reopen it.** An in-app run at friction 0 showing a shimmer a player reads as a bug; dense
crowds at friction 0 reaching the soft cap's threshold of 25; the in-app run (task 6.1) showing the
simmer at shipped friction as a visible jitter.

### D15. Frames past a measured frame factor substep

**The choice** (the user's, 13-09-26). When a frame's frame factor `ff` passes `ff_stable`, the whole
frame description runs `⌈ff / ff_stable⌉` substeps through the executor's existing substep path
(`src/webgpu_compute.nim:979-988,1243-1253`), each advancing `ff / ⌈ff / ff_stable⌉` reference
frames. The time-scale range is not narrowed. Frame factors run from 0.2 (60 Hz at `TIME_SCALE_MIN`
0.1) to 30 (the 0.05 s frame cap, `src/app.nim:239-241`, times `TIME_SCALE_MAX` 5,
`src/config_ranges.nim:177-178`); the shipped frame is `ff = 1`, a 60 Hz frame at the default time
scale 0.5 (`src/physics_core.nim:23-26`, `src/ui/state/simulation_state.nim:138`).

**A correction to the finding the choice was made on.** The previous revision's table compared late
speeds per step across frame factors and read frame factor 10 as boiling (0.90–0.99 against
0.100–0.135 at `ff = 1`). A step at `ff` advances `ff` reference frames, and friction and the
position update act once per step (`src/app.nim:191`, `web/shaders/src/integrate.wgsl:87-106`), so a
steady push moves a particle `ff` times as far per step and equally far per reference frame. Per
step, a world at time scale 5 is expected to move ten times as far as the shipped world. Motion per
reference frame (late speed over `ff`) is the reading that compares one simulated world across frame
rates, and it is also the only one substeps can satisfy: `n` substeps at `ff / n` sum `n` steps of
motion into one rendered frame. On it, `K = 540` at frame factor 10 moves 0.090–0.099 per reference
frame against 0.100–0.135 at the shipped frame, not ten times more. The user's choice stands as
given; what it triggers depends on the stiffness (below).

**The stability limit, measured** (design notes, batches N, P, Q, R and S). `ff_stable` is the largest
frame factor, held fixed for the whole run, at which a dense self-attracting world's late-window mean speed per reference frame is no
warmer than at the shipped frame: one-sided paired `t` over seeds at `α = 5%` (D5), warmer when the
lower bound of the mean difference passes zero. Conditions: native binned oracle world, 16 000
particles, radius 50, one self-attracting species, onset `x = 6.3` (`ρ_on = 31.8`), crowd smoothing
0.7, velocity retention 0.95 (shipped friction 0.05), 900 steps, late window steps 749–899.

**The chosen arm, `K = 540` without viscosity, 8 seeds** (42, 7, 1001, 11, 13, 17, 19, 23; `t = 1.895`,
df 7). Late speed per reference frame, range over seeds, and the mean over the shipped frame's mean:

| Frame factor | Per reference frame | Over `ff = 1` | One-sided lower bound of the difference |
|---|---|---|---|
| 1 (shipped) | 0.085–0.135 | 1 | |
| 10 | 0.089–0.117 | 0.91× | −0.021 |
| 11 | 0.080–0.126 | 0.94× | −0.022 |
| 12 | 0.085–0.130 | 1.04× | −0.016 |
| **13** | 0.114–0.140 | **1.10×, warmer** | 0.001 |
| 14 | 0.094–0.152 | 1.18×, warmer | 0.006 |
| 20 | 0.134–0.152 | 1.31×, warmer | 0.024 |
| 30 | 0.138–0.150 | 1.33×, warmer | 0.022 |

**`ff_stable = 12`** for the chosen arm on these 8 seeds; on the first 3 alone frame factor 30 read
1.25× with a lower bound of −0.002, which is why the earlier revision called it borderline. Frame
factors 2, 4 and 7 (3 seeds) read 0.18–0.36×. Without the term the world rests at every frame factor
(0.000 from 2 to 30; 0.003–0.005 at 1). Task 1.3 bisects `ff_stable` again on the 16 calibration seeds
and records it beside these conditions.

**When the substeps trigger at `ff_stable = 12`.** The frame factor is `120 · min(rawDt, 0.05) ·
timeScale`. On a 60 Hz display it reaches at most 10 (time scale 5), so no substep runs there. A frame
longer than `0.1 / timeScale` seconds passes 12: at time scale 5, any frame slower than 50 fps. **At
the 0.05 s cap they do trigger**: the frame factor is `6 · timeScale`, so time scales above 2 up to 4
run 2 substeps and above 4 run 3 (frame factor 30 as 3 × 10).

**What gate 7 does at frame factor 30.** Through the substep rule, frame factor 30 runs as three steps
of 10, which read 0.91× the shipped frame on 8 seeds; the gate's one-sided check passes there. With
the trigger missing, frame factor 30 reads 1.33× with a lower bound of 0.022 on 8 seeds, so the gate
fails. That is the wrong code it names: a missing substep trigger, or `ff_stable` recorded at 30.

**A frame factor that changes every frame (third critique, F3).** `ff_stable` was bisected with the
frame factor held fixed, but the app recomputes it every rendered frame from the measured interval,
`ff = 120 · min(rawDt, 0.05) · timeScale` (`src/app.nim:239-241`, `src/physics_core.nim:23,36`). At time
scale 5 a 20 ms frame gives 12 and a 22 ms frame 13.2, so a session wandering between 60 and 45 fps
straddles the limit. The code gives the mapping, not the interval's distribution, so batch T takes two
bounding cases at time scale 5: frame factor drawn per frame uniformly from 8 to 16 (`rawDt` 13.3–26.7
ms, independent frame to frame, the most toggling a spread that wide gives), and a strict alternation
of 10 and 13 (16.7 and 21.7 ms, a toggle every frame). Conditions as above, 8 seeds, the late window's
statistic taken over every rendered frame 749–899 as the mean of speed over the step's frame factor:

| Arm | Per reference frame | Over `ff = 1` | Lower bound of the difference | Frames substepped / toggles |
|---|---|---|---|---|
| fixed 1 (shipped) | 0.087–0.133 | 1 | | 0 / 0 |
| fixed 10 | 0.089–0.114 | 0.89× | −0.022 | 0 / 0 |
| uniform 8–16, substeps at 12 | 0.045–0.097 | 0.59× | −0.064 | 432–490 / 424–478 |
| alternating 10, 13, substeps at 12 | 0.033–0.061 | 0.40× | −0.076 | 450 / 899 |
| uniform 8–16, no substeps | 0.112–0.152 | **1.18×, warmer** | 0.0035 | 0 / 0 |
| alternating 10, 13, no substeps | 0.094–0.133 | 0.97× | −0.017 | 0 / 0 |

The substep count flaps on nearly every frame and the settle reads cooler for it, so the trigger
carries no hysteresis: a hysteresis band would be a hand-set constant with nothing measured to set it.
The uniform arm without substeps fails, so gate 7 carries both jittered arms (D10); the measured
wrong code they name is a missing trigger. Whether the toggling shows as stutter in the app is
task 4.5's reading.

**The rejected arms, for the record** (3 seeds, batches P and Q): `K = 540` with viscosity was never
warmer up to 30; `K = 1728` with viscosity was warmer from 6 (1.32×) and ran 2.0–2.2× from 10 to 30,
`ff_stable = 5`.

**The added GPU cost.** A substep repeats every compute node except those marked once per frame (the
field, the long-range solve and two buffer clears, `src/sim_registry.nim:362,369,417,460`); draw and
present are render passes and run once (`src/webgpu_render.nim:1795,1905`). Each extra substep
therefore adds the grid and physics passes, and the term, the long-range force and the bodies when
active. The harness figures are timestamped on the first substep only, so they are per-substep costs
(`docs/perf-report.md:83-84`). Per extra substep at 128 000 particles and shipped settings: grid 0.089
plus physics 1.471, 1.56 ms after 30 s (`w1-128k`); grid 0.019 plus physics 7.929, 7.95 ms after 150 s
(`w1-128k-150`, still climbing, so a lower bound). No in-app run measured it: today the substep path
engages only with the fluid on (`src/webgpu_compute.nim:984-987`), so no world reaches it without
adding SPH's passes, and this change edits no source; task 4.5 reads it once the trigger exists.

| Frame | Substeps at `ff_stable = 12` | Added, 30 s figures | Added, 150 s figures |
|---|---|---|---|
| 60 Hz, any time scale (`ff ≤ 10`) | 1 | 0 | 0 |
| 0.05 s cap, time scale above 2 to 4 (`ff` 12–24) | 2 | 1.56 ms plus the term's cost once more | 7.95 ms plus the term's |
| 0.05 s cap, time scale above 4 (`ff` to 30) | 3 | 3.12 ms plus the term's cost twice more | 15.9 ms plus the term's |

A frame at the 0.05 s cap has already missed the 16.7 ms budget, so the headroom does not bound it;
there the substeps lengthen a slow frame by the table's figure (Risks). On a 60 Hz display at any time
scale the chosen arm adds nothing. The working headroom is 11.65 ms, a lower bound (Context); task
4.5's in-app reading covers the capped frames.

**The options the user did not take, with their costs** (measured on batch N unless stated):

| Option | What the player would see | Cost |
|---|---|---|
| Accept | At `K = 540`, dense clumps simmer up to 1.33× faster per simulated frame when frames run past 12 reference frames: slow frames at time scale above 2 | None |
| Substep only the pair pass and integrate | As the chosen option | A second substep path in the executor, with its own ordering against the once-per-frame passes |
| Hold the pressure per step (`K / ff`) | Per reference frame 0.015–0.017 at `ff` 10 (`K = 54`) and 0.071–0.091 at 30 (`K = 18`), against 0.100–0.135 shipped | At long frames the pressure is weaker per simulated frame, so holds compress further; the per-step stiffness no longer matches the chosen one |
| The viscosity's exact per-pair decay | 0.50–0.59 per reference frame at `ff` 30 (`K = 18`), four to eight times the plain form | Overshoots; rejected, and the viscosity itself is rejected (D4) |

## Risks / Trade-offs

- [The onset's ratio and floor are measured on 3 seeds and 600 frames per world, and the exponential
  model's floor is unprobed] → Task 1.2 measures 16 calibration seeds, down to radius 10 and 100
  particles, both models, before `x_on` is recorded.
- [Every probe is a CPU model; the GPU compiles under relaxed math] → GPU bit identity is
  unenforced (D4); the in-app run 6.2 compares the settled look.
- [A fixed stiffness cannot hold the stacked D16 column near the onset at app scale] → Accepted (D6):
  the held crowd stays local, below its collapse, and test 5 holds it against the control.
- [A held or dense crowd costs more than the pair-pass allotment] → Accepted under the relative
  ceiling (D6); task 6.1 records the held figure, and the allotment bounds the added cost of a settled
  world.
- [At friction 0 a lagged pressure is linearly unstable, and the chosen `K = 540` runs friction-0
  settles about 17% warmer] → Accepted by the user (D13, D14), bounded on average by gate 7's `B_L`.
- [`K = 540` and `B_L` rest on 3 seeds at 128 000 particles on a CPU model] → Task 1.3 confirms both
  on 16 calibration seeds.
- [Mixed clumps a hold merged stay merged below the onset] → Accepted as a consequence of the onset
  at the self-attracting band's bottom (D3); gate 6 does not gate mixed worlds.
- [At shipped friction the term leaves dense self-attracting clumps simmering at 0.028–0.115 against
  0.000–0.003] → Accepted by the user with `K = 540` (D13, D14); task 6.1 observes it in-app.
- [At `K = 540` dense crowds run warmer per simulated frame from frame factor 13] → Frames past
  `ff_stable = 12` substep (D15); no frame on a 60 Hz display reaches it.
- [A frame at the 0.05 s cap runs up to `⌈30 / ff_stable⌉ = 3` substeps, which lengthens a frame that is already
  slow; if the GPU made it slow, the added substeps can hold it past the cap, so it stays capped and
  keeps substepping] → Unmeasured; task 4.5 reads `physics=` and the frame time at the cap and records
  whether the frame recovers when the load that capped it goes.
- [`docs/perf-report.md:129-131` multiplies draw and present by the substep count, but both are render
  passes run once per frame (`src/webgpu_render.nim:1795,1905`), so its `w2` and `w3` per-frame totals
  overstate the frame] → Outside this change's edits; D15 counts only the compute passes a substep
  repeats. Reported to the lead.
- [The reference-frame convention touches five writers; one left on the old convention writes up to
  30× too hard] → Tests 4b and 11 cover every writer's oracle; the pairing between shader and oracle
  stays unenforced, as for every oracle.
- [`forces.wgsl` reaches the default limit of 8 storage buffers] → Any later storage binding there
  needs a raised device limit or a merged buffer (D8).
- [The long-range and field-force per-particle maxima are not yet derived for the fine word's sum] →
  Task 2.3 derives or records each; if they exceed the 7 571 velocity per reference frame `k = 12`
  leaves, `k` falls to 11.
- [The coarse word's and the split's cost is unmeasured] → Task 1.5 measures it before the shader
  edit is accepted.
- [The 128 000-particle checks, `B_L`'s re-derivation, gate 7's friction-0 check and gate 6's
  relaxation arm, cost about 40 core-hours per run] → They run in `just calibrate-balance-128k`, outside
  `just check` and `just calibrate-balance`, when the term lands and on the D10 rerun trigger; nothing
  detects a change that skips it, which `docs/enforcement.md` records.
- [A session's frame factor changes every frame and can straddle `ff_stable`] → Batch T drove it
  across 12 frame to frame; the substep count toggled on 424–899 of 900 frames and the settle read
  cooler, not warmer, so the trigger carries no hysteresis (D15). Whether the toggle shows as stutter
  is task 4.5's in-app reading.
- [Force strength 0 gains incompressibility above the onset] → D11.
- [A world whose settle sits above the onset looks different] → The onset lies above the calibration
  band; a self-attracting world is the intended exception (D13), and D3 records the placement trade.
- [Under the radius-independent unit a fixed long-range slider pulls about as the radius squared,
  273× from radius 10 to 150] → Accepted (D2); the help line states it and the preset conversion
  carries each world's own radius (D7).
- [The long-range unit reads `x_on`, so changing the onset silently rescales every long-range preset]
  → A static assertion in `src/preset.nim` holds the version-5 `x_on` equal to the live constant (D7).

## Migration Plan

One schema bump (D7). Rollback is a revert: a version-5 preset loaded by the old code fails the
version check as any newer preset does (`src/preset.nim:753-758`, `pekNewerSchemaVersion`).

## Open Questions

None remain open.

Answered and recorded in place. On 13-09-26: the onset at the bottom of the self-attracting band,
with mixed worlds' trimmed peaks and kept merges as its consequence (D3); the radius-independent
long-range unit and its corrected formula (D2, D7); substeps past a measured frame factor (D15);
`α = 5%` (D5, D10); gates 5–7 in `just calibrate-balance` (D10). On 14-09-26: `K = 540` without
viscosity, with its friction-0 warmth, simmer and held peak accepted (D4, D13, D14); the looser
friction-0 settle on the corrected figures (D14); the allotment provisional on 11.65 ms as a lower
bound until task 4.5's in-app reading (Context); gate 6 at 16 000 particles with a derived `B_r`
(D10); gate 7's friction-0 check in `just calibrate-balance-128k` (D10). After the third critique
(14-09-26), the lead added gate 6's 128 000-particle arm, `B_L`'s re-derivation and the widened rerun
trigger to that recipe (D10).

Decided earlier and carried: the finite local hold and the relative ceiling (D6), the friction-0
shimmer (D14), crowding as a look control (D9), force strength 0 (D11), and the velocity word's
ownership (D8).
