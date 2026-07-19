# ==============================================================================
# PARTICLE GARDEN - CONTROL PANEL TESTS
# ==============================================================================
#
# Behavioral tests for the pure panel-state transitions behind ui.nim's
# toggleControls/toggleTrails. The toggles must be involutions (two clicks
# restore the prior state), stay independent of each other, and start in
# agreement with CONFIG so the first click cannot desync button and renderer.
#
# Run with: nimble test
#
# ==============================================================================

import std/unittest
import ../src/ui/controls/control_panel

const CONTROL_PANEL_TESTS_LOADED* = true

const CONFIG_DEFAULT_TRAILS = false
  ## Mirror of createConfig's trails default (config.nim is JS-only, so the
  ## value cannot be imported here — the mirror-constant pattern test_config
  ## documents). If config.nim changes this default, update it here too.

suite "Panel State Transitions":
  test "toggleCollapsed is an involution":
    let initial = initPanelState()
    check initial.toggleCollapsed().toggleCollapsed() == initial

  test "toggleTrails is an involution":
    let initial = initPanelState()
    check initial.toggleTrails().toggleTrails() == initial

  test "toggling collapse leaves trails untouched":
    let withTrailsOn = initPanelState().toggleTrails()
    check withTrailsOn.toggleCollapsed().hasTrails() == withTrailsOn.hasTrails()

  test "collapseButtonText tracks collapsed state":
    check collapseButtonText(initPanelState().withCollapsed(true)) == "+"
    check collapseButtonText(initPanelState().withCollapsed(false)) == "-"


suite "Panel Defaults Agree With Config":
  test "initial trails state matches the CONFIG default":
    # ui.nim writes CONFIG.trails through the panel state, so the two must
    # start equal or the first click desyncs button and renderer.
    check initPanelState().hasTrails() == CONFIG_DEFAULT_TRAILS
