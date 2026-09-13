# ==============================================================================
# PARTICLE GARDEN - SHIPPED MAPPING
# ==============================================================================
#
# What the instrument arrives mapped to: the MIDI and audio source
# declarations, the clock family's one source, the two weather tours, and the
# default mapping over them. Pure, and separate from control_matrix.nim because these name a
# family and the matrix is family-blind past delivery.
#
# The static gate at the bottom is the reason all three live in one file: a
# shipped row is checked against the live descriptor table, the declarations it
# names and the tours it rides, at compile time, so a row naming an id nothing
# serves fails the build rather than shipping dead.
#
# ==============================================================================

import std/tables

import control_matrix
import ../api/param_descriptor
import ../../climate_core
import ../../config_ranges

# ------------------------------------------------------------------------------
# Declared sources
# ------------------------------------------------------------------------------

const SHIPPED_MIDI_SOURCES* = [
  SourceDeclaration(id: "midi:cc:1:7", label: "Volume (CC 7)",
    kind: skContinuous),
  SourceDeclaration(id: "midi:cc:1:1", label: "Mod wheel (CC 1)",
    kind: skContinuous),
  SourceDeclaration(id: "midi:cc:1:74", label: "Cutoff (CC 74)",
    kind: skContinuous),
  SourceDeclaration(id: "midi:cc:1:71", label: "Resonance (CC 71)",
    kind: skContinuous),
  SourceDeclaration(id: "midi:pc:1", label: "Program change", kind: skEvent),
  SourceDeclaration(id: "midi:notes:1", label: "Notes", kind: skEvent),
  SourceDeclaration(id: "midi:clock", label: "Beat clock", kind: skEvent),
]
  ## Channel 1's hardware-common controls, declared at wiring time rather than
  ## on first send, so a shipped row resolves before any hardware has spoken.
  ## Every other control declares itself the first time it sends, through the
  ## family's re-registration.

const SHIPPED_AUDIO_SOURCES* = [
  SourceDeclaration(id: "audio:loudness", label: "Loudness",
    kind: skContinuous),
  SourceDeclaration(id: "audio:bass", label: "Bass", kind: skContinuous),
  SourceDeclaration(id: "audio:mid", label: "Mid", kind: skContinuous),
  SourceDeclaration(id: "audio:high", label: "High", kind: skContinuous),
  SourceDeclaration(id: "audio:brightness", label: "Brightness",
    kind: skContinuous),
  SourceDeclaration(id: "audio:onset", label: "Onset", kind: skEvent),
]
  ## The microphone's six features, in the order the meters show them. The
  ## family is fixed by the analyser, so it declares whole at wiring time.

const SHIPPED_CLOCK_SOURCES* = [
  SourceDeclaration(id: "clock:frame", label: "Frame clock",
    kind: skContinuous),
]
  ## The one source the clock family declares. No value is delivered on it: a
  ## Tour row names it so the row resolves through the same declaration check
  ## as every other row, and the frame's delta travels in the flush context.

# ------------------------------------------------------------------------------
# The two weather tours
# ------------------------------------------------------------------------------

const
  CLIMATE_TOUR_ID* = "climate"
  FORCE_WEATHER_TOUR_ID* = "forceWeather"
  CLIMATE_GATE_ID* = "climateDrift"
  FORCE_WEATHER_GATE_ID* = "forceWeather"
    ## The gate ids the boundary reads its two weather booleans into. They are
    ## the CONFIG field names, since no boolean descriptor exists to name.

func climatePointAt(phase: float): seq[float] =
  ## The climate's point, over CLIMATE_PARAM_IDS' axis order.
  let point = tourAt(RD_CLIMATE_TOUR, phase)
  @[point[caFeed], point[caKill]]

func forceWeatherPointAt(phase: float): seq[float] =
  ## The force weather's point, over FORCE_WEATHER_PARAM_IDS' axis order.
  let point = tourAt(FORCE_WEATHER_TOUR, phase)
  @[point[fxStrength], point[fxRadius], point[fxFriction]]

const CLIMATE_TOUR* = TourDeclaration(
  tourId: CLIMATE_TOUR_ID,
  axisParamIds: @CLIMATE_PARAM_IDS,
  gateId: CLIMATE_GATE_ID,
  pointAt: climatePointAt,
  maxStepPerAxis: @CLIMATE_MAX_STEPS)

const FORCE_WEATHER_TOUR_DECL* = TourDeclaration(
  tourId: FORCE_WEATHER_TOUR_ID,
  axisParamIds: @FORCE_WEATHER_PARAM_IDS,
  gateId: FORCE_WEATHER_GATE_ID,
  pointAt: forceWeatherPointAt,
  maxStepPerAxis: @FORCE_WEATHER_MAX_STEPS)

const SHIPPED_TOURS* = [CLIMATE_TOUR, FORCE_WEATHER_TOUR_DECL]
  ## Which axes each weather writes, and the ceilings each axis's step
  ## respects, stay climate_core's; registration is what travels from here.

# ------------------------------------------------------------------------------
# The default mapping
# ------------------------------------------------------------------------------

const
  SHIPPED_WRITE_RANK* = 1
  SHIPPED_TOUR_RANK* = 0
    ## Tours rank below writes, so a hand on a knob lands after ambient drift
    ## on the same parameter — the ordering the frame loop gave the weathers
    ## before they became rows.
  PAD_GRID_COLS* = 4
  PAD_GRID_ROWS* = 4
    ## Sixteen cells, the grid a stock pad controller lays out.
  PAD_BASE_NOTE* = 36
    ## The note common pad controllers start their bottom-left pad at.
  AUDIO_BASS_DEPTH* = 0.30
  AUDIO_LOUDNESS_DEPTH* = 0.25
    ## A full-scale room moves the fluid under a third of its travel and the
    ## force under a quarter: audible, and short of the range a hand keeps.
  AUDIO_RELEASE_MS* = 80.0
    ## The audio rows rise at once and fall over 80 ms, the upper end of the
    ## 20 to 100 ms release audio-reactive practice starts from, so a hit
    ## lands whole and its tail outlasts a frame.
  AUDIO_ONSET_DEPTH* = 0.40
    ## A full hit peaks forceStrength at travel 0.6 from the shipped base of
    ## 1.0 at travel 0.2, and sums with loudness on a loud hit.
  AUDIO_ONSET_RELEASE_MS* = 300.0
    ## Longer than AUDIO_RELEASE_MS, so a hit's tail outlasts the loudness
    ## that arrived with it and reads as its own kick.

func buildDefaultMapping(): seq[ControlRow] =
  ## The shipped rows, in the order the editor lists them. The four coupling
  ## strengths lead, on the knobs stock controllers emit without
  ## configuration: volume and cutoff share their targets with the audio
  ## family's loudness and brightness, so level means the dance's energy and
  ## brightness means field-heed whether it arrives from a knob or a room.
  ##
  ## Toggles ship unmapped and arrive through learn, so a stray note never
  ## flips the picture.
  result = @[
    ControlRow(sourceId: "midi:cc:1:7", kind: rkWrite,
      writeParamId: "forceStrength", jump: false, rank: SHIPPED_WRITE_RANK),
    ControlRow(sourceId: "midi:cc:1:1", kind: rkWrite,
      writeParamId: "fluidStrength", jump: false, rank: SHIPPED_WRITE_RANK),
    ControlRow(sourceId: "midi:cc:1:74", kind: rkWrite,
      writeParamId: "rdFieldForce", jump: false, rank: SHIPPED_WRITE_RANK),
    ControlRow(sourceId: "midi:cc:1:71", kind: rkWrite,
      writeParamId: "rdDeposit", jump: false, rank: SHIPPED_WRITE_RANK),
  ]
  # The six named regimes on program change, in the regime table's own order,
  # so adding a regime there adds its button here.
  for ordinal, regime in RD_REGIMES:
    result.add ControlRow(sourceId: "midi:pc:1", kind: rkFire,
      actionId: REGIME_ACTION_PREFIX & regime.id, ordinal: ordinal)
  result.add ControlRow(sourceId: "midi:notes:1", kind: rkTouch,
    gridCols: PAD_GRID_COLS, gridRows: PAD_GRID_ROWS, baseNote: PAD_BASE_NOTE)
  result.add ControlRow(sourceId: "clock:frame", kind: rkTour,
    tourId: CLIMATE_TOUR_ID, runningParamId: CLIMATE_GATE_ID,
    tourSpeedParamId: "climateSpeed", tourRank: SHIPPED_TOUR_RANK)
  result.add ControlRow(sourceId: "clock:frame", kind: rkTour,
    tourId: FORCE_WEATHER_TOUR_ID, runningParamId: FORCE_WEATHER_GATE_ID,
    tourSpeedParamId: "forceWeatherSpeed", tourRank: SHIPPED_TOUR_RANK)
  # The room. Every hit kicks the force the whole world feels, an impulse that
  # releases to base; the three levels modulate, two live and one parked at
  # zero depth so a player raises it once the first two feel familiar.
  result.add ControlRow(sourceId: "audio:onset", kind: rkModulate,
    modParamId: "forceStrength", depth: AUDIO_ONSET_DEPTH, attackMs: 0.0,
    releaseMs: AUDIO_ONSET_RELEASE_MS)
  for (sourceId, paramId, depth) in [
      ("audio:bass", "fluidStrength", AUDIO_BASS_DEPTH),
      ("audio:loudness", "forceStrength", AUDIO_LOUDNESS_DEPTH),
      ("audio:high", "glowIntensity", 0.0)]:
    result.add ControlRow(sourceId: sourceId, kind: rkModulate,
      modParamId: paramId, depth: depth, attackMs: 0.0,
      releaseMs: AUDIO_RELEASE_MS)

const DEFAULT_MAPPING* = buildDefaultMapping()
  ## Loaded when storage is empty or its document is refused.

func shippedMatrixState*(): MatrixState =
  ## A matrix carrying every shipped declaration and tour, for the gate below
  ## and for any caller that needs to validate a row against what ships.
  result = initMatrixState()
  result.registerSourceFamily("midi", SHIPPED_MIDI_SOURCES)
  result.registerSourceFamily("audio", SHIPPED_AUDIO_SOURCES)
  result.registerSourceFamily("clock", SHIPPED_CLOCK_SOURCES)
  for tour in SHIPPED_TOURS:
    result.registerTour(tour)

static:
  # THE SHIPPED-MAPPING GATE, in the style of the descriptor table's own
  # compile-time gates. Every row is checked against the live descriptor
  # table, the shipped declarations and the shipped tours, so a row naming a
  # parameter id, an action id, a tour or a source the build does not serve
  # fails the Nim compile instead of shipping as a dead control.
  let state = shippedMatrixState()
  var descriptors = initTable[string, ParamDescriptor]()
  for descriptor in buildParamDescriptors():
    descriptors[descriptor.id] = descriptor
  for index, row in DEFAULT_MAPPING:
    let named = "shipped mapping row " & $index & " (" & $row.kind & " on " &
      row.sourceId & " -> " & rowTarget(row) & ")"
    let verdict = validateRow(state, descriptors, row)
    doAssert verdict.ok, named & " fails validation: " & verdict.reason
    doAssert rowResolved(state, row),
      named & " names a source no shipped declaration covers with the kind " &
      "this row kind needs"
