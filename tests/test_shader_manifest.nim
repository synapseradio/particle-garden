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
import coupling_space  # ALL_COUPLINGS, the eight worlds every sweep covers

const SHADER_MANIFEST_TESTS_LOADED* = true

proc dispatchKeysOf(frame: FrameDescription): seq[string] =
  ## Every pipeline key the frame's compute passes dispatch, in order.
  for node in frame:
    if node.kind == fnkComputePass:
      for step in node.dispatches:
        result.add step.pipelineKey


suite "Every Dispatched Pipeline Has A Registered Shader Spec":
  test "each frame's dispatch keys all resolve to a manifest spec key":
    # THE red light: a pipelineKey dispatched by a frame with no matching
    # ShaderSpec means the pipeline is never loaded or created. Swept over
    # every couplings combination, so a composed world cannot dispatch a
    # pipeline its own manifest union forgot to register.
    for couplings in ALL_COUPLINGS:
      let specKeys = block:
        var keys: HashSet[string]
        for spec in shaderSpecsFor(couplings):
          keys.incl spec.key
        keys
      for dispatchKey in dispatchKeysOf(buildFrame(couplings)):
        check dispatchKey in specKeys

  test "the relation covers every couplings combination":
    # Guards against the relation silently testing nothing.
    check ALL_COUPLINGS.len == 8

  test "a composed world registers the union of its couplings' specs":
    # The specific thing a per-mode manifest could not express: chemistry needs
    # forces' grid triad AND the field's six shaders, from one call.
    let chemistry = shaderSpecsFor(WorldCouplings(forces: true, field: true))
    var keys: HashSet[string]
    for spec in chemistry:
      keys.incl spec.key
    for forcesKey in ["binCount", "binScatter", "forces"]:
      check forcesKey in keys
    for fieldKey in ["fieldDeposit", "fieldResolve", "fieldForce"]:
      check fieldKey in keys
    check "integrate" in keys
    check "forcesSph" notin keys

  test "a world coupling nothing still registers integrate":
    # Its frame dispatches integrate and nothing else, so the manifest has to
    # carry the pipeline that frame needs.
    let specs = shaderSpecsFor(
      WorldCouplings(forces: false, sph: false, field: false))
    check specs.len == 1
    check specs[0].key == "integrate"

  test "the union registers no key twice":
    # A duplicate key would create the same pipeline twice under one dictionary
    # entry. integrate and the grid triad each belong to more than one
    # coupling, so this is the case the union exists to handle.
    for couplings in ALL_COUPLINGS:
      let specs = shaderSpecsFor(couplings)
      var keys: HashSet[string]
      for spec in specs:
        keys.incl spec.key
      check keys.len == specs.len


suite "Shader Spec Manifests Are Well-Formed":
  test "spec keys are unique within each kind":
    # A duplicate key would make the pipelines/bindGroups dictionaries
    # collide. Paths are NOT required to be unique: reaction-diffusion's
    # rdStepToFront and rdStepToTrail deliberately share one path/entry
    # (one WGSL pipeline, two bind-group orientations over it) while keeping
    # distinct keys, so this only checks the keys.
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

  test "reaction-diffusion registers its six field shaders plus shared integrate":
    let rdKeys = block:
      var keys: HashSet[string]
      for spec in shaderSpecsFor(skReactionDiffusion):
        keys.incl spec.key
      keys
    check rdKeys.len == 7
    for expectedKey in ["fieldSeed", "fieldDeposit", "fieldResolve",
        "rdStepToFront", "rdStepToTrail", "fieldForce", "integrate"]:
      check expectedKey in rdKeys

  test "the one-shot seed shader is registered without any frame dispatching it":
    # CONTRACT: fieldSeed runs on demand (mode entry, reset), never as a frame
    # node, so it must be registered here to be fetched and pipelined even
    # though dispatchKeysOf(buildFrame) never names it. That asymmetry is why
    # the relation above checks dispatch keys are a SUBSET of spec keys rather
    # than an equality.
    let rdSpecKeys = block:
      var keys: HashSet[string]
      for spec in shaderSpecsFor(skReactionDiffusion):
        keys.incl spec.key
      keys
    check "fieldSeed" in rdSpecKeys
    check "fieldSeed" notin dispatchKeysOf(
      buildFrame(couplingsFor(skReactionDiffusion)))

  test "rdStepToFront and rdStepToTrail share one shader path and entry point":
    let specs = shaderSpecsFor(skReactionDiffusion)
    let toFrontSpec = block:
      var found: ShaderSpec
      for spec in specs:
        if spec.key == "rdStepToFront": found = spec
      found
    let toTrailSpec = block:
      var found: ShaderSpec
      for spec in specs:
        if spec.key == "rdStepToTrail": found = spec
      found
    check toFrontSpec.path == toTrailSpec.path
    check toFrontSpec.entryPoint == toTrailSpec.entryPoint

  test "reaction-diffusion's integrate spec is identical to particle-life's":
    # RD's fieldForce writes velocityDelta in the same layout integrate
    # expects, so both kinds share the exact same pipeline spec.
    let particleLifeIntegrate = block:
      var found: ShaderSpec
      for spec in shaderSpecsFor(skParticleLife):
        if spec.key == "integrate": found = spec
      found
    let rdIntegrate = block:
      var found: ShaderSpec
      for spec in shaderSpecsFor(skReactionDiffusion):
        if spec.key == "integrate": found = spec
      found
    check particleLifeIntegrate == rdIntegrate
