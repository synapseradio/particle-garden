# ==============================================================================
# PARTICLE GARDEN - WINDOW API BINDINGS
# ==============================================================================
#
# Browser window API bindings for animation loops and environment detection.
#
# This module provides idiomatic Nim bindings for:
# - Window object and properties (innerWidth, innerHeight)
# - Navigator object and properties (gpu, hardwareConcurrency)
# - Animation frame API (requestAnimationFrame, cancelAnimationFrame)
# - Timers (setTimeout, setInterval, clearTimeout, clearInterval)
# - Performance timing (performanceNow)
#
# NOTE: Many of these are re-exported from js_interop for convenience.
# This module adds typed Window/Navigator objects and additional properties.
#
# USAGE:
#   import bindings/window
#
#   let w = windowInnerWidth()
#   let h = windowInnerHeight()
#   let cores = navigatorHardwareConcurrency()
#   requestAnimationFrame(myLoopCallback)
#
# ==============================================================================

from std/jsffi import JsObject
import ./js_interop

# ==============================================================================
# SECTION 1: WINDOW TYPE
# ==============================================================================

type
  Window* = ref object of JsObject
    ## Browser window object with typed access to properties and methods.

# ==============================================================================
# SECTION 2: NAVIGATOR TYPE
# ==============================================================================

type
  Navigator* = ref object of JsObject
    ## Browser navigator object for environment detection.

  GPU* = ref object of JsObject
    ## WebGPU GPU object (navigator.gpu).

# ==============================================================================
# SECTION 3: GLOBAL WINDOW ACCESSORS
# ==============================================================================

var windowObj* {.importjs: "window".}: Window
  ## Typed window object (prefer over js_interop's untyped window).

proc getWindow*(): Window {.importjs: "(window)".}
  ## Get the window object (function form for explicit access).

# ==============================================================================
# SECTION 4: WINDOW DIMENSION PROPERTIES
# ==============================================================================

proc innerWidth*(window: Window): int {.importjs: "#.innerWidth".}
  ## Get the interior width of the window in pixels.

proc innerHeight*(window: Window): int {.importjs: "#.innerHeight".}
  ## Get the interior height of the window in pixels.

proc outerWidth*(window: Window): int {.importjs: "#.outerWidth".}
  ## Get the exterior width of the window including scrollbars.

proc outerHeight*(window: Window): int {.importjs: "#.outerHeight".}
  ## Get the exterior height of the window including title bar.

# Convenience procs for direct access without going through a Window handle
proc windowInnerWidth*(): int {.importjs: "(window.innerWidth)".}
  ## Get window inner width directly (convenience).

proc windowInnerHeight*(): int {.importjs: "(window.innerHeight)".}
  ## Get window inner height directly (convenience).

# ==============================================================================
# SECTION 5: WINDOW SCROLL PROPERTIES
# ==============================================================================

proc scrollX*(window: Window): float {.importjs: "#.scrollX".}
  ## Get horizontal scroll position.

proc scrollY*(window: Window): float {.importjs: "#.scrollY".}
  ## Get vertical scroll position.

proc pageXOffset*(window: Window): float {.importjs: "#.pageXOffset".}
  ## Alias for scrollX.

proc pageYOffset*(window: Window): float {.importjs: "#.pageYOffset".}
  ## Alias for scrollY.

# ==============================================================================
# SECTION 6: NAVIGATOR ACCESSORS
# ==============================================================================

var navigatorObj* {.importjs: "navigator".}: Navigator
  ## Typed navigator object.

proc getNavigator*(): Navigator {.importjs: "(navigator)".}
  ## Get the navigator object (function form).

proc navigator*(window: Window): Navigator {.importjs: "#.navigator".}
  ## Get navigator from window object.

# ==============================================================================
# SECTION 7: NAVIGATOR PROPERTIES
# ==============================================================================

proc hardwareConcurrency*(navigator: Navigator): int {.importjs: "#.hardwareConcurrency".}
  ## Get logical processor count available to run threads.

proc navigatorHardwareConcurrency*(): int {.importjs: "(navigator.hardwareConcurrency)".}
  ## Get hardware concurrency directly (convenience).

proc userAgent*(navigator: Navigator): cstring {.importjs: "#.userAgent".}
  ## Get the user agent string.

proc platform*(navigator: Navigator): cstring {.importjs: "#.platform".}
  ## Get the platform string.

proc language*(navigator: Navigator): cstring {.importjs: "#.language".}
  ## Get the preferred language.

proc languages*(navigator: Navigator): JsObject {.importjs: "#.languages".}
  ## Get array of preferred languages.

proc onLine*(navigator: Navigator): bool {.importjs: "#.onLine".}
  ## Check if browser is online.

proc maxTouchPoints*(navigator: Navigator): int {.importjs: "#.maxTouchPoints".}
  ## Get maximum touch points supported.

# ==============================================================================
# SECTION 8: WEBGPU VIA NAVIGATOR
# ==============================================================================

proc gpu*(navigator: Navigator): GPU {.importjs: "#.gpu".}
  ## Get the WebGPU GPU object (may be nil if not supported).

proc navigatorGPU*(): GPU {.importjs: "(navigator.gpu)".}
  ## Get WebGPU GPU object directly (convenience).

proc hasWebGPU*(): bool {.importjs: "(typeof navigator !== 'undefined' && !!navigator.gpu)".}
  ## Check if WebGPU is available in this environment.

# ==============================================================================
# SECTION 9: ANIMATION FRAME API (re-exported from js_interop with typed Window)
# ==============================================================================

# Note: requestAnimationFrame and cancelAnimationFrame are already in js_interop.
# These add method versions on Window type.

proc requestAnimationFrame*(window: Window, callback: proc(timestamp: float)): int {.importjs: "#.requestAnimationFrame(#)".}
  ## Request animation frame via window object.

proc cancelAnimationFrame*(window: Window, id: int) {.importjs: "#.cancelAnimationFrame(#)".}
  ## Cancel animation frame via window object.

# ==============================================================================
# SECTION 10: TIMER API (method versions on Window)
# ==============================================================================

# Note: setTimeout, setInterval, clearTimeout, clearInterval are in js_interop.
# These add method versions on Window type.

proc setTimeout*(window: Window, callback: proc(), ms: int): TimeoutId {.importjs: "#.setTimeout(#, #)".}
  ## Set timeout via window object.

proc clearTimeout*(window: Window, id: TimeoutId) {.importjs: "#.clearTimeout(#)".}
  ## Clear timeout via window object.

proc setInterval*(window: Window, callback: proc(), ms: int): IntervalId {.importjs: "#.setInterval(#, #)".}
  ## Set interval via window object.

proc clearInterval*(window: Window, id: IntervalId) {.importjs: "#.clearInterval(#)".}
  ## Clear interval via window object.

# ==============================================================================
# SECTION 11: WINDOW METHODS
# ==============================================================================

proc alert*(window: Window, message: cstring) {.importjs: "#.alert(#)".}
  ## Show alert dialog.

proc windowAlert*(message: cstring) {.importjs: "window.alert(#)".}
  ## Show alert dialog (convenience).

proc confirm*(window: Window, message: cstring): bool {.importjs: "#.confirm(#)".}
  ## Show confirm dialog, returns true if OK clicked.

proc prompt*(window: Window, message: cstring, default: cstring = ""): cstring {.importjs: "#.prompt(#, #)".}
  ## Show prompt dialog, returns input or null.

proc focus*(window: Window) {.importjs: "#.focus()".}
  ## Focus the window.

proc blur*(window: Window) {.importjs: "#.blur()".}
  ## Blur (unfocus) the window.

proc close*(window: Window) {.importjs: "#.close()".}
  ## Close the window.

proc print*(window: Window) {.importjs: "#.print()".}
  ## Open print dialog.

# ==============================================================================
# SECTION 12: WINDOW OPEN
# ==============================================================================

proc open*(window: Window, url: cstring, target: cstring = "_blank", features: cstring = ""): Window {.importjs: "#.open(#, #, #)".}
  ## Open a new window/tab.

proc windowOpen*(url: cstring, target: cstring = "_blank"): Window {.importjs: "window.open(#, #)".}
  ## Open a new window/tab (convenience).

# ==============================================================================
# SECTION 13: SCROLL METHODS
# ==============================================================================

proc scrollTo*(window: Window, xPos: float, yPos: float) {.importjs: "#.scrollTo(#, #)".}
  ## Scroll to absolute position.

proc scrollBy*(window: Window, xPos: float, yPos: float) {.importjs: "#.scrollBy(#, #)".}
  ## Scroll by relative amount.

# ==============================================================================
# SECTION 14: DEVICE PIXEL RATIO
# ==============================================================================

proc devicePixelRatio*(window: Window): float {.importjs: "#.devicePixelRatio".}
  ## Get the device pixel ratio (for HiDPI displays).

proc windowDevicePixelRatio*(): float {.importjs: "(window.devicePixelRatio)".}
  ## Get device pixel ratio directly (convenience).

# ==============================================================================
# SECTION 15: SCREEN PROPERTIES
# ==============================================================================

type
  Screen* = ref object of JsObject
    ## Browser screen object.

proc screen*(window: Window): Screen {.importjs: "#.screen".}
  ## Get the screen object.

proc width*(screen: Screen): int {.importjs: "#.width".}
  ## Get screen width.

proc height*(screen: Screen): int {.importjs: "#.height".}
  ## Get screen height.

proc availWidth*(screen: Screen): int {.importjs: "#.availWidth".}
  ## Get available screen width.

proc availHeight*(screen: Screen): int {.importjs: "#.availHeight".}
  ## Get available screen height.

proc colorDepth*(screen: Screen): int {.importjs: "#.colorDepth".}
  ## Get color depth in bits.

proc pixelDepth*(screen: Screen): int {.importjs: "#.pixelDepth".}
  ## Get pixel depth in bits.

# ==============================================================================
# SECTION 16: LOCATION
# ==============================================================================

type
  Location* = ref object of JsObject
    ## Browser location object.

proc location*(window: Window): Location {.importjs: "#.location".}
  ## Get the location object.

proc href*(loc: Location): cstring {.importjs: "#.href".}
  ## Get full URL.

proc `href=`*(loc: Location, url: cstring) {.importjs: "#.href = #".}
  ## Set URL (navigates).

proc protocol*(loc: Location): cstring {.importjs: "#.protocol".}
  ## Get protocol (e.g., "https:").

proc host*(loc: Location): cstring {.importjs: "#.host".}
  ## Get host with port.

proc hostname*(loc: Location): cstring {.importjs: "#.hostname".}
  ## Get hostname without port.

proc port*(loc: Location): cstring {.importjs: "#.port".}
  ## Get port number.

proc pathname*(loc: Location): cstring {.importjs: "#.pathname".}
  ## Get path.

proc search*(loc: Location): cstring {.importjs: "#.search".}
  ## Get query string.

proc hash*(loc: Location): cstring {.importjs: "#.hash".}
  ## Get URL fragment.

proc reload*(loc: Location) {.importjs: "#.reload()".}
  ## Reload the page.

proc assign*(loc: Location, url: cstring) {.importjs: "#.assign(#)".}
  ## Navigate to URL.

proc replace*(loc: Location, url: cstring) {.importjs: "#.replace(#)".}
  ## Replace current URL in history.

# ==============================================================================
# SECTION 17: HISTORY
# ==============================================================================

type
  History* = ref object of JsObject
    ## Browser history object.

proc history*(window: Window): History {.importjs: "#.history".}
  ## Get the history object.

proc length*(history: History): int {.importjs: "#.length".}
  ## Get history length.

proc back*(history: History) {.importjs: "#.back()".}
  ## Go back one page.

proc forward*(history: History) {.importjs: "#.forward()".}
  ## Go forward one page.

proc go*(history: History, delta: int) {.importjs: "#.go(#)".}
  ## Go delta pages (negative = back).

proc pushState*(history: History, state: JsObject, title: cstring, url: cstring) {.importjs: "#.pushState(#, #, #)".}
  ## Push state to history.

proc replaceState*(history: History, state: JsObject, title: cstring, url: cstring) {.importjs: "#.replaceState(#, #, #)".}
  ## Replace current history state.

# ==============================================================================
# SECTION 18: MATCHMEDIA
# ==============================================================================

type
  MediaQueryList* = ref object of JsObject
    ## MediaQueryList object for CSS media queries.

proc matchMedia*(window: Window, query: cstring): MediaQueryList {.importjs: "#.matchMedia(#)".}
  ## Test a CSS media query.

proc matches*(mql: MediaQueryList): bool {.importjs: "#.matches".}
  ## Check if media query matches.

proc media*(mql: MediaQueryList): cstring {.importjs: "#.media".}
  ## Get the media query string.

# ==============================================================================
# SECTION 19: LOCAL AND SESSION STORAGE
# ==============================================================================

type
  Storage* = ref object of JsObject
    ## Browser storage object (localStorage/sessionStorage).

proc localStorage*(window: Window): Storage {.importjs: "#.localStorage".}
  ## Get localStorage object.

proc sessionStorage*(window: Window): Storage {.importjs: "#.sessionStorage".}
  ## Get sessionStorage object.

proc length*(storage: Storage): int {.importjs: "#.length".}
  ## Get number of stored items.

proc getItem*(storage: Storage, key: cstring): cstring {.importjs: "#.getItem(#)".}
  ## Get item by key.

proc setItem*(storage: Storage, key: cstring, value: cstring) {.importjs: "#.setItem(#, #)".}
  ## Set item by key.

proc removeItem*(storage: Storage, key: cstring) {.importjs: "#.removeItem(#)".}
  ## Remove item by key.

proc clear*(storage: Storage) {.importjs: "#.clear()".}
  ## Clear all items.

proc key*(storage: Storage, index: int): cstring {.importjs: "#.key(#)".}
  ## Get key at index.

# ==============================================================================
# SECTION 20: TYPE ALIASES FOR MIGRATION COMPATIBILITY
# ==============================================================================

# These allow existing code to gradually migrate without breaking changes.
type
  BrowserWindow* = Window
    ## Alias for Window type.

  BrowserNavigator* = Navigator
    ## Alias for Navigator type.

  BrowserScreen* = Screen
    ## Alias for Screen type.

  BrowserLocation* = Location
    ## Alias for Location type.

  BrowserHistory* = History
    ## Alias for History type.

  BrowserStorage* = Storage
    ## Alias for Storage type.
