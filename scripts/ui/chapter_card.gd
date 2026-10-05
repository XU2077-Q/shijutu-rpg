class_name ChapterCard
extends Control
## 章节卡。暗场，章次、章名、题记，停一下再淡走。
##
## 【为什么用剧本里的 card 字段，不自己按 ch 拼】
## 六张卡的写法是排过的：「序 章」和「春 愁」中间空一格，副题用破折号夹住。
## 这种排法在剧本里是有意为之的（「春 愁」拆开两个字，慢下来），
## 用 `ch + chTitle` 拼出来的「序章 春愁」看着像文件名。
##
## 【停多久】
## 2.4 秒。短于 2 秒读不完六个字加一行副题；长于 3 秒玩家会去点鼠标，
## 而这时候点了没反应会显得游戏卡住 —— 所以卡片可以被点掉，但要停够。

signal finished

const HOLD := 2.4
const FADE_IN := 0.6
const FADE_OUT := 0.7

var _backdrop: ColorRect
var _num: Label
var _title: Label
var _sub: Label
var _rule_top: ColorRect
var _rule_bottom: ColorRect
var _tween: Tween
var _sticky := false
var _leaving := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_backdrop = ColorRect.new()
	_backdrop.color = Paper.NIGHT
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 20)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	_num = _label(24, Paper.INK_FAINT)
	col.add_child(_num)

	_rule_top = _rule()
	col.add_child(_rule_top)

	_title = _label(58, Paper.PAPER_LIGHT)
	col.add_child(_title)

	_rule_bottom = _rule()
	col.add_child(_rule_bottom)

	_sub = _label(22, Paper.GOLD)
	col.add_child(_sub)


func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	Paper.style_label(l, size, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 章名上下的两道细线。居中容器里要用「靠内容撑宽」的方式，
## 不然 ColorRect 会横贯整屏 —— 那是分隔线，不是装饰框。
func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(Paper.GOLD.r, Paper.GOLD.g, Paper.GOLD.b, 0.55)
	r.custom_minimum_size = Vector2(200, 1)
	r.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## card 是剧本场景里的那个字段：{num, title, sub}
##
## sticky = 不自动走。用在「试玩到此为止」那张收尾卡上 ——
## 那张卡是终点，让它 2.4 秒后自己消失，玩家会以为后面还有东西。
func present(card: Dictionary, sticky: bool = false) -> void:
	_num.text = str(card.get("num", ""))
	_title.text = str(card.get("title", ""))
	_sub.text = str(card.get("sub", ""))
	_sticky = sticky
	_leaving = false
	visible = true
	modulate.a = 0.0
	_play()


func _play() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, FADE_IN).set_trans(Tween.TRANS_SINE)
	if _sticky:
		return
	_tween.tween_interval(HOLD)
	_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT).set_trans(Tween.TRANS_SINE)
	_tween.finished.connect(_done)


func _done() -> void:
	if not visible:
		return
	visible = false
	finished.emit()


## 玩家点了一下 —— 不用等满 2.4 秒。但淡出还是要走完，
## 免得卡片「啪」地消失，像是切了张图。
##
## _leaving 这道闸是必须的：玩家会连点。每点一次都重新起一个 0.7 秒的淡出，
## 而 tween_property 是从**当前值**插到 0，所以连点等于每次都给淡出续命，
## 卡片会一直半透明地挂着不走。玩家看到的是「点了没反应」。
func skip() -> void:
	if not visible or _leaving:
		return
	_leaving = true
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT).set_trans(Tween.TRANS_SINE)
	_tween.finished.connect(_done)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		skip()
		accept_event()
