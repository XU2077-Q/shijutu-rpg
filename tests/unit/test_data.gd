extends TestCase
## 剧本数据的完整性。
##
## 这些断言大多在 tools/export_story.js 里已经跑过一遍了。这里再跑一遍不是重复 ——
## 导出器验的是「导出那一刻数据对不对」，这里验的是「游戏读到的这份对不对」。
## 中间隔着 JSON 序列化、Godot 的解析、以及**人手改档**的可能。
## 两处都绿，才说明玩家看到的就是校验过的那份。

## 垂直切片的 23 个场景。第一章 + 序章。
const SLICE := ["p_intro", "p_tea", "p_choice1", "p_ci", "p_ke", "p_gongche", "p_night",
	"p_lijm", "p_end", "c1_shanghai", "c1_home", "c1_village", "c1_father", "c1_choice",
	"c1_cons", "c1_rad", "c1_yanfu", "c1_draft", "c1_draft_a", "c1_draft_b", "c1_draft_c",
	"c1_miyue", "c1_end"]

## 切片范围内的 9 条扩写
const SLICE_EXPANSIONS := [1, 2, 3, 4, 5, 6, 7, 8, 9]


# ============================================================
#  DataDB 自己报的错
# ============================================================

func test_datadb_has_no_errors() -> void:
	# DataDB 在 _ready 里已经全量校验过（V1~V6）。这里只是把它的结论亮出来，
	# 失败信息直接列出，省得再去翻启动日志。
	ok(DataDB.errors.is_empty(),
		"DataDB 报了 %d 条校验错误：\n          %s"
			% [DataDB.errors.size(), "\n          ".join(DataDB.errors)])


func test_world_has_no_orphan_scenes() -> void:
	# V6 只把走不到的**扩写节点**当错误，其余走不到的只算 warning。
	# 但切片范围内的场景走不到，那就是真错了 —— 它们本该都在主线上。
	var unreachable: PackedStringArray = []
	for w in DataDB.warnings:
		for id in SLICE:
			if w.begins_with("场景 %s " % id):
				unreachable.append(id)
	ok(unreachable.is_empty(), "切片场景走不到：%s" % ", ".join(unreachable))


# ============================================================
#  总量
# ============================================================

func test_scene_and_beat_counts() -> void:
	var exp_nodes := 0
	var beats := 0
	for id in DataDB.scenes:
		beats += (DataDB.scenes[id].get("beats", []) as Array).size()
		if DataDB.scenes[id].has("expansion"):
			exp_nodes += 1
	eq(exp_nodes, 31, "扩写节点数")
	eq(DataDB.scenes.size(), 112, "场景总数（原文 81 + 扩写 31）")
	eq(beats, 2375, "节拍总数（原文 2193 + 扩写 182）")


func test_metadata_counts() -> void:
	eq(DataDB.endings.size(), 5, "结局数")
	eq(DataDB.markers.size(), 6, "印章数")
	eq(DataDB.expansions.size(), 31, "扩写条目数")
	eq(DataDB.notes.size(), 6, "史实注章数")


# ============================================================
#  原文没被动过
# ============================================================

func test_start_scene_is_intro() -> void:
	eq(DataDB.start_scene, "p_intro", "起始场景")


func test_original_beats_are_untouched_by_supersede() -> void:
	# supersede 是**播放时**顶替，不是把原文删掉。
	# 原文那一拍必须还在 beats 里 —— 回想屏要靠它。
	var c3: Dictionary = DataDB.scenes.get("c3_s4a", {})
	has_key(c3, "supersede", "c3_s4a 应当有 supersede（第 14 条扩写顶替了它的一拍）")
	var sup: Array = c3.get("supersede", [])
	eq(sup.size(), 1, "c3_s4a 的 supersede 条数")
	if sup.size() == 1:
		var i := int(sup[0]["beat"])
		var beats: Array = c3["beats"]
		ok(i >= 0 and i < beats.size(), "supersede 的拍号 %d 越界" % i)
		if i >= 0 and i < beats.size():
			var x: String = str(beats[i].get("x", ""))
			ok(x.begins_with("有一个学生回来说"),
				"被顶替的那一拍应当还在 beats 里，实际拿到：%s" % x)


func test_supersede_actually_takes_effect_when_playing() -> void:
	# 播放序列里，那一拍应当被替换者的节拍取代
	var c3: Dictionary = DataDB.scenes.get("c3_s4a", {})
	var playable := DataDB.playable_beats("c3_s4a")
	var raw: Array = c3.get("beats", [])
	var x14: Array = DataDB.scenes.get("x14", {}).get("beats", [])
	eq(playable.size(), raw.size() - 1 + x14.size(),
		"c3_s4a 播放序列长度（原文 %d 拍，去掉 1 拍、换成 %d 拍）" % [raw.size(), x14.size()])
	var joined := ""
	for b in playable:
		joined += str(b.get("x", b.get("body", "")))
	ok(joined.contains("柳先生"), "播放序列里应当出现第 14 条扩写的内容（塾师柳先生）")


func test_playable_equals_raw_when_no_supersede() -> void:
	# 绝大多数场景没有 supersede，播放序列必须与原文逐拍一致、顺序一致
	var checked := 0
	for id in DataDB.scenes:
		var sc: Dictionary = DataDB.scenes[id]
		if sc.has("supersede") or sc.has("expansion"):
			continue
		var raw: Array = sc.get("beats", [])
		var playable := DataDB.playable_beats(id)
		if playable.size() != raw.size():
			fail("%s 播放序列长度 %d ≠ 原文 %d" % [id, playable.size(), raw.size()])
			continue
		for i in raw.size():
			checked += 1
			if str(raw[i].get("x", raw[i].get("body", ""))) != str(playable[i].get("x", playable[i].get("body", ""))):
				fail("%s 第 %d 拍播放序列与原文不一致" % [id, i])
				break
	ok(checked > 2000, "应当检查了 2000 拍以上，实际 %d" % checked)


# ============================================================
#  寻址：每个 bid 唯一且可寻回
# ============================================================

func test_every_beat_is_addressable_and_unique() -> void:
	# bid = "场景id:序号"。这是回想屏、story_map 路由、存档共用的坐标。
	# 重复或取不回来，这三样都会静默错位。
	var seen := {}
	var dup: PackedStringArray = []
	var missing: PackedStringArray = []
	for id in DataDB.scenes:
		var beats: Array = DataDB.scenes[id].get("beats", [])
		for i in beats.size():
			var bid := "%s:%d" % [id, i]
			if seen.has(bid):
				dup.append(bid)
			seen[bid] = true
			if DataDB.get_beat(bid).is_empty():
				missing.append(bid)
	eq(dup.size(), 0, "重复的 bid：%s" % ", ".join(dup.slice(0, 8)))
	eq(missing.size(), 0, "取不回来的 bid：%s" % ", ".join(missing.slice(0, 8)))
	eq(seen.size(), 2375, "bid 总数")


# ============================================================
#  条件 AST
# ============================================================

func test_no_beat_holds_a_raw_function() -> void:
	# 导出器承诺「认不出来的函数一律 throw」。这里反过来查一遍：
	# 数据里不该再有任何函数痕迹。有的话说明导出器漏了一处，
	# 而那处的条件在运行时会被当成「不存在」—— 最阴的一种错。
	var suspects: PackedStringArray = []
	for id in DataDB.scenes:
		var sc: Dictionary = DataDB.scenes[id]
		for i in (sc.get("beats", []) as Array).size():
			var b: Dictionary = sc["beats"][i]
			for k in ["cond", "lock"]:
				if b.has(k) and not (b[k] is Dictionary):
					suspects.append("%s:%d.%s = %s" % [id, i, k, str(b[k]).substr(0, 40)])
			for j in (b.get("opts", []) as Array).size():
				var o: Dictionary = b["opts"][j]
				for k in ["cond", "lock"]:
					if o.has(k) and not (o[k] is Dictionary):
						suspects.append("%s:%d.opt%d.%s" % [id, i, j, k])
	eq(suspects.size(), 0, "残留的函数值字段：%s" % ", ".join(suspects))


func test_slice_has_no_conditional_ast() -> void:
	# 设计上，全部 18 处条件都在 c2_end / c4_end / c5_choice —— 都不在切片里。
	# 这条断言锁住这个事实：切片的关键路径上不需要求值器。
	# 哪天有人在切片里加了条件，这里会红，提醒他求值器已经不能拖了。
	var hits: PackedStringArray = []
	for id in SLICE:
		if not DataDB.scenes.has(id):
			continue
		for i in (DataDB.scenes[id].get("beats", []) as Array).size():
			var b: Dictionary = DataDB.scenes[id]["beats"][i]
			if b.has("cond") or b.has("lock"):
				hits.append("%s:%d" % [id, i])
			for j in (b.get("opts", []) as Array).size():
				var o: Dictionary = b["opts"][j]
				if o.has("cond") or o.has("lock"):
					hits.append("%s:%d.opt%d" % [id, i, j])
	eq(hits.size(), 0, "切片里出现了条件 AST：%s" % ", ".join(hits))


func test_all_ast_ops_are_known() -> void:
	# DataDB 的 V5 已经查过，这里再独立数一遍形状，顺便锁住总数
	var shapes := {}
	_walk_all_ast(func(node: Dictionary, where: String) -> void:
		var op: String = node.get("op", "")
		shapes[op] = int(shapes.get(op, 0)) + 1
	)
	# 15 处 beat 级 cond（lin_shiye 4 + lin_qingbao 6 + lin_youyu 5）
	# 加上 c4_end.next 那个 if 节点的条件（也是 flag）＝ 16 个 flag 节点
	eq(int(shapes.get("flag", 0)), 16, "flag 节点数（15 处 cond + if 里的 1 处）")
	eq(int(shapes.get("if", 0)), 1, "if 节点数（c4_end.next 的台湾分岔）")
	eq(int(shapes.get("and", 0)), 1, "and 节点数（c5_choice 的双门槛）")
	eq(int(shapes.get("template", 0)), 1, "template 节点数（c5_choice 的锁提示）")


# ============================================================
#  扩写
# ============================================================

func test_expansion_anchors_exist() -> void:
	var bad: PackedStringArray = []
	for e in DataDB.expansions:
		if not DataDB.scenes.has(e.get("anchor", "")):
			bad.append("第 %d 条「%s」→ 锚点 %s 不存在"
				% [e.get("run", -1), e.get("title", ""), e.get("anchor", "")])
	eq(bad.size(), 0, "锚点不存在：%s" % "；".join(bad))


func test_slice_expansions_are_the_expected_nine() -> void:
	var got: Array = []
	for e in DataDB.expansions:
		if SLICE.has(e.get("anchor", "")):
			got.append(int(e.get("run", -1)))
	got.sort()
	eq(got, SLICE_EXPANSIONS, "切片范围内的扩写 run 编号")


func test_every_expansion_has_beats_and_a_kind() -> void:
	var kinds := {}
	for e in DataDB.expansions:
		var n := (e.get("beats", []) as Array).size()
		ok(n > 0, "第 %d 条「%s」一拍都没有" % [e.get("run", -1), e.get("title", "")])
		var k: String = e.get("kind", "")
		kinds[k] = int(kinds.get(k, 0)) + 1
	eq(int(kinds.get("背景", 0)), 10, "背景类扩写数")
	eq(int(kinds.get("小人物", 0)), 9, "小人物类扩写数")
	eq(int(kinds.get("感情线", 0)), 9, "感情线类扩写数")
	eq(int(kinds.get("主角线", 0)), 3, "主角线类扩写数")


# ============================================================
#  切片本身
# ============================================================

func test_slice_scenes_all_exist() -> void:
	var missing: PackedStringArray = []
	for id in SLICE:
		if not DataDB.scenes.has(id):
			missing.append(id)
	eq(missing.size(), 0, "切片缺场景：%s" % ", ".join(missing))


func test_slice_original_beat_count() -> void:
	var n := 0
	for id in SLICE:
		if DataDB.scenes.has(id):
			n += (DataDB.scenes[id].get("beats", []) as Array).size()
	eq(n, 477, "切片原文节拍数")


## 切片的每一场都得有地点牌上的字。
##
## 【为什么这条值得单列】
## 31 个扩写节点原本全是 `place: ""`，于是玩家走到那儿，左上角那块牌子
## 是**空白**的 —— 不报错、不警告、测试也不红（没有任何一条用例问过
## 「地点是空的吗」）。整整 9 场戏，占切片的四分之一。
##
## 这类「某个字段是空串」的毛病最不值钱也最容易漏：它不影响任何逻辑，
## 只是画面上少一块字。所以与其一条条盯着看，不如在这里一次钉死。
## 日期不强制 —— 「题记」那一场本来就没有日期。
func test_every_slice_scene_has_a_place() -> void:
	var blank: PackedStringArray = []
	for id in DataDB.slice:
		if not DataDB.scenes.has(id):
			continue
		if str(DataDB.scenes[id].get("place", "")).is_empty():
			blank.append(id)
	ok(blank.is_empty(),
		"这些场景没有地点，走到那儿左上角的牌子会是空白：%s\n          "
		% ", ".join(blank) +
		"扩写节点默认继承锚点场景的地点（见 tools/export_story.js 的 splice）；\n"
		+ "         正文自己换了场的那几条，要在 data/expansion_map.json 里写 place。")


# ============================================================
#  文本
# ============================================================

func test_no_bbcode_metacharacters_in_prose() -> void:
	# Godot 的 RichTextLabel 用 BBCode。正文里若出现 [ ] { }，
	# 会被当成标签吃掉或直接报错。导出器已经查过，这里护住手改的情况。
	# 例外只有史实注里的 [ref]…[/ref]，那是我们自己放进去的。
	var bad: PackedStringArray = []
	_scan_text(func(where: String, s: String) -> void:
		var t := s.replace("[ref]", "").replace("[/ref]", "")
		if t.contains("[") or t.contains("]") or t.contains("{") or t.contains("}"):
			bad.append("%s = %s" % [where, s.substr(0, 40)])
	)
	eq(bad.size(), 0, "正文含 BBCode 元字符：%s" % "；".join(bad.slice(0, 6)))


func test_all_five_endings_have_bodies() -> void:
	for e in DataDB.endings:
		ok(not str(e.get("id", "")).is_empty(), "结局缺 id")
		ok(str(e.get("body", "")).length() > 100,
			"结局「%s」正文太短（%d 字）" % [e.get("name", ""), str(e.get("body", "")).length()])


# ============================================================
#  遍历工具
# ============================================================

func _walk_all_ast(cb: Callable) -> void:
	for id in DataDB.scenes:
		var sc: Dictionary = DataDB.scenes[id]
		var nx: Variant = sc.get("next")
		if nx is Dictionary:
			_collect(nx, cb)
		for b in sc.get("beats", []):
			for k in ["cond", "lock"]:
				if b.has(k) and b[k] is Dictionary:
					_collect(b[k], cb)
			for o in b.get("opts", []):
				for k in ["cond", "lock"]:
					if o.has(k) and o[k] is Dictionary:
						_collect(o[k], cb)


func _collect(node: Dictionary, cb: Callable) -> void:
	cb.call(node, "")
	for k in ["cond", "lhs", "rhs", "arg"]:
		if node.has(k) and node[k] is Dictionary:
			_collect(node[k], cb)
	for k in ["args"]:
		for a in node.get(k, []):
			if a is Dictionary:
				_collect(a, cb)


func _scan_text(cb: Callable) -> void:
	for id in DataDB.scenes:
		var sc: Dictionary = DataDB.scenes[id]
		for i in (sc.get("beats", []) as Array).size():
			var b: Dictionary = sc["beats"][i]
			for k in b.keys():
				if k in ["opts", "bid", "t"]:
					continue
				if b[k] is String:
					cb.call("%s:%d.%s" % [id, i, k], b[k])
			for j in (b.get("opts", []) as Array).size():
				var o: Dictionary = b["opts"][j]
				for k in o.keys():
					if o[k] is String:
						cb.call("%s:%d.opt%d.%s" % [id, i, j, k], o[k])
