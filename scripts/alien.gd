extends CharacterBody2D
## The invasive alien. It cannot be killed - only stunned (3 s) - and it is lethal on contact
## unless stunned. Hunts the player with grid pathfinding (see main.gd nav_path()).
## When the shaft opens it is swept along the corridors towards the vacuum and ejected.

enum S { DORMANT, HUNT, SUCKED, EJECTED }

const RADIUS := 19.0
const ACCEL := 420.0
const SUCK_SPEED := 300.0
const MESH_GRID := 14           # wobble mesh resolution (cells per side)
const SPRITE_HEIGHT := 104.0    # drawn size of the alien sprite (the hit circle stays RADIUS)

var main
var state: int = S.DORMANT
var base_speed := 140.0          # grows slightly with every repaired system
var wake_t := 7.0                # grace period at the start of the game
var stun_left := 0.0
var path := PackedVector2Array()
var repath_t := 0.0
var anim := 0.0
var eject_t := 0.0
var mesh := ArrayMesh.new()      # re-built every frame so the artwork ripples (see _draw_animated)


func _ready() -> void:
	collision_layer = 2   # layer 2: alien
	collision_mask = 1    # walls only (it does not physically block the player; contact kills)
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	cs.shape = circle
	add_child(cs)


# ---------------------------------------------------------------- public API
func stun(seconds: float) -> void:
	if state == S.EJECTED:
		return
	stun_left = seconds


func is_lethal() -> bool:
	return (state == S.HUNT or state == S.SUCKED) and stun_left <= 0.0


func is_targetable() -> bool:
	return state != S.EJECTED


func start_sucked() -> void:
	state = S.SUCKED
	repath_t = 0.0


func status_text() -> String:
	if state == S.EJECTED:
		return "EJECTED INTO SPACE"
	if stun_left > 0.0:
		return "STUNNED %.1fs" % stun_left
	match state:
		S.DORMANT:
			return "DORMANT"
		S.SUCKED:
			return "BEING SUCKED OUT"
	return "HUNTING"


# ---------------------------------------------------------------- simulation
func _physics_process(delta: float) -> void:
	anim += delta
	if main == null or main.player == null:
		return
	if stun_left > 0.0:
		stun_left = maxf(0.0, stun_left - delta)

	match state:
		S.DORMANT:
			wake_t -= delta
			velocity = velocity.move_toward(Vector2(sin(anim * 0.7), cos(anim * 0.5)) * 25.0, 60.0 * delta)
			if wake_t <= 0.0:
				state = S.HUNT
				main.show_message("Something is moving in the station... it's hunting you!", 4.0)
		S.HUNT:
			_hunt(delta)
		S.SUCKED:
			_sucked(delta)
		S.EJECTED:
			_ejected(delta)
			queue_redraw()
			return

	var col := move_and_collide(velocity * delta)
	if col:
		velocity = velocity.bounce(col.get_normal()) * 0.5
	queue_redraw()


func _hunt(delta: float) -> void:
	if stun_left > 0.0:
		# Stunned: no thrust at all, just coasting to a halt.
		velocity = velocity.move_toward(Vector2.ZERO, 120.0 * delta)
		return
	var target: Vector2 = main.player.global_position
	repath_t -= delta
	if repath_t <= 0.0:
		repath_t = 0.2
		path = main.nav_path(global_position, target)

	var goal := global_position
	if global_position.distance_to(target) < 160.0 and _clear_line(target):
		goal = target
	elif path.size() > 1:
		goal = path[1]
		if global_position.distance_to(goal) < 10.0 and path.size() > 2:
			goal = path[2]
	var desired := (goal - global_position).normalized() * base_speed
	velocity = velocity.move_toward(desired, ACCEL * delta)


func _sucked(delta: float) -> void:
	repath_t -= delta
	if repath_t <= 0.0:
		repath_t = 0.25
		path = main.nav_path(global_position, main.shaft_goal)
	var goal: Vector2 = main.shaft_pos
	if path.size() > 1 and global_position.distance_to(main.shaft_pos) > 80.0:
		goal = path[1]
		if global_position.distance_to(goal) < 10.0 and path.size() > 2:
			goal = path[2]
	velocity = velocity.move_toward((goal - global_position).normalized() * SUCK_SPEED, 900.0 * delta)
	if global_position.distance_to(main.shaft_pos) < 48.0:
		state = S.EJECTED
		eject_t = 0.0
		collision_layer = 0
		collision_mask = 0
		main.on_alien_ejected()


func _ejected(delta: float) -> void:
	eject_t += delta
	position += Vector2.RIGHT * (320.0 + eject_t * 600.0) * delta
	rotation += 9.0 * delta
	scale = Vector2.ONE * maxf(0.05, 1.0 - eject_t * 0.45)


func _clear_line(target: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, target, 1)
	return space.intersect_ray(query).is_empty()


# ---------------------------------------------------------------- drawing
func _draw() -> void:
	var tex: Texture2D = main.tex_alien if main != null else null
	if tex == null:
		_draw_fallback()
		return
	var stunned := stun_left > 0.0
	var bob := sin(anim * (1.5 if stunned else 5.0))

	# glow behind the creature so the dark sprite reads against the dim station
	if stunned:
		draw_circle(Vector2.ZERO, 34.0, Color(0.4, 0.9, 1.0, 0.14))
		draw_circle(Vector2.ZERO, 22.0, Color(0.4, 0.9, 1.0, 0.16))
	elif state == S.DORMANT:
		draw_circle(Vector2.ZERO, 30.0, Color(0.9, 0.55, 0.1, 0.12))
	else:
		draw_circle(Vector2.ZERO, 36.0 + 3.0 * bob, Color(1.0, 0.1, 0.2, 0.13))
		draw_circle(Vector2.ZERO, 24.0 + 2.0 * bob, Color(1.0, 0.1, 0.2, 0.17))

	# the artwork faces left; mirror it so the alien always looks toward the player
	var flip := 1.0
	if main != null and main.player != null and main.player.global_position.x > global_position.x:
		flip = -1.0
	var tint := Color.WHITE
	if stunned:
		tint = Color(0.55, 0.85, 1.0)
	elif state == S.DORMANT:
		tint = Color(0.7, 0.7, 0.8)
	_draw_animated(tex, tint, flip, stunned)

	if stunned:
		for k in 5:
			var a2 := randf() * TAU
			var p1 := Vector2.from_angle(a2) * randf_range(18.0, 38.0)
			var p2 := p1 + Vector2.from_angle(a2 + randf_range(-0.8, 0.8)) * randf_range(8.0, 16.0)
			draw_line(p1, p2, Color(0.6, 0.95, 1.0), 2.0)
		draw_arc(Vector2.ZERO, 50.0, -PI * 0.5, -PI * 0.5 + TAU * stun_left / 3.0, 28, Color(0.4, 0.9, 1.0), 3.0)


## Draws the artwork as a grid mesh whose vertices ripple: the further a point is from the body,
## the more it sways, so tentacles, claws and tail wave while the torso breathes. A stunned alien
## twitches slowly. The body also leans against its own velocity.
func _draw_animated(tex: Texture2D, tint: Color, flip: float, stunned: bool) -> void:
	var t := anim * (1.5 if stunned else 4.0)
	var amp := 0.3 if stunned else 1.0
	var h := SPRITE_HEIGHT * (1.0 + 0.03 * sin(t * 0.7))
	var w := SPRITE_HEIGHT * tex.get_size().x / tex.get_size().y
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in MESH_GRID + 1:
		for i in MESH_GRID + 1:
			var u := float(i) / MESH_GRID
			var v := float(j) / MESH_GRID
			var dist := Vector2(u - 0.5, (v - 0.5) * 0.9).length()
			var wgt := smoothstep(0.1, 0.6, dist)
			var dx := sin(t + v * 7.0 + u * 3.0) * 6.0 * wgt * amp
			var dy := cos(t * 0.8 + u * 6.0 + v * 2.0) * 4.0 * wgt * amp
			dx += sin(t * 2.3 + v * 12.0) * 1.6 * amp                    # fine shudder everywhere
			dx -= velocity.x * 0.04 * (1.0 - v)                           # head lags behind the motion
			dy -= velocity.y * 0.03 * (1.0 - v)
			verts.append(Vector2(((u - 0.5) * w + dx) * flip, (v - 0.5) * h + dy - 2.0))
			uvs.append(Vector2(u, v))
	for j in MESH_GRID:
		for i in MESH_GRID:
			var a0 := j * (MESH_GRID + 1) + i
			var a1 := a0 + 1
			var a2 := a0 + MESH_GRID + 1
			var a3 := a2 + 1
			idx.append_array([a0, a1, a2, a1, a3, a2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	draw_mesh(mesh, tex, Transform2D.IDENTITY, tint)


# Original procedural alien, used only if the sprite is missing.
func _draw_fallback() -> void:
	var stunned := stun_left > 0.0
	var body := Color(0.11, 0.2, 0.15)
	var glow := Color(1.0, 0.15, 0.2)
	if stunned:
		body = Color(0.2, 0.3, 0.5)
		glow = Color(0.4, 0.9, 1.0)
	elif state == S.DORMANT:
		glow = Color(0.7, 0.45, 0.1)

	var speed_anim := 1.0 if stunned else 5.0
	for i in 9:
		var a := TAU * float(i) / 9.0 + anim * (0.1 if stunned else 0.4)
		var dir := Vector2.from_angle(a)
		var pts := PackedVector2Array()
		for j in 5:
			var t := float(j) / 4.0
			var wave := sin(anim * speed_anim + float(i) * 1.7 + t * 4.0) * (5.0 + 9.0 * t)
			pts.append(dir * (RADIUS * 0.6 + t * 26.0) + dir.orthogonal() * wave)
		draw_polyline(pts, body.lightened(0.12), 4.0, true)

	draw_circle(Vector2.ZERO, RADIUS, body)
	draw_circle(Vector2(-6, 5), 5.0, body.lightened(0.15))
	draw_circle(Vector2(7, -7), 3.5, body.lightened(0.15))

	var look := Vector2.RIGHT
	if main != null and main.player != null:
		look = (main.player.global_position - global_position).normalized()
		look = look.rotated(-rotation)
	for off in [Vector2(-6, -4), Vector2(6, -4), Vector2(0, 4)]:
		var p: Vector2 = off + look * 3.0
		draw_circle(p, 4.2, Color(0, 0, 0))
		draw_circle(p, 3.0, glow)

	if stunned:
		for k in 4:
			var a2 := randf() * TAU
			var p1 := Vector2.from_angle(a2) * RADIUS
			var p2 := p1 + Vector2.from_angle(a2 + randf_range(-0.8, 0.8)) * randf_range(8.0, 16.0)
			draw_line(p1, p2, Color(0.6, 0.95, 1.0), 2.0)
		draw_arc(Vector2.ZERO, RADIUS + 12.0, -PI * 0.5, -PI * 0.5 + TAU * stun_left / 3.0, 28, Color(0.4, 0.9, 1.0), 3.0)
