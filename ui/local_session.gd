extends Node
## Local authority. A network transport should send commands to the host and
## return snapshot_for(authenticated_seat) only to that seat.
signal changed
const GAME = preload("res://components/game.tscn")
var game: Game
var seat := 0
var revision := 0
var history: Array[String] = []
var table: Array[String] = []
var round_number := 1
var winner := ""

func start() -> void:
	if is_instance_valid(game):
		remove_child(game)
		game.queue_free()
	game = GAME.instantiate()
	add_child(game)
	history.clear()
	table.clear()
	round_number = 1
	winner = ""
	game.awaiting_action.connect(_awaiting)
	game.trick_won.connect(_trick)
	game.round_ended.connect(_round)
	game.game_ended.connect(_ended)
	game.start_game.call_deferred()

func _seat(player: Player) -> int:
	return 1 if player == game.player_1 else 2

func _player(id: int) -> Player:
	return game.player_1 if id == 1 else game.player_2

func card_text(card: CardData) -> String:
	return ["9", "10", "V", "D", "R", "A", "8", "7"][card.rank] + " " + ["Hearts", "Diamonds", "Spades", "Clubs"][card.suit]

func _awaiting(player: Player, _phase: int) -> void:
	seat = _seat(player)
	revision += 1
	changed.emit.call_deferred()

func _trick(player: Player, _cards: Array) -> void:
	_log("Trick tied." if player == null else "Player %d wins the trick." % _seat(player))

func _round(player: Player, points: int) -> void:
	_log("Round %d: draw." % round_number if player == null else "Round %d: Player %d earns %d points." % [round_number, _seat(player), points])
	round_number += 1

func _ended(player: Player) -> void:
	winner = "Player %d" % _seat(player)
	_log(winner + " wins the match!")
	revision += 1
	changed.emit.call_deferred()

func _log(message: String) -> void:
	history.append(message)
	if history.size() > 40:
		history.pop_front()

func legal_actions(id: int) -> Array[String]:
	var result: Array[String] = []
	if id != seat or not winner.is_empty() or not game.round_is_playing:
		return result
	match game.phase:
		Game.Phase.REDEAL_OFFER: result.assign(["pass_redeal", "propose_redeal"])
		Game.Phase.REDEAL_RESPONSE: result.assign(["accept_redeal", "decline_redeal"])
		Game.Phase.RAISE_WINDOW:
			result.append("pass_raise")
			if game.bet < game.points_to_win:
				result.append("offer_raise")
				result.append("offer_mon_reste")
		Game.Phase.RAISE_RESPONSE:
			result.append("accept_raise")
			if not game.mon_reste_pending and game.pending_bet < game.points_to_win:
				result.append("raise_more")
		Game.Phase.PLAY: result.append("play_card")
	result.append("concede")
	return result

## Revision rejects double clicks and stale commands. The host must derive id
## from the authenticated connection, not trust a seat supplied by a client.
func submit(id: int, action: String, card_index: int, expected_revision: int) -> bool:
	if expected_revision != revision or not legal_actions(id).has(action):
		return false
	var player := _player(id)
	if action == "play_card" and (card_index < 0 or card_index >= player.hand.size()):
		return false
	revision += 1
	if action == "play_card":
		if game.trick_cards.is_empty():
			table.clear()
		var card: CardData = player.hand[card_index]
		var played := "Player %d: %s" % [id, card_text(card)]
		table.append(played)
		_log(played)
		game.play_card(player, card)
	else:
		_log("Player %d: %s" % [id, action.replace("_", " ")])
		match action:
			"pass_redeal": game.pass_redeal(player)
			"propose_redeal": game.propose_redeal(player)
			"accept_redeal": game.accept_redeal(player, true)
			"decline_redeal": game.accept_redeal(player, false)
			"pass_raise": game.pass_raise(player)
			"offer_raise": game.offer_raise(player)
			"offer_mon_reste": game.offer_mon_reste(player)
			"accept_raise": game.accept_raise(player)
			"raise_more": game.raise_more(player)
			"concede": game.concede(player)
	changed.emit.call_deferred()
	return true

## Plain data only: never includes the opponent's cards or the deck order.
func snapshot_for(id: int) -> Dictionary:
	var hand: Array[Dictionary] = []
	if id in [1, 2]:
		for card in _player(id).hand:
			hand.append({"rank": int(card.rank), "suit": int(card.suit), "label": card_text(card)})
	return {"seat": id, "active_seat": seat, "revision": revision,
		"hand": hand, "actions": legal_actions(id), "phase": int(game.phase),
		"scores": [game.player_1.points, game.player_2.points],
		"hand_counts": [game.player_1.hand.size(), game.player_2.hand.size()],
		"bet": game.bet, "pending_bet": game.pending_bet,
		"target": game.points_to_win, "round": round_number,
		"dealer": _seat(game.dealer), "winner": winner,
		"table": table.duplicate(), "history": history.duplicate()}
