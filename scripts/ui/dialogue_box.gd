class_name DialogueBox
extends Control
## 对话框。宣纸底、墨字、右上角一枚「点击继续」。
##
## 【打字机为什么要能被跳过】
## 中文一行二十几个字，按 45 字/秒 也要半秒。玩家读到第三遍剧情时，
## 半秒乘以四百拍就是三分钟。所以第一次点击**永远是「显示完整句」**，
## 第二次才是「下一句」—— 这是所有 AVG 的默契，别自作聪明改掉。
##
## 【emph 的排法】
## 剧本里 22 处旁白带 emph 标记，它们不是普通旁白，是每一场的**落点**：
##   「不变法，必亡。」
##   「如果不变法必亡，那么，从哪里变起？」
## 这种句子跟上下文一样大地混在段落里就废了。所以居中、放大、用足墨色。

signal typing_finished

## 每秒打几个字。中文 40~50 是舒适区：再快就糊，再慢就等。
const CPS := 45.0
## 至少打这么久。短句（「是。」）如果按字数算只有 0.05 秒，
## 等于瞬间蹦出来，反而让人以为漏了一拍。
const MIN_DURATION := 0.28

const EMPH_SIZE := 34
const BODY_SIZE := 27

var _plate: PanelContainer
var _name_label: Label
var _box: PanelContainer
var _body: RichTextLabel
var _hint: Label

var _tween: Tween
var _typing := false
var _hint_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

	_build_box()
	_build_plate()
	_build_hint()
	set_process(false)


func _build_box() -> void:
	_box = PanelContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_stylebox_override("panel", Paper.translucent_paper(0.94))
	_box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_box.offset_left = 72
	_box.offset_right = -72
	_box.offset_top = -212
	_box.offset_bottom = -36
	add_child(_box)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = false
	_body.fit_content = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Paper.style_rich(_body, BODY_SIZE, Paper.INK)
	_body.add_theme_constant_override("line_separation", 12)
	_box.add_child(_body)


## 名条压在框的左上角，**骑在边框上** —— 骑上去才像贴的一张签，
## 完全在框内就像表格的一格。
func _build_plate() -> void:
	_plate = PanelContainer.new()
	_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plate.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_DEEP, Paper.PAPER_EDGE, 2))
	_plate.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_plate.offset_left = 104
	_plate.offset_top = -252
	_plate.offset_bottom = -196
	_plate.offset_right = 104 + 220
	add_child(_plate)

	_name_label = Label.new()
	Paper.style_label(_name_label, 28, Paper.INK)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_plate.add_child(_name_label)


func _build_hint() -> void:
	_hint = Label.new()
	Paper.style_label(_hint, 20, Paper.INK_FAINT)
	_hint.text = "点击继续"
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_hint.offset_left = -180
	_hint.offset_right = -96
	_hint.offset_top = -76
	_hint.offset_bottom = -48
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_hint)
	_hint.modulate.a = 0.0


# ============================================================
#  对外
# ============================================================

## 旁白：没有名条。
func show_narration(text: String, emph: bool = false) -> void:
	_show("", _markup(text, emph))


## 对白：有名条。speaker 是名字，role 是身份（只在第一次出场时给，可以为空）。
func show_speech(speaker: String, role: String, text: String, emph: bool = false) -> void:
	var plate := speaker
	if not role.is_empty():
		plate += "（%s）" % role
	_show(plate, _markup(text, emph))


func _show(plate: String, markup: String) -> void:
	visible = true
	if plate.is_empty():
		_plate.visible = false
	else:
		_plate.visible = true
		_name_label.text = plate
		# 名条宽度跟着名字走：固定 220 px 的话，「沈怀瑾」三个字会顶到边上，
		# 「康有为（广东南海 · 举人）」又会溢出。
		var want: float = Paper.font().get_string_size(
			plate, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x + 56.0
		_plate.offset_right = _plate.offset_left + maxf(want, 140.0)

	_body.text = markup
	_start_typing()


## 正在打字 —— 界面据此决定这次点击是「显示完整」还是「下一句」。
func is_typing() -> bool:
	return _typing


## 把这一句一次显示完。玩家第一次点击走的永远是这条路。
func skip_typing() -> void:
	if not _typing:
		return
	_finish_typing()


## 给测试看的：现在框里写着什么、名条上是谁。
## 不给的话，测试只能去翻 _body.text 这种私有字段，重构一次就全挂。
func debug_text() -> String:
	return _body.text

func debug_speaker() -> String:
	return _name_label.text if _plate.visible else ""


func hide_box() -> void:
	visible = false
	_typing = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint.modulate.a = 0.0


# ============================================================
#  内部
# ============================================================

func _markup(text: String, emph: bool) -> String:
	# 剧本正文里可能出现 []，那是给玩家看的原文，不是标签。
	# 不转义的话 RichTextLabel 会把它当成 BBCode 吃掉 —— 引文里就有方括号。
	var safe := text.replace("[", "[lb]")
	if not emph:
		return safe
	return "[center][font_size=%d]%s[/font_size][/center]" % [EMPH_SIZE, safe]


func _start_typing() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_typing = true
	_hint.modulate.a = 0.0
	_body.visible_ratio = 0.0

	var n := _body.get_total_character_count()
	var dur := maxf(MIN_DURATION, float(n) / CPS)
	_tween = create_tween()
	_tween.tween_property(_body, "visible_ratio", 1.0, dur)
	_tween.finished.connect(_finish_typing)


func _finish_typing() -> void:
	if not _typing:
		return
	_typing = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_body.visible_ratio = 1.0
	_blink_hint()
	typing_finished.emit()


func _blink_hint() -> void:
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint.modulate.a = 0.0
	_hint_tween = create_tween().set_loops()
	_hint_tween.tween_property(_hint, "modulate:a", 1.0, 0.7)
	_hint_tween.tween_property(_hint, "modulate:a", 0.35, 0.7)
