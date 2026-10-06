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
## 本个输入事件里是否有子面板刚关掉。viewport 倒序派 _input：子面板先收到
## Esc、关自己，主菜单同一拍才收到 —— 没这个标记就会把「回主面板」误判成
## 「没有子面板，继续游戏」。当拍消费；鼠标关闭子面板时没有同拍 Esc，
## 帧尾延迟清一道，免得标记留到下一键。
var _sub_just_closed := false
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
	col.add_theme_constant_override("separation", 10)
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
	b.custom_minimum_size = Vector2(320, 46)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", Paper.font())
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Paper.INK)
	b.add_theme_color_override("font_hover_color", Paper.CINNABAR_HI)
	# paper_box 默认上下各 20 的内容边距 —— 配上 VF 字体偏大的行高，
	# 单颗按钮会被顶到 65px 高，八颗加标题超出 720 视口，末颗被裁掉。
	# 菜单按钮自己收一份紧边距（八颗总高 ≈ 46*8 + 间隔）。
	var normal := Paper.paper_box(Paper.PAPER, Paper.PAPER_EDGE, 1)
	normal.content_margin_top = 5
	normal.content_margin_bottom = 5
	var hover := Paper.paper_box(Paper.PAPER, Paper.CINNABAR, 1)
	hover.content_margin_top = 5
	hover.content_margin_bottom = 5
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
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


## 子面板关掉后回主面板。记下「这一拍是子面板在关」，同拍稍后到达本层的
## Esc 才不会被当成「继续游戏」。
func _back_to_panel() -> void:
	_panel.visible = true
	_sub_just_closed = true
	_clear_sub_marker.call_deferred()


# ============================================================
#  子面板
# ============================================================

func _open_save() -> void:
	_panel.visible = false
	if _save_slots == null:
		_save_slots = SaveSlots.new()
		add_child(_save_slots)
		_save_slots.closed.connect(_back_to_panel)
	_save_slots.open(SaveSlots.Mode.SAVE)


func _open_load() -> void:
	if _save_slots == null:
		_save_slots = SaveSlots.new()
		add_child(_save_slots)
		_save_slots.loaded.connect(_after_load)
		_save_slots.closed.connect(_back_to_panel)
	_panel.visible = false
	_save_slots.open(SaveSlots.Mode.LOAD)


func _open_markers() -> void:
	_panel.visible = false
	if _marker == null:
		_marker = MarkerOverview.new()
		add_child(_marker)
		_marker.closed.connect(_back_to_panel)
	_marker.open()


func _open_notes() -> void:
	_panel.visible = false
	if _notes == null:
		_notes = NotesBrowser.new()
		add_child(_notes)
		_notes.closed.connect(_back_to_panel)
	_notes.open()


func _open_quests() -> void:
	_panel.visible = false
	if _quests == null:
		_quests = QuestLog.new()
		add_child(_quests)
		_quests.closed.connect(_back_to_panel)
	_quests.open()


func _open_settings() -> void:
	_panel.visible = false
	if _settings == null:
		_settings = SettingsPanel.new()
		add_child(_settings)
		_settings.closed.connect(_back_to_panel)
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

func _clear_sub_marker() -> void:
	_sub_just_closed = false


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
		# 子面板（后加的子节点）先于本层收到这一键并关掉自己，_sub_just_closed
		# 是那一拍留下的记号：这一下 Esc 的语义是「回主面板」，不是继续游戏。
		if _sub_open() or _sub_just_closed:
			_sub_just_closed = false
			return
		get_viewport().set_input_as_handled()
		resume_game()
		return
	# 吞掉走路键，暂停时不许走。
	for act in ["walk_up", "walk_down", "walk_left", "walk_right"]:
		if e.is_action_pressed(act):
			get_viewport().set_input_as_handled()
			return
