extends SceneTree
var failures := 0
func _initialize() -> void:
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func run() -> void:
	var ui = load("res://ui/main.tscn").instantiate()
	root.add_child(ui)
	ui._rules()
	check(ui.page == "rules", "Rules navigation failed")
	ui._tutorial_start()
	ui._tutorial_advance()
	ui._tutorial_advance()
	ui._tutorial_card("9 Diamonds")
	check(ui.tutorial_step == 2 and not ui.tutorial_feedback.is_empty(), "Wrong card feedback failed")
	ui._tutorial_card("7 Hearts")
	ui._tutorial_card("8 Clubs")
	check(ui.tutorial_step == 4, "Tutorial completion failed")
	ui._menu()
	ui._online_menu()
	check(ui.session.game == null, "Online placeholder started a match")
	ui._menu()
	for mode in range(3):
		ui._start()
		await process_frame
		await process_frame
		var steps := 0
		while ui.session.winner.is_empty() and steps < 2000:
			var session = ui.session
			var state: Dictionary = session.snapshot_for(session.seat)
			check(not state.has("deck") and not state.has("opponent_hand"), "Private state leaked")
			check(session.snapshot_for(0).hand.is_empty(), "Spectator received hand")
			check(not session.submit(3 - session.seat, "concede", -1, state.revision), "Wrong seat accepted")
			check(not session.submit(session.seat, "concede", -1, state.revision - 1), "Stale action accepted")
			ui._reveal()
			var actions: Array = state.actions
			var action: String = actions[0]
			if mode == 1 and actions.has("propose_redeal"):
				action = "propose_redeal"
			elif mode == 1 and actions.has("offer_raise"):
				action = "offer_raise"
			elif mode == 2 and actions.has("offer_mon_reste"):
				action = "offer_mon_reste"
			ui._act(action, 0)
			await process_frame
			await process_frame
			steps += 1
		check(steps < 2000, "Match failed to terminate")
		check(not ui.session.winner.is_empty(), "No winner screen")
		print("Completed UI match variant ", mode, " in ", steps, " actions")
	ui.queue_free()
	await process_frame
	print("UI CHECKS PASSED" if failures == 0 else "UI CHECKS FAILED: %d" % failures)
	quit(0 if failures == 0 else 1)


