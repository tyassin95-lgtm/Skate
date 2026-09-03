class_name SkaterController
extends CharacterBody3D
## Physics-driven skateboard controller.
##
## The body itself stays upright and world-aligned -- only `BoardPivot` tilts to
## match the surface, which keeps collision behaviour predictable on transitions
## while the visuals still hug the ramps.
##
## Velocity is integrated by hand rather than handed to a rigid body so that the
## four forces that decide how skating feels -- tangential gravity, rolling
## resistance, lateral grip and steering -- stay separately tunable.

signal state_changed(new_state: int)
signal trick_started(trick_name: String)
signal trick_landed(trick_name: String, points: int)
signal bailed(reason: String)
signal pushed()
signal landed(impact: float)

enum State { ROLL, AIR, GRIND, BAIL }

# --- speed / rolling ---------------------------------------------------------
@export_group("Rolling")
## One push adds this much speed, like kicking off the ground.
@export var push_impulse := 3.2
## Pushes stop helping past this speed; you have to find a ramp instead.
@export var push_top_speed := 13.0
@export var push_interval := 0.55
@export var brake_decel := 12.0
## Constant drag from bearings/urethane (m/s^2).
@export var rolling_resistance := 0.55
## Quadratic air drag coefficient.
@export var drag := 0.014
@export var max_speed := 26.0

# --- steering ----------------------------------------------------------------
@export_group("Steering")
@export var max_turn_rate := 2.6          # rad/s at the carving sweet spot
@export var pivot_turn_rate := 1.9        # rad/s kick-turn when nearly stopped
@export var carve_speed_ref := 5.0        # speed where steering is most responsive
@export var high_speed_turn_scale := 0.42 # steering authority retained at max_speed
## How hard the wheels resist sliding sideways. Higher = railed, lower = loose.
@export var grip := 14.0
@export var powerslide_grip := 2.2
## Speed bled off by carving hard, as a fraction of speed per second.
@export var carve_drag := 0.30

# --- air / ollie -------------------------------------------------------------
@export_group("Air")
@export var gravity := 18.0
@export var ollie_min_impulse := 4.6
@export var ollie_max_impulse := 8.2
@export var ollie_charge_time := 0.42
## Blend between "straight up" and "off the ramp normal" when popping.
@export_range(0.0, 1.0) var ollie_normal_bias := 0.55
@export var coyote_time := 0.12
@export var air_turn_rate := 2.0
@export var air_drag := 0.06
## Landing steeper than this relative to the surface is a bail.
@export_range(0.0, 90.0) var land_angle_tolerance := 48.0
@export var land_speed_keep := 0.94
## How far off the surface plane the velocity may point and still be treated as
## riding along it rather than slamming into it. Roughly sin(angle).
@export_range(0.05, 1.0) var redirect_limit := 0.5

# --- probing -----------------------------------------------------------------
@export_group("Ground probing")
@export var ride_height := 0.07
@export var probe_length := 0.9
@export var wheelbase := 0.34
@export var track_width := 0.13
## How far a wheel may be off the surface and still count as contact. This is
## also how far the skater will snap down to hug a ramp.
@export var ground_tolerance := 0.18

@export_group("Bounds")
## Below this height the skater has fallen out of the world entirely.
@export var fall_limit := -8.0
## Horizontal distance from the park centre that counts as leaving the area.
@export var park_radius := 34.0

@onready var board_pivot: Node3D = $BoardPivot
@onready var _probe_root: Node3D = $Probes
@onready var trick_system: TrickSystem = $TrickSystem
@onready var grind_system: GrindSystem = $GrindSystem

var state: State = State.ROLL
var heading := 0.0                  ## world yaw of the board, radians
var ground_normal := Vector3.UP
var surface_up := Vector3.UP        ## smoothed normal used for visuals
var speed := 0.0
var grounded := false
var crouch := 0.0                   ## 0..1, drives the ollie charge and animation
var powersliding := false
var push_anim_timer := 0.0

const PROBE_HEIGHT := 0.35

var _probes: Array[RayCast3D] = []
var _ground_gap := INF
var _ground_lockout := 0.0
var _time_since_grounded := 0.0
var _push_cooldown := 0.0
var _bail_timer := 0.0
var _checkpoint_timer := 0.0
var _last_ground_speed := 0.0

func _ready() -> void:
	# Grounded motion mode is built for walking: it discards the velocity along
	# the up axis every tick, which on a steep transition throws away almost all
	# of the skater's speed and leaves them crawling instead of dropping in.
	# Floating mode does pure sliding collision and lets the wheel probes below
	# decide what counts as ground.
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	up_direction = Vector3.UP
	_build_probes()
	heading = rotation.y
	Game.set_spawn(global_transform)

## Five downward rays (centre plus the four wheel positions) averaged into one
## normal. A single ray pops between facets where ramps meet flat ground.
func _build_probes() -> void:
	var offsets := [
		Vector3.ZERO,
		Vector3(track_width, 0.0, -wheelbase),
		Vector3(-track_width, 0.0, -wheelbase),
		Vector3(track_width, 0.0, wheelbase),
		Vector3(-track_width, 0.0, wheelbase),
	]
	for o in offsets:
		var ray := RayCast3D.new()
		ray.position = o + Vector3.UP * PROBE_HEIGHT
		ray.target_position = Vector3.DOWN * probe_length
		ray.collision_mask = 1
		ray.enabled = true
		ray.exclude_parent = true
		_probe_root.add_child(ray)
		_probes.append(ray)

func _physics_process(delta: float) -> void:
	_push_cooldown = maxf(0.0, _push_cooldown - delta)
	push_anim_timer = maxf(0.0, push_anim_timer - delta)
	_ground_lockout = maxf(0.0, _ground_lockout - delta)

	if Controls.respawn_pressed:
		respawn()
		return

	_sample_ground()

	match state:
		State.ROLL:
			_process_roll(delta)
		State.AIR:
			_process_air(delta)
		State.GRIND:
			grind_system.process_grind(delta)
		State.BAIL:
			_process_bail(delta)

	speed = velocity.length()
	_update_visual_orientation(delta)
	_track_checkpoint(delta)
	_check_bounds()

# -----------------------------------------------------------------------------
# Ground sampling
# -----------------------------------------------------------------------------

func _sample_ground() -> void:
	var normal_sum := Vector3.ZERO
	var hits := 0
	var gap := INF
	for ray in _probes:
		ray.force_raycast_update()
		if not ray.is_colliding():
			continue
		hits += 1
		normal_sum += ray.get_collision_normal()
		# Height of the body origin above the surface under this wheel.
		gap = minf(gap, ray.global_position.y - ray.get_collision_point().y - PROBE_HEIGHT)
	if hits > 0:
		ground_normal = (normal_sum / float(hits)).normalized()
	else:
		# Ease back to level so the board doesn't stay cocked at the lip angle.
		ground_normal = ground_normal.lerp(Vector3.UP, 0.12).normalized()

	_ground_gap = gap
	grounded = hits > 0 and gap <= ground_tolerance and _ground_lockout <= 0.0
	if grounded:
		_time_since_grounded = 0.0

## Pulls the skater down onto the surface so the wheels stay on a ramp instead
## of skipping off every bump. Only ever pulls down, and never while popping.
func _snap_to_ground() -> void:
	if not grounded or _ground_gap <= 0.002 or _ground_gap == INF:
		return
	if velocity.dot(ground_normal) > 0.5:
		return
	global_position.y -= _ground_gap

## Board forward, projected onto whatever we are standing on.
func forward_on_surface() -> Vector3:
	var flat := Basis(Vector3.UP, heading) * Vector3.FORWARD
	var n := ground_normal if grounded else Vector3.UP
	var f := flat - n * flat.dot(n)
	if f.length_squared() < 0.0001:
		return flat
	return f.normalized()

# -----------------------------------------------------------------------------
# Rolling
# -----------------------------------------------------------------------------

func _process_roll(delta: float) -> void:
	if not grounded:
		_enter_air(false)
		_process_air(delta)
		return

	var n := ground_normal
	var fwd := forward_on_surface()
	var right := fwd.cross(n).normalized()

	_project_onto_surface(n)

	# Tangential gravity -- this is what makes ramps and banks pump speed.
	velocity += (Vector3.DOWN * gravity).slide(n) * delta

	var v_fwd := velocity.dot(fwd)
	var v_lat := velocity.dot(right)
	var spd := absf(v_fwd)

	# --- steering ------------------------------------------------------------
	var steer := Controls.steer
	var turn := _turn_rate(spd) * steer
	if v_fwd < -0.5:
		turn = -turn  # rolling backwards inverts the steering, as it should
	heading = wrapf(heading + turn * delta, -PI, PI)

	# --- push / brake --------------------------------------------------------
	if Controls.push and _push_cooldown <= 0.0 and spd < push_top_speed:
		v_fwd += push_impulse * (1.0 - clampf(spd / push_top_speed, 0.0, 1.0) * 0.55)
		_push_cooldown = push_interval
		push_anim_timer = 0.45
		pushed.emit()

	powersliding = Controls.brake and absf(steer) > 0.4 and spd > 3.0
	if Controls.brake:
		v_fwd = move_toward(v_fwd, 0.0, brake_decel * delta)

	# --- resistance ----------------------------------------------------------
	v_fwd = move_toward(v_fwd, 0.0, rolling_resistance * delta)
	v_fwd -= v_fwd * absf(v_fwd) * drag * delta
	# Carving scrubs speed the way leaning into a turn really does.
	v_fwd -= v_fwd * absf(steer) * carve_drag * delta
	v_fwd = clampf(v_fwd, -max_speed * 0.5, max_speed)

	# --- lateral grip --------------------------------------------------------
	var g := powerslide_grip if powersliding else grip
	v_lat = lerpf(v_lat, 0.0, clampf(g * delta, 0.0, 1.0))

	velocity = fwd * v_fwd + right * v_lat + n * velocity.dot(n)
	_last_ground_speed = absf(v_fwd)

	# --- ollie charge --------------------------------------------------------
	if Controls.ollie_held:
		crouch = minf(1.0, crouch + delta / ollie_charge_time)
	else:
		crouch = maxf(0.0, crouch - delta * 5.0)
	if Controls.ollie_just_released:
		_do_ollie()
		return

	# Requesting a trick on the ground just pops with it queued.
	var queued := Controls.consume_trick()
	if queued != "":
		_do_ollie()
		trick_system.request(queued)
		return

	move_and_slide()
	_sample_ground()
	_snap_to_ground()
	if grind_system.try_enter_grind():
		return
	if not grounded:
		_enter_air(false)

## Constrains velocity to the surface.
##
## Simply dropping the normal component bleeds speed on every curved surface,
## because a transition's normal rotates a little each tick and the truncation
## eats the difference -- a quarter pipe would swallow most of your speed on the
## way up and give none of it back. A frictionless normal force does no work, so
## while the skater is genuinely riding along the surface the direction is
## constrained but the speed is carried through. Arriving at a steep angle is a
## real impact, and there the normal component is simply dropped.
func _project_onto_surface(n: Vector3) -> void:
	var incoming := velocity.length()
	if incoming < 0.01:
		return
	var tangential := velocity.slide(n)
	var into_surface := -velocity.dot(n)
	if into_surface < incoming * redirect_limit and tangential.length() > 0.001:
		velocity = tangential.normalized() * incoming
	else:
		velocity = tangential

func _turn_rate(spd: float) -> float:
	if spd < 0.6:
		return pivot_turn_rate
	var ramp_up := clampf(spd / carve_speed_ref, 0.0, 1.0)
	var falloff := clampf((spd - carve_speed_ref) / maxf(1.0, max_speed - carve_speed_ref), 0.0, 1.0)
	return max_turn_rate * ramp_up * lerpf(1.0, high_speed_turn_scale, falloff)

func _do_ollie() -> void:
	var pop_dir := Vector3.UP.lerp(ground_normal, ollie_normal_bias).normalized()
	var power := lerpf(ollie_min_impulse, ollie_max_impulse, crouch)
	velocity += pop_dir * power
	crouch = 0.0
	# Stop the wheel probes from re-grounding us on the frame we pop.
	_ground_lockout = 0.12
	grounded = false
	_enter_air(true)

# -----------------------------------------------------------------------------
# Air
# -----------------------------------------------------------------------------

func _enter_air(from_pop: bool) -> void:
	if state == State.AIR:
		return
	state = State.AIR
	if not from_pop:
		_time_since_grounded = 0.0
	state_changed.emit(state)

func _process_air(delta: float) -> void:
	_time_since_grounded += delta

	# Coyote time: a pop just after the lip still counts.
	if Controls.ollie_just_released and _time_since_grounded < coyote_time:
		_do_ollie()

	velocity += Vector3.DOWN * gravity * delta
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	horiz -= horiz * air_drag * delta
	velocity = Vector3(horiz.x, velocity.y, horiz.z)

	heading = wrapf(heading + Controls.steer * air_turn_rate * delta, -PI, PI)
	crouch = maxf(0.0, crouch - delta * 4.0)

	var queued := Controls.consume_trick()
	if queued != "":
		trick_system.request(queued)

	move_and_slide()
	_sample_ground()

	if grind_system.try_enter_grind():
		return
	# Only a descent into the surface is a landing; brushing past a wall is not.
	if grounded and velocity.dot(ground_normal) <= 0.0:
		_try_land()

func _try_land() -> void:
	var n := ground_normal
	var board_up := board_pivot.global_transform.basis.y
	var angle := rad_to_deg(board_up.angle_to(n))

	if angle > land_angle_tolerance:
		bail("landed sideways")
		return
	if not trick_system.can_land():
		bail("didn't catch the board")
		return

	var impact := absf(velocity.dot(n))
	# Keep the tangential speed, drop the part that went into the ground.
	velocity -= n * velocity.dot(n)
	velocity *= land_speed_keep

	# Steep landings scrub more, so dropping in doesn't feel free.
	var steep := clampf(impact / 14.0, 0.0, 0.5)
	velocity *= (1.0 - steep * 0.35)

	trick_system.finish_landing()
	_snap_to_ground()
	state = State.ROLL
	state_changed.emit(state)
	landed.emit(impact)

# -----------------------------------------------------------------------------
# Bail / respawn
# -----------------------------------------------------------------------------

func bail(reason: String) -> void:
	if state == State.BAIL:
		return
	state = State.BAIL
	_bail_timer = Game.RESPAWN_DELAY
	trick_system.abort()
	grind_system.exit_grind()
	crouch = 0.0
	velocity *= 0.45
	bailed.emit(reason)
	Game.bailed.emit(reason)
	state_changed.emit(state)

func _process_bail(delta: float) -> void:
	velocity += Vector3.DOWN * gravity * delta
	var horiz := Vector3(velocity.x, 0.0, velocity.z)
	horiz = horiz.move_toward(Vector3.ZERO, 9.0 * delta)
	velocity = Vector3(horiz.x, velocity.y, horiz.z)
	move_and_slide()
	_bail_timer -= delta
	if _bail_timer <= 0.0:
		respawn()

func respawn() -> void:
	var xform := Game.respawn_transform()
	global_transform = xform
	velocity = Vector3.ZERO
	speed = 0.0
	crouch = 0.0
	heading = xform.basis.get_euler().y
	ground_normal = Vector3.UP
	surface_up = Vector3.UP
	trick_system.abort()
	grind_system.exit_grind()
	state = State.ROLL
	state_changed.emit(state)
	Game.respawned.emit()

## Remember a spot to come back to, but only while genuinely rolling along, so
## the checkpoint never lands mid-air or halfway up a wall.
func _track_checkpoint(delta: float) -> void:
	if state != State.ROLL or not grounded or speed < 1.5:
		_checkpoint_timer = 0.0
		return
	if ground_normal.dot(Vector3.UP) < 0.9:
		_checkpoint_timer = 0.0
		return
	_checkpoint_timer += delta
	if _checkpoint_timer > 1.0:
		_checkpoint_timer = 0.0
		var xform := Transform3D(Basis(Vector3.UP, heading), global_position + Vector3.UP * 0.1)
		Game.update_checkpoint(xform)

## Falling out of the world resets immediately; skating off the edge of the park
## is treated as a bail so it reads as a mistake rather than a teleport.
func _check_bounds() -> void:
	if global_position.y < fall_limit:
		respawn()
		return
	if Vector2(global_position.x, global_position.z).length() > park_radius:
		bail("left the skate area")

# -----------------------------------------------------------------------------
# Visuals
# -----------------------------------------------------------------------------

func _update_visual_orientation(delta: float) -> void:
	var target_up := ground_normal if (grounded or state == State.GRIND) else Vector3.UP
	# In the air the board keeps some of the lip's angle before levelling out.
	surface_up = surface_up.lerp(target_up, clampf(delta * (14.0 if grounded else 4.0), 0.0, 1.0)).normalized()

	var flat := Basis(Vector3.UP, heading) * Vector3.FORWARD
	var fwd := flat - surface_up * flat.dot(surface_up)
	if fwd.length_squared() < 0.0001:
		fwd = flat
	fwd = fwd.normalized()

	var z_axis := -fwd
	var x_axis := surface_up.cross(z_axis)
	if x_axis.length_squared() < 0.0001:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()

	var target := Basis(x_axis, y_axis, z_axis)
	# Lean into the carve; visual only, but it sells the grip model.
	var lean := -Controls.steer * clampf(speed / 10.0, 0.0, 1.0) * 0.45
	target = target * Basis(Vector3.FORWARD, lean)

	board_pivot.global_transform = Transform3D(
		board_pivot.global_transform.basis.slerp(target, clampf(delta * 16.0, 0.0, 1.0)),
		global_position + Vector3.UP * ride_height)

func surface_speed() -> float:
	return _last_ground_speed
