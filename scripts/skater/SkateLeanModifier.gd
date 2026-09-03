class_name SkateLeanModifier
extends SkeletonModifier3D
## Additive skating pose layered on top of whatever clip is playing.
##
## The animation library is a generic humanoid set with no skate clips, so this
## modifier supplies the parts that make the body read as a skater: knees bent
## into the ride, the torso counter-rotated over the board, arms out for
## balance, and a carve lean that tracks the actual steering input. Because it
## multiplies into the animated pose rather than replacing it, the underlying
## clip still breathes through.

const BONES := {
	"pelvis": "pelvis",
	"spine1": "spine_01",
	"spine2": "spine_02",
	"spine3": "spine_03",
	"head":   "Head",
	"thigh_l": "thigh_l", "calf_l": "calf_l", "foot_l": "foot_l",
	"thigh_r": "thigh_r", "calf_r": "calf_r", "foot_r": "foot_r",
	"arm_l": "upperarm_l", "forearm_l": "lowerarm_l",
	"arm_r": "upperarm_r", "forearm_r": "lowerarm_r",
}

## Feet sit across the board, one over each truck. The legs swing apart in the
## character's coronal plane, which -- because the skater stands side-on -- is
## along the length of the deck. Radians.
@export var stance_spread := 0.24
## Front foot angled out toward the nose, the way a real stance sits.
@export var stance_toe_out := 0.2
## Knees are never locked on a board, so there is a floor under the crouch.
@export_range(0.0, 1.0) var base_crouch := 0.55
## How far the knees bend at full crouch, radians.
@export var crouch_knee := 0.85
@export var crouch_hip := 0.3
## Torso roll into a carve at full lock, radians.
@export var carve_lean := 0.30
## Torso twist that keeps the shoulders squarer to the direction of travel.
@export var shoulder_counter := 0.26
## How far the arms come up when airborne or grinding.
@export var balance_arms := 0.85
@export var response := 9.0

var skater: SkaterController

var _idx := {}
var _crouch := 0.0
var _lean := 0.0
var _air := 0.0
var _speed := 0.0

func _ready() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	for key in BONES:
		_idx[key] = skel.find_bone(BONES[key])

func _process(delta: float) -> void:
	if skater == null:
		return
	var t := clampf(delta * response, 0.0, 1.0)
	# Riders sit low; the crouch input and speed both push them lower.
	var speed_crouch := clampf(skater.speed / 14.0, 0.0, 1.0) * 0.45
	var want_crouch := clampf(base_crouch + skater.crouch + speed_crouch, 0.0, 1.0)
	if skater.state == SkaterController.State.AIR:
		want_crouch = maxf(want_crouch, 0.55)
	if skater.state == SkaterController.State.BAIL:
		want_crouch = 0.0
	_crouch = lerpf(_crouch, want_crouch, t)

	var want_lean := Controls.steer * clampf(skater.speed / 9.0, 0.0, 1.0)
	_lean = lerpf(_lean, want_lean, t)

	var want_air := 1.0 if skater.state in [SkaterController.State.AIR, SkaterController.State.GRIND] else 0.0
	_air = lerpf(_air, want_air, t)
	_speed = lerpf(_speed, clampf(skater.speed / 16.0, 0.0, 1.0), t)

func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or _idx.is_empty():
		return

	# Spread first (about the limb's side axis), then flex.
	_add(skel, "thigh_l", Quaternion(Vector3.BACK, stance_spread)
		* Quaternion(Vector3.RIGHT, -crouch_knee * 0.55 * _crouch))
	_add(skel, "thigh_r", Quaternion(Vector3.BACK, -stance_spread)
		* Quaternion(Vector3.RIGHT, -crouch_knee * 0.55 * _crouch))
	_add(skel, "calf_l", Quaternion(Vector3.RIGHT, crouch_knee * _crouch))
	_add(skel, "calf_r", Quaternion(Vector3.RIGHT, crouch_knee * _crouch))
	# Turn the feet back level with the deck instead of following the leg swing.
	_add(skel, "foot_l", Quaternion(Vector3.BACK, -stance_spread + stance_toe_out))
	_add(skel, "foot_r", Quaternion(Vector3.BACK, stance_spread - stance_toe_out))

	# Fold at the hips so the crouch doesn't just sink straight down.
	_add(skel, "pelvis", Quaternion(Vector3.RIGHT, crouch_hip * _crouch)
		* Quaternion(Vector3.FORWARD, carve_lean * _lean * 0.4))

	var spine_lean := Quaternion(Vector3.FORWARD, carve_lean * _lean * 0.35)
	var spine_twist := Quaternion(Vector3.UP, shoulder_counter * _speed * 0.5)
	_add(skel, "spine1", spine_lean * Quaternion(Vector3.RIGHT, crouch_hip * 0.35 * _crouch))
	_add(skel, "spine2", spine_lean * spine_twist)
	_add(skel, "spine3", spine_lean * spine_twist)
	# The head keeps looking down the line rather than following the twist.
	_add(skel, "head", Quaternion(Vector3.UP, -shoulder_counter * _speed * 0.8))

	var arm_out := balance_arms * maxf(_air, _speed * 0.45)
	_add(skel, "arm_l", Quaternion(Vector3.FORWARD, -arm_out))
	_add(skel, "arm_r", Quaternion(Vector3.FORWARD, arm_out))
	_add(skel, "forearm_l", Quaternion(Vector3.RIGHT, -arm_out * 0.4))
	_add(skel, "forearm_r", Quaternion(Vector3.RIGHT, -arm_out * 0.4))

## Multiplies an offset into the bone's animated pose instead of overwriting it.
func _add(skel: Skeleton3D, key: String, offset: Quaternion) -> void:
	var bone: int = _idx.get(key, -1)
	if bone < 0:
		return
	skel.set_bone_pose_rotation(bone, skel.get_bone_pose_rotation(bone) * offset)
