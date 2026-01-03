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

func initPanelState*(): PanelState =
  PanelState(
    collapsed: false,
    trailsEnabled: false
  )

# ==============================================================================
# SECTION 2: IMMUTABLE UPDATES
# ==============================================================================

func withCollapsed*(state: PanelState; collapsed: bool): PanelState =
  result = state
  result.collapsed = collapsed

func withTrailsEnabled*(state: PanelState; enabled: bool): PanelState =
  result = state
  result.trailsEnabled = enabled

func toggleCollapsed*(state: PanelState): PanelState =
  result = state
  result.collapsed = not state.collapsed

func toggleTrails*(state: PanelState): PanelState =
  result = state
  result.trailsEnabled = not state.trailsEnabled

# ==============================================================================
# SECTION 3: QUERIES
# ==============================================================================

func isCollapsed*(state: PanelState): bool =
  state.collapsed

func hasTrails*(state: PanelState): bool =
  state.trailsEnabled

func collapseButtonText*(state: PanelState): string =
  ## Return the text for collapse button.
  if state.collapsed: "+" else: "-"
