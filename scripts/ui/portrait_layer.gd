class_name PortraitLayer
extends Control
## 立绘层。两个位子，谁在说话谁亮。
##
## 【为什么是两个位子而不是一个】
## 一个位子的话，甲说完乙说，甲的脸就得先淡出再淡入 —— 两人对谈时会闪。
## 两个位子各站一个人，说话的那个亮、另一个压暗，来回切就不闪了。
## 这是 To the Moon 和绝大多数 AVG 的做法。
##
## 【立绘不抠图】
## 这十五张是水彩边缘，自动抠不干净，抠完边上会有一圈脏的白边。
## 所以**保留宣纸底** —— 立绘就是一张画笺，压在水墨背景上反而更贴。
## 代价是不能让立绘盖住背景上的字，好在这部作品里背景上本来就不写字。

const SLOT_SIZE := Vector2(400, 600)
const SLOT_BOTTOM := -640.0     ## 相对屏幕底边的偏移（负数 = 往上）
const SLOT_LEFT_X := 60.0
const SLOT_RIGHT_X := -460.0    ## 相对屏幕右边的偏移

const DIM := Color(0.70, 0.68, 0.64, 0.82)
const LIT := Color(1, 1, 1, 1)

const FADE := 0.22

const EDGE_SHADER := "res://art/ui/portrait_edge.gdshader"

var _slots: Array[TextureRect] = []
var _owner: Array[String] = ["", ""]
var _active := -1
var _tweens: Array[Tween] = [null, null]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in 2:
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 位置全部写成 offsets，不用 `tr.position = ...`。
		# 用 position 的话，它和上一句 set_anchors_preset 的先后就变得有讲究了
		# （见 dialogue_box.gd 里那段关于 0×0 的说明）—— 换个顺序、或者哪天
		# 把这句挪进 _ready()，尺寸就会静默塌掉。直接写 offsets 没有这个问题：
		# 它只依赖锚点，跟调用时机无关。
		tr.set_anchors_and_offsets_preset(
			Control.PRESET_BOTTOM_LEFT if i == 0 else Control.PRESET_BOTTOM_RIGHT)
		if i == 0:
			tr.offset_left = SLOT_LEFT_X
			tr.offset_right = SLOT_LEFT_X + SLOT_SIZE.x
		else:
			tr.offset_right = SLOT_RIGHT_X
			tr.offset_left = SLOT_RIGHT_X - SLOT_SIZE.x
		tr.offset_top = SLOT_BOTTOM
		tr.offset_bottom = SLOT_BOTTOM + SLOT_SIZE.y
		tr.modulate = Color(1, 1, 1, 0)
		# 软边材质。见 art/ui/portrait_edge.gdshader ——
		# 立绘保留宣纸底（不抠图），硬边的话屏幕上就是一个贴上去的长方形。
		var m := ShaderMaterial.new()
		m.shader = load(EDGE_SHADER)
		if m.shader == null:
			# 材质丢了不该让整张脸消失 —— 退回硬边，游戏照跑。
			push_warning("[PortraitLayer] 软边材质加载不出来，这一版立绘是硬边的：" + EDGE_SHADER)
		tr.material = m
		add_child(tr)
		_slots.append(tr)
		_tweens.append(null)


## 换说话人。没立绘的人（龙套、旁白）传空串 —— 两个位子都压暗，
## 但不淡出：脸还留在台上，只是不亮了。一场戏里人物进进出出，不该把台清空。
func set_speaker(speaker: String) -> void:
	var file := Cast.portrait_file(speaker)
	if file.is_empty():
		_active = -1
		for i in 2:
			_dim(i, true)
		return

	var slot := _slot_for(speaker)
	if _owner[slot] != speaker:
		_owner[slot] = speaker
		_slots[slot].texture = load(Cast.PORTRAIT_DIR + file)
		# 换人时从透明重新淡入 —— 直接换图会看到脸「啪」地跳一下
		_slots[slot].modulate = Color(1, 1, 1, 0)
	_active = slot
	for i in 2:
		_dim(i, i != slot)


## 这个人现在站在哪个位子上；没站过就挑一个空位。
## 站位是**黏的**：同一个角色整场戏都站同一边，来回换边会让人认不出谁是谁。
func _slot_for(speaker: String) -> int:
	for i in 2:
		if _owner[i] == speaker:
			return i
	# 挑一个没人的；都有人的话，顶掉不亮的那个
	for i in 2:
		if _owner[i].is_empty():
			return i
	return 0 if _active != 0 else 1


func _dim(slot: int, dim: bool) -> void:
	var target := DIM if dim else LIT
	# 淡出只在「从无到有」时用；压暗/点亮直接过渡
	if _slots[slot].modulate.a < 0.01 and not dim:
		pass
	if _tweens[slot] != null and _tweens[slot].is_valid():
		_tweens[slot].kill()
	var t := create_tween()
	t.tween_property(_slots[slot], "modulate", target, FADE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tweens[slot] = t


## 换场时清台。同一场景内不调 —— 那会让对话变成幻灯片。
func clear() -> void:
	for i in 2:
		_owner[i] = ""
		_slots[i].texture = null
		_slots[i].modulate = Color(1, 1, 1, 0)
	_active = -1


func active_speaker() -> String:
	return _owner[_active] if _active >= 0 else ""


## 给测试用：不看动画，只问「现在台上是谁」。
func standing() -> Array:
	return _owner.duplicate()
