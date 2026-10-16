extends CharacterBody2D
## The last survivor. Zero-gravity thrust movement (arrow keys), stun weapon (Z).
## Interaction (SPACE) is handled by main.gd so that all "hold to use" logic lives in one place.

const THRUST := 460.0          # acceleration from the arrow keys (px/s^2)
const MAX_SPEED := 250.0
const DRAG := 0.25             # tiny damping so the player is controllable, still very "floaty"
const RADIUS := 14.0
const STUN_SECONDS := 3.0      # RULE: a stun lasts exactly 3 seconds
const STUN_COOLDOWN := 0.9
const BOLT_SPEED := 820.0
const BOLT_RANGE := 620.0
const AIM_TURN_DEG := 300.0    # aim sweeps smoothly (deg/s) toward the held arrow direction -> any angle, not just 8
const AIM_ASSIST_DEG := 28.0   # arrow-keys-only aiming gets a gentle cone of assistance

var main
var facing := Vector2.RIGHT
var suit_on := false
var dead := false
var cooldown := 0.0
var spin := 0.0                # tumble angle after death

# Tether / decompression (set by main.gd once the shaft is opened)
var tethered := false
var tether_anchor := Vector2.ZERO
var tether_len := 200.0
var pull_target := Vector2.ZERO
var pull_strength := 0.0

var bolts: Array = []
var flashes: Array = []
var puffs: Array = []


func _ready() -> void:
	collision_layer = 4   # layer 3: player
	collision_mask = 1    # collides with station walls only
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # keep the pixel-art astronaut crisp
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS
	cs.shape = circle
	add_child(cs)


func cooldown_ratio() -> float:
	return 1.0 - clampf(cooldown / STUN_COOLDOWN, 0.0, 1.0)


func set_suit(value: bool) -> void:
	suit_on = value


func die() -> void:
	dead = true
	velocity += Vector2.from_angle(randf() * TAU) * 60.0


func _physics_process(delta: float) -> void:
	cooldown = maxf(0.0, cooldown - delta)
	_update_fx(delta)
	if dead:
		spin += delta * 2.5
		move_and_collide(velocity * delta)
		queue_redraw()
		return

	var input := Vector2(Input.get_axis("left", "right"), Input.get_axis("up", "down"))
	if input != Vector2.ZERO:
		var dir := input.normalized()
		velocity += dir * THRUST * delta
		# Aim turns smoothly toward the held direction instead of snapping to it, so a short tap
		# leaves the aim at any angle in between (full 360 degrees with only the arrow keys).
		var max_step := deg_to_rad(AIM_TURN_DEG) * delta
		facing = facing.rotated(clampf(facing.angle_to(dir), -max_step, max_step)).normalized()
		_add_puff(-dir)

	if pull_strength > 0.0:
		velocity += (pull_target - global_position).normalized() * pull_strength * delta

	velocity = velocity.limit_length(MAX_SPEED)
	velocity *= maxf(0.0, 1.0 - DRAG * delta)

	var col := move_and_collide(velocity * delta)
	if col:
		velocity = velocity.bounce(col.get_normal()) * 0.45

	_apply_tether()

	if Input.is_action_just_pressed("stun"):
		_fire()
	_update_bolts(delta)
	queue_redraw()


func _apply_tether() -> void:
	if not tethered:
		return
	var off := global_position - tether_anchor
	var excess := off.length() - tether_len
	if excess > 0.0:
		var dir := off.normalized()
		move_and_collide(-dir * excess)
		var radial := velocity.dot(dir)
		if radial > 0.0:
			velocity -= dir * radial


# ---------------------------------------------------------------- stun weapon
func _fire() -> void:
	if cooldown > 0.0:
		return
	cooldown = STUN_COOLDOWN
	var dir := facing
	var a = main.alien if main != null else null
	if a != null and a.is_targetable():
		var to: Vector2 = a.global_position - global_position
		if to.length() < BOLT_RANGE and absf(facing.angle_to(to)) < deg_to_rad(AIM_ASSIST_DEG):
			dir = to.normalized()
	bolts.append({"pos": global_position, "dir": dir, "dist": 0.0})
	velocity -= dir * 40.0   # tiny recoil - it is zero-g after all


func _update_bolts(delta: float) -> void:
	var space := get_world_2d().direct_space_state
	var i := bolts.size() - 1
	while i >= 0:
		var b: Dictionary = bolts[i]
		var step := BOLT_SPEED * delta
		var from: Vector2 = b.pos
		var to: Vector2 = from + (b.dir as Vector2) * step
		var query := PhysicsRayQueryParameters2D.create(from, to, 3)  # walls (1) + alien (2)
		var hit := space.intersect_ray(query)
		var finished := false
		if hit:
			var c = hit.collider
			if c != null and c.has_method("stun"):
				c.stun(STUN_SECONDS)
			b.pos = hit.position
			finished = true
		else:
			b.pos = to
			b.dist += step
			if b.dist > BOLT_RANGE:
				finished = true
		if finished:
			flashes.append({"pos": b.pos, "t": 1.0})
			bolts.remove_at(i)
		i -= 1


func _add_puff(dir: Vector2) -> void:
	if puffs.size() > 40:
		return
	puffs.append({
		"pos": global_position + dir * 12.0 + Vector2(randf_range(-3, 3), randf_range(-3, 3)),
		"vel": dir * randf_range(60.0, 120.0) + velocity * 0.3,
		"life": 1.0,
	})


func _update_fx(delta: float) -> void:
	for p in puffs:
		p.pos += p.vel * delta
		p.life -= delta * 2.5
	puffs = puffs.filter(func(p): return p.life > 0.0)
	for f in flashes:
		f.t -= delta * 4.0
	flashes = flashes.filter(func(f): return f.t > 0.0)


# ---------------------------------------------------------------- drawing
func _draw() -> void:
	# tether rope
	if tethered:
		var a := to_local(tether_anchor)
		var slack := maxf(0.0, tether_len - (global_position - tether_anchor).length())
		var c := a * 0.5 + Vector2(0.0, slack * 0.8)
		var pts := PackedVector2Array()
		for i in 13:
			var t := float(i) / 12.0
			pts.append(c * 2.0 * (1.0 - t) * t + a * t * t)
		draw_polyline(pts, Color(1.0, 0.85, 0.3), 2.5, true)
		draw_circle(a, 5.0, Color(1.0, 0.85, 0.3))

	for p in puffs:
		draw_circle(to_local(p.pos), 2.0 + 3.0 * (1.0 - p.life), Color(0.7, 0.9, 1.0, p.life * 0.5))

	var tex: Texture2D = main.tex_astronaut if main != null else null
	if tex != null:
		# pixel-art astronaut: leans into the thrust direction, tinted until the real spacesuit is on
		var tilt := clampf(velocity.x / MAX_SPEED, -1.0, 1.0) * 0.35
		var tint := Color.WHITE if suit_on else Color(0.62, 0.76, 1.0)
		if dead:
			tilt = spin
			tint = tint.darkened(0.5)
		draw_set_transform(Vector2.ZERO, tilt, Vector2.ONE)
		draw_texture(tex, -tex.get_size() * 0.5, tint)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if suit_on:
			draw_arc(Vector2.ZERO, 27.0, 0.0, TAU, 28, Color(1.0, 0.5, 0.1, 0.8), 2.0)
	else:
		_draw_fallback_body()

	if not dead:
		for k in 5:
			draw_circle(facing * (34.0 + 12.0 * k), 1.6 + 0.15 * k, Color(0.4, 0.9, 1.0, 0.65 - 0.1 * k))
		var tip := facing * 98.0
		draw_arc(tip, 6.0, 0.0, TAU, 16, Color(0.4, 0.9, 1.0, 0.7), 1.5)
		draw_line(tip - facing.orthogonal() * 10.0, tip + facing.orthogonal() * 10.0, Color(0.4, 0.9, 1.0, 0.5), 1.5)

	for b in bolts:
		var head := to_local(b.pos)
		var dir: Vector2 = b.dir
		draw_line(head - dir * 30.0, head, Color(0.3, 0.9, 1.0, 0.8), 5.0)
		draw_line(head - dir * 30.0, head, Color.WHITE, 1.5)
		draw_circle(head, 6.0, Color(0.5, 0.95, 1.0, 0.5))
	for f in flashes:
		draw_circle(to_local(f.pos), 8.0 + (1.0 - f.t) * 16.0, Color(0.5, 0.9, 1.0, f.t * 0.7))


func _draw_fallback_body() -> void:
	var perp := facing.orthogonal()
	var suit_col := Color(0.93, 0.94, 0.97) if suit_on else Color(0.35, 0.5, 0.75)
	if dead:
		suit_col = suit_col.darkened(0.5)
	draw_circle(-facing * 9.0, 8.0, Color(0.55, 0.58, 0.62))       # life-support pack
	draw_circle(Vector2.ZERO, 13.0, suit_col)                         # body
	if suit_on:
		draw_arc(Vector2.ZERO, 12.0, 0.0, TAU, 24, Color(1.0, 0.5, 0.1), 3.0)
	draw_circle(facing * 6.0, 9.0, Color(0.95, 0.95, 1.0))            # helmet
	draw_circle(facing * 8.0, 6.0, Color(0.1, 0.2, 0.4))              # visor
	draw_circle(facing * 9.5 - perp * 2.0, 1.8, Color(1, 1, 1, 0.9))  # glint
