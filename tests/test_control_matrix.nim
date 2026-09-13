#
# The control matrix: the one spine every mapped control runs through — rows
# binding a source to a parameter, an action or a gesture, with arbitration,
# takeover, persistence and learn.
#
# Every expected value comes from the design and the control-matrix spec, never
# from the module's own arithmetic: travel is recomputed here through
# slider_curve's served pair, envelope convergence is read in wall-clock
# seconds off the frame delta the context carries, and every descriptor is the
# real one buildParamDescriptors() serves, so a range or step edit reaches these
# expectations rather than passing them by.
#
# The sources are a probe family of this suite's own minting. The matrix is
# family-blind past delivery, so nothing here needs MIDI to exist; the shipped
# MIDI rows are checked where they live, against the declarations that ship
# with them.
#

import std/[unittest, math, os, strutils, tables]

import ../src/climate_core
import ../src/config_ranges
import ../src/ui/api/param_descriptor
import ../src/ui/api/param_fields
import ../src/ui/api/slider_curve
import ../src/ui/input/control_matrix
import ../src/ui/input/shipped_mapping
import ../src/ui/state/render_state
import ../src/ui/state/simulation_state
import ../src/ui/presets/preset_store_core

const CONTROL_MATRIX_TESTS_LOADED* = true

# ------------------------------------------------------------------------------
# The probe vocabulary: two knobs, one pad, one clock, one tour
# ------------------------------------------------------------------------------

const
  PROBE_FAMILY = "probe"
  KNOB_A = "probe:knobA"
  KNOB_B = "probe:knobB"
  PAD = "probe:pad"
  CLOCK_FAMILY = "clock"
  CLOCK_FRAME = "clock:frame"
  PROBE_TOUR = "probeTour"
  PROBE_FORCE_TOUR = "probeForceTour"
  PROBE_GATE = "probeGate"
  PROBE_FORCE_GATE = "probeForceGate"

func probePointAt(phase: float): seq[float] =
  ## The shipped climate tour, read back as a seq over its two axes: the point
  ## is climate_core's, so these tests pin the matrix's use of a tour rather
  ## than restating one.
  let point = tourAt(RD_CLIMATE_TOUR, phase)
  @[point[caFeed], point[caKill]]

func forcePointAt(phase: float): seq[float] =
  ## The shipped force weather, in ForceAxis order. Its radius axis is pkInt,
  ## which is where the rounding a tour axis takes becomes observable.
  let point = tourAt(FORCE_WEATHER_TOUR, phase)
  @[point[fxStrength], point[fxRadius], point[fxFriction]]

proc descriptorTable(): Table[string, ParamDescriptor] =
  result = initTable[string, ParamDescriptor]()
  for descriptor in buildParamDescriptors():
    result[descriptor.id] = descriptor

let descriptors = descriptorTable()

proc probeDeclarations(): seq[SourceDeclaration] =
  @[SourceDeclaration(id: KNOB_A, label: "Knob A", kind: skContinuous),
    SourceDeclaration(id: KNOB_B, label: "Knob B", kind: skContinuous),
    SourceDeclaration(id: PAD, label: "Pad", kind: skEvent)]

proc probeTour(): TourDeclaration =
  TourDeclaration(
    tourId: PROBE_TOUR,
    axisParamIds: @["rdFeed", "rdKill"],
    gateId: PROBE_GATE,
    pointAt: probePointAt,
    maxStepPerAxis: @[0.01, 0.01])

proc probeForceTour(): TourDeclaration =
  TourDeclaration(
    tourId: PROBE_FORCE_TOUR,
    axisParamIds: @["forceStrength", "interactionRadius", "friction"],
    gateId: PROBE_FORCE_GATE,
    pointAt: forcePointAt,
    maxStepPerAxis: @FORCE_WEATHER_MAX_STEPS)

proc probeState(): MatrixState =
  ## A matrix carrying the probe family, the clock family and the two probe
  ## tours: the declarations every row below resolves against.
  result = initMatrixState()
  result.registerSourceFamily(PROBE_FAMILY, probeDeclarations())
  result.registerSourceFamily(CLOCK_FAMILY, @[
    SourceDeclaration(id: CLOCK_FRAME, label: "Frame clock",
      kind: skContinuous)])
  result.registerTour(probeTour())
  result.registerTour(probeForceTour())

const
  FRAME_60 = 1.0 / 60.0
  FRAME_120 = 1.0 / 120.0
    ## 16.7 ms and 8.33 ms: the two frame deltas every time constant here must
    ## span the same wall-clock seconds across.

template checkNear(actual, expected: float; tolerance = 1e-9) =
  ## One reason to fail, and the two numbers in the message when it does.
  let observed = actual
  let wanted = expected
  if abs(observed - wanted) > tolerance:
    checkpoint("expected " & $wanted & ", got " & $observed)
  check abs(observed - wanted) <= tolerance

proc contextOf(dtSeconds: float;
    params: seq[(string, ParamContext)] = @[];
    gates: seq[(string, bool)] = @[]): FlushContext =
  result = FlushContext(dtSeconds: dtSeconds,
    params: initTable[string, ParamContext](),
    gates: initTable[string, bool]())
  for (id, context) in params:
    result.params[id] = context
  for (id, running) in gates:
    result.gates[id] = running

proc paramAt(id: string; storedValue: float; ceiling = NaN): ParamContext =
  ParamContext(descriptor: descriptors[id], storedValue: storedValue,
    ceiling: ceiling)

proc writeRow(sourceId, paramId: string; jump = false; rank = 1): ControlRow =
  ControlRow(sourceId: sourceId, kind: rkWrite, writeParamId: paramId,
    jump: jump, rank: rank)

proc modulateRow(sourceId, paramId: string; depth: float;
    attackMs = 0.0; releaseMs = 0.0): ControlRow =
  ControlRow(sourceId: sourceId, kind: rkModulate, modParamId: paramId,
    depth: depth, attackMs: attackMs, releaseMs: releaseMs)

proc fireRow(sourceId, actionId: string; ordinal = 0): ControlRow =
  ControlRow(sourceId: sourceId, kind: rkFire, actionId: actionId,
    ordinal: ordinal)

proc touchRow(sourceId: string; cols, rows, baseNote: int): ControlRow =
  ControlRow(sourceId: sourceId, kind: rkTouch, gridCols: cols,
    gridRows: rows, baseNote: baseNote)

proc tourRow(sourceId, tourId, gateId, speedId: string;
    tourRank = 0): ControlRow =
  ControlRow(sourceId: sourceId, kind: rkTour, tourId: tourId,
    runningParamId: gateId, tourSpeedParamId: speedId, tourRank: tourRank)

# ------------------------------------------------------------------------------
# Registration
# ------------------------------------------------------------------------------

suite "a source family registers the sources it carries":
  test "registerSourceFamily serves each declaration with its kind and label":
    var state = probeState()
    let declared = declaredSources(state)
    check declared.len == 4
    check declared[0].id == KNOB_A
    check declared[0].label == "Knob A"
    check declared[0].kind == skContinuous
    check declared[2].kind == skEvent
    # Registration order across families, not a table's iteration order.
    check declared[3].id == CLOCK_FRAME

  test "declarationOf answers the declaration behind a source id":
    var state = probeState()
    let found = declarationOf(state, PAD)
    check found.found
    check found.decl.kind == skEvent
    check not declarationOf(state, "probe:absent").found

  test "a second registration replaces that family's declared set whole":
    var state = probeState()
    state.registerSourceFamily(PROBE_FAMILY, @[
      SourceDeclaration(id: KNOB_B, label: "Knob B", kind: skContinuous)])
    check declarationOf(state, KNOB_B).found
    # An id present only in the first registration stops resolving.
    check not declarationOf(state, KNOB_A).found

  test "one family's registration leaves another family's declarations alone":
    var state = probeState()
    state.registerSourceFamily("audio", @[
      SourceDeclaration(id: "audio:loudness", label: "Loudness",
        kind: skContinuous)])
    check declarationOf(state, KNOB_A).found
    check declarationOf(state, PAD).found
    check declarationOf(state, "audio:loudness").found

  test "a declaration outside the family's own prefix is dropped":
    var state = initMatrixState()
    state.registerSourceFamily("audio", @[
      SourceDeclaration(id: "audio:loudness", label: "Loudness",
        kind: skContinuous),
      SourceDeclaration(id: "midi:cc:1:7", label: "Stolen",
        kind: skContinuous)])
    check declaredSources(state).len == 1
    check not declarationOf(state, "midi:cc:1:7").found

# ------------------------------------------------------------------------------
# Resolution
# ------------------------------------------------------------------------------

suite "the mapping names every parameter it writes through the store":
  test "write targets and tour axes are listed once each, in row order":
    var state = probeState()
    state.setRows(@[
      writeRow(KNOB_A, "forceStrength"),
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed"),
      writeRow(KNOB_B, "forceStrength", rank = 2),
      tourRow(CLOCK_FRAME, PROBE_FORCE_TOUR, PROBE_FORCE_GATE,
        "forceWeatherSpeed")])
    check writtenParamIds(state) == @["forceStrength", "rdFeed", "rdKill",
      "interactionRadius", "friction"]

  test "a modulate row is absent, since it moves no stored value":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 0.5)])
    check writtenParamIds(state).len == 0

  test "a tour row whose tour is unregistered contributes no axis":
    var state = probeState()
    state.setRows(@[tourRow(CLOCK_FRAME, "nobodyRegisteredThis", PROBE_GATE,
      "climateSpeed")])
    check tourAxisIds(state, "nobodyRegisteredThis").len == 0
    check writtenParamIds(state).len == 0

suite "a row resolves against the declarations present":
  test "a Write row naming a declared continuous source resolves":
    var state = probeState()
    check rowResolved(state, writeRow(KNOB_A, "forceStrength"))

  test "a row naming an undeclared source keeps its place and reports unresolved":
    var state = probeState()
    state.setRows(@[writeRow("probe:absent", "forceStrength")])
    check state.rows.len == 1
    check not rowResolved(state, state.rows[0])

  test "a Fire row resolves on an event declaration and not on a continuous one":
    var state = probeState()
    check rowResolved(state, fireRow(PAD, "reseedField"))
    check not rowResolved(state, fireRow(KNOB_A, "reseedField"))

  test "a Modulate row resolves on a declaration of either kind":
    var state = probeState()
    check rowResolved(state, modulateRow(KNOB_A, "forceStrength", 0.5))
    check rowResolved(state, modulateRow(PAD, "forceStrength", 0.5))
    check not rowResolved(state, modulateRow("probe:absent", "forceStrength", 0.5))

# ------------------------------------------------------------------------------
# The five validation relations
# ------------------------------------------------------------------------------

suite "a row admits only legal combinations of source and target":
  test "a Write row on a continuous source and a served parameter validates":
    var state = probeState()
    check validateRow(state, descriptors, writeRow(KNOB_A, "forceStrength")).ok

  test "a Write row on an event source is refused":
    var state = probeState()
    check not validateRow(state, descriptors,
      writeRow(PAD, "forceStrength")).ok

  test "a Modulate row on an event source validates and resolves":
    var state = probeState()
    let row = modulateRow(PAD, "forceStrength", 0.5)
    check validateRow(state, descriptors, row).ok
    check rowResolved(state, row)

  test "a Fire or Touch row on a continuous source is refused":
    var state = probeState()
    check not validateRow(state, descriptors,
      fireRow(KNOB_A, "reseedField")).ok
    check not validateRow(state, descriptors,
      touchRow(KNOB_A, 4, 4, 36)).ok

  test "a row naming an undeclared source passes validation and reports unresolved":
    var state = probeState()
    let row = writeRow("probe:absent", "forceStrength")
    check validateRow(state, descriptors, row).ok
    check not rowResolved(state, row)

  test "particleCount and speciesCount are refused as Modulate and Write targets":
    var state = probeState()
    for paramId in ["particleCount", "speciesCount"]:
      check not validateRow(state, descriptors,
        modulateRow(KNOB_A, paramId, 0.5)).ok
      check not validateRow(state, descriptors,
        writeRow(KNOB_A, paramId)).ok

  test "a Modulate row outside the simulation and render stores is refused while a Write row takes it":
    var state = probeState()
    # paletteSaturation is psPalette and cameraZoom is psCamera: setParam
    # routes both, and neither is a field of the two records the modulated
    # overlay walks.
    for paramId in ["paletteSaturation", "cameraZoom"]:
      check not validateRow(state, descriptors,
        modulateRow(KNOB_A, paramId, 0.5)).ok
      check validateRow(state, descriptors, writeRow(KNOB_A, paramId)).ok

  test "a Write row on a per-species chemistry column is refused":
    # setParam does not route psSpeciesChemistry: those cells are written
    # through chemistry() by reference, so no row can reach them.
    var state = probeState()
    check not validateRow(state, descriptors,
      writeRow(KNOB_A, "secretion")).ok

  test "a Modulate or Write row naming an unserved parameter id is refused":
    var state = probeState()
    check not validateRow(state, descriptors,
      modulateRow(KNOB_A, "nothingServesThis", 0.5)).ok
    check not validateRow(state, descriptors,
      writeRow(KNOB_A, "nothingServesThis")).ok

  test "a Fire row naming an action id actionOf does not resolve is refused":
    var state = probeState()
    check validateRow(state, descriptors, fireRow(PAD, "reseedField")).ok
    check not validateRow(state, descriptors, fireRow(PAD, "explodeWorld")).ok
    check not validateRow(state, descriptors, fireRow(PAD, "regime:nowhere")).ok

  test "a Touch row needs a cell and a base note the wire can carry":
    var state = probeState()
    check validateRow(state, descriptors, touchRow(PAD, 4, 4, 36)).ok
    check not validateRow(state, descriptors, touchRow(PAD, 0, 4, 36)).ok
    check not validateRow(state, descriptors, touchRow(PAD, 4, 0, 36)).ok
    # MIDI note numbers are seven bits, so 128 names nothing on the wire.
    check not validateRow(state, descriptors, touchRow(PAD, 4, 4, -1)).ok
    check not validateRow(state, descriptors, touchRow(PAD, 4, 4, 128)).ok

  test "a Tour row names a registered tour, that tour's gate and a non-negative speed":
    var state = probeState()
    check validateRow(state, descriptors,
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed")).ok
    check not validateRow(state, descriptors,
      tourRow(CLOCK_FRAME, "absentTour", PROBE_GATE, "climateSpeed")).ok
    check not validateRow(state, descriptors,
      tourRow(CLOCK_FRAME, PROBE_TOUR, "someOtherGate", "climateSpeed")).ok
    check not validateRow(state, descriptors,
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "nothingServesThis")).ok
    # A speed whose range reaches below zero would run a tour backwards; the
    # two shipped speeds both floor above zero.
    check descriptors["climateSpeed"].minValue >= 0.0
    check not validateRow(state, descriptors,
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "temperature")).ok
    check descriptors["temperature"].minValue < 0.0

suite "a mapping edit validates before it lands":
  test "setRow replaces a row the validation accepts":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "forceStrength")])
    check state.setRow(0, writeRow(KNOB_B, "fluidStrength"), descriptors).ok
    check state.rows[0].writeParamId == "fluidStrength"

  test "a refused row edit changes nothing":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "forceStrength")])
    let refused = state.setRow(0, writeRow(KNOB_A, "particleCount"),
      descriptors)
    check not refused.ok
    check refused.reason.len > 0
    check state.rows.len == 1
    check state.rows[0].writeParamId == "forceStrength"

  test "an index outside the mapping is refused by every edit that names one":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "forceStrength")])
    check not state.setRow(1, writeRow(KNOB_A, "fluidStrength"),
      descriptors).ok
    check not state.setRank(1, 3, descriptors).ok
    check not state.removeRow(1).ok
    check state.rows.len == 1

  test "addRow appends a validated row and refuses an invalid one":
    var state = probeState()
    check state.addRow(writeRow(KNOB_A, "forceStrength"), descriptors).ok
    check not state.addRow(fireRow(PAD, "explodeWorld"), descriptors).ok
    check state.rows.len == 1

  test "removeRow drops the row at its index":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "forceStrength"),
      writeRow(KNOB_B, "fluidStrength")])
    check state.removeRow(0).ok
    check state.rows.len == 1
    check state.rows[0].writeParamId == "fluidStrength"

  test "setRank moves a Write row's rank and a Tour row's tourRank":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "forceStrength", rank = 1),
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed")])
    check state.setRank(0, 4, descriptors).ok
    check state.rows[0].rank == 4
    check state.setRank(1, 2, descriptors).ok
    check state.rows[1].tourRank == 2

  test "setRank refuses a kind that carries no rank":
    var state = probeState()
    state.setRows(@[fireRow(PAD, "reseedField")])
    let refused = state.setRank(0, 2, descriptors)
    check not refused.ok
    check refused.reason.len > 0

suite "delivery keeps the latest continuous value and queues events in order":
  test "a sweep collapses to its latest value per source id":
    var state = probeState()
    for value in [0.1, 0.4, 0.9, 0.62]:
      state.setSourceValue(KNOB_A, value)
    state.setSourceValue(KNOB_B, 0.25)
    check state.latestValue(KNOB_A) == 0.62
    check state.latestValue(KNOB_B) == 0.25

  test "a value outside [0, 1] is clamped at the entry point":
    var state = probeState()
    state.setSourceValue(KNOB_A, 1.75)
    check state.latestValue(KNOB_A) == 1.0
    state.setSourceValue(KNOB_A, -3.0)
    check state.latestValue(KNOB_A) == 0.0

  test "a source that has never delivered reads as zero":
    var state = probeState()
    check state.latestValue(KNOB_A) == 0.0

  test "events keep their arrival order":
    var state = probeState()
    state.emitSourceEvent(PAD, 1.0, 36)
    state.emitSourceEvent(PAD, 0.5, 38)
    state.emitSourceEvent(KNOB_A, 0.25, 3)
    let staged = state.stagedEvents()
    check staged.len == 3
    check staged[0].ordinal == 36
    check staged[1].ordinal == 38
    check staged[1].magnitude == 0.5
    check staged[2].sourceId == KNOB_A

  test "an event magnitude outside [0, 1] is clamped at the entry point":
    var state = probeState()
    state.emitSourceEvent(PAD, 4.0, 36)
    state.emitSourceEvent(PAD, -1.0, 37)
    check state.stagedEvents()[0].magnitude == 1.0
    check state.stagedEvents()[1].magnitude == 0.0

  test "a source with no ordinal space sends zero":
    var state = probeState()
    state.emitSourceEvent(PAD, 1.0, 0)
    check state.stagedEvents().len == 1
    check state.stagedEvents()[0].ordinal == 0

suite "modulate excursions sum in travel space":
  test "two rows on one parameter add their travel offsets":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 0.25),
      modulateRow(KNOB_B, "fluidStrength", 0.5)])
    state.setSourceValue(KNOB_A, 1.0)
    state.setSourceValue(KNOB_B, 0.4)
    let stored = 0.3
    let outcome = state.flushMatrix(
      contextOf(FRAME_60, @[("fluidStrength", paramAt("fluidStrength", stored))]))
    let descriptor = descriptors["fluidStrength"]
    let offset = 0.25 * 1.0 + 0.5 * 0.4
    let base = positionOf(descriptor, stored)
    checkNear(outcome.excursions["fluidStrength"], offset)
    check outcome.remirror
    checkNear(outcome.effective["fluidStrength"],
      valueAt(descriptor, base + offset))
    # The stored record is the user's: a flush produces an effective value and
    # writes no parameter from a Modulate row.
    check outcome.writes.len == 0

  test "an offset carrying travel past either end lands on the end value under the live ceiling":
    var state = probeState()
    let ceiling = minimumCeiling(pcStableStiffness)
    let descriptor = descriptors["sphStiffness"]
    # Non-vacuous: the ceiling has to bite before it can be observed.
    check ceiling < descriptor.maxValue
    check descriptor.bound.kind == bDerived
    state.setRows(@[modulateRow(KNOB_A, "sphStiffness", 1.0)])
    state.setSourceValue(KNOB_A, 1.0)
    let context = contextOf(FRAME_60,
      @[("sphStiffness", paramAt("sphStiffness", 20.0, ceiling))])
    let up = state.flushMatrix(context)
    checkNear(up.effective["sphStiffness"],
      valueAt(descriptor, 1.0, boundMax = ceiling))

    var falling = probeState()
    falling.setRows(@[modulateRow(KNOB_A, "sphStiffness", -1.0)])
    falling.setSourceValue(KNOB_A, 1.0)
    let down = falling.flushMatrix(context)
    checkNear(down.effective["sphStiffness"],
      valueAt(descriptor, 0.0, boundMax = ceiling))

  test "a zero depth moves nothing whatever its source does":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 0.0)])
    state.setSourceValue(KNOB_A, 1.0)
    let outcome = state.flushMatrix(
      contextOf(FRAME_60, @[("fluidStrength", paramAt("fluidStrength", 0.3))]))
    check outcome.excursions.len == 0
    check outcome.effective.len == 0
    check not outcome.remirror

  test "the frame after the last excursion re-mirrors the base and the frame after that writes nothing":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 0.5)])
    let stored = 0.3
    let context = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", stored))])
    state.setSourceValue(KNOB_A, 1.0)
    let live = state.flushMatrix(context)
    check live.remirror
    checkNear(live.excursions["fluidStrength"], 0.5)

    state.setSourceValue(KNOB_A, 0.0)
    let returning = state.flushMatrix(context)
    check returning.excursions.len == 0
    check returning.remirror
    checkNear(returning.effective["fluidStrength"],
      valueAt(descriptors["fluidStrength"], positionOf(
        descriptors["fluidStrength"], stored)))

    let quiet = state.flushMatrix(context)
    check not quiet.remirror
    check quiet.effective.len == 0
    check quiet.excursions.len == 0

  test "a rising source approaches over the attack constant":
    var state = probeState()
    const attackMs = 100.0
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 1.0,
      attackMs = attackMs)])
    state.setSourceValue(KNOB_A, 1.0)
    let context = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.0))])
    let first = state.flushMatrix(context)
    # The exponential approach D4 states, at the row's own time constant.
    let afterOneFrame = 1.0 - exp(-FRAME_60 / (attackMs / 1000.0))
    checkNear(first.excursions["fluidStrength"], afterOneFrame)
    let second = state.flushMatrix(context)
    checkNear(second.excursions["fluidStrength"],
      1.0 - exp(-2.0 * FRAME_60 / (attackMs / 1000.0)))

  test "a zero attack constant applies the raw value on the next frame":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 1.0)])
    state.setSourceValue(KNOB_A, 0.6)
    let outcome = state.flushMatrix(contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.0))]))
    checkNear(outcome.excursions["fluidStrength"], 0.6)

  test "a falling source approaches over the release constant while the rise landed at once":
    var state = probeState()
    const releaseMs = 200.0
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 1.0,
      releaseMs = releaseMs)])
    let context = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.0))])
    state.setSourceValue(KNOB_A, 1.0)
    let risen = state.flushMatrix(context)
    checkNear(risen.excursions["fluidStrength"], 1.0)
    state.setSourceValue(KNOB_A, 0.0)
    let falling = state.flushMatrix(context)
    checkNear(falling.excursions["fluidStrength"],
      exp(-FRAME_60 / (releaseMs / 1000.0)))

  test "the same signal spans the same wall-clock constant at either frame delta":
    let context60 = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.0))])
    let context120 = contextOf(FRAME_120,
      @[("fluidStrength", paramAt("fluidStrength", 0.0))])
    var slow = probeState()
    var fast = probeState()
    for state in [slow.addr, fast.addr]:
      state[].setRows(@[modulateRow(KNOB_A, "fluidStrength", 1.0,
        attackMs = 100.0)])
      state[].setSourceValue(KNOB_A, 1.0)
    let slowOutcome = slow.flushMatrix(context60)
    discard fast.flushMatrix(context120)
    let fastOutcome = fast.flushMatrix(context120)
    checkNear(fastOutcome.excursions["fluidStrength"],
      slowOutcome.excursions["fluidStrength"], 1e-12)

  test "a release under the envelope floor reaches the base instead of approaching it":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 1.0,
      releaseMs = 200.0)])
    let context = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.0))])
    state.setSourceValue(KNOB_A, 1.0)
    discard state.flushMatrix(context)
    state.setSourceValue(KNOB_A, 0.0)
    # exp(-t / 0.2) crosses 1e-4 at 1.84 s, so two seconds of frames settle it.
    var settled = false
    for frame in 0 ..< 120:
      settled = state.flushMatrix(context).excursions.len == 0
      if settled: break
    check settled

  test "the envelope floor sits under half the finest position step a row can target":
    # The condition ENVELOPE_FLOOR is set against, read off the live descriptor
    # table: a residual offset under half a position step cannot carry a stored
    # value across a lattice midpoint, so the snap moves no lattice value.
    var finest = 1.0
    var considered = 0
    for descriptor in buildParamDescriptors():
      if descriptor.reinitOnCommit or
          descriptor.store notin {psSimulation, psRender, psPalette, psCamera}:
        continue
      inc considered
      finest = min(finest, positionStep(descriptor))
    check considered > 0
    check ENVELOPE_FLOOR < finest / 2.0

  test "withdrawSourceFamily releases a held Modulate row to base":
    var state = probeState()
    const releaseMs = 200.0
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 0.5,
      releaseMs = releaseMs)])
    let stored = 0.3
    let context = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", stored))])
    state.setSourceValue(KNOB_A, 1.0)
    for frame in 0 ..< 3:
      checkNear(state.flushMatrix(context).excursions["fluidStrength"], 0.5)

    state.withdrawSourceFamily(PROBE_FAMILY)
    let released = state.flushMatrix(context)
    checkNear(released.excursions["fluidStrength"],
      0.5 * exp(-FRAME_60 / (releaseMs / 1000.0)))

    var settled = false
    var remirrored: FlushOutcome
    for frame in 0 ..< 600:
      remirrored = state.flushMatrix(context)
      if remirrored.excursions.len == 0:
        settled = true
        break
    checkpoint("withdrawSourceFamily never settled the excursion within 600 frames")
    check settled
    check remirrored.remirror
    checkNear(remirrored.effective["fluidStrength"],
      valueAt(descriptors["fluidStrength"], positionOf(
        descriptors["fluidStrength"], stored)))

    let quiet = state.flushMatrix(context)
    check not quiet.remirror
    check quiet.effective.len == 0
    check quiet.excursions.len == 0

  test "withdrawSourceFamily leaves another family's staged value untouched":
    var state = probeState()
    state.setRows(@[modulateRow(CLOCK_FRAME, "forceStrength", 1.0)])
    state.setSourceValue(CLOCK_FRAME, 1.0)
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 0.0))])
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 1.0)

    state.withdrawSourceFamily(PROBE_FAMILY)
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 1.0)

  test "withdrawSourceFamily records no delivery, so a Write row on the withdrawn source writes nothing":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "forceStrength", jump = true)])
    state.setSourceValue(KNOB_A, 1.0)
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 0.0))])
    check state.flushMatrix(context).writes.len == 1

    state.withdrawSourceFamily(PROBE_FAMILY)
    check state.flushMatrix(context).writes.len == 0

  test "withdrawSourceFamily on an unregistered family id is a no-op":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", 0.5)])
    state.setSourceValue(KNOB_A, 1.0)
    state.withdrawSourceFamily("nonexistent")
    check state.latestValue(KNOB_A) == 1.0
    let context = contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.3))])
    checkNear(state.flushMatrix(context).excursions["fluidStrength"], 0.5)

  test "an event on an impulse row lifts the envelope to the event's magnitude on that frame":
    var state = probeState()
    state.setRows(@[modulateRow(PAD, "forceStrength", 0.5, releaseMs = 200.0)])
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 1.0))])
    state.emitSourceEvent(PAD, 0.8, 0)
    # The lift lands whole on the hit frame: no attack, and no release taken
    # out of the magnitude that arrived.
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5 * 0.8)

  test "two hits inside one release do not dip":
    var state = probeState()
    const releaseMs = 200.0
    state.setRows(@[modulateRow(PAD, "forceStrength", 0.5,
      releaseMs = releaseMs)])
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 1.0))])
    state.emitSourceEvent(PAD, 1.0, 0)
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5)

    state.emitSourceEvent(PAD, 0.3, 0)
    let released = exp(-FRAME_60 / (releaseMs / 1000.0))
    check released > 0.3
    checkNear(state.flushMatrix(context).excursions["forceStrength"],
      0.5 * max(released, 0.3))

    state.emitSourceEvent(PAD, 1.0, 0)
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5)

  test "an impulse row releases over its release constant and re-mirrors the base after the last excursion":
    var state = probeState()
    const releaseMs = 200.0
    state.setRows(@[modulateRow(PAD, "forceStrength", 0.5,
      releaseMs = releaseMs)])
    let stored = 1.0
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", stored))])
    state.emitSourceEvent(PAD, 1.0, 0)
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5)
    checkNear(state.flushMatrix(context).excursions["forceStrength"],
      0.5 * exp(-FRAME_60 / (releaseMs / 1000.0)))

    var settled = false
    var remirrored: FlushOutcome
    for frame in 0 ..< 600:
      remirrored = state.flushMatrix(context)
      if remirrored.excursions.len == 0:
        settled = true
        break
    checkpoint("the impulse never settled to base within 600 frames")
    check settled
    check remirrored.remirror
    checkNear(remirrored.effective["forceStrength"],
      valueAt(descriptors["forceStrength"], positionOf(
        descriptors["forceStrength"], stored)))

    let quiet = state.flushMatrix(context)
    check not quiet.remirror
    check quiet.effective.len == 0
    check quiet.excursions.len == 0

  test "an impulse row ignores its attack constant":
    var state = probeState()
    state.setRows(@[modulateRow(PAD, "forceStrength", 0.5, attackMs = 500.0,
      releaseMs = 200.0)])
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 1.0))])
    state.emitSourceEvent(PAD, 1.0, 0)
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5)

  test "an impulse row with a zero release lasts one frame":
    var state = probeState()
    state.setRows(@[modulateRow(PAD, "forceStrength", 0.5, releaseMs = 0.0)])
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 1.0))])
    state.emitSourceEvent(PAD, 1.0, 0)
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5)
    let after = state.flushMatrix(context)
    check after.excursions.len == 0
    check after.remirror

  test "a Fire row and an impulse row on the same event both act in one flush":
    var state = probeState()
    state.setRows(@[fireRow(PAD, "reseedField", 0),
      modulateRow(PAD, "forceStrength", 0.5),
      touchRow(PAD, 1, 1, 0)])
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 1.0))])
    state.emitSourceEvent(PAD, 1.0, 0)
    let outcome = state.flushMatrix(context)
    check outcome.actions.len == 1
    checkNear(outcome.excursions["forceStrength"], 0.5)
    check outcome.hasBlast

  test "a continuous-source Modulate row is unchanged by the impulse pass":
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "forceStrength", 0.5)])
    state.setSourceValue(KNOB_A, 1.0)
    state.emitSourceEvent(PAD, 1.0, 0)
    let context = contextOf(FRAME_60,
      @[("forceStrength", paramAt("forceStrength", 1.0))])
    checkNear(state.flushMatrix(context).excursions["forceStrength"], 0.5)

suite "write rows write through the path the panel writes through":
  test "a jump row writes the value its travel names on the descriptor's curve":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "rdFieldForce", jump = true)])
    state.setSourceValue(KNOB_A, 0.5)
    let outcome = state.flushMatrix(contextOf(FRAME_60,
      @[("rdFieldForce", paramAt("rdFieldForce", 1.0))]))
    let descriptor = descriptors["rdFieldForce"]
    checkNear(outcome.writes["rdFieldForce"], valueAt(descriptor, 0.5))
    # Travel is not the value: the descriptor's own range is what makes the
    # mapping observable.
    check abs(valueAt(descriptor, 0.5) - 0.5) > 1e-6

  test "a row whose travel names a value above the live ceiling writes that value whole":
    var state = probeState()
    let ceiling = minimumCeiling(pcStableStiffness)
    let descriptor = descriptors["sphStiffness"]
    check ceiling < descriptor.maxValue
    state.setRows(@[writeRow(KNOB_A, "sphStiffness", jump = true)])
    state.setSourceValue(KNOB_A, 1.0)
    let outcome = state.flushMatrix(contextOf(FRAME_60,
      @[("sphStiffness", paramAt("sphStiffness", 20.0, ceiling))]))
    # No bound argument on a Write row: the store takes what travel names and
    # the effect-time clamp keeps the world under the ceiling.
    checkNear(outcome.writes["sphStiffness"], valueAt(descriptor, 1.0))
    check outcome.writes["sphStiffness"] > ceiling

  test "an unresolved row writes nothing":
    var state = probeState()
    state.setRows(@[writeRow("probe:absent", "rdFieldForce", jump = true)])
    state.setSourceValue("probe:absent", 0.5)
    let outcome = state.flushMatrix(contextOf(FRAME_60,
      @[("rdFieldForce", paramAt("rdFieldForce", 1.0))]))
    check outcome.writes.len == 0

suite "soft takeover engages by crossing the live value":
  # fluidStrength is linear over [0, 1] at a step of 0.01, so travel and value
  # are one number here and one position step is 0.01. The arithmetic under
  # test is the comparison, not the curve; the curve is pinned above.
  const stored = 0.30

  proc context(storedValue = stored): FlushContext =
    contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", storedValue))])

  test "a resting row whose source never crosses the live travel writes nothing":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength")])
    for travel in [0.80, 0.60, 0.45]:
      state.setSourceValue(KNOB_A, travel)
      check state.flushMatrix(context()).writes.len == 0

  test "crossing the live travel hands the parameter over":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength")])
    state.setSourceValue(KNOB_A, 0.60)
    check state.flushMatrix(context()).writes.len == 0
    state.setSourceValue(KNOB_A, 0.20)
    let crossed = state.flushMatrix(context())
    checkNear(crossed.writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], 0.20))

  test "landing within one position step hands the parameter over":
    var state = probeState()
    let step = positionStep(descriptors["fluidStrength"])
    check step > 0.0
    state.setRows(@[writeRow(KNOB_A, "fluidStrength")])
    state.setSourceValue(KNOB_A, stored + step / 2.0)
    let landed = state.flushMatrix(context())
    checkNear(landed.writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], stored + step / 2.0))

  test "a jump row writes on its first delivery with no crossing":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength", jump = true)])
    state.setSourceValue(KNOB_A, 0.90)
    let outcome = state.flushMatrix(context())
    checkNear(outcome.writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], 0.90))

  test "an engaged row's own writes do not release it":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength")])
    var current = stored
    # The first delivery lands on the live travel, which is what engages a
    # soft row; every delivery after it is the row moving its own parameter.
    for travel in [stored, 0.40, 0.50, 0.65, 0.90]:
      state.setSourceValue(KNOB_A, travel)
      let outcome = state.flushMatrix(context(current))
      checkNear(outcome.writes["fluidStrength"],
        valueAt(descriptors["fluidStrength"], travel))
      # The boundary's next frame reports what the row wrote, which is what
      # keeps the row engaged.
      current = outcome.writes["fluidStrength"]

  test "a slider move of more than one position step releases the row":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength")])
    state.setSourceValue(KNOB_A, 0.60)
    discard state.flushMatrix(context())
    state.setSourceValue(KNOB_A, 0.20)
    check state.flushMatrix(context()).writes.len == 1
    # A hand drags the slider far away from where the row last wrote.
    state.setSourceValue(KNOB_A, 0.21)
    check state.flushMatrix(context(0.60)).writes.len == 0

  test "a preset apply releases the row on the same terms":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength", jump = false)])
    state.setSourceValue(KNOB_A, stored)
    check state.flushMatrix(context()).writes.len == 1
    # A preset lands a value the row never wrote.
    state.setSourceValue(KNOB_A, stored + 0.01)
    check state.flushMatrix(context(0.85)).writes.len == 0

  test "another row's write releases the soft row":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength", rank = 1),
      writeRow(KNOB_B, "fluidStrength", jump = true, rank = 2)])
    state.setSourceValue(KNOB_A, stored)
    let engaged = state.flushMatrix(context())
    checkNear(engaged.writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], stored))
    # The higher-ranked jump row takes the parameter somewhere else, and the
    # boundary reports that value next frame.
    state.setSourceValue(KNOB_A, stored)
    state.setSourceValue(KNOB_B, 0.90)
    let taken = state.flushMatrix(context())
    checkNear(taken.writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], 0.90))
    state.setSourceValue(KNOB_A, stored)
    check state.flushMatrix(context(0.90)).writes.len == 0

  test "a quiet frame carries no ownership and no release":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength")])
    state.setSourceValue(KNOB_A, stored)
    check state.flushMatrix(context()).writes.len == 1
    # Nothing delivers: the row emits nothing and keeps its engagement.
    check state.flushMatrix(context()).writes.len == 0
    state.setSourceValue(KNOB_A, 0.34)
    checkNear(state.flushMatrix(context()).writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], 0.34))

suite "colliding writers apply in ascending rank":
  proc context(storedValue = 0.30): FlushContext =
    contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", storedValue))])

  test "the higher rank owns the frame whichever row is listed first":
    for higherFirst in [false, true]:
      var state = probeState()
      let low = writeRow(KNOB_A, "fluidStrength", jump = true, rank = 1)
      let high = writeRow(KNOB_B, "fluidStrength", jump = true, rank = 2)
      state.setRows(if higherFirst: @[high, low] else: @[low, high])
      state.setSourceValue(KNOB_A, 0.20)
      state.setSourceValue(KNOB_B, 0.80)
      checkNear(state.flushMatrix(context()).writes["fluidStrength"],
        valueAt(descriptors["fluidStrength"], 0.80))

  test "a quiet frame lets the lower rank take the parameter":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_A, "fluidStrength", jump = true, rank = 1),
      writeRow(KNOB_B, "fluidStrength", jump = true, rank = 2)])
    state.setSourceValue(KNOB_A, 0.20)
    state.setSourceValue(KNOB_B, 0.80)
    discard state.flushMatrix(context())
    state.setSourceValue(KNOB_A, 0.20)
    checkNear(state.flushMatrix(context(0.80)).writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], 0.20))

  test "a Write row outranking a Tour row takes one axis and leaves the others":
    var state = probeState()
    state.setRows(@[
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed",
        tourRank = 0),
      writeRow(KNOB_A, "rdFeed", jump = true, rank = 1)])
    state.setSourceValue(KNOB_A, 0.40)
    let speed = 1.0
    let outcome = state.flushMatrix(contextOf(FRAME_60, @[
      ("rdFeed", paramAt("rdFeed", 0.030)),
      ("rdKill", paramAt("rdKill", 0.060)),
      ("climateSpeed", paramAt("climateSpeed", speed))],
      @[(PROBE_GATE, true)]))
    let point = tourAt(RD_CLIMATE_TOUR, tourPhaseStep(speed, FRAME_60))
    checkNear(outcome.writes["rdFeed"],
      valueAt(descriptors["rdFeed"], 0.40))
    checkNear(outcome.writes["rdKill"], point[caKill])
    # Non-vacuous: the tour's own feed is not what landed on the contested
    # axis.
    check abs(outcome.writes["rdFeed"] - point[caFeed]) > 1e-6

suite "a Tour row advances a phase on the wall clock and writes a whole point":
  const climateSpeed = 1.0
  const forceSpeed = 0.5
    ## Two speeds a slider can hold, so a phase is the frame delta times the
    ## row's own number and not a shared one.

  proc tourContext(dtSeconds: float; climateRunning, forceRunning: bool):
      FlushContext =
    contextOf(dtSeconds, @[
      ("rdFeed", paramAt("rdFeed", 0.030)),
      ("rdKill", paramAt("rdKill", 0.060)),
      ("climateSpeed", paramAt("climateSpeed", climateSpeed)),
      ("forceStrength", paramAt("forceStrength", 1.0)),
      ("interactionRadius", paramAt("interactionRadius", 50.0)),
      ("friction", paramAt("friction", 0.05)),
      ("forceWeatherSpeed", paramAt("forceWeatherSpeed", forceSpeed))],
      @[(PROBE_GATE, climateRunning), (PROBE_FORCE_GATE, forceRunning)])

  proc climateRow(): ControlRow =
    tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed")

  proc forceRow(): ControlRow =
    tourRow(CLOCK_FRAME, PROBE_FORCE_TOUR, PROBE_FORCE_GATE,
      "forceWeatherSpeed")

  test "a running row writes every axis of its tour in one batch":
    var state = probeState()
    state.setRows(@[climateRow()])
    let outcome = state.flushMatrix(tourContext(FRAME_60, true, false))
    let point = tourAt(RD_CLIMATE_TOUR, tourAdvance(0.0, climateSpeed,
      FRAME_60))
    check outcome.writes.len == 2
    checkNear(outcome.writes["rdFeed"], point[caFeed])
    checkNear(outcome.writes["rdKill"], point[caKill])

  test "the phase advances on the wall clock scaled by the row's speed":
    var state = probeState()
    state.setRows(@[climateRow()])
    var phase = 0.0
    for frame in 0 ..< 3:
      discard state.flushMatrix(tourContext(FRAME_60, true, false))
      phase = tourAdvance(phase, climateSpeed, FRAME_60)
    let outcome = state.flushMatrix(tourContext(FRAME_60, true, false))
    phase = tourAdvance(phase, climateSpeed, FRAME_60)
    let point = tourAt(RD_CLIMATE_TOUR, phase)
    checkNear(outcome.writes["rdFeed"], point[caFeed])
    checkNear(outcome.writes["rdKill"], point[caKill])

  test "an integer axis takes the rounded point":
    var state = probeState()
    state.setRows(@[forceRow()])
    # A delta that lands the phase half way along the first segment, where the
    # interpolated radius sits between two whole world units.
    let dt = 0.5 * (60.0 / FORCE_WEATHER_TOUR.len.float) / forceSpeed
    let outcome = state.flushMatrix(tourContext(dt, false, true))
    let point = tourAt(FORCE_WEATHER_TOUR, tourAdvance(0.0, forceSpeed, dt))
    check descriptors["interactionRadius"].kind == pkInt
    # Non-vacuous: the raw point is not already a whole number.
    check abs(point[fxRadius] - round(point[fxRadius])) > 1e-6
    checkNear(outcome.writes["interactionRadius"], round(point[fxRadius]))
    checkNear(outcome.writes["forceStrength"], point[fxStrength])

  test "a false gate freezes the phase and writes nothing":
    var state = probeState()
    state.setRows(@[climateRow()])
    for frame in 0 ..< 2:
      check state.flushMatrix(tourContext(FRAME_60, false, false)).writes.len == 0
    let outcome = state.flushMatrix(tourContext(FRAME_60, true, false))
    let point = tourAt(RD_CLIMATE_TOUR, tourAdvance(0.0, climateSpeed,
      FRAME_60))
    checkNear(outcome.writes["rdFeed"], point[caFeed])

  test "two rows keep separate phases":
    var state = probeState()
    state.setRows(@[climateRow(), forceRow()])
    var climatePhase = 0.0
    for frame in 0 ..< 3:
      discard state.flushMatrix(tourContext(FRAME_60, true, false))
      climatePhase = tourAdvance(climatePhase, climateSpeed, FRAME_60)
    # The force weather switches on three frames late, and the climate's own
    # position is untouched by the switch.
    let outcome = state.flushMatrix(tourContext(FRAME_60, true, true))
    climatePhase = tourAdvance(climatePhase, climateSpeed, FRAME_60)
    let climatePoint = tourAt(RD_CLIMATE_TOUR, climatePhase)
    let forcePoint = tourAt(FORCE_WEATHER_TOUR,
      tourAdvance(0.0, forceSpeed, FRAME_60))
    checkNear(outcome.writes["rdFeed"], climatePoint[caFeed])
    checkNear(outcome.writes["forceStrength"], forcePoint[fxStrength])

suite "Fire rows select an action by ordinal":
  proc bareContext(): FlushContext =
    contextOf(FRAME_60)

  test "a matching ordinal fires once and another ordinal fires nothing":
    var state = probeState()
    state.setRows(@[fireRow(PAD, "reseedField", ordinal = 3)])
    state.emitSourceEvent(PAD, 1.0, 3)
    let outcome = state.flushMatrix(bareContext())
    check outcome.actions.len == 1
    check outcome.actions[0].kind == akReseedField
    state.emitSourceEvent(PAD, 1.0, 4)
    check state.flushMatrix(bareContext()).actions.len == 0

  test "a queued event fires at one flush and no later one":
    var state = probeState()
    state.setRows(@[fireRow(PAD, "reseedField")])
    state.emitSourceEvent(PAD, 1.0, 0)
    check state.flushMatrix(bareContext()).actions.len == 1
    check state.flushMatrix(bareContext()).actions.len == 0

  test "two different actions in one frame both run in arrival order":
    var state = probeState()
    state.setRows(@[fireRow(PAD, "resetParticles", ordinal = 0),
      fireRow(PAD, "toggleBloom", ordinal = 1)])
    state.emitSourceEvent(PAD, 1.0, 1)
    state.emitSourceEvent(PAD, 1.0, 0)
    let outcome = state.flushMatrix(bareContext())
    check outcome.actions.len == 2
    check outcome.actions[0].kind == akToggleBloom
    check outcome.actions[1].kind == akResetParticles

  test "a flurry of regime selections settles on the last":
    var state = probeState()
    state.setRows(@[
      fireRow(PAD, "regime:" & RD_REGIMES[0].id, ordinal = 0),
      fireRow(PAD, "regime:" & RD_REGIMES[3].id, ordinal = 1),
      fireRow(PAD, "regime:" & RD_REGIMES[5].id, ordinal = 2)])
    for ordinal in [0, 1, 2]:
      state.emitSourceEvent(PAD, 1.0, ordinal)
    let outcome = state.flushMatrix(bareContext())
    check outcome.actions.len == 1
    check outcome.actions[0].kind == akRegime
    check outcome.actions[0].payload == RD_REGIMES[5].id

  test "a regime collapse keeps the position of the last selection":
    var state = probeState()
    state.setRows(@[
      fireRow(PAD, "regime:" & RD_REGIMES[0].id, ordinal = 0),
      fireRow(PAD, "toggleTrails", ordinal = 1),
      fireRow(PAD, "regime:" & RD_REGIMES[2].id, ordinal = 2)])
    for ordinal in [0, 1, 2]:
      state.emitSourceEvent(PAD, 1.0, ordinal)
    let outcome = state.flushMatrix(bareContext())
    check outcome.actions.len == 2
    check outcome.actions[0].kind == akToggleTrails
    check outcome.actions[1].kind == akRegime
    check outcome.actions[1].payload == RD_REGIMES[2].id

suite "Touch rows lay a pad grid over the visible view":
  proc bareContext(): FlushContext =
    contextOf(FRAME_60)

  test "the base note blasts the centre of the bottom-left cell":
    var state = probeState()
    state.setRows(@[touchRow(PAD, 4, 4, 36)])
    state.emitSourceEvent(PAD, 1.0, 36)
    let outcome = state.flushMatrix(bareContext())
    check outcome.hasBlast
    checkNear(outcome.blast.u, 0.5 / 4.0)
    checkNear(outcome.blast.v, 0.5 / 4.0)
    checkNear(outcome.blast.strength, 1.0)

  test "the next ordinal steps along the bottom row and the fifth starts the next":
    var state = probeState()
    state.setRows(@[touchRow(PAD, 4, 4, 36)])
    state.emitSourceEvent(PAD, 1.0, 37)
    let along = state.flushMatrix(bareContext())
    checkNear(along.blast.u, 1.5 / 4.0)
    checkNear(along.blast.v, 0.5 / 4.0)
    state.emitSourceEvent(PAD, 1.0, 40)
    let up = state.flushMatrix(bareContext())
    checkNear(up.blast.u, 0.5 / 4.0)
    checkNear(up.blast.v, 1.5 / 4.0)

  test "an ordinal outside the grid places nothing":
    var state = probeState()
    state.setRows(@[touchRow(PAD, 4, 4, 36)])
    state.emitSourceEvent(PAD, 1.0, 35)
    check not state.flushMatrix(bareContext()).hasBlast
    state.emitSourceEvent(PAD, 1.0, 52)
    check not state.flushMatrix(bareContext()).hasBlast

  test "a one-cell grid resolves an ordinal-zero event":
    var state = probeState()
    state.setRows(@[touchRow(PAD, 1, 1, 0)])
    state.emitSourceEvent(PAD, 1.0, 0)
    let outcome = state.flushMatrix(bareContext())
    check outcome.hasBlast
    checkNear(outcome.blast.u, 0.5)
    checkNear(outcome.blast.v, 0.5)

  test "magnitude scales the strength and the later touch of a frame wins":
    var state = probeState()
    state.setRows(@[touchRow(PAD, 4, 4, 36)])
    state.emitSourceEvent(PAD, 0.25, 36)
    checkNear(state.flushMatrix(bareContext()).blast.strength, 0.25)
    state.emitSourceEvent(PAD, 0.25, 36)
    state.emitSourceEvent(PAD, 0.9, 37)
    let outcome = state.flushMatrix(bareContext())
    checkNear(outcome.blast.strength, 0.9)
    checkNear(outcome.blast.u, 1.5 / 4.0)

suite "an idle frame writes nothing":
  test "no delivery, no live excursion and no running tour leaves an empty outcome":
    var state = probeState()
    state.setRows(@[
      modulateRow(KNOB_A, "fluidStrength", 0.5),
      writeRow(KNOB_B, "rdFieldForce"),
      fireRow(PAD, "reseedField"),
      touchRow(PAD, 4, 4, 36),
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed")])
    let outcome = state.flushMatrix(contextOf(FRAME_60, @[
      ("fluidStrength", paramAt("fluidStrength", 0.3)),
      ("rdFieldForce", paramAt("rdFieldForce", 1.0)),
      ("rdFeed", paramAt("rdFeed", 0.030)),
      ("rdKill", paramAt("rdKill", 0.060)),
      ("climateSpeed", paramAt("climateSpeed", 1.0))],
      @[(PROBE_GATE, false)]))
    check outcome.writes.len == 0
    check outcome.excursions.len == 0
    check outcome.effective.len == 0
    check not outcome.remirror
    check outcome.actions.len == 0
    check not outcome.hasBlast
    check not outcome.learned

suite "the mapping document is versioned, dropping malformed rows and keeping unresolved ones":
  proc fullMapping(): seq[ControlRow] =
    @[modulateRow(KNOB_A, "fluidStrength", -0.4, attackMs = 5.0,
        releaseMs = 80.0),
      writeRow(KNOB_B, "rdFieldForce", jump = true, rank = 3),
      fireRow(PAD, "regime:" & RD_REGIMES[2].id, ordinal = 2),
      touchRow(PAD, 4, 4, 36),
      tourRow(CLOCK_FRAME, PROBE_TOUR, PROBE_GATE, "climateSpeed",
        tourRank = 0)]

  test "the schema version this build writes is one":
    check MATRIX_SCHEMA_VERSION == 1

  test "a document round-trips every row kind unchanged":
    var state = probeState()
    let rows = fullMapping()
    let loaded = parseDocument(toDocumentText(rows), descriptors, state)
    check loaded.ok
    check loaded.errorKind == mekNone
    check loaded.rows.len == rows.len
    for index in 0 ..< rows.len:
      check loaded.rows[index] == rows[index]

  test "an exported document applies back to an equal mapping row for row":
    var state = probeState()
    state.setRows(fullMapping())
    let text = toDocumentText(state.rows)
    var other = probeState()
    other.setRows(parseDocument(text, descriptors, other).rows)
    check other.rows == state.rows

  test "one structurally malformed row costs one row":
    var state = probeState()
    const document = """{"schemaVersion": 1, "rows": [
      {"kind": "write", "source": "probe:knobA",
       "writeParamId": "forceStrength", "jump": false, "rank": 1},
      {"kind": "write", "source": "probe:knobA",
       "writeParamId": 42, "jump": false, "rank": 1},
      {"kind": "fire", "source": "probe:pad",
       "actionId": "reseedField", "ordinal": 0}
    ]}"""
    let loaded = parseDocument(document, descriptors, state)
    check loaded.ok
    check loaded.rows.len == 2
    check loaded.rows[0].kind == rkWrite
    check loaded.rows[1].kind == rkFire

  test "a row naming a kind or a field this build does not know drops":
    var state = probeState()
    const document = """{"schemaVersion": 1, "rows": [
      {"kind": "integrate", "source": "probe:knobA"},
      {"kind": "modulate", "source": "probe:knobA",
       "modParamId": "fluidStrength", "depth": 0.5, "attackMs": 0.0},
      {"kind": "write", "source": "probe:knobA",
       "writeParamId": "fluidStrength", "jump": false, "rank": 1}
    ]}"""
    let loaded = parseDocument(document, descriptors, state)
    check loaded.rows.len == 1
    check loaded.rows[0].kind == rkWrite

  test "an out-of-range field clamps into range":
    var state = probeState()
    const document = """{"schemaVersion": 1, "rows": [
      {"kind": "modulate", "source": "probe:knobA",
       "modParamId": "fluidStrength", "depth": 3.5,
       "attackMs": -5.0, "releaseMs": 20.0},
      {"kind": "modulate", "source": "probe:knobB",
       "modParamId": "fluidStrength", "depth": -2.0,
       "attackMs": 0.0, "releaseMs": -1.0},
      {"kind": "touch", "source": "probe:pad",
       "gridCols": 0, "gridRows": -3, "baseNote": 200},
      {"kind": "fire", "source": "probe:pad",
       "actionId": "reseedField", "ordinal": -4}
    ]}"""
    let loaded = parseDocument(document, descriptors, state)
    check loaded.rows.len == 4
    checkNear(loaded.rows[0].depth, DEPTH_MAX)
    checkNear(loaded.rows[0].attackMs, 0.0)
    checkNear(loaded.rows[1].depth, DEPTH_MIN)
    checkNear(loaded.rows[1].releaseMs, 0.0)
    check loaded.rows[2].gridCols == GRID_MIN
    check loaded.rows[2].gridRows == GRID_MIN
    check loaded.rows[2].baseNote == BASE_NOTE_MAX
    check loaded.rows[3].ordinal == 0

  test "a document declaring a newer version is refused whole":
    var state = probeState()
    let text = toDocumentText(fullMapping()).replace(
      "\"schemaVersion\":" & $MATRIX_SCHEMA_VERSION,
      "\"schemaVersion\":" & $(MATRIX_SCHEMA_VERSION + 1))
    # Non-vacuous: the substitution has to have landed.
    check ("\"schemaVersion\":" & $(MATRIX_SCHEMA_VERSION + 1)) in text
    let loaded = parseDocument(text, descriptors, state)
    check not loaded.ok
    check loaded.errorKind == mekNewerSchemaVersion
    check loaded.rows.len == 0
    check loaded.error.len > 0

  test "text that is not JSON is refused with no row applied":
    var state = probeState()
    let loaded = parseDocument("{not json at all", descriptors, state)
    check not loaded.ok
    check loaded.errorKind == mekInvalidJson
    check loaded.rows.len == 0

  test "a row naming an undeclared source loads and reports unresolved":
    var state = probeState()
    const document = """{"schemaVersion": 1, "rows": [
      {"kind": "write", "source": "absent:knob",
       "writeParamId": "fluidStrength", "jump": false, "rank": 1}
    ]}"""
    let loaded = parseDocument(document, descriptors, state)
    check loaded.rows.len == 1
    check not rowResolved(state, loaded.rows[0])

  test "a row whose target relation fails drops":
    var state = probeState()
    const document = """{"schemaVersion": 1, "rows": [
      {"kind": "write", "source": "probe:knobA",
       "writeParamId": "nothingServesThis", "jump": false, "rank": 1},
      {"kind": "write", "source": "probe:knobA",
       "writeParamId": "particleCount", "jump": false, "rank": 1},
      {"kind": "fire", "source": "probe:pad",
       "actionId": "explodeWorld", "ordinal": 0},
      {"kind": "tour", "source": "clock:frame", "tourId": "absentTour",
       "runningParamId": "probeGate", "tourSpeedParamId": "climateSpeed",
       "tourRank": 0},
      {"kind": "tour", "source": "clock:frame", "tourId": "probeTour",
       "runningParamId": "someOtherGate",
       "tourSpeedParamId": "climateSpeed", "tourRank": 0}
    ]}"""
    check parseDocument(document, descriptors, state).rows.len == 0

  test "a document carrying no rows decodes to an empty mapping":
    var state = probeState()
    let loaded = parseDocument("""{"schemaVersion": 1, "rows": []}""",
      descriptors, state)
    check loaded.ok
    check loaded.rows.len == 0

  test "migrate falls through with no branch to take yet":
    var state = probeState()
    let text = toDocumentText(fullMapping())
    let loaded = parseDocument(text, descriptors, state)
    check loaded.ok
    check loaded.rows.len == fullMapping().len

suite "the mapping storage key is distinct from every preset key":
  # Both constants cross to TypeScript, which owns localStorage: the panel must
  # never read a mapping where it looks for a preset.
  test "MAPPING_STORAGE_KEY is neither the preset index key nor under its prefix":
    check MAPPING_STORAGE_KEY != PRESET_INDEX_KEY
    check MAPPING_STORAGE_KEY != PRESET_KEY_PREFIX
    check not MAPPING_STORAGE_KEY.startsWith(PRESET_KEY_PREFIX)
    check MAPPING_STORAGE_KEY.len > 0

suite "the shipped default mapping loads when storage holds nothing usable":
  test "every shipped row validates against the shipped declarations":
    let shipped = shippedMatrixState()
    check DEFAULT_MAPPING.len > 0
    for index, row in DEFAULT_MAPPING:
      let verdict = validateRow(shipped, descriptors, row)
      if not verdict.ok:
        checkpoint("row " & $index & ": " & verdict.reason)
      check verdict.ok
      check rowResolved(shipped, row)

  test "the shipped mapping is the seventeen rows the two specs name":
    # Four coupling strengths, six regimes, one pad grid, the two weathers and
    # the four audio rows (mid and brightness stay declared sources with no
    # row).
    check DEFAULT_MAPPING.len ==
      4 + RD_REGIMES.len + 1 + SHIPPED_TOURS.len + 4
    const expectedWrites = {
      "midi:cc:1:7": "forceStrength",
      "midi:cc:1:1": "fluidStrength",
      "midi:cc:1:74": "rdFieldForce",
      "midi:cc:1:71": "rdDeposit",
    }
    for index, (sourceId, paramId) in expectedWrites:
      check DEFAULT_MAPPING[index].kind == rkWrite
      check DEFAULT_MAPPING[index].sourceId == sourceId
      check DEFAULT_MAPPING[index].writeParamId == paramId
      # Soft takeover is the default, so a knob resting somewhere else waits.
      check not DEFAULT_MAPPING[index].jump
    for ordinal, regime in RD_REGIMES:
      let row = DEFAULT_MAPPING[4 + ordinal]
      check row.kind == rkFire
      check row.sourceId == "midi:pc:1"
      check row.ordinal == ordinal
      check row.actionId == "regime:" & regime.id
    let pads = DEFAULT_MAPPING[4 + RD_REGIMES.len]
    check pads.kind == rkTouch
    check pads.sourceId == "midi:notes:1"
    check pads.gridCols == 4
    check pads.gridRows == 4
    check pads.baseNote == 36
    let climate = DEFAULT_MAPPING[5 + RD_REGIMES.len]
    check climate.kind == rkTour
    check climate.sourceId == "clock:frame"
    check climate.tourId == CLIMATE_TOUR_ID
    check climate.runningParamId == CLIMATE_GATE_ID
    check climate.tourSpeedParamId == "climateSpeed"
    let weather = DEFAULT_MAPPING[6 + RD_REGIMES.len]
    check weather.kind == rkTour
    check weather.tourId == FORCE_WEATHER_TOUR_ID
    check weather.runningParamId == FORCE_WEATHER_GATE_ID
    check weather.tourSpeedParamId == "forceWeatherSpeed"

  test "the four audio rows ship pinned by source, kind, target and depth":
    # The two live level rows carry the depths the audio spec names; the one
    # waiting row sits at zero so a player raises it by choice.
    const expectedModulates = {
      "audio:bass": ("fluidStrength", 0.30),
      "audio:loudness": ("forceStrength", 0.25),
      "audio:high": ("glowIntensity", 0.0),
    }
    var levelTargets: seq[string]
    var onsetTarget: string
    var onsetRows = 0
    var modulateRows = 0
    for row in DEFAULT_MAPPING:
      if not row.sourceId.startsWith("audio:"):
        continue
      check row.kind == rkModulate
      check row.attackMs == 0.0
      inc modulateRows
      if row.sourceId == "audio:onset":
        inc onsetRows
        onsetTarget = row.modParamId
        check row.modParamId == "forceStrength"
        checkNear(row.depth, AUDIO_ONSET_DEPTH)
        check row.releaseMs == AUDIO_ONSET_RELEASE_MS
        continue
      var expected = false
      for (sourceId, spec) in expectedModulates:
        if sourceId == row.sourceId:
          expected = true
          check row.modParamId == spec[0]
          checkNear(row.depth, spec[1])
      check expected
      check row.releaseMs == AUDIO_RELEASE_MS
      check row.modParamId notin levelTargets
      levelTargets.add row.modParamId
    check onsetRows == 1
    check modulateRows == expectedModulates.len + 1
    # The three levels keep distinct targets; onset rides one of them, so a hit
    # and the level it arrives with sum on that parameter.
    check onsetTarget in levelTargets

  test "every shipped tour row ranks below every shipped write row":
    var highestTourRank = low(int)
    var lowestWriteRank = high(int)
    var tours = 0
    var writes = 0
    for row in DEFAULT_MAPPING:
      case row.kind
      of rkTour:
        inc tours
        highestTourRank = max(highestTourRank, row.tourRank)
      of rkWrite:
        inc writes
        lowestWriteRank = min(lowestWriteRank, row.rank)
      else: discard
    check tours > 0
    check writes > 0
    check highestTourRank < lowestWriteRank

  test "no toggle ships mapped":
    for row in DEFAULT_MAPPING:
      if row.kind != rkFire:
        continue
      let action = actionOf(row.actionId)
      check action.found
      check action.kind == akRegime

  test "the shipped tours name the axes climate_core names":
    check @(CLIMATE_TOUR.axisParamIds) == @CLIMATE_PARAM_IDS
    check @(FORCE_WEATHER_TOUR_DECL.axisParamIds) == @FORCE_WEATHER_PARAM_IDS
    check CLIMATE_TOUR.maxStepPerAxis == @CLIMATE_MAX_STEPS
    check FORCE_WEATHER_TOUR_DECL.maxStepPerAxis == @FORCE_WEATHER_MAX_STEPS

  test "an empty store loads the shipped default":
    let shipped = shippedMatrixState()
    check loadMapping("", DEFAULT_MAPPING, descriptors, shipped) ==
      DEFAULT_MAPPING

  test "a refused document loads the shipped default":
    let shipped = shippedMatrixState()
    let newer = toDocumentText(DEFAULT_MAPPING).replace(
      "\"schemaVersion\":" & $MATRIX_SCHEMA_VERSION,
      "\"schemaVersion\":" & $(MATRIX_SCHEMA_VERSION + 1))
    check loadMapping(newer, DEFAULT_MAPPING, descriptors, shipped) ==
      DEFAULT_MAPPING
    check loadMapping("{not json", DEFAULT_MAPPING, descriptors, shipped) ==
      DEFAULT_MAPPING

  test "a stored mapping that decodes keeps the default out":
    let shipped = shippedMatrixState()
    let stored = @[ControlRow(sourceId: "midi:cc:1:7", kind: rkWrite,
      writeParamId: "friction", jump: true, rank: 2)]
    let loaded = loadMapping(toDocumentText(stored), DEFAULT_MAPPING,
      descriptors, shipped)
    check loaded == stored
    check loaded.len < DEFAULT_MAPPING.len

  test "a document that decodes to no rows is still a decoded document":
    let shipped = shippedMatrixState()
    check loadMapping("""{"schemaVersion": 1, "rows": []}""",
      DEFAULT_MAPPING, descriptors, shipped).len == 0

suite "learn binds the next qualifying delivery":
  proc knobContext(): FlushContext =
    contextOf(FRAME_60,
      @[("fluidStrength", paramAt("fluidStrength", 0.30))])

  proc bareContext(): FlushContext =
    contextOf(FRAME_60)

  test "a knob learns a write slot and the parameter does not move from that delivery":
    var state = probeState()
    state.armLearn(writeRow("", "fluidStrength", jump = true))
    check state.learnState().armed
    state.setSourceValue(KNOB_A, 0.90)
    let binding = state.flushMatrix(knobContext())
    check binding.learned
    check not state.learnState().armed
    check state.rows.len == 1
    check state.rows[0].kind == rkWrite
    check state.rows[0].sourceId == KNOB_A
    # The binding gesture is suppressed from ordinary effect, so learning a
    # knob does not also drive what it was mapped to.
    check binding.writes.len == 0
    # The row works from the next delivery on.
    state.setSourceValue(KNOB_A, 0.90)
    checkNear(state.flushMatrix(knobContext()).writes["fluidStrength"],
      valueAt(descriptors["fluidStrength"], 0.90))

  test "a pad learns a fire slot with its ordinal and the action does not run":
    var state = probeState()
    state.armLearn(fireRow("", "reseedField"))
    state.emitSourceEvent(PAD, 1.0, 7)
    let binding = state.flushMatrix(bareContext())
    check binding.learned
    check state.rows.len == 1
    check state.rows[0].sourceId == PAD
    check state.rows[0].ordinal == 7
    check binding.actions.len == 0
    state.emitSourceEvent(PAD, 1.0, 7)
    check state.flushMatrix(bareContext()).actions.len == 1

  test "a pad learns a touch slot with the delivered ordinal as its base note":
    var state = probeState()
    state.armLearn(touchRow("", 4, 4, 0))
    state.emitSourceEvent(PAD, 1.0, 48)
    check state.flushMatrix(bareContext()).learned
    check state.rows[0].kind == rkTouch
    check state.rows[0].sourceId == PAD
    check state.rows[0].baseNote == 48

  test "a source already streaming does not bind and a later one does":
    var state = probeState()
    # KNOB_A delivered in the frame before the arm, so it is captured.
    state.setSourceValue(KNOB_A, 0.5)
    discard state.flushMatrix(knobContext())
    state.armLearn(writeRow("", "fluidStrength", jump = true))
    for frame in 0 ..< 3:
      state.setSourceValue(KNOB_A, 0.5 + frame.float * 0.1)
      check not state.flushMatrix(knobContext()).learned
      check state.learnState().armed
      check state.rows.len == 0
    # A source that first delivers after the arm binds.
    state.setSourceValue(KNOB_A, 0.9)
    state.setSourceValue(KNOB_B, 0.2)
    check state.flushMatrix(knobContext()).learned
    check state.rows[0].sourceId == KNOB_B

  test "a source delivering in the same frame as the arm is captured too":
    var state = probeState()
    state.setSourceValue(KNOB_A, 0.5)
    state.armLearn(writeRow("", "fluidStrength", jump = true))
    state.setSourceValue(KNOB_B, 0.2)
    check state.flushMatrix(knobContext()).learned
    check state.rows[0].sourceId == KNOB_B

  test "a knob does not qualify for a gesture slot":
    var state = probeState()
    state.armLearn(fireRow("", "reseedField"))
    state.setSourceValue(KNOB_A, 0.9)
    check not state.flushMatrix(knobContext()).learned
    check state.learnState().armed
    check state.rows.len == 0

  test "an event does not qualify for a continuous slot":
    var state = probeState()
    state.armLearn(writeRow("", "fluidStrength", jump = true))
    state.emitSourceEvent(PAD, 1.0, 36)
    check not state.flushMatrix(knobContext()).learned
    check state.learnState().armed
    check state.rows.len == 0

  test "cancel leaves the mapping as it was":
    var state = probeState()
    state.setRows(@[writeRow(KNOB_B, "rdFieldForce", jump = true)])
    state.armLearn(writeRow("", "fluidStrength", jump = true))
    state.cancelLearn()
    check not state.learnState().armed
    state.setSourceValue(KNOB_A, 0.9)
    check not state.flushMatrix(knobContext()).learned
    check state.rows.len == 1
    check state.rows[0].sourceId == KNOB_B

  test "an arming waits as long as it takes":
    var state = probeState()
    state.armLearn(writeRow("", "fluidStrength", jump = true))
    for frame in 0 ..< 50:
      check not state.flushMatrix(knobContext()).learned
    check state.learnState().armed
    check state.learnState().slot.kind == rkWrite
    check state.rows.len == 0

suite "actionOf resolves every action the boundary serves":
  test "the six named regimes resolve under the regime prefix with their id as payload":
    for regime in RD_REGIMES:
      let resolved = actionOf("regime:" & regime.id)
      check resolved.found
      check resolved.kind == akRegime
      check resolved.payload == regime.id

  test "the momentary and toggle actions resolve to their own kinds with no payload":
    const expected = {
      "randomizeMatrix": akRandomizeMatrix,
      "resetParticles": akResetParticles,
      "reseedField": akReseedField,
      "toggleTrails": akToggleTrails,
      "toggleBloom": akToggleBloom,
      "toggleClimateDrift": akToggleClimateDrift,
      "toggleForceWeather": akToggleForceWeather,
      "toggleCameraDrift": akToggleCameraDrift,
    }
    for (id, kind) in expected:
      let resolved = actionOf(id)
      check resolved.found
      check resolved.kind == kind
      check resolved.payload == ""

  test "an id no action serves resolves to nothing":
    check not actionOf("").found
    check not actionOf("regime:").found
    check not actionOf("toggleEverything").found

  test "ACTION_IDS lists exactly the ids actionOf resolves":
    check ACTION_IDS.len == RD_REGIMES.len + 8
    for id in ACTION_IDS:
      check actionOf(id).found

# ------------------------------------------------------------------------------
# The flush is the frame's only parameter writer
# ------------------------------------------------------------------------------
#
# A sweep over src/app.nim, in tests/test_no_modes.nim's shape: it reads real
# source from disk and asserts the read found real source, so a sweep over a
# missing or moved file cannot pass by finding nothing. The path is taken off
# this file's own location rather than the working directory.

const APP_SOURCE_PATH =
  currentSourcePath().parentDir.parentDir / "src" / "app.nim"

const FRAME_PARAM_WRITERS = [
  "setClimateFromSimulation",
  "setForceWeatherFromSimulation",
]
  ## The per-frame parameter writers the two weather branches called. Both
  ## weathers are Tour rows now, so the flush writes their axes and nothing in
  ## the loop writes a parameter beside it.

const FLUSH_CALL = "flushMatrix"

suite "the flush is the frame loop's only parameter writer":
  test "src/app.nim calls the matrix flush":
    let source = readFile(APP_SOURCE_PATH)
    # The sweep looked at real source: the file is there, it is not empty, and
    # it holds a string it must hold and none of a string it must not. The
    # predicates land in locals so a failure names the predicate rather than
    # printing the whole file.
    let holdsFrameLoop = "proc loop" in source
    let holdsNothing = "proc loopThatNeverExisted" in source
    let callsFlush = FLUSH_CALL in source
    check source.len > 0
    check holdsFrameLoop
    check not holdsNothing
    check callsFlush

  test "no parameter writer stands beside the flush in src/app.nim":
    let source = readFile(APP_SOURCE_PATH)
    let holdsFrameLoop = "proc loop" in source
    check source.len > 0
    check holdsFrameLoop
    var offenders: seq[string]
    for writer in FRAME_PARAM_WRITERS:
      if writer in source:
        offenders.add writer
    if offenders.len > 0:
      checkpoint("frame-loop parameter writers still present: " &
        offenders.join(", "))
    check offenders.len == 0

# ------------------------------------------------------------------------------
# The modulation base
# ------------------------------------------------------------------------------
#
# A Modulate row offsets from what the user stored, so the base is read from the
# state records and never from the mirror the previous frame's effective value
# already landed in. The second test drives the same rows off the mirror, which
# is what the first one must be able to tell apart.

const WEB_API_SOURCE_PATH =
  currentSourcePath().parentDir.parentDir / "src" / "web_api.nim"

suite "the modulation base is the stored record":
  const
    HELD_FRAMES = 600
    BASE_TOLERANCE = 1e-9

  test "a held source produces the same excursion and effective value on every consecutive flush":
    var sim = initSimulationState()
    sim.fluidStrength = 0.0
    let render = initRenderState()
    # The CONFIG mirror's stand-in: the effective value lands here every frame.
    var world = sim
    let descriptor = descriptors["fluidStrength"]
    let expectedValue = valueAt(descriptor,
      positionOf(descriptor, 0.0) + AUDIO_BASS_DEPTH)
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", AUDIO_BASS_DEPTH,
      releaseMs = AUDIO_RELEASE_MS)])

    var divergentFrame = 0
    var seenExcursion = 0.0
    var seenWorld = 0.0
    for frame in 1 .. HELD_FRAMES:
      state.setSourceValue(KNOB_A, 1.0)
      let outcome = state.flushMatrix(contextOf(FRAME_60,
        @[("fluidStrength", storedContext(descriptor, sim, render))]))
      if "fluidStrength" in outcome.effective:
        discard assignParamField(world, "fluidStrength",
          outcome.effective["fluidStrength"])
      seenExcursion = outcome.excursions.getOrDefault("fluidStrength", 0.0)
      seenWorld = world.fluidStrength
      if abs(seenExcursion - AUDIO_BASS_DEPTH) > BASE_TOLERANCE or
          abs(seenWorld - expectedValue) > BASE_TOLERANCE:
        divergentFrame = frame
        break
    if divergentFrame > 0:
      checkpoint("first divergent frame: " & $divergentFrame)
    checkNear(seenExcursion, AUDIO_BASS_DEPTH, BASE_TOLERANCE)
    checkNear(seenWorld, expectedValue, BASE_TOLERANCE)
    checkNear(sim.fluidStrength, 0.0, BASE_TOLERANCE)

  test "a base read from the world ratchets to the track end within a handful of frames":
    var sim = initSimulationState()
    sim.fluidStrength = 0.0
    let render = initRenderState()
    var world = sim
    let descriptor = descriptors["fluidStrength"]
    var state = probeState()
    state.setRows(@[modulateRow(KNOB_A, "fluidStrength", AUDIO_BASS_DEPTH,
      releaseMs = AUDIO_RELEASE_MS)])
    # Full travel takes one frame per depth, and the frame after the clamp lands
    # carries no excursion.
    let settledFrame = int(ceil(1.0 / AUDIO_BASS_DEPTH)) + 1

    var divergentFrame = 0
    var lingeringFrame = 0
    var seenWorld = 0.0
    var expectedWorld = 0.0
    for frame in 1 .. HELD_FRAMES:
      state.setSourceValue(KNOB_A, 1.0)
      let previous = world.fluidStrength
      let outcome = state.flushMatrix(contextOf(FRAME_60,
        @[("fluidStrength", storedContext(descriptor, world, render))]))
      if "fluidStrength" in outcome.effective:
        discard assignParamField(world, "fluidStrength",
          outcome.effective["fluidStrength"])
      if lingeringFrame == 0 and frame >= settledFrame and
          "fluidStrength" in outcome.excursions:
        lingeringFrame = frame
      expectedWorld = valueAt(descriptor,
        clamp(positionOf(descriptor, previous) + AUDIO_BASS_DEPTH, 0.0, 1.0))
      seenWorld = world.fluidStrength
      if abs(seenWorld - expectedWorld) > BASE_TOLERANCE:
        divergentFrame = frame
        break
    if divergentFrame > 0:
      checkpoint("first divergent frame: " & $divergentFrame)
    checkNear(seenWorld, expectedWorld, BASE_TOLERANCE)
    if lingeringFrame > 0:
      checkpoint("excursion still offered at frame " & $lingeringFrame &
        ", expected none from frame " & $settledFrame)
    check lingeringFrame == 0
    checkNear(world.fluidStrength, FLUID_STRENGTH_MAX, BASE_TOLERANCE)

  test "web_api builds the modulation base through storedContext and never from CONFIG":
    let source = readFile(WEB_API_SOURCE_PATH)
    let readsMirror = "readParamField(CONFIG" in source
    let buildsFromSimAndRender =
      "storedContext(descriptor, currentSimulation, currentRender)" in source
    check source.len > 0
    if readsMirror:
      checkpoint("web_api still reads a param field out of CONFIG")
    check not readsMirror
    if not buildsFromSimAndRender:
      checkpoint("web_api names no storedContext(descriptor, currentSimulation, " &
        "currentRender) call")
    check buildsFromSimAndRender
