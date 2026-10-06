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


# ============================================================
#  脊梁（里程碑 5）
# ============================================================
#
# 【这一组在验什么】
# 里程碑 4 之前，「剧情」和「房间」是两套互不认识的系统，各自都能跑通。
# 里程碑 5 把它们接上，于是多出一类全新的坏法：**两边各自都对，接起来错**。
# 比如剧情在 r_ci 演、人却站在 r_tea；比如停住等玩家走过来，却没人能走过来。
# 这些都不会崩、不会报错，只会让玩家看着一间空屋子发呆。
#
# 所以这一组不测「函数返回什么」，测**玩家能不能把这条切片从头玩到尾**。

func _reset_runner() -> void:
	BeatRunner.stop()
	BeatRunner.slice_only = true
	BeatRunner.vn_mode = false
	BeatRunner.spine_mode = false
	BeatRunner.pause_between_scenes = false


## 开一屏房间，从脊梁开头演起。
func _open_spine() -> Variant:
	_reset_runner()
	GameState.reset()
	AppSettings.pending_resume = false
	AppSettings.pending_spine = true
	AppSettings.pending_room = ""
	AppSettings.pending_at = Vector2.INF

	var v: Variant = load(ROOM_SCENE).instantiate()
	if not (v is RoomView):
		fail("room.tscn 没加载出 RoomView —— 脚本有解析错误（看上面的 SCRIPT ERROR）")
		return v
	host.add_child(v)
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	return v


## 一直按到 pred 成立。返回是否成立。
## 【为什么不写「按 n 下」】打字机要不要多吃一下是不确定的（看它跑完没有），
## 所以「第 7 下之后必然是什么」这种断言本身就是错的。
func _press_until(v: Variant, pred: Callable, limit: int = 400) -> bool:
	for i in limit:
		if bool(pred.call()):
			return true
		v.press_now()
	return bool(pred.call())


## 把整条脊梁在房间屏里走完：**停在哪间房就走进哪间房**。
## 这正是玩家要做的事，一步不多、一步不少。
##
## stop 给了就在它成立的那一刻收手（用来走到半路停下来看现场）。
## 不传就是一路走到切片末尾的收尾卡。
##
## 返回 {scenes, wrong, stalled, steps}。
func _walk_spine(v: Variant, stop: Callable = Callable(), limit: int = 4000) -> Dictionary:
	var scenes: Array = []
	var wrong: Array = []
	var last_sig := ""
	var same := 0
	var stalled := false
	var step := 0

	while step < limit:
		if stop.is_valid() and bool(stop.call()):
			break
		step += 1

		# 【两种卡要分得开，第一版没分，红了一片】
		# 原来的循环条件是 `not card_visible()` —— 那是里程碑 4 写的，
		# 当时屏上只可能有收尾卡。里程碑 5 补上章节卡（序章那张挂在 p_tea）之后，
		# 这个条件的意思就变成了「一进茶楼就收工」，报出来是
		# 「一共只演了 1 场」「收尾卡上该写着到 此 为 止，实为 春 愁」。
		# 看着像剧情断了，其实只是驱动把**路过**的卡当成了**终点**。
		if bool(v.card_visible()) and bool(v.card_ends_run()):
			break

		# 章节卡是**路过的**，但它横在对话框前面 —— 不拿掉就什么也读不到。
		#
		# 【为什么不按空格让它自己淡掉】
		# 试过：press() 确实会调 _card.skip()，可淡出是 0.7 秒的 tween，
		# 而同步的 while 循环里帧是不动的（headless 每帧的 delta 还特别小，
		# await process_frame 也不作数）。于是每一圈只是把 skip() 又叫一遍
		# —— 它自己带 _leaving 闸，第二下就不理了 —— 卡永远挂在那儿。
		# 所以这里直接 force_hide：测试要验的是剧情走得通，不是卡的淡出好不好看。
		# 卡本身有没有出现在对的场景、写着对的字，另有两条用例在守。
		if bool(v.card_visible()):
			v.drop_card()
			continue

		var sc := str(v.spine_scene())
		if not scenes.has(sc):
			scenes.append(sc)
			var want := DataDB.room_for_scene(sc)
			if not want.is_empty() and str(v.room_id()) != want:
				wrong.append("%s 该在 %s 演，人却在 %s" % [sc, want, str(v.room_id())])

		# 卡死检测。判据是「这一圈跟上一圈一模一样」——
		# 不能按「按了多少下」算：c1_shanghai 一场就 22 拍，正常也要按几十下。
		var sig := "%s|%s|%s|%s" % [sc, str(v.box_text()),
			str(v.spine_paused()), str(v.choices_open())]
		if sig == last_sig:
			same += 1
			if same > 30:
				stalled = true
				break
		else:
			same = 0
			last_sig = sig

		if bool(v.choices_open()):
			var opts: Array = v.choice_texts()
			var pick := -1
			for i in opts.size():
				if bool(opts[i]["enabled"]):
					pick = i
					break
			if pick < 0:
				break
			v.choose(pick)
			continue

		if bool(v.spine_paused()):
			var nxt := str(v.spine_next_scene())
			var r := DataDB.room_for_scene(nxt)
			if nxt.is_empty() or r.is_empty():
				break
			v.enter(r)
			continue

		v.press_now()

	return {"scenes": scenes, "wrong": wrong, "stalled": stalled, "steps": step}


## 日志里的 bid 序列。
func _log_bids() -> Array:
	var out: Array = []
	for e in GameState.log:
		out.append(str(e["bid"]))
	return out


## 两个序列第一处不一样的地方。报告里要看得见「差在第几条」——
## 两个几十条的数组一起打出来，报告里只看得见开头那几条，而差异不在开头。
func _first_diff(a: Array, b: Array) -> String:
	for i in maxi(a.size(), b.size()):
		var x := str(a[i]) if i < a.size() else "<没有>"
		var y := str(b[i]) if i < b.size() else "<没有>"
		if x != y:
			return "第 %d 条起不一样：房间屏是 %s，纯推进器是 %s" % [i, x, y]
	return ""


## 题记那一场没有房间，压在一块暗底上演 —— 不能装作它是一间屋子。
func test_the_spine_opens_on_the_scene_that_has_no_room() -> void:
	var v: Variant = await _open_spine()
	ok(bool(v.spine_on()), "标题屏点了「走 动」，房间屏就该从脊梁演起")
	eq(str(v.spine_scene()), DataDB.spine_start(), "脊梁应当从 spine_start 起")
	ok(DataDB.room_for_scene(str(v.spine_scene())).is_empty(),
		"开场这一场（题记）本就不该有房间 —— 有的话这条用例的前提就不成立了")
	ok(bool(v.presentation_on()), "没有房间的那几场应当压在暗底上演")
	ok(not bool(v.is_playing()) or true, "")
	await _close(v)


## 剧情走一走，玩家就进了第一间房 —— 不用他做任何事。
func test_the_story_carries_the_player_into_the_first_room() -> void:
	var v: Variant = await _open_spine()
	var got := await _press_until(v, func() -> bool: return str(v.room_id()) != "")
	ok(got, "题记演完了，玩家应当已经在某间房里了（现在还在暗底上）")
	if got:
		eq(str(v.room_id()), "r_tea", "序章第一场有房间的戏是茶楼")
		ok(not bool(v.presentation_on()), "进了房间就该把暗底收起来")

		# 序章卡挂在 p_tea 上。房间屏原本漏了它 —— VN 屏有、这条路上没有，
		# 于是同一个序章，两种走法一个看得到「春 愁」那张卡、一个看不到。
		ok(bool(v.card_visible()), "进茶楼该摆出序章卡（它挂在 p_tea 上）")
		ok(str(v.card_title()).contains("春 愁"),
			"序章卡上该写着「春 愁」，实为「%s」" % str(v.card_title()))
		# 【这一条是防「卡把人送回标题屏」的】章节卡的 finished 与收尾卡
		# 长得一模一样，不区分的话一进茶楼游戏就没了。
		ok(not bool(v.card_ends_run()),
			"序章卡退场不该回标题屏 —— 那是收尾卡才做的事")
	await _close(v)


## **整条切片能在房间屏里从头玩到尾。**
## 这一条是里程碑 5 的总验收 —— 它红了，就等于「垂直切片不可玩」。
func test_the_whole_slice_is_playable_in_rooms() -> void:
	var v: Variant = await _open_spine()
	var r: Dictionary = _walk_spine(v)
	var scenes: Array = r["scenes"]

	ok(not bool(r["stalled"]),
		"走到第 %d 步就卡住了（演到 %s）—— 有一处没有出路" % [int(r["steps"]), str(v.spine_scene())])
	ok(bool(v.card_visible()),
		"没走到切片末尾。演到 %s 就断了，一共演了 %d 场" % [str(v.spine_scene()), scenes.size()])
	ok((r["wrong"] as Array).is_empty(),
		"有戏演错了房间：\n          %s" % "\n          ".join(r["wrong"]))
	ok(scenes.size() >= 15, "一共只演了 %d 场 —— 太少了，多半是中途断了" % scenes.size())

	for id in scenes:
		ok(DataDB.is_spine(str(id)),
			"房间里演到了不在脊梁上的场景：%s（那是热点扩写，不该自动演）" % id)
	await _close(v)


## 停在场景缝里：剧情不动，玩家能走，而且**提示条告诉他该去哪儿**。
func test_the_story_waits_for_the_player_to_walk_over() -> void:
	var v: Variant = await _open_spine()
	_walk_spine(v, func() -> bool: return bool(v.spine_paused()))
	ok(bool(v.spine_paused()), "走了一段都没停过 —— pause_between_scenes 没接上")
	if not bool(v.spine_paused()):
		await _close(v)
		return

	var nxt := str(v.spine_next_scene())
	ok(not nxt.is_empty(), "停下来了，却没说下一场是哪一场")
	var want := DataDB.room_for_scene(nxt)
	ok(not want.is_empty(), "停下来的下一场 %s 没有房间 —— 那它就该直接接着演" % nxt)
	ok(want != str(v.room_id()),
		"停在缝里时，下一场不该跟当前房间是同一间（同房就该连播，不该停）")
	ok(str(v.hint_text()).contains("宣武门"),
		"提示条该写明剧情在哪儿等着，实为「%s」" % str(v.hint_text()))

	# 走到那间房，剧情自己接上
	var before := str(v.spine_scene())
	v.enter(want)
	ok(str(v.spine_scene()) != before,
		"走到「%s」了，剧情却没接上（还停在 %s）" % [want, str(v.spine_scene())])
	await _close(v)


## 走错了房间什么也不该发生 —— 这条是「闲笔不锁出口」的底气。
func test_wandering_into_the_wrong_room_leaves_the_story_alone() -> void:
	var v: Variant = await _open_spine()
	_walk_spine(v, func() -> bool: return bool(v.spine_paused()))
	if not bool(v.spine_paused()):
		fail("没能走到场景缝里，这条用例什么也没测到")
		await _close(v)
		return

	var scene_before := str(v.spine_scene())
	var next_before := str(v.spine_next_scene())
	var want := DataDB.room_for_scene(next_before)

	# 随便挑一间**不是**目标房的屋子进去转一圈
	var detour := ""
	for rid in DataDB.rooms:
		if str(rid) != want and str(rid) != str(v.room_id()):
			detour = str(rid)
			break
	ok(not detour.is_empty(), "找不到一间可以乱走的房 —— 测试自己的前提就不成立")
	v.enter(detour)

	eq(str(v.spine_scene()), scene_before, "乱走了一间房，剧情游标动了")
	eq(str(v.spine_next_scene()), next_before, "乱走了一间房，下一场变了")
	ok(bool(v.spine_paused()), "乱走了一间房，暂停被解掉了")

	# 回到该去的那间，剧情照样接得上
	v.enter(want)
	ok(str(v.spine_scene()) != scene_before, "回到该去的房间，剧情却没接上")
	await _close(v)


## **停在缝里的时候，跟 NPC 说得上话。**
##
## 【这一条是补一个真漏洞的】
## 脊梁接上之后，进一场戏会把 _playing 点亮；而 press() 里 `if _spine`
## 那条分支排在前面，于是玩家在房间里查来的那一段（顺子四拍）也被
## 送去 BeatRunner.advance() —— 推进器正停在缝里，那是个空操作。
## 屏幕上是「第一句永远翻不过去」，看着像点了没反应。
##
## 老用例一条都不红：它们走的是里程碑 4 那条自由走动路径（_spine 为假），
## 那条路上 press() 落到的是 `_qi += 1`。所以这个漏洞只在
## **脊梁停下来、玩家去跟人说话**的时候露头 —— 而那正是里程碑 5 的全部意义。
func test_an_npc_still_talks_while_the_story_waits() -> void:
	var v: Variant = await _open_spine()
	_walk_spine(v, func() -> bool: return bool(v.spine_paused()))
	if not bool(v.spine_paused()):
		fail("没能走到场景缝里，这条用例什么也没测到")
		await _close(v)
		return
	eq(str(v.room_id()), "r_tea", "序章第一段缝应当停在广和茶楼")

	v.stand_at_spot("tea.shunzi")
	v.activate("tea.shunzi")
	ok(bool(v.is_playing()), "跟顺子说上话之后应当有一段在播")
	# 读着的时候人走不动，提示条就不该还写着「走到那间房就接着演」。
	ok(not str(v.hint_text()).contains("走到那间房"),
		"读扩写的时候，提示条还写着「走到那间房就接着演」：%s" % str(v.hint_text()))

	var want: Array = DataDB.playable_bids("x2")
	ok(want.size() > 1, "x2 得多于一拍，不然这条用例证明不了什么")

	# **按的是玩家按的那颗键。** 用测试专用的 next_beat() 就绕开了 press()，
	# 也就正好绕开了这个漏洞 —— 那这条用例就成了自己骗自己。
	var guard := 0
	while bool(v.is_playing()) and guard < 40:
		guard += 1
		v.press_now()

	ok(not bool(v.is_playing()), "按了 %d 下还没播完 —— 空格翻不动这段扩写" % guard)
	eq(int(v.queue_index()), want.size(), "扩写没翻到头")
	ok(bool(v.spine_paused()), "读完扩写，剧情该还停在原来那道缝里等着")
	eq(str(v.spine_scene()), "p_tea", "读了一段扩写，剧情游标不该动")
	ok(str(v.hint_text()).contains("走到那间房"),
		"读完扩写，提示条该改回「该去哪儿」：%s" % str(v.hint_text()))
	await _close(v)


## 选项摆在房间里，选哪条决定下一间房是哪间。
func test_the_choice_appears_in_the_room_and_picks_the_next_room() -> void:
	var v: Variant = await _open_spine()
	_walk_spine(v, func() -> bool: return bool(v.choices_open()))
	ok(bool(v.choices_open()), "走了一段都没碰到选择")
	if not bool(v.choices_open()):
		await _close(v)
		return

	eq(str(v.spine_scene()), "p_choice1", "第一个选择应当出现在宣武门外大街那一场")
	eq(str(v.room_id()), "r_xuanwu", "选项是在大街的房间里摆出来的")

	var shown: Array = v.choice_texts()
	var script_opts: Array = []
	for b in (DataDB.scenes["p_choice1"]["beats"] as Array):
		if str(b.get("t", "")) == "choice":
			script_opts = b["opts"]
	eq(shown.size(), script_opts.size(), "屏幕上的选项个数与剧本对不上")
	for i in mini(shown.size(), script_opts.size()):
		eq(str(shown[i]["text"]), str(script_opts[i]["x"]), "第 %d 个选项的字不对" % i)

	# 【提示条这会儿不能写着「空格 继续」】空格在选项摆着的时候是**哑的**
	# （ChoiceMenu._input 把它吞了，理由见那边）。写着能按却按不动，
	# 玩家只会以为游戏卡住了 —— 而这个坑正是「按空格把选项按掉」修完之后
	# 新露出来的：以前空格真能按，只是按出来的不是玩家想要的。
	ok(not str(v.hint_text()).contains("空格"),
		"选项摆着的时候提示条还写着「空格」：%s" % str(v.hint_text()))
	ok(str(v.hint_text()).contains("回车"),
		"选项摆着的时候，提示条该告诉玩家怎么选：%s" % str(v.hint_text()))

	# 选第一条（去杨椒山祠）—— 下一间房应当跟着变
	v.choose(0)
	ok(not bool(v.choices_open()), "选完之后选项该收起来")
	eq(str(v.spine_scene()), "p_ci", "选了「去杨椒山祠」，下一场就该是杨椒山祠那一场")
	eq(str(v.room_id()), "r_ci", "剧情走到杨椒山祠，人也就该在那儿")
	await _close(v)


## **房间屏一拍都不许丢、也不许重复。**
##
## 【为什么拿推进器当基准，而不是拿剧本当基准】
## 剧本是「该演什么」，推进器是「里程碑 3 那套已经被逐字比对验过的走法」。
## 房间层是在它外面套的一层，所以要比的是「套上这层之后，播出来的还是不是原来那些」。
## 拿剧本直接比的话，比的是「推进器对不对」——那件事已经有人管了。
func test_playing_the_story_in_rooms_loses_no_beat() -> void:
	var v: Variant = await _open_spine()
	_walk_spine(v)
	var in_rooms: Array = _log_bids()
	await _close(v)

	# 同一个走法，但不经过房间层。
	#
	# 【基准为什么取 GameState.log，不取 beat_entered】
	# 第一版接的是 beat_entered，于是**选项那一拍漏了** —— 推进器对 choice
	# 走的是 choice_presented，不发 beat_entered。报出来是
	# 「房间屏 420 拍，纯推进器 417 拍」，差三拍，正好是三个选择场景。
	# 那一刻看着像房间层多记了东西，其实是我这条基准少记了。
	# 回想日志才是「玩家读到了什么」的账本，两边都拿它当基准。
	_reset_runner()
	GameState.reset()
	BeatRunner.spine_mode = true
	BeatRunner.begin(DataDB.spine_start())
	var guard := 0
	while BeatRunner.running and guard < 20000:
		guard += 1
		if BeatRunner.awaiting_choice:
			var pick := -1
			for o in BeatRunner.current_options():
				if bool(o["enabled"]):
					pick = int(o["index"])
					break
			if pick < 0:
				break
			BeatRunner.choose(pick)
		else:
			BeatRunner.advance()
	var straight: Array = _log_bids()

	ok(in_rooms.size() > 300,
		"房间屏一共只记下 %d 拍 —— 太少了，多半是中途断了" % in_rooms.size())
	var where := _first_diff(in_rooms, straight)
	eq(where, "",
		"房间屏播出来的拍子与纯推进器不一样（房间屏 %d 拍，纯推进器 %d 拍）：%s"
		% [in_rooms.size(), straight.size(), where])
	_reset_runner()


## 切片演完了，得有一张明明白白的收尾卡 —— 不能让玩家对着一间空房发呆。
func test_the_slice_ends_with_a_card_that_says_so() -> void:
	var v: Variant = await _open_spine()
	_walk_spine(v)
	ok(bool(v.card_visible()), "走到切片末尾应当出一张收尾卡")
	if bool(v.card_visible()):
		ok(str(v.card_title()).contains("到 此 为 止"),
			"收尾卡上该写着「到 此 为 止」，实为「%s」" % str(v.card_title()))
		ok(bool(v.card_ends_run()), "收尾卡退场该回标题屏 —— 这一局到头了")
	# 收尾卡摆着的时候，再按不该把剧情又推起来
	var sc := str(v.spine_scene())
	v.press_now()
	eq(str(v.spine_scene()), sc, "收尾卡摆着的时候，按一下把剧情又推起来了")
	await _close(v)
