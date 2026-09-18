extends Node

class_name Server

## Authoritative multiplayer host for Le Truc.
##
## The server runs p2p on one player's machine; that player is also a client
## (seat 1) and drives the match through Client like everybody else. Guest
## machines run this same node as an inert relay, so the RPC node paths match
## on every machine (Godot RPCs are addressed by scene-tree path).
##
## Specifications (from the original stubs):
##  - start_server(port): opens an ENet server bound to IPv6 on `port`, but
##    only while not already hosting and not connected to another server.
##    Emits server_started once the room is up.
##  - stop_server(): closes any hosted server; every connected client gets
##    disconnected. Emits server_stopped.
##  - s_action(): the RPC wrappers for game.gd's action methods. The acting
##    player is derived from the sending peer and checked against the seat the
##    client claims, so a client can never make moves for the opponent.
##  - State sync: after every game signal a snapshot is pushed to all peers.
##    Hands are private: each peer receives only its own cards. The snapshot
##    also carries local_session.gd's fields (revision, actions, table,
##    history, winner, ...) so the online UI can reuse the local contract.

signal server_started(port: int)
signal server_stopped()
signal state_received(state: Dictionary)  # latest snapshot; local Clients connect here

const GROUP := "truc_server"  # Clients find their local Server node via this group
const GAME_SCENE := preload("res://components/game.tscn")
const LOCAL_SESSION := preload("res://ui/local_session.gd")
const DEFAULT_PORT := 24565

@export var bind_ip: String = "::"  # IPv6 wildcard; "*", "127.0.0.1", ... also work
@export var max_clients := 2  # seat 2 plus one spare (extra peers spectate, unseated)

var game: Game  # the authoritative match; exists only on the host

# Bookkeeping mirrored from ui/local_session.gd, so clients can reuse the
# local UI contract: revision-guarded actions, public history, table, winner.
var revision := 0  # bumps on every awaited turn; clients echo it back
var history: Array[String] = []  # public plays and actions only
var table: Array[String] = []  # cards of the trick in play
var round_number := 1
var winner := ""

var _hosting := false
var _seat_by_peer := { 1: 1 }  # peer id -> seat; first guest to join gets seat 2


func _ready() -> void:
	add_to_group(GROUP)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


# --- lifecycle ---------------------------------------------------------------

## Create a server on `port`. Fails with ERR_ALREADY_IN_USE while already
## hosting or connected to someone else's server, or with the ENet error if
## the port cannot be bound.
func start_server(port: int = DEFAULT_PORT) -> Error:
	if _network_active():
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(bind_ip)
	var err := peer.create_server(port, max_clients)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_hosting = true
	revision = 0
	history.clear()
	table.clear()
	round_number = 1
	winner = ""
	game = GAME_SCENE.instantiate()
	add_child(game)
	game.awaiting_action.connect(_on_awaiting)
	game.trick_won.connect(_on_trick_won)
	game.round_ended.connect(_on_round_ended)
	game.game_ended.connect(_on_game_ended)
	_sync_state()
	server_started.emit(port)
	return OK


## Stop the hosted server and disconnect every client.
func stop_server() -> void:
	if not _hosting:
		return
	_hosting = false
	_seat_by_peer = { 1: 1 }
	var peer := multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = null  # room closed: no further RPCs
	if peer != null:
		peer.close()  # ENet notifies the clients, they see server_disconnected
	if game != null:
		game.queue_free()
		game = null
	server_stopped.emit()


func is_hosting() -> bool:
	return _hosting


# --- peers -------------------------------------------------------------------


func _on_peer_disconnected(id: int) -> void:
	if not _hosting:
		return  # relay machines ignore connection events
	_seat_by_peer.erase(id)  # the seat opens up again for a rejoiner
	_sync_state()

func _on_peer_connected(id: int) -> void:
	if not _hosting:
		return  # relay machines ignore connection events
	if id != 1 and not _seat_by_peer.values().has(2):
		_seat_by_peer[id] = 2  # first joiner takes the open seat, extras spectate
	_sync_state()


# --- session bookkeeping (mirrors ui/local_session.gd) -----------------------

func _on_awaiting(_player: Player, _phase: int) -> void:
	revision += 1
	_sync_state()

func _on_trick_won(player: Player, _cards: Array) -> void:
	_log("Trick tied." if player == null else "Player %d wins the trick." % _seat_of(player))
	_sync_state()

func _on_round_ended(player: Player, points: int) -> void:
	_log("Round %d: draw." % round_number if player == null else "Round %d: Player %d earns %d points." % [round_number, _seat_of(player), points])
	round_number += 1
	_sync_state()

func _on_game_ended(player: Player) -> void:
	winner = "Player %d" % _seat_of(player)
	_log(winner + " wins the match!")
	_sync_state()

func _log(message: String) -> void:
	history.append(message)
	if history.size() > 40:
		history.pop_front()



# --- game action wrappers (invoked over RPC by the Clients' local relays) ----

@rpc("any_peer", "call_local", "reliable")
func s_action(seat: int, action: String, args: Array) -> void:
	if game == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = 1  # call_local execution on the host itself
	var my_seat: int = _seat_by_peer.get(sender, 0)
	if my_seat == 0:
		return  # unseated spectator
	if seat != 0 and seat != my_seat:
		return  # a client may never act for its opponent
	var player := _seat_player(my_seat)
	if action != "start_game" and not _legal_actions(my_seat).has(action):
		return  # out-of-turn or stale commands never reach the Game
	match action:
		"start_game":
			if not game.game_is_playing:
				# start/restart is host-controlled; shared state resets with it
				revision += 1
				history.clear()
				table.clear()
				round_number = 1
				winner = ""
				game.start_game()
			return
		"play_card":
			if args.size() < 2:
				return
			var card := _hand_card(player, args[0], args[1])
			if card == null:
				return
			if game.trick_cards.is_empty():
				table.clear()
			var played := "Player %d: %s" % [my_seat, LOCAL_SESSION.card_text(card)]
			table.append(played)
			_log(played)
			game.play_card(player, card)
			return
	_log("Player %d: %s" % [my_seat, action.replace("_", " ")])
	match action:
		"concede":
			game.concede(player)
		"pass_redeal":
			game.pass_redeal(player)
		"propose_redeal":
			game.propose_redeal(player)
		"accept_redeal":
			if args.size() < 1:
				return
			game.accept_redeal(player, args[0])
		"pass_raise":
			game.pass_raise(player)
		"offer_raise":
			game.offer_raise(player)
		"offer_mon_reste":
			game.offer_mon_reste(player)
		"accept_raise":
			game.accept_raise(player)
		"raise_more":
			game.raise_more(player)


# --- state sync --------------------------------------------------------------

func _sync_state() -> void:
	if not _hosting or game == null:
		return
	state_received.emit(_snapshot(1))  # the host's own Client is local
	for peer in multiplayer.get_peers():
		rpc_id(peer, "c_state", _snapshot(_seat_by_peer.get(peer, 0)))


@rpc("authority", "call_remote", "reliable")
func c_state(snap: Dictionary) -> void:
	state_received.emit(snap)  # relay: hand the snapshot to the local Client


func _snapshot(for_seat: int) -> Dictionary:
	var p1: Player = game.player_1
	var p2: Player = game.player_2
	var hand: Array = []
	var opp_cards := -1
	if for_seat == 1:
		hand = _hand_payload(p1)
		opp_cards = p2.hand.size()
	elif for_seat == 2:
		hand = _hand_payload(p2)
		opp_cards = p1.hand.size()
	var active := _seat_of(game.decision_player)
	if active == 0:
		active = _seat_of(game.current_player)
	return {
		"phase": game.phase,
		"your_seat": for_seat,
		"points": [p1.points, p2.points],
		"bet": game.bet,
		"pending_bet": game.pending_bet,
		"mon_reste": game.mon_reste_pending,
		"tricks_left": game.tricks_left,
		"trick_wins": [game.trick_wins.get(p1, 0), game.trick_wins.get(p2, 0)],
		"dealer": _seat_of(game.dealer),
		"lead": _seat_of(game.lead),
		"current": _seat_of(game.current_player),
		"decision": _seat_of(game.decision_player),
		"hand": hand,  # own cards only, as [[suit, rank, label], ...]
		"opp_cards": opp_cards,  # opponent's cards stay hidden behind a count
		# local_session.gd-compatible fields: the online UI renders these as-is
		"revision": revision,
		"actions": _legal_actions(for_seat),
		"active_seat": active,
		"scores": [p1.points, p2.points],
		"target": game.points_to_win,
		"round": round_number,
		"winner": winner,
		"table": table.duplicate(),
		"history": history.duplicate(),
	}


# --- helpers -------------------------------------------------------------------

func _seat_of(player: Player) -> int:
	if player == null or game == null:
		return 0
	return 1 if player == game.player_1 else 2


func _seat_player(seat: int) -> Player:
	if seat == 1:
		return game.player_1
	if seat == 2:
		return game.player_2
	return null


func _hand_payload(player: Player) -> Array:
	var out: Array = []
	for card in player.hand:
		out.append([card.suit, card.rank, LOCAL_SESSION.card_text(card)])
	return out

## What the UI may offer this seat right now; mirrors local_session.legal_actions.
func _legal_actions(for_seat: int) -> Array[String]:
	var result: Array[String] = []
	var player := _seat_player(for_seat)
	if game == null or player == null or not game.round_is_playing:
		return result
	match game.phase:
		Game.Phase.REDEAL_OFFER:
			if game.decision_player == player:
				result.assign(["pass_redeal", "propose_redeal"])
		Game.Phase.REDEAL_RESPONSE:
			if game.decision_player == player:
				result.assign(["accept_redeal", "decline_redeal"])
		Game.Phase.RAISE_WINDOW:
			if game.decision_player == player:
				result.append("pass_raise")
				if game.bet < game.points_to_win:
					result.append("offer_raise")
					result.append("offer_mon_reste")
		Game.Phase.RAISE_RESPONSE:
			if game.decision_player == player:
				result.append("accept_raise")
				if not game.mon_reste_pending and game.pending_bet < game.points_to_win:
					result.append("raise_more")
		Game.Phase.PLAY:
			if game.current_player == player:
				result.append("play_card")
	if not result.is_empty():
		result.append("concede")
	return result

## Cards are sent as (suit, rank); map back to the instance in the player's
## hand, because game.gd compares CardData by reference.
func _hand_card(player: Player, suit: int, rank: int) -> CardData:
	for card in player.hand:
		if card.suit == suit and card.rank == rank:
			return card
	return null  # not in hand: game.play_card ignores it


func _network_active() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not peer is OfflineMultiplayerPeer
