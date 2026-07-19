# ==============================================================================
# SIM CONFIG - Typed configuration aggregate + active simulation kind
# ==============================================================================
#
# SimConfig composes the two typed tunable records (SimulationState for
# physics, RenderState for visuals) with the active simulation kind. The
# preset store snapshots and applies this shape; ui.nim keeps CONFIG (the
# flat GPU-facing mirror) in sync at every mutation point.
#
# activeSimKind is the mode selector's source of truth. app.nim subscribes
# it to webgpu_compute.setActiveSimKind, so switching modes swaps the frame
# description the executor walks. Serialization uses sim_registry's stable
# string ids (simKindId/parseSimKind), never enum ordinals.
#
# Pure module: compiles on both the native (nimble test) and JS backends.
#
# ==============================================================================

import ../core/observable
import ../../sim_registry
import simulation_state
import render_state

export observable, sim_registry, simulation_state, render_state

type
  SimConfig* = object
    ## Every live tunable plus the active mode, as one typed record.
    simulation*: SimulationState
    render*: RenderState
    simKind*: SimKind

func defaultSimConfig*(): SimConfig =
  SimConfig(
    simulation: initSimulationState(),
    render: initRenderState(),
    simKind: skParticleLife
  )

## The active simulation mode. ui.nim's mode buttons set it; app.nim
## subscribes the compute executor to it.
var activeSimKind* = newObservable(skParticleLife)
