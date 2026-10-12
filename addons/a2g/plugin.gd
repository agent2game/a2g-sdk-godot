@tool
extends EditorPlugin
## Enabling the plugin registers the "A2G" autoload; disabling it removes the autoload again.

const AUTOLOAD = "A2G"

func _enable_plugin():
	add_autoload_singleton(AUTOLOAD, "res://addons/a2g/a2g_client.gd")

func _disable_plugin():
	remove_autoload_singleton(AUTOLOAD)
