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
  BODY_SPECS* = [
    ShaderSpec(key: "bodyForce", path: "./shaders/body-force.wgsl",
      label: "Body Force Shader", entryPoint: "applyBodyForce"),
    ShaderSpec(key: "bodyIntegrate", path: "./shaders/body-integrate.wgsl",
      label: "Body Integrate Shader", entryPoint: "integrateBodies"),
  ]
    ## What the bodies do to the particles, and what the particles do back. The
    ## force pass reads particle positions and writes the velocity accumulator,
    ## exactly as fieldForce does, and needs no grid: a body's reach is its own
    ## band rather than the neighbour sweep's radius. The integrate is one
    ## thread per body over the sum of the reactions the force pass accumulated.

  LONG_RANGE_SPECS* = [
    ShaderSpec(key: "lrDeposit", path: "./shaders/lr-deposit.wgsl",
      label: "Long Range Deposit Shader", entryPoint: "depositCharge"),
    ShaderSpec(key: "lrFftRows", path: "./shaders/lr-fft-rows.wgsl",
      label: "Long Range Row Transform Shader", entryPoint: "transformRows"),
    ShaderSpec(key: "lrFftCols", path: "./shaders/lr-fft-cols.wgsl",
      label: "Long Range Column Transform Shader",
      entryPoint: "transformCols"),
    ShaderSpec(key: "lrKernel", path: "./shaders/lr-kernel.wgsl",
      label: "Long Range Kernel Shader", entryPoint: "mixSpectra"),
    ShaderSpec(key: "lrFftColsInv", path: "./shaders/lr-fft-cols.wgsl",
      label: "Long Range Column Transform Shader (Inverse)",
      entryPoint: "transformColsInverse"),
    ShaderSpec(key: "lrFftRowsInv", path: "./shaders/lr-fft-rows.wgsl",
      label: "Long Range Row Transform Shader (Inverse)",
      entryPoint: "transformRowsInverse"),
    ShaderSpec(key: "lrForce", path: "./shaders/lr-force.wgsl",
      label: "Long Range Force Shader", entryPoint: "applyLongRangeForce"),
  ]
    ## The long-range mesh: deposit, the forward transform along each axis, the
    ## matrix-weighted mix in k-space, the inverse back, and the force the
    ## particles feel. Seven keys over five files.
    ##
    ## Each transform file carries two entry points rather than two files
    ## carrying one each: rows and columns walk different strides and so are
    ## genuinely different shaders, while forward and inverse along one axis
    ## differ by a sign and a normalization inside otherwise identical code.
    ## This is the other arrangement a shared file takes — rdStepToFront and
    ## rdStepToTrail share a file AND an entry point, differing only in which
    ## textures their bind groups name.

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
  result.add BODY_SPECS
  result.add LONG_RANGE_SPECS
