extends TestCase
## 房间里的路。
##
## 【为什么这块必须单独测】
## 「点一下，小人绕开桌子走过去」是这一层唯一的手感来源。
## 而它坏起来是**静默**的：路算错了，小人的表现是「站着不动」或者
## 「从桌子中间穿过去」—— 不报错、不崩溃，玩家只会觉得这游戏很糙。
## NavGrid 是纯数据，能在这里逐条问清楚：绕没绕开、走不走得通、哪儿不能站。

const W := 1000.0
const H := 600.0

## 一整间空屋。
func _open_room() -> NavGrid:
	var g := NavGrid.new()
	g.build(
		PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, H), Vector2(0, H)]),
		[], Vector2(W, H))
	return g


## 屋当间一张桌子。
func _room_with_table() -> NavGrid:
	var g := NavGrid.new()
	g.build(
		PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, H), Vector2(0, H)]),
		[Rect2(400, 240, 200, 120)], Vector2(W, H))
	return g


func test_an_open_room_is_walkable_almost_everywhere() -> void:
	var g := _open_room()
	var total := g.cell_count()
	ok(g.open_count() > 0, "空屋应该有能站的格子")
	# 边缘那一圈会因为没有四个角都在屋里而被判掉，所以不是 100%。
	var ratio := float(g.open_count()) / float(total)
	ok(ratio > 0.80, "空屋的可行走格子应占八成以上，实为 %.0f%%" % (ratio * 100.0))


func test_outside_the_walk_area_is_not_walkable() -> void:
	var g := NavGrid.new()
	# 只铺屋子中间一块
	g.build(
		PackedVector2Array([Vector2(200, 150), Vector2(800, 150), Vector2(800, 450), Vector2(200, 450)]),
		[], Vector2(W, H))
	ok(g.is_walkable(Vector2(500, 300)), "屋子中间应当能站")
	ok(not g.is_walkable(Vector2(60, 60)), "可走区之外（左上角）不该能站")
	ok(not g.is_walkable(Vector2(950, 560)), "可走区之外（右下角）不该能站")


func test_a_path_crosses_an_open_room() -> void:
	var g := _open_room()
	var p := g.path(Vector2(80, 520), Vector2(920, 80))
	ok(p.size() >= 2, "空屋里两点之间应该有路，实得 %d 个点" % p.size())
	if p.size() >= 2:
		near(p[0].x, 80.0, 1.0, "路的起点应当就是出发点")
		near(p[p.size() - 1].x, 920.0, 30.0, "路的终点应当落在目标附近")


## 这一条是整块的核心：路**不许穿过桌子**。
func test_a_path_goes_around_a_blocker() -> void:
	var g := _room_with_table()
	var table := Rect2(400, 240, 200, 120)
	var from := Vector2(500, 560)
	var to := Vector2(500, 60)          # 正对桌子，直线会穿过去
	var p := g.path(from, to)
	ok(p.size() >= 2, "桌子挡不住整间房，路应该存在")
	if p.size() < 2:
		return

	var hit := 0
	for q in p:
		if table.has_point(q):
			hit += 1
	ok(hit == 0, "路穿过了桌子，有 %d 个点落在桌面上" % hit)

	# 绕路必然比直线长。没长的话，多半是路根本没绕，只是碰巧没采样到桌子。
	var straight := from.distance_to(to)
	var walked := 0.0
	for i in range(1, p.size()):
		walked += p[i - 1].distance_to(p[i])
	ok(walked > straight * 1.05,
		"绕桌子的路应当明显比直线长（直线 %.0f，实走 %.0f）" % [straight, walked])


func test_every_point_on_a_path_is_somewhere_you_can_stand() -> void:
	var g := _room_with_table()
	var p := g.path(Vector2(100, 100), Vector2(900, 500))
	ok(p.size() >= 2, "应当找得到路")
	var bad := 0
	for q in p:
		if not g.is_walkable(q):
			bad += 1
	ok(bad == 0, "路上有 %d 个点是站不住的 —— 小人在穿墙" % bad)


## 玩家会点在桌子上、点在半步之外的墙上。
## 那时候应该是「走到桌子边上」，而不是「站着不动」。
func test_clicking_on_a_blocker_walks_to_its_edge() -> void:
	var g := _room_with_table()
	var p := g.path(Vector2(120, 300), Vector2(500, 300))   # 终点在桌子正中间
	ok(p.size() >= 2, "点在桌子上也该有路 —— 否则手感上就是「点了没反应」")
	if p.size() >= 2:
		var end: Vector2 = p[p.size() - 1]
		ok(not Rect2(400, 240, 200, 120).has_point(end),
			"路的终点不该落在桌子里面，实际停在 %s" % end)


func test_a_wall_across_the_room_blocks_the_path() -> void:
	var g := NavGrid.new()
	# 一道从可走区顶通到底的墙，把屋子劈成两半
	g.build(
		PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, H), Vector2(0, H)]),
		[Rect2(480, -10, 40, H + 20)], Vector2(W, H))
	var p := g.path(Vector2(200, 300), Vector2(800, 300))
	ok(p.size() == 0, "墙两边走不通，路应当是空的，实得 %d 个点" % p.size())
	# 但同一侧的还是走得到 —— 否则「走不通」可能是整间房都废了
	var q := g.path(Vector2(100, 100), Vector2(400, 500))
	ok(q.size() >= 2, "墙的同一侧应当照样走得到")


func test_an_empty_room_returns_no_path() -> void:
	var g := NavGrid.new()
	g.build(PackedVector2Array(), [], Vector2(W, H))
	eq(g.open_count(), 0, "没有可走区，就不该有能站的格子")
	eq(g.path(Vector2(10, 10), Vector2(900, 500)).size(), 0,
		"没有可走区时应当返回空路，而不是硬凑一条出来")
