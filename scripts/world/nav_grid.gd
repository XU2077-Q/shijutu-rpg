class_name NavGrid
extends RefCounted
## 房间里的路 —— 把「哪儿能走」变成一张格子图，再在上面找路。
##
## 【为什么是格子，不是 NavigationPolygon】
## Godot 的导航节点要先建多边形、再烘一遍，全程在渲染/物理那一侧，
## headless 下不好断言「从这儿到那儿走得通吗」。而房间的走法本来就粗糙 ——
## 玩家点一下，小人绕开桌子走过去，绕得像不像人走路没那么要紧。
## AStarGrid2D 是纯数据，能在测试里直接问路径，也能直接验「路有没有穿过桌子」。
##
## 【为什么要往里缩半个格子】
## 只按「格子中心在不在可走区里」来判，最外圈那排格子的中心贴着边界，
## 小人的脚就会**踩在墙上**。所以判定的不是中心，而是中心 ± 半个格子
## 那四个点全都得在可走区里 —— 等于把可走区往里缩了半格。
## 代价是窄过一格的过道会被整条封死；切片里没有这种过道，真有的话把
## CELL 调小即可。
##
## 【坐标】
## 传进来的是**像素**（房间的实际像素矩形），不是归一化值。
## 归一化 → 像素那一步在 RoomView 里做一次，之后就全是像素，
## 免得路径、碰撞、绘制三处各转一次、各错一次。

## 格子边长（像素）。24 在 1280×720 上是 54×30 格 ——
## 够细，绕得开桌子；又够粗，路径点数不会多到小人一步一顿。
const CELL := 24.0

var _astar := AStarGrid2D.new()
var _region := Rect2i()
var _size := Vector2.ZERO
var _cell := CELL
var _open := 0


## walk / blockers 都是像素坐标。size 是房间的像素尺寸。
func build(walk: PackedVector2Array, blockers: Array, size: Vector2, cell: float = CELL) -> void:
	_size = size
	_cell = maxf(8.0, cell)
	_region = Rect2i(0, 0,
		int(ceil(size.x / _cell)), int(ceil(size.y / _cell)))
	_astar = AStarGrid2D.new()
	_astar.region = _region
	_astar.cell_size = Vector2(_cell, _cell)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.update()

	_open = 0
	for y in _region.size.y:
		for x in _region.size.x:
			if _walkable(Vector2i(x, y), walk, blockers):
				_open += 1
			else:
				_astar.set_point_solid(Vector2i(x, y), true)


## 这一格能不能站。四个角（中心 ± 半格）都得在可走区里，且都不在障碍物里。
func _walkable(c: Vector2i, walk: PackedVector2Array, blockers: Array) -> bool:
	var mid := _cell_center(c)
	var h := _cell * 0.5
	for d in [Vector2.ZERO, Vector2(-h, -h), Vector2(h, -h), Vector2(-h, h), Vector2(h, h)]:
		var p: Vector2 = mid + d
		if p.x < 0.0 or p.y < 0.0 or p.x > _size.x or p.y > _size.y:
			return false
		if not Geometry2D.is_point_in_polygon(p, walk):
			return false
		for b in blockers:
			if (b as Rect2).has_point(p):
				return false
	return true


func _cell_center(c: Vector2i) -> Vector2:
	return Vector2((float(c.x) + 0.5) * _cell, (float(c.y) + 0.5) * _cell)


func to_cell(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / _cell)), int(floor(p.y / _cell)))


func cell_count() -> int:
	return _region.size.x * _region.size.y


## 能站的格子数。测试用它区分「整间房都能走」和「全被障碍物封死了」。
func open_count() -> int:
	return _open


func is_walkable(p: Vector2) -> bool:
	var c := to_cell(p)
	if not _region.has_point(c):
		return false
	return not _astar.is_point_solid(c)


## 找一条从 a 到 b 的路（像素坐标，返回的是格心的序列）。
##
## 【为什么要往最近的空格上吸】
## 玩家会点在桌子上、点在半步之外的墙上。直接判「目标格是实心的 → 无路」
## 会让「点了桌子旁边一点」变成「小人站着不动」，手感上像是坏了。
## 所以两个端点都先吸到附近的空格上 —— 目标实在吸不到才真的返回空。
func path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _open == 0:
		return out
	var a := _nearest_open(to_cell(from))
	var b := _nearest_open(to_cell(to))
	if a.x < 0 or b.x < 0:
		return out
	if a == b:
		out.append(_cell_center(a))
		return out
	var ids := _astar.get_id_path(a, b)
	for c in ids:
		out.append(_cell_center(c))
	# 路径的第一个点就是出发点那一格，走的时候会先往格心挪一下 ——
	# 那一下是看得出来的小抽动，所以把它换回真实起点。
	if out.size() > 0:
		out[0] = from
	return out


## 从 c 出发往外一圈圈找第一个能站的格子。找不到返回 (-1, -1)。
func _nearest_open(c: Vector2i, max_r: int = 6) -> Vector2i:
	if _region.has_point(c) and not _astar.is_point_solid(c):
		return c
	for r in range(1, max_r + 1):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				# 只看这一圈的外框，里圈上一轮已经找过了
				if absi(dx) != r and absi(dy) != r:
					continue
				var q := Vector2i(c.x + dx, c.y + dy)
				if not _region.has_point(q) or _astar.is_point_solid(q):
					continue
				var d := Vector2(dx, dy).length()
				if d < best_d:
					best_d = d
					best = q
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)
