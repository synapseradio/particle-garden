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
# (seq[tuple[red, green, blue: float]]) is load-bearing beyond config.nim.
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
    psOpenColor ## Fixed bright swatches from the Open Color palette
                ## (https://yeun.github.io/open-color/); saturation and
                ## lightness arguments are inert for this scheme.

  RgbColor* = tuple[red, green, blue: float]
    ## One color as RGB channels, each in [0, 1]. The palette serialization
    ## contract: presets store palettes in this shape.

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

func rgbFrom8Bit(red8, green8, blue8: int): RgbColor =
  ## An RGB tuple from 8-bit channel values, e.g. a hex swatch's bytes.
  (red: red8.float / 255.0, green: green8.float / 255.0, blue: blue8.float / 255.0)

const OPEN_COLOR_SWATCHES*: array[6, RgbColor] = [
  ## Bright picks from the Open Color palette, verified against the canonical
  ## open-color.json, ordered to keep the classic species identities
  ## (red, green, blue, yellow, magenta-slot, cyan).
  rgbFrom8Bit(0xff, 0x6b, 0x6b),  # red-5
  rgbFrom8Bit(0x51, 0xcf, 0x66),  # green-5
  rgbFrom8Bit(0x33, 0x9a, 0xf0),  # blue-5
  rgbFrom8Bit(0xff, 0xd4, 0x3b),  # yellow-4
  rgbFrom8Bit(0xcc, 0x5d, 0xe8),  # grape-5
  rgbFrom8Bit(0x3b, 0xc9, 0xdb),  # cyan-4
]

# ==============================================================================
# SECTION 3: HSL -> RGB CONVERSION
# ==============================================================================

func hslToRgb*(hue, saturation, lightness: float): RgbColor =
  ## Convert an HSL color to RGB.
  ##
  ## hue - Fraction of the wheel, any real value (wrapped into [0, 1);
  ##       0 = red, 1/3 = green, 2/3 = blue)
  ## saturation - In [0, 1] (0 = gray, 1 = fully saturated)
  ## lightness - In [0, 1] (0 = black, 1 = white)
  ##
  ## Returns (red, green, blue), each in [0, 1].
  let wrappedHue = hue - floor(hue)  # wrap into [0, 1)

  if saturation <= 0.0:
    return (red: lightness, green: lightness, blue: lightness)

  let chromaHigh =
    if lightness < 0.5: lightness * (1.0 + saturation)
    else: lightness + saturation - lightness * saturation
  let chromaLow = 2.0 * lightness - chromaHigh

  func hueToChannel(chromaLow, chromaHigh, rawHue: float): float =
    var channelHue = rawHue
    if channelHue < 0.0: channelHue += 1.0
    if channelHue > 1.0: channelHue -= 1.0
    if channelHue < 1.0 / 6.0:
      return chromaLow + (chromaHigh - chromaLow) * 6.0 * channelHue
    if channelHue < 1.0 / 2.0:
      return chromaHigh
    if channelHue < 2.0 / 3.0:
      return chromaLow + (chromaHigh - chromaLow) * (2.0 / 3.0 - channelHue) * 6.0
    return chromaLow

  result = (
    red: hueToChannel(chromaLow, chromaHigh, wrappedHue + 1.0 / 3.0),
    green: hueToChannel(chromaLow, chromaHigh, wrappedHue),
    blue: hueToChannel(chromaLow, chromaHigh, wrappedHue - 1.0 / 3.0)
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
  of psGolden, psSpectrum, psOpenColor: (start: 0.0, spread: 1.0)

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
    let arcPosition = if count <= 1: 0.0 else: index.float / (count - 1).float
    result = start + arcPosition * spread
    result -= floor(result)
  of psOpenColor:
    # Fixed swatches, not hue-generated; generatePalette never consults
    # hueAt for this scheme. Guarded here so a future call path fails loudly.
    raise newException(ValueError, "psOpenColor has no hue sequence")

# ==============================================================================
# SECTION 5: PALETTE GENERATION
# ==============================================================================

func generatePalette*(count: int, scheme: PaletteScheme = psGolden;
    saturation: float = DEFAULT_SATURATION,
    lightness: float = DEFAULT_LIGHTNESS): seq[RgbColor] =
  ## Generate `count` species colors as RGB tuples, each channel in [0, 1].
  ##
  ## count - Number of colors to generate. count <= 0 returns an empty seq.
  ## scheme - Hue-generation strategy (default psGolden; see PaletteScheme).
  ## saturation, lightness - Fixed HSL saturation/lightness shared by every
  ##   generated color; only hue varies across the palette.
  if count <= 0:
    return @[]

  result = newSeq[RgbColor](count)
  if scheme == psOpenColor:
    # Fixed swatch picks: truncate below six, wrap above. Saturation and
    # lightness are inert (documented on the enum).
    for colorIndex in 0 ..< count:
      result[colorIndex] = OPEN_COLOR_SWATCHES[colorIndex mod OPEN_COLOR_SWATCHES.len]
    return

  for colorIndex in 0 ..< count:
    let hue = hueAt(scheme, colorIndex, count)
    result[colorIndex] = hslToRgb(hue, saturation, lightness)

# ==============================================================================
# SECTION 6: FLAT ENCODING (for Float32Array / GPU buffers)
# ==============================================================================

func flattenPalette*(palette: seq[RgbColor]): seq[float] =
  ## Interleave a palette's RGB tuples into a flat [r0, g0, b0, r1, g1, b1, ...]
  ## sequence — the layout config.COLORS (and the GPU-facing Float32Array it
  ## backs) expects.
  result = newSeq[float](palette.len * 3)
  for colorIndex, color in palette:
    result[colorIndex * 3 + 0] = color.red
    result[colorIndex * 3 + 1] = color.green
    result[colorIndex * 3 + 2] = color.blue
