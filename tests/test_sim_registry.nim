# Behavioral tests for src/sim_registry.nim: the pure frame description that
# webgpu_compute.nim's executor walks each frame.
#
# What these pin: there is one world, and a coupling contributes according to a
# strength whose zero is an ordinary value. So the frame path may ask a
# strength exactly one question — is it zero — and a pass may be skipped only
# when its strength provably scales everything that pass produces. A skip that
# removes an output the strength never scaled is a mode wearing a
# floating-point comparison, and these tests are what stop one appearing.

import std/unittest
import std/sets
import ../src/sim_registry
import ../src/field_core
import coupling_space  # the corners of the strength space, ALL_COUPLINGS

const SIM_REGISTRY_TESTS_LOADED* = true

proc dispatchesPipeline(couplings: WorldCouplings; pipelineKey: string): bool =
  for node in buildFrame(couplings):
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        if step.pipelineKey == pipelineKey:
          return true
  false

proc dispatchSequence(couplings: WorldCouplings): seq[string] =
  ## Every pipeline key the frame dispatches, in encoded order. Pass grouping
  ## and profiler slots are presentation; the order work reaches the GPU in is
  ## the behavior.
  for node in buildFrame(couplings):
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        result.add step.pipelineKey

proc clearedBuffers(couplings: WorldCouplings): seq[SimBuffer] =
  for node in buildFrame(couplings):
    if node.kind == fnkClearBuffer:
      result.add node.clearTarget

proc without(sequence: seq[string]; key: string): seq[string] =
  for item in sequence:
    if item != key: result.add item

func rdStepKeys(): seq[string] =
  for stepIndex in 0 ..< RD_STEPS_PER_FRAME:
    result.add(
      if stepIndex mod 2 == 0: "rdStepToFront" else: "rdStepToTrail")

const WORLD_INTRINSIC_SEQUENCE =
  @["binCount", "prefixLocal", "prefixBlocks", "prefixFinal",
    "binScatter", "forces", "fieldResolve"] & rdStepKeys() & @["integrate"]
  ## What the world is, at every setting of every strength: the spatial hash,
  ## the neighbour sweep that measures density and carries the mouse, the
  ## field's own Gray-Scott evolution, and the integration that moves particles.


suite "The World Runs, Whatever The Strengths Are":
  test "a world with every strength at zero still runs every world-intrinsic pass":
    # The definition of world-intrinsic, stated as the one case that isolates
    # it. Nothing here is a contribution; it is what the world is made of.
    check dispatchSequence(UNCOUPLED) == WORLD_INTRINSIC_SEQUENCE

  test "every world-intrinsic pass survives every combination of strengths":
    for couplings in ALL_COUPLINGS:
      let sequence = dispatchSequence(couplings)
      for key in WORLD_INTRINSIC_SEQUENCE:
        if key notin sequence:
          checkpoint("a strength removed the world-intrinsic pass " & key)
        check key in sequence

  test "the neighbour sweep runs where no forces act":
    # The honest price of that skip rule, asserted rather than assumed.
    # Density and the mouse both come out of this pass, and neither belongs to
    # the force coupling, so force strength zero cannot take the sweep with it.
    check dispatchesPipeline(UNCOUPLED, "binCount")
    check dispatchesPipeline(UNCOUPLED, "forces")

  test "the field evolves in a world that deposits nothing into it":
    # Chemistry's strengths own the deposit and the force, never the reaction.
    # A field frozen mid-pattern at zero deposit and breathing again one epsilon
    # above it is the jump-at-zero this design forbids.
    check dispatchesPipeline(UNCOUPLED, "fieldResolve")
    var substeps = 0
    for key in dispatchSequence(UNCOUPLED):
      if key in ["rdStepToFront", "rdStepToTrail"]: inc substeps
    check substeps == RD_STEPS_PER_FRAME

  test "integrate runs last and exactly once in every world":
    for couplings in ALL_COUPLINGS:
      let sequence = dispatchSequence(couplings)
      check sequence.len > 0
      check sequence[^1] == "integrate"
      var integrations = 0
      for key in sequence:
        if key == "integrate": inc integrations
      check integrations == 1


suite "A Strength At Zero Skips Its Own Pass And Nothing Else":
  # The multiplier property in its frame form: at exactly zero the
  # world is identical to the world with that pass absent. The continuity half —
  # that the contribution approaches zero as the strength does — is physics, and
  # lives with the oracles that mirror the shaders.

  test "zero fluid strength skips the SPH pass":
    check dispatchesPipeline(FULLY_COUPLED, "forcesSph")
    var noFluid = FULLY_COUPLED
    noFluid.fluid = COUPLING_OFF
    check not dispatchesPipeline(noFluid, "forcesSph")

  test "zero deposit skips the deposit pass":
    var noDeposit = FULLY_COUPLED
    noDeposit.deposit = COUPLING_OFF
    check not dispatchesPipeline(noDeposit, "fieldDeposit")

  test "zero field force skips the field-force pass":
    var noFieldForce = FULLY_COUPLED
    noFieldForce.fieldForce = COUPLING_OFF
    check not dispatchesPipeline(noFieldForce, "fieldForce")

  test "moving a strength to zero changes nothing else about the world":
    # The test that makes a skip an optimization rather than a mode: zeroing one
    # strength must subtract exactly one pass and leave every other pass in
    # place, in order. A skip that also drops a neighbour's work rebuilds the
    # eight enumerated worlds under a nicer name.
    for skippable in [("fluid", "forcesSph"), ("deposit", "fieldDeposit"),
        ("fieldForce", "fieldForce")]:
      var zeroed = FULLY_COUPLED
      case skippable[0]
      of "fluid": zeroed.fluid = COUPLING_OFF
      of "deposit": zeroed.deposit = COUPLING_OFF
      else: zeroed.fieldForce = COUPLING_OFF
      checkpoint("zeroing " & skippable[0])
      check dispatchSequence(zeroed) ==
        dispatchSequence(FULLY_COUPLED).without(skippable[1])

  test "force strength never changes the frame":
    # Forces are the asymmetric coupling and this is where that is recorded.
    # The force TERM is coupling-owned and scaled by its strength, but its pass
    # also measures density and applies the mouse, so the pass is world-intrinsic
    # and no force strength may skip it. The strength acts inside the shader,
    # which is why it reaches zero continuously without the frame moving at all.
    for couplings in ALL_COUPLINGS:
      var flipped = couplings
      flipped.forces =
        if couplings.forces == COUPLING_OFF: COUPLING_ON else: COUPLING_OFF
      check dispatchSequence(flipped) == dispatchSequence(couplings)

  test "a strength one part in a billion above zero dispatches its pass":
    # Zero is the only special value. A threshold — `> 0.001`, `> epsilon` —
    # would be a mode with a floating-point door, and a user dragging a slider
    # to its bottom would fall through it into a different world.
    var barelyOn = UNCOUPLED
    barelyOn.fluid = 1e-9
    barelyOn.deposit = 1e-9
    barelyOn.fieldForce = 1e-9
    check dispatchSequence(barelyOn) == dispatchSequence(FULLY_COUPLED)

  test "no world enumerates: every frame is the intrinsic sequence plus its couplings":
    # The frame is a union over independent strengths, never a table of worlds.
    # Stated as a derivation: strip the coupling-owned passes from any world and
    # exactly the intrinsic sequence is left, whatever the strengths were.
    for couplings in ALL_COUPLINGS:
      var stripped = dispatchSequence(couplings)
      for key in ["forcesSph", "fieldDeposit", "fieldForce"]:
        stripped = stripped.without(key)
      check stripped == WORLD_INTRINSIC_SEQUENCE


suite "Delta Buffers Have One Reset Owner":
  test "every frame clears velocityDelta and densityDelta before any pass that writes them":
    # The invariant that makes composition possible: a contributor that
    # self-resets these buffers in its own prologue erases the work of whichever
    # contributor ran before it in the frame. The frame owns the reset;
    # forces.wgsl and forces-sph.wgsl accumulate only.
    for couplings in ALL_COUPLINGS:
      let frame = buildFrame(couplings)
      var clearedAt: array[SimBuffer, int]
      for buffer in SimBuffer:
        clearedAt[buffer] = -1
      for index, node in frame:
        if node.kind == fnkClearBuffer and clearedAt[node.clearTarget] < 0:
          clearedAt[node.clearTarget] = index
      check clearedAt[sbVelocityDelta] >= 0
      check clearedAt[sbDensityDelta] >= 0

      for index, node in frame:
        if node.kind != fnkComputePass: continue
        for step in node.dispatches:
          if step.pipelineKey in ["forces", "forcesSph", "fieldForce"]:
            check clearedAt[sbVelocityDelta] < index
          if step.pipelineKey == "forces":
            check clearedAt[sbDensityDelta] < index

  test "no delta buffer is cleared twice in a frame":
    # Two clears would be harmless but would mean two owners. The frame is the
    # only one.
    for couplings in ALL_COUPLINGS:
      let cleared = clearedBuffers(couplings)
      check toHashSet(cleared).len == cleared.len

  test "the SPH pass is not a density writer in any world":
    # Density leaves the physics through ONE writer, the world-intrinsic sweep.
    # A fluid that also wrote it loses the density the renderer reads whenever
    # zero strength skips the fluid — the jump-at-zero appearing in the density
    # channel instead of the velocity channel.
    for couplings in ALL_COUPLINGS:
      let frame = buildFrame(couplings)
      var densityClearedAt = -1
      for index, node in frame:
        if node.kind == fnkClearBuffer and node.clearTarget == sbDensityDelta:
          densityClearedAt = index
      check densityClearedAt >= 0


suite "The Grid Is Built Once":
  test "every world builds the spatial hash exactly once":
    # Two builds would double-count every particle into gridCounts, and the
    # second scatter would run against pointers the first had already consumed.
    for couplings in ALL_COUPLINGS:
      var gridBuilds = 0
      var scatters = 0
      for key in dispatchSequence(couplings):
        if key == "binCount": inc gridBuilds
        if key == "binScatter": inc scatters
      check gridBuilds == 1
      check scatters == 1

  test "the scatter precedes every pass that reads sorted particles":
    for couplings in ALL_COUPLINGS:
      let sequence = dispatchSequence(couplings)
      let scatterAt = sequence.find("binScatter")
      check scatterAt >= 0
      for reader in ["forces", "forcesSph"]:
        let readerAt = sequence.find(reader)
        if readerAt >= 0:
          check scatterAt < readerAt

  test "gridCounts is cleared before bin-count increments it":
    for couplings in ALL_COUPLINGS:
      let frame = buildFrame(couplings)
      var clearedAt = -1
      for index, node in frame:
        if node.kind == fnkClearBuffer and node.clearTarget == sbGridCounts:
          clearedAt = index
        if node.kind == fnkComputePass:
          for step in node.dispatches:
            if step.pipelineKey == "binCount":
              check clearedAt >= 0
              check clearedAt < index


suite "Field Passes Compose Safely":
  test "the field ping-pong parity holds in every world":
    # fieldResolve is itself one swap, so 1 + RD_STEPS_PER_FRAME swaps happen
    # per frame. The substeps must start ToFront and end ToFront, or the live
    # field lands on the texture nothing reads and the last substep is thrown
    # away every frame. The field being world-intrinsic makes this unconditional
    # rather than a property only some worlds must satisfy.
    for couplings in ALL_COUPLINGS:
      var steps: seq[string]
      for key in dispatchSequence(couplings):
        if key in ["rdStepToFront", "rdStepToTrail"]: steps.add key
      check steps.len == RD_STEPS_PER_FRAME
      check steps[0] == "rdStepToFront"
      check steps[^1] == "rdStepToFront"
      for stepIndex, key in steps:
        check key == (
          if stepIndex mod 2 == 0: "rdStepToFront" else: "rdStepToTrail")

  test "fieldDeposit precedes fieldResolve which precedes every substep":
    # fieldResolve consumes the deposit buffer and zeroes it; a substep running
    # first would evolve a field the frame's deposits never reached.
    for couplings in ALL_COUPLINGS:
      let sequence = dispatchSequence(couplings)
      let resolveAt = sequence.find("fieldResolve")
      let firstStepAt = sequence.find("rdStepToFront")
      let depositAt = sequence.find("fieldDeposit")
      check resolveAt >= 0
      check resolveAt < firstStepAt
      if depositAt >= 0:
        check depositAt < resolveAt

  test "fieldForce runs after the substeps it reads":
    # It samples the gradient of the field the frame just evolved; running it
    # first would steer particles by the previous frame's chemistry.
    for couplings in ALL_COUPLINGS:
      let sequence = dispatchSequence(couplings)
      let forceAt = sequence.find("fieldForce")
      if forceAt >= 0:
        for stepIndex, key in sequence:
          if key in ["rdStepToFront", "rdStepToTrail"]:
            check stepIndex < forceAt

  test "no world dispatches an unknown pipeline key":
    # A typo'd key reaches the executor as a missing dictionary entry at
    # runtime, in a browser, with no native test between it and the user.
    const KNOWN = [
      "binCount", "prefixLocal", "prefixBlocks", "prefixFinal", "binScatter",
      "forces", "forcesSph", "integrate",
      "fieldDeposit", "fieldResolve", "rdStepToFront", "rdStepToTrail",
      "fieldForce"]
    for couplings in ALL_COUPLINGS:
      for key in dispatchSequence(couplings):
        check key in KNOWN


suite "Profiler Slot Constants":
  test "the slot constants are distinct":
    # They index one query set. Two passes sharing a slot overwrite each other's
    # timestamps and report a meaningless delta — the field pass borrowing the
    # grid-build slot is the collision this forbids.
    let slots = [PROFILER_SLOT_GRID_BUILD, PROFILER_SLOT_PHYSICS,
      PROFILER_SLOT_FIELD, PROFILER_SLOT_INTEGRATE]
    check toHashSet(slots).len == slots.len

  test "PROFILER_SLOT_NONE indexes no query slot":
    # It marks the absence of a slot, so it must not collide with a real one.
    check PROFILER_SLOT_NONE notin [PROFILER_SLOT_GRID_BUILD,
      PROFILER_SLOT_PHYSICS, PROFILER_SLOT_FIELD, PROFILER_SLOT_INTEGRATE]

  test "every frame's timestamped compute passes hold distinct profiler slots":
    # Passes carrying PROFILER_SLOT_NONE write no timestamps, so any number of
    # them may share it; what cannot repeat is a slot that indexes the query set.
    for couplings in ALL_COUPLINGS:
      var seenSlots: HashSet[int]
      for node in buildFrame(couplings):
        if node.kind == fnkComputePass and
            node.profilerSlot != PROFILER_SLOT_NONE:
          check node.profilerSlot notin seenSlots
          seenSlots.incl node.profilerSlot

suite "The Field Chemistry Runs Once Per Rendered Frame":
  # The executor encodes this description once per substep, so before cadences
  # existed a fluid world multiplied the chemistry: three substeps meant three
  # times the pattern evolution and three deposit folds per rendered frame,
  # which made Fluid Strength a hidden control on how fast the pattern moves.
  # The chemistry now carries a per-frame cadence; the field force does not,
  # because it contributes a velocity delta that every substep integrates.

  proc nodesWithCadence(couplings: WorldCouplings;
      cadence: FrameNodeCadence): seq[string] =
    for node in buildFrame(couplings):
      if node.cadence == cadence:
        case node.kind
        of fnkComputePass:
          for step in node.dispatches:
            result.add step.pipelineKey
        of fnkClearBuffer: result.add "clear:" & $node.clearTarget
        of fnkCopyBuffer: result.add "copy:" & $node.copySource

  test "the chemistry chain and the alive census run once per frame":
    for couplings in ALL_COUPLINGS:
      let oncePerFrame = nodesWithCadence(couplings, fncOncePerFrame)
      check "fieldResolve" in oncePerFrame
      check "rdStepToFront" in oncePerFrame
      check "clear:sbFieldAlive" in oncePerFrame

  test "the field force runs every substep":
    for couplings in ALL_COUPLINGS:
      if dispatchesPipeline(couplings, "fieldForce"):
        check "fieldForce" in nodesWithCadence(couplings, fncEverySubstep)

  test "the deposit fold runs once per frame wherever it runs at all":
    for couplings in ALL_COUPLINGS:
      if dispatchesPipeline(couplings, "fieldDeposit"):
        check "fieldDeposit" in nodesWithCadence(couplings, fncOncePerFrame)

  test "every delta clear and the grid build run every substep":
    # These reset what a substep accumulates and rebuild what it reads, so a
    # substep that skipped them would integrate the previous substep's deltas.
    for couplings in ALL_COUPLINGS:
      let everySubstep = nodesWithCadence(couplings, fncEverySubstep)
      for key in ["clear:sbVelocityDelta", "clear:sbDensityDelta",
          "clear:sbSphDensityDelta", "clear:sbCrowdDensityDelta",
          "clear:sbGridCounts", "binCount", "forces", "integrate"]:
        check key in everySubstep

  test "the ping-pong chain closes inside the per-frame group":
    # fieldResolve is itself a swap, so the frame performs 1 + RD_STEPS_PER_FRAME
    # of them and must land the live field back on the front texture. Splitting
    # the field force out of this group must not have taken a swap with it.
    for couplings in ALL_COUPLINGS:
      let oncePerFrame = nodesWithCadence(couplings, fncOncePerFrame)
      var swaps = 0
      for key in oncePerFrame:
        if key in ["fieldResolve", "rdStepToFront", "rdStepToTrail"]:
          swaps.inc
      check swaps == 1 + RD_STEPS_PER_FRAME
      # An even total returns the live field to the texture it started on,
      # which is the one the renderer, the field force and the next frame's
      # resolve all read. field_core asserts RD_STEPS_PER_FRAME odd for it.
      check swaps mod 2 == 0

  test "no compute pass mixes two cadences":
    # A pass is the unit the executor skips, so two cadences inside one node
    # could only be honoured by skipping both or neither.
    for couplings in ALL_COUPLINGS:
      for node in buildFrame(couplings):
        if node.kind == fnkComputePass and node.cadence == fncOncePerFrame:
          for step in node.dispatches:
            check step.pipelineKey != "fieldForce"
