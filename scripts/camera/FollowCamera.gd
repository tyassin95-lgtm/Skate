class_name FollowCamera
extends Node3D
## Third-person chase camera.
##
## It follows the skater's *position* closely but its *yaw* only eases toward the
## direction of travel, so spins and quick carves read as the skater rotating
## rather than the world whipping around. Height, distance and FOV all open up
## with speed and in the air to keep the landing in frame.

@export var target_path: NodePath
@export_group("Framing")
@export var distance := 5.0
@export var air_distance := 6.4
@export var height := 1.9
@export var look_height := 1.1
@export_group("Response")
@export var position_smooth := 9.0
@export var yaw_smooth := 4.5
@export var air_yaw_smooth := 1.6
@export var distance_smooth := 3.0
@export_group("Feel")
@export var base_fov := 68.0
@export var speed_fov := 16.0
@export var fov_speed_ref := 20.0
## Keeps the camera from clipping through ramps and walls.
@export var collision_padding := 0.35

@onready var _camera: Camera3D = $Camera3D

var _skater: SkaterController
var _yaw := 0.0
var _follow_pos := Vector3.ZERO
var _distance := 5.0
var _fov := 68.0

func _ready() -> void:
	_skater = get_node_or_null(target_path) as SkaterController
	_distance = distance
	_fov = base_fov
	if _skater:
		_follow_pos = _skater.global_position
		_yaw = _skater.heading
	top_level = true

func _physics_process(delta: float) -> void:
	if _skater == null:
		return

	_follow_pos = _follow_pos.lerp(_skater.global_position,
		clampf(delta * position_smooth, 0.0, 1.0))

	# Chase the direction of travel once actually moving; below that keep the
	# last yaw so the camera doesn't spin when the skater is standing still.
	var horiz := Vector3(_skater.velocity.x, 0.0, _skater.velocity.z)
	var want_yaw := _yaw
	if horiz.length() > 1.2:
		want_yaw = atan2(-horiz.x, -horiz.z)
	elif _skater.state == SkaterController.State.ROLL:
		want_yaw = _skater.heading

	var yaw_rate := air_yaw_smooth if _skater.state == SkaterController.State.AIR else yaw_smooth
	_yaw = _lerp_angle(_yaw, want_yaw, clampf(delta * yaw_rate, 0.0, 1.0))

	var want_distance := air_distance if _skater.state == SkaterController.State.AIR else distance
	_distance = lerpf(_distance, want_distance, clampf(delta * distance_smooth, 0.0, 1.0))

	var back := Basis(Vector3.UP, _yaw) * Vector3.BACK
	var pivot := _follow_pos + Vector3.UP * height
	var wanted := pivot + back * _distance

	global_position = _avoid_geometry(pivot, wanted)
	look_at(_follow_pos + Vector3.UP * look_height, Vector3.UP)

	var target_fov := base_fov + speed_fov * clampf(_skater.speed / fov_speed_ref, 0.0, 1.0)
	_fov = lerpf(_fov, target_fov, clampf(delta * 4.0, 0.0, 1.0))
	_camera.fov = _fov

## Pulls the camera in if a ramp or wall would come between it and the skater.
func _avoid_geometry(pivot: Vector3, wanted: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(pivot, wanted)
	query.collision_mask = 1
	query.exclude = [_skater.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return wanted
	var point: Vector3 = hit["position"]
	return point + (pivot - point).normalized() * collision_padding

func _lerp_angle(from_angle: float, to_angle: float, weight: float) -> float:
	return from_angle + wrapf(to_angle - from_angle, -PI, PI) * weight
