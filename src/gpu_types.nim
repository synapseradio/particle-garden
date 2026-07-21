# =============================================================================
# GPU TYPES - Type-Safe GPU Buffer Layouts
# =============================================================================
# Provides:
# 1. Nim-side definitions of WGSL struct layouts
# 2. Compile-time validation of field offsets
# 3. Type-safe buffer write helpers
#
# This module is the single source of truth for GPU struct layouts in Nim.
# The WGSL modules in web/shaders/modules/ should match these definitions.
# =============================================================================

# std/macros powers genFieldIndices, which emits the SIM_*/RENDER_*/FADE_*
# buffer-write indices from the layout tables. std/strutils feeds the macro's
# name mangling. Compile-time only; the JS backend never ships either.
import std/macros
import std/strutils

# =============================================================================
# GPU TYPE SYSTEM
# =============================================================================

type
  GpuType* = enum
    ## WGSL scalar and vector types with known sizes
    gtF32         ## f32: 4 bytes
    gtU32         ## u32: 4 bytes
    gtI32         ## i32: 4 bytes
    gtVec2F32     ## vec2<f32>: 8 bytes
    gtVec3F32     ## vec3<f32>: 12 bytes (but 16-byte aligned in structs!)
    gtVec4F32     ## vec4<f32>: 16 bytes
    gtVec2U32     ## vec2<u32>: 8 bytes
    gtVec4U32     ## vec4<u32>: 16 bytes
    gtArray       ## array<T, N>: variable size

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
  ## Size in bytes for each GPU type
  case t
  of gtF32, gtU32, gtI32: 4
  of gtVec2F32, gtVec2U32: 8
  of gtVec3F32: 12  # Note: aligns to 16 in structs!
  of gtVec4F32, gtVec4U32: 16
  of gtArray: 0     # Must be calculated from element type * count

func gpuTypeAlignment*(t: GpuType): int =
  ## Alignment requirement for each GPU type
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
      GpuField(name: "_pad0",   kind: gtU32,     offset: 24, size: 4,  count: 1),
      GpuField(name: "_pad1",   kind: gtU32,     offset: 28, size: 4,  count: 1),
    ],
    totalSize: 32
  )

  # GridParams struct (32 bytes, matches web/shaders/modules/grid_params.wgsl)
  GridParamsLayout* = GpuStruct(
    name: "GridParams",
    fields: @[
      GpuField(name: "gridW",        kind: gtU32, offset: 0,  size: 4, count: 1),
      GpuField(name: "gridH",        kind: gtU32, offset: 4,  size: 4, count: 1),
      GpuField(name: "canvasWidth",  kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "canvasHeight", kind: gtF32, offset: 12, size: 4, count: 1),
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

  # SimParams struct (248 bytes, matches forces.wgsl / forces-sph.wgsl)
  # Layout: 16 scalar fields (64 bytes) + 9 vec4 matrix (144 bytes) + 6 force-model
  # fields (24 bytes) + 4 SPH fields (16 bytes)
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
      GpuField(name: "_pad",            kind: gtF32, offset: 60, size: 4, count: 1),
      # Attraction matrix: 36 floats packed as 9 vec4s (64-208)
      GpuField(name: "attractionMatrix", kind: gtArray, offset: 64, size: 144, count: 9, elemKind: gtVec4F32),
      # Force model parameters (208-232)
      GpuField(name: "repulsionEnd",    kind: gtF32, offset: 208, size: 4, count: 1),
      GpuField(name: "attractionPeak",  kind: gtF32, offset: 212, size: 4, count: 1),
      GpuField(name: "forceModel",      kind: gtU32, offset: 216, size: 4, count: 1),
      GpuField(name: "expAlpha",        kind: gtF32, offset: 220, size: 4, count: 1),
      GpuField(name: "expBeta",         kind: gtF32, offset: 224, size: 4, count: 1),
      GpuField(name: "_pad2",           kind: gtF32, offset: 228, size: 4, count: 1),
      # SPH fluid-mode parameters (232-248). forces-sph.wgsl reads these; the
      # particle-life force shader ignores them.
      GpuField(name: "sphRestDensity",  kind: gtF32, offset: 232, size: 4, count: 1),
      GpuField(name: "sphStiffness",    kind: gtF32, offset: 236, size: 4, count: 1),
      GpuField(name: "sphGamma",        kind: gtF32, offset: 240, size: 4, count: 1),
      GpuField(name: "sphViscosity",    kind: gtF32, offset: 244, size: 4, count: 1),
    ],
    totalSize: 248
  )

  # RenderParams struct (64 bytes, generated into web/shaders/modules/render_params.wgsl)
  # glowDensityFloor (S10) lifts the glow's density factor to a per-mode floor.
  # Reaction-diffusion leaves particle density stale at ~0 (no forces pass), so
  # without a floor its glow reads flat; the render loop sets this per active
  # mode (RD lifts it, the density-driven modes leave it at 0). Three trailing
  # pads round the struct to 64 bytes.
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
      GpuField(name: "_pad0",             kind: gtF32, offset: 52, size: 4, count: 1),
      GpuField(name: "_pad1",             kind: gtF32, offset: 56, size: 4, count: 1),
      GpuField(name: "_pad2",             kind: gtF32, offset: 60, size: 4, count: 1),
    ],
    totalSize: 64
  )

  # FadeParams struct (16 bytes, generated into web/shaders/modules/fade_params.wgsl)
  FadeParamsLayout* = GpuStruct(
    name: "FadeParams",
    fields: @[
      GpuField(name: "fadeAmount", kind: gtF32, offset: 0,  size: 4, count: 1),
      GpuField(name: "pad0",       kind: gtF32, offset: 4,  size: 4, count: 1),
      GpuField(name: "pad1",       kind: gtF32, offset: 8,  size: 4, count: 1),
      GpuField(name: "pad2",       kind: gtF32, offset: 12, size: 4, count: 1),
    ],
    totalSize: 16
  )

  # FieldParams struct (32 bytes, generated into web/shaders/modules/field_params.wgsl)
  # The reaction-diffusion mode's uniform: the two Gray-Scott tunables (feed,
  # kill), the diffusion rates and timestep field_core.nim's grayScottStep
  # takes as parameters, and the two live knobs (depositAmount,
  # fieldForceScale) the next stage's fieldDeposit/fieldForce shaders read.
  # depositAmount/fieldForceScale are layout slots only this stage — S8a's
  # CONFIG plumbing does not wire them to a live tunable yet.
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
      GpuField(name: "padding0",        kind: gtF32, offset: 28, size: 4, count: 1),
    ],
    totalSize: 32
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
  ## Get byte offset for a field by name
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
  ## Replaces the hand SIM_*/RENDER_*/FADE_* blocks so the write indices can
  ## never drift from the layout tables.
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
  assert ParticleLayout.fieldOffset("density") == 20

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
    assert SimParamsLayout.wgslUniformSize == 256, "SimParams allocates 256 bytes"

# =============================================================================
# SIMPARAMS FIELD INDICES (for type-safe buffer writes)
# =============================================================================
# Generated from SimParamsLayout by genFieldIndices — see the macro above. This
# emits SIM_DT=0, SIM_WORLD_WIDTH=1, ... SIM_ATTRACTION_MATRIX_START=16 /
# _END=51, ... SIM_PAD2=57, and SIM_PARAMS_F32_COUNT=58, replacing the
# magic numbers webgpu_compute.nim once hand-wrote.

genFieldIndices(SimParamsLayout, "SIM")

# =============================================================================
# GRIDPARAMS FIELD INDICES
# =============================================================================

const
  GRID_W* = 0
  GRID_H* = 1
  GRID_CANVAS_WIDTH* = 2
  GRID_CANVAS_HEIGHT* = 3
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
# RENDER_RESOLUTION_X=0 ... RENDER_GLOW_WARMTH=11, RENDER_PARAMS_F32_COUNT=12;
# FADE_AMOUNT=0 ... FADE_PAD2=3, FADE_PARAMS_F32_COUNT=4.

genFieldIndices(RenderParamsLayout, "RENDER")
genFieldIndices(FadeParamsLayout, "FADE")

static:
  # The generated WGSL and the Nim writer must agree on every offset for the
  # render-path structs, exactly as asserted for SimParams above.
  for layout in [RenderParamsLayout, FadeParamsLayout]:
    let computedOffsets = layout.wgslComputedOffsets
    for fieldIndex in 0 ..< layout.fields.len:
      assert computedOffsets[fieldIndex] == layout.fields[fieldIndex].offset,
        layout.name & "." & layout.fields[fieldIndex].name & " offset drift"
  assert RenderParamsLayout.wgslUniformSize == 64, "RenderParams allocates 64 bytes"
  assert FadeParamsLayout.wgslUniformSize == 16, "FadeParams allocates 16 bytes"

# =============================================================================
# FIELDPARAMS FIELD INDICES (reaction-diffusion mode, webgpu_compute.nim)
# =============================================================================
# Generated from FieldParamsLayout by genFieldIndices, like SIM_*/RENDER_*/
# FADE_* above: FIELD_FEED=0, FIELD_KILL=1, ... FIELD_PADDING0=7,
# FIELD_PARAMS_F32_COUNT=8.

genFieldIndices(FieldParamsLayout, "FIELD")

static:
  # Same offset-agreement invariant as SimParams/RenderParams/FadeParams: a
  # drift here would corrupt every reaction-diffusion uniform write.
  block:
    let computedOffsets = FieldParamsLayout.wgslComputedOffsets
    for fieldIndex in 0 ..< FieldParamsLayout.fields.len:
      assert computedOffsets[fieldIndex] == FieldParamsLayout.fields[fieldIndex].offset,
        "FieldParams." & FieldParamsLayout.fields[fieldIndex].name & " offset drift"
  assert FieldParamsLayout.totalSize == 32, "FieldParams must be 32 bytes"
  assert FieldParamsLayout.wgslUniformSize == 32, "FieldParams allocates 32 bytes"

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
  assert TonemapParamsLayout.wgslUniformSize == 32, "TonemapParams allocates 32 bytes"
