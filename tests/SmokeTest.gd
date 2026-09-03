extends Node
## Headless behaviour test for the skating prototype.
##
## Run with:  godot --headless --path . res://tests/SmokeTest.tscn
##
## It boots the real Main scene, drives the same `Controls` struct the touch HUD
## writes to, and checks that pushing builds speed, that an ollie leaves the
## ground and lands clean, that a trick landed too early bails, that rails can be
## grinded, and that respawning recovers. Cheap to run and it catches the class
## of regression that only shows up once things are actually moving.

const STEP := 1.0 / 60.0

var _failures: Array[String] = []
var _main: Node3D
var _skater: SkaterController

func _ready() -> void:
	_run()

func _run() -> void:
	var packed: PackedScene = load("res://scenes/Main.tscn")
	if packed == null:
		_fail("could not load Main.tscn")
		return _finish()
	_main = packed.instantiate()
	# The tree is still building this node's own children, so defer the add.
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	await get_tree().physics_frame
	_skater = _main.get_node("Skater")

	await _test_rolls_when_pushed()
	await _test_ollie_leaves_ground_and_lands()
	await _test_early_landing_bails()
	await _test_trick_with_enough_air_lands()
	await _test_grind_on_flat_rail()
	await _test_respawn_after_falling()
	await _test_park_geometry()
	await _test_ramp_converts_height_to_speed()
	await _test_steering_turns_the_skater()
	await _test_skater_goes_where_the_stick_points()
	await _test_pulling_back_brakes()
	await _test_character_faces_along_the_board()
	await _test_landing_compresses_the_trucks()
	await _test_feet_land_on_the_deck()
	await _test_push_reaches_the_ground()
	_test_touch_stick_tracks_every_direction()
	_test_animation_tree_built()
	_finish()

# -----------------------------------------------------------------------------

func _test_rolls_when_pushed() -> void:
	_reset()
	var start := _skater.global_position
	_stick_toward(Vector3.FORWARD)
	await _steps(120)
	_clear_input()
	_expect(_skater.speed > 3.0, "pushing should build speed (got %.2f m/s)" % _skater.speed)
	_expect(start.distance_to(_skater.global_position) > 3.0,
		"skater should have travelled while pushing")

	# ...and coast down again once the pushing stops.
	var coast_speed := _skater.speed
	await _steps(120)
	_expect(_skater.speed < coast_speed,
		"rolling resistance should bleed speed off (%.2f -> %.2f)" % [coast_speed, _skater.speed])

func _test_ollie_leaves_ground_and_lands() -> void:
	_reset()
	_stick_toward(Vector3.FORWARD)
	await _steps(90)
	_clear_input()

	Controls.touch_ollie = true
	await _steps(30)  # load the pop
	var peak_charge := _skater.crouch
	Controls.touch_ollie = false
	await _steps(6)
	_expect(peak_charge > 0.5, "holding the pad should charge the ollie (got %.2f)" % peak_charge)
	_expect(_skater.state == SkaterController.State.AIR,
		"releasing the pad should pop into the air (state %d)" % _skater.state)

	var max_height := -INF
	for i in range(120):
		await _step()
		max_height = maxf(max_height, _skater.global_position.y)
		if _skater.state == SkaterController.State.ROLL:
			break
	_expect(max_height > 0.5, "the ollie should gain real height (got %.2f m)" % max_height)
	_expect(_skater.state == SkaterController.State.ROLL,
		"a plain ollie should land clean, not bail (state %d)" % _skater.state)

func _test_early_landing_bails() -> void:
	_reset()
	# Put the skater in a hop far too short to bring a kickflip back round, so
	# the board is still sideways when the wheels touch down.
	_skater.global_position = Vector3(0.0, 0.45, 6.0)
	_skater.heading = 0.0
	_skater.velocity = Vector3(0.0, 1.0, -5.0)
	_skater.state = SkaterController.State.AIR
	await _step()
	Controls.touch_trick = "kickflip"
	await _step()
	_expect(_skater.trick_system.active_trick == "kickflip",
		"the flick should start a kickflip (got '%s')" % _skater.trick_system.active_trick)

	for i in range(60):
		await _step()
		if _skater.state != SkaterController.State.AIR:
			break
	_expect(_skater.state == SkaterController.State.BAIL,
		"landing mid-kickflip should bail (state %d)" % _skater.state)

	# ...and the bail should recover on its own.
	await _steps(150)
	_expect(_skater.state == SkaterController.State.ROLL,
		"a bail should respawn back to rolling (state %d)" % _skater.state)

## The same trick with enough air under it has to land clean, otherwise the
## check above would pass even if tricks never completed at all.
func _test_trick_with_enough_air_lands() -> void:
	_reset()
	_skater.global_position = Vector3(0.0, 0.45, 6.0)
	_skater.heading = 0.0
	_skater.velocity = Vector3(0.0, 7.0, -5.0)
	_skater.state = SkaterController.State.AIR
	await _step()
	Controls.touch_trick = "kickflip"
	await _step()
	for i in range(140):
		await _step()
		if _skater.state == SkaterController.State.ROLL or _skater.state == SkaterController.State.BAIL:
			break
	_expect(_skater.state == SkaterController.State.ROLL,
		"a kickflip with airtime to spare should land clean (state %d)" % _skater.state)
	_expect(Game.score > 0, "landing a kickflip should score (got %d)" % Game.score)

func _test_grind_on_flat_rail() -> void:
	# The flat rail runs along Z at x = -9, its bar at y = 0.45.
	var rail := _main.get_node_or_null("Skatepark/FlatRail")
	_expect(rail != null, "the park should build a FlatRail")
	if rail == null:
		return
	_reset()
	# Drop onto the middle of the bar already moving along it.
	_skater.global_position = Vector3(-9.0, 0.85, -4.0)
	_skater.heading = 0.0
	_skater.velocity = Vector3(0.0, 0.0, 8.0)
	_skater.state = SkaterController.State.AIR
	var grinded := false
	for i in range(90):
		await _step()
		if _skater.state == SkaterController.State.GRIND:
			grinded = true
			break
	_expect(grinded, "dropping onto the rail in line with it should start a grind")
	if grinded:
		var before := _skater.global_position.z
		await _steps(20)
		_expect(_skater.global_position.z > before,
			"the grind should carry the skater along the bar")

func _test_respawn_after_falling() -> void:
	_reset()
	_skater.global_position = Vector3(0.0, -40.0, 0.0)
	await _steps(4)
	_expect(_skater.global_position.y > -8.0,
		"falling out of the world should respawn (y = %.1f)" % _skater.global_position.y)
	# The spawn point sits just above the ground, so allow a few frames to settle.
	await _steps(30)
	_expect(_skater.state == SkaterController.State.ROLL,
		"respawn should leave the skater rolling (state %d)" % _skater.state)

func _test_park_geometry() -> void:
	var park := _main.get_node("Skatepark")
	var rails := 0
	var bodies := 0
	for c in park.get_children():
		if c is Rail:
			rails += 1
		elif c is StaticBody3D:
			bodies += 1
	_expect(rails >= 4, "the park should have several grindable edges (got %d)" % rails)
	_expect(bodies >= 8, "the park should have solid geometry (got %d bodies)" % bodies)

	# Every ramp needs collision that matches what you can see.
	for c in park.get_children():
		if c is StaticBody3D and c.collision_layer == 1:
			var has_shape := false
			for gc in c.get_children():
				if gc is CollisionShape3D and gc.shape != null:
					has_shape = true
			_expect(has_shape, "%s has collision matching its visual" % c.name)

## The north quarter pipe is a curved transition at z = -18. Riding into it
## should trade speed for height and then give the speed back on the way down --
## that round trip is the whole slope-gravity model in one check.
func _test_ramp_converts_height_to_speed() -> void:
	_reset()
	_skater.global_position = Vector3(0.0, 0.05, -12.0)
	_skater.heading = PI  # face -Z, toward the ramp
	# Slow enough to stall partway up rather than fly out over the coping.
	_skater.velocity = Vector3(0.0, 0.0, -7.0)
	await _step()

	var peak_y := -INF
	var climbed := false
	for i in range(180):
		await _step()
		peak_y = maxf(peak_y, _skater.global_position.y)
		if _skater.global_position.y > 0.6:
			climbed = true
		# Once back down and heading away from the ramp we are done.
		if climbed and _skater.global_position.y < 0.3 and _skater.velocity.z > 1.0:
			break
	_expect(climbed, "riding into the quarter pipe should carry the skater up it (peak %.2f m)" % peak_y)
	_expect(_skater.velocity.z > 1.0,
		"dropping back in should send the skater out the way they came (vz %.2f)" % _skater.velocity.z)
	_expect(peak_y < 2.6,
		"7 m/s should stall inside the transition, not clear the coping (peak %.2f m)" % peak_y)
	_expect(_skater.state != SkaterController.State.BAIL,
		"a normal transition should not bail")

func _test_steering_turns_the_skater() -> void:
	_reset()
	_stick_toward(Vector3.FORWARD)
	await _steps(60)
	var before := _skater.heading
	# Hold the stick to the right of where the camera is looking.
	_stick(1.0, 0.0)
	await _steps(45)
	_clear_input()
	var turned := wrapf(_skater.heading - before, -PI, PI)
	_expect(absf(turned) > 0.5, "holding the stick aside should carve (turned %.2f rad)" % turned)

	# Steering authority has to survive at a standstill as a kick-turn.
	_reset()
	await _steps(2)
	before = _skater.heading
	_stick(1.0, 0.0)
	await _steps(30)
	_clear_input()
	_expect(absf(wrapf(_skater.heading - before, -PI, PI)) > 0.2,
		"a stationary skater should still be able to kick-turn")

## The whole point of camera-relative input: the stick names a direction on
## screen and the skater must actually end up going that way. This is the check
## that would have caught the old build steering the wrong way round.
func _test_skater_goes_where_the_stick_points() -> void:
	# The follow camera republishes Controls.camera_yaw every tick, which is
	# right in play but would overwrite the fixed view this test needs.
	var rig: Node3D = _main.get_node("CameraRig")
	rig.set_physics_process(false)
	for target in [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]:
		_reset()
		await _steps(2)
		_stick_toward(target)
		await _steps(200)
		_clear_input()
		var horiz := Vector3(_skater.velocity.x, 0.0, _skater.velocity.z)
		_expect(horiz.length() > 2.0,
			"stick toward %s should build speed (got %.2f m/s)" % [target, horiz.length()])
		if horiz.length() > 0.5:
			var error := rad_to_deg(horiz.normalized().angle_to(target))
			_expect(error < 25.0,
				"should travel toward %s (off by %.1f deg)" % [target, error])
	rig.set_physics_process(true)

## Pulling the stick back against the direction of travel is the brake.
func _test_pulling_back_brakes() -> void:
	_reset()
	_stick_toward(Vector3.FORWARD)
	await _steps(120)
	var rolling := _skater.speed
	_expect(rolling > 4.0, "should be rolling before the brake test (%.2f m/s)" % rolling)
	# Same camera, stick fully back.
	_stick(0.0, -1.0)
	await _steps(45)
	_clear_input()
	_expect(_skater.speed < rolling * 0.5,
		"pulling back should brake hard (%.2f -> %.2f m/s)" % [rolling, _skater.speed])

## The character's root has to point along the board, or every forward-moving
## animation plays across the deck -- which is exactly what went wrong before.
func _test_character_faces_along_the_board() -> void:
	_reset()
	await _steps(4)
	var board: Node3D = _skater.get_node("BoardPivot")
	var character: Node3D = _skater.get_node("BoardPivot/CharacterPivot")
	# The rig faces +Z, so its forward in world terms is +basis.z.
	var rig_forward: Vector3 = character.global_transform.basis.z
	var board_forward: Vector3 = -board.global_transform.basis.z
	var error := rad_to_deg(rig_forward.angle_to(board_forward))
	_expect(error < 5.0,
		"character root should face the board's nose (off by %.1f deg)" % error)

## Trucks compress on landing and spring back rather than staying squashed.
func _test_landing_compresses_the_trucks() -> void:
	_reset()
	_skater.global_position = Vector3(0.0, 2.5, 6.0)
	_skater.velocity = Vector3(0.0, -6.0, 0.0)
	_skater.state = SkaterController.State.AIR
	var lowest := 0.0
	var settled := 0
	for i in range(80):
		await _step()
		lowest = minf(lowest, _skater.compression)
		if _skater.state == SkaterController.State.ROLL and i > 10:
			settled += 1
			if settled > 12:
				break
	_expect(lowest < -0.01, "landing should load the trucks (dipped %.3f m)" % lowest)
	await _steps(90)
	_expect(absf(_skater.compression) < 0.01,
		"the suspension should settle back (%.3f m)" % _skater.compression)

## The feet have to be *on* the deck, not near it. The leg solver is closed
## form, so this can be checked to the millimetre rather than eyeballed -- and it
## is checked across the whole crouch range, because joint angles that look fine
## standing still are exactly what used to drift off the board under load.
func _test_feet_land_on_the_deck() -> void:
	var lean = _skater.get_node("Animator").lean
	_expect(lean != null, "the animator should install the skate pose modifier")
	if lean == null:
		return

	var cases := {
		"at rest": func(): pass,
		"rolling": func(): _stick_toward(Vector3.FORWARD),
		"loading an ollie": func(): Controls.touch_ollie = true,
	}
	for label in cases:
		_reset()
		(cases[label] as Callable).call()
		await _steps(70)
		_clear_input()
		await _steps(2)

		var solved: Dictionary = lean.solved_ankles()
		var wanted: Dictionary = lean.foot_targets()
		var worst := 0.0
		for side in wanted:
			if solved.has(side):
				worst = maxf(worst, (solved[side] as Vector3).distance_to(wanted[side] as Vector3))
		_expect(worst < 0.01,
			"leg solver should hit its foot targets %s (worst %.1f mm)" % [label, worst * 1000.0])

	# The soles have to be on the deck surface, not a fixed distance off it.
	for label in cases:
		_reset()
		(cases[label] as Callable).call()
		await _steps(70)
		_clear_input()
		await _steps(2)
		# Wait for the push stroke to actually end: the pushing foot is *meant* to
		# leave the deck, so measuring it mid-stroke would assert the opposite of
		# what the push is for.
		for i in range(120):
			if _skater.push_anim_timer <= 0.0:
				break
			await _step()
		await _steps(8)
		var clearance: Dictionary = lean.sole_clearance()
		_expect(not clearance.is_empty(), "sole clearance should be measurable")
		var worst_gap := 0.0
		for side in clearance:
			worst_gap = maxf(worst_gap, absf(clearance[side] as float))
		_expect(worst_gap < 0.01,
			"soles should sit on the deck %s (worst %.1f mm off)" % [label, worst_gap * 1000.0])

	# ...and the targets themselves have to sit on the board, one over each truck.
	_reset()
	await _steps(30)
	var targets: Dictionary = lean.foot_targets()
	var board_axis_gap := absf((targets["l"] as Vector3).z - (targets["r"] as Vector3).z)
	_expect(board_axis_gap > 0.24 and board_axis_gap < 0.5,
		"feet should straddle the deck along its length (%.2f m apart)" % board_axis_gap)
	_expect(absf((targets["l"] as Vector3).x) < 0.05 and absf((targets["r"] as Vector3).x) < 0.05,
		"feet should sit on the centre line of the deck, not beside it")

## A push has to put one foot on the ground beside the board while the other
## stays planted -- that is the difference between a push and a sideways jog.
func _test_push_reaches_the_ground() -> void:
	var lean = _skater.get_node("Animator").lean
	if lean == null:
		return
	_reset()
	_stick_toward(Vector3.FORWARD)
	var reached := false
	var planted_ok := true
	for i in range(200):
		await _step()
		if _skater.push_phase > 0.4 and _skater.push_phase < 0.6:
			var targets: Dictionary = lean.foot_targets()
			var front: Vector3 = targets["l"]
			var back: Vector3 = targets["r"]
			var frame: Dictionary = lean.deck_frame()
			if back.y < front.y - 0.04 and _off_deck_line(frame, back) > 0.10:
				reached = true
			if _off_deck_line(frame, front) > 0.06:
				planted_ok = false
			if reached:
				break
	_clear_input()
	_expect(reached, "the pushing foot should reach down beside the deck")
	_expect(planted_ok, "the other foot should stay planted on the deck while pushing")

## How far a point sits off the deck's centre line, measured in the board's own
## frame -- the feet have to be judged against the board, not a world axis.
func _off_deck_line(frame: Dictionary, point: Vector3) -> float:
	var rel: Vector3 = point - (frame["origin"] as Vector3)
	var fwd: Vector3 = frame["forward"]
	var up: Vector3 = frame["up"]
	return (rel - fwd * rel.dot(fwd) - up * rel.dot(up)).length()

## Drives the touch HUD with synthetic touch events, because "the joystick does
## not respond" is an input-plumbing bug and no amount of physics testing finds
## it. In particular this covers two thumbs at once, which is what Godot's
## touch/mouse emulation used to break: it mirrors only the first finger, so the
## stick stopped tracking the moment the pop pad was held.
func _test_touch_stick_tracks_every_direction() -> void:
	var hud: Control = _main.get_node("HUD/Root")
	var centre := Vector2(hud.size.x * 0.25, hud.size.y * 0.6)
	var radius: float = hud.stick_radius

	var directions := {
		"forward": Vector2(0.0, -1.0),
		"back": Vector2(0.0, 1.0),
		"left": Vector2(-1.0, 0.0),
		"right": Vector2(1.0, 0.0),
		"diagonal": Vector2(0.7, -0.7),
	}
	for label in directions:
		var screen: Vector2 = directions[label]
		_touch_down(hud, 0, centre)
		_touch_drag(hud, 0, centre + screen * radius)
		# Screen-down is +y but forward on the stick is up, so y inverts.
		var expected := Vector2(screen.x, -screen.y).limit_length(1.0)
		var got: Vector2 = Controls.touch_move
		_expect(got.distance_to(expected) < 0.05,
			"stick %s should read %s (got %s)" % [label, expected, got])
		_touch_up(hud, 0, centre + screen * radius)
		_expect(Controls.touch_move == Vector2.ZERO,
			"lifting the thumb should centre the stick (%s)" % label)

	# Two thumbs at once: steering and the pop pad must not fight each other.
	_touch_down(hud, 0, centre)
	_touch_drag(hud, 0, centre + Vector2(radius, 0.0))
	var pad := Vector2(hud.size.x * 0.75, hud.size.y * 0.6)
	_touch_down(hud, 1, pad)
	_expect(Controls.touch_ollie, "the pop pad should register while steering")
	_touch_drag(hud, 0, centre + Vector2(-radius, 0.0))
	_expect(Controls.touch_move.x < -0.9,
		"the stick should keep tracking with a second thumb down (got %s)" % Controls.touch_move)
	# ...and a flick on release still selects a trick.
	_touch_drag(hud, 1, pad + Vector2(-hud.flick_distance * 2.0, 0.0))
	_touch_up(hud, 1, pad + Vector2(-hud.flick_distance * 2.0, 0.0))
	_expect(not Controls.touch_ollie, "releasing the pad should pop")
	_expect(Controls.touch_trick == "kickflip",
		"flicking left on release should ask for a kickflip (got '%s')" % Controls.touch_trick)
	_touch_up(hud, 0, centre)
	Controls.clear_all()

	# A touch that starts on the pad must never steal the stick, and the reset
	# button must not be swallowed by the pad either.
	_touch_down(hud, 0, pad)
	_expect(Controls.touch_move == Vector2.ZERO,
		"a thumb on the right half should not move the stick")
	_touch_up(hud, 0, pad)
	Controls.clear_all()

func _touch_down(hud: Control, index: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = true
	hud._input(e)

func _touch_up(hud: Control, index: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = false
	hud._input(e)

func _touch_drag(hud: Control, index: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	hud._input(e)

## Guards the clip-name mapping: a renamed animation would silently leave the
## character in a T-pose otherwise.
func _test_animation_tree_built() -> void:
	var animator = _skater.get_node("Animator")
	_expect(animator.anim_tree != null, "the animator should build an AnimationTree")
	if animator.anim_tree == null:
		return
	var sm: AnimationNodeStateMachine = animator.anim_tree.tree_root
	for state_name in ["board", "bail"]:
		_expect(sm.has_node(state_name), "animation state '%s' resolved to a real clip" % state_name)

# -----------------------------------------------------------------------------

func _reset() -> void:
	_clear_input()
	Game.reset_run()
	_skater.global_transform = Game.spawn_transform
	_skater.respawn()
	_skater.velocity = Vector3.ZERO

func _clear_input() -> void:
	Controls.clear_all()

## Pushes the stick in a world direction, as if the camera were behind the
## skater looking that way -- which is what the touch stick resolves to.
func _stick_toward(direction: Vector3, amount := 1.0) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z).normalized()
	Controls.camera_yaw = atan2(-flat.x, -flat.z)
	Controls.touch_move = Vector2(0.0, amount)

func _stick(x: float, y: float) -> void:
	Controls.touch_move = Vector2(x, y)

func _step() -> void:
	await get_tree().physics_frame

func _steps(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame

func _expect(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		_fail(message)

func _fail(message: String) -> void:
	_failures.append(message)
	printerr("  FAIL %s" % message)

func _finish() -> void:
	if _failures.is_empty():
		print("\nSmoke test passed.")
		get_tree().quit(0)
	else:
		printerr("\n%d check(s) failed:" % _failures.size())
		for f in _failures:
			printerr("  - %s" % f)
		get_tree().quit(1)
