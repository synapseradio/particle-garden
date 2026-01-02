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

# No imports needed - pure compile-time definitions

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

  # SimParams struct (232 bytes, matches forces.wgsl)
  # Layout: 16 scalar fields (64 bytes) + 9 vec4 matrix (144 bytes) + 6 fields (24 bytes)
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
      GpuField(name: "attractionMatrix", kind: gtArray, offset: 64, size: 144, count: 9),
      # Force model parameters (208-232)
      GpuField(name: "repulsionEnd",    kind: gtF32, offset: 208, size: 4, count: 1),
      GpuField(name: "attractionPeak",  kind: gtF32, offset: 212, size: 4, count: 1),
      GpuField(name: "forceModel",      kind: gtU32, offset: 216, size: 4, count: 1),
      GpuField(name: "expAlpha",        kind: gtF32, offset: 220, size: 4, count: 1),
      GpuField(name: "expBeta",         kind: gtF32, offset: 224, size: 4, count: 1),
      GpuField(name: "_pad2",           kind: gtF32, offset: 228, size: 4, count: 1),
    ],
    totalSize: 232
  )

# =============================================================================
# FIELD LOOKUP
# =============================================================================

func fieldByName*(s: GpuStruct, name: string): GpuField =
  ## Find a field by name, raises if not found
  for f in s.fields:
    if f.name == name:
      return f
  raise newException(KeyError, "Field not found: " & name & " in struct " & s.name)

func fieldOffset*(s: GpuStruct, name: string): int =
  ## Get byte offset for a field by name
  fieldByName(s, name).offset

func fieldIndex*(s: GpuStruct, name: string): int =
  ## Get array index for a field (offset / 4 for f32/u32 fields)
  let f = fieldByName(s, name)
  if f.kind in {gtF32, gtU32, gtI32}:
    f.offset div 4
  else:
    raise newException(ValueError, "fieldIndex only valid for scalar types")

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

# =============================================================================
# SIMPARAMS FIELD INDICES (for type-safe buffer writes)
# =============================================================================
# These replace magic numbers like simParamsData[52] with named constants.

const
  # Core fields (indices 0-15)
  SIM_DT* = 0
  SIM_WORLD_WIDTH* = 1
  SIM_WORLD_HEIGHT* = 2
  SIM_INTERACTION_RADIUS* = 3
  SIM_FORCE_MULTIPLIER* = 4
  SIM_GRID_CELLS_X* = 5
  SIM_GRID_CELLS_Y* = 6
  SIM_MOUSE_X* = 7
  SIM_MOUSE_Y* = 8
  SIM_MOUSE_LEFT_DOWN* = 9
  SIM_MOUSE_RIGHT_DOWN* = 10
  SIM_PARTICLE_COUNT* = 11
  SIM_BLAST_X* = 12
  SIM_BLAST_Y* = 13
  SIM_BLAST_STRENGTH* = 14
  SIM_PAD* = 15

  # Attraction matrix (indices 16-51, 36 floats)
  SIM_MATRIX_START* = 16
  SIM_MATRIX_END* = 51

  # Force model parameters (indices 52-57)
  SIM_REPULSION_END* = 52
  SIM_ATTRACTION_PEAK* = 53
  SIM_FORCE_MODEL* = 54
  SIM_EXP_ALPHA* = 55
  SIM_EXP_BETA* = 56
  SIM_PAD2* = 57

  # Total size in f32 units
  SIM_PARAMS_F32_COUNT* = 58

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
# RENDERPARAMS FIELD INDICES (webgpu_render.nim)
# =============================================================================

const
  RENDER_RESOLUTION_X* = 0
  RENDER_RESOLUTION_Y* = 1
  RENDER_WORLD_SIZE_X* = 2
  RENDER_WORLD_SIZE_Y* = 3
  RENDER_BASE_SIZE* = 4
  RENDER_GLOW_INTENSITY* = 5
  RENDER_VELOCITY_GLOW_SCALE* = 6
  RENDER_MAX_VELOCITY* = 7
  RENDER_PARAMS_F32_COUNT* = 8

# =============================================================================
# FADEPARAMS FIELD INDICES (webgpu_render.nim)
# =============================================================================

const
  FADE_AMOUNT* = 0
  FADE_PAD1* = 1
  FADE_PAD2* = 2
  FADE_PAD3* = 3
  FADE_PARAMS_F32_COUNT* = 4
