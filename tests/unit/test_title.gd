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


func test_the_three_buttons_are_there() -> void:
	var t: Variant = load(TITLE_SCENE).instantiate()
	host.add_child(t)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var got: Array = t.described()
	ok(got.size() == 3, "标题屏应有三颗按钮，实得 %d" % got.size())
	if got.size() == 3:
		ok(str(got[0]["text"]) == "新 的 一 局" and not bool(got[0]["disabled"]),
			"第一颗应是可点的「新 的 一 局」")
		ok(str(got[2]["text"]) == "设 置" and not bool(got[2]["disabled"]),
			"第三颗应是可点的「设 置」")

	t.queue_free()
	await host.get_tree().process_frame


func test_continue_follows_the_autosave() -> void:
	SaveManager.delete_slot("auto")
	var t: Variant = load(TITLE_SCENE).instantiate()
	host.add_child(t)
	await host.get_tree().process_frame
	await host.get_tree().process_frame

	var got: Array = t.described()
	ok(got.size() == 3 and bool(got[1]["disabled"]),
		"盘上没有 auto 档，「续 前 一 局」应当是灰的")

	# 落一份 auto 档 —— 存档机制是真实的，灌回来的状态也必须是真的。
	SaveManager.save("auto")
	var got2: Array = t.described()
	ok(got2.size() == 3 and not bool(got2[1]["disabled"]),
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
