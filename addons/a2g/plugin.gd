@tool
extends EditorPlugin
## Enabling the plugin registers the "A2G" autoload and shows the a2g/* Project Settings with their defaults.

const AUTOLOAD = "A2G"
const Client = preload("res://addons/a2g/a2g_client.gd")

func _enable_plugin():
	add_autoload_singleton(AUTOLOAD, "res://addons/a2g/a2g_client.gd")
	for name in Client.SETTINGS:
		var value = Client.SETTINGS[name]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, value)
		ProjectSettings.set_initial_value(name, value)
		ProjectSettings.add_property_info({"name": name, "type": typeof(value)})
	ProjectSettings.save()

func _disable_plugin():
	remove_autoload_singleton(AUTOLOAD)
