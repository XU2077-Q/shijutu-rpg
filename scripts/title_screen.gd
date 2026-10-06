extends Control
## 标题屏。进游戏前的第一屏。
##
## 【长什么样，抄谁】
## 抄网页版的 #titleScreen：深色底（#161310 一族）+ 中心一团暖光 + 居中一列按钮。
## 正文是宣纸，标题页是夜 —— 进游戏像翻开一册书，这个反差是原版定下的。
##
## 【按钮为什么只有三颗】
## 网页版原版是「新的一局 / 续前一局 / 读取存档 / 结局图鉴 / 创作说明 / 设置」。
## 切片阶段读取存档格、结局图鉴的界面还没做（里程碑 6），
## 宁可少摆几颗，也不摆点了没反应的空壳。
##
## 【键盘】新的一局默认拿焦点 —— 回车 / 空格直接开局。
## 这不只是手感：tools/webcheck.js 的浏览器自查靠的就是「回车」这一下。

const VN_SCENE := "res://scenes/vn/vn_screen.tscn"
const ROOM_SCENE := "res://scenes/world/room.tscn"
const BTN_W := 300.0

var _continue_btn: Button
var _settings: SettingsPanel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	# 「续 前 一 局」的灰亮跟着盘上的 auto 档走 —— 档在别处落了/删了，
	# 这颗按钮要跟着变。SaveManager.saved 在每次存档后发。
	SaveManager.saved.connect(func(_slot: String) -> void:
		_continue_btn.disabled = not SaveManager.has_slot("auto"))


func _build() -> void:
	# 夜底
	var bg := ColorRect.new()
	bg.color = Color("161310")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# 中心暖光。对应网页版那道
	# radial-gradient(ellipse at 50% 42%, rgba(120,90,45,.28), transparent 62%)。
	var glow := TextureRect.new()
	glow.texture = _glow_texture()
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(glow)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	# 居中用手动摆位，不用 PRESET_CENTER ——
	# 那个预设把锚点设到 (0.5,0.5)，之后 position 的参照点就成了父中心，
	# 再赋一次 position 等于把「居中」又加了一遍半，整列会被推到右下角去。
	# 左上锚点 + 手动 position，语义才是一条：position 就是从父左上算的。
	# col 自身的尺寸会随内容变（Label 树外量不准，进树才撑开），
	# 所以 resized 也要挂一次。
	col.resized.connect(_recenter.bind(col))
	resized.connect(_recenter.bind(col))

	col.add_child(_label("时 局 图", 64, Color("e8dcc0")))
	col.add_child(_gap(10))
	col.add_child(_label("历 史 互 动 视 觉 小 说", 19, Color("9a8a6a")))
	col.add_child(_gap(20))
	col.add_child(_label("沉沉酣睡我中华，哪知爱国即爱家！\n国民知醒宜今醒，莫待土分裂似瓜。",
			16, Color("8d7c5c")))
	col.add_child(_gap(18))
	col.add_child(_rule())
	col.add_child(_gap(26))

	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 12)
	col.add_child(menu)

	var first := _menu_button("新 的 一 局", _start_new)
	menu.add_child(first)
	_continue_btn = _menu_button("续 前 一 局", _continue)
	_continue_btn.disabled = not SaveManager.has_slot("auto")
	if _continue_btn.disabled:
		_continue_btn.tooltip_text = "还没有可以续的进度"
	menu.add_child(_continue_btn)
	# 房间屏那一版。里程碑 4 时它还只是「能走、能查」的演示，
	# 里程碑 5 用 story_map 把它和脊梁接上了 —— 现在这条路是真的从头演到尾。
	# 与「新 的 一 局」的区别就在这儿：那条是 VN 屏，从头按到底，没有房间。
	# 两条路都得留着：VN 屏是 I6 的验证预言机（逐字比对靠它）。
	if DataDB.has_room(DataDB.room_start):
		var walk_btn := _menu_button("走 动 · 序 章 至 第 一 章", _walk_demo)
		walk_btn.tooltip_text = "在房间里走动、查看物件、与人交谈 —— 剧情按原著顺序推进"
		menu.add_child(walk_btn)
	menu.add_child(_menu_button("设 置", _open_settings))

	# 键盘开局。回车 / 空格按下去要有地方落 —— 焦点不给出去，
	# 这两个键就掉在屏幕上，标题屏永远等不来第一下。
	first.call_deferred("grab_focus")

	col.add_child(_gap(30))

	var foot := _label("1895 — 1899 · 序章 至 第一章（切片）", 13, Color("6b5f4a"))
	col.add_child(foot)

	_recenter(col)


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Paper.style_label(l, size, color)
	l.add_theme_constant_override("line_spacing", 12)
	# 标题那行要网页版同款的暖色光晕 + 硬投影；其余行不加。
	if size >= 64:
		l.add_theme_color_override("font_outline_color", Color(0.784, 0.588, 0.275, 0.35))
		l.add_theme_constant_override("outline_size", 14)
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.4))
		l.add_theme_constant_override("shadow_offset_y", 4)
	return l


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _rule() -> Control:
	var r := ColorRect.new()
	r.color = Color("6d5a38")
	r.custom_minimum_size = Vector2(120, 1)
	r.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _menu_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(BTN_W, 52)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", Paper.font())
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Color("cbb894"))
	b.add_theme_color_override("font_hover_color", Color("f0e2c2"))
	b.add_theme_color_override("font_focus_color", Color("f0e2c2"))
	b.add_theme_color_override("font_disabled_color", Color("cbb894") * Color(1, 1, 1, 0.28))
	b.add_theme_stylebox_override("normal", _btn_style(Color("161310").lightened(0.015), Color("4d4230")))
	b.add_theme_stylebox_override("hover", _btn_style(Color(0.745, 0.549, 0.235, 0.14), Color("96794a")))
	b.add_theme_stylebox_override("pressed", _btn_style(Color(0.745, 0.549, 0.235, 0.20), Color("96794a")))
	b.add_theme_stylebox_override("focus", _btn_style(Color(0.745, 0.549, 0.235, 0.14), Color("96794a")))
	b.add_theme_stylebox_override("disabled", _btn_style(Color("161310"), Color("352d22")))
	b.pressed.connect(handler)
	return b


func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


# 网页版标题页的中心暖光：中心 42% 高度处一团 rgba(120,90,45,.28)，
# 到 62% 半径淡没。GradientTexture2D 的径向填充用 fill_from/fill_to 表达。
func _glow_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0.47, 0.353, 0.176, 0.28))
	g.set_color(1, Color(0, 0, 0, 0))
	g.add_point(0.55, Color(0.47, 0.353, 0.176, 0.10))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.42)
	t.fill_to = Vector2(1.12, 0.42)
	t.width = 512
	t.height = 512
	return t


# PRESET_CENTER 不用（见上）—— 左上锚点 + 手动摆位，语义只有一条。
func _recenter(col: VBoxContainer) -> void:
	if not is_instance_valid(col):
		return
	var m := col.get_combined_minimum_size()
	col.position = (size - m) * 0.5


## 键盘兜底：焦点若被谁抢走（或压根没建立），回车 / 空格也要能开局。
##
## 【原来这里写的是「有焦点时按钮自己消费 ui_accept，走不到这里」，这句是错的】
## 踩出来的：加了「走 动」这颗按钮之后，焦点停在它上面按回车，
## 进的是**纯 VN**，不是房间。
##
## 原因是 Button 对 ui_accept 的消费只发生在**按下**那一半：
##   按下 → 按钮 accept_event()，这里确实走不到；
##   松开 → 按钮在这里 emit pressed（于是「走动」真的跑了），
##          但那一半没有被 accept，于是**这里也跑了一遍**，
##          后跑的 change_scene_to_file 盖掉先跑的。
## 之前三颗按钮时看不出来 —— 焦点默认在「新 的 一 局」上，
## 两条路干的是同一件事，谁盖谁都一样。换一颗按钮，这个坑才露出来。
##
## 所以判据换成「有没有人拿着焦点」：有，回车就是它的；没有，才轮到兜底。
func _unhandled_input(e: InputEvent) -> void:
	if _settings != null and _settings.visible:
		return
	if e.is_action_pressed("ui_accept") and enter_starts_a_new_game():
		_start_new()


## 回车该不该当成「开局」—— 有东西拿着焦点时不该。
## 单独拎出来是为了能被测试问到：真调 _unhandled_input 会 change_scene，
## 那会把测试跑架自己换掉。
func enter_starts_a_new_game() -> bool:
	return get_viewport().gui_get_focus_owner() == null


func _start_new() -> void:
	AppSettings.pending_resume = false
	get_tree().change_scene_to_file(VN_SCENE)


func _continue() -> void:
	var d := SaveManager.load_slot("auto")
	if d.is_empty():
		return
	AppSettings.pending_resume = true
	get_tree().change_scene_to_file(VN_SCENE)


## 走动演示：进房间屏，从脊梁开头演起。
## 不碰 pending_resume —— 那条路是给「续 前 一 局」的，两边别互相踩。
func _walk_demo() -> void:
	AppSettings.pending_resume = false
	AppSettings.pending_spine = true
	AppSettings.pending_room = ""
	AppSettings.pending_at = Vector2.INF
	get_tree().change_scene_to_file(ROOM_SCENE)


func _open_settings() -> void:
	if _settings == null:
		_settings = SettingsPanel.new()
		add_child(_settings)
	_settings.open()


## 给测试用：三颗按钮现在的样子。
func described() -> Array:
	var out: Array = []
	for b in find_children("*", "Button", true, false):
		out.append({"text": (b as Button).text, "disabled": (b as Button).disabled})
	return out
