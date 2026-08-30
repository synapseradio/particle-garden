---
group: camera
---

# Camera

The world wraps at its edges, and the camera looks at it from above. Zoom 1
frames the whole world exactly; zooming in approaches creature scale. Pan
far enough in any direction and the view comes back around.

- `cameraZoom` — how close the view sits. The wheel zooms at the cursor,
  the zero key reframes the whole world, and while you drag this slider the
  world's edges draw as a frame so you can see how much of it you are
  looking at.
- `cameraDriftSpeed` — view widths the camera travels per minute while Drift
  is on. One screen a minute is the notch; the floor takes twenty minutes to
  cross a screen, and the ceiling crosses one every fifteen seconds.

Drift sends the camera on a slow tour of its own. The view slides along a
heading that never retraces its path, and the zoom breathes between the level
you left it at and twice that, so the tour passes over the same ground at
different distances. Drift off holds the camera exactly where you put it, and
the speed slider greys out.

Move the camera yourself and the drift yields: a drag, a wheel, an arrow key
or the Zoom slider stops it while you work and for a few seconds after your
last touch. It then picks up from where your gesture left the view, at that
position and that zoom, so nothing snaps back.

A preset carries whether the drift runs and how fast, and never carries where
the camera is standing. Loading one leaves your view where you left it.
