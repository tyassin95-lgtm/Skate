extends Node
## Autoload that merges keyboard/gamepad input with the on-screen Android touch
## controls into one struct the skater reads. Anything that wants to drive the
## skater (touch HUD, a replay, a tutorial) writes to the `touch_*` fields.

# --- written by the touch HUD -------------------------------------------------
var touch_steer := 0.0        # -1 (left) .. 1 (right)
var touch_push := false       # push pad held
var touch_brake := false
var touch_ollie := false      # ollie/crouch pad held
var touch_trick := ""         # one-shot trick request, consumed by the skater
var touch_respawn := false

# --- resolved state read by the skater ---------------------------------------
var steer := 0.0
var push := false
var brake := false
var ollie_held := false
var ollie_just_pressed := false
var ollie_just_released := false
var respawn_pressed := false

var _trick_request := ""
var _prev_ollie := false

## Runs in the physics step so one-shot edges line up exactly with the tick the
## skater reads them on -- polling these from _process drops or repeats inputs
## whenever the render and physics rates disagree.
func _physics_process(_delta: float) -> void:
	var key_steer := Input.get_axis(&"steer_left", &"steer_right")
	steer = clampf(key_steer + touch_steer, -1.0, 1.0)

	push = Input.is_action_pressed(&"push") or touch_push

	brake = Input.is_action_pressed(&"brake") or touch_brake

	ollie_held = Input.is_action_pressed(&"ollie") or touch_ollie
	ollie_just_pressed = ollie_held and not _prev_ollie
	ollie_just_released = _prev_ollie and not ollie_held
	_prev_ollie = ollie_held

	respawn_pressed = Input.is_action_just_pressed(&"respawn") or touch_respawn
	touch_respawn = false

	if touch_trick != "":
		_trick_request = touch_trick
		touch_trick = ""
	elif Input.is_action_just_pressed(&"trick_kickflip"):
		_trick_request = "kickflip"
	elif Input.is_action_just_pressed(&"trick_shuvit"):
		_trick_request = "shuvit"

## Returns and clears any pending trick request.
func consume_trick() -> String:
	var t := _trick_request
	_trick_request = ""
	return t

func clear_trick() -> void:
	_trick_request = ""
