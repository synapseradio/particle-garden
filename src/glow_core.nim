# ==============================================================================
# PARTICLE GARDEN - GLOW CORE (Pure)
# ==============================================================================
#
# The pure mirror of web/shaders/src/glow.wgsl: the halo radius composition
# (:96-101), the density and velocity factors (:148-149, :164-165), the
# Gaussian falloff (:169-170), and the warm shift (:176-177). The halo runs in
# a fragment shader, where no native test reaches it, so this module carries
# the same arithmetic in the same order and the suite holds it to the shader's
# contract. A change to either side without the other is the review flag
# (engineering principle 5).
#
# WHAT A RESPONSE PROBE READS. `haloAlphaIntegralClamped` is the observable the
# glow sliders are measured through (design E1): the display-clamped alpha
# summed over the halo's screen footprint, in pixels squared. A screen answers
# alpha up to DISPLAY_ALPHA_MAX and no further, so past that the raw integral
# keeps climbing through slider travel that shows nothing — which is exactly
# the deadness the metric has to see. `haloAlphaIntegralRaw` is the same sum
# without the clamp, kept beside it so the gap between them is measurable.
#
# THE FOOTPRINT IS AN AREA, NOT A LINE. The clamp acts per pixel, so the sum of
# what pixels display is an area integral; a plain radial integral would be a
# quantity no clamp applies to pixel-wise. That choice is what makes
# glowRadiusScale move the observable quadratically, as the halo's own area
# does.
#
# TWO INPUT GROUPS, MIRRORING THE SHADER'S OWN SPLIT. `GlowUniforms` carries
# the RenderParams fields the user's sliders write (src/gpu_types.nim's
# RenderParamsLayout, written by src/webgpu_render.nim:1630-1643).
# `GlowTuning` carries the curve constants the bundler substitutes as the
# {{TUNABLE_GLOW_*}} family, whose home is shader_config.nim's TuningConstants;
# `shader_config.glowTuning()` builds it from that one home rather than
# restating a number here.
#
# ONE PLACE THE MIRROR CANNOT FOLLOW. The shader antialiases the disc boundary
# over one screen pixel with `fwidth` (:138-139). A pure function has no screen
# derivatives, so `circleMask` here is that edge in the limit — a hard disc.
# The difference is confined to the boundary's own width.
#
# Used by:
#   - tests/test_glow_core.nim (native tests)
#
# ==============================================================================

import std/math

# ==============================================================================
# WHAT THE SHADER READS
# ==============================================================================

type
  GlowTuning* = object
    ## glow.wgsl's curve constants, as the bundler substitutes them (:64-77).
    velocityLogScale*: float  ## {{TUNABLE_GLOW_VELOCITY_LOG_SCALE}} (:64)
    velocityBase*: float      ## {{TUNABLE_GLOW_VELOCITY_BASE}} (:65)
    densityScale*: float      ## {{TUNABLE_GLOW_DENSITY_SCALE}} (:68)
    densityMin*: float        ## {{TUNABLE_GLOW_DENSITY_MIN}} (:69)
    densityMax*: float        ## {{TUNABLE_GLOW_DENSITY_MAX}} (:70)
    divisor*: float           ## {{TUNABLE_GLOW_DIVISOR}} (:73)
    warmthGreen*: float       ## {{TUNABLE_GLOW_WARMTH_GREEN}} (:76)
    warmthBlue*: float        ## {{TUNABLE_GLOW_WARMTH_BLUE}} (:77)

  GlowUniforms* = object
    ## The RenderParams fields glow.wgsl reads. Every one but baseSize is a
    ## user-facing slider; baseSize is the particle's own drawn size in pixels,
    ## which webgpu_render writes as `particleSize + 1`.
    baseSize*: float
    glowIntensity*: float
    velocityGlowScale*: float
    glowRadiusScale*: float
    glowFalloff*: float
    glowWarmth*: float
    glowDensityFloor*: float
      ## Lifts the density factor where density is unavailable. Every world
      ## measures density, so the renderer writes zero and this is inert.

const
  DISPLAY_ALPHA_MAX* = 1.0
    ## The alpha a screen answers. Beyond it the halo brightens numerically and
    ## shows nothing, which is what the clamped integral below refuses to count.
  HALO_INTEGRAL_SAMPLES* = 1024
    ## Midpoint-rule intervals across the halo radius. The integrand is smooth
    ## except at the radius where the clamp engages, so this leaves the
    ## quadratic rule's error orders below the tolerances the suite checks at.
  MAX_VELOCITY_GUARD* = 0.0001
    ## glow.wgsl:91's `max(params.maxVelocity, 0.0001)` — a zero ceiling
    ## divides by this rather than by zero.
  VELOCITY_RADIUS_BOOST* = 0.5
    ## glow.wgsl:99's half: at full speed the halo grows by half the velocity
    ## coupling, so the coupling's maximum is a 2.5x halo rather than a 6x one.

# ==============================================================================
# THE HALO'S GEOMETRY
# ==============================================================================

func normalizedVelocity*(speed, maxVelocity: float): float =
  ## Speed as a fraction of the world's velocity ceiling, clamped into [0, 1].
  ## glow.wgsl:91 calls this velocityNorm and feeds it to both the radius and
  ## the brightness.
  clamp(speed / max(maxVelocity, MAX_VELOCITY_GUARD), 0.0, 1.0)

func baseHaloRadius*(uniforms: GlowUniforms): float =
  ## The halo a still particle draws, in pixels (glow.wgsl:98). It multiplies
  ## the particle's own size, which is what keeps halo, particle and trail
  ## moving together rather than drifting apart (design D9).
  uniforms.baseSize * uniforms.glowRadiusScale

func haloRadius*(uniforms: GlowUniforms; velocityNorm: float): float =
  ## The drawn halo radius in pixels (glow.wgsl:99-100): the base radius grown
  ## by the velocity coupling, at half weight.
  baseHaloRadius(uniforms) *
    (1.0 + velocityNorm * uniforms.velocityGlowScale * VELOCITY_RADIUS_BOOST)

func haloDiscArea*(uniforms: GlowUniforms; velocityNorm: float): float =
  ## The screen area the halo covers, in pixels squared — and therefore the
  ## ceiling on the clamped integral, since no pixel inside it displays more
  ## than DISPLAY_ALPHA_MAX.
  let radius = haloRadius(uniforms, velocityNorm)
  PI * radius * radius

func circleMask*(offsetLength: float): float =
  ## Inside the unit disc or nothing (glow.wgsl:138-142). The shader's
  ## one-pixel antialiased edge needs screen derivatives; this is that edge in
  ## the limit, which is also what the discard leaves for every pixel but the
  ## boundary's own.
  if offsetLength > 1.0: 0.0 else: 1.0

# ==============================================================================
# WHAT DECIDES A HALO'S BRIGHTNESS
# ==============================================================================

func densityFactor*(tuning: GlowTuning; uniforms: GlowUniforms;
    density: float): float =
  ## Colony density as a brightness multiplier (glow.wgsl:148-149): a dense
  ## neighbourhood glows, a sparse one keeps a floor so a lone particle stays
  ## visible.
  let measured = clamp(density * tuning.densityScale, tuning.densityMin,
    tuning.densityMax)
  max(measured, uniforms.glowDensityFloor)

func velocityFactor*(tuning: GlowTuning; uniforms: GlowUniforms;
    velocityNorm: float): float =
  ## Speed as a brightness multiplier (glow.wgsl:164-165). The log curve gives
  ## slow particles room; the glowIntensity inside the coupling term is what
  ## makes a moving particle's alpha grow as intensity squared.
  let logVelocity = ln(1.0 + velocityNorm * tuning.velocityLogScale) /
    ln(1.0 + tuning.velocityLogScale)
  tuning.velocityBase + logVelocity *
    (1.0 - tuning.velocityBase +
      uniforms.velocityGlowScale * uniforms.glowIntensity)

func haloAlpha*(tuning: GlowTuning; uniforms: GlowUniforms;
    offsetLength, velocityNorm, density: float): float =
  ## The halo's alpha at a point `offsetLength` from its centre, in units of
  ## the halo radius (glow.wgsl:169-170). Unbounded above: the additive blend
  ## takes whatever this returns, and the display is what stops answering.
  let gauss = exp(-uniforms.glowFalloff * offsetLength * offsetLength)
  gauss * circleMask(offsetLength) * uniforms.glowIntensity *
    densityFactor(tuning, uniforms, density) *
    velocityFactor(tuning, uniforms, velocityNorm) / tuning.divisor

func haloWarmth*(tuning: GlowTuning; uniforms: GlowUniforms;
    density: float): float =
  ## How far the halo shifts warm (glow.wgsl:176). Density drives it and the
  ## glowWarmth slider ceilings it, since the density factor cannot exceed
  ## tuning.densityMax.
  densityFactor(tuning, uniforms, density) * uniforms.glowWarmth

func warmShift*(tuning: GlowTuning; warmth: float): tuple[r, g, b: float] =
  ## The per-channel multiplier a warm shift applies (glow.wgsl:177). Warmth
  ## takes green and blue away and never adds; red passes untouched.
  (r: 1.0,
   g: 1.0 - warmth * tuning.warmthGreen,
   b: 1.0 - warmth * tuning.warmthBlue)

# ==============================================================================
# THE PROBE OBSERVABLE
# ==============================================================================

func haloAlphaIntegral(tuning: GlowTuning; uniforms: GlowUniforms;
    velocityNorm, density, alphaCeiling: float; samples: int): float =
  ## Alpha summed over the halo's screen footprint, in pixels squared. The
  ## substitution r = l * radius turns the disc integral into
  ## 2*pi*radius^2 * integral(alpha(l) * l, l = 0..1), evaluated by midpoint
  ## rule. `alphaCeiling` is what a pixel can display; passing infinity leaves
  ## the sum unbounded.
  let radius = haloRadius(uniforms, velocityNorm)
  let step = 1.0 / samples.float
  var total = 0.0
  for index in 0 ..< samples:
    let offsetLength = (index.float + 0.5) * step
    let alpha = haloAlpha(tuning, uniforms, offsetLength, velocityNorm,
      density)
    total += min(alpha, alphaCeiling) * offsetLength * step
  2.0 * PI * radius * radius * total

func haloAlphaIntegralRaw*(tuning: GlowTuning; uniforms: GlowUniforms;
    velocityNorm, density: float;
    samples: int = HALO_INTEGRAL_SAMPLES): float =
  ## The halo's total alpha with no display ceiling. It rises without bound,
  ## which is why a probe reading it would report travel the screen never
  ## showed.
  haloAlphaIntegral(tuning, uniforms, velocityNorm, density, Inf, samples)

func haloAlphaIntegralClamped*(tuning: GlowTuning; uniforms: GlowUniforms;
    velocityNorm, density: float;
    samples: int = HALO_INTEGRAL_SAMPLES): float =
  ## The probe observable (design E1): the halo's total alpha as a display can
  ## show it. Bounded above by haloDiscArea, which it approaches once every
  ## pixel of the halo sits at the clamp.
  haloAlphaIntegral(tuning, uniforms, velocityNorm, density,
    DISPLAY_ALPHA_MAX, samples)
