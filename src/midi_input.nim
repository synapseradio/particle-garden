# ==============================================================================
#
# Layer 3: browser integration for the Web MIDI transport, on
# audio_input.nim's terms. Requests access inside the connect click, tracks
# every input port and the beat-clock count each one carries, and turns raw
# bytes into deliveries through ui/input/midi_core. Hands its
# connect/disconnect/state/ports hooks to web_api through wireMidiControl,
# which app.nim calls first thing in its init: an import used only for a
# module-init effect fails the build's unused-import gate, so the wiring is a
# call rather than a side effect of importing.
#
# JS-only: no native test imports this module, the same limit
# ui/input/midi_core.nim's own comment records for the wiring above it.
#
# ==============================================================================

when defined(js):
  import std/asyncjs
  from std/tables import OrderedTable, initOrderedTable, `[]`, `[]=`,
    hasKey, del, pairs
  from std/strutils import split

  from bindings/typed_arrays import Uint8Array, len, `[]`
  import bindings/web_midi
  import ui/input/midi_core
  import ui/input/control_matrix
  import ui/input/shipped_mapping
  import web_api

  var midiState = if midiAccessAvailable(): msDisconnected else: msUnavailable
  var midiAccess: MIDIAccess
  var subscribedPorts = initOrderedTable[string, MIDIInput]()
  var clockStates = initOrderedTable[string, ClockState]()
  var knownSources: seq[SourceDeclaration] = @SHIPPED_MIDI_SOURCES

  proc labelFor(sourceId: string): string =
    ## Composes a display label for a source not in the shipped set; every
    ## other label is the shipped one already carried in knownSources.
    let parts = sourceId.split(':')
    if parts.len == 4 and parts[0] == "midi" and parts[1] == "cc":
      "CC " & parts[3] & " (channel " & parts[2] & ")"
    elif parts.len == 3 and parts[0] == "midi" and parts[1] == "notes":
      "Notes (channel " & parts[2] & ")"
    elif parts.len == 3 and parts[0] == "midi" and parts[1] == "pc":
      "Program change (channel " & parts[2] & ")"
    else:
      sourceId

  proc declareIfNew(sourceId: string; kind: SourceKind) =
    for decl in knownSources:
      if decl.id == sourceId:
        return
    knownSources.add SourceDeclaration(id: sourceId, label: labelFor(sourceId), kind: kind)
    web_api.registerSourceFamily("midi", knownSources)

  proc handleDelivery(delivery: Delivery) =
    case delivery.kind
    of dkNone:
      discard
    of dkContinuous:
      declareIfNew(delivery.sourceId, skContinuous)
      web_api.setSourceValue(delivery.sourceId, delivery.value)
    of dkEvent:
      declareIfNew(delivery.eventSourceId, skEvent)
      web_api.emitSourceEvent(delivery.eventSourceId, delivery.magnitude, delivery.ordinal)

  proc onPortMessage(portId: string; event: MIDIMessageEvent) =
    let data = event.data
    var bytes = newSeq[byte](data.len)
    for i in 0 ..< data.len:
      bytes[i] = byte(data[i])
    let parsed = parseMessage(bytes)
    if parsed.found:
      handleDelivery(deliveryOf(clockStates[portId], parsed.message))

  proc subscribePort(port: MIDIInput) =
    let portId = $port.id
    if not clockStates.hasKey(portId):
      clockStates[portId] = initClockState()
    subscribedPorts[portId] = port
    port.onmidimessage = proc(event: MIDIMessageEvent) =
      onPortMessage(portId, event)

  proc unsubscribePort(portId: string) =
    if subscribedPorts.hasKey(portId):
      clearOnMidiMessage(subscribedPorts[portId])
      subscribedPorts.del(portId)

  proc onStateChange(event: MIDIConnectionEvent) =
    let port = event.port
    if $portType(port) != "input":
      return
    let portId = $port.id
    case $port.state
    of "connected":
      subscribePort(cast[MIDIInput](port))
    of "disconnected":
      unsubscribePort(portId)
    else:
      discard

  proc onAccessGranted(access: MIDIAccess) =
    if midiState != msRequesting:
      return
    midiAccess = access
    let ports = inputPorts(access)
    for index in 0 ..< portsLength(ports):
      subscribePort(portAt(ports, index))
    access.onstatechange = onStateChange
    midiState = msConnected

  proc onAccessDenied() =
    if midiState != msRequesting:
      return
    midiState = msUnavailable

  proc requestAccess(): Future[void] {.async.} =
    try:
      let access = await requestMIDIAccess()
      onAccessGranted(access)
    except CatchableError:
      onAccessDenied()

  proc connectMidi*() =
    if midiState != msDisconnected:
      return  # a second click mid-request or while connected asks nothing new
    midiState = msRequesting
    discard requestAccess()

  proc disconnectMidi*() =
    for portId, port in subscribedPorts.pairs:
      clearOnMidiMessage(port)
    subscribedPorts = initOrderedTable[string, MIDIInput]()
    if not midiAccess.isNil:
      clearOnStateChange(midiAccess)
      midiAccess = nil
    midiState = msDisconnected
    web_api.withdrawSourceFamily("midi")

  proc stateRead(): MidiState = midiState

  proc portsRead(): seq[tuple[id, name: string]] =
    for portId, port in subscribedPorts.pairs:
      result.add (id: portId, name: $port.name)

  proc wireMidiControl*() =
    ## Declares the shipped MIDI sources, so the shipped rows resolve before
    ## any hardware has spoken, and hands the affordance's hooks to the
    ## boundary. Until this runs the boundary answers Unavailable.
    web_api.registerSourceFamily("midi", SHIPPED_MIDI_SOURCES)
    web_api.registerMidiControl(connectMidi, disconnectMidi, stateRead,
      portsRead)
