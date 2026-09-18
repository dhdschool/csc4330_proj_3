extends Node

## Online session: the contract main.gd uses for ui/local_session.gd, with the
## authoritative Game running on the host's Server node instead of locally.
##
## One node per machine. It owns this machine's Client and attaches to (or
## creates) the local Server node: the real host on the hosting machine, an
## inert relay on guests. Godot RPCs are addressed by scene-tree path, so the
## Server node must sit at the same path on every machine — main.gd always
## creates this session as "OnlineSession" under the same main scene, and the
## headless tests build the identical tree by hand.
##
## Wire snapshots (server.gd's format) are adapted into local_session.gd's
## snapshot shape, so main.gd renders an online seat exactly like a local one:
## fixed seat, no pass/reveal screens, own hand only.

signal changed
signal failed(reason: String)

var seat := 0  # my seat; 0 until the host's first snapshot arrives
var hosting := false

var _client: Client
var _server: Server
var _snap: Dictionary = {}  # latest host snapshot, wire format
var _view: Dictionary = {}  # _snap mapped to local_session.gd's shape


func _ready() -> void:
	_server = get_tree().get_first_node_in_group(Server.GROUP)
	if _server == null:
		_server = Server.new()
		_server.name = "Server"
		add_child(_server)
	_client = Client.new()
	_client.name = "Client"
	add_child(_client)
	_server.state_received.connect(_on_state)
	_client.connection_failed.connect(func() -> void: failed.emit("Could not reach the host."))
	_client.server_disconnected.connect(func() -> void: failed.emit("Connection to the host was lost."))


## Host the match on this machine; the hosting player takes seat 1.
func host(port: int = Server.DEFAULT_PORT) -> Error:
	var err := _server.start_server(port)
	hosting = err == OK
	return err


## Join the match at `address` (IPv4 or IPv6, e.g. "::1").
func join(address: String, port: int = Server.DEFAULT_PORT) -> Error:
	return _client.connect_to_server(address, port)


## Start/restart is host-controlled: only the host's Client sends it.
func start() -> void:
	if hosting:
		_client.start_game()


func stop() -> void:
	if hosting:
		_server.stop_server()
	elif multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null


## Same guards as local_session.submit, then one deferred trip through the
## Client. The host re-validates seat and turn; revision rejects stale input.
func submit(id: int, action: String, card_index: int, expected_revision: int) -> bool:
	if id != seat or expected_revision != int(_view.get("revision", -1)) \
			or not (_view.get("actions", []) as Array).has(action):
		return false
	var hand: Array = _view.get("hand", [])
	if action == "play_card" and (card_index < 0 or card_index >= hand.size()):
		return false
	match action:
		"play_card":
			var card: Dictionary = hand[card_index]
			_client.play_card(CardData.new(card["suit"], card["rank"]))
		"pass_redeal":
			_client.pass_redeal()
		"propose_redeal":
			_client.propose_redeal()
		"accept_redeal":
			_client.accept_redeal(true)
		"decline_redeal":
			_client.accept_redeal(false)
		"pass_raise":
			_client.pass_raise()
		"offer_raise":
			_client.offer_raise()
		"offer_mon_reste":
			_client.offer_mon_reste()
		"accept_raise":
			_client.accept_raise()
		"raise_more":
			_client.raise_more()
		"concede":
			_client.concede()
		_:
			return false
	return true


## Only this machine's own seat exists here; main.gd always asks with it.
func snapshot_for(_id: int) -> Dictionary:
	return _view


func _on_state(snap: Dictionary) -> void:
	_snap = snap
	seat = int(snap.get("your_seat", seat))
	_view = _adapt(snap)
	changed.emit()


## Wire snapshot -> local_session.gd's snapshot shape.
func _adapt(snap: Dictionary) -> Dictionary:
	var hand: Array = []
	for card in snap.get("hand", []):
		hand.append({"rank": int(card[1]), "suit": int(card[0]), "label": str(card[2])})
	var mine := int(snap.get("your_seat", 0))
	var opp := int(snap.get("opp_cards", -1))
	var counts := [hand.size(), opp] if mine == 1 else [opp, hand.size()] if mine == 2 else [0, 0]
	var active := int(snap.get("decision", 0))
	if active == 0:
		active = int(snap.get("current", 0))
	return {"seat": mine, "active_seat": active, "revision": int(snap.get("revision", 0)),
		"hand": hand, "actions": snap.get("actions", []), "phase": int(snap.get("phase", 0)),
		"scores": snap.get("points", [0, 0]), "hand_counts": counts,
		"bet": int(snap.get("bet", 0)), "pending_bet": int(snap.get("pending_bet", 0)),
		"target": int(snap.get("target", 12)), "round": int(snap.get("round", 1)),
		"dealer": int(snap.get("dealer", 0)), "winner": str(snap.get("winner", "")),
		"table": snap.get("table", []).duplicate(), "history": snap.get("history", []).duplicate()}
