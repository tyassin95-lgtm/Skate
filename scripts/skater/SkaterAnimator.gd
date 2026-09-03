class_name SkaterAnimator
extends Node
## Chooses the base animation the procedural skate pose is layered on top of.
##
## Reviewing the library: it has no skateboarding clips at all, and its
## locomotion clips (`Walk`, `Jog_Fwd`, `Sprint`, `Crouch_Fwd`, `Push`) are worse
## than nothing here -- each one steps the body through space, so on a rider they
## read as running or sliding rather than standing on a board. `Crouch_Idle`
## looks promising by name but is a folded-over sneak. Playing any of them was
## the single biggest reason the old build looked wrong.
##
## So there are only two base states, and they are chosen by whether the skater
## is on the board at all:
##
##   board -- `Idle`, a still upright pose. Every skating read (stance, crouch,
##            push stroke, carve lean, landing compression) is built on top by
##            `SkateLeanModifier` from the board's real state, so it can never
##            disagree with what the board is doing.
##   bail  -- `Roll`, which is genuinely the right clip: the skater has come off
##            and is tumbling, so a canned full-body animation is correct.
##
## Two states also means transitions are never abrupt: the procedural layer is
## continuous by construction, and the only cross-fade left is on and off a bail.

## Clip names are the library's, minus the `_Loop` suffix Godot's glTF importer
## strips when it turns those clips into looping animations.
const CLIPS := {
	"board": "Idle",
	"bail": "Roll",
}

@export var blend_time := 0.25

@onready var _skater: SkaterController = get_parent()

var anim_player: AnimationPlayer
var anim_tree: AnimationTree
var lean: SkateLeanModifier

var _playback: AnimationNodeStateMachinePlayback
var _current := ""
var _ready_ok := false

var _character: Node3D
var _skeleton: Skeleton3D

func _ready() -> void:
	var character := _skater.get_node_or_null(^"BoardPivot/CharacterPivot/Character")
	if character == null:
		push_warning("SkaterAnimator: no Character node found; animation disabled.")
		return
	anim_player = _find_animation_player(character)
	if anim_player == null:
		push_warning("SkaterAnimator: imported character has no AnimationPlayer.")
		return
	# Assigned before _build_tree, which wires it into the pose modifier.
	_character = character as Node3D
	_build_tree(character)
	_ready_ok = true
	_travel("board")

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
			t.xfade_time = blend_time
			t.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC
			t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED
			sm.add_transition(from_state, to_state, t)

	anim_tree = AnimationTree.new()
	anim_tree.tree_root = sm
	anim_tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	character.add_child(anim_tree)
	# Ordering is load-bearing. The skeleton runs its SkeletonModifier3D children
	# during its own idle process, so if the AnimationTree processes afterwards it
	# writes the raw clip pose straight over the skate pose -- which looks like
	# the modifier "partly working" rather than like an ordering bug. Putting the
	# tree first in the parent and giving it priority guarantees the clip lands
	# before the modifier layers on top of it.
	character.move_child(anim_tree, 0)
	anim_tree.process_priority = -100
	anim_tree.anim_player = anim_tree.get_path_to(anim_player)
	anim_tree.active = true
	_playback = anim_tree.get(&"parameters/playback")

	_skeleton = _find_skeleton(character)
	if _skeleton:
		lean = SkateLeanModifier.new()
		lean.skater = _skater
		lean.body = _character
		# Fetched by path, not via the skater's @onready: child _ready() runs
		# before the parent's, so board_pivot is still null at this point and the
		# pose would silently fall back to the skeleton origin.
		lean.board = _skater.get_node_or_null(^"BoardPivot")
		_skeleton.add_child(lean)

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
	_travel(_desired_state())

func _desired_state() -> String:
	return "bail" if _skater.state == SkaterController.State.BAIL else "board"

func _travel(to: String) -> void:
	if to == _current or _playback == null:
		return
	if not (anim_tree.tree_root as AnimationNodeStateMachine).has_node(to):
		return
	_playback.travel(to)
	_current = to

