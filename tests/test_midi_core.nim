#
# The MIDI core: raw bytes in, typed messages out, deliveries out.
#
# Every expected value here comes from the MIDI 1.0 facts the design states,
# never from this module's own arithmetic: a CC value divides by 127, a note
# number is the event's ordinal, and the beat clock counts 24 pulses per
# quarter note, wrapping there. Byte arrays are built from the status nibbles
# the spec fixes, not copied from parseMessage's own branches.
#

import std/unittest
import ../src/ui/input/midi_core

const MIDI_CORE_TESTS_LOADED* = true

func statusByte(highNibble: uint8; channel: int): uint8 =
  ## Channel is 1-based on the wire in, 0-based in the low nibble.
  highNibble or uint8(channel - 1)

func ccBytes(channel, number, value: int): seq[uint8] =
  @[statusByte(0xB0'u8, channel), uint8(number), uint8(value)]

func noteOnBytes(channel, note, velocity: int): seq[uint8] =
  @[statusByte(0x90'u8, channel), uint8(note), uint8(velocity)]

func noteOffBytes(channel, note, velocity: int): seq[uint8] =
  @[statusByte(0x80'u8, channel), uint8(note), uint8(velocity)]

func pcBytes(channel, program: int): seq[uint8] =
  @[statusByte(0xC0'u8, channel), uint8(program)]

const
  CLOCK_BYTES = @[0xF8'u8]
  START_BYTES = @[0xFA'u8]
  CONTINUE_BYTES = @[0xFB'u8]
  STOP_BYTES = @[0xFC'u8]

func next(state: var ClockState; bytes: seq[uint8]): Delivery =
  deliveryOf(state, parseMessage(bytes).message)


suite "Midi Core Parses Raw Bytes Into Typed Messages":
  test "parseMessage reads channel, number and value from a control-change triple":
    let (found, message) = parseMessage(ccBytes(4, 74, 100))
    check found
    check message.kind == mmControlChange
    check message.ccChannel == 4
    check message.ccNumber == 74
    check message.ccValue == 100

  test "parseMessage reads a one-byte 0xF8 as clock":
    let (found, message) = parseMessage(CLOCK_BYTES)
    check found
    check message.kind == mmClock

  test "parseMessage rejects a status naming none of the eight consumed messages":
    # 0xA0 is polyphonic key pressure, a status D3 does not consume.
    let (found, _) = parseMessage(@[0xA0'u8, 60'u8, 100'u8])
    check found == false

  test "parseMessage rejects an array of the wrong length for its status":
    check parseMessage(@[0xB0'u8, 74'u8]).found == false
    check parseMessage(@[0x90'u8, 60'u8, 100'u8, 0'u8]).found == false
    check parseMessage(@[0xC0'u8]).found == false
    check parseMessage(@[0xF8'u8, 0'u8]).found == false
    # Non-vacuous: the same statuses at their right lengths parse elsewhere in
    # this suite, so length alone is what these reject on.


suite "Midi Core Normalizes Messages Into Deliveries":
  test "deliveryOf normalizes a control change to value over 127 on midi:cc:<channel>:<number>":
    var state = initClockState()
    let (_, message) = parseMessage(ccBytes(2, 74, 64))
    let delivery = deliveryOf(state, message)
    check delivery.kind == dkContinuous
    check delivery.sourceId == "midi:cc:2:74"
    check delivery.value == 64.0 / 127.0

  test "deliveryOf delivers a note on as an event on midi:notes:<channel> with the note as ordinal and velocity over 127 as magnitude":
    var state = initClockState()
    let (_, message) = parseMessage(noteOnBytes(3, 60, 100))
    let delivery = deliveryOf(state, message)
    check delivery.kind == dkEvent
    check delivery.eventSourceId == "midi:notes:3"
    check delivery.ordinal == 60
    check delivery.magnitude == 100.0 / 127.0

  test "deliveryOf delivers nothing for a note off and for a note on at velocity zero":
    var state = initClockState()
    let (_, noteOff) = parseMessage(noteOffBytes(1, 60, 64))
    check deliveryOf(state, noteOff).kind == dkNone
    let (_, zeroVelocityNoteOn) = parseMessage(noteOnBytes(1, 60, 0))
    check deliveryOf(state, zeroVelocityNoteOn).kind == dkNone

  test "deliveryOf delivers a program change as ordinal and magnitude 1.0 on midi:pc:<channel>":
    var state = initClockState()
    let (_, message) = parseMessage(pcBytes(5, 12))
    let delivery = deliveryOf(state, message)
    check delivery.kind == dkEvent
    check delivery.eventSourceId == "midi:pc:5"
    check delivery.ordinal == 12
    check delivery.magnitude == 1.0

  test "deliveryOf gives the same control number on two channels two distinct source ids":
    var state = initClockState()
    let (_, onChannelOne) = parseMessage(ccBytes(1, 7, 50))
    let (_, onChannelTwo) = parseMessage(ccBytes(2, 7, 50))
    check deliveryOf(state, onChannelOne).sourceId != deliveryOf(state, onChannelTwo).sourceId


suite "Midi Core Counts Beat-Clock Pulses Across Start, Continue And Stop":
  test "deliveryOf ordinal runs 0 through 23 then wraps to 0 across 25 pulses after start":
    var state = initClockState()
    discard state.next(START_BYTES)
    var ordinals: seq[int]
    for _ in 0 ..< 25:
      let delivery = state.next(CLOCK_BYTES)
      check delivery.kind == dkEvent
      ordinals.add(delivery.ordinal)
    var expected = @[0]
    for value in 1 .. 23:
      expected.add(value)
    expected.add(0)
    check ordinals == expected

  test "deliveryOf delivers nothing for pulses after a stop until continue or start resumes":
    var state = initClockState()
    discard state.next(START_BYTES)
    discard state.next(CLOCK_BYTES)
    discard state.next(STOP_BYTES)
    check state.next(CLOCK_BYTES).kind == dkNone
    check state.next(CLOCK_BYTES).kind == dkNone

  test "deliveryOf resumes the held count on continue rather than resetting it":
    var state = initClockState()
    discard state.next(START_BYTES)
    discard state.next(CLOCK_BYTES)   # ordinal 0 consumed
    discard state.next(STOP_BYTES)
    discard state.next(CONTINUE_BYTES)
    let delivery = state.next(CLOCK_BYTES)
    check delivery.ordinal == 1

  test "deliveryOf counts from its first pulse when the stream sends no start":
    var state = initClockState()
    let first = state.next(CLOCK_BYTES)
    let second = state.next(CLOCK_BYTES)
    check first.ordinal == 0
    check second.ordinal == 1
