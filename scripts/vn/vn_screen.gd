extends Control
## 纯 VN 屏 —— 里程碑 3 的成品：切片不带房间、不带行走，一路读到底。
##
## 【它是「指挥」，不是「画师」】
## 这一屏只干一件事：把 BeatRunner 发出来的信号翻译成「该哪个部件上场了」。
## 所有画法都在各自的部件里（对话框、引文、书信、章节卡），
## 所以里程碑 4 加上房间和行走时，这一屏基本不用动 ——
## 房间只是把「advance()」换成「走到某个位置才 advance()」。
##
## 【模态为什么用队列而不是直接叠】
## BeatRunner 是同步的：进一个场景它会连着发 scene_entered 和 beat_entered。
## 而章节卡是压在节拍**上面**的 —— 卡还在演的时候，底下那句已经发过来了。
## 直接渲染的话，玩家会先看见字、再看见卡盖上去、卡走了字还在，
## 像是漏了一拍。所以模态开着的时候，节拍先存进 _pending，等卡走完再放。

const BG_DIR := "res://data/bg_placeholder/"   ## 背景还没生成，先留着位置

enum Modal { NONE, CARD, QUOTE, LETTER, CHOICE }

var _bg: ColorRect
var _vignette: TextureRect
var _place: PanelContainer
var _place_label: Label
var _portraits: PortraitLayer
var _box: DialogueBox
var _choices: ChoiceMenu
var _quote: QuoteView
var _letter: LetterView
var _card: ChapterCard
var _toast: PanelContainer
var _toast_label: Label
var _toast_tween: Tween

var _modal := Modal.NONE
var _pending: Array = []          ## 模态期间攒下的 [{bid, beat}]
var _run_over := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()

	BeatRunner.scene_entered.connect(_on_scene_entered)
	BeatRunner.beat_entered.connect(_on_beat_entered)
	BeatRunner.choice_presented.connect(_on_choice_presented)
	BeatRunner.run_finished.connect(_on_run_finished)

	# 自动开局。将来这一屏前面会有一张标题屏，那时改成由标题屏调 begin()。
	call_deferred("_begin")


func _begin() -> void:
	GameState.reset()
	_portraits.clear()
	_pending.clear()
	_run_over = false
	BeatRunner.begin()


# ============================================================
#  搭界面
# ============================================================

func _build() -> void:
	_bg = ColorRect.new()
	_bg.color = Paper.PAPER_DEEP
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_vignette = TextureRect.new()
	_vignette.texture = _vignette_texture()
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	_portraits = PortraitLayer.new()
	_portraits.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_portraits)

	# 点屏幕任意处推进。放在立绘之上、对话框之下 ——
	# 对话框自己是 MOUSE_FILTER_IGNORE，点击会穿到这一层。
	var click := Control.new()
	click.set_anchors_preset(Control.PRESET_FULL_RECT)
	click.mouse_filter = Control.MOUSE_FILTER_STOP
	click.gui_input.connect(_on_click)
	add_child(click)

	_place = PanelContainer.new()
	_place.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place.add_theme_stylebox_override("panel", Paper.translucent_paper(0.86))
	_place.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_place.offset_left = 40
	_place.offset_top = 32
	_place.offset_bottom = 88
	_place.offset_right = 560
	add_child(_place)

	_place_label = Label.new()
	Paper.style_label(_place_label, 21, Paper.INK_SOFT)
	_place_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_place.add_child(_place_label)

	_box = DialogueBox.new()
	add_child(_box)

	_choices = ChoiceMenu.new()
	_choices.chosen.connect(_on_chosen)
	add_child(_choices)

	_quote = QuoteView.new()
	_quote.dismissed.connect(_on_modal_closed)
	add_child(_quote)

	_letter = LetterView.new()
	_letter.dismissed.connect(_on_modal_closed)
	add_child(_letter)

	_card = ChapterCard.new()
	_card.finished.connect(_on_modal_closed)
	add_child(_card)

	_build_toast()


## 四角压暗。宣纸本身是平的，整屏一个色会显得像没画完；
## 压一圈暗角就有了「这是一页纸」的感觉，也让中间的字更聚。
func _vignette_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0, 0, 0, 0.30))
	g.add_point(0.55, Color(0, 0, 0, 0.04))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	return t


func _build_toast() -> void:
	_toast = PanelContainer.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.add_theme_stylebox_override("panel", Paper.paper_box(Paper.CINNABAR, Paper.CINNABAR_HI, 2))
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -260
	_toast.offset_right = 260
	_toast.offset_top = 40
	_toast.offset_bottom = 116
	_toast.modulate.a = 0.0
	add_child(_toast)

	_toast_label = Label.new()
	Paper.style_label(_toast_label, 24, Paper.PAPER_LIGHT)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast.add_child(_toast_label)


# ============================================================
#  BeatRunner 的信号
# ============================================================

func _on_scene_entered(_id: String, scene: Dictionary) -> void:
	_place_label.text = _place_text(scene)

	# 暗场（题记那一场）。底色调暗，四角压得更重 —— 那一场是梦里的话。
	var dark := bool(scene.get("dark", false))
	_bg.color = Paper.NIGHT if dark else Paper.PAPER_DEEP
	_vignette.modulate.a = 0.0 if dark else 1.0

	# 章节卡挂在**场景**上，不是挂在「章变了」上。
	# 序章的第一场是题记（p_intro），而序章卡挂在 p_tea 上 ——
	# 按「章变了」来放，卡就会在题记里先冒出来，那不对。
	if scene.has("card"):
		_modal = Modal.CARD
		_portraits.clear()
		_box.hide_box()
		_card.present(scene["card"])


func _on_beat_entered(bid: String, beat: Dictionary) -> void:
	if _modal != Modal.NONE:
		_pending.append({"bid": bid, "beat": beat})
		return
	_render_beat(bid, beat)


func _on_choice_presented(bid: String, beat: Dictionary) -> void:
	if _modal != Modal.NONE:
		_pending.append({"bid": bid, "beat": beat, "choice": true})
		return
	_render_choice(beat)


func _on_run_finished(reason: String) -> void:
	_run_over = true

	# 收场时还攒着拍 = 有内容被跳过了。这是**沉默的丢内容**，
	# 玩家不会知道自己少读了一段，所以不能默默清掉。
	if not _pending.is_empty():
		push_warning("[VNScreen] 收场时还攒着 %d 拍没放 —— 有内容被跳过了" % _pending.size())

	# 把模态收干净。切片最后一场的末拍常常是一条引文，
	# 不收的话结局卡会盖在一张还亮着的引文上面（卡是不透明的，看不见，
	# 但引文还占着模态，下一轮开局就乱套）。
	_quote.force_hide()
	_letter.force_hide()
	_choices.close()
	_box.hide_box()
	_modal = Modal.NONE

	match reason:
		"slice_end":
			_modal = Modal.CARD
			_portraits.clear()
			_card.present({
				"num": "垂 直 切 片",
				"title": "到 此 为 止",
				"sub": "—— 序章「春愁」与第一章「熊」已完成 ——",
			}, true)
		"no_next":
			# 走到剧本尽头却停在切片里 —— 说明导出器的 slice 和剧本对不上，
			# 是数据错，不是玩家走到了结局。别装作没事。
			push_error("[VNScreen] 剧本走完了但没到切片边界 —— 检查导出器的 SLICE 清单")
			_modal = Modal.CARD
			_card.present({"num": "", "title": "数据异常", "sub": "剧本走到尽头，但不是切片边界"}, true)
		_:
			push_warning("[VNScreen] 运行中断：%s" % reason)
			_modal = Modal.CARD
			_card.present({"num": "", "title": "中断", "sub": reason}, true)


# ============================================================
#  渲染
# ============================================================

func _render_beat(_bid: String, beat: Dictionary) -> void:
	match str(beat.get("t", "")):
		"n":
			_box.show_narration(str(beat.get("x", "")), bool(beat.get("emph", false)))
		"d":
			var who := str(beat.get("w", ""))
			_portraits.set_speaker(who)
			_box.show_speech(who, str(beat.get("r", "")), str(beat.get("x", "")),
				bool(beat.get("emph", false)))
		"q":
			_box.hide_box()
			_modal = Modal.QUOTE
			_quote.present(str(beat.get("x", "")), str(beat.get("src", "")))
		"letter":
			_box.hide_box()
			_modal = Modal.LETTER
			_letter.present(beat)
		"map":
			# 揭章：给一枚印章，再把那段话当重点旁白念出来。
			for id in beat.get("reveal", []):
				_toast_marker(str(id))
			_box.show_narration(str(beat.get("text", "")), true)
		_:
			push_warning("[VNScreen] 不认识的节拍类型：%s" % beat.get("t", ""))


func _render_choice(beat: Dictionary) -> void:
	_box.hide_box()
	_modal = Modal.CHOICE
	_choices.present(str(beat.get("prompt", "")), BeatRunner.current_options())


## 模态退场：把攒下的节拍接着放。
## **只放一个** —— 放完这个，后面可能又攒了新的（比如连着两张卡），
## 一次全倒出来会跳拍。
func _on_modal_closed() -> void:
	if _modal == Modal.NONE:
		return
	_modal = Modal.NONE
	if _pending.is_empty():
		return
	var item: Dictionary = _pending.pop_front()
	if bool(item.get("choice", false)):
		_render_choice(item["beat"])
	else:
		_render_beat(str(item["bid"]), item["beat"])


func _place_text(scene: Dictionary) -> String:
	var place := str(scene.get("place", ""))
	var date := str(scene.get("date", ""))
	if date.is_empty():
		return place
	if place.is_empty():
		return date
	return "%s　·　%s" % [place, date]


func _toast_marker(id: String) -> void:
	var name := id
	var glyph := ""
	for m in DataDB.markers:
		if str(m.get("id", "")) == id:
			name = str(m.get("name", id))
			glyph = str(m.get("glyph", ""))
			break
	_toast_label.text = "时局图 · 揭「%s」%s" % [glyph, name] if not glyph.is_empty() \
		else "时局图 · 揭「%s」" % name
	_toast.modulate.a = 0.0
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast, "modulate:a", 1.0, 0.3)
	_toast_tween.tween_interval(2.2)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.6)


# ============================================================
#  输入
# ============================================================

func _on_click(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		press()


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_advance") or e.is_action_pressed("interact"):
		press()
		get_viewport().set_input_as_handled()


## 一次「按下」在不同场合意思不同 —— 顺序不能乱：
## 模态优先，然后是打字机，最后才是推进。反过来会让模态被点掉的同时
## 底下那句也往前走一格，一次点击吃掉两句。
func press() -> void:
	if _run_over:
		return
	match _modal:
		Modal.CARD:
			_card.skip()
		Modal.QUOTE:
			_quote.dismiss()
		Modal.LETTER:
			_letter.dismiss()
		Modal.CHOICE:
			pass   # 选择必须点选项，点空白不算
		_:
			if _box.is_typing():
				_box.skip_typing()
			else:
				BeatRunner.advance()


func _on_chosen(index: int) -> void:
	if _modal != Modal.CHOICE:
		return
	_modal = Modal.NONE
	_choices.close()
	BeatRunner.choose(index)


# ============================================================
#  给测试看的
# ============================================================

func is_over() -> bool:
	return _run_over

func modal_name() -> String:
	return Modal.keys()[_modal]

## 攒了多少拍还没放。**这个数必须一直是 0 或很小** ——
## 它一直涨，说明模态退场时没把节拍接回去，游戏会安静地停在那儿。
func pending_count() -> int:
	return _pending.size()

func choices_open() -> bool:
	return _modal == Modal.CHOICE and _choices.visible

func choose(index: int) -> void:
	_on_chosen(index)

## 现在对话框里写着什么（含 BBCode）。测试拿它比对剧本原文。
func box_text() -> String:
	return _box.debug_text()

## 现在名条上写的是谁。
func box_speaker() -> String:
	return _box.debug_speaker()
