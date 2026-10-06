extends TestCase
## 纯 VN 屏 —— 把整条切片从界面里走一遍。
##
## 【为什么引擎测过了，界面还要再测一遍】
## test_beat_runner 证明的是「剧本走得通」。它证明不了「界面接得住」——
## 而界面这一层有个很特别的失败方式：**模态**。
## 章节卡、引文、书信、选项都会盖在对话上面，盖着的时候节拍还在往下发。
## 所以 VNScreen 把发过来的节拍先攒进 _pending，等模态走了再放。
## 这段队列一旦写错（少放一拍、或者干脆不放），
## 后果不是崩溃，是**剧本安静地少了几段** —— 玩家不知道自己漏了什么。
##
## 所以这里拿两条路对账：
##   甲：直接驱动 BeatRunner（没有界面）
##   乙：驱动 VNScreen（有界面、有模态、有动画）
## 两条路走出来的回想日志必须**一模一样**。差一条就是界面吃掉了内容。
##
## 【为什么用例是协程】
## 它要等真的动画跑完 —— 不是等一个假的替身。所以每一轮都 yield 一帧，
## 让 tween 真的推进。跑架已经支持 await 用例（见 run_tests.gd）。

const VN_SCENE := "res://scenes/vn/vn_screen.tscn"
const STEP_LIMIT := 6000
## 动画加起来才几秒，但万一卡住，这条上限保证测试不会挂死。
const FRAME_LIMIT := 4000


func _reset() -> void:
	GameState.reset()
	BeatRunner.stop()
	BeatRunner.slice_only = true
	BeatRunner.vn_mode = false


## 甲路：直接推引擎，每个选择都挑第一个能选的。返回日志条数。
func _drive_engine() -> int:
	_reset()
	BeatRunner.begin()
	var step := 0
	while BeatRunner.running and step < STEP_LIMIT:
		step += 1
		if BeatRunner.awaiting_choice:
			var pick := -1
			for o in BeatRunner.current_options():
				if o["enabled"]:
					pick = int(o["index"])
					break
			if pick < 0:
				break
			BeatRunner.choose(pick)
		else:
			BeatRunner.advance()
	return GameState.log.size()


## 乙路：把真的界面挂进场景树，然后一直按。
## 返回一份走查记录。
func _drive_screen() -> Dictionary:
	_reset()

	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	# _begin 是 call_deferred 的，等两帧让它把第一拍放出来
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var seen_modals := {}
	var card_count := 0
	var quote_count := 0
	var letter_count := 0
	var choice_count := 0
	var max_pending := 0
	var last_modal := ""

	var frames := 0
	while not screen.is_over() and frames < FRAME_LIMIT:
		frames += 1
		var m: String = screen.modal_name()
		if m != last_modal:
			seen_modals[m] = true
			match m:
				"CARD": card_count += 1
				"QUOTE": quote_count += 1
				"LETTER": letter_count += 1
				"CHOICE": choice_count += 1
			last_modal = m
		max_pending = maxi(max_pending, screen.pending_count())

		if screen.choices_open():
			screen.choose(0)      # 每个选择都挑第一个
		else:
			screen.press()
		await host.get_tree().process_frame

	# 结局卡是 sticky 的，走完还要几帧才稳
	for i in 30:
		await host.get_tree().process_frame

	var out := {
		"frames": frames,
		"log": GameState.log.size(),
		"cards": card_count,
		"quotes": quote_count,
		"letters": letter_count,
		"choices": choice_count,
		"max_pending": max_pending,
		"pending": screen.pending_count(),
		"modal": screen.modal_name(),
		"reason": BeatRunner.last_reason,
		"log_entries": GameState.log.duplicate(),
	}
	screen.queue_free()
	await host.get_tree().process_frame
	return out


# ============================================================
#  两条路对账
# ============================================================

func test_the_screen_plays_the_same_slice_as_the_bare_engine() -> void:
	var engine_count := _drive_engine()
	var r: Dictionary = await _drive_screen()

	ok(engine_count > 400, "引擎自己走只记下 %d 条日志 —— 基准本身就不对" % engine_count)
	eq(r["reason"], "slice_end", "界面走到的停止原因不对")
	eq(r["log"], engine_count,
		"界面走出的日志条数（%d）和引擎直接走的（%d）对不上 —— "
		% [r["log"], engine_count] + "界面这一层吃掉或者多放了内容")

	# 逐条比对，不只是数个数 —— 条数一样但内容串了也照样是错的
	var engine_log := _engine_log_bids()
	var ui_bids: Array = []
	for e in r["log_entries"]:
		ui_bids.append(str(e["bid"]))
	var diff := -1
	for i in mini(engine_log.size(), ui_bids.size()):
		if engine_log[i] != ui_bids[i]:
			diff = i
			break
	eq(diff, -1, "第 %d 条日志的 bid 和引擎走出来的不一样" % diff)


## 再走一遍引擎，把 bid 序列拿出来做逐条比对。
## 单独一个函数是为了让它跑在**同一个** GameState 上、干净地重来一次。
func _engine_log_bids() -> Array:
	_reset()
	BeatRunner.begin()
	var step := 0
	while BeatRunner.running and step < STEP_LIMIT:
		step += 1
		if BeatRunner.awaiting_choice:
			var pick := -1
			for o in BeatRunner.current_options():
				if o["enabled"]:
					pick = int(o["index"])
					break
			if pick < 0:
				break
			BeatRunner.choose(pick)
		else:
			BeatRunner.advance()
	var out: Array = []
	for e in GameState.log:
		out.append(str(e["bid"]))
	return out


func test_the_queue_never_strands_beats() -> void:
	var r: Dictionary = await _drive_screen()
	eq(r["pending"], 0,
		"走完之后还攒着 %d 拍没放 —— 界面把内容落在了队列里" % r["pending"])
	ok(int(r["max_pending"]) <= 4,
		"队列里最多同时攒了 %d 拍，太多了 —— 模态退场时没及时接回去" % r["max_pending"])


# ============================================================
#  各种呈现层有没有真的上过场
# ============================================================

## 切片里有 2 张章节卡（序章挂在 p_tea 上、第一章挂在 c1_shanghai 上）。
## 一张都没出 = 卡片那套逻辑根本没被走到，别的用例也就不用指望了。
func test_chapter_cards_are_shown() -> void:
	var r: Dictionary = await _drive_screen()
	ok(int(r["cards"]) >= 2,
		"只出现了 %d 张章节卡，切片跨两章，至少该有两张" % r["cards"])


func test_quotes_and_letters_are_shown() -> void:
	var r: Dictionary = await _drive_screen()
	ok(int(r["quotes"]) > 0, "整条切片一条引文都没弹出过 —— 引文层没接上")
	ok(int(r["letters"]) > 0, "整条切片一封信都没弹出过 —— 书信层没接上")
	ok(int(r["choices"]) > 0, "整条切片一个选择都没弹出过")


## 收场的时候屏幕上不能还留着别的模态。
## 切片最后一场的末拍常常是一条引文 —— 不收的话，结局卡会盖在它上面。
func test_nothing_is_left_open_at_the_end() -> void:
	var r: Dictionary = await _drive_screen()
	eq(r["modal"], "CARD", "收场时的模态应该是那张「到此为止」的卡")
	ok(int(r["frames"]) < FRAME_LIMIT, "走查撞上了帧数上限，说明中途卡住了")


# ============================================================
#  对白与立绘
# ============================================================

## 说话的人要有名条，旁白不能有名条。
func test_speaker_plate_appears_only_for_speech() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	# p_intro 全是旁白：一路按到出现第一句对白为止
	var frames := 0
	var saw_narration_without_plate := false
	while frames < 400:
		frames += 1
		if screen.modal_name() == "NONE" and screen.box_text() != "":
			if screen.box_speaker().is_empty():
				saw_narration_without_plate = true
			else:
				break
		screen.press()
		await host.get_tree().process_frame

	ok(saw_narration_without_plate, "旁白也挂上了名条 —— 名条只该给说话的人")
	ok(not screen.box_speaker().is_empty(), "按了半天没碰到一句对白")
	ok(screen.box_text().length() > 0, "碰到对白了，但框里是空的")

	screen.queue_free()
	await host.get_tree().process_frame


## 名条上写的人，必须和剧本里那一拍的 `w` 对得上。
func test_the_plate_names_the_right_speaker() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	# 走到第一句对白，然后拿它的名条去剧本里找那一拍
	var frames := 0
	while frames < 400 and screen.box_speaker().is_empty():
		frames += 1
		screen.press()
		await host.get_tree().process_frame

	var plate: String = screen.box_speaker()
	ok(not plate.is_empty(), "没走到任何一句对白")
	# 名条可能是「名字（身份）」，取括号前那一段
	var name := plate.split("（")[0]

	var found := false
	for scene_id in DataDB.slice:
		for e in DataDB.playable_bids(scene_id):
			var b: Dictionary = e["beat"]
			if b.get("t") == "d" and str(b.get("w", "")) == name:
				found = true
				break
		if found:
			break
	ok(found, "名条上写的「%s」在剧本里找不到对应的说话人" % name)

	screen.queue_free()
	await host.get_tree().process_frame


# ============================================================
#  几何 —— 内容对了，不等于画出来了
# ============================================================
#
# 【这一组用例是怎么来的】
# 上面那七条全绿的那一版，**对话框在屏幕上根本不存在**。
# 病根是一句看着人畜无害的 `set_anchors_preset(PRESET_FULL_RECT)`：
# 它的默认行为是「改锚点，但保住控件当前的矩形」，于是 offsets 被反算成
# 让那个 0×0 的新控件**继续是 0×0**。对话框的根层因此塌了，
# 底下那块 BOTTOM_WIDE 的面板按「父高 = 0」定位，被摆到了 y = -212。
#
# 而七条用例一条都没红 —— 它们查的是 `_body.text`。文字确实写进去了，
# 只是没人看得见。**「内容对」和「画出来了」是两件事**，这一组量的是后者。
#
# 是浏览器截图先发现的（tools/webcheck.js）。headless 的哑渲染器出不了像素，
# 这类错它一辈子也看不见 —— 这就是为什么每个里程碑都得真的导一次 Web。

## 本该铺满整屏的那几层。
const FULL_SCREEN_LAYERS := [
	"_bg", "_vignette", "_portraits", "_box",
	"_choices", "_quote", "_letter", "_card",
]


func test_every_full_screen_layer_covers_the_screen() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var want: Vector2 = screen.size
	ok(want.x > 100.0 and want.y > 100.0,
		"界面自己是 %s —— 根控件没铺开，后面的都白量" % want)
	for layer in FULL_SCREEN_LAYERS:
		var c: Variant = screen.get(layer)
		ok(c != null, "找不到 %s —— 名字改了？改名字要连这条用例一起改" % layer)
		if c == null:
			continue
		ok(is_equal_approx(c.size.x, want.x) and is_equal_approx(c.size.y, want.y),
			"%s 的尺寸是 %s，应该跟界面一样是 %s —— 满屏层没铺满"
			% [layer, c.size, want])

	screen.queue_free()
	await host.get_tree().process_frame


## 对话框得**在屏幕上**，而且在下半部分。
## 这条是上面那个 y = -212 的直接看守：跑到屏幕外面去，它一样不报错。
func test_the_dialogue_panel_is_actually_on_screen() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var vp := Rect2(Vector2.ZERO, screen.size)
	var panel: Variant = screen.get("_box").get("_box")
	var r: Rect2 = panel.get_global_rect()

	ok(vp.encloses(r), "对话面板 %s 跑到屏幕 %s 外面去了" % [r, vp])
	ok(r.size.x > vp.size.x * 0.5,
		"对话面板只有 %d 宽（屏幕 %d）—— 多半是外层塌成了 0×0" % [int(r.size.x), int(vp.size.x)])
	ok(r.size.y > 60.0, "对话面板只有 %d 高，一行字都放不下" % int(r.size.y))
	ok(r.position.y > vp.size.y * 0.5,
		"对话面板在 y=%d，跑到屏幕上半部分去了" % int(r.position.y))

	screen.queue_free()
	await host.get_tree().process_frame


## 名条不能压住正文第一行。
##
## 【这条是怎么来的】
## 名条是「骑在边框上」的，第一版按「框顶往上 40、往下 16」摆，
## 但 PanelContainer 会被自己的最小高度撑大（28 号字 + 上下留白 ≈ 85 px），
## 于是它长到正文头上，把台词第一行的开头盖住了。
## 截图里看得一清二楚，而所有查文字的用例都是绿的 —— 文字确实在，
## 只是被另一块不透明的东西压着。
func test_the_name_plate_does_not_cover_the_text() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	# 走到一句对白，让名条真的显示出来
	var frames := 0
	while frames < 400 and screen.box_speaker().is_empty():
		frames += 1
		screen.press()
		await host.get_tree().process_frame
	ok(not screen.box_speaker().is_empty(), "没走到任何一句对白，名条没显示")

	var inner: Variant = screen.get("_box")
	var plate: Control = inner.get("_plate")
	var body: Control = inner.get("_body")
	ok(plate.visible, "名条没显示出来")

	var pr: Rect2 = plate.get_global_rect()
	var br: Rect2 = body.get_global_rect()
	ok(pr.end.y <= br.position.y,
		"名条下沿在 y=%d，正文第一行顶在 y=%d —— 名条压住了正文"
		% [int(pr.end.y), int(br.position.y)])
	ok(pr.position.y >= 0.0,
		"名条顶到 y=%d，跑到屏幕上边外面去了" % int(pr.position.y))

	screen.queue_free()
	await host.get_tree().process_frame


## 立绘的两个位子也要在屏幕上 —— 同理，画到屏幕外不会报错。
func test_the_portrait_slots_are_on_screen() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var vp := Rect2(Vector2.ZERO, screen.size)
	var slots: Array = screen.get("_portraits").get("_slots")
	eq(slots.size(), 2, "立绘位不是两个")
	for i in slots.size():
		var r: Rect2 = slots[i].get_global_rect()
		ok(r.size.x > 100.0 and r.size.y > 100.0,
			"第 %d 个立绘位的尺寸是 %s —— 塌了" % [i, r.size])
		ok(vp.intersects(r) and vp.encloses(r),
			"第 %d 个立绘位 %s 不在屏幕 %s 里" % [i, r, vp])

	screen.queue_free()
	await host.get_tree().process_frame


## 兜底：任何**可见的直接子层**都得占住像素。
## 这条不针对某一个控件，针对的是「新加一层时又忘了那件事」——
## 加进来一个 0×0 的可见控件，它在屏幕上和不存在完全一样。
func test_no_visible_layer_collapses_to_nothing() -> void:
	_reset()
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	for c in screen.get_children():
		if not (c is Control) or not c.visible:
			continue
		ok(c.size.x > 0.0 and c.size.y > 0.0,
			"直接子层 %s 是可见的，尺寸却是 %s —— 它占不到一个像素" % [c.name, c.size])

	screen.queue_free()
	await host.get_tree().process_frame


# ============================================================
#  选项按钮的几何 —— 文字不许溢出框
# ============================================================
#
# 【这条是怎么来的】
# 浏览器截图里，选项的文字垂在按钮框外面，提示行被裁掉半截。
# 病根：Button 不是容器，不会被子内容撑大，而 custom_minimum_size.y
# 给的是 0 —— 按钮只剩样式盒那 32px 高。headless 的用例全绿，
# 因为它们查的是「选项文字对不对」，不是「字画在了哪里」。
# 修法是按内容算高（内层 VBox 的最小尺寸 + 上下内边距 32），
# 这条用例就是修法的看守：谁改了布局，字再溢出去，这里先红。
func test_choice_buttons_hold_their_text() -> void:
	_reset()
	var menu: Variant = load("res://scripts/ui/choice_menu.gd").new()
	host.add_child(menu)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	# 最长选项 24 字 + 一行提示；再塞一个无提示的短选项对照。
	var opts := [
		{"index": 0, "text": "去杨椒山祠。举子们都在往那边去。", "hint": "亲眼看见愤怒是什么样子", "enabled": true, "lock": ""},
		{"index": 1, "text": "回客栈。", "hint": "", "enabled": true, "lock": ""},
	]
	menu.present("你打算怎么办？", opts)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var buttons: Array = menu._buttons
	ok(buttons.size() == 2, "应当摆出两个选项按钮，实得 %d" % buttons.size())
	for b: Button in buttons:
		var min_size: Vector2 = b.get_combined_minimum_size()
		ok(b.size.y >= min_size.y - 0.5,
			"按钮实际高度 %d 小于内容需要 %d —— 文字要溢出去了" % [int(b.size.y), int(min_size.y)])
		# 每个文字标签都得完整待在自己的按钮框里。
		for l: Label in b.find_children("*", "Label", true, false):
			if l.text.strip_edges().is_empty():
				continue
			var lr: Rect2 = l.get_global_rect()
			var br: Rect2 = b.get_global_rect()
			ok(br.encloses(lr.grow(1.0)),
				"「%s」的文字框 %s 跑出了按钮框 %s" % [l.text.left(8), lr, br])
			var need: Vector2 = l.get_combined_minimum_size()
			ok(l.size.y >= need.y - 0.5,
				"标签高 %d 不足内容高 %d —— 行数被压掉了" % [int(l.size.y), int(need.y)])

	menu.queue_free()
	await host.get_tree().process_frame


# ============================================================
#  自动存档 —— 「续 前 一 局」的地基
# ============================================================
#
# 标题屏的「续 前 一 局」读的是 auto 档；VN 屏在场景进门和选项摆出时
# 各落一次。这条用例盯着两件事：
#   一、真的会落（没人调 autosave，按钮就永远是灰的，这条断过一次）；
#   二、落进去的书签跟 GameState 一致 —— 续玩要能精确回到那一拍。
# 用例结束把 auto 档清掉，别把起跑线留给下一个人。
func test_autosave_lands_on_scene_entry_and_choices() -> void:
	_reset()
	SaveManager.delete_slot("auto")

	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	# 场景进门就应有档，且书签 = 当前场景。
	var frames := 0
	while not SaveManager.has_slot("auto") and frames < FRAME_LIMIT:
		screen.press()
		await host.get_tree().process_frame
		frames += 1
	ok(SaveManager.has_slot("auto"), "走过开场还没落自动存档 —— 挂钩断了")
	if SaveManager.has_slot("auto"):
		var meta: Dictionary = SaveManager.peek("auto")
		ok(str(meta.get("scene", "")) == GameState.scene,
			"档里场景 %s 跟 GameState 的 %s 对不上" % [meta.get("scene"), GameState.scene])

	# 走到第一个选择处（选项摆出时又落一次档），书签应停在选项那拍。
	frames = 0
	while not screen.choices_open() and frames < FRAME_LIMIT:
		screen.press()
		await host.get_tree().process_frame
		frames += 1
	ok(screen.choices_open(), "一直没等到选项")
	if screen.choices_open():
		var meta2: Dictionary = SaveManager.peek("auto")
		ok(int(meta2.get("idx", -1)) == GameState.idx,
			"档里 idx %d 跟 GameState 的 %d 对不上 —— 续玩会跳拍"
			% [int(meta2.get("idx", -1)), GameState.idx])
		ok(str(meta2.get("scene", "")) == GameState.scene,
			"选项处的场景书签不对：档里 %s，实际 %s" % [meta2.get("scene"), GameState.scene])

	screen.queue_free()
	await host.get_tree().process_frame
	SaveManager.delete_slot("auto")
