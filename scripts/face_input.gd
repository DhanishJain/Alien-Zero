extends Node
## Face-control receiver. tools/face_control.py reads the webcam and streams the state of six
## booleans over UDP (127.0.0.1:4242). This node mirrors them onto the SAME input actions as the keyboard,
## so the game rules do not change:
##   head up / down    -> "up" / "down"      (arrow keys)
##   head turn l / r   -> "left" / "right"   (arrow keys)
##   mouth open        -> "stun"             (Z)
##   eyes closed/blink -> "interact"         (SPACE)
## Keyboard keeps working. If packets stop for TIMEOUT seconds every face-held action is released.

const PORT := 4242
const TIMEOUT := 0.6
const ACTIONS := ["left", "right", "up", "down", "stun", "interact"]

var udp := PacketPeerUDP.new()
var listening := false
var connected := false
var last_packet := -100.0
var held := {}


func _ready() -> void:
	for a in ACTIONS:
		held[a] = false
	var err := udp.bind(PORT, "127.0.0.1")
	listening = err == OK
	if not listening:
		push_warning("Face control: could not bind UDP port %d (is another game instance running?)" % PORT)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if listening:
		while udp.get_available_packet_count() > 0:
			var text := udp.get_packet().get_string_from_utf8()
			var data = JSON.parse_string(text)
			if data is Dictionary:
				last_packet = now
				for a in ACTIONS:
					_apply(a, bool(data.get(a, false)))
	connected = (now - last_packet) < TIMEOUT
	if not connected:
		release_all()


func _apply(action: String, value: bool) -> void:
	if held[action] == value:
		return
	held[action] = value
	if value:
		Input.action_press(action)
	else:
		Input.action_release(action)


func release_all() -> void:
	for a in ACTIONS:
		_apply(a, false)


func status_text() -> String:
	if not listening:
		return "FACE CONTROL: port busy"
	if connected:
		return "FACE CONTROL: ON"
	return "FACE CONTROL: waiting for tools/face_control.py"
