# ==============================================================================
# PARTICLE GARDEN - SIM CONFIG TESTS
# ==============================================================================
#
# Behavioral tests for the typed configuration layer: SimulationState (physics
# tunables), RenderState (visual tunables), SimConfig (their composition), and
# couplingsOf, which reads the world's couplings off the strengths rather than
# storing them. config.nim's createConfig copies these defaults into the flat
# GPU-facing CONFIG mirror, so this module is the single authoritative home of
# every default value.
#
# Tests prefer relations over scalar pins: each default must lie inside its
# own config_ranges clamp range (the same constants the sliders and preset
# schema use), and cross-field identities are asserted directly.
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import ../src/ui/state/sim_config
import ../src/config_ranges

const SIM_CONFIG_TESTS_LOADED* = true

suite "Simulation Defaults Lie Inside Their Slider Ranges":
  let defaults = initSimulationState()

  test "count and radius defaults are inside their clamp ranges":
    check defaults.particleCount in PARTICLE_COUNT_MIN .. PARTICLE_COUNT_MAX
    check defaults.speciesCount in SPECIES_COUNT_MIN .. SPECIES_COUNT_MAX
    check defaults.interactionRadius in
      INTERACTION_RADIUS_MIN .. INTERACTION_RADIUS_MAX

  test "physics scalar defaults are inside their clamp ranges":
    check defaults.forceStrength >= FORCE_STRENGTH_MIN
    check defaults.forceStrength <= FORCE_STRENGTH_MAX
    check defaults.friction >= FRICTION_MIN
    check defaults.friction <= FRICTION_MAX
    check defaults.timeScale >= TIME_SCALE_MIN
    check defaults.timeScale <= TIME_SCALE_MAX
    check defaults.ruleTemperature >= RULE_TEMPERATURE_MIN
    check defaults.ruleTemperature <= RULE_TEMPERATURE_MAX
    check defaults.maxVelocity >= MAX_VELOCITY_MIN
    check defaults.maxVelocity <= MAX_VELOCITY_MAX

  test "force model defaults are inside their clamp ranges":
    check defaults.repulsionEnd >= REPULSION_END_MIN
    check defaults.repulsionEnd <= REPULSION_END_MAX
    check defaults.attractionPeak >= ATTRACTION_PEAK_MIN
    check defaults.attractionPeak <= ATTRACTION_PEAK_MAX
    check defaults.expRepulsionAlpha >= EXP_REPULSION_ALPHA_MIN
    check defaults.expRepulsionAlpha <= EXP_REPULSION_ALPHA_MAX
    check defaults.expAttractionBeta >= EXP_ATTRACTION_BETA_MIN
    check defaults.expAttractionBeta <= EXP_ATTRACTION_BETA_MAX

  test "attraction peaks after repulsion ends":
    # The polynomial force curve is only well-formed when the repulsion zone
    # ends before the attraction peak.
    check defaults.repulsionEnd < defaults.attractionPeak

  test "SPH defaults are inside their clamp ranges":
    check defaults.sphRestDensity >= SPH_REST_DENSITY_MIN
    check defaults.sphRestDensity <= SPH_REST_DENSITY_MAX
    check defaults.sphStiffness >= SPH_STIFFNESS_MIN
    check defaults.sphStiffness <= SPH_STIFFNESS_MAX
    check defaults.sphViscosity >= SPH_VISCOSITY_MIN
    check defaults.sphViscosity <= SPH_VISCOSITY_MAX
    check defaults.sphSubsteps in SPH_SUBSTEPS_MIN .. SPH_SUBSTEPS_MAX

  test "reaction-diffusion defaults are inside their clamp ranges":
    check defaults.rdFeed >= RD_FEED_MIN
    check defaults.rdFeed <= RD_FEED_MAX
    check defaults.rdKill >= RD_KILL_MIN
    check defaults.rdKill <= RD_KILL_MAX


suite "Render Defaults Lie Inside Their Slider Ranges":
  let defaults = initRenderState()

  test "particle size and trail defaults are inside their clamp ranges":
    check defaults.particleSize in PARTICLE_SIZE_MIN .. PARTICLE_SIZE_MAX
    check defaults.trailLength >= TRAIL_LENGTH_MIN
    check defaults.trailLength <= TRAIL_LENGTH_MAX

  test "glow defaults are inside their clamp ranges":
    check defaults.glowIntensity >= GLOW_INTENSITY_MIN
    check defaults.glowIntensity <= GLOW_INTENSITY_MAX
    check defaults.velocityGlowScale >= VELOCITY_GLOW_SCALE_MIN
    check defaults.velocityGlowScale <= VELOCITY_GLOW_SCALE_MAX
    check defaults.glowRadiusScale >= GLOW_RADIUS_SCALE_MIN
    check defaults.glowRadiusScale <= GLOW_RADIUS_SCALE_MAX
    check defaults.glowFalloff >= GLOW_FALLOFF_MIN
    check defaults.glowFalloff <= GLOW_FALLOFF_MAX
    check defaults.glowWarmth >= GLOW_WARMTH_MIN
    check defaults.glowWarmth <= GLOW_WARMTH_MAX

  test "default glow radius reproduces the pre-knob hard-coded radius":
    # CONTRACT: the defaults hold (particleSize + 1) * glowRadiusScale at 12.0,
    # the baseRadius glow.wgsl draws with and what fixes the default look.
    check float(defaults.particleSize + 1) * defaults.glowRadiusScale == 12.0

  test "bloom and grade defaults are inside their clamp ranges":
    check defaults.bloomIntensity >= BLOOM_INTENSITY_MIN
    check defaults.bloomIntensity <= BLOOM_INTENSITY_MAX
    check defaults.exposure >= EXPOSURE_MIN
    check defaults.exposure <= EXPOSURE_MAX
    check defaults.saturation >= SATURATION_MIN
    check defaults.saturation <= SATURATION_MAX
    check defaults.contrast >= CONTRAST_MIN
    check defaults.contrast <= CONTRAST_MAX
    check defaults.temperature >= TEMPERATURE_MIN
    check defaults.temperature <= TEMPERATURE_MAX

  test "bloom defaults off so the default look is the non-bloom quality floor":
    check defaults.bloomEnabled == false


suite "SimConfig Composition":
  test "defaultSimConfig composes the two state records and nothing else":
    let composed = defaultSimConfig()
    check composed.simulation == initSimulationState()
    check composed.render == initRenderState()


suite "The Couplings Are Read Off The Parameters":
  test "each strength is the simulation parameter it names":
    # Derived, never stored: a second copy could disagree with the sliders, and
    # the disagreement would be a frame skipping a pass whose strength is not
    # zero. Asserting equality with the source is what makes the copy absent.
    var state = initSimulationState()
    state.forceStrength = 2.5
    state.fluidStrength = 0.25
    state.rdDeposit = 0.03
    state.rdFieldForce = 40.0
    let couplings = couplingsOf(state)
    check couplings.forces == 2.5
    check couplings.fluid == 0.25
    check couplings.deposit == 0.03
    check couplings.fieldForce == 40.0

  test "the shipped world couples forces and chemistry, and no fluid":
    # The shipped world: colonies that feel each other AND write the field they
    # live in. The fluid waits at zero behind a slider the panel always shows.
    let couplings = couplingsOf(initSimulationState())
    check couplings.forces > 0.0
    check couplings.deposit > 0.0
    check couplings.fieldForce > 0.0
    check couplings.fluid == 0.0

  test "every coupling strength can be turned off through its own range":
    # Design D13 as an executable fact rather than a claim about ranges. A
    # strength whose minimum sits above zero cannot express "off", leaving its
    # world with a coupling the user cannot remove.
    var silent = initSimulationState()
    silent.forceStrength = FORCE_STRENGTH_MIN
    silent.fluidStrength = FLUID_STRENGTH_MIN
    silent.rdDeposit = RD_DEPOSIT_MIN
    silent.rdFieldForce = RD_FIELD_FORCE_MIN
    let couplings = couplingsOf(silent)
    check couplings.forces == 0.0
    check couplings.fluid == 0.0
    check couplings.deposit == 0.0
    check couplings.fieldForce == 0.0

  test "fluid strength's default and range are consistent":
    let defaults = initSimulationState()
    check defaults.fluidStrength >= FLUID_STRENGTH_MIN
    check defaults.fluidStrength <= FLUID_STRENGTH_MAX


suite "The Trails Toggle Always Produces Trails":
  # THE DEFECT THIS PINS. Trails are two controls over one effect: a boolean
  # gating the fade pass, and a length deciding how much of the previous frame
  # that pass keeps. At length 0 the pass keeps nothing, so switching the
  # toggle on runs a pass that clears — a control that does nothing, from the
  # user's side indistinguishable from a broken one.

  test "enabling trails from the shipped defaults yields a visible length":
    let enabled = initRenderState().withTrails(true)
    check enabled.trails
    check enabled.trailLength > 0.0

  test "enabling trails does not overwrite a length the user chose":
    var chosen = initRenderState()
    chosen.trailLength = 80.0
    let enabled = chosen.withTrails(true)
    check enabled.trailLength == 80.0

  test "disabling trails leaves the length alone":
    # So off-and-on-again returns the trail the user had, not the default.
    let cycled = initRenderState().withTrails(true).withTrails(false)
    check not cycled.trails
    check cycled.trailLength > 0.0
    check cycled.withTrails(true).trailLength == cycled.trailLength

  test "the lifted length is inside the slider's own range":
    # Otherwise the toggle writes a value the slider cannot represent and the
    # descriptor clamps it back on the next touch.
    check TRAIL_LENGTH_WHEN_ENABLED > TRAIL_LENGTH_MIN
    check TRAIL_LENGTH_WHEN_ENABLED <= TRAIL_LENGTH_MAX

  test "trails still ship off by default":
    check not initRenderState().trails
