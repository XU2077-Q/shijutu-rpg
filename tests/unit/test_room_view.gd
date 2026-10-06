extends TestCase
## 房间屏：能走、能查、能交谈。
##
## 【里程碑 3 的教训，这一屏照样适用】
## 「内容对了不等于画出来了」—— 对话框塌成 0×0 那一次，84 个用例全绿。
## 所以这里除了「文字对不对」，还要问「它在不在屏幕上」。
##
## 【为什么不模拟点击，直接调 activate()】
## 点一下要走完「算路 → 走 → 到了开口」三步，中间隔着好几帧动画。
## 那是手感，该由人肉眼验（导 Web 出来点）。这里要验的是**接线对不对**：
## 站到顺子跟前，focus 是不是他；开口之后，播的是不是 x2 那四拍、顺序对不对。
## 混在一起测的话，失败时分不清是「接线断了」还是「路算慢了」。

const ROOM_SCENE := "res://scenes/world/room.tscn"


func _open(room_id: String) -> Variant:
	AppSettings.pending_room = room_id
	AppSettings.pending_at = Vector2.INF
	var v: Variant = load(ROOM_SCENE).instantiate()
	if not (v is RoomView):
		# 【这一句是拿血换来的，别删】
		# room_view.gd 解析不过的时候，room.tscn 会加载出一个**没有脚本的
		# Control**。之后每一句 v.stand_at_spot() 都报「Invalid call」并
		# **中断这个用例** —— 而中断的用例 failures 是空的，跑架报 ✓。
		# 那次 12 个用例里 11 个假绿。所以这里必须先手动记一条失败。
		fail("room.tscn 没加载出 RoomView —— 脚本有解析错误（看上面的 SCRIPT ERROR）")
		return v
	host.add_child(v)
	# 房间尺寸要等一帧才定下来（FULL_RECT 锚点靠父节点给尺寸），
	# 进房间那一步又是 call_deferred 的，排在帧尾。
	# 三帧是「尺寸定了 + deferred 跑完了 + resized 也跟着重排过」的最小余量。
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	return v


func _close(v: Variant) -> void:
	v.queue_free()
	await host.get_tree().process_frame


func test_the_room_opens_and_the_walker_stands_in_it() -> void:
	var v: Variant = await _open("r_tea")
	eq(str(v.room_id()), "r_tea", "应当进的是茶楼")
	ok(float(v.size.x) > 100.0 and float(v.size.y) > 100.0,
		"房间屏应当铺满视口，实为 %s" % str(v.size))
	ok(v.spot_count() > 0, "茶楼里应当有物件")
	ok(v.grid() != null and v.grid().open_count() > 0,
		"茶楼应当有一片能走的区域")

	var w: Variant = v.walker()
	ok(w != null, "应当有小人")
	if w != null:
		ok(v.grid().is_walkable(w.foot()),
			"小人的出生点站不住：%s" % str(w.foot()))
		var f: Vector2 = w.foot()
		ok(f.x >= 0.0 and f.x <= float(v.size.x) and f.y >= 0.0 and f.y <= float(v.size.y),
			"小人在屏幕外：%s（屏幕 %s）" % [str(f), str(v.size)])
		ok(bool(w.has_art()), "行走图应当加载得到（art/walk/shen_*.png）")

	await _close(v)


## 背景还没出图，占位和示意层就得在 —— 不然屏幕上是一片素色，
## 「哪儿能走、哪儿有东西」全看不出来。
func test_the_placeholder_shows_while_the_background_is_missing() -> void:
	var v: Variant = await _open("r_tea")
	var bg_path := str(DataDB.room("r_tea").get("bg", ""))
	var has_art := ResourceLoader.exists(bg_path)
	var ph: Variant = v.get("_placeholder")
	ok(ph != null, "应当有占位层")
	if ph != null:
		eq(bool(ph.visible), not has_art,
			"占位层的显隐应当与背景图在不在相反（背景图存在=%s）" % str(has_art))
	await _close(v)


func test_every_object_becomes_a_hotspot_on_screen() -> void:
	var v: Variant = await _open("r_tea")
	var ids: PackedStringArray = v.spot_ids()
	eq(ids.size(), (DataDB.room("r_tea").get("objects", []) as Array).size(),
		"rooms.json 里的物件应当一个不少地变成热点")
	for id in ids:
		var r: Rect2 = v.spot_rect(id)
		ok(r.size.x > 0.0 and r.size.y > 0.0,
			"热点 %s 的矩形是空的（宽 %f 高 %f）" % [id, r.size.x, r.size.y])
		ok(r.position.x >= -1.0 and r.position.y >= -1.0
				and r.end.x <= float(v.size.x) + 1.0 and r.end.y <= float(v.size.y) + 1.0,
			"热点 %s 跑到屏幕外去了：%s（屏幕 %s）" % [id, str(r), str(v.size)])
	await _close(v)


## 够得着才有提示。站远了提示还亮着，玩家会以为按空格有用。
func test_focus_picks_the_nearest_thing_within_reach() -> void:
	var v: Variant = await _open("r_tea")
	v.stand_at_spot("tea.shunzi")
	eq(str(v.focus_id()), "tea.shunzi", "站在顺子跟前，聚焦的应当就是他")
	ok(bool(v.prompt_visible()), "够得着的时候应当有提示条")
	ok(str(v.prompt_text()).contains("顺子"), "提示条上应当写着「顺子」，实为「%s」" % str(v.prompt_text()))

	# 走到屋子另一头，提示应当收起来
	v.walker().set_foot(Vector2(60.0, float(v.size.y) - 60.0))
	v.walker().stop()
	v.call("_refresh_focus")
	ok(str(v.focus_id()) == "", "离得远的时候不该还聚焦着谁，实为 %s" % str(v.focus_id()))
	ok(not bool(v.prompt_visible()), "离得远的时候提示条应当收起来")
	await _close(v)


## 提示条得真的画在屏幕上 —— 这是里程碑 3 那次的教训。
func test_the_prompt_is_actually_on_screen() -> void:
	var v: Variant = await _open("r_tea")
	v.stand_at_spot("tea.shunzi")
	var p: Variant = v.get("_prompt")
	ok(p != null, "应当有提示条")
	if p != null:
		ok(bool(p.visible), "够得着的时候提示条应当可见")
		var r: Rect2 = p.get_global_rect()
		ok(r.size.x > 0.0 and r.size.y > 0.0,
			"提示条塌成了 %s" % str(r.size))
		ok(r.end.y <= float(v.size.y) + 1.0 and r.position.y >= -1.0,
			"提示条跑到屏幕外了：%s（屏幕 %s）" % [str(r), str(v.size)])
	await _close(v)


## 交谈：播的必须是 x2 那四拍，顺序不能乱，一句不能少。
##
## 【这里直接拿 box_text() 与 beat.x 逐字比，是有前提的】
## 框里存的是**标记文本**：带 emph 的旁白会多包一层 [center][font_size=…]，
## 正文里的方括号会转义成 [lb]。切片里四条扩写（x1/x2/x3/x4）全是朴素旁白，
## 既没有 emph 也没有方括号，所以两者逐字相同。
## 哪天扩写里出现了 emph 或方括号，这条会红 —— 那时把断言换成
## 「还原标记之后的纯文本」即可。现在不预先抽象：多一层还原函数，
## 反而会把「屏幕上到底写着什么」这件事糊掉。
func test_talking_to_shunzi_plays_the_expansion_in_order() -> void:
	var v: Variant = await _open("r_tea")
	v.stand_at_spot("tea.shunzi")
	v.activate("tea.shunzi")

	ok(bool(v.is_playing()), "跟顺子说上话之后应当有一段在播")
	var want: Array = DataDB.playable_bids("x2")
	eq(int(v.queue_size()), want.size(), "应当把 x2 的每一拍都排上队")
	eq(int(v.queue_index()), 0, "应当从第一拍开始")

	for i in want.size():
		eq(int(v.queue_index()), i, "第 %d 拍的位置不对" % i)
		var beat: Dictionary = want[i]["beat"]
		eq(str(v.box_text()), str(beat.get("x", "")),
			"第 %d 拍的字不对" % i)
		v.next_beat()

	ok(not bool(v.is_playing()), "四拍播完就该收场")
	await _close(v)


## 查物件：开史实注。史实注不占剧情，读完剧情原地不动 ——
## 所以它不能把 _playing 打开，否则剧情会被它顶住。
func test_looking_at_the_cup_opens_a_note_and_does_not_hold_the_story() -> void:
	var v: Variant = await _open("r_tea")
	v.stand_at_spot("tea.cup")
	v.activate("tea.cup")

	ok(bool(v.note_open()), "查茶盏应当翻出一条史实注")
	eq(str(v.note_title()), "《马关条约》", "翻出来的应当是《马关条约》")
	ok(not bool(v.is_playing()), "史实注不该占住剧情队列")

	var txt := str(v.note_text())
	ok(not txt.contains("[ref]"), "史实注正文里不该漏出 [ref] 标记：%s" % txt.substr(0, 40))
	ok(txt.length() > 40, "史实注正文不该是空的")

	v.get("_note").dismiss()
	ok(not bool(v.note_open()), "合上之后应当看不见了")
	await _close(v)


func test_examining_something_is_remembered() -> void:
	var v: Variant = await _open("r_tea")
	GameState.examined.clear()
	v.stand_at_spot("tea.cup")
	ok(not GameState.has_examined("tea.cup"), "还没查过")
	v.activate("tea.cup")
	ok(GameState.has_examined("tea.cup"), "查过之后应当记住")
	await _close(v)


func test_walking_into_an_exit_changes_the_room() -> void:
	var v: Variant = await _open("r_tea")
	v.activate("tea.stairs")
	eq(str(v.room_id()), "r_xuanwu", "下楼应当到宣武门外大街")
	eq(GameState.room, "r_xuanwu", "GameState 里的房间也要跟着走")
	# 换房间之后，小人得站在新房间里站得住的地方
	var f: Vector2 = v.walker().foot()
	ok(v.grid().is_walkable(f), "到了新房间，小人的落点站不住：%s" % str(f))
	ok(str(v.spot_ids()).contains("xw.notice"), "新房间的热点应当重建过了")
	await _close(v)


## 三间房走得通：茶楼 → 大街 → 都察院 → 大街 → 茶楼。
func test_the_three_rooms_are_walkable_in_a_loop() -> void:
	var v: Variant = await _open("r_tea")
	v.activate("tea.stairs")
	eq(str(v.room_id()), "r_xuanwu", "茶楼 → 大街")
	v.activate("xw.gongche")
	eq(str(v.room_id()), "r_gongche", "大街 → 都察院")
	v.activate("gc.back")
	eq(str(v.room_id()), "r_xuanwu", "都察院 → 大街")
	v.activate("xw.tea")
	eq(str(v.room_id()), "r_tea", "大街 → 茶楼")
	await _close(v)


## 造一个真的左键按下事件，塞进 _gui_input —— Godot 自己也是这么调的。
## 【为什么不给 RoomView 加一个 click() 接口】那样测的是「我新写的那个函数」，
## 不是真实的输入通路。这一条要防的恰恰是「输入通路上有人把点击吃了」。
static func _click_at(v: Variant, p: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = p
	v.call("_gui_input", ev)


## 点一下地上，人就该走过去。
##
## 【为什么要单拎出来，而且要用真的 _gui_input】
## 这一条是导 Web 到浏览器里点出来的：跟顺子说完话之后，再点地上**没反应**。
## 屏幕上看不出任何异常 —— 不报错、不崩，只是「点了没动静」，
## 玩家会以为这游戏本来就不能走。这类坏最难靠肉眼发现。
## 所以这里把点击事件真的塞进 _gui_input（Godot 自己也是这么调的），
## 而不是绕过输入层直接调 walk_to。
##
## 目标点 (0.15, 0.72) 是**茶楼里的空地**：在可走多边形里，
## 不在窗边桌 / 柜台 / 长凳三块障碍上，也不压任何热点矩形。
## 压在热点上走的是「走过去 + 开口」那条路，那是另一条用例。
func test_clicking_the_floor_walks_the_walker() -> void:
	var v: Variant = await _open("r_tea")
	var before: Vector2 = v.walker().foot()
	var target := Vector2(float(v.size.x) * 0.15, float(v.size.y) * 0.72)
	ok(v.grid().is_walkable(target), "目标点应当是能站的（测试自己的前提）")
	_click_at(v, target)
	v.walker().snap_to_path_end()
	ok(v.walker().foot().distance_to(before) > 40.0,
		"点地上应当走过去（原地不动：%s → %s）" % [str(before), str(v.walker().foot())])
	await _close(v)


## 【同一件事，但发生在「说完话之后」——这才是踩到的那个场景】
## 区别在 _playing：对话没播完的时候，点击归「按一下」，不归「走过去」。
## 如果 _playing 没被清干净，说完话之后整间房就点不动了。
func test_the_room_is_clickable_again_after_a_conversation() -> void:
	var v: Variant = await _open("r_tea")
	v.stand_at_spot("tea.shunzi")
	v.activate("tea.shunzi")
	var guard := 0
	while bool(v.is_playing()) and guard < 50:
		v.next_beat()
		guard += 1
	ok(not bool(v.is_playing()), "对话应当播完了（播不完就是队列卡住了）")

	var before: Vector2 = v.walker().foot()
	var target := Vector2(float(v.size.x) * 0.15, float(v.size.y) * 0.72)
	_click_at(v, target)
	v.walker().snap_to_path_end()
	ok(v.walker().foot().distance_to(before) > 40.0,
		"说完话之后点地上应当还能走（原地不动：%s → %s）"
		% [str(before), str(v.walker().foot())])
	await _close(v)


## 对话**没播完**的时候点地上，点击该归「按一下」，不该让人走掉。
## 这是上面那一条的反面 —— 两条合起来才说明白「_playing 到底管什么」。
##
## 【这里不断言「一下正好翻一拍」】因为一下点下去可能只是收打字机
## （看打字机跑完没有）。要断的是**不变量**：还在播的时候，人一步都不许动。
func test_a_click_mid_conversation_does_not_walk_the_walker() -> void:
	var v: Variant = await _open("r_tea")
	v.stand_at_spot("tea.shunzi")
	v.activate("tea.shunzi")
	ok(bool(v.is_playing()), "应当有一段在播（前提）")

	var before: Vector2 = v.walker().foot()
	var floor := Vector2(float(v.size.x) * 0.15, float(v.size.y) * 0.72)
	for i in 2:
		_click_at(v, floor)
		v.walker().snap_to_path_end()
		ok(bool(v.is_playing()) or int(v.queue_index()) >= int(v.queue_size()),
			"第 %d 下点完，这段要么还在播、要么已经播到底（位置 %d / %d）"
			% [i + 1, int(v.queue_index()), int(v.queue_size())])
		ok(v.walker().foot().distance_to(before) < 40.0,
			"对话还没播完，点地上不该走开（第 %d 下之后：%s → %s）"
			% [i + 1, str(before), str(v.walker().foot())])
	await _close(v)


func test_the_place_label_names_the_room() -> void:
	var v: Variant = await _open("r_gongche")
	var t := str(v.place_text())
	ok(t.contains("都察院"), "地名标签应当写着都察院，实为「%s」" % t)
	await _close(v)


## 每一个挂扩写的物件，都得能真的播出来 —— 不能只验顺子那一个。
func test_every_expansion_object_plays_cleanly() -> void:
	for room_id in DataDB.rooms:
		var v: Variant = await _open(room_id)
		for o in (DataDB.room(room_id).get("objects", []) as Array):
			var s := str(o.get("scene", ""))
			if s.is_empty():
				continue
			var oid := str(o.get("id", "?"))
			v.stand_at_spot(oid)
			v.activate(oid)
			eq(int(v.queue_size()), DataDB.playable_bids(s).size(),
				"%s 的 %s 排队拍数与 %s 对不上" % [room_id, oid, s])
			ok(bool(v.is_playing()), "%s 的 %s 应当播起来了" % [room_id, oid])
			# 播到底，看会不会卡住
			var guard := 0
			while bool(v.is_playing()) and guard < 200:
				v.next_beat()
				guard += 1
			ok(not bool(v.is_playing()),
				"%s 的 %s 播不完 —— 有一拍卡住了" % [room_id, oid])
		await _close(v)
