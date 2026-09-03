extends Node3D
## Wires the scene together: records the spawn point the respawn system falls
## back to and hands the HUD its skater.

@onready var skater: SkaterController = $Skater
@onready var hud: Control = $HUD/Root

func _ready() -> void:
	Game.reset_run()
	Game.set_spawn(skater.global_transform)
	hud.call(&"setup", skater)
