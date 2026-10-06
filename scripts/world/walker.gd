class_name Walker
extends Control
## 场景里走动的那个小人。像素画，四向 × 三帧。
##
## 【锚点为什么在脚上，不在中心】
## 俯视角里，「人站在哪儿」说的是脚站的那一点。按中心定位的话，
## 走到房间下沿时人会有一半陷进地板，往上走又会浮起来 ——
## 而且不同身高的角色浮得不一样多。锚点定在脚上，换谁都不会错。
##
## 【为什么不用 CharacterBody2D + 碰撞】
## 碰撞体是给「撞到了要弹开」准备的。这里不需要弹开 ——
## 玩家点了一下，小人就该沿着算好的路绕过去，绕不过去就是无路可走。
## 用碰撞体反而会引出「卡在桌角上抖」这类要调参的问题。
## 路是 NavGrid 算的，能不能站也是它判的，两边同一套格子，不会打架。
##
## 【为什么不写 .tscn】
## 同 Paper 里那段：代码搭的界面有类型检查，少一个节点当场就炸；
## .tscn 少一个节点只是「屏幕上少一块」，不报错。

const SPRITE := Vector2(96, 128)
const DIR := "res://art/walk/"

## 脚在贴图里的位置。留 8 px 是让鞋底略高于贴图下沿 ——
## 像素画的最后一两行通常是描边，拿它当脚会显得人陷在地里。
const FOOT_IN_SPRITE := Vector2(48.0, 120.0)

## 像素/秒。走得太快像在滑，太慢玩家会不耐烦 ——
## 20 格（480 px）大约两秒出头，这个节奏跟 To the Moon 接近。
const SPEED := 215.0

## 每秒换几帧。三帧一轮，8 帧/秒 ≈ 每步 0.125 秒。
const ANIM_FPS := 8.0

const FRAMES := 3
const FACINGS := ["down", "up", "left", "right"]

var facing := "down"
var _sprite: TextureRect
var _frames: Dictionary = {}        ## "down" → [Texture2D, …]
var _prefix := ""
var _grid: NavGrid = null
var _path: PackedVector2Array = PackedVector2Array()
var _pi := 0
var _anim := 0.0
var _moving := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 锚点全 0 = 左上角，这是 Control 的默认值。这里**故意不调
	# set_anchors_preset** —— 见 dialogue_box.gd 里那段关于 0×0 的说明：
	# 那个函数会保住当前矩形，调了反而要担心调用时机。
	size = SPRITE
	_sprite = TextureRect.new()
	_sprite.size = SPRITE
	_sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# 像素画放大必须用最近邻，不然边缘会糊成一团 ——
	# 4 倍整数放大配最近邻，才是「像素小人」该有的样子。
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_sprite)
	set_process(true)


## 换人。prefix 是 art/walk 里的文件名前缀（shen / lin）。
func setup(prefix: String, grid: NavGrid) -> void:
	_prefix = prefix
	_grid = grid
	_load_frames()


## 窗口尺寸变了要换一张新的格子图。房间层重建 NavGrid 之后会调这个 ——
## 不换的话，小人会照着一张按旧尺寸算出来的格子图走，
## 分辨率一变，人就开始穿墙。
func set_grid(g: NavGrid) -> void:
	_grid = g


func _load_frames() -> void:
	_frames.clear()
	for d in FACINGS:
		var arr: Array = []
		for i in FRAMES:
			var p := "%s%s_%s_%d.png" % [DIR, _prefix, d, i]
			if ResourceLoader.exists(p):
				arr.append(load(p))
			else:
				arr.append(null)
		_frames[d] = arr
	if _frame() == null:
		# 行走图没出，不该让整间房打不开 —— 退回一块素色，位置和朝向照旧。
		# 这是**看得见**的坏：屏幕上有个方块在动，比黑屏好查得多。
		push_warning("[Walker] 行走图缺失：%s%s_*_*.png" % [DIR, _prefix])


func _frame() -> Texture2D:
	var arr: Array = _frames.get(facing, [])
	if arr.is_empty():
		return null
	var i := int(_anim * ANIM_FPS) % FRAMES if _moving else 0
	return arr[i]


# ---------------------- 位置 ----------------------

## 脚的位置（房间像素坐标）。
func foot() -> Vector2:
	return position + FOOT_IN_SPRITE


func set_foot(p: Vector2) -> void:
	position = p - FOOT_IN_SPRITE


## 站位点。给「走到某个物件前面」用 —— 取物件下沿正中，
## 这样小人站在物件下方，不会挡住它。
static func stand_point(rect: Rect2) -> Vector2:
	return Vector2(rect.position.x + rect.size.x * 0.5, rect.end.y + 28.0)


# ---------------------- 走动 ----------------------

func walk_to(p: PackedVector2Array) -> void:
	_path = p
	_pi = 0
	_moving = _path.size() > 0
	if not _moving:
		return
	# 先转个身。转身和迈步同一帧发生的话，看起来像原地打了个转。
	_face_toward(_path[0])


func stop() -> void:
	_path = PackedVector2Array()
	_pi = 0
	_moving = false
	_anim = 0.0
	_refresh()


func is_walking() -> bool:
	return _moving


## 键盘直接走。dir 是归一化方向，返回这一帧实际动了没有。
func step(dir: Vector2, delta: float) -> bool:
	if dir == Vector2.ZERO:
		return false
	stop()
	_face_toward(foot() + dir)
	var to := foot() + dir.normalized() * SPEED * delta
	# 走不进墙里：目标点不可站就不动，而不是滑过去。
	# 「滑」听起来更聪明，但在窄处会把人一点点挤进障碍物里。
	if _grid != null and not _grid.is_walkable(to):
		return false
	set_foot(to)
	_moving = true
	_anim += delta
	_refresh()
	return true


func _process(delta: float) -> void:
	if not _moving or _path.is_empty():
		return
	var target: Vector2 = _path[_pi]
	var cur := foot()
	var d := target - cur
	var step_len := SPEED * delta
	if d.length() <= step_len:
		set_foot(target)
		_pi += 1
		if _pi >= _path.size():
			stop()
			return
		_face_toward(_path[_pi])
	else:
		set_foot(cur + d.normalized() * step_len)
		_anim += delta
	_refresh()


func _face_toward(to: Vector2) -> void:
	var d := to - foot()
	if absf(d.x) > absf(d.y):
		facing = "right" if d.x > 0.0 else "left"
	else:
		facing = "down" if d.y > 0.0 else "up"
	_refresh()


func _refresh() -> void:
	if _sprite == null:
		return
	var t := _frame()
	if _sprite.texture != t:
		_sprite.texture = t


# ---------------------- 给测试看的 ----------------------

## 不走动画，直接把人放到路径终点。测试里等真实帧太慢。
func snap_to_path_end() -> void:
	if _path.size() > 0:
		set_foot(_path[_path.size() - 1])
	stop()


func has_art() -> bool:
	return _frame() != null
