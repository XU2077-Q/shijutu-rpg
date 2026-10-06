extends TestCase
## 任务栏：QuestManager 的游标推导、Q 组数据校验、任务条 / 任务一览界面、
## 以及「状态不存盘、从游标与印章现算」这件事本身（存档往返后状态仍对）。

const PROLOGUE_GOALS := 9
const BEAR_GOALS := 11


func test_quest_data_is_present_and_valid() -> void:
	eq(QuestManager.quest_defs().size(), 2, "切片有两条任务线（序章 / 第一章）")
	ok(DataDB.errors.is_empty(), "Q 组校验不该有报错（启动时已经验过）")
	var n := 0
	for q in QuestManager.quest_defs():
		n += (q.get("goals", []) as Array).size()
	eq(n, PROLOGUE_GOALS + BEAR_GOALS, "目标条数：序章 9 + 第一章 11")


func test_state_follows_the_spine_cursor() -> void:
	GameState.reset()
	ok(QuestManager.current().is_empty(), "游标为空时没有在做的任务")
	eq(QuestManager.current_goal(), "", "也没有目标文字")

	GameState.scene = "p_intro"
	eq(str(QuestManager.current().get("id", "")), "prologue", "题记处序章任务开始")
	ok(QuestManager.current_title().contains("春愁"), "章题应当是「序章 · 春愁」")
	ok(not QuestManager.current_goal().is_empty(), "当下目标不能为空")
	eq(QuestManager.state_of(QuestManager.quest_defs()[1]), QuestManager.State.LOCKED,
		"第一章任务此刻应当锁着")

	GameState.scene = "p_gongche"
	ok(QuestManager.current_goal().contains("都察院"), "都察院一场的目标该提到都察院")

	# 脊梁上每一场都必须有在做的任务和非空目标（分支场景回退到最近的锚点）。
	for id in DataDB.spine:
		GameState.scene = str(id)
		ok(not QuestManager.current().is_empty(), "脊梁场景 %s 时应当有任务" % id)
		ok(not QuestManager.current_goal().is_empty(), "脊梁场景 %s 的目标不能为空" % id)

	# 章末印章一揭，序章就算完 —— 哪怕游标还在 p_end。
	GameState.scene = "p_end"
	eq(QuestManager.state_of(QuestManager.quest_defs()[0]), QuestManager.State.ACTIVE,
		"印章还没揭、游标在末场：仍是进行中")
	GameState.reveal_marker("jp")
	eq(QuestManager.state_of(QuestManager.quest_defs()[0]), QuestManager.State.DONE,
		"印章揭了 = 任务完成")

	GameState.scene = "c1_shanghai"
	eq(str(QuestManager.current().get("id", "")), "bear", "第一章开场，当前任务换成「熊」")
	eq(QuestManager.state_of(QuestManager.quest_defs()[0]), QuestManager.State.DONE,
		"游标过了 end，序章同样算完（不依赖印章）")


func test_quest_state_round_trips_through_a_save_without_being_saved() -> void:
	GameState.reset()
	GameState.scene = "p_end"
	GameState.reveal_marker("jp")
	SaveManager.delete_slot("5")
	ok(SaveManager.save("5", GameState.world_dict()), "存档应当成功")

	GameState.reset()
	ok(not GameState.is_marker_revealed("jp"), "复位后印章应当没了")
	var d := SaveManager.load_slot("5")
	ok(bool(d.get("ok", false)), "读档应当成功")
	ok(GameState.is_marker_revealed("jp"), "印章随档回来")
	# 游标本身存在剧情档里（不是 world），这里手动摆到末场，验完成状态是现算的。
	GameState.scene = "p_end"
	eq(QuestManager.state_of(QuestManager.quest_defs()[0]), QuestManager.State.DONE,
		"完成状态必须能从存档里的东西重新算出来")
	SaveManager.delete_slot("5")


func test_quest_bar_shows_and_hides() -> void:
	GameState.reset()
	var bar := QuestBar.new()
	host.add_child(bar)
	await host.get_tree().process_frame
	bar.refresh()
	ok(not bar.visible, "没进剧情时任务条应当藏着")

	GameState.scene = "p_tea"
	bar.refresh()
	ok(bar.visible, "进了茶楼任务条该出现")
	ok(bar.chapter_text().contains("春愁"), "章题：" + bar.chapter_text())
	ok(bar.goal_text().contains("广和茶楼"), "目标该是茶楼里的事：" + bar.goal_text())

	GameState.reveal_marker("jp")
	GameState.scene = "c1_end"
	GameState.reveal_marker("ru")
	bar.refresh()
	ok(not bar.visible, "两条任务都完了，任务条该藏起")
	bar.queue_free()
	await host.get_tree().process_frame


func test_quest_log_hides_locked_quest_and_marks_the_current_goal() -> void:
	GameState.reset()
	GameState.scene = "p_tea"
	var log := QuestLog.new()
	host.add_child(log)
	await host.get_tree().process_frame
	log.open()

	var texts := PackedStringArray()
	for l in log.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	var joined := "\n".join(texts)
	ok(joined.contains("尚 未 开 始"), "没走到的任务不露题")
	ok(not joined.contains("熊"), "「熊」这个题不该提前露")
	ok(joined.contains("春愁"), "当前任务要露题")
	ok(joined.contains("●"), "当前目标要有实心标记")
	ok(joined.contains("✓"), "翻过的目标要打勾")

	# 推进到第一章：序章整段变「已竟」，熊变成进行中。
	GameState.reveal_marker("jp")
	GameState.scene = "c1_father"
	log.open()
	texts = PackedStringArray()
	for l in log.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	joined = "\n".join(texts)
	ok(joined.contains("已竟"), "序章任务应当标成已竟")
	ok(joined.contains("熊"), "第一章任务该露题了")
	log.queue_free()
	await host.get_tree().process_frame


func test_quest_log_opens_from_the_pause_menu() -> void:
	GameState.reset()
	GameState.scene = "p_tea"
	var p := PauseMenu.new()
	host.add_child(p)
	await host.get_tree().process_frame
	p.open()

	var btn: Button = null
	for b in p.find_children("*", "Button", true, false):
		if (b as Button).text.replace(" ", "").replace("　", "").contains("任务"):
			btn = b
	ok(btn != null, "暂停菜单里应当有「任务」按钮")
	btn.emit_signal("pressed")
	await host.get_tree().process_frame
	ok(p.get("_quests") != null and bool((p.get("_quests") as Control).visible),
		"点下去任务一览应当打开")
	ok(not bool((p.get("_panel") as Control).visible), "主面板应当让出来")

	# Esc 先关子面板，回主面板，不能连带把暂停整个关掉。
	#
	# 【必须走真 viewport 派发】事件先到最上层的子面板（viewport 倒序派
	# _input），**同一帧**再到 PauseMenu。早先测试直接调子面板的 _input，
	# 结果真 bug 漏掉了：子面板关了自己之后，主菜单这一层看 _sub_open()
	# 已是 false，就把「Esc = 继续游戏」也触发了 —— 按一下 Esc 三层全关。
	var resumed := [false]
	p.resumed.connect(func() -> void: resumed[0] = true)
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	host.get_viewport().push_input(ev, false)
	var log_panel: Variant = p.get("_quests")
	ok(not bool((log_panel as Control).visible), "任务一览应当已关")
	ok(bool((p.get("_panel") as Control).visible), "子面板关了，主面板应当回来")
	ok(bool(p.is_open()) and not resumed[0], "Esc 关的是任务一览，暂停菜单必须还开着")
	p.queue_free()
	await host.get_tree().process_frame


func test_q_validation_rejects_a_broken_quest_table() -> void:
	var saved := DataDB.quests.duplicate(true)
	var before := DataDB.errors.size()
	DataDB.quests = {
		"quests": [{
			"id": "bad",
			"start": "p_intro",
			"end": "p_tea",
			"marker": "no_such_power",
			"goals": [
				{"at": "c1_end", "text": "锚点在区间外"},
				{"at": "p_intro", "text": "顺序反了"},
			],
		}],
	}
	DataDB._validate_quests()
	var got := PackedStringArray()
	for i in range(before, DataDB.errors.size()):
		got.append(DataDB.errors[i])
	var joined := "\n".join(got)
	ok(joined.contains("no_such_power"), "印章不存在该报错")
	ok(joined.contains("区间外"), "锚点越界该报错")
	ok(joined.contains("顺序"), "锚点顺序错该报错")
	DataDB.quests = saved
	DataDB.errors.resize(before)
