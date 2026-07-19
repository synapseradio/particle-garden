# ==============================================================================
# PARTICLE GARDEN - SHADER MANIFEST TESTS
# ==============================================================================
#
# Relation tests for src/shader_manifest.nim against src/sim_registry.nim. The
# manifest lists the compute shaders each simulation kind needs; the frame
# description lists the pipeline keys each kind dispatches. These must agree: a
# frame that dispatches a pipeline the manifest never registers is the
# "forgot to register the shader" bug, and it must fail here rather than as a
# blank GPU pipeline at runtime.
#
# The relation covers exactly the kinds whose buildFrame is implemented (does
# not raise), so a kind gains coverage automatically the moment its frame lands.
#
# Run with: nimble test
#
# ==============================================================================

import std/[unittest, sets, strutils]
import ../src/sim_registry
import ../src/shader_manifest

const SHADER_MANIFEST_TESTS_LOADED* = true

proc buildFrameRaises(kind: SimKind): bool =
  ## True when a kind's frame is not implemented yet (buildFrame raises).
  try:
    discard buildFrame(kind)
    false
  except ValueError:
    true

proc dispatchKeysOf(frame: FrameDescription): seq[string] =
  ## Every pipeline key the frame's compute passes dispatch, in order.
  for node in frame:
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        result.add step.pipelineKey


suite "Every Dispatched Pipeline Has A Registered Shader Spec":
  test "each frame's dispatch keys all resolve to a manifest spec key":
    # THE red light: a pipelineKey dispatched by a frame with no matching
    # ShaderSpec means the pipeline is never loaded or created.
    for kind in SimKind:
      if buildFrameRaises(kind):
        continue
      let specKeys = block:
        var keys: HashSet[string]
        for spec in shaderSpecsFor(kind):
          keys.incl spec.key
        keys
      for dispatchKey in dispatchKeysOf(buildFrame(kind)):
        check dispatchKey in specKeys

  test "at least the two implemented kinds are covered by this relation":
    # Guards against the relation silently testing nothing: particle-life and
    # SPH both have frames this stage.
    var implementedKinds = 0
    for kind in SimKind:
      if not buildFrameRaises(kind):
        inc implementedKinds
    check implementedKinds >= 2


suite "Shader Spec Manifests Are Well-Formed":
  test "spec keys are unique within each kind":
    # A duplicate key would make the pipelines/bindGroups dictionaries collide.
    for kind in SimKind:
      let specs = shaderSpecsFor(kind)
      var keys: HashSet[string]
      for spec in specs:
        keys.incl spec.key
      check keys.len == specs.len

  test "every spec path is a .wgsl file served under ./shaders/":
    # main.nim serves the compute shaders from ./shaders/; a path that does not
    # match cannot be fetched at pipeline-load time.
    for kind in SimKind:
      for spec in shaderSpecsFor(kind):
        check spec.path.startsWith("./shaders/")
        check spec.path.endsWith(".wgsl")

  test "particle-life keeps its seven compute shaders":
    check shaderSpecsFor(skParticleLife).len == 7

  test "SPH swaps forces for forcesSph and shares the rest of the pipeline":
    let sphKeys = block:
      var keys: HashSet[string]
      for spec in shaderSpecsFor(skSph):
        keys.incl spec.key
      keys
    # The SPH-specific force pass replaces the particle-life force pass.
    check "forcesSph" in sphKeys
    check "forces" notin sphKeys
    # The grid triad, bin-scatter, and integrate are shared verbatim.
    for shared in ["binCount", "prefixLocal", "prefixBlocks", "prefixFinal",
                   "binScatter", "integrate"]:
      check shared in sphKeys

  test "reaction-diffusion registers no shaders yet":
    check shaderSpecsFor(skReactionDiffusion).len == 0
