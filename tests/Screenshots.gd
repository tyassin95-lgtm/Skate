extends Node
## Renders a few reference frames of the prototype so visual regressions show up
## without needing a device or an editor.
##
## Run with:
##   xvfb-run -a godot --path . --rendering-driver opengl3 \
##     --resolution 1280x720 res://tests/Screenshots.tscn
##
## PNGs are written next to the project directory.

const OUT_DIR := "res://../"

var _main: Node3D
var _skater: SkaterController

func _ready() -> void:
	_run()

func _run() -> void:
	_main = (load("res://scenes/Main.tscn") as PackedScene).instantiate()
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	await get_tree().physics_frame
	_skater = _main.get_node("Skater")

	await _shot_rolling()
	await _shot_trick()
	await _shot_stance()
	await _shot_ramp()
	get_tree().quit(0)

func _shot_rolling() -> void:
	Controls.touch_push = true
	await _physics(100)
	Controls.touch_push = false
	await _save("roll")

func _shot_trick() -> void:
	Controls.touch_ollie = true
	await _physics(25)
	Controls.touch_ollie = false
	Controls.touch_trick = "kickflip"
	await _physics(14)
	await _save("trick")

## Freezes the skater and orbits the camera so the riding pose is legible.
func _shot_stance() -> void:
	await _physics(60)  # let the landing and push animations settle
	var rig: Node3D = _main.get_node("CameraRig")
	var camera: Camera3D = rig.get_node("Camera3D")
	rig.set_physics_process(false)
	_skater.set_physics_process(false)
	camera.fov = 40

	var origin := _skater.global_position
	var views := {
		"stance_side": Vector3(3.0, 0.9, 0.0),   # perpendicular to the deck
		"stance_front": Vector3(0.0, 0.9, 3.0),  # down the direction of travel
	}
	for shot_name in views:
		rig.global_position = origin + (views[shot_name] as Vector3)
		rig.look_at(origin + Vector3.UP * 0.5, Vector3.UP)
		await _save(shot_name)

	camera.fov = 68.0
	rig.set_physics_process(true)
	_skater.set_physics_process(true)

func _shot_ramp() -> void:
	_skater.global_position = Vector3(0.0, 0.05, -12.0)
	_skater.heading = PI
	_skater.velocity = Vector3(0.0, 0.0, -9.0)
	await _physics(40)
	await _save("ramp")

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
