# ==============================================================================
# PARTICLE GARDEN - THE COUPLING SPACE (SHARED TEST FIXTURE)
# ==============================================================================
#
# Every combination of the three coupling booleans, so an invariant asserted
# "for every couplings" genuinely covers the space rather than the three legacy
# triples. Both the frame tests and the manifest tests sweep the same eight
# worlds, and they sweep this one list so a fourth coupling widens their reach
# by editing one loop.
#
# A fixture rather than a test module: it declares no suite, so test_all.nim
# reaches it through the test modules that import it and it needs no entry of
# its own there.
#
# ==============================================================================

import ../src/sim_registry

const ALL_COUPLINGS* = block:
  var combinations: seq[WorldCouplings]
  for forces in [false, true]:
    for sph in [false, true]:
      for field in [false, true]:
        combinations.add WorldCouplings(forces: forces, sph: sph, field: field)
  combinations
