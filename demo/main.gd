extends Node2D
## Minimal A2G demo. Arrow keys move the player; guards run their native AI ("chase when close")
## unless A2G has a fresh decision for them. Press A to toggle AI mode (needs the decision service).

const Guard = preload("res://demo/guard.gd")
const Player = preload("res://demo/player.gd")

var adapter = preload("res://demo/demo_adapter.gd").new()
var player: Node2D

func _ready():
	player = Player.new()
	player.position = Vector2(320, 180)
	add_child(player)
	adapter.player = player
	A2G.world_provider = func(): return {"player_hp_fraction": 1.0}
	A2G.register_adapter("guard", adapter)
	A2G.register_adapter("player", adapter.PlayerAdapter.new())
	A2G.track(player, "player")
	for spot in [Vector2(80, 80), Vector2(560, 90), Vector2(320, 320)]:
		var guard = Guard.new()
		guard.position = spot
		guard.player = player
		add_child(guard)

func _unhandled_input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_A:
		A2G.set_ai_enabled(not A2G.ai_enabled)
