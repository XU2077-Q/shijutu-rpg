extends Node
## 条件 AST 求值器。
##
## 【为什么要有这一层】
## 剧本里有 18 处字段是函数（选项门槛、结局分岔）。JSON 装不下函数，
## 而旧做法「把函数序列化掉」等于静默丢掉条件 —— 那是最危险的一类错：
## 游戏照跑，只是某条线永远进不去，玩一百遍也未必发现。
## 所以导出器把函数编成**声明式 AST**，这里负责求值。
##
## 【三个入口为什么分开且带类型】
## 条件求出来是布尔，分岔求出来是场景 id，锁提示求出来是一段文字。
## 混成一个 eval() 返回 Variant，就得在几十个调用点各写一次类型判断，
## 写漏一处就是运行时崩。分开之后，类型不对在**调用的那一行**就炸。
##
## 算子合法性由 DataDB 在启动时全量校验（V5），所以这里遇到不认识的算子
## 属于「不该发生」—— 那就 push_error 并返回安全值，不装作没事。

## call 算子能调用的函数。目前剧本里没有 call 节点，先留空表，
## 将来真要用时在这里登记，未登记的名字一律报错，不允许隐式生效。
const CALLABLE := {}


func eval_cond(node: Variant) -> bool:
	var v: Variant = _eval(node)
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		return not (v as String).is_empty()
	return false


## 分岔：返回场景 id。节点必须是 if，或直接就是一个字符串。
func eval_next(node: Variant) -> String:
	if node is String:
		return node
	if node is Dictionary and node.get("op") == "if":
		return str(node["then"]) if eval_cond(node["cond"]) else str(node["else"])
	push_error("[CondEval] 分岔节点形状不对：%s" % node)
	return ""


## 锁提示：把 {0} {1} 填成当前数值。
func eval_text(node: Variant) -> String:
	if node is String:
		return node
	if node is Dictionary and node.get("op") == "template":
		var out: String = node.get("fmt", "")
		var args: Array = node.get("args", [])
		for i in args.size():
			out = out.replace("{%d}" % i, _as_text(_eval(args[i])))
		return out
	push_error("[CondEval] 文本节点形状不对：%s" % node)
	return ""


# ============================================================
#  内部
# ============================================================

func _eval(node: Variant) -> Variant:
	if node is bool or node is int or node is float or node is String:
		return node
	if not (node is Dictionary):
		push_error("[CondEval] 不是条件节点：%s" % node)
		return false

	var op: String = node.get("op", "")
	match op:
		"lit":
			return node.get("value")
		"var":
			return GameState.get_var(str(node.get("name", "")))
		"flag":
			return GameState.has_flag(str(node.get("name", "")))
		"not":
			return not eval_cond(node.get("arg"))
		"and":
			for a in node.get("args", []):
				if not eval_cond(a):
					return false
			return true
		"or":
			for a in node.get("args", []):
				if eval_cond(a):
					return true
			return false
		"eq":
			return _eval(node.get("lhs")) == _eval(node.get("rhs"))
		"ne":
			return _eval(node.get("lhs")) != _eval(node.get("rhs"))
		"gt":
			return _num(node.get("lhs")) > _num(node.get("rhs"))
		"gte":
			return _num(node.get("lhs")) >= _num(node.get("rhs"))
		"lt":
			return _num(node.get("lhs")) < _num(node.get("rhs"))
		"lte":
			return _num(node.get("lhs")) <= _num(node.get("rhs"))
		"has_ending":
			return GameState.is_unlocked(str(node.get("name", "")))
		"template":
			return eval_text(node)
		"call":
			var nm: String = str(node.get("name", ""))
			if not CALLABLE.has(nm):
				push_error("[CondEval] call 了未登记的函数 %s" % nm)
				return false
			var args: Array = []
			for a in node.get("args", []):
				args.append(_eval(a))
			return CALLABLE[nm].callv(args)

	push_error("[CondEval] 不认识的算子 %s" % op)
	return false


func _num(node: Variant) -> float:
	var v: Variant = _eval(node)
	if v is int or v is float:
		return float(v)
	push_error("[CondEval] 期望数值，拿到 %s" % v)
	return 0.0


func _as_text(v: Variant) -> String:
	if v is bool:
		return "真" if v else "假"
	return str(v)
