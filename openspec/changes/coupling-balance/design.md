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
  3840 × 2160 world. No coupling acting, settled peaks run 11.6 to 721 across those worlds, and
  divided by `ρ̄` they fall in one band, 2.2–6.6 for mixed matrices and 9.7–11.3 for a
  self-attracting species (design notes, batch A).
- **Units.** The pair force is multiplied by `params.dt` in seconds (`forces.wgsl:297,377`). One
  touching neighbour at force strength 1 hands `FRAME_DT_REFERENCE = 1/120` velocity per reference
  frame. That is `u0` here. The largest substep is 0.25 s, a frame factor of 30
  (`src/body_core.nim:139-148`).
- **Fixed point.** The velocity word holds ±32 768 at 2^16 (`web/shaders/modules/fixed_point.wgsl`).
  In WGSL concrete `i32` arithmetic wraps and an `f32 → i32` conversion saturates
  (https://www.w3.org/TR/WGSL/), so each per-pair conversion and each particle's final sum must fit,
  and intermediate wraps are exact. The body accumulator already asserts a full-crowd bound,
  `MAX_PARTICLES ×` the per-particle maximum (`src/body_core.nim:262-269`).
- **Crowding** attenuates positive attraction only and ships at 0 (`forces.wgsl:73-93,261`,
  `src/config_ranges.nim:48`). It stays a look control (D9).
- **Bodies.** `parametric-bodies` D16 and its requirement "A body's pull on a particle is bounded in
  size and in region": at most `BODY_FORCE_CEILING · bodiesStrength · envelope` per reference frame per
  body (10 at the ceilings), inside a shell reaching at most `2 · bandWidth · max(anisotropy,
  1/anisotropy)` from the surface, a smoothstep bump peaking one band out; contributions add across up
  to `MAX_BODIES = 32` bodies; no normalization (`openspec/changes/parametric-bodies/design.md:652-699`,
  `specs/parametric-bodies/spec.md:170-212`). The push stays uncapped (the lead's answer).
- **Frame budget.** 128 000 particles settle with 3.75 ms of headroom, of which long range allots
  itself 1.0 ms (`src/config_ranges.nim:112-114`). The bodies passes read 0.066–0.076 ms at 128 000
  with no live body (`docs/perf-report.md:322-325`). The pair pass's allotment is therefore
  3.75 − 1.0 − 0.076 ≈ **2.67 ms, provisional**: `parametric-bodies` 9.3 waits on this change, so its
  live-body reading cannot supply the bodies share first, and replaces the idle figure when it lands
  (the lead's answer, 13-09-26). It gates the settled world, not a held one (D6).
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
- A long-range pull independent of mesh size, with a ceiling derived from that unit.
- A pressure that is local: a crowd's resistance depends on that crowd's own density, never on what
  a coupling does elsewhere.
- Onset and stiffness derived from the world's own configuration and measured behaviour, with no
  hand-set constant and no range clamped.
- A compressed crowd that stays finite while compressed and relaxes to the neighbourhood a fresh
  settle reaches once the compressor goes, including a self-attracting species.
- Zero change to any world whose crowd stays below the onset.

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
| Long range | `LONG_RANGE_STRENGTH_MAX · MATRIX_MAX_VALUE · R · M/(2πr)` at the reference colony (D2) | `long_range_core` |
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

### D2. The long-range potential is measured in `u0 · R`, not in cell area

The impulse today is `s · A · cellArea · M/(2πr)` inside the reach. The coarse mesh pulls 4.006× and
4.004× harder at 240 and 600 from the centre of a 1 000-particle clump (`lr_unit_probe.nim`); at 60
the ratio is 3.19, so mesh independence holds only a few cell widths out. The factor `cellArea`
becomes `u0 · R`, with `R` the live interaction radius. The kernel shape, `G(0) = 0`, the unit-charge
deposit and the fixed point stay.

The one site is the force scale written to `LR_FORCE_SCALE` (`src/webgpu_compute.nim:1125`), computed
by a `long_range_core` function the test calls, so the shader receives one oracle-computed number.

| Option | Sacrifice | Verdict |
|---|---|---|
| Stand still | The slider pulls 4× harder on one mesh; no unit to derive a ceiling from | Rejected |
| Normalize by `N` (a contrast potential) | Long range against pair scales as `1/N` at fixed local structure, so small worlds collapse | Rejected |
| Unit-integral Yukawa kernel `κ²/(k² + κ²)` | The far pull falls to about `M/r³`; distant groups stop answering, a navigability loss | Rejected |
| Normalize by mean particles per cell | Same `1/N` dependence | Rejected |
| **`u0 · R` in place of cell area** | Every saved long-range world changes unit (D7); the pull scales with interaction radius | **Chosen** |

Why `R`: the pair force's reach is `R`, so a clump's pair-force edge impulse grows with `R` at fixed
crowd density. Scaling the long-range unit by `R` keeps the ratio of the two from moving with the
radius slider.

**The reference colony (critique M8).** `LONG_RANGE_STRENGTH_MAX` is the strength at which the whole
population, `MAX_PARTICLES`, gathered into one disc at the onset density (D4), pulls a particle one
interaction radius past the disc's edge as hard as the pair force's peak edge impulse at that
density. The colony's mass and radius are then both fixed by recorded numbers: `M = MAX_PARTICLES`,
radius `√(M / (π · n_on))` with `n_on` the number density at the onset. Beyond that strength long range
out-pulls the pair force at the scale of the largest colony the world can hold, the regime the in-app
filaments came from. The value is computed by `balance_core` at the recorded onset; it is not
computed here, because the onset is not yet measured. `longRange.impulseShare` reports its impulse in
`u0` at the same colony.

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
| **`x = ρ / ρ̄` from live `N`, `R` and area** | A uniform written per frame; the band's top is measured on 400 frames and 5 seeds only, still climbing on one world | **Chosen** |

### D4. Where the pressure term lives

Per pair, inside the existing loop, alongside the force law and not inside its expression:

```
π(x)   = (max(x − x_on, 0) / x_on)²
q      = quantize(K · (π_this + π_other) · (1 − r/R) · dt)     one signed integer per pair
this  −= q · separation/r        other += q · separation/r     in the pressure word (D8)
```

`π_this` is hoisted beside `attenuationOnThis`. The law has no ceiling parameter: its scale is the
onset itself, so the only measured numbers it carries are `x_on` and `K` (D5).

**Bit identity below the onset (critique M7).** The force law keeps its grouping,
`forceMagnitudeOnThis *= params.forceMultiplier * invDistance` (`forces.wgsl:282`). The pressure is
formed and accumulated separately, so below the onset the velocity delta the force law writes is the
same expression it is today at every force strength, not only at 1 (the critic measured 35 207 of
100 000 products changed by the first draft's regrouping at 0.7). On the GPU this holds only if the
shader compiler does not regroup: Dawn's Metal backend compiles with relaxed math unless strict math
is requested (https://raw.githubusercontent.com/google/dawn/main/src/dawn/native/metal/ShaderModuleMTL.mm,
lines 460-469 and 564, read by the critic) [.?], and whether Chromium requests it is unread (task 1.6). GPU bit identity is therefore
**unenforced**; the native oracle holds it.

**Momentum (critique M6).** The pair's impulse is quantized once, to one integer `q`, which is added
to one particle and subtracted from the other. Momentum in the pressure word is then conserved
exactly, not to within a quantum per pair. The force law's own truncation asymmetry (the critic's
−394 to −643 quanta per frame) is today's and unchanged.

| Placement | Sacrifice | Verdict |
|---|---|---|
| Stand still | Collapse under every compressor, no relaxation (1 499/1 500 neighbours stuck) | Rejected |
| Integrate pass, along `∇ρ` | Integrate has no neighbour direction; a gradient needs a second neighbour pass | Rejected on cost |
| A grid pressure (density to mesh, gradient back) | A deposit, a stencil and a gather per frame; one cell is coarser than `R` on the shipped mesh | Rejected on cost |
| Onset-shifted Tait law on `sphDensity` (critique M11) | `sphDensity` belongs to the fluid pass, which is skipped at fluid 0 (`docs/one-world.md:52-60`), so the pressure would vanish with the fluid slider or need a second writer; and a Tait law's slope at its onset is `γ/ρ_on`, not zero: at the same stiffness it boiled the self-attracting settle at mean speed 4.02 against 1.47 for the square, and 2.34 at a tenth of the stiffness (design notes, batch B) | Rejected on ownership and on the onset step |
| Onset-shifted Tait law on the crowd density | Keeps ownership; keeps the onset step (batch B) | Rejected |
| Unsmoothed crowd density for the pressure | Linear stability of a lagged pressure is 3× higher without the smoothing (design notes, stability table); but crowding reads the same field, so crowding's look would change, and at a fixed high stiffness it did not stop the boil (run 5, mean 6.41) | Not chosen; reopens if the in-app run shows onset jitter |
| A density gate: outside pushes and a particle's own attraction fade between onset and ceiling | Zero extra pair cost. Lowered the app-scale stacked hold's peak 35% (394 against 608 at the same stiffness) but did not hold it under 2× the onset, and in the small world it added nothing and failed with weak pressure (design notes, g0, g1, app scale). A dense crowd would stop hearing bodies, long range, tropism and the mouse: a new behaviour | Rejected by the user (D6) |
| Pair viscosity on approach speed above the onset | One dot product per pair; at friction 0 it lowered the settled mean speed from 4.5 to 2.4–2.8 in one seed, noisy (design notes, batch D) | Not chosen; unmeasured beyond one seed |
| Implicit density projection (position-based, iterated) | Unconditionally stable and a hard bound, at one extra neighbour sweep per iteration | Rejected by the user on performance, the top priority (D6) |
| **Pair term on the smoothed crowd density, own accumulator** | A second per-particle word and one more pair of atomic adds per pair (D8), cost unmeasured; the smoothed signal lags, which bounds the stiffness (D5) | **Chosen** |

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

**Deriving `K` (critique B2, M1).** `K` is the largest stiffness at which a world still settles the
way it settles without the term: on the calibration seeds (D10), at the friction range's minimum and
at the shipped friction, the ratio of a late window's mean speed to an earlier window's lies within
the spread of that ratio without the term. A first form of the criterion, "the settled mean speed
lies within the no-term spread", was ill-posed and is withdrawn: below the onset the term is zero, so
mixed worlds cannot fail it, and above the onset the term must change the settle, so a
self-attracting world fails it at every `K` (app scale: mean speed 0.26 at `K = 54` and 0.47 at
`K = 1728` against 0.11 without the term, all at frame 199, design notes batch F). The trend ratio
asks only whether the world comes to rest as it did. The criterion names no compressor, so the
collapse and relaxation gates, which run held-out seeds under compressors, can fail against it. The
number 54 in the design notes is a probe setting, not this derivation, which has not been run.

**Why a stability derivation alone does not serve.** A pressure read through a smoothed, one-frame
lagged density is linearly stable only for a gain below a limit set by the smoothing and the velocity
retention: 0.018 per frame at smoothing 0.7 and retention 0.95, 0.65 at retention 0.5, and zero at
retention 1, which is friction 0 (`FRICTION_MIN`) (design notes, stability table; a linear model, not
measured against the app). At friction 0 every fixed stiffness is linearly unstable, and only the soft
speed cap bounds the motion: the probe at friction 0 settled at mean speed 4.5 with `K = 54` against
3.9 without the term. The settling criterion above is measured instead, so it holds where the linear
bound is zero; what it permits at friction 0 is the shimmer D14 accepts.

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
per pair `p = 2K · π(x) / 120` velocity per reference frame, so `C(x) = 3 (x ρ̄)² · K π(x) / (480 π R)`. A compressor's demand is the column pressure `F · √(M n / π)` it builds, with `F` its push per
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
ceiling is imposed. The onset is measured in the world's own mean crowd density (D3), so every world
keeps its own settled look at every particle count and radius, and a configuration whose settle is
dense costs what that settle costs: a 128 000-particle world at radius 150 sits at `ρ̄ = 364` with
nothing acting, and no term pushes it apart. The pair pass's 2.67 ms allotment gates the settled
shipped world at `MAX_PARTICLES` (tasks 1.5, 6.2), not dense configurations and not held crowds.

Asking `parametric-bodies` to saturate the per-particle push is not an option this design takes: the
body push stays uncapped (the lead's answer, 13-09-26).

**Finite at every setting.** `π` grows with the square of the excess while every push is bounded per
particle and `N ≤ MAX_PARTICLES`, so a static balance exists at a finite density. That argument is
static; the held world is dynamic, so finiteness is held by the stepped gate (D10 test 5), not by the
argument.

**A finding for `parametric-bodies`, outside this change.** Under 32 stacked bodies the whole-world
mean speed ran 16–17 at app scale with or without pressure, and in the small world 23.2–25.2 without
pressure and 29.7–31.3 with `K = 1728` (critique M12). The soft cap's threshold is 25
(`integrate.wgsl:92`, shipped `maxVelocity` 50). A stacked hold without pressure runs at the
threshold, and pressure pushes it above. Nothing in either change bounds a hold's heat.

### D7. Presets: a conversion, then the clamp decides

`CURRENT_SCHEMA_VERSION` 4 → 5 with a `fromVersion < 5` branch that multiplies the long-range
strength by `cellArea(savedGridIndex) / (u0 · savedInteractionRadius)`, both read from the preset
itself, before `validateSettings` clamps. Zero stays exactly zero. The factor runs from 50.6 (512 ×
256, radius 150) to 3 037.5 (256 × 128, radius 10), and is 151.9 at the shipped mesh and radius
(critique M9). Where the converted strength exceeds the derived `LONG_RANGE_STRENGTH_MAX` the clamp
decides: the pull the saved world had is kept only below the new ceiling, and a saved strength above
roughly the new ceiling over the factor loses the excess. The alternative, loading the old number
unconverted, changes every saved long-range world by that factor and was rejected.

Nothing shipped carries a non-zero long-range strength: the default is 0.0
(`src/preset.nim:276`) and the repo ships no preset files. Presets in a player's localStorage are
unknown, and the conversion covers them.

`long-range-mesh`'s spec says "no schema version and no migration branch is added"
(`openspec/changes/long-range-mesh/specs/long-range-coupling/spec.md:300,309`), and its
parameter-range-authority delta states the provisional ceiling. This change lands first and amends
both in the same pass as the conversion (tasks 3.4).

### D8. Every velocity impulse accumulates per reference frame, and the pressure has its own word

**The relation (critique B4).** Each per-pair integer and each particle's final sum must fit its
word. In WGSL an intermediate `i32` wrap is exact and an `f32 → i32` conversion saturates
(https://www.w3.org/TR/WGSL/), so the bound is on each conversion and on the final sum. It is a
full-crowd bound, as the body accumulator's is (`src/body_core.nim:262-269`): `MAX_PARTICLES`
neighbours, each at its per-pair maximum.

**The velocity word fails that bound today (this change owns it: the lead's answer, 13-09-26).** Six
shaders write `velocityDeltaFixed`: `forces.wgsl`, `forces-sph.wgsl`, `body-force.wgsl`,
`field-force.wgsl` and `lr-force.wgsl`, each already multiplied by the substep (the pair force by
`params.dt`, `forces.wgsl:297,377`; the others by `frameFactor`, `src/webgpu_compute.nim:1066,1098,1126`),
and `integrate.wgsl:55-58` decodes it at 2^16. The pair law alone reaches
`FORCE_STRENGTH_MAX 5 · MAX_PARTICLES 128 000 · frame factor 30 / 120 = 160 000` against a span of
32 767, so a full crowd at force strength 5 on the largest substep saturates to a wrong impulse.
Nothing asserts it, and the `fixed_point.wgsl` header's "far more range than a per-frame impulse ever
needs" is false at that substep. Force strength's range is not narrowed to fit.

| Remedy | What it costs | Verdict |
|---|---|---|
| Narrow `FORCE_STRENGTH_MAX` or the largest substep | A user range clamped to fit an implementation limit | Rejected (fix the mechanism, never the ceiling) |
| A coarser velocity scale derived from the budget, as the SPH density word's is (`src/sph_core.nim`) | One constant; but 2^13 or coarser is needed, 8× less resolution at every frame length including the shipped one, and the bound still grows with the frame factor | Rejected |
| **Accumulate every writer's impulse per reference frame; integrate multiplies the decoded delta by the frame factor** | Six writers change convention in one pass; `IntegrationParams` carries the frame factor in a pad slot (`integrate.wgsl:25-34`); the quantum in velocity grows with the frame factor, 30× coarser on the 0.25 s substep only; the delta the force law writes is no longer bit-equal to today's at a frame factor other than 1 | **Chosen** |

Why the reference-frame form: it removes the frame factor from every accumulator bound at once, the
velocity word's and the pressure word's, so the pair law's full-crowd sum is
`5 · 128 000 / 120 ≈ 5 333`, inside 32 767 at the existing 2^16 with 6× headroom; and it keeps full
resolution where the world usually runs, at frame factors near 1, spending resolution only on the
largest substep, which already trades precision for step length. The fallback spends resolution at
every frame length and still fails again when the frame factor grows. The added cost is one
multiply per particle in integrate, which already multiplies each particle's velocity by friction
(`integrate.wgsl:87-88`); it is unmeasured.

The assertion sums every writer: `Σ writers (per-particle maximum per reference frame) · 2^16 <
2^31 − 1`, at the bottom of `src/config_ranges.nim`. The pair law's term is
`FORCE_STRENGTH_MAX · MAX_PARTICLES / 120`; the bodies' `MAX_BODIES · BODY_FORCE_CEILING`; the other writers'
maxima are not yet derived: `forces-sph.wgsl` clamps each pair at `SPH_MAX_PRESSURE_ACCEL` 5000
(`src/sph_core.nim:48`) but bounds "one interaction but not the number of them"
(`forces-sph.wgsl:86`); `field-force.wgsl` writes once per particle,
`gradient · fieldForceScale · tropism` (`field-force.wgsl:76`), bounded by `RD_FIELD_FORCE_MAX`
(`src/config_ranges.nim:291`), `|TROPISM_MIN|` and a gradient bound no source states; `lr-force.wgsl`
writes once per particle, and `long_range_core` asserts its deposit's bound
(`src/long_range_core.nim:238`) but no force bound. Where
a writer has no finite per-particle maximum today, the task records it as a finding rather than
asserting a guess.

**The pressure word.** A per-particle pressure word pair with its own scale `S_p` and a per-pair
saturation `q_max`, in the same reference-frame convention:

- `q_max · MAX_PARTICLES · S_p < 2^31 − 1`, asserted beside the velocity word's.
- `S_p` is the coarsest scale at which the collapse and relaxation gates still pass on the calibration
  seeds and the settling criterion of D5 still holds. The small world ran a per-pair quantum of
  0.018 velocity per frame (a scale of about 55) with its settle at mean speed 2.48 against 1.89
  unquantized and the stacked hold under 208; a quantum of 0.1 settled at 2.61 (design notes, batch E).
- `q_max` is then the largest value the span admits: at a scale of 55,
  `(2^31 − 1)/(128 000 · 55) ≈ 305` velocity per reference frame per pair, above the 138 the uniform
  column estimate asks for (D6). A pair past it saturates; the saturation is the word's capability,
  not a user range.

Why a separate word rather than the velocity word's remaining span: the velocity word's remaining span
after the pair law is about 27 000, which admits `27 000 / 128 000 ≈ 0.21` per pair under the
full-crowd bound, below the column's need; the pressure wants a coarse scale and the force law a fine
one.

Cost: one 8-byte word pair per particle (1 MB at `MAX_PARTICLES`), two atomic adds per pair and one
per particle, one decode in integrate. Unmeasured; task 1.5 measures it.

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

**Seeds.** Every number derived from a run (`x_on`, `K`, `S_p`) is derived on a recorded set of
calibration seeds. Every gate that checks behaviour runs a disjoint recorded set of held-out seeds.
No margin is fitted to a gate (critique B2).

1. `tests/test_long_range_core.nim`, "The Pull Does Not Depend On Mesh Size": the impulse sampled 240
   and 600 from the clump centre agrees across `LR_GRID_SIZES` within the tolerance recorded beside
   the test, which is the formula gap the static solve measured at reach 4000 (0.7%) doubled for two
   meshes. Catches: `cellArea` left in the scale (ratio 4.006), or a grid-dependent factor anywhere in
   the kernel.
2. `tests/test_long_range_core.nim`, "The Pull Is The Pair Unit Spread By The Green's Function": at
   `LONG_RANGE_REACH_MAX` (4000), 240 from the centre of a clump, the sampled impulse equals
   `s · A · u0 · R · M/(2πr)` within the same tolerance. At reach 600 screening alone opens a 12.4% gap,
   so the test runs at the reach where the unscreened formula is the right oracle. Catches: `cellArea`
   in place of `u0 · R`, a missing `R`, a `2π` slip.
3. `tests/test_physics.nim`, "Pressure Past The Onset": `pressurePairImpulse` is zero at and below the
   onset, strictly increasing above, equal and opposite as one integer, and unchanged by force
   strength, matrix entry and crowding. Catches: pressure scaled by `fMul` (D11), a sign flip, a law
   with a step at the onset, a per-side quantization that breaks the integer symmetry. Fails to
   compile today.
4. `tests/test_physics.nim`, "The Force Law Is Untouched Below The Onset": at force strengths 0.7, 1
   and `FORCE_STRENGTH_MAX`, at frame factors 1 and 30, the velocity delta of a settled world below
   the onset is bit-identical with and without the term compiled in (both under the reference-frame
   convention of D8). Catches: the first draft's regrouping (35 207 of 100 000 products differ at
   0.7), a `−0.0` leaking into the force register, pressure integers routed into the velocity word.
5. `tests/test_balance_core.nim`, "A Compressed Crowd Stays Finite And Local": on the held-out seeds,
   32 aligned D16 bodies at the ceilings hold a 128 000-particle binned world; the held crowd's peak
   stays finite and the mean speed of crowds beyond the bodies' reach stays within the spread of a
   no-body run. Negative control: stiffness zero collapses past any finite bound the run can hold
   (the probe: 6 305 by frame 24). Catches: a live stiffness (far crowds heat), a term that vanishes
   above some density, a pressure that reads a coupling's strength.
6. `tests/test_balance_core.nim`, "Compression Is Not Remembered": on the held-out seeds, 900 frames
   after the bodies go, the mean neighbour count lies within the spread of fresh settles of the same
   seeds at the same frame count. Catches: a pressure too weak to separate a self-attracting clump
   (today 1 499 against 502), a hysteresis in the term.
7. `tests/test_balance_core.nim`, "A Settling World Still Settles": on the held-out seeds with no
   coupling, including self-attracting worlds that settle above the onset, the ratio of a late
   window's mean speed to an earlier window's lies within the no-term spread of that ratio at
   `FRICTION_MIN` and at the shipped friction. Catches: a stiffness above the D5 derivation (a
   sustained boil), a law with a step at the onset (the Tait row of D4). The derivation of `K` uses
   the calibration seeds, so this gate can fail.
8. `tests/test_preset.nim`: a version-4 long-range preset decodes to the converted strength, then the
   clamp. Catches: no branch (decodes unconverted), a factor inverted, zero not kept zero.
9. `tests/test_response_probe.nim`, "Couplings Are Compared On One Scale": each response probe's
   impulse at its range maximum, in `u0` at the reference configuration, agrees with that compressor's
   demand function evaluated directly. Catches: a probe still reporting in mesh cells, a demand
   function doubled or halved, a probe sampled at a different configuration. Under the relative
   ceiling the suite also reports each compressor's `x*` (D6) and asserts nothing about it: no
   absolute density bound exists to hold it under, and `x*` is finite by the law's form, so an
   assertion there could not fail (critique B2). Replaces the first draft's "Couplings Share One
   Unit", which was an identity.
10. The static assertions in `src/config_ranges.nim` for D8, the velocity word's summed full-crowd
    bound and the pressure word's: raise `MAX_PARTICLES`, `FORCE_STRENGTH_MAX` or `q_max` locally and
    the build fails. On today's code the velocity word's assertion fails the build (160 000 against
    32 767), which is its red step.
11. `tests/test_physics.nim`, "A Full Crowd Decodes To Its Impulse": `MAX_PARTICLES` neighbours at
    contact on one particle, at `FORCE_STRENGTH_MAX` and frame factor 30, encoded by the writer oracle
    and decoded by the integrate oracle, give the float impulse within one quantum times the frame
    factor, with its sign. Today the sum cannot fit: where this particle's share is converted once it
    saturates, decoding to about a fifth of the true impulse, and where neighbours add per pair the
    sum wraps and can decode with the wrong sign. Catches: the substep multiplied in before accumulation,
    the frame factor applied twice or not at all, a scale raised past the span, a writer left on the
    old convention (its impulse arrives 30× too large at frame factor 30).

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

### D13. Relaxation is history independence

After a compressor is removed, the mean neighbour count converges to a fresh settle from the same
seed. The small probe measured it failing today: one self-attracting species stays at 1 499 neighbours
against a fresh settle of 502. With a pressure the same world returned to 235 against 277 (run 2), and
at app scale the held crowd fell from 629 to 132–139 within 50 frames of removal (design notes). A
crowd above the onset has a repulsive term that grows with the excess, so the compressed state is not
a fixed point once the push is gone.

A self-attracting species settles looser than today: 456 → 308 crowd peak at app scale with onset
270 (design notes, batch C), 502 → 277 neighbours in the small world. Its own settle lies above an
onset that leaves mixed worlds untouched. That is the collapse the pressure bounds.

### D14. Friction 0: dense crowds shimmer

**The choice.** The pressure is not scaled by friction. At friction 0 a crowd above the onset
shimmers: its members keep moving, bounded by the soft speed cap, instead of coming to rest.

**Why.** A pressure read through a smoothed, one-frame lagged density is linearly unstable at velocity
retention 1 for every stiffness above zero (design notes, stability table), so no fixed stiffness
removes the shimmer. Scaling the stiffness with friction would remove the pressure at friction 0 and
reopen the collapse there, the way D11's alternative would at force strength 0.

**The cost.** At friction 0 dense crowds run warmer than without the term: in the probe, mean speed
4.5 against 3.9 for one self-attracting species (design notes, batch D). A world without the term
at friction 0 is itself warm, so the added motion is a fraction of what is already there. The
settling criterion of D5 at `FRICTION_MIN` compares the trend of motion, not its level, so it permits
the shimmer and still catches a boil that grows.

**What would reopen it.** Any of: the derivation at `FRICTION_MIN` (task 1.3) pins `K` below what the
relaxation gate (D10 test 6) needs; an in-app run at friction 0 showing a shimmer a player reads as a
bug; dense crowds at friction 0 reaching the soft cap's threshold of 25; pair viscosity above the onset
(D4) shown on the calibration seeds to remove the shimmer at a cost the pair-pass allotment holds.

The user accepted this on 13-09-26.

## Risks / Trade-offs

- [The onset band is measured on 400 frames and 5 seeds, and one world was still climbing] → Task
  1.2 measures longer runs on at least 16 calibration seeds before `x_on` is recorded.
- [Every probe is a CPU model; the GPU compiles under relaxed math] → GPU bit identity is
  unenforced (D4); the in-app run 6.2 compares the settled look.
- [A fixed stiffness cannot hold the stacked D16 column near the onset at app scale] → Accepted (D6):
  the held crowd stays finite and local, and relaxes; test 5 holds finiteness and locality.
- [A held or dense crowd costs more than the pair-pass allotment] → Accepted under the relative
  ceiling (D6); task 6.1 records the held figure, and the allotment gates the settled world.
- [At friction 0 a lagged pressure is linearly unstable] → Accepted as a shimmer (D14).
- [The reference-frame convention touches six writers; one left on the old convention writes 30× too
  hard on the largest substep] → Test 11 decodes a full crowd per writer oracle; the pairing between
  shader and oracle stays unenforced, as for every oracle.
- [The long-range, field-force and SPH per-particle maxima are not yet derived for the summed
  velocity-word assertion] → Task 2.3 derives or records each.
- [The pressure word's cost is unmeasured] → Task 1.5 measures it before the shader edit is accepted.
- [The per-pair saturation that fits the word may be too small for the column] → Task 1.4; the design
  returns if so.
- [Force strength 0 gains incompressibility above the onset] → D11.
- [A world whose settle sits above the onset looks different] → The onset lies above the calibration
  band; a self-attracting world is the intended exception (D13).

## Migration Plan

One schema bump (D7). Rollback is a revert: a version-5 preset loaded by the old code fails the
version check as any newer preset does (`src/preset.nim:753-758`, `pekNewerSchemaVersion`).

## Open Questions

None open to the user or the lead. The three user trades are decided (D6 hold, D6 ceiling, D14
friction 0), and the lead answered the allotment (Context) and the velocity word's ownership (D8).
