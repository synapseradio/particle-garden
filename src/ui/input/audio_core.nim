# ==============================================================================
# PARTICLE GARDEN - AUDIO FEATURE CORE
# ==============================================================================
#
# From two analyser arrays to six bounded features, every constant here. Pure:
# no FFI, no DOM, compiled on both backends and exercised natively by
# tests/test_audio_core.nim. The wiring (src/audio_input.nim) polls, copies and
# calls; nothing outside this file computes a feature.
#
# ==============================================================================

import std/math

const ANALYSER_FFT_SIZE* = 2048
  ## At 48000 Hz: 23.4 Hz bins, a 42.7 ms window. 4096 smears a transient
  ## across five rendered frames; 1024 leaves the bass band five bins wide.
const ANALYSER_SMOOTHING* = 0.0
  ## The browser averages nothing, so every conditioning step lives here where
  ## a native test reaches it.
const FREQUENCY_BIN_COUNT* = ANALYSER_FFT_SIZE div 2

const
  BAND_LOW_HZ* = 20.0
    ## Below this is rumble a room always carries and no instrument plays.
  BASS_MID_HZ* = 250.0
    ## Roughly the top of a voice's fundamental range.
  MID_HIGH_HZ* = 2000.0
    ## Roughly the bottom of the presence region.
  BAND_HIGH_HZ* = 8000.0
    ## Above this a consumer microphone reports mostly its own hiss.
  BRIGHTNESS_LOW_HZ* = 200.0
  BRIGHTNESS_HIGH_HZ* = 8000.0
    ## The centroid's logarithmic mapping onto [0, 1]. A centroid under 200 Hz
    ## is already as dark as the feature reads.
  ONSET_REFRACTORY_SECONDS* = 0.1
    ## After a firing, no further onset however the flux moves: two drum hits
    ## closer than this are one gesture, and one hit smeared across the 42.7 ms
    ## analysis window must not fire twice.
  SILENCE_SECONDS* = 3.0
    ## Loudness at the bottom of its window this long reports silence, the span
    ## that separates a pause in the room from a capture that stopped working.

const
  LEVEL_FLOOR_DB = -120.0
    ## The decibel value a magnitude of exactly zero takes, and the bottom every
    ## window starts at. The analyser's own default `minDecibels` is -100, so no
    ## captured frame sits here; clamping to it keeps one denormal frame from
    ## opening a window hundreds of decibels wide.
  MIN_WINDOW_DB = 12.0
    ## The narrowest window a feature is read against, so silence divides by
    ## nothing. It is also the swing a level must have to reach full scale.
  FLOOR_RISE_SECONDS = 2.0
    ## Time constant of the floor's climb toward a level above it. It falls
    ## instantly instead, so the floor is the recent quiet rather than an
    ## average.
  CEILING_DECAY_SECONDS = 3.0
    ## Time constant of the ceiling's fall toward a level below it. Slower than
    ## the floor's climb, which is what bounds the pumping a dynamic passage
    ## would otherwise show.
  BRIGHTNESS_FLOOR_MAGNITUDE = 1e-5
    ## Mean linear magnitude across 20 to 8000 Hz under which the centroid is
    ## the noise floor's own shape. 1e-5 is -100 dB, the analyser's default
    ## `minDecibels`.
  BRIGHTNESS_DECAY_SECONDS = 0.5
    ## How fast brightness falls toward zero while the centroid is undefined.
  FLUX_MEDIAN_SECONDS = 0.25
    ## The median tracker's step covers this fraction of its own value per
    ## second, so it follows the flux at any input gain. A sign-following step
    ## settles where half the frames sit above it, which is the median.
  FLUX_MEDIAN_FLOOR = 1e-9
    ## A flux sum under this is float noise rather than a transient. It also
    ## keeps the threshold and the energy division defined before any flux has
    ## been seen.
  ONSET_THRESHOLD_RATIO = 2.0
    ## Flux must double the running median to fire.
  ONSET_FULL_SCALE = 4.0
    ## Flux at four times the firing threshold carries full energy.
  SILENCE_LOUDNESS = 0.02
    ## Loudness at or under this counts as the bottom of its window. The floor
    ## falls instantly, so a room with nothing in it settles here in a frame.

type
  LevelWindow = object
    ## One normalized feature's adaptive window, in decibels.
    floorDb: float
    ceilingDb: float

  FeatureBand = enum
    ## The three band features, and the order their windows are held in.
    fbBass
    fbMid
    fbHigh

  ListenState* = enum
    ## The affordance's five states; `$state` is the name the panel renders.
    lsDisconnected = "Disconnected"
    lsRequesting = "Requesting"
    lsConnected = "Connected"
    lsDenied = "Denied"
    lsSilent = "Silent"

  AudioFrame* = object
    bins*: seq[float32]
      ## FREQUENCY_BIN_COUNT decibel values, negative infinity where silent.
    samples*: seq[float32]
      ## ANALYSER_FFT_SIZE time-domain samples in [-1, 1].
    sampleRate*: float
    dtSeconds*: float
      ## The frame's wall-clock delta; every time constant is honored against it.

  Onset* = object
    case fired*: bool
    of true:
      energy*: float
        ## In [0, 1].
    of false:
      discard

  AudioFeatures* = object
    loudness*: float
    bass*: float
    mid*: float
    high*: float
    brightness*: float
      ## Each in [0, 1], finite for any finite input.
    onset*: Onset
    silent*: bool
      ## Loudness has sat at its floor for the silence window.

  AnalysisState* = object
    ## Everything one frame carries into the next. Nothing here is read outside
    ## this module: the features are the whole boundary.
    previousMagnitudes: seq[float32]
      ## Last frame's linear magnitudes, which the flux differences against.
    hasPrevious: bool
      ## The first frame has no predecessor, so its flux is zero.
    loudnessWindow: LevelWindow
    bandWindows: array[FeatureBand, LevelWindow]
    brightness: float
      ## Carried across frames only so it can decay while the centroid is
      ## undefined; a sounding frame overwrites it outright.
    fluxMedian: float
    fluxSeeded: bool
    refractorySeconds: float
    silenceSeconds: float

func initLevelWindow(): LevelWindow =
  LevelWindow(floorDb: LEVEL_FLOOR_DB, ceilingDb: LEVEL_FLOOR_DB)

func initAnalysisState*(): AnalysisState =
  AnalysisState(
    loudnessWindow: initLevelWindow(),
    bandWindows: [fbBass: initLevelWindow(), fbMid: initLevelWindow(),
                  fbHigh: initLevelWindow()])

func isFiniteValue(value: float): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

func magnitudeOf(decibels: float32): float =
  ## A bin at negative infinity is silence, and NaN names no level either.
  let level = decibels.float
  if isFiniteValue(level): pow(10.0, level / 20.0) else: 0.0

func decibelsOf(magnitude: float): float =
  ## Zero magnitude has no decibel value, and anything under the floor reads as
  ## the floor.
  if magnitude > 0.0 and isFiniteValue(magnitude):
    max(20.0 * log10(magnitude), LEVEL_FLOOR_DB)
  else:
    LEVEL_FLOOR_DB

func approach(value, target, seconds, dtSeconds: float): float =
  ## Exponential approach at a wall-clock time constant: the same elapsed span
  ## covers the same fraction of the gap however the frame delta moves.
  target + (value - target) * exp(-dtSeconds / seconds)

func track(window: var LevelWindow; levelDb, dtSeconds: float): float =
  ## The level's clamped position inside its own window. The floor rises slowly
  ## and falls instantly; the ceiling rises instantly and decays slowly.
  if levelDb < window.floorDb:
    window.floorDb = levelDb
  else:
    window.floorDb = approach(window.floorDb, levelDb, FLOOR_RISE_SECONDS,
      dtSeconds)
  if levelDb > window.ceilingDb:
    window.ceilingDb = levelDb
  else:
    window.ceilingDb = approach(window.ceilingDb, levelDb,
      CEILING_DECAY_SECONDS, dtSeconds)
  clamp((levelDb - window.floorDb) /
    max(window.ceilingDb - window.floorDb, MIN_WINDOW_DB), 0.0, 1.0)

func bandOf(hz: float): FeatureBand =
  if hz < BASS_MID_HZ: fbBass
  elif hz < MID_HIGH_HZ: fbMid
  else: fbHigh

func analyse*(state: var AnalysisState; frame: AudioFrame): AudioFeatures =
  ## One frame's six features, and the state the next frame needs.
  let dt = max(frame.dtSeconds, 0.0)
  let binCount = frame.bins.len
  if state.previousMagnitudes.len != binCount:
    state.previousMagnitudes = newSeq[float32](binCount)
    state.hasPrevious = false
  let binWidthHz =
    if binCount > 0: frame.sampleRate / (2.0 * binCount.float) else: 0.0

  var bandSums: array[FeatureBand, float]
  var bandCounts: array[FeatureBand, int]
  var centroidWeighted = 0.0
  var centroidTotal = 0.0
  var centroidCount = 0
  var flux = 0.0
  for index in 0 ..< binCount:
    let magnitude = magnitudeOf(frame.bins[index])
    if state.hasPrevious:
      let increase = magnitude - state.previousMagnitudes[index].float
      if increase > 0.0:
        flux += increase
    state.previousMagnitudes[index] = magnitude.float32
    # The three bands tile 20 to 8000 Hz, which is also the centroid's range,
    # so one pass over the bins serves the bands and brightness both.
    let hz = index.float * binWidthHz
    if hz >= BAND_LOW_HZ and hz < BAND_HIGH_HZ:
      centroidWeighted += hz * magnitude
      centroidTotal += magnitude
      inc centroidCount
      let band = bandOf(hz)
      bandSums[band] += magnitude
      inc bandCounts[band]
  state.hasPrevious = true

  var square = 0.0
  for sample in frame.samples:
    square += sample.float * sample.float
  let rms =
    if frame.samples.len > 0: sqrt(square / frame.samples.len.float) else: 0.0

  result.loudness = track(state.loudnessWindow, decibelsOf(rms), dt)
  for band in FeatureBand:
    let mean =
      if bandCounts[band] > 0: bandSums[band] / bandCounts[band].float else: 0.0
    let value = track(state.bandWindows[band], decibelsOf(mean), dt)
    case band
    of fbBass: result.bass = value
    of fbMid: result.mid = value
    of fbHigh: result.high = value

  let centroidMean =
    if centroidCount > 0: centroidTotal / centroidCount.float else: 0.0
  if centroidMean >= BRIGHTNESS_FLOOR_MAGNITUDE:
    let centroidHz = centroidWeighted / centroidTotal
    state.brightness = clamp(ln(centroidHz / BRIGHTNESS_LOW_HZ) /
      ln(BRIGHTNESS_HIGH_HZ / BRIGHTNESS_LOW_HZ), 0.0, 1.0)
  else:
    state.brightness *= exp(-dt / BRIGHTNESS_DECAY_SECONDS)
  result.brightness = state.brightness

  state.refractorySeconds = max(state.refractorySeconds - dt, 0.0)
  let threshold = ONSET_THRESHOLD_RATIO * max(state.fluxMedian,
    FLUX_MEDIAN_FLOOR)
  if flux > threshold and state.refractorySeconds <= 0.0:
    state.refractorySeconds = ONSET_REFRACTORY_SECONDS
    result.onset = Onset(fired: true,
      energy: clamp(flux / (threshold * ONSET_FULL_SCALE), 0.0, 1.0))
  else:
    result.onset = Onset(fired: false)
  if state.fluxSeeded:
    let step = dt / FLUX_MEDIAN_SECONDS *
      max(state.fluxMedian, FLUX_MEDIAN_FLOOR)
    if flux > state.fluxMedian:
      state.fluxMedian += step
    elif flux < state.fluxMedian:
      state.fluxMedian = max(state.fluxMedian - step, 0.0)
  elif flux > 0.0:
    # The first flux seen sets the tracker's scale, so it starts at the
    # signal's own level instead of climbing to it from zero.
    state.fluxMedian = flux
    state.fluxSeeded = true

  state.silenceSeconds =
    if result.loudness <= SILENCE_LOUDNESS:
      min(state.silenceSeconds + dt, SILENCE_SECONDS)
    else:
      0.0
  result.silent = state.silenceSeconds >= SILENCE_SECONDS
