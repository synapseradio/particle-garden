# ==============================================================================
# PARTICLE GARDEN - SIMULATION PASS REGISTRY (Pure)
# ==============================================================================
#
# The frame as data: a pure, natively-tested description of the GPU work one
# physics frame performs, per simulation kind. webgpu_compute.nim builds the
# active frame once (at init or on a structural change, never per frame) and
# walks it each frame, resolving symbolic dispatch sizes against the live
# particle count and grid dimensions.
#
# A new simulation mode registers a frame here instead of forking the
# executor: its passes become data, its pipelines pre-warm at init, and its
# sequence is pinned by tests/test_sim_registry.nim the same way
# particle-life's is.
#
# Pure module: no FFI, no imports from GPU-facing code. Compiles on both the
# native (nimble test) and JS backends.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: SIMULATION KINDS
# ==============================================================================

type
  SimKind* = enum
    ## The simulation modes the garden offers. Serialization (presets, the
    ## mode selector) uses the stable string ids below via simKindId /
    ## parseSimKind — never ordinals, so reordering this enum cannot change
    ## what a saved preset means.
    skParticleLife
    skSph
    skReactionDiffusion

func simKindId*(kind: SimKind): string =
  ## The stable serialization id for a simulation kind.
  case kind
  of skParticleLife: "particle-life"
  of skSph: "sph"
  of skReactionDiffusion: "reaction-diffusion"

func parseSimKind*(id: string): SimKind =
  ## Inverse of simKindId. Raises ValueError for an unknown id — callers
  ## dealing with untrusted input (presets) catch and fall back explicitly.
  for kind in SimKind:
    if simKindId(kind) == id:
      return kind
  raise newException(ValueError, "unknown simulation kind id: " & id)

# ==============================================================================
# SECTION 2: FRAME DESCRIPTION TYPES
# ==============================================================================

type
  SimBuffer* = enum
    ## GPU buffers a frame node may clear or copy. The executor maps each to
    ## the live GPUBuffer and its per-frame byte length (all four are sized
    ## by grid cell count today).
    sbGridCounts
    sbGridOffsets
    sbFillPointers
    sbDensityDelta

  DispatchSize* = enum
    ## Symbolic dispatch sizes, resolved by the executor each frame. The
    ## description itself stays immutable: particle count and grid size
    ## changes never rebuild it.
    dsParticleWorkgroups  ## ceil(particleCount / workgroup size)
    dsScanBlocks          ## ceil(numCells / prefix-sum block size)
    dsOne                 ## a single workgroup

  Dispatch* = object
    ## One setPipeline/setBindGroup/dispatchWorkgroups triple. pipelineKey
    ## indexes webgpu_compute's pipelines/bindGroups dictionaries.
    pipelineKey*: string
    size*: DispatchSize

  FrameNodeKind* = enum
    fnkClearBuffer
    fnkCopyBuffer
    fnkComputePass

  FrameNode* = object
    ## One step of a frame: an encoder-level buffer operation or a compute
    ## pass grouping dispatches under a label and a profiler slot.
    case kind*: FrameNodeKind
    of fnkClearBuffer:
      clearTarget*: SimBuffer
    of fnkCopyBuffer:
      copySource*: SimBuffer
      copyDest*: SimBuffer
    of fnkComputePass:
      label*: string
      profilerSlot*: int
      dispatches*: seq[Dispatch]

  FrameDescription* = seq[FrameNode]

const
  PROFILER_SLOT_GRID_BUILD* = 0
    ## Mirrors gpu_profiler.passGridBuild (that module is JS-only, so the
    ## value is duplicated here; both sides document the pairing).
  PROFILER_SLOT_PHYSICS* = 1
    ## Mirrors gpu_profiler.passPhysics.

# ==============================================================================
# SECTION 3: NODE CONSTRUCTORS
# ==============================================================================

func clearBufferNode*(target: SimBuffer): FrameNode =
  FrameNode(kind: fnkClearBuffer, clearTarget: target)

func copyBufferNode*(source, dest: SimBuffer): FrameNode =
  FrameNode(kind: fnkCopyBuffer, copySource: source, copyDest: dest)

func computePassNode*(label: string, profilerSlot: int,
    dispatches: seq[Dispatch]): FrameNode =
  FrameNode(kind: fnkComputePass, label: label, profilerSlot: profilerSlot,
    dispatches: dispatches)

func dispatch*(pipelineKey: string, size: DispatchSize): Dispatch =
  Dispatch(pipelineKey: pipelineKey, size: size)

# ==============================================================================
# SECTION 4: FRAME DESCRIPTIONS PER KIND
# ==============================================================================

func buildFrame*(kind: SimKind): FrameDescription =
  ## The full GPU frame for a simulation kind. Raises ValueError for kinds
  ## whose frames are not implemented yet, so a mode cannot silently run
  ## another mode's physics.
  case kind
  of skParticleLife:
    @[
      # gridCounts must start at zero for bin-count's atomic increments.
      # Deliberately NO clears of velocityDelta/densityDelta: forces.wgsl
      # self-resets them via atomicStore, and an encoder-level clear here
      # would race those atomics.
      clearBufferNode(sbGridCounts),
      computePassNode("Grid Build", PROFILER_SLOT_GRID_BUILD, @[
        dispatch("binCount", dsParticleWorkgroups),
        dispatch("prefixLocal", dsScanBlocks),
        dispatch("prefixBlocks", dsOne),
        dispatch("prefixFinal", dsScanBlocks),
      ]),
      # bin-scatter consumes fillPointers as its running write cursors,
      # which must start at each cell's exclusive-scan offset.
      copyBufferNode(sbGridOffsets, sbFillPointers),
      computePassNode("Physics (AoS)", PROFILER_SLOT_PHYSICS, @[
        dispatch("binScatter", dsParticleWorkgroups),
        dispatch("forces", dsParticleWorkgroups),
        dispatch("integrate", dsParticleWorkgroups),
      ]),
    ]
  of skSph:
    raise newException(ValueError, "SPH frame not implemented yet (roadmap S7)")
  of skReactionDiffusion:
    raise newException(ValueError,
      "reaction-diffusion frame not implemented yet (roadmap S8)")
