# ==============================================================================
# PARTICLE GARDEN - PALETTE (Pure Color Generation)
# ==============================================================================
#
# Pure functions for generating species color palettes. No side effects, no
# JS/FFI dependencies: compiles native (nimble test) and JS (config.nim's
# frontend build) identically.
#
# Used by:
#   - config.nim to initialize COLORS (native build cannot reach config.nim
#     itself, since ConfigObject uses jsffi, but palette.nim has no such
#     restriction and is exercised directly by tests/test_palette.nim)
#   - tests/test_palette.nim (native test compilation)
#
# This module is the serialization contract for palettes: presets (B2) store
# a generated or edited palette by its RGB tuples, so the shape returned here
# (seq[tuple[r, g, b: float]]) is load-bearing beyond config.nim.
#
# ==============================================================================

import std/math

# ==============================================================================
# SECTION 1: TYPES
# ==============================================================================

type
  PaletteScheme* = enum
    ## Named hue-generation strategies for generatePalette.
    psGolden    ## Default. Hues advance by the golden-ratio conjugate each
                ## step, which spreads any number of colors around the wheel
                ## without the exact repeats a low-denominator fraction (e.g.
                ## dividing by 3, 4, 6) produces when count changes.
    psSpectrum  ## Hues evenly spaced across the full 360-degree wheel.
    psWarm      ## Hues confined to magenta-red-orange-yellow.
    psCool      ## Hues confined to green-cyan-blue-violet.

# ==============================================================================
# SECTION 2: CONSTANTS
# ==============================================================================

const
  GOLDEN_RATIO_CONJUGATE* = 0.6180339887498949
    ## 1/phi. Successive hue steps of this fraction, taken mod 1, land
    ## maximally far from every previously placed hue (see the classic
    ## "golden angle" color-spacing technique).

  DEFAULT_SATURATION* = 0.70
  DEFAULT_LIGHTNESS* = 0.55
    ## Fixed S/L for generated palettes: vivid enough to read clearly against
    ## the dark canvas background without clipping to pure primaries at
    ## extreme hues the way S=1.0 would.

  WARM_HUE_START* = -1.0 / 12.0   # -30 deg
  WARM_HUE_SPREAD* = 1.0 / 3.0    # 120 deg: covers magenta(-30) through yellow(90)
  COOL_HUE_START* = 5.0 / 12.0    # 150 deg
  COOL_HUE_SPREAD* = 1.0 / 3.0    # 120 deg: covers green(150) through violet(270)
    ## Warm and cool are symmetric 120-degree arcs on opposite sides of the
    ## wheel; together they cover 240 of 360 degrees and never overlap.

# ==============================================================================
# SECTION 3: HSL -> RGB CONVERSION
# ==============================================================================

func hslToRgb*(h, s, l: float): tuple[r, g, b: float] =
  ## Convert an HSL color to RGB.
  ##
  ## h - Hue as a fraction of the wheel, any real value (wrapped into [0, 1);
  ##     0 = red, 1/3 = green, 2/3 = blue)
  ## s - Saturation in [0, 1] (0 = gray, 1 = fully saturated)
  ## l - Lightness in [0, 1] (0 = black, 1 = white)
  ##
  ## Returns (r, g, b), each in [0, 1].
  var hue = h - floor(h)  # wrap into [0, 1)

  if s <= 0.0:
    return (r: l, g: l, b: l)

  let q = if l < 0.5: l * (1.0 + s) else: l + s - l * s
  let p = 2.0 * l - q

  func hueToChannel(p, q, tIn: float): float =
    var t = tIn
    if t < 0.0: t += 1.0
    if t > 1.0: t -= 1.0
    if t < 1.0 / 6.0: return p + (q - p) * 6.0 * t
    if t < 1.0 / 2.0: return q
    if t < 2.0 / 3.0: return p + (q - p) * (2.0 / 3.0 - t) * 6.0
    return p

  result = (
    r: hueToChannel(p, q, hue + 1.0 / 3.0),
    g: hueToChannel(p, q, hue),
    b: hueToChannel(p, q, hue - 1.0 / 3.0)
  )

# ==============================================================================
# SECTION 4: HUE SEQUENCES PER SCHEME
# ==============================================================================

func hueRangeFor(scheme: PaletteScheme): tuple[start, spread: float] =
  ## Starting hue and angular spread (both as wheel fractions) for a bounded
  ## scheme. Only meaningful for psWarm/psCool; psGolden and psSpectrum
  ## generate their own hue sequences directly in generatePalette.
  case scheme
  of psWarm: (start: WARM_HUE_START, spread: WARM_HUE_SPREAD)
  of psCool: (start: COOL_HUE_START, spread: COOL_HUE_SPREAD)
  of psGolden, psSpectrum: (start: 0.0, spread: 1.0)

func hueAt(scheme: PaletteScheme, index, count: int): float =
  ## The hue (wheel fraction) for the color at `index` of `count` under `scheme`.
  case scheme
  of psGolden:
    result = (index.float * GOLDEN_RATIO_CONJUGATE)
    result -= floor(result)
  of psSpectrum:
    result = index.float / count.float
  of psWarm, psCool:
    let (start, spread) = hueRangeFor(scheme)
    # Single color: place it at the arc's start rather than dividing by zero.
    let t = if count <= 1: 0.0 else: index.float / (count - 1).float
    result = start + t * spread
    result -= floor(result)

# ==============================================================================
# SECTION 5: PALETTE GENERATION
# ==============================================================================

func generatePalette*(count: int, scheme: PaletteScheme = psGolden;
    saturation: float = DEFAULT_SATURATION,
    lightness: float = DEFAULT_LIGHTNESS): seq[tuple[r, g, b: float]] =
  ## Generate `count` species colors as RGB tuples, each channel in [0, 1].
  ##
  ## count - Number of colors to generate. count <= 0 returns an empty seq.
  ## scheme - Hue-generation strategy (default psGolden; see PaletteScheme).
  ## saturation, lightness - Fixed HSL saturation/lightness shared by every
  ##   generated color; only hue varies across the palette.
  if count <= 0:
    return @[]

  result = newSeq[tuple[r, g, b: float]](count)
  for i in 0 ..< count:
    let hue = hueAt(scheme, i, count)
    result[i] = hslToRgb(hue, saturation, lightness)

# ==============================================================================
# SECTION 6: FLAT ENCODING (for Float32Array / GPU buffers)
# ==============================================================================

func flattenPalette*(palette: seq[tuple[r, g, b: float]]): seq[float] =
  ## Interleave a palette's RGB tuples into a flat [r0, g0, b0, r1, g1, b1, ...]
  ## sequence — the layout config.COLORS (and the GPU-facing Float32Array it
  ## backs) expects.
  result = newSeq[float](palette.len * 3)
  for i, c in palette:
    result[i * 3 + 0] = c.r
    result[i * 3 + 1] = c.g
    result[i * 3 + 2] = c.b
