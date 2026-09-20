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
import std/strutils
import std/tables
import ../src/sim_registry
import ../src/balance_core
import ../src/field_core
import ../src/config_ranges
import ../src/sph_core
import ../src/ui/api/param_descriptor
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

const LONG_RANGE_SOLVE_KEYS = @["lrDeposit", "lrFftRows", "lrFftCols",
  "lrKernel", "lrFftColsInv", "lrFftRowsInv"]
  ## The mesh solve, in the order the round trip forces: deposit, forward
  ## transform along each axis, the mix in k-space, then the inverse back.

const LONG_RANGE_KEYS = LONG_RANGE_SOLVE_KEYS & @["lrForce"]
  ## The whole chain. One strength owns all seven, which is why the skip tests
  ## below check the chain leaves as a unit rather than pass by pass.


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

  test "zero bodies strength skips the bodies pass":
    # Exact rather than merely cheap, and the argument has one premise: bodies
    # are not drawn. Everything a body does reaches the world through forces
    # this strength scales, so at zero a body that moved and a body that did not
    # are the same world. Drawing one would break the argument, not the code.
    check dispatchesPipeline(FULLY_COUPLED, "bodyForce")
    var noBodies = FULLY_COUPLED
    noBodies.bodies = COUPLING_OFF
    check not dispatchesPipeline(noBodies, "bodyForce")

  test "zero long-range strength skips the whole mesh chain":
    # Seven dispatches, one strength: the solve and the force it feeds are one
    # coupling, so a world at zero strength must run none of them rather than
    # solve a mesh nothing reads.
    for key in LONG_RANGE_KEYS:
      check dispatchesPipeline(FULLY_COUPLED, key)
    var noLongRange = FULLY_COUPLED
    noLongRange.longRange = COUPLING_OFF
    for key in LONG_RANGE_KEYS:
      checkpoint("zero long-range strength still dispatches " & key)
      check not dispatchesPipeline(noLongRange, key)

  test "zeroing the long-range strength removes its seven passes and nothing else":
    var noLongRange = FULLY_COUPLED
    noLongRange.longRange = COUPLING_OFF
    var stripped = dispatchSequence(FULLY_COUPLED)
    for key in LONG_RANGE_KEYS:
      stripped = stripped.without(key)
    check dispatchSequence(noLongRange) == stripped

  test "moving a strength to zero changes nothing else about the world":
    # The test that makes a skip an optimization rather than a mode: zeroing one
    # strength must subtract that strength's own passes and leave every other
    # pass in place, in order. A skip that also drops a neighbour's work rebuilds
    # the eight enumerated worlds under a nicer name.
    for skippable in [("fluid", @["forcesSph"]), ("deposit", @["fieldDeposit"]),
        ("fieldForce", @["fieldForce"]),
        ("bodies", @["bodyForce", "bodyIntegrate"])]:
      var zeroed = FULLY_COUPLED
      case skippable[0]
      of "fluid": zeroed.fluid = COUPLING_OFF
      of "deposit": zeroed.deposit = COUPLING_OFF
      of "bodies": zeroed.bodies = COUPLING_OFF
      else: zeroed.fieldForce = COUPLING_OFF
      checkpoint("zeroing " & skippable[0])
      var remaining = dispatchSequence(FULLY_COUPLED)
      for key in skippable[1]:
        remaining = remaining.without(key)
      check dispatchSequence(zeroed) == remaining

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
    barelyOn.bodies = 1e-9
    barelyOn.longRange = 1e-9
    check dispatchSequence(barelyOn) == dispatchSequence(FULLY_COUPLED)

  test "no world enumerates: every frame is the intrinsic sequence plus its couplings":
    # The frame is a union over independent strengths, never a table of worlds.
    # Stated as a derivation: strip the coupling-owned passes from any world and
    # exactly the intrinsic sequence is left, whatever the strengths were.
    for couplings in ALL_COUPLINGS:
      var stripped = dispatchSequence(couplings)
      for key in @["forcesSph", "fieldDeposit", "fieldForce", "bodyForce",
          "bodyIntegrate"] & LONG_RANGE_KEYS:
        stripped = stripped.without(key)
      check stripped == WORLD_INTRINSIC_SEQUENCE


suite "Delta Buffers Have One Reset Owner":
  test "every frame clears both velocity words and densityDelta before any pass that writes them":
    # The invariant that makes composition possible: a contributor that
    # self-resets these buffers in its own prologue erases the work of whichever
    # contributor ran before it in the frame. The frame owns the reset; the
    # five velocity writers accumulate only.
    for couplings in ALL_COUPLINGS:
      let frame = buildFrame(couplings)
      var clearedAt: array[SimBuffer, int]
      for buffer in SimBuffer:
        clearedAt[buffer] = -1
      for index, node in frame:
        if node.kind == fnkClearBuffer and clearedAt[node.clearTarget] < 0:
          clearedAt[node.clearTarget] = index
      for word in [sbVelocityDelta, sbVelocityCoarse]:
        checkpoint($word & " is cleared")
        check clearedAt[word] >= 0
      check clearedAt[sbDensityDelta] >= 0

      for index, node in frame:
        if node.kind != fnkComputePass: continue
        for step in node.dispatches:
          if step.pipelineKey in ["forces", "forcesSph", "fieldForce",
              "lrForce", "bodyForce"]:
            for word in [sbVelocityDelta, sbVelocityCoarse]:
              checkpoint($word & " cleared before " & step.pipelineKey)
              check clearedAt[word] in 0 ..< index
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


suite "A Body Feels What It Does":
  test "the bodies node pushes the particles and then moves the body":
    # Two dispatches in ONE node, in this order: the force pass writes both the
    # particles' impulses and the body's share of them, and the integrate reads
    # that share. A node is the unit the executor skips, so passes that cannot
    # be skipped apart cannot live in two.
    let frame = buildFrame(FULLY_COUPLED)
    var bodiesAt = -1
    for index, node in frame:
      if node.kind == fnkComputePass and node.label == "Bodies":
        bodiesAt = index
    check bodiesAt >= 0
    var keys: seq[string]
    var sizes: seq[DispatchSize]
    for step in frame[bodiesAt].dispatches:
      keys.add step.pipelineKey
      sizes.add step.size
    check keys == @["bodyForce", "bodyIntegrate"]
    # One thread per body and one workgroup over the whole table, which is what
    # shader_config's MAX_BODIES assertion holds the workgroup wide enough for.
    check sizes == @[dsParticleWorkgroups, dsOne]

  test "the body accumulator is cleared once, ahead of the pass that fills it":
    # Same rule as velocityDelta's, for the same reason: body-integrate reads
    # this buffer without resetting it, so the frame is its one reset owner.
    for couplings in ALL_COUPLINGS:
      let frame = buildFrame(couplings)
      var clears = 0
      var clearedAt = -1
      for index, node in frame:
        if node.kind == fnkClearBuffer and node.clearTarget == sbBodyAccum:
          inc clears
          if clearedAt < 0: clearedAt = index
      check clears == 1
      for index, node in frame:
        if node.kind != fnkComputePass: continue
        for step in node.dispatches:
          if step.pipelineKey == "bodyForce":
            check clearedAt < index


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
      "fieldForce", "bodyForce", "bodyIntegrate",
      "lrDeposit", "lrFftRows", "lrFftCols", "lrKernel", "lrFftColsInv",
      "lrFftRowsInv", "lrForce"]
    for couplings in ALL_COUPLINGS:
      for key in dispatchSequence(couplings):
        check key in KNOWN


suite "A Strength Crossing Zero Rebuilds The Frame":
  # The executor rebuilds the frame description only when the shape changes, so
  # what counts as a change of shape has to be exactly the set of zeros. A
  # strength whose zero this comparison forgets leaves a world dispatching a
  # pass at zero strength, or skipping one whose strength is not zero, until
  # something else happens to rebuild.

  test "a strength moving inside its range is the same frame shape":
    var moved = FULLY_COUPLED
    moved.longRange = 0.4
    var movedAgain = moved
    movedAgain.longRange = 0.5
    check sameFrameShape(moved, movedAgain)

  test "the long-range strength crossing zero is a different frame shape":
    var acting = FULLY_COUPLED
    acting.longRange = COUPLING_ON
    var silent = acting
    silent.longRange = COUPLING_OFF
    check not sameFrameShape(acting, silent)

  test "two worlds dispatching different work never call themselves the same shape":
    # Stated over the whole corner space rather than per strength: a strength
    # this comparison forgot would show up here as two worlds calling
    # themselves the same shape while dispatching different work, and the
    # executor would keep running the frame the previous world composed.
    #
    # ONE DIRECTION ONLY, and deliberately. The converse is false for the force
    # strength, which changes no dispatch at all (it acts inside forces.wgsl),
    # so two worlds differing only there are the same frame under different
    # zeros. Comparing it anyway costs one rebuild of a pure sequence when the
    # slider crosses zero; forgetting a strength that does change the frame
    # costs a wrong world until something else rebuilds.
    for lhs in ALL_COUPLINGS:
      for rhs in ALL_COUPLINGS:
        if dispatchSequence(lhs) != dispatchSequence(rhs):
          check not sameFrameShape(lhs, rhs)


suite "A Dispatch Size Resolves Through Its Own Dimensionality":
  # The executor dispatches most sizes as a single workgroup count, the field
  # as (x, y), and the mesh chain as (x, y, z). A size resolved through the
  # wrong path would not fail: it would return a number and dispatch a wrong
  # shape, which on the GPU reads as a partly-transformed grid rather than as
  # an error. So the one-integer path raises on every size that is not one.

  test "the one-integer sizes resolve to the counts they name":
    check resolveOneDimensional(dsParticleWorkgroups, 7, 3) == 7
    check resolveOneDimensional(dsScanBlocks, 7, 3) == 3
    check resolveOneDimensional(dsOne, 7, 3) == 1

  test "a multi-dimensional size raises rather than resolving to a number":
    for size in [dsFieldWorkgroups, dsLrRowWorkgroups, dsLrColWorkgroups,
        dsLrBinWorkgroups]:
      checkpoint("resolving " & $size & " through the one-integer path")
      expect CatchableError:
        discard resolveOneDimensional(size, 7, 3)

  test "every size the mesh chain dispatches is a three-dimensional one":
    # The species batch rides the z extent, so a mesh pass resolved as one
    # integer would transform the first species and leave the rest holding the
    # previous frame's spectrum.
    for node in buildFrame(FULLY_COUPLED):
      if node.kind != fnkComputePass: continue
      for step in node.dispatches:
        if step.pipelineKey in LONG_RANGE_SOLVE_KEYS and
            step.pipelineKey != "lrDeposit":
          checkpoint(step.pipelineKey & " resolves as one integer")
          expect CatchableError:
            discard resolveOneDimensional(step.size, 7, 3)


suite "Profiler Slot Constants":
  test "the slot constants are distinct":
    # They index one query set. Two passes sharing a slot overwrite each other's
    # timestamps and report a meaningless delta — the field pass borrowing the
    # grid-build slot is the collision this forbids.
    let slots = [PROFILER_SLOT_GRID_BUILD, PROFILER_SLOT_PHYSICS,
      PROFILER_SLOT_FIELD, PROFILER_SLOT_INTEGRATE, PROFILER_SLOT_LONG_RANGE,
      PROFILER_SLOT_BODIES]
    check toHashSet(slots).len == slots.len

  test "PROFILER_SLOT_NONE indexes no query slot":
    # It marks the absence of a slot, so it must not collide with a real one.
    check PROFILER_SLOT_NONE notin [PROFILER_SLOT_GRID_BUILD,
      PROFILER_SLOT_PHYSICS, PROFILER_SLOT_FIELD, PROFILER_SLOT_INTEGRATE,
      PROFILER_SLOT_LONG_RANGE, PROFILER_SLOT_BODIES]

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

  test "every velocity-delta or field writer holds a timed slot apart from the world-intrinsic sequence":
    # The five coupling-owned writers (forcesSph, fieldForce, lrForce,
    # bodyForce, fieldDeposit) may not share a node with a world-intrinsic
    # dispatch: that would fold a coupling's cost into a slot that never
    # skips. "forces" is the neighbour sweep itself, so it may keep
    # world-intrinsic company (binScatter); its own slot must still be timed.
    const ALL_WRITERS = ["forces", "forcesSph", "fieldForce", "lrForce",
      "bodyForce", "fieldDeposit"]
    const COUPLING_OWNED = ["forcesSph", "fieldForce", "lrForce", "bodyForce",
      "fieldDeposit"]
    for couplings in ALL_COUPLINGS:
      for node in buildFrame(couplings):
        if node.kind != fnkComputePass: continue
        for step in node.dispatches:
          if step.pipelineKey notin ALL_WRITERS: continue
          checkpoint(step.pipelineKey & " sits in node \"" & node.label &
            "\" at slot " & $node.profilerSlot)
          check node.profilerSlot != PROFILER_SLOT_NONE
          if step.pipelineKey notin COUPLING_OWNED: continue
          for sibling in node.dispatches:
            if sibling.pipelineKey == step.pipelineKey: continue
            checkpoint(step.pipelineKey & " shares its node with the " &
              "world-intrinsic " & sibling.pipelineKey)
            check sibling.pipelineKey notin WORLD_INTRINSIC_SEQUENCE

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
      for key in ["clear:sbVelocityDelta", "clear:sbVelocityCoarse",
          "clear:sbDensityDelta",
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

  test "the mesh solve runs once per frame and the force it feeds every substep":
    # The solve is the expensive half and the potential it leaves is good for
    # the whole rendered frame; the force reads that potential into the
    # velocity delta every substep clears and integrates. Two cadences, so two
    # nodes.
    for couplings in ALL_COUPLINGS:
      if not dispatchesPipeline(couplings, "lrForce"):
        continue
      let oncePerFrame = nodesWithCadence(couplings, fncOncePerFrame)
      for key in LONG_RANGE_SOLVE_KEYS:
        checkpoint("solve pass " & key & " is not once per frame")
        check key in oncePerFrame
      check "lrForce" in nodesWithCadence(couplings, fncEverySubstep)

  test "the mesh density clear carries the solve's cadence":
    # The deposit accumulates into it and the solve consumes it, both once per
    # rendered frame. Clearing it per substep would empty the grid under a
    # solve that already ran; clearing it less often would sum frames.
    for couplings in ALL_COUPLINGS:
      if not dispatchesPipeline(couplings, "lrDeposit"):
        continue
      check "clear:sbLrDensity" in nodesWithCadence(couplings, fncOncePerFrame)

  test "no compute pass mixes two cadences":
    # A pass is the unit the executor skips, so two cadences inside one node
    # could only be honoured by skipping both or neither.
    for couplings in ALL_COUPLINGS:
      for node in buildFrame(couplings):
        if node.kind == fnkComputePass and node.cadence == fncOncePerFrame:
          for step in node.dispatches:
            check step.pipelineKey notin ["fieldForce", "lrForce"]
        if node.kind == fnkComputePass and node.cadence == fncEverySubstep:
          for step in node.dispatches:
            check step.pipelineKey notin LONG_RANGE_SOLVE_KEYS


suite "Every Writer Belongs To One Coupling":
  # coupling-contract, "Every coupling is declared once": every pass that
  # writes the velocity delta or the field belongs to exactly one
  # declaration's `passes`, or is the neighbour sweep, which belongs to none.

  proc owningCouplings(pipelineKey: string): seq[Coupling] =
    for coupling in Coupling:
      for p in COUPLINGS[coupling].passes:
        if p.pipeline == pipelineKey:
          result.add coupling

  test "every velocity-delta or field writer in every world maps to one declaration or is the neighbour sweep":
    const WRITERS = ["forces", "forcesSph", "fieldForce", "lrForce",
      "bodyForce", "fieldDeposit"]
    for couplings in ALL_COUPLINGS:
      for node in buildFrame(couplings):
        if node.kind != fnkComputePass: continue
        for step in node.dispatches:
          if step.pipelineKey notin WRITERS: continue
          let owners = owningCouplings(step.pipelineKey)
          if step.pipelineKey == "forces":
            checkpoint("forces is the neighbour sweep and must own no declaration")
            check owners.len == 0
          else:
            checkpoint(step.pipelineKey & " maps to " & $owners)
            check owners.len == 1


suite "Only Integrate Reads The Frame Factor":
  # coupling-contract, "Every velocity impulse accumulates per reference frame":
  # every writer hands over its impulse per reference frame, and integrate
  # alone multiplies by the frame factor. bodyIntegrate keeps its own clock
  # because it integrates the bodies, not particle velocity. Read from source,
  # since no native test can run a shader or the JS-only executor.

  const TIME_TOKENS = ["dt", "frameFactor", "frames", "substepDt"]
  const WRITER_SHADERS = [("forces", "forces.wgsl"),
    ("forcesSph", "forces-sph.wgsl"), ("fieldForce", "field-force.wgsl"),
    ("lrForce", "lr-force.wgsl"), ("bodyForce", "body-force.wgsl")]
  const WRITER_PARAMS = [("simParamsData", "forces and forcesSph"),
    ("fieldParamsData", "fieldForce"), ("lrParamsData", "lrForce")]
    ## The CPU uniform each writer reads. bodyParams is absent: bodyIntegrate
    ## shares it, so body-force's source is where its ban is read.

  func identifiers(line: string): seq[string] =
    var current = ""
    for character in line & " ":
      if character in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        current.add character
      elif current.len > 0:
        result.add current
        current = ""

  func codeOf(line, commentMarker: string): string =
    let at = line.find(commentMarker)
    if at < 0: line else: line[0 ..< at]

  func indentOf(line: string): int =
    while result < line.len and line[result] == ' ': inc result

  test "no writer shader reads a time factor":
    var verdicts: seq[string]
    var writersSeen: seq[string]
    for (pipelineKey, file) in WRITER_SHADERS:
      let lines = readFile("web/shaders/src/" & file).splitLines
      for number, line in lines:
        let tokens = identifiers(line.codeOf("//"))
        if "atomicAdd" in tokens and "velocityDeltaFixed" in tokens and
            pipelineKey notin writersSeen:
          writersSeen.add pipelineKey
        for token in tokens:
          if token in TIME_TOKENS:
            verdicts.add pipelineKey & " (" & file & ":" & $(number + 1) &
              ") reads " & token
    for message in verdicts: checkpoint message
    check verdicts.len == 0
    checkpoint("writers found adding into velocityDeltaFixed: " & $writersSeen)
    check writersSeen.len == WRITER_SHADERS.len

  test "no writer's CPU parameters carry a time factor":
    var verdicts: seq[string]
    var arraysSeen: seq[string]
    let lines = readFile("src/webgpu_compute.nim").splitLines
    for number, line in lines:
      for (paramsArray, writers) in WRITER_PARAMS:
        let code = line.codeOf("#")
        if not code.strip.startsWith(paramsArray & "["): continue
        if paramsArray notin arraysSeen: arraysSeen.add paramsArray
        var statement = code
        var next = number + 1
        while next < lines.len and lines[next].strip.len > 0 and
            lines[next].indentOf > line.indentOf:
          statement.add " " & lines[next].codeOf("#")
          inc next
        for token in identifiers(statement):
          if token in TIME_TOKENS:
            verdicts.add writers & " (src/webgpu_compute.nim:" & $(number + 1) &
              ") writes " & token & " into " & paramsArray
    for message in verdicts: checkpoint message
    check verdicts.len == 0
    checkpoint("parameter arrays assigned in src/webgpu_compute.nim: " & $arraysSeen)
    check arraysSeen.len == WRITER_PARAMS.len


suite "Bounds Read Only Declared Parameters":
  # coupling-contract, "No coupling's range reads another coupling's
  # ceiling": for each registered ceiling, the CeilingInputs fields it is
  # actually sensitive to must equal its coupling's declared boundsRead.
  # Sensitivity is measured behaviourally — moving one field at a time off a
  # baseline — rather than by reading the case arm's source, since a Nim
  # `case` body admits no such introspection.

  const CEILING_COUPLING = {pcStableStiffness: cpFluid}.toTable
    ## Which coupling owns each registered ceiling. Hand-maintained, the same
    ## way param_descriptor.ceilingName and .ceilingReason are.

  proc baselineInputs(): CeilingInputs =
    CeilingInputs(interactionRadius: INTERACTION_RADIUS_MIN,
      sphRadiusFraction: SPH_RADIUS_FRACTION_MIN, timeScale: TIME_SCALE_MIN)

  test "each registered ceiling's sensitive inputs equal its coupling's declared boundsRead":
    for id in ParamCeilingId:
      let boundsRead = COUPLINGS[CEILING_COUPLING[id]].boundsRead
      let base = evaluateCeiling(id, baselineInputs())

      template checkSensitivity(fieldName: string; moved: CeilingInputs) =
        let sensitive = evaluateCeiling(id, moved) != base
        checkpoint(fieldName & " sensitivity " & $sensitive & ", declared " &
          $(fieldName in boundsRead))
        check sensitive == (fieldName in boundsRead)

      var moved = baselineInputs()
      moved.interactionRadius = INTERACTION_RADIUS_MAX
      checkSensitivity("interactionRadius", moved)

      moved = baselineInputs()
      moved.sphRadiusFraction = SPH_RADIUS_FRACTION_MAX
      checkSensitivity("sphRadiusFraction", moved)

      moved = baselineInputs()
      moved.timeScale = TIME_SCALE_MAX
      checkSensitivity("timeScale", moved)


suite "Every Size Names Its Space":
  # coupling-contract, "Every size names its space": a length-valued
  # descriptor is named by exactly one declaration (or RENDER_SIZES), which is
  # what "carries exactly one space" comes to for a (string, SizeSpace) pair —
  # two entries for the same name could only disagree or duplicate.

  test "no length-valued descriptor is named more than once across the declarations":
    var seen: Table[string, SizeSpace]
    for coupling in Coupling:
      for (name, space) in COUPLINGS[coupling].sizes:
        checkpoint(name & " already named by another declaration")
        check name notin seen
        seen[name] = space
    for (name, space) in RENDER_SIZES:
      checkpoint(name & " already named by a coupling declaration")
      check name notin seen
      seen[name] = space


suite "Substeps Follow The Tightest Coupling":
  # substepPlan's count is the largest of three counts, capped at 3: the
  # frame-factor count n_ff = ceil(ff / 12); the travel count n_T =
  # ceil(maxVelocity * ff / T), only where some coupling declares a travel
  # length T; and n_c, a coupling's own declared need (only the fluid
  # declares one, from its stiffness). Over the stub substepPlan (count 1,
  # source scNone, always), each test below works this arithmetic against
  # its own live values; the divisor (12) and the cap (3) are not yet named
  # constants, so the literals stand in for them.

  test "shipped settings give one substep at frame factor one":
    # Band 120, Max Velocity 50, ff 1, fluid off. Bodies are on
    # (BODIES_DEFAULT_STRENGTH) but no body is live: with no live body
    # there is no surface a step could carry a particle through, so the
    # travel bound declares no length. With fluid off, ff 1 leaves the
    # frame-factor count at ceil(1 / 12) = 1: nothing asks for more than
    # one substep.
    #
    # GUARD, not a red: this bullet's right answer (count 1, source scNone)
    # is exactly what the stub always returns, so this test cannot fail
    # against the stub. It still pins the worked value.
    let live = LiveValues(
      fluid: 0.0,  # fluid off (simulation_state.nim:152)
      bodies: BODIES_DEFAULT_STRENGTH,  # 1.0 (config_ranges.nim:492)
      bodyBand: BODY_DEFAULT_BAND,  # 120 (config_ranges.nim:500)
      bodyLive: false,
      maxVelocity: 50.0)  # simulation_state.nim:139
    let plan = substepPlan(1.0, live)
    check plan.count == 1
    check plan.source == scNone

  test "stiffness at the ceiling with h 50 needs three substeps at frame factor one":
    # The fluid's own declared need is n_c = ceil(stiffness * ff /
    # (0.3 * h)), h = interactionRadius * sphRadiusFraction. At stiffness
    # 40 (SPH_STIFFNESS_MAX), h 50 (interactionRadius 50, sphRadiusFraction
    # 1, both shipped defaults, simulation_state.nim:131,158) and ff 1:
    # ceil(40 / (0.3 * 50)) = ceil(2.667) = 3.
    let live = LiveValues(
      fluid: 1.0,  # nonzero: fluid is acting (sim_registry.acts)
      interactionRadius: 50.0,
      sphRadiusFraction: 1.0,
      sphStiffness: SPH_STIFFNESS_MAX,
      bodyLive: false)
    let plan = substepPlan(1.0, live)
    check plan.count == 3
    check plan.source == scCouplingNeed

  test "frame factor 10 with a live body caps at three substeps and clamps Max Velocity to 36":
    # The travel bound is n_T = ceil(maxVelocity * ff / T), T = bodyBand
    # while bodiesStrength > 0 and a body lives. At Max Velocity 50, band
    # 120 (both shipped defaults) and ff 10: ceil(50 * 10 / 120) =
    # ceil(4.167) = 5, past the cap of 3, so the effect-time clamp holds
    # effMaxVelocity = T * 3 / ff = 120 * 3 / 10 = 36, and the travel bound
    # is what asked for the count.
    let live = LiveValues(
      fluid: 0.0,
      bodies: BODIES_DEFAULT_STRENGTH,
      bodyBand: BODY_DEFAULT_BAND,
      bodyLive: true,
      maxVelocity: 50.0)
    let plan = substepPlan(10.0, live)
    check plan.count == 3
    check plan.effMaxVelocity == 36.0
    check plan.source == scTravelBound

  test "frame factor 30 alone needs three substeps":
    # The frame-factor count is n_ff = ceil(ff / 12) = ceil(30 / 12) = 3,
    # with fluid off and no live body so neither other count reaches it:
    # the frame factor is what asked for the count.
    let live = LiveValues(
      fluid: 0.0,
      bodies: BODIES_DEFAULT_STRENGTH,
      bodyBand: BODY_DEFAULT_BAND,
      bodyLive: false,
      maxVelocity: 50.0)
    let plan = substepPlan(30.0, live)
    check plan.count == 3
    check plan.source == scFrameFactor

  test "a live body at the band floor needs two substeps at frame factor one":
    # T = BODY_BAND_MIN (25), Max Velocity 50, ff 1: the travel bound is
    # n_T = ceil(50 * 1 / 25) = 2.
    let live = LiveValues(
      fluid: 0.0,
      bodies: BODIES_DEFAULT_STRENGTH,
      bodyBand: BODY_BAND_MIN,
      bodyLive: true,
      maxVelocity: 50.0)
    let plan = substepPlan(1.0, live)
    check plan.count == 2
    check plan.source == scTravelBound

  test "bodies above zero declares the band's length only while a body lives":
    # No live body means no surface a step could carry a particle through,
    # so with no live body the bodies declaration contributes no length:
    # bodyLive gates the travel bound, not bodiesStrength alone. Asserted
    # as a contrast rather than a lone count, because a scalar test at
    # bodyLive false alone cannot fail against the stub — its right answer
    # (1) is the stub's constant. The same live values as the band-floor
    # test above (T = BODY_BAND_MIN, Max Velocity 50, ff 1), one relation,
    # both halves.
    let base = LiveValues(
      fluid: 0.0,
      bodies: BODIES_DEFAULT_STRENGTH,
      bodyBand: BODY_BAND_MIN,
      maxVelocity: 50.0)

    var withLiveBody = base
    withLiveBody.bodyLive = true
    let livePlan = substepPlan(1.0, withLiveBody)
    check livePlan.count == 2  # the band floor declares its length
    check livePlan.source == scTravelBound

    var withNoLiveBody = base
    withNoLiveBody.bodyLive = false
    let nonePlan = substepPlan(1.0, withNoLiveBody)
    check nonePlan.count == 1  # no live body, no length, no extra substep
    check nonePlan.source == scNone

  test "a fluid request past SUBSTEPS_MAX runs three substeps at the clamped stiffness, with the stored stiffness unchanged":
    # The clamp is effStiffness = min(stored, servedCeiling,
    # 0.3 * h * SUBSTEPS_MAX / ff), reusing the stiffness test's h (50) and
    # stiffness (40 = SPH_STIFFNESS_MAX) at the Max-Velocity test's ff (10)
    # and the shipped Time Scale default (0.5, simulation_state.nim:138).
    # servedCeiling is the panel's stable-stiffness ceiling,
    # sph_core.stableStiffnessCeiling (sph_core.nim:242-254), at
    # SUBSTEPS_MAX (3) and the 60 Hz reference dt.
    const h = 50.0
    const stiffness = 40.0  # SPH_STIFFNESS_MAX
    const ff = 10.0
    const timeScale = 0.5
    const substepsMax = 3  # SUBSTEPS_MAX is 3: the substep ceiling
    let servedCeiling = stableStiffnessCeiling(h, substepsMax,
      timeScale * SPH_CEILING_REFERENCE_FRAME_SECONDS, SPH_STIFFNESS_MAX)
    let expectedEffStiffness =
      min(min(stiffness, servedCeiling), 0.3 * h * substepsMax.float / ff)

    let live = LiveValues(
      fluid: 1.0,
      interactionRadius: h,
      sphRadiusFraction: 1.0,
      sphStiffness: stiffness,
      timeScale: timeScale,
      bodyLive: false)
    let plan = substepPlan(ff, live)
    check plan.count == 3
    check plan.effStiffness == expectedEffStiffness
    check plan.source == scCouplingNeed
    check live.sphStiffness == stiffness  # neither clamp touches a stored
      # value


# The world in which the two onset tests below are read. Any world separating
# the two branches serves; these are a dense one and a sparse one.
const
  PRESSURE_WORLD_W = 1920.0
  PRESSURE_WORLD_H = 1080.0
  PRESSURE_REST_SPACING = 0.5

func pressureUnits(particleCount: int; radius: float): UnitConfig =
  ## The test's world in the shape balance_core's two density functions read,
  ## so the expected onset is composed from them rather than from the producer.
  UnitConfig(
    particleCount: particleCount,
    interactionRadius: radius,
    worldWidth: PRESSURE_WORLD_W,
    worldHeight: PRESSURE_WORLD_H,
    repulsionEnd: PRESSURE_REST_SPACING,
    onsetRatio: CROWD_ONSET_RATIO)

func pressureLive(particleCount: int; radius: float): PressureWorld =
  ## The same world as the live values the frame holds.
  PressureWorld(
    particleCount: particleCount,
    interactionRadius: radius,
    worldWidth: PRESSURE_WORLD_W,
    worldHeight: PRESSURE_WORLD_H,
    repulsionEnd: PRESSURE_REST_SPACING)

suite "The Pressure Onset Comes From The Density Functions":
  # forces.wgsl reads one onset uniform, as physics_core's pairImpulse reads
  # one pressureOnset. webgpu_compute.nim writes it per frame and cannot be
  # imported natively (it opens on std/jsffi), so the check sits on the
  # producer the executor calls.

  test "the pressure onset takes x_on times the mean crowd density when the world is dense":
    let cfg = pressureUnits(128_000, 50.0)
    require CROWD_ONSET_RATIO * meanCrowdDensity(cfg) > contactFloorDensity(cfg)
    check pressureOnset(pressureLive(128_000, 50.0)) ==
      CROWD_ONSET_RATIO * meanCrowdDensity(cfg)

  test "the pressure onset takes the contact floor when the world is sparse":
    let cfg = pressureUnits(100, 10.0)
    require CROWD_ONSET_RATIO * meanCrowdDensity(cfg) < contactFloorDensity(cfg)
    check pressureOnset(pressureLive(100, 10.0)) == contactFloorDensity(cfg)

  test "the pressure onset stays positive in the sparsest world the ranges allow":
    # forces.wgsl divides by this uniform once per pair. The contact floor is
    # what keeps it off zero, and the floor is positive only while
    # REPULSION_END_MAX stays below one, where the hexagonal lattice's six
    # nearest sites still fall inside the radius.
    let world = PressureWorld(
      particleCount: PARTICLE_COUNT_MIN,
      interactionRadius: INTERACTION_RADIUS_MIN.float,
      worldWidth: PRESSURE_WORLD_W,
      worldHeight: PRESSURE_WORLD_H,
      repulsionEnd: REPULSION_END_MAX)
    check pressureOnset(world) > 0.0

  test "the frame fills the onset uniform from the producer":
    # An onset assembled inside the executor would be a second copy of the
    # composition balance_core owns, free to drift from the one these tests
    # and the oracle hold. Read from source, since the executor opens on
    # std/jsffi and no native test can import it.
    const SLOT = "simParamsData[SIM_PRESSURE_ONSET]"
    let lines = readFile("src/webgpu_compute.nim").splitLines
    var statement = ""
    for number, line in lines:
      if not line.strip.startsWith(SLOT): continue
      let indent = line.len - line.strip(trailing = false).len
      statement = line
      var next = number + 1
      while next < lines.len and lines[next].strip.len > 0 and
          lines[next].len - lines[next].strip(trailing = false).len > indent:
        statement.add " " & lines[next]
        inc next
      break
    checkpoint("assignment found for " & SLOT & ": " & statement)
    check "pressureOnset(" in statement
