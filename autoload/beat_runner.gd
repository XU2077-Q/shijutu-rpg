extends Node
## 节拍推进器 —— 剧本的时间轴。
##
## 【它是被动的】
## 它只负责「下一拍是什么」，不负责「这一拍怎么画」。每进入一拍就发个信号
## 然后**停下等**，界面调 advance() 才走下一拍。这样：
##   · 打字机效果、立绘淡入、书信翻页，全都不需要引擎知道
##   · 存档只要记 scene + idx 两个数
##   · headless 测试可以直接循环 advance() 把整部剧跑完（见 test_beat_runner）
##
## 【为什么要有 slice_only】
## 垂直切片只到第一章末。不加这道闸，demo 会一路演到第五章去 ——
## 而后面几章的美术还没做，玩家会看到一堆占位图。
## 闸门用的是**导出器给的 slice**，不是这里手抄的清单。

signal scene_entered(scene_id: String, scene: Dictionary)
signal beat_entered(bid: String, beat: Dictionary)
signal choice_presented(bid: String, beat: Dictionary)
signal chapter_changed(ch: String, ch_title: String)
signal story_finished(ending_id: String)
signal run_finished(reason: String)

## 走到切片边界就停。demo 用 true，将来正式版用 false。
var slice_only := true

## VN 回退模式（I6）：把每一拍都当线性文本播，不看条件。
## 它同时是**验证预言机** —— 这个模式跑一遍，拼出来的文本必须与原文逐字相同。
## 目前 story_map 的物件/环境路由还没实现（里程碑 5），所以这里先只管 cond；
## 等路由上了，这里再一并忽略路由。
var vn_mode := false

var running := false
var awaiting_choice := false
var scene_id := ""
var idx := -1
var beats: Array = []
var last_bid := ""

## 上一次停下来的原因（"slice_end" / "no_next" / "bad_scene" …）。
## 单独留一个字段，是因为信号是瞬时的一发 —— 测试和存档界面都想事后查一下。
var last_reason := ""


func begin(from_scene: String = "") -> void:
	var id := from_scene if not from_scene.is_empty() else DataDB.start_scene
	if not DataDB.scenes.has(id):
		push_error("[BeatRunner] 起始场景不存在：%s" % id)
		_finish("bad_scene")
		return
	running = true
	awaiting_choice = false
	GameState.chapter = ""
	_enter(id)
	_pump()


## 从存档恢复：跳到某个场景的第 idx 拍。
func resume(from_scene: String, from_idx: int) -> void:
	if not DataDB.scenes.has(from_scene):
		push_error("[BeatRunner] 存档里的场景不存在：%s" % from_scene)
		_finish("bad_scene")
		return
	running = true
	awaiting_choice = false
	_enter(from_scene)
	# 落在存档记的那一拍上（而不是从头再播一遍）。
	idx = clampi(from_idx, 0, maxi(0, beats.size() - 1))
	_pump()


func stop() -> void:
	running = false
	awaiting_choice = false


func advance() -> void:
	if not running:
		return
	if awaiting_choice:
		# 选项没选就想往下走 —— 这是界面接错了线，不是玩家的问题。
		push_warning("[BeatRunner] 正在等选择，advance() 被忽略了")
		return
	idx += 1
	_pump()


## 玩家选了第 i 个选项。
func choose(i: int) -> void:
	if not running or not awaiting_choice:
		push_error("[BeatRunner] 没在等选择，choose() 被忽略了")
		return
	var beat: Dictionary = beats[idx]["beat"]
	var opts: Array = beat.get("opts", [])
	if i < 0 or i >= opts.size():
		push_error("[BeatRunner] 选项下标越界：%d / %d" % [i, opts.size()])
		return
	var o: Dictionary = opts[i]
	if o.has("cond") and not CondEval.eval_cond(o["cond"]):
		# 界面不该把不能选的选项渲染成可点的。真点到了，是界面的错。
		push_error("[BeatRunner] 选项 %d 的条件不满足，不该被选到" % i)
		return

	awaiting_choice = false

	var gain: Dictionary = o.get("gain", {})
	for k in gain:
		GameState.add_stat(str(k), int(gain[k]))
	if o.has("flag"):
		GameState.set_flag(str(o["flag"]), true)

	var to := str(o.get("to", ""))
	if not DataDB.scenes.has(to):
		push_error("[BeatRunner] 选项指向不存在的场景：%s" % to)
		_finish("bad_choice")
		return
	_enter(to)
	_pump()


## 当前这一拍的选项，供界面渲染。带「能不能选」和「为什么不能选」。
func current_options() -> Array:
	if not awaiting_choice or idx < 0 or idx >= beats.size():
		return []
	var out: Array = []
	var opts: Array = beats[idx]["beat"].get("opts", [])
	for i in opts.size():
		var o: Dictionary = opts[i]
		var enabled := true
		if o.has("cond"):
			enabled = CondEval.eval_cond(o["cond"])
		var lock_text := ""
		if o.has("lock"):
			lock_text = CondEval.eval_text(o["lock"])
		out.append({
			"index": i,
			"text": str(o.get("x", "")),
			"hint": str(o.get("hint", "")),
			"enabled": enabled,
			"lock": lock_text,
		})
	return out


func current_beat() -> Dictionary:
	if idx < 0 or idx >= beats.size():
		return {}
	return beats[idx]["beat"]


# ============================================================
#  内部
# ============================================================

func _enter(id: String) -> void:
	scene_id = id
	beats = DataDB.playable_bids(id)
	# 必须是 0，不能是 -1。
	#
	# 【踩过的坑】原来是 -1，想让 _pump 里的 `idx >= beats.size()` 判它「走完了」
	# 再进下一场。但 GDScript 的数组**负下标是绕回去的**：beats[-1] 不报错，
	# 它给你最后一个元素。于是每进一个场景，都先把它**最后一拍重播一遍**，
	# 然后才从头开始 —— 112 个场景，112 句散文被播了两遍。
	# 更阴的是：文本确实来自剧本（逐字比对过不了）、显示数与日志数也相等，
	# 只有「同一场景内 bid 必须递增」这条能抓到它。
	idx = 0

	# 【GameState 的书签必须在这里落】
	# 自动存档挂在 scene_entered 信号上，而那个信号是下面才发的；
	# 存档 meta 里的 scene/idx 读的正是 GameState。不在进场景这一刻把
	# 书签拨到位（idx 归零），自动存档就会拿着**上一个场景的最后一拍**
	# 当本场景的书签 —— 续玩时 clamp 到末尾，新场景的第一段永远跳不过去。
	GameState.scene = id
	GameState.idx = 0

	var sc: Dictionary = DataDB.scenes.get(id, {})
	var ch := str(sc.get("ch", ""))
	if not ch.is_empty() and ch != GameState.chapter:
		GameState.chapter = ch
		chapter_changed.emit(ch, str(sc.get("chTitle", "")))
	scene_entered.emit(id, sc)


## 推进到「下一拍可以给界面看」为止。用循环不用递归 ——
## 场景之间互相跳（_enter → _pump → _enter）递归下去，
## 碰到一串空场景会把调用栈吃光。
func _pump() -> void:
	while running:
		if idx >= beats.size():
			var to := _next_scene()
			if to.is_empty():
				_finish("no_next")
				return
			if slice_only and not DataDB.slice_set.has(to):
				_finish("slice_end")
				return
			_enter(to)
			continue

		var entry: Dictionary = beats[idx]
		var beat: Dictionary = entry["beat"]

		# 带条件的拍：条件不满足就当它不存在，连日志都不记。
		# VN 模式例外 —— 那个模式的全部意义就是把条件拿掉，好拿去跟原文逐字比对。
		if not vn_mode and beat.has("cond") and not CondEval.eval_cond(beat["cond"]):
			idx += 1
			continue

		_present(str(entry["bid"]), beat)
		return


func _present(bid: String, beat: Dictionary) -> void:
	last_bid = bid
	# 书签跟着走：自动存档在 choice_presented 时落盘，续玩要能精确
	# 回到「选项正摆着」的那一拍，靠的就是这个 idx。
	GameState.idx = idx
	match str(beat.get("t", "")):
		"choice":
			awaiting_choice = true
			_log(bid, beat)
			choice_presented.emit(bid, beat)
		"end":
			var id := str(beat.get("id", ""))
			GameState.unlock_ending(id)
			running = false
			story_finished.emit(id)
		"map":
			for m in beat.get("reveal", []):
				GameState.reveal_marker(str(m))
			_log(bid, beat)
			beat_entered.emit(bid, beat)
		_:
			_log(bid, beat)
			beat_entered.emit(bid, beat)


func _next_scene() -> String:
	var sc: Dictionary = DataDB.scenes.get(scene_id, {})
	var nx: Variant = sc.get("next")
	if nx is String:
		return nx
	if nx is Dictionary:
		return CondEval.eval_next(nx)
	return ""


## 每一拍都进回想日志（I5）。玩家跳过没看的闲笔，事后在回想屏还能读到。
func _log(bid: String, beat: Dictionary) -> void:
	var speaker := ""
	var text := ""
	match str(beat.get("t", "")):
		"n":
			text = str(beat.get("x", ""))
		"d":
			speaker = str(beat.get("w", ""))
			text = str(beat.get("x", ""))
		"q":
			speaker = str(beat.get("src", ""))
			text = str(beat.get("x", ""))
		"letter":
			speaker = "书信 · " + str(beat.get("title", ""))
			text = str(beat.get("body", ""))
		"choice":
			text = str(beat.get("prompt", ""))
		"map":
			text = str(beat.get("text", ""))
		_:
			return
	GameState.log_beat(bid, speaker, text)


func _finish(reason: String) -> void:
	running = false
	awaiting_choice = false
	last_reason = reason
	run_finished.emit(reason)
