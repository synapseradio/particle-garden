# ==============================================================================
# PARTICLE GARDEN - GPU TYPE LAYOUT TESTS
# ==============================================================================
#
# Behavioral tests for the pure layout helpers in gpu_types.nim. The compile-time
# static asserts in that module pin a handful of specific offsets; these tests
# exercise the helper FUNCTIONS that buffer-write code calls at runtime and the
# structural relationships (non-overlap, contiguity) the GPU depends on.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import std/strutils
import ../src/gpu_types

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
    for s in allStructs:
      for i in 1 ..< s.fields.len:
        check s.fields[i].offset >= s.fields[i - 1].offset + s.fields[i - 1].size

  test "every struct totalSize covers its final field":
    for s in allStructs:
      let last = s.fields[^1]
      check s.totalSize >= last.offset + last.size


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

  test "wgslComputedOffsets equals every declared field offset for SimParams":
    # The offset WGSL's own layout algorithm assigns must match what we declared,
    # or a uniform write lands on the wrong field.
    let computedOffsets = wgslComputedOffsets(SimParamsLayout)
    check computedOffsets.len == SimParamsLayout.fields.len
    for fieldIndex in 0 ..< SimParamsLayout.fields.len:
      check computedOffsets[fieldIndex] == SimParamsLayout.fields[fieldIndex].offset

  test "SimParams is 232 bytes written and 240 bytes allocated (16-byte round-up)":
    check SimParamsLayout.totalSize == 232
    check wgslUniformSize(SimParamsLayout) == 240

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

  test "the generated indices reproduce the values the hand-written block held":
    check SIM_DT == 0
    check SIM_PAD == 15
    check SIM_ATTRACTION_MATRIX_START == 16
    check SIM_ATTRACTION_MATRIX_END == 51
    check SIM_REPULSION_END == 52
    check SIM_PAD2 == 57
    check SIM_PARAMS_F32_COUNT == 58

  test "the attraction matrix spans exactly its 36 float slots":
    check SIM_ATTRACTION_MATRIX_END - SIM_ATTRACTION_MATRIX_START + 1 == 36

  test "SIM_PARAMS_F32_COUNT covers the whole 232-byte struct":
    check SIM_PARAMS_F32_COUNT == SimParamsLayout.totalSize div 4


suite "RenderParams Glow Knob Indices":
  # S1 promotes the three RenderParams pad slots into glow knobs. The struct
  # size must not change: the pads were free f32 slots, so the knob indices
  # take their exact positions and the 48-byte buffer stays 48 bytes.

  test "the three former pad slots are the glow knob indices":
    check RENDER_GLOW_RADIUS_SCALE == 9
    check RENDER_GLOW_FALLOFF == 10
    check RENDER_GLOW_WARMTH == 11

  test "RenderParams stays 12 floats (48 bytes) after the knob promotion":
    check RENDER_PARAMS_F32_COUNT == 12


suite "toUpperSnake Names Index Constants From Field Names":
  test "camelCase field names become UPPER_SNAKE":
    check toUpperSnake("dt") == "DT"
    check toUpperSnake("worldWidth") == "WORLD_WIDTH"
    check toUpperSnake("gridCellsX") == "GRID_CELLS_X"
    check toUpperSnake("attractionMatrix") == "ATTRACTION_MATRIX"

  test "leading underscores are dropped and trailing digits kept":
    check toUpperSnake("_pad") == "PAD"
    check toUpperSnake("_pad2") == "PAD2"
