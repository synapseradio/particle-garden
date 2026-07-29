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

# ==============================================================================
# SECTION 2: NAVIGATOR TYPE
# ==============================================================================

type
  Navigator* = ref object of JsObject

  GPU* = ref object of JsObject

# ==============================================================================
# SECTION 3: GLOBAL WINDOW ACCESSORS
# ==============================================================================

var windowObj* {.importjs: "window".}: Window

proc getWindow*(): Window {.importjs: "(window)".}

# ==============================================================================
# SECTION 4: WINDOW DIMENSION PROPERTIES
# ==============================================================================

proc innerWidth*(window: Window): int {.importjs: "#.innerWidth".}

proc innerHeight*(window: Window): int {.importjs: "#.innerHeight".}

proc outerWidth*(window: Window): int {.importjs: "#.outerWidth".}

proc outerHeight*(window: Window): int {.importjs: "#.outerHeight".}

# Convenience procs for direct access without going through a Window handle
proc windowInnerWidth*(): int {.importjs: "(window.innerWidth)".}

proc windowInnerHeight*(): int {.importjs: "(window.innerHeight)".}

# ==============================================================================
# SECTION 5: WINDOW SCROLL PROPERTIES
# ==============================================================================

proc scrollX*(window: Window): float {.importjs: "#.scrollX".}

proc scrollY*(window: Window): float {.importjs: "#.scrollY".}

proc pageXOffset*(window: Window): float {.importjs: "#.pageXOffset".}
  ## Alias for scrollX.

proc pageYOffset*(window: Window): float {.importjs: "#.pageYOffset".}
  ## Alias for scrollY.

# ==============================================================================
# SECTION 6: NAVIGATOR ACCESSORS
# ==============================================================================

var navigatorObj* {.importjs: "navigator".}: Navigator

proc getNavigator*(): Navigator {.importjs: "(navigator)".}

proc navigator*(window: Window): Navigator {.importjs: "#.navigator".}

# ==============================================================================
# SECTION 7: NAVIGATOR PROPERTIES
# ==============================================================================

proc hardwareConcurrency*(navigator: Navigator): int {.importjs: "#.hardwareConcurrency".}

proc navigatorHardwareConcurrency*(): int {.importjs: "(navigator.hardwareConcurrency)".}

proc userAgent*(navigator: Navigator): cstring {.importjs: "#.userAgent".}

proc platform*(navigator: Navigator): cstring {.importjs: "#.platform".}

proc language*(navigator: Navigator): cstring {.importjs: "#.language".}

proc languages*(navigator: Navigator): JsObject {.importjs: "#.languages".}

proc onLine*(navigator: Navigator): bool {.importjs: "#.onLine".}

proc maxTouchPoints*(navigator: Navigator): int {.importjs: "#.maxTouchPoints".}

# ==============================================================================
# SECTION 8: WEBGPU VIA NAVIGATOR
# ==============================================================================

proc gpu*(navigator: Navigator): GPU {.importjs: "#.gpu".}
  ## Get the WebGPU GPU object (may be nil if not supported).

proc navigatorGPU*(): GPU {.importjs: "(navigator.gpu)".}

proc hasWebGPU*(): bool {.importjs: "(typeof navigator !== 'undefined' && !!navigator.gpu)".}
  ## Check if WebGPU is available in this environment.

# ==============================================================================
# SECTION 9: ANIMATION FRAME API (re-exported from js_interop with typed Window)
# ==============================================================================

# Note: requestAnimationFrame and cancelAnimationFrame are already in js_interop.
# These add method versions on Window type.

proc requestAnimationFrame*(window: Window, callback: proc(timestamp: float)): int {.importjs: "#.requestAnimationFrame(#)".}

proc cancelAnimationFrame*(window: Window, id: int) {.importjs: "#.cancelAnimationFrame(#)".}

# ==============================================================================
# SECTION 10: TIMER API (method versions on Window)
# ==============================================================================

# Note: setTimeout, setInterval, clearTimeout, clearInterval are in js_interop.
# These add method versions on Window type.

proc setTimeout*(window: Window, callback: proc(), ms: int): TimeoutId {.importjs: "#.setTimeout(#, #)".}

proc clearTimeout*(window: Window, id: TimeoutId) {.importjs: "#.clearTimeout(#)".}

proc setInterval*(window: Window, callback: proc(), ms: int): IntervalId {.importjs: "#.setInterval(#, #)".}

proc clearInterval*(window: Window, id: IntervalId) {.importjs: "#.clearInterval(#)".}

# ==============================================================================
# SECTION 11: WINDOW METHODS
# ==============================================================================

proc alert*(window: Window, message: cstring) {.importjs: "#.alert(#)".}

proc windowAlert*(message: cstring) {.importjs: "window.alert(#)".}

proc confirm*(window: Window, message: cstring): bool {.importjs: "#.confirm(#)".}

proc prompt*(window: Window, message: cstring, default: cstring = ""): cstring {.importjs: "#.prompt(#, #)".}
  ## Returns input, or nil if the user cancels.

proc focus*(window: Window) {.importjs: "#.focus()".}

proc blur*(window: Window) {.importjs: "#.blur()".}

proc close*(window: Window) {.importjs: "#.close()".}

proc print*(window: Window) {.importjs: "#.print()".}

# ==============================================================================
# SECTION 12: WINDOW OPEN
# ==============================================================================

proc open*(window: Window, url: cstring, target: cstring = "_blank", features: cstring = ""): Window {.importjs: "#.open(#, #, #)".}

proc windowOpen*(url: cstring, target: cstring = "_blank"): Window {.importjs: "window.open(#, #)".}

# ==============================================================================
# SECTION 13: SCROLL METHODS
# ==============================================================================

proc scrollTo*(window: Window, xPos: float, yPos: float) {.importjs: "#.scrollTo(#, #)".}

proc scrollBy*(window: Window, xPos: float, yPos: float) {.importjs: "#.scrollBy(#, #)".}

# ==============================================================================
# SECTION 14: DEVICE PIXEL RATIO
# ==============================================================================

proc devicePixelRatio*(window: Window): float {.importjs: "#.devicePixelRatio".}

proc windowDevicePixelRatio*(): float {.importjs: "(window.devicePixelRatio)".}

# ==============================================================================
# SECTION 15: SCREEN PROPERTIES
# ==============================================================================

type
  Screen* = ref object of JsObject

proc screen*(window: Window): Screen {.importjs: "#.screen".}

proc width*(screen: Screen): int {.importjs: "#.width".}

proc height*(screen: Screen): int {.importjs: "#.height".}

proc availWidth*(screen: Screen): int {.importjs: "#.availWidth".}

proc availHeight*(screen: Screen): int {.importjs: "#.availHeight".}

proc colorDepth*(screen: Screen): int {.importjs: "#.colorDepth".}

proc pixelDepth*(screen: Screen): int {.importjs: "#.pixelDepth".}

# ==============================================================================
# SECTION 16: LOCATION
# ==============================================================================

type
  Location* = ref object of JsObject

proc location*(window: Window): Location {.importjs: "#.location".}

proc href*(loc: Location): cstring {.importjs: "#.href".}

proc `href=`*(loc: Location, url: cstring) {.importjs: "#.href = #".}

proc protocol*(loc: Location): cstring {.importjs: "#.protocol".}

proc host*(loc: Location): cstring {.importjs: "#.host".}

proc hostname*(loc: Location): cstring {.importjs: "#.hostname".}

proc port*(loc: Location): cstring {.importjs: "#.port".}

proc pathname*(loc: Location): cstring {.importjs: "#.pathname".}

proc search*(loc: Location): cstring {.importjs: "#.search".}

proc hash*(loc: Location): cstring {.importjs: "#.hash".}

proc reload*(loc: Location) {.importjs: "#.reload()".}

proc assign*(loc: Location, url: cstring) {.importjs: "#.assign(#)".}

proc replace*(loc: Location, url: cstring) {.importjs: "#.replace(#)".}

# ==============================================================================
# SECTION 17: HISTORY
# ==============================================================================

type
  History* = ref object of JsObject

proc history*(window: Window): History {.importjs: "#.history".}

proc length*(history: History): int {.importjs: "#.length".}

proc back*(history: History) {.importjs: "#.back()".}

proc forward*(history: History) {.importjs: "#.forward()".}

proc go*(history: History, delta: int) {.importjs: "#.go(#)".}
  ## delta: negative goes back, positive goes forward.

proc pushState*(history: History, state: JsObject, title: cstring, url: cstring) {.importjs: "#.pushState(#, #, #)".}

proc replaceState*(history: History, state: JsObject, title: cstring, url: cstring) {.importjs: "#.replaceState(#, #, #)".}

# ==============================================================================
# SECTION 18: MATCHMEDIA
# ==============================================================================

type
  MediaQueryList* = ref object of JsObject

proc matchMedia*(window: Window, query: cstring): MediaQueryList {.importjs: "#.matchMedia(#)".}

proc matches*(mql: MediaQueryList): bool {.importjs: "#.matches".}

proc media*(mql: MediaQueryList): cstring {.importjs: "#.media".}

# ==============================================================================
# SECTION 19: LOCAL AND SESSION STORAGE
# ==============================================================================

type
  Storage* = ref object of JsObject

proc localStorage*(window: Window): Storage {.importjs: "#.localStorage".}

proc sessionStorage*(window: Window): Storage {.importjs: "#.sessionStorage".}

proc length*(storage: Storage): int {.importjs: "#.length".}

proc getItem*(storage: Storage, key: cstring): cstring {.importjs: "#.getItem(#)".}

proc setItem*(storage: Storage, key: cstring, value: cstring) {.importjs: "#.setItem(#, #)".}

proc removeItem*(storage: Storage, key: cstring) {.importjs: "#.removeItem(#)".}

proc clear*(storage: Storage) {.importjs: "#.clear()".}

proc key*(storage: Storage, index: int): cstring {.importjs: "#.key(#)".}
