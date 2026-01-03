# ==============================================================================
# DOM HELPERS - Simple DOM manipulation utilities
# ==============================================================================
#
# Null-safe helpers for common DOM operations.
# Reduces casting boilerplate and improves readability.
#
# ==============================================================================

when defined(js):
  from std/dom import Element, getElementById

  from ../bindings/dom_extensions import
    HTMLElement, setClass

  proc setVisible*(id: string; visible: bool) =
    ## Set element visibility by id. No-op if element not found.
    let el = cast[HTMLElement](getElementById(cstring(id)))
    if not el.isNil:
      el.style.display = if visible: cstring"block" else: cstring"none"

  proc show*(id: string) =
    ## Show element by id.
    setVisible(id, true)

  proc hide*(id: string) =
    ## Hide element by id.
    setVisible(id, false)

  proc setText*(id: string; text: string) =
    ## Set element text content by id. No-op if element not found.
    let el = getElementById(cstring(id))
    if not el.isNil:
      el.textContent = cstring(text)

  proc setActive*(id: string; active: bool) =
    ## Toggle "active" class on element by id.
    let el = getElementById(cstring(id))
    if not el.isNil:
      discard el.classList.setClass("active", active)
