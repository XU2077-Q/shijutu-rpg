class_name QuestLog
extends Control
## 任务一览 —— 暂停菜单「任 务」打开的东西。
##
## 跟时局图同一条规矩：没走到的任务不露题，只写「尚未开始」。
## 进行中的任务列出全部目标，已翻过的条目淡墨、当前一条朱砂；
## 已完成的任务整段淡墨、目标前打勾。状态一律现场问 QuestManager，
## 每次 open() 重搭 —— 面板是复用的，但内容不能是上一回的。

signal closed

var _list: VBoxContainer


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
	panel.offset_left = 150
	panel.offset_right = -150
	panel.offset_top = 60
	panel.offset_bottom = -60
	add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	panel.add_child(outer)

	var title := Label.new()
	Paper.style_label(title, 30, Paper.INK)
	title.text = "任 务"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 14)
	scroll.add_child(_list)


func open() -> void:
	for c in _list.get_children():
		c.queue_free()
	for q in QuestManager.quest_defs():
		if q is Dictionary:
			_list.add_child(_card(q))
	visible = true


func _card(q: Dictionary) -> Control:
	var st := QuestManager.state_of(q)
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER, Paper.PAPER_EDGE, 1))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	card.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	col.add_child(head)

	var glyph := Label.new()
	Paper.style_label(glyph, 28, _glyph_color(st))
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.text = _glyph(st)
	head.add_child(glyph)

	var name := Label.new()
	Paper.style_label(name, 25, _title_color(st))
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.text = _title_text(q, st)
	head.add_child(name)

	if st == QuestManager.State.LOCKED:
		var hint := Label.new()
		Paper.style_label(hint, 17, Paper.INK_FAINT)
		hint.text = "—— 还没有走到那一段 ——"
		col.add_child(hint)
		return card

	var summary := Label.new()
	Paper.style_label(summary, 18, Paper.INK_SOFT)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.text = str(q.get("summary", ""))
	col.add_child(summary)

	# 目标清单。进行中：翻过的淡墨打勾，当下的一条朱砂；完成：全部淡墨打勾。
	var cur := DataDB.spine_index(GameState.scene)
	var active_anchor := -1
	if st == QuestManager.State.ACTIVE:
		for g in q.get("goals", []):
			var gi := DataDB.spine_index(str(g.get("at", "")))
			if gi <= cur:
				active_anchor = gi
	for g in q.get("goals", []):
		var gi := DataDB.spine_index(str(g.get("at", "")))
		var is_now := st == QuestManager.State.ACTIVE and gi == active_anchor
		var past := st == QuestManager.State.DONE or gi < active_anchor
		var row := Label.new()
		Paper.style_label(row, 19, Paper.CINNABAR if is_now else (Paper.INK_SOFT if past else Paper.INK_FAINT))
		var mark := "● " if is_now else ("✓ " if past else "○ ")
		row.text = "　" + mark + str(g.get("text", ""))
		row.visible = is_now or past or st == QuestManager.State.DONE
		col.add_child(row)

	return card


func _glyph(st: int) -> String:
	match st:
		QuestManager.State.ACTIVE:
			return "◆"
		QuestManager.State.DONE:
			return "✓"
	return "？"


func _glyph_color(st: int) -> Color:
	match st:
		QuestManager.State.ACTIVE:
			return Paper.CINNABAR
		QuestManager.State.DONE:
			return Paper.INK_SOFT
	return Paper.INK_FAINT


func _title_color(st: int) -> Color:
	return Paper.INK if st != QuestManager.State.LOCKED else Paper.INK_FAINT


func _title_text(q: Dictionary, st: int) -> String:
	if st == QuestManager.State.LOCKED:
		return "尚 未 开 始"
	var t := "%s · %s" % [str(q.get("chapter", "")), str(q.get("title", ""))]
	if st == QuestManager.State.DONE:
		t += "　（已竟）"
	return t


func close_panel() -> void:
	visible = false
	closed.emit()


func _input(e: InputEvent) -> void:
	if visible and e.is_action_pressed("menu"):
		close_panel()
		get_viewport().set_input_as_handled()
