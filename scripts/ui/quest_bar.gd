class_name QuestBar
extends PanelContainer
## 房间屏左上角的任务条：章题一行（朱砂），当下目标一行（墨）。
##
## 状态完全问 QuestManager 现算（它自己不存），每进一场脊梁戏刷新一次。
## 鼠标穿透 —— 这条纸不挡点地走路。暂停时整个房间屏的输入已被挡在外面，
## 这里不用再管。

var _chapter: Label
var _goal: Label
var _last_goal := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	offset_left = 22
	offset_top = 16
	custom_minimum_size = Vector2(470, 0)
	add_theme_stylebox_override("panel", Paper.translucent_paper(0.86))

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 3)
	add_child(col)

	_chapter = Label.new()
	Paper.style_label(_chapter, 17, Paper.CINNABAR)
	col.add_child(_chapter)

	_goal = Label.new()
	Paper.style_label(_goal, 19, Paper.INK)
	_goal.add_theme_constant_override("line_spacing", 4)
	col.add_child(_goal)


## 进脊梁场景 / 进房间时调。目标换了就闪一下，告诉玩家任务在往前走。
func refresh() -> void:
	var title := QuestManager.current_title()
	visible = not title.is_empty()
	if not visible:
		_last_goal = ""
		return
	_chapter.text = "◆ " + title
	var goal := QuestManager.current_goal()
	_goal.text = goal
	if not goal.is_empty() and goal != _last_goal:
		modulate.a = 0.4
		var tw := create_tween()
		tw.tween_property(self, "modulate:a", 1.0, 0.45)
	_last_goal = goal


func goal_text() -> String:
	return _goal.text


func chapter_text() -> String:
	return _chapter.text
