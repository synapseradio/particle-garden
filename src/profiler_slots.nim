# Every GPU profiler slot, shared between the pure frame description
# (sim_registry, native and JS) and the JS-only timestamp-query profiler
# (gpu_profiler). One module closes the pairing between the two: a slot
# renumbered here moves in both places at once instead of by hand in two.
#
# Pure module: no FFI. Compiles on both the native and JS backends.

const
  PROFILER_SLOT_GRID_BUILD* = 0
  PROFILER_SLOT_PHYSICS* = 1
    ## The neighbour sweep plus, until group 1's split, the fluid: now the
    ## sweep alone (binScatter, forces).
  PROFILER_SLOT_DRAW* = 2
  PROFILER_SLOT_PRESENT* = 3
  PROFILER_SLOT_BLOOM* = 4
  PROFILER_SLOT_FIELD* = 5
    ## The world-intrinsic field: fieldResolve and the Gray-Scott substeps.
  PROFILER_SLOT_INTEGRATE* = 6
  PROFILER_SLOT_LONG_RANGE* = 7
    ## The mesh solve (deposit, transforms, kernel mix), once per frame.
  PROFILER_SLOT_BODIES* = 8
  PROFILER_SLOT_FLUID* = 9
    ## forcesSph, in its own per-substep node apart from the sweep.
  PROFILER_SLOT_SCENT* = 10
    ## fieldForce.
  PROFILER_SLOT_LR_FORCE* = 11
    ## lrForce, apart from the solve it reads.
  PROFILER_SLOT_DEPOSIT* = 12
    ## fieldDeposit, in its own once-per-frame node ahead of the field.
  PROFILER_SLOT_NONE* = -1
    ## A pass that writes no timestamps. gpu_profiler holds one query slot per
    ## pass, so two passes sharing a slot in one encoder would overwrite each
    ## other's query; a pass with no slot of its own carries this instead.
  PROFILER_SLOT_COUNT* = 13
