class_name GrindSystem
extends Node
## Locks the skater onto a rail or ledge and slides them along it.
##
## While grinding the skater is driven along the curve directly instead of by
## `move_and_slide`, which is what keeps a 50-50 from chattering off the bar.

@export var snap_radius := 0.55
## The skater has to be travelling roughly along the bar, not across it.
@export_range(0.0, 1.0) var alignment_threshold := 0.55
## Board sits this far above the curve while grinding.
@export var grind_height := 0.09
@export var grind_friction := 1.6
@export var min_grind_speed := 1.4
@export var pop_out_impulse := 5.4
## Stops the skater re-latching onto the bar they just popped off.
@export var relatch_cooldown := 0.35

@onready var _skater: SkaterController = get_parent()

var rail: Rail = null
var offset := 0.0
var along_speed := 0.0

var _cooldown := 0.0

func _physics_process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)

func is_grinding() -> bool:
	return rail != null

## Looks for a rail worth latching onto. Returns true if we entered a grind.
func try_enter_grind() -> bool:
	if rail != null or _cooldown > 0.0:
		return false
	var horiz := Vector3(_skater.velocity.x, 0.0, _skater.velocity.z)
	if horiz.length() < min_grind_speed:
		return false

	var best: Rail = null
	var best_q := {}
	for node in _skater.get_tree().get_nodes_in_group(&"rails"):
		var r := node as Rail
		if r == null or r.curve == null or r.curve.point_count < 2:
			continue
		var q := r.query(_skater.global_position)
		if q["distance"] > snap_radius:
			continue
		# Only latch coming down onto the bar, never clipping it from below.
		if _skater.global_position.y < (q["position"] as Vector3).y - 0.12:
			continue
		var tangent: Vector3 = q["tangent"]
		if absf(horiz.normalized().dot(Vector3(tangent.x, 0.0, tangent.z).normalized())) < alignment_threshold:
			continue
		if best == null or q["distance"] < best_q["distance"]:
			best = r
			best_q = q
	if best == null:
		return false
	_enter(best, best_q)
	return true

func _enter(r: Rail, q: Dictionary) -> void:
	rail = r
	offset = q["offset"]
	var tangent: Vector3 = q["tangent"]
	along_speed = _skater.velocity.dot(tangent)
	# Grind in whatever direction we were already going.
	_skater.state = SkaterController.State.GRIND
	_skater.trick_system.abort()
	_skater.global_position = (q["position"] as Vector3) + Vector3.UP * grind_height
	_skater.velocity = tangent * along_speed
	_skater.ground_normal = Vector3.UP
	_align_heading(tangent)
	_skater.state_changed.emit(_skater.state)

func process_grind(delta: float) -> void:
	if rail == null:
		_skater.state = SkaterController.State.AIR
		return

	# Gravity still nudges you along a sloped rail.
	var tangent := rail.tangent_at(offset)
	along_speed += -tangent.y * _skater.gravity * delta
	along_speed = move_toward(along_speed, 0.0, grind_friction * delta)

	if Controls.ollie_held:
		_skater.crouch = minf(1.0, _skater.crouch + delta / _skater.ollie_charge_time)
	else:
		_skater.crouch = maxf(0.0, _skater.crouch - delta * 5.0)

	if Controls.ollie_just_released:
		_pop_off(tangent)
		return

	var queued := Controls.consume_trick()
	if queued != "":
		_pop_off(tangent)
		_skater.trick_system.request(queued)
		return

	offset += along_speed * delta
	var rail_len := rail.length()
	if offset < 0.0 or offset > rail_len or absf(along_speed) < min_grind_speed * 0.5:
		_exit_to_air(tangent)
		return

	_skater.global_position = rail.point_at(offset) + Vector3.UP * grind_height
	_skater.velocity = tangent * along_speed
	_align_heading(tangent)

func _align_heading(tangent: Vector3) -> void:
	var dir := tangent if along_speed >= 0.0 else -tangent
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() > 0.0001:
		flat = flat.normalized()
		_skater.heading = atan2(-flat.x, -flat.z)

func _pop_off(tangent: Vector3) -> void:
	var power := lerpf(_skater.ollie_min_impulse, _skater.ollie_max_impulse, _skater.crouch)
	_skater.velocity = tangent * along_speed + Vector3.UP * maxf(power, pop_out_impulse)
	_skater.crouch = 0.0
	exit_grind()
	_skater.state = SkaterController.State.AIR
	_skater.state_changed.emit(_skater.state)

func _exit_to_air(tangent: Vector3) -> void:
	_skater.velocity = tangent * along_speed
	exit_grind()
	_skater.state = SkaterController.State.AIR
	_skater.state_changed.emit(_skater.state)

func exit_grind() -> void:
	if rail != null:
		_cooldown = relatch_cooldown
	rail = null
	along_speed = 0.0
	offset = 0.0
