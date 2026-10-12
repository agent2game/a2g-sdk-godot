@tool
extends EditorPlugin
## Registers the a2g/* Project Settings on every editor start (Godot does not save values equal to
## their defaults, so they must be declared each time to stay visible), and adds or removes the "A2G"
## autoload when the plugin is enabled or disabled.

const AUTOLOAD = "A2G"
const Client = preload("res://addons/a2g/a2g_client.gd")

func _enter_tree():
	for name in Client.SETTINGS:
		var value = Client.SETTINGS[name]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, value)
		ProjectSettings.set_initial_value(name, value)
		ProjectSettings.add_property_info({"name": name, "type": typeof(value)})

func _enable_plugin():
	add_autoload_singleton(AUTOLOAD, "res://addons/a2g/a2g_client.gd")

func _disable_plugin():
	remove_autoload_singleton(AUTOLOAD)
