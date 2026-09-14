extends SceneTree

## Headless self-check for the Le Truc core logic.
## Run: godot --headless --path . -s res://test_game.gd

const GameScene := preload("res://components/game.tscn")

var game: Game
var failures: int = 0

var queue: Array = []  # scripted decisions; a default policy is used when empty
var stop: bool = false
var rounds_target: int = 0  # stop driving once this many rounds ended (0: until game end)
var rounds_meta: Array = []  # [lead, p1 hand size, p2 hand size, dealer] captured at round_ended
var trick_rounds: Array = []  # round index of each trick_won event
var awaiting: Array = []  # [player, phase] awaiting_action log
var tricks: Array = []  # [winner, cards] trick_won log
var rounds: Array = []  # [winner, points] round_ended log
var games: Array = []  # [winner] game_ended log
var dealt: Array = []  # pre-redeal hand snapshot
var dealt_after: Array = []  # post-redeal hand snapshot
var acted: int = 0  # number of validated actions seen through Game._acted


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _basic_round()
	await _raise_chain_concede()
	await _refuse_raise()
	await _mon_reste()
	await _mon_reste_response()
	await _full_game()
	await _redeal()
	await _direct_checks()
	print("")
	if failures == 0:
		print("ALL CHECKS PASSED")
		quit(0)
	else:
		print("%d CHECK(S) FAILED" % failures)
		quit(1)


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   " + msg)
	else:
		failures += 1
		print("  FAIL " + msg)


# --- driver ----------------------------------------------------------------

func new_game() -> void:
	seed(11)  # before any RNG use (deck shuffles in its _ready)
	game = GameScene.instantiate()
	root.add_child(game)
	game.awaiting_action.connect(_on_awaiting)
	game.trick_won.connect(_on_trick)
	game.round_ended.connect(_on_round)
	game.game_ended.connect(_on_game)
	game._acted.connect(func() -> void: acted += 1)
	queue = []
	stop = false
	awaiting = []
	tricks = []
	rounds = []
	games = []
	rounds_meta = []
	trick_rounds = []
	acted = 0


func free_game() -> void:
	game.queue_free()
	await process_frame


func play_out(max_rounds: int) -> void:
	rounds_target = max_rounds
	game.start_game()
	var frames := 0
	while not stop and frames < 3000:
		await process_frame
		frames += 1
		if max_rounds > 0 and rounds.size() >= max_rounds:
			stop = true
	check(frames < 3000, "terminated within frame budget")


func _on_awaiting(player, ph) -> void:
	awaiting.append([player, ph])
	if stop:
		return
	var d: Callable = queue.pop_front() if not queue.is_empty() else _default_for(ph)
	d.call_deferred(game, player)


func _on_trick(winner, cards) -> void:
	tricks.append([winner, cards])
	trick_rounds.append(rounds.size())  # round that is still being played


func _on_round(winner, pts) -> void:
	rounds.append([winner, pts])
	rounds_meta.append([game.lead, game.player_1.hand.size(), game.player_2.hand.size(), game.dealer])
	if rounds_target > 0 and rounds.size() >= rounds_target:
		stop = true  # synchronously, before the flow can start another round


func _on_game(winner) -> void:
	games.append([winner])
	stop = true

func _default_for(ph: int) -> Callable:
	match ph:
		Game.Phase.REDEAL_OFFER:
			return d_pass_redeal
		Game.Phase.RAISE_WINDOW:
			return d_pass_raise
		Game.Phase.RAISE_RESPONSE:
			return d_accept_raise
	return d_play_first  # Phase.PLAY


# scripted decisions: (game, player) -> void
func d_pass_redeal(g, p) -> void:
	g.pass_redeal(p)


func d_propose_redeal(g, p) -> void:
	g.propose_redeal(p)


func d_accept_redeal(g, p) -> void:
	g.accept_redeal(p, true)


func d_decline_redeal(g, p) -> void:
	g.accept_redeal(p, false)


func d_pass_raise(g, p) -> void:
	g.pass_raise(p)


func d_offer_raise(g, p) -> void:
	g.offer_raise(p)


func d_mon_reste(g, p) -> void:
	g.offer_mon_reste(p)


func d_accept_raise(g, p) -> void:
	g.accept_raise(p)


func d_raise_more(g, p) -> void:
	g.raise_more(p)


func d_concede(g, p) -> void:
	g.concede(p)


func d_play_first(g, p) -> void:
	g.play_card(p, p.hand[0])


func d_snap_and_pass_redeal(g, p) -> void:
	dealt = [g.player_1.hand.duplicate(), g.player_2.hand.duplicate()]
	g.pass_redeal(p)


func d_snap_and_propose_redeal(g, p) -> void:
	dealt = [g.player_1.hand.duplicate(), g.player_2.hand.duplicate()]
	g.propose_redeal(p)


func d_capture_and_pass_raise(g, p) -> void:
	dealt_after = [g.player_1.hand.duplicate(), g.player_2.hand.duplicate()]
	g.pass_raise(p)


func d_no_raise_vs_mon_reste(g, p) -> void:
	acted = 0
	g.raise_more(p)  # must be rejected: a mon reste can only be accepted or folded
	check(acted == 0, "re-raise against a mon reste is rejected")
	g.accept_raise(p)


func d_no_raise_at_full_bet(g, p) -> void:
	acted = 0
	g.offer_raise(p)  # must be rejected: the round is already worth the whole game
	g.offer_mon_reste(p)
	check(acted == 0, "no raising once the bet is the whole game")
	g.pass_raise(p)


func _otherp(p) -> Player:
	return game.player_2 if p == game.player_1 else game.player_1


# --- scenarios ---------------------------------------------------------------

func _basic_round() -> void:
	print("scenario: basic round, no raises, default play")
	new_game()
	queue = [d_snap_and_pass_redeal]
	await play_out(1)

	var plays: Array = []
	for e in awaiting:
		if e[1] == Game.Phase.PLAY:
			plays.append(e[0])
	check(rounds.size() == 1, "one round ended")
	check(dealt.size() == 2 and dealt[0].size() == 3 and dealt[1].size() == 3, "3 cards dealt to each player")
	check(plays.size() == tricks.size() * 2, "two cards played per trick")

	# independently re-derive every trick from the card log: winner = higher
	# rank, first card of a trick belongs to its leader, tie = null
	var wins := { game.player_1: 0, game.player_2: 0 }
	var first_winner = null
	var cur_lead = plays[0] if plays.size() > 0 else null
	var ok_ranks := true
	var ok_lead := true
	for i in tricks.size():
		var cards: Array = tricks[i][1]
		var expect = null
		if cards[0].rank > cards[1].rank:
			expect = cur_lead
		elif cards[1].rank > cards[0].rank:
			expect = _otherp(cur_lead)
		if tricks[i][0] != expect:
			ok_ranks = false
		if 2 * i + 2 < plays.size():
			var want = tricks[i][0] if tricks[i][0] != null else cur_lead
			if plays[2 * i + 2] != want:
				ok_lead = false
		if tricks[i][0] != null:
			wins[tricks[i][0]] += 1
			if first_winner == null:
				first_winner = tricks[i][0]
		cur_lead = tricks[i][0] if tricks[i][0] != null else cur_lead
	check(ok_ranks, "trick winners follow rank order (ties draw)")
	check(ok_lead, "trick winner leads the next trick")

	var expect_winner = null
	if wins[game.player_1] >= 2:
		expect_winner = game.player_1
	elif wins[game.player_2] >= 2:
		expect_winner = game.player_2
	else:
		expect_winner = first_winner
	check(rounds[0][0] == expect_winner, "round winner matches rules (2 tricks, else first won trick)")
	check(rounds[0][1] == (1 if expect_winner != null else 0), "round awards min_bet (nothing on three ties)")

	var counts := { game.player_1: 0, game.player_2: 0 }
	for p in plays:
		counts[p] += 1
	check(rounds_meta[0][1] + counts[game.player_1] == 3 and rounds_meta[0][2] + counts[game.player_2] == 3, "played cards leave the hands")
	await free_game()


func _raise_chain_concede() -> void:
	print("scenario: raise, re-raise, accept, concede mid-trick")
	new_game()
	queue = [d_pass_redeal, d_pass_raise, d_offer_raise, d_raise_more, d_accept_raise, d_play_first, d_concede]
	await play_out(1)

	check(rounds.size() == 1, "round ended")
	var winner = rounds[0][0]
	check(rounds.size() == 1 and winner == rounds_meta[0][0], "conceding mid-trick loses to the trick leader")
	check(rounds[0][1] == 5, "raise chain 1->3->5 accepted; concession scored at stake 5")
	check(winner.points == 5, "points awarded at the raised stake")
	check(tricks.size() == 0, "mid-trick concession leaves the trick unresolved")
	await free_game()


func _refuse_raise() -> void:
	print("scenario: refuse a raise, concede at the original bet")
	new_game()
	queue = [d_pass_redeal, d_pass_raise, d_offer_raise, d_concede]
	await play_out(1)

	check(rounds.size() == 1, "round ended")
	check(rounds[0][1] == 1, "concession against a pending raise scores the stake before the raise")
	check(tricks.size() == 0 and awaiting.any(func(e): return e[1] == Game.Phase.RAISE_RESPONSE), "concession happened during the raise response")
	await free_game()


func _mon_reste() -> void:
	print("scenario: mon reste bets the whole game")
	new_game()
	queue = [d_pass_redeal, d_pass_raise, d_mon_reste, d_accept_raise]
	await play_out(0)  # stops on game_ended

	check(games.size() == 1, "game ended")
	var w = games[0][0]
	check(w.points >= game.points_to_win, "mon reste winner reaches the game target")
	check(rounds.size() == 1 and rounds[0][0] == w and rounds[0][1] == game.points_to_win, "mon reste round is worth the whole game")
	check(game.phase == Game.Phase.GAME_OVER and not game.game_is_playing, "game is over")
	await free_game()


func _mon_reste_response() -> void:
	print("scenario: mon reste must be accepted or conceded, never re-raised")
	new_game()
	queue = [d_pass_redeal, d_pass_raise, d_mon_reste, d_no_raise_vs_mon_reste, d_play_first, d_play_first, d_no_raise_at_full_bet]
	await play_out(0)  # the accepted mon reste ends the game

	check(games.size() == 1, "game ended")
	check(rounds.size() == 1 and rounds[0][1] == game.points_to_win, "mon reste round stands at the full stake")
	await free_game()


func _redeal() -> void:
	print("scenario: redeal proposal accepted")
	new_game()
	queue = [d_snap_and_propose_redeal, d_accept_redeal, d_capture_and_pass_raise]
	await play_out(1)

	check(dealt_after.size() == 2 and dealt_after[0].size() == 3 and dealt_after[1].size() == 3, "hands redealt to 3 cards each")
	check(dealt_after[0] != dealt[0] or dealt_after[1] != dealt[1], "redeal actually reshuffles the hands")
	await free_game()


func _direct_checks() -> void:
	print("scenario: rank order, ties, and action validation")
	new_game()
	var p1: Player = game.player_1
	var p2: Player = game.player_2
	game.lead = p1
	var C = CardData
	check(game._trick_winner(C.new(C.Suit.HEARTS, C.Rank.SEVEN), C.new(C.Suit.SPADES, C.Rank.ACE)) == p1, "7 outranks A")
	check(game._trick_winner(C.new(C.Suit.HEARTS, C.Rank.EIGHT), C.new(C.Suit.SPADES, C.Rank.ACE)) == p1, "8 outranks A")
	check(game._trick_winner(C.new(C.Suit.HEARTS, C.Rank.ACE), C.new(C.Suit.SPADES, C.Rank.ROI)) == p1, "A outranks R")
	check(game._trick_winner(C.new(C.Suit.HEARTS, C.Rank.DAME), C.new(C.Suit.SPADES, C.Rank.VALET)) == p1, "D outranks V")
	check(game._trick_winner(C.new(C.Suit.HEARTS, C.Rank.NINE), C.new(C.Suit.SPADES, C.Rank.TEN)) == p2, "10 outranks 9")
	check(game._trick_winner(C.new(C.Suit.HEARTS, C.Rank.VALET), C.new(C.Suit.SPADES, C.Rank.VALET)) == null, "equal ranks tie")

	acted = 0
	game.play_card(p1, null)
	game.pass_raise(p1)
	game.accept_raise(p1)
	game.raise_more(p1)
	game.concede(p1)  # no round running
	check(acted == 0, "out-of-phase actions are rejected")

	game.phase = Game.Phase.RAISE_RESPONSE
	game.decision_player = p1
	game.mon_reste_pending = true
	game.pending_bet = 5  # below the cap: only the mon reste flag can block this
	game.raise_more(p1)
	check(acted == 0, "re-raise against a mon reste is rejected by the flag")
	game.mon_reste_pending = false
	game.pending_bet = game.points_to_win
	game.raise_more(p1)
	check(acted == 0, "cannot re-raise once the pending bet is the whole game")
	game.pending_bet = game.points_to_win - 1
	game.raise_more(p1)
	check(acted == 1, "re-raise accepted while below the cap")
	await free_game()


func _full_game() -> void:
	print("scenario: full game to 12 points, default play")
	new_game()
	await play_out(0)  # defaults until game_ended

	check(games.size() == 1, "game ended")
	var w = games[0][0]
	var l = _otherp(w)
	check(w.points >= 12 and l.points < 12, "exactly one player reaches 12")

	var p1_pts := 0
	var p2_pts := 0
	for e in rounds:
		if e[0] == game.player_1:
			p1_pts += e[1]
		elif e[0] == game.player_2:
			p2_pts += e[1]
	check(game.player_1.points == p1_pts and game.player_2.points == p2_pts, "points ledger matches every round's award")

	var ok_alt := true
	for i in range(1, rounds.size()):
		if rounds_meta[i][3] == rounds_meta[i - 1][3]:
			ok_alt = false
	check(ok_alt, "dealer alternates every round")

	# the non-dealer leads the first trick of every round
	var plays: Array = []
	for e in awaiting:
		if e[1] == Game.Phase.PLAY:
			plays.append(e[0])
	var plays_per_round := {}
	for r in tricks:
		plays_per_round[r] = 0
	for r in trick_rounds:
		plays_per_round[r] = plays_per_round.get(r, 0) + 2
	var idx := 0
	var ok_lead_round := true
	for r in rounds.size():
		if idx >= plays.size() or plays[idx] != _otherp(rounds_meta[r][3]):
			ok_lead_round = false
		idx += plays_per_round.get(r, 0)
	check(ok_lead_round, "non-dealer leads the first trick of every round")
	check(idx == plays.size(), "every played card belongs to a round's tricks")
	await free_game()
