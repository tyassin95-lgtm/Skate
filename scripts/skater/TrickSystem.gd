class_name TrickSystem
extends Node
## Drives the board's own rotation during a trick and decides whether a landing
## was clean.
##
## The board model spins independently of the board pivot: the pivot tracks the
## skater's heading and the surface, the model adds the flip on top. A trick is
## "caught" only once its rotation has come back around to level, so landing
## early is a bail -- which is what makes tricks feel like they have weight.

const TRICKS := {
	"ollie":    {"duration": 0.30, "flip": 0.0,   "shuv": 0.0,   "points": 50},
	"kickflip": {"duration": 0.44, "flip": TAU,   "shuv": 0.0,   "points": 150},
	"shuvit":   {"duration": 0.52, "flip": 0.0,   "shuv": TAU,   "points": 200},
}

## A trick this close to finished still counts; the rest is snapped away.
@export_range(0.5, 1.0) var catch_tolerance := 0.86
## Extra pitch (nose-up) while popping, in radians.
@export var pop_pitch := 0.30

@onready var _skater: SkaterController = get_parent()

var board_model: Node3D
var active_trick := ""
var combo: Array[String] = []
var combo_points := 0

var _elapsed := 0.0
var _duration := 0.0
var _flip := 0.0
var _shuv := 0.0

func _ready() -> void:
	board_model = _skater.get_node_or_null(^"BoardPivot/BoardModel")

func request(trick_name: String) -> void:
	if not TRICKS.has(trick_name):
		return
	if active_trick != "":
		return  # one at a time; the queued input is simply dropped
	var t: Dictionary = TRICKS[trick_name]
	active_trick = trick_name
	_elapsed = 0.0
	_duration = t["duration"]
	_flip = t["flip"]
	_shuv = t["shuv"]
	_skater.trick_started.emit(trick_name)

func _process(delta: float) -> void:
	if board_model == null:
		return
	if active_trick == "":
		_settle(delta)
		return

	_elapsed += delta
	var p := clampf(_elapsed / _duration, 0.0, 1.0)
	# Ease the spin so the board whips through the middle and lands softly.
	var eased := _ease_spin(p)
	board_model.rotation = Vector3(_pop_pitch_now(), _shuv * eased, _flip * eased)

	if p >= 1.0:
		_complete()

## Slightly front-loaded easing: quick snap off the foot, gentler catch.
func _ease_spin(p: float) -> float:
	return 1.0 - pow(1.0 - p, 1.85)

func _pop_pitch_now() -> float:
	if _skater.state != SkaterController.State.AIR:
		return 0.0
	# Nose up on the way up, nose down coming back in.
	return clampf(_skater.velocity.y / 6.0, -1.0, 1.0) * pop_pitch

func _settle(delta: float) -> void:
	var target := Vector3(_pop_pitch_now(), 0.0, 0.0)
	board_model.rotation = board_model.rotation.lerp(target, clampf(delta * 12.0, 0.0, 1.0))

func _complete() -> void:
	var t: Dictionary = TRICKS[active_trick]
	combo.append(active_trick)
	combo_points += int(t["points"])
	board_model.rotation = Vector3(_pop_pitch_now(), 0.0, 0.0)
	active_trick = ""
	_elapsed = 0.0

## True when the skater may touch down without eating it.
func can_land() -> bool:
	if active_trick == "":
		return true
	return (_elapsed / _duration) >= catch_tolerance

func finish_landing() -> void:
	if active_trick != "":
		# Landed inside the tolerance window -- credit it and snap level.
		_complete()
	if combo.is_empty():
		return
	var multiplier := 1.0 + 0.5 * float(combo.size() - 1)
	var points := int(round(float(combo_points) * multiplier))
	var label := " + ".join(combo)
	_skater.trick_landed.emit(label, points)
	Game.award(label, points)
	_reset_combo()

func abort() -> void:
	active_trick = ""
	_elapsed = 0.0
	if board_model:
		board_model.rotation = Vector3.ZERO
	_reset_combo()

func _reset_combo() -> void:
	combo.clear()
	combo_points = 0
