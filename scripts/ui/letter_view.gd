class_name LetterView
extends Control
## 书信。一张竖长的信笺，抬头、正文、落款、朱印。
##
## 【字号是算出来的，不是定死的】
## 切片里最长的一封（严复来信）412 字，最短的 117 字 —— 差 3.5 倍。
## 定死字号的话，要么短的稀稀拉拉，要么长的装不下。
## 装不下最糟：**Godot 不会报错，它把多余的字裁掉**，
## 玩家读到一半信就断了，而且看不出是断的。
## 所以这里从 24 px 往下试，试到装得下为止 —— 真正的排字工就是这么干的。
##
## 下限 17 px：再小就该换一页，而不是把字缩成蚂蚁。

signal dismissed

const SHEET_TOP := 46.0
const SHEET_BOTTOM := -46.0
const SHEET_SIDE := 150.0
const MAX_SIZE := 24
const MIN_SIZE := 17

## 正文区占信笺内容高度的比例 —— 抬头和落款各占去一些。
const BODY_SHARE := 0.66

var _backdrop: ColorRect
var _sheet: PanelContainer
var _title: Label
var _to: Label
var _date: Label
var _body: Label
var _sig: Label
var _seal: Panel
var _seal_text: Label
var _tween: Tween
var _leaving := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.06, 0.05, 0.04, 0.72)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	_sheet = PanelContainer.new()
	_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_LIGHT, Paper.PAPER_EDGE, 3))
	_sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sheet.offset_left = SHEET_SIDE
	_sheet.offset_right = -SHEET_SIDE
	_sheet.offset_top = SHEET_TOP
	_sheet.offset_bottom = SHEET_BOTTOM
	add_child(_sheet)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheet.add_child(col)

	_title = _label(26, Paper.INK, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_title)

	_to = _label(24, Paper.INK, HORIZONTAL_ALIGNMENT_RIGHT)
	col.add_child(_to)

	_date = _label(19, Paper.INK_FAINT, HORIZONTAL_ALIGNMENT_RIGHT)
	col.add_child(_date)

	_body = _label(MAX_SIZE, Paper.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	col.add_child(_body)

	_sig = _label(24, Paper.INK, HORIZONTAL_ALIGNMENT_RIGHT)
	col.add_child(_sig)

	# 朱印。稍微歪一点 —— 正正方方地摆着像图标，歪一点才像盖上去的。
	_seal = Panel.new()
	_seal.custom_minimum_size = Vector2(76, 76)
	_seal.size_flags_horizontal = Control.SIZE_SHRINK_END
	_seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seal.rotation = deg_to_rad(-4.0)
	var ss := StyleBoxFlat.new()
	ss.bg_color = Paper.CINNABAR
	ss.set_corner_radius_all(4)
	_seal.add_theme_stylebox_override("panel", ss)
	col.add_child(_seal)

	_seal_text = Label.new()
	Paper.style_label(_seal_text, 22, Paper.PAPER_LIGHT)
	_seal_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seal_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_seal_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_seal_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seal.add_child(_seal_text)


func _label(size: int, color: Color, align: int) -> Label:
	var l := Label.new()
	Paper.style_label(l, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func present(beat: Dictionary) -> void:
	_title.text = str(beat.get("title", ""))
	_to.text = str(beat.get("to", ""))
	_date.text = str(beat.get("date", ""))
	_body.text = str(beat.get("body", ""))
	_sig.text = str(beat.get("sig", ""))
	var seal := str(beat.get("seal", ""))
	_seal.visible = not seal.is_empty()
	_seal_text.text = seal

	_leaving = false
	visible = true
	modulate.a = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 0.4).set_trans(Tween.TRANS_SINE)

	_fit_body()


## 把正文字号调到刚好装得下。返回最终用的字号（测试要看这个数）。
##
## 【为什么不等一帧再量】
## 第一版是 `await get_tree().process_frame` 再量容器尺寸，看着更稳，
## 但那会把 present() 变成协程 —— 而调用方（VNScreen）是同步的，
## 在同步上下文里调协程，Godot 直接报
## 「Trying to call an async function without await」，
## 整封信根本弹不出来。为一个「更稳」等一帧，代价是功能整个不工作。
##
## 尺寸其实算得出来：信笺铺满屏幕减去两侧留白，正文占其中 BODY_SHARE。
## 容器已经排好版时就用它的真实尺寸，没排好就用算出来的。
func _fit_body() -> int:
	# 局部变量不能叫 size —— 那会遮住 Control.size，
	# 而 GDScript 的解析是编译期的，一遮住，同一函数里所有 size.x 全部报
	# 「Identifier not found: size」。名字撞上内建属性时，是编译错误不是运行错误。
	var width := _body.size.x
	if width <= 1.0:
		width = maxf(self.size.x, 980.0) - SHEET_SIDE * 2 - 56.0
	var room := _body.size.y
	if room <= 1.0:
		room = maxf(self.size.y, 720.0) * BODY_SHARE

	var f := Paper.font()
	var text := _body.text
	var pt := MAX_SIZE
	while pt > MIN_SIZE:
		var h := f.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, width, pt).y
		if h <= room:
			break
		pt -= 1
	Paper.style_label(_body, pt, Paper.INK)
	return pt


## _leaving 防连点：连点会一次次重起淡出，而 tween 从当前值插到 0，
## 等于每点一次都给淡出续命，信纸永远收不起来。
func dismiss() -> void:
	if not visible or _leaving:
		return
	_leaving = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, 0.3)
	_tween.finished.connect(func() -> void:
		visible = false
		dismissed.emit())


## 立刻收起来，不走淡出、不发信号。见 QuoteView.force_hide 的说明。
func force_hide() -> void:
	visible = false
	_leaving = false
	if _tween != null and _tween.is_valid():
		_tween.kill()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		dismiss()
		accept_event()
