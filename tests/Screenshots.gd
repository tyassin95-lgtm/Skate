extends Node
## Renders reference frames of the whole riding loop so alignment and pose
## regressions show up without needing a device or an editor.
##
## Run with:
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##     --resolution 1280x720 res://tests/Screenshots.tscn
##
## PNGs are written next to the project directory.

const OUT_DIR := "res://../"

var _main: Node3D
var _skater: SkaterController
var _rig: Node3D
var _camera: Camera3D

func _ready() -> void:
	_run()

func _run() -> void:
	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	await get_tree().physics_frame
	_skater = _main.get_node("Skater")
	_rig = _main.get_node("CameraRig")
	_camera = _rig.get_node("Camera3D")

	await _shot_rolling()
	await _shot_push_stroke()
	await _shot_carving()
	await _shot_air()
	await _shot_landing()
	get_tree().quit(0)

func _ride(frames: int) -> void:
	Controls.touch_move = Vector2(0.0, 1.0)
	await _physics(frames)

func _shot_rolling() -> void:
	await _ride(110)
	Controls.touch_move = Vector2.ZERO
	await _save("roll")
	await _orbit("stance")

## Caught mid-stroke, so the pushing leg should be down at the ground and the
## planted foot still on the deck.
func _shot_push_stroke() -> void:
	_reset_to_flat()
	Controls.touch_move = Vector2(0.0, 1.0)
	# Step until the stroke is around halfway through its sweep.
	for i in range(200):
		await get_tree().physics_frame
		if _skater.push_phase > 0.45 and _skater.push_phase < 0.6 and _skater.speed > 2.0:
			break
	await _save("push")
	await _orbit("push_stance")
	Controls.touch_move = Vector2.ZERO

func _shot_carving() -> void:
	_reset_to_flat()
	await _ride(90)
	Controls.touch_move = Vector2(0.85, 0.5)
	await _physics(50)
	await _save("carve")
	Controls.touch_move = Vector2.ZERO

func _shot_air() -> void:
	_reset_to_flat()
	await _ride(90)
	Controls.touch_ollie = true
	await _physics(28)
	Controls.touch_ollie = false
	await _physics(16)
	await _save("air")
	await _orbit("air_stance")

func _shot_landing() -> void:
	_reset_to_flat()
	_skater.global_position = Vector3(0.0, 2.2, 6.0)
	_skater.velocity = Vector3(0.0, -5.0, -6.0)
	_skater.state = SkaterController.State.AIR
	for i in range(120):
		await get_tree().physics_frame
		if _skater.compression < -0.02:
			break
	await _save("land")

func _reset_to_flat() -> void:
	Controls.clear_all()
	Game.reset_run()
	_skater.global_transform = Game.spawn_transform
	_skater.respawn()

## Freezes everything and looks at the skater from the side and the front, which
## is the only way to check the board and body actually line up.
func _orbit(prefix: String) -> void:
	_rig.set_physics_process(false)
	_skater.set_physics_process(false)
	var was_fov := _camera.fov
	_camera.fov = 40
	var origin := _skater.global_position
	var heading := _skater.heading
	var fwd := Basis(Vector3.UP, heading) * Vector3.FORWARD
	var side := fwd.cross(Vector3.UP).normalized()
	for shot in {"_side": side * 3.0, "_behind": -fwd * 3.2}:
		_rig.global_position = origin + (({"_side": side * 3.0, "_behind": -fwd * 3.2}[shot]) as Vector3) + Vector3.UP * 0.9
		_rig.look_at(origin + Vector3.UP * 0.55, Vector3.UP)
		await _save(prefix + shot)
	_camera.fov = was_fov
	_rig.set_physics_process(true)
	_skater.set_physics_process(true)

func _physics(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame

func _save(shot_name: String) -> void:
	for i in range(3):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path("%sshot_%s.png" % [OUT_DIR, shot_name]))
	print("saved shot_%s.png" % shot_name)
