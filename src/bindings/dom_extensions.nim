# ==============================================================================
# DOM EXTENSIONS - Minimal extensions to std/dom
# ==============================================================================
#
# Extensions to std/dom for what's missing:
# - HTMLCanvasElement type (std/dom has no Canvas support)
# - Type aliases for HTML naming convention
# - Global document/window bindings
# - Event listener overloads for specific event types
# - ClassList.toggle with force parameter
# - forEach for querySelectorAll results
# - dataset accessor
#
# ==============================================================================

from std/dom import
  Element, InputElement, Document, Window, EventTarget, Node,
  ClassList, Event, MouseEvent, TouchEvent, KeyboardEvent

from std/jsffi import JsObject

# ==============================================================================
# TYPE ALIASES - Map our HTML* names to std/dom names
# ==============================================================================

type
  HTMLElement* = Element
    ## Alias for Element from std/dom

  HTMLInputElement* = InputElement
    ## Alias for InputElement from std/dom

# ==============================================================================
# CANVAS ELEMENT - Not in std/dom
# ==============================================================================

type
  HTMLCanvasElement* = ref object of Element
    ## HTML canvas element for 2D/WebGL rendering
    width* {.importjs: "width".}: int
    height* {.importjs: "height".}: int

proc getContext*(canvas: HTMLCanvasElement, contextType: cstring): JsObject {.importjs: "#.getContext(#)".}
  ## Get a rendering context from canvas (e.g., "2d")

proc getContext*(canvas: HTMLCanvasElement, contextType: cstring, options: JsObject): JsObject {.importjs: "#.getContext(#, #)".}
  ## Get a rendering context with options

proc toDataURL*(canvas: HTMLCanvasElement): cstring {.importjs: "#.toDataURL()".}
  ## Export canvas to data URL (default PNG)

proc toDataURL*(canvas: HTMLCanvasElement, mimeType: cstring): cstring {.importjs: "#.toDataURL(#)".}
  ## Export canvas to data URL with specified MIME type

proc toDataURL*(canvas: HTMLCanvasElement, mimeType: cstring, quality: float): cstring {.importjs: "#.toDataURL(#, #)".}
  ## Export canvas to data URL with MIME type and quality

# ==============================================================================
# GLOBAL BINDINGS - Named domDocument/domWindow to avoid conflicts
# ==============================================================================

var domDocument* {.importjs: "document", nodecl.}: Document
  ## The global document object. Named domDocument to avoid shadowing.

var domWindow* {.importjs: "window", nodecl.}: Window
  ## The global window object. Named domWindow to avoid shadowing.

# ==============================================================================
# EVENT LISTENER OVERLOADS - for various callback signatures
# ==============================================================================

# No-argument callbacks
proc addEventListener*(et: EventTarget, event: cstring, handler: proc()) {.importjs: "#.addEventListener(#, #)".}
  ## Add event listener with no-argument callback

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(), useCapture: bool) {.importjs: "#.addEventListener(#, #, #)".}
  ## Add event listener with no-argument callback and capture option

# Specific event type callbacks
proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: Event)) {.importjs: "#.addEventListener(#, #)".}
  ## Add event listener with Event callback

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: MouseEvent)) {.importjs: "#.addEventListener(#, #)".}
  ## Add event listener with MouseEvent callback

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: TouchEvent)) {.importjs: "#.addEventListener(#, #)".}
  ## Add event listener with TouchEvent callback

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: KeyboardEvent)) {.importjs: "#.addEventListener(#, #)".}
  ## Add event listener with KeyboardEvent callback

# ==============================================================================
# CLASSLIST EXTENSIONS - std/dom lacks force parameter
# ==============================================================================

proc setClass*(c: ClassList, class: cstring, present: bool): bool {.importjs: "#.toggle(#, #)".}
  ## Set class presence explicitly - returns true if class is now present
  ## This is classList.toggle(class, force) which sets rather than toggles

# ==============================================================================
# NODELIST/SEQ HELPERS - forEach for querySelectorAll results
# ==============================================================================

proc forEach*(elements: seq[Element], callback: proc(el: Element)) {.importjs: "#.forEach(#)".}
  ## Iterate over elements from querySelectorAll

# ==============================================================================
# ELEMENT EXTENSIONS - dataset, etc.
# ==============================================================================

proc dataset*(el: Element): JsObject {.importjs: "#.dataset".}
  ## Access element's data-* attributes as object

# ==============================================================================
# TYPE CONVERSION HELPERS
# ==============================================================================

proc toHTMLInputElement*(el: Element): HTMLInputElement {.inline.} =
  ## Cast Element to HTMLInputElement
  cast[HTMLInputElement](el)

proc toHTMLCanvasElement*(el: Element): HTMLCanvasElement {.inline.} =
  ## Cast Element to HTMLCanvasElement
  cast[HTMLCanvasElement](el)

proc toHTMLElement*(el: Element): HTMLElement {.inline.} =
  ## Cast Element to HTMLElement (identity since HTMLElement = Element)
  cast[HTMLElement](el)
