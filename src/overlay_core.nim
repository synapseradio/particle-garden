# ==============================================================================
# PARTICLE GARDEN - SPATIAL DRAG OVERLAYS (pure)
# ==============================================================================
#
# While a spatial parameter's slider is dragged, the renderer draws its length
# in the world: interactionRadius as a ring at the cursor, cameraZoom as a
# frame on the world seams. The set is closed to parameters that are literally
# a world distance. Coverage math mirrors overlay.wgsl; constants reach the
# shader through shader_config substitution.

import std/math

type OverlayKind* = enum
  okNone = 0
  okRing = 1
  okFrame = 2

const
  OVERLAY_THICKNESS_PX* = 1.5'f32
    ## Line thickness on screen, in pixels.
  OVERLAY_AA_PX* = 1.0'f32
    ## Antialiasing band beyond the line's edge, in pixels.
  OVERLAY_ALPHA* = 0.35'f32
    ## Peak opacity — quiet enough to read the world through it.

func overlayKindFor*(paramId: string): OverlayKind =
  ## The closed set. A new entry must be literally a world distance.
  case paramId
  of "interactionRadius": okRing
  of "cameraZoom": okFrame
  else: okNone

func edgeCoverage*(distanceFromLine, halfThickness, aa: float32): float32 =
  ## Coverage of a line edge: 1 inside halfThickness, smoothstepping to 0
  ## across the aa band. Mirrors `1 - smoothstep(...)` in overlay.wgsl.
  if distanceFromLine <= halfThickness:
    1.0'f32
  elif distanceFromLine >= halfThickness + aa:
    0.0'f32
  else:
    let t = (distanceFromLine - halfThickness) / aa
    1.0'f32 - t * t * (3.0'f32 - 2.0'f32 * t)

func ringCoverage*(dist, radius, halfThickness, aa: float32): float32 =
  edgeCoverage(abs(dist - radius), halfThickness, aa)

func seamDistance*(coord, size: float32): float32 =
  ## Distance to the nearest world seam (coord = 0 mod size), so the frame
  ## repeats with the torus rather than drawing one privileged image.
  let m = floorMod(coord, size)
  min(m, size - m)

func frameCoverage*(seamX, seamY, halfThickness, aa: float32): float32 =
  edgeCoverage(min(seamX, seamY), halfThickness, aa)
