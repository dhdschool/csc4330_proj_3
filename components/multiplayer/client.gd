extends Node

class_name Client

## Le Truc game client.
##
## Specifications (from the original stub):
##  - Every game action is sent to the host's server.gd (s_action RPC); the
##    client never touches a Game, so the match stays authoritative on the host.
##  - The client is bound to one player (seat): every request carries it and
##    the host checks it against the sending peer, so clients can never make
##    moves for the opponent.
##
## Seats are how players travel over the wire (1 = host, 2 = guest), because
## Player objects only exist inside the host's Game. The host assigns the seat
## when the connection opens and repeats it in every snapshot. The host player
## also drives the match through this class; its requests loop back locally
## thanks to the "call_local" RPC mode on Server.s_action.
##
## Note: the stub extended Resource, but RPCs need a Node in the scene tree.

signal state_changed(state: Dictionary)
signal connected_to_server()
signal connection_failed()
signal server_disconnected()

var state: Dictionary = {}  # latest snapshot from the host
var seat := 0  # this client's player seat; 0 until the first snapshot arrives

var _server: Server  # local Server node: RPC carrier on guests, the real host on the host machine


func _ready() -> void:
	multiplayer.connected_to_server.connect(connected_to_server.emit)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_find_server.call_deferred()  # the Server node may enter the tree after us


func _find_server() -> void:
	_server = get_tree().get_first_node_in_group(Server.GROUP)
	if _server != null:
		_server.state_received.connect(_on_state)


## Join the match at `address` (IPv4 or IPv6, e.g. "::1"). Refuses with
## ERR_ALREADY_IN_USE while already hosting or connected. Follow the
## connected_to_server / connection_failed signals for the outcome.
func connect_to_server(address: String, port: int = Server.DEFAULT_PORT) -> Error:
	var peer := multiplayer.multiplayer_peer
	if peer != null and not peer is OfflineMultiplayerPeer:
		return ERR_ALREADY_IN_USE
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = enet
	return OK


# --- game actions: wrappers forwarded to server.gd ---------------------------

func start_game() -> void:
	_send("start_game")


func play_card(card: CardData) -> void:
	if card != null:
		_send("play_card", [card.suit, card.rank])


func concede() -> void:
	_send("concede")


func pass_redeal() -> void:
	_send("pass_redeal")


func propose_redeal() -> void:
	_send("propose_redeal")


func accept_redeal(accept: bool) -> void:
	_send("accept_redeal", [accept])


func pass_raise() -> void:
	_send("pass_raise")


func offer_raise() -> void:
	_send("offer_raise")


func offer_mon_reste() -> void:
	_send("offer_mon_reste")


func accept_raise() -> void:
	_send("accept_raise")


func raise_more() -> void:
	_send("raise_more")


## This client's hand, rebuilt from the latest snapshot.
func hand() -> Array[CardData]:
	var cards: Array[CardData] = []
	for c in state.get("hand", []):
		cards.append(CardData.new(c[0], c[1]))
	return cards


# --- internals ----------------------------------------------------------------

## Deferred on purpose: game.gd's coroutines `await _acted` right after
## emitting awaiting_action, so an action submitted synchronously from inside
## a state_changed handler would be missed (same reason test_game.gd defers
## its scripted decisions).
func _send(action: String, args: Array = []) -> void:
	_do_send.call_deferred(action, args)


func _do_send(action: String, args: Array) -> void:
	var peer := multiplayer.multiplayer_peer
	if _server == null or peer == null or peer is OfflineMultiplayerPeer \
			or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return  # not in a match: requests are dropped silently, like game.gd
	_server.rpc_id(1, "s_action", seat, action, args)


func _on_state(snap: Dictionary) -> void:
	state = snap
	seat = snap.get("your_seat", seat)
	state_changed.emit(snap)


func _on_connection_failed() -> void:
	_reset()
	connection_failed.emit()


func _on_server_disconnected() -> void:
	_reset()
	server_disconnected.emit()

func _reset() -> void:
	multiplayer.multiplayer_peer = null
	state = {}
	seat = 0
