# A2G for Godot

Client for the [Agent2Game (A2G) protocol](https://agent2game.org) 0.1. Your characters ask an AI model which of their actions to take; your code executes the choice, and your native AI takes over whenever there is no valid decision.

1. Enable **Project → Project Settings → Plugins → A2G**. This adds the `A2G` autoload.
2. Put your manifest at `res://a2g_manifest.json`.
3. Register an adapter and hook your entities:

```gdscript
A2G.register_adapter("guard", adapter)   # observe(), legal_actions(), execute()
A2G.track(self, "guard")                 # in the entity's _ready()
if A2G.execute(self, delta):             # in _physics_process(); false = run your native AI
	return
```

Documentation: https://agent2game.org/implementations/godot-sdk/ · Source: https://github.com/agent2game/a2g-sdk-godot

Apache License 2.0, see `LICENSE`.
