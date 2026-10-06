class_name RoomView
extends Control
## 房间屏 —— 里程碑 5 的成品：脊梁在房间里演，玩家在房间里走。
##
## 【它与 VN 屏的分工】
## VN 屏是里程碑 3 留下的**线性回退**：从头按到底，没有房间、没有走动。
## 房间屏才是这款游戏的正身 —— 剧情在房间里演，演完放玩家走走。
## 两边共用对话框、立绘层、史实注，但**走的不是同一条路**：
## VN 屏是 I6 的验证预言机（vn_mode，见 beat_runner.gd），
## 房间屏是 spine_mode。两条路都必须留着，理由在下面。
##
## 【「读一场 → 走一段」这个节奏是怎么定下来的】
## 试过两种别的走法，都不行：
##
##   一是「拍一层路由」——把连续的旁白切成调查点。真拿 c1_shanghai 对了一遍，
##   那是 22 拍连着的散文，从十六铺码头一路写到「原来中国人，可以这样跟洋人说话」。
##   切开就是把它剁成七八段。原文是这部作品的本体，动不得（见 story_map.json）。
##
##   二是「边走边演」——剧情一直往前推，玩家随时能走。听着最 RPG，
##   但对话框只有一个：玩家一走开，读到哪儿、剧情推到哪儿，两件事立刻打架，
##   而且打完架没有一处代码能说清是谁的错。
##
## 所以定成现在这样：**一场戏演完就停住（BeatRunner.pause_between_scenes），
## 玩家在房间里走、查物件、跟人说话，走到下一场戏所在的那间房，剧情自动接上。**
## 两个模式轮流占用屏幕，谁都不用去抢对方的对话框 ——
## 这条边界正是「互不知道对方存在」那句话的落地方式。
##
## 【玩家走错了房间怎么办】
## 什么也不发生。查物件、走回头路，都不动剧情游标 ——
## 下一场戏在哪间房等着，是 story_map 说了算的，玩家走到那儿才接上。
## 这就是 rooms.json 里那些闲笔敢不锁出口的底气。
##
## 【点一下就自动走过去，为什么要这样】
## 玩家点一个物件，心里想的是「我要看那个」，不是「我要走到那儿，然后再按一下」。
## 所以点到物件 = 走过去 + 到了自动开口。点到空地才是单纯地走过去。
## 这一条是 To the Moon 的手感，也是这部作品该有的节奏 —— 别让人按两次。
##
## 【背景还没有图怎么办】
## 十二张背景要等方舟出图（ARK_API_KEY 还没填）。缺图时这里画一块占位，
## **并且把可走区、障碍物、热点都画出来** —— 没有背景的房间里，
## 光看一片素色是看不出「哪儿能走、哪儿有东西」的。
## 图一到位，这层示意自己就退场了（见 _debug_visible）。

const ROOM_SCENE := "res://scenes/world/room.tscn"
const TITLE_SCENE := "res://scenes/title/title.tscn"

## 从脚到物件矩形，够得着的距离（像素）。
## 96 ≈ 小人往前走半步。太小会「明明站在旁边却按不动」，
## 太大会隔着大半间房把东西吸过来 —— 两种都比看着像坏了。
const REACH := 96.0

var _room_id := ""
var _room: Dictionary = {}

var _grid: NavGrid
var _walker: Walker
var _bg: TextureRect
var _placeholder: Control
var _place: PanelContainer
var _place_label: Label
var _prompt: PanelContainer
var _prompt_label: Label
var _box: DialogueBox
var _portraits: PortraitLayer
var _note: NoteView
var _hint: Label
var _choices: ChoiceMenu
var _card: ChapterCard
var _pause: PauseMenu
var _quest: QuestBar
var _fail: Label
var _fail_tween: Tween

## 呈现层的暗场。没有房间的那几场（题记 / 书信 / 林婉如视角 / 尾声）
## 就压在这块底色上演 —— 它们不属于沈怀瑾走过的任何一个地方。
var _present: ColorRect

## 热点：[{data, rect(像素), stand(像素)}]。每次尺寸变化重算。
var _spots: Array = []
var _focus := -1
var _bg_exists := false

## 点了一个物件，走过去之后要自动开口
var _walking_to := -1

## 正在播的一段扩写
var _queue: Array = []
var _qi := 0

## 屏上正压着一段东西，玩家不能走。**两种**东西都会把它点亮：
##   · 脊梁的一场戏（推进器在推，press() 该调 BeatRunner.advance()）
##   · 玩家查来的一段扩写（_queue 在翻，press() 该调 _qi += 1）
## 走路、焦点、提示条只关心「能不能动」，不关心是哪种，所以共用这一个。
var _playing := false

## 在播的那一段是**扩写**，不是脊梁。
##
## 【为什么非得分出来】
## 里程碑 5 之前 `_playing` 只有扩写一种来源，press() 里 `if _playing: _qi += 1`
## 就是对的。脊梁接上之后，进一场戏也会把 `_playing` 点亮 —— 于是
## press() 被 `if _spine` 那条分支抢先接走，去调 BeatRunner.advance()。
## 而玩家查东西的时候，推进器正停在场景缝里（_paused），advance() 是个空操作。
##
## 结果：**在房间里跟顺子说话，第一句永远翻不过去。**
## 而 milestone 4 那条自由走动路径（_spine 为假）照旧能翻，
## 所以老用例一条都不红 —— 只有真的在脊梁上跟 NPC 说一次话才看得见。
var _expansion := false

## 正在播的是哪一段。_show_current 报错时要指名道姓 ——
## 它自己拿不到场景 id（那是 _play_scene 的入参），所以存在这儿。
var _scene_id := ""

# ---------------------- 脊梁模式 ----------------------

## 这一屏是「在演剧情」还是「在放玩家乱走」。
## 关掉它，本屏就是里程碑 4 那套纯调查层（测试里两种都要跑）。
var _spine := false
## 这一场戏的 id。停在缝里的时候 BeatRunner.scene_id 还是它，但别处不该去读
## 推进器的内部状态 —— 存一份，房间层自己说的话自己负责。
var _spine_scene := ""
## 停在缝里时，下一场戏是哪一场。空串 = 没在缝里。
##
## 【为什么在这儿算一次，而不是等 resume_next 时问推进器】
## 玩家得**先知道该往哪儿走**。而 resume_next() 一调，推进器就迈过去了 ——
## 那时候再问「下一场在哪间房」已经晚了一步，玩家看到的是
## 「我还没走，剧情自己跑了」。所以停在缝里的时候就把下一场定下来，
## 写进提示条，等玩家走到那间房再放行。
var _next_spine := ""

## 现在这张卡是不是**这一局的收尾卡**。章节卡退场什么都不做，
## 收尾卡退场回标题屏 —— 两者的 finished 信号长得一模一样。
var _card_ends_run := false

var _debug := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	resized.connect(_relayout)
	call_deferred("_enter_from_settings")


func _enter_from_settings() -> void:
	# 「走 动」那颗按钮走的是脊梁：剧情游标从 p_intro 起，房间跟着剧情换。
	# 里程碑 4 那套「直接丢进一间空房乱走」的路留着 —— 调试和测试都要用。
	if AppSettings.pending_spine:
		var resume := AppSettings.pending_resume
		AppSettings.pending_spine = false
		AppSettings.pending_resume = false
		AppSettings.pending_room = ""
		AppSettings.pending_at = Vector2.INF
		begin_spine(resume)
		return

	var id := AppSettings.pending_room
	AppSettings.pending_room = ""
	if id.is_empty():
		id = GameState.room if DataDB.has_room(GameState.room) else DataDB.room_start
	if id.is_empty():
		push_error("[RoomView] 没有可进的房间 —— rooms.json 的 start 是空的")
		return
	enter(id, AppSettings.pending_at)
	AppSettings.pending_at = Vector2.INF


# ============================================================
#  脊梁
# ============================================================
#
# 【谁拿着剧情游标】
# BeatRunner。房间屏一根手指都不碰 GameState.scene/idx ——
# 它只做两件事：把推进器送来的拍子画出来，以及把玩家走到的地方告诉它。
#
# 【为什么不用 _queue 自己播脊梁】
# _queue 那套是给扩写用的：只播不推。要是拿它播脊梁，条件过滤、supersede
# 顶替、选项的 gain/flag 全得在房间屏里再写一遍 —— 两处各写一遍的
# 剧情逻辑，迟早会有一处跟另一处不一样，而且不会报错。

func begin_spine(resume := false) -> void:
	_spine = true
	_next_spine = ""
	_spine_scene = ""

	BeatRunner.stop()
	BeatRunner.slice_only = true
	BeatRunner.vn_mode = false
	BeatRunner.spine_mode = true
	BeatRunner.pause_between_scenes = true

	BeatRunner.scene_entered.connect(_on_spine_scene_entered)
	BeatRunner.beat_entered.connect(_on_spine_beat)
	BeatRunner.choice_presented.connect(_on_spine_choice)
	BeatRunner.scene_finished.connect(_on_spine_scene_finished)
	BeatRunner.run_finished.connect(_on_spine_run_finished)

	# 读档续播：书签在 GameState（SaveManager.load_slot 已灌回）。
	# 从头演：spine_start。
	if resume:
		BeatRunner.resume(GameState.scene, GameState.idx)
	else:
		BeatRunner.begin(DataDB.spine_start())


func _on_spine_scene_entered(id: String, scene: Dictionary) -> void:
	_spine_scene = id
	# 下一场已经落地了，缝里那条提示作废。
	_next_spine = ""

	var room := DataDB.room_for_scene(id)
	if room.is_empty():
		_set_presentation(true)
	else:
		_set_presentation(false)
		if room != _room_id:
			# 续播时把小人放回存档里的位置；新戏（无位置）走房间 spawn。
			var at := GameState.player_pos if GameState.player_pos != Vector2.ZERO else Vector2.INF
			enter(room, at)
	_place_label.text = _spine_place_text(scene)

	# 章节卡挂在**场景**上（序章卡挂在 p_tea，不是挂在 p_intro 上）。
	# 房间屏原本漏了这一条，而 VN 屏有 —— 同一个序章，两条路一个看得到卡、
	# 一个看不到。卡不占拍子（它是盖在对话框上的一层，退场后第一拍还在），
	# 所以这里补上不会打乱节奏。
	if scene.has("card"):
		_card_ends_run = false
		_portraits.clear()
		_card.present(scene["card"])

	_playing = true
	_prompt.visible = false
	_update_hint()
	_quest.refresh()
	SaveManager.autosave()


func _on_spine_beat(_bid: String, beat: Dictionary) -> void:
	_render(beat, true)


func _on_spine_choice(_bid: String, beat: Dictionary) -> void:
	_render(beat, true)
	# 提示条要改口（见 _update_hint 里那条）：这会儿空格是哑的，
	# 不能还写着「空格 继续」。
	_update_hint()
	# 选项正摆着的那一刻落一次档（与 VN 屏同一条规矩）：续玩回到选择现场。
	SaveManager.autosave()


func _on_choice_made(index: int) -> void:
	_choices.close()
	BeatRunner.choose(index)


## 一场戏的拍子播完了。停在缝里，让玩家走一段。
func _on_spine_scene_finished(id: String) -> void:
	_playing = false
	_box.hide_box()
	_choices.close()

	_next_spine = DataDB.spine_step(id)
	var room := DataDB.room_for_scene(_next_spine)

	# 没地方可走就直接接着演：同房连播、呈现层（它没有房间）、
	# 以及开局（玩家还没有任何房间可站）。这三种情况要是也停下来，
	# 玩家会卡在一个走不到任何地方的缝里 —— 没有出口能让他「走到」下一场。
	if _next_spine.is_empty() or room.is_empty() or room == _room_id or _room_id.is_empty():
		_resume_spine()
		return

	# 真停在缝里了：对话框已收，最后一句说话人的立绘也得撤 ——
	# 不然自由走动时一个等身大人像会一直杵在房间左边。
	_portraits.clear()
	_update_hint()


func _resume_spine() -> void:
	_next_spine = ""
	BeatRunner.resume_next()


func _on_spine_run_finished(reason: String) -> void:
	_playing = false
	_next_spine = ""
	_choices.close()
	_box.hide_box()
	_prompt.visible = false
	_update_hint()

	# 这里出现的卡**一律**是收尾卡（章节卡只在进场景时放，不走这条路）。
	_card_ends_run = true
	match reason:
		"slice_end":
			_set_presentation(true)
			_card.present({
				"num": "垂 直 切 片",
				"title": "到 此 为 止",
				"sub": "—— 序章「春愁」与第一章「熊」已完成 ——",
			}, true)
		"no_next":
			# 脊梁走到头却不是切片边界 —— 是数据错，不是玩家走到了结局。
			push_error("[RoomView] 脊梁走完了但没到切片边界 —— 检查 story_map 的 spine")
			_set_presentation(true)
			_card.present({"num": "", "title": "数据异常", "sub": "脊梁走到尽头，但不是切片边界"}, true)
		_:
			push_warning("[RoomView] 脊梁中断：%s" % reason)
			_set_presentation(true)
			_card.present({"num": "", "title": "中断", "sub": reason}, true)


## 卡退场了。
##
## 【为什么要有 _card_ends_run 这道闸】
## 章节卡（序章「春愁」那张）也会发 finished —— 非 sticky 的卡 2.4 秒后
## 自己淡出。不区分的话，一进茶楼就被那张卡**送回标题屏**，
## 而画面上看起来只是「卡闪了一下，游戏没了」。
func _on_card_closed() -> void:
	if not _card_ends_run:
		return
	# 收尾卡点掉 → 回标题。这一局到此为止，玩家能看见自己走到了哪儿。
	get_tree().change_scene_to_file(TITLE_SCENE)


## 呈现层开合。没有房间的那几场压在一块暗底上演，
## 背景、小人、提示条一起收起来 —— 不是「盖住了」，是「换了个地方」。
func _set_presentation(on: bool) -> void:
	_present.visible = on
	_walker.visible = not on
	_hint.visible = not on
	if on:
		_bg.visible = false
		_placeholder.visible = false
		_prompt.visible = false
		return
	_bg.visible = _bg_exists
	_placeholder.visible = not _bg_exists


func _spine_place_text(scene: Dictionary) -> String:
	var place := str(scene.get("place", ""))
	var date := str(scene.get("date", ""))
	if not place.is_empty() and not date.is_empty():
		return "%s　·　%s" % [place, date]
	if not place.is_empty():
		return place
	if not date.is_empty():
		return date
	return _place_text()


func _update_hint() -> void:
	if not _spine:
		return
	if _card.visible:
		_hint.text = "空格 / 点击 收起"
		return
	# 选项摆着的时候不能写「空格 继续」—— 空格这会儿是**哑的**
	# （ChoiceMenu._input 把它吞了，见那边的说明）。写着能按却按不动，
	# 玩家只会以为卡住了。
	if _choices.visible:
		_hint.text = "点选项 · 或按 ↑↓ 选、回车定 · Esc 暂停"
		return
	if _playing:
		_hint.text = "空格 继续 · Esc 暂停"
		return
	if not _next_spine.is_empty():
		_hint.text = "剧情在「%s」· 走到那间房就接着演 · WASD 或点地上走" % _room_name_of(_next_spine)
		return
	_hint.text = "点地上走过去 · WASD 也能走 · 空格 查看 / 交谈 · Esc 暂停"


func _room_name_of(scene_id: String) -> String:
	var r := DataDB.room_for_scene(scene_id)
	if r.is_empty():
		return "别处"
	if not DataDB.has_room(r):
		return r
	return str(DataDB.room(r).get("name", r))


# ============================================================
#  搭界面
# ============================================================

func _build() -> void:
	# 呈现层的暗场。挂在**最底下**，但初始不可见；_set_presentation(true) 时
	# 把背景/占位/小人/提示一起藏起来，只剩它 —— 于是它看起来像是
	# 「换了个地方」，而不是「背景图上盖了块布」。
	_present = ColorRect.new()
	_present.color = Paper.NIGHT
	_present.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_present.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_present.visible = false
	add_child(_present)

	_bg = TextureRect.new()
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_placeholder = _build_placeholder()
	add_child(_placeholder)

	# 可走区 / 障碍物 / 热点的示意。画在背景之上、小人之下。
	var overlay := Control.new()
	overlay.name = "_overlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay.bind(overlay))
	add_child(overlay)

	_walker = Walker.new()
	add_child(_walker)

	_portraits = PortraitLayer.new()
	_portraits.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_portraits)

	_place = PanelContainer.new()
	_place.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place.add_theme_stylebox_override("panel", Paper.translucent_paper(0.86))
	# 右上角：左上角是任务条的地盘。居中试过 —— 牌牌左半截被后画的任务条
	# 压住（浏览器自查截图里「北京」两个字整段消失）。右上离任务条最远，
	# 也是地点牌常见的位置。宽 560 容得下最长的「北京·宣武门外·广和茶楼　·
	# 　光绪二十一年三月廿三」。
	_place.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_place.offset_left = -588
	_place.offset_top = 26
	_place.offset_bottom = 74
	_place.offset_right = -28
	add_child(_place)

	_place_label = Label.new()
	Paper.style_label(_place_label, 21, Paper.INK_SOFT)
	_place_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_place.add_child(_place_label)

	_prompt = PanelContainer.new()
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.add_theme_stylebox_override("panel", Paper.paper_box(Paper.CINNABAR, Paper.CINNABAR_HI, 2))
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.offset_left = -220
	_prompt.offset_right = 220
	_prompt.offset_top = -252
	_prompt.offset_bottom = -188
	_prompt.visible = false
	add_child(_prompt)

	_prompt_label = Label.new()
	Paper.style_label(_prompt_label, 22, Paper.PAPER_LIGHT)
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt.add_child(_prompt_label)

	# 小人可能站在对话框正背后：半透明纸会把像素小人透成鬼影，这里用不透明纸。
	# 注意次序：set_opaque_paper 改的是 _build_box() 里建的内层面板，
	# 那层在 _ready() 里才出生 —— add_child 之前调等于打在 null 上
	# （浏览器发行版里直接踩成 wasm「memory access out of bounds」）。
	_box = DialogueBox.new()
	add_child(_box)
	_box.set_opaque_paper()

	_note = NoteView.new()
	add_child(_note)

	# 选项。三个选择场景（p_choice1 / c1_choice / c1_draft）都在房间里演，
	# 所以房间屏必须自己有一套 —— 不能指望「碰到选择就切去 VN 屏」：
	# 那会把玩家从他正站着的房间一脚踢出去，回来时人还站在原地，
	# 而中间发生的事全在一张黑屏上。用 VN 屏现成的那一个，行为也一致。
	_choices = ChoiceMenu.new()
	_choices.chosen.connect(_on_choice_made)
	add_child(_choices)

	_card = ChapterCard.new()
	add_child(_card)
	_card.finished.connect(_on_card_closed)

	# 走动提示。切片阶段玩家不知道能点能走，给一行小字。
	#
	# 【为什么留 20 px 下边距、还加了投影】
	# 原来写的是 -44/-16（离底 16 px）。导 Web 一看：可走多边形的下沿
	# （rooms.json 里 y=0.95 那条线）正好从这行字上穿过去，字压在线里，
	# 看着像被屏幕底边切了一半。屏幕并没有切它 —— 是它贴着边、又压着一条线。
	# 所以往上抬 20 px，再给一层深色投影：背景图一到位，这行字要压在
	# 任意明暗的图画上，光靠一个浅墨色是读不清的。
	_hint = Label.new()
	Paper.style_label(_hint, 18, Paper.INK_FAINT)
	_hint.text = "点地上走过去 · WASD 也能走 · 空格 查看 / 交谈 · Esc 暂停"
	_hint.add_theme_color_override("font_shadow_color", Color(0.98, 0.94, 0.87, 0.85))
	_hint.add_theme_constant_override("shadow_offset_x", 1)
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = 40
	_hint.offset_top = -64
	_hint.offset_bottom = -20
	_hint.offset_right = 900
	add_child(_hint)

	# 任务条。放在房间层，呈现层（暗场）时也保留 —— 题记那场也有任务。
	_quest = QuestBar.new()
	add_child(_quest)
	_quest.refresh()

	# 空格按空时的提示。自由走动、附近没有热点时 press() 原本是静默的，
	# 玩家只会觉得「空格坏了」。给一句话，让这个按键有个看得见的下落。
	_fail = Label.new()
	Paper.style_label(_fail, 20, Paper.INK_SOFT)
	_fail.text = ""
	_fail.add_theme_color_override("font_shadow_color", Color(0.98, 0.94, 0.87, 0.85))
	_fail.add_theme_constant_override("shadow_offset_x", 1)
	_fail.add_theme_constant_override("shadow_offset_y", 1)
	_fail.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_fail.offset_left = -300
	_fail.offset_right = 300
	_fail.offset_top = -330
	_fail.offset_bottom = -286
	_fail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fail.modulate.a = 0.0
	add_child(_fail)

	# 暂停菜单放最后，最上层。
	_pause = PauseMenu.new()
	add_child(_pause)
	_pause.title_requested.connect(func() -> void:
		get_tree().change_scene_to_file(TITLE_SCENE))


## 空格落了空：把一句提示闪一下。
func say_fail(text: String) -> void:
	_fail.text = text
	_fail.modulate.a = 1.0
	if _fail_tween != null and _fail_tween.is_valid():
		_fail_tween.kill()
	_fail_tween = create_tween()
	_fail_tween.tween_interval(1.0)
	_fail_tween.tween_property(_fail, "modulate:a", 0.0, 0.5)


func _build_placeholder() -> Control:
	var c := Control.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var base := ColorRect.new()
	base.color = Paper.PAPER_DEEP
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(base)

	# 一道浅浅的地平线。素色一片会让人分不清「远处」和「脚下」，
	# 有了这条线，可走区画在哪儿就一眼看得懂。
	var floor := ColorRect.new()
	floor.color = Color(Paper.PAPER_EDGE.r, Paper.PAPER_EDGE.g, Paper.PAPER_EDGE.b, 0.35)
	floor.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	floor.offset_top = -0.62 * 720.0
	floor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(floor)

	var name_label := Label.new()
	Paper.style_label(name_label, 46, Color(Paper.INK_SOFT.r, Paper.INK_SOFT.g, Paper.INK_SOFT.b, 0.22))
	name_label.name = "_pname"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	name_label.offset_left = -420
	name_label.offset_right = 420
	name_label.offset_top = 120
	name_label.offset_bottom = 210
	c.add_child(name_label)

	var note := Label.new()
	Paper.style_label(note, 17, Color(Paper.INK_FAINT.r, Paper.INK_FAINT.g, Paper.INK_FAINT.b, 0.7))
	note.name = "_pnote"
	note.text = "背景待生成 · 填好 .env 里的 ARK_API_KEY 后跑 node tools/gen_art.js"
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	note.offset_left = -420
	note.offset_right = 420
	note.offset_top = 216
	note.offset_bottom = 250
	c.add_child(note)
	return c


# ============================================================
#  进房间
# ============================================================

func enter(id: String, at: Vector2 = Vector2.INF) -> void:
	if not DataDB.has_room(id):
		push_error("[RoomView] 没有这间房：%s" % id)
		return
	_room_id = id
	_room = DataDB.room(id)
	GameState.room = id

	_place_label.text = _place_text()

	# 背景。文件在就画，不在就退回占位 + 示意层。
	_bg_exists = ResourceLoader.exists(str(_room.get("bg", "")))
	if _bg_exists:
		_bg.texture = load(str(_room["bg"]))
		_bg.visible = true
	else:
		_bg.texture = null
		_bg.visible = false
		var nm: Label = _placeholder.get_node("_pname")
		nm.text = str(_room.get("name", id))
	_placeholder.visible = not _bg_exists

	_playing = false
	_expansion = false
	_queue.clear()
	_qi = 0
	_box.hide_box()
	_note.force_hide()
	_portraits.clear()

	_relayout()

	var spawn := at
	if spawn == Vector2.INF:
		spawn = _norm_to_px(_room.get("spawn", [0.5, 0.5]))
	_walker.setup(_walker_prefix(), _grid)
	# 续播的位置可能被旧墙/边界夹住（窗口比例变了），站不进去就退回 spawn。
	if not _grid.is_walkable(spawn):
		spawn = _norm_to_px(_room.get("spawn", [0.5, 0.5]))
	_walker.set_foot(spawn)
	_walker.stop()
	_refresh_focus()
	_quest.refresh()

	SaveManager.autosave()

	# 走到了「下一场戏所在的那间房」= 剧情接上。
	#
	# 【判据为什么是「房间对不对」，不是「玩家走了哪条出口」】
	# 出口是空间的事，剧情是叙事的事，story_map 把两者接在一起靠的就是
	# room_for_scene 这一张对照表。按出口判的话，同一间房多开一条路
	# （比如将来加一扇侧门）就得记得改两处。
	#
	# 放最后：_resume_spine 会一路推下去、可能又进一次 enter()，
	# 前面那些收尾得先做完。
	if _spine and not _next_spine.is_empty() and DataDB.room_for_scene(_next_spine) == id:
		_resume_spine()


func _walker_prefix() -> String:
	# 切片只有沈怀瑾一个人可操作。林婉如的行走图已经出好了，
	# 等第一章她出场、需要玩家操作她的时候，把这里换成按剧情取人即可。
	var p := Cast.walker_prefix("沈怀瑾")
	return p if not p.is_empty() else "shen"


func _place_text() -> String:
	var place := str(_room.get("place", ""))
	var sub := str(_room.get("sub", ""))
	if sub.is_empty():
		return place
	return "%s　·　%s" % [place, sub]


## 尺寸变了就重算：格子图、热点矩形、小人位置的比例。
## 归一化的坐标只有在这里才变成像素 —— 只此一处，别处一律用像素。
func _relayout() -> void:
	if size.x < 4.0 or size.y < 4.0:
		return
	_grid = NavGrid.new()
	_grid.build(_walk_px(), _blockers_px(), size)
	_spots.clear()
	for o in _room.get("objects", []):
		if not (o is Dictionary):
			continue
		var r := _norm_rect_to_px(o.get("rect", []))
		_spots.append({
			"data": o,
			"rect": r,
			"stand": Walker.stand_point(r),
		})
	if _walker != null:
		_walker.set_grid(_grid)
		# 窗口变了，人可能被甩到墙外去。夹回可走区里。
		if not _grid.is_walkable(_walker.foot()):
			_walker.set_foot(_norm_to_px(_room.get("spawn", [0.5, 0.5])))
		_refresh_focus()
	_overlay_redraw()


func _overlay_redraw() -> void:
	var ov := get_node_or_null("_overlay")
	if ov != null:
		(ov as Control).queue_redraw()


# ---------------------- 归一化 → 像素 ----------------------

func _norm_to_px(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() == 2:
		return Vector2(float(v[0]) * size.x, float(v[1]) * size.y)
	return size * 0.5


func _norm_rect_to_px(v: Variant) -> Rect2:
	if v is Array and (v as Array).size() == 4:
		return Rect2(
			float(v[0]) * size.x, float(v[1]) * size.y,
			float(v[2]) * size.x, float(v[3]) * size.y)
	return Rect2()


func _walk_px() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _room.get("walk", []):
		if p is Array and (p as Array).size() == 2:
			out.append(_norm_to_px(p))
	return out


func _blockers_px() -> Array:
	var out: Array = []
	for b in _room.get("blockers", []):
		if b is Dictionary:
			out.append(_norm_rect_to_px(b.get("rect", [])))
	return out


# 站位点用 Walker.stand_point —— 这里曾经自己算过一份（+34 而不是 +28）。
# 两份差 6 px 的「同一件事」，正是那种「热点画在 A、人走到 B」的隐患：
# 画面上看不出，只有站过去才发现够不着。一份就够。


# ============================================================
#  输入
# ============================================================

func _unhandled_input(e: InputEvent) -> void:
	# 暂停菜单开着，游戏不接键。
	if _pause.is_open():
		return
	if _note.visible:
		if e.is_action_pressed("ui_advance") or e.is_action_pressed("interact"):
			_note.dismiss()
			get_viewport().set_input_as_handled()
		return
	if e.is_action_pressed("menu"):
		# 收尾卡（垂直切片到此为止）不弹暂停 —— 它自己就是这一局的终点。
		if _card.visible and _card_ends_run:
			return
		get_viewport().set_input_as_handled()
		_walker.stop()
		_pause.open()
		return
	if e is InputEventKey and (e as InputEventKey).pressed \
			and (e as InputEventKey).keycode == KEY_F1:
		_debug = not _debug
		_overlay_redraw()
		get_viewport().set_input_as_handled()
		return
	if e.is_action_pressed("ui_advance") or e.is_action_pressed("interact"):
		press()
		get_viewport().set_input_as_handled()


func _gui_input(e: InputEvent) -> void:
	if not (e is InputEventMouseButton) or not (e as InputEventMouseButton).pressed:
		return
	if (e as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return
	if _note.visible or _playing:
		press()
		accept_event()
		return
	var p: Vector2 = (e as InputEventMouseButton).position
	# 点到物件上 → 走过去 + 到了自动开口。点到空地 → 单纯走过去。
	var hit := _spot_at(p)
	if hit >= 0:
		_walk_to_spot(hit)
	else:
		_walker.walk_to(_grid.path(_walker.foot(), p))
		_walking_to = -1
	accept_event()


## 一「按」。顺序不能乱：卡 → 史实注 → 选项 → 扩写 → 脊梁 → 默认无反应。
##
## 【扩写为什么排在脊梁前面】
## 两者都由 _playing 点着，光看 _playing 分不出该翻哪一本账（见 _expansion）。
## 真同时在的场合其实没有（查东西的时候玩家动不了，剧情也就接不上），
## 但顺序写死比「反正不会同时发生」稳 —— 后者是句要靠推理维持的话。
func press() -> void:
	if _card.visible:
		_card.skip()
		return
	if _note.visible:
		_note.dismiss()
		return
	if _choices.visible:
		# 选项摆着，等玩家点。空格落到这儿是**界面的**意思，不是推进 ——
		# 推进器那边也会拦（awaiting_choice 时 advance() 无效），两道都要有：
		# 一道拦玩家，一道拦写错的界面。
		return
	if _expansion:
		if _box.is_typing():
			_box.skip_typing()
		else:
			_qi += 1
			_show_current()
		return
	if _spine:
		if not _playing:
			# 自由走动、附近没有热点。静默 = 玩家以为空格坏了 —— 给句话。
			say_fail("附近没有可查看 / 交谈的东西 —— 走近桌上或门边再按空格")
			return
		if _box.is_typing():
			_box.skip_typing()
		else:
			BeatRunner.advance()
		return
	if _playing:
		# 走到这儿说明既不是脊梁也不是扩写 —— 没有第三种，真到了就是状态串了。
		push_error("[RoomView] 在播，但既不是脊梁也不是扩写：_scene_id=%s" % _scene_id)


func _process(delta: float) -> void:
	if _note.visible or _playing or _pause.is_open():
		return
	# 键盘走。按了键盘就把点选的路取消掉 ——
	# 不取消的话松手之后小人会自己跑回原来那条路上，看着像闹鬼。
	var dir := Vector2(
		Input.get_action_strength("walk_right") - Input.get_action_strength("walk_left"),
		Input.get_action_strength("walk_down") - Input.get_action_strength("walk_up"))
	if dir != Vector2.ZERO:
		if _walker.is_walking():
			_walker.stop()
			_walking_to = -1
		_walker.step(dir, delta)
	elif _walker.is_walking():
		pass   # Walker 自己 _process 里走
	else:
		# 走到头了。如果是「点物件走过来的」，这时候开口。
		if _walking_to >= 0:
			var i := _walking_to
			_walking_to = -1
			_activate(i)

	_refresh_focus()


# ============================================================
#  热点
# ============================================================

## 脚到矩形的最短距离。用「夹到矩形上」算，不是到中心的距离 ——
## 物件是长条的（比如一整面告示墙），按中心算会变成「必须走到正中间」。
static func _dist_to_rect(p: Vector2, r: Rect2) -> float:
	var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
	return p.distance_to(q)


func _spot_at(p: Vector2) -> int:
	for i in _spots.size():
		if (_spots[i]["rect"] as Rect2).has_point(p):
			return i
	return -1


## 够得着的东西里最近的那个。够不着就是 -1（提示条收起来）。
func _refresh_focus() -> void:
	var best := -1
	var best_d := REACH
	var f := _walker.foot()
	for i in _spots.size():
		var r: Rect2 = _spots[i]["rect"]
		var d := _dist_to_rect(f, r)
		if d <= best_d:
			best_d = d
			best = i
	if best != _focus:
		_focus = best
		_update_prompt()


func _update_prompt() -> void:
	if _focus < 0 or _playing:
		_prompt.visible = false
		return
	var o: Dictionary = _spots[_focus]["data"]
	var verb := str(o.get("hint", "查看"))
	var mark := "·" if GameState.has_examined(str(o.get("id", ""))) else ""
	_prompt_label.text = "%s%s　空格 %s" % [mark, str(o.get("name", "")), verb]
	_prompt.visible = true


func _walk_to_spot(i: int) -> void:
	var stand: Vector2 = _spots[i]["stand"]
	_walker.walk_to(_grid.path(_walker.foot(), stand))
	_walking_to = i
	# 已经很近了就不必走 —— 直接开口，免得「点了一下，人挪了两像素才说话」。
	if not _walker.is_walking():
		_walking_to = -1
		_activate(i)


func _activate(i: int) -> void:
	if i < 0 or i >= _spots.size():
		return
	var o: Dictionary = _spots[i]["data"]
	var id := str(o.get("id", ""))
	match str(o.get("kind", "")):
		"exit":
			_go(str(o.get("to", "")), _norm_to_px(o.get("at", [])))
		_:
			GameState.mark_examined(id)
			var scene := str(o.get("scene", ""))
			var note: Variant = o.get("note", [])
			if not scene.is_empty():
				_play_scene(scene)
			elif note is Array and (note as Array).size() == 2:
				_note.present(str(note[0]), str(note[1]),
					DataDB.note_body(str(note[0]), str(note[1])))
			_update_prompt()


func _go(to: String, at: Vector2) -> void:
	if to.is_empty() or not DataDB.has_room(to):
		push_error("[RoomView] 出口指向不存在的房间：%s" % to)
		return
	enter(to, at)


# ============================================================
#  播一段扩写
# ============================================================
#
# 【为什么不是走 BeatRunner】
# BeatRunner 是**剧情游标**：它推进 GameState.scene/idx，一路往下走到结局。
# 查一个物件不该动剧情游标 —— 那正是这个工程跟网页版最大的结构差别
# （见 game_state.gd 开头）。所以这里另起一个小队列，只播不推。
# 但它**照样进回想日志**（I5）：玩家查过的东西，事后在回想屏里读得到。

func _play_scene(scene_id: String) -> void:
	if not DataDB.scenes.has(scene_id):
		push_error("[RoomView] 要播的场景不存在：%s" % scene_id)
		return
	_scene_id = scene_id
	_queue = DataDB.playable_bids(scene_id)
	_qi = 0
	_playing = true
	_expansion = true
	_prompt.visible = false
	# 提示条也要改口。不改的话玩家一边读着顺子、底下一边写着
	# 「走到那间房就接着演 · WASD 或点地上走」—— 而他此刻一步也走不动。
	_update_hint()
	_show_current()


func _show_current() -> void:
	if _qi >= _queue.size():
		_finish_playing()
		return
	var entry: Dictionary = _queue[_qi]
	var beat: Dictionary = entry["beat"]
	var bid := str(entry["bid"])

	var t := DataDB.beat_text(beat)
	if not t.is_empty():
		GameState.log_beat(bid, str(t["w"]), str(t["x"]))

	if not _render(beat, false):
		# 扩写里出现了不能单独播的拍。悄悄跳过去的话，玩家会少读一段
		# 而没人知道 —— 所以先报错，再跳，别把整段卡死。
		_qi += 1
		_show_current()
		return


## 把一拍画出来。**房间屏只有这一处画拍子** —— 脊梁和扩写走同一条路。
##
## 【为什么非要合成一个】
## 这两条路各自画一拍的话，将来给「书信」加个翻页动画、给「揭章」换个
## 印章样式，就得记得改两处。而漏改一处不会报错，只会让玩家在
## 「查来的那一封」和「剧情里的那一封」上看到两个样子。
##
## story = 这一拍来自脊梁。区别只有两处：
##   · 脊梁允许 choice / end（扩写不允许，出现了就是数据错）
##   · 选项摆出来的时机不同（脊梁那边推进器已经在等，扩写那边永远等不到）
##
## 返回 false = 这一拍画不出来，调用方该跳过它。
func _render(beat: Dictionary, story: bool) -> bool:
	match str(beat.get("t", "")):
		"n":
			_box.show_narration(str(beat.get("x", "")), bool(beat.get("emph", false)))
		"d":
			var who := str(beat.get("w", ""))
			_portraits.set_speaker(who)
			_box.show_speech(who, str(beat.get("r", "")), str(beat.get("x", "")),
				bool(beat.get("emph", false)))
		"q":
			_box.show_narration("%s\n—— %s" % [str(beat.get("x", "")), str(beat.get("src", ""))])
		"letter":
			_box.show_narration(str(beat.get("body", "")))
		"map":
			for m in beat.get("reveal", []):
				GameState.reveal_marker(str(m))
			_box.show_narration(str(beat.get("text", "")), true)
		"choice":
			if not story:
				push_error("[RoomView] 扩写 %s 里有不能单独播的节拍：choice"
					% _scene_id)
				return false
			_box.hide_box()
			_choices.present(str(beat.get("prompt", "")), BeatRunner.current_options())
		"end":
			if not story:
				push_error("[RoomView] 扩写 %s 里有不能单独播的节拍：end" % _scene_id)
				return false
			# 结局拍由推进器收尾（story_finished），屏幕上没有要画的。
			_box.hide_box()
		_:
			push_error("[RoomView] %s 里有不能播的节拍：%s"
				% [_scene_id if not story else _spine_scene, str(beat.get("t", ""))])
			return false
	return true


func _finish_playing() -> void:
	_playing = false
	_expansion = false
	_queue.clear()
	_box.hide_box()
	# 跟脊梁停缝同一类问题：NPC 的话读完了，人不能还杵在左边。
	_portraits.clear()
	_update_prompt()
	# 读完一段，提示条要改回「该去哪儿 / 能走」。剧情多半还停在缝里。
	_update_hint()


# ============================================================
#  示意层
# ============================================================
#
# 【为什么要有】
# 背景一张都还没有。一片素色上，玩家（和我）看不出可走区划在哪儿、
# 桌子挡在哪儿、热点对不对得上。这一层把这些画出来。
# 背景图一到位，_debug 自动关掉 —— 它是脚手架，不是功能。

func _debug_visible() -> bool:
	return _debug and not _bg_exists


func _draw_overlay(c: Control) -> void:
	if not _debug_visible() or _grid == null:
		return
	var walk := _walk_px()
	if walk.size() >= 3:
		var closed := walk.duplicate()
		closed.append(walk[0])
		c.draw_polyline(closed, Color(0.28, 0.42, 0.30, 0.55), 2.0)
	for b in _blockers_px():
		c.draw_rect(b, Color(0.66, 0.20, 0.16, 0.30), true)
		c.draw_rect(b, Color(0.66, 0.20, 0.16, 0.55), false, 1.0)
	for i in _spots.size():
		var r: Rect2 = _spots[i]["rect"]
		var hot := i == _focus
		var col := Color(0.55, 0.42, 0.14, 0.85) if hot else Color(0.55, 0.42, 0.14, 0.35)
		c.draw_rect(r, col, false, 2.0 if hot else 1.0)
		# 站位的落点。热点位置对不对，看它比看框准。
		c.draw_circle(_spots[i]["stand"], 3.0, col)


# ============================================================
#  给测试看的
# ============================================================

func room_id() -> String:
	return _room_id

func walker() -> Walker:
	return _walker

func grid() -> NavGrid:
	return _grid

func spot_count() -> int:
	return _spots.size()

func spot_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	for s in _spots:
		var d: Dictionary = s["data"]
		out.append(str(d.get("id", "")))
	return out

func spot_rect(id: String) -> Rect2:
	for s in _spots:
		var d: Dictionary = s["data"]
		if str(d.get("id", "")) == id:
			var r: Rect2 = s["rect"]
			return r
	return Rect2()

func spot_stand(id: String) -> Vector2:
	for s in _spots:
		var d: Dictionary = s["data"]
		if str(d.get("id", "")) == id:
			var p: Vector2 = s["stand"]
			return p
	return Vector2.INF

func focus_id() -> String:
	if _focus < 0:
		return ""
	var d: Dictionary = _spots[_focus]["data"]
	return str(d.get("id", ""))

## 把小人直接放到某个热点跟前，不跑动画。测试用。
func stand_at_spot(id: String) -> void:
	for i in _spots.size():
		var d: Dictionary = _spots[i]["data"]
		if str(d.get("id", "")) == id:
			var p: Vector2 = _spots[i]["stand"]
			_walker.set_foot(p)
			_walker.stop()
			_refresh_focus()
			return

func activate(id: String) -> void:
	for i in _spots.size():
		var d: Dictionary = _spots[i]["data"]
		if str(d.get("id", "")) == id:
			_activate(i)
			return

func is_playing() -> bool:
	return _playing

func box_text() -> String:
	return _box.debug_text()

func box_speaker() -> String:
	return _box.debug_speaker()

func note_open() -> bool:
	return _note.visible

func note_title() -> String:
	return _note.shown_title()

func note_text() -> String:
	return _note.shown_text()

func prompt_visible() -> bool:
	return _prompt.visible

func prompt_text() -> String:
	return _prompt_label.text

func place_text() -> String:
	return _place_label.text

## 现在这一拍是队列里的第几拍（从 0 数）。测试拿它验顺序。
func queue_index() -> int:
	return _qi

func queue_size() -> int:
	return _queue.size()

## 不走打字机，直接把当前这一句显示完并翻到下一拍。
##
## 【判据是 _expansion 不是 _playing】翻的是 _queue 那本账，
## 脊梁在演的时候 _qi 是上一个场景留下的旧数 —— 照着它翻会把
## 一段早演完的扩写重新拉出来。
func next_beat() -> void:
	if not _expansion:
		return
	_box.skip_typing()
	_qi += 1
	_show_current()


# ---------------------- 脊梁（给测试看的） ----------------------

func spine_on() -> bool:
	return _spine

func spine_scene() -> String:
	return _spine_scene

## 停在缝里时，下一场戏是哪一场（空串 = 没在缝里）。
func spine_next_scene() -> String:
	return _next_spine

## 停在缝里 = 玩家在走、剧情不动。这是「读一段、走一段」那个节奏的判据。
func spine_paused() -> bool:
	return _spine and not _playing and BeatRunner.is_paused()

func presentation_on() -> bool:
	return _present.visible

func hint_text() -> String:
	return _hint.text

func choices_open() -> bool:
	return _choices.visible

## [{text, enabled}] —— 屏幕上真摆着的那几个。
func choice_texts() -> Array:
	return _choices.described()

func choose(index: int) -> void:
	_on_choice_made(index)

func card_visible() -> bool:
	return _card.visible

func card_title() -> String:
	return _card.debug_title()

## 现在这张卡退场之后会不会回标题屏。
## 【为什么不直接调 _on_card_closed() 看它跳不跳】那会真的 change_scene，
## 把跑架自己换掉 —— 测试当场没了。所以验的是那道闸本身。
func card_ends_run() -> bool:
	return _card_ends_run


## 立刻把章节卡收掉，不走淡出。测试用 —— 见 ChapterCard.force_hide 的说明。
func drop_card() -> void:
	_card.force_hide()


## 一「按」。测试用它推进剧情，不必造键盘事件。
func press_now() -> void:
	press()
