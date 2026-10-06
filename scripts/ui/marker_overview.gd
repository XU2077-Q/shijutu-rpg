class_name MarkerOverview
extends Control
## 时局图 —— 暂停菜单里「时 局 图」打开的东西：六枚势力印章的一览。
##
## 【没揭的不露内容】只露「？· 尚未显现」。跟游戏里「未解锁的结局不露名字」
## 是同一条规矩：没发生的历史，不该提前把答案念给玩家。
## 揭过的：大字（势力名）+ 名 + 地区 + 说明。

signal closed

## 卡高是按 720 视口算过的：面板（上下各留 40）+ 标题 + 三行卡 + 间隔
## 必须放得下六枚章，超了第三行会冲出纸边（浏览器自查里抓过这个溢出）。
## 揭过的卡说明长、会自然撑高 —— 那时由外层 ScrollContainer 兜住。
const CARD_MIN := Vector2(480, 166)


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
	panel.offset_left = 110
	panel.offset_right = -110
	panel.offset_top = 40
	panel.offset_bottom = -40
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	panel.add_child(col)

	var title := Label.new()
	Paper.style_label(title, 30, Paper.INK)
	title.text = "时 局 图"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	# ScrollContainer 是兜底：六章全是未揭状态时六张卡正好放满 720 视口；
	# 揭过的卡说明文字长，会把卡撑高 —— 那时宁可滚动，也不许冲出纸面。
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	scroll.add_child(grid)

	for m in DataDB.markers:
		grid.add_child(_card(m))


func _card(m: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_MIN
	card.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER, Paper.PAPER_EDGE, 1))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	card.add_child(hb)

	var id := str(m.get("id", ""))
	var revealed := GameState.is_marker_revealed(id)

	var glyph := Label.new()
	Paper.style_label(glyph, 62, Paper.CINNABAR if revealed else Paper.INK_FAINT)
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.custom_minimum_size = Vector2(104, 0)
	glyph.text = str(m.get("glyph", "")) if revealed else "？"
	hb.add_child(glyph)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	hb.add_child(col)

	var name := Label.new()
	Paper.style_label(name, 24, Paper.INK if revealed else Paper.INK_FAINT)
	name.text = str(m.get("name", "")) if revealed else "尚 未 显 现"
	col.add_child(name)

	var region := Label.new()
	Paper.style_label(region, 17, Paper.CINNABAR if revealed else Paper.INK_FAINT)
	region.text = str(m.get("region", "")) if revealed else "—— 走到那一步，它才出现 ——"
	col.add_child(region)

	if revealed:
		var desc := Label.new()
		Paper.style_label(desc, 18, Paper.INK_SOFT)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.text = str(m.get("desc", ""))
		col.add_child(desc)

	return card


func open() -> void:
	visible = true


func close_panel() -> void:
	visible = false
	closed.emit()


func _input(e: InputEvent) -> void:
	if visible and e.is_action_pressed("menu"):
		close_panel()
		get_viewport().set_input_as_handled()
