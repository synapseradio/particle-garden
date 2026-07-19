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
  ## The compute shaders a simulation kind's frame dispatches. The keys here
  ## are exactly the Dispatch.pipelineKey values sim_registry.buildFrame(kind)
  ## emits — the relation test pins that agreement.
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
    # Pipelines land with their stage (roadmap S8).
    @[]
