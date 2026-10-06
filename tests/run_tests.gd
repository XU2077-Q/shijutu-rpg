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
	"res://tests/unit/test_cast.gd",
	"res://tests/unit/test_beat_runner.gd",
	"res://tests/unit/test_vn_screen.gd",
	"res://tests/unit/test_title.gd",
	"res://tests/unit/test_rooms.gd",
	"res://tests/unit/test_nav.gd",
	"res://tests/unit/test_room_view.gd",
	"res://tests/unit/test_note_view.gd",
]

## 跳过这些从基类继承来的方法（它们不是用例）
const NOT_TESTS := ["test_case.gd"]

## 冒烟加载要扫的目录。
const SMOKE_DIRS := ["res://autoload", "res://scripts", "res://scenes", "res://tests"]


func _ready() -> void:
	await get_tree().process_frame
	var code: int = await _run()
	get_tree().quit(code)


## 全工程能不能解析 —— 这是**任何**用例有意义的前提。
##
## 【为什么要这一步：第二种「安静的假绿」】
## 写死的 TEST_SCRIPTS 防住了第一种假绿（少跑文件）。
## 还有一种防不住：**用例跑到一半被中断**。
## 踩过一次：room_view.gd 里引了一个不存在的变量，脚本解析不过；
## room.tscn 于是加载出一个**没有脚本的 Control**；测试里每一句
## v.stand_at_spot() 都报「Invalid call」并中断该用例 ——
## 而中断的用例 failures 是空的，跑架报了 ✓。
## 12 个用例里 11 个假绿，只有碰巧有一句不依赖脚本的断言的那个红了。
##
## GDScript 里没有「捕获运行时错误」这回事，跑架无法在调用点察觉中断。
## 所以换个方向：进任何用例之前，先把全工程的脚本和场景加载一遍。
## 加载不动就当场报出来 —— 解析错误是**整体性**的，早报晚报都要报，
## 早报至少不会伪装成一屏绿勾。
##
## 【判「加载不动」不能写 load(p) == null】
## 解析不过的 .gd，load() **照样返回一个非 null 的 GDScript 对象**
## （它只是编译不出代码）。所以那条判据是假的 —— 第一版就是这么写的，
## 探针文件摆在 tests/ 里，跑架依旧报全绿。
## 真正分得开的是 Script.can_instantiate()：
## 好脚本 true，坏脚本 false（reload() 则是 0 对 ERR_PARSE_ERROR=43）。
func _smoke_load() -> PackedStringArray:
	var bad: PackedStringArray = []
	for d in SMOKE_DIRS:
		_walk_load(d, bad)
	return bad


func _walk_load(dir_path: String, bad: PackedStringArray) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		bad.append("%s —— 目录打不开" % dir_path)
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var p := dir_path.path_join(n)
		if d.current_is_dir():
			if not n.begins_with("."):
				_walk_load(p, bad)
		elif n.ends_with(".gd"):
			var s: Variant = load(p)
			if s == null or not (s is GDScript) or not (s as GDScript).can_instantiate():
				bad.append("%s —— 编译不出来（解析错误？）" % p)
		elif n.ends_with(".tscn"):
			# 场景里挂的脚本由上面那一遍 .gd 兜住了（本工程的脚本都在
			# autoload/scripts/scenes/tests 底下）。这里只验场景本身读得出来。
			var ps: Variant = load(p)
			if ps == null or not (ps is PackedScene):
				bad.append("%s —— 场景读不出来" % p)
		n = d.get_next()
	d.list_dir_end()


func _run() -> int:
	print("")
	print("══════════════════════════════════════════════════════════")
	print("  《时局图》RPG —— 测试")
	print("══════════════════════════════════════════════════════════")

	var total_cases := 0
	var total_asserts := 0
	var total_failures := 0
	var broken_files: PackedStringArray = []

	# 先冒烟。解析不过的话，下面每一条绿都是假的，先停下来。
	broken_files.append_array(_smoke_load())
	if not broken_files.is_empty():
		print("")
		print("  工程里有加载不动的东西 —— 用例不必跑了，跑了也是假绿：")
		for b in broken_files:
			print("    ! %s" % b)
		print("══════════════════════════════════════════════════════════")
		return 1

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
