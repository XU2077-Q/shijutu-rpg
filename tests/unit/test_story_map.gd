extends TestCase
## 叙事路由（data/story_map.json）—— 计划里那五条保真不变量。
##
## 【为什么这一份测试比别的重要】
## 别的数据坏了，坏的是「某句话显示得不对」；这一份坏了，坏的是**剧情顺序**。
## 而且它坏起来是沉默的：
##   漏路由一个场景 —— 玩家走到那儿，画面停住，没有任何报错；
##   脊梁排错一格   —— 玩家看到的是另一个故事，而每一句话都是原文里的真句子。
## 后者尤其难发现：文本全对，顺序不对。
##
## 所以这里不去读 story_map 自己声明的顺序（那会变成拿我写的东西验我写的东西），
## 而是**回头问 story.json**：故事图自己说下一步该是谁，脊梁听没听它的。

const ROUTE_SPINE := "spine"
const ROUTE_OBJECT := "object"
const ROUTE_AMBIENT := "ambient"


func _routes() -> Dictionary:
	var out := {}
	for id in DataDB.slice:
		out[str(id)] = DataDB.route_of(str(id))
	return out


## 所有「选择场景的非首选分支」—— 一次游玩走不到的那些。
##
## 【为什么要单独算出来】三个选择场景各有几条分支，一次只走一条。
## 于是「走一遍只演了 28 场，切片却有 32 场」是正常的，
## 不正常的是「少演的那几场不是分支」。
## 这两件事在数目上长得一模一样（都是少 4 场），
## 所以判据不能落在数目上，得落在**少的是哪几场**上。
func _non_first_branches() -> Dictionary:
	var out := {}
	for id in DataDB.scenes:
		var edges := DataDB._story_edges(str(id))
		if edges.size() < 2:
			continue
		for i in range(1, edges.size()):
			out[str(edges[i])] = str(id)
	return out


func test_data_db_reports_no_story_map_errors() -> void:
	var bad: PackedStringArray = []
	for e in DataDB.errors:
		if str(e).begins_with("S"):
			bad.append(str(e))
	ok(bad.is_empty(), "DataDB 的路由校验有 %d 条没过：\n          %s"
		% [bad.size(), "\n          ".join(bad)])


## I1 不丢：切片里每一个场景**恰好**归一种路由。
##
## 【为什么「恰好」两头都要查】少一个 = 那段剧情在 RPG 里根本不存在；
## 多一个（路由表里有切片外的场景）= 那是某次删场景留下的残骸，
## 而它会安静地待在那儿，直到哪天 spine_step 走到它上面去。
func test_i1_every_slice_scene_is_routed_exactly_once() -> void:
	var counts := {ROUTE_SPINE: 0, ROUTE_OBJECT: 0, ROUTE_AMBIENT: 0}
	var unrouted: Array = []
	for id in DataDB.slice:
		var r := DataDB.route_of(str(id))
		if r.is_empty():
			unrouted.append(str(id))
		elif counts.has(r):
			counts[r] += 1
		else:
			ok(false, "%s 的路由是「%s」，不在三种之内" % [str(id), r])

	ok(unrouted.is_empty(),
		"切片里有 %d 个场景没有任何路由，玩家玩到那儿会停住：%s"
		% [unrouted.size(), ", ".join(unrouted)])
	eq(int(counts[ROUTE_SPINE]) + int(counts[ROUTE_OBJECT]) + int(counts[ROUTE_AMBIENT]),
		DataDB.slice.size(), "三种路由加起来应当正好盖住整个切片")

	# 切片之外的场景不该出现在路由表里。
	var outside: Array = []
	for id in DataDB.story_map.get("spine", []):
		if not DataDB.slice_set.has(str(id)):
			outside.append("spine:" + str(id))
	for key in ["object", "ambient"]:
		for id in DataDB.story_map.get(key, []):
			if not DataDB.slice_set.has(str(id)):
				outside.append("%s:%s" % [key, str(id)])
	ok(outside.is_empty(),
		"路由表里有不在切片里的场景（删场景留下的残骸？）：%s" % ", ".join(outside))


## I1 的拍一级版本。拍跟着场景走，所以这条其实是把场景级的结论乘开 ——
## 但它顺手把「切片一共多少拍」也钉住了，那个数会随剧本改动而变，
## 是个便宜的哨。
func test_i1_every_slice_beat_inherits_exactly_one_route() -> void:
	var beats := 0
	var bad: Array = []
	for id in DataDB.slice:
		var r := DataDB.route_of(str(id))
		for e in DataDB.playable_bids(str(id)):
			beats += 1
			var br := DataDB.route_of_beat(str(e["bid"]))
			if br != r:
				bad.append("%s（场景是 %s，拍是 %s）" % [str(e["bid"]), r, br])
	ok(bad.is_empty(), "这些拍的路由跟它所在场景对不上：%s" % ", ".join(bad))
	eq(beats, 530, "切片应当是 530 拍（原文 477 + 扩写 53）")


## I2 脊梁保序。
##
## 【为什么拿故事图当预言机，而不是拿 slice 数组比】slice 数组是导出器
## 按「原文顺序 + 扩写追加在后」拼的，两段感情线扩写（x6/x9）在数组末尾，
## 可它们实际演在中间。拿数组比，比的是「导出器的拼接顺序」，
## 而我要验的是「故事自己说的顺序」。所以直接问 story.json 的边。
##
## 判据：故事图里每条边 A→B，只要 A、B 都在脊梁上，A 就得排在 B 前面。
func test_i2_the_spine_respects_the_story_graph() -> void:
	var bad: Array = []
	var checked := 0
	for id in DataDB.spine:
		var sid := str(id)
		for nxt in DataDB._story_edges(sid):
			var n := str(nxt)
			if not DataDB.is_spine(n):
				continue   # 没选中的分支不在这条线上，不算
			checked += 1
			if DataDB.spine_index(n) <= DataDB.spine_index(sid):
				bad.append("%s（第 %d）→ %s（第 %d）"
					% [sid, DataDB.spine_index(sid), n, DataDB.spine_index(n)])
	ok(bad.is_empty(), "这几条边被排反了：%s" % ", ".join(bad))
	ok(checked >= 20, "只验了 %d 条边，太少了 —— 是不是脊梁快空了" % checked)


## 脊梁要走得通：从起点顺着 spine_step 一路走，要能走到头。
## 这条同时验 spine_step 的「跳过非脊梁节点」那套逻辑。
##
## 【为什么走一遍只走到 21 个、脊梁却有 25 个】
## 三个选择场景各带几条分支，一次游玩只走其中一条。
## 没走的那四条（p_ke / c1_rad / c1_draft_b / c1_draft_c）留在 spine 里
## 不播 —— 它们在表里是为了「保序」有个完整说法，不是为了每次都演。
## 所以这里断言的不是「走到 25」，是两件更准的事：
##   一、走过的顺序是脊梁顺序的子序列（没跳号、没倒着走）；
##   二、漏掉的那几个，**恰好**是选择场景的非首选分支 —— 一个不多一个不少。
## 第二条才是关键：它把「为什么可以漏」说清楚了。
## 少了它，哪天 spine_step 静默吃掉一场正经戏，这条用例照样绿。
func test_i2_the_spine_walks_from_start_to_end() -> void:
	var visited: Array = []
	var cur := DataDB.spine_start()
	var guard := 0
	while not cur.is_empty() and guard < DataDB.scenes.size() + 4:
		guard += 1
		ok(not visited.has(cur), "脊梁走回了自己：%s（环）" % cur)
		if visited.has(cur):
			break
		visited.append(cur)
		cur = DataDB.spine_step(cur)

	eq(str(visited[0]), "p_intro", "脊梁应当从题记开始")
	eq(str(visited[visited.size() - 1]), "c1_end", "脊梁应当走到第一章尾声")

	# 一、顺序是脊梁的子序列。
	var pos := 0
	for id in visited:
		var i := DataDB.spine_index(str(id))
		ok(i >= 0, "%s 走出来了，却不在脊梁表里" % str(id))
		ok(i >= pos, "%s 走倒了（脊梁里在第 %d 位，上一场在第 %d 位）" % [str(id), i, pos])
		pos = i

	# 二、漏掉的恰好是非首选分支。
	var left: Array = []
	for id in DataDB.spine:
		if not visited.has(str(id)):
			left.append(str(id))
	var branches := _non_first_branches()
	for id in left:
		ok(branches.has(id),
			"%s 没被走到，可它也不是哪个选择场景的非首选分支 —— "
			% id + "那是 spine_step 把它吃掉了，不是玩家没选它")
	# 反过来：非首选分支一条都不许被走到 —— 走了就是一次游玩演了两条分支。
	for id in visited:
		var sid := str(id)
		ok(not branches.has(sid),
			"%s 是 %s 的非首选分支，却也被走到了 —— 一次游玩不该演两条分支"
			% [sid, str(branches.get(sid, "?"))])
	ok(left.size() > 0, "一个分支都没漏？那选择场景是不是被删了")


## 两段感情线扩写必须在脊梁上 —— 它们是「强制节拍」不是调查点。
## 这条例的是计划的四类扩写对照表：背景/小人物 → 热点，感情线 → 脊梁。
func test_the_two_feeling_line_expansions_ride_the_spine() -> void:
	for id in ["x6", "x9"]:
		eq(DataDB.route_of(id), ROUTE_SPINE,
			"%s 是感情线扩写，应当走脊梁（走热点的话，玩家不查就永远看不到）" % id)
	# 七个背景/小人物扩写反过来，都归热点。
	for id in ["x1", "x2", "x3", "x4", "x5", "x7", "x8"]:
		eq(DataDB.route_of(id), ROUTE_OBJECT, "%s 应当归热点触发" % id)


## I3 物件内保序：一个热点播它那段扩写时，拍按 bid 升序。
## 听着像废话，但它挡的是「有人为了排版好看去动 beats 数组」——
## 动了之后场景内顺序就乱了，而错的是原文的叙述顺序。
func test_i3_a_hotspot_plays_its_beats_in_order() -> void:
	for id in DataDB.object_scenes:
		var sid := str(id)
		var last := -1
		for e in DataDB.playable_bids(sid):
			var i := int(str(e["bid"]).get_slice(":", 1))
			ok(i > last, "%s 的拍 %s 排在了上一拍前面" % [sid, str(e["bid"])])
			last = i


## I4 强制调查点到为止：闲笔不许挡路。
##
## 【切片里一个都没有，这条是故意写死的】计划写的是「只有剧情命脉处才锁出口，
## 默认不锁」。锁出口这件事一旦开了头，很容易变成「这个也重要、那个也重要」，
## 最后玩家在房间里被挨个逼着点一遍才能出去 —— 那就不是 RPG 是清单了。
## 所以这里直接断言：切片里**没有**任何物件锁出口。
## 哪天真要加一个，这条会红，逼着加的人说明白为什么。
func test_i4_no_examine_ever_locks_an_exit() -> void:
	var locked: Array = []
	for rid in DataDB.rooms:
		for o in (DataDB.room(rid).get("objects", []) as Array):
			if not (o is Dictionary):
				continue
			var d: Dictionary = o
			if bool(d.get("required", false)) or bool(d.get("locks_exit", false)):
				locked.append("%s/%s" % [str(rid), str(d.get("id", "?"))])
	ok(locked.is_empty(),
		"切片里不该有锁出口的物件，可是这几个锁了：%s —— "
		% ", ".join(locked) + "闲笔不许挡路。真要锁，先把这条用例改掉并写清理由")


## I5 回想兜底：跳过闲笔的玩家，事后还能在回想屏读到。
##
## 这条是「允许可选文本」的前提 —— 没有它，「调查点可以不查」就变成
## 「不查就永远看不到」，那是丢内容，不是可选。
##
## 走一遍脊梁，把每一拍都记下来，然后：
##   一、日志条数 == 脊梁上所有该入日志的拍；
##   二、日志按 bid 重排之后，跟原文顺序一致。
func test_i5_every_spine_beat_reaches_the_recall_log() -> void:
	GameState.reset()
	BeatRunner.stop()
	BeatRunner.slice_only = true
	BeatRunner.vn_mode = false
	BeatRunner.spine_mode = true

	var expect: Array = []
	var cur := DataDB.spine_start()
	var guard := 0
	while not cur.is_empty() and guard < DataDB.scenes.size() + 4:
		guard += 1
		for e in DataDB.playable_bids(cur):
			var beat: Dictionary = e["beat"]
			# 进日志的判据跟 BeatRunner._log 一样：beat_text 认得这个类型。
			if not DataDB.beat_text(beat).is_empty():
				expect.append(str(e["bid"]))
		cur = DataDB.spine_step(cur)

	ok(expect.size() > 400, "脊梁上应当有四百多拍，实际 %d —— 脊梁是不是断了" % expect.size())

	# 走一遍真家伙（不是复算一遍我自己的列表）：从起点跑到停。
	BeatRunner.begin(DataDB.spine_start())
	var step := 0
	while BeatRunner.running and step < 20000:
		step += 1
		if BeatRunner.awaiting_choice:
			var opts := BeatRunner.current_options()
			var pick := -1
			for o in opts:
				if bool(o["enabled"]):
					pick = int(o["index"])
					break
			ok(pick >= 0, "选项一个都选不了，走不下去了")
			if pick < 0:
				break
			BeatRunner.choose(pick)
		else:
			BeatRunner.advance()

	var got: Array = []
	for entry in GameState.log:
		got.append(str((entry as Dictionary).get("bid", "")))

	eq(got.size(), expect.size(),
		"回想日志应当有 %d 条，实际 %d 条 —— 有拍没进日志，跳过的人事后读不到"
		% [expect.size(), got.size()])

	# 日志是**按玩家实际动作顺序**追加的（他可能倒着查物件），
	# 所以不比顺序，比集合；顺序由回想屏按 bid 重排。
	var want := {}
	for b in expect:
		want[str(b)] = true
	var missing: Array = []
	for b in got:
		if not want.has(b):
			missing.append(b)
	ok(missing.is_empty(), "日志里有脊梁上不存在的拍：%s" % ", ".join(missing))

	# 重排之后要跟脊梁顺序一致 —— 这就是回想屏要做的事，在这儿先验一遍。
	#
	# 【排序键是「脊梁位置 + 拍序号」，不是 bid 字符串】
	# 直接 sort() 会按字典序排："c1_choice:0" 排在 "p_intro:0" 前面 ——
	# 因为 'c' < 'p'。那是按**场景 id 的字母**排，不是按剧情顺序排，
	# 回想屏真这么做的话，玩家读到的是一部打乱了章节次序的作品。
	# 而它看起来还挺「有序」的，所以这个错很难自己冒出来。
	var sorted := got.duplicate()
	sorted.sort_custom(func(a: String, b: String) -> bool:
		var sa := DataDB.spine_index(a.get_slice(":", 0))
		var sb := DataDB.spine_index(b.get_slice(":", 0))
		if sa != sb:
			return sa < sb
		return int(a.get_slice(":", 1)) < int(b.get_slice(":", 1)))
	eq(sorted, expect, "按「脊梁位置 + 拍序号」重排之后，应当跟脊梁上的顺序一致")

	# 走架是全局单例，模式开关不能留给下一个用例去发现。
	BeatRunner.spine_mode = false
	BeatRunner.stop()


## I6 预言机**没有**被脊梁模式污染：vn_mode 下必须把九个扩写节点也演一遍。
##
## 【为什么这条非有不可】I6 是「没丢东西」的唯一铁证 —— 它把整部切片
## 按原文顺序拼成一份文本，拿去跟 index.html 逐字比对。
## 要是哪天有人图省事，让 vn_mode 也走脊梁，那七个归热点的扩写就
## 悄悄从预言机里消失了 —— 而预言机照样报「逐字相同」，
## 因为它比的是它自己走过的那部分。**铁证就此变成自证。**
## 这条用例就是钉住这件事的。
func test_i6_the_vn_oracle_still_plays_the_object_routed_expansions() -> void:
	GameState.reset()
	BeatRunner.stop()
	BeatRunner.slice_only = true
	BeatRunner.spine_mode = false
	BeatRunner.vn_mode = true

	BeatRunner.begin(DataDB.start_scene)
	var seen := {}
	var step := 0
	while BeatRunner.running and step < 20000:
		step += 1
		seen[BeatRunner.scene_id] = true
		if BeatRunner.awaiting_choice:
			var opts := BeatRunner.current_options()
			var pick := -1
			for o in opts:
				if bool(o["enabled"]):
					pick = int(o["index"])
					break
			if pick < 0:
				break
			BeatRunner.choose(pick)
		else:
			BeatRunner.advance()

	BeatRunner.vn_mode = false
	BeatRunner.stop()

	for id in DataDB.object_scenes:
		ok(seen.has(str(id)),
			"预言机没有演 %s —— 它归热点路由，可 vn_mode 就该把什么都演一遍，"
			% str(id) + "不然逐字比对比的是它自己走过的那部分")

	# 没演到的应当**只有**选择场景的非首选分支。
	# 不能写 `eq(seen.size(), slice.size())` —— 一次游玩本来就演不了两条分支，
	# 那样断言会红在一个完全正常的状态上。要断的是「少的是哪几场」。
	var branches := _non_first_branches()
	var left: Array = []
	for id in DataDB.slice:
		if not seen.has(str(id)):
			left.append(str(id))
	for id in left:
		ok(branches.has(id),
			"预言机漏了 %s，可它不是非首选分支 —— vn_mode 把它跳过去了" % id)
	ok(left.size() > 0, "一条分支都没漏？那 vn_mode 是不是把分支也演了")


## S7 的独立版本：每一场脊梁戏都得有地方演。
## 没有房间的那四场必须在 present 里显式写着 —— 让「没房间」是个决定，不是漏写。
func test_every_spine_scene_has_somewhere_to_play() -> void:
	var homeless: Array = []
	var present := 0
	for id in DataDB.spine:
		var sid := str(id)
		if DataDB.is_present_scene(sid):
			present += 1
			ok(DataDB.room_for_scene(sid).is_empty(),
				"%s 既在 present 里又有房间 %s" % [sid, DataDB.room_for_scene(sid)])
			continue
		var r := DataDB.room_for_scene(sid)
		if r.is_empty():
			homeless.append(sid)
		else:
			ok(DataDB.has_room(r), "%s 排给了不存在的房间 %s" % [sid, r])
	ok(homeless.is_empty(),
		"这几场脊梁戏没说在哪儿演：%s" % ", ".join(homeless))
	eq(present, 4, "走呈现层的脊梁节点应当正好是四场（题记 / 书信 / 林婉如视角 / 尾声）")


## 十二条房间不是摆着看的 —— 每一间都得承接至少一场脊梁戏。
## 反过来说，这条也验了「房间和剧情真的接上了」，而不只是各自都对。
func test_the_twelve_rooms_each_host_at_least_one_scene() -> void:
	var used := {}
	for id in DataDB.spine:
		var r := DataDB.room_for_scene(str(id))
		if not r.is_empty():
			used[r] = int(used.get(r, 0)) + 1
	# 归热点的扩写也把玩家带进房间，算上它们。
	for id in DataDB.object_scenes:
		var r2 := DataDB.room_for_scene(str(id))
		if not r2.is_empty():
			used[r2] = int(used.get(r2, 0)) + 1

	for rid in DataDB.rooms:
		ok(used.has(rid), "房间 %s（%s）没有承接任何一场戏 —— 造了但剧情不走这儿"
			% [rid, str(DataDB.room(rid).get("name", ""))])

	# 书房是切片里最划算的一间：第一章七场戏都在它里面。
	eq(int(used.get("r_study", 0)), 7,
		"沈家书房应当承接七场戏（c1_father / c1_rad / c1_draft 及三分支 / c1_miyue）")


## 归热点的扩写，得在它该在的那间房里。
## 这条防的是「热点挂对了场景，可是房间摆错了地方」——
## 比如把「外滩的路牌」摆进茶楼，点了能播，可玩家站在北京看着上海的路牌。
func test_object_routed_expansions_live_in_the_right_room() -> void:
	var want := {
		"x1": "r_xuanwu",
		"x2": "r_tea",
		"x3": "r_gongche",
		"x4": "r_gongche",
		"x5": "r_shanghai",
		"x7": "r_oldhouse",
		"x8": "r_farm",
	}
	for sid in want:
		var r := DataDB.room_for_scene(str(sid))
		eq(r, str(want[sid]), "%s 应当在 %s 里" % [str(sid), str(want[sid])])
		ok(not DataDB.hotspot_for_scene(str(sid)).is_empty(),
			"%s 归热点路由，可是没有热点挂着它" % str(sid))


# ============================================================
#  走得到（里程碑 5 接上房间之后才成立的问题）
# ============================================================

## 从一间房出发，按出口走，能走到的所有房间（含它自己）。
func _reachable_from(start: String) -> Dictionary:
	var seen := {start: true}
	var queue: Array = [start]
	while not queue.is_empty():
		var here := str(queue.pop_front())
		for o in (DataDB.room(here).get("objects", []) as Array):
			if str(o.get("kind", "")) != "exit":
				continue
			var to := str(o.get("to", ""))
			if to.is_empty() or seen.has(to) or not DataDB.has_room(to):
				continue
			seen[to] = true
			queue.append(to)
	return seen


## **每一对相邻的脊梁房间之间，都得有一条走得通的路。**
##
## 【这条为什么非有不可】
## 房间屏的规则是：剧情停在缝里，玩家走到下一场戏所在的那间房，剧情才接上。
## 于是 rooms.json 的出口图一旦断开，玩家就会**永远卡在那儿** ——
## 不报错、不崩溃，只是站在一间屋子里，提示条上写着「剧情在『杨椒山祠』」，
## 而那条路根本不存在。
##
## 单测「每间房有出口」是抓不到这个的：出口可能都通向别的房间，
## 而剧情要的那一间偏偏到不了（第一章就有这种形状 ——
## 从陈宅回书房要经过老宅，两跳）。
##
## 所以判据落在**可达性**上，不是「有没有出口」。
## 用 DFS 走一遍出口图，问「从这间房出发，走得到那一间吗」。
func test_every_step_of_the_spine_is_walkable() -> void:
	var seq: Array = []
	for id in DataDB.spine:
		var r := DataDB.room_for_scene(str(id))
		if not r.is_empty() and (seq.is_empty() or str(seq[seq.size() - 1]) != r):
			seq.append(r)

	ok(seq.size() >= 8, "脊梁一共只串起 %d 间房 —— 太少了，多半是 rooms 表缺了" % seq.size())

	var stuck: Array = []
	for i in range(1, seq.size()):
		var from := str(seq[i - 1])
		var to := str(seq[i])
		if from == to:
			continue
		if not _reachable_from(from).has(to):
			stuck.append("%s → %s" % [from, to])
	ok(stuck.is_empty(),
		"这些相邻的剧情房间之间走不通 —— 玩家会卡在前一间，剧情永远接不上：\n          %s"
		% "\n          ".join(stuck))


# 「每间房都从起点走得到」那条不在这儿 —— test_rooms.gd 的
# test_every_room_is_reachable_from_the_start 已经在守了。
# 一开始这里也写了一份，跑了一次才发现是重复：同一个事实两处断言，
# 改出口图的时候要记得改两处，而漏掉的那一处不会报错，只会静静地不再守任何东西。
#
# 这一份守的是**另一件事**：可达性对了，顺序不一定对。
# 上面那条只问「走得到吗」，不问「相邻的两场戏之间走得到吗」——
# 出口图完全可能既连通、又让某一步走不通（绕不过去的那种连通）。
