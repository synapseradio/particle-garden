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
