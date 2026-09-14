extends Node2D

class_name Deck

var cards: Array[CardData]
var discards: Array[CardData] = []

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	cards = create_cards()
	cards.shuffle()
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func create_cards() -> Array[CardData]:
	var card_arr: Array[CardData] = []
	for suit in CardData.Suit.values():
		for rank in CardData.Rank.values():
			card_arr.append(CardData.new(suit, rank))
	return card_arr

func shuffle() -> void:
	cards += discards
	discards = []
	cards.shuffle()
	
func deal_one() -> CardData:
	if cards.is_empty():
		shuffle()
		
	var card: CardData = cards.pop_front()
	discards.push_front(card)
	return card
	
func deal(n: int = 3) -> Array[CardData]:
	var dealt_cards: Array[CardData] = []
	for i in range(n):
		dealt_cards.append(deal_one())
	return dealt_cards
