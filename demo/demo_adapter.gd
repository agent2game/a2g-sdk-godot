extends RefCounted
## The game-specific glue for the demo: what a guard observes, which actions are legal now, how to run them.

var player: Node2D

func observe(guard) -> Dictionary:
	return {
		"hp_fraction": guard.hp,
		"distance_to_player": snappedf(guard.position.distance_to(player.position), 0.1),
		"sees_player": sees_player(guard),
	}

func sees_player(guard) -> bool:
	return guard.position.distance_to(player.position) < 160

func legal_actions(guard) -> Array:
	return ["chase", "wait", "retreat"] if sees_player(guard) else ["wait"]

func execute(guard, action: String, delta: float) -> bool:
	guard.state = action
	var direction = guard.position.direction_to(player.position)
	if action == "chase":
		guard.position += direction * guard.SPEED * delta
	elif action == "retreat":
		guard.position -= direction * guard.SPEED * delta
	guard.queue_redraw()
	return true

func position(guard) -> Vector2:
	return guard.position

func state(guard) -> String:
	return guard.state.to_upper()

class PlayerAdapter:
	func observe(_player) -> Dictionary:
		return {"hp_fraction": 1.0}

	func legal_actions(_player) -> Array:
		return []

	func position(node) -> Vector2:
		return node.position
