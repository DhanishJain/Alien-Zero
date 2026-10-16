extends Node2D
## ISS: LAST SURVIVOR - main controller.
## Builds the station from rectangles, runs the repair / airlock / decompression sequence,
## the HUD and the win / death / restart flow. Sprites (alien, astronaut) and the station-interior
## floor art live in res://assets/; everything else (walls, consoles, door, FX) is drawn procedurally.

const TS := 48          # tile size in pixels
const W := 58           # map width in tiles
const H := 32           # map height in tiles
const PlayerScript := preload("res://scripts/player.gd")
const AlienScript := preload("res://scripts/alien.gd")
const FaceInputScript := preload("res://scripts/face_input.gd")
const ART_ALIEN := "res://assets/alien.png"
const ART_ASTRONAUT := "res://assets/astronaut.png"
const ART_BACKGROUND := "res://assets/space_bg.jpg"      # portrait space scene, drifts slowly behind the station
const ART_INTERIOR := "res://assets/iss_interior.jpg"   # exactly map-sized (W*TS x H*TS)
const INTERIOR_TINT := Color(0.80, 0.82, 0.90)            # slight dimming so sprites and HUD stay readable

enum State { PLAYING, DECOMPRESSION, WON, DEAD }

var state: State = State.PLAYING
var time := 0.0
var shake := 0.0

var grid: Array = []         # grid[y][x]: 0 floor, 1 wall, 2 airlock door
var near_floor: Array = []   # wall tiles that touch floor (these get collision + drawing)
var astar := AStarGrid2D.new()

var tex_alien: Texture2D
var tex_astronaut: Texture2D
var tex_interior: Texture2D
var tex_bg: Texture2D
var bg: Node2D               # screen-space animated background (lives on a CanvasLayer behind the level)
var bg_glow: Node2D          # additive second nebula layer + star glints (deeper parallax)
var bg_t := 0.0
var shooting: Dictionary = {}
var next_shot := 6.0

var player
var alien
var face: Node               # webcam face-control receiver (UDP) -> same input actions as the keys
var camera: Camera2D
var dyn: Node2D              # animated layer (consoles, door, hatch, debris)
var door_body: StaticBody2D

var door_open := false
var suit_on := false
var shaft_open := false
var alien_out := false
var alien_out_t := 0.0
var death_timer := 0.0
var death_reason := ""
var win_t := 0.0

var interactables: Array = []
var debris: Array = []
var stars: Array = []

# World positions of airlock features (airlock interior is tiles x 44..55, y 2..12)
var shaft_pos := Vector2(56.0 * TS, 7.5 * TS)      # the hatch in the east wall
var shaft_goal := Vector2(55.5 * TS, 7.5 * TS)     # floor cell right in front of it
var lever_pos := Vector2(53.5 * TS, 2.5 * TS)      # tether anchor + shaft release lever

# HUD
var hud_objectives: Label
var hud_message: Label
var hud_prompt: Label
var hud_status: Label
var hud_controls: Label
var hud_face: Label
var hud_progress: ProgressBar
var hud_stun: ProgressBar
var hud_alarm: ColorRect
var hud_overlay: ColorRect
var hud_title: Label
var hud_sub: Label
var message_time := 0.0


func _ready() -> void:
	randomize()
	_load_art()
	_setup_input()
	face = FaceInputScript.new()
	add_child(face)
	_build_grid()
	_build_collision()
	_build_nav()
	_build_decor()
	_build_interactables()
	dyn = Node2D.new()
	dyn.draw.connect(_draw_dynamic)
	add_child(dyn)
	_spawn_actors()
	_build_hud()
	show_message("SYSTEMS CRITICAL. Repair all 5 systems, then reach the airlock.", 7.0)


# ====================================================================== art
## Loads a texture from res://. Uses the imported resource when available and falls back to reading
## the PNG straight from disk (e.g. a headless run before the first import). Returns null if missing.
func load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			return t
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null or img.is_empty():
		push_warning("Missing art: " + path)
		return null
	return ImageTexture.create_from_image(img)


func _load_art() -> void:
	tex_alien = load_tex(ART_ALIEN)
	tex_astronaut = load_tex(ART_ASTRONAUT)
	tex_interior = load_tex(ART_INTERIOR)
	tex_bg = load_tex(ART_BACKGROUND)


# ====================================================================== input
func _setup_input() -> void:
	# RULE: the player may ONLY use the arrow keys, Z and SPACE.
	var keys := {
		"left": KEY_LEFT, "right": KEY_RIGHT, "up": KEY_UP, "down": KEY_DOWN,
		"stun": KEY_Z, "interact": KEY_SPACE,
	}
	for action in keys:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.keycode = keys[action]
		InputMap.action_add_event(action, ev)


# ====================================================================== level
func _carve(x0: int, y0: int, x1: int, y1: int) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			grid[y][x] = 0


func _build_grid() -> void:
	grid = []
	for y in H:
		var row := []
		row.resize(W)
		row.fill(1)
		grid.append(row)
	_carve(2, 2, 15, 10)     # Habitat module
	_carve(21, 2, 36, 10)    # Laboratory
	_carve(2, 17, 15, 27)    # Engine room
	_carve(21, 17, 36, 27)   # Life support
	_carve(44, 2, 55, 12)    # Airlock / outside access area
	_carve(16, 5, 20, 7)     # corridor Habitat <-> Lab
	_carve(8, 11, 10, 16)    # corridor Habitat <-> Engine
	_carve(27, 11, 29, 16)   # corridor Lab <-> Life support
	_carve(16, 21, 20, 23)   # corridor Engine <-> Life support
	_carve(37, 5, 42, 7)     # corridor Lab <-> Airlock
	for y in range(5, 8):
		grid[y][43] = 2      # airlock door (locked until everything is repaired)

	near_floor = []
	for y in H:
		var row := []
		for x in W:
			var near := false
			if grid[y][x] == 1:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var nx: int = x + dx
						var ny: int = y + dy
						if nx >= 0 and nx < W and ny >= 0 and ny < H and grid[ny][nx] != 1:
							near = true
			row.append(near)
		near_floor.append(row)


func _wall_near(x: int, y: int) -> bool:
	return grid[y][x] == 1 and near_floor[y][x]


func _add_box(body: StaticBody2D, origin: Vector2, size: Vector2) -> void:
	var cs := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = size
	cs.shape = rs
	cs.position = origin + size * 0.5
	body.add_child(cs)


func _build_collision() -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	# Greedy-merge wall tiles into big rectangles (fewer shapes, no snagging on seams).
	var used := []
	for y in H:
		var r := []
		r.resize(W)
		r.fill(false)
		used.append(r)
	for y in H:
		for x in W:
			if used[y][x] or not _wall_near(x, y):
				continue
			var w := 1
			while x + w < W and not used[y][x + w] and _wall_near(x + w, y):
				w += 1
			var h := 1
			var ok := true
			while ok and y + h < H:
				for xx in range(x, x + w):
					if used[y + h][xx] or not _wall_near(xx, y + h):
						ok = false
						break
				if ok:
					h += 1
			for yy in range(y, y + h):
				for xx in range(x, x + w):
					used[yy][xx] = true
			_add_box(body, Vector2(x * TS, y * TS), Vector2(w * TS, h * TS))
	# Airlock door
	door_body = StaticBody2D.new()
	door_body.collision_layer = 1
	door_body.collision_mask = 0
	add_child(door_body)
	_add_box(door_body, Vector2(43 * TS, 5 * TS), Vector2(TS, 3 * TS))


func _build_nav() -> void:
	astar.region = Rect2i(0, 0, W, H)
	astar.cell_size = Vector2(TS, TS)
	astar.offset = Vector2(TS, TS) * 0.5
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for y in H:
		for x in W:
			if grid[y][x] != 0:
				astar.set_point_solid(Vector2i(x, y), true)


func nav_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a := Vector2i((from / TS).floor())
	var b := Vector2i((to / TS).floor())
	if not astar.is_in_boundsv(a) or not astar.is_in_boundsv(b):
		return PackedVector2Array()
	if astar.is_point_solid(a) or astar.is_point_solid(b):
		return PackedVector2Array()
	return astar.get_point_path(a, b)


func _tile_center(x: float, y: float) -> Vector2:
	return Vector2((x + 0.5) * TS, (y + 0.5) * TS)


func _build_decor() -> void:
	# animated background: a CanvasLayer behind the world, so it never scrolls with the level
	var layer := CanvasLayer.new()
	layer.layer = -10
	add_child(layer)
	bg = Node2D.new()
	bg.draw.connect(_draw_background)
	layer.add_child(bg)
	# second, additively blended layer: mirrored nebula that drifts the other way + star glints
	bg_glow = Node2D.new()
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bg_glow.material = add_mat
	bg_glow.draw.connect(_draw_glow_layer)
	layer.add_child(bg_glow)
	# twinkling stars in screen space (normalised 0..1 positions), three depth bands
	var tints := [Color(0.85, 0.92, 1.0), Color(1.0, 0.95, 0.85), Color(0.7, 0.85, 1.0), Color(1.0, 0.82, 0.8)]
	for i in 230:
		var depth := randf()
		stars.append({
			"p": Vector2(randf(), randf()),
			"s": lerpf(0.5, 2.0, depth),
			"ph": randf() * TAU,
			"sp": randf_range(0.8, 3.4),
			"v": lerpf(2.0, 11.0, depth),
			"d": depth,
			"c": tints[randi() % tints.size()],
		})


func _process(delta: float) -> void:
	bg_t += delta
	if shooting.is_empty():
		next_shot -= delta
		if next_shot <= 0.0:
			next_shot = randf_range(3.5, 9.0)
			shooting = {"p": Vector2(randf_range(0.3, 1.0), randf_range(0.0, 0.5)), "t": 0.0, "len": randf_range(90.0, 170.0)}
	else:
		shooting.t += delta * 1.5
		if shooting.t >= 1.0:
			shooting = {}
	if bg != null:
		bg.queue_redraw()
	if bg_glow != null:
		bg_glow.queue_redraw()


func _bg_parallax(k: float) -> Vector2:
	if player == null:
		return Vector2.ZERO
	return Vector2((player.global_position.x / (W * TS) - 0.5) * k, (player.global_position.y / (H * TS) - 0.5) * k * 0.7)


## Slowly drifting, breathing space scene (cover-fit, panned by time and by the player's position
## for parallax) with depth-layered twinkling stars, a breathing nebula and shooting stars on top.
func _draw_background() -> void:
	var vp := get_viewport_rect().size
	bg.draw_rect(Rect2(Vector2.ZERO, vp), Color(0.005, 0.008, 0.02))
	if tex_bg != null:
		var ts := tex_bg.get_size()
		var cover := maxf(vp.x / ts.x, vp.y / ts.y)
		var zoom := 1.25 + 0.06 * sin(bg_t * 0.13)                      # slow breathing zoom
		var size := ts * cover * zoom
		var par := _bg_parallax(0.35)
		var fx := clampf(0.5 + 0.35 * sin(bg_t * 0.05 + 1.0) + par.x, 0.0, 1.0)
		var fy := clampf(0.5 + 0.42 * sin(bg_t * 0.03) + par.y, 0.0, 1.0)
		var pos := Vector2((vp.x - size.x) * fx, (vp.y - size.y) * fy)
		var pulse := 0.92 + 0.08 * sin(bg_t * 0.6)                       # nebula "breathes" in brightness
		bg.draw_texture_rect(tex_bg, Rect2(pos, size), false, Color(0.9 * pulse, 0.92 * pulse, 1.0 * pulse))
	# stars: far ones barely move, near ones drift faster and shift with the player
	var ppos := Vector2.ZERO
	if player != null:
		ppos = player.global_position
	for s in stars:
		var p: Vector2 = s.p
		var d: float = s.d
		var x := fposmod(p.x * vp.x - bg_t * s.v - ppos.x * 0.04 * d, vp.x)   # drift left
		var y := fposmod(p.y * vp.y + bg_t * s.v * 0.35 - ppos.y * 0.03 * d, vp.y)
		var tw := 0.5 + 0.5 * sin(bg_t * s.sp + s.ph)
		var a := 0.2 + 0.8 * tw
		var c: Color = s.c
		bg.draw_circle(Vector2(x, y), s.s, Color(c.r, c.g, c.b, a * 0.85))
	if not shooting.is_empty():
		var t: float = shooting.t
		var dir := Vector2(-0.8, 0.6).normalized()
		var head: Vector2 = (shooting.p as Vector2) * vp + dir * t * 460.0
		var fade := sin(t * PI)
		var length: float = shooting.len
		for i in 8:                                                       # tapered, fading tail
			var k0 := float(i) / 8.0
			var k1 := float(i + 1) / 8.0
			bg.draw_line(head - dir * length * k0, head - dir * length * k1, Color(0.8, 0.92, 1.0, 0.75 * fade * (1.0 - k0)), 2.6 * (1.0 - k0) + 0.4)
		bg.draw_circle(head, 2.4, Color(1, 1, 1, fade))
		bg.draw_circle(head, 6.0, Color(0.7, 0.85, 1.0, 0.25 * fade))


## Additive layer: a mirrored, larger copy of the nebula drifting the opposite way (fake depth),
## soft colour clouds that pulse, and cross-shaped glints on the brightest stars.
func _draw_glow_layer() -> void:
	var vp := get_viewport_rect().size
	if tex_bg != null:
		var ts := tex_bg.get_size()
		var cover := maxf(vp.x / ts.x, vp.y / ts.y)
		var size := ts * cover * (1.9 + 0.08 * sin(bg_t * 0.09 + 2.0))
		var par := _bg_parallax(-0.8)
		var fx := clampf(0.5 - 0.40 * sin(bg_t * 0.04) + par.x, 0.0, 1.0)
		var fy := clampf(0.5 - 0.45 * sin(bg_t * 0.027 + 0.7) + par.y, 0.0, 1.0)
		var pos := Vector2((vp.x - size.x) * fx, (vp.y - size.y) * fy)
		var a := 0.20 + 0.10 * sin(bg_t * 0.35)
		# negative width mirrors the texture horizontally
		bg_glow.draw_texture_rect(tex_bg, Rect2(pos + Vector2(size.x, 0.0), Vector2(-size.x, size.y)), false, Color(0.55, 0.7, 1.0, a))
	# drifting colour clouds
	for i in 4:
		var f := float(i)
		var c := Vector2(
			vp.x * (0.5 + 0.42 * sin(bg_t * (0.05 + f * 0.013) + f * 1.9)),
			vp.y * (0.5 + 0.40 * cos(bg_t * (0.04 + f * 0.011) + f * 2.6)))
		var col := Color(0.15, 0.3, 0.7) if i % 2 == 0 else Color(0.4, 0.2, 0.6)
		var amp := 0.5 + 0.5 * sin(bg_t * 0.5 + f * 1.3)
		for k in 6:
			bg_glow.draw_circle(c, 260.0 - k * 38.0, Color(col.r, col.g, col.b, 0.012 + 0.010 * amp))
	# glints on bright stars
	for s in stars:
		if s.d < 0.78:
			continue
		var p: Vector2 = s.p
		var d: float = s.d
		var ppos := Vector2.ZERO
		if player != null:
			ppos = player.global_position
		var x := fposmod(p.x * vp.x - bg_t * s.v - ppos.x * 0.04 * d, vp.x)
		var y := fposmod(p.y * vp.y + bg_t * s.v * 0.35 - ppos.y * 0.03 * d, vp.y)
		var tw := maxf(0.0, sin(bg_t * s.sp + s.ph))
		var L := 3.0 + 9.0 * tw
		var c: Color = s.c
		var col := Color(c.r, c.g, c.b, 0.55 * tw)
		bg_glow.draw_line(Vector2(x - L, y), Vector2(x + L, y), col, 1.0)
		bg_glow.draw_line(Vector2(x, y - L), Vector2(x, y + L), col, 1.0)
		bg_glow.draw_circle(Vector2(x, y), 4.0 + 3.0 * tw, Color(c.r, c.g, c.b, 0.12 * tw))


func _build_interactables() -> void:
	var consoles := [
		["Oxygen Generator", Vector2i(4, 3)],
		["Comms Array", Vector2i(34, 3)],
		["Power Core", Vector2i(12, 25)],
		["Coolant Pump", Vector2i(23, 25)],
		["Hull Breach Patch", Vector2i(34, 19)],
	]
	for c in consoles:
		interactables.append({
			"kind": "console", "name": c[0], "pos": _tile_center(c[1].x, c[1].y),
			"progress": 0.0, "done": false, "hold": 2.5, "active": false,
		})
	interactables.append({
		"kind": "locker", "name": "Spacesuit Locker", "pos": _tile_center(45, 11),
		"progress": 0.0, "done": false, "hold": 1.8, "active": false,
	})
	interactables.append({
		"kind": "lever", "name": "Shaft Release Lever", "pos": lever_pos,
		"progress": 0.0, "done": false, "hold": 1.5, "active": false,
	})


func _spawn_actors() -> void:
	alien = AlienScript.new()
	alien.main = self
	alien.position = _tile_center(12, 22)
	add_child(alien)

	player = PlayerScript.new()
	player.main = self
	player.position = _tile_center(5, 8)
	add_child(player)

	camera = Camera2D.new()
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 6.0
	player.add_child(camera)


# ====================================================================== drawing
func _draw() -> void:
	for y in H:
		var x := 0
		while x < W:
			var r := Rect2(x * TS, y * TS, TS, TS)
			if grid[y][x] != 1:
				if tex_interior != null:
					# draw each horizontal run of floor in one go from the interior art (1:1 with the map)
					var x1 := x
					while x1 < W and grid[y][x1] != 1:
						x1 += 1
					var run := Rect2(x * TS, y * TS, (x1 - x) * TS, TS)
					draw_texture_rect_region(tex_interior, run, run, INTERIOR_TINT)
					x = x1
					continue
				var sh := 0.15 + 0.02 * float((x + y) % 2)
				draw_rect(r, Color(sh, sh + 0.02, sh + 0.06))
				draw_rect(r, Color(0, 0, 0, 0.3), false, 1.0)
			x += 1
	# faint hull edge where the floor meets empty space (replaces the old grey brick border)
	var edge := Color(0.55, 0.8, 1.0, 0.35)
	for y in H:
		for x in W:
			if grid[y][x] == 1:
				continue
			var o := Vector2(x * TS, y * TS)
			if y == 0 or grid[y - 1][x] == 1:
				draw_line(o, o + Vector2(TS, 0), edge, 2.0)
			if y == H - 1 or grid[y + 1][x] == 1:
				draw_line(o + Vector2(0, TS), o + Vector2(TS, TS), edge, 2.0)
			if x == 0 or grid[y][x - 1] == 1:
				draw_line(o, o + Vector2(0, TS), edge, 2.0)
			if x == W - 1 or grid[y][x + 1] == 1:
				draw_line(o + Vector2(TS, 0), o + Vector2(TS, TS), edge, 2.0)
	var font := ThemeDB.fallback_font
	var labels := {
		"HABITAT MODULE": Vector2(2, 2), "LABORATORY": Vector2(21, 2),
		"ENGINE ROOM": Vector2(2, 17), "LIFE SUPPORT": Vector2(21, 17),
		"AIRLOCK - OUTSIDE ACCESS": Vector2(44, 2),
	}
	for text in labels:
		var tp: Vector2 = labels[text]
		var lp := Vector2(tp.x * TS + 10, tp.y * TS + 22)
		draw_string_outline(font, lp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, 5, Color(0, 0, 0, 0.75))
		draw_string(font, lp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.85, 0.95, 1.0, 0.9))


func _draw_dynamic() -> void:
	var font := ThemeDB.fallback_font
	var blink := 0.5 + 0.5 * sin(time * 6.0)

	# airlock door
	if not door_open:
		var r := Rect2(43 * TS, 5 * TS, TS, 3 * TS)
		dyn.draw_rect(r, Color(0.35, 0.08, 0.08))
		dyn.draw_rect(r.grow(-6), Color(0.55, 0.12, 0.12))
		dyn.draw_circle(r.get_center(), 8.0, Color(1.0, 0.2, 0.2, 0.3 + 0.7 * blink))
		dyn.draw_string(font, r.position + Vector2(-30, -8), "LOCKED", HORIZONTAL_ALIGNMENT_CENTER, 108, 14, Color(1, 0.4, 0.4))
	else:
		dyn.draw_rect(Rect2(43 * TS, 5 * TS, TS, 3 * TS), Color(0.1, 0.4, 0.2, 0.35))

	# outer hatch / shaft
	var hatch := Rect2(56 * TS - 10, 6 * TS, TS + 10, 3 * TS)
	if not shaft_open:
		dyn.draw_rect(hatch, Color(0.45, 0.45, 0.5))
		for i in 9:
			if i % 2 == 0:
				dyn.draw_rect(Rect2(hatch.position.x, hatch.position.y + i * 16, hatch.size.x, 8), Color(0.9, 0.75, 0.1))
		dyn.draw_string(font, hatch.position + Vector2(-70, -8), "OUTER SHAFT", HORIZONTAL_ALIGNMENT_CENTER, 150, 14, Color(1, 0.9, 0.4))
	else:
		dyn.draw_rect(hatch, Color(0.0, 0.0, 0.02))
		for i in 14:
			var sp := hatch.position + Vector2(fposmod(i * 37.0, hatch.size.x), fposmod(i * 61.0, hatch.size.y))
			dyn.draw_circle(sp, 1.4, Color(1, 1, 1, 0.9))
		dyn.draw_rect(hatch.grow(3), Color(1.0, 0.2, 0.2, 0.25 + 0.4 * blink), false, 3.0)

	# machines: consoles / locker / lever are drawn as animated machinery
	for it in interactables:
		_draw_machine(it, font, blink)

	# vacuum debris streaming to the shaft
	if shaft_open:
		for d in debris:
			dyn.draw_line(d.p, d.p - d.v * 0.04, Color(0.8, 0.8, 0.85, 0.6), d.r * 0.7)
			dyn.draw_circle(d.p, d.r, Color(0.7, 0.72, 0.78))


# ====================================================================== machines
## Deterministic pseudo-random 0..1 from a float sd (no state, so draws stay stable per frame).
func _rnd(x: float) -> float:
	return fposmod(sin(x * 127.1 + 311.7) * 43758.5453, 1.0)


func _glow(c: Vector2, r: float, col: Color) -> void:
	for i in 5:
		dyn.draw_circle(c, r * (1.0 - 0.18 * i), Color(col.r, col.g, col.b, col.a * 0.3))


func _sparks(c: Vector2, sd: float, n: int, col: Color, spread: float) -> void:
	for i in n:
		var ph := fposmod(time * 2.4 + _rnd(sd + i) * 3.0, 1.0)
		if ph > 0.45:
			continue
		var dir := Vector2.from_angle(_rnd(sd + i * 7.1) * TAU)
		var a := 1.0 - ph / 0.45
		var head := c + dir * ph * spread * 2.2 + Vector2(0.0, ph * ph * 24.0)
		dyn.draw_line(head - dir * 5.0, head, Color(col.r, col.g, col.b, a), 1.8)


func _smoke(c: Vector2, sd: float, n: int, col: Color) -> void:
	for i in n:
		var ph := fposmod(time * 0.45 + float(i) / n + _rnd(sd + i) * 0.5, 1.0)
		var pos := c + Vector2(sin(ph * 6.0 + i + sd) * 7.0, -ph * 36.0)
		dyn.draw_circle(pos, 3.0 + ph * 8.0, Color(col.r, col.g, col.b, col.a * (1.0 - ph)))


func _lightning(a: Vector2, b: Vector2, segs: int, jitter: float, col: Color, sd: float) -> void:
	var prev := a
	var step := floorf(time * 14.0)
	for i in range(1, segs + 1):
		var t := float(i) / segs
		var pt := a.lerp(b, t)
		if i < segs:
			pt += Vector2(_rnd(step + i * 3.1 + sd) - 0.5, _rnd(step + i * 5.3 + sd) - 0.5) * jitter
		dyn.draw_line(prev, pt, col, 2.0)
		dyn.draw_line(prev, pt, Color(1, 1, 1, col.a * 0.8), 0.8)
		prev = pt


func _machine_box(p: Vector2, size: Vector2, ok: bool, blink: float) -> void:
	var r := Rect2(p - size * 0.5, size)
	dyn.draw_rect(r.grow(3), Color(0, 0, 0, 0.45))
	dyn.draw_rect(r, Color(0.13, 0.15, 0.2))
	dyn.draw_rect(r.grow(-3), Color(0.19, 0.21, 0.28))
	dyn.draw_rect(Rect2(r.position + Vector2(3, 3), Vector2(size.x - 6, 3)), Color(1, 1, 1, 0.08))   # top bevel
	var edge := Color(0.25, 0.95, 0.5, 0.8) if ok else Color(1.0, 0.25, 0.2, 0.35 + 0.5 * blink)
	dyn.draw_rect(r, edge, false, 2.0)
	for c in [Vector2(5, 5), Vector2(size.x - 5, 5), Vector2(5, size.y - 5), Vector2(size.x - 5, size.y - 5)]:
		dyn.draw_circle(r.position + c, 1.8, Color(0.5, 0.52, 0.6))


func _draw_machine(it: Dictionary, font: Font, blink: float) -> void:
	var p: Vector2 = it.pos
	var kind: String = it.kind
	var ok: bool = it.done
	var prog: float = it.progress
	var act: bool = it.active
	if kind == "console":
		# soft light pool: green when running, pulsing red when broken
		var gc := Color(0.2, 1.0, 0.5, 0.20) if ok else Color(1.0, 0.2, 0.15, 0.08 + 0.12 * blink)
		_glow(p + Vector2(0, 4), 62.0, gc)
		match String(it.name):
			"Oxygen Generator":
				_m_oxygen(p, ok, prog, act, blink)
			"Comms Array":
				_m_comms(p, ok, prog, act, blink)
			"Power Core":
				_m_core(p, ok, prog, act, blink)
			"Coolant Pump":
				_m_coolant(p, ok, prog, act, blink)
			_:
				_m_hull(p, ok, prog, act, blink)
		if not ok and prog > 0.0:
			dyn.draw_arc(p, 46.0, -PI * 0.5, -PI * 0.5 + TAU * prog, 40, Color(0.4, 0.9, 1.0), 4.0)
		dyn.draw_string(font, p + Vector2(-80, 50), it.name, HORIZONTAL_ALIGNMENT_CENTER, 160, 12, Color(1, 1, 1, 0.8))
	elif kind == "locker":
		_m_locker(p, ok, prog, act, blink)
		dyn.draw_string(font, p + Vector2(-60, 48), "SPACESUIT", HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(1, 1, 1, 0.8))
		if prog > 0.0 and not ok:
			dyn.draw_arc(p, 42.0, -PI * 0.5, -PI * 0.5 + TAU * prog, 40, Color(0.4, 0.9, 1.0), 4.0)
	elif kind == "lever":
		_m_lever(p, ok, prog, act, blink)
		dyn.draw_string(font, p + Vector2(-70, 46), "SHAFT LEVER", HORIZONTAL_ALIGNMENT_CENTER, 140, 12, Color(1, 1, 1, 0.8))
		if prog > 0.0 and not ok:
			dyn.draw_arc(p, 40.0, -PI * 0.5, -PI * 0.5 + TAU * prog, 40, Color(0.4, 0.9, 1.0), 4.0)


# ---- Oxygen generator: two tanks that fill and bubble, a turbine fan, vent steam
func _m_oxygen(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	_machine_box(p, Vector2(76, 60), ok, blink)
	var level := 0.92 if ok else 0.10 + prog * 0.75
	for i in 2:
		var tx := p.x - 27.0 + i * 19.0
		var tr := Rect2(tx - 7.0, p.y - 22.0, 14.0, 40.0)
		dyn.draw_rect(tr, Color(0.04, 0.08, 0.13))
		var fh := tr.size.y * level
		var surf := 1.2 * sin(time * 3.0 + i)
		dyn.draw_rect(Rect2(tr.position.x, tr.end.y - fh + surf, tr.size.x, fh - surf), Color(0.2, 0.62, 0.98, 0.78))
		dyn.draw_rect(Rect2(tr.position.x + 2, tr.position.y + 2, 2, tr.size.y - 4), Color(1, 1, 1, 0.18))
		dyn.draw_rect(tr, Color(0.65, 0.82, 1.0, 0.85), false, 1.5)
		if ok or act:
			for b in 4:
				var ph := fposmod(time * 0.8 + b * 0.25 + i * 0.13, 1.0)
				dyn.draw_circle(Vector2(tx + sin(ph * 9.0 + b) * 3.0, tr.end.y - ph * fh), 1.5, Color(0.9, 0.97, 1.0, 0.85 * (1.0 - ph)))
	# turbine
	var fc := p + Vector2(21, -3)
	dyn.draw_circle(fc, 18.0, Color(0.06, 0.07, 0.1))
	var ang := 0.0
	if ok:
		ang = time * 11.0
	elif act:
		ang = time * 4.5
	else:
		ang = sin(time * 3.1) * 0.4                      # jammed, shuddering
	for k in 4:
		var d := Vector2.from_angle(ang + k * TAU / 4.0)
		dyn.draw_line(fc, fc + d * 15.0, Color(0.72, 0.78, 0.9), 4.5)
		dyn.draw_line(fc, fc + d * 15.0, Color(1, 1, 1, 0.25), 1.2)
	if ok:                                                # motion blur ring
		dyn.draw_arc(fc, 12.0, 0.0, TAU, 24, Color(0.8, 0.9, 1.0, 0.25), 6.0)
	dyn.draw_circle(fc, 3.5, Color(0.35, 0.38, 0.45))
	dyn.draw_arc(fc, 18.0, 0.0, TAU, 28, Color(0.55, 0.6, 0.7), 2.0)
	# status lamp
	dyn.draw_circle(p + Vector2(21, 24), 3.0, Color(0.3, 1.0, 0.5) if ok else Color(1.0, 0.2, 0.2, 0.3 + 0.7 * blink))
	if ok:
		_smoke(p + Vector2(21, -22), 1.0, 4, Color(0.8, 0.92, 1.0, 0.22))
	elif not act:
		_sparks(p + Vector2(21, -3), 3.0, 3, Color(1.0, 0.85, 0.3), 12.0)
	else:
		_sparks(p + Vector2(21, -3), 3.0, 6, Color(1.0, 0.9, 0.5), 14.0)


# ---- Comms array: sweeping dish, waveform screen, expanding signal rings
func _m_comms(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	_machine_box(p, Vector2(76, 60), ok, blink)
	# oscilloscope screen
	var sr := Rect2(p + Vector2(-33, 4), Vector2(34, 22))
	dyn.draw_rect(sr, Color(0.02, 0.07, 0.05))
	var amp := 7.0 if ok else (3.0 + prog * 4.0 if act else 0.0)
	var pts := PackedVector2Array()
	for i in 18:
		var fx := float(i) / 17.0
		var y := sin(fx * 16.0 + time * 7.0) * amp * sin(fx * PI)
		if not ok and not act:
			y = (_rnd(floorf(time * 10.0) + i) - 0.5) * 5.0                   # static noise
		pts.append(sr.get_center() + Vector2((fx - 0.5) * (sr.size.x - 4.0), y))
	dyn.draw_polyline(pts, Color(0.3, 1.0, 0.5) if ok else Color(1.0, 0.45, 0.3), 1.5)
	dyn.draw_rect(sr, Color(0.5, 0.9, 0.7, 0.6), false, 1.0)
	# mast + dish
	var base := p + Vector2(18, 20)
	var dc := p + Vector2(18, -6)
	dyn.draw_line(base, dc, Color(0.6, 0.64, 0.74), 4.0)
	var a := 0.0
	if ok:
		a = -0.9 + sin(time * 0.9) * 0.55                                    # tracking the sky
	else:
		a = 1.25 + sin(time * (14.0 if act else 5.0)) * 0.05                  # drooping, twitching
		a += (-1.9 * prog) if act else 0.0
	var dir := Vector2.from_angle(a)
	var feed := dc + dir * 6.0
	dyn.draw_arc(feed, 15.0, a + PI - 1.0, a + PI + 1.0, 16, Color(0.85, 0.88, 0.95), 4.0)
	dyn.draw_arc(feed, 12.0, a + PI - 0.9, a + PI + 0.9, 16, Color(0.4, 0.45, 0.55), 2.0)
	dyn.draw_line(dc, dc + dir * 18.0, Color(0.7, 0.72, 0.8), 1.5)
	dyn.draw_circle(dc + dir * 18.0, 2.5, Color(1.0, 0.85, 0.3) if ok else Color(1.0, 0.2, 0.2, 0.3 + 0.7 * blink))
	if ok:
		for k in 3:
			var ph := fposmod(time * 0.9 + k / 3.0, 1.0)
			dyn.draw_arc(dc + dir * 18.0, 6.0 + ph * 36.0, a - 0.55, a + 0.55, 12, Color(0.4, 1.0, 0.65, 0.75 * (1.0 - ph)), 2.0)
	else:
		_sparks(dc + dir * 12.0, 11.0, 4 if not act else 7, Color(1.0, 0.9, 0.4), 12.0)


# ---- Power core: glowing reactor, orbiting rings, arcs of lightning while faulty
func _m_core(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	_machine_box(p, Vector2(80, 66), ok, blink)
	var c := p + Vector2(0, -3)
	var e := 1.0 if ok else 0.18 + prog * 0.6
	if not ok and not act:
		e *= 0.25 + 0.75 * (1.0 if _rnd(floorf(time * 9.0)) > 0.45 else 0.0)  # stuttering power
	dyn.draw_circle(c, 25.0, Color(0.03, 0.05, 0.08))
	_glow(c, 30.0, Color(0.3, 0.9, 1.0, 0.55 * e))
	var pulse := 1.0 + 0.18 * sin(time * (5.0 if ok else 9.0))
	dyn.draw_circle(c, 9.0 * pulse, Color(0.6 + 0.4 * e, 1.0, 1.0, 0.4 + 0.6 * e))
	dyn.draw_circle(c, 4.0, Color(1, 1, 1, e))
	var spd := 1.0 if ok else (0.7 if act else 0.15)
	dyn.draw_arc(c, 16.0, time * 2.0 * spd, time * 2.0 * spd + PI * 1.3, 20, Color(0.4, 0.95, 1.0, 0.4 + 0.6 * e), 3.0)
	dyn.draw_arc(c, 20.0, -time * 1.5 * spd, -time * 1.5 * spd + PI * 1.1, 20, Color(0.9, 0.85, 0.35, 0.35 + 0.6 * e), 2.5)
	dyn.draw_arc(c, 24.0, 0.0, TAU, 32, Color(0.55, 0.62, 0.72), 2.0)
	if ok:
		for k in 3:
			var o := Vector2.from_angle(time * 3.0 + k * TAU / 3.0) * 20.0
			dyn.draw_circle(c + o, 2.2, Color(0.8, 1.0, 1.0))
	else:
		var tgt := [Vector2(-38, -26), Vector2(38, 20), Vector2(30, -30), Vector2(-36, 24)]
		var nb := 3 if act else 2
		for i in nb:
			if _rnd(floorf(time * 7.0) + i * 2.7) > 0.35:
				_lightning(c + Vector2.from_angle(i * 1.7) * 16.0, p + tgt[(int(floorf(time * 3.0)) + i) % 4], 5, 9.0, Color(0.6, 0.9, 1.0, 0.9), i * 4.3)
		_sparks(c, 21.0, 6, Color(1.0, 0.85, 0.35), 18.0)
		_smoke(p + Vector2(-28, -24), 5.0, 3, Color(0.25, 0.25, 0.28, 0.5))


# ---- Coolant pump: pistons, flowing coolant, pressure gauge, leak while broken
func _m_coolant(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	_machine_box(p, Vector2(80, 60), ok, blink)
	var run := ok or act
	for i in 2:
		var cx := p.x - 27.0 + i * 18.0
		dyn.draw_rect(Rect2(cx - 6, p.y - 24, 12, 22), Color(0.07, 0.09, 0.13))
		var stroke := 0.0
		if ok:
			stroke = (0.5 + 0.5 * sin(time * 6.0 + i * PI)) * 11.0
		elif act:
			stroke = (0.5 + 0.5 * sin(time * 3.0 + i * PI)) * 6.0
		dyn.draw_rect(Rect2(cx - 3, p.y - 22 + stroke, 6, 20), Color(0.75, 0.8, 0.9))
		dyn.draw_rect(Rect2(cx - 7, p.y - 24 + stroke, 14, 4), Color(0.5, 0.55, 0.65))
		dyn.draw_rect(Rect2(cx - 6, p.y - 24, 12, 22), Color(0.5, 0.58, 0.7), false, 1.5)
	# pipe
	var pipe := Rect2(p.x - 36, p.y + 6, 72, 10)
	dyn.draw_rect(pipe, Color(0.08, 0.1, 0.14))
	var coolant := Color(0.25, 0.85, 1.0, 0.85 if run else 0.35)
	dyn.draw_rect(pipe.grow(-2), Color(coolant.r, coolant.g, coolant.b, 0.25 if run else 0.1))
	if run:
		var spd := 46.0 if ok else 22.0
		for k in 6:
			var x := fposmod(time * spd + k * 13.0, 68.0)
			dyn.draw_circle(Vector2(pipe.position.x + 2 + x, pipe.get_center().y), 2.2, coolant)
	dyn.draw_rect(pipe, Color(0.55, 0.62, 0.74), false, 1.5)
	for jx in [-18.0, 12.0]:
		dyn.draw_rect(Rect2(p.x + jx - 2, p.y + 4, 4, 14), Color(0.62, 0.66, 0.76))
	# gauge
	var gc := p + Vector2(22, -14)
	dyn.draw_circle(gc, 12.0, Color(0.05, 0.06, 0.09))
	dyn.draw_arc(gc, 10.0, PI * 0.8, PI * 2.2, 16, Color(0.3, 0.9, 0.5), 2.0)
	dyn.draw_arc(gc, 10.0, PI * 1.9, PI * 2.2, 6, Color(1.0, 0.25, 0.2), 2.0)
	var na := 0.0
	if ok:
		na = PI * 1.15 + sin(time * 2.0) * 0.1
	elif act:
		na = PI * 1.5 + sin(time * 5.0) * 0.12
	else:
		na = PI * 2.05 + (_rnd(floorf(time * 12.0)) - 0.5) * 0.35             # redlined and jittering
	dyn.draw_line(gc, gc + Vector2.from_angle(na) * 9.0, Color(1, 1, 1), 1.8)
	dyn.draw_arc(gc, 12.0, 0.0, TAU, 20, Color(0.65, 0.7, 0.8), 1.5)
	if not ok:
		# leak: drips fall from the left joint, hissing steam when not being fixed
		for k in 3:
			var ph := fposmod(time * 1.5 + k * 0.33, 1.0)
			dyn.draw_circle(p + Vector2(-18, 20 + ph * ph * 26.0), 2.0, Color(0.3, 0.9, 1.0, 0.9 * (1.0 - ph * 0.5)))
		if not act:
			_smoke(p + Vector2(-18, 4), 8.0, 3, Color(0.85, 0.95, 1.0, 0.3))
	else:
		_smoke(p + Vector2(26, -26), 9.0, 2, Color(0.85, 0.95, 1.0, 0.16))


# ---- Hull breach: a ragged hole to space with air rushing out, a patch plate that slides in + welding
func _m_hull(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	_machine_box(p, Vector2(76, 64), ok, blink)
	var h := p + Vector2(0, 2)
	# warning stripes on top
	for i in 8:
		if i % 2 == 0:
			dyn.draw_rect(Rect2(p.x - 36 + i * 9, p.y - 31, 9, 5), Color(0.95, 0.78, 0.1))
	if not ok:
		var poly := PackedVector2Array()
		for i in 10:
			var rr := 15.0 + _rnd(i * 1.7) * 7.0
			poly.append(h + Vector2.from_angle(i * TAU / 10.0) * rr)
		dyn.draw_colored_polygon(poly, Color(0.0, 0.0, 0.02))
		for i in 6:
			var sp := h + Vector2(_rnd(i * 2.3) - 0.5, _rnd(i * 4.1) - 0.5) * 26.0
			dyn.draw_circle(sp, 1.0, Color(1, 1, 1, 0.4 + 0.5 * sin(time * 3.0 + i)))
		var outline := poly.duplicate()
		outline.append(poly[0])
		dyn.draw_polyline(outline, Color(0.9, 0.5, 0.2, 0.8), 2.0)
		# air rushing out
		for k in 8:
			var ph := fposmod(time * 1.6 + k / 8.0, 1.0)
			var d := Vector2.from_angle(k * TAU / 8.0 + 0.3)
			var pos := h + d * (40.0 * (1.0 - ph) + 6.0)
			dyn.draw_line(pos, pos - d * 6.0, Color(0.9, 0.95, 1.0, 0.65 * ph), 1.5)
	# patch plate slides over the hole as repair progresses
	var off := 0.0
	if not ok:
		off = lerpf(-62.0, 0.0, clampf(prog, 0.0, 1.0))
	if ok or prog > 0.0:
		var pr := Rect2(h + Vector2(-25, -25 + off), Vector2(50, 50))
		dyn.draw_rect(pr, Color(0.45, 0.5, 0.6))
		dyn.draw_rect(pr.grow(-3), Color(0.55, 0.6, 0.7))
		dyn.draw_line(pr.position + Vector2(4, 4), pr.end - Vector2(4, 4), Color(1, 1, 1, 0.08), 8.0)
		dyn.draw_rect(pr, Color(0.25, 0.95, 0.5, 0.9) if ok else Color(1.0, 0.8, 0.3, 0.8), false, 2.0)
		for c in [Vector2(6, 6), Vector2(44, 6), Vector2(6, 44), Vector2(44, 44)]:
			dyn.draw_circle(pr.position + c, 2.2, Color(0.3, 0.33, 0.4))
		if act and not ok:
			var tip := Vector2(pr.get_center().x + sin(time * 5.0) * 18.0, pr.end.y)
			_glow(tip, 14.0, Color(0.7, 0.9, 1.0, 0.9))
			dyn.draw_circle(tip, 3.0, Color(1, 1, 1))
			_sparks(tip, 17.0, 9, Color(1.0, 0.85, 0.4), 16.0)


# ---- Spacesuit locker: glass door, suit floating in zero-g, door swings open when used
func _m_locker(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	var r := Rect2(p - Vector2(24, 34), Vector2(48, 68))
	dyn.draw_rect(r.grow(3), Color(0, 0, 0, 0.45))
	dyn.draw_rect(r, Color(0.2, 0.24, 0.32))
	var inner := r.grow(-5)
	dyn.draw_rect(inner, Color(0.04, 0.06, 0.1))
	# interior light strip
	dyn.draw_rect(Rect2(inner.position, Vector2(inner.size.x, 3)), Color(0.7, 0.9, 1.0, 0.5 + 0.2 * sin(time * 2.0)))
	var c := p + Vector2(0, sin(time * 1.4) * 2.5)                          # suit floats gently
	if not ok:
		var suit := Color(0.92, 0.93, 0.97)
		dyn.draw_rect(Rect2(c.x - 8, c.y - 8, 16, 22), suit)                 # torso
		dyn.draw_rect(Rect2(c.x - 5, c.y - 4, 10, 8), Color(1.0, 0.5, 0.1))  # chest pack
		dyn.draw_line(c + Vector2(-8, -5), c + Vector2(-16, 6 + sin(time * 1.9) * 2.0), suit, 5.0)   # arms drift
		dyn.draw_line(c + Vector2(8, -5), c + Vector2(16, 6 + sin(time * 1.7 + 1.0) * 2.0), suit, 5.0)
		dyn.draw_line(c + Vector2(-4, 14), c + Vector2(-5, 27), suit, 6.0)   # legs
		dyn.draw_line(c + Vector2(4, 14), c + Vector2(5, 27), suit, 6.0)
		dyn.draw_circle(c + Vector2(0, -16), 9.0, suit)                      # helmet
		dyn.draw_circle(c + Vector2(0, -16), 6.5, Color(0.1, 0.25, 0.45))
		dyn.draw_circle(c + Vector2(-2, -18), 2.0, Color(1, 1, 1, 0.6))
	else:
		dyn.draw_line(p + Vector2(-8, -26), p + Vector2(8, -26), Color(0.5, 0.55, 0.65), 2.0)       # empty hanger
		dyn.draw_line(p + Vector2(0, -26), p + Vector2(0, -20), Color(0.5, 0.55, 0.65), 2.0)
	# door, hinged on the left; swings open with progress, fully when done
	var f := 1.0 if ok else clampf(prog, 0.0, 1.0) * 0.85
	var dw := inner.size.x * cos(f * 1.45)
	if dw > 2.0:
		var dr := Rect2(inner.position, Vector2(dw, inner.size.y))
		dyn.draw_rect(dr, Color(0.55, 0.78, 1.0, 0.18))
		dyn.draw_rect(dr, Color(0.7, 0.85, 1.0, 0.8), false, 2.0)
		dyn.draw_line(dr.position + Vector2(dw * 0.2, 4), dr.position + Vector2(dw * 0.6, inner.size.y * 0.5), Color(1, 1, 1, 0.18), 3.0)
	else:
		dyn.draw_rect(Rect2(inner.position.x - 6, inner.position.y, 6, inner.size.y), Color(0.5, 0.58, 0.72))
	dyn.draw_rect(r, Color(0.45, 0.55, 0.7), false, 2.0)
	var lamp := Color(0.3, 1.0, 0.5) if ok else Color(1.0, 0.55, 0.1, 0.4 + 0.6 * blink)
	dyn.draw_circle(p + Vector2(0, -42), 3.5, lamp)


# ---- Shaft lever: swinging arm, rotating beacon, hazard base, sparks once pulled
func _m_lever(p: Vector2, ok: bool, prog: float, act: bool, blink: float) -> void:
	_machine_box(p, Vector2(64, 60), ok, blink)
	for i in 8:
		if i % 2 == 0:
			dyn.draw_rect(Rect2(p.x - 32 + i * 8, p.y + 25, 8, 5), Color(0.95, 0.78, 0.1))
	# slot the lever travels in
	var pivot := p + Vector2(0, 14)
	dyn.draw_arc(pivot, 28.0, -PI * 0.5 - 1.0, -PI * 0.5 + 1.0, 20, Color(0.05, 0.05, 0.08), 7.0)
	dyn.draw_arc(pivot, 28.0, -PI * 0.5 - 1.0, -PI * 0.5 + 1.0, 20, Color(0.4, 0.42, 0.5), 1.5)
	var t := 1.0 if ok else clampf(prog, 0.0, 1.0)
	var ang := lerpf(-0.95, 0.95, t) + (sin(time * 28.0) * 0.03 if act else 0.0)
	var tip := pivot + Vector2(0, -1).rotated(ang) * 28.0
	dyn.draw_line(pivot, tip, Color(0.75, 0.78, 0.86), 7.0)
	dyn.draw_line(pivot, tip, Color(1, 1, 1, 0.25), 2.0)
	dyn.draw_circle(tip, 8.0, Color(1.0, 0.3, 0.2))
	dyn.draw_circle(tip + Vector2(-2, -2), 2.5, Color(1, 1, 1, 0.5))
	dyn.draw_circle(pivot, 6.0, Color(0.3, 0.32, 0.4))
	dyn.draw_circle(pivot, 2.5, Color(0.7, 0.72, 0.8))
	# rotating warning beacon
	var bc := p + Vector2(-20, -20)
	var armed := suit_on and not ok
	var bcol := Color(1.0, 0.2, 0.15) if (ok or not suit_on) else Color(1.0, 0.75, 0.15)
	if armed or ok:
		var ba := time * 5.0
		for s in [0.0, PI]:
			var d1 := Vector2.from_angle(ba + s - 0.25) * 34.0
			var d2 := Vector2.from_angle(ba + s + 0.25) * 34.0
			dyn.draw_colored_polygon(PackedVector2Array([bc, bc + d1, bc + d2]), Color(bcol.r, bcol.g, bcol.b, 0.14))
	dyn.draw_circle(bc, 5.0, Color(bcol.r, bcol.g, bcol.b, 0.4 + 0.6 * blink))
	dyn.draw_arc(bc, 6.0, 0.0, TAU, 12, Color(0.7, 0.72, 0.8), 1.5)
	if ok:
		_sparks(tip, 31.0, 6, Color(1.0, 0.7, 0.3), 16.0)


# ====================================================================== HUD
func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _anchor(c: Control, l: float, t: float, r: float, b: float, ol := 0.0, ot := 0.0, orr := 0.0, ob := 0.0) -> void:
	c.anchor_left = l
	c.anchor_top = t
	c.anchor_right = r
	c.anchor_bottom = b
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var root := Control.new()
	_anchor(root, 0, 0, 1, 1)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	hud_alarm = ColorRect.new()
	_anchor(hud_alarm, 0, 0, 1, 1)
	hud_alarm.color = Color(1, 0, 0, 0)
	hud_alarm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud_alarm)

	hud_objectives = _label(16, Color(0.85, 0.95, 1.0))
	_anchor(hud_objectives, 0, 0, 0, 0, 16, 12, 460, 200)
	root.add_child(hud_objectives)

	hud_status = _label(16, Color(1, 0.6, 0.6))
	hud_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_anchor(hud_status, 1, 0, 1, 0, -420, 12, -16, 60)
	root.add_child(hud_status)

	hud_message = _label(22, Color(1.0, 0.95, 0.6))
	hud_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_anchor(hud_message, 0, 0, 1, 0, 0, 90, 0, 140)
	root.add_child(hud_message)

	hud_prompt = _label(20, Color(1, 1, 1))
	hud_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_anchor(hud_prompt, 0, 1, 1, 1, 0, -120, 0, -90)
	root.add_child(hud_prompt)

	hud_progress = ProgressBar.new()
	hud_progress.show_percentage = false
	hud_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(hud_progress, 0.35, 1, 0.65, 1, 0, -80, 0, -62)
	hud_progress.visible = false
	root.add_child(hud_progress)

	var stun_label := _label(14, Color(0.5, 0.95, 1.0))
	stun_label.text = "STUN CHARGE (Z)"
	_anchor(stun_label, 0, 1, 0, 1, 16, -62, 260, -42)
	root.add_child(stun_label)

	hud_stun = ProgressBar.new()
	hud_stun.show_percentage = false
	hud_stun.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_anchor(hud_stun, 0, 1, 0, 1, 16, -38, 236, -20)
	root.add_child(hud_stun)

	hud_face = _label(14, Color(0.6, 1.0, 0.8))
	hud_face.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_anchor(hud_face, 1, 0, 1, 0, -520, 64, -16, 90)
	root.add_child(hud_face)

	hud_controls = _label(14, Color(1, 1, 1, 0.75))
	hud_controls.text = "ARROWS / head: thrust & aim    Z / mouth open: stun (3 s)    SPACE / blink: hold to repair / use"
	hud_controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_anchor(hud_controls, 1, 1, 1, 1, -760, -36, -16, -12)
	root.add_child(hud_controls)

	hud_overlay = ColorRect.new()
	_anchor(hud_overlay, 0, 0, 1, 1)
	hud_overlay.color = Color(0, 0, 0, 0.72)
	hud_overlay.visible = false
	hud_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud_overlay)
	hud_title = _label(72, Color(1, 0.2, 0.2))
	hud_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_anchor(hud_title, 0, 0.3, 1, 0.3, 0, 0, 0, 100)
	hud_overlay.add_child(hud_title)
	hud_sub = _label(26, Color(1, 1, 1))
	hud_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_anchor(hud_sub, 0, 0.5, 1, 0.5, 0, 0, 0, 120)
	hud_overlay.add_child(hud_sub)


func show_message(text: String, seconds: float) -> void:
	hud_message.text = text
	message_time = seconds


func _show_overlay(title: String, sub: String, color: Color) -> void:
	hud_overlay.visible = true
	hud_title.text = title
	hud_title.add_theme_color_override("font_color", color)
	hud_sub.text = sub


func _update_hud(delta: float) -> void:
	var lines := "OBJECTIVES\n"
	for it in interactables:
		if it.kind == "console":
			lines += ("[x] " if it.done else "[ ] ") + "Repair: " + it.name + "\n"
	lines += ("[x] " if door_open else "[ ] ") + "Airlock unlocks when all 5 are fixed\n"
	lines += ("[x] " if suit_on else "[ ] ") + "Change into the spacesuit\n"
	lines += ("[x] " if shaft_open else "[ ] ") + "Pull the lever - open the shaft\n"
	lines += ("[x] " if alien_out else "[ ] ") + "Get the alien sucked out"
	hud_objectives.text = lines

	var suit_text := "SUIT: OFF"
	if suit_on:
		suit_text = "SUIT: ON  |  TETHER: " + ("CLIPPED" if player.tethered else "READY")
	hud_status.text = "ALIEN: " + alien.status_text() + "\n" + suit_text
	hud_stun.value = player.cooldown_ratio() * 100.0
	hud_face.text = face.status_text()
	hud_face.add_theme_color_override("font_color", Color(0.6, 1.0, 0.8) if face.connected else Color(1.0, 0.75, 0.4))

	message_time -= delta
	hud_message.visible = message_time > 0.0

	if shaft_open and state != State.WON:
		hud_alarm.color.a = 0.07 + 0.06 * sin(time * 8.0)
	else:
		hud_alarm.color.a = 0.0


# ====================================================================== game loop
func _physics_process(delta: float) -> void:
	time += delta
	shake = move_toward(shake, 0.0, 10.0 * delta)
	match state:
		State.PLAYING:
			_tick_play(delta)
		State.DECOMPRESSION:
			_tick_play(delta)
			_tick_decompression(delta)
		State.DEAD:
			_tick_dead(delta)
		State.WON:
			_tick_won(delta)
	_update_hud(delta)
	camera.offset = Vector2(randf_range(-shake, shake), randf_range(-shake, shake))
	dyn.queue_redraw()


func _tick_play(delta: float) -> void:
	_handle_interaction(delta)
	if alien.is_lethal() and alien.global_position.distance_to(player.global_position) < 33.0:
		kill_player("The creature caught you.")


# ---------------------------------------------------------------- interaction
func _available(it: Dictionary) -> bool:
	match it.kind:
		"console":
			return not it.done
		"locker":
			return door_open and not suit_on
		"lever":
			return door_open and not shaft_open
	return false


func _handle_interaction(delta: float) -> void:
	var held := Input.is_action_pressed("interact")
	for it in interactables:
		it.active = false
	var best = null
	var best_d := 70.0
	for it in interactables:
		if not _available(it):
			continue
		var d: float = player.global_position.distance_to(it.pos)
		if d < best_d:
			best_d = d
			best = it

	# unfinished suit / lever actions slowly reset when released; repairs keep their progress
	for it in interactables:
		if it.kind != "console" and not it.done and not (it == best and held and _can_use(it)):
			it.progress = maxf(0.0, it.progress - delta * 0.6)

	hud_progress.visible = false
	hud_prompt.text = ""
	if best == null:
		return
	if not _can_use(best):
		hud_prompt.text = "SPACESUIT REQUIRED - opening the shaft without one would blow you into space!"
		return
	hud_prompt.text = "Hold [SPACE]:  " + _verb(best)
	if held:
		best.active = true
		best.progress += delta / best.hold
	hud_progress.visible = best.progress > 0.0
	hud_progress.value = best.progress * 100.0
	if best.progress >= 1.0:
		_complete(best)


func _can_use(it: Dictionary) -> bool:
	return not (it.kind == "lever" and not suit_on)


func _verb(it: Dictionary) -> String:
	match it.kind:
		"console":
			return "Repair " + it.name
		"locker":
			return "Change into spacesuit"
	return "Pull the shaft release lever"


func _complete(it: Dictionary) -> void:
	it.progress = 1.0
	it.done = true
	match it.kind:
		"console":
			var fixed := 0
			for c in interactables:
				if c.kind == "console" and c.done:
					fixed += 1
			alien.base_speed += 8.0   # the creature gets angrier with every fix
			if fixed >= 5:
				_unlock_door()
			else:
				show_message("%s repaired  (%d / 5)" % [it.name, fixed], 3.0)
		"locker":
			suit_on = true
			player.set_suit(true)
			show_message("Spacesuit on. Now stun the alien and pull the shaft lever!", 5.0)
		"lever":
			_open_shaft()


func _unlock_door() -> void:
	door_open = true
	door_body.queue_free()
	for y in range(5, 8):
		astar.set_point_solid(Vector2i(43, y), false)
	show_message("ALL SYSTEMS REPAIRED - AIRLOCK UNLOCKED. Suit up at the locker!", 6.0)


func _open_shaft() -> void:
	shaft_open = true
	state = State.DECOMPRESSION
	player.tethered = true
	player.tether_anchor = lever_pos
	player.tether_len = 200.0
	player.pull_target = shaft_pos
	player.pull_strength = 300.0
	alien.start_sucked()
	_init_debris()
	shake = 6.0
	show_message("SHAFT OPEN! Tether clipped - hold on! Stun the alien if it gets close!", 6.0)


# ---------------------------------------------------------------- decompression
func _init_debris() -> void:
	debris.clear()
	for i in 45:
		var d := {"p": Vector2.ZERO, "v": Vector2.ZERO, "r": randf_range(1.5, 4.0)}
		_respawn_debris(d)
		debris.append(d)


func _respawn_debris(d: Dictionary) -> void:
	d.p = Vector2(randf_range(44.5 * TS, 55.0 * TS), randf_range(2.5 * TS, 12.5 * TS))
	d.v = Vector2.ZERO


func _tick_decompression(delta: float) -> void:
	shake = maxf(shake, 3.0)
	for d in debris:
		var to: Vector2 = shaft_pos - d.p
		d.v += to.normalized() * 900.0 * delta
		d.p += d.v * delta
		if to.length() < 30.0 or d.p.x > shaft_pos.x:
			_respawn_debris(d)
	if alien_out:
		alien_out_t += delta
		if alien_out_t > 2.5:
			_win()


func on_alien_ejected() -> void:
	alien_out = true
	show_message("The creature was blown out into space!", 4.0)


func _win() -> void:
	state = State.WON
	win_t = 0.0
	shaft_open = false
	player.pull_strength = 0.0
	player.tethered = false
	_show_overlay("STATION SECURED", "The alien is gone and the ISS is repaired. You survived.\nPress SPACE to play again", Color(0.4, 1.0, 0.6))


func _tick_won(delta: float) -> void:
	win_t += delta
	if win_t > 1.0 and Input.is_action_just_pressed("interact"):
		get_tree().reload_current_scene()


# ---------------------------------------------------------------- death / restart
func kill_player(reason: String) -> void:
	if state == State.DEAD or state == State.WON:
		return
	state = State.DEAD
	death_timer = 3.0
	death_reason = reason
	player.die()
	hud_progress.visible = false
	hud_prompt.text = ""
	shake = 12.0
	_show_overlay("YOU DIED", reason, Color(1, 0.2, 0.2))


func _tick_dead(delta: float) -> void:
	death_timer -= delta
	hud_sub.text = "%s\nRestarting in %d...  (SPACE to retry now)" % [death_reason, ceili(maxf(death_timer, 0.0))]
	if death_timer <= 0.0 or (death_timer < 2.4 and Input.is_action_just_pressed("interact")):
		get_tree().reload_current_scene()
