# ==============================================================================
# PARTICLE GARDEN - SIM CONFIG TESTS
# ==============================================================================
#
# Behavioral tests for the typed configuration layer: SimulationState (physics
# tunables), RenderState (visual tunables), and SimConfig (their composition
# plus the active simulation kind). config.nim's createConfig copies these
# defaults into the flat GPU-facing CONFIG mirror, so this module is the
# single authoritative home of every default value.
#
# Tests prefer relations over scalar pins: each default must lie inside its
# own config_ranges clamp range (the same constants the sliders and preset
# schema use), and cross-field identities are asserted directly.
#
# Run with: nimble test
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
    # glow.wgsl hard-coded baseRadius = 12.0 before the knobs existed; the
    # defaults must keep (particleSize + 1) * glowRadiusScale at that value
    # so default visuals are unchanged.
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
  test "defaultSimConfig starts in particle-life with the module defaults":
    let composed = defaultSimConfig()
    check composed.simKind == skParticleLife
    check composed.simulation == initSimulationState()
    check composed.render == initRenderState()

  test "activeSimKind observable starts in particle-life":
    check activeSimKind.get() == skParticleLife
