# Force budget

How much velocity each of the three force layers hands the integrator, in
pixels per frame, read where the layer writes into `velocityDeltaFixed`: before
friction, before the logarithmic soft cap, and summed across the substeps a
rendered frame encodes. `tests/test_force_budget.nim` writes this file.

## Conditions

| what | value |
|---|---|
| commit | 39b01c667a98 |
| seed | 0x9E3779B9, a fixed LCG |
| world | 3840 x 2160 px, toroidal |
| particles | 16000 |
| number density | 1.929e-03 particles per square px |
| species | 4, on a cyclic-chase matrix at the band edges |
| interaction radius | 50 px |
| friction | 0.05 |
| maxVelocity | 50.0 px per frame |
| timeScale | 0.50 |
| force curve | polynomial, repulsionEnd 0.50, attractionPeak 0.75 |
| particle horizon | 20 settling frames, 10 measured |
| field horizon | 250 frames of field alone, then 120 settling and 20 measured |
| settling tolerance | 0.05 relative drift across the window |
| species agreement tolerance | 1e-4 relative, against an all-pairs reference |
| runtime | 0.042 s per frame at 16000 particles |

The field runs on a periodic patch of the shipped grid, 128 by 128 cells at the shipped 1.875 px per cell, holding
the 111 particles the reference number density
places in it. The full grid is 2.36 million cells and costs about 0.73 s per
frame in this build, which no horizon here can afford.

## The three layers

Each layer is measured with the other couplings at their shipped defaults, and
the fluid's shipped default is zero, so the fluid's own default budget is zero
by construction.

| layer | shipped default | full scale | full-scale p95 | cap saturated |
|---|---|---|---|---|
| species | 1.119e-02 | 5.708e-02 | 1.228e-01 | 0.0000 |
| fluid | 0.000e+00 | 1.174e-02 | 2.347e-02 | 0.0000 |
| field | 1.915e-02 | 4.753e-02 | 1.028e-01 | 0.0000 |

Full scale means forceStrength 5.0, fluidStrength 1.0 and rdFieldForce 37.5.

Under the fixed 0.3/1.3/0.7 curve, which no shipped forceModel selects, the
species budget at the shipped defaults reads 4.532e-03. Under the polynomial
curve forceModel 0 ships, it reads 1.119e-02.

## The pre-registered prediction

The prediction went on the record before this harness ran: about 3e-4 px per
frame from the species force at the shipped defaults, and about 0.27 from the
field force.

| layer | predicted | measured | measured over predicted |
|---|---|---|---|
| species | 3.000e-04 | 1.119e-02 | 37.3 |
| field | 2.700e-01 | 1.915e-02 | 0.071 |

Both predictions missed, in opposite directions, and the measurement stands.

The species force delivers more than predicted. The prediction treated the
arrangement as the seeded scatter. It does not stay that way: over the settling
frames attraction pulls neighbours together, local density rises, and the force
rises with it.

The field force delivers far less than predicted. The prediction multiplied the
field force scale by the inhibitor gradient averaged over every cell of the
grid, a gradient of 3.600e-02 per cell. Particles do not sample cells uniformly. The shipped tropism
is -1.0, full
down-gradient, so each particle is driven toward the flats of the pattern and
comes to rest where the gradient is small.

Measured from the frame the population is scattered, before that sorting has
happened, the same scene reads 1.176e-01 px per frame. After 120 settling frames it reads 1.915e-02. The distance between those two numbers is the whole of the
disagreement with the prediction.

## Settling

Every number above is measured after the settling frames, on a world that has
had time to arrange itself. That arrangement is most of the answer, and the
three layers move in opposite directions as it forms.

| layer | fresh scatter | settled | settled over fresh |
|---|---|---|---|
| species | 1.213e-02 | 1.119e-02 | 0.92 |
| fluid | 1.596e-01 | 1.174e-02 | 0.07 |
| field | 1.176e-01 | 1.915e-02 | 0.16 |

The species force rises as the world settles, because attraction gathers
neighbours and the force grows with local density. The fluid and the field both
fall, and for the same reason in two guises: each is a restoring force acting
against a disorder it is busy removing. Pressure drives the population toward
the locally uniform spacing where pressure cancels. Down-gradient tropism drives
each particle toward a flat of the pattern, where the gradient it reads is
small.

A budget quoted on a fresh scatter therefore describes a transient. The
species row is measured at the shipped defaults, the fluid row at full scale,
because the shipped fluid strength is zero.

## Species strength

Every other coupling at its shipped default.

| forceStrength | species mean | species p95 | fluid mean | fluid p95 |
|---|---|---|---|---|
| 0.00 | 0.000e+00 | 0.000e+00 | 0.000e+00 | 0.000e+00 |
| 0.50 | 5.856e-03 | 1.207e-02 | 0.000e+00 | 0.000e+00 |
| 1.00 | 1.119e-02 | 2.308e-02 | 0.000e+00 | 0.000e+00 |
| 1.50 | 1.628e-02 | 3.401e-02 | 0.000e+00 | 0.000e+00 |
| 2.00 | 2.145e-02 | 4.541e-02 | 0.000e+00 | 0.000e+00 |
| 2.50 | 2.683e-02 | 5.716e-02 | 0.000e+00 | 0.000e+00 |
| 3.00 | 3.246e-02 | 6.934e-02 | 0.000e+00 | 0.000e+00 |
| 3.50 | 3.832e-02 | 8.209e-02 | 0.000e+00 | 0.000e+00 |
| 4.00 | 4.439e-02 | 9.523e-02 | 0.000e+00 | 0.000e+00 |
| 4.50 | 5.065e-02 | 1.087e-01 | 0.000e+00 | 0.000e+00 |
| 5.00 | 5.708e-02 | 1.228e-01 | 0.000e+00 | 0.000e+00 |

## Fluid strength

Every other coupling at its shipped default. The species column moves along
this axis because the fluid rearranges the population the species force acts on,
and because a fluid above zero makes the frame take sphSubsteps substeps
instead of one.

| fluidStrength | species mean | species p95 | fluid mean | fluid p95 |
|---|---|---|---|---|
| 0.00 | 1.119e-02 | 2.308e-02 | 0.000e+00 | 0.000e+00 |
| 0.10 | 1.084e-02 | 2.208e-02 | 8.084e-03 | 1.720e-02 |
| 0.20 | 1.087e-02 | 2.200e-02 | 9.704e-03 | 1.984e-02 |
| 0.30 | 1.091e-02 | 2.202e-02 | 1.046e-02 | 2.103e-02 |
| 0.40 | 1.094e-02 | 2.209e-02 | 1.087e-02 | 2.172e-02 |
| 0.50 | 1.095e-02 | 2.210e-02 | 1.113e-02 | 2.230e-02 |
| 0.60 | 1.096e-02 | 2.213e-02 | 1.132e-02 | 2.268e-02 |
| 0.70 | 1.097e-02 | 2.211e-02 | 1.146e-02 | 2.292e-02 |
| 0.80 | 1.098e-02 | 2.215e-02 | 1.157e-02 | 2.314e-02 |
| 0.90 | 1.098e-02 | 2.218e-02 | 1.166e-02 | 2.334e-02 |
| 1.00 | 1.099e-02 | 2.219e-02 | 1.174e-02 | 2.347e-02 |

## Field force

Every other coupling at its shipped default.

| rdFieldForce | field mean | field p95 | cap saturated |
|---|---|---|---|
| 0.00 | 0.000e+00 | 0.000e+00 | 0.0000 |
| 3.75 | 1.446e-02 | 3.159e-02 | 0.0000 |
| 7.50 | 1.915e-02 | 3.889e-02 | 0.0000 |
| 11.25 | 2.065e-02 | 4.173e-02 | 0.0000 |
| 15.00 | 2.606e-02 | 5.323e-02 | 0.0000 |
| 18.75 | 3.030e-02 | 6.516e-02 | 0.0000 |
| 22.50 | 3.339e-02 | 7.026e-02 | 0.0000 |
| 26.25 | 3.778e-02 | 7.877e-02 | 0.0000 |
| 30.00 | 4.064e-02 | 8.629e-02 | 0.0000 |
| 33.75 | 4.383e-02 | 9.400e-02 | 0.0000 |
| 37.50 | 4.753e-02 | 1.028e-01 | 0.0000 |

## timeScale

Shared axis, every coupling at full scale.

| timeScale | species mean | fluid mean | field mean |
|---|---|---|---|
| 0.10 | 1.126e-02 | 1.035e-02 | 1.779e-02 |
| 0.50 | 5.311e-02 | 4.785e-02 | 8.910e-02 |
| 5.00 | 5.003e-01 | 4.989e-01 | 1.911e+00 |

`params.dt` is a gain rather than a timestep: `integrate.wgsl` advances position
by the velocity itself with no dt. The species force multiplies by dt once and
so scales with this axis. The field force reaches the axis by two routes at
once. `frameScaledFieldForce` multiplies its gain by the frame's dt as a
multiple of `FRAME_DT_REFERENCE`, and `rdStepsForTimeScale` sets how many
reaction-diffusion steps a frame runs, so the pattern the force reads evolves at
a rate this axis sets too. The two compound, which is why the column climbs
faster than the axis above the reference.

## sphSubsteps

Shared axis, every coupling at full scale. The axis bites only where the fluid
acts, because `webgpu_compute` encodes one substep per frame otherwise.

| sphSubsteps | species mean | fluid mean | field mean |
|---|---|---|---|
| 1 | 5.340e-02 | 5.382e-02 | 1.030e-01 |
| 3 | 5.315e-02 | 4.755e-02 | 8.594e-02 |

The chemistry carries `fncOncePerFrame`, so the deposit fold and the
reaction-diffusion chain run once however many substeps the frame encodes, and
the field the force reads is the same field at either substep count. The species
force and the field force divide dt by the substep count and run that many
times, so what each sums over a frame is left where it was. That leaves one
route for this axis to reach either column: particles move between substeps and
therefore sample their neighbors and the field from different places.

## Number density

Shared axis, every coupling at full scale, as a multiple of the reference
1.929e-03 particles per square px. The
world is held and the count varies.

| density | species mean | fluid mean | field mean |
|---|---|---|---|
| 0.5x | 3.832e-02 | 3.072e-02 | 8.910e-02 |
| 1.0x | 5.311e-02 | 4.785e-02 | 8.910e-02 |
| 2.0x | 7.483e-02 | 7.363e-02 | 8.910e-02 |

## Interaction radius

Shared axis, every coupling at full scale. No term of the field force reads the
interaction radius. Its column still moves along this axis, because a wider
radius changes where the species force carries the particles, and a particle
elsewhere reads a different part of the pattern.

| interactionRadius | species mean | fluid mean | field mean |
|---|---|---|---|
| 10 | 4.699e-03 | 2.025e-03 | 4.007e-02 |
| 50 | 5.311e-02 | 4.785e-02 | 8.910e-02 |
| 150 | 1.596e-01 | 1.582e-01 | 1.404e-01 |

## The octave band

The three layers at full scale span a factor of 4.9, against a band of 2.

| layer | full-scale mean |
|---|---|
| species | 5.708e-02 |
| fluid | 1.174e-02 |
| field | 4.753e-02 |

`tests/test_force_budget.nim` carries that comparison as a test, and it is red.
A slider at full travel means a different amount of velocity depending on which
layer it belongs to, by the factor above.

## The seed radius

Separate from the budget, and found while building the field limb.

`RD_SEED_BLOB_RADIUS` is 24 cells, and a field seeded with it does not ignite.
Measured on the shipped grid itself rather than on the patch: `FIELD_W` by
`FIELD_H` at 2048 by 1152, `RD_SEED_BLOB_COUNT` at 48, radius 24, feed 0.030,
kill 0.062, no particle deposit, 200 frames. The seed starts with 1.776% of
cells above `FIELD_ALIVE_THRESHOLD` and a peak inhibitor of 0.25000. By frame
25 the peak is 0.00066, and from frame 50 to the end of the run it is 0.00000
with no cell alive.

Domain fraction does not account for it. On a 128-cell patch, holding the blob
at the shipped 2.34% of the width (radius 1.5) fails to ignite at one, 24 and 85
blobs, the last of which matches the shipped 3.68% areal coverage. Holding the
radius at 24 and growing the domain to 512 cells, where the blob spans 9.38% of
the width and 3.45% of the area, also fails. A radius-6 blob at that same 9.38%
of the width does ignite, reaching 29.2% of cells alive. Changing the radius
flips the outcome across every domain fraction tried, and holding the domain
fraction at the shipped value changes nothing.

What this bounds is the seed on its own. The run carries no particle deposit,
while `RD_DEFAULT_DEPOSIT` ships at 0.02 and every particle folds chemical into
the field each frame, so the running app reaches the field by a second route
this measurement excludes. Whether the shipped world shows a pattern is
therefore a question about deposit, unanswered here; what is answered is that
the seed the reseed path lays down dies within 50 frames if nothing feeds it.

`RD_SEED_BLOB_RADIUS` stands unchanged.

## Deviations

The species and fluid layers are measured on the full reference world with the
field force silent, because the reaction-diffusion field cannot run at world
scale inside a test. The field layer is measured on the patch with the species
force at its shipped default. No measurement here carries all three couplings
at once.

The field patch is seeded with blobs of radius 6 rather than
`RD_SEED_BLOB_RADIUS`, because a blob at the shipped radius does not ignite.
The settled pattern does not depend on which seed reaches it: seeds an order of
magnitude apart in coverage converge to the same grid-mean gradient of 0.0354
and the same 29.2% of cells alive.
