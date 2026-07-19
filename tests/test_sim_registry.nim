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
import ../src/sim_registry

const SIM_REGISTRY_TESTS_LOADED* = true

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


suite "Particle-Life Frame Description":
  # The exact sequence the hand-coded runPhysicsFrame executed:
  #   clear gridCounts;
  #   compute "Grid Build" [binCount, prefixLocal, prefixBlocks, prefixFinal];
  #   copy gridOffsets -> fillPointers;
  #   compute "Physics (AoS)" [binScatter, forces, integrate];
  # and NO delta-buffer clears (forces.wgsl self-resets them via atomicStore).

  let frame = buildFrame(skParticleLife)

  test "the frame has exactly four nodes in order":
    check frame.len == 4
    check frame[0].kind == fnkClearBuffer
    check frame[1].kind == fnkComputePass
    check frame[2].kind == fnkCopyBuffer
    check frame[3].kind == fnkComputePass

  test "node 0 clears gridCounts":
    check frame[0].clearTarget == sbGridCounts

  test "node 1 is the Grid Build pass with the profiler's grid slot":
    check frame[1].label == "Grid Build"
    check frame[1].profilerSlot == PROFILER_SLOT_GRID_BUILD
    check frame[1].dispatches.len == 4
    check frame[1].dispatches[0] == Dispatch(pipelineKey: "binCount", size: dsParticleWorkgroups)
    check frame[1].dispatches[1] == Dispatch(pipelineKey: "prefixLocal", size: dsScanBlocks)
    check frame[1].dispatches[2] == Dispatch(pipelineKey: "prefixBlocks", size: dsOne)
    check frame[1].dispatches[3] == Dispatch(pipelineKey: "prefixFinal", size: dsScanBlocks)

  test "node 2 copies gridOffsets into fillPointers":
    check frame[2].copySource == sbGridOffsets
    check frame[2].copyDest == sbFillPointers

  test "node 3 is the Physics pass with the profiler's physics slot":
    check frame[3].label == "Physics (AoS)"
    check frame[3].profilerSlot == PROFILER_SLOT_PHYSICS
    check frame[3].dispatches.len == 3
    check frame[3].dispatches[0] == Dispatch(pipelineKey: "binScatter", size: dsParticleWorkgroups)
    check frame[3].dispatches[1] == Dispatch(pipelineKey: "forces", size: dsParticleWorkgroups)
    check frame[3].dispatches[2] == Dispatch(pipelineKey: "integrate", size: dsParticleWorkgroups)

  test "no node clears a delta buffer":
    # forces.wgsl self-resets velocityDelta/densityDelta via atomicStore; an
    # accidental clear here would race the atomics (the bug the old comment
    # in runPhysicsFrame warned about).
    for node in frame:
      if node.kind == fnkClearBuffer:
        check node.clearTarget == sbGridCounts

  test "the monolithic prefix-sum pipeline is gone from the frame":
    for node in frame:
      if node.kind == fnkComputePass:
        for dispatch in node.dispatches:
          check dispatch.pipelineKey != "prefixSum"


suite "Unimplemented Modes Fail Loudly":
  test "buildFrame raises for modes that have no frame yet":
    expect ValueError:
      discard buildFrame(skSph)
    expect ValueError:
      discard buildFrame(skReactionDiffusion)
