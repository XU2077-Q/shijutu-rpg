class_name TestCase
extends RefCounted
## 极简测试基类。
##
## 【为什么不用 GUT】
## 我们要测的东西几乎全是**数据不变量**：每个 bid 恰好路由一次、脊梁保序、
## 存档往返、AST 求值。这些是纯函数，不需要场景树、不需要替身对象、
## 不需要 JUnit 报告。GUT 是个几千行的编辑器插件，为这点事引入它，
## 换来的是「它自己升级会破坏我们的测试」这类新问题。
##
## 这里的契约只有三条：
##   1. 方法名以 test_ 开头就会被跑
##   2. 断言失败**不中断**该用例 —— 一次跑完，把所有问题都列出来
##   3. 跑架只认 failures 是否为空
## 将来真需要替身对象了，再换 GUT 也不迟，测试文件本身不用改。

var failures: PackedStringArray = []
var assertions: int = 0
var current: String = ""

## 测试宿主 —— 跑架自己（一个 Node）。
##
## 【为什么要有这个】
## TestCase 是 RefCounted，没有场景树。绝大多数用例是纯函数，用不着树。
## 但「界面接不接得住剧本」这类用例必须把**真的界面**挂进树里跑 ——
## 挂个假的替身就测不出真界面才会犯的错（比如模态队列把节拍吞了）。
## 所以由跑架把自己借出来，用例要用时用 host.add_child()。
var host: Node = null

## 跑架在调用每个 test_ 方法前会设好 current，用于把失败归属到具体用例
func _begin(test_name: String) -> void:
	current = test_name
	assertions = 0
	failures.clear()


func ok(cond: bool, msg: String) -> void:
	assertions += 1
	if not cond:
		failures.append(msg)


func eq(actual: Variant, expected: Variant, msg: String) -> void:
	assertions += 1
	if actual != expected:
		failures.append("%s\n          期望  %s\n          实际  %s"
			% [msg, _fmt(expected), _fmt(actual)])


func ne(actual: Variant, unexpected: Variant, msg: String) -> void:
	assertions += 1
	if actual == unexpected:
		failures.append("%s\n          不该等于  %s" % [msg, _fmt(unexpected)])


func has_key(d: Variant, k: Variant, msg: String) -> void:
	assertions += 1
	if not (d is Dictionary) or not (d as Dictionary).has(k):
		failures.append("%s\n          字典里没有键  %s" % [msg, _fmt(k)])


func has_value(arr: Variant, v: Variant, msg: String) -> void:
	assertions += 1
	if not (arr is Array) or not (arr as Array).has(v):
		failures.append("%s\n          数组里没有  %s" % [msg, _fmt(v)])


func near(actual: float, expected: float, tol: float, msg: String) -> void:
	assertions += 1
	if absf(actual - expected) > tol:
		failures.append("%s\n          期望约 %f（容差 %f）\n          实际  %f"
			% [msg, expected, tol, actual])


func fail(msg: String) -> void:
	assertions += 1
	failures.append(msg)


func _fmt(v: Variant) -> String:
	var s := str(v)
	return s if s.length() <= 160 else s.substr(0, 160) + "…"
