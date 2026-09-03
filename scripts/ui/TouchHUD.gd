extends Control
## Android touch controls plus the run readout.
##
## Two zones, both "touch anywhere" rather than fixed buttons, which is what
## makes a skating game playable on glass: the left half is a steering stick
## that appears wherever your thumb lands, the right half is the pop pad. The
## pad doubles as the trick selector -- hold to load the ollie, then flick the
## direction of the trick as you let go, the way a real flick works.

@export var stick_radius := 110.0
@export var stick_deadzone := 0.12
## Downward drag past this fraction of the stick radius engages the brake.
@export var brake_threshold := 0.55
## Horizontal flick distance (px) that turns a pop into a flip trick.
@export var flick_distance := 60.0

@onready var _speed_label: Label = $Readout/Speed
@onready var _score_label: Label = $Readout/Score
@onready var _trick_label: Label = $TrickPopup
@onready var _hint_label: Label = $Hint
@onready var _push_button: Button = $PushButton
@onready var _reset_button: Button = $ResetButton

var _skater: SkaterController

var _steer_touch := -1
var _steer_origin := Vector2.ZERO
var _steer_point := Vector2.ZERO

var _pop_touch := -1
var _pop_origin := Vector2.ZERO
var _pop_point := Vector2.ZERO

var _popup_timer := 0.0

func setup(skater: SkaterController) -> void:
	_skater = skater
	_skater.trick_landed.connect(_on_trick_landed)
	_skater.bailed.connect(_on_bailed)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_push_button.button_down.connect(func(): Controls.touch_push = true)
	_push_button.button_up.connect(func(): Controls.touch_push = false)
	_reset_button.pressed.connect(func(): Controls.touch_respawn = true)
	_trick_label.modulate.a = 0.0
	# Mouse drags emulate touch so the same code path works on desktop.
	if not DisplayServer.is_touchscreen_available():
		_hint_label.text = "WASD steer/push  ·  SPACE hold-release ollie  ·  J kickflip  ·  K shuvit  ·  R reset"

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag:
		_handle_drag(event.index, event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_touch(-2, event.position, event.pressed)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_handle_drag(-2, event.position)

func _handle_touch(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		if _over_button(pos):
			return
		if pos.x < size.x * 0.5:
			if _steer_touch == -1:
				_steer_touch = index
				_steer_origin = pos
				_steer_point = pos
		else:
			if _pop_touch == -1:
				_pop_touch = index
				_pop_origin = pos
				_pop_point = pos
				Controls.touch_ollie = true
		queue_redraw()
		return

	if index == _steer_touch:
		_steer_touch = -1
		Controls.touch_steer = 0.0
		Controls.touch_brake = false
	elif index == _pop_touch:
		_release_pop()
	queue_redraw()

func _handle_drag(index: int, pos: Vector2) -> void:
	if index == _steer_touch:
		_steer_point = pos
		var delta := pos - _steer_origin
		var steer := delta.x / stick_radius
		if absf(steer) < stick_deadzone:
			steer = 0.0
		Controls.touch_steer = clampf(steer, -1.0, 1.0)
		Controls.touch_brake = delta.y > stick_radius * brake_threshold
		queue_redraw()
	elif index == _pop_touch:
		_pop_point = pos
		queue_redraw()

## The direction of the flick on release picks the trick.
func _release_pop() -> void:
	var delta := _pop_point - _pop_origin
	if delta.x < -flick_distance:
		Controls.touch_trick = "kickflip"
	elif delta.x > flick_distance:
		Controls.touch_trick = "shuvit"
	_pop_touch = -1
	Controls.touch_ollie = false

func _over_button(pos: Vector2) -> bool:
	return _push_button.get_global_rect().has_point(pos) \
		or _reset_button.get_global_rect().has_point(pos)

func _process(delta: float) -> void:
	if _skater:
		_speed_label.text = "%.1f m/s" % _skater.speed
		_score_label.text = "%d pts" % Game.score
	if _popup_timer > 0.0:
		_popup_timer -= delta
		_trick_label.modulate.a = clampf(_popup_timer / 0.5, 0.0, 1.0)

func _draw() -> void:
	if _steer_touch != -1:
		_draw_stick()
	if _pop_touch != -1:
		_draw_pop_pad()

func _draw_stick() -> void:
	var knob := _steer_origin + Vector2(clampf(_steer_point.x - _steer_origin.x,
		-stick_radius, stick_radius), 0.0)
	draw_circle(_steer_origin, stick_radius, Color(1, 1, 1, 0.08))
	draw_arc(_steer_origin, stick_radius, 0.0, TAU, 48, Color(1, 1, 1, 0.35), 3.0, true)
	draw_circle(knob, stick_radius * 0.38, Color(1, 1, 1, 0.55))

func _draw_pop_pad() -> void:
	var charge := _skater.crouch if _skater else 0.0
	draw_arc(_pop_origin, 78.0, 0.0, TAU, 48, Color(1, 1, 1, 0.25), 3.0, true)
	# Filling ring shows how much ollie you have loaded up.
	draw_arc(_pop_origin, 78.0, -PI * 0.5, -PI * 0.5 + TAU * charge, 48,
		Color(1.0, 0.82, 0.3, 0.95), 6.0, true)
	var delta := _pop_point - _pop_origin
	var flick := Color(1, 1, 1, 0.3)
	if delta.x < -flick_distance:
		flick = Color(0.45, 0.85, 1.0, 0.9)
	elif delta.x > flick_distance:
		flick = Color(1.0, 0.55, 0.45, 0.9)
	draw_line(_pop_origin, _pop_origin + Vector2(delta.x, 0.0), flick, 5.0, true)

func _on_trick_landed(trick_name: String, points: int) -> void:
	_trick_label.text = "%s  +%d" % [trick_name.to_upper(), points]
	_trick_label.modulate = Color(1.0, 0.86, 0.35, 1.0)
	_popup_timer = 1.6

func _on_bailed(reason: String) -> void:
	_trick_label.text = "BAIL — %s" % reason
	_trick_label.modulate = Color(1.0, 0.45, 0.4, 1.0)
	_popup_timer = 1.6
