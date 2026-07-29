# ==============================================================================
# PARTICLE GARDEN - GLOW CORE TESTS
# ==============================================================================
#
# Behavioral tests for src/glow_core.nim, the pure mirror of
# web/shaders/src/glow.wgsl. The halo runs in a fragment shader no native test
# can execute, so what is checked here is the arithmetic the shader is written
# against: the radius composition, the Gaussian falloff, the warm shift, and
# the halo-alpha integral a response probe reads.
#
# THE PROBE OBSERVABLE IS THE CLAMPED INTEGRAL. A screen answers alpha up to 1
# and no further, so the raw integral keeps climbing through slider travel the
# display has stopped showing. Both forms are exercised here, and the pair is
# what makes the deadness visible rather than averaged away.
#
# Every coordinate comes from an owner: ranges from config_ranges.nim, shipped
# defaults from initRenderState(), curve constants from shader_config.nim's
# TuningConstants — the same values the bundler substitutes into the shader.
#
# Run with: just test
#
# ==============================================================================

import std/[unittest, math]
import ../src/glow_core
import ../src/config_ranges
import ../src/shader_config
import ../src/ui/state/render_state

const GLOW_CORE_TESTS_LOADED* = true

const
  EPSILON = 1e-12
    ## The mirror is closed-form arithmetic, so agreement is exact to within
    ## double rounding; a loose epsilon here would hide a changed composition.
  QUADRATURE_TOLERANCE = 1e-3
    ## Relative slack on integrals, which the module evaluates by midpoint rule.
  FULL_SPEED = 1.0
    ## velocityNorm at or above maxVelocity (glow.wgsl:91 clamps there).
  SETTLED_DENSITY = 50.0
    ## Far above the density that saturates the density factor, so the tests
    ## that hold density fixed sit on the flat part of its clamp.

func defaultUniforms(): GlowUniforms =
  ## The halo the app draws at its shipped defaults. baseSize mirrors
  ## webgpu_render.nim:1630 (`particleSize + 1`), and glowDensityFloor mirrors
  ## :1643, where the renderer writes zero because every world measures density.
  let shipped = initRenderState()
  GlowUniforms(
    baseSize: float(shipped.particleSize + 1),
    glowIntensity: shipped.glowIntensity,
    velocityGlowScale: shipped.velocityGlowScale,
    glowRadiusScale: shipped.glowRadiusScale,
    glowFalloff: shipped.glowFalloff,
    glowWarmth: shipped.glowWarmth,
    glowDensityFloor: 0.0)


suite "The Halo Falls Off As A Gaussian":
  test "halo alpha falls off as a Gaussian in normalized radius":
    # CONTRACT: glow.wgsl:169-170. Everything except `gauss` is constant across
    # the billboard, so alpha at radius l is the centre value times
    # exp(-glowFalloff * l * l) — the shape the slider promises to tighten.
    let tuning = glowTuning()
    var uniforms = defaultUniforms()
    for falloff in [GLOW_FALLOFF_MIN, uniforms.glowFalloff, GLOW_FALLOFF_MAX]:
      uniforms.glowFalloff = falloff
      let centre = haloAlpha(tuning, uniforms, 0.0, FULL_SPEED, SETTLED_DENSITY)
      check centre > 0.0
      var previous = centre
      for step in 1 .. 32:
        let radius = step.float / 32.0
        let alpha = haloAlpha(tuning, uniforms, radius, FULL_SPEED,
          SETTLED_DENSITY)
        check abs(alpha - centre * exp(-falloff * radius * radius)) < EPSILON
        # Monotone inward brightness: no ring, no plateau.
        check alpha < previous
        previous = alpha

  test "nothing is drawn outside the unit disc":
    # CONTRACT: glow.wgsl:140-142 discards past l = 1, so the square billboard
    # never shows. A mirror that integrated past the edge would credit the halo
    # with light the shader throws away.
    let tuning = glowTuning()
    let uniforms = defaultUniforms()
    check haloAlpha(tuning, uniforms, 1.0, FULL_SPEED, SETTLED_DENSITY) > 0.0
    for outside in [1.0 + 1e-9, 1.2, sqrt(2.0)]:
      check haloAlpha(tuning, uniforms, outside, FULL_SPEED,
        SETTLED_DENSITY) == 0.0

  test "a tighter falloff dims every radius but the centre":
    let tuning = glowTuning()
    var loose = defaultUniforms()
    var tight = defaultUniforms()
    loose.glowFalloff = GLOW_FALLOFF_MIN
    tight.glowFalloff = GLOW_FALLOFF_MAX
    check haloAlpha(tuning, loose, 0.0, FULL_SPEED, SETTLED_DENSITY) ==
      haloAlpha(tuning, tight, 0.0, FULL_SPEED, SETTLED_DENSITY)
    for step in 1 .. 16:
      let radius = step.float / 16.0
      check haloAlpha(tuning, tight, radius, FULL_SPEED, SETTLED_DENSITY) <
        haloAlpha(tuning, loose, radius, FULL_SPEED, SETTLED_DENSITY)


suite "Glow Intensity Reaches The Halo":
  test "raw alpha scales linearly with glowIntensity":
    # CONTRACT: glow.wgsl:170 multiplies by glowIntensity once. The velocity
    # term multiplies by it a second time (:165), so the plain linear promise
    # holds exactly where that term is out: a stationary particle, or a world
    # with the velocity coupling turned down to zero.
    let tuning = glowTuning()
    let shipped = defaultUniforms()
    # Two coordinates where the velocity term contributes nothing: a particle
    # standing still, and a world whose velocity coupling is at its floor.
    for coordinate in [(speed: 0.0, coupling: shipped.velocityGlowScale),
        (speed: FULL_SPEED, coupling: VELOCITY_GLOW_SCALE_MIN)]:
      var uniforms = defaultUniforms()
      let speed = coordinate.speed
      uniforms.velocityGlowScale = coordinate.coupling
      uniforms.glowIntensity = 1.0
      let unit = haloAlpha(tuning, uniforms, 0.25, speed, SETTLED_DENSITY)
      check unit > 0.0
      for step in 0 .. 16:
        let intensity = GLOW_INTENSITY_MIN +
          (GLOW_INTENSITY_MAX - GLOW_INTENSITY_MIN) * step.float / 16.0
        uniforms.glowIntensity = intensity
        let alpha = haloAlpha(tuning, uniforms, 0.25, speed, SETTLED_DENSITY)
        check abs(alpha - intensity * unit) < EPSILON

  test "the velocity coupling makes alpha quadratic in glowIntensity":
    # WHY THE LINEAR TEST NAMES ITS COORDINATE. glow.wgsl:165 folds
    # velocityGlowScale * glowIntensity into the velocity factor, so a moving
    # particle's halo grows as intensity squared — the shader's own documented
    # "velocity contribution is the AREA of the square" (:153-162). A mirror
    # that dropped the second factor would still pass the linear test above.
    let tuning = glowTuning()
    var uniforms = defaultUniforms()
    uniforms.velocityGlowScale = VELOCITY_GLOW_SCALE_MAX
    uniforms.glowIntensity = GLOW_INTENSITY_MAX * 0.5
    let half = haloAlpha(tuning, uniforms, 0.0, FULL_SPEED, SETTLED_DENSITY)
    uniforms.glowIntensity = GLOW_INTENSITY_MAX
    let full = haloAlpha(tuning, uniforms, 0.0, FULL_SPEED, SETTLED_DENSITY)
    check full > 2.0 * half

  test "the mirror's curve constants are the ones the bundler substitutes":
    # THE LOCKSTEP. glow.wgsl reads these as {{TUNABLE_GLOW_*}} placeholders
    # (shader_config.nim:267-274). This is the check that a renamed or
    # re-homed constant cannot leave the mirror measuring a different curve
    # from the one the GPU runs.
    let tuning = glowTuning()
    check tuning.velocityLogScale == getTunableFloat("GLOW_VELOCITY_LOG_SCALE")
    check tuning.velocityBase == getTunableFloat("GLOW_VELOCITY_BASE")
    check tuning.densityScale == getTunableFloat("GLOW_DENSITY_SCALE")
    check tuning.densityMin == getTunableFloat("GLOW_DENSITY_MIN")
    check tuning.densityMax == getTunableFloat("GLOW_DENSITY_MAX")
    check tuning.divisor == getTunableFloat("GLOW_DIVISOR")
    check tuning.warmthGreen == getTunableFloat("GLOW_WARMTH_GREEN")
    check tuning.warmthBlue == getTunableFloat("GLOW_WARMTH_BLUE")


suite "The Probe Observable Is What The Display Can Answer":
  test "the probe observable saturates at the display clamp":
    # CONTRACT: design E1. The clamped integral is bounded by the halo's own
    # disc area, because no pixel inside it can show more than alpha 1; the raw
    # integral has no ceiling at all. Measured at the brightest coordinate the
    # shipped sliders reach — full speed, velocityGlowScale at its maximum,
    # density past the factor's clamp.
    #
    # MEASURED, at that coordinate: the clamped integral is 85% of the raw one
    # at the top of the intensity track (1559 against 1843 pixels squared, of a
    # 5542 disc). At the SHIPPED velocityGlowScale of 1.0 the same track peaks
    # at alpha 0.5 and nothing clamps at all, so a sweep looking for saturation
    # has to say which velocity coupling it measured under.
    let tuning = glowTuning()
    var uniforms = defaultUniforms()
    uniforms.velocityGlowScale = VELOCITY_GLOW_SCALE_MAX
    let area = haloDiscArea(uniforms, FULL_SPEED)

    # Dim end of the track: nothing reaches the clamp, so the two agree.
    uniforms.glowIntensity = GLOW_INTENSITY_MIN +
      (GLOW_INTENSITY_MAX - GLOW_INTENSITY_MIN) * 0.125
    let dimRaw = haloAlphaIntegralRaw(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    let dimClamped = haloAlphaIntegralClamped(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    check dimRaw > 0.0
    check abs(dimClamped - dimRaw) < EPSILON

    # Top of the track: the display has stopped answering part of the halo.
    uniforms.glowIntensity = GLOW_INTENSITY_MAX
    let topRaw = haloAlphaIntegralRaw(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    let topClamped = haloAlphaIntegralClamped(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    check topClamped < topRaw
    check topClamped <= area * (1.0 + QUADRATURE_TOLERANCE)

    # Far past the track, the observable is the disc area and nothing more:
    # every pixel is pinned at the clamp while the raw integral runs away.
    uniforms.glowIntensity = GLOW_INTENSITY_MAX * 100.0
    let farRaw = haloAlphaIntegralRaw(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    let farClamped = haloAlphaIntegralClamped(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    check abs(farClamped - area) < area * QUADRATURE_TOLERANCE
    check farRaw > area * 10.0

  test "the clamped integral never falls as the track advances":
    # A probe observable that dipped would report a cliff the halo does not
    # have. Clamping a rising integrand keeps it non-decreasing.
    let tuning = glowTuning()
    var uniforms = defaultUniforms()
    uniforms.velocityGlowScale = VELOCITY_GLOW_SCALE_MAX
    var previous = -1.0
    for step in 0 .. 32:
      uniforms.glowIntensity = GLOW_INTENSITY_MIN +
        (GLOW_INTENSITY_MAX - GLOW_INTENSITY_MIN) * step.float / 32.0
      let observable = haloAlphaIntegralClamped(tuning, uniforms, FULL_SPEED,
        SETTLED_DENSITY)
      check observable >= previous
      previous = observable

  test "an unclamped halo integrates to its disc area times its mean alpha":
    # The quadrature itself, checked against a closed form: with the clamp out
    # of reach the integral is analytic —
    # 2*pi*R^2 * integral(exp(-f l^2) l dl, 0..1) = pi*R^2 * (1 - exp(-f)) / f
    # times the constant factors. This is what keeps the saturation test above
    # from passing on a mis-scaled integral.
    let tuning = glowTuning()
    var uniforms = defaultUniforms()
    uniforms.glowIntensity = GLOW_INTENSITY_MIN +
      (GLOW_INTENSITY_MAX - GLOW_INTENSITY_MIN) * 0.1
    let centre = haloAlpha(tuning, uniforms, 0.0, FULL_SPEED, SETTLED_DENSITY)
    let falloff = uniforms.glowFalloff
    let expected = haloDiscArea(uniforms, FULL_SPEED) * centre *
      (1.0 - exp(-falloff)) / falloff
    let measured = haloAlphaIntegralRaw(tuning, uniforms, FULL_SPEED,
      SETTLED_DENSITY)
    check abs(measured - expected) < expected * QUADRATURE_TOLERANCE


suite "The Halo Radius Composes From Size, Scale And Speed":
  test "base radius scales with glowRadiusScale":
    # CONTRACT: glow.wgsl:98-100. The slider multiplies the particle's own
    # size, so the halo tracks particle size rather than drifting out of step
    # with it (design D9).
    var uniforms = defaultUniforms()
    for scale in [GLOW_RADIUS_SCALE_MIN, uniforms.glowRadiusScale,
        GLOW_RADIUS_SCALE_MAX]:
      uniforms.glowRadiusScale = scale
      check abs(baseHaloRadius(uniforms) - uniforms.baseSize * scale) < EPSILON
      # A still particle's halo IS the base radius: the boost is velocity's.
      check abs(haloRadius(uniforms, 0.0) - baseHaloRadius(uniforms)) < EPSILON

  test "doubling the radius scale doubles the halo at every speed":
    var single = defaultUniforms()
    var doubled = defaultUniforms()
    doubled.glowRadiusScale = single.glowRadiusScale * 2.0
    check doubled.glowRadiusScale <= GLOW_RADIUS_SCALE_MAX
    for step in 0 .. 8:
      let speed = step.float / 8.0
      check abs(haloRadius(doubled, speed) - 2.0 * haloRadius(single, speed)) <
        EPSILON

  test "speed grows the halo by half the velocity coupling":
    # CONTRACT: glow.wgsl:99-100 — at full speed the halo is
    # (1 + velocityGlowScale * 0.5) times its base radius.
    var uniforms = defaultUniforms()
    for coupling in [VELOCITY_GLOW_SCALE_MIN, uniforms.velocityGlowScale,
        VELOCITY_GLOW_SCALE_MAX]:
      uniforms.velocityGlowScale = coupling
      let expected = baseHaloRadius(uniforms) * (1.0 + coupling * 0.5)
      check abs(haloRadius(uniforms, FULL_SPEED) - expected) < EPSILON

  test "speed is normalized against maxVelocity and clamps there":
    # CONTRACT: glow.wgsl:91.
    check normalizedVelocity(0.0, 50.0) == 0.0
    check normalizedVelocity(25.0, 50.0) == 0.5
    check normalizedVelocity(50.0, 50.0) == 1.0
    check normalizedVelocity(500.0, 50.0) == 1.0
    # A zero ceiling divides by the shader's guard rather than by zero.
    check normalizedVelocity(1.0, 0.0) == 1.0


suite "Warmth Is Bounded By The Warmth Slider":
  test "warmth is bounded above by glowWarmth":
    # CONTRACT: glow.wgsl:176 — warmth is densityFactor * glowWarmth, and the
    # density factor is clamped at densityMax. The bound is the slider's own
    # value exactly when that clamp sits at 1.
    let tuning = glowTuning()
    check tuning.densityMax <= 1.0
    var uniforms = defaultUniforms()
    for ceilingValue in [GLOW_WARMTH_MIN, uniforms.glowWarmth,
        GLOW_WARMTH_MAX]:
      uniforms.glowWarmth = ceilingValue
      for density in [0.0, 0.1, 1.0, 6.0, SETTLED_DENSITY, 1.0e6]:
        let warmth = haloWarmth(tuning, uniforms, density)
        check warmth >= 0.0
        check warmth <= ceilingValue + EPSILON

  test "the densest colony reaches the ceiling exactly":
    let tuning = glowTuning()
    var uniforms = defaultUniforms()
    uniforms.glowWarmth = GLOW_WARMTH_MAX
    check abs(haloWarmth(tuning, uniforms, SETTLED_DENSITY) -
      GLOW_WARMTH_MAX * tuning.densityMax) < EPSILON

  test "the warm shift attenuates green and blue and leaves red alone":
    # CONTRACT: glow.wgsl:177. Warmth removes green and blue; it never adds.
    let tuning = glowTuning()
    let neutral = warmShift(tuning, 0.0)
    check neutral == (r: 1.0, g: 1.0, b: 1.0)
    for step in 1 .. 8:
      let warmth = GLOW_WARMTH_MAX * step.float / 8.0
      let shift = warmShift(tuning, warmth)
      check shift.r == 1.0
      check shift.g < neutral.g
      check shift.b < shift.g
      check shift.g >= 0.0
      check shift.b >= 0.0
