extends TestCase
## 标题屏与设置。
##
## 【为什么值得测】
## 标题屏看着只是几颗按钮，但它攥着两条容易断的线：
##   一、「续 前 一 局」的灰与亮跟着**盘上有没有 auto 档**走 ——
##      自动存档是 VN 屏在场景进门/选项摆出时落的，这条断了，
##      玩家玩到一半退出，回来发现续不了，比没有这个按钮更伤。
##   二、设置要**真的落盘** —— ConfigFile 写 user://settings.cfg。
##      改了速度、退了浏览器、再进来还是旧速度，那种「设置形同虚设」
##      的感觉，比少一个功能更败好感。
##
## 都用真的 SaveManager / AppSettings 跑（autoload 本来就是全局单例），
## 用例自己负责把起跑线清干净。

const TITLE_SCENE := "res://scenes/title/title.tscn"
const SETTINGS_PATH := "user://settings.cfg"


## 按文字找按钮，不按下标。
## 【为什么不按下标】按钮是会增删的（里程碑 4 就加了一颗「走 动」）。
## 按下标写的断言，加一颗按钮就全线错位 —— 而错位报出来的话是
## 「第三颗应是设置」，看着像设置坏了，其实只是挪了位。
static func _btn(got: Array, text: String) -> Dictionary:
	for b in got:
		if str(b.get("text", "")) == text:
			return b
	return {}


## 按前缀找。**只给「走 动」那颗用** —— 它的副题随里程碑改过
## （里程碑 4 是「序 章 三 间」，里程碑 5 接上脊梁后是「序 章 至 第 一 章」）。
## 这条用例要验的是那颗按钮**在不在**，不是它印的什么字；
## 死抠全文的话，下次改文案又会红一次，而红的理由跟它想守的东西没关系。
static func _btn_prefix(got: Array, prefix: String) -> Dictionary:
	for b in got:
		if str(b.get("text", "")).begins_with(prefix):
			return b
	return {}


func test_the_menu_buttons_are_there() -> void:
	var t: Variant = load(TITLE_SCENE).instantiate()
	host.add_child(t)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var got: Array = t.described()
	var a := _btn(got, "新 的 一 局")
	ok(not a.is_empty() and not bool(a.get("disabled", true)), "应有可点的「新 的 一 局」")
	var s := _btn(got, "设 置")
	ok(not s.is_empty() and not bool(s.get("disabled", true)), "应有可点的「设 置」")

	# 走动演示只在 rooms.json 真的存在时才摆出来 ——
	# 摆一颗点了没反应的按钮，比少一颗更败好感。
	var w := _btn_prefix(got, "走 动")
	ok(DataDB.rooms.is_empty() == w.is_empty(),
		"「走 动」这颗按钮的有无，应当跟着 rooms.json 在不在走")

	t.queue_free()
	await host.get_tree().process_frame


## 【这一条是踩出来的，别删】
## 焦点停在「走 动」那颗按钮上按回车，进去的却是纯 VN。
## 原因是 Button 只在**按下**那一半消费 ui_accept，松开那一半没有 ——
## 于是按钮跑了（_walk_demo），标题屏的兜底也跑了（_start_new），
## 后者的 change_scene_to_file 盖掉前者。
## 之前只有三颗按钮时看不出来：焦点默认在「新 的 一 局」上，
## 两条路做的是同一件事。
##
## 这里只验判据本身 —— 真去调 _unhandled_input 会 change_scene，
## 那会把跑架自己换掉。
func test_enter_is_the_buttons_while_a_button_has_focus() -> void:
	var t: Variant = load(TITLE_SCENE).instantiate()
	host.add_child(t)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var first: Variant = null
	for b in t.find_children("*", "Button", true, false):
		if (b as Button).text == "新 的 一 局":
			first = b
	ok(first != null, "应当找得到「新 的 一 局」")
	if first != null:
		(first as Button).grab_focus()
		await host.get_tree().process_frame
		ok(host.get_viewport().gui_get_focus_owner() != null,
			"grab_focus 之后应当有人拿着焦点")
		ok(not bool(t.enter_starts_a_new_game()),
			"有按钮拿着焦点时，回车归那颗按钮 —— 兜底不该也跑一遍")

	# 焦点交出去，兜底才该接管
	(host.get_viewport() as Viewport).gui_release_focus()
	await host.get_tree().process_frame
	ok(bool(t.enter_starts_a_new_game()),
		"没人拿焦点时，回车才轮到兜底开局")

	t.queue_free()
	await host.get_tree().process_frame


func test_continue_follows_the_autosave() -> void:
	SaveManager.delete_slot("auto")
	var t: Variant = load(TITLE_SCENE).instantiate()
	host.add_child(t)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var c := _btn(t.described(), "续 前 一 局")
	ok(not c.is_empty() and bool(c.get("disabled", false)),
		"盘上没有 auto 档，「续 前 一 局」应当是灰的")

	# 落一份 auto 档 —— 存档机制是真实的，灌回来的状态也必须是真的。
	SaveManager.save("auto")
	var c2 := _btn(t.described(), "续 前 一 局")
	ok(not c2.is_empty() and not bool(c2.get("disabled", true)),
		"auto 档落盘之后，「续 前 一 局」应当亮起来")

	t.queue_free()
	await host.get_tree().process_frame
	SaveManager.delete_slot("auto")


func test_settings_really_persist() -> void:
	DirAccess.remove_absolute(SETTINGS_PATH)
	# AppSettings._ready 已在启动时读过一次（当时没有文件，是默认值）。
	ok(is_equal_approx(AppSettings.cps, AppSettings.CPS_DEFAULT),
		"没有设置文件时，速度应是默认值")

	AppSettings.set_cps(60.0)
	ok(is_equal_approx(AppSettings.cps, 60.0), "set_cps 应当场生效")

	# 直接读文件验落盘 —— 不再借道 AppSettings，免得「自己验自己」。
	var cf := ConfigFile.new()
	var err := cf.load(SETTINGS_PATH)
	ok(err == OK, "设置应已写进 %s（错误码 %d）" % [SETTINGS_PATH, err])
	if err == OK:
		ok(is_equal_approx(float(cf.get_value("ui", "cps", 0.0)), 60.0),
			"文件里的速度应是 60")

	# 边界：滑条两端之外的一律夹回来。
	AppSettings.set_cps(999.0)
	ok(AppSettings.cps <= AppSettings.CPS_MAX, "超上限的速度应被夹住")
	AppSettings.set_cps(AppSettings.CPS_DEFAULT)


func test_settings_panel_applies_and_shows() -> void:
	var p: Variant = load("res://scripts/ui/settings_panel.gd").new()
	host.add_child(p)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	p.open()
	ok(bool(p.visible), "open() 之后面板应当可见")

	# 面板打开时应显示 AppSettings 当前的值（不是它自己记的旧值）。
	AppSettings.set_cps(30.0)
	p.open()
	var slider: Variant = p.get("_cps_slider")
	ok(slider != null and is_equal_approx(float(slider.value), 30.0),
		"重开面板，滑条应跟上当前设置（30）")

	var check: Variant = p.get("_fs_check")
	ok(check != null and bool(check.button_pressed) == AppSettings.fullscreen,
		"全屏开关应显示当前状态")

	p.close_panel()
	ok(not bool(p.visible), "close_panel 之后面板应当藏起来")

	# 还原默认，免得影响别的用例或下一场跑测。
	AppSettings.set_cps(AppSettings.CPS_DEFAULT)
	p.queue_free()
	await host.get_tree().process_frame
