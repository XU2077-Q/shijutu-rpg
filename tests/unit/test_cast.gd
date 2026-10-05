extends TestCase
## 「谁有脸」这张表本身。
##
## 【为什么这张表值得单独测】
## 它是一张**手写的数据表**，而手写数据表只有三种坏法，三种都不会报错：
##   一、表里写了文件，文件其实不在      → 画面上少一张脸，没人知道为什么
##   二、文件在，表里忘了登记            → 十五张立绘里有一张永远不出现
##   三、剧本里冒出个新角色，表里没他    → 这个角色**默默地**变成了龙套
## 第三种最要命：加戏的人不会想到要去改一张他看不见的表。
## 所以这里反过来查 —— 拿剧本里所有说过话的人去问这张表：
## 「你认识他吗？不认识的话，他是故意不给脸的龙套吗？」

const PORTRAIT_MANIFEST := "res://art/portraits/manifest.json"


## 盘上真实存在的立绘文件名。
##
## 注意读的是 manifest 的 `id` 而不是 `file` —— `file` 记的是**去水印之前**
## 的原始文件名（「佃农何伯.png」这种中文名），`id` 才是去水印时重命名后
## 落在盘上的名字（he_bo.png）。读错字段的后果是这张表看起来全对、
## 实际上一张都对不上，而用例还会因为「文件都在」而报绿。
func _portraits_on_disk() -> Array:
	var out: Array = []
	var f := FileAccess.open(PORTRAIT_MANIFEST, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return out
	for p in parsed.get("portraits", []):
		var id := str(p.get("id", ""))
		if not id.is_empty():
			out.append(id + ".png")
	return out


## 表里写了的文件，要么在盘上，要么明确登记为「还没画」。
func test_every_listed_face_is_either_on_disk_or_marked_pending() -> void:
	var missing: Array = []
	for speaker in Cast.FACES:
		var file: String = Cast.FACES[speaker]
		if ResourceLoader.exists(Cast.PORTRAIT_DIR + file):
			continue
		if Cast.PENDING.has(file):
			continue
		missing.append("%s → %s" % [speaker, file])
	ok(missing.is_empty(),
		"表里登记了立绘但文件不在，也没记进 PENDING：\n          %s\n"
		% "\n          ".join(missing) +
		"        缺图不会崩，只会在画面上少一张脸 —— 所以必须在这里拦下来。")


## 反过来：盘上有立绘，表里得有个说法。
## 没说法 = 这张图是白画的，玩家永远看不见。
func test_every_portrait_on_disk_is_accounted_for() -> void:
	var known := {}
	for speaker in Cast.FACES:
		known[Cast.FACES[speaker]] = speaker

	var orphans: Array = []
	for file in _portraits_on_disk():
		if known.has(file) or Cast.NOT_A_SPEAKER.has(file):
			continue
		orphans.append(file)
	ok(orphans.is_empty(),
		"这些立绘在盘上，但 Cast 里没有登记，也没有记进 NOT_A_SPEAKER：\n          %s\n"
		% "\n          ".join(orphans) +
		"        等于白画了 —— 或者是有意的，那就写进 NOT_A_SPEAKER 并写明理由。")
	ok(not _portraits_on_disk().is_empty(), "art/portraits/manifest.json 里一张立绘都没有")


## PENDING 里的东西不该已经画好了 —— 那是忘了把状态更新。
func test_pending_list_has_no_stale_entries() -> void:
	var stale: Array = []
	for file in Cast.PENDING:
		if ResourceLoader.exists(Cast.PORTRAIT_DIR + file):
			stale.append(file)
	ok(stale.is_empty(),
		"这些立绘已经在盘上了，却还挂在 PENDING 里：%s" % ", ".join(stale))


## 收集说话人 → 句数。scope_slice 为真时只数切片内的场景。
func _speakers(scope_slice: bool) -> Dictionary:
	var out := {}
	var ids: Array = DataDB.slice if scope_slice else DataDB.scenes.keys()
	for scene_id in ids:
		if not DataDB.scenes.has(scene_id):
			continue
		for b in DataDB.scenes[scene_id].get("beats", []):
			if b.get("t") != "d":
				continue
			var w := str(b.get("w", ""))
			if w.is_empty():
				continue
			out[w] = int(out.get(w, 0)) + 1
	return out


## **切片里**每一个说过话的人，要么有脸，要么明确是龙套。
##
## 这条是本文件的重点：它把「谁该有立绘」这个决定**变成可执行的检查**。
## 剧本以后加一个新角色，只要他开口说话，这条用例就会红，逼着人做一次决定。
##
## 【为什么只查切片】
## 全剧本还有 7 个二至五章的人物（张謇 52 句、克纳普 21 句…）没有立绘，
## 也不在本次的美术工单里 —— 那是有意为之，不是遗漏。
## 把全剧本都卡上，这条用例会**长期红着**，而长期红的用例等于没有用例：
## 大家会习惯性忽略它，等切片真出问题时也就看不出来了。
## 所以范围卡在切片，其余的在下面那条里列出来给自己看。
func test_every_speaker_in_the_slice_is_a_face_or_a_named_crowd_member() -> void:
	var speakers := _speakers(true)
	ok(speakers.size() > 5, "切片里只读到 %d 个说话人 —— 剧本没加载上？" % speakers.size())

	var undecided: Array = []
	for w in speakers:
		if Cast.FACES.has(w) or Cast.CROWD.has(w):
			continue
		undecided.append("%s（%d 句）" % [w, speakers[w]])

	ok(undecided.is_empty(),
		"这些人在切片里说过话，但既没立绘也没登记成龙套：\n          %s\n"
		% "\n          ".join(undecided) +
		"        有脸就加进 Cast.FACES，是龙套就加进 Cast.CROWD 并写明理由。")

	# 顺手报一下全剧本还剩多少没定 —— 不判失败，只是别让它悄悄涨上去。
	var rest: Array = []
	for w in _speakers(false):
		if Cast.FACES.has(w) or Cast.CROWD.has(w):
			continue
		rest.append("%s（%d 句）" % [w, _speakers(false)[w]])
	if not rest.is_empty():
		print("       （切片之外还有 %d 个人物没定立绘，属二至五章：%s）"
			% [rest.size(), ", ".join(rest)])


## 龙套表里不该混进有立绘的人 —— 两处都登记会让人以为可以二选一。
func test_crowd_and_faces_do_not_overlap() -> void:
	var both: Array = []
	for w in Cast.CROWD:
		if Cast.FACES.has(w):
			both.append(w)
	ok(both.is_empty(), "这些人既在 FACES 又在 CROWD 里：%s" % ", ".join(both))


# ============================================================
#  行走图
# ============================================================

const DIRS := ["down", "up", "left", "right"]
const FRAMES := 3


## 可操作角色的行走图必须是**完整的一套**：四向 × 三帧。
## 缺一帧不会报错，只会在往某个方向走的时候突然变成一个静止的小人 ——
## 而那种「只有往左走才怪」的问题，肉眼测的时候极容易漏过去。
func test_every_walker_has_a_complete_sprite_set() -> void:
	for who in Cast.WALKERS:
		var prefix: String = Cast.WALKERS[who]
		var missing: Array = []
		for d in DIRS:
			for i in FRAMES:
				var p := "%s%s_%s_%d.png" % [Cast.WALK_DIR, prefix, d, i]
				if not ResourceLoader.exists(p):
					missing.append(p.get_file())
		ok(missing.is_empty(),
			"「%s」的行走图缺 %d 帧：%s" % [who, missing.size(), ", ".join(missing)])
		ok(ResourceLoader.exists("%s%s_sheet.png" % [Cast.WALK_DIR, prefix]),
			"「%s」没有整张的对照图（%s_sheet.png）" % [who, prefix])


func test_walkers_are_also_faces() -> void:
	var bad: Array = []
	for who in Cast.WALKERS:
		if not Cast.FACES.has(who):
			bad.append(who)
	ok(bad.is_empty(),
		"这些人能做行走图却没有立绘：%s —— 对不上话的时候脸会空着" % ", ".join(bad))
