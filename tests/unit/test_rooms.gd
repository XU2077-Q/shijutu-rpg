extends TestCase
## 房间数据（data/rooms.json）。
##
## 【为什么要在这里再验一遍 DataDB 已经验过的东西】
## DataDB 那套 R 组校验管的是「进游戏时别带着坏数据」——
## 它报出来的是一条 error 文本，够拦住游戏，但不够说清是哪儿。
## 这里的用例是**独立地把不变量再推一遍**，两条好处：
##   一、失败时指名道姓（「茶楼的 tea.cup 没有内容」比「R5 房间 r_tea…」好读）；
##   二、哪天 DataDB 的校验被改松了，这里还拦得住。
## 两处都写，是故意的冗余。

const ROOM_KINDS := ["look", "talk", "exit"]


func _rooms() -> Dictionary:
	return DataDB.rooms


func _objects(room_id: String) -> Array:
	return (DataDB.room(room_id).get("objects", []) as Array)


## 十二条房间：序章六间 + 第一章六间。
##
## 【为什么这条要写死数目】里程碑 4 只有三间（茶楼、大街、都察院），
## 三间连成一个小世界就够了。里程碑 5 把整个切片铺开 ——
## 数一下是对的，能挡住「加房间时漏了一间、而那间恰好没人走得到」。
## 数目本身不是目的，但它是最便宜的那道哨。
func test_the_slice_has_its_twelve_rooms() -> void:
	var want := ["r_tea", "r_xuanwu", "r_ci", "r_ke", "r_gongche", "r_hunan",
		"r_yongding", "r_shanghai", "r_oldhouse", "r_farm", "r_study", "r_chendi"]
	eq(_rooms().size(), want.size(), "切片应当是 %d 间房" % want.size())
	for id in want:
		ok(_rooms().has(id), "缺少房间 %s" % id)
	ok(_rooms().has(DataDB.room_start),
		"rooms.json 的 start（%s）不是一间真房间" % DataDB.room_start)


## 两条**元注**故意不挂在任何物件上 —— 它们讲的是这部作品本身，
## 不是某个茶壶。留给里程碑 6 的史实注一览直接列出来。
##
## 【为什么这个状态值得写死】因为它看起来像漏了。
## 一个只扫「物件引用的注」的检查会发现序章 6 条只用了 5 条，
## 然后有人会「顺手补上」—— 把《关于题记的说明》挂给茶盏，
## 玩家在茶楼查个茶盏，翻出来一段讲题记怎么写的话。
func test_the_two_meta_notes_are_deliberately_homeless() -> void:
	var used := {}
	for id in _rooms():
		for o in _objects(id):
			var note: Variant = o.get("note", [])
			if note is Array and (note as Array).size() == 2:
				used["%s/%s" % [str(note[0]), str(note[1])]] = true

	for meta in ["序章/关于题记的说明", "第一章/虚构人物声明"]:
		ok(not used.has(meta),
			"%s 被挂到物件上了 —— 它是元注，讲的是作品本身，不该从某个茶壶里翻出来"
			% meta)
		ok(not DataDB.note_body(meta.get_slice("/", 0), meta.get_slice("/", 1)).is_empty(),
			"%s 在 notes.json 里找不到了" % meta)

	# 反过来也要成立：切片范围内的注，除了那两条元注，其余都该有落脚处。
	var homeless: Array = []
	for ch in ["序章", "第一章"]:
		for n in DataDB.notes.get(ch, []):
			var key := "%s/%s" % [ch, str(n.get("h", ""))]
			if not used.has(key):
				homeless.append(key)
	homeless.sort()
	eq(homeless, ["序章/关于题记的说明", "第一章/虚构人物声明"],
		"切片里没被任何物件引用的注，应当正好是那两条元注")


## R5 的独立版本：空壳物件是这一层最难发现的一种坏 ——
## 它不报错，只是玩家点上去没反应。
func test_every_object_says_something() -> void:
	for id in _rooms():
		for o in _objects(id):
			var oid := str(o.get("id", "?"))
			var kind := str(o.get("kind", ""))
			if kind == "exit":
				ok(not str(o.get("to", "")).is_empty(),
					"%s 的 %s 是出口却没写 to" % [id, oid])
				continue
			var has_scene := not str(o.get("scene", "")).is_empty()
			var note: Variant = o.get("note", [])
			var has_note := note is Array and (note as Array).size() == 2
			ok(has_scene or has_note,
				"%s 的 %s 是个空壳：既没有 scene 也没有 note，点了不会有任何反应"
				% [id, oid])


## 物件只能挂**扩写**，不能挂原文节拍。
## 挂原文的话，那段文字会被播两遍：脊梁上一次，查物件时又一次。
## 而且两遍之间没有任何提示 —— 玩家会以为是自己看花了眼。
func test_objects_only_play_expansions() -> void:
	for id in _rooms():
		for o in _objects(id):
			var s := str(o.get("scene", ""))
			if s.is_empty():
				continue
			var oid := str(o.get("id", "?"))
			ok(DataDB.scenes.has(s), "%s 的 %s 指向不存在的场景 %s" % [id, oid, s])
			if DataDB.scenes.has(s):
				ok(DataDB.scenes[s].has("expansion"),
					"%s 的 %s 挂的是原文场景 %s —— 原文归脊梁走，挂到物件上会播两遍"
					% [id, oid, s])


func test_every_note_reference_exists() -> void:
	for id in _rooms():
		for o in _objects(id):
			var note: Variant = o.get("note", [])
			if not (note is Array and (note as Array).size() == 2):
				continue
			var ch := str(note[0])
			var ti := str(note[1])
			ok(not DataDB.note_body(ch, ti).is_empty(),
				"%s 的 %s 引了一条不存在的史实注：%s / %s"
				% [id, str(o.get("id", "?")), ch, ti])


func test_every_exit_lands_somewhere_you_can_stand() -> void:
	for id in _rooms():
		for o in _objects(id):
			if str(o.get("kind", "")) != "exit":
				continue
			var to := str(o.get("to", ""))
			ok(_rooms().has(to), "%s 的出口指向不存在的房间 %s" % [id, to])
			if not _rooms().has(to):
				continue
			var at: Variant = o.get("at", [])
			ok(at is Array and (at as Array).size() == 2,
				"%s 的出口没写落点" % id)
			if not (at is Array and (at as Array).size() == 2):
				continue
			var p := Vector2(float(at[0]), float(at[1]))
			var walk := PackedVector2Array()
			for q in DataDB.room(to).get("walk", []):
				walk.append(Vector2(float(q[0]), float(q[1])))
			ok(Geometry2D.is_point_in_polygon(p, walk),
				"%s → %s 的落点 %s 不在目标房间的可走区里" % [id, to, p])


## 造了一间谁也走不到的房 = 白造。
func test_every_room_is_reachable_from_the_start() -> void:
	var seen := {DataDB.room_start: true}
	var queue: Array = [DataDB.room_start]
	while not queue.is_empty():
		var id: String = queue.pop_back()
		for o in _objects(id):
			if str(o.get("kind", "")) != "exit":
				continue
			var to := str(o.get("to", ""))
			if not seen.has(to) and _rooms().has(to):
				seen[to] = true
				queue.append(to)
	for id in _rooms():
		ok(seen.has(id), "房间 %s 从起始房间走不到 —— 造了但进不去" % id)


func test_every_room_has_a_way_out() -> void:
	for id in _rooms():
		var exits := 0
		for o in _objects(id):
			if str(o.get("kind", "")) == "exit":
				exits += 1
		ok(exits > 0, "房间 %s 一个出口都没有，走进去就出不来了" % id)


func test_object_kinds_are_ones_we_can_do() -> void:
	for id in _rooms():
		for o in _objects(id):
			ok(ROOM_KINDS.has(str(o.get("kind", ""))),
				"%s 的 %s 用了不认识的 kind：%s"
				% [id, str(o.get("id", "?")), str(o.get("kind", ""))])


## DataDB 自己那一套（R 组）。上面几条是独立复算，
## 这一条是「加载时到底有没有报错」—— 两条都过才算真的没问题。
func test_data_db_loaded_the_rooms_without_complaint() -> void:
	ok(not DataDB.rooms.is_empty(), "rooms.json 没读进来")
	var room_errors: PackedStringArray = []
	for e in DataDB.errors:
		if str(e).begins_with("R"):
			room_errors.append(str(e))
	ok(room_errors.is_empty(), "DataDB 的房间校验有 %d 条没过：\n          %s"
		% [room_errors.size(), "\n          ".join(room_errors)])
