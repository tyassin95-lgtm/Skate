extends Node
## Autoload holding cross-scene state: the active checkpoint, run stats and the
## signals the HUD listens to. Kept deliberately small -- this is a prototype.

signal trick_landed(trick_name: String, points: int)
signal bailed(reason: String)
signal respawned()

const RESPAWN_DELAY := 1.4

var spawn_transform := Transform3D.IDENTITY
var checkpoint_transform := Transform3D.IDENTITY
var has_checkpoint := false

var score := 0
var best_combo := 0

func set_spawn(xform: Transform3D) -> void:
	spawn_transform = xform
	checkpoint_transform = xform
	has_checkpoint = true

## Called whenever the skater is rolling safely, so a bail sends them somewhere
## sensible instead of all the way back to the park entrance.
func update_checkpoint(xform: Transform3D) -> void:
	checkpoint_transform = xform
	has_checkpoint = true

func respawn_transform() -> Transform3D:
	return checkpoint_transform if has_checkpoint else spawn_transform

func award(trick_name: String, points: int) -> void:
	score += points
	trick_landed.emit(trick_name, points)

func reset_run() -> void:
	score = 0
	best_combo = 0
	checkpoint_transform = spawn_transform
