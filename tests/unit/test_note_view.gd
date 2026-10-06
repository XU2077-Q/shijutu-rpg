extends TestCase
## 史实注：正文不许把标记漏给玩家。
##
## 【为什么值得单独一个文件】
## 这一条是从浏览器里看出来的，而且**藏了很久**：茶盏那条注翻开之后，
## 正文最后一行明晃晃地印着
##   [color=#8d7c5c][font_size=19]　　—— 《马关条约》正文[/font_size][/color]
## 52 条注里只有 2 条带 [ref]（茶盏、告示墙），而这两条恰好是
## 浏览器自查原来点不到的两个热点 —— 点击坐标写错了，「点了没反应」
## 把「翻出来是乱码」挡在后面。修好坐标，乱码才露出来。
##
## 所以这里不但测那两条，还要**遍历全部 52 条** ——
## 只有两条带 [ref]，靠肉眼抽查永远抽不到它们。

## markup() 允许出现的方括号，一个不多。
## 这份表就是「什么是标记、什么是正文」的分界线：
## 表里的是我们自己拼进去的样式，表外的一律算漏出来的正文。
const ALLOWED := ["[lb]", "[color=#8d7c5c]", "[/color]", "[font_size=19]", "[/font_size]"]

## 解析之后**不许**还留在玩家眼前的东西。
##
## 【为什么这第二种检查是必须的 —— 它是拿一次假绿换来的】
## 「扫方括号」那一种（_stray_tags）抓的是**漏转义**：
## 正文里的 [ 没转，RichTextLabel 会把它当标签，吃掉一段字。
## 但那个 bug 是反过来的 —— **多转义**：我们自己插的 [color=…] 被一起转了，
## 标记字符串里变成 `[lb]color=#8d7c5c]`，扫方括号的检查读作
## 「一个合法的 [lb]，后面跟一串普通字符」，**全绿**。
## 可玩家读到的是 [color=#8d7c5c] 这一行字面量。
## 所以两种检查都得有：一个查标记字符串，一个查解析结果。
const LEAKED := ["[color=", "[/color]", "[font_size=", "[/font_size]", "[lb]", "[ref]", "[/ref]"]


## 把字符串里所有方括号片段挑出来，返回**不在允许表里**的那些。
static func _stray_tags(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while true:
		var a := s.find("[", i)
		if a < 0:
			break
		var b := s.find("]", a)
		if b < 0:
			out.append(s.substr(a, 12) + "…（没有闭合的 ]）")
			break
		var tag := s.substr(a, b - a + 1)
		if not ALLOWED.has(tag):
			out.append(tag)
		i = b + 1
	return out


## 解析之后还留在玩家眼前的标记。空 = 干净。
static func _leaked(plain: String) -> PackedStringArray:
	var out := PackedStringArray()
	for bad in LEAKED:
		if plain.contains(bad):
			out.append(bad)
	return out


func test_the_source_line_is_styled_and_never_shown_as_markup() -> void:
	var got := NoteView.markup("正文一句。[ref]《马关条约》正文[/ref]")
	ok(got.contains("[color=#8d7c5c]"), "落款应当真的带上小字样式：%s" % got)
	ok(got.contains("—— 《马关条约》正文"), "落款应当写出出处：%s" % got)
	ok(not got.contains("[ref]") and not got.contains("[/ref]"), "[ref] 应当已经换掉了")
	ok(got.begins_with("正文一句。"), "落款之前的正文应当原样保留：%s" % got)
	# 上面几条都在看**标记字符串**，那正是当初放它过去的地方。
	# 这一条才落在玩家眼前：解析完不该还剩下样式标签。
	ok(not got.contains("[lb]color"),
		"落款的样式标签被当成正文转义了（玩家会读到 [color=…]）：%s" % got)


## 【这一条才是真正兜住那个 bug 的】
## 两条带 [ref] 的注靠抽查看不见，52 条一起过一遍就看得见。
##
## 用**真的 NoteView**（不是静态函数）过一遍 —— 因为要的是 RichTextLabel
## 解析之后的结果。少了这一步，上面那个 bug 在标记字符串里是全绿的。
func test_every_real_note_reads_cleanly_to_the_player() -> void:
	var n := NoteView.new()
	host.add_child(n)
	await host.get_tree().process_frame

	var chapters: Array = DataDB.notes.keys()
	ok(chapters.size() > 0, "notes.json 应当有内容（前提）")
	var checked := 0
	var with_src := 0
	for chapter in chapters:
		for entry in DataDB.notes[chapter]:
			var title := str(entry.get("h", ""))
			var body := str(entry.get("b", ""))
			checked += 1
			if body.contains("[ref]"):
				with_src += 1

			n.present(str(chapter), title, body)
			var plain := str(n.shown_plain())
			ok(not plain.is_empty(), "%s / %s 翻开之后一个字都没有" % [str(chapter), title])
			var leaked := _leaked(plain)
			ok(leaked.is_empty(),
				"%s / %s 的正文把标记漏给玩家了：%s"
				% [str(chapter), title, ", ".join(leaked)])

	ok(checked >= 50, "应当真的过了一遍全部史实注，实际只过了 %d 条" % checked)
	# 带 [ref] 的那两条是**唯一**会走落款分支的，别哪天被删了却没人知道
	# （那样这一条就不再覆盖落款路径了，绿得毫无意义）。
	#
	# 【这两条是哪两条，值得记一笔】
	# 序章《马关条约》（茶盏）与第二章《张謇与〈厂约〉》。
	# 后者在第二章 —— **不在切片里**，这一版玩家根本翻不到。
	# 也就是说：浏览器自查最多只能把这件事揭出一半，
	# 另一半只有遍历全部 52 条才看得见。这正是这条用例存在的理由。
	eq(with_src, 2, "带 [ref] 的注应当还是那两条（序章《马关条约》/ 第二章《张謇与〈厂约〉》）")

	n.queue_free()
	await host.get_tree().process_frame


func test_a_stray_bracket_in_the_body_does_not_leak() -> void:
	var got := NoteView.markup("《时局图》里写着 [甲午] 二字。")
	ok(not got.contains("[甲午]"), "正文里的方括号应当转义掉，实为：%s" % got)
	ok(got.contains("[lb]甲午]"), "……转义成 [lb] 之后 RichTextLabel 才显示得出 [：%s" % got)


## 没闭合的 [ref] 不能把整段正文吞掉 —— 少一个斜杠就打不开注，
## 那种坏比显示乱码更让人摸不着头脑。
func test_an_unclosed_ref_keeps_the_text_readable() -> void:
	var got := NoteView.markup("前半句。[ref]《马关条约》正文")
	ok(got.contains("前半句。"), "没闭合的 [ref] 不该把前面的正文吃掉：%s" % got)
	ok(got.contains("《马关条约》正文"), "没闭合的 [ref] 后面的字也该留着：%s" % got)


## 里程碑 3 的教训在这一屏同样适用：内容对了不等于画出来了。
func test_the_note_panel_is_actually_on_screen() -> void:
	var n := NoteView.new()
	host.add_child(n)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	ok(not bool(n.visible), "没翻开之前不该露出来")

	n.present("序章", "《马关条约》", DataDB.note_body("序章", "《马关条约》"))
	ok(bool(n.visible), "present 之后应当可见")
	eq(str(n.shown_title()), "《马关条约》", "标题不对")
	ok(str(n.shown_text()).length() > 40, "正文不该是空的")

	var p: Variant = n.get("_panel")
	ok(p != null, "应当有面板")
	if p != null:
		var r: Rect2 = (p as Control).get_global_rect()
		ok(r.size.x > 100.0 and r.size.y > 100.0,
			"面板塌成了 %s（里程碑 3 那次就是栽在这上面）" % str(r.size))
		ok(r.position.y >= -1.0 and r.end.y <= float(n.size.y) + 1.0,
			"面板跑到屏幕外了：%s（屏幕 %s）" % [str(r), str(n.size)])

	n.dismiss()
	ok(not bool(n.visible), "dismiss 之后应当藏起来")
	ok(_stray_tags(str(n.shown_text())).is_empty(),
		"真数据过一遍 markup 也不该漏出方括号")

	n.queue_free()
	await host.get_tree().process_frame
