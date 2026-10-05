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
##
## V5/V6 这两条最值钱：它们拦的都是「东西写好了，但没接上」这种**沉默的错**。

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

var story_map: Dictionary = {}   ## 手写：节拍 → 路由
var rooms: Dictionary = {}       ## 手写：房间定义
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
	var rm: Variant = _read_json("rooms.json", false)
	if rm is Dictionary:
		rooms = rm
	var qs: Variant = _read_json("quests.json", false)
	if qs is Dictionary:
		quests = qs


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
