# A2G SDK for Godot

The Godot 4 client for the [Agent2Game (A2G) protocol](https://agent2game.org). Your game's characters ask an AI model which of their actions to take. Your code executes the choice, and your own AI takes over whenever there is no valid decision: no service, a timeout, a refusal or an expired decision.

> **Status:** `0.2.0`, draft, for protocol 0.1. See the [implementation status](https://agent2game.org/implementations/service/#implementation-status).

## Install

Copy `addons/a2g/` into your project and enable **Project → Project Settings → Plugins → A2G**. Enabling the plugin adds the `A2G` autoload.

| SDK | Protocol | Godot |
| --- | --- | --- |
| 0.2.0 | 0.1 | 4.7 |

## Quick start

1. Describe your game in `res://a2g_manifest.json` (see [Manifest](https://agent2game.org/specification/manifest/)).
2. Write an adapter: what an entity observes, which actions are legal now, how to execute one.
3. Track your entities and ask A2G before your native AI:

```gdscript
func _ready():
	A2G.track(self, "guard")

func _physics_process(delta):
	if A2G.execute(self, delta):   # A2G controls this entity this frame
		return
	# your existing AI, unchanged
```

4. Run a decision service and switch AI mode on with `A2G.set_ai_enabled(true)` or the `--a2g-ai` command-line flag. AI mode is off by default.

When an entity makes several independent choices at once (how hard to work, whether to help, whether to ask for a raise), declare [decision slots](https://agent2game.org/specification/manifest/#decision-slots): `legal_actions` returns `{slot: [...]}` and `execute` receives `{slot: action}` for the slots A2G decided. To keep your game's odds and seeded replays, sample from the provider's probabilities with your own RNG:

```gdscript
A2G.sample = A2G.sampler(game_rng)   # a seeded RandomNumberGenerator
```

The [integration guide](https://agent2game.org/guides/integrate/) and the [SDK reference](https://agent2game.org/implementations/godot-sdk/) cover the adapter contract, events, scopes, profiles, groups, slots and sampling.

## Settings

Enabling the plugin adds these to **Project → Project Settings** under `a2g/`. Defaults apply when a setting is absent.

| Setting | Default | Meaning |
| --- | --- | --- |
| `a2g/service/url` | `http://127.0.0.1:8787` | Decision service base URL |
| `a2g/manifest_path` | `res://a2g_manifest.json` | Your manifest |
| `a2g/decisions/max_batch` | `16` | Entities per decide request (the protocol maximum is 16) |
| `a2g/decisions/max_inflight` | `2` | Decide requests in flight at once |
| `a2g/decisions/batch_interval` | `0.25` | Seconds between batch checks |
| `a2g/decisions/default_interval_ms` | `3000` | Refresh interval when neither the adapter nor the manifest sets one |
| `a2g/decisions/min_interval_ms` | `500` | Minimum time between two requests for one entity |

## In this repository

| Path | Contents |
| --- | --- |
| `addons/a2g/` | The SDK. The only folder you install |
| `demo/` | A minimal scene: three guards, a player (arrow keys), `A` toggles AI mode |
| `tests/` | Offline checks; no service or API key needed |
| `a2g_manifest.json` | The demo's manifest |

Open the repository in Godot 4.7 to run the demo. Run the tests with:

```sh
godot --headless --path . --script res://tests/test_client.gd
```

## Examples

- [`demo/`](demo): the smallest possible integration.
- [Lango](https://agent2game.org/examples/lango/): a full RPG with scopes, groups, events and a debug overlay.

## License

[Apache License 2.0](LICENSE). Keep [`NOTICE`](NOTICE) when you redistribute the SDK. The addon folder carries its own copy of the license.
