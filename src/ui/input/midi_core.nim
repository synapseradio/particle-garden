# ==============================================================================
# PARTICLE GARDEN - MIDI CORE
# ==============================================================================
#
# Raw MIDI bytes in, typed messages and normalized deliveries out. Pure: no
# FFI, no transport, compiled on both backends and exercised natively by
# tests/test_midi_core.nim. The wiring (src/midi_input.nim) receives port
# bytes, calls parseMessage and deliveryOf, and stages what comes back for the
# control matrix; nothing outside this file interprets a MIDI byte.
#
# ==============================================================================

const MIDI_PULSES_PER_BEAT* = 24
  ## Quarter-note pulses per the MIDI 1.0 beat clock; fixed by the spec, not
  ## a tempo estimate.

type
  MidiState* = enum
    ## The connect affordance's four states; shared by the transport module
    ## and the boundary the way audio_core.ListenState is.
    msDisconnected = "Disconnected"
    msRequesting = "Requesting"
    msConnected = "Connected"
    msUnavailable = "Unavailable"

  MidiMessageKind* = enum
    mmControlChange, mmNoteOn, mmNoteOff, mmProgramChange
    mmClock, mmStart, mmContinue, mmStop

  MidiMessage* = object
    ## One parsed MIDI message. Each branch carries only the fields its wire
    ## format has, so a caller cannot read a note number off a clock pulse.
    case kind*: MidiMessageKind
    of mmControlChange:
      ccChannel*: int    ## 1-based
      ccNumber*: int
      ccValue*: int      ## 0..127, raw off the wire
    of mmNoteOn, mmNoteOff:
      noteChannel*: int  ## 1-based
      note*: int
      velocity*: int     ## 0..127, raw off the wire
    of mmProgramChange:
      pcChannel*: int    ## 1-based
      program*: int
    of mmClock, mmStart, mmContinue, mmStop:
      discard

  DeliveryKind* = enum dkNone, dkContinuous, dkEvent

  Delivery* = object
    ## What a parsed message hands the control matrix: nothing, a continuous
    ## value, or an event. Never a bare MidiMessage, so a consumer never
    ## re-derives a source id or re-applies the velocity-zero rule.
    case kind*: DeliveryKind
    of dkNone:
      discard
    of dkContinuous:
      sourceId*: string
      value*: float        ## [0, 1]
    of dkEvent:
      eventSourceId*: string
      magnitude*: float     ## [0, 1]
      ordinal*: int

  ClockState* = object
    ## The beat-clock counter one MIDI stream carries across messages.
    nextOrdinal: int  ## 0..MIDI_PULSES_PER_BEAT-1, what the next 0xF8 delivers
    stopped: bool      ## true after 0xFC, until 0xFB or 0xFA clears it

func initClockState*(): ClockState =
  ## A stream with no start counts from its first pulse, so this is exactly
  ## what start itself resets to.
  ClockState(nextOrdinal: 0, stopped: false)

func emptyMessage(): MidiMessage =
  MidiMessage(kind: mmClock)

func channelOf(status: uint8): int =
  int(status and 0x0F'u8) + 1

func parseMessage*(bytes: openArray[uint8]): tuple[found: bool, message: MidiMessage] =
  ## Three-byte channel messages (note on, note off, control change), the
  ## two-byte program change, and the one-byte system real-time messages.
  ## A status naming none of these, or an array of the wrong length for the
  ## status it names, is rejected with no delivery.
  if bytes.len == 0:
    return (false, emptyMessage())
  let status = bytes[0]
  case status
  of 0xF8'u8:
    if bytes.len == 1: (true, MidiMessage(kind: mmClock))
    else: (false, emptyMessage())
  of 0xFA'u8:
    if bytes.len == 1: (true, MidiMessage(kind: mmStart))
    else: (false, emptyMessage())
  of 0xFB'u8:
    if bytes.len == 1: (true, MidiMessage(kind: mmContinue))
    else: (false, emptyMessage())
  of 0xFC'u8:
    if bytes.len == 1: (true, MidiMessage(kind: mmStop))
    else: (false, emptyMessage())
  else:
    case status and 0xF0'u8
    of 0x80'u8:
      if bytes.len == 3:
        (true, MidiMessage(kind: mmNoteOff, noteChannel: channelOf(status),
          note: int(bytes[1]), velocity: int(bytes[2])))
      else: (false, emptyMessage())
    of 0x90'u8:
      if bytes.len == 3:
        (true, MidiMessage(kind: mmNoteOn, noteChannel: channelOf(status),
          note: int(bytes[1]), velocity: int(bytes[2])))
      else: (false, emptyMessage())
    of 0xB0'u8:
      if bytes.len == 3:
        (true, MidiMessage(kind: mmControlChange, ccChannel: channelOf(status),
          ccNumber: int(bytes[1]), ccValue: int(bytes[2])))
      else: (false, emptyMessage())
    of 0xC0'u8:
      if bytes.len == 2:
        (true, MidiMessage(kind: mmProgramChange, pcChannel: channelOf(status),
          program: int(bytes[1])))
      else: (false, emptyMessage())
    else:
      (false, emptyMessage())

func deliveryOf*(state: var ClockState; message: MidiMessage): Delivery =
  ## The message as the control matrix receives it. Clock messages consume
  ## and advance `state`; every other kind reads none of it.
  case message.kind
  of mmControlChange:
    Delivery(kind: dkContinuous,
      sourceId: "midi:cc:" & $message.ccChannel & ":" & $message.ccNumber,
      value: message.ccValue.float / 127.0)
  of mmNoteOn:
    if message.velocity == 0:
      # Velocity 0 is a note-off under the MIDI 1.0 specification.
      Delivery(kind: dkNone)
    else:
      Delivery(kind: dkEvent,
        eventSourceId: "midi:notes:" & $message.noteChannel,
        magnitude: message.velocity.float / 127.0, ordinal: message.note)
  of mmNoteOff:
    Delivery(kind: dkNone)
  of mmProgramChange:
    Delivery(kind: dkEvent, eventSourceId: "midi:pc:" & $message.pcChannel,
      magnitude: 1.0, ordinal: message.program)
  of mmClock:
    if state.stopped:
      Delivery(kind: dkNone)
    else:
      let ordinal = state.nextOrdinal
      state.nextOrdinal = (state.nextOrdinal + 1) mod MIDI_PULSES_PER_BEAT
      Delivery(kind: dkEvent, eventSourceId: "midi:clock", magnitude: 1.0,
        ordinal: ordinal)
  of mmStart:
    state.nextOrdinal = 0
    state.stopped = false
    Delivery(kind: dkNone)
  of mmContinue:
    state.stopped = false
    Delivery(kind: dkNone)
  of mmStop:
    state.stopped = true
    Delivery(kind: dkNone)
