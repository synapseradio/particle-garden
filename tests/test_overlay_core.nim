import std/unittest

const OVERLAY_CORE_TESTS_LOADED* = true

import ../src/overlay_core
import ../src/ui/api/param_descriptor

suite "The Overlay Set Is Closed":
  test "exactly the two world-distance parameters draw an overlay":
    for descriptor in buildParamDescriptors():
      let kind = overlayKindFor(descriptor.id)
      case descriptor.id
      of "interactionRadius":
        check kind == okRing
      of "cameraZoom":
        check kind == okFrame
      else:
        if kind != okNone:
          checkpoint(descriptor.id & " entered the closed overlay set")
        check kind == okNone

  test "an id outside the descriptor table draws nothing":
    check overlayKindFor("") == okNone
    check overlayKindFor("rdFeed") == okNone

suite "Ring Coverage":
  const halfT = OVERLAY_THICKNESS_PX * 0.5'f32
  const aa = OVERLAY_AA_PX

  test "full on the line, zero past the antialiasing band":
    check ringCoverage(40.0, 40.0, halfT, aa) == 1.0'f32
    check ringCoverage(40.0 + halfT, 40.0, halfT, aa) == 1.0'f32
    check ringCoverage(40.0 + halfT + aa, 40.0, halfT, aa) == 0.0'f32
    check ringCoverage(0.0, 40.0, halfT, aa) == 0.0'f32

  test "symmetric about the radius and monotone across the band":
    let inside = ringCoverage(40.0 - halfT - aa * 0.5'f32, 40.0, halfT, aa)
    let outside = ringCoverage(40.0 + halfT + aa * 0.5'f32, 40.0, halfT, aa)
    check abs(inside - outside) < 1e-6
    check inside > 0.0'f32 and inside < 1.0'f32
    check ringCoverage(40.0 + halfT + aa * 0.25'f32, 40.0, halfT, aa) > inside

  test "the smoothstep midpoint sits at half coverage":
    check abs(edgeCoverage(halfT + aa * 0.5'f32, halfT, aa) - 0.5'f32) < 1e-6

suite "Frame Coverage":
  const halfT = OVERLAY_THICKNESS_PX * 0.5'f32
  const aa = OVERLAY_AA_PX

  test "seam distance is zero on the world boundary and half a world at most":
    check seamDistance(0.0, 800.0) == 0.0'f32
    check seamDistance(800.0, 800.0) == 0.0'f32
    check seamDistance(400.0, 800.0) == 400.0'f32
    check abs(seamDistance(1.0, 800.0) - seamDistance(799.0, 800.0)) < 1e-6

  test "the frame lights on either seam and nowhere deep inside":
    check frameCoverage(0.0'f32, 300.0'f32, halfT, aa) == 1.0'f32
    check frameCoverage(300.0'f32, 0.0'f32, halfT, aa) == 1.0'f32
    check frameCoverage(300.0'f32, 300.0'f32, halfT, aa) == 0.0'f32
