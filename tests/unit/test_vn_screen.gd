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
