## Context

The proposal holds the evidence for the change (`proposal.md`, Why). The specs hold the requirements;
this design says how to meet them and why, and does not restate them. It supersedes the
`coupling-balance` design. Decisions C1–C15 carry that design's D1–D15 in the same order, with their
measurements. N1–N10 are new.

**Proven** means a run, a solve or a build established it, and the evidence is cited. **Designed**
means nothing has exercised it yet. Every probe cited under C1–C15 is a native CPU model of the
shader's expressions and never the GPU (`scratchpad/coupling-balance/`: `design-notes__13-09-26-1642.md`,
`lr_unit_probe.nim`, `pressure_probe.nim`, `app_scale_probe.nim`).

### The code as it stands

- **Time.** `dt = min(rawDt, 0.05) · timeScale` (`src/app.nim:239-241`). The frame factor is
  `ff = dt / FRAME_DT_REFERENCE`, with the reference frame 1/120 s (`src/physics_core.nim:23-36`). The
  shipped time scale is 0.5 (`src/preset.nim:243`), so a 60 Hz display at shipped settings runs at
  `ff = 1`. `ff` runs from 0.2 (60 Hz at `TIME_SCALE_MIN` 0.1) to 30 (the 0.05 s cap at
  `TIME_SCALE_MAX` 5, `src/config_ranges.nim:177-178`).
- **Integrate.** It decodes the velocity word at 2^16 (`web/shaders/src/integrate.wgsl:55-58`). It
  then applies `newVel = (vel + delta) · friction` (`:87-88`) and a soft cap with threshold
  `maxVelocity · 0.5`, a log excess above it and a hard cap at `maxVelocity` (`:90-100`). Last comes
  `pos += newVel`, with no `dt` (`:105-106`). The velocity state is therefore distance per step, and
  both friction and the cap act per step. `IntegrationParams` has three pad words at offsets 20–28
  (`:25-34`; Nim indices `INTEG_PAD1..3` at `src/gpu_types.nim:780-788`, written at
  `src/webgpu_compute.nim:1036-1041`).
- **Five velocity writers use three time conventions.**
  - `forces` multiplies by `params.dt` in seconds (`web/shaders/src/forces.wgsl:297,377`).
  - `forcesSph` multiplies its pressure by `params.dt` and its velocity blend by the frame factor.
    `fluidStrength` multiplies both (`web/shaders/src/forces-sph.wgsl:266-280`).
  - `fieldForce` takes the frame factor on the CPU (`src/webgpu_compute.nim:1064-1066`, through
    `frameScaledFieldForce`, `src/field_core.nim:209-216`), and so does `lrForce`
    (`src/webgpu_compute.nim:1125-1126`).
  - `bodyForce` takes it in the shader, from `BODY_FRAMES` (`src/webgpu_compute.nim:1097-1098`).
- **Substeps.** `substepCount = clamp(sphSubsteps, 1, SPH_MAX_SUBSTEPS)`, but only while the fluid
  acts (`src/webgpu_compute.nim:984-988`). `SIM_DT` is the substep's `dt` (`:992`). `SPH_MAX_SUBSTEPS`
  is 3 (`src/sph_core.nim:34`). The executor repeats every per-substep node
  (`src/webgpu_compute.nim:1248-1276`).
- **The field clock.** It is the rendered frame scaled by Time Scale, not `dt`.
  `rdStepsForTimeScale` sets the field steps a frame runs, and `depositFrameScale` holds the deposit
  per field step fixed (`src/field_core.nim:184-207`, used at `src/webgpu_compute.nim:272`).
- **The frame description.** One "Physics" node dispatches `binScatter`, `forces` and, while the
  fluid acts, `forcesSph` (`src/sim_registry.nim:389-395`). The long-range solve runs once per frame
  (`:409-417`). The field node (deposit, resolve, RD steps) runs once per frame (`:424-460`). "Field
  Force" and "Long Range Force" carry `PROFILER_SLOT_NONE` (`:467-480`). Bodies (`:491-500`) and
  integrate (`:506-508`) follow. The profiler has 9 passes (`src/gpu_profiler.nim:19-53`), mirrored
  by the registry's slot constants (`src/sim_registry.nim:251-280`). The pairing between the two is
  untested, because `gpu_profiler` does not compile natively (`:255-257`).
- **The physics figure.** `physics=` is `passPhysics + passIntegrate` (`src/app.nim:298-310`).
- **Bodies.** `BODY_BAND_FLOOR = BODY_PARTICLE_SPEED_CEILING · BODY_LARGEST_SUBSTEP_DT = 100 · 0.25 =
  25` (`src/body_core.nim:135-149,184-193`). That treats speed as distance per second. The integrator
  moves a particle up to `maxVelocity` per step, so at `MAX_VELOCITY_MAX` 100 a particle crosses 100
  per step, four times the floor (N9, defect 16). The CPU knows how many body slots are live
  (`liveSlots`, `src/body_core.nim:494`).
- **Files this change adds that do not exist yet:** `src/balance_core.nim` and
  `tests/test_balance_core.nim`.

### Quantities carried in (coupling-balance, native CPU probes)

| Quantity | Value | Status |
|---|---|---|
| `u0` | `FRAME_DT_REFERENCE` = 1/120 velocity per reference frame, one touching neighbour's repulsion at pair gain 1 | definition |
| `x_on` | 6.3 | the user's placement; G1.1 records the settles it separates at 128 000 and radius 50 |
| `K` | 540, no viscosity | the user's choice among measured arms; G1.2 confirms it on 16 seeds |
| `B_L` | ≈ 1.177 | provisional, batch M; G1.2 re-derives it under the step limit |
| `θ` (`PRESSURE_STEP_BOUND`) | 2 | the step limit's bound (C4b); replaces `ff_stable`, whose provisional 16 000-particle value of 12 disproved at 128 000 under the per-reference-frame cap: the bisection there reads 1 (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:44`, `runs/g1-ffstable-bisection__21-09-26-2024.log`) |
| `k`, `q_max` | 12; 11 310 coarse units = 706.9 velocity per reference frame per pair | derived by arithmetic |
| `ρ̄` | `N·π·R²/(3A)`: 5.1 at 16 000 and R 50, 40.4 at 128 000 and R 50, 364 at 128 000 and R 150 | exact for a uniform world |
| Lattice floor | 3.80 at `repulsionEnd` 0.5 | lattice sum |
| `a`, `U(R)` | 647.4; `U(R) = u0·R²·(a+R)/a²` | derived from `x_on` |
| Headroom | 11.65 ms (`w1-128k`, 30 s) is the working figure and a lower bound; 3.75 ms (`w1-128k-150`, the same world after 150 s, still climbing) | `docs/perf-report.md:132-147` |
| Neighbour-sweep allotment | 11.65 − 1.0 (long range) − 0.076 (bodies, idle) ≈ 10.57 ms | provisional on the in-app settled reading (G1.4) |
| Cost per extra substep at 128k | 1.56 ms (30 s run) or 7.95 ms (150 s run, a lower bound) | `docs/perf-report.md:83-84` harness figures |

The measurement gates, labelled here and used throughout:
- **G1.1–G1.5**, coupling-balance's five gates, carried unchanged (`proposal.md:128`):
  - G1.1: the settles the placed onset `x_on` separates
  - G1.2: the stiffness trade `K` and `B_L`
  - G1.3: the stacked hold
  - G1.4: the pressure's in-app cost and the settled headroom
  - G1.5: the frame-factor stability gate, now the crowding-redesign design's §3.5 arms under the
    lumped stiffness step limit (C4b), in place of the disproved `ff_stable` bisection
- **G2**: each coupling's full effect, measured in-app (`proposal.md:129`).
- **G3**: the chemistry-scale band (`proposal.md:130`).
- **G4**: the long-range cost with pressure on (`proposal.md:131`).

## Goals / Non-Goals

**Goals:**

- One unit in which every velocity writer's largest push is written and compared (`coupling-contract`).
- One time convention, applied at one site.
- Six coupling strengths on 0–1, each 1 a recorded full effect.
- The world's resistance to compression owned by the world and scaled by no strength
  (`world-pressure`).
- Stepping owned by the integrator, with no substep slider and no integrator limit leaking into an
  unrelated range.
- A live Pattern Scale on the chemistry.
- The reaction-diffusion field reaching particles only as force.
- The interaction-trace defects fixed.

Carried from coupling-balance:
- A long-range pull independent of mesh size, with one full effect at every interaction radius.
- A local pressure: a crowd's resistance depends only on that crowd's own density.
- Held crowds that stay local and finite and relax after release, at `K = 540`.
- Below the onset, the species term's delta changes only in its low bits, and is bit-identical at
  frame factor 1 (C4, C10).

**Non-Goals:**

- Choosing new shipped defaults beyond the ones this change's gates set. Those belong to
  `calibrate-shipped-defaults`.
- The bodies' falloff and their per-particle push, which belong to `parametric-bodies`. The push stays
  uncapped (C6).
- Transient impulses. The blast is a one-frame impulse, not a compressor.
- Bounding the heat of a held world. That is a finding for `parametric-bodies` (C6).
- The field's clock. The chemistry advances per rendered frame at Time Scale
  (`src/field_core.nim:184-207`), so a faster display runs the pattern faster in wall time. This
  change keeps that clock (N3).
- A Field Detail selector, or any change to the field's 2048 × 1152 resolution (`proposal.md:150`).
- Moving particle or halo sizes out of screen pixels (`proposal.md:149`).

## Decisions

### C1 (was D1). The shared unit is one touching neighbour over one reference frame

`u0 = FRAME_DT_REFERENCE`, the velocity per reference frame that one touching neighbour's repulsion
core hands a particle at **pair gain 1**. `src/balance_core.nim` owns it and one unit function per
velocity writer. Each function returns the largest per-particle impulse at a stated configuration, in
multiples of `u0` (`coupling-contract`, "Every velocity impulse is stated in one unit").

**What changed.** coupling-balance defined `u0` at force strength 1. The slider now runs 0–1 with a
pair gain of 5 behind it (N2), so the unit is anchored to the gain and not to any slider. The demand
functions become unit functions for every writer: the six couplings, the world pressure, the mouse
and the blast.

| Writer | Unit function at the reference configuration | Mirrors |
|---|---|---|
| Species (pair) | `g_pair · MATRIX_MAX_VALUE · 4 ·` edge neighbour sum; the ×4.0 is the pair law's recorded shape (N2) | `physics_core.polynomialForce` / `exponentialForce`, `forces.wgsl` |
| Fluid | `g_fluid ·` (the pressure clamp `SPH_MAX_PRESSURE_ACCEL` plus the velocity blend bound) per reference frame; `SPH_FORCE_SCALE` is the fluid's recorded shape | `sph_core`, `forces-sph.wgsl` |
| Scent | `g_scent(s) · |TROPISM_MIN| ·` inhibitor-gradient bound · world units per cell, at pattern scale `s` | `field_core`, `field-force.wgsl` |
| Long range | `g_LR · MATRIX_MAX_VALUE · A · (U(R)/u0) · M/(2π(a+R))` at the reference colony (C2) | `long_range_core`, `lr-force.wgsl` |
| Bodies | `Σ bodies BODY_FORCE_CEILING · strength · envelope / u0`, up to `MAX_BODIES`; `BODY_FORCE_CEILING` is the bodies' recorded shape | `body_core`, `body-force.wgsl` |
| World pressure | `min(K · 2φ(x) / 120, q_max)` per pair (C4) | `physics_core` pressure oracle |
| Mouse, blast | 300/120 and `3000 · blastStrength / 120` | `forces.wgsl:344,368` |
| Deposit | concentration per cell per field step, not `u0` (N3) | `field_core`, `field-deposit.wgsl` |

`balance_core` imports the oracles and never `config_ranges`, so `config_ranges` can import it and
assert against it.

Rejected:
- A unit of one reference frame at max speed. The cap is a soft log curve, not a force.
- A unit per coupling with conversion tables. That is the status quo, which let the couplings drift
  26–112× apart (`proposal.md:21`).

Evidence (**proven** for long range): a static mesh solve (`lr_unit_probe.nim`) agrees with the
long-range formula to 4% at 60 from the clump centre and reach 600 (55.4 by formula against 53.1
solved), and at 240 and reach 4000 within the gate bounds over a clump placed by seeds 42/7/1001
on both mesh sizes, per direction: along +x 0.604–0.720% (mean 0.675%, bound 0.7466%), along +y
4.127–4.309% (mean 4.223%, bound 4.320%). The fluid, scent, mouse and blast functions are
**designed**, not exercised.

### C2 (was D2). The long-range pull is measured in a radius-scaled pair unit, not in cell area

Today the impulse is `s · A · cellArea · M/(2πr)` inside the reach. Around a 1 000-particle clump the
coarse mesh pulls 4.0061–4.0104× harder at 240 from the centre and 4.0039–4.0050× harder at 600,
over a clump placed by seeds 42/7/1001 and sampled along +x and +y at reach 600. Under the unit the
mesh-to-mesh gap, with its gate bound per direction, is 0.153–0.198% along +x (mean 0.168%, bound
0.1977%) and 0.251–0.261% along +y (mean 0.256%, bound 0.2607%) at 240, and 0.098–0.106% along +x
(mean 0.101%, bound 0.1063%) and 0.104–0.126% along +y (mean 0.111%, bound 0.1258%) at 600. At 60
the ratio is 3.19
(`lr_unit_probe.nim`), so mesh independence holds only a few cell widths out. `cellArea` becomes `U(R) = u0 · R² · (a + R) / a²`, where `R` is the live interaction radius and
`a` the reference colony's radius. The kernel shape, `G(0) = 0`, the unit-charge deposit and the
fixed point stay. The one site is the value written to `LR_FORCE_SCALE`
(`src/webgpu_compute.nim:1125-1126`). A `long_range_core` function that the test also calls computes
it.

| Option | Sacrifice | Verdict |
|---|---|---|
| Stand still | The slider pulls 4× harder on one mesh, and there is no unit to derive a full effect from | Rejected |
| Normalize by `N` (a contrast potential) | Long range against pair scales as `1/N` at fixed local structure, so small worlds collapse | Rejected |
| Unit-integral Yukawa kernel `κ²/(k² + κ²)` | The far pull falls to about `M/r³` and distant groups stop answering | Rejected |
| Normalize by mean particles per cell | The same `1/N` dependence | Rejected |
| `u0 · R` in place of cell area | The derived full effect moves 18.4× across the radius range | Rejected by the user |
| **`U(R) = u0 · R² · (a + R) / a²`** | At a fixed strength the pull grows as `R²(a + R)`, 273× from radius 10 to 150 (`R²` times at most 1.21). Every saved long-range world changes unit (N7), and the unit carries `x_on` through `a` | **Chosen by the user** |

**The reference colony.** `M = MAX_PARTICLES` gathered into one disc at the onset density, with radius
`a = √(A_world / (π · x_on))`, which is independent of `R`. The pull on a particle one interaction
radius past the edge is `s · g_LR · A · U(R) · M / (2π(a + R))`. The pair force's peak edge impulse at
the onset density grows as `x_on · ρ̄ ∝ R²` at `N = MAX_PARTICLES`. Under `U(R)` the ratio between the
two loses every `R`, so one full effect holds at every radius. At `x_on = 6.3` in the 3840 × 2160
world, `a = 647.4` and `U(50)` is 0.083 of `u0 · 50`. Under `u0 · R` the ratio went as `R(a + R)`:
with an illustrative `x_on = 7` (`a = 614`) that is 6 241 at radius 10, 33 207 at 50 and 114 621 at
150, an 18.4× spread. The `u0 · R² / (a + R)` form on the option list the user chose from was an
algebra slip with the dimension of a velocity. The form above has the property the option described.

**What changed.** coupling-balance derived `LONG_RANGE_STRENGTH_MAX` from the reference colony. Here
the same derivation sets the full effect `F_LR`, at strength 1 (`coupling-contract`, "The long-range
pull is measured in the pair unit and not in mesh cells"), so the range is 0–1 and the gain is
`g_LR = F_LR / unit_LR(ref)`. The pair force's edge impulse in that derivation is taken at pair
strength 1 (gain 5), which is the old `FORCE_STRENGTH_MAX` the D2 derivation used. The number is
unchanged.

The diagnosis report's red test "scaling deposits leaves the gradient unchanged" stays rejected,
because it would hold a contrast potential. Mesh-size independence and the Green's-function formula
take its place (C10, tests 1 and 2).

**Open finding.** At reach 4000 and 240 from the clump, the Green's-function miss along +y
(4.127–4.309%) runs about 6× the miss along +x (0.604–0.720%) on both mesh sizes; the cause is
untested, and the candidates both sizes share are the grids' 2:1 aspect and the world's 16:9 torus.

### C3 (was D3). The density the pressure reads is measured in the world's own mean

The pressure reads `x = ρ/ρ̄`, with `ρ̄ = N·π·R²/(3A)` from the live count, radius and world area. A
`balance_core` function computes it once per frame, and the frame writes it as a uniform. The onset
is `ρ_on = max(x_on · ρ̄, ρ_floor)`, where `ρ_floor` is the crowd density of a hexagonal lattice at the
pair law's rest spacing for an attracting pair. `balance_core` computes that floor by lattice sum,
reading `CROWD_PACKING_CONSTANT` as it moves there from `physics_core` (`bounded-crowding`, REMOVED
"A density ceiling exists and is computed").

Evidence (**proven** on CPU):
- Batch A settled worlds with no coupling acting at 16 000 and 128 000 particles and radii 50 and 100.
  Their peaks spread 60× in `ρ` (11.6 to 721), yet in `x` they sit in one band: 2.2–6.6 for mixed
  matrices and 9.7–11.3 for a self-attracting species.
- Batch G covered 10 worlds from 100 to 128 000 particles and radius 10 to 150, 3 seeds, 600 frames.
  It showed the ratio alone fails at small `N · R²`: at 1 000 and radius 10 one pair reads `x = 40`.
- Lattice floors by rest spacing:

  | Spacing | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 | 0.6 | 0.75 | 0.9 |
  |---|---|---|---|---|---|---|---|---|
  | Floor | 120.0 | 29.3 | 12.6 | 6.64 | 3.80 | 2.40 | 1.50 | 0.60 |

  At the preset `repulsionEnd` of 0.5 the floor is 3.80. That sits above every mixed peak at 16 000
  and radius 10 (3.2) and below every self-attracting peak there (5.4).
- The exponential model's floor is unprobed (`openspec/changes/archive/2026-09-18-coupling-balance/design.md:216-219`). G1.1 runs the polynomial model only, so it stays unprobed.

Where the floor and the ratio do not separate the two kinds of world:
- Mixed peaks past the floor reach 9.1 (128 000 at radius 10), 8.0 (16 000 at 20) and 7.9 (1 000 at 50).
- Self-attracting settles read 6.3–7.9 at 1 000 and radius 150, and 8.9–13 at 1 000 and radius 50.

**Placement: `x_on = 6.3` (the user's decision).** It trims the densest particles of dense mixed
settles by about 20%. At 128 000 and radius 10 with `x_on = 6` the densest crowd fell from 14.7 to
11.8, while p99, weighted neighbours and mean speed stayed unchanged to the printed digit (batch I-a).
Mixed clumps that a hold merged stay merged after release.

G1.1 does not derive `x_on`; it records what 6.3 separates (`scratchpad/core-force-interface/g1-onset__21-09-26-2024.md`).
At 128 000 particles and radius 50, on the gate seeds, the end-of-window p99.9 `x` reads 10.56–11.46
for one self-attracting species and 2.88–3.34 for four species that each attract only themselves.
So 6.3 spares the mixed-like worlds and engages in the self-attracting ones. The band's margin rule
(mean less the largest run's distance) gives 2.657 over the bimodal six runs, below every run, and is
recorded as measured, not adopted.

| Option | Verdict |
|---|---|
| Onset and ceiling in `ρ` | Rejected by batch A |
| `x` in units of `n · R^k` with a fitted `k ≠ 2` | Not chosen: batch A's two radii cannot fix `k` better than the exact 2 |
| `x = ρ/ρ̄` alone | Rejected by batch G |
| `x_on` above every mixed peak (≈ 9.1) | Rejected: some self-attracting settles would get no pressure |
| `x_on ≈ 3` | Rejected: ordinary mixed settles change; merged-clump memory halves (1.16–1.28 against 1.37–1.71, batch L) |
| **`ρ_on = max(x_on·ρ̄, ρ_floor)`, `x_on ≈ 6.3`** | **Chosen** |

**What changed.** Nothing but ownership: `ρ̄` and the floor are named in `world-pressure` ("The onset
and the stiffness are derived and fixed").

### C4 (was D4). The pressure term lives per pair, inside the existing loop

```
φ(ρ)   = (max(ρ − ρ_on, 0) / ρ_on)²
c      = min(K · (φ_this + φ_other) / 120, q_max)                 the saturated sum, before the weight
m      = c · (1 − r/R)                                            per reference frame, no dt
slope  = c / R                                                    the pair's radial stiffness, added to both particles' stiffness words
qx, qy = trunc(−m · (separation/r) · 2^16)                       one integer per component
this  += (qx, qy);  other −= (qx, qy)                            split across fine and coarse (C8)
```

`φ_this` is hoisted beside `attenuationOnThis`. The magnitude saturates before the direction is
applied, and the sum saturates before the proximity weight, so the pair's radial slope stays bounded
by `q_max/R` at every distance (crowding-redesign design, §3.1). The species term keeps its grouping,
`forceMagnitudeOnThis *= params.forceMultiplier * invDistance` (`forces.wgsl:282`), and the pressure is
formed and accumulated apart from it, so below the onset the species term's integers are today's at
every Force Strength.

**Proven** on the oracle: the pressure integers a pair exchanges are exactly opposite, because one
integer pair goes to both particles. **Narrowed:** this holds for the words, not for the integrated
velocity. Integrate's step limit (crowding-redesign design, §3.4) scales a particle's whole decoded
delta by its own `s`, and two particles in one pair may carry different `D` and so different `s`, so
the integrated change is not exactly opposite where neighbouring `s` differ. The critic measured the
first draft's regrouping changing 35 207 of 100 000 products at strength 0.7; this form does not
regroup. GPU bit identity is **unenforced**. Dawn's Metal backend compiles
with relaxed math unless strict math is set
(https://raw.githubusercontent.com/google/dawn/main/src/dawn/native/metal/ShaderModuleMTL.mm,
lines 464-468 and 564). Strict math is set only through the `ShaderModuleCompilationOptions` chained
struct (https://raw.githubusercontent.com/google/dawn/main/src/dawn/native/ShaderModule.cpp, lines
1837-1839), and `src/webgpu_init.nim` passes no such option, so this app's shaders compile relaxed on
Metal unless the browser chains that struct itself.

| Placement | Verdict and evidence |
|---|---|
| Stand still | Rejected: collapse under every compressor, with 1 499 of 1 500 neighbours stuck |
| Integrate pass, along `∇ρ` | Rejected on cost: it needs a second neighbour pass |
| Grid pressure | Rejected on cost: one cell is coarser than `R` on the shipped mesh |
| Onset-shifted Tait on `sphDensity` | Rejected: the fluid pass is skipped at fluid 0. Its slope step at the onset boiled the settle at mean speed 4.02 against 1.47 for the square law (batch B) |
| Onset-shifted Tait on crowd density | Rejected: it keeps the onset step (batch B) |
| Unsmoothed crowd density | Not chosen: crowding's look would change, and at a fixed high stiffness it did not stop the boil (run 5, mean 6.41) |
| Density gate on outside pushes | Rejected by the user: a dense crowd would stop hearing bodies, long range, scent and the mouse. The held peak was 394 against 608 |
| Pair viscosity 0.5 | Rejected by the user in favour of `K = 540` without it (C13). At 128 000: L 0.864–0.890 and simmer 0.107–0.125 (batch M) |
| Implicit density projection | Rejected on performance, the top priority |
| **Pair term on the smoothed crowd density, split across the two words** | **Chosen** |
| Explicit push, no step limit (`ff_stable`, `n_ff`) | Rejected: at 128 000 the step is unstable from frame factor 2 (3.09×) up to 30 (7.97×), and jittered arms read 5.42× and 5.47× (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:38-63`) |
| Lumped stiffness step limit at integrate | **Chosen** for stability: `s = min(1, θ/(2·ff·D))` scales the whole decoded delta at integrate; stable at every frame factor by construction, no new pass, no recorded stability limit (crowding-redesign design, §3.4, §6) |
| Pair-symmetric limit inside the loop, from last step's `D` | Rejected: `D` lags a whole step, and at ff 30 a particle can travel past its own neighbour set before the bound it rests on is re-read; it also spends the "only integrate reads the frame factor" invariant, since `forces.wgsl` would need `ff` as a uniform (crowding-redesign design, §5) |
| Position-based Jacobi correction, applied after integrate | Rejected: a new law, re-deriving `x_on`, `K`, `B_L` and C6's capacity from scratch; the crowd loses inertia per step, and restoring it re-enters the explicit limit it was meant to replace (crowding-redesign design, §5) |

**What changed.** "Force strength" reads as Force Strength on the new 0–1 scale. The term is named in
`world-pressure`. The stability of the step at every frame factor is C4b, below.

### C4b. The lumped stiffness step limit removes the explicit scheme's stability bound

The explicit scheme (`v' = r·(v + ff·Δ)`, `x' = x + v'`) is stable only while `ff·λ < 2(1+r)/r`, where
a particle's `λ` is bounded by twice its summed pair slope `D = Σ_j slope_ij`. Integrate decodes `D`
from two stiffness words (fine at `STIFFNESS_FIXED_POINT_SCALE = 2^16`, coarse at
`STIFFNESS_COARSE_SHIFT`, split and decoded as the velocity words are) and forms
`s = min(1, θ/(2·ff·D))`, then multiplies the particle's whole decoded delta — every writer, not the
pressure alone — by `s`. `s = 1` exactly where `2·ff·D ≤ θ`, so a below-onset particle's step is
bit-identical to today's at every frame factor. `θ = PRESSURE_STEP_BOUND = 2`, half the symplectic
bound of 4 at retention 1, leaving a factor of 2 for the density lag (C4, `ρ` carries a 0.7-retained
smoothing) and for the slopes `D` omits (transverse pair terms, which only loosen the bound). The
argument, and the code sites, are the crowding-redesign design's §3.1–§3.4; the tests are its §8, T1–T7.

**What it keeps.** A static balance — total force zero — is unchanged at every frame factor, since `s`
scales every writer alike: the ratio between the pressure and the compressors on one particle holds, so
a held crowd reaches the same depth at time scale 5 as at 0.5, only more slowly per reference frame.

**What it gives up.** Two particles with different `s` receive unequal halves of one pair's pressure
(C4's narrowed "Proven" paragraph). At time scale 2–5, dense crowds answer the mouse, blast and bodies
more slowly per reference frame — the same balance, reached more slowly. The user accepted this
(crowding-redesign design, the user's decisions); task 4.10's help line and 12.1's in-app reading state
it.

### C5 (was D5). The stiffness is fixed, and the square law rises with the crowd's own density

A live stiffness breaks locality. A stiffness ramp from 54 to 1728 with no body present gave these
first-frame mean speeds:

| Schedule | First-frame mean speed | Once at 1728 |
|---|---|---|
| Step | 9.61 (from 1.47) | 1.3–8.7 |
| Ramp over 60 frames | 1.61 | 1.5–5.7 |
| Ramp over 240 frames | 1.55 | 2.6–4.4 |

The square law's local stiffness is `2K · (x − x_on)/x_on²`: zero at the onset, rising with the
excess. Rejected laws:
- The barrier `t²/(1 − t)` needed saturation. Single frames wrote 38 284 and 31 870 against a 32 768
  span, and 481 635 per particle at app scale. It held the column only 7–12% lower (812 against 918).
- Tait has the onset step.

**The settle statistic.** `L` is the late-window mean speed with the term over the same seed's without
it, at `FRICTION_MIN`, on frames 749, 799, 849 and 899. At friction 0 the no-term world moves at
1.28–1.32, a well-conditioned denominator. At shipped friction it moves at 0.000–0.005, which is not.
The late-over-early ratio stays withdrawn.

Measured L (**proven** on CPU):
- 16 000, 8 seeds: square `K = 54` 0.963 (sd 0.0068); Tait `K = 54` 1.221 (sd 0.0257).
- 16 000, 3 seeds: square 173 → 0.984, 540 → 1.036, 1728 → 1.117, 5400 → 1.249; Tait 5.4 → 1.012,
  17 → 1.078 (batch H).
- 128 000, 3 seeds, **superseded by the step limit (below):**
  - `K = 540` → 1.163–1.175
  - `K = 1728` with viscosity → 1.220–1.261 (batch M)
  - `K = 1728` without viscosity → 1.360–1.393 (lower bound 1.347)
  - Tait `K = 54` → 1.525–1.605 (batch R)

**Re-measured under the step limit.** These 128 000-particle figures, and `B_L` below, were measured
against the explicit scheme, which is unstable at 128 000 from frame factor 2
(`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:44`). The crowding-redesign design's
lumped stiffness step limit (C4b) replaces that scheme; task 4.5 reruns `L` at `K = 540` and 1728 under
the limit, and the 540-vs-1728 trade is re-decided from that rerun (Q1, crowding-redesign design §11).
`K = 540` stands as the user's placement pending that rerun.

**`B_L`.** `B_L` is the mean of `L` over the three gate seeds at 128 000 particles plus the largest
single seed's distance from that mean. On C13's seeds, against the explicit scheme, 540 read
1.163–1.175, so provisionally **`B_L ≈ 1.177`**. G1.2, rerun under the step limit, replaces it.

**The margin, stated once.** Every gate runs the three gate seeds 42, 7 and 1001 at 128 000
particles. A gate passes when the three-seed mean is at most its bound. A bound derived from a run is
that run's mean plus the largest single seed's distance from it.

**At shipped friction the square law adds a simmer that no `K` removes.** It reads 0.05–0.10 at every
square `K` against 0.000–0.005 without the term, and 0.028–0.115 at `K = 540` and 128 000 (batch M).
The user accepted it; it is observed in-app and not gated.

At 16 000 particles, onset `x = 7`, 3 seeds (batches H, J, L):

| Law | L at friction 0 | After-release over fresh |
|---|---|---|
| square `K = 173` | 0.984 | 1.096–1.106 |
| square `K = 540` | 1.036 | 1.018–1.037 |
| square `K = 1728` | 1.117 | 0.968–0.991 |
| square 540, viscosity 0.5 | 0.956–0.970 | 1.075–1.106 |
| square 1728, viscosity 0.5 | 1.048–1.089 | 0.972–0.995 |

Stability at every frame factor no longer rests on a linear model of the lagged, smoothed pressure
alone: C4b's bound, `ff · λ_max ≤ θ < 4`, holds by construction for every frame factor, radius and
count, and the density lag and the slopes `D` omits are the margin `θ = 2` leaves under the symplectic
bound of 4. A static balance — total force zero on a particle — is unchanged by the limit, since `s`
scales every writer on that particle alike; a held crowd reaches the same depth at every frame factor,
only more slowly per reference frame at high ones (C4b).

**What changed.** `K` stands at the user's placement, pending the 540-vs-1728 rerun under the limit
(task 4.5, Q1). `K`, `B_L` and the step-limit bound `θ` live in `src/config_ranges.nim`
(`world-pressure`).

### C6 (was D6). What the fixed pressure holds, and the column it cannot

A column under a constant inward push `F` on a disc of mass `M` at number density `n` has centre
pressure `F · √(M·n/π)`. The 2D virial pressure of a pair push `p(1 − r/R)` is `3ρ²p/(8πR)`, so the
contact push that answers a column is `p = 8F√(3M)/(3ρ^1.5)`. That is 15.8 per pair in the small probe
world, where `K = 1728` supplied about 23 and held, and 138 at 128 000 with 32 stacked bodies at crowd
density 250.

At app scale (128 000, radius 50, 12 species, seed 42, 32 aligned bodies at the ceilings), the table
below was measured at frame factor 1, against the explicit scheme. Under the step limit (C4b) a held
crowd reaches the same balance at every frame factor — the ratio between the pressure and the
compressors on a particle is unchanged by `s` — only more slowly per reference frame at high ones, so
these held-peak and far-speed readings stand as frame-factor-1 readings:

| Pressure | Held peak (p99) | Largest delta per particle per reference frame | Far mean speed | After removal |
|---|---|---|---|---|
| None | 6 305 (5 238) by frame 24, still collapsing | 0 | 0.27 | not reached |
| Square `K = 54`, onset 120 | 602–629 (523–579) | 4 103 | 0.27–0.30 | 132–139 within 50 frames |
| Square `K = 54`, gate | 383–505 (341–446) | 1 526 | 0.27–0.30 | 111–129 |
| Square `K = 54`, onset 270 | 894–935 (780–846) | 2 275 | 0.27–0.28 | unmeasured |
| Barrier, saturation 1 000, onset 270 | 812–875 (683–756) | 481 635 | 0.27–0.29 | unmeasured |
| Square `K = 540`, onset 270 | 638 (552) at frame 24 | 2 676 | 0.27 | unmeasured |
| Square `K = 1728`, onset 270 | 589 (502) at frame 24 | 6 527 | 0.27 | unmeasured |

**Capacity.** `C(x) = 3(xρ̄)² · K · φ(x) / (480π · R)` below saturation. It is reported per coupling
as `x*`, the density at which capacity meets demand, and asserted nothing about
(`coupling-contract`, "Couplings are compared on one scale").

**Decision (the user's): a strong hold compresses a finite, local crowd.**
- It passes the onset while held, relaxes after, and costs more while held: 245 weighted neighbours
  against 41 settled.
- In-app, Hold 10 raised GPU physics from 0.99 to 101.89 ms while the bodies slot stayed at 0.07 ms
  (`scratchpad/parametric-bodies/in-app__13-09-26-1616.md`, observations 1 and 3). The share of the
  neighbour sweep in that is not isolated.
- The ceiling is relative. No absolute crowd-density or cost ceiling is imposed. The allotment bounds
  the cost the term adds to a settled world at `MAX_PARTICLES`.

Rejected:
- The density gate.
- A higher fixed stiffness: 32× the stiffness bought a third lower peak and warmed a no-body settle
  (0.47 against 0.26).
- Implicit projection.

**Finite at every setting.** Past `q_max` the virial pressure still grows as `ρ²`, so a static balance
exists. The held world is dynamic, so gate 5 checks it against the stiffness-zero control.

**Finding for `parametric-bodies`.** Under 32 stacked bodies the world ran at mean speed 16–17 with or
without pressure. The small world ran at 23.2–25.2 without and 29.7–31.3 with `K = 1728`, against a
soft-cap threshold of 25 (`integrate.wgsl:90-100`, shipped `maxVelocity` 50).

**What changed.** The compressors at their maxima are the couplings at strength 1. The same hold with
long range, scent and the mouse at 1 is a SHALL in `world-pressure:130`. In coupling-balance it was a
SHOULD, and it stays unenforced by a suite (inconsistency 12).

### C7 (was D7). Presets: a conversion, then the clamp decides

`CURRENT_SCHEMA_VERSION` goes from 4 to 5 with a `fromVersion < 5` branch. The factor
`cellArea(savedGridIndex) / U(savedRadius)` runs from 177.4 (512 × 256, radius 150) to 193 645
(256 × 128, radius 10), and is 1 825 at the shipped mesh and radius 50. The same conversion moves the
long-range strength. Zero stays zero. The clamp decides after conversion. No shipped preset carries a
non-zero long-range strength (the default is 0.0, `src/preset.nim:276`, and the repo ships no preset
files).

Two consequences reach the help text:
- After loading, moving the radius moves long range, about as `R²`.
- `x_on` is part of the long-range unit. `src/preset.nim` records the `x_on` of version 5, and a
  static assertion holds it equal to the live constant. A re-derived `x_on` then fails the build until
  a new branch converts.

**What changed.** The branch now converts every coupling strength, drops three fields, and restates
the Force Weather waypoints (N7). `long-range-mesh`'s "no schema version and no migration branch"
(`openspec/changes/long-range-mesh/specs/long-range-coupling/spec.md:300,309`) is amended in the same
pass (N10).

Rejected: loading unconverted, which changes every saved long-range world by the factor.

### C8 (was D8). Every velocity impulse accumulates per reference frame, in a fine and a coarse word

WGSL `i32` arithmetic wraps, and float-to-int conversion clamps (https://www.w3.org/TR/WGSL/). The
bound is therefore on each conversion and on each final sum, over a full crowd of `MAX_PARTICLES`.

| Writer | Per-contribution maximum per reference frame | Full crowd × 2^16 at ff 1 |
|---|---|---|
| Species (pair) | `g_pair 5 · 1.66/120 = 0.0692` (exponential at contact; polynomial peaks at 1.32) | 5.80 × 10⁸ |
| Mouse | 300/120 = 2.5 | 1.64 × 10⁵ |
| Blast | 3000/120 = 25 | 1.64 × 10⁶ |
| Fluid | pressure 5000/120 = 41.7 plus the blend (1 + 0.5) · 2 · 100 = 300, at `g_fluid` ≤ 1 | 2.87 × 10¹², 1 335× the span |
| Bodies | 32 · `BODY_MAX_FORCE_PER_PARTICLE` 20 = 640 | 4.19 × 10⁷ |
| Scent, long range | derived by their unit functions at strength 1 (N2) | must fit the 7 251 left at `k = 12` (`VELOCITY_FINE_ROOM`) |

Remedies rejected:
- Narrowing any range. That fixes the ceiling and not the mechanism.
- A neighbour cap in SPH, which would be order-dependent and anisotropic.
- One coarser scale for the whole word, a 1/32 quantum for every writer.
- A word per writer, since SPH alone is still 1 335× over.
- SPH as a gather, which doubles its pair evaluations.

**Chosen:** per reference frame, with SPH and the pressure split across a fine word at 2^16 and a
coarse word counting `2^k` fine quanta. `q >> k` goes to the coarse word and `q & (2^k − 1)` to the
fine word. The arithmetic right shift makes the split exact. The "this" side splits its float register
once per particle. `forces.wgsl` reaches 8 storage bindings, the WebGPU default limit
(`webgpu_init.nim:351-358` does not raise it).

**Derived constants.**
- `k = 12`. The fine word's full-crowd sum is 1.672 × 10⁹, with headroom 1.28. At 13 it would be
  2.68 × 10⁹, which does not fit. If scent and long range need more than 7 251, `k` falls to 11.
  Long range at its live maxima is 2 589 (at `x_on` 6.3, grid 256 × 128, `R` 10). Scent is
  37.5 · 1 per unit of inhibitor gradient, 18.75 while the inhibitor stays in [0, 1], and the room
  left after long range admits a gradient up to 124. `k = 12` holds.
- SPH takes `⌈341.7 · 2^16/2^k⌉ = 5 467` coarse units. `q_max = ⌊(2^31 − 1)/MAX_PARTICLES⌋ − 5 467 =
  11 310`, which is 706.9 velocity per reference frame per pair. The margin is 27 647, or 0.0013%.
- **The stiffness words' full crowd** (C4b): the fine word's is `MAX_PARTICLES · (2^STIFFNESS_COARSE_SHIFT − 1) ≈ 5.24 × 10⁸`; the coarse word's is
  `MAX_PARTICLES · (q_max/INTERACTION_RADIUS_MIN) · 2^16/2^STIFFNESS_COARSE_SHIFT ≈ 1.45 × 10⁸`. Both sit below
  `2^31 − 1`. The crowd buffer moves from stride 1 to stride 3 — crowd density, stiffness fine, stiffness
  coarse — and `forces.wgsl` stays at 8 storage bindings, its default limit (K7): the two stiffness words
  reuse the crowd buffer's binding rather than adding one.

**What changed.**
- The pair row reads `g_pair` in place of `FORCE_STRENGTH_MAX`. The value is the same 5.
- **The fluid row is budgeted at `g_fluid = 1`, the fluid's gain ceiling.** A static assertion holds
  `g_fluid ≤ 1`, so `k` and `q_max` stay where the gates measured them when `F_fluid` moves below it.
  This meets "q_max SHALL be the largest per-pair pressure the coarse word admits after SPH's" with
  SPH's share taken at its gain ceiling.
- The body row loses `BODY_LARGEST_FRAME_FACTOR`, because the writer no longer multiplies by frames
  (N3). `BODY_MAX_FORCE_PER_PARTICLE` becomes `2 · BODY_FORCE_CEILING · BODY_STRENGTH_CEILING = 20`
  per reference frame, and the body accumulator's assertion (`src/body_core.nim:195-199`) follows.
- The `fixed_point.wgsl` header's "far more range than a per-frame impulse ever needs" is false. It is
  rewritten (N9).
- The five-writer conversion order is N3.

### C9 (was D9). The pressure is part of the pair law; crowding is a texture control

| Classification | Verdict |
|---|---|
| A new coupling strength | Rejected: zero would be the collapsed world |
| An extension of crowding | Rejected: crowding ships at 0 |
| **Part of the pair law, world-intrinsic, no slider** | **Chosen** |

The onset is a zero of a continuous function, so it is not a mode, and `test_no_modes` gains nothing.
The step limit (C4b) is likewise a continuous function of `D` and the frame factor, `s = min(1,
θ/(2·ff·D))`, with no branch a mode could hide in: it reaches 1 exactly, not approximately, whenever
`2·ff·D ≤ θ`. Crowding stays a texture control, and `calibrate-shipped-defaults` calibrates it by
`c_soften` alone (C12).

**What changed.** The density-ceiling block (`src/physics_core.nim:108-224`) and suite "The Density
Ceiling" are deleted, and `CROWD_PACKING_CONSTANT` moves to `balance_core`'s floor. The comments at
`src/config_ranges.nim:37-41` and `:46-54` that cite the crowding ceiling are rewritten (N9).

### C10 (was D10). Red tests first, each able to fail

Seeds, recipes and oracles are carried. Every constant derived from a run, and every behavioural
gate, uses the three gate seeds at 128 000 particles with the C5 margin.

Gates 5–7 run in `just calibrate-balance`, at about 1.3 s per step (batch M: 1 171–1 275 s per
900-step run). It does not run in `just check`. It runs when the term lands and again on any change
to:
- `K`
- the pressure law
- the onset
- `k` or `q_max`
- how `ρ̄`, the floor or the smoothing depend on particle count
- `θ` (`PRESSURE_STEP_BOUND`) or the step limit itself (C4b)

Today-convention encode and decode oracles are written first (N3, step 1), so red steps fail on
values and not on compilation.

Tests, with coupling-balance's numbering kept and the new suite names from the specs:

1. `test_long_range_core` "The Pull Does Not Depend On Mesh Size". The gap is within the static
   solve's gate bounds per direction (C2): 0.1977% along +x and 0.2607% along +y at 240, 0.1063% and
   0.1258% at 600. Catches `cellArea` left in (300%).
2. Same file, "The Pull Is The Pair Unit Spread By The Green's Function". At reach 4000 and 240 from
   the centre, within the gate bounds per direction (C1), 0.7466% along +x and 4.320% along +y, at
   radii 10, 50 and 150. Catches `cellArea` (1 825×), `u0·R` (0.083 at
   radius 50), `a + R` dropped (1.21 at 150), and a `2π` slip.
   - 2b. **Changed:** "One Long-Range Full Effect Holds At Every Radius". `F_LR`'s derivation returns
     the same value at radii 10, 50 and 150. Catches 18.4× and the slipped form's 1.47×.
3. `test_physics` "Pressure Past The Onset", as in `world-pressure`.
4. **Renamed and re-armed:** `test_physics` "The Species Term Is Untouched Below The Onset". It runs
   at Force Strength **0.14, 0.2, 0.5 and 1** on the new scale, at ff 1. That is old 0.7, 1, 2.5 and 5.
   0.14 is kept beyond the spec's three because the measured falsifier (35 207 of 100 000) was taken
   at old 0.7.
   - 4b. "Today's Low Bits Move By Less Than The Frame Factor" at ff 1, 2 and 30.
5. `test_balance_core` "A Compressed Crowd Stays Local And Below Its Collapse". The pressured peak was
   95–171 against a control of 1 558–6 116 within 100 held frames (batches I-b, J). At 128 000:
   638 against 6 305 at frame 24 (C6).
6. "Compression Is Not Remembered" at 128 000 against 1 (0.971–0.976, batch M). Falsifiers:
   1.16–1.19 at `K = 54`, 1.10 at 173 (at 16 000).
7. "A Settling World Still Settles":
   - Friction 0 at 128 000, ff 1, against `B_L`. Falsifiers: 1.220–1.261, 1.360–1.393 and
     1.525–1.605.
   - Frame-factor arms at 128 000 and shipped friction: sustained ff 0.42, 2, 4.2, 10 and 30, uniform
     8–16, alternating 10/13, and held frames (ff 0.42 with single ff-30 steps), run through the step
     limit (C4b) rather than the substep rule — C15's `ff_stable`/`n_ff` path is disproved at 128 000
     (below) and replaced by §3.5's arms A–D. Falsifier at 128 000, against the explicit scheme with no
     limit: ff 2 reads 3.09× and ff 4 reads 8.32×
     (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:109`).
8. **Widened:** `test_preset`, the version-5 suite `coupling-contract` names. Every coupling strength
   at each grid size and two radii (N7).
9. `test_response_probe` "Couplings Are Compared On One Scale". It reports `x*` and asserts nothing
   about it.
10. The two word assertions in `src/config_ranges.nim` (C8). On today's code the single-word
    assertion fails, because SPH is 1 335× the span.
11. `test_physics` "A Full Crowd Decodes To Its Impulse", for every writer, at ff 1, 2 and 30. **Gains
    a `D > 0` arm** (C4b): the decoded delta at nonzero stiffness is `s · ff · impulse` for the
    hand-computed `s`.
12. **Renamed:** `test_balance_core` "Every Writer Answers In The Pair Unit", over every unit
    function.

**T1–T7, the step limit (C4b).** Each fails for one reason, stub-first (a stub `stepLimit` returning 1
and a stub slope returning 0, so T1–T4, T6, T8 and T10 read red on values, not on a missing symbol):
- T1 "The Step Limit Leaves A Calm Particle Untouched": zero stiffness gives integrate output
  bit-identical to today's at every frame factor.
- T2 "A Stiff Particle's Step Stays Inside The Bound": for random `(ff, D)`, `2·ff·s·D ≤ θ` and `s = 1`
  exactly where `2·ff·D ≤ θ`.
- T3 "A Pair's Stiffness Is Its Radial Slope": the slope equals the central finite difference of the
  impulse in `r`; zero at and below the onset; `≤ q_max/R`.
- T4 "The Stiffness Words Decode To The Summed Slope": a full crowd of `MAX_PARTICLES` pairs at
  `q_max/INTERACTION_RADIUS_MIN` encodes and decodes within `n · 2^-17` of the f64 sum; the two static
  assertions (C8) hold.
- T5 "A Limited Step Cannot Overshoot" (property, on the oracle, not calibration): 20 random crowds'
  linear one-step map, built from the oracle's pressure Hessian and `D`, has spectral radius ≤ 1 + 1e-6
  at every frame factor the app produces and both frictions; the same map with `s ≡ 1` exceeds 1 at ff
  30.
- T6 "The Step Limit Scales Every Writer Alike": with species, pressure and body words set on one
  particle, the decoded delta is `s · ff · (sum)` for the hand-computed `s`.
- T7 "A Balance Holds At Every Frame Factor" (integration, not calibration): a held crowd settles to the
  same peak density at ff 30 as at ff 0.25, within the seed spread.

The new suites the specs add are listed under N1–N9 where each lands.

### C11 (was D11). Force Strength 0 still resists compression above the onset

The pressure is not scaled by Force Strength, and the step limit `s` (C4b) reads no Force Strength
either: it is a function of `ff` and a particle's summed stiffness `D` alone. With the pair law off, a
gated world with no pressure held at 618–658 and stayed at 602 after the body went. The same world with
pressure relaxed to 105 (g0). The cost: a player cannot turn incompressibility off. On a limited
particle (`s < 1`) the species impulse scales by the same `s` the pressure's does, since `s` multiplies
the whole decoded delta (C4b): Force Strength 0 removes the species term from that delta, but does not
change what `s` is.

Reopen it on any of:
- a player need for dense crowds that pass through each other
- a push bound in `parametric-bodies` that makes collapse impossible
- an in-app artefact at Force Strength 0

The user accepted this and asked for it to stay visible. **What changed:** the spec wording (the
species term adds exactly zero at 0, `coupling-contract`).

### C12 (was D12). Interaction with `calibrate-shipped-defaults`

Two changes carry over (`openspec/changes/calibrate-shipped-defaults/design.md:110-133`):
- Fixture C becomes a world that settles above the onset, gated by "its crowd rises past the onset at
  crowding 0".
- `c_hold` becomes vacuous.

**What changed:** its Force Strength values restate on the 0–1 scale (÷5), with the edits made in
the same pass (N10).

### C13 (was D13). Relaxation is history independence, and as measured it holds only in part

Today a small world stays at 1 499 neighbours against a fresh 502. With the pressure it returns to 235
against 277, and at app scale 629 falls to 132–139 within 50 frames. A self-attracting species settles
looser: 456 → 308 crowd peak, 502 → 277 neighbours.

Second round (16 000, 32 bodies held 300 frames, 900 after, 3 seeds):
- Self-attracting, onset below its settle: 1.16–1.19 at `K = 54`, 1.10 at 173, 1.02–1.04 at 540,
  0.97–0.99 at 1728.
- Onset at or above its settle (`x_on = 12`): 1.39–1.45.
- Mixed, 4 species: merged clumps stay merged at every `K` (1.37–1.71).

Trade at 128 000 (onset `x = 6.3`, `ρ̄` 40.4, `ρ_on` 254.4, seeds 42, 7 and 1001; one-sided `t` =
2.920), **measured under the explicit push, before the step limit (C4b):**

| Arm | L | Friction-0 neighbours (none: 193–199) | After / fresh | Settled speed (none: 0.000–0.003) | Fresh neighbours (none: 186.4–186.6) | Held peak / neighbours |
|---|---|---|---|---|---|---|
| 540, ν 0.5 | 0.864–0.890 (ub 0.902) | 61.8–64.7 | 0.901–0.972 (ub 0.998) | 0.107–0.125 | 167.6–169.8 | 567–573 / 309–313 |
| 1728, ν 0.5 | 1.220–1.261 (lb 1.208) | 60.2–62.6 | 0.987–1.024 (ub 1.047) | 0.950–1.120 | 141.9–149.5 | 472–478 / 272–275 |
| **540, no ν** | 1.163–1.175 (lb 1.159) | 62.7–67.1 | 0.971–0.976 (ub 0.978) | 0.028–0.115 | 170.6–173.2 | 618–630 / 323–353 |

The `ff_stable` column this table carried is deleted: it recorded each arm's bisected largest stable
frame factor under the explicit push, a stability mechanism the step limit replaces (C4b). At 540, no
ν, `ff_stable` read 12 on 8 seeds; the 128 000-particle bisection under the per-reference-frame cap
found the true value is 1, not 12
(`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:44`, task 4.5's now-superseded run).

**The user's choice: `K = 540` without viscosity.** It accepts friction-0 settles about 17% warmer,
the simmer, and the densest held peak, and it relaxes fully at 128 000. **This stands pending Q1**
(crowding-redesign design §11): under the step limit, `K = 1728` may no longer exceed `B_L`, since the
limit caps what extra stiffness can do to the step, and task 4.5 reruns `L`, relaxation and the held
peak at 540 and 1728 under the limit and returns the table to the user. **What changed:** nothing yet;
the rerun may.

### C14 (was D14). Friction 0 and shipped friction: what the chosen term costs

The pressure is not scaled by friction and carries no viscosity (the user's decisions). At friction
0, 128 000, `K = 540`, **measured under the explicit push and re-measured by G1.2 under the step limit
(C4b, task 4.5):**
- motion is about 17% above no term (L 1.163–1.175)
- neighbours are about a third of today's (62.7–67.1 against 193.4–198.9)

At 16 000 L reads 1.036, and the no-term settle has 20.8–21.8 weighted neighbours. At shipped friction
the simmer is 0.028–0.115 against 0.000–0.003.

Reopen it on any of:
- an in-app shimmer read as a bug
- dense crowds at friction 0 reaching the soft cap's threshold of 25
- a visible jitter at shipped friction

**What changed:** nothing.

### C15 (was D15). Frames at any frame factor take one step

**The choice (the user's), superseded.** This section originally chose substepping past a measured
`ff_stable`. That path is disproved at 128 000 particles: the bisection under the per-reference-frame
cap found `ff_stable = 1`, not the provisional 12 this section recorded, meaning two substeps already
run warm (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:44`). The user chose the
lumped stiffness step limit (C4b) over substepping to a bisected `ff_stable` and over a recorded
stability limit of any kind (crowding-redesign design, the user's decisions). **Frames at any frame
factor now take one step:** the step limit scales the decoded delta so the step is stable by
construction (C4b), and no substep count exists for pressure stability. `ff_stable` and `n_ff` are
deleted from `src/config_ranges.nim` and `src/sim_registry.nim`. The criterion that replaces
`ff_stable` is crowding-redesign design §3.5: four arms (sustained, `FRICTION_MIN` sustained, cap
contact, and unsteady/held-frame schedules) hold that a world settles no warmer per reference frame at
any frame factor the app produces than at frame factor 1, on 16 000 and 128 000 particles. Substeps
still exist for the travel bound and the fluid's own stiffness law (N4); a step advances `ff` reference
frames, and friction and position act once per step, so motion per reference frame (late speed over
`ff`) remains the reading that compares one world across frame rates.

**History, under the explicit push (superseded by C4b).** At `K = 540` and ff 10 the explicit scheme
moved 0.090–0.099 per reference frame against 0.100–0.135 shipped.

`ff_stable`, history under the explicit push: measured at 16 000, radius 50, one species, onset 6.3
(`ρ_on` 31.8), smoothing 0.7, retention 0.95, 900 steps, window 749–899, 8 seeds, `t` = 1.895:

| ff | Per reference frame | Over ff 1 | Lower bound of difference |
|---|---|---|---|
| 1 | 0.085–0.135 | 1 | |
| 10 | 0.089–0.117 | 0.91× | −0.021 |
| 11 | 0.080–0.126 | 0.94× | −0.022 |
| 12 | 0.085–0.130 | 1.04× | −0.016 |
| **13** | 0.114–0.140 | **1.10×, warmer** | 0.001 |
| 14 | 0.094–0.152 | 1.18× | 0.006 |
| 20 | 0.134–0.152 | 1.31× | 0.024 |
| 30 | 0.138–0.150 | 1.33× | 0.022 |

`ff_stable = 12`. Frame factors 2, 4 and 7 read 0.18–0.36× (3 seeds). Through 3 substeps of 10, ff 30
reads 0.91×.

Jittered frame factor, history under the explicit push (batch T, time scale 5, 8 seeds):

| Arm | Per reference frame | Over ff 1 | Lower bound | Substepped / toggles |
|---|---|---|---|---|
| fixed 10 | 0.089–0.114 | 0.89× | −0.022 | 0 / 0 |
| uniform 8–16, substeps | 0.045–0.097 | 0.59× | −0.064 | 432–490 / 424–478 |
| alternating 10/13, substeps | 0.033–0.061 | 0.40× | −0.076 | 450 / 899 |
| uniform 8–16, no substeps | 0.112–0.152 | 1.18×, warmer | 0.0035 | 0 / 0 |
| alternating, no substeps | 0.094–0.133 | 0.97× | −0.017 | 0 / 0 |

The trigger carries no hysteresis.

Rejected:
- Accept the warm frames.
- Substep only the pair pass and integrate, which needs a second substep path.
- Hold the pressure per step (`K/ff`), which is weaker per simulated frame: 0.015–0.017 at ff 10.
- The viscosity's exact decay, which overshot at 0.50–0.59.
- **Substeps to the bisected `ff_stable`** (the user's decision). At 128 000 the bisection reads
  `ff_stable = 1` under the per-reference-frame cap, so this path would substep from frame factor 2, and
  three substeps cannot hold above frame factor 3
  (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:44-45`).
- **A recorded stability limit of any kind** (the user's decision). The lumped stiffness step limit
  (C4b) is stable by construction at every frame factor, so no constant records where it stops holding.

**What changed.**
- `n`, the substep count, is still the largest of three counts (N4), but the frame-factor count
  `⌈ff/ff_stable⌉` is gone: pressure stability no longer needs a substep count, so only the travel bound
  and the fluid's declared need can ask for more than one substep.
- The cap moves from `SPH_MAX_SUBSTEPS` to `SUBSTEPS_MAX = 3` in `src/config_ranges.nim`, re-derived
  from the fluid's former `SPH_MAX_SUBSTEPS` alone rather than from `⌈30/ff_stable⌉` and it. Beside it
  goes the per-extra-substep cost at 128k: 1.56 ms from the 30 s run and 7.95 ms from the 150 s run.
  The 150 s figure is a lower bound, and no in-app run has read it.
- At the 0.05 s cap, only travel or a fluid ask can add substeps: with neither acting, a held frame at
  time scale 5 (frame factor 30) now runs one step, scaled by the limit.
- The substep path no longer engages only with the fluid, so G1.4 can read the cost without adding
  SPH's passes.

### N1. The declaration table in `src/sim_registry.nim`

```nim
type
  Coupling* = enum cpSpecies, cpFluid, cpScent, cpDeposit, cpLongRange, cpBodies
  SizeSpace* = enum ssWorld, ssFieldCell, ssScreenPx
  CostScaling* = enum csPerParticle, csPerFieldCell, csPerMeshCell
  PassDecl* = object
    pipeline*: string          ## pipeline key, e.g. "forcesSph"
    cadence*: FrameNodeCadence ## fncEverySubstep / fncOncePerFrame
    slot*: int                 ## a PROFILER_SLOT_* constant
    cost*: CostScaling
  CouplingDecl* = object
    strengthParam*: string     ## descriptor id
    unit*: UnitFnId            ## balance_core enum
    passes*: seq[PassDecl]     ## the gate is acts(strength) over all of them
    dormancy*: string          ## dormancy predicate id
    boundsRead*: seq[string]   ## param ids its registered ceilings read
    ownParams*: seq[string]    ## descriptors that shape only this coupling
    sizes*: seq[(string, SizeSpace)]
    raisesCrowd*: bool
    substepNeed*: SubstepNeedId
const COUPLINGS*: array[Coupling, CouplingDecl] = [...]
```

`UnitFnId` is an enum in `balance_core` with one member per velocity writer and one for the deposit.
`unitImpulse(id, cfg)` evaluates it with an exhaustive `case`, following the pattern of `ParamCeilingId`
and `evaluateCeiling` (`src/ui/api/param_descriptor.nim:71-76,242-254`). A missing arm fails to
compile. `SubstepNeedId` works the same way in `sim_registry` (N4).

| Coupling | Strength | Passes (slot) | Dormancy | Bounds read | Sizes | Raises crowd |
|---|---|---|---|---|---|---|
| Species | `forceStrength` | none: its term lives in the neighbour sweep | `forceOff` | — | `interactionRadius` world | yes |
| Fluid | `fluidStrength` | `forcesSph` (FLUID 9) | `fluidOff` | `interactionRadius`, `sphRadiusFraction`, `timeScale` | — | no: the pressure is floored at rest and purely repulsive (`forces-sph.wgsl:244-248`) |
| Scent | `rdFieldForce` | `fieldForce` (SCENT 10) | `tropismOff` | `rdPatternScale` | field pattern, field cells | yes |
| Deposit | `rdDeposit` | `fieldDeposit`, per frame (DEPOSIT 12) | `depositOff` | — | splat radius, field cells | no |
| Long range | `longRangeStrength` | the solve, per frame (LONG_RANGE 7); `lrForce` (LR_FORCE 11) | `longRangeOff` | `interactionRadius`, `longRangeGridIndex`, `longRangeReach` | `longRangeReach` world | yes |
| Bodies | `bodiesStrength` | `bodyForce` + `bodyIntegrate` (BODIES 8) | `bodiesOff` (new) | — | `bodyBand`, body radius, world | yes |

The neighbour sweep (`binScatter`, `forces`) keeps PHYSICS 1 and belongs to no declaration. Screen-pixel
lengths (Particle Size, the glow halo) belong to no coupling. They go in a sibling `RENDER_SIZES`
table with `ssScreenPx`, so the one-space suite covers every length descriptor. The world↔cell
conversion has one site, `worldUnitsPerCell()` in `field_core`. Both the scent unit function and
`patternDiameterWorld` call it.

**Frame shape.**
- `forcesSph` leaves the Physics node for its own "Fluid" node, per substep.
- `fieldDeposit` leaves the Field node for its own once-per-frame "Deposit" node ahead of it.
- "Field Force" and "Long Range Force" get slots 10 and 11.
- The Field node keeps resolve and the RD steps on slot 5.

**Profiler slots.** The slot constants move into a new pure module, `src/profiler_slots.nim`. Both
`gpu_profiler` (`numPasses = 13`) and `sim_registry` import it, which closes the unenforced pairing
that `gpu-frame-registry:37-40` records (inconsistency 6).

**Two figures.** `physics=` keeps its meaning, sweep plus integrate (`gpu-frame-registry:30-31`). A new
`coupled=` figure is physics plus every coupling slot. It is the "physics time" that
`coupling-contract:241` and G4 read (inconsistency 1).

**New suites** (`tests/test_sim_registry.nim`):
- "Every Writer Belongs To One Coupling"
- "Profiler Slot Constants" (extended)
- "Substeps Follow The Tightest Coupling"
- "Bounds Read Only Declared Parameters"
- the one-space check
- the check that the frame factor reaches only integrate's parameters, with `bodyIntegrate`'s clock
  exempt by name (inconsistency 5)

Rejected:
- Declarations as a `seq`: the enum index is what makes a missing entry a compile error.
- Unit functions as `proc` fields: `noSideEffect` closures in a `const` table are brittle, and the
  enum-and-case pattern is already the repo's.
- Profiler slots staying mirrored: that leaves the pairing unenforced.

### N2. Gains derive from each full effect

`g_c = F_c / unitImpulse(unit_c, referenceConfig)` at gain 1, so that `impulse = s · F_c · u0` at the
reference configuration. Each `g_c` is a `const` in `src/config_ranges.nim` beside `F_c`, and a static
assertion holds it equal to the derived value. The pair ×4.0, `SPH_FORCE_SCALE` and
`BODY_FORCE_CEILING` stay in their shaders. Each is recorded as its coupling's shape inside the unit
function, so no shader changes for them and no gain hides outside the declared one.

**The reference configuration.**
- 16 000 particles and radius 50 (the shipped values), onset density at `x_on`, one self-attracting
  species at `MATRIX_MAX_VALUE`.
- Pattern scale 1, the scent's measured base (`field-scale`).
- One live body at `bodyBand` 120.

**Provisional full effects** (G2 confirms or replaces each):

| Coupling | `F_c` | Grounds |
|---|---|---|
| Species | `F_pair` = 5 in pair gain, so `g_pair = 5` | The old `FORCE_STRENGTH_MAX`. Every old value stays representable, new 0.2 = old default 1, and C8's word budget is unchanged |
| Fluid | `F_edge` | See the rule below |
| Scent | `F_edge` at pattern scale 1 | Same rule |
| Long range | `F_LR = F_edge` | Set by `coupling-contract`; C2 |
| Bodies | `BODY_FORCE_CEILING / u0` = 1 200 per body at the envelope peak, gain 1 | Unchanged: the user asked for no bodies reduction, and `parametric-bodies` owns the push |
| Deposit | 0.08 concentration per cell per field step | The measured flood-bounded `RD_DEPOSIT_MAX` (`src/config_ranges.nim:277-287`), so the ignition measurements keep their units |

**"Well below today's" (the user asked for "down to a fraction of what they are").** `F_edge` is the
pair force's peak edge impulse on a particle of a clump at the onset density at pair strength 1. It is
the quantity `coupling-contract` already fixes `F_LR` to. At strength 1, no field or mesh coupling
pushes a clump's edge harder than the species force holds it. Today long range at 0.5 hands 26–112
units against the pair's about 1 (`proposal.md:21`), so this is a fraction by construction for long
range. For fluid and scent, the test "Strength Is A Fraction Of The Full Effect" in
`tests/test_balance_core.nim` asserts that the ratio of today's impulse at the old maximum to `F_c` is
above 1. If it is not, the fraction the user asked for is not delivered, and the task stops and returns
the numbers to the user. It does not pick another constant. The numbers themselves do not exist yet:
`src/balance_core.nim`, which computes them, is not in the tree.

**Order.** G2 runs in-app after the pressure lands (G1.x done), because every full effect is read over
a world that resists compression. It runs before the group that switches the ranges to 0–1 and lands
schema v5. Until G2 records a value, each `F_c` carries the provisional note, as
`LONG_RANGE_STRENGTH_MAX` does (`src/config_ranges.nim:63-75`). `src/preset.nim` records the `F_c` and
`g_c` set that version 5 converts against, with static assertions against the live constants, the way
it records `x_on`. A later change to any `F_c` then needs version 6.

Rejected:
- Today's strength-max impulse as `F_c`: that keeps every coupling as strong as it is, which the user
  rejected.
- A single scalar fraction of today's impulse (for example 1/10): a hand-set number with no measurement
  behind it.
- `F_c` per coupling from in-app taste alone: no relation between couplings survives.

### N3. One time site: integrate. Five writers, converted in one step

**The site.** `IntegrationParams`' pad word at offset 20 (`INTEG_PAD1`) becomes `frameFactor`, the
substep's `ff_sub = ff/n`. Integrate decodes both velocity words and the two stiffness words (C4b),
forms the particle's step limit `s`, and multiplies the decoded delta by `frameFactor · s` once.
`SIM_DT` becomes a pad. `forces` and `forcesSph` read no time: their per-reference-frame factor is the
constant `FRAME_DT_REFERENCE`, substituted by the bundler. The writer-time ban (no writer reads `ff`)
and its suite, "Only Integrate Reads The Frame Factor", stand unchanged: `s` is computed and applied at
integrate, the one time site, alongside `frameFactor`.

The deposit and the chemistry keep the field clock. The deposit is stated per field step through
`depositFrameScale`, and ignition was measured per field step. Moving the deposit alone onto `ff` would
shift the balance between deposit and reaction that the regime floors rest on.

**Order, keeping the tree green at each step.**
1. Write `balance_core` and today-convention encode and decode oracles for all five writers and for
   integrate. Test 4b and the today-convention arm of test 11 pass against them; test 11's
   per-reference-frame arms at ff 2 and 30 stay red until the switch. There is no behaviour change.
2. **The switch, in one commit.**
   - integrate: `× frameFactor`
   - `forces`: pair, mouse and blast use `FRAME_DT_REFERENCE` in place of `params.dt`
   - `forcesSph`: pressure `× FRAME_DT_REFERENCE`, and the blend drops its `frameFactor`
   - `fieldForce`: the CPU drops `frameScaledFieldForce`
   - `lrForce`: the CPU drops `frameFactor`
   - `bodyForce`: drops `frames`
   The oracles move to the new convention in the same commit. At `ff = 1` the pair's integers are
   unchanged (test 4 on the oracle).
3. The coarse word, the split in `forcesSph`, and the word assertions (test 10).
4. The substep plan (N4).
5. The pressure, as the second coarse writer.

`bodyIntegrate` keeps its own clock (`dtSeconds`, `frames`, `web/shaders/src/body-integrate.wgsl:18-19,79-100`).
It integrates the bodies, not particle velocity. Its reaction decode stays on the body accumulator,
which `bodyForce` now fills per reference frame. `bodyIntegrate` therefore multiplies the decoded
reaction by `frames`, one line at the decode. The ban on writers reading time is checked by reading
the writer shader sources for `dt`, `frameFactor` and `frames` in the registry suite, with
`bodyIntegrate` exempt.

Rejected:
- **Writer by writer, with a transitional per-step word beside a per-reference word.** It keeps each
  step small, but it costs a storage binding in `forces.wgsl`, which sits at the default limit of 8
  once the coarse word lands (C8). It also means a double decode, and shipping frames with two
  conventions at once. The switch is small per writer, a single removed multiply, and the oracles
  gate it.
- **The frame factor in each writer's CPU parameters.** That is the status quo, with five sites.

Evidence: **designed**. Test 4b bounds the low-bit change at `ff ≠ 1` to fewer than `max(1, ff)`
quanta.

### N4. Substeps: the travel bound, the cap and the effect-time clamps

`func substepPlan*(ff: float; live: LiveValues): SubstepPlan` is pure, in `sim_registry`.
`LiveValues` holds:
- the six strengths
- `maxVelocity`, `interactionRadius`, `sphRadiusFraction`, `sphStiffness`, `timeScale`, `bodyBand`
- `bodyLive = liveSlots(state, now) > 0` (`src/body_core.nim:494`)

`SubstepPlan` holds `count`, `effMaxVelocity`, `effStiffness` and the requesting source. The source
is an enum over the three counts below and the case where none of them asked for more than one, so
only a count that exists can be named. It is not `SubstepNeedId`, which says what one coupling
declares, where this says which count won.
`webgpu_compute` replaces `:984-988` with it and writes:
- integrate's `frameFactor = ff/count`
- the effective Max Velocity into the integrate params
- the effective stiffness into the SPH params

**The cap moves to per reference frame.** Integrate applies today's curve to `speed / ff_sub` and
rescales by `ff_sub`, so per-step travel is at most `maxVelocity · ff_sub`. The result is
bit-identical at `ff_sub = 1`. Without this change a per-step cap cannot bound a substep's travel in
the spec's terms (inconsistency 4). Friction stays per step, the condition C15 was measured under (see
Risks).

**The three counts, now two.** `n = min(max(n_T, n_c), SUBSTEPS_MAX)`. `n_ff = ⌈ff / ff_stable⌉` is
gone: pressure stability is the step limit's job now (C4b), not the substep count's, so no count reads
`ff_stable`.
- `n_T = ⌈maxVelocity · ff / T⌉`. Only if some coupling declares a length.
- `n_c` is each acting coupling's declared need. Only the fluid declares one:
  `⌈sphStiffness · ff / (0.3 · h)⌉`, with `h = interactionRadius · sphRadiusFraction`. This is the
  stiffness law `0.0025 · h · n / dt` (`src/sph_core.nim:135-176`) at the delivered `dt`, since
  `0.0025 / FRAME_DT_REFERENCE = 0.3`.

**The travel bound `T`.** It is the length the bodies declare, `bodyBand`, and only while
`bodiesStrength > 0` and a body lives. No other coupling declares a length:
- The pair core would substep the shipped world: `repulsionEnd · R` = 25 against a per-step travel of
  up to 50.
- The fluid, scent and long range act smoothly over their ranges.
Bodies with no live body declare nothing, because there is no surface to tunnel through
(inconsistency 7).

**`SUBSTEPS_MAX = 3`.** Re-derived from today's `SPH_MAX_SUBSTEPS` alone, where the stiffness law was
used: `⌈30 / ff_stable⌉` no longer enters it, since pressure stability holds by construction at every
frame factor (C4b) and asks for no substep count. The per-extra-substep cost sits beside it (C15). The fluid's scenario at
`coupling-contract:204-207` ("declared count 4 → 4 substeps") needs `SUBSTEPS_MAX ≥ 4`. Under this
decision that scenario is the clamp scenario (inconsistency 15).

**Effect-time clamps, past the cap.** Neither clamp touches a stored value.
- Travel: `effMaxVelocity = T · 3 / ff`.
- Fluid: `effStiffness = min(stored, servedCeiling, 0.3 · h · 3 / ff)`. `servedCeiling` is the panel's
  `pcStableStiffness` at `SUBSTEPS_MAX` and the 60 Hz reference `dt`.

The ceiling function loses its substep input:
- `CeilingInputs` loses `sphSubsteps` (`src/ui/api/param_descriptor.nim:134-142`).
- `ceilingInputBox` loses that axis (`:271-285`).
- The reason text (`:263-269`) becomes "…the current interaction radius, fluid radius and time scale".

**Worked values.**
- Shipped: band 120, Max Velocity 50, ff 1, fluid off gives `n = 1`.
- Stiffness 40 at h 50 and ff 1 gives `n_c = 3`.
- ff 10 at time scale 5 on 60 Hz, with a body alive, gives `n_T = 5`, so the frame runs 3 at
  `effMaxVelocity` 36.
- ff 30 with no travel or fluid ask gives `n = 1`; the step limit (C4b), not a substep count, holds it
  stable.

**The band floor.** `BODY_BAND_MIN = 25.0` is a stated literal and no longer derived. It is the value
every saved band was clamped against, so no preset moves. It is strictly positive, and the travel
count holds a particle inside a band at the floor. At the floor with ff 1 and Max Velocity 50 the frame runs 2 substeps. `BODY_BAND_FLOOR`,
`BODY_LARGEST_SUBSTEP_DT` and `BODY_LARGEST_FRAME_FACTOR` leave `body_core`, and the tests pinning them
go too. The tunnelling suite "An Enclosing Body Cannot Be Tunnelled"
(`tests/test_body_core.nim:951`) is rewritten to step at `substepPlan`'s count with the per-step
travel model.

**Removed:**
- the `sphSubsteps` descriptor (`src/ui/api/param_descriptor.nim:598-599`), state field and preset
  field
- `SPH_SUBSTEPS_MIN` and `SPH_SUBSTEPS_MAX` (`src/config_ranges.nim:263-266`) and their assertion
  (`:639`)
- `SPH_MAX_SUBSTEPS`, which becomes `SUBSTEPS_MAX`
- the Substeps line in `docs/help/30-fluid.md`

Rejected:
- `T` as the smallest length of any acting coupling. It would substep the shipped world.
- `SUBSTEPS_MAX = 4`. That goes past the stiffness-law range on file and adds 4.68 ms or 23.85 ms at
  the cap.
- Keeping the per-step cap. The travel count could not bound a substep at `ff > 1`.
- Hysteresis on the count. C15 measured none needed.

### N5. Pattern Scale

**The descriptor.** `rdPatternScale`, group `rd`, float, linear, step 0.01, precision 2, range
`[RD_PATTERN_SCALE_MIN, 1]`.
- It has no dormancy.
- It carries a closed-form probe over `patternDiameterWorld`, with `rhStructural`.
- Its help line goes in `docs/help/40-rd.md`.
- A pure `rdDiffusionRates(scale)` in `field_core` returns `(RD_DIFFUSION_A·s, RD_DIFFUSION_B·s)`.
  `webgpu_compute` writes them where it writes the rates today (`:1053-1054`).

**The floor.**
- `RD_PATTERN_SCALE_MIN` is 0.25, G3's floor (`scratchpad/core-force-interface/g3__21-09-26-2010.md`).
  Coral has no restoring row at 0.22 or 0.2 anywhere in the feed and kill ranges, so 0.22 is the
  first failing step below it. The measured diameter clears 4 cells down to 0.2 (4.02) and not at
  0.19 (3.96).
- The closed-form floor `(4.0/9.30)² ≈ 0.185` is not used. The measured diameter falls below the √D
  law near the cliff (4.47 against 4.65 predicted at 0.25, and 3.71 at 0.16). Interpolating linearly
  between the measured 0.16 and 0.25 points puts 4.0 cells at `0.16 + 0.09 · (4.0 − 3.71)/(4.47 − 3.71)
  ≈ 0.194`. That figure is arithmetic on `src/field_core.nim:232-239`, not a measurement.
- G3 measures the band steps `[1, 0.5, 0.25]` plus candidate floors below 0.25, down to the first
  step that fails. It records the floor as the smallest step that passes every criterion in
  `field-scale` ("The pattern-scale band is measured before its constants are set"). The
  single-cell and scattered negative controls are criteria at scale 1 only: below it a smaller
  diffusion lets a narrow deposit ignite inside the deposit range (0.0625 at 0.5, 0.0325 at 0.25),
  and `RD_DEPOSIT_MAX` stays one constant. Worms and Coral stay dark at the default deposit and
  ignite at 0.04.
- Static assertions: `patternDiameterCells(RD_DIFFUSION_A · floor) ≥ 4.0`, and the ceiling is 1.

**Regime rows.** `RD_REGIMES` keeps one row per regime, the scale-1 row. A sibling table,
`RD_REGIME_SCALE_ROWS` (id, scale, feed, kill, minDeposit), holds rows only for the steps where G3
finds a regime drifting: Coral at 0.5 and 0.25, Worms at 0.25. A row restores its regime when its
shipped path settles nearer the regime's own unforced attractor, taken at the scale-1 coordinates and
that step, than any other regime's. `regimeRow(id, scale)` returns the row at the nearest step,
falling back to `RD_REGIMES`.
- `applyRegimeImpl` (`src/web_api.nim:620-640`) and the catalog it serves (`:596-603`) read
  `regimeRow` at the live scale.
- `rdClimateTour` (`src/climate_core.nim:107-112`) takes a scale.
- The feed and kill notches stay the scale-1 map (Risks).
- The regime assertions (`src/config_ranges.nim:677-686`) extend over the sibling table.

**Scent follows the scale.** The inhibitor gradient per cell grows as the pattern shrinks, as
`1/diameter ∝ 1/√s`. So `scentUnit(s) = scentUnit(1)/√s` and `g_scent(s) = F_scent · √s / scentUnit(1)`.
The CPU writes it each frame. G3 records the stepped strength-1 impulse at each band step beside the
gain. "Every Writer Answers In The Pair Unit" sweeps the scent oracle over the steps. If the
closed-form `√s` misses the stepped impulse at some step by more than the oracle's tolerance, the gain
follows the recorded per-step table, interpolated in `s`. G3 measured it at 1, 0.983 and 0.927 of
the scale-1 impulse at 1, 0.5 and 0.25 (128x128 torus, settled peak gradient), so √s stays the
closed form and 8.4 writes the table, `RD_SCENT_STEPPED_IMPULSE`.

Group 7 has not landed `F_scent` or `scentUnit`. Until it does, 8.4 writes the correction directly
onto today's gain: `rdFieldForce · rdScentGainFactor(s)`, where `rdScentGainFactor(s) =
√s / interpolatedRatio(s)` (`src/config_ranges.nim`) is the `√s` closed form divided by
`RD_SCENT_STEPPED_IMPULSE`'s interpolated ratio, so the strength-1 impulse holds its scale-1 value
at every step. Once group 7 lands `F_scent` and `scentUnit`, `g_scent(1)` carries the same
correction: `g_scent(s) = g_scent(1) · rdScentGainFactor(s)`.

**Presets.** An absent `rdPatternScale` decodes to 1.

The default is the floor, `RD_PATTERN_SCALE_DEFAULT = RD_PATTERN_SCALE_MIN`: the user chose the smallest
scale that holds. A static assertion ties the two, so G3 moving the floor moves the default. Presets
saved before the control decode at scale 1, the look they were saved with.

Rejected:
- Changing the field resolution, which the user excluded.
- A ceiling above 1, which crosses the activator's Euler line (`RD_DIFFUSION_A · RD_DELTA_T == 1`).
- One regime row per step for every regime. It is noise where nothing drifts.

### N6. Reaction-diffusion reaches particles only as force

Bindings as they stand:
- `render.wgsl` binds `fieldTexture` at 3 (`:72`) and reads it at `:189-193`.
- `glow.wgsl` shares render's layout. Its camera sits at binding 4 because 3 is the field
  (`:29-33`), and it never reads the field.
- `fade.wgsl` binds the field at 3 (`:30`) and drifts at `:88-94`.
- `tonemap.wgsl` binds it at 4 (`:29`) under `fieldOpacity` (`:74-86`).
- `field-composite.wgsl` binds it at 0.

**Deleted:**
- `web/shaders/src/field-composite.wgsl` and its generated output
- `web/shaders/modules/colormap.wgsl`, `src/colormap_core.nim`, `tests/test_colormap_core.nim`
- `docs/help/41-rd-field.md`
- the `rd-field` group, the `fieldOpacity` descriptor (`src/ui/api/param_descriptor.nim:721-723`) and
  the `fieldUnlit` predicate
- `FIELD_LIGHT_STRENGTH` (`src/shader_config.nim:434`) and `FIELD_DRIFT_SCALE`
- the field-composite pipeline, layout, bind group and present step
  (`src/webgpu_render.nim:135-137,247,848-932,1476-1511,1566-1573,1973-1981`)
- in `src/web_api.nim`: `setColormapImpl` (`:384-387`), the preset capture and apply of both fields
  (`:1094-1095`, `:1240-1246`), the colormap catalog (`:1271-1285`), and the `colormaps` and
  `getColormap` accessors (`:1412-1413`)
- `fieldOpacityProbe` (`src/ui/api/response_probe.nim:666`)
- the `colormap_core` entry in `tools/wgsl_bundle.nim:207`
- the config fields (`src/config.nim:57-58,222-223`)
- the colormap and field-opacity uses in `web-ui/src/components/Panel.tsx`

**Struct members become pads, keeping every offset:**
- `RenderParams.fieldOpacity` and `colormapIndex` (52, 56)
- `FadeParams.fieldDriftScale` (4)
- `TonemapParams.colormapIndex` and `fieldOpacity` (20, 24)
(`src/gpu_types.nim:213-235,258,533-552`)

**Layouts.**
- The render layout drops entry 3. Glow keeps its camera at 4, since WebGPU allows gaps.
- Fade drops binding 3.
- Tonemap drops binding 4.
- `ExpectedShaderBindings` loses those entries.

**Kept:** `webgpu_init`'s `fieldSampledViewA/B` (`src/webgpu_init.nim:270-271`), which the compute
side's scent binds (`src/webgpu_compute.nim:523-524`).

**Also removed, alongside `webgpu_render.nim`'s uses:** `webgpu_init`'s `activeFieldView`,
`fieldSampler`, `fieldGeneration` accessors and their backing `fieldLinearSampler`,
`fieldGenerationCounter` vars — `grep -rn "fieldGeneration\|activeFieldView\|fieldSampler\b"
src/*.nim` finds no reference left once `webgpu_render.nim`'s field-composite/render/tonemap
paths are gone.

Docs updates:
- `docs/help/52-bloom.md` already says the grade is dormant with bloom off, and this makes it true.
- `docs/one-world.md`, `docs/enforcement.md`, `docs/slider-interactions.md`, `tests/README.md` and
  `src/main.nim:37-61`'s comment lose their field-composite and colormap lines.

Rejected: keeping the backdrop behind a default of 0. The user decided the field is force only.

### N7. The version-5 migration

The branch reads the strengths the earlier branches left, then:

| Field | Version 5 value, before the clamp to 0–1 |
|---|---|
| `forceStrength` | `saved / 5` |
| `fluidStrength` | `saved · unit_fluid(ref) / F_fluid` (the old gain was 1) |
| `rdFieldForce` | `saved · scentUnitPerOldValue(1) / F_scent`, after the version-1 `V1_FIELD_FORCE_SCALE` |
| `longRangeStrength` | `saved · cellArea(savedGridIndex) / (U(savedRadius) · g_LR)` |
| `rdDeposit` | `saved / 0.08` |
| `bodiesStrength` | `saved` |
| `rdPatternScale` | 1 |
| `sphSubsteps`, `colormapIndex`, `fieldOpacity` | dropped without error |

Zero stays exactly zero, since every factor is finite.

Constants restated on the 0–1 scale:
- Force Weather waypoints (`src/config_ranges.nim:140-146`): 0.8, 1.6, 2.4, 1.2, 0.5 become **0.16,
  0.32, 0.48, 0.24, 0.10**.
- `FORCE_WEATHER_MAX_STEPS[fxStrength]` (`src/climate_core.nim:183-196`): 0.01 becomes **0.002**, still
  a fiftieth of the axis range.
- `RD_REGIME_HIGH_FEED_DEPOSIT`: 0.040 becomes strength **0.5**.
- `RD_DEPOSIT_MAX` splits in two. The deposit strength range is 0–1. The concentration ceiling of
  0.08 becomes `RD_DEPOSIT_CONCENTRATION_MAX`, the deposit's full effect, and every reading of it as a
  concentration reads that constant.

The default `rdDeposit` of 0.02 becomes 0.25. The default Force Strength of 1.0 becomes 0.2, and its
descriptor precision rises from 1 to 2 (N9).

MIDI and audio control rows map sources to strengths in travel units and carry over unchanged
(`coupling-contract`).

The branch runs after the version-1 and version-3/4 branches (`src/preset.nim:681-732`).
`V1_FIELD_FORCE_SCALE` composes with the scent factor, and the clamp applies once, last.

Rejected:
- Converting on save. Old files would still need a load path.
- Clamping before converting. That would change worlds that fit.

### N8. The fluid re-examination: three one-term arms

**Harness.** The new recipe `just calibrate-fluid`, outside `just check`, extends `balance_core`'s
binned oracle world with a mirror of `sph_core`'s pair loop (`forces-sph.wgsl:240-280`). This answers
the unsourced mark at `sph-scale:136`. The arms run after the step limit lands (C4b): "the pressure
acting" below means the limited pressure, integrate's decoded delta scaled by `s`, not the explicit
push. Conditions, otherwise unchanged:
- 128 000 particles, radius 50, the species force at its shipped default (0.2 on the new scale)
- the pressure acting, crowding 0, fluid 1
- 900 steps, late window 749–899
- the three gate seeds with the C5 margin

**Readings** (answering the unsourced mark at `sph-scale:107`):
- **Structure survival.** `σ = (S_arm − 1/n_s) / (S_0 − 1/n_s)`. `S` is the mean share of a
  particle's proximity-weighted neighbours that belong to its own species, `n_s` is the species count,
  and `S_0` is the same world with fluid 0. σ = 1 means the fluid kept all the structure; σ = 0 means
  the species mixed at random.
- **Evenness.** `E` is the coefficient of variation of crowd density on the arm over the coefficient
  of variation with fluid 0. Lower means flatter.

**Arms, and the default each gates:**
1. Blend at `SPH_XSPH_EPSILON` against 0, at Viscosity 0. This gates `SPH_XSPH_EPSILON`. If σ is lower
   with the blend, then `SPH_XSPH_EPSILON = 0`, no smoothing acts at Viscosity 0, and the
   Viscosity help line says so.
2. The pressure term's gain at `SPH_FORCE_SCALE` against 0. This **gates the `sphStiffness` default**,
   answering `sph-scale:114`'s caller mark: stiffness is the knob that scales that term. The reading
   is recorded beside `SPH_FORCE_SCALE`. If σ is lower with pressure, the default steps down by halves
   from 8 to the largest value whose σ is not lower than fluid-without-pressure's. The floor is
   `SPH_STIFFNESS_MIN` 1.
3. Radius fraction 1 against steps 0.75, 0.5, 0.25 and 0.1. This gates the `sphRadiusFraction`
   default: the largest step whose σ is not lower than fraction 1's. The record also says
   whether 0.1 still computes a fluid.

If no step of an arm passes, meaning every value flattens, the arm's numbers go back to the user with
the proposal's "delete the fluid" case (`proposal.md:144`). The task does not choose.

Rejected:
- A GPU harness: no headless oracle, and no seeds.
- A single combined arm: it could not attribute the flattening.
- Radial-distribution statistics: they have more parameters and no reading on file.

### N9. Folded defects and where each fix lands

1. `docs/help/10-simulation.md:9-10` says "rebuilds". It becomes "resizes", as the code does
   (`src/web_api.nim:893-901`).
2. `docs/one-world.md:168-169`: "Four passes" becomes five, listing the five writers.
3. The `sbVelocityDelta` doc (`src/sim_registry.nim:124-130`) lists five writers, adding `bodyForce`.
4. Bloom-off dimming is made true by N6. No descriptor edit.
5. Palette Saturation and Lightness get a new `paletteFixed` predicate. It is true when the scheme
   takes fixed swatches, which is `psOpenColor` (`src/palette.nim:27-29,141-164`) and the default
   (`src/ui/state/palette_state.nim:40-44`).
   - `DormancyPredicate` gains `paletteFields`, and `dormantParams` (`src/web_api.nim:1442-1455`)
     reads them from `paletteEditorState` (`:293`).
   - `tests/test_dormancy.nim` walks them against `PaletteEditorState`.
6. `docs/help/51-glow.md:10-11`: the Velocity Sweep description gains halo growth
   (`web/shaders/src/glow.wgsl:94-99`). The Interacts line already names it.
7. `docs/help/30-fluid.md:15-22`: the Substeps line is removed, and the stiffness-ceiling line names
   Interaction Radius, fluid radius and time scale.
8. `docs/help/12-species.md:12` says "particles drift through each other". It is corrected for the
   pressure: below the onset they still pass through each other.
9. The crowding-ceiling comments at `src/config_ranges.nim:37-41,46-54` are rewritten (C9).
10. `tests/test_field_core.nim:325-345`: the harness comment states 1.875 units per cell and derives
    from `WORLD_W` (`field-scale`, scent requirement).
11. `src/preset.nim:641-644` claims a test that does not exist. The test is added:
    `V1_FIELD_FORCE_SCALE == 1 / FIELD_PATTERN_SHRINK` in `tests/test_preset.nim`.
12. `forceStrength` precision goes from 1 to 2 (`src/ui/api/param_descriptor.nim:442-443`). On 0–1 a
    step of 0.1 is half the default. The record is the before (0.1 step against the 0.2 default) and
    the after, beside the precision.
13. The `gpu_profiler` pairing (N1).
14. A `bodiesOff` predicate. The body descriptors that shape only the bodies cite it.
15. `src/config_ranges.nim:110-125` calls 3.75 ms "the settled 128k headroom". It is corrected to
    cite `w1-128k`'s 11.65 ms as the working figure, a lower bound, with 3.75 ms as the 150 s run still
    climbing, the correction coupling-balance task 1.5 named.
16. `BODY_BAND_FLOOR` models speed per second (N4).
17. The `web/shaders/modules/fixed_point.wgsl` header (C8).
18. The three `audio-interface` findings land in that change's artifacts, which this change does not
    edit:
    - `openspec/changes/audio-interface/tasks.md:197`, the fresh-state test
    - `openspec/changes/audio-interface/specs/audio-input/spec.md:160`, "same wall-clock time at any
      frame rate". The audio poll receives the capped delta (`src/app.nim:240,259`), capped at 0.05 s,
      so the claim fails below 20 fps.
    - `openspec/changes/audio-interface/design.md:188` holds the gain-step figures (a 20 dB up-step,
      and a 10 dB drop moving p50 from 0.57 to 0.49). The proposal calls them stale. No rerun on file
      confirms or refutes that, so the fix is a rerun of that probe.
    The user chose to fold found defects into this change, so its tasks edit those artifacts.

### N10. How `coupling-balance` closes

Its decisions and measurements now live in C1–C15. One of its own errors is corrected here and not
there: task 6.2's "frame factor 2" at shipped defaults on 60 Hz, which is 1
(`openspec/changes/archive/2026-09-18-coupling-balance/tasks.md:51`). The in-app comparison that task describes runs at
frame factor 1.

The user chose to archive it with `openspec archive coupling-balance --skip-specs` once this change's
`tasks.md` lands: its history stays under `openspec/changes/archive/`, and its spec, which this change
replaces, never merges.

Its named amendments move with this change:
- **`long-range-mesh`**: the migration and the strength range (task 6.2, and
  `specs/long-range-coupling/spec.md:300,309`).
- **`calibrate-shipped-defaults`**: group 3 and fixture C (C12).
- **`parametric-bodies`**:
  - 9.2 and 9.3 wait on the pressure.
  - The held-world heat is a finding (C6).
  - The band floor is no longer derived (N4).

## Risks / Trade-offs

Carried from coupling-balance:
- [The onset is placed, not derived; the exponential floor is unprobed] → G1.1 records the settles
  6.3 separates on the gate seeds at 128 000 and radius 50, polynomial model only. Other counts,
  radii, species counts and the exponential model stay unmeasured.
- [Every probe is a CPU model; GPU bit identity is unenforced] → In-app comparison of the settled look.
- [A fixed stiffness cannot hold the stacked column near the onset] → Accepted (C6). Gate 5 holds it
  against the control.
- [A held crowd costs more than the allotment] → Accepted under the relative ceiling. The held figure
  is recorded.
- [Friction-0 settles run about 17% warmer at `K = 540`] → Accepted by the user, and bounded by `B_L`.
- [`K` and `B_L` rest on 3 seeds at 128k] → G1.2.
- [Mixed clumps a hold merged stay merged] → Accepted (C3).
- [The simmer at shipped friction] → Accepted, and observed in-app.
- [Frames at the 0.05 s cap run up to 3 substeps, which lengthens a slow frame and may keep it capped]
  → Now applies only when travel or the fluid asks for more than one substep (C4b, N4): pressure
  stability no longer asks. Unmeasured. G1.4 reads `physics=` and the frame time at the cap, and
  whether the frame recovers.
- [`docs/perf-report.md:129-131` multiplies the render passes by the substep count] → Outside this
  change. Only compute passes repeat.
- [A writer left on the old convention writes up to 30× too hard] → Tests 4b and 11, and N3's single
  switch.
- [`forces.wgsl` at 8 storage buffers] → Any further binding needs a raised limit or a merged buffer.
- [Scent and long-range maxima may exceed 7 251] → `k` falls to 11 (C8).
- [The coarse word's cost is unmeasured] → G1.4.
- [A full `calibrate-balance` run costs core-hours at 128 000; nothing detects a skipped rerun] → Recorded in
  `docs/enforcement.md` at the recipe tier.
- [The substep count toggles frame to frame] → It read cooler (batch T). Stutter is an in-app
  reading.
- [Force Strength 0 gains incompressibility] → C11.
- [The long-range pull grows as `R²` at a fixed strength] → Accepted. Stated in help, and converted
  per world (C7).
- [`x_on` inside the long-range unit] → The static `x_on` record in `src/preset.nim`.

New:
- [Every `F_c` but the bodies' and the deposit's is provisional until G2] → Provisional notes. The
  schema-v5 group waits on G2, and version 5 records the `F_c` set.
- [`F_edge` may not lie below today's fluid or scent impulse] → The "fraction" assertion stops the
  task and returns the numbers to the user (N2).
- [Friction stays per step, a second time convention inside integrate: at `ff` 10 a particle loses
  `1 − retention` per step, so less per reference frame] → This is a condition §3.5's arms hold fixed
  (crowding-redesign design §3.5, arm A). A cause probe found moving friction to `retention^ff`
  over-damps rather than restoring time consistency, and is a diagnostic only, not a fix
  (`scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md:90`); it is the user's call to
  reopen.
- [The per-reference-frame cap lets a particle move up to `maxVelocity · ff` per step where today it
  moves `maxVelocity`] → The travel count bounds it where a body needs it. §3.5's arms run at the
  frame factors the app produces, under the step limit, in place of a `ff_stable` re-bisection.
- [A body's own motion is not in the travel count. Bodies move by `velocity · dtSeconds` per substep
  (`web/shaders/src/body-integrate.wgsl:96-100`), and N4's `n_T` reads only particle Max Velocity, so a
  fast body can sweep its band across particles] → How far a body moves per substep is unmeasured. The travel count bounds particle travel only. This is a finding for
  `parametric-bodies`.
- [The effective Max Velocity drops at high `ff` while a body lives: 36 at ff 10 on the shipped
  band] → Visible only at time scale 5 with a body alive. The stored value is intact.
- [Pattern Scale's regime notches mark the scale-1 map] → The regime buttons apply the live-scale row,
  and a notch may sit off a drifted regime at small scales. This exists only where G3 records a
  drift row.
- [Deposit and chemistry stay on the field clock] → Non-goal, recorded.
- [Removing field-composite changes the bloom-off image for worlds with Field Opacity above 0] →
  Intended (the user's decision). The saved opacity is dropped.
- [A single commit converts five writers] → The oracles gate it. The in-app check at ff 1 is the
  visual confirmation.
- [Exact momentum after integrate is narrowed to the pressure integers a pair exchanges, not the
  integrated velocity, since the step limit scales two particles' shares of one pair unequally when
  their stiffness differs] → C4, C4b. The words stay exactly opposite; the world never conserved
  momentum in the species term either, since that matrix is asymmetric.
- [At time scale 2–5, dense crowds answer the mouse, blast and bodies more slowly per reference frame,
  reaching the same balance] → Accepted (the user's decision). A help line (4.10) and an in-app reading
  (12.1) state it.
- [The stiffness words cost 1–2 atomics per above-onset pair, and a crowd buffer at stride 3 rather
  than 1] → G1.4 (task 4.9) reads the added GPU cost against the allotment.
- [Overestimated `D` from stiffness-word quantization over-damps crowd-edge particles at ff 30 by at
  most `n_pairs · 2^-17` in `D`] → Bounded by construction (C4b); unmeasured in play.

## Migration Plan

1. **No behaviour change:**
   - `balance_core`, the unit functions and the today-convention oracles
   - `profiler_slots` and the new nodes and slots
   - the declaration table
2. The time switch (N3). Then the coarse word and the split, with the assertions.
3. The substep plan, the per-reference-frame cap, and the removal of the Substeps slider (N4).
4. The world pressure (C3–C5), the stiffness words and the lumped step limit (C4b), and gates 5–7.
   G1.1–G1.4 run here; G1.2 measures `L` at `K = 540` and 1728 under the limit, and G1.5 is replaced by
   §3.5's four arms rather than a `ff_stable` re-bisection.
5. **G2** in-app, then the gains, the 0–1 ranges, the constants restated for the scale, and schema
   version 5 (N2, N7), in one group.
6. Pattern Scale and G3 (N5). G4 reads in the final in-app pass.
7. The long-range unit (C2), after step 4 and before G2 in step 5, because G2 reads long range in it.
8. RD visual removal (N6), which can land at any point after step 1.
9. The fluid arms (N8).
10. Defects, help and docs (N9), and the amendments to other changes (N10).

**Rollback.** Revert. A version-5 preset loaded by older code fails the version check as any newer
preset does (`src/preset.nim:753-758`, `pekNewerSchemaVersion`). Presets saved while version 5 was live
do not load on the reverted build.
