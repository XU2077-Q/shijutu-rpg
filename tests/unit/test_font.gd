extends TestCase
## 字体覆盖率。
##
## 【为什么这条测试必须有】
## art/fonts/SourceHanSansLite.ttf 只有 2.9 MB，而完整的思源黑体是 17 MB ——
## 因为它是**子集化**过的：只留下剧本用到的那几千个字。
## 子集里没有的字，Godot 不报错，它画一个豆腐块（□）。
## 这种错最阴：编译过、测试绿、跑起来也没崩，只是屏幕上那个字看不见了，
## 而且很可能要等玩家玩到第一百句才遇上。
##
## 所以把剧本里出现过的每一个字都拿去问字体有没有。
## 顺手把界面文案也加进来 —— 那些字不在剧本里，最容易漏。

const FONT_PATH := "res://art/fonts/NotoSerifSC-VF.ttf"

## 界面文案。加了新界面词就往这里补一行，否则这条测试护不住它。
const UI_TEXT := [
	"序章", "第一章", "第二章", "第三章", "第四章", "第五章",
	"春愁", "熊", "时局图", "史实注", "见闻", "回想", "存档", "读档",
	"设置", "继续", "返回", "退出", "开始新游戏", "从存档继续",
	"自动存档", "存档格", "空", "已保存", "保存失败", "确定", "取消",
	"任务", "线索", "调查", "已调查", "未解锁", "结局", "印章",
	"点击继续", "空格继续", "跳过", "回顾", "上一句", "下一句",
	"音量", "全屏", "窗口", "语言", "字体大小", "文字速度",
	"沈怀瑾", "林婉如", "沈鹤龄", "黎景明", "何伯", "周子安",
	"康有为", "陈道台", "俄国商人", "台湾举子", "顺子", "赵得胜",
	"湖南蒙学先生", "日本士兵", "同乡举子", "街上的人",
	"需要", "觉醒", "当前", "（", "）", "、", "。", "，", "：", "；", "？", "！",
	"——", "「", "」", "《", "》", "…", "·", "＊",
]


func _ready_font() -> Font:
	var f: Variant = load(FONT_PATH)
	return f as Font


## 剧本里出现过的所有文字，拼成一大串。
## 只取字符串值 —— 键名（"t" / "x" / "op"）是给机器看的，不需要字形。
func _story_text() -> String:
	var buf := PackedStringArray()
	_collect(DataDB.story, buf)
	return "".join(buf)


func _collect(v: Variant, buf: PackedStringArray) -> void:
	if v is String:
		buf.append(v)
	elif v is Array:
		for e in v:
			_collect(e, buf)
	elif v is Dictionary:
		for k in v:
			_collect(v[k], buf)


func test_font_file_is_present() -> void:
	ok(ResourceLoader.exists(FONT_PATH), "字体文件不在：" + FONT_PATH)


func test_font_covers_every_character_in_the_script() -> void:
	var f := _ready_font()
	ok(f != null, "字体加载不出来：" + FONT_PATH)
	if f == null:
		return

	var missing := {}
	var total := 0
	for ch in _story_text():
		var cp: int = ch.unicode_at(0)
		if cp < 0x20 or cp == 0x20:      # 换行、制表这些不需要字形
			continue
		total += 1
		if not f.has_char(cp):
			missing[ch] = cp

	var detail := ""
	if not missing.is_empty():
		var keys := missing.keys()
		keys.sort()
		for i in mini(keys.size(), 40):
			detail += "「%s」U+%04X  " % [keys[i], missing[keys[i]]]
		if keys.size() > 40:
			detail += "…（还有 %d 个）" % (keys.size() - 40)

	ok(missing.is_empty(),
		"剧本里有 %d 个字字体没有，会渲染成豆腐块：\n          %s\n"
		% [missing.size(), detail] +
		"        换字体，或者把 art/fonts/ 换成完整版思源。")
	ok(total > 0, "剧本里一个字都没读到 —— 是 story 没加载，还是 _collect 写错了？")


func test_font_covers_every_character_in_the_ui() -> void:
	var f := _ready_font()
	# 这里**不能** load 失败就 return —— 那会让这条用例在字体整个没导入时
	# 反而显示「✓」。测不到东西的绿是最坏的一种绿。
	ok(f != null, "字体加载不出来，界面文案覆盖率没测成：" + FONT_PATH)
	if f == null:
		return

	var missing := {}
	for s in UI_TEXT:
		for ch in s:
			var cp: int = ch.unicode_at(0)
			if not f.has_char(cp):
				missing[ch] = cp

	var detail := ""
	if not missing.is_empty():
		var keys := missing.keys()
		keys.sort()
		for k in keys:
			detail += "「%s」U+%04X  " % [k, missing[k]]

	ok(missing.is_empty(),
		"界面文案里有 %d 个字字体没有：\n          %s" % [missing.size(), detail])


## 字号上限。
##
## 【现状：这条是「已知欠账」的守门员，不是合格证】
## 现在用的是**完整版**思源宋体（25 MB），因为原来那份 2.9 MB 的子集版
## 缺 11 个字（屣、謇、缫、畬…），连切片里都缺 4 个 —— 子集是按**网页版**
## 的文本切的，RPG 的扩写读本多出来的字它没有。
##
## 正确做法是**按 RPG 自己的文本重新子集化**，能压到 3 MB 上下。
## 那要自己写一个 TTF 子集化工具（本机没有 python/fonttools），
## 属于导出优化，排在里程碑 7。在那之前先守着上限，
## 免得哪天有人塞进来一个几百 MB 的字体全家桶。
const FONT_SIZE_CEILING_MB := 40.0

func test_font_is_not_absurdly_large() -> void:
	var f := FileAccess.open(FONT_PATH, FileAccess.READ)
	if f == null:
		fail("读不出字体文件")
		return
	var mb := f.get_length() / 1048576.0
	f.close()
	ok(mb < FONT_SIZE_CEILING_MB,
		"字体有 %.1f MB，超过了 %.0f MB 的上限 —— 网页版会加载不动。"
		% [mb, FONT_SIZE_CEILING_MB])
	# 顺带把实际大小打出来，好知道距离子集化还有多少油水
	if mb > 8.0:
		print("       （字体 %.1f MB —— 子集化的欠账还挂着，里程碑 7 处理）" % mb)
