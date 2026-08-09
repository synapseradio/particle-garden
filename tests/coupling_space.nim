# The corners of the coupling-strength space, so an invariant asserted "for
# every world" genuinely covers the space rather than a handful of settings the
# author happened to think of. Both the frame tests and the manifest tests sweep
# this one list, so a fifth strength widens their reach by editing one loop.
#
# CORNERS, NOT SAMPLES. buildFrame asks exactly one question of each strength —
# is it zero — so the frame space is finite however continuous the strengths
# are, and these sixteen worlds are all of it. A test needing the values BETWEEN
# the corners is testing physics rather than frame composition, and belongs with
# the oracle that mirrors that physics (sph_core, field_core, physics_core).
#
# tests/test_sim_registry.nim asserts the arbitrariness of the nonzero value
# directly — a strength one part in a billion above zero dispatches exactly
# what a strength of one does — so a threshold smuggled in as `> 0.001` fails
# there rather than hiding as a mode with a floating-point door.

import ../src/sim_registry

const
  COUPLING_OFF* = 0.0
    ## The one value every strength treats specially, and the only one.
  COUPLING_ON* = 1.0
    ## Any nonzero value; the frame path cannot tell this from 0.08 or 150.

const ALL_COUPLINGS* = block:
  var combinations: seq[WorldCouplings]
  for forces in [COUPLING_OFF, COUPLING_ON]:
    for fluid in [COUPLING_OFF, COUPLING_ON]:
      for deposit in [COUPLING_OFF, COUPLING_ON]:
        for fieldForce in [COUPLING_OFF, COUPLING_ON]:
          combinations.add WorldCouplings(forces: forces, fluid: fluid,
            deposit: deposit, fieldForce: fieldForce)
  combinations

const FULLY_COUPLED* = WorldCouplings(forces: COUPLING_ON, fluid: COUPLING_ON,
  deposit: COUPLING_ON, fieldForce: COUPLING_ON)
  ## Every coupling acting. The world every skip is measured against.

const UNCOUPLED* = WorldCouplings(forces: COUPLING_OFF, fluid: COUPLING_OFF,
  deposit: COUPLING_OFF, fieldForce: COUPLING_OFF)
  ## Every strength at zero. Still a world, still running: what survives here is
  ## the definition of world-intrinsic.
