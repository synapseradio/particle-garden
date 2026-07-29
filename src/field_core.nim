# ==============================================================================
# PARTICLE GARDEN - FIELD CORE (Pure Reaction-Diffusion Math)
# ==============================================================================
#
# Pure functions for the Gray-Scott reaction-diffusion field: the 9-point
# discrete Laplacian and one Gray-Scott step for a single grid cell. No side
# effects, no FFI — compiles on both the native (just test) and JS backends,
# and is the analytic mirror the rd-step.wgsl compute shader is written
# against (sph_core.nim and physics_core.nim play the same role for the SPH
# and species force math).
#
# The field itself (the two concentration channels, activator and inhibitor)
# lives only on the GPU as a storage texture — there is no CPU-side grid here.
# These functions take one cell's neighborhood as nine scalars and return the
# next step's two scalars, exactly the shape the shader's per-invocation body
# needs.
#
# Used by:
#   - tests/test_field_core.nim (native analytic tests)
#   - src/sim_registry.nim (RD_STEPS_PER_FRAME drives the frame's step count)
#   - src/shader_config.nim (the seed constants substituted into field-seed.wgsl)
#
# ==============================================================================

import std/math

# ==============================================================================
# FIELD DIMENSIONS
# ==============================================================================

const
  FIELD_WORLD_ASPECT* = 16.0 / 9.0
    ## The aspect of the world the field covers — src/config.nim's WORLD_W over
    ## WORLD_H. Stated here because field_core is pure and cannot import
    ## config.nim, which carries FFI pragmas; tests/test_field_core.nim reads
    ## config.nim from source and checks the two still agree.
  FIELD_PATTERN_SHRINK* = 4
    ## THE ONE KNOB FOR HOW BIG THE PATTERN DRAWS. Everything the field's scale
    ## touches is derived from it: the grid below, RD_DEFAULT_FIELD_FORCE,
    ## RD_FIELD_FORCE_MAX in config_ranges, and RD_SEED_BLOB_RADIUS.
    ##
    ## Reads as a multiple of a 512-cell square field: at 1 a spot draws that
    ## width, at 4 a quarter of it. Raising it
    ## costs memory and bandwidth quadratically and costs nothing else — the
    ## chemistry lives in cell space and never sees this (RD_DIFFUSION_A says
    ## what happens when something DOES move the chemistry).
  FIELD_W* = 512 * FIELD_PATTERN_SHRINK
    ## Storage-texture width for the reaction-diffusion field. Its own grid, not
    ## derived from the spatial hash the particle passes use.
  FIELD_H* = 288 * FIELD_PATTERN_SHRINK
    ## Storage-texture height. FIELD_W:FIELD_H holds FIELD_WORLD_ASPECT, which
    ## is what makes a cell SQUARE in world units.
    ##
    ## field-deposit.wgsl maps the whole world rect onto FIELD_W x FIELD_H, so
    ## the two aspects have to match. A square 512x512 grid over a 16:9 world
    ## would give cells 7.5 by 4.22 world units, and since the 9-point Laplacian
    ## is isotropic in CELLS, every spot would come out an ellipse 1.78x wider
    ## than tall.
    ##
    ## RESOLUTION IS THE ONLY SAFE LEVER FOR PATTERN SIZE. Gray-Scott's
    ## dynamics live in cell space, so shrinking the cell shrinks what the eye
    ## sees and changes no chemistry at all: every ignition threshold, regime
    ## coordinate and collapse bound in this file is measured in cells and
    ## survives untouched. RD_DIFFUSION_A says what the other lever costs.
    ##
    ## COST at the shipped shrink of 4: 2.36M cells, carried in two rgba16float
    ## ping-pong textures (~19 MB each) plus one i32 deposit buffer (~9 MB).
    ## Every frame runs 1 + RD_STEPS_PER_FRAME passes over all of it, so
    ## RD_STEPS_PER_FRAME is the lever to reach for if the field pass costs too
    ## much — it trades evolution speed for bandwidth and must stay odd.

# ==============================================================================
# TUNING CONSTANTS
# ==============================================================================

const
  RD_DIFFUSION_A* = 1.0
    ## Activator diffusion rate Da. Classic Gray-Scott convention: the
    ## activator diffuses at the reference rate 1.0.
    ##
    ## THESE RATES ARE NOT A TUNING KNOB FOR PATTERN SIZE, though the sqrt law
    ## in patternDiameterCells makes them look like one. Pearson's (F, k) phase
    ## map — which RD_REGIMES cites, which the feed and kill slider ranges are
    ## drawn against, and which every named regime is a coordinate in — is drawn
    ## at THESE diffusion rates. Moving them moves the whole map underneath the
    ## table: measured at Da=0.25, a floored regime settled 2.5x further from
    ## its own unforced morphology than from a different regime's, scattered
    ## deposits ignited without the coherence the shipped rate requires, and
    ## the chemotactic collapse the safety bound is measured against stopped
    ## reproducing.
    ## Pattern size is set by FIELD_W/FIELD_H instead, which changes what a cell
    ## covers and leaves the chemistry in cell space untouched.
  RD_DIFFUSION_B* = 0.5
    ## Inhibitor diffusion rate Db. Half the activator's rate — the ratio
    ## Db/Da that produces Turing-pattern instability rather than a field
    ## that simply smooths itself flat.
  RD_DELTA_T* = 1.0
    ## Per-substep timestep. Gray-Scott's explicit-Euler update is stable at
    ## dt=1 for these diffusion rates because the Laplacian is the normalized
    ## (center weight -1) 9-point stencil, laplacian9 — its worst-mode
    ## amplification factor reaches the unit circle exactly at Da*dt == 1, so
    ## the activator channel runs ON that boundary rather than inside it. The
    ## -4-center 5-point form would need dt <= 0.25 at these rates.
  RD_STEPS_PER_FRAME* = 7
    ## Reaction-diffusion substeps run per rendered frame. The pattern
    ## evolves slowly relative to a video frame, so multiple steps per frame
    ## buys visible motion without lowering dt (and hence stability).
    ## Must be ODD — see the static assertion below.
    ## NOT a free performance lever, although each frame runs
    ## 1 + RD_STEPS_PER_FRAME full-field passes and the cost is real: deposits
    ## fold once per frame, so LOWERING the substep count raises the deposit
    ## rate per unit of field time and dissolves the coherence requirement on
    ## ignition. Measured unscaled at 3: a scattered deposit ignites on frame 6, the
    ## critical splat radius falls from 5 to 3, and the single-cell negative
    ## control lights the field. The fold
    ## therefore renormalizes: RD_DEPOSIT_FRAME_SCALE below holds the deposit
    ## rate per FIELD STEP invariant under this knob, which is what makes it
    ## a speed lever at all. What the knob still changes is wall-clock: the
    ## pattern evolves proportionally slower, and particles travel further
    ## per field step, which the chemotaxis suite measures.
  RD_DEPOSIT_STEP_REFERENCE* = 8
    ## Field steps per frame — 1 + RD_STEPS_PER_FRAME — at which every deposit
    ## constant in this file was measured: the splat radius, the cell cap, the
    ## collapse bounds, and the regime deposit floors. The fold scales against
    ## this reference so those measurements stay valid when the substep count
    ## moves. Re-measuring the deposit constants at a new step count is the
    ## only reason to change this number.
  RD_DEPOSIT_FRAME_SCALE* =
    float(1 + RD_STEPS_PER_FRAME) / float(RD_DEPOSIT_STEP_REFERENCE)
    ## Multiplier the resolve fold applies to each frame's capped deposit so
    ## the deposit rate per FIELD STEP is invariant under RD_STEPS_PER_FRAME.
    ## Exactly 1.0 when the substep count sits at the reference. Applied after
    ## the cell cap, so the effective injection bound scales with it and the
    ## measured stability margin holds in field time.
  RD_DEFAULT_FEED* = 0.030
    ## Feed rate F. Paired with RD_DEFAULT_KILL below, this sits in Pearson's
    ## self-replicating-spots regime (see the constants' test suite for the
    ## citation and the (F, k) range it names).
  RD_DEFAULT_KILL* = 0.062
    ## Kill rate k. See RD_DEFAULT_FEED.
  RD_DEFAULT_DEPOSIT* = 0.02
    ## Default inhibitor concentration each particle folds into the field per
    ## frame. field-deposit.wgsl splats this (fixed-point) across the cells
    ## within RD_DEPOSIT_SPLAT_RADIUS; field-resolve.wgsl adds the decoded sum
    ## onto the inhibitor channel.
    ##
    ## Spread over a splat radius this magnitude IGNITES the field from a
    ## colony — that is what the radius exists to buy. Landing in one isolated
    ## cell it cannot: diffusion strips an isolated peak of Db*B per substep,
    ## so no deposit magnitude in a usable band lifts a single-cell
    ## perturbation off Gray-Scott's trivial (activator=1, inhibitor=0) fixed
    ## point. Coherence, not magnitude, is what crosses the threshold.
    ##
    ## MEASURED BAND (64x64 grid, Pearson defaults, seeded field, deposit folded
    ## once per frame ahead of RD_STEPS_PER_FRAME substeps): at 0.02 the pattern
    ## survives the forcing largely intact; from ~0.15 the field floods into a
    ## uniform bath rather than spots; at ~0.30 it diverges. RD_DEPOSIT_MAX in
    ## config_ranges is set well below the flood point because the feed/kill
    ## sliders can weaken the depletion that opposes the deposit.
  RD_DEFAULT_FIELD_FORCE* = 30.0 / float(FIELD_PATTERN_SHRINK)
    ## Default conversion from the sampled field gradient to a per-frame
    ## velocity impulse. field-force.wgsl multiplies the central-difference
    ## inhibitor gradient by this and writes it to the velocity-delta buffer
    ## integrate.wgsl consumes. Zero leaves particles blind to the field.
    ##
    ## DIVIDED BY THE SHRINK, because of a unit mismatch that is easy to miss:
    ## the gradient is taken PER CELL while the impulse lands in WORLD units.
    ## Holding the number fixed while the cell shrinks therefore leaves a
    ## particle moving the same distance per frame across a pattern that has
    ## itself become smaller, so its response to a feature strengthens by
    ## exactly the shrink.
    ##
    ##   cells crossed per frame = gradient * scale * FIELD_W / worldWidth
    ##
    ## What holds a particle's behaviour fixed is that product, not this
    ## constant. 30 against the 512-cell field's 7.5 world units per cell is the
    ## same motion through the same pattern as 7.5 against 1.875. Every
    ## measurement in the chemotactic collapse suite is taken in cell space and
    ## rests on that identity — tests/test_field_core.nim derives its harness
    ## geometry from FIELD_W for exactly this reason.
    ##
    ## MEASURED (128x128 torus, settled at the Pearson defaults, central
    ## difference): mean inhibitor gradient 0.0364 per cell, peak 0.0868. At 30
    ## against the original grid that is roughly 1.5 velocity units per frame
    ## against a maxVelocity of 50.
# ==============================================================================
# HOW BIG THE PATTERN DRAWS
# ==============================================================================
#
# Two independent levers set the size of a spot on screen, and only their
# product is visible: Gray-Scott's wavelength in CELLS, which scales as
# sqrt(diffusion), and the world extent one cell covers, worldExtent/fieldExtent.
# These functions state that product so a change to either lever can be checked
# against the other rather than eyeballed.
#
# No caller in src/ — like physics_core and sph_core, this is a reference oracle
# the native suite measures the shipped constants against.

const
  RD_DIAMETER_CELLS_AT_UNIT_DIFFUSION* = 9.30
    ## Mean spot diameter in cells at the conventional Da=1.0, Db=0.5.
    ##
    ## MEASURED (128x128 torus, Pearson defaults, 30 seeded blobs, 6000 steps,
    ## connected components above half the peak inhibitor). Diameter tracks
    ## sqrt(diffusion) closely across the usable band: 9.30 cells at scale 1.0,
    ## 6.55 at 0.5 (predicted 6.58), 4.47 at 0.25 (predicted 4.65), 3.71 at 0.16
    ## (predicted 3.72).
  RD_MIN_RESOLVED_DIAMETER_CELLS* = 4.0
    ## Narrowest pattern the grid still carries as a pattern.
    ##
    ## MEASURED, same sweep: below scale 0.16 the sqrt law stops holding and the
    ## pattern dies rather than shrinking — at 0.09 coverage collapses from 0.22
    ## to 0.03, and by 0.04 every surviving component is a single cell. 4.0 sits
    ## above that cliff rather than on it.

func patternDiameterCells*(diffusionA: float): float =
  ## Mean spot diameter in FIELD CELLS at an activator diffusion rate, assuming
  ## Db/Da holds at 0.5. Turing wavelength goes as the square root of the
  ## diffusion coefficient, so quartering the rate halves the pattern.
  RD_DIAMETER_CELLS_AT_UNIT_DIFFUSION * sqrt(diffusionA)

func patternDiameterWorld*(diffusionA, fieldExtent, worldExtent: float): float =
  ## Mean spot diameter in WORLD units — what the eye actually judges. Takes the
  ## field and world extents rather than reading FIELD_W, so the shipped
  ## geometry can be compared against another one.
  patternDiameterCells(diffusionA) * (worldExtent / fieldExtent)

static:
  # Field cells must be square in world units. field-deposit.wgsl maps the whole
  # world rect onto FIELD_W x FIELD_H, so any mismatch between the two aspects
  # stretches every pattern the field draws by exactly that mismatch.
  doAssert abs(FIELD_W.float / FIELD_H.float - FIELD_WORLD_ASPECT) < 1e-9

  # fieldResolve is itself a ping-pong stage — it reads the trailing texture
  # and writes the front — so one frame performs 1 + RD_STEPS_PER_FRAME texture
  # swaps. That total must be even for the live field to land back on the
  # texture the renderer samples and the next frame's resolve reads. An even
  # RD_STEPS_PER_FRAME leaves it on the wrong texture, silently discarding the
  # last substep every frame.
  doAssert RD_STEPS_PER_FRAME mod 2 == 1

# ==============================================================================
# DEPOSIT SPLAT KERNEL
# ==============================================================================
#
# A particle's deposit is spread over a disc rather than dropped in one cell,
# because coherence is what escapes the trivial fixed point and a single cell
# has none. web/shaders/src/field-deposit.wgsl mirrors these two functions; the
# radius and the normalization reach it as substituted shader constants, so the
# two sides cannot disagree about kernel weight.
#
# The kernel is NORMALIZED: a particle contributes the same total deposit
# whatever the radius. Spreading is a redistribution, not an amplification —
# which is why widening the radius cannot flood the field past the ceiling
# RD_DEPOSIT_MAX is measured against.

const
  RD_DEPOSIT_SPLAT_RADIUS* = 5.0
    ## Radius in field cells over which one particle's deposit is spread.
    ##
    ## MEASURED (tests/test_field_core.nim, 64x64 grid, flat trivial-fixed-point
    ## start, deposit coverage matched to the scattered baseline, deposit folded
    ## once per frame ahead of RD_STEPS_PER_FRAME substeps). Minimum igniting
    ## (radius, amplitude) at the shipped Pearson defaults:
    ##
    ##   Gaussian profile: radius 5 at amplitude 0.02 — ignites on frame 12
    ##   Top-hat profile:  radius 8 at amplitude 0.02 — ignites on frame 9
    ##   radius 3:         does not ignite at 0.02; needs 0.04
    ##   radius 1:         does not ignite at ANY amplitude up to
    ##                     RD_DEPOSIT_MAX, over 120 frames
    ##
    ## 5 is therefore the floor at the shipped deposit, and the Gaussian profile
    ## is what buys it: at radius 5 the top-hat does NOT ignite at 0.02, because
    ## the same total weight spread flat reaches a lower peak. The measurement
    ## uses uniform particle coverage, so it is a lower bound — a real colony
    ## concentrates deposits far above the uniform mask and ignites sooner.
    ##
    ## Traded against cost: the splat costs one atomic per covered cell per
    ## particle, so ~79 atomics here versus ~201 at radius 8. Radius 5 is the
    ## smallest measured radius that ignites at the default deposit, which is
    ## the cheapest honest choice.
  RD_DEPOSIT_SPLAT_SIGMA_FRACTION* = 0.5
    ## Sigma as a fraction of the splat radius, so the width scales with any
    ## radius `depositSplatWeight` is handed rather than only with the shipped
    ## one.
  RD_DEPOSIT_SPLAT_SIGMA* = RD_DEPOSIT_SPLAT_RADIUS * RD_DEPOSIT_SPLAT_SIGMA_FRACTION
    ## Gaussian falloff width. Half the radius puts the truncation at 2 sigma,
    ## where the weight has fallen to ~13% of the peak — far enough out that
    ## the cut does not visibly square off the splat, close enough that the
    ## kernel stays compact.
  FIELD_ALIVE_THRESHOLD* = 0.15
    ## Inhibitor level above which a cell counts as alive — the single
    ## authority read by the pattern tests, the stepped probes, and
    ## field-resolve.wgsl's census (substituted through shader_config).
  RD_DEPOSIT_CELL_MAX* = 0.10
    ## Most inhibitor one cell may take from particles in one frame.
    ##
    ## RD_DEPOSIT_MAX bounds ONE PARTICLE. This bounds their SUM, which is the
    ## quantity the stability argument needs and the one nothing else limits:
    ## particles per cell has no ceiling, so any input that gathers a crowd
    ## into one place drives a cell without limit. At 0.02 it takes ~342
    ## co-located particles to reach a diverging deposit and ~86 at
    ## RD_DEPOSIT_MAX, both of which a held mouse passes immediately.
    ##
    ## MEASURED (64x64 grid, 100 feed/kill samples across the full slider
    ## ranges, a block of cells taking the cap every frame for 400 frames on
    ## top of a living pattern — the held mouse, without end):
    ##
    ##   cap 0.10, 3x3 and 21x21 blocks: stable, peak inhibitor 0.637
    ##   cap 0.20, 3x3 and 21x21 blocks: stable, peak inhibitor 0.658
    ##   cap 0.25, 21x21 block:          diverges at feed 0.010, kill 0.040
    ##
    ## 0.10 is half the largest measured stable cap. The margin is worth its
    ## cost because the boundary is not monotone near the edge — clamping the
    ## field's STATE instead was measured stable at 0.75 and unstable at both
    ## 0.72 and 0.80 — so a cap chosen at the last passing sample would sit on
    ## a ragged edge rather than inside a safe interval.
    ##
    ## Bounding the injection rather than the state is what leaves the reaction
    ## alone: a living pattern reaches 0.515 inhibitor in steady state and
    ## excursions above 0.7 while igniting, all of it self-limiting. A ceiling
    ## on the state would clip those; a ceiling on what particles add does not.

func resolveCellDeposit*(inhibitor, deposit: float,
    scale = RD_DEPOSIT_FRAME_SCALE): float =
  ## One cell's inhibitor after this frame's particle deposits land on it.
  ## Mirrors field-resolve.wgsl in the same order: cap the incoming deposit,
  ## scale it per field step, fold it onto the inhibitor, then floor the fold
  ## at 0.0. The cap is on what arrives, never on what the reaction produces,
  ## so the dynamics keep every excursion they make. The scale parameter
  ## exists for the invariance test; every shipped caller takes the default.
  ##
  ## The cap bounds excess only from above (min() against a negative deposit
  ## is a no-op), so full-erosion secretion has no matching floor without this
  ## last step: enough eroders sharing one cell drive the fold negative, and
  ## the reaction term (activator * inhibitor^2) does not distinguish sign —
  ## a negative inhibitor erodes activator the same way a positive one would
  ## spend it.
  max(0.0, inhibitor + scale * min(deposit, RD_DEPOSIT_CELL_MAX))

func depositSplatWeight*(distance, radius: float): float =
  ## Unnormalized weight one cell receives from a particle `distance` cells
  ## away. Gaussian out to the radius, zero beyond it. Truncation keeps the
  ## covered-cell count finite and the shader's loop bounded.
  if distance > radius: return 0.0
  let sigma = radius * RD_DEPOSIT_SPLAT_SIGMA_FRACTION
  exp(-(distance * distance) / (2.0 * sigma * sigma))

func depositSplatNormalization*(radius: float): float =
  ## Total unnormalized weight the kernel places, summed over the same integer
  ## cell offsets the shader visits. Dividing by this is what conserves a
  ## particle's total deposit across radii.
  ##
  ## Summed rather than integrated on purpose: the continuous Gaussian integral
  ## would disagree with the discrete sum the shader actually performs, and the
  ## disagreement grows as the radius shrinks toward a single cell.
  let extent = int(radius)
  for dy in -extent .. extent:
    for dx in -extent .. extent:
      result += depositSplatWeight(
        sqrt((dx * dx + dy * dy).float), radius)

# ==============================================================================
# SPECIES CHEMISTRY
# ==============================================================================
#
# Each species couples to the field through two signed scalars. SECRETION
# scales what it deposits: positive builds inhibitor structure, negative erodes
# it, zero leaves no mark. TROPISM scales the gradient force it feels:
# NEGATIVE moves a particle DOWN the inhibitor gradient, away from its own
# deposits; POSITIVE moves it UP, toward them.
#
# The sign convention is not arbitrary and the two directions are not
# symmetric. Climbing a self-deposited gradient is a positive feedback loop —
# the Keller-Segel chemotactic-collapse threshold chi*M > 8*pi applies to
# exactly that sign, while negative chemosensitivity is stabilizing
# (docs/research/chemotaxis-stability.md). That asymmetry is why TROPISM_MAX in
# config_ranges is half of |TROPISM_MIN|, and why tests/test_field_core.nim
# measures the collapse point rather than assuming one.
#
# web/shaders/src/field-deposit.wgsl and field-force.wgsl mirror the two
# functions below; gpu_types.SpeciesChemistryLayout is how the values reach
# them.

const
  SPECIES_CHEMISTRY_STRIDE* = 2
    ## Values per species in the CPU-side chemistry array: secretion, then
    ## tropism. The GPU packs the same data as two parallel channels
    ## (gpu_types.SpeciesChemistryLayout); this stride is the interleaved
    ## CPU-side layout the UI edits in place.
  SPECIES_SECRETION_SLOT* = 0
  SPECIES_TROPISM_SLOT* = 1
  RD_DEFAULT_SECRETION* = 1.0
    ## Full positive secretion: a species deposits exactly RD_DEFAULT_DEPOSIT,
    ## which is what the field ships doing. Every measurement behind
    ## RD_DEPOSIT_MAX and RD_DEPOSIT_SPLAT_RADIUS is taken at this value.
  RD_DEFAULT_TROPISM* = -1.0
    ## Full DOWN-gradient response, the stabilizing sign: particles are pushed
    ## away from their own deposits, spreading across the pattern instead of
    ## piling onto one seed. The default sits at the bound because the bound is
    ## the safe end of an asymmetric range, not the risky one.

func speciesDeposit*(depositAmount, secretion: float): float =
  ## What one species folds into the field per frame, before the splat kernel
  ## redistributes it. Signed: a negative secretion removes inhibitor.
  ## Mirrors field-deposit.wgsl.
  depositAmount * secretion

func speciesTropismForce*(gradient, fieldForceScale, tropism: float): float =
  ## One axis of the velocity impulse a species feels from the field gradient.
  ## Mirrors field-force.wgsl. The sign lives entirely in `tropism`: negative
  ## descends the inhibitor gradient, positive climbs it.
  gradient * fieldForceScale * tropism

# ==============================================================================
# FIELD SEED
# ==============================================================================
#
# The initial field state. The render-pass clear the field textures get
# (activator=1, inhibitor=0) is Gray-Scott's trivial fixed point for ANY
# feed/kill/dt, and per-cell noise cannot escape it either — an isolated peak
# loses Db*B to diffusion every substep with no neighbors to replenish it. Only
# a spatially COHERENT perturbation ignites the system, which is what these
# blobs are.
#
# web/shaders/src/field-seed.wgsl mirrors rdSeedCell exactly. The pair is
# hand-maintained with no compile-time link, the same contract grayScottStep
# and rd-step.wgsl already have. Blob centers are integers and the hash is pure
# 32-bit integer arithmetic precisely so Nim's float64 and WGSL's f32 cannot
# disagree about where a blob is.

const
  RD_SEED_BLOB_COUNT* = 48
    ## Blobs the seed scatters across the field. Calibrated for the shipped
    ## FIELD_W x FIELD_H: enough that spots fill the frame within a few
    ## seconds, few enough that the seed reads as scattered structure rather
    ## than a uniform bath.
  RD_SEED_BLOB_RADIUS* = 6.0 * float(FIELD_PATTERN_SHRINK)
    ## Blob radius in cells. The floor that matters is coherence, not size —
    ## below ~2 cells diffusion erases the blob before it can react.
    ##
    ## Multiplied by the shrink so a spore holds the same WORLD footprint at any
    ## field resolution: it stays the same size on screen and simply spans more
    ## cells at a higher shrink.
  RD_SEED_CORE_ACTIVATOR* = 0.5
    ## Activator concentration at a blob's core. Depressed from the background
    ## 1.0: Gray-Scott spots are activator-depleted, inhibitor-rich regions.
  RD_SEED_CORE_INHIBITOR* = 0.25
    ## Inhibitor concentration at a blob's core, against a background of 0.

func rdSeedHash*(value: uint32): uint32 =
  ## A pure 32-bit integer hash (the lowbias32 xor-shift/multiply chain). No
  ## floating point anywhere: this is what lets field-seed.wgsl, which has only
  ## f32, place blobs at byte-identical integer coordinates.
  var mixed = value
  mixed = mixed xor (mixed shr 16)
  mixed = mixed * 0x7feb352d'u32
  mixed = mixed xor (mixed shr 15)
  mixed = mixed * 0x846ca68b'u32
  mixed = mixed xor (mixed shr 16)
  mixed

func rdSeedBlobCenter*(blobIndex: int, nonce: uint32, width, height: int):
    tuple[x, y: int] =
  ## Integer cell coordinates of one blob's center. The nonce is what makes
  ## Reset produce a different pattern rather than the same one again.
  let stream = rdSeedHash(uint32(blobIndex) * 2'u32 + 1'u32) xor
    rdSeedHash(nonce)
  (x: int(rdSeedHash(stream) mod uint32(width)),
   y: int(rdSeedHash(stream xor 0x9e3779b9'u32) mod uint32(height)))

func rdSeedCell*(x, y: int, nonce: uint32, width, height, blobCount: int,
    blobRadius: float): tuple[activator, inhibitor: float] =
  ## The seeded state of one field cell: the background (activator 1,
  ## inhibitor 0) blended toward the blob core by the strongest blob covering
  ## it. Distances are toroidal because the field wraps, exactly as the
  ## Laplacian's neighbor lookups do.
  ##
  ## The blend takes the MAX over blobs rather than the sum, so overlapping
  ## blobs saturate at the core values instead of stacking past them into the
  ## flooded regime.
  var coverage = 0.0
  for blobIndex in 0 ..< blobCount:
    let center = rdSeedBlobCenter(blobIndex, nonce, width, height)
    var dx = abs(x - center.x).float
    if dx > width.float * 0.5: dx = width.float - dx
    var dy = abs(y - center.y).float
    if dy > height.float * 0.5: dy = height.float - dy
    let distance = sqrt(dx * dx + dy * dy)
    # A flat core out to half the radius, falling to background at the edge.
    let falloff = clamp((blobRadius - distance) / (blobRadius * 0.5), 0.0, 1.0)
    coverage = max(coverage, falloff)
  (activator: 1.0 + (RD_SEED_CORE_ACTIVATOR - 1.0) * coverage,
   inhibitor: RD_SEED_CORE_INHIBITOR * coverage)

# ==============================================================================
# FIELD GRID TOPOLOGY
# ==============================================================================

func fieldWrap*(cell, dims: int): int =
  ## The field's toroidal wrap: every integer cell coordinate, however far
  ## outside the grid, names exactly one in-range cell. Floor-mod, because the
  ## single-mod spelling `(cell + dims) mod dims` survives only one span of
  ## negativity. web/shaders/modules/field_grid.wgsl mirrors this per axis.
  result = cell mod dims
  if result < 0:
    result += dims

# ==============================================================================
# 9-POINT LAPLACIAN STENCIL
# ==============================================================================

func laplacian9*(center, north, south, east, west, ne, nw, se, sw: float):
    float =
  ## The discrete 2D Laplacian at one grid cell via the normalized 9-point
  ## stencil: 0.2 per axis-neighbor, 0.05 per diagonal, -1 for the center.
  ## The weights sum to 0, so the stencil is zero on a constant field (no
  ## curvature to diffuse), linear in its nine inputs, and reduces to -center
  ## when all neighbors are 0 (an isolated peak's own decay).
  0.2 * (north + south + east + west) + 0.05 * (ne + nw + se + sw) - center

# ==============================================================================
# GRAY-SCOTT REACTION-DIFFUSION STEP
# ==============================================================================

func grayScottStep*(activator, inhibitor, laplacianA, laplacianB,
    diffusionA, diffusionB, feed, kill, deltaT: float):
    tuple[activator, inhibitor: float] =
  ## One explicit-Euler Gray-Scott step for a single cell, given its current
  ## activator/inhibitor concentrations and their precomputed Laplacians (see
  ## laplacian9). The classic two-channel reaction-diffusion system:
  ##   reaction = activator * inhibitor^2
  ##   activator' = activator + dt*(Da*lapA - reaction + feed*(1-activator))
  ##   inhibitor' = inhibitor + dt*(Db*lapB + reaction - (feed+kill)*inhibitor)
  ## The feed term replenishes the activator toward 1; the kill term (plus
  ## feed's equal drain) depletes the inhibitor. At the trivial steady state
  ## (activator=1, inhibitor=0) with no diffusion, both terms vanish for any
  ## feed/kill — the fixed point the tests pin analytically.
  let reaction = activator * inhibitor * inhibitor
  let nextActivator = activator + deltaT * (
    diffusionA * laplacianA - reaction + feed * (1.0 - activator))
  let nextInhibitor = inhibitor + deltaT * (
    diffusionB * laplacianB + reaction - (feed + kill) * inhibitor)
  (activator: nextActivator, inhibitor: nextInhibitor)
