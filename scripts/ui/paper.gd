class_name Paper
extends RefCounted
## 宣纸与朱砂 —— 全游戏共用的配色、字体、面板样式。
##
## 【颜色是从网页版抄的，不是新配的】
## 网页版《时局图》已经上线，视觉基准以它为准。
## 这六个色值是从 index.html 里统计出来的高频色，抄过来两边才像同一部作品，
## 而不是两个画风不同的游戏。
##
## 【为什么 UI 全用代码搭，不写 .tscn】
## .tscn 是给编辑器用的格式，手写容易出两类错：uid 对不上、节点路径写错，
## 而且**错了不报错**，只是界面上少一块。代码搭 UI 有类型检查，
## 少一个节点当场就炸。等界面定型了再考虑转成 .tscn 交给编辑器维护。

# ---- 纸 ----
const PAPER_LIGHT := Color("f6ecd8")
const PAPER := Color("e8dcc0")
const PAPER_DEEP := Color("d8c9a6")
const PAPER_EDGE := Color("cbb894")

# ---- 墨 ----
const INK := Color("1a1408")
const INK_SOFT := Color("5e5340")
const INK_FAINT := Color("8d7c5c")

# ---- 朱砂与金 ----
const CINNABAR := Color("a8322a")
const CINNABAR_HI := Color("c0392b")
const GOLD := Color("8a6a3b")

## 暗场（题记、夜戏）的底色
const NIGHT := Color("14110c")

const FONT_PATH := "res://art/fonts/NotoSerifSC-VF.ttf"

static var _font: Font = null
static var _theme: Theme = null


static func font() -> Font:
	if _font == null:
		_font = load(FONT_PATH)
		if _font == null:
			push_error("[Paper] 字体加载不出来：" + FONT_PATH)
	return _font


## 全局主题。挂在根 Control 上，子节点自动继承。
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	var f := font()
	if f != null:
		t.default_font = f
	t.default_font_size = 26
	return t


## 一张宣纸面板的样式。圆角很小 —— 手工纸不是 UI 控件，
## 圆角一大就变成「现代卡片」，跟水墨版画不是一路。
static func paper_box(bg: Color = PAPER, border: Color = PAPER_EDGE, border_w: int = 2) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(3)
	s.content_margin_left = 28
	s.content_margin_right = 28
	s.content_margin_top = 20
	s.content_margin_bottom = 20
	return s


## 半透明的纸 —— 对话框压在背景上时用，既看得清字，又不完全遮住画。
static func translucent_paper(alpha: float = 0.94) -> StyleBoxFlat:
	var c := PAPER_LIGHT
	c.a = alpha
	var s := paper_box(c, PAPER_EDGE, 2)
	return s


static func style_label(l: Label, size: int, color: Color = INK) -> void:
	var f := font()
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)


static func style_rich(r: RichTextLabel, size: int, color: Color = INK) -> void:
	var f := font()
	if f != null:
		r.add_theme_font_override("normal_font", f)
		r.add_theme_font_override("bold_font", f)
		r.add_theme_font_override("italics_font", f)
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_color_override("default_color", color)
