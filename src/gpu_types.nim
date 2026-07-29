# =============================================================================
# GPU TYPES - Type-Safe GPU Buffer Layouts
# =============================================================================
#
# The single source of truth for GPU struct layouts in Nim.
# The WGSL modules in web/shaders/modules/ should match these definitions.
# =============================================================================

# std/macros powers genFieldIndices, which emits the SIM_*/RENDER_*/FADE_*
# buffer-write indices from the layout tables. std/strutils feeds the macro's
# name mangling. Compile-time only; the JS backend never ships either.
import std/macros
import std/strutils

# MAX_SPECIES is the cross-language species ceiling. SpeciesChemistryLayout
# sizes its arrays against it, so a raise that outgrows the packing fails the
# static assertion below rather than silently truncating a species.
import memory_layout

# =============================================================================
# GPU TYPE SYSTEM
# =============================================================================

type
  GpuType* = enum
    ## WGSL scalar and vector types with known sizes
    gtF32
    gtU32
    gtI32
    gtVec2F32
    gtVec3F32
    gtVec4F32
    gtVec2U32
    gtVec4U32
    gtArray

  GpuField* = object
    ## A field within a GPU struct
    name*: string
    kind*: GpuType
    offset*: int      ## Byte offset from struct start
    size*: int        ## Size in bytes
    count*: int       ## Array element count (1 for non-arrays)
    elemKind*: GpuType  ## Element type for gtArray fields; ignored for scalars
                        ## (defaults to gtF32). Drives the WGSL `array<T, N>`
                        ## emitted by toWgslStruct.

  GpuStruct* = object
    ## A complete GPU struct definition
    name*: string
    fields*: seq[GpuField]
    totalSize*: int   ## Total size including padding

# =============================================================================
# TYPE SIZE HELPERS
# =============================================================================

func gpuTypeSize*(t: GpuType): int =
  case t
  of gtF32, gtU32, gtI32: 4
  of gtVec2F32, gtVec2U32: 8
  of gtVec3F32: 12  # Note: aligns to 16 in structs!
  of gtVec4F32, gtVec4U32: 16
  of gtArray: 0     # Must be calculated from element type * count

func gpuTypeAlignment*(t: GpuType): int =
  case t
  of gtF32, gtU32, gtI32: 4
  of gtVec2F32, gtVec2U32: 8
  of gtVec3F32, gtVec4F32, gtVec4U32: 16
  of gtArray: 16    # Arrays align to 16 bytes in WGSL

# =============================================================================
# STRUCT DEFINITIONS - Single Source of Truth
# =============================================================================

const
  # Particle struct (32 bytes, matches web/shaders/modules/particle.wgsl)
  ParticleLayout* = GpuStruct(
    name: "Particle",
    fields: @[
      GpuField(name: "pos",     kind: gtVec2F32, offset: 0,  size: 8,  count: 1),
      GpuField(name: "vel",     kind: gtVec2F32, offset: 8,  size: 8,  count: 1),
      GpuField(name: "species", kind: gtU32,     offset: 16, size: 4,  count: 1),
      GpuField(name: "density", kind: gtF32,     offset: 20, size: 4,  count: 1),
      GpuField(name: "sphDensity", kind: gtF32,  offset: 24, size: 4,  count: 1),
      GpuField(name: "crowdDensity", kind: gtF32, offset: 28, size: 4, count: 1),
    ],
    totalSize: 32
  )

  # GridParams struct (32 bytes, matches web/shaders/modules/grid_params.wgsl)
  GridParamsLayout* = GpuStruct(
    name: "GridParams",
    fields: @[
      GpuField(name: "gridW",        kind: gtU32, offset: 0,  size: 4, count: 1),
      GpuField(name: "gridH",        kind: gtU32, offset: 4,  size: 4, count: 1),
      GpuField(name: "worldWidth",   kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "worldHeight",  kind: gtF32, offset: 12, size: 4, count: 1),
      GpuField(name: "particleCount", kind: gtU32, offset: 16, size: 4, count: 1),
      GpuField(name: "padding0",     kind: gtU32, offset: 20, size: 4, count: 1),
      GpuField(name: "padding1",     kind: gtU32, offset: 24, size: 4, count: 1),
      GpuField(name: "padding2",     kind: gtU32, offset: 28, size: 4, count: 1),
    ],
    totalSize: 32
  )

  # ScanParams struct (16 bytes, matches web/shaders/modules/scan_params.wgsl)
  ScanParamsLayout* = GpuStruct(
    name: "ScanParams",
    fields: @[
      GpuField(name: "numCells",  kind: gtU32, offset: 0,  size: 4, count: 1),
      GpuField(name: "numBlocks", kind: gtU32, offset: 4,  size: 4, count: 1),
      GpuField(name: "padding1",  kind: gtU32, offset: 8,  size: 4, count: 1),
      GpuField(name: "padding2",  kind: gtU32, offset: 12, size: 4, count: 1),
    ],
    totalSize: 16
  )

  # SimParams struct (256 bytes written, 256 allocated; matches forces.wgsl /
  # forces-sph.wgsl)
  # Layout: 16 scalar fields (64 bytes) + 9 vec4 matrix (144 bytes) + 6 force-model
  # fields (24 bytes) + 4 SPH fields (16 bytes) + crowding (4 bytes) + the SPH
  # radius fraction (4 bytes). The written size fills the allocation
  # exactly, so the next field costs a 16-byte block rather than a pad.
  SimParamsLayout* = GpuStruct(
    name: "SimParams",
    fields: @[
      # Core simulation parameters (0-15)
      GpuField(name: "dt",              kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "worldWidth",      kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "worldHeight",     kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "interactionRadius", kind: gtF32, offset: 12, size: 4, count: 1),
      GpuField(name: "forceMultiplier", kind: gtF32, offset: 16, size: 4, count: 1),
      GpuField(name: "gridCellsX",      kind: gtU32, offset: 20, size: 4, count: 1),
      GpuField(name: "gridCellsY",      kind: gtU32, offset: 24, size: 4, count: 1),
      GpuField(name: "mouseX",          kind: gtF32, offset: 28, size: 4, count: 1),
      GpuField(name: "mouseY",          kind: gtF32, offset: 32, size: 4, count: 1),
      GpuField(name: "mouseLeftDown",   kind: gtF32, offset: 36, size: 4, count: 1),
      GpuField(name: "mouseRightDown",  kind: gtF32, offset: 40, size: 4, count: 1),
      GpuField(name: "particleCount",   kind: gtU32, offset: 44, size: 4, count: 1),
      GpuField(name: "blastX",          kind: gtF32, offset: 48, size: 4, count: 1),
      GpuField(name: "blastY",          kind: gtF32, offset: 52, size: 4, count: 1),
      GpuField(name: "blastStrength",   kind: gtF32, offset: 56, size: 4, count: 1),
      # Spends the pad rather than growing the struct. Sits in the core block
      # only because that is where the free word is; forces-sph.wgsl is the
      # sole reader.
      GpuField(name: "fluidStrength",   kind: gtF32, offset: 60, size: 4, count: 1),
      # Attraction matrix: 36 floats packed as 9 vec4s (64-208)
      GpuField(name: "attractionMatrix", kind: gtArray, offset: 64, size: 144, count: 9, elemKind: gtVec4F32),
      # Force model parameters (208-232)
      GpuField(name: "repulsionEnd",    kind: gtF32, offset: 208, size: 4, count: 1),
      GpuField(name: "attractionPeak",  kind: gtF32, offset: 212, size: 4, count: 1),
      GpuField(name: "forceModel",      kind: gtU32, offset: 216, size: 4, count: 1),
      GpuField(name: "expAlpha",        kind: gtF32, offset: 220, size: 4, count: 1),
      GpuField(name: "expBeta",         kind: gtF32, offset: 224, size: 4, count: 1),
      GpuField(name: "_pad2",           kind: gtF32, offset: 228, size: 4, count: 1),
      # SPH fluid parameters (232-248). forces-sph.wgsl reads these; the
      # species force shader ignores them.
      GpuField(name: "sphRestDensity",  kind: gtF32, offset: 232, size: 4, count: 1),
      GpuField(name: "sphStiffness",    kind: gtF32, offset: 236, size: 4, count: 1),
      GpuField(name: "sphGamma",        kind: gtF32, offset: 240, size: 4, count: 1),
      GpuField(name: "sphViscosity",    kind: gtF32, offset: 244, size: 4, count: 1),
      # Crowding (248-252). forces.wgsl reads it; the fluid ignores it. Appended
      # rather than spending _pad2 above, so the force-model block and the SPH
      # block keep the offsets every existing write targets.
      GpuField(name: "crowdingStrength", kind: gtF32, offset: 248, size: 4, count: 1),
      # The SPH smoothing radius as a fraction of interactionRadius (252-256).
      # forces-sph.wgsl multiplies the two; the fraction is capped at 1 by its
      # range, so the smoothing radius can never outrun the neighbour sweep,
      # whose cells are sized to the interaction radius (src/grid.nim). Appended
      # for the reason crowding was, rather than joining the SPH block above:
      # every write that exists keeps the offset it targets.
      GpuField(name: "sphRadiusFraction", kind: gtF32, offset: 252, size: 4, count: 1),
    ],
    totalSize: 256
  )

  # RenderParams struct (64 bytes, generated into web/shaders/modules/render_params.wgsl)
  # glowDensityFloor is a floor under the glow's density factor, for a
  # world where colony density is unavailable. forces.wgsl is world-intrinsic
  # and writes that density every frame, so webgpu_render.nim writes the floor
  # at 0 and glow.wgsl's max is inert. The field stays until someone shrinks
  # RenderParams deliberately.
  #
  # fieldOpacity and colormapIndex are duplicated here from TonemapParams so the
  # VERTEX stage can light each particle by the field it is standing in
  # (render.wgsl), which the composite stages cannot do — they only ever see the
  # field per screen pixel, after the particles are already coloured. They spend
  # two of the three pads that rounded the struct to 64 bytes, so the field
  # reaches the render stage without growing or reallocating the uniform. One
  # pad remains.
  RenderParamsLayout* = GpuStruct(
    name: "RenderParams",
    fields: @[
      GpuField(name: "resolution",        kind: gtVec2F32, offset: 0,  size: 8, count: 1),
      GpuField(name: "worldSize",         kind: gtVec2F32, offset: 8,  size: 8, count: 1),
      GpuField(name: "baseSize",          kind: gtF32, offset: 16, size: 4, count: 1),
      GpuField(name: "glowIntensity",     kind: gtF32, offset: 20, size: 4, count: 1),
      GpuField(name: "velocityGlowScale", kind: gtF32, offset: 24, size: 4, count: 1),
      GpuField(name: "maxVelocity",       kind: gtF32, offset: 28, size: 4, count: 1),
      GpuField(name: "trailLengthScale",  kind: gtF32, offset: 32, size: 4, count: 1),
      GpuField(name: "glowRadiusScale",   kind: gtF32, offset: 36, size: 4, count: 1),
      GpuField(name: "glowFalloff",       kind: gtF32, offset: 40, size: 4, count: 1),
      GpuField(name: "glowWarmth",        kind: gtF32, offset: 44, size: 4, count: 1),
      GpuField(name: "glowDensityFloor",  kind: gtF32, offset: 48, size: 4, count: 1),
      GpuField(name: "fieldOpacity",      kind: gtF32, offset: 52, size: 4, count: 1),
      GpuField(name: "colormapIndex",     kind: gtF32, offset: 56, size: 4, count: 1),
      GpuField(name: "_pad0",             kind: gtF32, offset: 60, size: 4, count: 1),
    ],
    totalSize: 64
  )

  # FadeParams struct (16 bytes, generated into web/shaders/modules/fade_params.wgsl)
  #
  # The fade pass's own two settings and nothing else. How much of the previous
  # frame survives, and how far the trail slides along the field gradient while
  # it decays.
  #
  # The VIEW the pass reprojects through does not live here. The trail texture
  # is in screen space, so a moving camera has to be reprojected or the history
  # stays welded to the screen and smears across the world, and that needs two
  # cameras — where a world point is now, and where it sat on the frame the
  # trail was drawn. Both arrive as Camera records on their own bindings, so
  # the pass reads the same struct the renderer transforms through instead of
  # reassembling one from scalars carried here.
  FadeParamsLayout* = GpuStruct(
    name: "FadeParams",
    fields: @[
      GpuField(name: "fadeAmount", kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "fieldDriftScale", kind: gtF32, offset: 4, size: 4, count: 1),
      GpuField(name: "pad1",       kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "pad2",       kind: gtF32, offset: 12, size: 4, count: 1),
    ],
    totalSize: 16
  )

  # Camera struct (32 bytes, generated into web/shaders/modules/camera.wgsl)
  # Where the view sits over the toroidal world, how close it is, and how big
  # that world is. Its own uniform rather than more RenderParams fields because
  # RenderParams has one pad left and this needs five slots — and because
  # glow.wgsl needs the camera without needing the rest of RenderParams.
  #
  # centerX/centerY/zoom mirror camera_core.Camera, which is where the transform
  # is tested. centerX/centerY are always wrapped into [0, worldSize); the
  # shaders' nearest-image arithmetic depends on that, exactly as camera_core
  # documents.
  #
  # THE EXTENT TRAVELS WITH THE VIEW. Every transform in camera_transform.wgsl
  # needs the world span as well as the camera — a view over a torus means
  # nothing without the span it wraps around — so the pass that binds a camera
  # gets both from one record. Carrying private copies in the fade and
  # composite passes' own param structs would be two structs holding one
  # number and two chances to disagree about how big the world is inside a
  # single frame.
  #
  # A pass wanting a SECOND view (fade, which reprojects the trail from the
  # previous frame's camera) binds a second buffer of this layout rather than
  # spelling the fields out again somewhere else.
  CameraLayout* = GpuStruct(
    name: "Camera",
    fields: @[
      GpuField(name: "centerX",     kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "centerY",     kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "zoom",        kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "worldWidth",  kind: gtF32, offset: 12, size: 4, count: 1),
      GpuField(name: "worldHeight", kind: gtF32, offset: 16, size: 4, count: 1),
      GpuField(name: "pad0",        kind: gtF32, offset: 20, size: 4, count: 1),
      GpuField(name: "pad1",        kind: gtF32, offset: 24, size: 4, count: 1),
      GpuField(name: "pad2",        kind: gtF32, offset: 28, size: 4, count: 1),
    ],
    totalSize: 32
  )

  # OverlayParams struct (16 bytes, generated into
  # web/shaders/modules/overlay_params.wgsl). The spatial drag overlay:
  # kind selects ring/frame per overlay_core.OverlayKind's ordinals, the
  # centre is in world coordinates, the radius in world units.
  OverlayParamsLayout* = GpuStruct(
    name: "OverlayParams",
    fields: @[
      GpuField(name: "kind",    kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "centerX", kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "centerY", kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "radius",  kind: gtF32, offset: 12, size: 4, count: 1),
    ],
    totalSize: 16
  )

  # FieldParams struct (32 bytes, generated into web/shaders/modules/field_params.wgsl)
  # The chemical field's uniform: the two Gray-Scott tunables (feed,
  # kill), the diffusion rates and timestep field_core.nim's grayScottStep
  # takes as parameters, the two particle-coupling knobs (depositAmount,
  # fieldForceScale) fieldDeposit/fieldForce read, and the seed nonce
  # field-seed.wgsl hashes to place its blobs.
  #
  # The struct is FULL. A ninth field pushes it to 48 bytes and breaks the
  # static offset assertions below along with every uniform write in
  # webgpu_compute.
  FieldParamsLayout* = GpuStruct(
    name: "FieldParams",
    fields: @[
      GpuField(name: "feed",            kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "kill",            kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "diffusionA",      kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "diffusionB",      kind: gtF32, offset: 12, size: 4, count: 1),
      GpuField(name: "deltaT",          kind: gtF32, offset: 16, size: 4, count: 1),
      GpuField(name: "depositAmount",   kind: gtF32, offset: 20, size: 4, count: 1),
      GpuField(name: "fieldForceScale", kind: gtF32, offset: 24, size: 4, count: 1),
      GpuField(name: "seedNonce",       kind: gtF32, offset: 28, size: 4, count: 1),
    ],
    totalSize: 32
  )

  # ReactionParams struct (16 bytes, generated into
  # web/shaders/modules/reaction_params.wgsl)
  #
  # WHICH reaction the field runs. Separate from FieldParamsLayout because that
  # table is full at 32 bytes and its static assertions reject a ninth field —
  # and because the two answer different questions: FieldParams carries the
  # values a user drags, ReactionParams carries the reaction's identity.
  #
  # The uniform exists so a second reaction never revisits rd-step's bind
  # group, its layout, its entry-count constant, or the shader manifest — that
  # reaction's parameters grow this struct in the same change that reads them,
  # never as reserved members ahead of a consumer.
  ReactionParamsLayout* = GpuStruct(
    name: "ReactionParams",
    fields: @[
      GpuField(name: "reactionKind", kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "pad0",         kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "pad1",         kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "pad2",         kind: gtF32, offset: 12, size: 4, count: 1),
    ],
    totalSize: 16
  )

  # SpeciesChemistry struct (64 bytes, generated into
  # web/shaders/modules/species_chemistry.wgsl)
  #
  # Per-species coupling to the field: what a species SECRETES into it (the
  # signed scale on its deposit) and its TROPISM (the signed scale on the
  # gradient force it feels). This is what makes speciesCount change the
  # chemical world's dynamics rather than only its palette — two species with
  # opposite secretion signs push the field in opposite directions at their own
  # locations, and a species with zero on both is inert in the chemistry while
  # still obeying every other coupling.
  #
  # PACKING. Two parallel `array<vec4<f32>, 2>` rather than MAX_SPECIES
  # interleaved pairs, because WGSL's uniform address space rounds an array's
  # element stride up to 16 bytes: `array<vec2<f32>, 6>` would occupy 96 bytes,
  # not 48, and blow the 64-byte budget. Packing four species per vec4 gives
  # eight slots per array in exactly 32 bytes each, so both channels fit in 64
  # with room for MAX_SPECIES up to 8. Shaders index a species the same way
  # forces.wgsl indexes the attraction matrix: `secretion[i / 4u][i % 4u]`.
  SpeciesChemistryLayout* = GpuStruct(
    name: "SpeciesChemistry",
    fields: @[
      GpuField(name: "secretion", kind: gtArray, offset: 0,  size: 32, count: 2, elemKind: gtVec4F32),
      GpuField(name: "tropism",   kind: gtArray, offset: 32, size: 32, count: 2, elemKind: gtVec4F32),
    ],
    totalSize: 64
  )

  # BloomParams struct (16 bytes, generated into web/shaders/modules/bloom_params.wgsl)
  # The separable-blur pass uniform. `direction` selects the blur axis — (1,0)
  # for the horizontal pass, (0,1) for the vertical — and `texelSize` is one
  # over the half-resolution bloom target dimensions, so `direction * texelSize`
  # is the per-tap UV step. Both are constant per frame (they change only on
  # resize); the Gaussian weights themselves are compile-time placeholders from
  # bloom_core.nim, not uniform data.
  BloomParamsLayout* = GpuStruct(
    name: "BloomParams",
    fields: @[
      GpuField(name: "direction", kind: gtVec2F32, offset: 0, size: 8, count: 1),
      GpuField(name: "texelSize", kind: gtVec2F32, offset: 8, size: 8, count: 1),
    ],
    totalSize: 16
  )

  # TonemapParams struct (32 bytes, generated into web/shaders/modules/tonemap_params.wgsl)
  # The bloom composite/tonemap pass uniform: HDR exposure, the bloom mix gain,
  # the three colour-grade knobs (saturation, contrast, signed temperature), and
  # the S10 field-visualization pair — colormapIndex (which procedural ramp maps
  # the RD field) and fieldOpacity (how much the field contributes). The RD
  # field-composite (bloom-off) floor reads the same two slots from the same
  # buffer. Written every frame from CONFIG.
  #
  # Nothing about the VIEW appears here. Both composite paths map screen UV
  # into field space, which needs the camera and the world extent, and both
  # bind the shared Camera uniform that carries the pair — render, glow, fade,
  # tonemap and field-composite must agree about the view within a frame, and
  # five copies is five chances to disagree.
  TonemapParamsLayout* = GpuStruct(
    name: "TonemapParams",
    fields: @[
      GpuField(name: "exposure",       kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "bloomIntensity", kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "saturation",     kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "contrast",       kind: gtF32, offset: 12, size: 4, count: 1),
      GpuField(name: "temperature",    kind: gtF32, offset: 16, size: 4, count: 1),
      GpuField(name: "colormapIndex",  kind: gtF32, offset: 20, size: 4, count: 1),
      GpuField(name: "fieldOpacity",   kind: gtF32, offset: 24, size: 4, count: 1),
      GpuField(name: "pad2",           kind: gtF32, offset: 28, size: 4, count: 1),
    ],
    totalSize: 32
  )

# =============================================================================
# FIELD LOOKUP
# =============================================================================

func fieldByName*(gpuStruct: GpuStruct, name: string): GpuField =
  ## Find a field by name, raises if not found
  for field in gpuStruct.fields:
    if field.name == name:
      return field
  raise newException(KeyError, "Field not found: " & name & " in struct " & gpuStruct.name)

func fieldOffset*(gpuStruct: GpuStruct, name: string): int =
  fieldByName(gpuStruct, name).offset

func fieldIndex*(gpuStruct: GpuStruct, name: string): int =
  ## Get array index for a field (offset / 4 for f32/u32 fields)
  let field = fieldByName(gpuStruct, name)
  if field.kind in {gtF32, gtU32, gtI32}:
    field.offset div 4
  else:
    raise newException(ValueError, "fieldIndex only valid for scalar types")

# =============================================================================
# WGSL STRUCT CODEGEN
# =============================================================================
# toWgslStruct renders a GpuStruct as a WGSL struct declaration, enforcing the
# WGSL uniform address-space layout rules. tools/wgsl_bundle.nim writes the
# result to web/shaders/modules/sim_params.wgsl, so the Nim byte-writer (the
# SIM_* indices below) and the WGSL struct are generated from one table and
# cannot silently disagree. New uniform members are added by extending the
# layout table alone.

func roundUpTo(value, multiple: int): int {.inline.} =
  ## Smallest multiple of `multiple` that is >= value.
  ((value + multiple - 1) div multiple) * multiple

func wgslTypeName(gpuType: GpuType): string =
  ## WGSL spelling for a scalar or vector type. gtArray has no standalone
  ## spelling; toWgslType renders it from its element type.
  case gpuType
  of gtF32: "f32"
  of gtU32: "u32"
  of gtI32: "i32"
  of gtVec2F32: "vec2<f32>"
  of gtVec3F32: "vec3<f32>"
  of gtVec4F32: "vec4<f32>"
  of gtVec2U32: "vec2<u32>"
  of gtVec4U32: "vec4<u32>"
  of gtArray: ""

func fieldAlignment(field: GpuField): int =
  ## WGSL alignment of a field: an array (and its vec4 elements) aligns to 16.
  if field.kind == gtArray: gpuTypeAlignment(gtArray)
  else: gpuTypeAlignment(field.kind)

func toWgslType*(field: GpuField): string =
  ## WGSL type expression for a field: "f32" or "array<vec4<f32>, 9>".
  if field.kind == gtArray:
    "array<" & wgslTypeName(field.elemKind) & ", " & $field.count & ">"
  else:
    wgslTypeName(field.kind)

func wgslComputedOffsets*(layout: GpuStruct): seq[int] =
  ## The byte offset WGSL's layout algorithm assigns each member — each placed at
  ## the next position satisfying its alignment. Equality with the declared
  ## offsets proves the shader compiler and the Nim writer agree, the invariant
  ## that keeps SimParams/FieldParams growth from corrupting physics.
  var cursor = 0
  for field in layout.fields:
    cursor = roundUpTo(cursor, fieldAlignment(field))
    result.add cursor
    cursor += field.size

func wgslUniformSize*(layout: GpuStruct): int =
  ## Bytes a uniform buffer must allocate: struct size rounded up to 16.
  ## SimParams is 248 bytes written, 256 allocated.
  roundUpTo(layout.totalSize, 16)

func toWgslStruct*(layout: GpuStruct): string =
  ## Render `layout` as a WGSL struct declaration. Raises (failing the build) if a
  ## field violates WGSL uniform layout: a misaligned offset, an offset the WGSL
  ## compiler would not itself choose, or an array whose size <> elemSize*count.
  let computedOffsets = wgslComputedOffsets(layout)
  for fieldIndex, field in layout.fields:
    doAssert field.offset mod fieldAlignment(field) == 0,
      layout.name & "." & field.name & " offset " & $field.offset &
      " is not aligned to " & $fieldAlignment(field)
    doAssert field.offset == computedOffsets[fieldIndex],
      layout.name & "." & field.name & " declared offset " & $field.offset &
      " != WGSL-computed offset " & $computedOffsets[fieldIndex] &
      " (layout would corrupt)"
    if field.kind == gtArray:
      doAssert field.size == gpuTypeSize(field.elemKind) * field.count,
        layout.name & "." & field.name & " array size " & $field.size &
        " != elemSize*count"
  result = "struct " & layout.name & " {\n"
  for field in layout.fields:
    result &= "  " & field.name & ": " & toWgslType(field) & ",\n"
  result &= "}\n"

# =============================================================================
# FIELD-INDEX CODEGEN (macro)
# =============================================================================

func toUpperSnake*(name: string): string =
  ## camelCase or _leading-underscore name -> UPPER_SNAKE. "gridCellsX" ->
  ## "GRID_CELLS_X", "_pad2" -> "PAD2". Names the generated index constants.
  var charIndex = 0
  while charIndex < name.len and name[charIndex] == '_':  # drop leading underscores
    inc charIndex
  var prevWasLower = false
  while charIndex < name.len:
    let currentChar = name[charIndex]
    if currentChar in {'A'..'Z'}:
      if prevWasLower: result.add '_'
      result.add currentChar
      prevWasLower = false
    elif currentChar in {'a'..'z'}:
      result.add char(ord(currentChar) - 32)
      prevWasLower = true
    else:
      result.add currentChar
      prevWasLower = false
    inc charIndex

proc newExportedIntConst(constName: string, constValue: int): NimNode =
  ## Build the AST for `constName* = constValue` inside a const section.
  nnkConstDef.newTree(
    nnkPostfix.newTree(ident"*", ident(constName)),
    newEmptyNode(),
    newLit(constValue),
  )

macro genFieldIndices*(layout: static GpuStruct, prefix: static string): untyped =
  ## Emit an exported const per field of `layout`, named `<prefix>_<FIELD>` and
  ## valued at the field's f32-array index (byte offset div 4). An array field
  ## emits `<prefix>_<FIELD>_START` and `_END`; a vec2 field emits the two
  ## write slots `<prefix>_<FIELD>_X` and `_Y`; a trailing
  ## `<prefix>_PARAMS_F32_COUNT` gives the total f32 count. A field whose
  ## upper-snake name already begins with the prefix keeps a single prefix
  ## ("fadeAmount" under "FADE" -> FADE_AMOUNT, not FADE_FADE_AMOUNT).
  ## Generating them rather than hand-writing the SIM_*/RENDER_*/FADE_* blocks
  ## keeps the write indices from drifting from the layout tables.
  result = nnkConstSection.newTree()
  for field in layout.fields:
    let upperName = toUpperSnake(field.name)
    let constBase =
      if upperName.startsWith(prefix & "_"): upperName
      else: prefix & "_" & upperName
    case field.kind
    of gtArray:
      result.add newExportedIntConst(constBase & "_START", field.offset div 4)
      result.add newExportedIntConst(constBase & "_END", (field.offset + field.size) div 4 - 1)
    of gtVec2F32, gtVec2U32:
      result.add newExportedIntConst(constBase & "_X", field.offset div 4)
      result.add newExportedIntConst(constBase & "_Y", field.offset div 4 + 1)
    else:
      result.add newExportedIntConst(constBase, field.offset div 4)
  result.add newExportedIntConst(prefix & "_PARAMS_F32_COUNT", layout.totalSize div 4)

# =============================================================================
# COMPILE-TIME VALIDATION
# =============================================================================

static:
  # Validate Particle struct matches memory_layout.nim constants
  assert ParticleLayout.totalSize == 32, "Particle must be 32 bytes"
  assert ParticleLayout.fieldOffset("pos") == 0
  assert ParticleLayout.fieldOffset("vel") == 8
  assert ParticleLayout.fieldOffset("species") == 16
  assert ParticleLayout.fieldOffset("density") == memory_layout.PARTICLE_DENSITY_OFFSET
  assert ParticleLayout.fieldOffset("sphDensity") ==
    memory_layout.PARTICLE_SPH_DENSITY_OFFSET
  assert ParticleLayout.fieldOffset("crowdDensity") ==
    memory_layout.PARTICLE_CROWD_DENSITY_OFFSET

  # Validate GridParams struct
  assert GridParamsLayout.totalSize == 32, "GridParams must be 32 bytes"

  # Validate ScanParams struct
  assert ScanParamsLayout.totalSize == 16, "ScanParams must be 16 bytes"

  # Validate SimParams critical fields
  assert SimParamsLayout.fieldOffset("dt") == 0
  assert SimParamsLayout.fieldOffset("attractionMatrix") == 64
  assert SimParamsLayout.fieldOffset("repulsionEnd") == 208

  # WGSL's own layout algorithm must assign every SimParams member the exact
  # offset the Nim writer targets, or a uniform write lands on the wrong field.
  block:
    let computedOffsets = SimParamsLayout.wgslComputedOffsets
    for fieldIndex in 0 ..< SimParamsLayout.fields.len:
      assert computedOffsets[fieldIndex] == SimParamsLayout.fields[fieldIndex].offset,
        "SimParams." & SimParamsLayout.fields[fieldIndex].name & " offset drift"
    assert SimParamsLayout.totalSize == 256, "SimParams writes 256 bytes"
    assert SimParamsLayout.wgslUniformSize == 256, "SimParams allocates 256 bytes"

# =============================================================================
# SIMPARAMS FIELD INDICES (for type-safe buffer writes)
# =============================================================================
# Generated from SimParamsLayout by genFieldIndices — see the macro above. This
# emits SIM_DT=0, SIM_WORLD_WIDTH=1, ... SIM_ATTRACTION_MATRIX_START=16 /
# _END=51, ... SIM_PAD2=57, SIM_CROWDING_STRENGTH=62,
# SIM_SPH_RADIUS_FRACTION=63, and SIM_PARAMS_F32_COUNT=64, so
# webgpu_compute.nim hand-writes no magic number.

genFieldIndices(SimParamsLayout, "SIM")

# =============================================================================
# GRIDPARAMS FIELD INDICES
# =============================================================================

const
  GRID_W* = 0
  GRID_H* = 1
  GRID_WORLD_WIDTH* = 2
  GRID_WORLD_HEIGHT* = 3
  GRID_PARTICLE_COUNT* = 4
  GRID_PAD0* = 5
  GRID_PAD1* = 6
  GRID_PAD2* = 7
  GRID_PARAMS_U32_COUNT* = 8

# =============================================================================
# SCANPARAMS FIELD INDICES
# =============================================================================

const
  SCAN_NUM_CELLS* = 0
  SCAN_NUM_BLOCKS* = 1
  SCAN_PAD1* = 2
  SCAN_PAD2* = 3
  SCAN_PARAMS_U32_COUNT* = 4

# =============================================================================
# INTEGRATIONPARAMS FIELD INDICES (webgpu_compute.nim)
# =============================================================================

const
  INTEG_WORLD_WIDTH* = 0
  INTEG_WORLD_HEIGHT* = 1
  INTEG_FRICTION* = 2
  INTEG_MAX_VELOCITY* = 3
  INTEG_PARTICLE_COUNT* = 4  # u32 via aliased buffer
  INTEG_PAD1* = 5
  INTEG_PAD2* = 6
  INTEG_PAD3* = 7
  INTEG_PARAMS_F32_COUNT* = 8

# =============================================================================
# RENDERPARAMS / FADEPARAMS FIELD INDICES (webgpu_render.nim)
# =============================================================================
# Generated from the layout tables by genFieldIndices, like SIM_* above.
# RENDER_RESOLUTION_X=0 ... RENDER_GLOW_DENSITY_FLOOR=12, then
# RENDER_FIELD_OPACITY=13 and RENDER_COLORMAP_INDEX=14 (the field reaching the
# vertex stage) and one pad at 15, RENDER_PARAMS_F32_COUNT=16 (totalSize 64);
# FADE_AMOUNT=0, FADE_FIELD_DRIFT_SCALE=1 ... FADE_PAD2=3,
# FADE_PARAMS_F32_COUNT=4; CAMERA_CENTER_X=0 ... CAMERA_WORLD_HEIGHT=4, three
# pads, CAMERA_PARAMS_F32_COUNT=8.

genFieldIndices(RenderParamsLayout, "RENDER")
genFieldIndices(FadeParamsLayout, "FADE")
genFieldIndices(CameraLayout, "CAMERA")
genFieldIndices(OverlayParamsLayout, "OVERLAY")

static:
  # The generated WGSL and the Nim writer must agree on every offset, exactly as
  # asserted for SimParams above. One sweep over every layout that shares the
  # check: a layout added to this list is checked, and the per-struct size
  # assertions stay beside the struct they size.
  for layout in [RenderParamsLayout, FadeParamsLayout, CameraLayout,
      OverlayParamsLayout, FieldParamsLayout, ReactionParamsLayout,
      SpeciesChemistryLayout]:
    let computedOffsets = layout.wgslComputedOffsets
    for fieldIndex in 0 ..< layout.fields.len:
      assert computedOffsets[fieldIndex] == layout.fields[fieldIndex].offset,
        layout.name & "." & layout.fields[fieldIndex].name & " offset drift"
  assert RenderParamsLayout.wgslUniformSize == 64, "RenderParams allocates 64 bytes"
  assert FadeParamsLayout.totalSize == 16, "FadeParams must be 16 bytes"
  assert FadeParamsLayout.wgslUniformSize == 16, "FadeParams allocates 16 bytes"
  assert CameraLayout.totalSize == 32, "Camera must be 32 bytes"
  assert CameraLayout.wgslUniformSize == 32, "Camera allocates 32 bytes"
  assert OverlayParamsLayout.totalSize == 16, "OverlayParams must be 16 bytes"
  assert OverlayParamsLayout.wgslUniformSize == 16,
    "OverlayParams allocates 16 bytes"

# =============================================================================
# FIELDPARAMS FIELD INDICES (the chemical field, webgpu_compute.nim)
# =============================================================================
# Generated from FieldParamsLayout by genFieldIndices, like SIM_*/RENDER_*/
# FADE_* above: FIELD_FEED=0, FIELD_KILL=1, ... FIELD_SEED_NONCE=7,
# FIELD_PARAMS_F32_COUNT=8.

genFieldIndices(FieldParamsLayout, "FIELD")

static:
  # Offset agreement is covered by the shared sweep above; the sizes stay
  # beside the struct they size.
  assert FieldParamsLayout.totalSize == 32, "FieldParams must be 32 bytes"
  assert FieldParamsLayout.wgslUniformSize == 32, "FieldParams allocates 32 bytes"

# =============================================================================
# REACTIONPARAMS FIELD INDICES (which reaction the field runs)
# =============================================================================
# REACTION_KIND=0 (the macro collapses the duplicated prefix),
# REACTION_PAD0=1, ... REACTION_PAD2=3, REACTION_PARAMS_F32_COUNT=4.

genFieldIndices(ReactionParamsLayout, "REACTION")

static:
  # Offset agreement rides the layout sweep above; the size this struct must
  # hold is its own.
  assert ReactionParamsLayout.totalSize == 16, "ReactionParams must be 16 bytes"
  assert ReactionParamsLayout.wgslUniformSize == 16, "ReactionParams allocates 16 bytes"

# =============================================================================
# SPECIESCHEMISTRY FIELD INDICES (per-species field coupling)
# =============================================================================
# CHEM_SECRETION_START=0 / _END=7, CHEM_TROPISM_START=8 / _END=15,
# CHEM_PARAMS_F32_COUNT=16. Both arrays are contiguous f32 runs, so species i
# writes at CHEM_SECRETION_START + i and CHEM_TROPISM_START + i — the same
# arithmetic the shader's `[i / 4u][i % 4u]` performs on the vec4 side.

genFieldIndices(SpeciesChemistryLayout, "CHEM")

const CHEMISTRY_SPECIES_SLOTS* = 8
  ## Species slots each chemistry channel holds: two vec4s of four. The
  ## assertion below ties this to the packing rather than leaving it a literal.

static:
  # Offset agreement rides the layout sweep above; the size, the slot count, and
  # what must fit in it are this struct's own.
  assert SpeciesChemistryLayout.totalSize == 64, "SpeciesChemistry must be 64 bytes"
  assert SpeciesChemistryLayout.wgslUniformSize == 64, "SpeciesChemistry allocates 64 bytes"
  # Both channels hold the same number of slots, and MAX_SPECIES must fit in
  # them. Raising MAX_SPECIES past 8 means widening the arrays (and the struct
  # past 64 bytes), not silently dropping the species that no longer fit.
  assert SpeciesChemistryLayout.fieldByName("secretion").count * 4 ==
    CHEMISTRY_SPECIES_SLOTS
  assert SpeciesChemistryLayout.fieldByName("tropism").count * 4 ==
    CHEMISTRY_SPECIES_SLOTS
  assert MAX_SPECIES <= CHEMISTRY_SPECIES_SLOTS,
    "SpeciesChemistry holds 8 species slots; MAX_SPECIES exceeds them"

# =============================================================================
# BLOOMPARAMS / TONEMAPPARAMS FIELD INDICES (HDR bloom, webgpu_render.nim)
# =============================================================================
# Generated from the layout tables by genFieldIndices, like SIM_*/RENDER_*/
# FADE_*/FIELD_* above. BLOOM_DIRECTION_X=0 ... BLOOM_TEXEL_SIZE_Y=3,
# BLOOM_PARAMS_F32_COUNT=4; TONEMAP_EXPOSURE=0 ... TONEMAP_PAD2=7,
# TONEMAP_PARAMS_F32_COUNT=8.

genFieldIndices(BloomParamsLayout, "BLOOM")
genFieldIndices(TonemapParamsLayout, "TONEMAP")

static:
  # Same offset-agreement invariant as the render structs above: a drift here
  # would corrupt every bloom or tonemap uniform write.
  for layout in [BloomParamsLayout, TonemapParamsLayout]:
    let computedOffsets = layout.wgslComputedOffsets
    for fieldIndex in 0 ..< layout.fields.len:
      assert computedOffsets[fieldIndex] == layout.fields[fieldIndex].offset,
        layout.name & "." & layout.fields[fieldIndex].name & " offset drift"
  assert BloomParamsLayout.wgslUniformSize == 16, "BloomParams allocates 16 bytes"
  assert TonemapParamsLayout.totalSize == 32, "TonemapParams must be 32 bytes"
  assert TonemapParamsLayout.wgslUniformSize == 32, "TonemapParams allocates 32 bytes"
