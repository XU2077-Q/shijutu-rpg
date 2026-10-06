class_name NotesBrowser
extends Control
## 史实注一览 —— 暂停菜单里「史 实 注」打开的东西。
##
## 【它不是 NoteView】NoteView 是查物件时翻出**一条**注；
## 这里是把全部注列在左边，点一条读一条，跟网页版顶部那颗「史实注」同款。
## 已读/未读有记号，正文走 NoteView.markup（[ref]→落款的处理只有那一份）。

signal closed

var _list: ItemList
var _body: RichTextLabel
var _entries: Array = []   ## [{ch, h}]


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
	panel.offset_left = 96
	panel.offset_right = -96
	panel.offset_top = 70
	panel.offset_bottom = -70
	add_child(panel)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 20)
	panel.add_child(hb)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(380, 0)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_selected)
	# ItemList 默认皮是深灰底 + 引擎默认字体 —— 默认字体没有中文，
	# 目录会整列豆腐块（浏览器里一眼全是方块）。字体、皮、选中色全换成本作的。
	_list.add_theme_font_override("font", Paper.font())
	_list.add_theme_font_size_override("font_size", 18)
	_list.add_theme_color_override("font_color", Paper.INK_SOFT)
	_list.add_theme_color_override("font_selected_color", Paper.CINNABAR)
	_list.add_theme_constant_override("v_separation", 6)
	var list_panel := Paper.paper_box(Paper.PAPER, Paper.PAPER_EDGE, 1)
	_list.add_theme_stylebox_override("panel", list_panel)
	var sel := StyleBoxFlat.new()
	sel.bg_color = Color(0.55, 0.12, 0.07, 0.12)
	sel.content_margin_left = 10
	sel.content_margin_right = 10
	sel.content_margin_top = 3
	sel.content_margin_bottom = 3
	_list.add_theme_stylebox_override("selected", sel)
	_list.add_theme_stylebox_override("selected_focus", sel)
	var hov := StyleBoxFlat.new()
	hov.bg_color = Color(0.3, 0.22, 0.12, 0.07)
	hov.content_margin_left = 10
	hov.content_margin_right = 10
	hov.content_margin_top = 3
	hov.content_margin_bottom = 3
	_list.add_theme_stylebox_override("hover", hov)
	_list.add_theme_stylebox_override("hover_selected", sel)
	hb.add_child(_list)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	Paper.style_rich(_body, 23, Paper.INK)
	_body.add_theme_constant_override("line_separation", 12)
	hb.add_child(_body)


func open() -> void:
	_entries.clear()
	_list.clear()
	# DataDB.notes：{章: [{h, b}]}。Dictionary 保留 JSON 里的章序。
	for ch in DataDB.notes:
		for n in DataDB.notes[ch]:
			var h := str((n as Dictionary).get("h", ""))
			_entries.append({"ch": str(ch), "h": h})
			var seen := GameState.has_seen_codex(str(ch), h)
			_list.add_item("%s %s · %s" % ["✓" if seen else "·", str(ch), h])
	visible = true
	if not _entries.is_empty():
		_list.select(0)
		_on_selected(0)


func _on_selected(i: int) -> void:
	if i < 0 or i >= _entries.size():
		return
	var e: Dictionary = _entries[i]
	var ch := str(e["ch"])
	var h := str(e["h"])
	_body.text = NoteView.markup(DataDB.note_body(ch, h))
	_body.scroll_to_line(0)
	GameState.mark_codex(ch, h)
	# 读过之后行首的记号要改口
	_list.set_item_text(i, "✓ %s · %s" % [ch, h])


func close_panel() -> void:
	visible = false
	closed.emit()


func _input(e: InputEvent) -> void:
	if visible and e.is_action_pressed("menu"):
		close_panel()
		get_viewport().set_input_as_handled()


# ---------------------- 给测试看的 ----------------------

func entry_count() -> int:
	return _entries.size()

func body_text() -> String:
	return _body.text
