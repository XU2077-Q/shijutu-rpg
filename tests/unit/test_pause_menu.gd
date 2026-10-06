extends TestCase
## 暂停菜单及其子面板（存档格 / 时局图 / 史实注一览）。
##
## 【为什么值得测】
## Esc 原来在两个屏里都是「直接回标题」。改成弹暂停之后，最容易出的两类错：
##   一、菜单开了，游戏还在接键（小人继续走、空格继续翻页）；
##   二、存档覆盖一个点击就生效，手快抹掉旧档。
## 还有读档后的路由（有房间进房间屏），错了不会崩，只会把玩家丢错地方。

const ROOM_SCENE := "res://scenes/world/room.tscn"
const VN_SCENE := "res://scenes/vn/vn_screen.tscn"


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	return ev


func _open_room(room_id: String) -> Variant:
	AppSettings.pending_spine = false
	AppSettings.pending_resume = false
	AppSettings.pending_room = room_id
	AppSettings.pending_at = Vector2.INF
	var v: Variant = load(ROOM_SCENE).instantiate()
	host.add_child(v)
	for i in 3:
		await host.get_tree().process_frame
	return v


# ============================================================
#  暂停菜单本身
# ============================================================

func test_pause_menu_starts_closed_and_opens() -> void:
	var p := PauseMenu.new()
	host.add_child(p)
	await host.get_tree().process_frame
	ok(not p.is_open(), "新建的暂停菜单应当是关着的")
	p.open()
	ok(p.is_open(), "open() 之后应当开着")
	# GDScript 的 lambda 按值捕获局部变量，里面赋值传不出来 —— 用盒子装。
	var resumed := [false]
	p.resumed.connect(func() -> void: resumed[0] = true)
	p.resume_game()
	ok(not p.is_open() and resumed[0], "继续游戏应当关菜单并发信号")
	p.queue_free()
	await host.get_tree().process_frame


func test_esc_toggles_pause_in_the_room_instead_of_leaving() -> void:
	var v: Variant = await _open_room("r_tea")
	var p: Variant = v.get("_pause")
	ok(p != null and not bool(p.is_open()), "开局时暂停菜单应当关着")

	v._unhandled_input(_key(KEY_ESCAPE))
	ok(bool(p.is_open()), "按 Esc 应当弹出暂停菜单，而不是直接回标题")

	# 菜单开着时，推进键不该再落到游戏里：
	# 脊梁缝里按空格本会闪一句「附近没有…」，菜单开着时该被早返回挡住。
	v.set("_spine", true)
	v.set("_playing", false)
	var ev := InputEventAction.new()
	ev.action = "ui_advance"
	ev.pressed = true
	v._unhandled_input(ev)
	ok(float(v.get("_fail").modulate.a) == 0.0,
		"菜单开着时推进不该落到游戏（那句提示不该被点亮）")
	v.set("_spine", false)

	# 菜单面板开着时 Esc = 继续（子面板都没开）
	p._input(_key(KEY_ESCAPE))
	ok(not bool(p.is_open()), "再按 Esc 应当继续游戏")

	# 反向验一遍，防这条断言假绿：菜单关着、站在脊梁缝里按空格，
	# 那句「附近没有…」就该亮起来。
	v.set("_spine", true)
	v._unhandled_input(ev)
	ok(float(v.get("_fail").modulate.a) > 0.0,
		"菜单关着时按空格落空，提示应当亮起来")
	v.set("_spine", false)
	v.queue_free()
	await host.get_tree().process_frame


func test_esc_opens_pause_in_vn_when_no_modal() -> void:
	GameState.reset()
	BeatRunner.stop()
	BeatRunner.slice_only = true
	var screen: Variant = load(VN_SCENE).instantiate()
	host.add_child(screen)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var p: Variant = screen.get("_pause")
	screen._unhandled_input(_key(KEY_ESCAPE))
	ok(bool(p.is_open()), "VN 屏按 Esc 应当弹暂停（不再是直接回标题）")
	screen.queue_free()
	await host.get_tree().process_frame


# ============================================================
#  存档格：覆盖二次确认
# ============================================================

func test_saving_requires_a_second_click() -> void:
	SaveManager.delete_slot("5")
	var s := SaveSlots.new()
	host.add_child(s)
	await host.get_tree().process_frame
	s.open(SaveSlots.Mode.SAVE)
	eq(s.row_count(), 5, "永远是五格")

	ok(not SaveManager.has_slot("5"), "用例起点：第 5 格是空的")
	s._on_row("5")
	ok(not SaveManager.has_slot("5"), "第一下只该拿起，不该真写")
	s._on_row("5")
	# 第二次按下后有个 0.4 秒的关闭 tween，写档在它之前。
	ok(SaveManager.has_slot("5"), "第二下才该真的存进去")

	# 覆盖旧档也要两下 —— 比文件内容，比修改时间稳（同一秒内 mtime 相同）。
	s.open(SaveSlots.Mode.SAVE)
	var before := FileAccess.get_file_as_string(SaveManager.slot_path("5"))
	# 改点别的再覆盖（更新「最后一句」）
	GameState.log_beat("x:1", "", "覆盖前的旧句")
	s._on_row("5")
	ok(FileAccess.get_file_as_string(SaveManager.slot_path("5")) == before,
		"覆盖已有档，第一下也不该写")
	s._on_row("5")
	ok(FileAccess.get_file_as_string(SaveManager.slot_path("5")) != before,
		"第二下才覆盖")
	SaveManager.delete_slot("5")
	s.queue_free()
	await host.get_tree().process_frame


func test_load_mode_disables_empty_slots() -> void:
	SaveManager.delete_slot("4")
	var s := SaveSlots.new()
	host.add_child(s)
	await host.get_tree().process_frame
	s.open(SaveSlots.Mode.LOAD)
	var rows := s.find_children("*", "Button", true, false)
	var empty: Button = rows[3]
	ok(bool(empty.disabled), "空格在读档模式应当是灰的")
	s.queue_free()
	await host.get_tree().process_frame


func test_loading_a_room_save_routes_to_the_room_screen() -> void:
	# 造一份「有房间」的档，读它，路由应当指向房间屏。
	GameState.reset()
	GameState.room = "r_tea"
	SaveManager.save("5", GameState.world_dict())

	var p := PauseMenu.new()
	host.add_child(p)
	await host.get_tree().process_frame
	AppSettings.pending_spine = false
	AppSettings.pending_resume = false
	# change_scene_to_file 会换掉跑架，不能真调；只验它摆好的路标。
	var route1 := p.route_after_load()
	ok(AppSettings.pending_spine and AppSettings.pending_resume and route1 == ROOM_SCENE,
		"读房间档应当摆好 spine + resume，去房间屏")

	# 无房间的档 → VN 屏路标
	GameState.reset()
	SaveManager.save("5", GameState.world_dict())
	var route2 := p.route_after_load()
	ok(not AppSettings.pending_spine and AppSettings.pending_resume and route2 == VN_SCENE,
		"读纯 VN 档应当只摆 resume，去 VN 屏")
	SaveManager.delete_slot("5")
	p.queue_free()
	await host.get_tree().process_frame


# ============================================================
#  时局图：未揭不露
# ============================================================

func test_markers_hide_themselves_before_reveal() -> void:
	GameState.reset()
	var m := MarkerOverview.new()
	host.add_child(m)
	await host.get_tree().process_frame
	m.open()
	var texts := PackedStringArray()
	for l in m.find_children("*", "Label", true, false):
		texts.append((l as Label).text)
	var has_q := false
	var has_unknown := false
	for t in texts:
		if t == "？":
			has_q = true
		if t.find("尚 未 显 现") >= 0:
			has_unknown = true
	ok(has_q, "一个都没揭时应当有「？」")
	ok(has_unknown, "一个都没揭时应当写「尚未显现」")

	# 揭一个，它的名字和说明就得露出来
	var first_id := str(DataDB.markers[0].get("id", ""))
	var first_name := str(DataDB.markers[0].get("name", ""))
	GameState.reveal_marker(first_id)
	m.queue_free()
	await host.get_tree().process_frame
	m = MarkerOverview.new()
	host.add_child(m)
	await host.get_tree().process_frame
	m.open()
	var names := PackedStringArray()
	for l in m.find_children("*", "Label", true, false):
		names.append((l as Label).text)
	var found := false
	for t in names:
		if t == first_name:
			found = true
	ok(found, "揭过的印章应当露出名字：%s" % first_name)
	m.queue_free()
	await host.get_tree().process_frame


# ============================================================
#  史实注一览
# ============================================================

func test_notes_browser_lists_every_note() -> void:
	var expect := 0
	for ch in DataDB.notes:
		expect += (DataDB.notes[ch] as Array).size()
	ok(expect >= 50, "数据里应当有五十条以上的史实注（实有 %d）" % expect)

	var b := NotesBrowser.new()
	host.add_child(b)
	await host.get_tree().process_frame
	b.open()
	eq(b.entry_count(), expect, "一览应当一条不少")
	ok(not b.body_text().is_empty(), "默认选第一条，正文不该是空的")

	# 点一条之后应当被记为已读（行首变 ✓）
	var e: Dictionary = b.get("_entries")[0]
	var key := [str(e["ch"]), str(e["h"])]
	ok(GameState.has_seen_codex(key[0], key[1]), "看过的注应当记入 codex_seen")
	b.queue_free()
	await host.get_tree().process_frame
