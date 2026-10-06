extends Node
## 启动入口。
##
## 【数据不合格就停在这里，不往下走】
## 带着坏数据进游戏，出的错会离病根很远 —— 玩家看到的是「对话是空的」，
## 病根可能是 story.json 里一个逗号。宁可在第一秒黑屏报错。
## Web 版尤其需要这一屏：不然浏览器里就是一片黑，什么线索都没有。
##
## 【标题画面】
## 数据合格后进标题屏（scenes/title），由它决定新的一局还是续前一局；
## 设置（文字速度 / 全屏）也在那边。这一屏只剩一件事：把数据的门关好。

const TITLE_SCENE := "res://scenes/title/title.tscn"


func _ready() -> void:
	if not DataDB.errors.is_empty():
		_show_data_errors()
		return
	print("[Boot] 数据就绪，起始场景 %s，切片 %d 个场景"
		% [DataDB.start_scene, DataDB.slice.size()])
	# 必须延后一帧。在 _ready 里直接换场景会撞上「父节点正在增删子节点」——
	# 那个错只在启动时出现一次，很容易被当成无关的噪音忽略掉，
	# 然后游戏**根本没换场景**，黑屏，而日志里只有一行看起来像警告的 ERROR。
	get_tree().change_scene_to_file.call_deferred(TITLE_SCENE)


## 数据坏了。把每一条都摆出来 —— 这一屏只有开发者会看到，
## 所以宁可话多，不要客气。
func _show_data_errors() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Paper.NIGHT
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var label := Label.new()
	Paper.style_label(label, 20, Paper.CINNABAR_HI)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.offset_left = 60
	label.offset_right = -60
	label.offset_top = 60
	label.offset_bottom = -60
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var lines := PackedStringArray(["剧本数据校验未通过，共 %d 条：" % DataDB.errors.size()])
	for e in DataDB.errors:
		lines.append("  ✗ " + e)
	lines.append("")
	lines.append("（这一屏是给开发者看的。数据修好后重跑 tools/export_story.js）")
	label.text = "\n".join(lines)
	root.add_child(label)

	get_tree().root.add_child(root)
