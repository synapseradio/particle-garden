import std/[sets, unittest]
import ../src/ui/state/input_state
import ../src/ui/input/binding_table
import ../src/ui/input/key_handler
import ../src/ui/input/mouse_handler
import ../src/ui/input/touch_handler

const INPUT_TESTS_LOADED* = true

suite "InputState - Basic Operations":
  test "initInputState creates zeroed state":
    let state = initInputState()
    check state.mouseX == 0.0
    check state.mouseY == 0.0
    check state.mouseDown == false
    check state.mouseRightDown == false
    check state.blastStrength == 0.0

  test "withMousePosition updates coordinates":
    let state = initInputState().withMousePosition(100.0, 200.0)
    check state.mouseX == 100.0
    check state.mouseY == 200.0

  test "withMouseDown sets left button":
    let state = initInputState().withMouseDown(true)
    check state.mouseDown == true
    check state.mouseRightDown == false

  test "withMouseRightDown sets right button":
    let state = initInputState().withMouseRightDown(true)
    check state.mouseDown == false
    check state.mouseRightDown == true

  test "withAllButtonsUp releases all buttons":
    let state = initInputState()
      .withMouseDown(true)
      .withMouseRightDown(true)
      .withAllButtonsUp()
    check state.mouseDown == false
    check state.mouseRightDown == false


suite "InputState - Blast Effect":
  test "withBlast triggers blast at position":
    let state = initInputState().withBlast(50.0, 75.0, 1.0)
    check state.blastX == 50.0
    check state.blastY == 75.0
    check state.blastStrength == 1.0

  test "withBlast takes the strength its caller names":
    # A pad hit lands at the velocity it was struck with, so strength is the
    # caller's to say rather than pinned inside the state.
    let state = initInputState().withBlast(10.0, 20.0, 0.4)
    check state.blastX == 10.0
    check state.blastY == 20.0
    check state.blastStrength == 0.4

  test "withBlastDecay reduces strength":
    let state = initInputState()
      .withBlast(0.0, 0.0, 1.0)
      .withBlastDecay(0.5)
    check state.blastStrength == 0.5

  test "withBlastCleared zeroes strength":
    let state = initInputState()
      .withBlast(0.0, 0.0, 1.0)
      .withBlastCleared()
    check state.blastStrength == 0.0

  test "hasActiveBlast detects active blast":
    let inactive = initInputState()
    let active = initInputState().withBlast(0.0, 0.0, 1.0)
    let decayed = active.withBlastDecay(0.0001)

    check inactive.hasActiveBlast() == false
    check active.hasActiveBlast() == true
    check decayed.hasActiveBlast() == false


suite "InputState - Queries":
  test "isAnyButtonDown detects left button":
    let state = initInputState().withMouseDown(true)
    check state.isAnyButtonDown() == true

  test "isAnyButtonDown detects right button":
    let state = initInputState().withMouseRightDown(true)
    check state.isAnyButtonDown() == true

  test "isAnyButtonDown returns false when no buttons":
    let state = initInputState()
    check state.isAnyButtonDown() == false


suite "MouseHandler - Mouse Down":
  test "left click sets mouseDown":
    let event = MouseEventData(clientX: 10.0, clientY: 20.0, button: mbLeft)
    let state = handleMouseDown(initInputState(), event)

    check state.mouseX == 10.0
    check state.mouseY == 20.0
    check state.mouseDown == true
    check state.mouseRightDown == false

  test "right click sets mouseRightDown":
    let event = MouseEventData(clientX: 30.0, clientY: 40.0, button: mbRight)
    let state = handleMouseDown(initInputState(), event)

    check state.mouseX == 30.0
    check state.mouseY == 40.0
    check state.mouseDown == false
    check state.mouseRightDown == true

  test "middle click does not set buttons":
    let event = MouseEventData(clientX: 50.0, clientY: 60.0, button: mbMiddle)
    let state = handleMouseDown(initInputState(), event)

    check state.mouseX == 50.0
    check state.mouseY == 60.0
    check state.mouseDown == false
    check state.mouseRightDown == false


suite "MouseHandler - A Held Modifier Lights A Body":
  # The press point travels through unchanged; canvas_input converts the point
  # this returns to world space, since an ignition pins a moment to a world
  # point while the live cursor stays in canvas pixels.
  test "a modifier-held primary press asks for a body where it was pressed":
    let event = MouseEventData(clientX: 1280.0, clientY: 720.0, button: mbLeft,
      shiftHeld: true)
    let outcome = handlePrimaryPress(initInputState(), event)

    check outcome.ignites == true
    check outcome.atX == 1280.0
    check outcome.atY == 720.0

  test "the press that lights a body does not also grab the cursor":
    # Otherwise the gesture attracts particles toward the point for as long as
    # the button is held, and the body ignites into a crowd the gesture made.
    let event = MouseEventData(clientX: 1280.0, clientY: 720.0, button: mbLeft,
      shiftHeld: true)
    let outcome = handlePrimaryPress(initInputState(), event)

    check outcome.state.mouseDown == false
    check outcome.state.mouseRightDown == false

  test "an unmodified primary press still reaches the live cursor":
    let event = MouseEventData(clientX: 10.0, clientY: 20.0, button: mbLeft)
    let outcome = handlePrimaryPress(initInputState(), event)

    check outcome.ignites == false
    check outcome.state == handleMouseDown(initInputState(), event)

  test "a modifier held on a non-primary button lights nothing":
    # The right button repels; a modifier does not turn it into an ignition.
    for button in [mbRight, mbMiddle]:
      let event = MouseEventData(clientX: 10.0, clientY: 20.0, button: button,
        shiftHeld: true)
      let outcome = handlePrimaryPress(initInputState(), event)
      checkpoint($button)
      check outcome.ignites == false
      check outcome.state == handleMouseDown(initInputState(), event)

  test "the blast gestures are untouched by the modifier":
    # Double-click and the two-finger tap still fire blasts, held or not: the
    # ignition is a new gesture beside them, not a reinterpretation of one.
    let held = MouseEventData(clientX: 200.0, clientY: 300.0, button: mbLeft,
      shiftHeld: true)
    let blasted = handleDoubleClick(initInputState(), held)
    check blasted.blastX == 200.0
    check blasted.blastY == 300.0
    check blasted.blastStrength == 1.0

    let tap = TouchEventData(touches: @[
      TouchPoint(clientX: 100.0, clientY: 100.0),
      TouchPoint(clientX: 300.0, clientY: 300.0)])
    let tapped = handleTwoFingerTap(initInputState(), tap)
    check tapped.blastStrength == 1.0


suite "MouseHandler - Mouse Up":
  test "left button release":
    let initial = initInputState().withMouseDown(true)
    let event = MouseEventData(clientX: 0.0, clientY: 0.0, button: mbLeft)
    let state = handleMouseUp(initial, event)

    check state.mouseDown == false

  test "right button release":
    let initial = initInputState().withMouseRightDown(true)
    let event = MouseEventData(clientX: 0.0, clientY: 0.0, button: mbRight)
    let state = handleMouseUp(initial, event)

    check state.mouseRightDown == false

  test "releasing one button preserves other":
    let initial = initInputState()
      .withMouseDown(true)
      .withMouseRightDown(true)
    let event = MouseEventData(clientX: 0.0, clientY: 0.0, button: mbLeft)
    let state = handleMouseUp(initial, event)

    check state.mouseDown == false
    check state.mouseRightDown == true


suite "MouseHandler - Mouse Move":
  test "updates position":
    let event = MouseEventData(clientX: 123.0, clientY: 456.0, button: mbLeft)
    let state = handleMouseMove(initInputState(), event)

    check state.mouseX == 123.0
    check state.mouseY == 456.0

  test "preserves button state":
    let initial = initInputState().withMouseDown(true)
    let event = MouseEventData(clientX: 100.0, clientY: 200.0, button: mbLeft)
    let state = handleMouseMove(initial, event)

    check state.mouseDown == true


suite "MouseHandler - Mouse Leave":
  test "releases all buttons":
    let initial = initInputState()
      .withMouseDown(true)
      .withMouseRightDown(true)
    let state = handleMouseLeave(initial)

    check state.mouseDown == false
    check state.mouseRightDown == false


suite "MouseHandler - Double Click":
  test "triggers blast at position":
    let event = MouseEventData(clientX: 200.0, clientY: 300.0, button: mbLeft)
    let state = handleDoubleClick(initInputState(), event)

    check state.blastX == 200.0
    check state.blastY == 300.0
    check state.blastStrength == 1.0


suite "MouseHandler - Frame Update":
  test "decays active blast":
    let initial = initInputState().withBlast(0.0, 0.0, 1.0)
    let state = updateFrame(initial)

    check state.blastStrength < 1.0
    check state.blastStrength == BLAST_DECAY_FACTOR

  test "no-op when no active blast":
    let initial = initInputState()
    let state = updateFrame(initial)

    check state.blastStrength == 0.0


suite "TouchHandler - Touch Start":
  test "first touch acts as left mouse down":
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 100.0, clientY: 200.0)
    ])
    let state = handleTouchStart(initInputState(), event)

    check state.mouseX == 100.0
    check state.mouseY == 200.0
    check state.mouseDown == true

  test "empty touches does nothing":
    let event = TouchEventData(touches: @[])
    let state = handleTouchStart(initInputState(), event)

    check state.mouseDown == false


suite "TouchHandler - Touch End":
  test "releases when all touches end":
    let initial = initInputState().withMouseDown(true)
    let event = TouchEventData(touches: @[])
    let state = handleTouchEnd(initial, event)

    check state.mouseDown == false

  test "preserves state if touches remain":
    let initial = initInputState().withMouseDown(true)
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 50.0, clientY: 50.0)
    ])
    let state = handleTouchEnd(initial, event)

    check state.mouseDown == true


suite "TouchHandler - Touch Move":
  test "updates position from first touch":
    let initial = initInputState().withMouseDown(true)
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 300.0, clientY: 400.0)
    ])
    let state = handleTouchMove(initial, event)

    check state.mouseX == 300.0
    check state.mouseY == 400.0

  test "ignores secondary touches":
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 100.0, clientY: 100.0),
      TouchPoint(clientX: 500.0, clientY: 500.0)
    ])
    let state = handleTouchMove(initInputState(), event)

    check state.mouseX == 100.0
    check state.mouseY == 100.0


suite "TouchHandler - Touch Cancel":
  test "clears the press and preserves the last position":
    let initial = initInputState()
      .withMouseDown(true)
      .withMousePosition(100.0, 100.0)
    let state = handleTouchCancel(initial)

    check state.mouseDown == false
    check state.mouseX == 100.0


suite "TouchHandler - Two Finger Tap":
  test "two fingers fire a blast at their midpoint":
    # The midpoint, not either finger: a blast at one of two touch points sits
    # off to the side of the gesture, and WHICH side would depend on the
    # undefined order the browser reports touches in.
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 100.0, clientY: 200.0),
      TouchPoint(clientX: 300.0, clientY: 400.0)])
    let state = handleTwoFingerTap(initInputState(), event)

    check state.blastX == 200.0
    check state.blastY == 300.0
    check state.blastStrength > 0.0

  test "the midpoint does not depend on which finger is reported first":
    # Guards against order-dependence: the browser may report the two touches
    # in either order, and the midpoint must not depend on which.
    let forward = TouchEventData(touches: @[
      TouchPoint(clientX: 10.0, clientY: 20.0),
      TouchPoint(clientX: 90.0, clientY: 60.0)])
    let reversed = TouchEventData(touches: @[
      TouchPoint(clientX: 90.0, clientY: 60.0),
      TouchPoint(clientX: 10.0, clientY: 20.0)])

    check handleTwoFingerTap(initInputState(), forward).blastX ==
      handleTwoFingerTap(initInputState(), reversed).blastX
    check handleTwoFingerTap(initInputState(), forward).blastY ==
      handleTwoFingerTap(initInputState(), reversed).blastY

  test "two fingers clear the press the first finger registered":
    # Without this the state is stranded as held after the fingers lift, the
    # same failure handleDoubleClick guards against on the mouse path.
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 100.0, clientY: 100.0),
      TouchPoint(clientX: 200.0, clientY: 200.0)])
    let state = handleTwoFingerTap(
      initInputState().withMouseDown(true), event)

    check state.mouseDown == false

  test "a single finger is not a blast":
    let event = TouchEventData(touches: @[
      TouchPoint(clientX: 100.0, clientY: 100.0)])
    let state = handleTwoFingerTap(initInputState(), event)

    check state.blastStrength == 0.0

  test "no touches at all leaves the state untouched":
    let before = initInputState().withMouseDown(true)
    check handleTwoFingerTap(before, TouchEventData(touches: @[])) == before

suite "The Binding Table Is The Single Declaration":
  test "every binding carries a non-empty description":
    for binding in InputBindings:
      if binding.description.len == 0:
        checkpoint(binding.gesture & " has no description")
      check binding.description.len > 0

  test "no two bindings claim the same key":
    var claimed = initHashSet[string]()
    for binding in InputBindings:
      for key in binding.keys:
        if key in claimed:
          checkpoint("key \"" & key & "\" is claimed twice")
        check key notin claimed
        claimed.incl key

  test "every camera-key row dispatches through cameraKeyFor":
    const OnCanvas = KeyContext(modified: false, intoTextEntry: false)
    var dispatched = 0
    for binding in InputBindings:
      if binding.action != ckNone:
        check binding.keys.len > 0
        for key in binding.keys:
          check cameraKeyFor(key, OnCanvas) == binding.action
          inc dispatched
    # NON-VACUITY: the table must actually carry camera rows for this to mean
    # anything. Emptying InputBindings would otherwise leave it green.
    check dispatched > 0

  test "a key outside the table maps to no action":
    const OnCanvas = KeyContext(modified: false, intoTextEntry: false)
    check cameraKeyFor("F13", OnCanvas) == ckNone
