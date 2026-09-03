extends Control
## Android touch controls plus the run readout.
##
## Two thumb zones, split down the middle of the screen, both "touch anywhere"
## rather than fixed widgets -- which is what makes this playable on glass: you
## never have to find a control, the control appears under your thumb.
##
##   left  -- a full analog stick. Push it where you want to go on screen and the
##            skater carves that way; pull it back and you brake. It is resolved
##            in camera space by `Controls`, so it stays intuitive however the
##            view has swung round.
##   right -- the pop pad. Hold to load an ollie, release to pop, and flick left
##            or right on release to turn the pop into a flip trick.
##
## Both zones track by touch index, so two thumbs work independently. Pointer
## emulation is off in the project settings for the same reason: Godot's
## touch/mouse emulation only mirrors the first finger, which used to make the
## stick stop responding as soon as a second thumb went down.

## Full deflection distance from wherever the thumb landed.
@export var stick_radius := 130.0
## Horizontal flick distance (px) on release that turns a pop into a flip trick.
@export var flick_distance := 64.0
## Zones are generous: the stick claims the whole left half, the pad the right.
@export_range(0.2, 0.8) var split := 0.5

@onready var _speed_label: Label = $Readout/Speed
@onready var _score_label: Label = $Readout/Score
@onready var _trick_label: Label = $TrickPopup
@onready var _hint_label: Label = $Hint
@onready var _reset_button: Button = $ResetButton

var _skater: SkaterController

var _stick_touch := -1
var _stick_origin := Vector2.ZERO
var _stick_point := Vector2.ZERO

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
	_reset_button.pressed.connect(func(): Controls.touch_respawn = true)
	_trick_label.modulate.a = 0.0
	if not DisplayServer.is_touchscreen_available():
		_hint_label.text = "WASD ride/brake · SPACE hold-release ollie · J kickflip · K shuvit · R reset"

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_press(event.index, event.position, event.pressed)
	elif event is InputEventScreenDrag:
		_handle_move(event.index, event.position)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_handle_press(-1000, event.position, event.pressed)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_handle_move(-1000, event.position)

func _handle_press(index: int, pos: Vector2, pressed: bool) -> void:
	if pressed:
		if _reset_button.get_global_rect().has_point(pos):
			return
		if pos.x < size.x * split:
			if _stick_touch == -1:
				_stick_touch = index
				_stick_origin = pos
				_stick_point = pos
		elif _pop_touch == -1:
			_pop_touch = index
			_pop_origin = pos
			_pop_point = pos
			Controls.touch_ollie = true
		queue_redraw()
		return

	if index == _stick_touch:
		_stick_touch = -1
		Controls.touch_move = Vector2.ZERO
	elif index == _pop_touch:
		_release_pop()
	queue_redraw()

func _handle_move(index: int, pos: Vector2) -> void:
	if index == _stick_touch:
		_stick_point = pos
		var delta := pos - _stick_origin
		# Screen-down is +y, and forward on the stick is up, so y is inverted.
		var stick := Vector2(delta.x, -delta.y) / stick_radius
		Controls.touch_move = stick.limit_length(1.0)
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

## A finger lifting outside the window, or the app losing focus, can drop the
## release event. Re-centre anything whose finger has gone.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_stick_touch = -1
		_pop_touch = -1
		Controls.clear_all()
		queue_redraw()

func _process(delta: float) -> void:
	if _skater:
		_speed_label.text = "%.1f m/s" % _skater.speed
		_score_label.text = "%d pts" % Game.score
	if _popup_timer > 0.0:
		_popup_timer -= delta
		_trick_label.modulate.a = clampf(_popup_timer / 0.5, 0.0, 1.0)

func _draw() -> void:
	if _stick_touch != -1:
		_draw_stick()
	if _pop_touch != -1:
		_draw_pop_pad()

func _draw_stick() -> void:
	var offset := (_stick_point - _stick_origin).limit_length(stick_radius)
	draw_circle(_stick_origin, stick_radius, Color(1, 1, 1, 0.07))
	draw_arc(_stick_origin, stick_radius, 0.0, TAU, 56, Color(1, 1, 1, 0.3), 3.0, true)
	draw_line(_stick_origin, _stick_origin + offset, Color(1, 1, 1, 0.25), 4.0, true)
	draw_circle(_stick_origin + offset, stick_radius * 0.34, Color(1, 1, 1, 0.6))

func _draw_pop_pad() -> void:
	var charge := _skater.crouch if _skater else 0.0
	draw_arc(_pop_origin, 86.0, 0.0, TAU, 56, Color(1, 1, 1, 0.22), 3.0, true)
	# Filling ring shows how much ollie you have loaded up.
	draw_arc(_pop_origin, 86.0, -PI * 0.5, -PI * 0.5 + TAU * charge, 56,
		Color(1.0, 0.82, 0.3, 0.95), 6.0, true)
	var delta := _pop_point - _pop_origin
	var flick := Color(1, 1, 1, 0.28)
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
