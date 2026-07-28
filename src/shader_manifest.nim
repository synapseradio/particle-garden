# ==============================================================================
# PARTICLE GARDEN - COMPUTE SHADER MANIFEST (Pure)
# ==============================================================================
#
# The compute shaders each coupling needs, as data. A pure companion to
# sim_registry.nim: sim_registry says which pipeline keys a frame dispatches,
# this module says where each of those pipelines' shader source lives and how
# to build it. tests/test_shader_manifest.nim relates the two, so a frame that
# dispatches an unregistered pipeline fails natively instead of as a blank GPU
# pipeline at runtime.
#
# webgpu_compute.nim (JS-only) consumes this to load shaders, create pipelines,
# and extract bind-group layouts. Keeping the manifest pure lets the native
# test suite check the frame↔manifest contract without a GPU.
#
# Pure module: no FFI, no imports from GPU-facing code. Compiles on both the
# native (nimble test) and JS backends.
#
# ==============================================================================

import sim_registry

type
  ShaderSpec* = object
    ## One compute shader a coupling needs: its dictionary key (shared
    ## by the pipelines/bindGroups dictionaries and the frame's Dispatch
    ## pipelineKey), the URL main.nim serves it at, its debug label, and its
    ## WGSL entry-point function name.
    key*: string
    path*: string
    label*: string
    entryPoint*: string

const INTEGRATE_SPEC* = ShaderSpec(
  key: "integrate", path: "./shaders/integrate.wgsl",
  label: "Integrate Shader (AoS)", entryPoint: "integrate")
  ## Every frame ends with integrate, whatever is coupled — including a world
  ## coupling nothing, whose particles still carry their velocity forward.

const
  GRID_SPECS* = [
    ShaderSpec(key: "binCount", path: "./shaders/bin-count.wgsl",
      label: "Bin Count Shader (AoS)", entryPoint: "main"),
    ShaderSpec(key: "prefixLocal", path: "./shaders/prefix-sum-local.wgsl",
      label: "Prefix Sum Local Shader", entryPoint: "main"),
    ShaderSpec(key: "prefixBlocks", path: "./shaders/prefix-sum-blocks.wgsl",
      label: "Prefix Sum Blocks Shader", entryPoint: "main"),
    ShaderSpec(key: "prefixFinal", path: "./shaders/prefix-sum-final.wgsl",
      label: "Prefix Sum Final Shader", entryPoint: "main"),
    ShaderSpec(key: "binScatter", path: "./shaders/bin-scatter.wgsl",
      label: "Bin Scatter Shader (AoS)", entryPoint: "main"),
  ]
    ## The spatial hash both force couplings search through, registered once for
    ## whichever of them is active. sim_registry.buildsSpatialHash is the same
    ## question on the frame side, and asking it here is what keeps the two
    ## couplings from each registering their own copy of these five pipelines.
  FORCES_SPECS* = [
    ShaderSpec(key: "forces", path: "./shaders/forces.wgsl",
      label: "Forces Shader (AoS)", entryPoint: "computeForces"),
  ]
    ## Species attraction over the grid. One shader: everything else the
    ## coupling needs is the grid triad above.
  SPH_SPECS* = [
    ShaderSpec(key: "forcesSph", path: "./shaders/forces-sph.wgsl",
      label: "SPH Forces", entryPoint: "computeForces"),
  ]
    ## Smoothed-particle pressure and viscosity. It replaces the force pass
    ## rather than the grid search, which is why it reads interactionRadius as
    ## its smoothing radius and shares GRID_SPECS verbatim.
  FIELD_SPECS* = [
    ShaderSpec(key: "fieldSeed", path: "./shaders/field-seed.wgsl",
      label: "Field Seed Shader", entryPoint: "seedField"),
    ShaderSpec(key: "fieldDeposit", path: "./shaders/field-deposit.wgsl",
      label: "Field Deposit Shader", entryPoint: "depositField"),
    ShaderSpec(key: "fieldResolve", path: "./shaders/field-resolve.wgsl",
      label: "Field Resolve Shader", entryPoint: "resolveField"),
    ShaderSpec(key: "rdStepToFront", path: "./shaders/rd-step.wgsl",
      label: "Gray-Scott Step Shader (To Front)", entryPoint: "rdStep"),
    ShaderSpec(key: "rdStepToTrail", path: "./shaders/rd-step.wgsl",
      label: "Gray-Scott Step Shader (To Trail)", entryPoint: "rdStep"),
    ShaderSpec(key: "fieldForce", path: "./shaders/field-force.wgsl",
      label: "Field Force Shader", entryPoint: "applyFieldForce"),
  ]
    ## The Gray-Scott chemical field. Two entries need their asymmetry stated.
    ##
    ## fieldSeed is registered here and dispatched by no frame node at all: the
    ## executor encodes it on demand (reset, "scatter spores"), so the relation
    ## test checks that dispatch keys are a SUBSET of spec keys rather than an
    ## equality.
    ##
    ## rdStepToFront and rdStepToTrail share one shader file and entry point:
    ## one WGSL pipeline, but the executor gives each dispatch key its own bind
    ## group over that pipeline (the two orientations of the field-texture
    ## ping-pong), so both keys are registered against the same path/entry. The
    ## keys name their DESTINATION texture; a name saying nothing about which
    ## texture ends up holding the live field is exactly how an
    ## off-by-one-substep parity bug hid in the sequence.

func shaderSpecsFor*(couplings: WorldCouplings): seq[ShaderSpec] =
  ## Every compute shader the active couplings need: integrate always, the grid
  ## triad whenever a coupling searches neighbors, then each active coupling's
  ## own shaders. Every Dispatch.pipelineKey that
  ## sim_registry.buildFrame(couplings) emits appears here — the relation test
  ## pins that direction.
  ##
  ## A union rather than a per-mode list for the same reason buildFrame
  ## composes: a world coupling forces and the field dispatches both sets, and
  ## no third list should have to be written to say so.
  ##
  ## NO KEY BELONGS TO TWO OF THE LISTS ABOVE, which is what lets this append
  ## rather than deduplicate. The shared pipelines are shared by being hoisted
  ## out — integrate into INTEGRATE_SPEC, the neighbor search into GRID_SPECS —
  ## so a key can only be registered twice if a new list repeats one, and
  ## "the union registers no key twice" in tests/test_shader_manifest.nim is
  ## what catches that.
  result.add INTEGRATE_SPEC
  if buildsSpatialHash(couplings): result.add GRID_SPECS
  if couplings.forces: result.add FORCES_SPECS
  if couplings.sph: result.add SPH_SPECS
  if couplings.field: result.add FIELD_SPECS

func shaderSpecsFor*(kind: SimKind): seq[ShaderSpec] =
  ## The shaders a legacy mode id's world needs, through the couplings triple
  ## that id always meant.
  shaderSpecsFor(couplingsFor(kind))
