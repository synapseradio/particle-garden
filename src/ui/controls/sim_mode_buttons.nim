# ==============================================================================
# SIM MODE BUTTONS - Mode-selector button active-state sync
# ==============================================================================
#
# The one place the three mode-selector buttons' active classes are set from a
# SimKind. Both mode-switch entry points call it — ui.nim's setSimMode (user
# click) and preset_store.nim's pasMode apply step (preset load) — so the
# buttons can never disagree about which mode is active. Lives below both
# callers (ui.nim imports preset_store, so preset_store cannot reach ui.nim's
# setSimMode without a cycle).
#
# JS-only: pure DOM glue, verified by `nimble app`.
#
# ==============================================================================

when defined(js):
  import ../../sim_registry
  import ../dom_helpers

  proc syncSimModeButtons*(kind: SimKind) =
    ## Set the active class on exactly the mode button matching `kind`.
    setActive("modeParticleLifeBtn", kind == skParticleLife)
    setActive("modeSphBtn", kind == skSph)
    setActive("modeReactionDiffusionBtn", kind == skReactionDiffusion)
