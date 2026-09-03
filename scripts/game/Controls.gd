extends Node
## Autoload that merges the on-screen touch stick with keyboard input into one
## analog control state, and resolves it into a world direction.
##
## Everything that steers the skater goes through here, so the touch HUD, the
## keyboard and the tests all drive exactly the same code path.
##
## Stick convention: `move.x` is right, `move.y` is away from the camera. The
## stick is resolved in *camera* space -- push the stick where you want to go on
## screen and the skater carves toward it -- which is only coherent because the
## camera publishes its own yaw here every frame.

## Stick travel below this is treated as centred.
const DEADZONE := 0.16

# --- written by the touch HUD -------------------------------------------------
var touch_move := Vector2.ZERO
var touch_ollie := false
var touch_trick := ""
var touch_respawn := false

# --- written by the follow camera --------------------------------------------
## World yaw of the camera, so stick input can be resolved relative to the view.
var camera_yaw := 0.0

# --- resolved state read by the skater ---------------------------------------
var move := Vector2.ZERO        ## merged stick, already dead-zoned, |move| <= 1
var world_move := Vector3.ZERO  ## same thing as a direction on the ground plane
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
	var keys := Vector2(
		Input.get_axis(&"steer_left", &"steer_right"),
		Input.get_axis(&"brake", &"push"))
	move = (keys + touch_move).limit_length(1.0)
	if move.length() < DEADZONE:
		move = Vector2.ZERO
	else:
		# Rescale so the stick still reaches full deflection past the deadzone.
		move = move.normalized() * inverse_lerp(DEADZONE, 1.0, minf(move.length(), 1.0))

	var view := Basis(Vector3.UP, camera_yaw)
	world_move = view * Vector3(move.x, 0.0, -move.y)

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

func clear_all() -> void:
	touch_move = Vector2.ZERO
	touch_ollie = false
	touch_trick = ""
	touch_respawn = false
	move = Vector2.ZERO
	world_move = Vector3.ZERO
	_trick_request = ""
