extends Node2D
## A guard with a native AI. A2G only adds decisions on top: execute() returns false whenever
## there is no fresh, valid decision, and the native rule below runs as before.

const SPEED = 60.0
var player: Node2D
var hp := 1.0
var state := "wait"

func _ready():
	A2G.track(self, "guard")

func _physics_process(delta):
	if A2G.execute(self, delta):
		return
	# Native AI: chase when the player is close, otherwise wait.
	state = "chase" if position.distance_to(player.position) < 120 else "wait"
	if state == "chase":
		position += position.direction_to(player.position) * SPEED * delta
	queue_redraw()

func _draw():
	draw_circle(Vector2.ZERO, 7, Color("f2c230") if state != "retreat" else Color("f2bf55"))
