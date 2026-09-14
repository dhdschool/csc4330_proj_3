extends Resource

class_name CardData

enum Suit { HEARTS, DIAMONDS, SPADES, CLUBS }
enum Rank { NINE, TEN, VALET, DAME, ROI, ACE, EIGHT, SEVEN }

@export var suit: Suit = Suit.HEARTS
@export var rank: Rank = Rank.SEVEN

func _init(suit_value: Suit, rank_value: Rank) -> void:
	suit = suit_value
	rank = rank_value
