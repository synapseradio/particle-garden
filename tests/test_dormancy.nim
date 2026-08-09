# Dormancy: what a predicate READS is checked here (named fields walked
# against the state records, so a rename breaks loudly); what it MEANS is
# review-enforced. Horizons: executable exactly where a stepping mirror
# exists — the field parameters run through the stepped alive-fraction
# harness, every other non-instant declaration carries the review label,
# and this suite holds the labels to that rule in both directions.

import std/[sets, tables, unittest]

const DORMANCY_TESTS_LOADED* = true

import ../src/config_ranges
import ../src/ui/api/dormancy
import ../src/ui/api/param_descriptor
import ../src/ui/api/response_probe
import ../src/ui/state/render_state
import ../src/ui/state/simulation_state

let descriptors = buildParamDescriptors()
let predicates = dormancyRegistry()

proc recordFieldNames[T](record: T): HashSet[string] =
  for name, value in fieldPairs(record):
    result.incl name

let simFields = recordFieldNames(initSimulationState())
let renderFields = recordFieldNames(initRenderState())

suite "Dormancy Predicates Name Real State":
  test "every carried dormantWhen resolves to a registered predicate":
    for descriptor in descriptors:
      if descriptor.dormantWhen.len > 0:
        if descriptor.dormantWhen notin predicates:
          checkpoint(descriptor.id & " names unregistered predicate \"" &
            descriptor.dormantWhen & "\"")
        check descriptor.dormantWhen in predicates

  test "every registered predicate is carried by some descriptor":
    var carried = initHashSet[string]()
    for descriptor in descriptors:
      if descriptor.dormantWhen.len > 0:
        carried.incl descriptor.dormantWhen
    for id in predicates.keys:
      if id notin carried:
        checkpoint("predicate \"" & id & "\" is carried by no descriptor")
      check id in carried

  test "every named simulation field exists on the state record":
    for predicate in predicates.values:
      for fieldName in predicate.simFields:
        if fieldName notin simFields:
          checkpoint(predicate.id & " names missing sim field " & fieldName)
        check fieldName in simFields

  test "every named render field exists on the state record":
    for predicate in predicates.values:
      for fieldName in predicate.renderFields:
        if fieldName notin renderFields:
          checkpoint(predicate.id & " names missing render field " &
            fieldName)
        check fieldName in renderFields

  test "every named world signal is one the stats push carries":
    for predicate in predicates.values:
      for fieldName in predicate.statsFields:
        check fieldName in StatsWorldSignals

  test "a control never goes dormant under its own value alone":
    # A predicate whose only input is its carrier dims the one control that
    # is the way out. Reading the carrier stays legal inside a compound the
    # carrier's own movement can break (the feed/kill pair; the
    # supercritical-wake test below pins that escape hatch).
    for descriptor in descriptors:
      if descriptor.dormantWhen.len == 0:
        continue
      let predicate = predicates[descriptor.dormantWhen]
      let inputs = predicate.simFields & predicate.renderFields &
        predicate.statsFields
      if descriptor.id in inputs:
        checkpoint(descriptor.id & " reads its own value through \"" &
          predicate.id & "\" — legal only inside a breakable compound")
        check inputs.len > 1

  test "every predicate carries the line the panel shows":
    for predicate in predicates.values:
      check predicate.line.len > 0

proc witness(pairs: openArray[(string, float)]): Table[string, float] =
  for (key, value) in pairs:
    result[key] = value

suite "Each Predicate Distinguishes Dormant From Awake":
  test "the strength-family predicates fire at zero and only at zero":
    for (id, fieldName) in [("forceOff", "forceStrength"),
        ("fluidOff", "fluidStrength"), ("depositOff", "rdDeposit"),
        ("tropismOff", "rdFieldForce")]:
      check predicates[id].eval(witness({fieldName: 0.0}))
      check not predicates[id].eval(witness({fieldName: 0.4}))

  test "bloomOff reads the toggle":
    check predicates["bloomOff"].eval(witness({"bloomEnabled": 0.0}))
    check not predicates["bloomOff"].eval(witness({"bloomEnabled": 1.0}))

  test "fieldUnlit reads the alive-cell census":
    check predicates["fieldUnlit"].eval(witness({"fieldAliveCells": 0.0}))
    check not predicates["fieldUnlit"].eval(
      witness({"fieldAliveCells": 3.0}))

  test "the compound predicate is dormant only while dark AND subcritical":
    let compound = predicates["fieldSubcritical"]
    # Dark and subcritical (a named-regime-like coordinate): dormant.
    check compound.eval(witness({
      "fieldAliveCells": 0.0, "rdFeed": 0.03, "rdKill": 0.06}))
    # Lit at the same coordinate: awake — the line speaks only while the
    # field is dark, never about the coordinates being barren.
    check not compound.eval(witness({
      "fieldAliveCells": 5.0, "rdFeed": 0.03, "rdKill": 0.06}))

  test "the compound predicate wakes in the supercritical region before ignition":
    # A user who moves into F >= 4(F+k)^2 has chosen a self-starting
    # climate, so the pair leaves dormancy the moment the condition breaks —
    # before anything ignites.
    check not predicates["fieldSubcritical"].eval(witness({
      "fieldAliveCells": 0.0, "rdFeed": 0.08, "rdKill": 0.02}))

proc regimeNamed(id: string): typeof(RD_REGIMES[0]) =
  for entry in RD_REGIMES:
    if entry.id == id:
      return entry
  raiseAssert "no regime named " & id

suite "Horizons Are Executable Where A Mirror Steps":
  # The structural claim made executable: FieldProbeFrames frames of the
  # shipped frame shape, on the worms regime — partner at the named point,
  # deposit floored at the regime's measured minimum.

  let probes = probeRegistry()
  let worms = regimeNamed("worms")

  proc wormsContext(): ProbeContext =
    result = defaultProbeContext()
    result.sim.rdFeed = worms.feed
    result.sim.rdKill = worms.kill
    result.sim.rdDeposit = max(result.sim.rdDeposit, worms.minDeposit)

  test "moving feed moves the alive fraction within the stepping window":
    let fn = probes["field.aliveFraction.feed"].fn
    let atPoint = fn(worms.feed, wormsContext())
    let atFloor = fn(RD_FEED_MIN, wormsContext())
    checkpoint("alive at worms feed " & $atPoint & ", at floor " & $atFloor)
    check abs(atPoint - atFloor) > 0.01

  test "moving kill moves the alive fraction within the stepping window":
    let fn = probes["field.aliveFraction.kill"].fn
    let atPoint = fn(worms.kill, wormsContext())
    let atCeiling = fn(RD_KILL_MAX, wormsContext())
    checkpoint("alive at worms kill " & $atPoint & ", at ceiling " &
      $atCeiling)
    check abs(atPoint - atCeiling) > 0.01

  test "moving the deposit moves the alive fraction within the stepping window":
    # The regime-floor phenomenon: worms without its deposit floor measures
    # a dead world, so the deposit's structural horizon is executable
    # through the same harness.
    let fn = probes["field.aliveFraction.feed"].fn
    var bare = wormsContext()
    bare.sim.rdDeposit = 0.0
    let withFloor = fn(worms.feed, wormsContext())
    let without = fn(worms.feed, bare)
    checkpoint("alive with floor " & $withFloor & ", without " & $without)
    check abs(withFloor - without) > 0.01

  test "every non-instant horizon without the stepping mirror is review-labelled":
    const SteppingExecuted = ["rdFeed", "rdKill", "rdDeposit"]
    for descriptor in descriptors:
      if descriptor.horizon == rhInstant:
        check not descriptor.horizonReview
        continue
      if descriptor.id in SteppingExecuted:
        # This suite executes these above, so their claim carries no label.
        check not descriptor.horizonReview
      else:
        if not descriptor.horizonReview:
          checkpoint(descriptor.id & " declares a non-instant horizon " &
            "with no stepping mirror and no review label")
        check descriptor.horizonReview

  test "every render-store parameter answers instantly":
    for descriptor in descriptors:
      if descriptor.store in {psRender, psPalette, psCamera}:
        check descriptor.horizon == rhInstant
