#
# The single declaration of every mouse gesture, touch gesture, and key
# binding. The key handler derives its dispatch from the key rows, and help
# renders every row, so a binding cannot exist without appearing in help.
# Mouse, wheel, and touch rows describe the listeners canvas_input wires —
# held to them by review, since a DOM listener is not data.

type
  CameraKey* = enum
    ## The camera actions keys can name. Anything else maps to ckNone and
    ## leaves the camera alone.
    ckNone
    ckPanLeft
    ckPanRight
    ckPanUp
    ckPanDown
    ckZoomIn
    ckZoomOut
    ckReset

  BindingDevice* = enum
    bdMouse = "Mouse"
    bdWheel = "Wheel & trackpad"
    bdTouch = "Touch"
    bdKey = "Keys"

  InputBinding* = object
    device*: BindingDevice
    gesture*: string     ## What the user does, as help shows it.
    keys*: seq[string]   ## DOM key values this row claims; key rows only.
    action*: CameraKey   ## ckNone where the row is not a camera key.
    description*: string

const InputBindings* = [
  InputBinding(device: bdMouse, gesture: "Left press / drag",
    description: "attract particles toward the cursor"),
  InputBinding(device: bdMouse, gesture: "Right press / drag",
    description: "repel particles from the cursor"),
  InputBinding(device: bdMouse, gesture: "Double-click",
    description: "fire a blast at the cursor"),
  InputBinding(device: bdMouse, gesture: "Middle-button drag",
    description: "pan the camera"),
  InputBinding(device: bdWheel, gesture: "Scroll",
    description: "pan the view"),
  InputBinding(device: bdWheel, gesture: "Pinch, or scroll with Ctrl/Cmd",
    description: "zoom at the cursor"),
  InputBinding(device: bdTouch, gesture: "One finger press / drag",
    description: "attract particles, as the left button does"),
  InputBinding(device: bdTouch, gesture: "Two-finger tap",
    description: "fire a blast at the fingers' midpoint"),
  InputBinding(device: bdKey, gesture: "←",
    keys: @["ArrowLeft"], action: ckPanLeft,
    description: "pan left a tenth of the view"),
  InputBinding(device: bdKey, gesture: "→",
    keys: @["ArrowRight"], action: ckPanRight,
    description: "pan right a tenth of the view"),
  InputBinding(device: bdKey, gesture: "↑",
    keys: @["ArrowUp"], action: ckPanUp,
    description: "pan up a tenth of the view"),
  InputBinding(device: bdKey, gesture: "↓",
    keys: @["ArrowDown"], action: ckPanDown,
    description: "pan down a tenth of the view"),
  InputBinding(device: bdKey, gesture: "+",
    keys: @["+", "="], action: ckZoomIn,
    description: "zoom in, anchored at the view centre"),
  InputBinding(device: bdKey, gesture: "-",
    keys: @["-", "_"], action: ckZoomOut,
    description: "zoom out, anchored at the view centre"),
  InputBinding(device: bdKey, gesture: "0",
    keys: @["0"], action: ckReset,
    description: "reframe the whole world"),
  InputBinding(device: bdKey, gesture: "?",
    keys: @["?"],
    description: "open this help"),
  InputBinding(device: bdKey, gesture: "Esc",
    keys: @["Escape"],
    description: "close this help"),
]
