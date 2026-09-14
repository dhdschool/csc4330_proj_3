extends Node2D

class_name Player

## Player state for Le Truc. All game flow lives in Game: a driver (human UI
## or AI) reads this state and calls Game's action methods on the player's
## behalf whenever Game.awaiting_action fires.

var points: int = 0
var hand: Array[CardData] = []
