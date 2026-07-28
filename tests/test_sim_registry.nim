# ==============================================================================
# PARTICLE GARDEN - SIM REGISTRY TESTS
# ==============================================================================
#
# Behavioral tests for src/sim_registry.nim: the pure frame description that
# webgpu_compute.nim's executor walks each frame. buildFrame(skParticleLife)
# must reproduce exactly the pass sequence the hand-coded runPhysicsFrame
# executed — these tests pin it node-by-node, because a drifted description
# silently reorders GPU work.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import std/sets
import ../src/sim_registry
import ../src/field_core
import ../src/ui/api/param_descriptor
import coupling_space  # ALL_COUPLINGS, the eight worlds every sweep covers

const SIM_REGISTRY_TESTS_LOADED* = true

proc dispatchesPipeline(couplings: WorldCouplings; pipelineKey: string): bool =
  for node in buildFrame(couplings):
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        if step.pipelineKey == pipelineKey:
          return true
  false

proc dispatchSequence(couplings: WorldCouplings): seq[string] =
  ## Every pipeline key the frame dispatches, in encoded order. This is the
  ## thing that must not change for the legacy triples: pass grouping and
  ## profiler slots are presentation, but the order work reaches the GPU in is
  ## the behavior.
  for node in buildFrame(couplings):
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        result.add step.pipelineKey

proc clearedBuffers(couplings: WorldCouplings): seq[SimBuffer] =
  for node in buildFrame(couplings):
    if node.kind == fnkClearBuffer:
      result.add node.clearTarget

func rdStepKeys(): seq[string] =
  for stepIndex in 0 ..< RD_STEPS_PER_FRAME:
    result.add(
      if stepIndex mod 2 == 0: "rdStepToFront" else: "rdStepToTrail")

suite "SimKind Serialization Contract":
  test "mode ids are stable strings, never ordinals":
    # Presets and mode selectors serialize these strings; reordering the enum
    # must never change what a saved preset means.
    check simKindId(skParticleLife) == "particle-life"
    check simKindId(skSph) == "sph"
    check simKindId(skReactionDiffusion) == "reaction-diffusion"

  test "parseSimKind round-trips every kind and rejects unknown ids":
    for kind in SimKind:
      check parseSimKind(simKindId(kind)) == kind
    expect ValueError:
      discard parseSimKind("no-such-mode")

suite "Legacy Couplings Reproduce Today's Frames":
  # THE REGRESSION CHECK FOR THE WHOLE RESTRUCTURE. These three ran before any
  # shader was touched and must still run after. What they pin is the DISPATCH
  # SEQUENCE — the order work reaches the GPU in. Pass grouping and profiler
  # slots did move: integrate left the physics pass because the field passes
  # have to sit between the two, and the frame gained explicit delta clears
  # because the shaders no longer self-reset. Neither changes what executes,
  # or in what order.

  test "forces-only couplings produce exactly today's particle-life pass list":
    check dispatchSequence(couplingsFor(skParticleLife)) == @[
      "binCount", "prefixLocal", "prefixBlocks", "prefixFinal",
      "binScatter", "forces", "integrate"]

  test "sph-only couplings produce exactly today's SPH pass list":
    check dispatchSequence(couplingsFor(skSph)) == @[
      "binCount", "prefixLocal", "prefixBlocks", "prefixFinal",
      "binScatter", "forcesSph", "integrate"]

  test "field-only couplings produce exactly today's reaction-diffusion pass list":
    check dispatchSequence(couplingsFor(skReactionDiffusion)) ==
      @["fieldDeposit", "fieldResolve"] & rdStepKeys() &
      @["fieldForce", "integrate"]

  test "the legacy triples build no spatial hash they did not build before":
    # RD never ran a neighbor search and must not start: fieldForce reads a
    # texture, not sorted neighbor particles.
    check buildsSpatialHash(couplingsFor(skParticleLife))
    check buildsSpatialHash(couplingsFor(skSph))
    check not buildsSpatialHash(couplingsFor(skReactionDiffusion))

  test "the legacy force pass labels are unchanged":
    # A profile taken before the merge must read against one taken after.
    proc labelOf(couplings: WorldCouplings, slot: int): string =
      for node in buildFrame(couplings):
        if node.kind == fnkComputePass and node.profilerSlot == slot:
          return node.label
      ""
    check labelOf(couplingsFor(skParticleLife), PROFILER_SLOT_PHYSICS) ==
      "Physics (AoS)"
    check labelOf(couplingsFor(skSph), PROFILER_SLOT_PHYSICS) ==
      "Physics (SPH)"


suite "Composed Frames":
  test "chemistry runs the grid triad, forces, the field passes, then integrate":
    # The world this whole change exists to make possible: particles that feel
    # each other AND write the field, in one frame.
    check dispatchSequence(WorldCouplings(forces: true, field: true)) ==
      @["binCount", "prefixLocal", "prefixBlocks", "prefixFinal",
        "binScatter", "forces",
        "fieldDeposit", "fieldResolve"] & rdStepKeys() &
      @["fieldForce", "integrate"]

  test "forces and field together dispatch the grid build exactly once":
    # Both couplings want a spatial hash; building it twice would be pure waste
    # and would double-count every particle into gridCounts.
    for couplings in ALL_COUPLINGS:
      var gridBuilds = 0
      for key in dispatchSequence(couplings):
        if key == "binCount": inc gridBuilds
      check gridBuilds == (if buildsSpatialHash(couplings): 1 else: 0)

  test "fluid chemistry runs both force models over one shared grid":
    let sequence = dispatchSequence(
      WorldCouplings(forces: true, sph: true, field: true))
    check sequence == @[
      "binCount", "prefixLocal", "prefixBlocks", "prefixFinal",
      "binScatter", "forces", "forcesSph",
      "fieldDeposit", "fieldResolve"] & rdStepKeys() &
      @["fieldForce", "integrate"]

  test "couplings with nothing active dispatch only the clears and integrate":
    # The degenerate world still has to be a valid frame: particles keep their
    # velocity and drift. A frame that dispatched nothing would freeze them,
    # and one that skipped the clears would integrate last frame's deltas
    # forever.
    let empty = WorldCouplings(forces: false, sph: false, field: false)
    check dispatchSequence(empty) == @["integrate"]
    check clearedBuffers(empty) == @[sbVelocityDelta, sbDensityDelta]


suite "Delta Buffers Have One Reset Owner":
  test "every frame clears velocityDelta and densityDelta before any pass that writes them":
    # THE INVARIANT THAT MAKES COMPOSITION POSSIBLE. While forces.wgsl and
    # forces-sph.wgsl self-reset these buffers in their prologues, a frame
    # running two contributors erased the first one's work. The reset moved to
    # the frame; the contributors accumulate only.
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
          if step.pipelineKey in ["forces", "forcesSph"]:
            check clearedAt[sbDensityDelta] < index

  test "no delta buffer is cleared twice in a frame":
    # Two clears would be harmless but would mean two owners, which is the
    # state this change exists to leave.
    for couplings in ALL_COUPLINGS:
      let cleared = clearedBuffers(couplings)
      check toHashSet(cleared).len == cleared.len

  test "integrate runs last in every couplings combination":
    # integrate reads the summed deltas and moves particles, so every
    # contributor must already have run.
    for couplings in ALL_COUPLINGS:
      let sequence = dispatchSequence(couplings)
      check sequence.len > 0
      check sequence[^1] == "integrate"
      var integrations = 0
      for key in sequence:
        if key == "integrate": inc integrations
      check integrations == 1


suite "Which Worlds Compute Particle Density":
  test "computesDensity holds exactly for the worlds that run a force pass":
    # forces.wgsl and forces-sph.wgsl are the only passes that write
    # densityDelta; field-force.wgsl writes velocityDelta and nothing else. So
    # a world's density comes from its force couplings, and a field-only world
    # carries a stale ~0 density however much of a pattern it grows.
    #
    # webgpu_render.nim reads exactly this to decide whether the glow needs its
    # density floor: with no density source the density term reads flat and the
    # velocity term has to drive the glow instead. Stating the predicate against
    # the frame keeps the renderer's gate and the frame's contributors from
    # drifting apart.
    for couplings in ALL_COUPLINGS:
      let writesDensity = dispatchesPipeline(couplings, "forces") or
        dispatchesPipeline(couplings, "forcesSph")
      if computesDensity(couplings) != writesDensity:
        checkpoint("density claim disagrees with the frame for forces=" &
          $couplings.forces & " sph=" & $couplings.sph &
          " field=" & $couplings.field)
      check computesDensity(couplings) == writesDensity
      # The same relation over the booleans themselves: the field contributes
      # no density, so coupling it changes nothing here.
      check computesDensity(couplings) == (couplings.forces or couplings.sph)


suite "Field Passes Compose Safely":
  test "the field ping-pong parity holds for every couplings combination containing field":
    # fieldResolve is itself one swap, so 1 + RD_STEPS_PER_FRAME swaps happen
    # per frame. The substeps must start ToFront and end ToFront, or the live
    # field lands on the texture nothing reads and the last substep is thrown
    # away every frame.
    for couplings in ALL_COUPLINGS:
      if not couplings.field: continue
      var steps: seq[string]
      for key in dispatchSequence(couplings):
        if key in ["rdStepToFront", "rdStepToTrail"]: steps.add key
      check steps.len == RD_STEPS_PER_FRAME
      check steps[0] == "rdStepToFront"
      check steps[^1] == "rdStepToFront"
      for stepIndex, key in steps:
        check key == (
          if stepIndex mod 2 == 0: "rdStepToFront" else: "rdStepToTrail")

  test "the field passes appear exactly when the field is coupled":
    for couplings in ALL_COUPLINGS:
      for fieldKey in ["fieldDeposit", "fieldResolve", "fieldForce"]:
        check dispatchesPipeline(couplings, fieldKey) == couplings.field

  test "fieldDeposit precedes fieldResolve which precedes every substep":
    # fieldResolve consumes the deposit buffer and zeroes it; a substep running
    # first would evolve a field the frame's deposits never reached.
    for couplings in ALL_COUPLINGS:
      if not couplings.field: continue
      let sequence = dispatchSequence(couplings)
      let depositAt = sequence.find("fieldDeposit")
      let resolveAt = sequence.find("fieldResolve")
      let firstStepAt = sequence.find("rdStepToFront")
      check depositAt >= 0
      check depositAt < resolveAt
      check resolveAt < firstStepAt

  test "no couplings combination dispatches an unknown pipeline key":
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

  test "the monolithic prefix-sum pipeline is gone from every frame":
    for couplings in ALL_COUPLINGS:
      check not dispatchesPipeline(couplings, "prefixSum")


suite "Profiler Slot Constants":
  test "the slot constants are distinct":
    # They index one query set. Two passes sharing a slot would overwrite each
    # other's timestamps and report a meaningless delta — which is exactly what
    # the field pass did while it borrowed the grid-build slot.
    let slots = [PROFILER_SLOT_GRID_BUILD, PROFILER_SLOT_PHYSICS,
      PROFILER_SLOT_FIELD, PROFILER_SLOT_INTEGRATE]
    check toHashSet(slots).len == slots.len

  test "every frame's compute passes hold distinct profiler slots":
    for couplings in ALL_COUPLINGS:
      var seenSlots: HashSet[int]
      for node in buildFrame(couplings):
        if node.kind == fnkComputePass:
          check node.profilerSlot notin seenSlots
          seenSlots.incl node.profilerSlot


suite "Control Groups Follow The Couplings":
  let sectionOnly = toHashSet(@SECTION_ONLY_GROUPS)
  let descriptorGroups = block:
    var groups: HashSet[string]
    for descriptor in buildParamDescriptors():
      groups.incl descriptor.group
    groups

  test "every group a world lists either owns descriptors or is declared section-only":
    # THE red light: a typo'd group id would silently hide a whole section
    # instead of failing anywhere. Section-only ids (the matrix editor, the
    # force-model button row) are legitimately descriptor-free, so they are
    # declared rather than inferred.
    for couplings in ALL_COUPLINGS:
      for group in controlGroupsFor(couplings):
        check group in descriptorGroups or group in sectionOnly

  test "every descriptor group is reachable from some couplings":
    # The converse red light: an unreachable group vanishes from every panel,
    # so its sliders become unreachable without any error.
    var listed: HashSet[string]
    for couplings in ALL_COUPLINGS:
      for group in controlGroupsFor(couplings):
        listed.incl group
    for group in descriptorGroups:
      check group in listed

  test "no world lists a group twice":
    # "grid" belongs to both the forces and sph coupling sets, so the union has
    # to deduplicate — a plain concatenation would render that slider twice in
    # a world coupling both.
    for couplings in ALL_COUPLINGS:
      let groups = controlGroupsFor(couplings)
      check toHashSet(groups).len == groups.len

  test "controlGroupsFor unions the groups of active couplings":
    # The relation stated directly: every active coupling contributes all of
    # its groups, and an inactive one contributes none of its exclusive ones.
    for couplings in ALL_COUPLINGS:
      let groups = toHashSet(controlGroupsFor(couplings))
      if couplings.forces:
        for group in FORCES_GROUPS: check group in groups
      if couplings.sph:
        for group in SPH_GROUPS: check group in groups
      if couplings.field:
        for group in FIELD_GROUPS: check group in groups
      for universal in UNIVERSAL_GROUPS: check universal in groups

  test "only worlds that dispatch the forces pass offer the force-model groups":
    # forces.wgsl is the sole reader of the attraction matrix and the
    # force-model selector, so a world without that dispatch must not present
    # either. forces-sph reads neither, and the field runs no force pass.
    for couplings in ALL_COUPLINGS:
      let groups = toHashSet(controlGroupsFor(couplings))
      let runsForces = dispatchesPipeline(couplings, "forces")
      for forceGroup in ["matrix", "force-model", "force-polynomial",
          "force-exponential", "particle-life"]:
        check (forceGroup in groups) == runsForces

  test "the grid group appears exactly for the worlds that build a spatial hash":
    # interactionRadius is the neighbor-search radius binCount bins by, and
    # SPH's smoothing radius. A field-only world dispatches no binCount, so the
    # control would be inert there.
    for couplings in ALL_COUPLINGS:
      check ("grid" in controlGroupsFor(couplings)) ==
        dispatchesPipeline(couplings, "binCount")

  test "the field groups appear exactly when the field is coupled":
    for couplings in ALL_COUPLINGS:
      let groups = toHashSet(controlGroupsFor(couplings))
      check ("rd" in groups) == couplings.field
      check ("rd-field" in groups) == couplings.field

  test "every world offers the universal groups":
    # simulation/render/glow/bloom/palette touch every world's pipeline, so a
    # world that dropped one would hide a control that still works.
    for couplings in ALL_COUPLINGS:
      let groups = toHashSet(controlGroupsFor(couplings))
      for universal in ["simulation", "render", "glow", "bloom", "palette"]:
        check universal in groups

  test "the legacy modes still present exactly the groups they always did":
    # The compatibility layer has to hold on the panel too, not only in the
    # frame: a preset that reopens particle life must show the same panel.
    #
    # "camera" joins every list because it is UNIVERSAL, and that is the point
    # of the change rather than a drift in it: no coupling can take away where
    # the viewer is standing. What this test still pins is the part that must
    # not move — which groups each COUPLING contributes.
    check toHashSet(controlGroupsFor(couplingsFor(skParticleLife))) ==
      toHashSet(@["simulation", "grid", "particle-life", "matrix",
        "force-model", "force-polynomial", "force-exponential",
        "render", "glow", "bloom", "palette", "camera"])
    check toHashSet(controlGroupsFor(couplingsFor(skSph))) ==
      toHashSet(@["simulation", "grid", "sph",
        "render", "glow", "bloom", "palette", "camera"])
    check toHashSet(controlGroupsFor(couplingsFor(skReactionDiffusion))) ==
      toHashSet(@["simulation", "rd", "rd-field",
        "render", "glow", "bloom", "palette", "camera"])
