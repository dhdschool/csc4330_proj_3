extends Control
const SESSION = preload("res://ui/local_session.gd")
# Artwork numbers represent strength; the original rank enum stays unchanged.
const CARD_ART = {
	CardData.Rank.NINE: preload("res://cards/card-1.png"),
	CardData.Rank.TEN: preload("res://cards/card-2.png"),
	CardData.Rank.VALET: preload("res://cards/card-3.png"),
	CardData.Rank.DAME: preload("res://cards/card-4.png"),
	CardData.Rank.ROI: preload("res://cards/card-5.png"),
	CardData.Rank.ACE: preload("res://cards/card-6.png"),
	CardData.Rank.EIGHT: preload("res://cards/card-7.png"),
	CardData.Rank.SEVEN: preload("res://cards/card-8.png"),
}
const ONLINE_SESSION = preload("res://ui/online_session.gd")
var session: Node
var local_session: Node
var shown_seat := 0
var state: Dictionary = {}
var column: VBoxContainer
var busy := false
var page := "menu"
var online := false
var online_address := ""
var online_feedback := ""
var address_edit: LineEdit
var tutorial_step := 0
var tutorial_feedback := ""
var scroll_view: ScrollContainer
const CREAM = Color("f4eddc")
const SAGE = Color("5f725f")
const FOREST = Color("2d4b38")
const CHARCOAL = Color("302e27")
const BROWN = Color("504739")
const ACTION_LABELS = {"pass_redeal": "Keep these cards", "propose_redeal": "Request a redeal", "accept_redeal": "Accept redeal", "decline_redeal": "Keep the deal", "pass_raise": "Continue without raising", "offer_raise": "Raise by 2", "offer_mon_reste": "Mon reste • bet the match", "accept_raise": "Accept raise", "raise_more": "Re-raise by 2", "concede": "Concede round"}

func _ready() -> void:
	var background := ColorRect.new()
	background.color = FOREST
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var scroll := ScrollContainer.new()
	scroll_view = scroll
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	scroll.add_child(margin)
	column = VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)
	var theme_resource := Theme.new()
	theme_resource.default_font_size = 20
	theme = theme_resource
	_apply_theme()
	session = SESSION.new()
	local_session = session
	add_child(session)
	session.changed.connect(_refresh)
	_menu()

func _clear() -> void:
	column.add_theme_constant_override("separation", 16)
	scroll_view.scroll_vertical = 0
	for child in column.get_children():
		column.remove_child(child)
		child.queue_free()

func _label(text: String, size: int = 20) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(label)
	return label

func _button(text: String, callback: Callable, parent: Node = null) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(200, 52)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(callback)
	(parent if parent != null else column).add_child(button)
	return button

func _menu() -> void:
	_end_online()
	page = "menu"
	_clear()
	column.add_theme_constant_override("separation", 28)
	var space := Control.new()
	space.custom_minimum_size.y = 34
	column.add_child(space)
	var title := _label("Le Truc", 88)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var serif := SystemFont.new()
	serif.font_names = PackedStringArray(["Georgia", "Times New Roman", "serif"])
	title.add_theme_font_override("font", serif)
	for item in [["Game Rules", _rules], ["Tutorial", _tutorial_start], ["Local Play", _start], ["Online Play", _online_menu]]:
		var center := CenterContainer.new()
		column.add_child(center)
		var button := _button(item[0], item[1], center)
		button.custom_minimum_size = Vector2(minf(620, maxf(240, size.x - 72)), 82)
		button.add_theme_font_size_override("font_size", 28)
		button.add_theme_font_override("font", serif)
	var footer := _label("Two players. Three cards. One well-timed bluff.", 16)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

func _card_button(rank: int, label: String, callback: Callable, parent: Node) -> Button:
	var button := _button(label, callback, parent)
	button.icon = CARD_ART[rank]
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	button.custom_minimum_size = Vector2(150, 184)
	button.tooltip_text = label
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fff5dc")
	style.set_corner_radius_all(12)
	style.set_content_margin_all(6)
	for kind in ["normal", "hover", "pressed", "disabled"]:
		button.add_theme_stylebox_override(kind, style)
	var ink := Color("a72d35") if label.ends_with("Hearts") or label.ends_with("Diamonds") else Color("182e3c")
	for kind in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color"]:
		button.add_theme_color_override(kind, ink)
	for kind in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_disabled_color"]:
		button.add_theme_color_override(kind, Color.WHITE)
	return button

func _online_menu() -> void:
	page = "online"
	_clear()
	_label("ONLINE PLAY", 36)
	_label("Two computers, one match. One player hosts; the other joins over the local network.")
	address_edit = LineEdit.new()
	address_edit.name = "AddressEdit"
	address_edit.placeholder_text = "Host address  (e.g. ::1 or 192.168.1.42)"
	address_edit.custom_minimum_size = Vector2(minf(620, maxf(240, size.x - 72)), 52)
	address_edit.text = online_address
	column.add_child(address_edit)
	_button("Join game", _join_online)
	_button("Host a game", _host_online)
	if not online_feedback.is_empty():
		_label(online_feedback, 20)
		online_feedback = ""
	_label("Hosting uses UDP port %d. The host keeps the deck — only your own hand ever reaches this screen." % Server.DEFAULT_PORT, 16)
	_button("Back", _menu)


func _host_online() -> void:
	_enter_online()
	if session.host() != OK:
		_online_failed("Could not open the room (is UDP port %d already busy?)." % Server.DEFAULT_PORT)
		return
	session.start()  # start/restart is host-controlled


func _join_online() -> void:
	online_address = address_edit.text.strip_edges()
	if online_address.is_empty():
		online_feedback = "Enter the host player's address first."
		_online_menu()
		return
	_enter_online()
	if session.join(online_address) != OK:
		_online_failed("Could not start connecting to %s." % online_address)


func _enter_online() -> void:
	_end_online()
	online = true
	page = "game"
	shown_seat = 0
	busy = false
	session = ONLINE_SESSION.new()
	session.name = "OnlineSession"  # fixed path on every machine: RPCs match
	add_child(session)
	session.changed.connect(_refresh)
	session.failed.connect(_online_failed)


func _online_failed(reason: String) -> void:
	_end_online()
	online_feedback = reason
	_online_menu()


func _end_online() -> void:
	if not online:
		return
	online = false
	var net := session
	session = local_session
	net.stop()
	net.queue_free()


func _restart_online() -> void:
	session.start()


func _start() -> void:
	_end_online()
	page = "game"
	shown_seat = 0
	busy = false
	session.start()

func _refresh() -> void:
	if page != "game":
		return
	busy = false
	if online:
		shown_seat = session.seat  # the wire view is fixed to this machine's seat
	state = session.snapshot_for(session.seat)
	_clear()
	_game_header()
	if online and session.seat == 0:
		_label("Waiting for the host…", 28)
		return
	_label("Player 1  ·  %d     |     Player 2  ·  %d     •     First to %d" % [state.scores[0], state.scores[1], state.target], 24)
	if not state.winner.is_empty():
		_label(state.winner + " wins!", 36)
		if online and session.hosting:
			_button("Play again", _restart_online)
		elif online:
			_label("The host can start a rematch.", 20)
		else:
			_button("Play again", _start)
		_button("Back to start", _menu)
		_history()
		return
	if shown_seat != state.active_seat:
		if online:
			_label("Player %d is deciding…" % state.active_seat, 28)
			_label("Your hand stays hidden from your opponent; the table updates on its own.")
			_history()
			return
		_label("Pass to Player %d" % state.active_seat, 32)
		_label("Hands are hidden. When the other player has looked away, reveal your cards.")
		_button("Reveal my hand", _reveal)
		return
	_label("Round %d  •  Dealer: Player %d  •  Round stake: %d" % [state.round, state.dealer, state.bet])
	if state.pending_bet > 0:
		_label("Proposed stake: %d points. Conceding gives your opponent the previously agreed stake." % state.pending_bet)
	var prompts := {Game.Phase.REDEAL_OFFER: "Keep your hand or request a fresh deal.", Game.Phase.REDEAL_RESPONSE: "Your opponent requests a redeal. Do you agree?", Game.Phase.RAISE_WINDOW: "Continue, raise the stake, or bet the match.", Game.Phase.RAISE_RESPONSE: "Your opponent raised. Accept, re-raise when allowed, or concede.", Game.Phase.PLAY: "Choose a card to play."}
	_label("Player %d — %s" % [shown_seat, prompts.get(state.phase, "")], 24)
	_label("Opponent: %d cards remaining" % state.hand_counts[1 if shown_seat == 1 else 0], 16)
	_label("Table / last trick: " + ("No cards played yet" if state.table.is_empty() else "    |    ".join(state.table)))
	var cards := HFlowContainer.new()
	cards.add_theme_constant_override("h_separation", 16)
	column.add_child(cards)
	for index in state.hand.size():
		var card: Dictionary = state.hand[index]
		var button := _card_button(card.rank, card.label, _act.bind("play_card", index), cards)
		button.disabled = not state.actions.has("play_card")
	var controls := HFlowContainer.new()
	controls.add_theme_constant_override("h_separation", 12)
	controls.add_theme_constant_override("v_separation", 10)
	column.add_child(controls)
	for action in state.actions:
		if action != "play_card":
			_button(ACTION_LABELS[action], _act.bind(action, -1), controls)
	if not online:
		_button("Hide hand / pass computer", _hide)
	_label("Strength: 9 < 10 < V < D < R < A < 8 < 7  •  Suits do not break ties", 16)
	_history()

func _reveal() -> void:
	shown_seat = state.active_seat
	_refresh()

func _hide() -> void:
	shown_seat = 0
	_refresh()

func _act(action: String, index: int) -> void:
	if busy:
		return
	busy = true
	# Deferred delivery ensures the rules coroutine is waiting before an action.
	_deliver.call_deferred(shown_seat, action, index, int(state.revision))

func _deliver(id: int, action: String, index: int, revision: int) -> void:
	if page != "game":
		return
	session.submit(id, action, index, revision)
	_refresh()

func _history() -> void:
	_label("MATCH HISTORY", 18)
	var entries: Array = state.history
	var latest := entries.slice(maxi(0, entries.size() - 8))
	_label("\n".join(latest) if not latest.is_empty() else "Your match begins here.", 16)


func _apply_theme() -> void:
	theme.set_color("font_color", "Label", CREAM)
	for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = SAGE
		if state_name == "hover":
			style.bg_color = SAGE.lightened(0.12)
		elif state_name == "pressed":
			style.bg_color = BROWN
		elif state_name == "disabled":
			style.bg_color = Color("353b30")
		style.set_corner_radius_all(14)
		style.set_border_width_all(2)
		style.border_color = CREAM if state_name == "focus" else CHARCOAL
		if state_name == "focus":
			style.bg_color = Color.TRANSPARENT
		style.content_margin_left = 20
		style.content_margin_right = 20
		style.content_margin_top = 12
		style.content_margin_bottom = 12
		theme.set_stylebox(state_name, "Button", style)
	for property in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color"]:
		theme.set_color(property, "Button", CREAM)

func _rules() -> void:
	page = "rules"
	_clear()
	_label("Game Rules", 44)
	_label("The rules used in this version of Le Truc", 20)
	for section in [
		["01  •  The goal", "Two players compete to reach 12 points. Each round starts at a stake of 1 point. A round contains up to three tricks; a trick is one card played by each player."],
		["02  •  Cards & dealing", "Each player receives three cards. The first dealer is random; dealing alternates after every round. The non-dealer leads the first trick. Before play, the non-dealer may request one redeal; both hands are replaced only if the dealer agrees."],
		["03  •  Card strength", "Weakest → strongest: 9 < 10 < V < D < R < A < 8 < 7.\nV = Jack, D = Queen, R = King. Suits do not affect strength. Equal ranks tie. Artwork is numbered 1–8 in this strength order; the caption identifies the original rank and suit."],
		["04  •  Winning tricks & rounds", "The higher card wins the trick and its player leads next. After a tied trick, the same player leads. Win two tricks to win the round. If neither player wins two, the player who won the first non-tied trick wins the round. Three tied tricks award no points."],
		["05  •  Raising the stakes", "Before each trick, players may continue without raising, raise by 2, or offer mon reste. A raised stake must be accepted. The responder may accept, re-raise by 2 when allowed, or concede. Re-raises alternate between players and are capped at the 12-point match stake."],
		["06  •  Mon reste & conceding", "Mon reste makes the round worth the whole match: 12 points in this implementation. It may only be accepted or conceded, never re-raised. Conceding awards the opponent the previously agreed stake, not an unaccepted raise. The local interface offers Concede round on your action turns."],
		["07  •  Sharing one computer", "Choose Local Play. Pass the computer whenever the hand is hidden, then select Reveal my hand. Card buttons become playable when it is time to play a card. The first player to reach 12 points wins; Play again starts a fresh match."]
	]:
		_label(section[0], 25)
		_label(section[1])
	_button("Try the tutorial", _tutorial_start)
	_button("Back to main menu", _menu)

func _tutorial_start() -> void:
	page = "tutorial"
	tutorial_step = 0
	tutorial_feedback = ""
	_tutorial_render()

func _tutorial_render() -> void:
	_clear()
	_label("Practice Round", 44)
	_label("Guided practice  •  %d / 5  •  Your opponent is the coach" % (tutorial_step + 1), 18)
	_label("A scripted teaching round. Your real match scores are unaffected.", 16)
	match tutorial_step:
		0:
			_label("1. Meet your hand", 28)
			_label("You have 7 Hearts, 8 Clubs, and 9 Diamonds. The coach is the non-dealer and keeps their hand. You are the dealer. Select Keep these cards to continue the lesson.")
			_practice_cards(["7 Hearts", "8 Clubs", "9 Diamonds"], false)
			_button("Keep these cards", _tutorial_advance)
		1:
			_label("2. Raise the stake", 28)
			_label("The stake is 1 point. The coach passes their chance to raise. With two strong cards, try raising by 2. The coach will accept, making this round worth 3 points.")
			_button("Raise by 2", _tutorial_advance)
		2:
			_label("3. Beat the ace", 28)
			_label("The coach accepted: stake 3. They lead with A Spades. Click 7 Hearts to win this trick. In Le Truc, both 7 and 8 outrank an ace; save your 8 for the next trick.")
			_practice_cards(["7 Hearts", "8 Clubs", "9 Diamonds"], true)
		3:
			_label("4. Lead the next trick", 28)
			_label("Your 7 beat the coach's ace, so you lead now. Both players keep the stake at 3. Play 8 Clubs; the coach will respond with R Hearts (a king).")
			_practice_cards(["8 Clubs", "9 Diamonds"], true)
		4:
			_label("5. You won the round!", 32)
			_label("Trick 1: your 7 beat A.\nTrick 2: your 8 beat R.\nYou won two tricks, so the third card was not needed.")
			_label("You  3  ·  Coach  0", 32)
			_label("The accepted raise made this round worth 3 points. A real match continues with a new deal until someone reaches 12. You are ready to play!")
			_button("Start Local Play", _start)
			_button("Practice again", _tutorial_start)
	if not tutorial_feedback.is_empty():
		_label(tutorial_feedback, 20)
	_label("Strength: 9 < 10 < V < D < R < A < 8 < 7", 18)
	_button("Back to main menu", _menu)

func _practice_cards(cards: Array, clickable: bool) -> void:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 16)
	column.add_child(row)
	for card in cards:
		var rank := ["9", "10", "V", "D", "R", "A", "8", "7"].find(card.get_slice(" ", 0))
		var button := _card_button(rank, card, _tutorial_card.bind(card), row)
		button.disabled = not clickable

func _tutorial_card(card: String) -> void:
	var expected := "7 Hearts" if tutorial_step == 2 else "8 Clubs"
	if tutorial_step not in [2, 3]:
		return
	if card != expected:
		tutorial_feedback = "The 8 also beats the ace, but try the 7 first for this lesson." if card == "8 Clubs" else "The 9 is the weakest card. Try the highlighted instruction above; 7 and 8 are your strongest cards."
		_tutorial_render()
		return
	_tutorial_advance()

func _tutorial_advance() -> void:
	tutorial_step = mini(tutorial_step + 1, 4)
	tutorial_feedback = ""
	_tutorial_render()


func _game_header() -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	column.add_child(header)
	var title := _label("Le Truc", 36)
	title.reparent(header)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var home := Button.new()
	home.name = "HomeButton"
	home.custom_minimum_size = Vector2(52, 52)
	home.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	home.tooltip_text = "Return to main menu"
	home.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var icon_image := Image.new()
	icon_image.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M3 10.5 12 3l9 7.5M5.5 9v12h5v-7h3v7h5V9" fill="none" stroke="#f4eddc" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>')
	home.icon = ImageTexture.create_from_image(icon_image)
	for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := theme.get_stylebox(state_name, "Button").duplicate() as StyleBoxFlat
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 8
		style.content_margin_bottom = 8
		home.add_theme_stylebox_override(state_name, style)
	home.pressed.connect(_menu)
	header.add_child(home)
