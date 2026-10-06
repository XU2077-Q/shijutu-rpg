/* ============================================================
   像素房间底图生成器 —— RPG（房间）部分走像素风，参照 To the Moon
   ----------------------------------------------------------------
   里程碑 5 之后房间的碰撞/热点都在 rooms.json 里了，但背景一直是占位。
   方舟那 12 张工单是**水墨**底图，留给对话（VN）那一边；
   房间这边和像素小人（tools/gen_sprites.js）得是一套 —— 所以像素房。

   【为什么手工生成、不用 AI】
   图像模型画不出「碰撞框和图严格对齐」：rooms.json 里每张桌子都有
   归一化矩形，画错半格，玩家就会「看着走过了桌子」或「被空气挡住」。
   这里直接读 rooms.json 的 blockers/objects 坐标摆家具，像素格对齐。

   【画法】虚拟网格 360×180（一格 = 屏幕 4px），比例正好 2:1 = 视口比，
   STRETCH_KEEP_ASPECT_COVERED 铺满 1440×720 不变形。
   写完按 4 倍最近邻放大输出，像素边是硬的，不靠 Godot 的纹理过滤。

   用法：node tools/gen_pixel_rooms.js [房间id ...]   不给 id = 全部 12 间
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");
const { writePNG, Canvas } = require("./png.js");

const VW = 360, VH = 180, SCALE = 4;

/* ============================================================
   小画笔：在虚拟分辨率上作画，最后一次性放大
   ============================================================ */

class Pix {
	constructor() {
		this.buf = Buffer.alloc(VW * VH * 4); // 全透明
	}

	/** 一个虚拟像素。a 0~1；颜色直接预乘写入（各房间底图都是不透明叠加，用 source-over） */
	px(x, y, c, a = 1) {
		x = x | 0; y = y | 0;
		if (x < 0 || y < 0 || x >= VW || y >= VH || a <= 0) return;
		const i = (y * VW + x) * 4;
		const d = this.buf;
		if (a >= 1 || d[i + 3] === 0) {
			d[i] = c[0]; d[i + 1] = c[1]; d[i + 2] = c[2]; d[i + 3] = a * 255;
			return;
		}
		const da = d[i + 3] / 255;
		const oa = a + da * (1 - a);
		d[i]     = (c[0] * a + d[i]     * da * (1 - a)) / oa;
		d[i + 1] = (c[1] * a + d[i + 1] * da * (1 - a)) / oa;
		d[i + 2] = (c[2] * a + d[i + 2] * da * (1 - a)) / oa;
		d[i + 3] = oa * 255;
	}

	rect(x, y, w, h, c, a = 1) {
		for (let j = 0; j < h; j++)
			for (let i = 0; i < w; i++) this.px(x + i, y + j, c, a);
	}

	/** 只描矩形边 */
	box(x, y, w, h, c) {
		for (let i = 0; i < w; i++) { this.px(x + i, y, c); this.px(x + i, y + h - 1, c); }
		for (let j = 0; j < h; j++) { this.px(x, y + j, c); this.px(x + w - 1, y + j, c); }
	}

	/** 实心圆（遮挡树冠用） */
	disc(cx, cy, r, c, a = 1) {
		for (let y = -r; y <= r; y++)
			for (let x = -r; x <= r; x++)
				if (x * x + y * y <= r * r) this.px(cx + x, cy + y, c, a);
	}

	line(x0, y0, x1, y1, c) {
		const dx = Math.abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
		const dy = -Math.abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
		let err = dx + dy;
		for (;;) {
			this.px(x0, y0, c);
			if (x0 === x1 && y0 === y1) break;
			const e2 = 2 * err;
			if (e2 >= dy) { err += dy; x0 += sx; }
			if (e2 <= dx) { err += dx; y0 += sy; }
		}
	}

	/** 归一化坐标（rooms.json 的 0~1） */
	at(nx, ny) { return [nx * VW | 0, ny * VH | 0]; }
	normRect(r) { return { x: r[0] * VW | 0, y: r[1] * VH | 0, w: r[2] * VW | 0, h: r[3] * VH | 0 }; }

	/** 输出成 SCALE 倍最近邻的 Canvas */
	toCanvas() {
		const W = VW * SCALE, H = VH * SCALE;
		const out = new Canvas(W, H);
		for (let y = 0; y < H; y++) {
			const sy = (y / SCALE) | 0;
			for (let x = 0; x < W; x++) {
				const sx = (x / SCALE) | 0;
				const si = (sy * VW + sx) * 4;
				const di = (y * W + x) * 4;
				out.data[di] = this.buf[si];
				out.data[di + 1] = this.buf[si + 1];
				out.data[di + 2] = this.buf[si + 2];
				out.data[di + 3] = this.buf[si + 3];
			}
		}
		return out;
	}
}

/* 稳定的小哈希：地板脏色、噪点用它而不是 Math.random —— 重跑结果必须一模一样 */
function hash(x, y, seed = 0) {
	let h = (x * 374761393 + y * 668265263 + seed * 2147483647) | 0;
	h = (h ^ (h >>> 13)) * 1274126177;
	return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
}

function shade(c, f) { return [c[0] * f | 0, c[1] * f | 0, c[2] * f | 0]; }
function mixc(a, b, t) {
	return [a[0] + (b[0] - a[0]) * t | 0, a[1] + (b[1] - a[1]) * t | 0, a[2] + (b[2] - a[2]) * t | 0];
}

/* ============================================================
   通用构件
   ============================================================ */

/** 脏色地板：底色 + 按格哈希的 ±明暗，可选横纹（木板）/ 砖缝 */
function floor(p, x0, y0, x1, y1, base, opts = {}) {
	for (let y = y0; y < y1; y++) {
		for (let x = x0; x < x1; x++) {
			let f = 1 + (hash(x, y, opts.seed | 0) - 0.5) * (opts.noise || 0.12);
			p.px(x, y, shade(base, f));
		}
	}
	if (opts.planks) {
		// 横向木板缝
		const gap = opts.planks;
		for (let y = y0; y < y1; y++) if ((y - y0) % gap === gap - 1)
			for (let x = x0; x < x1; x++) p.px(x, y, shade(base, 0.72));
		// 错开的竖缝
		for (let r = 0; r * gap < y1 - y0; r++) {
			const seam = x0 + ((r * 53) % (x1 - x0));
			for (let k = 0; k < gap - 1; k++) p.px(seam, y0 + r * gap + k, shade(base, 0.8));
		}
	}
	if (opts.tiles) {
		const t = opts.tiles;
		for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++)
			if ((x - x0) % t === 0 || (y - y0) % t === 0) p.px(x, y, shade(base, 0.74));
	}
}

/** 后墙 + 踢脚线，墙顶可加一条暗影 */
function backWall(p, h, wall, opts = {}) {
	p.rect(0, 0, VW, h, wall);
	// 墙面轻微脏花
	for (let y = 2; y < h - 2; y++) for (let x = 0; x < VW; x++) {
		const n = hash(x, y, 7);
		if (n > 0.86) p.px(x, y, shade(wall, 0.94 + n * 0.05));
	}
	p.rect(0, h - 3, VW, 3, shade(wall, 0.62));           // 踢脚线
	if (opts.topShadow) p.rect(0, 0, VW, 6, shade(wall, 0.78));
}

/** 木棂窗（糊纸）：亮底 + 深色格子 */
function latticeWindow(p, x, y, w, h, paperC = [228, 214, 178], barC = [90, 60, 36]) {
	p.rect(x, y, w, h, paperC);
	for (let i = 4; i < w; i += 5) p.rect(x + i, y, 1, h, barC);
	for (let j = 4; j < h; j += 5) p.rect(x, y + j, w, 1, barC);
	p.box(x, y, w, h, barC);
}

/** 顶视家具：木桌（亮桌面 + 暗前沿 + 桌腿影） */
function table(p, x, y, w, h, wood = [132, 84, 44]) {
	const top = shade(wood, 1.18), edge = shade(wood, 0.72), dark = shade(wood, 0.5);
	p.rect(x, y, w, h - 4, top);
	p.rect(x, y + h - 5, w, 5, edge);
	p.box(x, y, w, h, dark);
	// 桌腿阴影
	p.rect(x + 1, y + h - 2, 3, 2, dark);
	p.rect(x + w - 4, y + h - 2, 3, 2, dark);
}

/** 长条凳 */
function bench(p, x, y, w, h, wood = [112, 72, 40]) {
	p.rect(x, y, w, h - 2, shade(wood, 1.1));
	p.rect(x, y + h - 2, w, 2, shade(wood, 0.6));
	p.box(x, y, w, h, shade(wood, 0.5));
}

/** 小瓷盏/碟子：两点白 + 一点青花 */
function cup(p, x, y) {
	p.px(x, y, [236, 232, 220]); p.px(x + 1, y, [236, 232, 220]);
	p.px(x, y + 1, [120, 140, 170]);
}

/** 门洞：黑色 + 门框 */
function doorway(p, x, y, w, h, frame = [102, 66, 38]) {
	p.rect(x, y, w, h, [28, 22, 18]);
	p.box(x, y, w, h, frame);
}

/** 柱子（朱/木） */
function pillar(p, x, y, h, c = [120, 52, 38]) {
	p.rect(x, y, 4, h, c);
	p.rect(x, y, 1, h, shade(c, 1.25));
}

/** 挂着的灯笼 */
function lantern(p, x, y) {
	p.px(x, y, [60, 40, 24]);
	p.rect(x - 2, y + 1, 5, 5, [196, 72, 48]);
	p.px(x, y + 1, [230, 150, 90]);
	p.px(x, y + 6, [196, 72, 48]);
}

/** 远景屋檐（翘角简化）：画一条带两端上翘的瓦顶 */
function roof(p, x, y, w, h, c = [70, 66, 62]) {
	p.rect(x + 3, y, w - 6, h - 2, c);
	p.px(x + 2, y + 1, c); p.px(x + 1, y + 2, c);
	p.px(x + w - 3, y + 1, c); p.px(x + w - 2, y + 2, c);
	// 瓦垄
	for (let i = 5; i < w - 5; i += 6) p.rect(x + i, y, 1, h - 2, shade(c, 0.8));
	p.rect(x + 3, y + h - 2, w - 6, 1, shade(c, 0.6));
}

/* ============================================================
   十二间房，逐间手摆。每间先读 rooms.json 的真实矩形再画 ——
    blockers = 碰撞家具，objects(exit) = 门洞/路口
   ============================================================ */

const PAL = {
	paperWall: [214, 196, 158],
	woodFloor: [138, 92, 50],
	dirt: [176, 156, 120],
	brick: [128, 128, 126],
	stone: [150, 146, 138],
};

function R(id) {
	const all = require("../data/rooms.json");
	const rooms = all.rooms || all;
	return rooms[id];
}

/* ---------------- 广和茶楼 ---------------- */
function draw_tea(p) {
	backWall(p, 68, PAL.paperWall, { topShadow: true });
	latticeWindow(p, 40, 14, 86, 36, [210, 200, 168], [96, 64, 40]);
	latticeWindow(p, 236, 14, 70, 36, [210, 200, 168], [96, 64, 40]);
	lantern(p, 150, 8); lantern(p, 200, 8);
	floor(p, 0, 68, VW, VH, PAL.woodFloor, { planks: 12, noise: 0.14, seed: 3 });

	const rm = R("r_tea");
	// 窗边的桌（碰撞框 0.1/0.44/0.26/0.14）
	let b = p.normRect(rm.blockers[0].rect);
	table(p, b.x, b.y, b.w, b.h + 6, [122, 78, 42]);
	cup(p, b.x + 12, b.y + 6); cup(p, b.x + 40, b.y + 8);
	// 碎盏（独立热点 0.12/0.6）
	const shard = p.normRect([0.12, 0.6, 0.07, 0.06]);
	p.px(shard.x, shard.y, [228, 224, 210]); p.px(shard.x + 2, shard.y + 1, [228, 224, 210]);
	p.px(shard.x + 1, shard.y + 2, [120, 140, 170]);
	// 柜台（0.64/0.42）
	b = p.normRect(rm.blockers[1].rect);
	table(p, b.x, b.y, b.w, b.h + 8, [110, 70, 40]);
	p.rect(b.x + 6, b.y - 8, 20, 8, [150, 120, 70]);   // 柜上茶壶
	// 长凳（0.4/0.62）
	b = p.normRect(rm.blockers[2].rect);
	bench(p, b.x, b.y, b.w, b.h + 2);
	// 楼梯口（exit，0.62/0.86）：深色楼梯井 + 台阶线
	const st = p.normRect([0.62, 0.86, 0.12, 0.11]);
	p.rect(st.x, st.y, st.w, st.h + 3, [56, 40, 28]);
	for (let i = 1; i < 5; i++) p.rect(st.x + 2, st.y + i * 3, st.w - 4, 1, [96, 72, 50]);
	p.box(st.x, st.y, st.w, st.h + 3, [80, 56, 36]);
}

/* ---------------- 宣武门外大街（外景） ---------------- */
function draw_xuanwu(p) {
	// 天
	p.rect(0, 0, VW, 56, [168, 172, 176]);
	for (let x = 0; x < VW; x++) for (let y = 0; y < 56; y++) {
		const n = hash(x, y, 11);
		p.px(x, y, shade([168, 172, 176], 0.96 + n * 0.08));
	}
	// 天地交界处一整道远处城景底色，50~63 行铺满 ——
	// 房屋都在它之上画，漏的缝由它兜着，不留下任何透明列。
	p.rect(0, 50, VW, 14, [126, 120, 110]);
	// 远处城门楼
	roof(p, 132, 18, 96, 14, [96, 92, 88]);
	p.rect(142, 32, 76, 18, [120, 116, 110]);
	p.rect(170, 38, 20, 12, [80, 76, 72]);
	// 城门楼与两侧铺面之间补两排远处矮房 —— 不然 50~63 行露天色，
	// 截图上是城楼底下一条亮缝。
	roof(p, 92, 52, 42, 10, [104, 100, 96]); p.rect(92, 60, 44, 8, [128, 124, 118]);
	roof(p, 226, 52, 42, 10, [104, 100, 96]); p.rect(224, 60, 44, 8, [128, 124, 118]);
	// 两侧铺面（后排）
	roof(p, 8, 40, 92, 16, [72, 68, 64]); p.rect(8, 56, 92, 20, [112, 100, 84]);
	roof(p, 262, 40, 90, 16, [72, 68, 64]); p.rect(262, 56, 90, 20, [112, 100, 84]);
	// 布幌子
	p.rect(30, 56, 4, 12, [150, 60, 50]); p.rect(304, 56, 4, 12, [60, 90, 120]);
	// 夯土地面
	floor(p, 0, 64, VW, VH, PAL.dirt, { noise: 0.16, seed: 5 });
	// 路中浅浅车辙
	for (let x = 0; x < VW; x++) { p.px(x, 130, shade(PAL.dirt, 0.86)); p.px(x, 150, shade(PAL.dirt, 0.88)); }

	const rm = R("r_xuanwu");
	// 告示墙（0.34/0.42）：矮砖墙 + 各色告示纸
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x, b.y + 4, b.w, b.h - 2, [118, 108, 92]);
	p.rect(b.x, b.y + 2, b.w, 3, [98, 90, 78]);
	const papers = [[220, 210, 170], [190, 90, 70], [210, 190, 130], [170, 180, 170]];
	for (let i = 0; i < 7; i++) p.rect(b.x + 4 + i * 14, b.y + 5, 10, 8, papers[i % 4]);
	// 拴马桩（0.62/0.66）
	b = p.normRect(rm.blockers[1].rect);
	for (let i = 0; i < 3; i++) {
		p.rect(b.x + i * 7, b.y, 3, b.h, [96, 82, 60]);
		p.px(b.x + i * 7 + 1, b.y - 1, [70, 58, 42]);
	}
	// 行人剪影两簇（街上的人热点 0.06/0.56）
	const folk = p.normRect([0.06, 0.56, 0.18, 0.14]);
	for (let i = 0; i < 5; i++) {
		const x = folk.x + 4 + i * 10, y = folk.y + 10 + (i % 2) * 4;
		p.disc(x, y, 2, [70, 60, 50]); p.rect(x - 1, y + 2, 3, 6, [70, 60, 50]);
	}
}

/* ---------------- 杨椒山祠（庭院） ---------------- */
function draw_ci(p) {
	// 正殿（后排）：红柱、三扇门、石阶
	p.rect(0, 0, VW, 60, [106, 102, 98]);
	roof(p, 60, 6, 240, 18, [74, 70, 66]);
	p.rect(72, 24, 216, 36, [118, 110, 100]);
	for (let i = 0; i < 5; i++) pillar(p, 84 + i * 48, 24, 36, [122, 54, 40]);
	doorway(p, 100, 30, 26, 30, [96, 52, 38]);
	doorway(p, 168, 30, 26, 30, [96, 52, 38]);
	doorway(p, 236, 30, 26, 30, [96, 52, 38]);
	// 两侧院墙
	p.rect(0, 52, 60, 20, [120, 116, 110]); p.rect(300, 52, 60, 20, [120, 116, 110]);
	// 白绢横幅（人群抬头看）
	p.rect(96, 44, 168, 6, [232, 228, 214]);
	// 青砖庭院。从 60 行起，不留空带 —— 正殿只到 59 行，
	// 第一版地面从 72 开始，中间 12 行透明，在游戏里是一道白缝。
	floor(p, 0, 60, VW, VH, PAL.brick, { tiles: 12, noise: 0.1, seed: 9 });

	const rm = R("r_ci");
	// 祠门/石阶（0.3/0.4）
	let b = p.normRect(rm.blockers[0].rect);
	for (let i = 0; i < 3; i++) p.rect(b.x, b.y + i * 4, b.w, 3, shade(PAL.stone, 0.95 - i * 0.08));
	// 石碑（0.14/0.62）
	b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x + 4, b.y, b.w - 8, b.h - 4, [110, 108, 102]);
	p.rect(b.x + 4, b.y, b.w - 8, 2, [84, 82, 78]);
	p.rect(b.x, b.y + b.h - 4, b.w, 4, [96, 94, 88]);
	// 龟趺
	p.disc(b.x + b.w / 2 | 0, b.y + b.h - 3, 5, [80, 78, 72]);
	// 底部临街大门缝（exit 回大街 0.42/0.86）
	const gate = p.normRect([0.42, 0.86, 0.16, 0.1]);
	p.rect(gate.x, gate.y, gate.w, gate.h + 2, [150, 146, 136]);
	p.box(gate.x, gate.y, gate.w, gate.h + 2, [100, 96, 88]);
}

/* ---------------- 悦来客栈（夜，内景） ---------------- */
function draw_ke(p) {
	backWall(p, 72, [150, 128, 96], { topShadow: true });
	// 夜窗：暗蓝
	latticeWindow(p, 208, 16, 64, 34, [70, 84, 104], [72, 52, 34]);
	floor(p, 0, 72, VW, VH, [96, 66, 40], { planks: 11, noise: 0.14, seed: 13 });

	const rm = R("r_ke");
	// 炕（0.1/0.44）
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x, b.y, b.w, b.h, [124, 84, 52]);          // 炕体
	p.rect(b.x + 3, b.y + 3, b.w - 6, b.h - 8, [78, 92, 116]);  // 蓝布褥
	p.rect(b.x + 6, b.y + 5, 22, 8, [220, 210, 180]);    // 枕头/被
	p.box(b.x, b.y, b.w, b.h, [80, 52, 32]);
	// 书案（0.56/0.5）
	b = p.normRect(rm.blockers[1].rect);
	table(p, b.x, b.y, b.w, b.h + 4, [104, 68, 38]);
	// 油灯 + 暖光晕
	const lampX = b.x + b.w - 10, lampY = b.y - 2;
	for (let r = 12; r > 0; r--) p.disc(lampX, lampY, r, [230, 180, 100], 0.05);
	p.disc(lampX, lampY, 2, [250, 220, 140]);
	p.rect(b.x + 10, b.y + 4, 18, 6, [216, 204, 170]);   // 抄本
	// 底部出口门
	const door = p.normRect([0.42, 0.86, 0.16, 0.1]);
	doorway(p, door.x, door.y, door.w, door.h + 3, [86, 56, 34]);
}

/* ---------------- 都察院门前 ---------------- */
function draw_gongche(p) {
	// 大照壁式衙门：灰墙 + 朱门
	p.rect(0, 0, VW, 66, [124, 120, 114]);
	roof(p, 56, 4, 248, 16, [78, 74, 70]);
	// 朱漆大门（成排门钉）
	p.rect(132, 18, 96, 48, [122, 44, 36]);
	p.box(132, 18, 96, 48, [80, 30, 26]);
	for (let y = 24; y < 60; y += 8)
		for (let x = 140; x < 224; x += 10) p.disc(x, y, 1, [214, 176, 96]);
	// 两侧灰墙与边门
	p.rect(0, 30, 120, 36, [124, 120, 114]); p.rect(240, 30, 120, 36, [124, 120, 114]);
	// 空竖匾
	p.rect(170, 6, 20, 10, [150, 144, 130]); p.box(170, 6, 20, 10, [90, 84, 72]);
	// 石板广场
	floor(p, 0, 66, VW, VH, PAL.stone, { tiles: 14, noise: 0.1, seed: 17 });

	const rm = R("r_gongche");
	// 台阶（0.26/0.4）
	let b = p.normRect(rm.blockers[0].rect);
	for (let i = 0; i < 4; i++) p.rect(b.x, b.y + i * 4, b.w, 3, shade(PAL.stone, 0.92 - i * 0.06));
	// 石狮一对
	for (const k of [1, 2]) {
		b = p.normRect(rm.blockers[k].rect);
		p.rect(b.x, b.y + b.h - 5, b.w, 5, [108, 104, 96]);     // 基座
		p.disc(b.x + b.w / 2 | 0, b.y + 8, 7, [120, 116, 108]); // 狮身
		p.disc(b.x + b.w / 2 | 0, b.y + 3, 4, [130, 126, 118]); // 头
	}
}

/* ---------------- 湖南会馆（院落） ---------------- */
function draw_hunan(p) {
	// 正厅 + 抄手游廊
	p.rect(0, 0, VW, 52, [108, 104, 98]);
	roof(p, 96, 4, 168, 16, [72, 68, 64]);
	p.rect(108, 20, 144, 32, [116, 108, 96]);
	pillar(p, 120, 20, 32); pillar(p, 240, 20, 32);
	doorway(p, 160, 24, 40, 28, [90, 52, 36]);
	// 两侧游廊
	roof(p, 0, 22, 84, 12, [82, 78, 74]); p.rect(0, 34, 84, 18, [120, 112, 98]);
	roof(p, 276, 22, 84, 12, [82, 78, 74]); p.rect(276, 34, 84, 18, [120, 112, 98]);
	// 青砖天井。52 行起 —— 后排厅房到 51 行，留缝会透成白带。
	floor(p, 0, 52, VW, VH, [138, 134, 128], { tiles: 10, noise: 0.1, seed: 21 });
	// 中央条石路
	p.rect(172, 72, 16, VH - 72, [158, 154, 146]);

	const rm = R("r_hunan");
	// 影壁（0.32/0.44）
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x, b.y, b.w, b.h, [146, 140, 128]);
	p.rect(b.x, b.y, b.w, 2, [110, 104, 94]);
	p.box(b.x, b.y, b.w, b.h, [104, 98, 88]);
	// 老槐树（0.7/0.6）
	b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x + b.w / 2 - 2, b.y + 12, 4, b.h - 10, [92, 70, 46]);
	p.disc(b.x + b.w / 2, b.y + 10, 13, [78, 100, 70]);
	p.disc(b.x + b.w / 2 - 6, b.y + 8, 8, [90, 112, 80]);
	p.disc(b.x + b.w / 2 + 7, b.y + 12, 7, [66, 88, 60]);
}

/* ---------------- 永定门外（黄昏外景） ---------------- */
function draw_yongding(p) {
	// 黄昏天
	for (let y = 0; y < 62; y++) {
		const t = y / 62;
		const c = mixc([214, 172, 120], [150, 148, 150], t);
		p.rect(0, y, VW, 1, c);
	}
	// 城墙横亘
	p.rect(0, 40, VW, 30, [104, 96, 84]);
	for (let x = 8; x < VW; x += 16) p.rect(x, 36, 8, 6, [112, 104, 90]); // 垛口
	// 城楼
	roof(p, 120, 12, 120, 16, [84, 72, 60]); p.rect(132, 28, 96, 14, [118, 98, 76]);
	// 远山
	p.line(20, 40, 90, 30, [120, 118, 118]); p.line(250, 42, 340, 32, [120, 118, 118]);
	// 黄土官道
	floor(p, 0, 70, VW, VH, [168, 142, 102], { noise: 0.15, seed: 25 });
	// 官道向城门收
	for (let x = 0; x < VW; x++) { p.px(x, 128, shade([168, 142, 102], 0.85)); p.px(x, 150, shade([168, 142, 102], 0.88)); }

	const rm = R("r_yongding");
	// 城门洞（0.28/0.38）
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x + 14, b.y + 6, b.w - 28, b.h + 8, [36, 30, 26]);
	p.archTop(p, b.x + 14, b.y + 6, b.w - 28, b.h + 8, [36, 30, 26]);
	// 石墩（0.12/0.62）
	b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x, b.y + b.h - 6, b.w, 6, [110, 104, 92]);
	p.disc(b.x + b.w / 2 | 0, b.y + 8, 6, [122, 116, 104]);
	// 枯柳两株
	for (const tx of [300, 320]) {
		p.rect(tx, 76, 3, 26, [96, 78, 54]);
		p.line(tx + 1, 78, tx - 6, 68, [104, 86, 60]);
		p.line(tx + 1, 80, tx + 8, 70, [104, 86, 60]);
	}
}

/* 给 Pix 补一个拱顶门洞（永定门） */
Pix.prototype.archTop = function (x, y, w, h, c) {
	this.px(x, y - 1, c); this.px(x + w - 1, y - 1, c);
	this.px(x + 1, y - 2, c); this.px(x + w - 2, y - 2, c);
};

/* ---------------- 十六铺码头 ---------------- */
function draw_shanghai(p) {
	// 灰白天
	p.rect(0, 0, VW, 60, [186, 190, 192]);
	// 江面（码头沿后面）：灰蓝 + 水波。整幅宽 —— 第一版从 x=60 起，
	// 左边那 60 列在货栈之外的部分 60~71 行透明，白一条。
	p.rect(0, 44, VW, 28, [112, 126, 138]);
	for (let x = 70; x < VW; x += 7) p.px(x, 52, [150, 162, 170]);
	for (let x = 90; x < VW; x += 11) p.px(x, 60, [150, 162, 170]);
	// 江上船：沙船（帆）+ 蒸汽轮（烟囱）
	p.rect(150, 48, 44, 8, [86, 74, 60]);
	p.rect(166, 30, 14, 18, [206, 196, 162]);   // 帆
	p.rect(240, 44, 52, 12, [70, 72, 76]);      // 轮船身
	p.rect(250, 34, 8, 10, [60, 60, 64]);       // 烟囱
	p.rect(251, 28, 6, 6, [120, 120, 122]);     // 烟
	// 货栈（左）。墙体一路到 78 行 —— 地上的 blocker 木箱从 79 行起，
	// 中间不能断，断了货栈就像悬在半空。
	p.rect(8, 40, 72, 39, [112, 92, 66]);
	roof(p, 4, 32, 80, 10, [76, 62, 48]);
	// 码头石地
	floor(p, 0, 72, VW, VH, [140, 128, 108], { tiles: 10, noise: 0.12, seed: 29 });

	const rm = R("r_shanghai");
	// 货栈 blocker 在地上延伸（0.08/0.44）
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x, b.y, b.w, b.h, [104, 86, 62]);
	p.box(b.x, b.y, b.w, b.h, [74, 60, 42]);
	// 码头边沿（0.3/0.42）：条石矮边
	b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x, b.y, b.w, b.h, [126, 120, 108]);
	p.rect(b.x, b.y, b.w, 2, [92, 86, 76]);
	// 缆桩（0.78/0.62）
	b = p.normRect(rm.blockers[2].rect);
	for (let i = 0; i < 2; i++) {
		p.rect(b.x + i * 14, b.y, 5, b.h, [86, 74, 58]);
		p.rect(b.x + i * 14, b.y, 5, 2, [60, 52, 40]);
	}
	// 报童小人
	const news = p.normRect([0.72, 0.66, 0.16, 0.14]);
	p.disc(news.x + 8, news.y + 8, 3, [72, 60, 48]);
	p.rect(news.x + 6, news.y + 11, 5, 8, [80, 92, 110]);
}

/* ---------------- 沈家老宅（门前） ---------------- */
function draw_oldhouse(p) {
	p.rect(0, 0, VW, 64, [120, 116, 108]);
	roof(p, 60, 6, 240, 18, [70, 62, 54]);
	// 白灰山墙
	p.rect(72, 22, 216, 42, [196, 188, 166]);
	// 堂屋门（暗）+ 两侧棂窗
	doorway(p, 166, 30, 28, 34, [96, 60, 36]);
	latticeWindow(p, 104, 32, 44, 22, [212, 200, 162], [96, 60, 36]);
	latticeWindow(p, 212, 32, 44, 22, [212, 200, 162], [96, 60, 36]);
	// 旧匾留白
	p.rect(160, 22, 40, 7, [150, 138, 110]); p.box(160, 22, 40, 7, [104, 88, 62]);
	// 石阶前地
	floor(p, 0, 64, VW, VH, [148, 142, 130], { tiles: 16, noise: 0.1, seed: 31 });

	const rm = R("r_oldhouse");
	// 堂屋台基（0.26/0.4）
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x, b.y, b.w, b.h, [132, 126, 116]);
	p.rect(b.x, b.y, b.w, 2, [100, 94, 84]);
	// 门槛（0.44/0.56）
	b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x, b.y, b.w, b.h + 2, [94, 62, 38]);
	// 旗杆石（0.1/0.44）
	b = p.normRect([0.1, 0.44, 0.12, 0.2]);
	p.rect(b.x, b.y + b.h - 8, b.w, 8, [118, 112, 102]);
	p.rect(b.x + b.w / 2 - 1, b.y, 2, b.h - 8, [80, 72, 60]);
}

/* ---------------- 田庄（外景田园） ---------------- */
function draw_farm(p) {
	// 天 + 远山
	p.rect(0, 0, VW, 52, [192, 198, 198]);
	p.line(10, 48, 120, 30, [150, 158, 156]);
	p.line(140, 50, 280, 28, [140, 148, 146]);
	p.line(220, 48, 350, 34, [150, 158, 156]);
	// 天地相接的一带：远处树色/村色 haze，52~71 行必须填满 ——
	// 第一版天到 51、地从 82，30 行透明带横贯全屏，白得刺眼。
	p.rect(0, 52, VW, 20, [168, 178, 172]);
	for (let x = 20; x < VW; x += 26) p.disc(x, 60 + (x % 18) - 8, 4, [132, 148, 138]);
	// 茅草屋（压在 haze 上）
	p.rect(26, 42, 56, 32, [120, 96, 66]);
	roof(p, 20, 34, 68, 10, [130, 110, 72]);
	doorway(p, 46, 52, 14, 22, [80, 60, 40]);
	// 水田（右半，72 行起）：水面反光
	p.rect(210, 72, 150, VH - 72, [122, 146, 140]);
	for (let y = 76; y < VH; y += 9) p.rect(214, y, 140, 1, [160, 178, 172]);
	for (let y = 80; y < VH; y += 13) p.rect(230, y, 120, 1, [104, 128, 122]);
	// 黄土晒场一侧，72 行起，与 haze 接上
	floor(p, 0, 72, 214, VH, [182, 158, 112], { noise: 0.1, seed: 35 });

	const rm = R("r_farm");
	// 晒场压实区（0.3/0.46）
	let b = p.normRect(rm.blockers[0].rect);
	p.rect(b.x, b.y, b.w, b.h, [168, 146, 104]);
	p.box(b.x, b.y, b.w, b.h, [140, 120, 82]);
	// 粮囤（0.1/0.62）
	b = p.normRect(rm.blockers[1].rect);
	p.disc(b.x + b.w / 2 | 0, b.y + 6, b.w / 2 - 1, [176, 150, 96]);
	p.rect(b.x + 3, b.y + b.h - 5, b.w - 6, 5, [120, 96, 62]);
	for (let x = b.x + 4; x < b.x + b.w - 4; x += 3) p.rect(x, b.y + 4, 1, b.h - 8, [150, 126, 80]);
	// 田埂（0.66/0.6）
	b = p.normRect(rm.blockers[2].rect);
	p.rect(b.x, b.y, b.w, 3, [150, 130, 90]);
	p.rect(b.x, b.y + b.h - 3, b.w, 3, [150, 130, 90]);
	// 水牛（站在黄土上，不是天上）
	p.disc(122, 86, 7, [72, 70, 64]); p.disc(113, 82, 3, [72, 70, 64]);
	p.rect(118, 92, 2, 3, [60, 58, 52]); p.rect(126, 92, 2, 3, [60, 58, 52]);
}

/* ---------------- 沈家书房（内景） ---------------- */
function draw_study(p) {
	backWall(p, 74, [206, 186, 148], { topShadow: true });
	latticeWindow(p, 190, 16, 80, 38, [206, 198, 168], [94, 62, 38]);
	// 墙上条幅（无字留白）
	p.rect(132, 12, 14, 44, [228, 218, 190]); p.box(132, 12, 14, 44, [140, 110, 70]);
	floor(p, 0, 74, VW, VH, [126, 86, 48], { planks: 12, noise: 0.13, seed: 39 });

	const rm = R("r_study");
	// 书架（0.08/0.46）
	let b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x, b.y, b.w, b.h, [96, 62, 36]);
	p.box(b.x, b.y, b.w, b.h, [60, 38, 22]);
	const bookC = [[120, 60, 48], [60, 80, 100], [110, 90, 50], [80, 96, 70], [100, 60, 70]];
	for (let shelf = 0; shelf < 4; shelf++)
		for (let x = b.x + 2; x < b.x + b.w - 3; x += 4)
			p.rect(x, b.y + 3 + shelf * 13, 3, 9, bookC[(x + shelf) % 5]);
	// 书案（0.3/0.46）
	b = p.normRect(rm.blockers[0].rect);
	table(p, b.x, b.y, b.w, b.h + 6, [112, 72, 40]);
	p.rect(b.x + 16, b.y + 5, 30, 8, [220, 210, 178]);    // 纸
	p.rect(b.x + b.w - 24, b.y - 6, 12, 8, [100, 66, 38]);// 笔筒
	for (let i = 0; i < 3; i++) p.px(b.x + b.w - 22 + i * 4, b.y - 8, [50, 40, 30]);
	// 书箱（0.74/0.62）
	b = p.normRect(rm.blockers[2].rect);
	p.rect(b.x, b.y, b.w, b.h, [106, 68, 38]);
	p.box(b.x, b.y, b.w, b.h, [66, 42, 24]);
	p.rect(b.x + 2, b.y + 3, b.w - 4, 2, [80, 50, 28]);
	// 出口
	const door = p.normRect([0.42, 0.86, 0.16, 0.1]);
	doorway(p, door.x, door.y, door.w, door.h + 2, [84, 54, 32]);
}

/* ---------------- 长沙·陈宅花厅 ---------------- */
function draw_chendi(p) {
	backWall(p, 74, [186, 150, 120], { topShadow: true });
	// 花窗（华丽）
	latticeWindow(p, 220, 14, 70, 40, [196, 160, 110], [110, 60, 40]);
	for (let x = 230; x < 284; x += 12) p.rect(x, 14, 1, 40, [140, 80, 50]);
	floor(p, 0, 74, VW, VH, [118, 78, 46], { planks: 12, noise: 0.13, seed: 43 });
	// 红毡
	p.rect(100, 120, 160, 40, [128, 52, 44], 0.5);

	const rm = R("r_chendi");
	// 屏风（0.08/0.48）
	let b = p.normRect(rm.blockers[1].rect);
	p.rect(b.x, b.y, b.w, b.h, [104, 60, 36]);
	p.box(b.x, b.y, b.w, b.h, [64, 36, 20]);
	for (let i = 0; i < 3; i++) {
		p.rect(b.x + 3 + i * 11, b.y + 4, 9, b.h - 8, [150, 110, 60]);
		p.rect(b.x + 3 + i * 11, b.y + 4, 9, 2, [110, 76, 40]);
	}
	// 席面（0.24/0.46）：大圆桌感的方桌 + 满桌碗碟
	b = p.normRect(rm.blockers[0].rect);
	table(p, b.x, b.y, b.w, b.h + 6, [116, 70, 40]);
	for (let i = 0; i < 8; i++)
		cup(p, b.x + 8 + (i % 4) * 40, b.y + 5 + ((i / 4) | 0) * 10);
	p.rect(b.x + b.w / 2 - 8, b.y + 8, 16, 8, [200, 160, 90]);  // 主菜
	// 出口
	const door = p.normRect([0.42, 0.86, 0.16, 0.1]);
	doorway(p, door.x, door.y, door.w, door.h + 2, [88, 54, 32]);
}

/* ============================================================ */

const DRAWERS = {
	r_tea: draw_tea,
	r_xuanwu: draw_xuanwu,
	r_ci: draw_ci,
	r_ke: draw_ke,
	r_gongche: draw_gongche,
	r_hunan: draw_hunan,
	r_yongding: draw_yongding,
	r_shanghai: draw_shanghai,
	r_oldhouse: draw_oldhouse,
	r_farm: draw_farm,
	r_study: draw_study,
	r_chendi: draw_chendi,
};

function main() {
	const ids = process.argv.slice(2).filter((x) => DRAWERS[x]);
	const list = ids.length ? ids : Object.keys(DRAWERS);
	const outDir = path.join(__dirname, "..", "art", "bg");
	fs.mkdirSync(outDir, { recursive: true });

	let bad = 0;
	for (const id of list) {
		const p = new Pix();
		DRAWERS[id](p);

		// 透明像素扫描：房间底图每个像素都必须是实的。漏画的地方在游戏里
		// 是一个能看穿的洞（看着像白缝），而画图时很难注意到。
		// 发现就填成扎眼的品红，叫它藏不住 —— 不是替它修补。
		let holes = 0;
		for (let i = 3; i < p.buf.length; i += 4)
			if (p.buf[i] === 0) { p.buf[i - 3] = 255; p.buf[i - 2] = 0; p.buf[i - 1] = 255; p.buf[i] = 255; holes++; }
		if (holes > 0) { console.log("✗", id, "有", holes, "个透明像素，已标成品红"); bad++; }

		const file = path.join(outDir, id + ".png");
		writePNG(file, p.toCanvas());
		console.log("✓", id, fs.statSync(file).size.toLocaleString(), "bytes");
	}
	if (bad > 0) process.exitCode = 1;
}

main();
