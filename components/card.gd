extends Button

class_name Card

const ARTWORK: Array[Texture2D] = [
	preload("res://cards/card-1.png"),
	preload("res://cards/card-2.png"),
	preload("res://cards/card-3.png"),
	preload("res://cards/card-4.png"),
	preload("res://cards/card-5.png"),
	preload("res://cards/card-6.png"),
	preload("res://cards/card-7.png"),
	preload("res://cards/card-8.png"),
	preload("res://cards/card-9.png"),
]

@export var data: CardData:
	set(value):
		data = value
		if data != null:
			icon = ARTWORK[data.rank - CardData.MIN_RANK]
			tooltip_text = "Rank %d" % data.rank
			accessibility_name = tooltip_text

func _ready() -> void:
	custom_minimum_size = Vector2(150, 150)
	expand_icon = true
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color.WHITE
		style.set_content_margin_all(4)
		style.set_border_width_all(3)
		style.border_color = Color("302e27")
		if state_name in ["hover", "focus"]:
			style.border_color = Color("dfb34f")
		elif state_name == "pressed":
			style.border_color = Color("5f725f")
		if state_name == "focus":
			style.draw_center = false
		add_theme_stylebox_override(state_name, style)
	for color_name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_disabled_color", "icon_focus_color"]:
		add_theme_color_override(color_name, Color.WHITE)
	if data == null:
		data = CardData.new()
