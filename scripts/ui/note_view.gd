class_name NoteView
extends Control
## 史实注。查一个物件，翻出一段真事。
##
## 【为什么它跟引文不是同一个部件】
## 引文（QuoteView）是**剧本的一部分** —— 原文里就有一段引文，它占一拍，
## 玩家读完，剧情往下走。史实注是**长在剧本外面的**：它不属于任何一拍，
## 玩家爱看不看，看完剧情原地不动。
## 混成一个部件的话，「读完要不要 advance()」这个判断会渗进每一个调用点。
##
## 【正文里的 [ref] 怎么处理】
## 52 条注里只有 2 条带 [ref]，形如 [ref]《马关条约》正文[/ref]，
## 意思是「这句出自哪儿」。直接当 BBCode 扔给 RichTextLabel 会炸
## （[ref] 不是标签），当纯文本又会把方括号显示给玩家。
## 所以在这里换成一行小字落款 —— 它本来就该长成落款的样子。

signal dismissed

const PANEL_MARGIN := 120.0

var _dim: ColorRect
var _panel: PanelContainer
var _chapter: Label
var _title: Label
var _body: RichTextLabel
var _hint: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()


func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.05, 0.04, 0.03, 0.62)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_LIGHT, Paper.PAPER_EDGE, 2))
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = PANEL_MARGIN
	_panel.offset_right = -PANEL_MARGIN
	_panel.offset_top = 76
	_panel.offset_bottom = -76
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(col)

	_chapter = Label.new()
	Paper.style_label(_chapter, 19, Paper.CINNABAR)
	col.add_child(_chapter)

	_title = Label.new()
	Paper.style_label(_title, 32, Paper.INK)
	col.add_child(_title)

	var rule := ColorRect.new()
	rule.color = Paper.PAPER_EDGE
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(rule)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Paper.style_rich(_body, 24, Paper.INK)
	_body.add_theme_constant_override("line_separation", 12)
	col.add_child(_body)

	_hint = Label.new()
	Paper.style_label(_hint, 18, Paper.INK_FAINT)
	_hint.text = "点击 / 空格 合上"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col.add_child(_hint)


## chapter 形如「序章」；title 是注的标题。
func present(chapter: String, title: String, body: String) -> void:
	_chapter.text = "史实注 · %s" % chapter
	_title.text = title
	_body.text = markup(body)
	_body.scroll_to_line(0)
	visible = true
	GameState.mark_codex(chapter, title)


## [ref]…[/ref] → 一行小字落款；其余方括号转义成 [lb]，免得被当成 BBCode 吃掉。
##
## 【顺序：转义只许作用在**原文**上，不许碰自己拼进去的标签】
## 上一版是「拼完再 out.replace("[", "[lb]")」，于是落款那对
## [color=…][font_size=…] 也被一起转义了 —— 玩家读到的是一行
##   [color=#8d7c5c][font_size=19]　　—— 《马关条约》正文[/font_size][/color]
## 方括号明晃晃地印在史实注正文里。
##
## 【为什么它藏了这么久】52 条注里只有 2 条带 [ref]，而带 [ref] 的那两条
## 恰好是茶盏和告示墙。浏览器自查原来那两下点击都没落到热点上，
## 于是这两条注从来没被翻开过。是修好点击坐标之后才露出来的 ——
## 「点了个寂寞」和「翻出来是乱码」，前一个把后一个挡住了。
static func markup(text: String) -> String:
	var out := ""
	var rest := text
	while true:
		var a := rest.find("[ref]")
		if a < 0:
			out += _esc(rest)
			break
		var b := rest.find("[/ref]", a)
		if b < 0:
			out += _esc(rest)
			break
		out += _esc(rest.substr(0, a))
		var src := rest.substr(a + 5, b - a - 5)
		out += "\n[color=#8d7c5c][font_size=19]　　—— %s[/font_size][/color]" % _esc(src)
		rest = rest.substr(b + 6)
	return out


## 原文里的方括号一律转义。不转义的话，正文里随便一个 [ 都会被
## RichTextLabel 当成标签的开头 —— 轻则吃掉后面几个字，重则整段不显示。
static func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func dismiss() -> void:
	if not visible:
		return
	visible = false
	dismissed.emit()


func force_hide() -> void:
	visible = false


func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	if e.is_action_pressed("ui_advance") or e.is_action_pressed("interact"):
		dismiss()
		get_viewport().set_input_as_handled()


func _gui_input(e: InputEvent) -> void:
	if visible and e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		dismiss()
		accept_event()


# ---------------------- 给测试看的 ----------------------

func shown_title() -> String:
	return _title.text

func shown_text() -> String:
	return _body.text


## **玩家实际读到的那段字** —— 走 RichTextLabel 自己的解析，不是我们猜的。
##
## 【为什么非要有这个，光看 _body.text 不够】
## markup() 出过两次方向相反的错，而两种错在标记字符串里长得都很正常：
##   漏转义：正文里的 [ 没转 → RichTextLabel 把它当标签吃掉一段字；
##   多转义：我们自己插的 [color=…] 被转了 → 玩家读到一行 [color=…] 的字面量。
## 第二种在 _body.text 里是 `[lb]color=#8d7c5c]` —— **看着完全合法**，
## 任何「扫方括号」的检查都会放它过去。只有解析之后才现原形。
## 所以判据只能落在这儿：解析完还带着 [color= 的，一定是漏给了玩家。
func shown_plain() -> String:
	return _body.get_parsed_text()
