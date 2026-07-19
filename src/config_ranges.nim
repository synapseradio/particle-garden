# ==============================================================================
# PARTICLE GARDEN - SLIDER RANGE CONTRACT (Pure)
# ==============================================================================
#
# The single source of truth for every user-facing tunable's range. Pure
# (no FFI, no DOM): compiles on both the native and JS backends.
#
# Consumed by:
#   - ui.nim's configSlider registrations (the live UI ranges)
#   - preset.nim's clamp bounds (what a loaded preset is coerced into)
#   - tests (natively)
#
# Because both consumers read these constants, the UI and the preset schema
# cannot drift apart — the drift class that once let preset bounds track
# dead web/index.html attributes (e.g. a 64000 particle ceiling against a
# live 128000 slider) is structurally closed.
#
# web/index.html's authored min/max/step attributes are dead values:
# slider.bindToDOM overwrites them from these registrations at bind time.
#
# ==============================================================================

import memory_layout

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

static:
  # Every range must be non-empty, or clamping inverts.
  doAssert PARTICLE_COUNT_MIN < PARTICLE_COUNT_MAX
  doAssert SPECIES_COUNT_MIN < SPECIES_COUNT_MAX
  doAssert PARTICLE_SIZE_MIN < PARTICLE_SIZE_MAX
  doAssert GLOW_RADIUS_SCALE_MIN < GLOW_RADIUS_SCALE_MAX
  doAssert GLOW_FALLOFF_MIN < GLOW_FALLOFF_MAX
  doAssert GLOW_WARMTH_MIN < GLOW_WARMTH_MAX
