extends Node2D

class_name Game

## Le Truc - core logic.
##
## Rules implemented (from the original prototype notes):
##  - First dealer is chosen at random (coin toss), then alternates every round.
##  - Dealer deals 3 cards to each player; the non-dealer leads the first trick.
##  - Before play, the non-dealer may propose a redeal once; if the dealer
##    accepts, the hands are thrown in and redealt.
##  - The winner of a trick is the higher rank; suits never count. Rank
##    strength follows CardData.Rank order: 9 < 10 < V < D < R < A < 8 < 7.
##    Equal ranks tie the trick.
##  - A player may concede at any time; the opponent scores the current bet.
##  - A round ends when a player concedes, takes 2 tricks, or all 3 tricks
##    are played. With no 2-trick winner, the winner of the first won trick
##    wins the round; three tied tricks award no points.
##  - Before each trick either player may raise the bet by raise_step or go
##    "mon reste" (bet the whole game). A pending raise must be answered by
##    accepting it, re-raising by 2 (capped at the whole game, and never
##    against a mon reste), or conceding at the stake before the raise:
##    declining a raise IS conceding. Once the round is worth the whole
##    game no further raises are possible.

enum Phase { IDLE, REDEAL_OFFER, REDEAL_RESPONSE, RAISE_WINDOW, RAISE_RESPONSE, PLAY, GAME_OVER }

signal trick_won(winner: Player, cards: Array)  # winner == null: tied trick
signal round_ended(winner: Player, points: int)  # winner == null: drawn round, no points
signal game_ended(winner: Player)
signal awaiting_action(player: Player, phase: Phase)  # a player must act via one of the action methods

@export var min_bet: int = 1
@export var points_to_win: int = 12
@export var raise_step: int = 2

@onready var deck: Deck = $Deck
@onready var player_1: Player = $Player1
@onready var player_2: Player = $Player2

var dealer: Player
var lead: Player  # leads the trick about to be played
var current_player: Player  # must play a card during Phase.PLAY
var decision_player: Player  # must act during redeal / raise phases

var bet: int = 0  # agreed stake of the current round
var pending_bet: int = 0  # raise under negotiation
var mon_reste_pending: bool = false  # the pending raise is a mon reste (answer: accept or fold only)
var tricks_left: int = 0
var trick_wins: Dictionary = {}  # Player -> tricks won this round
var trick_cards: Array[CardData] = []  # cards of the trick in play, in play order
var first_trick_winner: Player  # winner of the first won trick; decides drawn rounds
var round_is_playing: bool = false
var game_is_playing: bool = false
var phase: Phase = Phase.IDLE

signal _acted  # a validated player action arrived (private)
var _pending: Dictionary = {}  # the action the flow coroutine resumes from


# --- public API ------------------------------------------------------------
# start_game() runs the whole match as a coroutine. A driver (human UI or AI)
# reacts to awaiting_action by calling exactly one action method for the
# player it acts on. Actions submitted in the wrong phase, by the wrong
# player, or outside a round are silently ignored.

## Starts (or restarts) the match. First dealer is a coin toss.
func start_game() -> void:
	if game_is_playing:
		return
	game_is_playing = true
	player_1.points = 0
	player_2.points = 0
	dealer = [player_1, player_2].pick_random()
	while game_is_playing:
		await _play_round()
	phase = Phase.GAME_OVER


## Play a card (Phase.PLAY, current_player, card must be in hand).
func play_card(player: Player, card: CardData) -> void:
	if phase == Phase.PLAY and player == current_player and player.hand.has(card):
		_submit({ "action": "play_card", "player": player, "card": card })


## Concede the round at the current bet (any time during a round).
func concede(player: Player) -> void:
	if round_is_playing and _is_seat(player):
		_end_round(_other(player))


## Decline to propose a redeal (Phase.REDEAL_OFFER, non-dealer).
func pass_redeal(player: Player) -> void:
	if phase == Phase.REDEAL_OFFER and player == decision_player:
		_submit({ "action": "pass_redeal", "player": player })


## Propose a redeal (Phase.REDEAL_OFFER, non-dealer; allowed once per round).
func propose_redeal(player: Player) -> void:
	if phase == Phase.REDEAL_OFFER and player == decision_player:
		_submit({ "action": "propose_redeal", "player": player })


## Dealer's answer to a redeal proposal (Phase.REDEAL_RESPONSE).
func accept_redeal(player: Player, accept: bool) -> void:
	if phase == Phase.REDEAL_RESPONSE and player == decision_player:
		_submit({ "action": "accept_redeal" if accept else "decline_redeal", "player": player })


## Decline to raise (Phase.RAISE_WINDOW).
func pass_raise(player: Player) -> void:
	if phase == Phase.RAISE_WINDOW and player == decision_player:
		_submit({ "action": "pass_raise", "player": player })


## Offer to raise the bet by raise_step (Phase.RAISE_WINDOW; nothing above
## the whole game, so not once the bet already is the whole game).
func offer_raise(player: Player) -> void:
	if phase == Phase.RAISE_WINDOW and player == decision_player and bet < points_to_win:
		_submit({ "action": "offer_raise", "player": player })


## Bet the whole game on this round (Phase.RAISE_WINDOW).
func offer_mon_reste(player: Player) -> void:
	if phase == Phase.RAISE_WINDOW and player == decision_player and bet < points_to_win:
		_submit({ "action": "mon_reste", "player": player })


## Accept the pending raise (Phase.RAISE_RESPONSE, decision_player).
func accept_raise(player: Player) -> void:
	if phase == Phase.RAISE_RESPONSE and player == decision_player:
		_submit({ "action": "accept_raise", "player": player })


## Re-raise the pending bet (Phase.RAISE_RESPONSE, decision_player; never
## against a mon reste, and only while below the whole game).
func raise_more(player: Player) -> void:
	if phase == Phase.RAISE_RESPONSE and player == decision_player \
			and not mon_reste_pending and pending_bet < points_to_win:
		_submit({ "action": "raise_more", "player": player })


# --- match flow ------------------------------------------------------------

func _play_round() -> void:
	round_is_playing = true
	bet = min_bet
	pending_bet = 0
	mon_reste_pending = false
	tricks_left = 3
	trick_wins = { player_1: 0, player_2: 0 }
	first_trick_winner = null
	lead = _other(dealer)
	player_1.hand.clear()
	player_2.hand.clear()
	deck.shuffle()
	_deal()

	await _redeal_phase()
	while round_is_playing and tricks_left > 0:
		await _raise_window()
		await _play_trick()

	dealer = _other(dealer)  # dealer alternates between rounds


func _redeal_phase() -> void:
	phase = Phase.REDEAL_OFFER
	decision_player = _other(dealer)
	awaiting_action.emit(decision_player, phase)
	await _acted
	if not round_is_playing or _pending.action != "propose_redeal":
		return  # passed (or round died): keep the deal

	phase = Phase.REDEAL_RESPONSE
	decision_player = dealer
	awaiting_action.emit(dealer, phase)
	await _acted
	if not round_is_playing or _pending.action != "accept_redeal":
		return  # declined (or round died): redeal can only be proposed once per round

	player_1.hand.clear()
	player_2.hand.clear()
	deck.shuffle()  # dealt cards sit in deck.discards, so nothing is lost
	_deal()


func _raise_window() -> void:
	for i in 2:  # each player gets one chance to raise before the trick
		if not round_is_playing:
			return
		phase = Phase.RAISE_WINDOW
		decision_player = lead if i == 0 else _other(lead)
		awaiting_action.emit(decision_player, phase)
		await _acted
		if not round_is_playing:
			return
		match _pending.action:
			"offer_raise":
				pending_bet = bet + raise_step
				mon_reste_pending = false
				await _negotiate_raise(_pending.player)
				return  # one raise negotiation per trick
			"mon_reste":
				pending_bet = points_to_win
				mon_reste_pending = true
				await _negotiate_raise(_pending.player)
				return
			_:  # pass_raise: the other player may still raise
				pass


func _negotiate_raise(offerer: Player) -> void:
	var responder: Player = _other(offerer)
	while round_is_playing:
		phase = Phase.RAISE_RESPONSE
		decision_player = responder
		awaiting_action.emit(responder, phase)
		await _acted
		if not round_is_playing:
			return
		match _pending.action:
			"accept_raise":
				bet = pending_bet
				return
			"raise_more":
				pending_bet = mini(pending_bet + raise_step, points_to_win)
				responder = _other(responder)  # roles swap on a re-raise
			_:
				_end_round(_other(responder))  # declining a raise concedes at the pre-raise stake
				return


func _play_trick() -> void:
	trick_cards = []
	current_player = lead
	for i in 2:
		phase = Phase.PLAY
		awaiting_action.emit(current_player, phase)
		await _acted
		if not round_is_playing:
			return
		current_player.hand.erase(_pending.card)
		trick_cards.append(_pending.card)
		current_player = _other(current_player)

	tricks_left -= 1
	var winner: Player = _trick_winner(trick_cards[0], trick_cards[1])
	if winner:
		trick_wins[winner] += 1
		if first_trick_winner == null:
			first_trick_winner = winner
		lead = winner  # the winner leads next; a tied trick keeps the leader
	trick_won.emit(winner, trick_cards)

	if winner and trick_wins[winner] == 2:
		_end_round(winner)
	elif tricks_left == 0:
		_end_round(first_trick_winner)  # null: three tied tricks, no points


func _trick_winner(lead_card: CardData, follow_card: CardData) -> Player:
	if lead_card.rank > follow_card.rank:
		return lead
	if follow_card.rank > lead_card.rank:
		return _other(lead)
	return null  # equal ranks: drawn trick


func _end_round(winner: Player) -> void:
	var points: int = 0
	if winner:
		points = bet
		winner.points += points
	round_is_playing = false
	bet = 0
	pending_bet = 0
	mon_reste_pending = false
	phase = Phase.IDLE
	decision_player = null
	current_player = null
	round_ended.emit(winner, points)
	if winner and winner.points >= points_to_win:
		game_is_playing = false
		phase = Phase.GAME_OVER
		game_ended.emit(winner)
	_acted.emit()  # wake whatever coroutine was waiting for an action


# --- helpers ---------------------------------------------------------------

func _deal() -> void:
	for i in 3:  # dealer deals in sequence, non-dealer receives first
		lead.hand.append(deck.deal_one())
		dealer.hand.append(deck.deal_one())


func _submit(action: Dictionary) -> void:
	_pending = action
	_acted.emit()


func _is_seat(player: Player) -> bool:
	return player == player_1 or player == player_2


func _other(player: Player) -> Player:
	return player_2 if player == player_1 else player_1
