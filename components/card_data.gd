extends Resource

class_name CardData

const MIN_RANK: int = 1
const MAX_RANK: int = 9

@export_range(1, 9) var rank: int = MIN_RANK:
	set(value):
		rank = clampi(value, MIN_RANK, MAX_RANK)

func _init(rank_value: int = MIN_RANK) -> void:
	rank = rank_value
