extends Node
## 剧本数据的唯一入口。
##
## 数据是 Node 侧 tools/export_story.js 导出的 JSON —— 好处是导出器能跑断言、
## git diff 可读；代价是**没有编辑器校验**，手改一个字符 Godot 不会拦你。
## 所以这里补上：启动时全量校验一遍，不合格就报错。
##
## 校验清单（每条都对应一种真实会犯的错）：
##   V1 起始场景存在                     —— 导出器换了 start，这里没跟上
##   V2 next / opts.to 都能落地           —— 悬空引用，玩到那儿就卡死
##   V3 节拍类型都在支持范围内            —— 剧本加了新类型，运行时没实现
##   V4 supersede 指向的拍存在，
##      且被顶替的拍确实是替换者的起句     —— 第 14 条 replace 的定位规则
##   V5 条件 AST 的算子都认识             —— 剧本加了新门槛，求值器没实现
##   V6 每个扩写节点都从 start 走得到     —— 扩写写了但没接进图，等于白写
##   R1~R8 rooms.json（手写）的结构与互指
##
## V5/V6 这两条最值钱：它们拦的都是「东西写好了，但没接上」这种**沉默的错**。
## R 组同理，而且更要紧 —— 房间是手写的，没有导出器替我兜底。

const DATA_DIR := "res://data/"

## 导出器与运行时共同认可的词表。改这里必须同步改 tools/export_story.js。
const BEAT_TYPES := ["n", "d", "q", "letter", "choice", "map", "end"]
const AST_OPS := ["flag", "var", "lit", "eq", "ne", "gt", "gte", "lt", "lte",
	"and", "or", "not", "if", "has_ending", "template", "call"]

var story: Dictionary = {}
var notes: Dictionary = {}
var markers: Array = []
var endings: Array = []
var expansions: Array = []

var story_map: Dictionary = {}   ## 手写：叙事路由（spine / object / ambient）
var spine: Array = []            ## 手写：脊梁节点顺序（含选择场景的全部分支）
var object_scenes: Array = []    ## 手写：归热点触发的场景
var ambient_scenes: Array = []   ## 手写：进房自动播的场景
var scene_rooms: Dictionary = {} ## 手写：场景 → 在哪间房演
var present_scenes: Array = []   ## 手写：没有房间、在呈现层演的脊梁节点
var rooms: Dictionary = {}       ## 手写：房间定义
var room_start: String = ""      ## 手写：从哪一间开始走
var quests: Dictionary = {}      ## 手写：任务定义

var scenes: Dictionary = {}
var start_scene: String = ""

## 垂直切片的边界。**由导出器出**（story.json 的 slice 字段），
## 不在 GDScript 里另抄一份 —— 两份清单迟早不一致，
## 而不一致的那天 demo 会安安静静地演到第二章去。
var slice: Array = []
var slice_set: Dictionary = {}

var errors: PackedStringArray = []
var warnings: PackedStringArray = []


func _ready() -> void:
	load_all()
	_validate()
	if errors.is_empty():
		print("[DataDB] %d 场景（原文 %d + 扩写 %d）/ %d 拍 / %d 结局 —— 校验通过"
			% [scenes.size(), scenes.size() - expansions.size(), expansions.size(),
			   count_beats(), endings.size()])
	else:
		push_error("[DataDB] 数据校验未通过，共 %d 条：" % errors.size())
		for e in errors:
			push_error("  ✗ " + e)
	for w in warnings:
		push_warning("[DataDB] " + w)


## 读一个 JSON。文件不存在返回 null 并记一条 warning（不是 error）——
## story_map / rooms / quests 是手写的，允许暂时缺席。
func _read_json(name: String, required: bool) -> Variant:
	var path := DATA_DIR + name
	if not FileAccess.file_exists(path):
		if required:
			errors.append("缺数据文件 " + path)
		else:
			warnings.append("暂无 " + name + "（手写文件，允许缺席）")
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		errors.append("读不出内容或文件为空：" + path)
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		errors.append("JSON 解析失败（多半是手工改坏了）：" + path)
		return null
	return parsed


func load_all() -> void:
	errors.clear()
	warnings.clear()

	var s: Variant = _read_json("story.json", true)
	if s is Dictionary:
		story = s
		scenes = story.get("scenes", {})
		start_scene = story.get("start", "")
		slice = story.get("slice", [])
		slice_set.clear()
		for id in slice:
			slice_set[id] = true
	var n: Variant = _read_json("notes.json", true)
	if n is Dictionary:
		notes = n
	var mk: Variant = _read_json("markers.json", true)
	if mk is Array:
		markers = mk
	var en: Variant = _read_json("endings.json", true)
	if en is Array:
		endings = en
	var ex: Variant = _read_json("expansions.json", true)
	if ex is Array:
		expansions = ex

	var sm: Variant = _read_json("story_map.json", false)
	if sm is Dictionary:
		story_map = sm
		spine = sm.get("spine", [])
		object_scenes = sm.get("object", [])
		ambient_scenes = sm.get("ambient", [])
		scene_rooms = sm.get("rooms", {})
		present_scenes = sm.get("present", [])
	var rm: Variant = _read_json("rooms.json", false)
	if rm is Dictionary:
		rooms = rm.get("rooms", {})
		room_start = str(rm.get("start", ""))
	var qs: Variant = _read_json("quests.json", false)
	if qs is Dictionary:
		quests = qs

	# 路由索引要等 rooms.json 也读完才能建 —— 它要靠 rooms 才能算出
	# 「哪个热点挂的是哪段扩写」。放在这儿是 load_all 的最后一步。
	_reindex_routes()


## 一间房间的定义。没有就返回空字典 —— 调用方据此决定退到哪儿。
func room(id: String) -> Dictionary:
	return rooms.get(id, {})


func has_room(id: String) -> bool:
	return rooms.has(id)


# ============================================================
#  叙事路由（story_map.json）
# ============================================================

## 场景 → "spine" / "object" / "ambient"。没有路由的场景不在表里。
var _route_by_scene: Dictionary = {}
## 场景 → 在 spine 里的下标（只对脊梁节点有意义）
var _spine_index: Dictionary = {}
## 场景 → 挂它的热点 id（只对 object 路由有意义）
var _hotspot_by_scene: Dictionary = {}
## 热点 id → 场景。rooms.json 是权威，这里只是反过来查的快表。
var _scene_by_hotspot: Dictionary = {}

const ROUTE_SPINE := "spine"
const ROUTE_OBJECT := "object"
const ROUTE_AMBIENT := "ambient"


## 重建路由索引。load_all 的最后一步调它 ——
## 它同时依赖 story_map.json（spine/object/ambient 三张表）
## 和 rooms.json（热点 id → 场景），缺一个都算不全。
func _reindex_routes() -> void:
	_route_by_scene.clear()
	_spine_index.clear()
	_hotspot_by_scene.clear()
	_scene_by_hotspot.clear()

	for i in spine.size():
		var id := str(spine[i])
		_route_by_scene[id] = ROUTE_SPINE
		# 同一个场景在 spine 里出现两次的话，下标会互相盖掉 ——
		# S1 拦这一条，所以这里不必再判。
		_spine_index[id] = i
	for id in ambient_scenes:
		_route_by_scene[str(id)] = ROUTE_AMBIENT
	for id in object_scenes:
		_route_by_scene[str(id)] = ROUTE_OBJECT

	# 热点 → 场景。rooms.json 里每个物件的 scene 字段就是这条绑定，
	# 所以路由表里不必再抄一遍（抄了就会漂）。
	for rid in rooms:
		for o in (rooms[rid] as Dictionary).get("objects", []):
			if not (o is Dictionary):
				continue
			var sc := str((o as Dictionary).get("scene", ""))
			if sc.is_empty():
				continue
			_scene_by_hotspot[str((o as Dictionary).get("id", ""))] = sc
			_hotspot_by_scene[sc] = str((o as Dictionary).get("id", ""))


## 这个场景归哪种路由。空串 = 没路由（切片里的场景不该出现这种情况）。
func route_of(scene_id: String) -> String:
	return str(_route_by_scene.get(scene_id, ""))


## 一拍归哪种路由 —— 拍跟着场景走。
## 【为什么不做到拍一级】理由写在 data/story_map.json 的 _说明 里：
## 原文是连续的散文，按拍切会把它切碎。整个场景一起路由就没有这个问题。
func route_of_beat(bid: String) -> String:
	return route_of(str(bid).get_slice(":", 0))


func is_spine(scene_id: String) -> bool:
	return _spine_index.has(scene_id)


## 场景在脊梁上的位置。不在脊梁上返回 -1。
func spine_index(scene_id: String) -> int:
	return int(_spine_index.get(scene_id, -1))


## 挂这个场景的热点 id。没有返回空串。
func hotspot_for_scene(scene_id: String) -> String:
	return str(_hotspot_by_scene.get(scene_id, ""))


## 这个热点会播哪个场景。没挂返回空串。
func scene_for_hotspot(hotspot_id: String) -> String:
	return str(_scene_by_hotspot.get(hotspot_id, ""))


## 这场戏在哪间房演。空串 = 没有房间，走呈现层（见 story_map 的 present）。
##
## 归 object 路由的场景不用在这里再写一遍 —— 它在哪间房，
## 由「哪个热点挂着它」决定，rooms.json 已经说了（S4 保证只有一个）。
func room_for_scene(scene_id: String) -> String:
	var r := str(scene_rooms.get(scene_id, ""))
	if not r.is_empty():
		return r
	var h := hotspot_for_scene(scene_id)
	if not h.is_empty():
		for rid in rooms:
			for o in (rooms[rid] as Dictionary).get("objects", []):
				if o is Dictionary and str((o as Dictionary).get("id", "")) == h:
					return rid
	return ""


## 这场戏是不是走呈现层（暗场引文 / 书信 / 章节卡）—— 没有房间的那种。
func is_present_scene(scene_id: String) -> bool:
	return present_scenes.has(scene_id)


## 脊梁上的下一步：从 scene_id 往后走，跳过所有不归脊梁的场景，返回第一个归脊梁的。
##
## 【为什么不能直接用 story.json 的 next】那条链上串着九个扩写节点。
## 其中七个归热点（玩家查不查得到，看他走没走到），两个归脊梁。
## 直接顺着 next 走的话，玩家没查告示墙，剧情就永远停在 p_intro 上 ——
## 而画面上什么都不会说，像是卡了。
##
## chosen_to 只在选择场景用：玩家选了哪条分支就传哪条（空串 = 取第一条）。
## 选中的分支如果不在脊梁上，就继续顺着它往下找。
func spine_step(scene_id: String, chosen_to: String = "") -> String:
	var sc: Dictionary = scenes.get(scene_id, {})
	if sc.is_empty():
		return ""
	var edges := _story_edges(scene_id)
	if edges.is_empty():
		return ""
	var cursor := ""
	if not chosen_to.is_empty() and edges.has(chosen_to):
		cursor = chosen_to
	else:
		cursor = str(edges[0])

	# 顺着链往下找第一个脊梁节点。最多找 scenes.size() 步 ——
	# 再多就是数据里有个环，不能把调用方挂死在这儿。
	var guard := 0
	while not cursor.is_empty() and guard <= scenes.size():
		guard += 1
		if is_spine(cursor):
			return cursor
		var nxt := _story_edges(cursor)
		if nxt.is_empty():
			return ""
		cursor = str(nxt[0])
	return ""


## 脊梁上第一个节点（玩家从这儿开始）。
func spine_start() -> String:
	if is_spine(start_scene):
		return start_scene
	# 起始场景要是不归脊梁（比如被改成了某个热点扩写），顺着走一格。
	return spine_step(start_scene)


## 一条史实注的正文。找不到返回空串。
## notes.json 的形状是 {章名: [{h: 标题, b: 正文}, …]}。
func note_body(chapter: String, title: String) -> String:
	for n in notes.get(chapter, []):
		if str(n.get("h", "")) == title:
			return str(n.get("b", ""))
	return ""


func count_beats() -> int:
	var n := 0
	for id in scenes:
		n += (scenes[id].get("beats", []) as Array).size()
	return n


## 取某一拍。bid 形如 "c1_shack:12" 或扩写的 "x2:0"。
func get_beat(bid: String) -> Dictionary:
	var parts := bid.split(":")
	if parts.size() != 2:
		return {}
	var sc: Dictionary = scenes.get(parts[0], {})
	if sc.is_empty():
		return {}
	var beats: Array = sc.get("beats", [])
	var i := int(parts[1])
	return beats[i] if i >= 0 and i < beats.size() else {}


## 某场景在播放时**实际**会走的节拍序列 —— 已把 supersede 顶替算进去。
## 每一项是 {"bid": "场景id:序号", "beat": {...}}。
##
## 带上 bid 是必须的：回想屏要靠它排序（I5），而且顶替之后
## 下标会和原文的 beats 数组对不上 —— 只返回 beat 的话，
## 谁也没法说清「这一拍在原文里是哪一拍」。
func playable_bids(scene_id: String) -> Array:
	var sc: Dictionary = scenes.get(scene_id, {})
	if sc.is_empty():
		return []
	var out: Array = []
	var sup := {}
	for s in sc.get("supersede", []):
		sup[int(s.get("beat", -1))] = s
	var beats: Array = sc.get("beats", [])
	for i in beats.size():
		if sup.has(i):
			var by: String = sup[i].get("by", "")
			var repl: Dictionary = scenes.get(by, {})
			if repl.is_empty():
				continue
			var rb: Array = repl.get("beats", [])
			for j in rb.size():
				out.append({"bid": "%s:%d" % [by, j], "beat": rb[j]})
			continue
		out.append({"bid": "%s:%d" % [scene_id, i], "beat": beats[i]})
	return out


## 只要节拍本身、不要 bid 的版本。给「拼文本做比对」这类场合用。
func playable_beats(scene_id: String) -> Array:
	var out: Array = []
	for e in playable_bids(scene_id):
		out.append(e["beat"])
	return out


## 一拍该以什么面目进回想日志。返回 {"w": 说话人, "x": 正文}，空字典表示这一拍不入日志。
##
## 【为什么要提出来做成共用的】
## 现在有两个地方会「播一拍」：BeatRunner（走剧情）和房间层（查物件时播一段扩写）。
## 两边各写一遍映射的话，同一句话在回想屏里就会有两种记法 ——
## 而且这种不一致不会报错，只会在回想屏里长出一堆格式不齐的条目。
static func beat_text(beat: Dictionary) -> Dictionary:
	match str(beat.get("t", "")):
		"n":
			return {"w": "", "x": str(beat.get("x", ""))}
		"d":
			return {"w": str(beat.get("w", "")), "x": str(beat.get("x", ""))}
		"q":
			return {"w": str(beat.get("src", "")), "x": str(beat.get("x", ""))}
		"letter":
			return {"w": "书信 · " + str(beat.get("title", "")), "x": str(beat.get("body", ""))}
		"choice":
			return {"w": "", "x": str(beat.get("prompt", ""))}
		"map":
			return {"w": "", "x": str(beat.get("text", ""))}
	return {}


## 把 "——" 与 "＊" 抹平再比。理由见 tools/export_story.js 的 norm()：
## 同一个分隔符在原文与读本里是两种排法，不抹平会把排版差异误判成改字。
static func norm(t: String) -> String:
	var s := t.replace(" ", "").replace("\n", "").replace("\t", "").replace("\r", "")
	return s.replace("—", "").replace("＊", "")


# ============================================================
#  校验
# ============================================================

func _validate() -> void:
	if scenes.is_empty():
		errors.append("story.json 里一个场景都没有")
		return

	_validate_start()
	_validate_refs()
	_validate_beats()
	_validate_supersede()
	_validate_ast()
	_validate_reachability()
	_validate_slice()
	_validate_story_map()
	_validate_rooms()
	_validate_quests()


## V7：切片边界。导出器给的 slice 里每个 id 都得是真场景。
## 这条防的是「导出器的 SLICE 清单和实际场景对不上」——
## 那会让 demo 在某个节点突然停住，而导出器那边是绿的。
func _validate_slice() -> void:
	if slice.is_empty():
		errors.append("V7 story.json 没有 slice 字段 —— 导出器是不是没重跑？")
		return
	for id in slice:
		if not scenes.has(id):
			errors.append("V7 slice 里的 %s 不是真场景" % id)


func _validate_start() -> void:
	if start_scene.is_empty():
		errors.append("V1 没写起始场景")
	elif not scenes.has(start_scene):
		errors.append("V1 起始场景不存在：%s" % start_scene)


func _validate_refs() -> void:
	for id in scenes:
		var sc: Dictionary = scenes[id]
		var nx: Variant = sc.get("next")
		if nx is String:
			if not scenes.has(nx):
				errors.append("V2 %s.next 指向不存在的场景 %s" % [id, nx])
		elif nx is Dictionary:
			for k in ["then", "else"]:
				var t: Variant = nx.get(k)
				if t is String and not scenes.has(t):
					errors.append("V2 %s.next.%s 指向不存在的场景 %s" % [id, k, t])
		for b in sc.get("beats", []):
			if b.get("t") != "choice":
				continue
			for o in b.get("opts", []):
				var to: String = o.get("to", "")
				if not scenes.has(to):
					errors.append("V2 %s 的选项指向不存在的场景 %s" % [id, to])


func _validate_beats() -> void:
	for id in scenes:
		var beats: Array = scenes[id].get("beats", [])
		if beats.is_empty():
			errors.append("V3 场景 %s 一个节拍都没有" % id)
		for i in beats.size():
			var t: String = beats[i].get("t", "")
			if not BEAT_TYPES.has(t):
				errors.append("V3 %s:%d 节拍类型不认识：%s" % [id, i, t])


func _validate_supersede() -> void:
	for id in scenes:
		var sc: Dictionary = scenes[id]
		var beats: Array = sc.get("beats", [])
		for s in sc.get("supersede", []):
			var i := int(s.get("beat", -1))
			var by: String = s.get("by", "")
			if i < 0 or i >= beats.size():
				errors.append("V4 %s 的 supersede 指向越界的拍 %d" % [id, i])
				continue
			if not scenes.has(by):
				errors.append("V4 %s 的 supersede.by 指向不存在的场景 %s" % [id, by])
				continue
			# 被顶替的那一拍，其原文必须确实是替换者的**起句**
			var orig: String = norm(str(beats[i].get("x", beats[i].get("body", ""))))
			var repl_beats: Array = scenes[by].get("beats", [])
			if repl_beats.is_empty():
				errors.append("V4 %s 的替换者 %s 是空的" % [id, by])
				continue
			var head := ""
			for rb in repl_beats:
				head += norm(str(rb.get("x", rb.get("body", ""))))
			if not head.begins_with(orig):
				errors.append("V4 %s:%d 被 %s 顶替，但替换者并不是以它的原文起句 —— "
					% [id, i, by] + "定位规则不成立，这一拍可能放错了地方")


func _validate_ast() -> void:
	for id in scenes:
		# next 大多数时候就是个场景 id 字符串（正常情况），只有少数几处是条件节点。
		# 别把字符串当节点查 —— 那会把 81 个正常场景全报成错的。
		var nx: Variant = scenes[id].get("next")
		if nx is Dictionary:
			_ast_walk(nx, "V5 %s.next" % id)
		for i in (scenes[id].get("beats", []) as Array).size():
			var b: Dictionary = scenes[id]["beats"][i]
			var where := "V5 %s:%d" % [id, i]
			if b.has("cond"):
				_ast_walk(b["cond"], where + ".cond")
			if b.has("lock"):
				_ast_walk(b["lock"], where + ".lock")
			for j in (b.get("opts", []) as Array).size():
				var o: Dictionary = b["opts"][j]
				if o.has("cond"):
					_ast_walk(o["cond"], "%s.opt%d.cond" % [where, j])
				if o.has("lock"):
					_ast_walk(o["lock"], "%s.opt%d.lock" % [where, j])


func _ast_walk(node: Variant, where: String) -> void:
	if node == null or node is String:
		return   # 字符串是合法的「直接就是结果」，不是条件节点
	if not (node is Dictionary):
		errors.append("%s 不是合法的条件节点：%s" % [where, node])
		return
	var op: String = node.get("op", "")
	if not AST_OPS.has(op):
		errors.append("%s 用了不认识的算子 %s" % [where, op])
		return
	match op:
		"and", "or":
			for a in node.get("args", []):
				_ast_walk(a, where + ".args")
		"not":
			_ast_walk(node.get("arg"), where + ".arg")
		"if":
			# 分岔节点：条件本身也要查（c4_end.next 的条件就是个 flag 节点）
			_ast_walk(node.get("cond"), where + ".cond")
		"eq", "ne", "gt", "gte", "lt", "lte":
			_ast_walk(node.get("lhs"), where + ".lhs")
			_ast_walk(node.get("rhs"), where + ".rhs")
		"template":
			for a in node.get("args", []):
				_ast_walk(a, where + ".args")
		"call":
			for a in node.get("args", []):
				_ast_walk(a, where + ".args")
		"flag":
			var nm: String = node.get("name", "")
			if nm.is_empty():
				errors.append("%s 是 flag 节点却没写名字" % where)


## V6：从 start 出发能不能走到每个扩写节点。
## 走不到 = 扩写写好了但没接进图，玩家永远看不到，而导出器那边是绿的 —— 最阴的一种错。
func _validate_reachability() -> void:
	var seen := {}
	var queue: Array = [start_scene]
	while not queue.is_empty():
		var id: String = queue.pop_back()
		if seen.has(id) or not scenes.has(id):
			continue
		seen[id] = true
		var sc: Dictionary = scenes[id]
		var nx: Variant = sc.get("next")
		if nx is String:
			queue.append(nx)
		elif nx is Dictionary:
			for k in ["then", "else"]:
				if nx.get(k) is String:
					queue.append(nx[k])
		for b in sc.get("beats", []):
			if b.get("t") == "choice":
				for o in b.get("opts", []):
					queue.append(o.get("to", ""))
			if b.get("t") == "map":
				# 揭章可能带跳转
				if b.get("to") is String:
					queue.append(b["to"])
		for s in sc.get("supersede", []):
			queue.append(s.get("by", ""))

	for id in scenes:
		if scenes[id].has("expansion") and not seen.has(id):
			errors.append("V6 扩写节点 %s（第 %d 条「%s」）从起始场景走不到 —— 没接进图"
				% [id, scenes[id]["expansion"].get("run", -1), scenes[id]["expansion"].get("title", "")])

	for id in scenes:
		if not seen.has(id):
			warnings.append("场景 %s 从起始场景走不到（可能是尚未启用的章节）" % id)


# ============================================================
#  房间校验（R 组）
# ============================================================
#
# 房间是**手写**的 —— 没有导出器替我数、替我交叉核对。
# 所以这一组的每一条都在拦一类「手写时最容易犯、又最不容易发现」的错：
#   R1 start 房间存在          —— 改名字忘了改 start，一进游戏就是黑屏
#   R2 房间的骨架字段齐全      —— 少一个 walk，整间房走不动
#   R3 出生点在可走区里        —— 差 0.02 就站在墙里，卡住不动
#   R4 物件字段齐全、kind 认识
#   R5 物件**必须有内容**      —— 空壳物件点了没反应，是最难发现的一种「坏了」
#   R6 物件引用的扩写 / 史实注真的存在
#   R7 出口落点合法            —— 落地就在墙里、或一落地就被另一个出口吸走
#   R8 每个房间至少有一个出口  —— 走进去出不来

const ROOM_KINDS := ["look", "talk", "exit"]


## S1~S6：叙事路由。这是**手写**的，没有导出器替我兜底 ——
## 而且它错起来是沉默的：路由漏一个场景，玩家玩到那儿就卡住不动，
## 而所有别的检查都是绿的。
##
## 为什么值得这么厚一层：story_map 是「原文只做脊梁」那句话的落点。
## 它一旦漂了，漂的是**剧情顺序**，那是这部作品最不能动的东西。
func _validate_story_map() -> void:
	if story_map.is_empty():
		return   # 手写文件，允许缺席

	# S1 脊梁上的每个 id 都得是真场景，且不许重复。
	# 重复的后果很隐蔽：_reindex_routes 里下标会互相盖掉，
	# 后面按 spine_index 排序的地方就会静默地用错位置。
	var seen_spine := {}
	for id in spine:
		var sid := str(id)
		if not scenes.has(sid):
			errors.append("S1 脊梁上的 %s 不是真场景" % sid)
			continue
		if seen_spine.has(sid):
			errors.append("S1 脊梁上的 %s 出现了两次 —— 剧情会原地打转" % sid)
		seen_spine[sid] = true
		if not slice_set.is_empty() and not slice_set.has(sid):
			errors.append("S1 脊梁上的 %s 不在切片里 —— 玩到那儿接不下去" % sid)

	# S2 一个场景只许归一种路由。spine ∩ object 是最要命的一种：
	# 那个场景会被剧情游标播一遍、又被热点播一遍。
	for id in object_scenes:
		var oid := str(id)
		if seen_spine.has(oid):
			errors.append("S2 %s 既在脊梁上、又挂给了热点 —— 会播两遍。"
				% oid + "二选一：归剧情的就留在 spine 里，归调查的从 spine 里删掉。")
		if ambient_scenes.has(oid):
			errors.append("S2 %s 同时归了 object 和 ambient" % oid)

	# S3 object / ambient 里的都得是真场景，而且都得是**扩写节点**。
	# 跟 R6 同一条道理：原文节拍归脊梁走，别挂到物件上。
	for group in [["object", object_scenes], ["ambient", ambient_scenes]]:
		var gname := str(group[0])
		for id in (group[1] as Array):
			var gid := str(id)
			if not scenes.has(gid):
				errors.append("S3 %s 表里的 %s 不是真场景" % [gname, gid])
			elif not (scenes[gid] as Dictionary).has("expansion"):
				errors.append("S3 %s 表里的 %s 不是扩写节点 —— 原文归脊梁走（会播两遍）"
					% [gname, gid])

	# S4 object 路由的场景，在 rooms.json 里必须**恰好**有一个热点挂着它。
	# 零个 = 这段扩写玩家永远看不到（写了等于没写）；
	# 两个 = 查哪个热点都播同一段，其中一个必然是写错了。
	for id in object_scenes:
		var sid := str(id)
		if not scenes.has(sid):
			continue
		var n := 0
		for rid in rooms:
			for o in (rooms[rid] as Dictionary).get("objects", []):
				if o is Dictionary and str((o as Dictionary).get("scene", "")) == sid:
					n += 1
		if n == 0:
			errors.append("S4 %s 归了 object 路由，可是 rooms.json 里没有热点挂它 —— "
				% sid + "这段扩写玩家永远看不到")
		elif n > 1:
			errors.append("S4 %s 被 %d 个热点挂着 —— 查哪一个都播同一段，其中必有一个写错了"
				% [sid, n])

	# S5（I1 不丢）切片里每个场景恰好被路由一次。
	# 这条是整套路由的底线：漏一个 = 那段剧情在 RPG 里根本不存在。
	var missing: Array = []
	var multi: Array = []
	for id in slice:
		var sid := str(id)
		if not _route_by_scene.has(sid):
			missing.append(sid)
	for id in _route_by_scene:
		if not slice_set.is_empty() and not slice_set.has(str(id)):
			multi.append(str(id))
	if not missing.is_empty():
		errors.append("S5（I1）切片里有 %d 个场景没有任何路由，玩家玩到那儿会卡住：%s"
			% [missing.size(), ", ".join(missing)])
	if not multi.is_empty():
		errors.append("S5（I1）路由表里有不在切片里的场景：%s" % ", ".join(multi))

	# S6（I2 脊梁保序）故事图里每条边 A→B，只要 A、B 都在脊梁上，
	# A 就必须排在 B 前面。这就是「脊梁保序」——
	# 它不比对两份清单（那会变成拿我写的东西验我写的东西），
	# 而是直接问故事图：你自己说下一步该是谁，脊梁有没有听你的。
	var bad_edges: Array = []
	for id in spine:
		var sid := str(id)
		if not scenes.has(sid):
			continue
		for nxt in _story_edges(sid):
			if not _spine_index.has(nxt):
				continue   # 分支没选中的那条不在这条线上，不算
			if spine_index(nxt) <= spine_index(sid):
				bad_edges.append("%s → %s" % [sid, nxt])
	if not bad_edges.is_empty():
		errors.append("S6（I2）脊梁顺序跟故事图对不上，这几条边被排反了：%s"
			% ", ".join(bad_edges))

	# S7 每一场脊梁戏都得有个去处：要么在某间房里演，要么显式声明走呈现层。
	# 这条防的是「戏写好了，可是没告诉引擎在哪儿演」——
	# 那种错在运行期表现为「走到下一场，画面一片空白，也没报错」。
	var homeless: Array = []
	for id in spine:
		var sid := str(id)
		if not scenes.has(sid) or is_present_scene(sid):
			continue
		if scene_rooms.has(sid):
			var rid := str(scene_rooms[sid])
			if not rooms.has(rid):
				errors.append("S7 %s 排给了不存在的房间 %s" % [sid, rid])
			continue
		if route_of(sid) == ROUTE_OBJECT:
			continue   # 房间由热点决定，S4 已经保证挂上了
		homeless.append(sid)
	if not homeless.is_empty():
		errors.append("S7 这几场脊梁戏没说在哪儿演：%s —— "
			% ", ".join(homeless)
			+ "要么在 rooms 里给它一间房，要么放进 present（呈现层）")

	# S7 反过来：present 里的场景得是真场景，且不该同时有房间（那就有两个说法了）。
	for id in present_scenes:
		var pid := str(id)
		if not scenes.has(pid):
			errors.append("S7 present 里的 %s 不是真场景" % pid)
		elif scene_rooms.has(pid):
			errors.append("S7 %s 既在 present 里、又排了房间 %s —— 两个说法，运行期不知道该听谁的"
				% [pid, str(scene_rooms[pid])])
		elif not is_spine(pid):
			errors.append("S7 present 里的 %s 不在脊梁上 —— 挂上去也不会被播到" % pid)

	# S7 再反过来：rooms 里排的房间得是真房间，场景得是真场景。
	for id in scene_rooms:
		var sid2 := str(id)
		if not scenes.has(sid2):
			errors.append("S7 rooms 表里的 %s 不是真场景" % sid2)
		var rid2 := str(scene_rooms[id])
		if not rooms.has(rid2):
			errors.append("S7 rooms 表里 %s 排给了不存在的房间 %s" % [sid2, rid2])


## 一个场景在故事图上的出边：next，或者选择场景的全部分支。
## 只认故事图自己说的，不看 story_map —— 这是 S6 能当预言机的前提。
func _story_edges(scene_id: String) -> Array:
	var sc: Dictionary = scenes.get(scene_id, {})
	if sc.is_empty():
		return []
	var nx: Variant = sc.get("next")
	if nx is String and not (nx as String).is_empty():
		return [nx]
	var out: Array = []
	for b in sc.get("beats", []):
		if not (b is Dictionary) or str((b as Dictionary).get("t", "")) != "choice":
			continue
		for o in (b as Dictionary).get("opts", []):
			if o is Dictionary:
				out.append(str((o as Dictionary).get("to", "")))
	return out


func _validate_rooms() -> void:
	if rooms.is_empty():
		return   # 手写文件，允许缺席

	if not rooms.has(room_start):
		errors.append("R1 rooms.json 的 start 指向不存在的房间：%s" % room_start)

	for id in rooms:
		var r: Dictionary = rooms[id]
		var where := "R2 房间 %s" % id
		if str(r.get("name", "")).is_empty():
			errors.append(where + " 没写名字")
		if str(r.get("bg", "")).is_empty():
			errors.append(where + " 没写背景路径")

		var walk := _polygon(r.get("walk", []))
		if walk.size() < 3:
			errors.append(where + " 的 walk 不是个多边形（至少三个点）：%s" % str(r.get("walk", [])))
			continue
		var spawn := _point(r.get("spawn", []))
		if spawn == Vector2.INF:
			errors.append(where + " 的 spawn 不是 [x, y]：%s" % str(r.get("spawn", [])))
		elif not Geometry2D.is_point_in_polygon(spawn, walk):
			errors.append("R3 %s 的出生点 %s 不在可走区里 —— 一进场就站在墙里，动不了"
				% [where, spawn])

		var seen_ids := {}
		for o in r.get("objects", []):
			_validate_object(id, o, seen_ids)
		_validate_exits(id, r)


func _validate_object(room_id: String, o: Variant, seen_ids: Dictionary) -> void:
	if not (o is Dictionary):
		errors.append("R4 房间 %s 里有个物件不是字典" % room_id)
		return
	var oid := str(o.get("id", ""))
	var tag := "R4 房间 %s 的物件 %s" % [room_id, oid if not oid.is_empty() else "(没写 id)"]
	if oid.is_empty():
		errors.append(tag + " 没写 id")
	elif seen_ids.has(oid):
		errors.append(tag + " 重复了 —— 聚焦时不知道该选哪一个")
	else:
		seen_ids[oid] = true
	if str(o.get("name", "")).is_empty():
		errors.append(tag + " 没写名字（玩家看到的提示会是个空框）")

	var kind := str(o.get("kind", ""))
	if not ROOM_KINDS.has(kind):
		errors.append(tag + " 的 kind 不认识：%s（只认 %s）" % [kind, ", ".join(ROOM_KINDS)])
		return

	var rect := _rect(o.get("rect", []))
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		errors.append(tag + " 的 rect 不是 [x, y, 宽, 高]：%s" % str(o.get("rect", [])))
	elif rect.position.x < 0.0 or rect.position.y < 0.0 \
			or rect.end.x > 1.0 or rect.end.y > 1.0:
		errors.append(tag + " 的 rect 出了房间：%s" % str(rect))

	# 只有出口用 to/at，其余两种必须有内容。
	if kind == "exit":
		return

	var scene := str(o.get("scene", ""))
	var note: Variant = o.get("note", [])
	if scene.is_empty() and not (note is Array and (note as Array).size() == 2):
		errors.append("R5 " + tag
			+ " 是个空壳 —— 既没有 scene（扩写）也没有 note（史实注），"
			+ "点了不会有任何反应。要么给它内容，要么把它从 rooms.json 里删掉。")
		return
	if not scene.is_empty():
		if not scenes.has(scene):
			errors.append("R6 %s 的 scene 指向不存在的场景：%s" % [tag, scene])
		elif not scenes[scene].has("expansion"):
			errors.append("R6 %s 的 scene 指向的不是扩写节点：%s"
				% [tag, scene] + " —— 原文节拍归脊梁走，别挂到物件上（那会把它播两遍）")
	if note is Array and (note as Array).size() == 2:
		var ch := str(note[0])
		var ti := str(note[1])
		if note_body(ch, ti).is_empty():
			errors.append("R6 %s 的 note 在 notes.json 里找不到：%s / %s" % [tag, ch, ti])


func _validate_exits(room_id: String, r: Dictionary) -> void:
	var exits := 0
	for o in r.get("objects", []):
		if not (o is Dictionary) or str(o.get("kind", "")) != "exit":
			continue
		exits += 1
		var oid := str(o.get("id", "?"))
		var tag := "R7 房间 %s 的出口 %s" % [room_id, oid]
		var to := str(o.get("to", ""))
		var at := _point(o.get("at", []))
		if at == Vector2.INF:
			errors.append(tag + " 的 at 不是 [x, y]：%s" % str(o.get("at", [])))
		if to.is_empty():
			errors.append(tag + " 没写 to")
			continue
		if not rooms.has(to):
			errors.append(tag + " 指向不存在的房间：%s" % to)
			continue
		var tr: Dictionary = rooms[to]
		var twalk := _polygon(tr.get("walk", []))
		if twalk.size() >= 3 and at != Vector2.INF \
				and not Geometry2D.is_point_in_polygon(at, twalk):
			errors.append(tag + " 的落点 %s 不在 %s 的可走区里 —— 一过去就站在墙里"
				% [at, to])
		if at == Vector2.INF:
			continue
		# 落点不该压在目标房间的障碍物上。
		for b in _blockers(tr.get("blockers", [])):
			if (b["rect"] as Rect2).has_point(at):
				errors.append(tag + " 的落点 %s 压在 %s 的「%s」上" % [at, to, b["name"]])
		# 落点也不该落进目标房间的某个出口里 ——
		# 那样一进门就又被那个出口吸住，两间房之间来回弹。
		for o2 in tr.get("objects", []):
			if not (o2 is Dictionary) or str(o2.get("kind", "")) != "exit":
				continue
			var r2 := _rect(o2.get("rect", []))
			if r2.size.x > 0.0 and r2.has_point(at):
				errors.append(tag + " 的落点 %s 正落在 %s 的出口「%s」里 —— "
					% [at, to, str(o2.get("id", "?"))]
					+ "一进去就会被那个出口吸走，两间房来回弹")

	if exits == 0:
		errors.append("R8 房间 %s 一个出口都没有 —— 走进去就出不来了" % room_id)


# ============================================================
#  任务校验（Q 组）
# ============================================================
#
# 任务表是手写的（data/quests.json），任务状态又全靠游标与印章现算 ——
# 一旦锚点写错（指向不在脊梁上的场景、顺序写反、印章 id 写错），
# 运行时不报错，只是任务栏永远不更新或永远完不成。逐条拦住：
#   Q1 id 唯一且非空
#   Q2 start/end 都是脊梁场景，且 start 在 end 前面
#   Q3 goal 锚点是脊梁场景，落在区间内，严格按脊梁顺序
#   Q4 marker 真的存在
#   Q5 goal 文字非空

func _validate_quests() -> void:
	if quests.is_empty():
		return   # 手写文件，允许缺席

	var defs: Variant = quests.get("quests", [])
	if not (defs is Array):
		errors.append("Q1 quests.json 的 quests 不是数组")
		return

	var seen_ids := {}
	for q in defs:
		if not (q is Dictionary):
			errors.append("Q1 quests.json 里有一条不是字典")
			continue
		var qid := str(q.get("id", ""))
		var tag := "Q 任务 %s" % (qid if not qid.is_empty() else "(没写 id)")
		if qid.is_empty():
			errors.append(tag + " 没写 id")
		elif seen_ids.has(qid):
			errors.append(tag + " 重复了")
		else:
			seen_ids[qid] = true

		var st := str(q.get("start", ""))
		var en := str(q.get("end", ""))
		var i_st := spine_index(st)
		var i_en := spine_index(en)
		if i_st < 0:
			errors.append("%s 的 start「%s」不在脊梁上" % [tag, st])
		if i_en < 0:
			errors.append("%s 的 end「%s」不在脊梁上" % [tag, en])
		if i_st >= 0 and i_en >= 0 and not (i_st < i_en):
			errors.append("%s 的 start 必须排在 end 前面（%s=%d, %s=%d）"
				% [tag, st, i_st, en, i_en])

		var mk := str(q.get("marker", ""))
		if not mk.is_empty():
			var found := false
			for m in markers:
				if m is Dictionary and str((m as Dictionary).get("id", "")) == mk:
					found = true
					break
			if not found:
				errors.append("%s 的 marker「%s」在 markers.json 里不存在" % [tag, mk])

		var prev := -1
		for g in q.get("goals", []):
			if not (g is Dictionary):
				errors.append(tag + " 有一条 goal 不是字典")
				continue
			var at := str(g.get("at", ""))
			var txt := str(g.get("text", ""))
			if txt.strip_edges().is_empty():
				errors.append("%s 的 goal「%s」没有文字" % [tag, at])
			var i_at := spine_index(at)
			if i_at < 0:
				errors.append("%s 的 goal 锚点「%s」不在脊梁上" % [tag, at])
				continue
			if i_st >= 0 and i_en >= 0 and (i_at < i_st or i_at > i_en):
				errors.append("%s 的 goal 锚点「%s」落在 start/end 区间外" % [tag, at])
			if i_at <= prev:
				errors.append("%s 的 goal 锚点「%s」顺序不对（必须严格按脊梁向后）" % [tag, at])
			prev = i_at


# ---------------------- 归一化坐标的小工具 ----------------------
# rooms.json 里的坐标一律是 0~1。这几个函数只做「形状对不对」的检查，
# 不做范围检查 —— 范围由各自的校验点负责，混在一起会报出看不懂的错。

func _point(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() == 2 \
			and (v[0] is float or v[0] is int) and (v[1] is float or v[1] is int):
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.INF


func _polygon(v: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not (v is Array):
		return out
	for p in v:
		var q := _point(p)
		if q == Vector2.INF:
			return PackedVector2Array()
		out.append(q)
	return out


func _rect(v: Variant) -> Rect2:
	if v is Array and (v as Array).size() == 4:
		var p := _point([v[0], v[1]])
		var s := _point([v[2], v[3]])
		if p != Vector2.INF and s != Vector2.INF:
			return Rect2(p, s)
	return Rect2()


func _blockers(v: Variant) -> Array:
	var out: Array = []
	if not (v is Array):
		return out
	for b in v:
		if b is Dictionary:
			out.append({"name": str(b.get("name", "?")), "rect": _rect(b.get("rect", []))})
	return out
