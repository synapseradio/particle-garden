# ==============================================================================
# PARTICLE GARDEN - COMPUTE SHADER MANIFEST (Pure)
# ==============================================================================
#
# The compute shaders the world needs, as data. A pure companion to
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
# native (just test) and JS backends.
#
# ==============================================================================

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
    ## The spatial hash, world-intrinsic and registered once. Both force
    ## couplings search through it, so hoisting it here is what keeps them from
    ## each carrying a copy of these five pipelines.
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
    ## Smoothed-particle pressure and viscosity. It runs alongside the force
    ## pass rather than in place of it, and searches the same spatial hash,
    ## which is why it reads interactionRadius as its smoothing radius and
    ## shares GRID_SPECS verbatim.
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
    ## off-by-one-substep parity bug hides in the sequence.

func allShaderSpecs*(): seq[ShaderSpec] =
  ## Every compute shader the world can dispatch, registered once at init.
  ##
  ## ONE WORLD, ONE PIPELINE SET, AND THE REASON IS TIMING RATHER THAN TIDINESS.
  ## A strength crossing zero rebuilds the frame description, which is pure and
  ## costs nothing. Creating a pipeline is neither: the shader has to be fetched
  ## over HTTP and compiled, so registering only the couplings currently acting
  ## would make a slider leaving zero an asynchronous operation, and the frames
  ## between the slider moving and the pipeline arriving would dispatch against
  ## a missing dictionary entry. Registering everything up front costs one
  ## compile per shader at startup and makes every strength change synchronous.
  ##
  ## This is also what keeps the manifest free of enumeration. There is no
  ## per-world list to fall out of step with buildFrame, and
  ## tests/test_shader_manifest.nim asserts the relation that remains: every key
  ## any frame dispatches is registered here, and no key is registered twice.
  result.add INTEGRATE_SPEC
  result.add GRID_SPECS
  result.add FORCES_SPECS
  result.add SPH_SPECS
  result.add FIELD_SPECS
