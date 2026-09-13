# https://www.w3.org/TR/webmidi/

from std/jsffi import JsObject
from std/asyncjs import Future
import ./typed_arrays

type
  MIDIPort* = ref object of JsObject
    id* {.importjs: "id".}: cstring
    name* {.importjs: "name".}: cstring
    state* {.importjs: "state".}: cstring

  MIDIInput* = ref object of MIDIPort

  MIDIAccess* = ref object of JsObject

  MIDIMessageEvent* = ref object of JsObject
    data* {.importjs: "data".}: Uint8Array

  MIDIConnectionEvent* = ref object of JsObject
    port* {.importjs: "port".}: MIDIPort

proc portType*(port: MIDIPort): cstring {.importjs: "#.type".}
  ## "input" or "output"; a proc rather than a field since `type` is a Nim keyword.

proc midiAccessAvailable*(): bool {.importjs: "(typeof navigator.requestMIDIAccess === 'function')".}
  ## Lets the transport report unavailable without requesting access.

proc requestMIDIAccess*(): Future[MIDIAccess] {.importjs: "navigator.requestMIDIAccess()".}

proc inputPorts*(access: MIDIAccess): JsObject {.importjs: "Array.from(#.inputs.values())".}
  ## `inputs` is a MIDIInputMap (a Map); snapshotting it to an array avoids
  ## binding the Map/iterator protocol for a one-time read per connect.

proc portsLength*(ports: JsObject): int {.importjs: "#.length".}

proc portAt*(ports: JsObject, index: int): MIDIInput {.importjs: "#[#]".}

proc `onmidimessage=`*(port: MIDIInput, handler: proc(event: MIDIMessageEvent)) {.importjs: "#.onmidimessage = #".}

proc clearOnMidiMessage*(port: MIDIInput) {.importjs: "#.onmidimessage = null".}

proc `onstatechange=`*(access: MIDIAccess, handler: proc(event: MIDIConnectionEvent)) {.importjs: "#.onstatechange = #".}

proc clearOnStateChange*(access: MIDIAccess) {.importjs: "#.onstatechange = null".}
