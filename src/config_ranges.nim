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
# cannot silently diverge from what the slider offers.
#
# ==============================================================================

from std/math import ceil, sqrt
import memory_layout
import sph_core
import field_core
import bloom_core
import body_core
import long_range_core
from physics_core import FRAME_DT_REFERENCE, VELOCITY_FIXED_POINT_SCALE,
  MOUSE_FORCE_PEAK, BLAST_FORCE_PEAK

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
    ## Zero is an ordinary value of a coupling strength.
    ## `fMul` scales BOTH force zones (`src/physics_core.nim`), so zero
    ## removes short-range repulsion too and a pair below the onset passes
    ## through. The world pressure is not scaled by it: a crowd past the onset
    ## still pushes itself apart here.
  FORCE_STRENGTH_MAX* = 5.0
  CROWDING_STRENGTH_MIN* = 0.0
    ## Zero is today's force law exactly — `1 / (1 + 0 * log(1 + density))` is 1
    ## at every density — so it must stay reachable, and any regression the
    ## crowding term introduces bisects to this one number. It is also the
    ## shipped default: crowding shapes how attraction thins in a crowd, and
    ## the bound on compression is the world pressure's, at every crowding
    ## strength including this one.
  CROWDING_STRENGTH_MAX* = 2.0
    ## PROVISIONAL, pending the calibration. That task measures the strength at
    ## which ordinary colonies visibly soften and sets this ceiling above it,
    ## with the conditions recorded here, per the measured-bound rule. Until
    ## then this is a working bound, not a measured one. What it bounds is
    ## texture, not collapse: the world pressure holds compression at every
    ## crowding strength.
  FLUID_STRENGTH_MIN* = 0.0
  FLUID_STRENGTH_MAX* = 1.0
    ## One is the whole fluid. Nothing above it: this multiplies the pass's
    ## entire velocity contribution, so a higher value amplifies pressure past
    ## the settings the stability analysis covers. Stiffness is where to
    ## ask for a stiffer fluid, because its ceiling answers.
  LONG_RANGE_STRENGTH_MIN* = 0.0
    ## Zero is an ordinary value of a coupling strength, and the shipped
    ## default: a build carrying the long-range mesh runs the same world as one
    ## without it until this slider moves.
  LONG_RANGE_STRENGTH_MAX* = 1.0
    ## PROVISIONAL, pending an in-app calibration. This is a working bound, not
    ## a measured one: nothing has yet watched the coupling act. The
    ## calibration must record two strengths and set this ceiling above the
    ## second — the strength at which a settled population visibly gathers
    ## toward the world's densest region within a few seconds, and the strength
    ## at which the long-range term overwhelms the species force at the
    ## interaction radius. CROWDING_STRENGTH_MAX above is the worked example of
    ## the same marking. [?]
  LONG_RANGE_REACH_MIN* = 60.0
    ## The screening length lambda, in world units, and STRICTLY POSITIVE for
    ## two reasons that are not taste. The uniform carries 1/lambda^2
    ## (long_range_core.lrInverseReachSq), so a reach of zero has no finite
    ## representation at all. And a reach below the grid's cell size — 7.5 by
    ## 8.4375 units at the shipped size — names a force the softening has
    ## already removed, so the floor sits above a few cells rather than at the
    ## smallest number the slider could hold.
    ##
    ## Below the neighbour sweep's maximum reach of 150, deliberately: a floor
    ## at 150 would make the coupling long-range-only by construction and cost
    ## the short end of this control's travel.
  LONG_RANGE_REACH_MAX* = 4000.0
    ## Above the world's width of 3840, so the unscreened 2D limit — a reach the
    ## world cannot exhaust — is a slider position rather than an asymptote.
  LR_GRID_SIZES* = [
    (w: 256, h: 128),
    (w: 512, h: 256),
  ]
    ## The live sizes the mesh's grid may take, as a selector rather than a
    ## numeric range: a size that is not a power of two, or larger than the
    ## allocation ceiling, is unrepresentable here rather than clamped. The
    ## assertions at the bottom of this file hold every declared size to the
    ## ceiling in memory_layout and to the line length the transform's
    ## workgroup array is compiled for.
    ##
    ## Both aspects are 2:1, which is what keeps the cell aspect — and so the
    ## anisotropy the kernel's wavenumber mapping answers to — the same 1.125
    ## at every position.
  LONG_RANGE_GRID_INDEX_MIN* = 0
  LONG_RANGE_GRID_INDEX_MAX* = LR_GRID_SIZES.len - 1
    ## Derived from the table's length, so a declared size added or removed
    ## moves the selector's ceiling with it and no second number can disagree.
  LONG_RANGE_GRID_INDEX_DEFAULT* = 1
    ## MEASURED: 512 x 256, the second declared position. One batched round trip
    ## — forward row, forward column, per-bin multiply with the 12 x 12
    ## asymmetric species mix, inverse column, inverse row — costs 0.417 to
    ## 0.450 ms of GPU time at 512 x 256 x 12 against the 1.0 ms this coupling
    ## allots itself out of the settled 128k headroom of 3.75 ms
    ## (docs/perf-report.md). Conditions: Apple M5 Max, macOS 26.5.2, Chromium
    ## 152 headless on ANGLE/Metal, with roughly three cores busy with unrelated
    ## work, so the figure is an upper bound; the span is the observed min-max
    ## over the last four samples of a 15-second window.
    ##
    ## THE FIGURE COVERS THE SOLVE ALONE. The deposit and gradient-force passes
    ## are excluded from it and are the two per-particle passes in the chain,
    ## leaving about 0.55 ms of the allotment unmeasured. If the first in-app
    ## capture of the long-range profiler slot overruns, index 0 is the
    ## declared 256 x 128 position at about a fifth of the solve's cost, and
    ## moving this constant is the whole change.
  FRICTION_MIN* = 0.0
  FRICTION_MAX* = 0.5
  MATRIX_MIN_VALUE* = -0.330
  MATRIX_MAX_VALUE* = 0.330
    ## Provisional band, in-app judgment pending like the crowding ceiling
    ## above; tune it together with crowding attenuation — both shape
    ## same-species pile-up. [?]
  MATRIX_VALUE_STEP* = 0.001
  MATRIX_VALUE_PRECISION* = 3
  RULE_WILDNESS_MIN* = 0.1
  RULE_WILDNESS_MAX* = 0.6
    ## Sigma for the matrix rule sampler, as a FRACTION of MATRIX_MAX_VALUE
    ## (matrix_state.sampleRuleValue applies the scale), so this range keeps
    ## its meaning across any matrix re-range.
  FORCE_WEATHER_WAYPOINTS* = [
    (strength: 0.8, radius: 45.0, friction: 0.04),
    (strength: 1.6, radius: 60.0, friction: 0.08),
    (strength: 2.4, radius: 35.0, friction: 0.16),
    (strength: 1.2, radius: 80.0, friction: 0.06),
    (strength: 0.5, radius: 55.0, friction: 0.02),
  ]
    ## The closed tour the force weather walks, beside the three ranges its
    ## coordinates have to satisfy. The static assertions at the bottom of this
    ## file reject a coordinate outside its own slider, for the same reason they
    ## reject an unreachable regime notch.
    ##
    ## PROVISIONAL, chosen by construction rather than by watching.
    ## Read them as a spread over the force parameters
    ## that keeps the tour inside every range with room to spare, not as settled
    ## configurations: nothing here has been watched settle. [?]
    ##
    ## The construction. Five points, each
    ## moving at least two axes away from its neighbours so no segment reads as
    ## a single slider drifting: loose and drifty, tighter colonies, a
    ## short-range damped state, long-range slow structures, and a near-free
    ## wander. Every coordinate sits well inside its range, so narrowing a range
    ## for an unrelated reason does not immediately strand a waypoint.
    ##
    ## WHY THESE THREE AXES.
    ## `ruleWildness` is excluded and that exclusion is a measurement, not a
    ## preference: it feeds `sampleRuleValue` alone (`src/web_api.nim`), which
    ## runs when the rules are re-sampled, so touring it moves a slider and
    ## changes nothing a viewer can see until something else randomises the
    ## matrix. `interactionRadius` is included despite being the expensive one —
    ## it sets the spatial hash's cell size (`src/grid.nim`) — because
    ## `computeGridDimensions` already recomputes that every physics frame, so
    ## the tour walks exactly the path a user dragging that slider walks.
    ##
    ## `radius` is a float here and `interactionRadius` is an int. The tour
    ## interpolates in floats and the write path rounds, so the guarantees below
    ## are stated of the float path; the int lands within one unit of 140.
  TIME_SCALE_MIN* = 0.1
  TIME_SCALE_MAX* = 5.0
  SUBSTEPS_MAX* = 3
    ## The most physics substeps one rendered frame may run. Each extra substep
    ## re-encodes every per-substep pass: at 128 000 particles that measured
    ## 1.56 ms of grid plus physics over a 30 s window and 7.95 ms over a 150 s
    ## one, both lower bounds on the settled cost (docs/perf-report.md).
  FF_STABLE* = 12.0
    ## The largest frame factor one substep carries before the count grows.
    ## PROVISIONAL, and the frame-factor path is open: G1.5 at 128 000
    ## particles, K 540, shipped friction, bisected it to 1, every ff from 2 to
    ## 30 warmer than ff 1 (scratchpad/core-force-interface/g1-stiffness__21-09-26-2024.md).
    ## Friction acts once per step, the condition that run was measured under.
  PARTICLE_SIZE_MIN* = 1
  PARTICLE_SIZE_MAX* = 8
  PARTICLE_VISIBLE_RADIUS_FLOOR_PX* = 0.5
    ## Floor on the COMPOSED on-screen radius (camera_core.visibleRadiusPx),
    ## never on any single factor: half a pixel of radius is one pixel of
    ## diameter, the smallest footprint the rasterizer reliably lights.
    ## tests/test_camera_core.nim holds the worst reachable corner — minimum
    ## size, the density multiplier's floor, minimum zoom — above it; a
    ## re-range that dips the corner goes red there, and shipping a clamp at
    ## the end of the shader chain is the remedy for that red.
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
    ## `4 / (PI * h^8)` and `30 / (PI * h^5)` (`src/sph_core.nim`)
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
    ## quadratically as predicted before the sweep existed
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
    ## decision for whoever calibrates the fraction's default. [?]
  SPH_RADIUS_FRACTION_MAX* = 1.0
    ## Exactly one, and the assertion below holds it there. One is the whole
    ## interaction radius, which is the kernel every fluid world ran before this
    ## fraction existed, so keeping it representable is what stops this change
    ## from silently altering a saved world.
    ##
    ## Nothing above it, and by construction rather than by clamp: the SPH
    ## neighbour sweep visits only the cell block around a particle and the
    ## cells are sized to the interaction radius (`src/grid.nim`), so a
    ## smoothing radius past that radius would silently DROP neighbours instead
    ## of gathering more. Capped at 1, that fluid cannot be expressed at all.
  SPH_REST_DENSITY_MIN* = 0.2
  SPH_REST_DENSITY_MAX* = 4.0
  SPH_STIFFNESS_MIN* = 1.0
  SPH_STIFFNESS_MAX* = 40.0
  SPH_VISCOSITY_MIN* = 0.0
  SPH_VISCOSITY_MAX* = 1.0
  RD_FEED_MIN* = 0.010
  RD_FEED_MAX* = 0.085
    ## 0.085 clears Coral, whose feed coordinate is 0.082; a 0.080
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
  FORCE_WEATHER_SPEED_MIN* = CLIMATE_SPEED_MIN
  FORCE_WEATHER_SPEED_MAX* = CLIMATE_SPEED_MAX
    ## Tours per minute, the same unit and the same offerable band the climate
    ## speed carries, so these name that one fact rather than restating it. They
    ## carry their own names because the two weathers run independently, so a
    ## measured reason to widen one and not the other lands in one edit.
    ## The default speed lives in climate_core beside the climate's, where every
    ## tour default lives.
  # Camera. The bounds camera_core.clampZoom is called with — they live
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
  # Camera drift. View widths the camera travels per minute while the drift
  # toggle is on.
  CAMERA_DRIFT_SPEED_MIN* = 0.05
    ## One view width every twenty minutes, about 70 px a minute in the
    ## 1400x900 window main.nim opens: motion found by leaving the room and
    ## coming back, never by watching.
  CAMERA_DRIFT_SPEED_MAX* = 4.0
    ## One view width every fifteen seconds, about 93 px a second. BOUNDED BY
    ## LEGIBILITY. The mechanical ceiling sits far above: the fade pass
    ## reprojects the trail between consecutive cameras and breaks down only
    ## where consecutive frames stop overlapping, near 36 view widths a minute.
  CAMERA_DRIFT_SPEED_NOTCH_SCREEN* = 1.0
    ## One view width a minute, the unit's own definition.
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
    ## Half authority UP-gradient. Climbing a self-deposited
    ## gradient closes a positive feedback loop — deposit raises the peak, the
    ## peak steepens the gradient, the gradient pulls harder — which is the
    ## Keller-Segel collapse mechanism (chi*M > 8*pi in 2D,
    ## docs/research/chemotaxis-stability.md). The bound is asymmetric by
    ## design, not by oversight.
    ##
    ## MEASURED COLLAPSE BRACKET at pattern scale 1, fieldForceScale 37.5,
    ## harness at 1.875 world units per cell: no tropism up to 1024x this bound
    ## diverges the field at 5x RD_DEPOSIT_MAX, and 2x this bound diverges it
    ## at 7.5x, so the deposit bracket is (5x, 7.5x]. tests/test_field_core.nim's
    ## "Chemotactic Collapse Bound" suite holds the measurement and the bracket.
    ##
    ## THE COLLAPSE IS CHEMOTACTIC, not the deposit flooding on its own. The
    ## control settles it: the same 7.5x deposit laid down by a FROZEN
    ## population stays finite and saturates at maxB 0.876. Only the
    ## up-gradient motion, concentrating that deposit into one place, diverges
    ## the field. Concentration is the variable, not amplitude.
    ##
    ## WHAT BOUNDS THE REACHABLE RANGE IS RD_DEPOSIT_MAX, NOT THIS CONSTANT.
    ## Inside the deposit range the slider offers, no tropism collapses the
    ## field at all — 1024x this bound stays finite and bounded (maxB 0.696,
    ## peak cell 0.023 of the population). Collapse lives in the PRODUCT of
    ## tropism and deposit, and the deposit ceiling is already far enough below
    ## it that tropism has a thousandfold margin. This bound is the second line
    ## of defence, and it is worth keeping precisely because the two multiply:
    ## anything that later raises RD_DEPOSIT_MAX spends this margin too.
    ##
    ## Gray-Scott's (feed+kill)*B sink is what saturates the field against
    ## deposit AMPLITUDE — a uniform deposit at 7.5x and at 30x the ceiling
    ## peaks at 0.876 and 1.008. It does not saturate it against
    ## CONCENTRATION: raising the rate per cell lets the autocatalytic A*B^2
    ## term outrun the sink. Do not reason from "Gray-Scott bounds its own
    ## inhibitor" to "no collapse is possible"; the measurement above is what
    ## that reasoning misses.
    ##
    ## If the finite half of the bracket ever goes red, halve this constant and
    ## record the failing value here. Never widen the test's ceiling instead.
  TROPISM_COLLAPSE_BRACKETS* = [
    (scale: 1.0, safe: 5.0, collapse: 7.5, witness: 2.0),
    (scale: 0.5, safe: 3.0, collapse: 5.0, witness: 2.0),
    (scale: 0.25, safe: 7.5, collapse: 10.0, witness: 2.0)]
    ## The collapse bracket at each pattern-scale step, deposits in multiples
    ## of RD_DEPOSIT_MAX and the witness in multiples of this bound. MEASURED
    ## (64x64 harness, 1.875 world units per cell, 120 frames, tropism 0 to
    ## 1024x, fieldForceScale 37.5 * sqrt(scale)): no sampled tropism diverges
    ## at `safe`, the witness diverges at `collapse` and a frozen population
    ## does not. The lower edge sits at 3x or more at every step.
  # Parametric bodies. Every bound below is body_core's, imported rather than
  # restated: the overflow assertion on the per-body accumulator and the
  # stability sweep that warrants the rigid step's constants both read these,
  # and body_core sits upstream of this file, so a second copy here would be a
  # bound the assertion could not see.
  BODIES_STRENGTH_MIN* = 0.0
    ## Zero is an ordinary value of a coupling strength: at exactly zero the
    ## frame dispatches neither bodies pass.
  BODIES_STRENGTH_MAX* = body_core.BODY_STRENGTH_CEILING
  BODIES_DEFAULT_STRENGTH* = 1.0
    ## The coupling acts out of the box, and nothing happens until a body
    ## exists — the ignition rate below is what decides whether the world makes
    ## one unasked, and it ships at zero.
  BODY_RADIUS_MIN* = body_core.BODY_RADIUS_FLOOR
  BODY_RADIUS_MAX* = body_core.BODY_RADIUS_CEILING
  BODY_DEFAULT_RADIUS* = 240.0
  BODY_BAND_MIN* = 25.0
    ## The narrowest band a body may hold at. Strictly positive because the band
    ## divides the distance in the force law, and it is the value every saved
    ## band was clamped against. Nothing derives it: a particle stays inside a
    ## band this narrow because sim_registry.substepPlan counts the substeps its
    ## travel needs and clamps the effective Max Velocity past the ceiling.
  BODY_BAND_MAX* = body_core.BODY_BAND_CEILING
  BODY_DEFAULT_BAND* = 120.0
  BODY_PROXIMITY_MIN* = -body_core.BODY_FORCE_CEILING
  BODY_PROXIMITY_MAX* = body_core.BODY_FORCE_CEILING
    ## Signed and symmetric: positive pulls particles onto the surface,
    ## negative pushes them off it, and zero is an ordinary value of one
    ## quantity rather than a second parameter.
  BODY_DEFAULT_PROXIMITY* = 6.0
  BODY_ENCLOSURE_MIN* = -body_core.BODY_FORCE_CEILING
  BODY_ENCLOSURE_MAX* = body_core.BODY_FORCE_CEILING
    ## Signed on the same terms: positive holds particles in, negative keeps
    ## them out.
  BODY_DEFAULT_ENCLOSURE* = 0.0
  BODY_LIFETIME_MIN* = body_core.BODY_LIFETIME_FLOOR
  BODY_LIFETIME_MAX* = body_core.BODY_LIFETIME_CEILING
  BODY_DEFAULT_LIFETIME* = 8.0
  BODY_IGNITION_RATE_MIN* = 0.0
    ## Zero means the world ignites none, and that is the shipped default: a
    ## world does not make shapes nobody asked for.
  BODY_IGNITION_RATE_MAX* = body_core.BODY_IGNITION_RATE_CEILING
  BODY_DEFAULT_IGNITION_RATE* = 0.0

  # The three below back NO descriptor and draw no slider. They are a body's
  # character rather than the world's disposition — fixed when a body ignites,
  # not adjusted while it lives — so they travel on the ignition call and are
  # clamped against these bounds inside it, once, for every source at once. A
  # number without a slider is still a number this file owns.
  BODY_ANISOTROPY_MIN* = body_core.BODY_ANISOTROPY_FLOOR
  BODY_ANISOTROPY_MAX* = body_core.BODY_ANISOTROPY_CEILING
  BODY_ENVELOPE_SKEW_MIN* = -body_core.BODY_SKEW_EXTENT
  BODY_ENVELOPE_SKEW_MAX* = body_core.BODY_SKEW_EXTENT
  BODY_SUSTAIN_MIN* = body_core.BODY_SUSTAIN_FLOOR
  BODY_SUSTAIN_MAX* = body_core.BODY_SUSTAIN_CEILING
  # HDR bloom + colour grade. bloomEnabled is a toggle, not a slider, so
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

# THE PATTERN-SCALE BAND. Gate G3 measured every scale-dependent field constant
# at these steps (scratchpad/core-force-interface/g3__21-09-26-2010.md).
const
  RD_PATTERN_SCALE_MAX* = 1.0
    ## The base diffusion rates; above 1 the activator crosses its Euler line.
  RD_PATTERN_SCALE_MIN* = 0.25
    ## G3's floor: no Coral row restores Coral at 0.22 or 0.2 anywhere in the
    ## feed and kill ranges. The measured diameter here is 4.47 cells.
  RD_PATTERN_SCALE_DEFAULT* = RD_PATTERN_SCALE_MIN
  RD_PATTERN_SCALE_STEPS* = [RD_PATTERN_SCALE_MAX, 0.5, RD_PATTERN_SCALE_MIN]
    ## Descending, ceiling first and floor last.
  RD_REGIME_SCALE_ROWS* = [
    (id: "coral", scale: 0.5, feed: 0.080, kill: 0.059,
     minDeposit: RD_REGIME_HIGH_FEED_DEPOSIT),
    (id: "coral", scale: 0.25, feed: 0.0825, kill: 0.058,
     minDeposit: RD_REGIME_HIGH_FEED_DEPOSIT),
    (id: "worms", scale: 0.25, feed: 0.080, kill: 0.061,
     minDeposit: RD_REGIME_HIGH_FEED_DEPOSIT),
  ]
    ## Rows for the steps where a regime's scale-1 row drifts. MEASURED (64x64
    ## harness, 150 frames, distance to own attractor / half the separation):
    ## Coral 0.082 / 0.245 at 0.5, 0.202 / 0.348 at 0.25; Worms 0.197 / 0.559
    ## at 0.25, where its scale-1 row ignites at the default deposit.
  RD_SCENT_STEPPED_IMPULSE* = [
    (scale: 1.0, ratio: 1.0), (scale: 0.5, ratio: 0.983),
    (scale: 0.25, ratio: 0.927)]
    ## The scent's strength-1 impulse under a gain of sqrt(scale) times its
    ## scale-1 gain, over its scale-1 value. MEASURED as peak axis gradient
    ## times sqrt(scale) on a 128x128 torus settled 6000 steps at the Pearson
    ## defaults (peak 0.0837 at scale 1); sqrt(scale) misses by up to 7.3%.

func rdScentGainFactor*(scale: float): float =
  ## g_scent(s) / g_scent(1): what today's field-force gain must be
  ## multiplied by so its strength-1 impulse stays the measured scale-1 value
  ## at every pattern scale. The per-cell gradient grows as 1/sqrt(s), so
  ## sqrt(s) alone would cancel it exactly if the measured impulse actually
  ## tracked sqrt(s) — it does not (RD_SCENT_STEPPED_IMPULSE), so sqrt(s) is
  ## corrected by the recorded ratio, interpolated linearly between steps.
  let steps = RD_SCENT_STEPPED_IMPULSE
  var ratio = steps[0].ratio
  if scale >= steps[0].scale:
    ratio = steps[0].ratio
  elif scale <= steps[^1].scale:
    ratio = steps[^1].ratio
  else:
    for index in 1 ..< steps.len:
      let hi = steps[index - 1]
      let lo = steps[index]
      if scale >= lo.scale and scale <= hi.scale:
        let t = (scale - lo.scale) / (hi.scale - lo.scale)
        ratio = lo.ratio + t * (hi.ratio - lo.ratio)
        break
  sqrt(scale) / ratio

func regimeRow*(id: string, scale: float): typeof(RD_REGIMES[0]) =
  ## The regime `id` as a selection at `scale` applies it: its row for the
  ## band step nearest `scale`, the larger step on a tie, else its scale-1 row.
  var step = RD_PATTERN_SCALE_STEPS[0]
  for candidate in RD_PATTERN_SCALE_STEPS:
    if abs(candidate - scale) < abs(step - scale): step = candidate
  for regime in RD_REGIMES:
    if regime.id != id: continue
    result = regime
    for row in RD_REGIME_SCALE_ROWS:
      if row.id == id and row.scale == step:
        result.feed = row.feed
        result.kill = row.kill
        result.minDeposit = row.minDeposit
    return
  raise newException(KeyError, "no regime named " & id)

# The largest impulse per reference frame, on one axis, each velocity writer
# hands one particle at the range maxima. WGSL i32 atomics wrap
# (https://www.w3.org/TR/WGSL/#atomic-rmw), so the velocity words must hold
# the sum of these over a full crowd.
const
  SPECIES_PAIR_IMPULSE_MAX* = FORCE_STRENGTH_MAX *
    (1.0 + 2.0 * MATRIX_MAX_VALUE) * FRAME_DT_REFERENCE
    ## One pair at contact, forces.wgsl's exponential model.
  FLUID_PAIR_IMPULSE_MAX* = FLUID_STRENGTH_MAX *
    (SPH_MAX_PRESSURE_ACCEL * FRAME_DT_REFERENCE +
      (SPH_VISCOSITY_MAX + SPH_XSPH_EPSILON) * 2.0 * MAX_VELOCITY_MAX)
    ## One fluid pair: the pressure clamp plus the blend, whose normalized
    ## weight is at most 1 over a density floored at 1, across a velocity gap
    ## of at most twice the speed ceiling.
  POINTER_IMPULSE_MAX* = (MOUSE_FORCE_PEAK + BLAST_FORCE_PEAK) *
    FRAME_DT_REFERENCE
    ## The held pointer and a blast at strength 1, once per particle.
  BODIES_IMPULSE_MAX* = float(MAX_BODIES) * BODY_MAX_FORCE_PER_PARTICLE

# THE TWO VELOCITY WORDS. The fluid's full crowd is 1 335 times the span of one
# i32 at 2^16, so the fluid and the pressure split each integer between a fine
# word and a coarse word counting 2^VELOCITY_COARSE_SHIFT fine quanta. Every
# other writer adds to the fine word alone.
const
  VELOCITY_COARSE_SHIFT* = 12
    ## The largest shift the fine word admits: each split writer leaves a
    ## remainder below 2^shift per add, and at 13 the fine word's full crowd
    ## no longer fits.
  FLUID_COARSE_UNITS_PER_PAIR* = int(ceil(FLUID_PAIR_IMPULSE_MAX *
    VELOCITY_FIXED_POINT_SCALE / float(1 shl VELOCITY_COARSE_SHIFT)))
    ## 5 467 coarse units: one fluid pair at the gain ceiling.
  PRESSURE_COARSE_MAX* = int(high(int32)) div MAX_PARTICLES -
    FLUID_COARSE_UNITS_PER_PAIR
    ## 11 310 coarse units, 706.9 velocity per reference frame: the largest
    ## per-pair pressure the coarse word admits after the fluid's share.

func fineWordCrowd(coarseShift: int): float =
  ## The fine word's full crowd before scent and long range, in fine quanta:
  ## the species pairs, a remainder below 2^coarseShift per add from each of
  ## the two split writers, and the single-add writers.
  float(MAX_PARTICLES) * SPECIES_PAIR_IMPULSE_MAX * VELOCITY_FIXED_POINT_SCALE +
    2.0 * float(MAX_PARTICLES) * float((1 shl coarseShift) - 1) +
    (POINTER_IMPULSE_MAX + BODIES_IMPULSE_MAX) * VELOCITY_FIXED_POINT_SCALE

const
  VELOCITY_FINE_ROOM* = (float(high(int32)) -
    fineWordCrowd(VELOCITY_COARSE_SHIFT)) / VELOCITY_FIXED_POINT_SCALE
    ## The velocity per reference frame the fine word has left for scent and
    ## long range together, 7 251 at the shipped ranges.

# THE WORLD PRESSURE. A resistance to compression no coupling strength scales
# and no slider reaches. Its onset is read in the world's own mean crowd
# density, so it follows the live particle count and interaction radius.
const
  CROWD_ONSET_RATIO* = 6.3
    ## x_on: the crowd density the pressure starts at, in multiples of the
    ## world's uniform crowd density.
    ## The user's placement. G1.1 (128 000 particles, radius 50, polynomial,
    ## seeds 42/7/1001, species force only) put it below every one-species
    ## settle (p99.9 x >= 10.56) and above every four-species self-only settle
    ## (<= 3.34). Other counts, radii, species counts and the exponential model
    ## are unmeasured.
  WORLD_PRESSURE_STIFFNESS* = 540.0
    ## K: the pair impulse's stiffness, fixed at every live value. The user's
    ## choice, confirmed by G1.2 at 128 000 particles on seeds 42/7/1001:
    ## friction-0 L 1.1483-1.1613 at 540, and a mean 1.3431 at 1728 exceeding
    ## WORLD_PRESSURE_SETTLE_BOUND.
  WORLD_PRESSURE_SETTLE_BOUND* = 1.1613
    ## B_L: the bound on L, a self-attracting world's friction-0 late-window
    ## speed with the term over the same seed's without it. G1.2's mean 1.1527
    ## plus its largest seed distance 0.0085, at 128 000 and radius 50.
  WORLD_PRESSURE_IMPULSE_MAX* = float(PRESSURE_COARSE_MAX *
    (1 shl VELOCITY_COARSE_SHIFT)) / VELOCITY_FIXED_POINT_SCALE
    ## q_max as a velocity per reference frame, 706.9: the coarse word's
    ## per-pair ceiling after the fluid's share, in the units the pair impulse
    ## saturates at.

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
  # Every coupling strength reaches zero. One loop rather than an
  # assertion each, so a further coupling with a nonzero floor fails here.
  for strengthFloor in [FORCE_STRENGTH_MIN, FLUID_STRENGTH_MIN,
      RD_DEPOSIT_MIN, RD_FIELD_FORCE_MIN, BODIES_STRENGTH_MIN,
      LONG_RANGE_STRENGTH_MIN]:
    doAssert strengthFloor == 0.0,
      "a coupling strength's range excludes zero; every coupling can be " &
      "turned off through its own slider"
  # The bodies ranges are non-empty and every default sits inside its own, the
  # same guard the RD and bloom pairs carry.
  doAssert BODIES_STRENGTH_MIN < BODIES_STRENGTH_MAX
  doAssert BODY_RADIUS_MIN < BODY_RADIUS_MAX
  doAssert BODY_BAND_MIN < BODY_BAND_MAX
  doAssert BODY_BAND_MIN > 0.0,
    "the band divides the distance in the body force law; a zero band " &
    "divides by zero instead of naming a narrower one"
  doAssert BODY_PROXIMITY_MIN < BODY_PROXIMITY_MAX
  doAssert BODY_ENCLOSURE_MIN < BODY_ENCLOSURE_MAX
  doAssert BODY_PROXIMITY_MIN == -BODY_PROXIMITY_MAX and
    BODY_ENCLOSURE_MIN == -BODY_ENCLOSURE_MAX,
    "both body force signs are one quantity, so both ranges straddle zero " &
    "symmetrically"
  doAssert BODY_LIFETIME_MIN < BODY_LIFETIME_MAX
  doAssert BODY_IGNITION_RATE_MIN < BODY_IGNITION_RATE_MAX
  doAssert BODY_ANISOTROPY_MIN < BODY_ANISOTROPY_MAX
  doAssert BODY_ENVELOPE_SKEW_MIN < BODY_ENVELOPE_SKEW_MAX
  doAssert BODY_SUSTAIN_MIN < BODY_SUSTAIN_MAX
  doAssert BODIES_DEFAULT_STRENGTH >= BODIES_STRENGTH_MIN and
    BODIES_DEFAULT_STRENGTH <= BODIES_STRENGTH_MAX
  doAssert BODY_DEFAULT_RADIUS >= BODY_RADIUS_MIN and
    BODY_DEFAULT_RADIUS <= BODY_RADIUS_MAX
  doAssert BODY_DEFAULT_BAND >= BODY_BAND_MIN and
    BODY_DEFAULT_BAND <= BODY_BAND_MAX
  doAssert BODY_DEFAULT_PROXIMITY >= BODY_PROXIMITY_MIN and
    BODY_DEFAULT_PROXIMITY <= BODY_PROXIMITY_MAX
  doAssert BODY_DEFAULT_ENCLOSURE >= BODY_ENCLOSURE_MIN and
    BODY_DEFAULT_ENCLOSURE <= BODY_ENCLOSURE_MAX
  doAssert BODY_DEFAULT_LIFETIME >= BODY_LIFETIME_MIN and
    BODY_DEFAULT_LIFETIME <= BODY_LIFETIME_MAX
  doAssert BODY_DEFAULT_IGNITION_RATE >= BODY_IGNITION_RATE_MIN and
    BODY_DEFAULT_IGNITION_RATE <= BODY_IGNITION_RATE_MAX
  doAssert LONG_RANGE_STRENGTH_MIN < LONG_RANGE_STRENGTH_MAX
  doAssert LONG_RANGE_REACH_MIN < LONG_RANGE_REACH_MAX
  # The reach reaches the uniform as 1/lambda^2, which has no finite value at
  # zero, and the slider's travel is logarithmic, which has no zero either.
  doAssert LONG_RANGE_REACH_MIN > 0.0,
    "a reach of zero has no inverse squared screening length and no position " &
    "on a logarithmic track"
  # The declared live sizes, against the allocation ceiling they index inside
  # and against the line the transform's workgroup array is compiled to hold.
  # A radix-2 transform has no meaning on a line that is not a power of two, so
  # these are the shape of the buffer rather than a preference about it.
  doAssert LR_GRID_SIZES.len > 0
  doAssert LONG_RANGE_GRID_INDEX_DEFAULT >= LONG_RANGE_GRID_INDEX_MIN and
    LONG_RANGE_GRID_INDEX_DEFAULT <= LONG_RANGE_GRID_INDEX_MAX
  for size in LR_GRID_SIZES:
    doAssert lrIsPowerOfTwo(size.w) and lrIsPowerOfTwo(size.h),
      "a declared long-range grid size is not a power of two"
    doAssert size.w <= LR_GRID_MAX_W and size.h <= LR_GRID_MAX_H,
      "a declared long-range grid size exceeds the allocation ceiling in " &
      "src/memory_layout.nim"
    let longestLine = max(size.w, size.h)
    doAssert longestLine <= LR_FFT_MAX_LINE,
      "a declared long-range grid has a line longer than the workgroup array " &
      "the transform is compiled with"
    doAssert (longestLine div 2) mod LR_FFT_WORKGROUP_SIZE == 0 or
      (longestLine div 2) < LR_FFT_WORKGROUP_SIZE,
      "a declared long-range grid's line leaves butterflies the transform's " &
      "workgroup covers neither one per thread nor by looping"
  doAssert SPH_VISCOSITY_MIN < SPH_VISCOSITY_MAX
  doAssert MATRIX_MIN_VALUE == -MATRIX_MAX_VALUE,
    "the matrix band is symmetric: the cell colour scale and the rule " &
    "sampler both read magnitude against MATRIX_MAX_VALUE alone"
  doAssert MATRIX_VALUE_STEP > 0.0
  doAssert SPH_RADIUS_FRACTION_MIN < SPH_RADIUS_FRACTION_MAX
  # The radius fraction shapes the fluid rather than gating a pass, so it is
  # absent from the coupling loop above — and its floor has to clear zero for
  # the opposite reason crowding's has to reach it: zero divides by zero in
  # both kernel normalizations instead of naming a quieter world.
  doAssert SPH_RADIUS_FRACTION_MIN > 0.0,
    "a zero SPH smoothing radius divides by zero in both kernel " &
    "normalizations (src/sph_core.nim)"
  # At exactly 1 the smoothing radius can never outrun the neighbour sweep,
  # whose cells are sized to the interaction radius. Raising this ceiling would
  # make dropped neighbours expressible, which is the constraint this range
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
  for row in RD_REGIME_SCALE_ROWS:
    doAssert row.feed >= RD_FEED_MIN and row.feed <= RD_FEED_MAX,
      "regime " & row.id & "'s scale row has a feed outside the feed slider"
    doAssert row.kill >= RD_KILL_MIN and row.kill <= RD_KILL_MAX,
      "regime " & row.id & "'s scale row has a kill outside the kill slider"
    doAssert row.minDeposit >= RD_DEPOSIT_MIN and
      row.minDeposit <= RD_DEPOSIT_MAX,
      "regime " & row.id & "'s scale row needs a deposit outside the range"
    doAssert row.scale in RD_PATTERN_SCALE_STEPS,
      "regime " & row.id & "'s scale row sits off the band steps"
    var named = false
    for regime in RD_REGIMES:
      if regime.id == row.id: named = true
    doAssert named, "a scale row names no regime: " & row.id
  # The pattern-scale band.
  doAssert RD_PATTERN_SCALE_MAX == 1.0,
    "the ceiling is the base diffusion rates"
  doAssert RD_DIFFUSION_A * RD_PATTERN_SCALE_MAX * RD_DELTA_T <= 1.0,
    "the ceiling carries the activator past its explicit-Euler line"
  doAssert patternDiameterCells(RD_DIFFUSION_A * RD_PATTERN_SCALE_MIN) >=
    RD_MIN_RESOLVED_DIAMETER_CELLS,
    "the floor draws a pattern narrower than the grid resolves"
  doAssert RD_PATTERN_SCALE_DEFAULT >= RD_PATTERN_SCALE_MIN and
    RD_PATTERN_SCALE_DEFAULT <= RD_PATTERN_SCALE_MAX
  doAssert RD_PATTERN_SCALE_DEFAULT == RD_PATTERN_SCALE_MIN,
    "the default is the band's floor"
  doAssert RD_PATTERN_SCALE_STEPS[0] == RD_PATTERN_SCALE_MAX and
    RD_PATTERN_SCALE_STEPS[^1] == RD_PATTERN_SCALE_MIN,
    "the band steps run from the ceiling to the floor"
  for index in 1 ..< RD_PATTERN_SCALE_STEPS.len:
    doAssert RD_PATTERN_SCALE_STEPS[index] < RD_PATTERN_SCALE_STEPS[index - 1]
  doAssert RD_SCENT_STEPPED_IMPULSE.len == RD_PATTERN_SCALE_STEPS.len and
    TROPISM_COLLAPSE_BRACKETS.len == RD_PATTERN_SCALE_STEPS.len
  for index, step in RD_PATTERN_SCALE_STEPS:
    doAssert RD_SCENT_STEPPED_IMPULSE[index].scale == step,
      "the stepped scent impulse is recorded off the band steps"
    doAssert TROPISM_COLLAPSE_BRACKETS[index].scale == step,
      "a collapse bracket is recorded off the band steps"
    doAssert TROPISM_COLLAPSE_BRACKETS[index].safe > 1.0,
      "a collapse bracket's lower deposit edge falls within the deposit range"
  # The force weather's waypoints answer to the same reachability rule, and for
  # a sharper reason than the regime notches: the tour INTERPOLATES between
  # them, so a waypoint outside its range would drag the running simulation
  # somewhere its own sliders cannot express. Convexity is what lets the frame
  # loop write the tour with no clamp, and convexity only helps while every
  # waypoint is already inside the box. Narrowing FORCE_STRENGTH_MAX below 2.4,
  # INTERACTION_RADIUS_MAX below 80, or FRICTION_MAX below 0.16 fails here.
  for waypoint in FORCE_WEATHER_WAYPOINTS:
    doAssert waypoint.strength >= FORCE_STRENGTH_MIN and
      waypoint.strength <= FORCE_STRENGTH_MAX,
      "a force weather waypoint has a strength outside the strength slider"
    doAssert waypoint.radius >= INTERACTION_RADIUS_MIN.float and
      waypoint.radius <= INTERACTION_RADIUS_MAX.float,
      "a force weather waypoint has a radius outside the radius slider"
    doAssert waypoint.friction >= FRICTION_MIN and
      waypoint.friction <= FRICTION_MAX,
      "a force weather waypoint has a friction outside the friction slider"
  # The camera zoom notches are positions on the camera slider, so the same
  # reachability rule covers them.
  for zoomNotch in [CAMERA_ZOOM_NOTCH_WORLD, CAMERA_ZOOM_NOTCH_CREATURE]:
    doAssert zoomNotch >= CAMERA_ZOOM_MIN and zoomNotch <= CAMERA_ZOOM_MAX
  doAssert CAMERA_DRIFT_SPEED_MIN < CAMERA_DRIFT_SPEED_MAX
  doAssert CAMERA_DRIFT_SPEED_MIN > 0.0,
    "the drift toggle stops the drift; a speed slider that could stop it too " &
    "would give one state two controls"
  doAssert CAMERA_DRIFT_SPEED_NOTCH_SCREEN >= CAMERA_DRIFT_SPEED_MIN and
    CAMERA_DRIFT_SPEED_NOTCH_SCREEN <= CAMERA_DRIFT_SPEED_MAX
  # Species chemistry: non-empty ranges, and field_core's defaults inside the
  # range they are the default of — the same guard as the RD pair above. The
  # tropism range is asymmetric on purpose; the assertion below
  # states that as a checked property so a future "tidying" to [-1, +1] fails
  # here rather than shipping unmeasured up-gradient authority.
  doAssert SECRETION_MIN < SECRETION_MAX
  doAssert TROPISM_MIN < TROPISM_MAX
  doAssert TROPISM_MAX < -TROPISM_MIN,
    "tropism is bounded asymmetrically: up-gradient authority must stay " &
    "below down-gradient authority"
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
  # The two velocity words each hold a full crowd at the range maxima.
  doAssert FLUID_STRENGTH_MAX <= 1.0,
    "the coarse word is budgeted at the fluid's gain ceiling of 1"
  doAssert VELOCITY_FINE_ROOM > 0.0,
    "a full crowd at the range maxima wraps the fine velocity word"
  doAssert fineWordCrowd(VELOCITY_COARSE_SHIFT + 1) > float(high(int32)),
    "a larger coarse shift fits the fine word; the shift is not the largest"
  doAssert PRESSURE_COARSE_MAX > 0 and
    MAX_PARTICLES * (FLUID_COARSE_UNITS_PER_PAIR + PRESSURE_COARSE_MAX) <=
      int(high(int32)),
    "a full crowd of fluid and pressure pairs wraps the coarse velocity word"
