# The single native-tested source for the reaction-diffusion field colormaps
# and their defaults. Pure (no FFI, no DOM): compiles on both the native
# (nimble test) and JS backends.
#
# Two consumers, mirroring the bloom_core / field_core precedent:
#   - shader_config.nim substitutes the polynomial coefficients (and the
#     two-tone constants and field-scalar gain) into web/shaders/modules/
#     colormap.wgsl as {{COLORMAP_*}} placeholders. The ramp coefficients live
#     HERE, in Nim, so the ramp shape is natively testable rather than
#     hand-written in WGSL — and there is one authority for the numbers, never
#     a Nim copy drifting from a WGSL copy.
#   - ui/state/render_state.nim and config_ranges.nim read the COLORMAP_DEFAULT_*
#     / FIELD_OPACITY_* constants below, the same way they read bloom_core's
#     BLOOM_DEFAULT_* and field_core's RD_DEFAULT_*.
#
# THE RAMPS:
#   0 inferno  — matplotlib's perceptually-uniform black->red->yellow ramp,
#   1 viridis  — matplotlib's perceptually-uniform purple->teal->yellow ramp.
#     Both are the widely-mirrored 6th-order polynomial fits of the matplotlib
#     tables (Matt Zucker's approximations; the exact coefficients here were
#     transcribed from the rerun.io re_renderer WGSL implementation and
#     cross-checked against the Shadertoy 3lBXR3 viridis fit). A single scalar
#     drives them, derived from the field's inhibitor channel (see
#     fieldScalar).
#   2 two-tone — an original complementary ramp that reads the activator and
#     inhibitor channels DISTINCTLY: inhibitor (the pattern) glows warm amber,
#     activator (the substrate) tints a dim cool azure. Not a single-scalar
#     ramp; it consumes both channels.

import std/strutils

const
  COLORMAP_COUNT* = 3
    ## Number of selectable colormaps. colormapIndex is clamped to
    ## [0, COLORMAP_COUNT-1] by config_ranges.nim and preset.nim.
  COLORMAP_INDEX_INFERNO* = 0
  COLORMAP_INDEX_VIRIDIS* = 1
  COLORMAP_INDEX_TWO_TONE* = 2

  COLORMAP_DEFAULT_INDEX* = COLORMAP_INDEX_INFERNO
    ## The field's default colormap.

  FIELD_OPACITY_DEFAULT* = 0.0
    ## Default scale on the field's contribution AS A BACKDROP — the fullscreen
    ## layer field-composite.wgsl and the tonemap draw under the particles.
    ## 0.0 draws no backdrop at all; 1.0 draws it at full strength.
    ##
    ## THE FIELD SHOWS ITSELF THROUGH THE PARTICLES BY DEFAULT. Drawn as a
    ## backdrop the pattern owns whole regions of the frame, and colonies,
    ## trails and species colour have to compete with it for the same pixels.
    ## Lighting the particles instead (FIELD_LIGHT_STRENGTH, applied in
    ## render.wgsl and independent of this) says exactly the same thing — where
    ## the chemistry is, and how strong — without claiming any space of its own.
    ##
    ## The backdrop stays a slider rather than being deleted: it is the only way
    ## to see the field where no particles stand, which is what makes it worth
    ## keeping and worth leaving off.
  FIELD_OPACITY_MIN* = 0.0
  FIELD_OPACITY_MAX* = 1.0

  FIELD_LIGHT_STRENGTH* = 0.55
    ## How far a particle's colour is pulled toward the field's colour where the
    ## field is at full intensity — the "field as light" coupling, applied in
    ## render.wgsl's vertex stage. 0 leaves species colours untouched, 1 replaces
    ## them entirely with the colormapped field.
    ##
    ## Independent of FIELD_OPACITY_DEFAULT by design: the backdrop and the tint
    ## are two different ways to show one field. The pull is already
    ## proportional to the field's local intensity, so a particle standing
    ## where no pattern is keeps its species colour exactly — the tint needs no
    ## second gate.
    ##
    ## BLIND VISUAL PICK, deliberately below half-and-half so species stay
    ## tellable apart inside a bright pattern; the calibration pass owns the
    ## final value.

  FIELD_DRIFT_SCALE* = 0.02
    ## How far the fade pass displaces its trail sample along the field
    ## gradient, in UV units per unit of gradient. The inhibitor gradient runs
    ## to roughly 0.05 per cell in the spot regimes, so this is a shift of about
    ## a thousandth of the screen — one or two pixels at 1080p. BLIND VISUAL
    ## PICK, deliberately tiny: the effect wanted is trails bending around the
    ## pattern, and anything large enough to notice directly reads as a smear.
    ## The calibration pass owns the final value.

  COLORMAP_FIELD_GAIN* = 3.0
    ## Maps the field's inhibitor concentration (roughly [0, 0.4] in the
    ## Pearson spot/stripe regimes) onto the [0, 1] ramp parameter for the
    ## single-scalar ramps (inferno, viridis). BLIND VISUAL PICK: sets how
    ## quickly the pattern saturates the bright end of the ramp.

  # Two-tone ramp constants (this ramp is original to the project, so these ARE
  # the authority — no external source). BLIND VISUAL PICKS.
  TWO_TONE_WARM* = [1.0, 0.45, 0.15]
    ## Amber the inhibitor (pattern) channel drives.
  TWO_TONE_COOL* = [0.15, 0.55, 1.0]
    ## Azure the activator (substrate) channel tints.
  TWO_TONE_INHIBITOR_GAIN* = 3.0
    ## Gain on the inhibitor channel before it drives the warm tone.
  TWO_TONE_COOL_LEVEL* = 0.25
    ## Ceiling on the cool substrate tint, so the warm pattern stays dominant.

# 6th-order polynomial fits, one vec3 per Horner term (7 terms). Evaluated as
# c0 + t*(c1 + t*(c2 + ... + t*c6)). Source: rerun.io re_renderer
# shader/colormap.wgsl, itself Matt Zucker's matplotlib-colormap approximations.

type ColormapCoeffs* = array[7, array[3, float]]

const
  COLORMAP_POLY_TERMS* = 7
    ## Horner terms per channel — the WGSL array<vec3f, N> length.

  INFERNO_COEFFS*: ColormapCoeffs = [
    [0.0002189403691192265, 0.001651004631001012, -0.01948089843709184],
    [0.1065134194856116, 0.5639564367884091, 3.932712388889277],
    [11.60249308247187, -3.972853965665698, -15.9423941062914],
    [-41.70399613139459, 17.43639888205313, 44.35414519872813],
    [77.162935699427, -33.40235894210092, -81.80730925738993],
    [-71.31942824499214, 32.62606426397723, 73.20951985803202],
    [25.13112622477341, -12.24266895238567, -23.07032500287172],
  ]

  VIRIDIS_COEFFS*: ColormapCoeffs = [
    [0.2777273272234177, 0.005407344544966578, 0.3340998053353061],
    [0.1050930431085774, 1.404613529898575, 1.384590162594685],
    [-0.3308618287255563, 0.214847559468213, 0.09509516302823659],
    [-4.634230498983486, -5.799100973351585, -19.33244095627987],
    [6.228269936347081, 14.17993336680509, 56.69055260068105],
    [4.776384997670288, -13.74514537774601, -65.35303263337234],
    [-5.435455855934631, 4.645852612178535, 26.3124352495832],
  ]

# ==============================================================================
# RAMP EVALUATION (mirrors web/shaders/modules/colormap.wgsl)
# ==============================================================================

func clamp01(value: float): float =
  max(0.0, min(1.0, value))

func evalPolyColormap*(coeffs: ColormapCoeffs, rampT: float): array[3, float] =
  ## Horner evaluation of the 7-term polynomial at `rampT`, clamped to [0,1]
  ## per channel (the fits overshoot slightly at the ends; the display is LDR).
  let clampedT = clamp01(rampT)
  var channels = coeffs[COLORMAP_POLY_TERMS - 1]
  for termIndex in countdown(COLORMAP_POLY_TERMS - 2, 0):
    for channel in 0 .. 2:
      channels[channel] = coeffs[termIndex][channel] + clampedT * channels[channel]
  [clamp01(channels[0]), clamp01(channels[1]), clamp01(channels[2])]

func evalInferno*(rampT: float): array[3, float] =
  evalPolyColormap(INFERNO_COEFFS, rampT)

func evalViridis*(rampT: float): array[3, float] =
  evalPolyColormap(VIRIDIS_COEFFS, rampT)

func fieldScalar*(inhibitor: float): float =
  ## The [0,1] ramp parameter the single-scalar ramps read, derived from the
  ## field's inhibitor (pattern) channel. Clamped so the ramp never samples
  ## outside its fit range.
  clamp01(inhibitor * COLORMAP_FIELD_GAIN)

func evalTwoTone*(activator, inhibitor: float): array[3, float] =
  ## The original complementary ramp: warm amber scaled by the inhibitor
  ## pattern, plus a dim cool azure tint scaled by the activator substrate.
  let warmT = clamp01(inhibitor * TWO_TONE_INHIBITOR_GAIN)
  let coolT = clamp01(activator) * TWO_TONE_COOL_LEVEL
  [clamp01(TWO_TONE_WARM[0] * warmT + TWO_TONE_COOL[0] * coolT),
   clamp01(TWO_TONE_WARM[1] * warmT + TWO_TONE_COOL[1] * coolT),
   clamp01(TWO_TONE_WARM[2] * warmT + TWO_TONE_COOL[2] * coolT)]

func evalColormap*(index: int, activator, inhibitor: float): array[3, float] =
  ## Dispatch on `index`, mirroring the WGSL applyColormap. An out-of-range
  ## index falls back to inferno, matching the shader's default arm.
  case index
  of COLORMAP_INDEX_VIRIDIS: evalViridis(fieldScalar(inhibitor))
  of COLORMAP_INDEX_TWO_TONE: evalTwoTone(activator, inhibitor)
  else: evalInferno(fieldScalar(inhibitor))

# How much of a pixel the field claims, which is what lets the field read as
# light rather than as a backdrop. Mirrored by colormapFieldIntensity /
# colormapFieldCoverage in web/shaders/modules/colormap.wgsl, and consumed by
# BOTH render paths — tonemap.wgsl when bloom is on, field-composite.wgsl when
# it is off. One function for both is what keeps those paths in parity.
#
# COVERAGE FOLLOWS INTENSITY, NOT THE RAMP'S LUMINANCE, and the difference is
# not cosmetic. A ramp's colour at zero field is a property of the ramp, not a
# statement that field is present: measured with the Rec.709 weights
# tonemap_grade.wgsl uses, `evalColormap(index, 0, 0)` has luminance 0.00123
# for inferno, 0.08703 for viridis, and 0.0 for two-tone. Luminance-driven
# coverage would therefore paint 7.4% viridis purple over a field that is
# EMPTY, and would let a display choice silently decide what is opaque.
# Intensity is exactly zero at zero field for all three ramps.

func fieldIntensity*(index: int, activator, inhibitor: float): float =
  ## How much field is PRESENT at this sample, in [0,1] — the scalar the ramp
  ## turns into a colour, read before it becomes one. The single-scalar ramps
  ## are driven by the inhibitor (the pattern) alone; two-tone also renders the
  ## activator substrate, so its intensity is whichever of the two channels
  ## claims the pixel more strongly.
  case index
  of COLORMAP_INDEX_TWO_TONE:
    max(clamp01(inhibitor * TWO_TONE_INHIBITOR_GAIN),
        clamp01(activator) * TWO_TONE_COOL_LEVEL)
  else: fieldScalar(inhibitor)

func fieldCoverage*(index: int, activator, inhibitor, fieldOpacity: float):
    float =
  ## The alpha the field contributes at this sample. Zero where no field is
  ## present, so empty field leaves the pixel to the particles and the clear;
  ## one where the field is fully present at full opacity. `fieldOpacity`
  ## scales coverage as well as brightness, so turning the field down fades it
  ## out rather than leaving an invisible-but-opaque sheet over the world — and
  ## an opacity of zero contributes nothing at all, which is what lets the
  ## backdrop paths guard the whole lookup behind `if (fieldOpacity > 0.0)`.
  ##
  ## Backdrop only: field-composite.wgsl and tonemap.wgsl. render.wgsl's
  ## particle tint answers to FIELD_LIGHT_STRENGTH instead and never reads this,
  ## so a backdrop turned off still leaves the particles lit by the field.
  clamp01(fieldIntensity(index, activator, inhibitor) * fieldOpacity)

# ==============================================================================
# WGSL EMISSION (feeds shader_config.nim -> colormap.wgsl placeholders)
# ==============================================================================

func wgslFloat(value: float): string =
  ## A round-trippable WGSL f32 literal. Nim's `$` on a float always carries a
  ## decimal point or exponent, so the value never types as abstract-int.
  $value

func wgslVec3*(triple: array[3, float]): string =
  ## A `vec3f(x, y, z)` literal with round-trippable f32 components. Exported so
  ## shader_config.nim can emit the two-tone constants from this one authority.
  "vec3f(" & wgslFloat(triple[0]) & ", " & wgslFloat(triple[1]) & ", " &
    wgslFloat(triple[2]) & ")"

func wgslScalar*(value: float): string =
  ## A round-trippable WGSL f32 literal for a scalar tunable. Exported for the
  ## same single-authority reason as wgslVec3.
  wgslFloat(value)

func colormapCoeffsWgsl*(coeffs: ColormapCoeffs): string =
  ## The 7 coefficient vec3s as a comma-separated list, ready to paste inside
  ## `array<vec3f, COLORMAP_POLY_TERMS>( ... )`.
  var parts: seq[string]
  for term in coeffs:
    parts.add wgslVec3(term)
  parts.join(",\n  ")
