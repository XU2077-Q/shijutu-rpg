extends Node
## 测试跑架。
##
## 跑法（在工程根目录）：
##     godot --headless --path . res://tests/test_main.tscn
## 全绿退出码 0，有失败退出码 1 —— 可以直接挂 CI。
##
## 【测试清单为什么是写死的】
## 让 DirAccess 去扫目录、自动发现测试文件，看起来更优雅，
## 但那有个很坏的失败模式：路径写错、文件被排除、扫到一半出错，
## 跑架都会**安静地少跑几个文件**然后报「全绿」。
## 写死的话，文件不在就是 load() 返回 null，当场报错。
## 宁可每次加测试文件时手动加一行，也不要一个会骗人的绿。

const TEST_SCRIPTS := [
	"res://tests/unit/test_data.gd",
	"res://tests/unit/test_cond_eval.gd",
	"res://tests/unit/test_save.gd",
	"res://tests/unit/test_font.gd",
	"res://tests/unit/test_beat_runner.gd",
	"res://tests/unit/test_vn_screen.gd",
]

## 跳过这些从基类继承来的方法（它们不是用例）
const NOT_TESTS := ["test_case.gd"]


func _ready() -> void:
	await get_tree().process_frame
	var code: int = await _run()
	get_tree().quit(code)


func _run() -> int:
	print("")
	print("══════════════════════════════════════════════════════════")
	print("  《时局图》RPG —— 测试")
	print("══════════════════════════════════════════════════════════")

	var total_cases := 0
	var total_asserts := 0
	var total_failures := 0
	var broken_files: PackedStringArray = []

	for path in TEST_SCRIPTS:
		if not ResourceLoader.exists(path):
			broken_files.append(path + "  —— 文件不存在")
			continue
		var scr: Variant = load(path)
		if scr == null or not (scr is GDScript):
			broken_files.append(path + "  —— 加载不出 GDScript")
			continue

		var file_name: String = str(path).get_file()
		var obj: Variant = (scr as GDScript).new()
		if obj == null:
			broken_files.append(path + "  —— new() 失败")
			continue
		obj.host = self

		var cases := _test_methods(scr)
		if cases.is_empty():
			broken_files.append(path + "  —— 一个 test_ 方法都没有（跑架写错了？）")
			continue

		print("\n── %s  (%d 个用例)" % [file_name, cases.size()])
		for m in cases:
			total_cases += 1
			obj._begin(m)
			# 用例可以是协程（要 await 帧、等动画）。
			#
			# 【必须写成 `await obj.call(m)` 这一整句】
			# 先 `var res = obj.call(m)` 再 `await res` 会直接报
			# 「Trying to call an async function without await」——
			# Godot 是在**调用点**判的：只有 AWAIT 字节码紧跟在 CALL 后面，
			# 这个动态调用才被允许是协程。分成两句，编译器就不知道了。
			# 不 await 的话，跑架会在用例跑到一半时 quit()，
			# 那是**安静的假绿**：断言一条都没跑，报告说通过。
			# 顺带一提，对同步方法 await 也是合法的，会立刻返回。
			await obj.call(m)
			total_asserts += obj.assertions
			if obj.failures.is_empty():
				print("   ✓ %s" % m)
			else:
				total_failures += obj.failures.size()
				print("   ✗ %s" % m)
				for f in obj.failures:
					print("       %s" % f)

	print("")
	print("══════════════════════════════════════════════════════════")
	if not broken_files.is_empty():
		print("  跑架本身有问题：")
		for b in broken_files:
			print("    ! %s" % b)
	if total_failures == 0 and broken_files.is_empty():
		print("  全绿 —— %d 个用例 / %d 条断言" % [total_cases, total_asserts])
		print("══════════════════════════════════════════════════════════")
		return 0
	print("  %d 个用例 / %d 条断言，%d 条失败" % [total_cases, total_asserts, total_failures])
	print("══════════════════════════════════════════════════════════")
	return 1


## 取一个测试脚本里所有 test_ 开头的方法（含继承，靠 NOT_TESTS 过滤掉基类的）
func _test_methods(scr: GDScript) -> PackedStringArray:
	var out: PackedStringArray = []
	for m in scr.get_script_method_list():
		var n: String = m.get("name", "")
		if n.begins_with("test_") and not out.has(n):
			out.append(n)
	out.sort()
	return out
