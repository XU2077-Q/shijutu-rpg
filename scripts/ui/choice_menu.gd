class_name ChoiceMenu
extends Control
## 选项菜单。
##
## 【为什么每个选项是「按钮里套一个会折行的标签」】
## Button 自己的 text 不折行。剧本里的选项有长到 24 个字的
## （「去杨椒山祠。举子们都在往那边去。」），字号 26 就要 620 px 宽，
## 屏幕窄一点就顶出去 —— 而**顶出去不报错**，只是字被切掉半截。
## 所以按钮的 text 留空，里面塞一个 autowrap 的 Label，宽度交给容器管。
##
## 【不能选的选项为什么还要显示】
## 原作里门槛是叙事的一部分：玩家看见「需要 沈怀瑾觉醒 ≥13」就知道
## 还有别的路。直接藏起来，玩家只会以为这游戏只有一条线。
## 藏掉门槛比亮出门槛更伤 —— 但**必须标清楚为什么不能点**，否则就是耍人。

signal chosen(index: int)

const BTN_W := 760
## 按钮内文字区宽度 = 按钮宽 - 两侧内边距（offsets left 28 / right 28）。
## autowrap 的 Label 必须给它一个**定宽**，它才知道自己该折成几行、
## 报多高的最小尺寸 —— 不给的话它按当前矩形（还可能是 0）算，量出来的高度是错的。
const INNER_W := BTN_W - 56

## 选项摆着的时候，空格一律吞掉，不许它落到按钮上。
##
## 【为什么非拦不可】
## 玩家是一路按空格把剧情推到这里的，一秒钟按四五下。
## 选项弹出来的那一刻，他手里那颗空格已经在半路上 ——
## 而 Button 一旦拿到焦点就会吃掉 ui_accept（**空格和回车都是它**），
## 于是第一颗选项被选中，剧情拐上一条支线，而他根本没看清有选项。
##
## 这不是设想：里程碑 5 的浏览器验收脚本按空格按到这儿，
## 一眨眼就演成了「去杨椒山祠」，而脚本从头到尾没打算选任何东西。
## 房间屏的 press() 里明明写着「空格落到这儿是界面的意思，不是推进」——
## 那句注释是对的，只是被按钮的焦点抢先接走了，压根没轮到它执行。
##
## 【试过但不管用的两条路，记下来免得再走】
##   · 把 grab_focus 推迟 0.4 秒。挡得住「弹出来那一下」，挡不住接着按 ——
##     玩家是按满几秒的，0.4 秒之后照样一颗一颗选过去。浏览器验收图证明过。
##   · 写 headless 用例断言「刚弹出来时没人拿焦点」。**它是绿的，
##     把补丁去掉还是绿的** —— headless 里引擎自己就把那次 grab_focus
##     推后了（实测落在 0.15~0.65 秒），正好盖住。那种用例比没有更坏。
##
## 【为什么在 _input 里拦得着】
## 顺序是死的：节点 _input → 视口的 GUI 处理（按钮就在这里吃 ui_accept）
## → _shortcut_input → _unhandled_input。
## 房间屏的 press() 排在最后，等轮到它，按钮早吃完了。
## 要拦按钮，只能抢在它前面 —— 就是这里。
##
## 【回车为什么还留着】
## 空格是「往下读」，回车是「选定」，两个意思该由两个键担。
## 鼠标点击本来就要瞄准，不受影响。真有人狂按回车，仍然会选掉第一项 ——
## 这是有意留的口子：回车是公认的确认键，夺走它反而更怪。
func _input(e: InputEvent) -> void:
	if not visible:
		return
	if e is InputEventKey:
		var k := e as InputEventKey
		if k.physical_keycode == KEY_SPACE and k.pressed and not k.echo:
			get_viewport().set_input_as_handled()

var _dim: ColorRect
var _prompt_box: PanelContainer
var _prompt: Label
var _list: VBoxContainer
var _buttons: Array[Button] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	_dim = ColorRect.new()
	_dim.color = Color(0.05, 0.04, 0.03, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 18)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	# PRESET_CENTER 让容器缩到最小尺寸并居中；宽度靠最小尺寸撑
	col.custom_minimum_size = Vector2(BTN_W, 0)

	_prompt_box = PanelContainer.new()
	_prompt_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_box.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_LIGHT))
	_prompt_box.visible = false
	col.add_child(_prompt_box)

	_prompt = Label.new()
	Paper.style_label(_prompt, 28, Paper.INK)
	_prompt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt.custom_minimum_size = Vector2(BTN_W - 56, 0)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_box.add_child(_prompt)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 14)
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_list)

	# 居中容器不知道自己该多大，所以每一帧把位置拉回屏幕中央
	resized.connect(_recenter)
	_recenter()


func _recenter() -> void:
	for c in get_children():
		if c is VBoxContainer:
			var v := c as VBoxContainer
			v.size = Vector2(BTN_W, v.get_combined_minimum_size().y)
			v.position = Vector2(
				(size.x - BTN_W) * 0.5,
				(size.y - v.size.y) * 0.5)


## options 是 BeatRunner.current_options() 给的那一份：
## [{index, text, hint, enabled, lock}, ...]
func present(prompt: String, options: Array) -> void:
	_clear()
	_prompt_box.visible = not prompt.strip_edges().is_empty()
	_prompt.text = prompt

	var first_enabled: Button = null
	for o in options:
		var b := _make_button(o)
		_list.add_child(b)
		_buttons.append(b)
		if bool(o["enabled"]) and first_enabled == null:
			first_enabled = b

	visible = true
	_recenter()
	if first_enabled != null:
		first_enabled.grab_focus()


func _make_button(o: Dictionary) -> Button:
	var enabled := bool(o["enabled"])

	var b := Button.new()
	b.text = ""
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(BTN_W, 0)
	b.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", _style(Paper.PAPER_LIGHT, Paper.PAPER_EDGE))
	b.add_theme_stylebox_override("hover", _style(Paper.PAPER, Paper.CINNABAR))
	b.add_theme_stylebox_override("pressed", _style(Paper.PAPER_DEEP, Paper.CINNABAR))
	b.add_theme_stylebox_override("focus", _style(Paper.PAPER, Paper.CINNABAR_HI))
	b.add_theme_stylebox_override("disabled", _style(Paper.PAPER_DEEP, Paper.PAPER_EDGE))
	b.pressed.connect(func() -> void: chosen.emit(int(o["index"])))

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 4)
	# 按钮的内边距是自己画的，子容器要躲开它
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 28
	col.offset_right = -28
	col.offset_top = 16
	col.offset_bottom = -16
	b.add_child(col)

	var t := Label.new()
	Paper.style_label(t, 26, Paper.INK if enabled else Paper.INK_FAINT)
	t.text = str(o["text"])
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(INNER_W, 0)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(t)

	# 副题：开着的时候是「选了会怎样」的暗示，锁着的时候是「为什么锁着」。
	# 两个都空就不占位 —— 空标签会白撑出一行高度。
	var sub := str(o["lock"]) if not enabled else str(o["hint"])
	if not sub.strip_edges().is_empty():
		var s := Label.new()
		Paper.style_label(s, 19, Paper.CINNABAR if not enabled else Paper.INK_FAINT)
		s.text = sub
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s.custom_minimum_size = Vector2(INNER_W, 0)
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(s)

	# 【按钮的高度必须自己算，而且要用字体量】
	# Button 不是容器 —— 它**不会**被子内容撑大，custom_minimum_size.y 给 0 的话，
	# 按钮就只剩样式盒上下内边距那 32px 高，里面的字垂直溢出框外
	# （Label 默认不裁剪，字画在框底下，截图里「字掉在按钮外面」就是它）。
	#
	# 【为什么不用 col.get_combined_minimum_size()】
	# 那条路在**树外**是死的：autowrap 的 Label 不进场景树就不成形，
	# 报出来的最小高度是 0 —— 按钮还是 32。这里用字体直接量：
	# 同一款字体、同一个宽度（INNER_W），量出来的折行高度跟真实渲染一致，
	# 在不在树上都是同一个数。几何的看守在 test_vn_screen.gd。
	var content := _text_height(t.text, 26)
	if not sub.strip_edges().is_empty():
		content += 4 + _text_height(sub, 19)   # 4 = col 的 separation
	b.custom_minimum_size = Vector2(BTN_W, content + 32)

	return b


func _text_height(text: String, font_size: int) -> float:
	var f := Paper.font()
	if f == null:
		# 字体都加载不出来的时候，游戏早就在 Boot 那屏停了 —— 这里只是兜底。
		return font_size * 1.5
	return f.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, INNER_W, font_size).y


func _style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := Paper.paper_box(bg, border, 2)
	s.content_margin_left = 28
	s.content_margin_right = 28
	s.content_margin_top = 16
	s.content_margin_bottom = 16
	return s


func _clear() -> void:
	for b in _buttons:
		b.queue_free()
	_buttons.clear()
	# queue_free 是延迟的，立刻重建会让新旧按钮同框一帧 —— 手动摘掉
	for c in _list.get_children():
		_list.remove_child(c)


func close() -> void:
	visible = false
	_clear()


## 给测试用：现在屏幕上有几个选项、哪个能点。
func described() -> Array:
	var out: Array = []
	for b in _buttons:
		var labels := b.find_children("*", "Label", true, false)
		var txt := ""
		for l in labels:
			txt = (l as Label).text
			break
		out.append({"text": txt, "enabled": not b.disabled})
	return out
