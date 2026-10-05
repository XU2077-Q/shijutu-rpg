extends Node
## 剧情状态：旗标、觉醒值、回想日志、已解锁结局。
##
## 【与网页版最大的结构差异：剧情游标与空间状态分开】
## 网页版只有一条线（idx 走到黑）。RPG 里玩家会在房间里走动、调查物件、
## 跟 NPC 说话 —— 这些动作**不该**推进剧情游标，否则在茶楼多看一眼桌子
## 剧情就往前跳一格，整部作品就散了。
## 所以：
##     story.scene / story.idx   —— 只在脊梁（spine）上推进
##     world.room / player_pos   —— 空间状态，爱怎么动怎么动
## 存档也照这个分法写，两不相扰。

signal flag_changed(name: String, value: Variant)
signal stat_changed(name: String, value: int)
signal ending_unlocked(id: String)
signal chapter_changed(name: String)

## 旗标。键名与网页版一致（lin_shiye / c4_taiwan …），存档才通得过。
var flags: Dictionary = {}

## 觉醒值。网页版里这两个数直接写在存档顶层，这里收进 stats。
var stats: Dictionary = {"shen": 0, "lin": 0}

## 其他具名变量。目前 AST 只用到 shen / lin，留个口子。
var vars: Dictionary = {}

## 回想日志。**每一拍都进**，包括玩家跳过没看的闲笔 ——
## 这是「允许可选文本」的前提：跳过的人事后在回想屏还能读到。
## 按原始 bid 顺序追加，回想屏直接顺序重放即可。
var log: Array = []

## 已解锁结局 id → true。未解锁的结局在结局一览里**不露名字**。
var unlocked: Dictionary = {}

## 已揭的印章（时局图上的 `map` 拍）。与结局分开记 ——
## 印章是「看到了什么」，结局是「走到了哪」，两者可以不同步。
var markers: Dictionary = {}

## 已看过的史实注（按 "章名/标题" 存）
var codex_seen: Dictionary = {}

## 当前章名，用于日志分组与章节卡
var chapter: String = ""

## 剧情游标（只在脊梁上推进）
var scene: String = ""
var idx: int = 0


func reset() -> void:
	flags.clear()
	stats = {"shen": 0, "lin": 0}
	vars.clear()
	log.clear()
	unlocked.clear()
	markers.clear()
	codex_seen.clear()
	chapter = ""
	scene = ""
	idx = 0


# ---------------------- 旗标 ----------------------

func has_flag(name: String) -> bool:
	return bool(flags.get(name, false))


func set_flag(name: String, value: Variant = true) -> void:
	if name.is_empty():
		push_error("[GameState] 旗标名是空的")
		return
	if flags.get(name, null) == value:
		return
	flags[name] = value
	flag_changed.emit(name, value)


## 具名变量。shen / lin 走 stats，其余走 vars。
## AST 里的 var 节点从这里取数。
func get_var(name: String) -> Variant:
	if stats.has(name):
		return stats[name]
	return vars.get(name, 0)


func set_var(name: String, value: Variant) -> void:
	if stats.has(name):
		add_stat(name, int(value) - int(stats[name]))
	else:
		vars[name] = value


func add_stat(name: String, delta: int) -> void:
	if not stats.has(name):
		push_error("[GameState] 没有这个觉醒值：%s" % name)
		return
	var v: int = int(stats[name]) + delta
	if v == stats[name]:
		return
	stats[name] = v
	stat_changed.emit(name, v)


# ---------------------- 结局 ----------------------

func unlock_ending(id: String) -> void:
	if id.is_empty() or unlocked.has(id):
		return
	unlocked[id] = true
	ending_unlocked.emit(id)


func is_unlocked(id: String) -> bool:
	return unlocked.has(id)


# ---------------------- 印章 ----------------------

func reveal_marker(id: String) -> void:
	if id.is_empty():
		return
	markers[id] = true


func is_marker_revealed(id: String) -> bool:
	return markers.has(id)


# ---------------------- 回想 ----------------------

## 记一拍。bid 是原文坐标（"c1_shack:12"）或扩写坐标（"x2:0"）。
## 按 bid 的**原始顺序**追加 —— 但玩家可能倒着调查物件，
## 所以这里不排序，交给回想屏按 bid 重排（见 I5）。
func log_beat(bid: String, speaker: String, text: String) -> void:
	if text.strip_edges().is_empty():
		return
	log.append({"bid": bid, "c": chapter, "w": speaker, "x": text})


func mark_codex(chapter_name: String, title: String) -> void:
	codex_seen["%s/%s" % [chapter_name, title]] = true


func has_seen_codex(chapter_name: String, title: String) -> bool:
	return codex_seen.has("%s/%s" % [chapter_name, title])


# ---------------------- 存档 ----------------------

func to_dict() -> Dictionary:
	return {
		"flags": flags.duplicate(true),
		"stats": stats.duplicate(true),
		"vars": vars.duplicate(true),
		"log": log.duplicate(true),
		"unlocked": unlocked.duplicate(true),
		"markers": markers.duplicate(true),
		"codex_seen": codex_seen.duplicate(true),
		"chapter": chapter,
		"scene": scene,
		"idx": idx,
	}


func from_dict(d: Dictionary) -> void:
	reset()
	flags = d.get("flags", {}).duplicate(true)
	stats = d.get("stats", {"shen": 0, "lin": 0}).duplicate(true)
	vars = d.get("vars", {}).duplicate(true)
	log = d.get("log", []).duplicate(true)
	unlocked = d.get("unlocked", {}).duplicate(true)
	markers = d.get("markers", {}).duplicate(true)
	codex_seen = d.get("codex_seen", {}).duplicate(true)
	chapter = d.get("chapter", "")
	scene = d.get("scene", "")
	idx = int(d.get("idx", 0))
