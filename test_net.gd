extends SceneTree

## Headless self-check for the multiplayer layer (client.gd / server.gd).
##
## Loopback (no TRUC_ROLE): host lifecycle, seat binding, snapshot content,
## anti-forgery, stop_server teardown — all in one process via call_local.
## Two-process (TRUC_ROLE=host / guest): a real match over IPv6 loopback
## (::1), including a forged opponent-seat action that must be dropped.
##
## Run:
##   godot --headless --path . -s res://test_net.gd
##   TRUC_ROLE=host  godot --headless --path . -s res://test_net.gd
##   TRUC_ROLE=guest godot --headless --path . -s res://test_net.gd
const ONLINE_SESSION = preload("res://ui/online_session.gd")

var started_port := -1
var connected_flag := false
var stopped_flag := false
const PORT := 24565
const HOST_FLAG := "res://_net_host.flag"
const DONE_FLAG := "res://_net_done.flag"
var failures := 0

var server: Server
var client: Client
var online: Node  # ui/online_session.gd instance in the role scenarios
var me := 1  # seat this process drives
var my_plays := 0
var forged_tested := false
var round_result: Array = []  # [winner_seat, points] captured on the host


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   " + msg)
	else:
		failures += 1
		print("  FAIL " + msg)


func _run() -> void:
	match OS.get_environment("TRUC_ROLE"):
		"host":
			await _host_role()
		"guest":
			await _guest_role()
		_:
			await _loopback()
			await _adapter()
	print("")
	if failures == 0:
		print("NET CHECKS PASSED (%s)" % OS.get_environment("TRUC_ROLE"))
		quit(0)
	else:
		print("%d NET CHECK(S) FAILED" % failures)
		quit(1)


# Both processes must build the identical tree so RPC node paths match.

func build_tree() -> void:
	var net := Node.new()
	net.name = "Net"
	root.add_child(net)
	server = Server.new()
	server.name = "Server"
	net.add_child(server)
	client = Client.new()
	client.name = "Client"
	net.add_child(client)
	await process_frame  # let the deferred Client._find_server run


# --- shared reactive driver: act whenever the snapshot says it is my turn ---

func drive(snap: Dictionary) -> void:
	if snap.get("your_seat") != me:
		return
	match snap.get("phase"):
		Game.Phase.REDEAL_OFFER:
			if snap.get("decision") == me:
				client.pass_redeal()
		Game.Phase.RAISE_WINDOW:
			if snap.get("decision") == me:
				client.pass_raise()
		Game.Phase.RAISE_RESPONSE:
			if snap.get("decision") == me:
				client.accept_raise()
		Game.Phase.PLAY:
			if snap.get("current") == me:
				my_plays += 1
				if OS.get_environment("TRUC_ROLE") == "guest" and my_plays >= 2:
					client.concede()  # give the round away in trick 2
				else:
					client.play_card(client.hand()[0])


# --- loopback: single process, host client only -------------------------------

func _loopback() -> void:
	print("scenario: loopback host lifecycle and validation")
	seed(11)  # before any RNG use (deck shuffles in its _ready)
	await build_tree()
	server.server_started.connect(func(port: int) -> void: started_port = port)
	server.server_stopped.connect(func() -> void: stopped_flag = true)
	var acted := 0

	client.start_game()  # dropped: no connection yet
	await process_frame

	check(server.start_server(PORT) == OK, "start_server returns OK")
	check(started_port == PORT, "server_started emitted with the port")
	check(server.is_hosting() and server.game != null, "hosting with a game instance")
	await process_frame
	check(client.seat == 1, "host client is bound to seat 1")
	check(client.state.get("phase") == Game.Phase.IDLE and client.state.get("points") == [0, 0],
			"initial snapshot is idle at 0-0")

	server.game._acted.connect(func() -> void: acted += 1)
	server.s_action(2, "start_game", [])  # direct call: host claiming the guest seat
	check(acted == 0 and server.game.phase == Game.Phase.IDLE,
			"action claiming the opponent seat is dropped")

	client.start_game()
	await _wait_for(func() -> bool: return client.state.get("phase") == Game.Phase.REDEAL_OFFER, 60)
	check(client.state.get("phase") == Game.Phase.REDEAL_OFFER, "start_game reaches the redeal offer")
	check(client.state.get("hand", []).size() == 3, "snapshot carries my 3 dealt cards")
	check(client.state.get("opp_cards") == 3, "opponent appears as a card count, not cards")
	check(client.state.get("decision") in [1, 2], "snapshot names the deciding seat")
	server.stop_server()
	check(stopped_flag and not server.is_hosting() and server.game == null, "stop_server tears the room down")
	check(get_multiplayer().multiplayer_peer == null, "peer released after stop")
	client.pass_redeal()  # dropped silently now
	await process_frame


# --- host role: real socket, drives seat 1, waits for the guest ---------------

func _host_role() -> void:
	print("scenario: two-process host over IPv6 (online session adapter)")
	await build_tree()
	online = ONLINE_SESSION.new()
	online.name = "OnlineSession"
	root.add_child(online)
	await process_frame  # deferred Client._find_server wiring
	check(online.host(PORT) == OK, "start_server returns OK (bound to ::)")
	check(get_multiplayer().get_unique_id() == 1, "host peer id is 1")
	server.game.round_ended.connect(func(winner: Player, points: int) -> void: round_result = [server._seat_of(winner), points])
	online.start()
	online.changed.connect(_drive_view)
	_flag(HOST_FLAG, "ready")
	var frames := 0
	while round_result.is_empty() and frames < 3000:
		await process_frame
		frames += 1

	check(not round_result.is_empty(), "guest connected and a round ended over IPv6")
	check(round_result == [1, 1],
			"guest (seat 2) conceded the min bet to the host — the forged seat-1 concede was not honored")
	online.stop()
	_flag(DONE_FLAG, "done")

# --- guest role: joins ::1, drives seat 2, tries one forged action -----------

func _guest_role() -> void:
	me = 2
	print("scenario: two-process guest over IPv6 (online session adapter)")
	await build_tree()
	online = ONLINE_SESSION.new()
	online.name = "OnlineSession"
	root.add_child(online)
	await process_frame
	var up := await _wait_for(func() -> bool: return FileAccess.file_exists(HOST_FLAG), 100)
	check(up, "host room came up")
	check(online.join("::1", PORT) == OK, "connect request accepted")
	connected_flag = await _wait_for(func() -> bool: return get_multiplayer().multiplayer_peer != null \
			and get_multiplayer().multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, 1000)
	check(connected_flag, "connected over IPv6 loopback")

	var seated := await _wait_for(func() -> bool: return online.seat == 2, 1000)
	check(seated, "guest is bound to seat 2")
	check(online.snapshot_for(2).hand.size() == 3, "guest received its own hand")
	online.changed.connect(_guest_drive_view)
	_guest_drive_view()  # the stuck phase may already be ours to act on
	var done := await _wait_for(func() -> bool: return FileAccess.file_exists(DONE_FLAG), 600)
	check(done, "round finished on the host")
	await process_frame

func _guest_drive_view() -> void:
	var view: Dictionary = online.snapshot_for(2)
	if not forged_tested and view.get("phase") == Game.Phase.PLAY:
		forged_tested = true
		# Claim the OPPONENT's seat; the host must drop it. The host-side
		# result check proves it: an honored concede would award seat 2.
		server.rpc_id(1, "s_action", 1, "concede", [])
	_drive_view()


## Reactive driver over the adapter's local-contract view (both roles).
func _drive_view() -> void:
	var view: Dictionary = online.snapshot_for(me)
	var actions: Array = view.get("actions", [])
	if actions.is_empty():
		return
	var revision := int(view.get("revision", -1))
	if actions.has("play_card"):
		my_plays += 1
		if OS.get_environment("TRUC_ROLE") == "guest" and my_plays >= 2:
			online.submit(me, "concede", -1, revision)  # give the round away in trick 2
		else:
			online.submit(me, "play_card", 0, revision)
	elif actions.has("pass_redeal"):
		online.submit(me, "pass_redeal", -1, revision)
	elif actions.has("pass_raise"):
		online.submit(me, "pass_raise", -1, revision)
	elif actions.has("accept_raise"):
		online.submit(me, "accept_raise", -1, revision)

# --- adapter contract: main.gd's session interface over the p2p layer --------

func _adapter() -> void:
	print("scenario: online session adapter contract (loopback)")
	seed(7)
	online = ONLINE_SESSION.new()
	online.name = "OnlineSession"
	root.add_child(online)
	await process_frame
	check(online.host(PORT) == OK, "adapter hosts through the Server node")
	online.start()
	var seated := await _wait_for(func() -> bool: return online.seat == 1, 60)
	check(seated, "adapter is seated as the host")
	var dealt := await _wait_for(func() -> bool: return (online.snapshot_for(1).get("hand", []) as Array).size() == 3, 60)
	check(dealt, "adapter receives its dealt hand")
	var view: Dictionary = online.snapshot_for(1)
	check(view.has_all(["seat", "active_seat", "revision", "hand", "actions", "phase", "scores",
			"hand_counts", "bet", "pending_bet", "target", "round", "dealer", "winner", "table", "history"]),
			"view carries the full local session contract")
	check(not view.has("your_seat") and not view.has("opp_cards") and not view.has("points"),
			"wire-only fields stay out of the view")
	check(view.hand.size() == 3 and str(view.hand[0].label).split(" ").size() == 2,
			"hand renders as labeled cards")
	check(not online.submit(2, "concede", -1, view.revision), "wrong seat rejected by the adapter")
	check(not online.submit(1, "concede", -1, view.revision - 1), "stale revision rejected by the adapter")
	var actions: Array = view.actions
	if actions.is_empty():
		check(not online.submit(1, "pass_redeal", -1, view.revision),
				"out-of-turn action rejected by the adapter")
	else:
		var pick: String = actions[0]
		check(online.submit(1, pick, 0 if pick == "play_card" else -1, view.revision),
				"legal action accepted")
		var moved := await _wait_for(func() -> bool: return online.snapshot_for(1).revision > view.revision, 60)
		check(moved, "action advanced the match")
	online.stop()
	online.queue_free()
	await process_frame
	check(not server.is_hosting(), "adapter stop tears the room down")

# --- helpers --------------------------------------------------------------------

func _flag(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _wait_for(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()
