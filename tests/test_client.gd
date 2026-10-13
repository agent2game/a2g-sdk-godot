extends SceneTree
## Offline checks of the SDK with the demo scene: no service and no API key needed.
## Run: godot --headless --path . --script res://tests/test_client.gd

func _initialize():
	run.call_deferred()

var failures := 0

class WorkerAdapter:
	var last = null
	var drift = false
	func observe(_node) -> Dictionary:
		return {"stress": "high"} if drift else {"stress": 0.5}
	func legal_actions(_node):
		return {"effort": ["carry_on", "slack_off"]} if drift else {"effort": ["carry_on", "push_harder"], "help": []}
	func execute(_node, actions, _delta) -> bool:
		last = actions
		return true

func check(condition: bool, message: String):
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

## Feed a fake service reply through the SDK's own reply handler, as if /v1/decide had answered.
func decide(a2g, adapter, guard, action: String, ttl_ms: int):
	var request = {"id": a2g.entity_id(guard), "type": "guard", "observation": adapter.observe(guard), "legal_actions": adapter.legal_actions(guard)}
	var reply = {"a2g": "0.1", "epoch": a2g.epoch, "decisions": [{"id": request.id, "source": "AI", "action": action, "label": action,
		"confidence": 0.8, "ttl_ms": ttl_ms, "decision_id": "d_test"}]}
	a2g._on_decisions(200, reply, [request], a2g.epoch, Time.get_ticks_msec())

func run():
	var main = load("res://demo/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	await process_frame
	var a2g = root.get_node("A2G")
	check(a2g.parse_json("") == null and a2g.parse_json("<html>502</html>") == null, "non-JSON bodies parse to null")
	check(a2g.parse_json('{"ok": true}').ok == true, "JSON bodies parse")
	check(a2g.base_url == "http://127.0.0.1:8787" and a2g.max_batch == 16, "defaults apply without project settings")
	ProjectSettings.set_setting("a2g/service/url", "http://127.0.0.1:9000/")
	ProjectSettings.set_setting("a2g/decisions/max_batch", 40)
	var configured = load("res://addons/a2g/a2g_client.gd").new()
	check(configured.base_url == "http://127.0.0.1:9000", "service URL comes from project settings")
	check(configured.max_batch == 16, "max_batch never exceeds the protocol limit of 16")
	configured.free()
	ProjectSettings.set_setting("a2g/service/url", null)
	ProjectSettings.set_setting("a2g/decisions/max_batch", null)
	var guards = a2g.entities().filter(func(node): return node.get_meta("a2g_type") == "guard")
	check(guards.size() == 3, "three guards are tracked")
	check(not a2g.manifest.is_empty(), "manifest loaded from res://a2g_manifest.json")
	var guard = guards[0]
	main.player.position = guard.position + Vector2(50, 0)
	check(main.adapter.legal_actions(guard) == ["chase", "wait", "retreat"], "a visible player allows all actions")
	a2g.set_physics_process(false)
	check(not a2g.execute(guard, 0.1), "native AI runs while AI mode is off")
	a2g.set_ai_enabled(true)
	check(not a2g.execute(guard, 0.1), "native AI runs without a fresh decision")
	var before = guard.position
	decide(a2g, main.adapter, guard, "retreat", 8000)
	check(a2g.execute(guard, 0.5), "A2G controls the guard with a fresh decision")
	check(guard.position.distance_to(main.player.position) > before.distance_to(main.player.position), "retreat moves away from the player")
	decide(a2g, main.adapter, guard, "chase", 1000)
	guard.get_meta("a2g_decision").received_at -= 5000
	check(not a2g.execute(guard, 0.1), "an expired decision falls back to native AI")
	check(not a2g.execute(guard, 0.1), "it stays on native AI until a new decision arrives")
	# Decision slots: one choice per slot, empty slots are not asked, actions sampled with the game's RNG.
	a2g.manifest.entity_types["worker"] = {"fields": {"stress": "number"}, "decision_ttl_ms": 8000, "decisions": {
		"effort": {"actions": {"carry_on": "As usual", "push_harder": "More"}}, "help": {"actions": {"none": "Nothing", "help_colleague": "Help"}}}}
	var worker_adapter = WorkerAdapter.new()
	a2g.register_adapter("worker", worker_adapter)
	var worker = Node2D.new()
	main.add_child(worker)
	a2g.track(worker, "worker")
	var request = a2g._decide_entity(worker)
	check(request.legal_actions == {"effort": ["carry_on", "push_harder"]}, "slots without legal actions are not asked")
	var rng = RandomNumberGenerator.new()
	rng.seed = 7
	a2g.sample = a2g.sampler(rng)
	var reply = {"a2g": "0.1", "epoch": a2g.epoch, "decisions": [{"id": request.id, "source": "AI", "ttl_ms": 8000, "decision_id": "d_w",
		"slots": {"effort": {"action": "carry_on", "probabilities": {"carry_on": 0.0001, "push_harder": 0.9999}}, "help": {"action": "dance"}}}]}
	a2g._on_decisions(200, reply, [request], a2g.epoch, Time.get_ticks_msec())
	var decision = worker.get_meta("a2g_decision")
	check(not is_same(decision.start_observation, request.observation), "the start observation is a copy, not the game's dictionary")
	check(not decision.slots.has("help"), "a slot that was not asked or offered is dropped")
	check(a2g.execute(worker, 0.1), "A2G controls an entity with slot decisions")
	check(worker_adapter.last == {"effort": "push_harder"}, "the slot action is sampled from the probabilities")
	# Sampling never picks an action this request did not offer, whatever the probabilities say.
	var offered = {"id": request.id, "type": "worker", "observation": request.observation, "legal_actions": {"effort": ["carry_on"]}}
	var forged = {"a2g": "0.1", "epoch": a2g.epoch, "decisions": [{"id": request.id, "source": "AI", "ttl_ms": 8000, "decision_id": "d_w2",
		"slots": {"effort": {"action": "carry_on", "probabilities": {"carry_on": 0.01, "push_harder": 0.99}}}}]}
	a2g.sample = func(_probabilities, _node, _slot): return "push_harder"
	a2g._on_decisions(200, forged, [offered], a2g.epoch, Time.get_ticks_msec())
	a2g.execute(worker, 0.1)
	check(worker_adapter.last == {"effort": "carry_on"}, "sampling is limited to the actions the request offered")
	var exposed = worker.get_meta("a2g_decision").slots.effort.probabilities
	check(exposed == {"carry_on": 0.01}, "probabilities given to the game are limited to offered actions within [0, 1]")
	a2g.sample = Callable()
	# Manifest drift: an unknown action and a field of the wrong type are reported and never sent.
	worker_adapter.drift = true
	check(a2g.validate(worker) == ['worker.observation.stress is "high", not a valid number', 'worker.effort: action "slack_off" is not in the manifest'],
		"validate() names each drift problem")
	check(a2g._decide_entity(worker).is_empty(), "a mismatching entity is not sent")
	check(worker.get_meta("a2g_decision").code == "mismatch", "the entity stays native with code mismatch")
	check(a2g.field_problems({"hp": "number"}, {"hp": 1, "mana": 2}, "world") == ["world.mana is not declared in the manifest"], "undeclared fields are reported")
	worker_adapter.drift = false
	a2g.set_ai_enabled(false)
	if failures:
		quit(1)
		return
	print("PASS: A2G SDK offline checks")
	quit(0)
