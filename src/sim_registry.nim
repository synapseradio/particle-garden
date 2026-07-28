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

# field_core is itself pure (no FFI), so importing it for RD_STEPS_PER_FRAME
# keeps this module's own purity guarantee intact.
import field_core

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
# SECTION 1a: WORLD COUPLINGS
# ==============================================================================
#
# What the world couples together this frame. Three independent booleans rather
# than one mode enum, because the interesting worlds are combinations: particles
# that both feel each other AND write the chemical field is the whole point of
# the merge, and it is not expressible as a fourth mode without also writing a
# fifth and a sixth.
#
# SimKind above survives as the PRESET COMPATIBILITY LAYER and nothing more.
# Presets serialize the stable mode ids, and couplingsFor maps each to the
# triple it always meant. No migration is needed: preset.nim deliberately does
# not restrict `mode` to a known-mode allowlist, so a preset written by any
# build round-trips.

type
  WorldCouplings* = object
    ## Which force and field couplings the frame composes.
    forces*: bool  ## Species attraction over the spatial hash (forces.wgsl).
    sph*: bool     ## Smoothed-particle pressure and viscosity (forces-sph.wgsl).
    field*: bool   ## The reaction-diffusion chemical field.

func couplingsFor*(kind: SimKind): WorldCouplings =
  ## The couplings triple a legacy mode id always meant.
  case kind
  of skParticleLife: WorldCouplings(forces: true, sph: false, field: false)
  of skSph: WorldCouplings(forces: false, sph: true, field: false)
  of skReactionDiffusion: WorldCouplings(forces: false, sph: false, field: true)

func buildsSpatialHash*(couplings: WorldCouplings): bool =
  ## Whether the frame needs the grid triad and the sorted-particle scatter.
  ## Both force models search neighbors through it; the field does not — its
  ## particles read a texture, never each other.
  couplings.forces or couplings.sph

func computesDensity*(couplings: WorldCouplings): bool =
  ## Whether any active coupling writes per-particle density. forces.wgsl and
  ## forces-sph.wgsl both accumulate it over the neighbor search; the field
  ## passes write velocity only, so a field-only world reads a stale density of
  ## roughly zero and the renderer floors the glow's density term instead.
  ##
  ## The same triple as buildsSpatialHash for a different reason: that one
  ## answers what the frame must dispatch, this one what the frame produces.
  ## Adding a density-writing coupling that needs no grid separates them.
  couplings.forces or couplings.sph

# ==============================================================================
# SECTION 1b: THE CONTROLS EACH MODE USES
# ==============================================================================
#
# Which descriptor groups a mode's panel shows. This lives beside buildFrame
# deliberately: what a mode's frame dispatches is what decides which knobs can
# possibly affect it, and keeping the two lists in one file is what lets a
# native test assert the relation — for instance that a mode whose frame runs
# no `forces` dispatch does not offer the force-model groups.
#
# Two of the ids name no descriptor. They key panel sections that are not
# slider lists (the attraction-matrix editor, the force-model button row), and
# tests/test_sim_registry.nim declares them so the coverage invariant can tell
# a deliberate section-only id from a typo.

const
  SECTION_ONLY_GROUPS* = ["matrix", "force-model"]
    ## Group ids that key a panel section rather than a set of sliders. Every
    ## other id a mode lists must own at least one descriptor.

const
  UNIVERSAL_GROUPS* = [
    "simulation", "render", "glow", "bloom", "palette", "camera"]
    ## Groups every world offers. These touch the particle buffer, the
    ## renderer, or the palette — none of which any coupling can switch off.
    ## "camera" belongs here for a slightly different reason than the rest: it
    ## is not about the particle buffer at all, it is about where the viewer is
    ## standing, and no coupling can take that away either.
  FORCES_GROUPS* = [
    "grid", "particle-life", "matrix", "force-model",
    "force-polynomial", "force-exponential"]
    ## forces.wgsl is the sole reader of the attraction matrix and the
    ## force-model selector. "grid" rides along because the neighbor search
    ## bins by interactionRadius.
  SPH_GROUPS* = ["grid", "sph"]
    ## No matrix and no force-model: forces-sph.wgsl reads neither. It DOES
    ## read interactionRadius as its smoothing radius, which is why "grid"
    ## appears here too — the union is what makes sharing it correct.
  FIELD_GROUPS* = ["rd", "rd-field"]

func addGroups(target: var seq[string], groups: openArray[string]) =
  ## Appends every group `target` does not already carry, in first-seen order.
  ## One guard for every contributor rather than for whichever set happens to
  ## share an id today: "grid" belongs to both force couplings, and any future
  ## overlap between two coupling sets is covered by the same code.
  for group in groups:
    if group notin target: target.add group

func controlGroupsFor*(couplings: WorldCouplings): seq[string] =
  ## The union of every active coupling's descriptor groups. Everything not
  ## listed is hidden — not disabled, absent.
  ##
  ## A union rather than a per-mode list because couplings compose: a world
  ## running forces and field must offer both sets, and no third list should
  ## have to be written to say so. "grid" appearing in two coupling sets is
  ## exactly why this deduplicates rather than concatenates.
  addGroups(result, UNIVERSAL_GROUPS)
  if couplings.forces: addGroups(result, FORCES_GROUPS)
  if couplings.sph: addGroups(result, SPH_GROUPS)
  if couplings.field: addGroups(result, FIELD_GROUPS)

# ==============================================================================
# SECTION 2: FRAME DESCRIPTION TYPES
# ==============================================================================

type
  SimBuffer* = enum
    ## GPU buffers a frame node may clear or copy. The executor maps each to
    ## the live GPUBuffer and its per-frame byte length (the first four are
    ## sized by grid cell count; sbFieldDeposit is sized by field cell count).
    sbGridCounts
    sbGridOffsets
    sbFillPointers
    sbVelocityDelta
      ## The per-particle velocity accumulator, TWO i32 per particle (x and y).
      ## Every contributor — forces, forcesSph, fieldForce — accumulates into
      ## it atomically, and the frame clears it once at the top. That split is
      ## what lets two contributors run in the same frame: while each pass
      ## self-reset the buffer, whichever ran second erased the first.
    sbDensityDelta
    sbFieldDeposit
      ## The reaction-diffusion fixed-point splat buffer: one i32 per FIELD_W x
      ## FIELD_H cell. fieldDeposit accumulates each particle's inhibitor
      ## contribution into it and fieldResolve reads it to update the field
      ## texture. buildFrame(skReactionDiffusion) does not clear it, because
      ## fieldResolve zeroes each cell as it consumes it — the same self-reset
      ## convention forces.wgsl/forces-sph.wgsl use for velocityDelta and
      ## densityDelta.

  DispatchSize* = enum
    ## Symbolic dispatch sizes, resolved by the executor each frame. The
    ## description itself stays immutable: particle count and grid size
    ## changes never rebuild it.
    dsParticleWorkgroups  ## ceil(particleCount / workgroup size)
    dsScanBlocks          ## ceil(numCells / prefix-sum block size)
    dsOne                 ## a single workgroup
    dsFieldWorkgroups
      ## ceil(FIELD_W / workgroup size X) x ceil(FIELD_H / workgroup size Y):
      ## the one 2D dispatch size in this enum. Every other DispatchSize
      ## resolves to a single workgroup count; the executor special-cases
      ## this value with a dispatchWorkgroups(x, y) call
      ## (webgpu_compute.nim's frame walk) rather than resolving it through
      ## the same one-int path as the others.

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
  PROFILER_SLOT_FIELD* = 5
    ## Mirrors gpu_profiler.passField — the reaction-diffusion field pass.
    ## Distinct from PROFILER_SLOT_GRID_BUILD because this mode runs no
    ## grid-build passes, so sharing that slot reported field time under a
    ## label that meant something else in the other two modes.
  PROFILER_SLOT_INTEGRATE* = 6
    ## Mirrors gpu_profiler.passIntegrate. integrate moved out of the physics
    ## pass because it must run after the field passes and the field passes
    ## must run after forces — three orderings that no single pass can hold.
    ## app.nim adds this slot back into the reported physics time, so the
    ## number the stats show still means what it meant before the split.

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

func forcePassLabel(couplings: WorldCouplings): string =
  ## The profiler's name for the force pass. The legacy labels are preserved
  ## for the legacy triples so a profile taken before the merge still reads
  ## against one taken after.
  if couplings.forces and couplings.sph: "Physics (AoS+SPH)"
  elif couplings.sph: "Physics (SPH)"
  else: "Physics (AoS)"

func buildFrame*(couplings: WorldCouplings): FrameDescription =
  ## The full GPU frame the couplings compose.
  ##
  ## THE FRAME OWNS THE DELTA RESETS. Every accumulation buffer is cleared here,
  ## once, before anything writes it; every contributing pass accumulates only.
  ## This is what lets forces and fieldForce both run in one frame — while each
  ## pass self-reset velocityDelta in its own prologue, whichever ran second
  ## erased the first's contribution entirely.
  ##
  ## The clears are encoder-level operations interleaved into the same ordered
  ## command stream as the compute passes, so a clear that precedes a dispatch
  ## is ordered before it, not racing it. clearBufferNode(sbGridCounts) has
  ## always worked this way ahead of bin-count's atomic increments.
  ##
  ## Substepping (running the whole frame N times per rendered frame for
  ## stability at high stiffness) is an EXECUTOR loop, not frame nodes: the
  ## executor encodes this description N times in one command encoder. The
  ## description stays one substep's worth of work.

  # Both delta buffers, every frame, whatever is coupled. Clearing a buffer no
  # pass writes this frame costs one encoder operation and removes a whole
  # class of question about what the previous couplings left behind.
  result = @[
    clearBufferNode(sbVelocityDelta),
    clearBufferNode(sbDensityDelta),
  ]

  if buildsSpatialHash(couplings):
    # gridCounts must start at zero for bin-count's atomic increments.
    result.add clearBufferNode(sbGridCounts)
    result.add computePassNode("Grid Build", PROFILER_SLOT_GRID_BUILD, @[
      dispatch("binCount", dsParticleWorkgroups),
      dispatch("prefixLocal", dsScanBlocks),
      dispatch("prefixBlocks", dsOne),
      dispatch("prefixFinal", dsScanBlocks),
    ])
    # bin-scatter consumes fillPointers as its running write cursors, which
    # must start at each cell's exclusive-scan offset.
    result.add copyBufferNode(sbGridOffsets, sbFillPointers)

    var forceDispatches = @[dispatch("binScatter", dsParticleWorkgroups)]
    if couplings.forces:
      forceDispatches.add dispatch("forces", dsParticleWorkgroups)
    if couplings.sph:
      forceDispatches.add dispatch("forcesSph", dsParticleWorkgroups)
    result.add computePassNode(
      forcePassLabel(couplings), PROFILER_SLOT_PHYSICS, forceDispatches)

  if couplings.field:
    var fieldDispatches = @[
      dispatch("fieldDeposit", dsParticleWorkgroups),
      dispatch("fieldResolve", dsFieldWorkgroups),
    ]
    # RD_STEPS_PER_FRAME Gray-Scott substeps, alternating which of the two
    # field-texture copies is read from vs. written to each substep (the
    # ping-pong pattern a storage texture needs since a shader cannot read
    # and write the same texture binding in one dispatch).
    #
    # THE CHAIN MUST CLOSE. fieldResolve above is itself a ping-pong stage —
    # it reads the front texture and writes the trailing one — so the frame
    # performs 1 + RD_STEPS_PER_FRAME swaps in total. The substeps therefore
    # start on the texture resolve just wrote (the trail, hence ToFront first)
    # and must end back on the front, which is what the renderer, fieldForce,
    # and the next frame's resolve all read. That closure is why field_core
    # statically asserts RD_STEPS_PER_FRAME is odd: an even count leaves the
    # live field on the trailing texture where nothing looks for it, silently
    # discarding the last substep every single frame.
    for stepIndex in 0 ..< RD_STEPS_PER_FRAME:
      if stepIndex mod 2 == 0:
        fieldDispatches.add dispatch("rdStepToFront", dsFieldWorkgroups)
      else:
        fieldDispatches.add dispatch("rdStepToTrail", dsFieldWorkgroups)
    fieldDispatches.add dispatch("fieldForce", dsParticleWorkgroups)
    result.add computePassNode(
      "Field (RD)", PROFILER_SLOT_FIELD, fieldDispatches)

  # integrate always closes the frame: it is the one pass that reads the
  # summed deltas and moves particles, so every contributor must already have
  # run. It sits in its own pass because the field passes have to come between
  # it and the force pass, and one compute pass cannot be in two places.
  result.add computePassNode("Integrate", PROFILER_SLOT_INTEGRATE, @[
    dispatch("integrate", dsParticleWorkgroups),
  ])
