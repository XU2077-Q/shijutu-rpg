class_name Cast
extends RefCounted
## 谁有脸，谁只有名字。
##
## 【为什么是一张手写的表，不是模糊匹配】
## 剧本里的说话人写法和立绘文件名对不上，而且是**多对多地对不上**：
##   剧本写「何伯」        立绘叫「佃农何伯」
##   剧本写「守门兵」      立绘叫「守门士兵」
##   剧本写「周子安」      立绘将来叫「zhou_zi_an」
## 一开始想过用「包含」去猜（"何伯" ⊂ "佃农何伯"），但那是会出事的写法：
## 「黎景明」和「黎景高」互相包含不了，可一旦哪天加一张「沈怀瑾（少年）」，
## 猜法就会把成年立绘套到少年身上 —— 而且**不报错**，只是脸不对。
## 一张手写的表，错了看得见；一个猜法，错了看不见。
##
## 表里也包含「还没有立绘」的人：文件不在就不画立绘，只出名字。
## 龙套（街上的人、举子甲乙丙）**故意不登记** —— 他们本来就不该有脸。

const PORTRAIT_DIR := "res://art/portraits/"
const WALK_DIR := "res://art/walk/"

## 说话人 → 立绘文件名。
const FACES := {
	# —— 已就位 ——
	"沈怀瑾": "shen_huaijin.png",
	"林婉如": "lin_wanru.png",
	"沈鹤龄": "shen_heling.png",
	"黎景明": "li_jingming.png",
	"黎景高": "li_jinggao.png",
	"何伯": "he_bo.png",
	"守门兵": "gate_soldier.png",
	"日本士兵": "jp_soldier.png",
	"阿巧": "a_qiao.png",
	"豆腐老倌": "doufu_laoguan.png",
	"小满": "xiaoman.png",
	"林伯渊": "lin_clerk.png",
	"湖南蒙学先生": "mengxue_xiansheng.png",
	"顺子": "shunzi.png",
	"台湾母子": "taiwan_mother.png",
	# —— 待生成（tools/art_manifest.json 里的 pt_* 五项）——
	"周子安": "zhou_zi_an.png",
	"康有为": "kang_youwei.png",
	"俄国商人": "ru_merchant.png",
	"陈道台": "chen_daotai.png",
	"台湾举子": "tw_juzi.png",
}

## 立绘已登记但文件还没出的。缺图不算错，画面上少一张脸而已。
## 这条清单同时是给测试看的：它区分「还没画」和「画了但表里漏了」。
const PENDING := [
	"zhou_zi_an.png", "kang_youwei.png", "ru_merchant.png",
	"chen_daotai.png", "tw_juzi.png",
]

## 有立绘文件但**故意不登记**的（画的是群像，没有对应的说话人）。
const NOT_A_SPEAKER := {
	"taiwan_mother.png": "台湾母子是画面上的一对母子，剧本里没有以他们为说话人的句子",
}

## 有台词但**故意不给立绘**的 —— 龙套。
##
## 【为什么要写成一张表，而不是「查不到就不画」】
## 「查不到就不画」用起来完全一样，但它把**决定**藏起来了：
## 哪天剧本里「陌生人」的台词从 1 句涨到 30 句，画面还是没脸，
## 而没有任何地方会提醒你。写成一张表，就等于把「这些人不给脸」这句话
## 摆在明处，加人删人都要动手改一次 —— 那一下动手就是复核。
const CROWD := {
	"街上的人": "街景的一部分，不是人物",
	"举子": "同乡举子甲乙丙的合称，是背景人群",
	"举子甲": "同上",
	"举子乙": "同上",
	"举子丙": "同上",
	"有人喊": "画外音，根本没有出场",
	"陌生人": "只有一句，故意不露脸",
	"严复": "只有一句引文式的台词，出现在书信里，不是出场人物",
}

## 可操作角色 → 行走图前缀。art/walk/ 里的帧名是 <前缀>_<方向>_<帧号>.png
const WALKERS := {
	"沈怀瑾": "shen",
	"林婉如": "lin",
}


## 这个说话人有没有立绘。文件不在就返回空串 —— 调用方据此决定画不画。
static func portrait_file(speaker: String) -> String:
	var f: String = FACES.get(speaker, "")
	if f.is_empty():
		return ""
	if not ResourceLoader.exists(PORTRAIT_DIR + f):
		return ""
	return f


## 说话人身份栏。剧本里同一句话可能只写名字（"周子安"），
## 也可能名字后面跟一个身份（"周子安|同乡举子"）——
## 身份只在**第一次**出场时给，之后再出现就不重复了。
## 所以查脸只按名字，不按身份。
static func has_face(speaker: String) -> bool:
	return not portrait_file(speaker).is_empty()


static func walker_prefix(who: String) -> String:
	return WALKERS.get(who, "")
