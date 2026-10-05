extends Node
## 启动入口。
##
## 现在只做一件事：确认数据校验过了，然后报一声。
## 里程碑 3 会把它换成标题画面。**刻意先不做标题画面** ——
## 在数据还没有个准数之前先堆 UI，等于把错误藏到界面底下。

func _ready() -> void:
	if not DataDB.errors.is_empty():
		# 数据不合格就不该往下走。宁可黑屏报错，也不要带着坏数据进游戏 ——
		# 那样出的错会离病根很远，极难查。
		push_error("[Boot] 数据校验未通过，停在启动画面。详见上方 DataDB 报错。")
		return
	print("[Boot] 数据就绪，起始场景 %s" % DataDB.start_scene)
	print("[Boot] 里程碑 1 完成：数据层 + 测试。界面从里程碑 3 开始。")
