class_name PauseMenu
extends Control
## 暂停菜单 —— VN 屏和房间屏共用。Esc 打开（原来 Esc 是直接回标题）。
##
## 【按钮照网页版原作的操作列】继续游戏 · 存档 · 读档 · 时局图 · 史实注 ·
## 任务 · 设置 · 返回标题。回想屏还没做，先不摆空壳（跟标题屏同一取舍）。
##
## 【读档后去哪儿，按档里的房间判】档里有房间 → 进房间屏脊梁续播；
## 没有 → 进 VN 屏续读。在哪个屏打开的菜单不作数 ——
## 玩家读的是那个档，不是这个屏。
##
## 【输入】menu(Esc) 在没有子面板时 = 继续；walk_* 键在这层吞掉，
## 免得暂停时小人还在走。ui_advance 不碰：父屏自己用 is_open() 挡
## （这里若把 ui_advance 标成 handled，菜单按钮就收不到空格/回车激活了）。

signal resumed
signal title_requested

const VN_SCENE := "res://scenes/vn/vn_screen.tscn"
const ROOM_SCENE := "res://scenes/world/room.tscn"

var _panel: PanelContainer
var _save_slots: SaveSlots
var _marker: MarkerOverview
var _notes: NotesBrowser
var _quests: QuestLog
var _settings: SettingsPanel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.03, 0.60)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_LIGHT, Paper.GOLD, 2))
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(440, 0)
	add_child(_panel)
	_panel.resized.connect(func() -> void:
		_panel.position = (size - _panel.size) * 0.5)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	_panel.add_child(col)

	var title := Label.new()
	Paper.style_label(title, 30, Paper.INK)
	title.text = "暂 停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	col.add_child(_gap(8))

	col.add_child(_button("继 续 游 戏", resume_game))
	col.add_child(_button("存　　档", _open_save))
	col.add_child(_button("读　　档", _open_load))
	col.add_child(_button("时 局 图", _open_markers))
	col.add_child(_button("史 实 注", _open_notes))
	col.add_child(_button("任　　务", _open_quests))
	col.add_child(_button("设　　置", _open_settings))

	var quit := _button("返 回 标 题", _to_title)
	quit.add_theme_color_override("font_color", Paper.CINNABAR)
	quit.add_theme_color_override("font_hover_color", Paper.CINNABAR_HI)
	col.add_child(quit)


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 48)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", Paper.font())
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Paper.INK)
	b.add_theme_color_override("font_hover_color", Paper.CINNABAR_HI)
	b.add_theme_stylebox_override("normal", Paper.paper_box(Paper.PAPER, Paper.PAPER_EDGE, 1))
	b.add_theme_stylebox_override("hover", Paper.paper_box(Paper.PAPER, Paper.CINNABAR, 1))
	b.pressed.connect(handler)
	return b


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ============================================================
#  开合
# ============================================================

func open() -> void:
	visible = true
	_panel.visible = true


func is_open() -> bool:
	return visible


func resume_game() -> void:
	visible = false
	resumed.emit()


func _to_title() -> void:
	visible = false
	title_requested.emit()


# ============================================================
#  子面板
# ============================================================

func _open_save() -> void:
	_panel.visible = false
	if _save_slots == null:
		_save_slots = SaveSlots.new()
		add_child(_save_slots)
		_save_slots.closed.connect(func() -> void: _panel.visible = true)
	_save_slots.open(SaveSlots.Mode.SAVE)


func _open_load() -> void:
	if _save_slots == null:
		_save_slots = SaveSlots.new()
		add_child(_save_slots)
		_save_slots.loaded.connect(_after_load)
		_save_slots.closed.connect(func() -> void: _panel.visible = true)
	_panel.visible = false
	_save_slots.open(SaveSlots.Mode.LOAD)


func _open_markers() -> void:
	_panel.visible = false
	if _marker == null:
		_marker = MarkerOverview.new()
		add_child(_marker)
		_marker.closed.connect(func() -> void: _panel.visible = true)
	_marker.open()


func _open_notes() -> void:
	_panel.visible = false
	if _notes == null:
		_notes = NotesBrowser.new()
		add_child(_notes)
		_notes.closed.connect(func() -> void: _panel.visible = true)
	_notes.open()


func _open_quests() -> void:
	_panel.visible = false
	if _quests == null:
		_quests = QuestLog.new()
		add_child(_quests)
		_quests.closed.connect(func() -> void: _panel.visible = true)
	_quests.open()


func _open_settings() -> void:
	_panel.visible = false
	if _settings == null:
		_settings = SettingsPanel.new()
		add_child(_settings)
		_settings.closed.connect(func() -> void: _panel.visible = true)
	_settings.open()


# ============================================================
#  读档后的路由
# ============================================================

func _after_load(_slot: String) -> void:
	# SaveManager.load_slot 已经把档灌进 GameState 了。
	get_tree().change_scene_to_file(route_after_load())


## 读档后该去哪个屏。摆好路标（RoomView 进场时认），返回场景路径。
## 单拎出来：测试要验路由，但真调 change_scene_to_file 会把跑架自己换掉。
func route_after_load() -> String:
	if not GameState.room.is_empty():
		AppSettings.pending_spine = true
		AppSettings.pending_resume = true
		return ROOM_SCENE
	# spine 路标必须显式抹掉：上一次读过房间档会把它留在 true。
	AppSettings.pending_spine = false
	AppSettings.pending_resume = true
	return VN_SCENE


# ============================================================
#  输入
# ============================================================

func _sub_open() -> bool:
	return (_save_slots != null and _save_slots.visible) \
		or (_marker != null and _marker.visible) \
		or (_notes != null and _notes.visible) \
		or (_quests != null and _quests.visible) \
		or (_settings != null and _settings.visible)


func _input(e: InputEvent) -> void:
	if not visible:
		return
	if e.is_action_pressed("menu"):
		# 子面板各自的 _input 会自己关；都没开着，Esc = 继续。
		if not _sub_open():
			get_viewport().set_input_as_handled()
			resume_game()
		return
	# 吞掉走路键，暂停时不许走。
	for act in ["walk_up", "walk_down", "walk_left", "walk_right"]:
		if e.is_action_pressed(act):
			get_viewport().set_input_as_handled()
			return
