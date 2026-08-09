from std/dom import
  Element, InputElement, Document, Window, EventTarget, Node,
  ClassList, Event, MouseEvent, TouchEvent, KeyboardEvent

from std/jsffi import JsObject

type
  HTMLElement* = Element

  HTMLInputElement* = InputElement

# ==============================================================================
# CANVAS ELEMENT - Not in std/dom
# ==============================================================================

type
  HTMLCanvasElement* = ref object of Element
    ## HTML canvas element for 2D/WebGL rendering
    width* {.importjs: "width".}: int
    height* {.importjs: "height".}: int

type
  WheelEvent* = ref object of Event
    ## DOM WheelEvent. Declared here rather than derived from std/dom's
    ## MouseEvent because std/dom has no WheelEvent at all, and the three fields
    ## the camera needs are the only ones read.
    deltaY* {.importjs: "deltaY".}: float
      ## Vertical scroll amount. Positive scrolls down/away, which zooms OUT.
    deltaX* {.importjs: "deltaX".}: float
      ## Horizontal scroll amount, which a trackpad's sideways swipe reports.
    offsetX* {.importjs: "offsetX".}: float
      ## Cursor x relative to the target element's padding edge — canvas
      ## coordinates, not page coordinates, which is what the zoom anchor needs.
    offsetY* {.importjs: "offsetY".}: float
      ## Cursor y relative to the target element's padding edge.
    ctrlKey* {.importjs: "ctrlKey".}: bool
      ## Whether control was held. A trackpad pinch also arrives with this set
      ## and no key touched — a browser reports pinch gestures only as
      ## ctrl-wheel events, which is how pinch-to-zoom is detected here.
      ## https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/ctrlKey
    metaKey* {.importjs: "metaKey".}: bool
      ## Whether cmd was held, which is the macOS spelling of the same intent.

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: WheelEvent)) {.importjs: "#.addEventListener(#, #)".}

proc addNonPassiveEventListener*(et: EventTarget, event: cstring, handler: proc(e: WheelEvent)) {.importjs: "#.addEventListener(#, #, {passive: false})".}
  ## A passive listener cannot preventDefault: the browser drops the call and
  ## scrolls or zooms the page anyway, reporting nothing anywhere. Element
  ## targets default to non-passive, so this states the choice rather than
  ## inheriting it — and it states it at the one place a later move of the
  ## listener to window or document, where that default flips, would otherwise
  ## break the gesture in silence.
  ## https://developer.mozilla.org/en-US/docs/Web/API/EventTarget/addEventListener

proc getContext*(canvas: HTMLCanvasElement, contextType: cstring): JsObject {.importjs: "#.getContext(#)".}

proc getContext*(canvas: HTMLCanvasElement, contextType: cstring, options: JsObject): JsObject {.importjs: "#.getContext(#, #)".}

proc toDataURL*(canvas: HTMLCanvasElement): cstring {.importjs: "#.toDataURL()".}

proc toDataURL*(canvas: HTMLCanvasElement, mimeType: cstring): cstring {.importjs: "#.toDataURL(#)".}

proc toDataURL*(canvas: HTMLCanvasElement, mimeType: cstring, quality: float): cstring {.importjs: "#.toDataURL(#, #)".}

var domDocument* {.importjs: "document", nodecl.}: Document
  ## The global document object. Named domDocument to avoid shadowing.

var domWindow* {.importjs: "window", nodecl.}: Window
  ## The global window object. Named domWindow to avoid shadowing.

proc addEventListener*(et: EventTarget, event: cstring, handler: proc()) {.importjs: "#.addEventListener(#, #)".}

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(), useCapture: bool) {.importjs: "#.addEventListener(#, #, #)".}

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: Event)) {.importjs: "#.addEventListener(#, #)".}

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: MouseEvent)) {.importjs: "#.addEventListener(#, #)".}

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: TouchEvent)) {.importjs: "#.addEventListener(#, #)".}

proc addEventListener*(et: EventTarget, event: cstring, handler: proc(e: KeyboardEvent)) {.importjs: "#.addEventListener(#, #)".}

# ==============================================================================
# CLASSLIST EXTENSIONS - std/dom lacks force parameter
# ==============================================================================

proc setClass*(c: ClassList, class: cstring, present: bool): bool {.importjs: "#.toggle(#, #)".}
  ## Set class presence explicitly - returns true if class is now present
  ## This is classList.toggle(class, force) which sets rather than toggles

proc forEach*(elements: seq[Element], callback: proc(el: Element)) {.importjs: "#.forEach(#)".}

proc dataset*(el: Element): JsObject {.importjs: "#.dataset".}
  ## Access element's data-* attributes as object

proc toHTMLInputElement*(el: Element): HTMLInputElement {.inline.} =
  cast[HTMLInputElement](el)

proc toHTMLCanvasElement*(el: Element): HTMLCanvasElement {.inline.} =
  cast[HTMLCanvasElement](el)

proc toHTMLElement*(el: Element): HTMLElement {.inline.} =
  ## Identity cast since HTMLElement = Element.
  cast[HTMLElement](el)
