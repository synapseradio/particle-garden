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
# cannot drift apart — the drift class that once let preset bounds track
# dead web/index.html attributes (e.g. a 64000 particle ceiling against a
# live 128000 slider) is structurally closed.
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
    ## rules to exist. (ui.nim once registered 1 while the HTML said 2; this
    ## constant settles the mismatch at 2.)
  SPECIES_COUNT_MAX* = memory_layout.MAX_SPECIES
  INTERACTION_RADIUS_MIN* = 10
  INTERACTION_RADIUS_MAX* = 150
  FORCE_STRENGTH_MIN* = 0.1
  FORCE_STRENGTH_MAX* = 5.0
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
  RD_FEED_MAX* = 0.080
  RD_KILL_MIN* = 0.040
  RD_KILL_MAX* = 0.075
  RD_DEPOSIT_MIN* = 0.0
    ## Zero is a meaningful setting: it decouples the particles from the field
    ## entirely, leaving the reaction-diffusion pattern to evolve on its own.
  RD_DEPOSIT_MAX* = 0.08
    ## Measured at the Pearson defaults, the field floods into a uniform bath
    ## from around 0.15 and diverges near 0.30. Those numbers were taken at
    ## feed=0.030 kill=0.062; at the slider's weakest corner (RD_FEED_MIN,
    ## RD_KILL_MIN) the (feed+kill)*B depletion opposing the deposit is about
    ## 1.8x weaker, so the ceiling has to sit well below the measured flood
    ## point. 0.08 leaves roughly 2x margin at that corner, which is what
    ## test_field_core's deposit-ceiling sweep verifies.
  RD_FIELD_FORCE_MIN* = 0.0
    ## Zero leaves particles blind to the field — a real setting, and the way
    ## to watch the pattern evolve without particles stirring it.
  RD_FIELD_FORCE_MAX* = 150.0
    ## Inhibitor gradients peak near 0.05 per cell, so the default 30 is about
    ## 1.5 velocity units per frame against a maxVelocity of 50. 150 is five
    ## times that: violent, but still bounded by the integrator's own velocity
    ## clamp. Kept non-negative deliberately — field-force.wgsl notes that a
    ## negative scale pulls particles up-gradient, concentrating their deposits
    ## on inhibitor ridges into a positive-feedback loop nothing here has
    ## checked for stability.
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
  doAssert SPH_VISCOSITY_MIN < SPH_VISCOSITY_MAX
  doAssert SPH_SUBSTEPS_MIN < SPH_SUBSTEPS_MAX
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
