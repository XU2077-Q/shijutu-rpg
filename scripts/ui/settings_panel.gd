class_name SettingsPanel
extends Control
## 设置面板。标题屏那颗「设 置」弹出来的东西。
##
## 【切片阶段只有两项】
## 文字速度（打字机的每秒字数）和全屏。音量那格等真有了音频再加 ——
## 摆一个永远灰着的滑条，比没有更让人心慌。
##
## 【改了立刻生效、立刻落盘】
## AppSettings.set_cps / set_fullscreen 自己会写 ConfigFile。
## 面板只管把控件摆出来、把值读回来，不做第二份状态 ——
## 两份状态早晚会打架。

signal closed

var _cps_slider: HSlider
var _cps_value: Label
var _fs_check: CheckButton


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.03, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Paper.paper_box(Paper.PAPER_LIGHT, Paper.GOLD, 2))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(480, 0)
	add_child(panel)
	panel.resized.connect(func() -> void:
		panel.position = (size - panel.size) * 0.5)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	panel.add_child(col)

	var title := Label.new()
	Paper.style_label(title, 26, Paper.INK)
	title.text = "设 置"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	col.add_child(_row("文字速度", _build_cps()))
	col.add_child(_row("全屏显示", _build_fullscreen()))

	var close := Button.new()
	close.text = "关  闭"
	close.custom_minimum_size = Vector2(140, 44)
	close.focus_mode = Control.FOCUS_ALL
	close.add_theme_font_override("font", Paper.font())
	close.add_theme_font_size_override("font_size", 20)
	close.add_theme_color_override("font_color", Paper.CINNABAR)
	close.add_theme_color_override("font_hover_color", Paper.CINNABAR_HI)
	close.add_theme_stylebox_override("normal", Paper.paper_box(Paper.PAPER, Paper.PAPER_EDGE, 1))
	close.add_theme_stylebox_override("hover", Paper.paper_box(Paper.PAPER, Paper.CINNABAR, 1))
	close.pressed.connect(close_panel)
	var wrap := HBoxContainer.new()
	wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	wrap.add_child(close)
	col.add_child(wrap)


func _row(name: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	var l := Label.new()
	Paper.style_label(l, 20, Paper.INK_SOFT)
	l.text = name
	l.custom_minimum_size = Vector2(120, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	row.add_child(control)
	return row


func _build_cps() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)

	_cps_slider = HSlider.new()
	_cps_slider.min_value = AppSettings.CPS_MIN
	_cps_slider.max_value = AppSettings.CPS_MAX
	_cps_slider.step = 5.0
	_cps_slider.value = AppSettings.cps
	_cps_slider.custom_minimum_size = Vector2(200, 28)
	_cps_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cps_slider.value_changed.connect(func(v: float) -> void:
		AppSettings.set_cps(v)
		_cps_value.text = "%d 字/秒" % int(AppSettings.cps))
	box.add_child(_cps_slider)

	_cps_value = Label.new()
	Paper.style_label(_cps_value, 18, Paper.INK_SOFT)
	_cps_value.text = "%d 字/秒" % int(AppSettings.cps)
	_cps_value.custom_minimum_size = Vector2(88, 0)
	box.add_child(_cps_value)
	return box


func _build_fullscreen() -> Control:
	_fs_check = CheckButton.new()
	_fs_check.button_pressed = AppSettings.fullscreen
	_fs_check.toggled.connect(func(on: bool) -> void: AppSettings.set_fullscreen(on))
	return _fs_check


func open() -> void:
	# 打开时从 AppSettings 重读一遍 —— 面板藏着的这段时间里设置可能被别处改过。
	_cps_slider.set_value_no_signal(AppSettings.cps)
	_cps_value.text = "%d 字/秒" % int(AppSettings.cps)
	_fs_check.set_pressed_no_signal(AppSettings.fullscreen)
	visible = true


func close_panel() -> void:
	visible = false
	closed.emit()


func _input(e: InputEvent) -> void:
	# 跟其他暂停子面板一条规矩：Esc 关自己，回主面板。
	if visible and e.is_action_pressed("menu"):
		close_panel()
		get_viewport().set_input_as_handled()
