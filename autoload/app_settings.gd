extends Node
## 全局设置。与存档无关 —— 玩家调一次，以后一直是他调的样子。
##
## 【为什么不用 SaveManager】
## 存档是「这一局玩到哪」，设置是「这个人怎么玩」。重置游戏清的是前者，
## 顺手把人家调好的文字速度也抹了，是要挨骂的。（Ren'Py 版的
## engine/50_reset.rpy 里有一模一样的教训，两个工程共用同一条原则。）
##
## 【持久化】ConfigFile 写 user://settings.cfg。Web 上 user:// 落在
## IndexedDB，重启浏览器还在。
##
## 【pending_resume 为什么在这里】
## 标题屏 → VN 屏是一次 change_scene，那棵树整个重建，
## 任何成员变量都递不过去。两个屏之间的纸条只能放在 autoload 上。

signal changed

const PATH := "user://settings.cfg"
const CPS_MIN := 15.0
const CPS_MAX := 90.0
const CPS_DEFAULT := 45.0

## 每秒打几个字。中文 40~50 是舒适区：再快就糊，再慢就等。
var cps := CPS_DEFAULT
var fullscreen := false

## 标题屏「续 前 一 局」→ VN 屏的递纸条。
var pending_resume := false


func _ready() -> void:
	_load()
	_apply_fullscreen()


func set_cps(v: float) -> void:
	cps = clampf(v, CPS_MIN, CPS_MAX)
	_save()
	changed.emit()


func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_fullscreen()
	_save()
	changed.emit()


func _apply_fullscreen() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen \
			else DisplayServer.WINDOW_MODE_WINDOWED
	# Web 上这是「页面全屏」；浏览器要求必须由玩家手势触发 ——
	# 本设置只在设置面板的开关里被调，恰好满足。
	DisplayServer.window_set_mode(mode)


func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	cps = clampf(float(cf.get_value("ui", "cps", CPS_DEFAULT)), CPS_MIN, CPS_MAX)
	fullscreen = bool(cf.get_value("ui", "fullscreen", false))


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("ui", "cps", cps)
	cf.set_value("ui", "fullscreen", fullscreen)
	var err := cf.save(PATH)
	if err != OK:
		push_error("[AppSettings] 设置写不进去（错误码 %d）" % err)
