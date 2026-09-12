#
# The audio feature core: two analyser arrays in, six bounded features out.
#
# Every expected value here comes from the feature definitions, never from the
# module's own arithmetic: 440 Hz's brightness is computed from the logarithmic
# mapping in this file, a band's bins are selected from the exported edges, and
# the refractory and silence windows are read in seconds off the wall clock the
# frame delta carries.
#
# Two properties carry the boundary the panel and the matrix sit behind: every
# feature is finite and inside [0, 1] for any finite input, and silence reads
# exactly zero. The fuzz sweep and the silence case are what hold them.
#

import std/[unittest, math, random]
import ../src/ui/input/audio_core

const AUDIO_CORE_TESTS_LOADED* = true

const
  TEST_SAMPLE_RATE = 48000.0
    ## Bin i sits at i * 48000 / 2048 = 23.4375 Hz, the analyser's own spacing
    ## at the window audio_core fixes.
  FRAME_60 = 1.0 / 60.0
  FRAME_120 = 1.0 / 120.0
    ## 16.7 ms and 8.33 ms: the two frame deltas every time constant must span
    ## the same wall-clock seconds across.
  QUIET_DB = -20.0
    ## An ordinary sounding bin. Any level above the core's floor serves; this
    ## one is far enough above it that a window has room to open.
  DITHER_DB = 6.0
  DITHER_HZ = 1.0
    ## A level held perfectly flat has no window at all — its floor and its
    ## ceiling both close on it — so the step case holds a level the way a
    ## microphone delivers one, moving a few decibels at a syllable's rate.

func binHz(index: int): float =
  index.float * TEST_SAMPLE_RATE / ANALYSER_FFT_SIZE.float

func amplitudeFor(db: float): float =
  pow(10.0, db / 20.0)

proc filledBins(db: float32): seq[float32] =
  result = newSeq[float32](FREQUENCY_BIN_COUNT)
  for index in 0 ..< result.len:
    result[index] = db

proc silentBins(): seq[float32] =
  filledBins(float32(NegInf))

proc bandBins(loHz, hiHz: float; db: float32): seq[float32] =
  result = silentBins()
  for index in 0 ..< result.len:
    let hz = binHz(index)
    if hz >= loHz and hz < hiHz:
      result[index] = db

proc frameOf(bins: seq[float32]; rms: float; dt: float;
             sampleRate = TEST_SAMPLE_RATE): AudioFrame =
  ## Samples alternate +rms/-rms, so the frame's RMS is exactly `rms` and the
  ## loudness level under test is 20*log10(rms) with nothing to approximate.
  var samples = newSeq[float32](ANALYSER_FFT_SIZE)
  for index in 0 ..< samples.len:
    samples[index] = float32(if index mod 2 == 0: rms else: -rms)
  AudioFrame(bins: bins, samples: samples, sampleRate: sampleRate,
             dtSeconds: dt)

proc soundingFrame(db: float; dt: float): AudioFrame =
  frameOf(filledBins(float32(db)), amplitudeFor(db), dt)

proc silentFrame(dt: float): AudioFrame =
  frameOf(silentBins(), 0.0, dt)

func finite(value: float): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

func bandFeature(features: AudioFeatures; band: int): float =
  case band
  of 0: features.bass
  of 1: features.mid
  else: features.high

template checkBounded(features: AudioFeatures) =
  for value in [features.loudness, features.bass, features.mid,
                features.high, features.brightness]:
    check finite(value)
    check value >= 0.0
    check value <= 1.0
  if features.onset.fired:
    check finite(features.onset.energy)
    check features.onset.energy >= 0.0
    check features.onset.energy <= 1.0

template checkInsideOpenRange(features: AudioFeatures) =
  for value in [features.loudness, features.bass, features.mid,
                features.high, features.brightness]:
    check value > 0.0
    check value < 1.0

template holdDithered(state, elapsed, features, levelDb, frames: untyped) =
  ## Frames of a level dithered around `levelDb`, advancing the shared clock.
  for _ in 0 ..< frames:
    let db = levelDb + DITHER_DB * sin(2.0 * PI * DITHER_HZ * elapsed)
    features = analyse(state, soundingFrame(db, FRAME_60))
    elapsed += FRAME_60

proc holdLevel(state: var AnalysisState; db: float;
               seconds, dt: float): AudioFeatures =
  ## The same wall-clock hold at any frame delta.
  result = AudioFeatures(onset: Onset(fired: false))
  var elapsed = 0.0
  while elapsed < seconds - dt * 0.5:
    result = analyse(state, soundingFrame(db, dt))
    elapsed += dt


suite "Audio Core Places A Spectrum On Its Features":
  test "brightness reports a tone's logarithmic position when one bin at 440 Hz sounds":
    # Expected from the mapping itself: ln(440/200) / ln(8000/200). The bin
    # nearest 440 Hz sits at 445.3 Hz, 0.003 of the mapping's span away, which
    # is what the tolerance leaves room for.
    let nearest = int(round(440.0 / binHz(1)))
    var bins = silentBins()
    bins[nearest] = float32(QUIET_DB)
    var state = initAnalysisState()
    let features = analyse(state,
      frameOf(bins, amplitudeFor(QUIET_DB), FRAME_60))
    let expected = ln(440.0 / BRIGHTNESS_LOW_HZ) /
      ln(BRIGHTNESS_HIGH_HZ / BRIGHTNESS_LOW_HZ)
    check abs(features.brightness - expected) <= 0.02
    check features.bass <= 0.01
    check features.high <= 0.01

  test "each band feature leads when energy is confined to that band":
    const EDGES = [(BAND_LOW_HZ, BASS_MID_HZ), (BASS_MID_HZ, MID_HIGH_HZ),
                   (MID_HIGH_HZ, BAND_HIGH_HZ)]
    for band in 0 .. 2:
      var state = initAnalysisState()
      let bins = bandBins(EDGES[band][0], EDGES[band][1], float32(QUIET_DB))
      var features = AudioFeatures(onset: Onset(fired: false))
      for _ in 0 ..< 30:
        features = analyse(state,
          frameOf(bins, amplitudeFor(QUIET_DB), FRAME_60))
      check bandFeature(features, band) > 0.9
      for other in 0 .. 2:
        if other != band:
          check bandFeature(features, other) < 0.1

  test "brightness decays toward zero when energy falls below the floor":
    var state = initAnalysisState()
    let lit = analyse(state, soundingFrame(QUIET_DB, FRAME_60))
    check lit.brightness > 0.0
    let firstDark = analyse(state, silentFrame(FRAME_60))
    check firstDark.brightness < lit.brightness
    check firstDark.brightness > 0.0
    var settled = firstDark
    for _ in 0 ..< 180:
      settled = analyse(state, silentFrame(FRAME_60))
    check settled.brightness < 0.01


suite "Audio Core Fires Onsets On Rectified Flux":
  test "onset fires once per click and never inside the refractory window when a click train plays":
    const CLICK_FRAMES = 15
      ## 250 ms at 1/60 s, well outside the 100 ms refractory window.
    var state = initAnalysisState()
    var firedAt: seq[int]
    for index in 0 ..< 150:
      let click = index > 0 and index mod CLICK_FRAMES == 0
      let frame =
        if click: soundingFrame(QUIET_DB, FRAME_60)
        else: silentFrame(FRAME_60)
      if analyse(state, frame).onset.fired:
        firedAt.add(index)
    var expected: seq[int]
    for index in 1 .. 9:
      expected.add(index * CLICK_FRAMES)
    check firedAt == expected
    for pair in 1 ..< firedAt.len:
      check (firedAt[pair] - firedAt[pair - 1]).float * FRAME_60 >=
        ONSET_REFRACTORY_SECONDS

  test "onset fires once when two crossings fall inside the refractory window":
    var state = initAnalysisState()
    var fired = 0
    for index in 0 ..< 6:
      # Clicks at frames 2 and 4, 33 ms apart and so inside the 100 ms window.
      # The second is 20 dB the louder, which carries it past the threshold the
      # first one raised: only the refractory window can hold it.
      let frame =
        if index == 2: soundingFrame(QUIET_DB, FRAME_60)
        elif index == 4: soundingFrame(QUIET_DB + 20.0, FRAME_60)
        else: silentFrame(FRAME_60)
      if analyse(state, frame).onset.fired:
        inc fired
    check fired == 1

  test "onset fires nothing when a loud steady spectrum stops increasing":
    var state = initAnalysisState()
    var fired = 0
    var features = AudioFeatures(onset: Onset(fired: false))
    for _ in 0 ..< 60:
      features = analyse(state, soundingFrame(0.0, FRAME_60))
      if features.onset.fired:
        inc fired
    check fired == 0
    # Non-vacuous: the frames have to have been loud for "however loud" to mean
    # anything.
    check features.loudness > 0.0


suite "Audio Core Is Total Over Any Finite Frame":
  test "every feature reads exactly zero when every bin is negative infinity":
    var state = initAnalysisState()
    let features = analyse(state, silentFrame(FRAME_60))
    check features.loudness == 0.0
    check features.bass == 0.0
    check features.mid == 0.0
    check features.high == 0.0
    check features.brightness == 0.0
    check features.onset.fired == false
    let next = analyse(state, soundingFrame(QUIET_DB, FRAME_60))
    checkBounded(next)
    # Non-vacuous: a core returning zero for everything would pass the six
    # checks above and say nothing about silence.
    check next.loudness > 0.0

  test "every feature stays finite and in range when the arrays are random":
    var rng = initRand(20260912)
    var sounded = 0
    for sampleRate in [44100.0, 48000.0, 96000.0]:
      var state = initAnalysisState()
      for _ in 0 ..< 200:
        var bins = newSeq[float32](FREQUENCY_BIN_COUNT)
        for index in 0 ..< bins.len:
          bins[index] =
            if rng.rand(1.0) < 0.1: float32(NegInf)
            else: float32(rng.rand(-200.0 .. 20.0))
        var samples = newSeq[float32](ANALYSER_FFT_SIZE)
        for index in 0 ..< samples.len:
          samples[index] = float32(rng.rand(-1.0 .. 1.0))
        let frame = AudioFrame(bins: bins, samples: samples,
          sampleRate: sampleRate, dtSeconds: FRAME_60)
        let features = analyse(state, frame)
        checkBounded(features)
        if features.loudness > 0.0:
          inc sounded
    # Non-vacuous: range and finiteness hold trivially of a core that reports
    # nothing, so the sweep has to have produced values.
    check sounded > 0


suite "Audio Core Normalizes Against Unknown Gain":
  test "every feature returns inside its open range when the level steps 20 dB up and back down":
    const SETTLE_FRAMES = 120
      ## 2 s at 1/60 s: the frame count this test pins for the window to
      ## reopen around a level 20 dB away from the one it had closed on.
    var state = initAnalysisState()
    var elapsed = 0.0
    var features = AudioFeatures(onset: Onset(fired: false))
    holdDithered(state, elapsed, features, QUIET_DB, SETTLE_FRAMES)
    checkInsideOpenRange(features)
    holdDithered(state, elapsed, features, QUIET_DB + 20.0, SETTLE_FRAMES)
    checkInsideOpenRange(features)
    holdDithered(state, elapsed, features, QUIET_DB, SETTLE_FRAMES)
    checkInsideOpenRange(features)

  test "a feature stays finite when its window closes narrower than the minimum":
    var state = initAnalysisState()
    let features = holdLevel(state, QUIET_DB, 6.0, FRAME_60)
    checkBounded(features)
    check features.loudness > 0.0
    check features.loudness < 1.0

  test "the level features read their silent values when a loud frame is followed by a silent one":
    var state = initAnalysisState()
    let loud = analyse(state, soundingFrame(0.0, FRAME_60))
    check loud.loudness > 0.0
    let quiet = analyse(state, silentFrame(FRAME_60))
    check quiet.loudness == 0.0
    check quiet.bass == 0.0
    check quiet.mid == 0.0
    check quiet.high == 0.0


suite "Audio Core Keeps Wall-Clock Time At Any Frame Rate":
  test "onset spans the same refractory window at 8.33 ms and 16.7 ms deltas":
    const
      CLICK_SECONDS = 0.04
        ## Clicks far closer together than the refractory window, so what fires
        ## is decided by that window and by nothing else.
      RUN_SECONDS = 0.42
        ## Past the tenth click rather than on it, so neither grid loses a
        ## click to the run's own edge.
      CLICK_GROWTH_DB = 12.0
        ## Each click four times the last, so no click is ever held back by the
        ## running median instead.
      FIRST_CLICK_DB = -110.0
    var counts: array[2, int]
    for index, dt in [FRAME_60, FRAME_120]:
      var state = initAnalysisState()
      var elapsed = 0.0
      while elapsed < RUN_SECONDS - dt * 0.5:
        let ordinal = floor((elapsed + dt) / CLICK_SECONDS)
        let click = ordinal > floor(elapsed / CLICK_SECONDS)
        let frame =
          if click:
            soundingFrame(FIRST_CLICK_DB + CLICK_GROWTH_DB * (ordinal - 1.0), dt)
          else:
            silentFrame(dt)
        if analyse(state, frame).onset.fired:
          inc counts[index]
        elapsed += dt
      # Clicks land every 40 ms, so the first gap that clears a 100 ms window is
      # the third one. Ten clicks in 400 ms leave four firings.
      check counts[index] == 4
    check counts[0] == counts[1]

  test "the gain window adapts the same amount at 8.33 ms and 16.7 ms deltas":
    var slowState = initAnalysisState()
    var fastState = initAnalysisState()
    let slow = holdLevel(slowState, QUIET_DB, 6.0, FRAME_60)
    let fast = holdLevel(fastState, QUIET_DB, 6.0, FRAME_120)
    # Non-vacuous: a value pinned at either end would match without adapting.
    check slow.loudness > 0.0
    check slow.loudness < 1.0
    check abs(slow.loudness - fast.loudness) < 1e-6
    check abs(slow.bass - fast.bass) < 1e-6


suite "Audio Core Reports A Quiet Room":
  test "the core reports silent when loudness sits at its floor for three seconds":
    var state = initAnalysisState()
    var features = AudioFeatures(onset: Onset(fired: false))
    let beforeFrames = int((SILENCE_SECONDS - 0.1) / FRAME_60)
    for _ in 0 ..< beforeFrames:
      features = analyse(state, silentFrame(FRAME_60))
    check features.silent == false
    for _ in 0 ..< 12:
      features = analyse(state, silentFrame(FRAME_60))
    check features.silent

  test "the core clears silent on the next frame when sound returns":
    var state = initAnalysisState()
    var quiet = AudioFeatures(onset: Onset(fired: false))
    for _ in 0 ..< int((SILENCE_SECONDS + 0.5) / FRAME_60):
      quiet = analyse(state, silentFrame(FRAME_60))
    check quiet.silent
    let sounding = analyse(state, soundingFrame(QUIET_DB, FRAME_60))
    check sounding.silent == false
