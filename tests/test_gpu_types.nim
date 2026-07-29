# ==============================================================================
# PARTICLE GARDEN - GPU TYPE LAYOUT TESTS
# ==============================================================================
#
# Behavioral tests for the pure layout helpers in gpu_types.nim. The compile-time
# static asserts in that module pin a handful of specific offsets; these tests
# exercise the helper FUNCTIONS that buffer-write code calls at runtime and the
# structural relationships (non-overlap, contiguity) the GPU depends on.
#
# Run with: just test
#
# ==============================================================================

import std/unittest
import std/strutils
import ../src/gpu_types
import ../src/memory_layout  # MAX_SPECIES, the ceiling the chemistry packing holds

const GPU_TYPES_TESTS_LOADED* = true

suite "GPU Type Sizes":
  test "gpuTypeSize returns the WGSL byte size for each scalar and vector type":
    # CONTRACT: these sizes mirror the WGSL type system the shaders rely on.
    check gpuTypeSize(gtF32) == 4
    check gpuTypeSize(gtU32) == 4
    check gpuTypeSize(gtI32) == 4
    check gpuTypeSize(gtVec2F32) == 8
    check gpuTypeSize(gtVec3F32) == 12
    check gpuTypeSize(gtVec4F32) == 16
    check gpuTypeSize(gtVec2U32) == 8
    check gpuTypeSize(gtVec4U32) == 16

  test "gpuTypeAlignment rounds vec3 and vec4 up to the 16-byte WGSL boundary":
    check gpuTypeAlignment(gtF32) == 4
    check gpuTypeAlignment(gtVec2F32) == 8
    check gpuTypeAlignment(gtVec3F32) == 16
    check gpuTypeAlignment(gtVec4F32) == 16
    check gpuTypeAlignment(gtArray) == 16


suite "GPU Struct Layouts Are Non-Overlapping And Contiguous":
  # A mis-edited offset in any layout silently corrupts every GPU buffer write.
  # These relationships fail for a real reason rather than pinning a literal.
  const allStructs = [ParticleLayout, GridParamsLayout, ScanParamsLayout, SimParamsLayout]

  test "every struct has monotonic, non-overlapping field offsets":
    for struct in allStructs:
      for idx in 1 ..< struct.fields.len:
        check struct.fields[idx].offset >= struct.fields[idx - 1].offset + struct.fields[idx - 1].size

  test "every struct totalSize covers its final field":
    for struct in allStructs:
      let last = struct.fields[^1]
      check struct.totalSize >= last.offset + last.size


suite "Every Generated Layout Agrees With WGSL's Offset Algorithm":
  # ONE relation over every layout the tables generate: the offset WGSL's own
  # layout algorithm assigns must equal the offset the table declares, or a
  # uniform write lands on the wrong field and corrupts whatever it hits in
  # silence. gpu_types.nim asserts the same thing statically for the render-path
  # structs; this sweeps all of them at once, so a new layout joins the relation
  # by being added to this list rather than by someone remembering to write the
  # loop again.
  const generatedLayouts = [
    SimParamsLayout, RenderParamsLayout, FieldParamsLayout,
    ReactionParamsLayout, SpeciesChemistryLayout, BloomParamsLayout,
    TonemapParamsLayout]

  test "every layout's declared offsets are the ones WGSL computes":
    for layout in generatedLayouts:
      let computedOffsets = wgslComputedOffsets(layout)
      for fieldIndex in 0 ..< layout.fields.len:
        if computedOffsets[fieldIndex] != layout.fields[fieldIndex].offset:
          checkpoint(layout.name & "." & layout.fields[fieldIndex].name &
            " offset drift")
        check computedOffsets[fieldIndex] == layout.fields[fieldIndex].offset


suite "GPU Field Accessors":
  test "fieldOffset returns the declared byte offset for a named field":
    check ParticleLayout.fieldOffset("species") == 16
    check SimParamsLayout.fieldOffset("attractionMatrix") == 64

  test "fieldByName raises KeyError for a field that does not exist":
    expect KeyError:
      discard ParticleLayout.fieldByName("nonexistent")

  test "fieldIndex equals byte offset divided by 4 for scalar fields":
    check ParticleLayout.fieldIndex("species") == 4    # offset 16 / 4
    check SimParamsLayout.fieldIndex("repulsionEnd") == 52  # offset 208 / 4

  test "fieldIndex raises ValueError for vector and array fields":
    expect ValueError:
      discard ParticleLayout.fieldIndex("pos")            # vec2<f32>
    expect ValueError:
      discard SimParamsLayout.fieldIndex("attractionMatrix")  # array


suite "WGSL Struct Codegen Matches The Layout Table":
  # toWgslStruct is the single source the SimParams WGSL module is generated
  # from, and the SIM_* indices below drive the Nim uniform-writer. These lock
  # both to the same byte layout: a drift between them corrupts physics silently,
  # so it must fail here (and the mirrored static asserts fail the build).

  test "wgslComputedOffsets accounts for every declared SimParams field":
    # The offsets themselves are swept for every layout above; what this adds is
    # that the algorithm returns one per declared field — a short result would
    # leave the tail of the struct unchecked there.
    check wgslComputedOffsets(SimParamsLayout).len == SimParamsLayout.fields.len

  test "SimParams is 248 bytes written and 256 bytes allocated (16-byte round-up)":
    check SimParamsLayout.totalSize == 248
    check wgslUniformSize(SimParamsLayout) == 256

  test "toWgslStruct renders the SimParams fields with WGSL types in order":
    let generated = toWgslStruct(SimParamsLayout)
    check generated.startsWith("struct SimParams {")
    check "dt: f32," in generated
    check "gridCellsX: u32," in generated
    check "attractionMatrix: array<vec4<f32>, 9>," in generated
    check "forceModel: u32," in generated
    check "_pad2: f32," in generated
    check generated.strip.endsWith("}")

  test "toWgslType spells arrays and scalars the way WGSL expects":
    check toWgslType(SimParamsLayout.fieldByName("dt")) == "f32"
    check toWgslType(SimParamsLayout.fieldByName("gridCellsX")) == "u32"
    check toWgslType(SimParamsLayout.fieldByName("attractionMatrix")) ==
      "array<vec4<f32>, 9>"


suite "Generated SIM_ Indices Match The SimParams Byte Layout":
  # genFieldIndices emits these from SimParamsLayout. webgpu_compute.nim writes
  # simParamsData[SIM_*]; a wrong index writes the wrong float into the uniform.

  test "each SIM_ index equals its field's byte offset divided by four":
    check SIM_DT == SimParamsLayout.fieldOffset("dt") div 4
    check SIM_FORCE_MULTIPLIER == SimParamsLayout.fieldOffset("forceMultiplier") div 4
    check SIM_PARTICLE_COUNT == SimParamsLayout.fieldOffset("particleCount") div 4
    check SIM_ATTRACTION_MATRIX_START == SimParamsLayout.fieldOffset("attractionMatrix") div 4
    check SIM_REPULSION_END == SimParamsLayout.fieldOffset("repulsionEnd") div 4
    check SIM_EXP_BETA == SimParamsLayout.fieldOffset("expBeta") div 4

  test "the generated indices sit where the layout puts them":
    check SIM_DT == 0
    check SIM_FLUID_STRENGTH == 15
    check SIM_ATTRACTION_MATRIX_START == 16
    check SIM_ATTRACTION_MATRIX_END == 51
    check SIM_REPULSION_END == 52
    check SIM_PAD2 == 57
    check SIM_PARAMS_F32_COUNT == 62

  test "the attraction matrix spans exactly its 36 float slots":
    check SIM_ATTRACTION_MATRIX_END - SIM_ATTRACTION_MATRIX_START + 1 == 36

  test "SIM_PARAMS_F32_COUNT covers the whole 248-byte struct":
    check SIM_PARAMS_F32_COUNT == SimParamsLayout.totalSize div 4


suite "Generated SIM_ SPH Indices Follow The Force-Model Block":
  # S7 appends four SPH f32 fields after the force-model block. Their write
  # indices must equal their byte offset / 4, and sit immediately after
  # SIM_PAD2, or webgpu_compute's SPH uniform writes land on the wrong slot.

  test "each SPH index equals its field's byte offset divided by four":
    check SIM_SPH_REST_DENSITY == SimParamsLayout.fieldOffset("sphRestDensity") div 4
    check SIM_SPH_STIFFNESS == SimParamsLayout.fieldOffset("sphStiffness") div 4
    check SIM_SPH_GAMMA == SimParamsLayout.fieldOffset("sphGamma") div 4
    check SIM_SPH_VISCOSITY == SimParamsLayout.fieldOffset("sphViscosity") div 4

  test "the four SPH slots are contiguous and follow SIM_PAD2":
    check SIM_SPH_REST_DENSITY == SIM_PAD2 + 1
    check SIM_SPH_STIFFNESS == SIM_SPH_REST_DENSITY + 1
    check SIM_SPH_GAMMA == SIM_SPH_STIFFNESS + 1
    check SIM_SPH_VISCOSITY == SIM_SPH_GAMMA + 1
    # The last SPH slot is the final f32 in the struct.
    check SIM_SPH_VISCOSITY == SIM_PARAMS_F32_COUNT - 1


suite "Generated Render Struct Layouts":
  # S2: RenderParams and FadeParams join SimParams as layout-table-generated
  # structs. The generated indices must hold the exact values below, or every
  # uniform write in webgpu_render.nim shifts.

  test "RenderParamsLayout is 16 floats, 64 bytes written and allocated":
    check RenderParamsLayout.totalSize == 64
    check wgslUniformSize(RenderParamsLayout) == 64

  test "vec2 fields generate _X and _Y indices at offset/4 and offset/4 + 1":
    check RENDER_RESOLUTION_X == 0
    check RENDER_RESOLUTION_Y == 1
    check RENDER_WORLD_SIZE_X == 2
    check RENDER_WORLD_SIZE_Y == 3

  test "the generated RENDER_ indices reproduce the hand-written block":
    check RENDER_BASE_SIZE == 4
    check RENDER_GLOW_INTENSITY == 5
    check RENDER_VELOCITY_GLOW_SCALE == 6
    check RENDER_MAX_VELOCITY == 7
    check RENDER_TRAIL_LENGTH_SCALE == 8

  test "FadeParamsLayout is 8 floats and generates FADE_ indices":
    # 32 bytes because it carries the previous frame's camera, which the trail
    # reprojection needs — see the layout's own comment for why a pure UV
    # translation is not correct under zoom.
    check FadeParamsLayout.totalSize == 32
    check wgslUniformSize(FadeParamsLayout) == 32
    check FADE_AMOUNT == 0
    check FADE_PARAMS_F32_COUNT == 8

  test "a field name that begins with the prefix does not double the prefix":
    # fadeAmount under prefix FADE must emit FADE_AMOUNT, not FADE_FADE_AMOUNT.
    check FadeParamsLayout.fields[0].name == "fadeAmount"

  test "toWgslStruct renders both layouts with WGSL vector types":
    let renderStruct = toWgslStruct(RenderParamsLayout)
    check renderStruct.startsWith("struct RenderParams {")
    check "resolution: vec2<f32>," in renderStruct
    check "glowWarmth: f32," in renderStruct
    let fadeStruct = toWgslStruct(FadeParamsLayout)
    check fadeStruct.startsWith("struct FadeParams {")
    check "fadeAmount: f32," in fadeStruct


suite "RenderParams Glow Knob Indices":
  # S1 promotes three RenderParams pad slots into glow knobs; S10 grows the
  # struct with a glowDensityFloor and pads it back to 64 bytes. The knob
  # indices hold the exact positions below.

  test "the three former pad slots are the glow knob indices":
    check RENDER_GLOW_RADIUS_SCALE == 9
    check RENDER_GLOW_FALLOFF == 10
    check RENDER_GLOW_WARMTH == 11

  test "the S10 glowDensityFloor takes the next slot after the glow knobs":
    check RENDER_GLOW_DENSITY_FLOOR == 12

  test "RenderParams is 16 floats (64 bytes) after the S10 growth":
    check RENDER_PARAMS_F32_COUNT == 16


suite "Generated FieldParams Layout (Reaction-Diffusion)":
  # S8a: FieldParams joins SimParams/RenderParams/FadeParams as a
  # layout-table-generated struct — the reaction-diffusion field's uniform.

  test "FieldParamsLayout is 8 floats, 32 bytes written and allocated":
    check FieldParamsLayout.totalSize == 32
    check wgslUniformSize(FieldParamsLayout) == 32

  test "the generated FIELD_ indices reproduce the declared field order":
    check FIELD_FEED == 0
    check FIELD_KILL == 1
    check FIELD_DIFFUSION_A == 2
    check FIELD_DIFFUSION_B == 3
    check FIELD_DELTA_T == 4
    check FIELD_DEPOSIT_AMOUNT == 5
    check FIELD_FORCE_SCALE == 6
    check FIELD_SEED_NONCE == 7
    check FIELD_PARAMS_F32_COUNT == 8

  test "a field name that already begins with the prefix does not double it":
    # fieldForceScale under prefix FIELD must emit FIELD_FORCE_SCALE, not
    # FIELD_FIELD_FORCE_SCALE — the same rule FadeParams' fadeAmount pins.
    check FieldParamsLayout.fields[6].name == "fieldForceScale"

  test "toWgslStruct renders FieldParams with WGSL scalar types":
    let generated = toWgslStruct(FieldParamsLayout)
    check generated.startsWith("struct FieldParams {")
    check "feed: f32," in generated
    check "kill: f32," in generated
    check "fieldForceScale: f32," in generated
    check generated.strip.endsWith("}")


suite "Generated ReactionParams Layout (Reaction Identity)":
  # ReactionParams carries which reaction the field runs. Gray-Scott reads
  # reactionKind; a future reaction's parameters enter this struct in the
  # same change that reads them, never as reserved members ahead of a
  # consumer (one-world 3.7).

  test "ReactionParamsLayout is 4 floats, 16 bytes written and allocated":
    check ReactionParamsLayout.totalSize == 16
    check wgslUniformSize(ReactionParamsLayout) == 16

  test "the generated REACTION_ indices reproduce the declared field order":
    # REACTION_KIND, not REACTION_REACTION_KIND: reactionKind already begins
    # with the prefix, and the macro collapses the duplicate.
    check REACTION_KIND == 0
    check REACTION_PARAMS_F32_COUNT == 4

  test "FieldParams stays closed at 32 bytes":
    # The reason ReactionParams exists as its own uniform rather than as four
    # more FieldParams members: that table is full, and its static assertions
    # reject a ninth field. If this ever passes at a larger size, the split
    # loses its justification.
    check FieldParamsLayout.totalSize == 32
    check FieldParamsLayout.fields.len == 8

  test "toWgslStruct renders ReactionParams with WGSL scalar types":
    let generated = toWgslStruct(ReactionParamsLayout)
    check generated.startsWith("struct ReactionParams {")
    check "reactionKind: f32," in generated
    check generated.strip.endsWith("}")


suite "Generated SpeciesChemistry Layout (Per-Species Field Coupling)":
  # SpeciesChemistry is what makes speciesCount change the chemical world's
  # dynamics rather than only its palette: field-deposit scales by a species'
  # secretion, field-force by its tropism. Both passes bind this one uniform,
  # so a drift here corrupts the deposit and the force together.

  test "SpeciesChemistryLayout is 16 floats, 64 bytes written and allocated":
    check SpeciesChemistryLayout.totalSize == 64
    check wgslUniformSize(SpeciesChemistryLayout) == 64

  test "the generated CHEM_ indices bracket two contiguous channels":
    # The Nim writer reaches species i at CHEM_SECRETION_START + i; the shader
    # reaches the same value at secretion[i / 4u][i % 4u]. Both are the same
    # arithmetic over one contiguous f32 run, which is what lets the two sides
    # agree without a second table.
    check CHEM_SECRETION_START == 0
    check CHEM_SECRETION_END == 7
    check CHEM_TROPISM_START == 8
    check CHEM_TROPISM_END == 15
    check CHEM_PARAMS_F32_COUNT == 16
    # The channels must not overlap, or a secretion write lands on a tropism.
    check CHEM_SECRETION_END < CHEM_TROPISM_START

  test "every species slot the ceiling allows is addressable in both channels":
    # CONTRACT: the packing holds four species per vec4, two vec4s per channel.
    # Raising MAX_SPECIES past that must widen the struct, not silently drop
    # the species that no longer fit. gpu_types asserts this statically; this
    # states the same relation where a reader can see it.
    check MAX_SPECIES <= CHEMISTRY_SPECIES_SLOTS
    check CHEM_SECRETION_START + CHEMISTRY_SPECIES_SLOTS - 1 == CHEM_SECRETION_END
    check CHEM_TROPISM_START + CHEMISTRY_SPECIES_SLOTS - 1 == CHEM_TROPISM_END

  test "toWgslStruct renders SpeciesChemistry as two vec4 arrays":
    # Two parallel arrays rather than MAX_SPECIES interleaved pairs, because
    # WGSL's uniform address space rounds an array element's stride up to 16
    # bytes: array<vec2<f32>, 6> would occupy 96 bytes, not 48.
    let generated = toWgslStruct(SpeciesChemistryLayout)
    check generated.startsWith("struct SpeciesChemistry {")
    check "secretion: array<vec4<f32>, 2>," in generated
    check "tropism: array<vec4<f32>, 2>," in generated
    check generated.strip.endsWith("}")

  test "FieldParams stays closed while chemistry grows beside it":
    # The reason SpeciesChemistry is its own uniform: FieldParamsLayout is full
    # at 32 bytes and its static assertions reject a ninth field. If this ever
    # passes at a larger size, the split loses its justification.
    check FieldParamsLayout.totalSize == 32
    check FieldParamsLayout.fields.len == 8


suite "Generated BloomParams / TonemapParams Layouts (HDR Bloom)":
  # S9: BloomParams and TonemapParams join the layout-table-generated structs.
  # The blur pass writes bloomParamsData[BLOOM_*]; the tonemap pass writes
  # tonemapParamsData[TONEMAP_*] — a wrong index writes the wrong uniform slot.

  test "BloomParamsLayout is 4 floats, 16 bytes written and allocated":
    check BloomParamsLayout.totalSize == 16
    check wgslUniformSize(BloomParamsLayout) == 16

  test "the two vec2 bloom fields generate _X and _Y write indices":
    check BLOOM_DIRECTION_X == 0
    check BLOOM_DIRECTION_Y == 1
    check BLOOM_TEXEL_SIZE_X == 2
    check BLOOM_TEXEL_SIZE_Y == 3
    check BLOOM_PARAMS_F32_COUNT == 4

  test "TonemapParamsLayout is 12 floats, 48 bytes written and allocated":
    # 48 bytes because both composite paths map screen UV into field space,
    # which needs the world extent. The camera itself is bound from the shared
    # camera buffer rather than copied in here, so that costs two live fields
    # and the padding to the next 16-byte boundary.
    check TonemapParamsLayout.totalSize == 48
    check wgslUniformSize(TonemapParamsLayout) == 48

  test "the generated TONEMAP_ indices follow the declared field order":
    check TONEMAP_EXPOSURE == 0
    check TONEMAP_BLOOM_INTENSITY == 1
    check TONEMAP_SATURATION == 2
    check TONEMAP_CONTRAST == 3
    check TONEMAP_TEMPERATURE == 4
    # S10 claims two pad slots for the field-visualization pair.
    check TONEMAP_COLORMAP_INDEX == 5
    check TONEMAP_FIELD_OPACITY == 6
    # The camera work claims two more for the world extent the UV mapping needs.
    check TONEMAP_WORLD_WIDTH == 7
    check TONEMAP_WORLD_HEIGHT == 8
    check TONEMAP_PAD2 == 9
    check TONEMAP_PARAMS_F32_COUNT == 12

  test "toWgslStruct renders both layouts with WGSL types":
    let bloomStruct = toWgslStruct(BloomParamsLayout)
    check bloomStruct.startsWith("struct BloomParams {")
    check "direction: vec2<f32>," in bloomStruct
    check "texelSize: vec2<f32>," in bloomStruct
    let tonemapStruct = toWgslStruct(TonemapParamsLayout)
    check tonemapStruct.startsWith("struct TonemapParams {")
    check "exposure: f32," in tonemapStruct
    check "temperature: f32," in tonemapStruct


suite "toUpperSnake Names Index Constants From Field Names":
  test "camelCase field names become UPPER_SNAKE":
    check toUpperSnake("dt") == "DT"
    check toUpperSnake("worldWidth") == "WORLD_WIDTH"
    check toUpperSnake("gridCellsX") == "GRID_CELLS_X"
    check toUpperSnake("attractionMatrix") == "ATTRACTION_MATRIX"

  test "leading underscores are dropped and trailing digits kept":
    check toUpperSnake("_pad") == "PAD"
    check toUpperSnake("_pad2") == "PAD2"
