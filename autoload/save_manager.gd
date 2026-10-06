extends Node
## 存档：5 个手存格 + 1 个自动存档，沿用网页版的格局。
##
## 【原子写】先写 .tmp，再改名盖上去。
## 安卓会在后台随时杀进程。直接往存档文件上写，写一半被杀就是坏档 ——
## 而玩家往往正是在要紧处切出去的。改名在文件系统层面是原子的：
## 要么旧的完整版，要么新的完整版，不会出现半截。
##
## 【save_version 从第一天就写】
## 加字段容易，事后补迁移难。现在写上，将来改结构才有地方挂迁移函数，
## 而不是靠「读档时缺字段就填默认值」那种越滚越乱的补丁。
##
## 【三个平台的落盘位置都是免权限、都离线】
##   Windows  %APPDATA%\Godot\app_userdata\时局图\
##   Android  应用私有目录
##   Web      IndexedDB（所以 Web demo 的存档也是本地的，不上传任何东西）

const SAVE_VERSION := 1
const SLOT_COUNT := 5
const DIR := "user://saves/"

signal saved(slot: String)
signal loaded(slot: String)
signal save_failed(slot: String, reason: String)


func _ready() -> void:
	_ensure_dir()


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		var err := DirAccess.make_dir_recursive_absolute(DIR)
		if err != OK:
			push_error("[SaveManager] 建不出存档目录 %s（错误码 %d）" % [DIR, err])


func slot_path(slot: String) -> String:
	return DIR + "slot_%s.json" % slot


func has_slot(slot: String) -> bool:
	return FileAccess.file_exists(slot_path(slot))


func autosave() -> bool:
	return save("auto")


# ---------------------- 写 ----------------------

## world / quests 由空间层传进来。剧情状态从 GameState 取。
##
## 【world 为什么要 merge 而不是直接用传进来的】
## 存档有两个入口：VN 屏（走剧情时自动存）和房间（走动时存）。
## VN 屏那边手上没有空间状态，只会传一个空字典 —— 直接用的话，
## 每走一段剧情，玩家在房间里查过什么、站在哪儿，就被抹成空的了。
## 所以默认从 GameState 取一份，调用方传进来的再盖在上面。
func build_save(world: Dictionary = {}, quests: Dictionary = {}) -> Dictionary:
	var w := GameState.world_dict()
	w.merge(world, true)
	return {
		"save_version": SAVE_VERSION,
		"meta": {
			"ch": GameState.chapter,
			"scene": GameState.scene,
			"idx": GameState.idx,
			"t": int(Time.get_unix_time_from_system()),
			"last": _last_line(),
			"shen": int(GameState.stats.get("shen", 0)),
			"lin": int(GameState.stats.get("lin", 0)),
			"room": GameState.room,
		},
		"story": GameState.to_dict(),
		"world": w,
		"quests": quests,
	}


func save(slot: String, world: Dictionary = {}, quests: Dictionary = {}) -> bool:
	_ensure_dir()
	var data := build_save(world, quests)
	var text := JSON.stringify(data, "\t")

	var tmp := slot_path(slot) + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		var why := "打不开临时文件（错误码 %d）" % FileAccess.get_open_error()
		push_error("[SaveManager] " + why)
		save_failed.emit(slot, why)
		return false
	f.store_string(text)
	f.flush()
	f.close()

	var ok := _atomic_replace(tmp, slot_path(slot))
	if ok:
		saved.emit(slot)
	else:
		save_failed.emit(slot, "改名失败")
	return ok


## 把 tmp 原子地盖到目标上。
## POSIX 上 rename() 本就覆盖，Windows 上 MoveFile 遇到已存在的目标会失败，
## 所以失败时退一步：先删目标再改名。这一步不是原子的，
## 但窗口只有几微秒，且 tmp 里的新档已经完整落盘了 —— 比直接覆写安全得多。
func _atomic_replace(from: String, to: String) -> bool:
	var err := DirAccess.rename_absolute(from, to)
	if err == OK:
		return true
	DirAccess.remove_absolute(to)
	err = DirAccess.rename_absolute(from, to)
	if err != OK:
		push_error("[SaveManager] 改名失败 %s → %s（错误码 %d）" % [from, to, err])
		return false
	return true


# ---------------------- 读 ----------------------

## 返回 {ok, world, quests, error}
func load_slot(slot: String) -> Dictionary:
	if not has_slot(slot):
		return {"ok": false, "error": "没有这个存档"}
	var text := FileAccess.get_file_as_string(slot_path(slot))
	var d: Variant = JSON.parse_string(text)
	if not (d is Dictionary):
		return {"ok": false, "error": "存档读不出来（可能损坏）"}
	var m: Variant = _migrate(d)
	if not (m is Dictionary):
		return {"ok": false, "error": "存档版本 %s 迁移失败" % d.get("save_version")}

	GameState.from_dict(m.get("story", {}))
	GameState.load_world(m.get("world", {}))
	loaded.emit(slot)
	return {
		"ok": true,
		"world": m.get("world", {}),
		"quests": m.get("quests", {}),
		"meta": m.get("meta", {}),
	}


## 只读元信息，给存档格列表用 —— 不必把整档反序列化进内存。
func peek(slot: String) -> Dictionary:
	if not has_slot(slot):
		return {}
	var text := FileAccess.get_file_as_string(slot_path(slot))
	var d: Variant = JSON.parse_string(text)
	if not (d is Dictionary):
		return {"corrupt": true}
	return d.get("meta", {})


func list_slots() -> Array:
	var out: Array = []
	for i in SLOT_COUNT:
		var slot := str(i + 1)
		out.append({"slot": slot, "exists": has_slot(slot), "meta": peek(slot)})
	return out


func delete_slot(slot: String) -> void:
	if has_slot(slot):
		DirAccess.remove_absolute(slot_path(slot))


# ---------------------- 迁移 ----------------------

func _migrate(d: Dictionary) -> Variant:
	var v := int(d.get("save_version", 0))
	if v > SAVE_VERSION:
		push_error("[SaveManager] 存档版本 %d 比本程序(%d)还新，不敢读" % [v, SAVE_VERSION])
		return null
	# 将来的迁移在这里逐级加：
	#   if v < 2: d = _migrate_1_to_2(d); v = 2
	if v < 1:
		# v0 = 没有版本号的最早期档。目前不存在，留个口子。
		d["save_version"] = 1
	return d


func _last_line() -> String:
	if GameState.log.is_empty():
		return ""
	var last: Dictionary = GameState.log[GameState.log.size() - 1]
	var x: String = str(last.get("x", ""))
	return x.substr(0, 24)
