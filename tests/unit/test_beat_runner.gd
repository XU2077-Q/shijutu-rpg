extends TestCase
## 节拍推进器 —— 把整条切片走一遍。
##
## 【为什么这批用例值钱】
## 里程碑 3 之前，「剧本能不能跑通」是没法验的：导出器只保证 JSON 自洽，
## 而 BeatRunner 会在上面叠三层逻辑 —— 条件过滤、supersede 顶替、切片边界。
## 这三层每层都能**安静地吃掉几拍**：不报错、不崩溃，只是某句话再也不出现了。
## 玩家不会发现少了什么，因为少掉的那句他从来没看过。
##
## 所以这里不看代码，看**行为**：从起点一路 advance 到停，然后拿结果去比对剧本。
## 走的路径必须是剧本原文的子序列 —— 顺序不能乱，字不能改，一条都不能是编的。

## 走查的迭代上限。正常切片 477 拍，给 20 倍余量。
## 超过就是死循环（选项绕回了自己），必须报错而不是把测试挂死。
const WALK_LIMIT := 10000


func _reset() -> void:
	GameState.reset()
	BeatRunner.stop()
	BeatRunner.slice_only = true
	BeatRunner.vn_mode = false


## 从头走到停。每个选择都挑**第一个能选的**。
## 返回 {"reason": 停止原因, "scenes": [...], "chapters": [...], "choices": [...]}
func _walk_all() -> Dictionary:
	var seen_scenes: Array = []
	var seen_chapters: Array = []
	var choices: Array = []
	var step := 0

	while BeatRunner.running and step < WALK_LIMIT:
		step += 1
		if BeatRunner.awaiting_choice:
			var opts := BeatRunner.current_options()
			var pick := -1
			for o in opts:
				if o["enabled"]:
					pick = int(o["index"])
					break
			if pick < 0:
				return {"reason": "no_selectable_option", "scenes": seen_scenes,
					"chapters": seen_chapters, "choices": choices}
			choices.append(BeatRunner.current_beat())
			BeatRunner.choose(pick)
		else:
			BeatRunner.advance()

	if step >= WALK_LIMIT:
		return {"reason": "walk_limit", "scenes": seen_scenes,
			"chapters": seen_chapters, "choices": choices}
	return {"reason": BeatRunner.last_reason, "scenes": seen_scenes,
		"chapters": seen_chapters, "choices": choices}


func _walk() -> Dictionary:
	var scenes: Array = []
	var chapters: Array = []
	BeatRunner.scene_entered.connect(func(id: String, _s: Dictionary) -> void: scenes.append(id))
	BeatRunner.chapter_changed.connect(func(ch: String, _t: String) -> void: chapters.append(ch))
	BeatRunner.begin()
	var r := _walk_all()
	r["scenes"] = scenes
	r["chapters"] = chapters
	return r


# ============================================================
#  切片边界
# ============================================================

## 停下来的**原因**比「停下来了」重要得多。
## reason == "slice_end" 证明切片是真的在故事中途被切断的；
## 要是拿到 "no_next"，说明走到了剧本尽头 —— 那是另一个故事，
## 而 demo 不该演到那儿去。
func test_slice_walk_stops_at_the_boundary_not_at_the_end() -> void:
	_reset()
	BeatRunner.last_reason = ""
	var r := _walk()
	eq(r["reason"], "slice_end",
		"走完切片后的停止原因不对（no_next = 剧本跑完了，bad_scene = 起始场景没了）")
	ok(r["scenes"].size() > 5, "只走了 %d 个场景，太少了" % r["scenes"].size())


func test_slice_walk_never_leaves_the_slice() -> void:
	_reset()
	var r := _walk()
	var outside: Array = []
	for id in r["scenes"]:
		if not DataDB.slice_set.has(id):
			outside.append(id)
	ok(outside.is_empty(),
		"走进了切片外的场景：%s —— 导出器给的 slice 和剧本的 next 对不上" % str(outside))


func test_slice_walk_covers_both_chapters() -> void:
	_reset()
	var r := _walk()
	ok(r["chapters"].has("序章"), "没进过序章")
	ok(r["chapters"].has("第一章"), "没进过第一章 —— 切片跨两章，只走一章说明中途断了")


# ============================================================
#  文本保真
# ============================================================

## 日志里记的每一拍，正文必须与剧本**逐字相同**。
##
## 【为什么不按 slice 数组顺序拼一份参考文本来比】
## 第一版就是这么写的，结果第一条就挂了：slice 数组里 23 个原场景在前、
## 9 个扩写节点在后，而实际播放时扩写是**插在中间**的。
## 那份「参考」的顺序本身就是错的 —— 拿一个错的基准去比，比出来的错不算数。
##
## 改成逐条按 bid 回查原文：不依赖任何遍历顺序，直接问「你记的这一拍，
## 剧本里真是这么写的吗」。改字、串拍、凭空多出来的句子，三种错全都能抓到。
func test_every_logged_beat_is_verbatim_from_the_script() -> void:
	_reset()
	_walk()

	ok(GameState.log.size() > 100,
		"走完整条切片只记下 %d 条日志 —— 太少了" % GameState.log.size())

	var wrong: Array = []
	for e in GameState.log:
		var bid := str(e["bid"])
		var beat := DataDB.get_beat(bid)
		if beat.is_empty():
			wrong.append("%s —— 剧本里没有这一拍" % bid)
			continue
		var want := ""
		match str(beat.get("t", "")):
			"n", "d", "q":
				want = str(beat.get("x", ""))
			"letter":
				want = str(beat.get("body", ""))
			"choice":
				want = str(beat.get("prompt", ""))
			"map":
				want = str(beat.get("text", ""))
			_:
				wrong.append("%s —— 节拍类型 %s 不该进日志" % [bid, beat.get("t")])
				continue
		if str(e["x"]) != want:
			wrong.append("%s\n            日志：%s\n            原文：%s"
				% [bid, str(e["x"]).substr(0, 60), want.substr(0, 60)])

	ok(wrong.is_empty(),
		"有 %d 条日志的正文与剧本对不上：\n          %s"
		% [wrong.size(), "\n          ".join(wrong.slice(0, 5))])


## 同一场景内的日志，bid 序号必须**递增**。
## 倒着记 = 回想屏里那几句是反的；重复记 = 有一拍被播了两次。
func test_logged_bids_advance_within_each_scene() -> void:
	_reset()
	_walk()

	var last_idx := {}
	var backwards: Array = []
	var repeated: Array = []
	for e in GameState.log:
		var parts := str(e["bid"]).split(":")
		if parts.size() != 2:
			backwards.append("bid 形状不对：%s" % e["bid"])
			continue
		var sc := parts[0]
		var i := int(parts[1])
		if last_idx.has(sc):
			if i == int(last_idx[sc]):
				repeated.append(str(e["bid"]))
			elif i < int(last_idx[sc]):
				backwards.append("%s：%d 之后又出现了 %d" % [sc, last_idx[sc], i])
		last_idx[sc] = i

	ok(backwards.is_empty(), "有场景的日志是倒着记的：%s" % ", ".join(backwards.slice(0, 5)))
	ok(repeated.is_empty(), "有拍被记了两次：%s" % ", ".join(repeated.slice(0, 5)))


## 场景之间必须是**接得上**的：上一个场景要么 next 直接指向下一个，
## 要么是玩家选的选项指向它。接不上 = 剧本里有一处跳转没被推进器认出来，
## 那它多半是走了别的路（比如默默回到了起始场景）。
func test_scene_transitions_are_wired() -> void:
	_reset()
	var r := _walk()

	var broken: Array = []
	for i in range(1, r["scenes"].size()):
		var prev: String = r["scenes"][i - 1]
		var cur: String = r["scenes"][i]
		if prev == cur:
			continue
		if _can_reach(prev, cur):
			continue
		broken.append("%s → %s" % [prev, cur])

	ok(broken.is_empty(),
		"这些场景之间的跳转在剧本里找不到依据：%s" % ", ".join(broken))


## prev 能不能一步走到 cur：next 指过去，或者某个选项指过去。
func _can_reach(prev: String, cur: String) -> bool:
	var sc: Dictionary = DataDB.scenes.get(prev, {})
	var nx: Variant = sc.get("next")
	if nx is String and nx == cur:
		return true
	if nx is Dictionary and CondEval.eval_next(nx) == cur:
		return true
	for b in sc.get("beats", []):
		if b.get("t") != "choice":
			continue
		for o in b.get("opts", []):
			if str(o.get("to", "")) == cur:
				return true
	return false


## 每一拍**显示过就必须记下来**。
## 漏记 = 回想屏里那一拍永远读不到，而玩家跳过闲笔之后就再也见不着它了（I5）。
##
## 【计数为什么要用字典】
## GDScript 的 lambda 是**按值捕获**的：`presented += 1` 改的是闭包里的副本，
## 外面那个变量纹丝不动。第一版就是这么写的，结果「显示过 0 拍」——
## 一个永远为 0 的计数器会让这条用例恒真，比不写还糟。
## 字典/数组是引用类型，改里面的元素才真的改到了。
func test_every_presented_beat_gets_logged() -> void:
	_reset()
	var tally := {"n": 0}
	BeatRunner.beat_entered.connect(func(_b: String, beat: Dictionary) -> void:
		if str(beat.get("t", "")) != "end":
			tally["n"] += 1)
	BeatRunner.choice_presented.connect(func(_b: String, _x: Dictionary) -> void:
		tally["n"] += 1)
	BeatRunner.begin()
	_walk_all()

	ok(int(tally["n"]) > 100, "只显示过 %d 拍 —— 信号没接上？" % tally["n"])
	eq(GameState.log.size(), int(tally["n"]),
		"显示过 %d 拍，日志里只有 %d 条 —— 有拍显示了却没进回想"
		% [tally["n"], GameState.log.size()])


## 切片里出现过的每一种节拍，都得能取出一段非空正文。
## 取不出来 = 回想屏上那一行是空白，而这种错在跑通之前完全看不出来。
func test_every_beat_type_in_the_slice_has_text() -> void:
	var empty: Array = []
	var kinds := {}
	for scene_id in DataDB.slice:
		for e in DataDB.playable_bids(scene_id):
			var b: Dictionary = e["beat"]
			var t := str(b.get("t", ""))
			kinds[t] = true
			if t == "end":
				continue
			var s := ""
			match t:
				"n", "d", "q":
					s = str(b.get("x", ""))
				"letter":
					s = str(b.get("body", ""))
				"choice":
					s = str(b.get("prompt", ""))
				"map":
					s = str(b.get("text", ""))
				_:
					s = "?"
			if s.strip_edges().is_empty():
				empty.append("%s（%s）" % [e["bid"], t])

	ok(empty.is_empty(),
		"这些拍取不出正文，回想屏上会是空白：\n          %s" % ", ".join(empty))
	ok(kinds.has("n"), "切片里一条旁白都没有 —— 旁白是这部作品的本体，不可能没有")
	ok(kinds.has("d"), "切片里一句对白都没有")


# ============================================================
#  选择
# ============================================================

## 等选择的时候 advance() 必须无效。
## 不然玩家随便点两下屏幕，就会把选项跳过去 —— 而且跳过去的那个选择
## 可能带着旗标，整条支线就断了，还查不出原因。
func test_advance_is_ignored_while_awaiting_a_choice() -> void:
	_reset()
	BeatRunner.begin()
	var step := 0
	while BeatRunner.running and not BeatRunner.awaiting_choice and step < WALK_LIMIT:
		step += 1
		BeatRunner.advance()

	ok(BeatRunner.awaiting_choice, "走遍整条切片都没碰到一个选择 —— 剧本不该是这样")
	if not BeatRunner.awaiting_choice:
		return

	var bid_before := BeatRunner.last_bid
	BeatRunner.advance()
	BeatRunner.advance()
	eq(BeatRunner.last_bid, bid_before, "等选择时 advance() 把拍推进了")
	ok(BeatRunner.awaiting_choice, "等选择时 advance() 把等待状态清掉了")


func test_offered_options_match_the_beat() -> void:
	_reset()
	BeatRunner.begin()
	var step := 0
	while BeatRunner.running and not BeatRunner.awaiting_choice and step < WALK_LIMIT:
		step += 1
		BeatRunner.advance()
	if not BeatRunner.awaiting_choice:
		fail("没碰到选择，这条用例什么也没测到")
		return

	var beat := BeatRunner.current_beat()
	var opts: Array = beat.get("opts", [])
	var offered := BeatRunner.current_options()
	eq(offered.size(), opts.size(), "给出的选项个数和剧本对不上")
	for o in offered:
		var i := int(o["index"])
		if i < 0 or i >= opts.size():
			fail("给出的选项下标越界：%d" % i)
			continue
		eq(o["text"], str(opts[i].get("x", "")), "第 %d 个选项的文字对不上" % i)


## 选完之后，这一选项声明的 gain / flag 必须**真的落到状态上**。
## 这是觉醒值和支线旗标的唯一入口，漏掉就是「选项点了没用」——
## 玩家看得见选项、点得动、剧情也往下走，只是那条线的门槛永远不够。
func test_choosing_applies_gain_and_flag() -> void:
	_reset()
	BeatRunner.begin()
	var checked := 0
	var step := 0

	while BeatRunner.running and step < WALK_LIMIT:
		step += 1
		if not BeatRunner.awaiting_choice:
			BeatRunner.advance()
			continue

		var opts: Array = BeatRunner.current_beat().get("opts", [])
		var pick := 0
		for o in BeatRunner.current_options():
			if o["enabled"]:
				pick = int(o["index"])
				break
		var o: Dictionary = opts[pick]

		var before: Dictionary = GameState.stats.duplicate()
		BeatRunner.choose(pick)

		for k in o.get("gain", {}):
			eq(GameState.stats.get(k, 0), int(before.get(k, 0)) + int(o["gain"][k]),
				"选了第 %d 项，觉醒值 %s 没加上去" % [pick, k])
			checked += 1
		if o.has("flag"):
			ok(GameState.has_flag(str(o["flag"])),
				"选了第 %d 项，旗标 %s 没置上" % [pick, o["flag"]])
			checked += 1

	ok(checked > 0, "走完整条切片，一个有 gain/flag 的选项都没验到 —— 这条用例是空的")


## 锁着的选项：既要**标出来**，又要**真的选不走**。
##
## 【为什么要造一个假场景】
## 切片里一个带条件的选项都没有 —— 门槛全在二至五章（14 处 cond 全在 c2_end）。
## 也就是说这条逻辑在切片期间**一次都不会被执行**，等它第一次执行，
## 就是在玩家手上、在第二章里。这种代码不测等于没写。
##
## 所以临时往 DataDB 里插一个探针场景，跑完就拔掉。
## 下面那两行 ERROR 是**预期内的** —— 就是引擎拒绝了越权选择的那一声。
func test_a_locked_option_is_marked_and_cannot_be_chosen() -> void:
	_reset()
	const PROBE := "__t_probe"
	DataDB.scenes[PROBE] = {
		"ch": "序章",
		"next": "p_intro",
		"beats": [
			{"t": "n", "x": "探针。"},
			{"t": "choice", "prompt": "挑一个。", "opts": [
				{"x": "锁着的", "cond": {"op": "flag", "name": "__t_never_set"},
				 "lock": {"op": "template", "fmt": "需要觉醒 {0}", "args": [{"op": "var", "name": "shen"}]},
				 "to": "p_intro"},
				{"x": "开着的", "gain": {"shen": 1}, "to": "p_intro"},
			]},
		],
	}

	BeatRunner.resume(PROBE, 0)   # 落在第 0 拍（旁白）
	BeatRunner.advance()          # 再走一拍，才到选择
	ok(BeatRunner.awaiting_choice, "探针场景没走到选择那一步")

	var opts := BeatRunner.current_options()
	eq(opts.size(), 2, "探针场景的选项个数不对")
	if opts.size() == 2:
		ok(not opts[0]["enabled"], "带 flag 门槛的选项应该锁着")
		ok(opts[1]["enabled"], "没有门槛的选项应该开着")
		eq(opts[0]["lock"], "需要觉醒 0",
			"锁提示没算出来 —— 玩家只会看到一个灰按钮，不知道为什么点不动")

	# 界面上画成灰的还不够：手柄、键盘、将来的快捷键都可能绕过界面。
	# 引擎这一层必须自己拦一道。
	BeatRunner.choose(0)
	ok(BeatRunner.awaiting_choice, "锁着的选项被选走了 —— 引擎没拦住")

	BeatRunner.choose(1)
	ok(not BeatRunner.awaiting_choice, "开着的选项没被接受")
	eq(GameState.stats.get("shen", 0), 1, "探针选项的 gain 没落上")

	DataDB.scenes.erase(PROBE)
	_reset()


# ============================================================
#  存档挂钩
# ============================================================

## 推进器要如实把游标写进 GameState —— 存档就靠这两个数。
func test_cursor_follows_the_walk() -> void:
	_reset()
	BeatRunner.begin()
	var step := 0
	while BeatRunner.running and not BeatRunner.awaiting_choice and step < WALK_LIMIT:
		step += 1
		BeatRunner.advance()
	ok(not BeatRunner.scene_id.is_empty(), "走了一段，场景还是空的")
	ok(BeatRunner.idx >= 0, "走了一段，拍下标还是 %d" % BeatRunner.idx)
	ok(DataDB.scenes.has(BeatRunner.scene_id), "当前场景在剧本里不存在：%s" % BeatRunner.scene_id)


## stop() 之后必须真的停下来，不能还能 advance。
func test_stop_is_final() -> void:
	_reset()
	BeatRunner.begin()
	var before := BeatRunner.last_bid
	BeatRunner.stop()
	BeatRunner.advance()
	eq(BeatRunner.last_bid, before, "stop() 之后 advance() 还在推进")
	ok(not BeatRunner.running, "stop() 之后 running 还是真")
