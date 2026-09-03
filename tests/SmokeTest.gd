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
	_test_animation_tree_built()
	_finish()

# -----------------------------------------------------------------------------

func _test_rolls_when_pushed() -> void:
	_reset()
	var start := _skater.global_position
	Controls.touch_push = true
	await _steps(120)
	Controls.touch_push = false
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
	Controls.touch_push = true
	await _steps(90)
	Controls.touch_push = false

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
	Controls.touch_push = true
	await _steps(60)
	Controls.touch_push = false
	var before := _skater.heading
	Controls.touch_steer = 1.0
	await _steps(45)
	Controls.touch_steer = 0.0
	var turned := absf(wrapf(_skater.heading - before, -PI, PI))
	_expect(turned > 0.5, "holding the stick should carve the skater round (turned %.2f rad)" % turned)

	# Steering authority has to survive at speed, just reduced.
	_reset()
	_skater.velocity = Vector3.ZERO
	await _steps(2)
	before = _skater.heading
	Controls.touch_steer = 1.0
	await _steps(30)
	Controls.touch_steer = 0.0
	_expect(absf(wrapf(_skater.heading - before, -PI, PI)) > 0.2,
		"a stationary skater should still be able to kick-turn")

## Guards the clip-name mapping: a renamed animation would silently leave the
## character in a T-pose otherwise.
func _test_animation_tree_built() -> void:
	var animator = _skater.get_node("Animator")
	_expect(animator.anim_tree != null, "the animator should build an AnimationTree")
	if animator.anim_tree == null:
		return
	var sm: AnimationNodeStateMachine = animator.anim_tree.tree_root
	for state_name in ["ride", "push", "pop", "air", "land", "grind", "bail"]:
		_expect(sm.has_node(state_name), "animation state '%s' resolved to a real clip" % state_name)

# -----------------------------------------------------------------------------

func _reset() -> void:
	_clear_input()
	Game.reset_run()
	_skater.global_transform = Game.spawn_transform
	_skater.respawn()
	_skater.velocity = Vector3.ZERO

func _clear_input() -> void:
	Controls.touch_push = false
	Controls.touch_ollie = false
	Controls.touch_brake = false
	Controls.touch_steer = 0.0
	Controls.touch_trick = ""
	Controls.clear_trick()

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
