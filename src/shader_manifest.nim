# ==============================================================================
# PARTICLE GARDEN - COMPUTE SHADER MANIFEST (Pure)
# ==============================================================================
#
# The compute shaders each simulation kind needs, as data. A pure companion to
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
    ## One compute shader a simulation kind needs: its dictionary key (shared
    ## by the pipelines/bindGroups dictionaries and the frame's Dispatch
    ## pipelineKey), the URL main.nim serves it at, its debug label, and its
    ## WGSL entry-point function name.
    key*: string
    path*: string
    label*: string
    entryPoint*: string

func shaderSpecsFor*(kind: SimKind): seq[ShaderSpec] =
  ## The compute shaders a simulation kind's frame dispatches, plus any the
  ## mode runs outside its frame. Every Dispatch.pipelineKey that
  ## sim_registry.buildFrame(kind) emits appears here — the relation test pins
  ## that direction. The converse does not hold: a one-shot shader like
  ## fieldSeed, which the executor encodes on demand rather than every frame,
  ## is registered here and dispatched by no frame node at all.
  case kind
  of skParticleLife: @[
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
    ShaderSpec(key: "forces", path: "./shaders/forces.wgsl",
      label: "Forces Shader (AoS)", entryPoint: "computeForces"),
    ShaderSpec(key: "integrate", path: "./shaders/integrate.wgsl",
      label: "Integrate Shader (AoS)", entryPoint: "integrate"),
  ]
  of skSph: @[
    # SPH shares the grid triad, bin-scatter, and integrate with particle-life
    # verbatim; only the force pass differs. forcesSph self-resets the delta
    # buffers via atomicStore exactly as forces does, so the frame clears none.
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
    ShaderSpec(key: "forcesSph", path: "./shaders/forces-sph.wgsl",
      label: "SPH Forces", entryPoint: "computeForces"),
    ShaderSpec(key: "integrate", path: "./shaders/integrate.wgsl",
      label: "Integrate Shader (AoS)", entryPoint: "integrate"),
  ]
  of skReactionDiffusion:
    # The field mode's own six compute shaders, plus the particle-life
    # integrate pass it reuses verbatim (same pipeline, same spec entry — RD's
    # fieldForce writes velocityDelta in the same layout integrate expects).
    # rdStepToFront and rdStepToTrail share one shader file and entry point:
    # one WGSL pipeline, but the executor gives each dispatch key its own bind
    # group over that pipeline (the two orientations of the field-texture
    # ping-pong), so both keys are registered against the same path/entry. The
    # keys name their DESTINATION texture; the older Forward/Reverse names said
    # nothing about which texture ended up holding the live field, which is
    # exactly how an off-by-one-substep parity bug hid in the sequence.
    @[
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
      ShaderSpec(key: "integrate", path: "./shaders/integrate.wgsl",
        label: "Integrate Shader (AoS)", entryPoint: "integrate"),
    ]
