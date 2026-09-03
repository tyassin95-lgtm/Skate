class_name SkaterAnimator
extends Node
## Maps skater state onto the Quaternius Universal Animation Library.
##
## The library has no skateboarding clips, so the approach is: pick the closest
## generic clip as a base pose (a crouched stance reads as riding, `Jump_Loop`
## as an air), then let `SkateLeanModifier` layer the skating on top -- crouch
## depth, carve lean, shoulder counter-rotation and arm height. That procedural
## layer is what actually sells the blend; the clips just supply the body.
##
## The state machine is built in code rather than saved into the scene so the
## clip mapping stays readable and tunable in one place.

## Clip names are the library's, minus the `_Loop` suffix that Godot's glTF
## importer strips when it turns those clips into looping animations.
## `Crouch_Idle` looks like the obvious riding pose but the library's crouch is a
## folded-over sneak, so the upright `Idle` is the better base -- the skate stance
## comes from `SkateLeanModifier` bending the knees on top of it, where the depth
## can follow speed and the ollie charge.
const CLIPS := {
	"ride":  "Idle",
	"push":  "Jog_Fwd",
	"pop":   "Jump_Start",
	"air":   "Jump",
	"land":  "Jump_Land",
	"grind": "Idle",
	"bail":  "Roll",
}

## Without leg IK, bending the knees lifts the feet off the deck. Sinking the
## whole character by however far the lower foot rose keeps them planted, for any
## clip and any crouch depth.
@export var plant_feet := true
@export var foot_plant_limit := 0.3
@export var foot_plant_response := 12.0

@export var blend_time := 0.18
@export var push_blend_time := 0.12
@export var land_hold := 0.28
@export var push_hold := 0.42

@onready var _skater: SkaterController = get_parent()

var anim_player: AnimationPlayer
var anim_tree: AnimationTree
var lean: SkateLeanModifier

var _playback: AnimationNodeStateMachinePlayback
var _current := ""
var _hold_timer := 0.0
var _ready_ok := false

var _character: Node3D
var _skeleton: Skeleton3D
var _foot_bones: Array[int] = []
var _foot_rest_y := 0.0
var _foot_offset := 0.0

func _ready() -> void:
	var character := _skater.get_node_or_null(^"BoardPivot/CharacterPivot/Character")
	if character == null:
		push_warning("SkaterAnimator: no Character node found; animation disabled.")
		return
	anim_player = _find_animation_player(character)
	if anim_player == null:
		push_warning("SkaterAnimator: imported character has no AnimationPlayer.")
		return
	_build_tree(character)
	_character = character as Node3D
	_skater.landed.connect(_on_landed)
	_skater.pushed.connect(_on_pushed)
	_ready_ok = true
	_travel("ride")

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var found := _find_animation_player(c)
		if found:
			return found
	return null

func _build_tree(character: Node) -> void:
	var sm := AnimationNodeStateMachine.new()
	var missing: Array[String] = []
	var states: Array[String] = []
	var i := 0
	for key in CLIPS:
		var clip: String = CLIPS[key]
		if not anim_player.has_animation(clip):
			missing.append(clip)
			continue
		var node := AnimationNodeAnimation.new()
		node.animation = clip
		sm.add_node(key, node, Vector2(float(i % 3) * 260.0, float(i / 3) * 140.0))
		states.append(key)
		i += 1
	if not missing.is_empty():
		push_warning("SkaterAnimator: missing clips %s" % [missing])

	# Every state can reach every other state directly, so `travel()` is always
	# a single cross-fade and never walks through an unrelated pose.
	for from_state in states:
		for to_state in states:
			if from_state == to_state:
				continue
			var t := AnimationNodeStateMachineTransition.new()
			t.xfade_time = push_blend_time if (to_state == "push" or from_state == "push") else blend_time
			t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
			t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED
			sm.add_transition(from_state, to_state, t)

	anim_tree = AnimationTree.new()
	anim_tree.tree_root = sm
	anim_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	character.add_child(anim_tree)
	anim_tree.anim_player = anim_tree.get_path_to(anim_player)
	anim_tree.active = true
	_playback = anim_tree.get(&"parameters/playback")

	_skeleton = _find_skeleton(character)
	if _skeleton:
		lean = SkateLeanModifier.new()
		lean.skater = _skater
		_skeleton.add_child(lean)
		for bone_name in ["foot_l", "foot_r"]:
			var idx := _skeleton.find_bone(bone_name)
			if idx >= 0:
				_foot_bones.append(idx)
				_foot_rest_y = maxf(_foot_rest_y, _skeleton.get_bone_global_pose(idx).origin.y)

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var found := _find_skeleton(c)
		if found:
			return found
	return null

func _process(delta: float) -> void:
	if not _ready_ok:
		return
	_update_foot_plant(delta)
	_hold_timer = maxf(0.0, _hold_timer - delta)
	if _hold_timer > 0.0:
		return
	_travel(_desired_state())

func _update_foot_plant(delta: float) -> void:
	if not plant_feet or _character == null or _foot_bones.is_empty():
		return
	var target := 0.0
	# Only while the wheels are meant to be on something; in the air and in a
	# bail the feet are supposed to leave the board.
	if _skater.state == SkaterController.State.ROLL or _skater.state == SkaterController.State.GRIND:
		# Average the two feet rather than the lower one: splitting the
		# difference straddles the deck instead of planting one foot and
		# leaving the other hanging in the air.
		var total := 0.0
		for idx in _foot_bones:
			total += _skeleton.get_bone_global_pose(idx).origin.y
		var mean := total / float(_foot_bones.size())
		target = clampf(_foot_rest_y - mean, -foot_plant_limit, foot_plant_limit)
	_foot_offset = lerpf(_foot_offset, target, clampf(delta * foot_plant_response, 0.0, 1.0))
	_character.position.y = _foot_offset

func _desired_state() -> String:
	match _skater.state:
		SkaterController.State.BAIL:
			return "bail"
		SkaterController.State.AIR:
			return "air"
		SkaterController.State.GRIND:
			return "grind"
		_:
			if _skater.crouch > 0.25:
				return "pop"
			if _skater.push_anim_timer > 0.0:
				return "push"
			return "ride"

func _travel(to: String) -> void:
	if to == _current or _playback == null:
		return
	if not (anim_tree.tree_root as AnimationNodeStateMachine).has_node(to):
		return
	_playback.travel(to)
	_current = to

func _on_landed(_impact: float) -> void:
	_travel("land")
	_hold_timer = land_hold

func _on_pushed() -> void:
	_travel("push")
	_hold_timer = push_hold
