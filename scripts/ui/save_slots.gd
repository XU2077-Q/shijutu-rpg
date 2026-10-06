class_name SaveSlots
extends Control
## 存档格 —— 暂停菜单里「存 档」/「读 档」打开的东西。同一个面板两种模式。
##
## 【覆盖存档要二次确认】第一次点是「拿起」这一格（行变色、提示再点一次），
## 第二次才真写。手快的玩家、误触一下，都不该被一个点击抹掉旧档。
## 【读档】只有有内容的格能点，点一下就走（由 PauseMenu 负责去哪个屏）。

signal saved(slot: String)
signal loaded(slot: String)
signal closed

enum Mode { SAVE, LOAD }

var _mode := Mode.SAVE
var _rows: VBoxContainer
var _title: Label
var _status: Label
var _armed := ""
var _disarm_at := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.03, 0.66)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_LIGHT, Paper.PAPER_EDGE, 2))
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 220
	panel.offset_right = -220
	panel.offset_top = 80
	panel.offset_bottom = -80
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	panel.add_child(col)

	_title = Label.new()
	Paper.style_label(_title, 28, Paper.INK)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_title)

	_rows = VBoxContainer.new()
	_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 8)
	col.add_child(_rows)

	_status = Label.new()
	Paper.style_label(_status, 18, Paper.CINNABAR)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_status)


func open(mode: int) -> void:
	_mode = mode as Mode
	_armed = ""
	_status.text = ""
	_title_text()
	_refresh()
	visible = true


func _title_text() -> void:
	_title.text = "存 档" if _mode == Mode.SAVE else "读 档"


func _refresh() -> void:
	for c in _rows.get_children():
		c.queue_free()
	for info in SaveManager.list_slots():
		_rows.add_child(_row(info))


func _row(info: Dictionary) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 76)
	var slot := str(info["slot"])
	var exists: bool = info["exists"]
	var meta: Dictionary = info["meta"]
	b.text = _row_text(slot, exists, meta)
	b.disabled = _mode == Mode.LOAD and not exists
	if _armed == slot:
		b.add_theme_stylebox_override("normal", Paper.paper_box(
			Color(0.745, 0.549, 0.235, 0.22), Paper.CINNABAR, 2))
	b.add_theme_font_override("font", Paper.font())
	b.add_theme_font_size_override("font_size", 19)
	b.pressed.connect(_on_row.bind(slot))
	return b


func _row_text(slot: String, exists: bool, meta: Dictionary) -> String:
	var head := "第 %s 格" % slot
	if _armed == slot:
		return "%s　—— 再点一次，确认覆盖旧档" % head
	if not exists:
		return "%s　·　— 空 —" % head
	var where := str(meta.get("room", ""))
	if where.is_empty():
		where = str(meta.get("ch", ""))
	var clock := Time.get_time_string_from_unix_time(int(meta.get("t", 0)))
	var date := Time.get_date_string_from_unix_time(int(meta.get("t", 0)))
	var last := str(meta.get("last", ""))
	return "%s　·　%s　%s %s　%s" % [head, where, date, clock, last]


func _on_row(slot: String) -> void:
	if _mode == Mode.SAVE:
		if _armed != slot:
			_armed = slot
			_disarm_at = Time.get_ticks_msec() + 2500
			_status.text = "再点一次确认覆盖" if SaveManager.has_slot(slot) else "再点一次确认存档"
			_refresh()
			return
		_armed = ""
		if SaveManager.save(slot, GameState.world_dict()):
			_status.text = "已保存到第 %s 格" % slot
			saved.emit(slot)
			await get_tree().create_timer(0.4).timeout
			close_panel()
		else:
			_status.text = "保存失败，请重试"
		return
	# 读档
	var d := SaveManager.load_slot(slot)
	if bool(d.get("ok", false)):
		loaded.emit(slot)
		visible = false
	else:
		_status.text = "这个存档读不出来"


func _process(_delta: float) -> void:
	if not _armed.is_empty() and Time.get_ticks_msec() > _disarm_at:
		_armed = ""
		_status.text = ""
		_refresh()


func close_panel() -> void:
	visible = false
	closed.emit()


func _input(e: InputEvent) -> void:
	if visible and e.is_action_pressed("menu"):
		close_panel()
		get_viewport().set_input_as_handled()


# ---------------------- 给测试看的 ----------------------

func mode_name() -> String:
	return Mode.keys()[_mode]

func row_count() -> int:
	return _rows.get_child_count()
