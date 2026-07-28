# ==============================================================================
# SIM CONFIG - Typed configuration aggregate + the world's live couplings
# ==============================================================================
#
# SimConfig composes the two typed tunable records: SimulationState for physics,
# RenderState for visuals. The preset store snapshots and applies this shape;
# web_api keeps CONFIG (the flat GPU-facing mirror) in sync at every mutation
# point.
#
# THE COUPLINGS ARE DERIVED, NEVER STORED. What the world couples is a reading
# of four simulation parameters the user already sets, so couplingsOf computes
# it on demand and nothing holds a second copy. A stored copy would be one fact
# in two places, free to disagree — and the disagreement would be a frame
# dispatching a pass whose strength is zero, or skipping one whose strength is
# not.
#
# worldCouplings exists for a different job: notifying the executor that the
# frame needs rebuilding. It carries the derived value rather than owning it.
#
# Pure module: compiles on both the native (just test) and JS backends.
#
# ==============================================================================

import ../core/observable
import ../../sim_registry
import simulation_state
import render_state

export observable, sim_registry, simulation_state, render_state

type
  SimConfig* = object
    ## Every live tunable, as one typed record.
    simulation*: SimulationState
    render*: RenderState

func defaultSimConfig*(): SimConfig =
  SimConfig(
    simulation: initSimulationState(),
    render: initRenderState()
  )

func couplingsOf*(simulation: SimulationState): WorldCouplings =
  ## What this world couples, read off the parameters that already say so.
  ##
  ## Each strength is the number the shader multiplies by, not a proxy for it:
  ## forceStrength reaches forces.wgsl as `params.forceMultiplier`, fluidStrength
  ## scales forces-sph's whole per-pair contribution, rdDeposit is what
  ## field-deposit lays down, and rdFieldForce is the gain field-force applies.
  ## So a strength being zero and its pass contributing nothing are the same
  ## statement, which is what lets buildFrame skip on it.
  WorldCouplings(
    forces: simulation.forceStrength,
    fluid: simulation.fluidStrength,
    deposit: simulation.rdDeposit,
    fieldForce: simulation.rdFieldForce
  )

## The couplings the executor last acted on. web_api sets it after every write
## to the simulation state; app.nim subscribes webgpu_compute to it, so a
## strength crossing zero rebuilds the frame description. Setting it to a value
## whose zeros are unchanged costs nothing — webgpu_compute compares before
## rebuilding.
var worldCouplings* = newObservable(couplingsOf(initSimulationState()))
