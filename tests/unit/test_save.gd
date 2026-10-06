extends TestCase
## 存档：往返、原子性、迁移、损坏处理。
##
## 存档是最不该出错的地方 —— 它坏了，玩家几十小时的进度就没了，
## 而且是在他下次打开游戏时才知道。所以这里的断言比别处密。

const TEST_SLOT := "test"


func _cleanup() -> void:
	for s in [TEST_SLOT, "1", "auto"]:
		SaveManager.delete_slot(s)
	DirAccess.remove_absolute(SaveManager.slot_path(TEST_SLOT) + ".tmp")


func _seed_state() -> void:
	GameState.reset()
	GameState.chapter = "第一章"
	GameState.scene = "c1_father"
	GameState.idx = 12
	GameState.set_flag("c1_draft_a", true)
	GameState.set_flag("lin_shiye", true)
	GameState.stats["shen"] = 9
	GameState.stats["lin"] = 4
	GameState.log_beat("c1_home:3", "沈鹤龄", "家里的账，你来看。")
	GameState.log_beat("c1_home:4", "", "父亲把账册推过来。")
	GameState.unlock_ending("e3")
	GameState.mark_codex("第一章", "湘军故里")


# ============================================================
#  往返
# ============================================================

func test_round_trip_preserves_everything() -> void:
	_cleanup()
	_seed_state()

	var ok_save := SaveManager.save(TEST_SLOT,
		{"room": "r_study", "player_pos": [962, 806]},
		{"completed": {"q1": true}})
	ok(ok_save, "存档应当成功")
	ok(SaveManager.has_slot(TEST_SLOT), "存档文件应当存在")

	# 把状态清干净，确保读到的东西确实来自文件
	GameState.reset()
	eq(GameState.stats["shen"], 0, "reset 之后觉醒值应归零")

	var r := SaveManager.load_slot(TEST_SLOT)
	ok(r["ok"], "读档应当成功：%s" % r.get("error", ""))
	eq(GameState.chapter, "第一章", "章名")
	eq(GameState.scene, "c1_father", "场景")
	eq(GameState.idx, 12, "游标")
	eq(GameState.stats["shen"], 9, "沈怀瑾觉醒")
	eq(GameState.stats["lin"], 4, "林婉如觉醒")
	eq(GameState.has_flag("c1_draft_a"), true, "旗标 c1_draft_a")
	eq(GameState.has_flag("lin_shiye"), true, "旗标 lin_shiye")
	eq(GameState.has_flag("没设过的旗标"), false, "不存在的旗标应为假")
	eq(GameState.log.size(), 2, "回想日志条数")
	eq(GameState.log[0]["w"], "沈鹤龄", "日志第一条的说话人")
	eq(GameState.is_unlocked("e3"), true, "已解锁结局")
	eq(GameState.has_seen_codex("第一章", "湘军故里"), true, "看过的史实注")

	# 空间状态单独走 world，不进 story
	eq(r["world"]["room"], "r_study", "房间")
	# JSON 只有一个数字类型，Godot 解析回来一律是 float（962 → 962.0）。
	# 所以这里比数值，不比类型 —— 空间层接的时候也是 Vector2(x, y)，无碍。
	var pos: Array = r["world"]["player_pos"]
	eq(pos.size(), 2, "玩家坐标应当是二元数组")
	near(float(pos[0]), 962.0, 0.001, "玩家 x")
	near(float(pos[1]), 806.0, 0.001, "玩家 y")
	eq(r["quests"]["completed"]["q1"], true, "任务状态")
	_cleanup()


func test_meta_is_readable_without_full_load() -> void:
	# 存档格列表要在不反序列化整档的前提下显示章名、时间、末句
	_cleanup()
	_seed_state()
	SaveManager.save(TEST_SLOT)
	var m := SaveManager.peek(TEST_SLOT)
	eq(m.get("ch", ""), "第一章", "meta 章名")
	eq(int(m.get("shen", -1)), 9, "meta 里的觉醒值")
	ok(str(m.get("last", "")).contains("父亲"), "meta 末句应当是最后一条日志")
	ok(int(m.get("t", 0)) > 0, "meta 时间戳")
	_cleanup()


func test_slot_listing() -> void:
	_cleanup()
	_seed_state()
	SaveManager.save("1")
	SaveManager.save("auto")
	var slots := SaveManager.list_slots()
	eq(slots.size(), 5, "应当有 5 个手存格")
	eq(slots[0]["slot"], "1", "第一格编号")
	eq(slots[0]["exists"], true, "第 1 格应当已存")
	eq(slots[1]["exists"], false, "第 2 格应当为空")
	eq(slots[0]["meta"].get("ch", ""), "第一章", "第 1 格的章名")
	_cleanup()


# ============================================================
#  原子写
# ============================================================

func test_no_tmp_file_left_behind() -> void:
	# 改名成功之后临时文件不该还在 —— 留着的话，下次存盘会覆盖它，
	# 而且玩家目录里会多出一堆看不懂的文件
	_cleanup()
	_seed_state()
	SaveManager.save(TEST_SLOT)
	ok(not FileAccess.file_exists(SaveManager.slot_path(TEST_SLOT) + ".tmp"),
		"存完之后不该留下 .tmp")
	_cleanup()


func test_overwrite_is_clean() -> void:
	# 连续存两次（第二次数值不同），读回来必须是第二次的
	# 这一步验的是「改名覆盖」在 Windows 上真的行得通 —— 那里 MoveFile 遇到已存在的目标会失败
	_cleanup()
	_seed_state()
	SaveManager.save(TEST_SLOT)

	GameState.stats["shen"] = 17
	GameState.chapter = "第三章"
	SaveManager.save(TEST_SLOT)

	GameState.reset()
	var r := SaveManager.load_slot(TEST_SLOT)
	ok(r["ok"], "第二次存盘后应当能读出来")
	eq(GameState.stats["shen"], 17, "应当是第二次的值")
	eq(GameState.chapter, "第三章", "应当是第二次的章名")
	_cleanup()


func test_save_is_valid_json_on_disk() -> void:
	# 落盘的必须是一份能独立解析的 JSON —— 万一以后要用外部工具读档
	_cleanup()
	_seed_state()
	SaveManager.save(TEST_SLOT)
	var text := FileAccess.get_file_as_string(SaveManager.slot_path(TEST_SLOT))
	var d: Variant = JSON.parse_string(text)
	ok(d is Dictionary, "落盘内容应当是合法 JSON 对象")
	if d is Dictionary:
		eq(int(d.get("save_version", -1)), SaveManager.SAVE_VERSION, "save_version")
		has_key(d, "meta", "顶层 meta")
		has_key(d, "story", "顶层 story")
		has_key(d, "world", "顶层 world")
		has_key(d, "quests", "顶层 quests")
	_cleanup()


# ============================================================
#  损坏与迁移
# ============================================================

func test_corrupt_file_is_reported_not_crashed() -> void:
	_cleanup()
	var f := FileAccess.open(SaveManager.slot_path(TEST_SLOT), FileAccess.WRITE)
	f.store_string("{这不是合法 JSON 这不是")
	f.close()
	var r := SaveManager.load_slot(TEST_SLOT)
	eq(r["ok"], false, "坏档应当报失败而不是崩")
	ok(str(r.get("error", "")).length() > 0, "应当给出原因")
	_cleanup()


func test_missing_slot_is_reported() -> void:
	_cleanup()
	var r := SaveManager.load_slot("不存在的格")
	eq(r["ok"], false, "不存在的格应当报失败")
	_cleanup()


func test_future_version_is_refused() -> void:
	# 玩家的档来自更新的版本 —— 宁可拒绝并说清楚，也不要读出一半乱掉
	_cleanup()
	_seed_state()
	SaveManager.save(TEST_SLOT)
	var text := FileAccess.get_file_as_string(SaveManager.slot_path(TEST_SLOT))
	var d: Dictionary = JSON.parse_string(text)
	d["save_version"] = SaveManager.SAVE_VERSION + 5
	var f := FileAccess.open(SaveManager.slot_path(TEST_SLOT), FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()

	var r := SaveManager.load_slot(TEST_SLOT)
	eq(r["ok"], false, "更新版本的档应当被拒绝")
	_cleanup()


func test_v0_migrates_to_current() -> void:
	# 没有版本号的最早期档。现在还不存在，但迁移路径要提前验通 ——
	# 等真有玩家拿着 v0 的档来，才想起迁移没写就晚了。
	_cleanup()
	_seed_state()
	SaveManager.save(TEST_SLOT)
	var text := FileAccess.get_file_as_string(SaveManager.slot_path(TEST_SLOT))
	var d: Dictionary = JSON.parse_string(text)
	d.erase("save_version")
	var f := FileAccess.open(SaveManager.slot_path(TEST_SLOT), FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()

	var r := SaveManager.load_slot(TEST_SLOT)
	ok(r["ok"], "v0 档应当能迁移后读出来：%s" % r.get("error", ""))
	eq(GameState.chapter, "第一章", "迁移后内容应当还在")
	_cleanup()


func test_load_clears_previous_state() -> void:
	# 从一个存档切到另一个，上一次的旗标不能漏过来。
	# 漏过来的话会出现「读了 A 档却带着 B 档的旗标」这种极难查的 bug。
	_cleanup()
	_seed_state()
	SaveManager.save("1")

	GameState.reset()
	GameState.set_flag("只属于第二档的旗标", true)
	GameState.stats["shen"] = 99
	SaveManager.save("auto")

	SaveManager.load_slot("1")
	eq(GameState.stats["shen"], 9, "读第 1 格应回到第 1 格的值")
	eq(GameState.has_flag("只属于第二档的旗标"), false, "上一档的旗标不该漏过来")
	_cleanup()


func test_autosave_uses_auto_slot() -> void:
	_cleanup()
	_seed_state()
	ok(SaveManager.autosave(), "自动存档应当成功")
	ok(SaveManager.has_slot("auto"), "应当落在 auto 格")
	ok(not SaveManager.has_slot("1"), "不该碰手存格")
	_cleanup()


## 【这一条是为一个具体的坑写的，别删】
## 存档有两个入口：VN 屏（走剧情时自动存）和房间（走动时存）。
## VN 屏手上**没有**空间状态，调 save() 时只会传一个空字典。
## 早期实现直接把传进来的那个空字典当 world —— 于是
## 「在房间里查了一圈东西，回剧情走两步，进度就全没了」，
## 而且不报错、不崩溃，玩家下次打开才发现。
## 所以 build_save 改成「默认从 GameState 取一份，调用方传的再盖上去」。
func test_a_story_side_save_does_not_wipe_the_world() -> void:
	_cleanup()
	_seed_state()
	GameState.room = "r_tea"
	GameState.player_pos = Vector2(640, 590)
	GameState.mark_examined("tea.cup")

	# 空 world —— 这就是 VN 屏那边传的样子
	ok(SaveManager.save(TEST_SLOT), "剧情侧存档应当成功")

	GameState.reset()
	eq(GameState.room, "", "reset 之后房间应当清空（否则下面验不出东西）")

	var r := SaveManager.load_slot(TEST_SLOT)
	ok(r["ok"], "读档应当成功：%s" % r.get("error", ""))
	eq(GameState.room, "r_tea", "剧情侧的存档不该把房间抹掉")
	eq(GameState.has_examined("tea.cup"), true, "查过的物件也该还在")
	near(GameState.player_pos.x, 640.0, 0.001, "站位 x 应当保住")
	near(GameState.player_pos.y, 590.0, 0.001, "站位 y 应当保住")
	_cleanup()
