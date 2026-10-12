extends Node2D
## The player: arrow keys to move.

const SPEED = 140.0

func _process(delta):
	position += Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down") * SPEED * delta
	queue_redraw()

func _draw():
	draw_rect(Rect2(-6, -6, 12, 12), Color("4f7cff"))
