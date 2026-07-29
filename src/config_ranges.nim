# ==============================================================================
# PARTICLE GARDEN - SLIDER RANGE CONTRACT (Pure)
# ==============================================================================
#
# The single source of truth for every user-facing tunable's range. Pure
# (no FFI, no DOM): compiles on both the native and JS backends.
#
# Consumed by:
#   - ui/api/param_descriptor.nim (the descriptor table the Solid panel's
#     sliders and web_api's setParam clamping are built from)
#   - preset.nim's clamp bounds (what a loaded preset is coerced into)
#   - tests (natively)
#
# Because both consumers read these constants, the UI and the preset schema
# cannot drift apart — neither side holds its own copy, so a preset bound
# cannot track a dead web/index.html attribute (a 64000 particle ceiling
# against a live 128000 slider).
#
# ==============================================================================

import memory_layout
import sph_core
import field_core
import bloom_core
import colormap_core

const
  PARTICLE_COUNT_MIN* = 100
  PARTICLE_COUNT_MAX* = memory_layout.MAX_PARTICLES
  SPECIES_COUNT_MIN* = 2
    ## Minimum 2: particle life needs at least two species for cross-species
    ## rules to exist. This constant is the only authority on that floor.
  SPECIES_COUNT_MAX* = memory_layout.MAX_SPECIES
  INTERACTION_RADIUS_MIN* = 10
  INTERACTION_RADIUS_MAX* = 150
  FORCE_STRENGTH_MIN* = 0.0
    ## Zero is an ordinary value of a coupling strength (design D13).
    ## `fMul` scales BOTH force zones (`src/physics_core.nim:52-60`), so zero
    ## removes short-range repulsion too and particles pass through each other.
    ## Design C0 covers what that means for the crowding cap.
  FORCE_STRENGTH_MAX* = 5.0
  CROWDING_STRENGTH_MIN* = 0.0
    ## Zero is today's force law exactly — `1 / (1 + 0 * log(1 + density))` is 1
    ## at every density — so it must stay reachable, and any regression the
    ## crowding term introduces bisects to this one number.
  CROWDING_STRENGTH_MAX* = 2.0
    ## PROVISIONAL, pending the calibration one-world task C1.9 carries. That
    ## task measures the strength at which a collapsing single-species world
    ## stops tightening and the strength at which ordinary colonies visibly
    ## soften, sets the default between them, and sets this ceiling above the
    ## second — with the conditions recorded here, per the measured-bound rule.
    ## Until then this is a working bound, not a measured one, and the ceiling
    ## sweep in tests/test_physics.nim reads it from here so the calibration
    ## re-scopes that sweep without a second edit. [?]
  FLUID_STRENGTH_MIN* = 0.0
  FLUID_STRENGTH_MAX* = 1.0
    ## One is the whole fluid. Nothing above it: this multiplies the pass's
    ## entire velocity contribution, so a higher value amplifies pressure past
    ## the settings design C7's stability analysis covers. Stiffness is where to
    ## ask for a stiffer fluid, because its ceiling answers.
  FRICTION_MIN* = 0.0
  FRICTION_MAX* = 0.5
  RULE_TEMPERATURE_MIN* = 0.1
  RULE_TEMPERATURE_MAX* = 0.6
  TIME_SCALE_MIN* = 0.1
  TIME_SCALE_MAX* = 5.0
  PARTICLE_SIZE_MIN* = 1
  PARTICLE_SIZE_MAX* = 8
  TRAIL_LENGTH_MIN* = 0.0
  TRAIL_LENGTH_MAX* = 200.0
  GLOW_INTENSITY_MIN* = 0.0
  GLOW_INTENSITY_MAX* = 3.0
  VELOCITY_GLOW_SCALE_MIN* = 0.0
  VELOCITY_GLOW_SCALE_MAX* = 5.0
  MAX_VELOCITY_MIN* = 0.0
  MAX_VELOCITY_MAX* = 100.0
  REPULSION_END_MIN* = 0.1
  REPULSION_END_MAX* = 0.9
  ATTRACTION_PEAK_MIN* = 0.5
  ATTRACTION_PEAK_MAX* = 0.95
  EXP_REPULSION_ALPHA_MIN* = 1.0
  EXP_REPULSION_ALPHA_MAX* = 15.0
  EXP_ATTRACTION_BETA_MIN* = 1.0
  EXP_ATTRACTION_BETA_MAX* = 10.0
  GLOW_RADIUS_SCALE_MIN* = 0.5
  GLOW_RADIUS_SCALE_MAX* = 8.0
  GLOW_FALLOFF_MIN* = 2.0
  GLOW_FALLOFF_MAX* = 12.0
  GLOW_WARMTH_MIN* = 0.0
  GLOW_WARMTH_MAX* = 1.0
  PALETTE_SATURATION_MIN* = 0.0
  PALETTE_SATURATION_MAX* = 1.0
  PALETTE_LIGHTNESS_MIN* = 0.0
  PALETTE_LIGHTNESS_MAX* = 1.0
  SPH_RADIUS_FRACTION_MIN* = 0.1
    ## PROVISIONAL, and strictly positive for a reason that is not taste. A zero
    ## smoothing radius divides by zero in BOTH kernel normalizations —
    ## `4 / (PI * h^8)` and `30 / (PI * h^5)`, `src/sph_core.nim:62` and `:82`
    ## raise h to the 8th and 5th power in a denominator — so zero is a
    ## singularity here rather than a quiet setting, and the floor's job is to
    ## make it unreachable.
    ##
    ## The VALUE 0.1 is a working bound, not a measured one: it is the smallest
    ## kernel the slider offers, chosen to leave room below the default while
    ## staying clear of the singularity.
    ##
    ## TWO MEASUREMENTS BEAR ON RAISING IT, both from the stability sweep in
    ## tests/test_sph_core.nim, and neither forces a change yet.
    ##
    ## The stable stiffness ceiling falls LINEARLY with this fraction, not
    ## quadratically as design C7 predicted before the sweep existed
    ## (src/sph_core.nim's SPH_STABILITY_COEFFICIENT records why). So the floor
    ## still decides the worst-case ceiling, at 0.0025 * fraction *
    ## interactionRadius * substeps / dt. Every labelled stiffness notch has to
    ## sit below that worst case, and stiffness carries no notches today — the
    ## sweep in tests/test_param_descriptor.nim goes red on the first one that
    ## strands.
    ##
    ## Below a smoothing radius of about 2.5 px the fluid computes NOTHING: the
    ## shader floors every pair distance at MIN_DISTANCE_SQ (2 px), and both
    ## kernels return zero at and beyond their own radius, so a kernel narrower
    ## than that floor sees no neighbour at any separation. This fraction against
    ## the smallest interaction radius reaches 1 px, which is inside that inert
    ## region. Raising the floor to make it unreachable is a live option and a
    ## decision for whoever calibrates the fraction's default (C2.6). [?]
  SPH_RADIUS_FRACTION_MAX* = 1.0
    ## Exactly one, and the assertion below holds it there. One is the whole
    ## interaction radius, which is the kernel every fluid world ran before this
    ## fraction existed, so keeping it representable is what stops this change
    ## from silently altering a saved world (design C5).
    ##
    ## Nothing above it, and by construction rather than by clamp: the SPH
    ## neighbour sweep visits only the cell block around a particle and the
    ## cells are sized to the interaction radius (`src/grid.nim:61`), so a
    ## smoothing radius past that radius would silently DROP neighbours instead
    ## of gathering more. Capped at 1, that fluid cannot be expressed at all.
  SPH_REST_DENSITY_MIN* = 0.2
  SPH_REST_DENSITY_MAX* = 4.0
  SPH_STIFFNESS_MIN* = 1.0
  SPH_STIFFNESS_MAX* = 40.0
  SPH_VISCOSITY_MIN* = 0.0
  SPH_VISCOSITY_MAX* = 1.0
  SPH_SUBSTEPS_MIN* = 1
  SPH_SUBSTEPS_MAX* = SPH_MAX_SUBSTEPS
    ## The substep ceiling is sph_core's SPH_MAX_SUBSTEPS, not a bare literal —
    ## the executor loop and the slider bound stay one value.
  RD_FEED_MIN* = 0.010
  RD_FEED_MAX* = 0.085
    ## 0.085 clears Coral, whose feed coordinate is 0.082 (design D4); a 0.080
    ## ceiling strands it. Shipping a labelled notch outside its own slider's
    ## range would be the same defect the named regimes exist to fix — a
    ## position the panel names and the user cannot reach. The static assertion
    ## below ties the ceiling to the regime table, so the next coordinate past
    ## it fails the build rather than shipping an unreachable label.
  RD_KILL_MIN* = 0.040
  RD_KILL_MAX* = 0.075
  RD_DEPOSIT_MIN* = 0.0
    ## Zero is a meaningful setting: it decouples the particles from the field
    ## entirely, leaving the reaction-diffusion pattern to evolve on its own.
  RD_DEPOSIT_MAX* = 0.08
    ## Measured at the Pearson defaults, the field floods into a uniform bath
    ## from around 0.15 and diverges near 0.30. Those numbers come from
    ## feed=0.030 kill=0.062; at the slider's weakest corner (RD_FEED_MIN,
    ## RD_KILL_MIN) the (feed+kill)*B depletion opposing the deposit is about
    ## 1.8x weaker, so the ceiling has to sit well below the measured flood
    ## point. 0.08 leaves roughly 2x margin at that corner, which is what
    ## test_field_core's deposit-ceiling sweep verifies.
  RD_FIELD_FORCE_MIN* = 0.0
    ## Zero leaves particles blind to the field — a real setting, and the way
    ## to watch the pattern evolve without particles stirring it.
  RD_FIELD_FORCE_MAX* = RD_DEFAULT_FIELD_FORCE * 5.0
    ## Five times the default: violent, but still bounded by the integrator's
    ## own velocity clamp, and the setting every measurement in test_field_core's
    ## chemotactic collapse suite is taken at.
    ##
    ## Derived from the default rather than written down, so it inherits the
    ## division by FIELD_PATTERN_SHRINK — the gradient is per CELL and the
    ## impulse lands in WORLD units, so the pairing of the two is what a
    ## particle actually feels. RD_DEFAULT_FIELD_FORCE carries the derivation.
    ##
    ## Kept non-negative deliberately — field-force.wgsl notes that a negative
    ## scale pulls particles up-gradient, concentrating their deposits on
    ## inhibitor ridges into a positive-feedback loop nothing here has checked
    ## for stability.
  RD_REGIME_HIGH_FEED_DEPOSIT* = 0.040
    ## The deposit the high-feed regimes need, as a notch on the Deposit slider
    ## as well as a floor the regime buttons apply. RD_REGIMES' `minDeposit`
    ## reads it for the worms and coral rows, so the slider and the button
    ## cannot come to disagree about it.
    ##
    ## THE MINIMUM IS ALSO THE GENTLEST, which is the argument against ever
    ## "simplifying" this into one deposit applied to every regime. Measured
    ## against each regime's unforced attractor (tests/test_field_core.nim,
    ## "The Regime Deposit Floor Preserves The Regime"), Coral at this floor
    ## sits 0.10 from its own attractor while Coral at RD_DEPOSIT_MAX sits
    ## 0.42 from it — four times further. A larger deposit does not merely cost
    ## nothing extra, it actively distorts the regime it is meant to reveal.
    ## Raising this constant, or flattening the per-regime `minDeposit` into a
    ## single value, trades morphology fidelity for a simpler table.
  # Named reaction-diffusion regimes. Representative (feed, kill) points for
  # the classic Gray-Scott morphologies, transcribed from
  # docs/research/pearson-map.md's practitioner table (source [5] there).
  #
  # THEY ARE POINTS, NOT REGIONS. Pearson publishes only a graphical phase map
  # and no numeric boundaries, so labelling representative points is honest and
  # drawing borders would be fabrication. That is also why the sliders stay
  # continuous — a notch marks the map, it does not fence the road.
  #
  # They live here, beside RD_FEED_MIN/MAX and RD_KILL_MIN/MAX, because a
  # labelled value outside its own slider's range is an unreachable label. The
  # static assertions at the bottom of this file make that a build failure
  # rather than a shipped dead button.
  RD_REGIMES* = [
    (id: "waves",     label: "Waves",     feed: 0.014, kill: 0.054, minDeposit: 0.0),
    (id: "mitosis",   label: "Mitosis",   feed: 0.028, kill: 0.062, minDeposit: 0.0),
    (id: "labyrinth", label: "Labyrinth", feed: 0.029, kill: 0.057, minDeposit: 0.0),
    (id: "spots",     label: "Spots",     feed: 0.035, kill: 0.065, minDeposit: 0.0),
    (id: "worms",     label: "Worms",     feed: 0.078, kill: 0.061,
     minDeposit: RD_REGIME_HIGH_FEED_DEPOSIT),
    (id: "coral",     label: "Coral",     feed: 0.082, kill: 0.059,
     minDeposit: RD_REGIME_HIGH_FEED_DEPOSIT),
  ]
    ## `minDeposit` is the MEASURED floor for a regime to appear at all on the
    ## shipped path — no seed, colonies depositing through the splat kernel.
    ## Zero means the default deposit already ignites it.
    ##
    ## MEASURED (tests/test_field_core.nim, frame of ignition against deposit,
    ## 64x64 grid, Gaussian splat at RD_DEPOSIT_SPLAT_RADIUS, budget 60 frames):
    ##
    ##   regime     0.020   0.030   0.040   0.080
    ##   Waves          4       -       -       1
    ##   Mitosis        7       -       -       1
    ##   Labyrinth      6       -       -       1
    ##   Spots         11       -       -       1
    ##   Worms         NO      15       4       1
    ##   Coral         NO      21       4       1
    ##
    ## Worms and Coral do not ignite at RD_DEFAULT_DEPOSIT (0.02) at ALL — not
    ## slowly, not in 600 frames. Their high feed rate depletes a nucleus faster
    ## than the default deposit builds one. Selecting either regime without
    ## raising the deposit would leave the field blank, which is exactly the
    ## "no way to find the living parts except by accident" failure the named
    ## regimes exist to fix. 0.040 ignites both on frame 4, comfortably above
    ## the 0.030 boundary where they first ignite at all.
  CLIMATE_SPEED_MIN* = 0.05
    ## Slowest weather: one tour of the regimes every twenty minutes. Not zero —
    ## zero is what the drift toggle is for, and a speed slider that can also
    ## stop the drift would give the same state two controls.
  CLIMATE_SPEED_MAX* = 2.0
    ## Fastest weather: two tours a minute. Bounded by CLIMATE_MAX_STEP rather
    ## than by taste — tests/test_climate_core.nim sweeps the loop at this speed
    ## and fails if any single frame moves a slider further than that ceiling.
  # Camera (S6). The bounds camera_core.clampZoom is called with — they live
  # here rather than beside the camera maths because this file is the single
  # source of truth for every user-facing range, and camera_core takes them as
  # parameters precisely so that stays true.
  CAMERA_ZOOM_MIN* = 1.0
    ## The whole world once, framed to the window, and the widest view there
    ## is. The view therefore never spans more than one world, which is what
    ## lets the render path draw each particle at a single nearest toroidal
    ## image: one image covers the whole window, so no part of the frame asks
    ## for a second copy of the world.
  CAMERA_ZOOM_MAX* = 8.0
    ## Close enough that a single particle and its immediate neighbours fill the
    ## view — the scale at which the attraction matrix's behaviour is legible as
    ## individual motion rather than as bulk texture.
  # Camera zoom notches. The camera's own descriptor belongs to the camera
  # work; these are its labelled positions, kept beside CAMERA_ZOOM_MIN/MAX
  # above so the same range assertions cover them.
  CAMERA_ZOOM_NOTCH_WORLD* = 1.0
    ## One world to one screen: the whole world framed to the window. A literal
    ## rather than CAMERA_ZOOM_MIN — zoom 1 means this framing by definition,
    ## so the notch must stay put even if the floor ever moves.
  CAMERA_ZOOM_NOTCH_CREATURE* = CAMERA_ZOOM_MAX
    ## Close enough to watch one particle, and the near end of the zoom range.
  # Per-species field chemistry. Not sliders on a single CONFIG field — one
  # value per species, edited in the chemistry grid — but clamped through the
  # same range authority as everything else.
  SECRETION_MIN* = -1.0
    ## Full erosion: the species subtracts inhibitor wherever it sits. The
    ## magnitude matches the positive bound because both directions carry the
    ## same risk profile — the deposit's total is conserved by the splat
    ## kernel's normalization either way, and RD_DEPOSIT_MAX already bounds
    ## the amplitude both signs scale.
  SECRETION_MAX* = 1.0
    ## Full construction, and the default: a species deposits exactly the
    ## Deposit slider's value. Every measurement behind RD_DEPOSIT_MAX and
    ## RD_DEPOSIT_SPLAT_RADIUS is taken here, so the ceiling is the value
    ## those measurements describe rather than a multiple of it.
  TROPISM_MIN* = -1.0
    ## Full DOWN-gradient authority. Negative chemosensitivity is stabilizing:
    ## particles pushed away from their own deposits spread across the pattern,
    ## and no feedback loop closes. There is no measured hazard to bound.
  TROPISM_MAX* = 0.5
    ## Half authority UP-gradient, per design D5. Climbing a self-deposited
    ## gradient closes a positive feedback loop — deposit raises the peak, the
    ## peak steepens the gradient, the gradient pulls harder — which is the
    ## Keller-Segel collapse mechanism (chi*M > 8*pi in 2D,
    ## docs/research/chemotaxis-stability.md). The bound is asymmetric by
    ## design, not by oversight.
    ##
    ## MEASURED COLLAPSE POINT: tropism 4.0 (8x this bound), at deposit 0.8
    ## (10x RD_DEPOSIT_MAX) and fieldForceScale 150. There the field diverges
    ## to infinity and every particle ends in a single field cell. At the same
    ## deposit and field force, this bound stays finite (maxB 0.886), so the
    ## collapse point is bracketed in (1x, 8x] of 0.5 under those conditions.
    ## tests/test_field_core.nim's "Chemotactic Collapse Bound" suite holds the
    ## measurement and the bracket.
    ##
    ## THE COLLAPSE IS CHEMOTACTIC, not the deposit flooding on its own. The
    ## control settles it: the same 0.8 deposit laid down by a FROZEN
    ## population stays finite and saturates at maxB 0.856. Only the
    ## up-gradient motion, concentrating that deposit into one place, diverges
    ## the field. Concentration is the variable, not amplitude.
    ##
    ## WHAT BOUNDS THE REACHABLE RANGE IS RD_DEPOSIT_MAX, NOT THIS CONSTANT.
    ## Inside the deposit range the slider offers, no tropism collapses the
    ## field at all — 1024x this bound stays finite and bounded (maxB 0.803,
    ## peak cell 0.102 of the population). Collapse lives in the PRODUCT of
    ## tropism and deposit, and the deposit ceiling is already far enough below
    ## it that tropism has a thousandfold margin. This bound is the second line
    ## of defence, and it is worth keeping precisely because the two multiply:
    ## anything that later raises RD_DEPOSIT_MAX spends this margin too.
    ##
    ## Gray-Scott's (feed+kill)*B sink is what saturates the field against
    ## deposit AMPLITUDE — 1x and 10x the ceiling land within 0.1 of each other
    ## when the deposit is uniform. It does not saturate it against
    ## CONCENTRATION: raising the rate per cell lets the autocatalytic A*B^2
    ## term outrun the sink. Do not reason from "Gray-Scott bounds its own
    ## inhibitor" to "no collapse is possible"; the measurement above is what
    ## that reasoning misses.
    ##
    ## If the finite half of the bracket ever goes red, halve this constant and
    ## record the failing value here. Never widen the test's ceiling instead.
  # HDR bloom + colour grade (S9). bloomEnabled is a toggle, not a slider, so
  # it has no range here. Temperature is signed (warm/cool), centred on 0.
  BLOOM_INTENSITY_MIN* = 0.0
  BLOOM_INTENSITY_MAX* = 3.0
  EXPOSURE_MIN* = 0.2
  EXPOSURE_MAX* = 3.0
  SATURATION_MIN* = 0.0
  SATURATION_MAX* = 2.0
  CONTRAST_MIN* = 0.5
  CONTRAST_MAX* = 2.0
  TEMPERATURE_MIN* = -1.0
  TEMPERATURE_MAX* = 1.0
  # Reaction-diffusion field visualization (S10). colormapIndex is an integer
  # ramp selector (a button group, not a slider, but preset.nim clamps it);
  # fieldOpacity is a slider. Both ranges come from colormap_core, the field
  # colormap authority.
  COLORMAP_INDEX_MIN* = 0
  COLORMAP_INDEX_MAX* = COLORMAP_COUNT - 1
  FIELD_OPACITY_RANGE_MIN* = FIELD_OPACITY_MIN
  FIELD_OPACITY_RANGE_MAX* = FIELD_OPACITY_MAX

static:
  # Every range must be non-empty, or clamping inverts.
  doAssert PARTICLE_COUNT_MIN < PARTICLE_COUNT_MAX
  doAssert SPECIES_COUNT_MIN < SPECIES_COUNT_MAX
  doAssert PARTICLE_SIZE_MIN < PARTICLE_SIZE_MAX
  doAssert GLOW_RADIUS_SCALE_MIN < GLOW_RADIUS_SCALE_MAX
  doAssert GLOW_FALLOFF_MIN < GLOW_FALLOFF_MAX
  doAssert GLOW_WARMTH_MIN < GLOW_WARMTH_MAX
  doAssert SPH_REST_DENSITY_MIN < SPH_REST_DENSITY_MAX
  doAssert SPH_STIFFNESS_MIN < SPH_STIFFNESS_MAX
  doAssert FORCE_STRENGTH_MIN < FORCE_STRENGTH_MAX
  doAssert FLUID_STRENGTH_MIN < FLUID_STRENGTH_MAX
  doAssert CROWDING_STRENGTH_MIN < CROWDING_STRENGTH_MAX
  # Crowding shapes the force law rather than gating a pass, so it is absent
  # from the coupling loop below. Its floor still has to be zero, and for its
  # own reason: zero reproduces today's force exactly, and a floor above it
  # would make the pre-crowding world unreachable.
  doAssert CROWDING_STRENGTH_MIN == 0.0,
    "crowding strength zero is today's force law and must stay reachable"
  # Every coupling strength reaches zero (design D13). One loop rather than an
  # assertion each, so a fifth coupling with a nonzero floor fails here.
  for strengthFloor in [FORCE_STRENGTH_MIN, FLUID_STRENGTH_MIN,
      RD_DEPOSIT_MIN, RD_FIELD_FORCE_MIN]:
    doAssert strengthFloor == 0.0,
      "a coupling strength's range excludes zero; design D13 requires that " &
      "every coupling can be turned off through its own slider"
  doAssert SPH_VISCOSITY_MIN < SPH_VISCOSITY_MAX
  doAssert SPH_SUBSTEPS_MIN < SPH_SUBSTEPS_MAX
  doAssert SPH_RADIUS_FRACTION_MIN < SPH_RADIUS_FRACTION_MAX
  # The radius fraction shapes the fluid rather than gating a pass, so it is
  # absent from the coupling loop above — and its floor has to clear zero for
  # the opposite reason crowding's has to reach it: zero divides by zero in
  # both kernel normalizations instead of naming a quieter world.
  doAssert SPH_RADIUS_FRACTION_MIN > 0.0,
    "a zero SPH smoothing radius divides by zero in both kernel " &
    "normalizations (src/sph_core.nim:62 and :82)"
  # At exactly 1 the smoothing radius can never outrun the neighbour sweep,
  # whose cells are sized to the interaction radius. Raising this ceiling would
  # make dropped neighbours expressible, which is the constraint design C5
  # chose to make unrepresentable rather than to clamp.
  doAssert SPH_RADIUS_FRACTION_MAX == 1.0,
    "the SPH smoothing radius must stay at or below the interaction radius " &
    "the neighbour sweep's cells are sized to"
  doAssert RD_FEED_MIN < RD_FEED_MAX
  doAssert RD_KILL_MIN < RD_KILL_MAX
  doAssert RD_DEPOSIT_MIN < RD_DEPOSIT_MAX
  doAssert RD_FIELD_FORCE_MIN < RD_FIELD_FORCE_MAX
  doAssert RD_DEFAULT_DEPOSIT >= RD_DEPOSIT_MIN and
    RD_DEFAULT_DEPOSIT <= RD_DEPOSIT_MAX
  doAssert RD_DEFAULT_FIELD_FORCE >= RD_FIELD_FORCE_MIN and
    RD_DEFAULT_FIELD_FORCE <= RD_FIELD_FORCE_MAX
  # field_core's Pearson defaults must themselves lie inside the slider range
  # they are the default value of — a future default change that escapes the
  # range fails the build here rather than shipping an out-of-bounds slider.
  doAssert RD_DEFAULT_FEED >= RD_FEED_MIN and RD_DEFAULT_FEED <= RD_FEED_MAX
  doAssert RD_DEFAULT_KILL >= RD_KILL_MIN and RD_DEFAULT_KILL <= RD_KILL_MAX
  # Every named regime must be a position both its sliders can reach. A notch
  # the panel labels and the slider cannot land on is an unreachable label —
  # the exact defect the named regimes exist to remove — so this is a build
  # failure rather than a test. Narrowing RD_FEED_MAX below 0.082 strands
  # Coral and fails here.
  for regime in RD_REGIMES:
    doAssert regime.feed >= RD_FEED_MIN and regime.feed <= RD_FEED_MAX,
      "regime " & regime.id & " has a feed outside the feed slider's range"
    doAssert regime.kill >= RD_KILL_MIN and regime.kill <= RD_KILL_MAX,
      "regime " & regime.id & " has a kill outside the kill slider's range"
    doAssert regime.minDeposit >= RD_DEPOSIT_MIN and
      regime.minDeposit <= RD_DEPOSIT_MAX,
      "regime " & regime.id & " needs a deposit outside the deposit range"
  doAssert RD_REGIME_HIGH_FEED_DEPOSIT >= RD_DEPOSIT_MIN and
    RD_REGIME_HIGH_FEED_DEPOSIT <= RD_DEPOSIT_MAX
  # The camera zoom notches are positions on the camera slider, so the same
  # reachability rule covers them.
  for zoomNotch in [CAMERA_ZOOM_NOTCH_WORLD, CAMERA_ZOOM_NOTCH_CREATURE]:
    doAssert zoomNotch >= CAMERA_ZOOM_MIN and zoomNotch <= CAMERA_ZOOM_MAX
  # Species chemistry: non-empty ranges, and field_core's defaults inside the
  # range they are the default of — the same guard as the RD pair above. The
  # tropism range is asymmetric on purpose (design D5); the assertion below
  # states that as a checked property so a future "tidying" to [-1, +1] fails
  # here rather than shipping unmeasured up-gradient authority.
  doAssert SECRETION_MIN < SECRETION_MAX
  doAssert TROPISM_MIN < TROPISM_MAX
  doAssert TROPISM_MAX < -TROPISM_MIN,
    "tropism is bounded asymmetrically: up-gradient authority must stay " &
    "below down-gradient authority (design D5)"
  doAssert RD_DEFAULT_SECRETION >= SECRETION_MIN and
    RD_DEFAULT_SECRETION <= SECRETION_MAX
  doAssert RD_DEFAULT_TROPISM >= TROPISM_MIN and
    RD_DEFAULT_TROPISM <= TROPISM_MAX
  # Camera zoom is a non-empty range straddling 1.0, and it must: 1.0 is the
  # view that frames the whole world to the window, so a range excluding it
  # would make the default view unreachable.
  doAssert CAMERA_ZOOM_MIN < CAMERA_ZOOM_MAX
  doAssert CAMERA_ZOOM_MIN <= 1.0 and CAMERA_ZOOM_MAX >= 1.0,
    "zoom range must contain 1.0, the whole world framed to the window"
  # Bloom/grade ranges are non-empty and their bloom_core defaults sit inside
  # the slider range they are the default of — the same guard as the RD pair,
  # so a future default change that escapes its range fails the build here.
  doAssert BLOOM_INTENSITY_MIN < BLOOM_INTENSITY_MAX
  doAssert EXPOSURE_MIN < EXPOSURE_MAX
  doAssert SATURATION_MIN < SATURATION_MAX
  doAssert CONTRAST_MIN < CONTRAST_MAX
  doAssert TEMPERATURE_MIN < TEMPERATURE_MAX
  doAssert BLOOM_DEFAULT_INTENSITY >= BLOOM_INTENSITY_MIN and
    BLOOM_DEFAULT_INTENSITY <= BLOOM_INTENSITY_MAX
  doAssert BLOOM_DEFAULT_EXPOSURE >= EXPOSURE_MIN and
    BLOOM_DEFAULT_EXPOSURE <= EXPOSURE_MAX
  doAssert BLOOM_DEFAULT_SATURATION >= SATURATION_MIN and
    BLOOM_DEFAULT_SATURATION <= SATURATION_MAX
  doAssert BLOOM_DEFAULT_CONTRAST >= CONTRAST_MIN and
    BLOOM_DEFAULT_CONTRAST <= CONTRAST_MAX
  doAssert BLOOM_DEFAULT_TEMPERATURE >= TEMPERATURE_MIN and
    BLOOM_DEFAULT_TEMPERATURE <= TEMPERATURE_MAX
  # Field-visualization ranges are non-empty and colormap_core's defaults sit
  # inside them — the same default-in-range guard as the bloom/RD pairs.
  doAssert COLORMAP_INDEX_MIN < COLORMAP_INDEX_MAX
  doAssert FIELD_OPACITY_RANGE_MIN < FIELD_OPACITY_RANGE_MAX
  doAssert COLORMAP_DEFAULT_INDEX >= COLORMAP_INDEX_MIN and
    COLORMAP_DEFAULT_INDEX <= COLORMAP_INDEX_MAX
  doAssert FIELD_OPACITY_DEFAULT >= FIELD_OPACITY_RANGE_MIN and
    FIELD_OPACITY_DEFAULT <= FIELD_OPACITY_RANGE_MAX
