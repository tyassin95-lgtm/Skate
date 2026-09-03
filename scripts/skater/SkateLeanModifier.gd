class_name SkateLeanModifier
extends SkeletonModifier3D
## Builds the skating pose procedurally, on top of whatever clip is playing.
##
## The animation library has no skateboarding clips, and its locomotion clips are
## actively wrong here: every one of them walks the body through space, so played
## on a rider they read as sliding or running sideways however the root is
## oriented. So the base clip only supplies idle breathing, and everything that
## makes this read as skating is built here, driven by the board's real state.
##
## Two things make it hold together:
##
## *The stance is a hip twist, not a rotated character.* Hips open across the
## deck, shoulders follow most of the way, head turns back down the line. That is
## the real anatomy, and it leaves the character's root pointing along the
## direction of travel so nothing downstream has to compensate.
##
## *The feet are solved, not posed.* Each leg is placed by closed-form two-bone
## IK against a target on the deck, so the soles genuinely sit on the board at
## any crouch depth instead of drifting off it as joint angles accumulate. The
## push stroke is just that target moving off the deck to the ground and
## sweeping back, which is what a push actually is.
##
## Rig notes (measured, not assumed): the model faces +Z with its left on +X, so
## in skeleton space the deck runs along Z with the nose at +Z. Down each limb is
## the bone's local +Y, and every leg bone rests with its local X on world X --
## which is why a bone's global basis is built here as
## (x = knee axis, y = down the limb).

const BONES := {
	"pelvis": "pelvis",
	"spine1": "spine_01", "spine2": "spine_02", "spine3": "spine_03",
	"neck": "neck_01", "head": "Head",
	"clav_l": "clavicle_l", "arm_l": "upperarm_l", "forearm_l": "lowerarm_l",
	"clav_r": "clavicle_r", "arm_r": "upperarm_r", "forearm_r": "lowerarm_r",
}
const LEG_BONES := {
	"l": {"thigh": "thigh_l", "calf": "calf_l", "foot": "foot_l"},
	"r": {"thigh": "thigh_r", "calf": "calf_r", "foot": "foot_r"},
}

@export_group("Stance")
## Hip twist while riding, degrees. This is what puts the feet across the deck.
@export_range(-120.0, 120.0) var stance_yaw := -72.0
## Hips square up toward the direction of travel to push, as they really do.
@export_range(-120.0, 120.0) var push_stance_yaw := -30.0
## Shoulders take this share of the hip twist; the head gives back the rest, so
## the skater is always looking down the line rather than off the side.
@export_range(0.0, 1.0) var shoulder_follow := 0.8
## Half the distance between the feet along the deck, metres.
@export var stance_half_width := 0.16
## Which foot sits over the nose truck. This has to agree with the sign of
## `stance_yaw`: the hip twist swings one hip toward the nose, and putting the
## other foot there makes the legs cross the board and run out of reach.
@export_enum("left", "right") var front_foot := "left"

@export_group("Crouch")
## How far the hips sink at rest, metres. Knees are never locked on a board --
## and a shallower crouch than this leaves the legs near full extension, where
## the solver runs out of reach on the outer foot.
@export var crouch_base := 0.16
## Extra sink at speed and at full ollie charge, metres.
@export var crouch_speed_add := 0.07
@export var crouch_charge_add := 0.16
## The body follows the trucks, so a landing drives the knees too.
@export var crouch_compression_gain := 1.4
@export var crouch_max := 0.40
## The hips drop to push, which is both what really happens and what keeps the
## reaching leg inside its own length.
@export var crouch_push_add := 0.13

@export_group("Push stroke")
## How far the pushing foot reaches out beside the deck.
@export var push_side_offset := 0.24
## How far it sweeps fore-aft over one stroke.
@export var push_sweep := 0.18
## How far below the deck the ground is, for the pushing foot to reach.
@export var deck_height := 0.07

@export_group("Balance")
@export_range(0.0, 60.0) var carve_lean := 18.0
@export_range(0.0, 90.0) var balance_arms := 44.0
@export var response := 11.0

var skater: SkaterController
## The character node, sunk by the crouch so the solved feet stay on the deck.
var body: Node3D
## The board's pivot. Foot targets are placed in *its* frame rather than the
## skeleton's, so the feet track the deck through leans, ramps and compression
## instead of relying on the two frames happening to line up.
var board: Node3D

var _idx := {}
var _leg := {}
var _thigh_len := {}
var _calf_len := {}
## Ankle height above the sole, measured off the rest pose so nothing here
## depends on the model's proportions.
var _sole_drop := 0.1
var _foot_rest_basis := {}
var _deck_local := Vector3.ZERO

var _board_fwd := Vector3.BACK
var _board_up := Vector3.UP
## Which way the twisted torso is actually facing, in skeleton space. Both the
## knee break and the side the pushing foot comes down on follow from this, so
## the stance can be flipped by changing `stance_yaw` alone and the feet, knees
## and pushing leg all stay consistent with the body.
var _chest := Vector3.BACK

var _clamped := {}
var _lifted := {}
var _solved_ankle := {}
var _solved_target := {}

var _crouch := 0.0
var _lean := 0.0
var _air := 0.0
var _speed := 0.0
var _push := 0.0
var _phase := 0.0

func _ready() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	for key in BONES:
		_idx[key] = skel.find_bone(BONES[key])
	for side in LEG_BONES:
		var ids := {}
		for part in LEG_BONES[side]:
			ids[part] = skel.find_bone(LEG_BONES[side][part])
		_leg[side] = ids
		if ids["thigh"] < 0 or ids["calf"] < 0:
			continue
		# Segment lengths come from the rest pose, so the solver never needs
		# hard-coded proportions.
		var hip: Vector3 = skel.get_bone_global_pose(ids["thigh"]).origin
		var knee: Vector3 = skel.get_bone_global_pose(ids["calf"]).origin
		_thigh_len[side] = hip.distance_to(knee)
		if ids["foot"] >= 0:
			var ankle := skel.get_bone_global_pose(ids["foot"])
			_calf_len[side] = knee.distance_to(ankle.origin)
			_foot_rest_basis[side] = ankle.basis
			_sole_drop = ankle.origin.y - _rest_sole_height(skel)
		else:
			_calf_len[side] = 0.42

## Lowest point of the skinned mesh in the rest pose, i.e. where the sole is.
func _rest_sole_height(skel: Skeleton3D) -> float:
	for child in skel.get_children():
		if child is MeshInstance3D:
			return (child as MeshInstance3D).get_aabb().position.y
	return 0.0

func _process(delta: float) -> void:
	if skater == null:
		return
	var t := clampf(delta * response, 0.0, 1.0)

	var want := crouch_base
	want += crouch_speed_add * clampf(skater.speed / 14.0, 0.0, 1.0)
	want += crouch_charge_add * skater.crouch
	# Compression is negative when the trucks are loaded, which is the landing.
	want += -skater.compression * crouch_compression_gain
	want += crouch_push_add * _push
	if skater.state == SkaterController.State.AIR:
		want = maxf(want, crouch_base + 0.12)
	_crouch = lerpf(_crouch, clampf(want, 0.0, crouch_max), t)

	# Lean follows the trucks, not the raw stick, so body and board agree.
	_lean = lerpf(_lean, skater.steer * clampf(skater.speed / 8.0, 0.0, 1.0), t)

	var airborne := skater.state == SkaterController.State.AIR
	_air = lerpf(_air, 1.0 if airborne else 0.0, t)
	_speed = lerpf(_speed, clampf(skater.speed / 15.0, 0.0, 1.0), t)

	var pushing := skater.push_anim_timer > 0.0 and not airborne
	_push = lerpf(_push, 1.0 if pushing else 0.0, clampf(delta * 10.0, 0.0, 1.0))
	if pushing:
		_phase = skater.push_phase

func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null or _idx.is_empty():
		return

	var hips := deg_to_rad(lerpf(stance_yaw, push_stance_yaw, _push))
	# Sinking the body is what bends the knees: the feet are pinned to the deck
	# by the solver, so lowering the hips has to close the legs up.
	if body == null:
		push_error("SkateLeanModifier: no body assigned; the crouch cannot sink.")
		return
	body.position.y = -_crouch
	# The board frame has to be resolved before anything derived from it.
	_resolve_board_frame(skel)
	# Knees break the way the body faces, not the way the board points.
	_chest = (Basis(_board_up, hips) * _board_fwd).normalized()

	_pose_torso(skel, hips)
	_pose_arms(skel)

	# The legs hang off the pelvis we just twisted, so its global pose has to be
	# recomposed by hand -- querying it back would read the pre-twist cache.
	var pelvis: int = _idx.get("pelvis", -1)
	if pelvis < 0:
		return
	var pelvis_parent := skel.get_bone_parent(pelvis)
	var above := skel.get_bone_global_pose(pelvis_parent) if pelvis_parent >= 0 else Transform3D.IDENTITY
	var pelvis_global := above * skel.get_bone_pose(pelvis)

	for side in _leg:
		var thigh: int = _leg[side]["thigh"]
		if thigh < 0:
			continue
		# Only the hip's rotation is ours; its offset from the pelvis is the rig's.
		var hip: Vector3 = pelvis_global * skel.get_bone_pose(thigh).origin
		_solve_leg(skel, pelvis_global, side, _reachable(side, hip, _foot_target(side)), _chest)

## Where this foot should be, in skeleton space.
##
## Placed in the board's frame and then converted, so the feet sit on the deck
## one over each truck regardless of how the board is leaning, what slope it is
## on, or how far the trucks have compressed. Sinking the body for a crouch
## moves the deck within skeleton space automatically, so the crouch needs no
## bookkeeping here -- it just closes the legs up.
func _foot_target(side: String) -> Vector3:
	var is_front := (side == "l") == (front_foot == "left")
	var along := stance_half_width if is_front else -stance_half_width

	var deck := _deck_local + _board_up * _sole_drop + _board_fwd * along
	if _push <= 0.001 or is_front:
		_lifted[side] = 0.0
		return deck

	# The pushing foot leaves the deck, reaches down beside it, sweeps back
	# against the ground, and steps back on.
	var down := sin(clampf(_phase, 0.0, 1.0) * PI)
	var sweep := cos(_phase * TAU)
	_lifted[side] = down * _push
	var ground := _deck_local \
		+ _board_up * (_sole_drop - deck_height) \
		+ _board_fwd * (push_sweep * sweep) \
		- _chest * push_side_offset
	return deck.lerp(ground, down * _push)

## Pulls a foot target onto the shell the leg can actually reach.
##
## The pushing foot asks for the floor at the far ends of its sweep, which is
## slightly further than the leg is long. Clamping here rather than inside the
## solver means the target the solver is given is always one it can hit exactly,
## so the foot stops short instead of the ankle silently drifting away from where
## the pose says it should be -- which is what a leg does anyway.
func _reachable(side: String, hip: Vector3, target: Vector3) -> Vector3:
	var l1: float = _thigh_len[side]
	var l2: float = _calf_len[side]
	var to_target := target - hip
	var d := to_target.length()
	if d < 0.0001:
		return target
	var longest := l1 + l2 - 0.01
	var shortest := absf(l1 - l2) + 0.02
	if d > longest:
		_clamped[side] = d - longest
		return hip + to_target * (longest / d)
	if d < shortest:
		_clamped[side] = shortest - d
		return hip + to_target * (shortest / d)
	_clamped[side] = 0.0
	return target

## Closed-form two-bone IK. Places the ankle on `target` (skeleton space) with
## the knee breaking toward `knee_forward`, and leaves the sole level.
##
## Every frame in the chain is composed forwards from the pelvis rather than
## queried back out of the skeleton: each bone's global basis is known here the
## moment it is chosen, and reading it back instead would pick up whatever the
## animation left there before this modifier ran.
func _solve_leg(skel: Skeleton3D, pelvis_global: Transform3D, side: String,
		target: Vector3, knee_forward: Vector3) -> void:
	var ids: Dictionary = _leg[side]
	var thigh: int = ids["thigh"]
	var calf: int = ids["calf"]
	if thigh < 0 or calf < 0:
		return
	var l1: float = _thigh_len[side]
	var l2: float = _calf_len[side]

	var hip: Vector3 = pelvis_global * skel.get_bone_pose(thigh).origin
	var to_target := target - hip
	if to_target.length_squared() < 0.000001:
		return
	var dir := to_target.normalized()
	# Never fully straight and never folded past the joint limit.
	var reach := clampf(to_target.length(), absf(l1 - l2) + 0.02, l1 + l2 - 0.005)

	# Knee axis. At rest the leg hangs straight with its local X on world X, and
	# this expression reproduces that, so the solved pose never rolls the mesh.
	var axis := knee_forward.cross(dir)
	if axis.length_squared() < 0.0001:
		axis = Vector3.RIGHT
	axis = axis.normalized()

	# Angle between the thigh and the straight hip-to-target line.
	var cos_hip := clampf((l1 * l1 + reach * reach - l2 * l2) / (2.0 * l1 * reach), -1.0, 1.0)
	var thigh_dir := dir.rotated(axis, -acos(cos_hip))
	var thigh_basis := _limb_basis(axis, thigh_dir)

	var knee_pos := hip + thigh_dir * l1
	var shin_dir := target - knee_pos
	if shin_dir.length_squared() < 0.000001:
		shin_dir = thigh_dir
	shin_dir = shin_dir.normalized()
	var calf_basis := _limb_basis(axis, shin_dir)

	_set_local_rotation(skel, thigh, pelvis_global.basis, thigh_basis)
	_set_local_rotation(skel, calf, thigh_basis, calf_basis)
	# Keep the sole level with the deck instead of following the shin.
	if ids["foot"] >= 0 and _foot_rest_basis.has(side):
		_set_local_rotation(skel, ids["foot"], calf_basis, _foot_rest_basis[side])

	# Record where the chain actually put the ankle, while we are still inside
	# the modification pass. Godot restores bone poses once the pass ends, so
	# this cannot be read back afterwards -- and reading it afterwards is exactly
	# what makes a working solver look broken.
	_solved_ankle[side] = knee_pos + shin_dir * l2
	_solved_target[side] = target

## Limb bones rest with their local Y down the bone and local X on the joint
## axis, so a global basis is fully determined by those two directions.
func _limb_basis(axis: Vector3, limb_dir: Vector3) -> Basis:
	var bx := axis
	var by := limb_dir
	bx = (bx - by * bx.dot(by)).normalized()
	return Basis(bx, by, bx.cross(by))

## Converts a desired global basis into the local rotation that produces it,
## given the basis its parent ended up with.
func _set_local_rotation(skel: Skeleton3D, bone: int, parent_basis: Basis,
		global_basis: Basis) -> void:
	skel.set_bone_pose_rotation(bone,
		(parent_basis.inverse() * global_basis).get_rotation_quaternion())

## Expresses the deck's position and axes in skeleton space, which is the frame
## the leg solver works in.
func _resolve_board_frame(skel: Skeleton3D) -> void:
	if board == null:
		# Falling back silently here is what hid a null `board` for a whole
		# iteration: the pose looked plausible but the feet were placed against
		# the skeleton origin instead of the deck.
		push_error("SkateLeanModifier: no board assigned; feet cannot be placed.")
		return
	var to_skeleton := skel.global_transform.affine_inverse()
	_deck_local = to_skeleton * board.global_position
	var b := to_skeleton.basis * board.global_transform.basis
	_board_fwd = -b.z.normalized()
	_board_up = b.y.normalized()

## Hips open across the deck, shoulders follow most of the way, head turns back
## so the skater looks where they are going.
func _pose_torso(skel: Skeleton3D, hips: float) -> void:
	var shoulders := hips * shoulder_follow
	var lean := deg_to_rad(carve_lean) * _lean
	# Deeper crouches fold the torso forward a little rather than just sinking.
	var fold := _crouch * 0.9

	_add(skel, "pelvis", Quaternion(Vector3.UP, hips)
		* Quaternion(Vector3.RIGHT, -fold)
		* Quaternion(Vector3.FORWARD, lean * 0.3))

	var give := (shoulders - hips) / 3.0
	for bone: String in ["spine1", "spine2", "spine3"]:
		_add(skel, bone, Quaternion(Vector3.UP, give)
			* Quaternion(Vector3.FORWARD, lean * 0.2)
			* Quaternion(Vector3.RIGHT, -fold * 0.25))

	# Whatever twist the torso kept, the neck and head undo.
	_add(skel, "neck", Quaternion(Vector3.UP, -shoulders * 0.5))
	_add(skel, "head", Quaternion(Vector3.UP, -shoulders * 0.5))

func _pose_arms(skel: Skeleton3D) -> void:
	# Arms come out for balance: a little at speed, a lot in the air.
	var out := deg_to_rad(balance_arms) * clampf(maxf(_air, 0.35 + _speed * 0.5 + _push * 0.3), 0.0, 1.0)
	_add(skel, "clav_l", Quaternion(Vector3.FORWARD, out * 0.12))
	_add(skel, "clav_r", Quaternion(Vector3.FORWARD, -out * 0.12))
	_add(skel, "arm_l", Quaternion(Vector3.FORWARD, out) * Quaternion(Vector3.UP, out * 0.25))
	_add(skel, "arm_r", Quaternion(Vector3.FORWARD, -out) * Quaternion(Vector3.UP, -out * 0.25))
	_add(skel, "forearm_l", Quaternion(Vector3.RIGHT, -out * 0.4))
	_add(skel, "forearm_r", Quaternion(Vector3.RIGHT, -out * 0.4))

## Multiplies an offset into the bone's animated pose instead of overwriting it,
## so the underlying clip still shows through.
func _add(skel: Skeleton3D, key: String, offset: Quaternion) -> void:
	var bone: int = _idx.get(key, -1)
	if bone < 0:
		return
	skel.set_bone_pose_rotation(bone, skel.get_bone_pose_rotation(bone) * offset)

## Where the solver actually put each ankle, and what it was aiming at, both in
## skeleton space and both captured during the modification pass. The tests use
## these to prove the feet land on the deck rather than merely near it.
func solved_ankles() -> Dictionary:
	return _solved_ankle.duplicate()

func foot_targets() -> Dictionary:
	return _solved_target.duplicate()

## The deck's origin and axes in skeleton space, so tests can measure foot
## placement in the board's own frame rather than assuming a world axis.
func deck_frame() -> Dictionary:
	return {"origin": _deck_local, "forward": _board_fwd, "up": _board_up}

## How far each sole sits above (+) or below (-) the deck surface, in metres.
##
## This is the invariant the whole pose exists to satisfy, and it is worth
## asserting directly: every alignment bug so far -- a rotated character root, a
## null board, a null body -- showed up here as soles floating a fixed distance
## off the board while every individual pose value still looked reasonable.
## How far each foot target had to be pulled in to stay within the leg's reach.
func reach_shortfall() -> Dictionary:
	return _clamped.duplicate()

func sole_clearance() -> Dictionary:
	var out := {}
	for side in _solved_ankle:
		var rel: Vector3 = (_solved_ankle[side] as Vector3) - _deck_local
		out[side] = rel.dot(_board_up) - _sole_drop
	return out
