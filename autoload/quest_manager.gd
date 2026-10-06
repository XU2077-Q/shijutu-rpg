extends Node
## 任务栏。
##
## 【为什么不存状态】任务进度完全由两样已经存盘的东西现算：
##   剧情游标 GameState.scene（在脊梁上的位置）、印章 GameState.markers。
## 再单立一份「任务状态」写进存档，就有两份真相，迟早漂 ——
## 游标在 c1_end、任务却还挂着「去书房」那种 bug 不会报错，只会嘲笑玩家。
##
## 任务的定义在 data/quests.json（手写，DataDB 的 Q 组校验兜底）。

enum State { LOCKED, ACTIVE, DONE }

## 游标不在任何任务的区间里（比如标题屏、纯 VN 模式还没进场）时，
## 调用方应当隐藏任务栏 —— 用空字符串表示「现在没有任务」。


func quest_defs() -> Array:
	var qs: Variant = DataDB.quests.get("quests", [])
	return qs if qs is Array else []


## 一条任务现在的状态。游标过了 end，或章末印章已揭，就算完。
func state_of(q: Dictionary) -> int:
	var marker := str(q.get("marker", ""))
	if not marker.is_empty() and GameState.is_marker_revealed(marker):
		return State.DONE
	var cur := DataDB.spine_index(GameState.scene)
	if cur < 0:
		# 游标不在脊梁上（object/ambient 播完回到房间时仍是脊梁场景，
		# 只有标题屏之类才会走到这儿）：有印章就算完，否则按锁住算太冤，
		# 交给调用方隐藏即可 —— 返回 LOCKED 仅用于一览里的保守显示。
		return State.LOCKED
	if cur > DataDB.spine_index(str(q.get("end", ""))):
		return State.DONE
	if cur < DataDB.spine_index(str(q.get("start", ""))):
		return State.LOCKED
	return State.ACTIVE


## 当下在做的任务。没有返回空字典。
func current() -> Dictionary:
	for q in quest_defs():
		if q is Dictionary and state_of(q) == State.ACTIVE:
			return q
	return {}


## 当前任务的章题，如「序章 · 春愁」。没有任务返回空串。
func current_title() -> String:
	var q := current()
	if q.is_empty():
		return ""
	return "%s · %s" % [str(q.get("chapter", "")), str(q.get("title", ""))]


## 当下目标文字：最后一个锚点不晚于当前游标的 goal。
func current_goal() -> String:
	var q := current()
	if q.is_empty():
		return ""
	var cur := DataDB.spine_index(GameState.scene)
	var out := ""
	for g in q.get("goals", []):
		if not (g is Dictionary):
			continue
		if DataDB.spine_index(str(g.get("at", ""))) <= cur:
			out = str(g.get("text", ""))
	return out


## 已完成的任务数（任务一览用）。
func done_count() -> int:
	var n := 0
	for q in quest_defs():
		if q is Dictionary and state_of(q) == State.DONE:
			n += 1
	return n
