extends Node
## Game-agnostic A2G protocol 0.1 client (autoload "A2G"). Spec: https://agent2game.org
##
## The game registers one adapter per entity type and calls track() and execute() from its entities.
## Adapter methods: observe(node) -> Dictionary, legal_actions(node) -> Array, execute(node, action, delta) -> bool
## (false = the action was blocked and the adapter did something safe instead).
## Types with decision slots (manifest "decisions"): legal_actions returns {slot: Array} for the slots to ask, and
## execute receives {slot: action} for the slots A2G decided; the adapter runs the native AI for every other slot.
## Optional adapter methods:
##   state(node) -> String            actual executed state, for telemetry
##   position(node) -> Vector2/3      lets the service compute nearby entities and group members
##   trigger(node) -> String          name of a manifest event that just happened ("" if none); asks for a decision now
##   interval_ms(node) -> int         refresh interval without events (default: manifest refresh_ms, then 3000)
##   release(node)                    native game AI takes control back
## A type whose legal_actions are always empty is observe-only: reported in telemetry (e.g. the player), never decided.
## world_provider returns the shared world state; scope_provider returns {"scope": name, "state": {...}} for the
## active scope (or {}). update_context() adds, replaces or removes scopes and profiles during the session.
## sample (optional) draws each AI action from the provider's probabilities, e.g. A2G.sample = A2G.sampler(game_rng),
## so A2G decisions vary like native AI and seeded replays stay identical. It runs on a decision's first execute().

const PROTOCOL = "0.1"
const GROUP = "a2g"
const PROTOCOL_MAX_BATCH = 16

## Project Settings read at startup (Project → Project Settings → a2g). The values here are the defaults.
const SETTINGS = {
	"a2g/service/url": "http://127.0.0.1:8787",
	"a2g/manifest_path": "res://a2g_manifest.json",
	"a2g/decisions/max_batch": 16,
	"a2g/decisions/max_inflight": 2,
	"a2g/decisions/batch_interval": 0.25,
	"a2g/decisions/default_interval_ms": 3000,
	"a2g/decisions/min_interval_ms": 500,
}

## Parse a JSON body without engine error output: error pages, empty bodies and HTML from proxies are
## expected while a service is down, and must not flood the game's log. Returns null when it is not JSON.
static func parse_json(text: String):
	if text.strip_edges() == "":
		return null
	var json = JSON.new()
	return json.data if json.parse(text) == OK else null

static func setting(name: String):
	return ProjectSettings.get_setting(name, SETTINGS[name])

var base_url: String = str(setting("a2g/service/url")).trim_suffix("/")
var manifest_path: String = setting("a2g/manifest_path")
var max_batch: int = clampi(int(setting("a2g/decisions/max_batch")), 1, PROTOCOL_MAX_BATCH)
var max_inflight: int = maxi(1, int(setting("a2g/decisions/max_inflight")))
var batch_interval: float = float(setting("a2g/decisions/batch_interval"))
var default_interval_ms: int = int(setting("a2g/decisions/default_interval_ms"))
var min_interval_ms: int = int(setting("a2g/decisions/min_interval_ms"))

var adapters: Dictionary = {}
var sample: Callable  # (probabilities: Dictionary, node: Node, slot: String) -> String
var world_provider: Callable
var scope_provider: Callable
var manifest: Dictionary = {}
var manifest_hash = ""
var context_updates = {"scopes": {}, "profiles": {}}  # replayed after every new session
var confirmed_scopes = {}  # context scopes the service has accepted in this session
var ai_enabled = false
var epoch = 0
var client_id = str(OS.get_process_id()) + "-" + str(Time.get_ticks_usec()) + "-" + str(randi())
var service_status = "checking"
var session_ready = false
var forbidden = false          # 403: stop asking until restart
var backoff_until = 0          # 429: no decide requests before this time (ms)
var last_ai_reply_ms = -1
var last_error = ""
var inflight = 0
var batch_elapsed = 0.0
var last_session_attempt = -10000
var last_health_check = -10000
var health_busy = false
var telemetry_busy = false
var last_population = -1

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	var text = FileAccess.get_file_as_string(manifest_path)
	var parsed = JSON.parse_string(text) if text != "" else null
	if parsed is Dictionary:
		manifest = parsed
	else:
		last_error = "Missing or invalid " + manifest_path
	var timer = Timer.new()
	timer.wait_time = 1.0
	timer.timeout.connect(_send_telemetry)
	add_child(timer)
	timer.start()
	check_service()
	if "--a2g-ai" in OS.get_cmdline_user_args():
		set_ai_enabled(true)

# --- Registration -------------------------------------------------------------

func register_adapter(type: String, adapter: Object):
	adapters[type] = adapter

## options: {"profile": "name", "parent": node_or_id}
func track(node: Node, type: String, options: Dictionary = {}):
	node.set_meta("a2g_type", type)
	if options.has("profile"):
		node.set_meta("a2g_profile", options.profile)
	if options.has("parent"):
		set_parent(node, options.parent)
	node.add_to_group(GROUP)

## Link an entity to its group (squad, faction, director or a leader); null unlinks.
func set_parent(node: Node, parent):
	if parent == null:
		node.remove_meta("a2g_parent")
	else:
		node.set_meta("a2g_parent", entity_id(parent) if parent is Node else str(parent))

func entity_id(node: Node) -> String:
	return str(node.get_instance_id())

func entities() -> Array:
	var scene = get_tree().current_scene
	var result = []
	for node in get_tree().get_nodes_in_group(GROUP):
		if is_instance_valid(node) and not node.is_queued_for_deletion() and scene != null and scene.is_ancestor_of(node) and adapters.has(node.get_meta("a2g_type", "")):
			result.append(node)
	return result

func adapter_of(node: Node) -> Object:
	return adapters.get(node.get_meta("a2g_type", ""))

func type_spec(node: Node) -> Dictionary:
	return manifest.get("entity_types", {}).get(node.get_meta("a2g_type", ""), {})

func pending_count() -> int:
	var count = 0
	for node in entities():
		if node.get_meta("a2g_pending", false):
			count += 1
	return count

func position_of(node: Node, adapter: Object):
	if not adapter.has_method("position"):
		return null
	var value = adapter.position(node)
	return [snappedf(value.x, 0.1), snappedf(value.y, 0.1)] if value is Vector2 else ([snappedf(value.x, 0.1), snappedf(value.y, 0.1), snappedf(value.z, 0.1)] if value is Vector3 else null)

func world() -> Dictionary:
	return world_provider.call() if world_provider.is_valid() else {}

func scope() -> Dictionary:
	var value = scope_provider.call() if scope_provider.is_valid() else {}
	return value if value is Dictionary and str(value.get("scope", "")) != "" else {}

# --- HTTP ---------------------------------------------------------------------

func _request(method: int, path: String, body, timeout: float, callback: Callable):
	var request = HTTPRequest.new()
	request.timeout = timeout
	request.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(request)
	request.request_completed.connect(func(result, code, headers, response):
		request.queue_free()
		var data = parse_json(response.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS else null
		code = code if result == HTTPRequest.RESULT_SUCCESS else 0
		_handle_status(code, data, headers)
		callback.call(code, data))
	var payload = JSON.stringify(body) if body != null else ""
	if request.request(base_url + path, ["Content-Type: application/json"], method, payload) != OK:
		request.queue_free()
		callback.call(0, null)

## Protocol error handling: every non-200 means "no decision" (native AI) plus one reaction.
func _handle_status(code: int, data, headers: PackedStringArray):
	var message = str(data.get("error", "")) if data is Dictionary else ""
	match code:
		401, 409:
			session_ready = false  # reopen the session (local profile has no credential to refresh)
		403:
			forbidden = true
			last_error = "Forbidden by the service: " + message
		429:
			var wait_s = 5
			for header in headers:
				if header.to_lower().begins_with("retry-after:"):
					wait_s = maxi(1, int(header.split(":", true, 1)[1].strip_edges()))
			backoff_until = Time.get_ticks_msec() + wait_s * 1000
			last_error = "Rate limited; retrying in %d s" % wait_s

## A sampler driven by the game's own RandomNumberGenerator (seeded for replays).
static func sampler(rng: RandomNumberGenerator) -> Callable:
	return func(probabilities: Dictionary, _node, _slot) -> String:
		var total = 0.0
		for action in probabilities:
			total += float(probabilities[action])
		var roll = rng.randf() * total
		for action in probabilities:
			roll -= float(probabilities[action])
			if roll < 0:
				return action
		return probabilities.keys()[-1]

func check_service():
	if health_busy or Time.get_ticks_msec() - last_health_check < 5000:
		return
	health_busy = true
	last_health_check = Time.get_ticks_msec()
	_request(HTTPClient.METHOD_GET, "/health", null, 1.5, func(code, data):
		health_busy = false
		if code == 200 and data is Dictionary and data.get("service") == "a2g":
			service_status = "ready (key configured)" if data.get("key_configured") == true else "missing API key"
		else:
			service_status = "offline"
			session_ready = false)

func _start_session():
	if manifest.is_empty() or forbidden or Time.get_ticks_msec() - last_session_attempt < 3000:
		return
	last_session_attempt = Time.get_ticks_msec()
	var body = {"a2g": PROTOCOL, "client_id": client_id, "game": str(ProjectSettings.get_setting("application/config/name", "Godot game")),
		"engine": "Godot " + Engine.get_version_info().string, "manifest": manifest}
	_request(HTTPClient.METHOD_POST, "/v1/session", body, 2.0, func(code, data):
		if code != 200:
			last_error = "Session rejected: " + (str(data.get("error", "")) if data is Dictionary else "service unavailable")
			return
		manifest_hash = str(data.get("manifest_hash", ""))
		confirmed_scopes.clear()
		if context_updates.scopes.is_empty() and context_updates.profiles.is_empty():
			session_ready = true
			return
		# A new session forgets earlier /v1/context updates: replay them before asking for decisions.
		_send_context(context_updates, func(ok): session_ready = ok))

## Add/replace (dictionary value) or remove (null) scopes and profiles for this session.
func update_context(scopes: Dictionary = {}, profiles: Dictionary = {}):
	for name in scopes:
		context_updates.scopes[name] = scopes[name]
	for name in profiles:
		context_updates.profiles[name] = profiles[name]
	if session_ready:
		_send_context({"scopes": scopes, "profiles": profiles}, func(_ok): pass)

func _send_context(update: Dictionary, done: Callable):
	var body = {"client_id": client_id}
	for part in ["scopes", "profiles"]:
		if not update[part].is_empty():
			body[part] = update[part]
	_request(HTTPClient.METHOD_POST, "/v1/context", body, 2.0, func(code, data):
		if code == 200:
			for name in update.scopes:
				if update.scopes[name] == null:
					confirmed_scopes.erase(name)
				else:
					confirmed_scopes[name] = true
		else:
			last_error = "Context update rejected: " + (str(data.get("error", "")) if data is Dictionary else "service unavailable")
		done.call(code == 200))

## True when decide requests may name this scope: declared in the manifest or accepted through update_context().
func scope_ready(name: String) -> bool:
	return (manifest.get("scopes", {}).has(name) and not context_updates.scopes.has(name)) or confirmed_scopes.has(name)

# --- Mode ---------------------------------------------------------------------

func set_ai_enabled(on: bool):
	ai_enabled = on
	epoch += 1
	for node in get_tree().get_nodes_in_group(GROUP):
		if not is_instance_valid(node):
			continue
		node.set_meta("a2g_decision", {})
		node.set_meta("a2g_pending", false)
		node.set_meta("a2g_next", 0)
		var adapter = adapter_of(node)
		if not on and adapter != null and adapter.has_method("release"):
			adapter.release(node)

# --- Decisions ----------------------------------------------------------------

func _physics_process(delta):
	# This node keeps processing while paused for telemetry; a paused game must not spend provider calls.
	if not ai_enabled or forbidden or get_tree().paused:
		return
	if not session_ready:
		_start_session()
		return
	batch_elapsed += delta
	if batch_elapsed < batch_interval:
		return
	batch_elapsed = 0.0
	var now = Time.get_ticks_msec()
	var current = entities()
	# Someone died or appeared: the situation changed for everyone, so re-decide soon (rate-limited per entity).
	var population_changed = last_population >= 0 and current.size() != last_population
	last_population = current.size()
	for node in current:
		var adapter = adapter_of(node)
		var soon = population_changed
		if adapter.has_method("trigger"):
			var event = str(adapter.trigger(node))
			if event != "" and type_spec(node).get("events", {}).has(event):
				node.set_meta("a2g_trigger", event)  # the latest event wins until it is sent
				soon = true
		if soon:
			node.set_meta("a2g_next", mini(node.get_meta("a2g_next", 0), node.get_meta("a2g_last_request", 0) + min_interval_ms))
	if inflight >= max_inflight or now < backoff_until:
		return
	var batch = []
	var nodes = []
	for node in current:
		if batch.size() >= max_batch or node.get_meta("a2g_pending", false) or now < node.get_meta("a2g_next", 0):
			continue
		var request = _decide_entity(node)
		if request.is_empty():
			continue
		batch.append(request)
		nodes.append(node)
	if batch.is_empty():
		return
	for node in nodes:
		node.set_meta("a2g_pending", true)
		node.set_meta("a2g_last_request", now)
		node.remove_meta("a2g_trigger")
	inflight += 1
	var request_epoch = epoch
	var body = {"client_id": client_id, "epoch": request_epoch, "world": world(), "entities": batch}
	var active = scope()
	if not active.is_empty():
		body["scope"] = active.scope
		if not active.get("state", {}).is_empty():
			body["scope_state"] = active.state
	_request(HTTPClient.METHOD_POST, "/v1/decide", body, 4.0, func(code, data): _on_decisions(code, data, batch, request_epoch, now))

## One decide entity, or {} when it should not be asked (observe-only or nothing legal).
func _decide_entity(node: Node) -> Dictionary:
	var adapter = adapter_of(node)
	var spec = type_spec(node)
	var raw = adapter.legal_actions(node)
	var legal
	if spec.has("decisions"):
		legal = {}
		if raw is Dictionary:
			for slot in raw:
				var slot_actions = spec.decisions.get(slot, {}).get("actions", {})
				var allowed = Array(raw[slot]).filter(func(action): return slot_actions.has(action))
				if not allowed.is_empty():
					legal[slot] = allowed
	else:
		var actions = spec.get("actions", {})
		legal = (raw if raw is Array else []).filter(func(action): return actions.has(action))
	if legal.is_empty():
		return {}
	var request = {"id": entity_id(node), "type": node.get_meta("a2g_type"), "observation": adapter.observe(node), "legal_actions": legal}
	var where = position_of(node, adapter)
	if where != null:
		request["position"] = where
	for key in ["profile", "parent", "trigger"]:
		if node.has_meta("a2g_" + key):
			request[key] = node.get_meta("a2g_" + key)
	return request

func _on_decisions(code: int, data, batch: Array, request_epoch: int, started: int):
	inflight = maxi(0, inflight - 1)
	var replies = {}
	if code == 200 and data is Dictionary and int(data.get("epoch", -1)) == request_epoch and data.get("decisions") is Array:
		for decision in data.decisions:
			if decision is Dictionary:
				replies[str(decision.get("id"))] = decision
	var error = ""
	if replies.is_empty():
		error = str(data.get("error")) if data is Dictionary and data.has("error") else "Local service unavailable or invalid reply"
	var now = Time.get_ticks_msec()
	for request in batch:
		var node = instance_from_id(int(request.id))
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		node.set_meta("a2g_pending", false)
		if not ai_enabled or request_epoch != epoch:
			continue
		_finish(node)
		var reply = replies.get(request.id, {})
		var decision = {"source": "FALLBACK", "code": str(reply.get("code", "unavailable")), "reason": str(reply.get("reason", error if error != "" else "Missing decision")), "ttl_ms": 0}
		var legal = request.legal_actions
		var slots = {}  # slots whose action was offered; a missing or invalid slot stays with the native AI
		if legal is Dictionary and reply.get("slots") is Dictionary:
			for slot in reply.slots:
				var result = reply.slots[slot]
				if legal.has(slot) and result is Dictionary and (not result.has("action") or result.action in legal[slot]):
					slots[slot] = result
		var valid = reply.get("action") in legal if legal is Array else slots.values().any(func(result): return result.has("action"))
		if reply.get("source") == "AI" and valid and reply.get("decision_id") is String:
			# duplicate(): games often mutate one world or observation dictionary in place
			decision = {"source": "AI", "label": str(reply.get("label", "")), "confidence": reply.get("confidence"),
				"decision_id": reply.decision_id, "cached": reply.get("cached", false) == true, "trigger": request.get("trigger", ""),
				"ttl_ms": int(reply.get("ttl_ms", 12000)), "start_observation": request.observation.duplicate(true), "start_world": world().duplicate(true),
				"legal": legal}
			if legal is Array:
				decision["action"] = reply.action
				decision["probabilities"] = _clean_probabilities(reply.get("probabilities"), legal)
			else:
				for slot in slots:
					if slots[slot].has("probabilities"):
						slots[slot]["probabilities"] = _clean_probabilities(slots[slot].probabilities, legal[slot])
				decision["slots"] = slots
			last_ai_reply_ms = now
			last_error = ""
		else:
			last_error = decision.reason
		decision["latency_ms"] = now - started
		decision["received_at"] = now
		node.set_meta("a2g_decision", decision)
		var adapter = adapter_of(node)
		var interval = adapter.interval_ms(node) if adapter.has_method("interval_ms") else int(type_spec(node).get("refresh_ms", default_interval_ms))
		node.set_meta("a2g_next", now + interval)

func is_fresh(decision: Dictionary) -> bool:
	return decision.get("source") == "AI" and Time.get_ticks_msec() - decision.get("received_at", 0) <= decision.get("ttl_ms", 0)

## Call from the entity's physics step. Returns true when A2G controls the node this frame;
## false means the game must run its native AI.
func execute(node: Node, delta: float) -> bool:
	var adapter = adapter_of(node)
	if not ai_enabled or adapter == null:
		return false
	var decision: Dictionary = node.get_meta("a2g_decision", {})
	if not is_fresh(decision):
		_finish(node, true)
		if adapter.has_method("release"):
			adapter.release(node)
		return false
	if not decision.get("ran", false):
		_choose(node, decision)
	decision["ran"] = true
	if not adapter.execute(node, decision.actions if decision.has("slots") else decision.action, delta):
		decision["blocked"] = true
	return true

## Fix the executed action(s) once: sampled from the probabilities when sample is set, else the service's choice.
## Only actions this request offered can be picked: the service's probabilities are never trusted to name a legal action.
func _choose(node: Node, decision: Dictionary):
	var pick = func(result: Dictionary, legal: Array, slot: String) -> String:
		var options = {}
		var probabilities = result.get("probabilities", {})
		if probabilities is Dictionary:
			for action in probabilities:
				var p = probabilities[action]
				if action in legal and (p is float or p is int) and p > 0:
					options[action] = p
		if not sample.is_valid() or options.is_empty():
			return result.action
		var chosen = sample.call(options, node, slot)
		return chosen if options.has(chosen) else result.action
	if decision.has("slots"):
		var actions = {}
		for slot in decision.slots:
			if decision.slots[slot].has("action"):
				actions[slot] = pick.call(decision.slots[slot], decision.legal.get(slot, []), slot)
		decision["actions"] = actions
	else:
		decision["action"] = pick.call(decision, decision.legal, "")

## Report the outcome of the node's current AI decision once: numeric deltas of its observation and the world.
## expiring = its TTL ran out with no new decision. A decision that ran and is replaced counts as executed.
func _finish(node: Node, expiring := false):
	var decision: Dictionary = node.get_meta("a2g_decision", {})
	if decision.get("source") != "AI" or decision.get("reported", false):
		return
	decision["reported"] = true
	var adapter = adapter_of(node)
	var status = "blocked" if decision.get("blocked", false) else ("executed" if not expiring and (decision.get("ran", false) or is_fresh(decision)) else "expired")
	var outcome = {}
	_add_deltas(outcome, "", decision.start_observation, adapter.observe(node))
	_add_deltas(outcome, "world_", decision.start_world, world())
	outcome["seconds"] = snappedf((Time.get_ticks_msec() - decision.received_at) / 1000.0, 0.1)
	var body = {"client_id": client_id, "entity_id": entity_id(node), "decision_id": decision.decision_id, "status": status, "outcome": outcome}
	if decision.has("slots"):
		body["actions"] = decision.get("actions", _slot_actions(decision))
	else:
		body["action"] = decision.action
	_request(HTTPClient.METHOD_POST, "/v1/report", body, 2.0, func(_code, _data): pass)

## Probabilities as the game may use them: only for offered actions and within [0, 1].
func _clean_probabilities(probabilities, legal: Array) -> Dictionary:
	var clean = {}
	if probabilities is Dictionary:
		for action in probabilities:
			var p = probabilities[action]
			if action in legal and (p is float or p is int) and p >= 0 and p <= 1:
				clean[action] = p
	return clean

func _slot_actions(decision: Dictionary) -> Dictionary:
	var actions = {}
	for slot in decision.get("slots", {}):
		if decision.slots[slot].has("action"):
			actions[slot] = decision.slots[slot].action
	return actions

func _add_deltas(outcome: Dictionary, prefix: String, before: Dictionary, after: Dictionary):
	for name in before:
		if outcome.size() >= 11:  # reports carry at most 12 values, one is "seconds"
			return
		if (before[name] is float or before[name] is int) and (after.get(name) is float or after.get(name) is int):
			outcome[prefix + name + "_delta"] = snappedf(after[name] - before[name], 0.001)

# --- Telemetry ----------------------------------------------------------------

func _scalars(values: Dictionary) -> Dictionary:
	var result = {}
	for key in values:
		if values[key] is bool or values[key] is int or values[key] is float or values[key] is String:
			result[key] = values[key]
	return result

func _send_telemetry():
	check_service()
	if telemetry_busy:
		return
	var current_scene = get_tree().current_scene
	var items = []
	var now = Time.get_ticks_msec()
	for node in entities().slice(0, 128):
		var adapter = adapter_of(node)
		var decision: Dictionary = node.get_meta("a2g_decision", {})
		var compact = {}
		for key in ["source", "action", "label", "confidence", "code", "reason", "latency_ms", "cached", "trigger", "decision_id"]:
			if decision.get(key) != null and str(decision.get(key)) != "":
				compact[key] = decision[key]
		if decision.has("slots"):
			var executed = decision.get("actions", _slot_actions(decision))
			var summary = ", ".join(executed.keys().map(func(slot): return "%s=%s" % [slot, executed[slot]]))
			compact["action"] = summary if summary.length() <= 80 else summary.left(79) + "…"  # telemetry strings are at most 80 chars
			compact["slots"] = executed
			compact.erase("label")
		if decision.has("received_at"):
			compact["age_ms"] = now - decision.received_at
		var item = {"id": entity_id(node), "type": node.get_meta("a2g_type"), "name": str(node.name),
			"state": adapter.state(node) if adapter.has_method("state") else "", "pending": node.get_meta("a2g_pending", false),
			"fields": _scalars(adapter.observe(node)), "decision": compact if ai_enabled else {}}
		var where = position_of(node, adapter)
		if where != null:
			item["position"] = where
		for key in ["parent", "profile"]:
			if node.has_meta("a2g_" + key):
				item[key] = node.get_meta("a2g_" + key)
		items.append(item)
	var body = {"client_id": client_id, "mode": "ai" if ai_enabled else "native", "paused": get_tree().paused,
		"scene": str(current_scene.name) if current_scene else "Loading", "world": _scalars(world()), "entities": items, "last_error": last_error}
	var active = scope()
	if not active.is_empty():
		body["scope"] = active.scope
	telemetry_busy = true
	_request(HTTPClient.METHOD_POST, "/v1/telemetry", body, 2.0, func(code, _data):
		telemetry_busy = false
		if code != 200:
			service_status = "offline"
		if not session_ready and service_status != "offline":
			_start_session())
