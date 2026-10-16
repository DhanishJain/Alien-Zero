extends SceneTree
## Headless smoke test:  godot --headless --path . -s res://tests/smoke_test.gd
## Plays the whole game through (repairs -> suit -> lever -> alien ejected -> win),
## then checks stun (3 s) and alien-contact death.

var main
var failures := 0


func check(cond: bool, label: String) -> void:
	if cond:
		print("PASS  ", label)
	else:
		print("FAIL  ", label)
		failures += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func spawn_game() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await frames(3)


func teleport(pos: Vector2) -> void:
	main.player.global_position = pos
	main.player.velocity = Vector2.ZERO


func hold_interact(n: int) -> void:
	Input.action_press("interact")
	await frames(n)
	Input.action_release("interact")
	await frames(2)


func _initialize() -> void:
	await run()
	print("RESULT: ", "ALL PASSED" if failures == 0 else "%d FAILED" % failures)
	quit(failures)


func run() -> void:
	# ---- full playthrough ------------------------------------------------
	await spawn_game()
	check(main.state == main.State.PLAYING, "game starts in PLAYING")
	check(main.tex_alien != null and main.tex_astronaut != null and main.tex_interior != null and main.tex_bg != null, "alien, astronaut, interior and background art loaded")
	check(main.tex_interior.get_size() == Vector2(main.W * main.TS, main.H * main.TS), "interior art matches the map size")
	main.alien.wake_t = 1e9   # keep the alien asleep during the scripted playthrough
	for it in main.interactables:
		if it.kind == "console":
			teleport(it.pos)
			await hold_interact(170)
			check(it.done, "repaired " + it.name)
	check(main.door_open, "airlock unlocked after 5 repairs")
	for it in main.interactables:
		if it.kind == "locker":
			teleport(it.pos)
			await hold_interact(130)
	check(main.suit_on, "spacesuit equipped")
	for it in main.interactables:
		if it.kind == "lever":
			teleport(it.pos)
			await hold_interact(110)
	check(main.shaft_open or main.state == main.State.WON or main.state == main.State.DECOMPRESSION, "shaft opened")
	check(main.player.tethered, "player is tethered")
	var peak := 0.0
	for i in 1500:
		await physics_frame
		peak = maxf(peak, main.player.global_position.distance_to(main.lever_pos))
		if main.state == main.State.WON:
			break
	check(main.alien_out, "alien was sucked out")
	check(main.state == main.State.WON, "victory reached")
	check(peak <= 202.0, "tether limit respected (max %.1f px)" % peak)
	main.queue_free()
	await frames(2)

	# ---- stun weapon -------------------------------------------------------
	await spawn_game()
	main.alien.state = main.alien.S.HUNT
	teleport(main._tile_center(5, 8))
	main.alien.global_position = main.player.global_position + Vector2(150, 0)
	main.alien.velocity = Vector2.ZERO
	main.player.facing = Vector2.RIGHT
	Input.action_press("stun")
	await frames(2)
	Input.action_release("stun")
	await frames(20)
	check(main.alien.stun_left > 2.0 and main.alien.stun_left <= 3.0, "stun bolt stuns alien (~3 s left: %.2f)" % main.alien.stun_left)
	check(not main.alien.is_lethal(), "stunned alien is harmless")
	await frames(190)
	check(main.alien.stun_left == 0.0 and main.alien.is_lethal(), "stun wears off after 3 s")
	main.queue_free()
	await frames(2)

	# ---- smooth 360-degree aim -----------------------------------------------
	await spawn_game()
	main.alien.wake_t = 1e9
	main.player.facing = Vector2.RIGHT
	Input.action_press("up")
	await frames(6)   # ~0.1 s of holding: aim has only partly turned from RIGHT toward UP
	Input.action_release("up")
	await frames(2)
	var aim_deg: float = absf(rad_to_deg(main.player.facing.angle()))
	check(aim_deg > 5.0 and aim_deg < 85.0, "aim turns smoothly to in-between angles (%.0f deg)" % aim_deg)
	Input.action_press("up")
	await frames(60)
	Input.action_release("up")
	check(main.player.facing.dot(Vector2.UP) > 0.99, "held direction ends exactly on that direction")
	main.queue_free()
	await frames(2)

	# ---- chase + death -------------------------------------------------------
	await spawn_game()
	main.alien.state = main.alien.S.HUNT
	var start_d: float = main.alien.global_position.distance_to(main.player.global_position)
	await frames(600)
	var end_d: float = main.alien.global_position.distance_to(main.player.global_position)
	check(end_d < start_d * 0.6 or main.state == main.State.DEAD, "alien pathfinds toward the player (%.0f -> %.0f px)" % [start_d, end_d])
	main.alien.global_position = main.player.global_position + Vector2(10, 0)
	await frames(3)
	check(main.state == main.State.DEAD, "alien contact kills the player")
	main.queue_free()
	await frames(2)
