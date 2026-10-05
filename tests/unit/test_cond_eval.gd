extends TestCase
## 条件 AST 求值。
##
## 用**合成样例**测，不依赖真数据 —— 因为真数据里那 18 处条件全在
## c2_end / c4_end / c5_choice，都不在切片范围内。
## 这是刻意把最难的一块从关键路径上挪开：求值器可以现在测透，
## 而不必等第三章做完。下面四种形状就是那 18 处的**逐字形状**，
## 从 index.html 里 dump 出来照抄的，不是我想象出来的。

func _reset() -> void:
	GameState.reset()


# ============================================================
#  形状一：function(s){ return !!s.flags.lin_shiye; }   —— 14 处
# ============================================================

func test_shape_flag() -> void:
	_reset()
	var node := {"op": "flag", "name": "lin_shiye"}
	eq(CondEval.eval_cond(node), false, "旗标没置时应为假")
	GameState.set_flag("lin_shiye")
	eq(CondEval.eval_cond(node), true, "旗标置上后应为真")


func test_shape_flag_absent_is_false_not_error() -> void:
	# 旗标从没被设过 —— 这是最常见的情况，必须是干净的 false，
	# 而不是报错或者 null
	_reset()
	eq(CondEval.eval_cond({"op": "flag", "name": "从来没设过的旗标"}), false,
		"不存在的旗标应当求值为 false")


func test_all_three_real_flag_names() -> void:
	# c2_end 里那 15 处 cond 用的就是这三个旗标名
	for nm in ["lin_shiye", "lin_qingbao", "lin_youyu"]:
		_reset()
		GameState.set_flag(nm)
		eq(CondEval.eval_cond({"op": "flag", "name": nm}), true, "旗标 " + nm)


# ============================================================
#  形状二：s => s.flags.c4_taiwan ? "c4_tw1" : "c5_1"   —— 1 处
# ============================================================

func test_shape_if_next() -> void:
	_reset()
	var node := {"op": "if", "cond": {"op": "flag", "name": "c4_taiwan"},
		"then": "c4_tw1", "else": "c5_1"}
	eq(CondEval.eval_next(node), "c5_1", "没去台湾时应走 c5_1")
	GameState.set_flag("c4_taiwan")
	eq(CondEval.eval_next(node), "c4_tw1", "去了台湾时应走 c4_tw1")


func test_eval_next_passes_through_plain_string() -> void:
	# next 既可能是 AST 也可能是普通字符串，两种都要能吃
	eq(CondEval.eval_next("c1_home"), "c1_home", "纯字符串直接返回")


# ============================================================
#  形状三：s => s.shen >= 13 && s.lin >= 8   —— 1 处
# ============================================================

func _double_gate() -> Dictionary:
	return {"op": "and", "args": [
		{"op": "gte", "lhs": {"op": "var", "name": "shen"}, "rhs": {"op": "lit", "value": 13}},
		{"op": "gte", "lhs": {"op": "var", "name": "lin"}, "rhs": {"op": "lit", "value": 8}},
	]}


func test_shape_and_double_gate() -> void:
	_reset()
	var node := _double_gate()
	eq(CondEval.eval_cond(node), false, "两项都不到时应为假")

	GameState.stats["shen"] = 13
	eq(CondEval.eval_cond(node), false, "只够沈怀瑾那一项，仍应为假")

	GameState.stats["lin"] = 8
	eq(CondEval.eval_cond(node), true, "两项都刚好够，应为真")


func test_double_gate_boundaries() -> void:
	# 门槛值是 >=，边界必须精确。差一就少一个结局，而且很难发现。
	var node := _double_gate()
	var cases := [
		[12, 8, false, "沈怀瑾差 1"],
		[13, 7, false, "林婉如差 1"],
		[13, 8, true, "刚好够"],
		[20, 20, true, "远超"],
		[0, 0, false, "全零"],
	]
	for c in cases:
		_reset()
		GameState.stats["shen"] = c[0]
		GameState.stats["lin"] = c[1]
		eq(CondEval.eval_cond(node), c[2], "%s（%d / %d）" % [c[3], c[0], c[1]])


# ============================================================
#  形状四：锁提示模板   —— 1 处
# ============================================================

func test_shape_template_lock_text() -> void:
	_reset()
	var node := {"op": "template",
		"fmt": "需要 沈怀瑾觉醒 ≥13、林婉如觉醒 ≥8（当前 {0} / {1}）",
		"args": [{"op": "var", "name": "shen"}, {"op": "var", "name": "lin"}]}
	GameState.stats["shen"] = 9
	GameState.stats["lin"] = 4
	eq(CondEval.eval_text(node),
		"需要 沈怀瑾觉醒 ≥13、林婉如觉醒 ≥8（当前 9 / 4）",
		"锁提示应当把当前数值填进去")


func test_template_with_more_than_two_slots() -> void:
	# 目前只有两槽，但别把 9 槽写死成 2 槽
	_reset()
	GameState.stats["shen"] = 1
	GameState.stats["lin"] = 2
	var node := {"op": "template", "fmt": "{0}-{1}-{0}",
		"args": [{"op": "var", "name": "shen"}, {"op": "var", "name": "lin"}]}
	eq(CondEval.eval_text(node), "1-2-1", "同一槽位可以复用")


# ============================================================
#  其余算子
# ============================================================

func test_comparison_operators() -> void:
	_reset()
	GameState.stats["shen"] = 10
	var v := {"op": "var", "name": "shen"}
	var l := {"op": "lit", "value": 10}
	eq(CondEval.eval_cond({"op": "eq", "lhs": v, "rhs": l}), true, "eq 相等")
	eq(CondEval.eval_cond({"op": "ne", "lhs": v, "rhs": l}), false, "ne 相等")
	eq(CondEval.eval_cond({"op": "gt", "lhs": v, "rhs": {"op": "lit", "value": 9}}), true, "gt")
	eq(CondEval.eval_cond({"op": "lt", "lhs": v, "rhs": {"op": "lit", "value": 9}}), false, "lt")
	eq(CondEval.eval_cond({"op": "lte", "lhs": v, "rhs": l}), true, "lte 相等")
	eq(CondEval.eval_cond({"op": "gte", "lhs": v, "rhs": l}), true, "gte 相等")


func test_not_and_or() -> void:
	_reset()
	var t := {"op": "flag", "name": "a"}
	var f := {"op": "flag", "name": "b"}
	eq(CondEval.eval_cond({"op": "not", "arg": f}), true, "not 假 = 真")
	eq(CondEval.eval_cond({"op": "or", "args": [t, f]}), false, "or 全假")
	eq(CondEval.eval_cond({"op": "and", "args": [t, f]}), false, "and 有假")
	GameState.set_flag("b")
	eq(CondEval.eval_cond({"op": "or", "args": [t, f]}), true, "or 一真")
	eq(CondEval.eval_cond({"op": "and", "args": [t, f]}), false, "and 仍有一假")


func test_and_short_circuits() -> void:
	# and 遇到假就该停 —— 否则后面的节点即使畸形也会被求值，
	# 把一个「本该跳过」的错报出来
	_reset()
	var node := {"op": "and", "args": [
		{"op": "flag", "name": "no_such_flag"},
		{"op": "不存在的算子"},
	]}
	eq(CondEval.eval_cond(node), false, "短路后不应碰到第二个节点")


func test_has_ending() -> void:
	_reset()
	var node := {"op": "has_ending", "name": "e1"}
	eq(CondEval.eval_cond(node), false, "未解锁")
	GameState.unlock_ending("e1")
	eq(CondEval.eval_cond(node), true, "已解锁")


func test_lit_and_bare_values() -> void:
	_reset()
	eq(CondEval.eval_cond({"op": "lit", "value": true}), true, "lit true")
	eq(CondEval.eval_cond({"op": "lit", "value": false}), false, "lit false")
	# 裸值也应当能直接吃（有些字段可能直接就是字符串/布尔）
	eq(CondEval.eval_cond("非空字符串"), true, "裸字符串按非空为真")
	eq(CondEval.eval_cond(""), false, "空字符串为假")


# ============================================================
#  真数据里的那 18 处，逐个求值
# ============================================================

func test_real_ast_nodes_all_evaluate_without_error() -> void:
	# 不检查结果对不对（那要看具体语境），只检查**求值不炸**。
	# 求值器面对畸形节点会 push_error，跑架会把错误打出来。
	_reset()
	var n := 0
	for id in DataDB.scenes:
		var sc: Dictionary = DataDB.scenes[id]
		var nx: Variant = sc.get("next")
		if nx is Dictionary and nx.get("op") == "if":
			n += 1
			CondEval.eval_next(nx)
		for b in sc.get("beats", []):
			for k in ["cond", "lock"]:
				if b.has(k) and b[k] is Dictionary:
					n += 1
					if k == "cond":
						CondEval.eval_cond(b[k])
					else:
						CondEval.eval_text(b[k])
			for o in b.get("opts", []):
				for k in ["cond", "lock"]:
					if o.has(k) and o[k] is Dictionary:
						n += 1
						if k == "cond":
							CondEval.eval_cond(o[k])
						else:
							CondEval.eval_text(o[k])
	eq(n, 18, "真数据里的条件节点总数")
