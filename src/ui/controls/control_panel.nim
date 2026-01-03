# ==============================================================================
# CONTROL PANEL - Panel state and toggle logic
# ==============================================================================
#
# Pure state for control panel visibility and button states.
# DOM binding is JS-only.
#
# ==============================================================================

# ==============================================================================
# SECTION 1: PANEL STATE
# ==============================================================================

type
  PanelState* = object
    ## Control panel visibility state.
    collapsed*: bool
    trailsEnabled*: bool

proc initPanelState*(): PanelState =
  PanelState(
    collapsed: false,
    trailsEnabled: false
  )

# ==============================================================================
# SECTION 2: IMMUTABLE UPDATES
# ==============================================================================

proc withCollapsed*(state: PanelState; collapsed: bool): PanelState =
  result = state
  result.collapsed = collapsed

proc withTrailsEnabled*(state: PanelState; enabled: bool): PanelState =
  result = state
  result.trailsEnabled = enabled

proc toggleCollapsed*(state: PanelState): PanelState =
  result = state
  result.collapsed = not state.collapsed

proc toggleTrails*(state: PanelState): PanelState =
  result = state
  result.trailsEnabled = not state.trailsEnabled

# ==============================================================================
# SECTION 3: QUERIES
# ==============================================================================

proc isCollapsed*(state: PanelState): bool =
  state.collapsed

proc hasTrails*(state: PanelState): bool =
  state.trailsEnabled

proc collapseButtonText*(state: PanelState): string =
  ## Return the text for collapse button.
  if state.collapsed: "+" else: "-"
