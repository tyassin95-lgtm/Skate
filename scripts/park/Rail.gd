@tool
class_name Rail
extends Node3D
## A grindable edge: a round rail or the lip of a ledge.
##
## The curve is authored in local space; the grind system queries it in world
## space. Building the visual from the same curve means what you see is exactly
## what you grind.

@export var curve: Curve3D:
	set(value):
		curve = value
		if is_inside_tree():
			_rebuild()
## Ledges are wider and sit on top of a block; rails are thin round bars.
@export var is_ledge := false:
	set(value):
		is_ledge = value
		if is_inside_tree():
			_rebuild()
@export var radius := 0.05
@export var material: Material

var _mesh: MeshInstance3D

func _ready() -> void:
	add_to_group(&"rails")
	_rebuild()

func _rebuild() -> void:
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		add_child(_mesh)
	if curve == null or curve.point_count < 2 or is_ledge:
		# A ledge's visual is the block itself, so there is nothing to draw.
		_mesh.mesh = null
		return
	_mesh.mesh = _build_tube()
	if material:
		_mesh.material_override = material

## Sweeps a low-poly ring along the curve. Six sides is plenty at this scale and
## keeps the whole park in a handful of draw calls on mobile.
func _build_tube() -> ArrayMesh:
	const SIDES := 6
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var length := curve.get_baked_length()
	var steps := maxi(2, int(length / 0.5) + 1)

	for s in range(steps + 1):
		var offset := length * float(s) / float(steps)
		var centre := curve.sample_baked(offset)
		var tangent := _tangent_at(offset)
		var side := tangent.cross(Vector3.UP)
		if side.length_squared() < 0.001:
			side = Vector3.RIGHT
		side = side.normalized()
		var up := side.cross(tangent).normalized()
		for i in range(SIDES):
			var a := TAU * float(i) / float(SIDES)
			var dir := side * cos(a) + up * sin(a)
			verts.append(centre + dir * radius)
			normals.append(dir)

	for s in range(steps):
		for i in range(SIDES):
			var i0 := s * SIDES + i
			var i1 := s * SIDES + (i + 1) % SIDES
			var i2 := (s + 1) * SIDES + i
			var i3 := (s + 1) * SIDES + (i + 1) % SIDES
			# Clockwise, to match Godot's front-face winding.
			indices.append_array([i0, i1, i2, i1, i3, i2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _tangent_at(offset: float) -> Vector3:
	var length := curve.get_baked_length()
	var d := 0.05
	var a := curve.sample_baked(clampf(offset - d, 0.0, length))
	var b := curve.sample_baked(clampf(offset + d, 0.0, length))
	var t := b - a
	if t.length_squared() < 0.000001:
		return Vector3.FORWARD
	return t.normalized()

## Nearest point on this rail to a world-space position.
## Returns {"offset", "position", "tangent", "distance"}.
func query(world_point: Vector3) -> Dictionary:
	var local := to_local(world_point)
	var offset := curve.get_closest_offset(local)
	var local_pos := curve.sample_baked(offset)
	var local_tan := _tangent_at(offset)
	var world_pos := to_global(local_pos)
	return {
		"offset": offset,
		"position": world_pos,
		"tangent": (global_transform.basis * local_tan).normalized(),
		"distance": world_point.distance_to(world_pos),
	}

func length() -> float:
	return curve.get_baked_length() if curve else 0.0

func point_at(offset: float) -> Vector3:
	return to_global(curve.sample_baked(clampf(offset, 0.0, length())))

func tangent_at(offset: float) -> Vector3:
	return (global_transform.basis * _tangent_at(clampf(offset, 0.0, length()))).normalized()
