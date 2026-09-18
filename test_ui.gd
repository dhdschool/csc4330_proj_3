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
	ui.queue_free()
	await process_frame
	# Online host smoke: the menu wires the p2p adapter into the game page
	var online_ui = load("res://ui/main.tscn").instantiate()
	root.add_child(online_ui)
	online_ui._host_online()
	for i in 6:
		await process_frame
	check(online_ui.online and online_ui.page == "game", "Hosting enters the game page")
	var view: Dictionary = online_ui.session.snapshot_for(online_ui.session.seat)
	check(online_ui.session.seat == 1 and view.hand.size() == 3, "Host renders its own dealt hand")
	check(view.hand_counts[1] == 3 and not JSON.stringify(view).contains("opp_cards"), "Opponent stays a count")
	var online_steps := 0
	while online_steps < 20:
		view = online_ui.session.snapshot_for(1)
		if (view.actions as Array).is_empty():
			break
		var action: String = view.actions[0]
		online_ui._act(action, 0 if action == "play_card" else -1)
		for i in 4:
			await process_frame
		online_steps += 1
	check(view.active_seat == 2 and (view.actions as Array).is_empty(), "Online turn passes to the opponent")
	var deciding: bool = online_ui.find_children("*", "Label", true, false).any(func(l: Node) -> bool: return (l as Label).text.begins_with("Player 2 is deciding"))
	var reveal: bool = online_ui.find_children("*", "Button", true, false).any(func(b: Node) -> bool: return (b as Button).text == "Reveal my hand")
	check(deciding and not reveal, "Waiting screen replaces pass/reveal online")
	online_ui._menu()
	await process_frame
	check(not online_ui.online and online_ui.session == online_ui.local_session, "Menu tears the online session down")
	check(get_multiplayer().multiplayer_peer == null, "Peer released after leaving online play")
	online_ui.queue_free()
	await process_frame
	print("UI CHECKS PASSED" if failures == 0 else "UI CHECKS FAILED: %d" % failures)
	quit(0 if failures == 0 else 1)


