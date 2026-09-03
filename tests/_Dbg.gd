extends Node
func _ready() -> void: _run()
func _run() -> void:
	var m = load("res://scenes/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(m)
	await get_tree().process_frame
	await get_tree().physics_frame
	Controls.camera_yaw = 0.0
	Controls.touch_move = Vector2(0, 1)
	for i in range(200): await get_tree().physics_frame
	get_tree().quit(0)
