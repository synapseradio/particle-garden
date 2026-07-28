# ==============================================================================
# RENDER STATE - Visual rendering parameters
# ==============================================================================
#
# The typed record for every visual-side tunable: the eight ConfigObject
# fields the render/glow pipeline reads. ui.nim holds this in an Observable
# and mirrors each change synchronously into the flat CONFIG the hot paths
# consume; config.nim's createConfig copies these defaults, so the values
# below are the single authoritative defaults.
#
# Pure module: compiles on both the native (nimble test) and JS backends.
#
# ==============================================================================

import ../../bloom_core
import ../../colormap_core

type
  RenderState* = object
    ## Visual rendering parameters.
    ## Pure immutable data - updates go through a copied var and re-set.
    particleSize*: int
    trails*: bool
    trailLength*: float       ## 0-100 particle diameters (0 = no trails)
    glowIntensity*: float
    velocityGlowScale*: float
    glowRadiusScale*: float   ## Glow halo radius = (particleSize+1) * this
    glowFalloff*: float       ## Gaussian falloff exponent (higher = tighter)
    glowWarmth*: float        ## Density-driven warm shift, [0,1]
    # HDR bloom + colour grade (S9). bloomEnabled gates the whole bloom path;
    # off is the exact non-bloom quality floor. The rest drive the tonemap.
    bloomEnabled*: bool
    bloomIntensity*: float    ## Gain on the blurred bloom in the composite
    exposure*: float          ## HDR exposure before the ACES tonemap
    saturation*: float        ## Grade: 1 = unchanged, 0 = greyscale
    contrast*: float          ## Grade: 1 = unchanged, around a 0.5 pivot
    temperature*: float       ## Grade: signed warm/cool tint, 0 = neutral
    # Reaction-diffusion field visualization (S10). colormapIndex selects the
    # procedural ramp; fieldOpacity scales the field's contribution. Read by
    # both the HDR tonemap and the bloom-off field-composite floor.
    colormapIndex*: int
    fieldOpacity*: float

const TRAIL_LENGTH_WHEN_ENABLED* = 25.0
  ## The length the Trails toggle lifts a zero-length trail to.
  ##
  ## Trails are two controls over one effect: a boolean that decides whether the
  ## fade pass runs at all, and a length that decides how much of the previous
  ## frame it keeps. At length 0 the fade pass retains nothing, so the toggle
  ## switches on a pass that clears — a control that visibly does nothing, which
  ## is how it read to the user.
  ##
  ## 25 diameters decays the trail to 5% over roughly 50 frames, a little under
  ## a second at 60fps. Long enough to read as motion, short enough that the
  ## screen does not turn into a smear.

func withTrails*(state: RenderState, enabled: bool): RenderState =
  ## The render state with trails switched on or off.
  ##
  ## Enabling lifts a zero length so the toggle always produces trails; it never
  ## overwrites a length the user chose. Disabling leaves the length alone, so
  ## toggling off and back on returns the trail the user last had rather than
  ## the default.
  result = state
  result.trails = enabled
  if enabled and state.trailLength <= 0.0:
    result.trailLength = TRAIL_LENGTH_WHEN_ENABLED

func initRenderState*(): RenderState =
  ## The authoritative render defaults (copied into CONFIG by createConfig).
  ## (particleSize + 1) * glowRadiusScale must stay 12.0 to reproduce the
  ## radius glow.wgsl hard-coded before the knobs existed (pinned by
  ## tests/test_sim_config.nim). The bloom defaults come from bloom_core, the
  ## same pure leaf config_ranges static-asserts them against.
  RenderState(
    particleSize: 3,
    trails: false,
    trailLength: 0.0,
    glowIntensity: 0.8,      # Subtle glow
    velocityGlowScale: 1.0,  # Full velocity-to-glow influence
    glowRadiusScale: 3.0,
    glowFalloff: 6.0,
    glowWarmth: 0.4,
    bloomEnabled: BLOOM_DEFAULT_ENABLED,
    bloomIntensity: BLOOM_DEFAULT_INTENSITY,
    exposure: BLOOM_DEFAULT_EXPOSURE,
    saturation: BLOOM_DEFAULT_SATURATION,
    contrast: BLOOM_DEFAULT_CONTRAST,
    temperature: BLOOM_DEFAULT_TEMPERATURE,
    colormapIndex: COLORMAP_DEFAULT_INDEX,
    fieldOpacity: FIELD_OPACITY_DEFAULT
  )
