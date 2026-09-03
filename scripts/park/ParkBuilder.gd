@tool
class_name ParkBuilder
extends Node3D
## Generates the whole skatepark from code: flat ground, two quarter pipes, a
## bank, a funbox with grindable ledges, and a couple of flat rails.
##
## Building it procedurally keeps the repo free of binary level data, makes the
## layout easy to tweak by hand, and guarantees the collision meshes match the
## visuals exactly -- which matters a lot when the whole game is about riding
## the surface you can see.

@export var rebuild := false:
	set(value):
		rebuild = false
		if is_inside_tree():
			build()

@export_group("Layout")
@export var ground_size := 64.0
@export var quarter_radius := 2.6
@export var quarter_width := 12.0
@export var bank_height := 1.5

const COL_GROUND := Color(0.34, 0.35, 0.38)
const COL_CONCRETE := Color(0.55, 0.55, 0.57)
const COL_RAMP := Color(0.47, 0.49, 0.54)
const COL_LEDGE := Color(0.62, 0.60, 0.55)
const COL_METAL := Color(0.72, 0.74, 0.78)
const COL_LINE := Color(0.85, 0.68, 0.25)

var _mats := {}

func _ready() -> void:
	build()

func build() -> void:
	for c in get_children():
		c.queue_free()
	_build_ground()
	_build_quarter_pipes()
	_build_bank()
	_build_funbox()
	_build_rails()

# -----------------------------------------------------------------------------
# Pieces
# -----------------------------------------------------------------------------

func _build_ground() -> void:
	_add_box(Vector3(ground_size, 1.0, ground_size),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.5, 0.0)), COL_GROUND)
	# A painted lane so speed and turning are readable against a flat surface.
	for i in range(-4, 5):
		var strip := _add_box(Vector3(0.12, 0.02, ground_size - 6.0),
			Transform3D(Basis.IDENTITY, Vector3(float(i) * 4.0, 0.005, 0.0)),
			COL_LINE, false)
		strip.name = "Line%d" % i

## Two facing quarter pipes make a lazy half-pipe: pump one, carry speed to the
## other. This is where the slope-gravity part of the physics gets exercised.
func _build_quarter_pipes() -> void:
	var profile := _quarter_profile(quarter_radius)
	# Yawed so the profile's rise runs along Z and the extrusion spans X.
	_add_extrusion(profile, quarter_width,
		Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(0.0, 0.0, -18.0)),
		COL_RAMP, "QuarterNorth")
	_add_extrusion(profile, quarter_width,
		Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(0.0, 0.0, 18.0)),
		COL_RAMP, "QuarterSouth")
	# Coping: a grindable lip along the top of each transition.
	var lip := quarter_radius
	_add_rail(Vector3(-quarter_width * 0.5, lip + 0.03, -18.0 - quarter_radius),
		Vector3(quarter_width * 0.5, lip + 0.03, -18.0 - quarter_radius), "CopingNorth", 0.055)
	_add_rail(Vector3(-quarter_width * 0.5, lip + 0.03, 18.0 + quarter_radius),
		Vector3(quarter_width * 0.5, lip + 0.03, 18.0 + quarter_radius), "CopingSouth", 0.055)

func _build_bank() -> void:
	var profile := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(5.0, bank_height),
		Vector2(6.2, bank_height), Vector2(6.2, 0.0)])
	_add_extrusion(profile, 9.0,
		Transform3D(Basis(Vector3.UP, PI), Vector3(-16.0, 0.0, 0.0)),
		COL_CONCRETE, "BankWest")

## Centrepiece: a low box with grindable ledges down both long edges and a
## kicker on each end, so it can be ollied onto or grinded across.
func _build_funbox() -> void:
	var h := 0.55
	var w := 3.6
	var l := 8.0
	_add_box(Vector3(w, h, l), Transform3D(Basis.IDENTITY, Vector3(9.0, h * 0.5, 0.0)),
		COL_CONCRETE).name = "FunboxTop"

	for side: float in [-1.0, 1.0]:
		var x := 9.0 + side * (w * 0.5 - 0.08)
		_add_box(Vector3(0.22, 0.16, l),
			Transform3D(Basis.IDENTITY, Vector3(x, h + 0.06, 0.0)), COL_LEDGE)
		_add_rail(Vector3(x, h + 0.15, -l * 0.5), Vector3(x, h + 0.15, l * 0.5),
			"FunboxLedge%s" % ("L" if side < 0.0 else "R"), 0.06, true)

	# Kicker ramps at both ends.
	var kicker := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(2.4, h), Vector2(2.4, 0.0)])
	_add_extrusion(kicker, w,
		Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(9.0, 0.0, -l * 0.5 - 2.4)),
		COL_RAMP, "KickerNorth")
	_add_extrusion(kicker, w,
		Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(9.0, 0.0, l * 0.5 + 2.4)),
		COL_RAMP, "KickerSouth")

func _build_rails() -> void:
	# Flat bar on the ground, the classic first grind.
	_add_rail_with_posts(Vector3(-9.0, 0.45, -6.0), Vector3(-9.0, 0.45, 6.0), "FlatRail")
	# Down-rail: starts on the funbox side and slopes to the floor.
	_add_rail_with_posts(Vector3(3.0, 1.3, -7.0), Vector3(3.0, 0.35, 1.0), "DownRail")

# -----------------------------------------------------------------------------
# Primitives
# -----------------------------------------------------------------------------

func _material(color: Color) -> StandardMaterial3D:
	if _mats.has(color):
		return _mats[color]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	m.metallic = 0.0
	# Cheap on mobile: no specular, no per-pixel extras.
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_mats[color] = m
	return m

func _add_box(size: Vector3, xform: Transform3D, color: Color, collide := true) -> Node3D:
	var body := StaticBody3D.new()
	body.transform = xform
	body.collision_layer = 1 if collide else 0
	body.collision_mask = 0
	add_child(body)

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = _material(color)
	body.add_child(mi)

	if collide:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
	return body

## Quarter-pipe profile in the XY plane: a concave arc rising to the coping,
## then a vertical back and a flat base to close the polygon.
func _quarter_profile(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	const SEGMENTS := 10
	for i in range(SEGMENTS + 1):
		var a := (PI * 0.5) * float(i) / float(SEGMENTS)
		pts.append(Vector2(-r * sin(a), r * (1.0 - cos(a))))
	pts.append(Vector2(-r - 0.5, r))
	pts.append(Vector2(-r - 0.5, 0.0))
	return pts

## Extrudes a closed 2D profile along +Z and builds matching trimesh collision.
func _add_extrusion(profile: PackedVector2Array, width: float, xform: Transform3D,
		color: Color, node_name: String) -> Node3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.transform = xform
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)

	# Outward-facing normals depend on winding, so force CCW up front.
	if _signed_area(profile) < 0.0:
		profile = _reversed(profile)

	var n := profile.size()
	var z0 := -width * 0.5
	var z1 := width * 0.5
	var tris := PackedVector3Array()

	# Side walls, one quad per profile edge. Godot treats clockwise-wound
	# triangles as front-facing, which is the opposite of the right-hand rule --
	# get this backwards and rays (and the skater) fall straight through the ramp.
	for i in range(n):
		var a := profile[i]
		var b := profile[(i + 1) % n]
		var p0 := Vector3(a.x, a.y, z0)
		var p1 := Vector3(b.x, b.y, z0)
		var p2 := Vector3(b.x, b.y, z1)
		var p3 := Vector3(a.x, a.y, z1)
		tris.append_array([p0, p2, p1, p0, p3, p2])

	# End caps.
	var cap := Geometry2D.triangulate_polygon(profile)
	for i in range(0, cap.size(), 3):
		var a := profile[cap[i]]
		var b := profile[cap[i + 1]]
		var c := profile[cap[i + 2]]
		tris.append_array([
			Vector3(a.x, a.y, z0), Vector3(b.x, b.y, z0), Vector3(c.x, c.y, z0)])
		tris.append_array([
			Vector3(a.x, a.y, z1), Vector3(c.x, c.y, z1), Vector3(b.x, b.y, z1)])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	arrays[Mesh.ARRAY_NORMAL] = _face_normals(tris)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material(color)
	body.add_child(mi)

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return body

func _signed_area(poly: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(poly.size()):
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		total += a.x * b.y - b.x * a.y
	return total * 0.5

func _reversed(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(poly.size() - 1, -1, -1):
		out.append(poly[i])
	return out

func _face_normals(tris: PackedVector3Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(tris.size())
	for i in range(0, tris.size(), 3):
		# Matches the clockwise winding above, so shading normals face outward.
		var n := (tris[i + 2] - tris[i]).cross(tris[i + 1] - tris[i])
		n = n.normalized() if n.length_squared() > 0.000001 else Vector3.UP
		normals[i] = n
		normals[i + 1] = n
		normals[i + 2] = n
	return normals

func _add_rail(from_pos: Vector3, to_pos: Vector3, node_name: String,
		radius := 0.05, is_ledge := false) -> Rail:
	var rail := Rail.new()
	rail.name = node_name
	rail.radius = radius
	rail.is_ledge = is_ledge
	rail.material = _material(COL_METAL)
	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(to_pos - from_pos)
	rail.curve = curve
	rail.position = from_pos
	add_child(rail)
	return rail

func _add_rail_with_posts(from_pos: Vector3, to_pos: Vector3, node_name: String) -> Rail:
	var rail := _add_rail(from_pos, to_pos, node_name, 0.05)
	for t: float in [0.06, 0.5, 0.94]:
		var p: Vector3 = from_pos.lerp(to_pos, t)
		_add_box(Vector3(0.08, p.y, 0.08),
			Transform3D(Basis.IDENTITY, Vector3(p.x, p.y * 0.5, p.z)), COL_METAL, false)
	return rail
