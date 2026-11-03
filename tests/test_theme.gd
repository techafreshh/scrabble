# Wordtable warm-club theme suite (shared visual foundation, no scene deps).
# Run headless via res://tests/test_runner.gd (`--suite theme` or full run).
# Prints the palette_colors acceptance marker on every theme run.
class_name TestTheme
extends RefCounted

const THEME_PATH := "res://themes/warm_club.tres"
const TEXTURE_PATHS := [
	"res://assets/placeholder_wood.svg",
	"res://assets/placeholder_felt.svg",
	"res://assets/placeholder_ivory.svg",
	"res://assets/placeholder_brass.svg",
]
const EXPECTED_COLORS := {
	"wood": "4a2f1d",
	"felt": "1d5c3f",
	"ivory": "f3ead3",
	"brass": "c9a227",
}


static func run_all(runner: SceneTree) -> void:
	runner.assert_true(ResourceLoader.exists(THEME_PATH), "theme_file_exists")
	var theme: Theme = load(THEME_PATH) as Theme
	runner.assert_true(theme != null, "theme_loads_as_theme")
	if theme == null:
		return
	runner.assert_true(theme.has_default_font(), "theme_has_default_font")
	runner.assert_eq(theme.get_default_font_size(), 16, "theme_default_font_size_16")

	var colors: int = 0
	for color_name: String in EXPECTED_COLORS.keys():
		runner.assert_true(theme.has_color(color_name, "WarmClub"), "theme_has_color_" + color_name)
		var got: String = theme.get_color(color_name, "WarmClub").to_html(false).to_lower()
		runner.assert_eq(got, EXPECTED_COLORS[color_name], "theme_color_hex_" + color_name)
		colors += 1
	runner.assert_eq(theme.get_color_list("WarmClub").size(), 4, "theme_palette_size_4")

	runner.assert_true(theme.has_stylebox("panel_felt", "WarmClub"), "theme_has_panel_felt")
	runner.assert_true(theme.has_stylebox("tile_ivory", "WarmClub"), "theme_has_tile_ivory")
	runner.assert_true(theme.has_stylebox("button_wood", "WarmClub"), "theme_has_button_wood")
	runner.assert_true(theme.get_stylebox("panel_felt", "WarmClub") is StyleBoxFlat, "theme_panel_felt_flat")
	runner.assert_true(theme.get_stylebox("tile_ivory", "WarmClub") is StyleBoxFlat, "theme_tile_ivory_flat")
	runner.assert_true(theme.get_stylebox("button_wood", "WarmClub") is StyleBoxFlat, "theme_button_wood_flat")
	runner.assert_true(theme.has_stylebox("normal", "Button"), "theme_button_normal")
	runner.assert_true(theme.has_stylebox("hover", "Button"), "theme_button_hover")
	runner.assert_true(theme.has_stylebox("pressed", "Button"), "theme_button_pressed")
	runner.assert_true(theme.has_stylebox("panel", "PanelContainer"), "theme_panelcontainer_panel")

	for texture_path: String in TEXTURE_PATHS:
		runner.assert_true(ResourceLoader.exists(texture_path), "theme_texture_exists_" + texture_path.get_file())
		var texture: Texture2D = load(texture_path) as Texture2D
		runner.assert_true(texture != null, "theme_texture_loads_" + texture_path.get_file())
		if texture != null:
			var size: Vector2i = Vector2i(int(texture.get_width()), int(texture.get_height()))
			runner.assert_true(size.x > 0 and size.y > 0, "theme_texture_nonzero_" + texture_path.get_file())

	print("palette_colors=%d" % colors)
