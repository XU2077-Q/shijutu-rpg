class_name RoomView
extends Control
## 房间屏 —— 里程碑 4 的成品：能走、能调查。
##
## 【它与 VN 屏的分工】
## VN 屏负责脊梁：剧情一拍一拍往前走，玩家只能按「下一句」。
## 房间屏负责中间那层：玩家在场景里走动、查物件、跟人说话。
## 两边共用对话框、立绘层、史实注，但**互不知道对方存在** ——
## 里程碑 5 才用 story_map 把它们串起来。现在串起来的话，
## 「走到哪儿剧情就跳到哪儿」这件事会渗进两个屏，两边都难改。
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

## 热点：[{data, rect(像素), stand(像素)}]。每次尺寸变化重算。
var _spots: Array = []
var _focus := -1
var _bg_exists := false

## 点了一个物件，走过去之后要自动开口
var _walking_to := -1

## 正在播的一段扩写
var _queue: Array = []
var _qi := 0
var _playing := false
## 正在播的是哪一段。_show_current 报错时要指名道姓 ——
## 它自己拿不到场景 id（那是 _play_scene 的入参），所以存在这儿。
var _scene_id := ""

var _debug := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	resized.connect(_relayout)
	call_deferred("_enter_from_settings")


func _enter_from_settings() -> void:
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
#  搭界面
# ============================================================

func _build() -> void:
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
	_place.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_place.offset_left = 40
	_place.offset_top = 32
	_place.offset_bottom = 88
	_place.offset_right = 560
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

	_box = DialogueBox.new()
	add_child(_box)

	_note = NoteView.new()
	add_child(_note)

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
	_hint.text = "点地上走过去 · WASD 也能走 · 空格 查看 / 交谈 · Esc 回标题"
	_hint.add_theme_color_override("font_shadow_color", Color(0.98, 0.94, 0.87, 0.85))
	_hint.add_theme_constant_override("shadow_offset_x", 1)
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.offset_left = 40
	_hint.offset_top = -64
	_hint.offset_bottom = -20
	_hint.offset_right = 900
	add_child(_hint)


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
	_walker.set_foot(spawn)
	_walker.stop()
	_refresh_focus()

	SaveManager.autosave()


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
	if _note.visible:
		if e.is_action_pressed("ui_advance") or e.is_action_pressed("interact"):
			_note.dismiss()
			get_viewport().set_input_as_handled()
		return
	if e.is_action_pressed("menu"):
		# 【顺序不能反：先吃掉这一下，再换场景】
		# change_scene_to_file 是**立刻**把旧场景拆出树，但新场景要等这一帧末尾才进来。
		# 拆出去之后再调 set_input_as_handled，走的是「已不在树上的 Viewport」——
		# 引擎会往控制台甩一句
		#   ERROR: Condition "!is_inside_tree()" is true. at: set_input_as_handled
		# 不崩、不影响玩，但浏览器自查里它就是一条真的报错，会把真问题淹掉。
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file(TITLE_SCENE)
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


## 一「按」。顺序不能乱：史实注 → 正在播的一段 → 默认无反应。
func press() -> void:
	if _note.visible:
		_note.dismiss()
		return
	if _playing:
		if _box.is_typing():
			_box.skip_typing()
		else:
			_qi += 1
			_show_current()
		return


func _process(delta: float) -> void:
	if _note.visible or _playing:
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
	_prompt.visible = false
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
		_:
			# 扩写里不该出现 choice / end。真出现了就是数据错了 ——
			# 悄悄跳过去的话，玩家会少读一段而没人知道。
			push_error("[RoomView] 扩写 %s 里有不能单独播的节拍：%s"
				% [_scene_id, str(beat.get("t", ""))])
			_qi += 1
			_show_current()
			return


func _finish_playing() -> void:
	_playing = false
	_queue.clear()
	_box.hide_box()
	_update_prompt()


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
func next_beat() -> void:
	if not _playing:
		return
	_box.skip_typing()
	_qi += 1
	_show_current()
