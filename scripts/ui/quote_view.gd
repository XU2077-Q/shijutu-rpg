class_name QuoteView
extends Control
## 引文。全屏，暗底，一句诗或一段史料，底下署出处。
##
## 【为什么不塞进对话框】
## 剧本里 18 条引文全是**别人的声音**：谭嗣同的诗、《马关条约》的条文、
## 梁启超的事后追述。它们和沈怀瑾的世界不在同一个时间层上 ——
## 用同一个对话框播，读起来就像是场景里有人在念台词。
## 所以给它们一块自己的屏：暗下去，只剩字，看完再回来。

signal dismissed

const VERSE_SIZE := 30
const SRC_SIZE := 21

var _backdrop: ColorRect
var _verse: Label
var _src: Label
var _col: VBoxContainer
var _tween: Tween
var _leaving := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_backdrop = ColorRect.new()
	_backdrop.color = Color(Paper.NIGHT.r, Paper.NIGHT.g, Paper.NIGHT.b, 0.93)
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	_col = VBoxContainer.new()
	_col.set_anchors_preset(Control.PRESET_FULL_RECT)
	_col.offset_left = 140
	_col.offset_right = -140
	_col.alignment = BoxContainer.ALIGNMENT_CENTER
	_col.add_theme_constant_override("separation", 34)
	_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_col)

	_verse = Label.new()
	Paper.style_label(_verse, VERSE_SIZE, Paper.PAPER_LIGHT)
	_verse.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_verse.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_verse.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(_verse)

	_src = Label.new()
	Paper.style_label(_src, SRC_SIZE, Paper.CINNABAR_HI)
	_src.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_src.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_src.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(_src)


func present(verse: String, src: String) -> void:
	_verse.text = verse
	_src.text = "—— " + src if not src.is_empty() else ""
	_leaving = false
	visible = true
	modulate.a = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 0.45).set_trans(Tween.TRANS_SINE)


## 玩家点了 / 按了空格。淡出之后才发信号 —— 立刻切走会看见引文「啪」地消失。
##
## _leaving 是防连点的闸：连点会一次次重起淡出，而 tween 是从当前值插到 0，
## 等于每点一次都给淡出续命，引文永远走不掉。
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


## 立刻收起来，不走淡出、不发信号。
## 用在「这一轮已经结束了」的时候：这时候还演淡出没有意义，
## 而且它会和结局卡抢屏幕。
func force_hide() -> void:
	visible = false
	_leaving = false
	if _tween != null and _tween.is_valid():
		_tween.kill()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		dismiss()
		accept_event()
