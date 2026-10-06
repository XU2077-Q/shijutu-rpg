/* ============================================================
   水墨背景生成器 —— 对话（VN）部分走水墨风
   ----------------------------------------------------------------
   VN 屏（scripts/vn/vn_screen.gd）一直是纯纸底 + 立绘。
   用户要求对话部分给水墨背景；方舟工单（tools/art_manifest.json）也是
   水墨 prompts，但 ARK_API_KEY 还空着，且这一版先要不花钱、可重跑的底。

   【画法】宣纸底 + 墨色层（山/屋/树/船），墨层画完做箱式模糊做出
   「淡墨渲染」的软边，再压 mist 雾带和一层薄纸白 —— 保住文字可读性。
   留白就是水墨本身，画面宁可空。

   输出 1440×720（与视口同比）到 art/ink/<id>.png
   用法：node tools/gen_ink.js [id ...]   不给 id = 全部
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");
const { writePNG, Canvas } = require("./png.js");

const W = 1440, H = 720;

/* ---------------- 墨层：独立 RGBA ---------------- */

/* 墨层画在 1/S 的低分辨率缓冲里，finish() 时最近邻放大 + 轻模糊 ——
   细笔触自动变肥厚软润，这就是想要的墨韵（在全分辨率上画细线再模糊只会变没） */
const S = 2, IW = W / S, IH = H / S;

class Layer {
	constructor() { this.d = Buffer.alloc(IW * IH * 4); }

	/** 硬边墨块（坐标传全分辨率值） */
	put(x, y, c, a = 1) {
		x = (x / S) | 0; y = (y / S) | 0;
		if (x < 0 || y < 0 || x >= IW || y >= IH || a <= 0) return;
		const i = (y * IW + x) * 4, d = this.d;
		const da = d[i + 3] / 255;
		const oa = Math.min(1, a + da);
		if (oa <= 0) return;
		d[i]     = (c[0] * a + d[i]     * da * (1 - a)) / oa;
		d[i + 1] = (c[1] * a + d[i + 1] * da * (1 - a)) / oa;
		d[i + 2] = (c[2] * a + d[i + 2] * da * (1 - a)) / oa;
		d[i + 3] = oa * 255;
	}

	rect(x, y, w, h, c, a = 1) {
		for (let j = 0; j < h; j += S) for (let i = 0; i < w; i += S) this.put(x + i, y + j, c, a);
	}

	disc(cx, cy, r, c, a = 1) {
		const ri = r / S;
		const rr = Math.ceil(ri);
		for (let y = -rr; y <= rr; y++)
			for (let x = -rr; x <= rr; x++) {
				const d2 = x * x + y * y;
				if (d2 <= ri * ri) {
					const aa = a * (1 - 0.25 * (d2 / (ri * ri)));
					this.put(cx + x * S, cy + y * S, c, aa);
				}
			}
	}

	/** 笔触：圆头沿线，宽度 w；按 S 间距采样，避免同一缓冲像素叠两次（alpha 翻倍） */
	stroke(x0, y0, x1, y1, w, c, a = 1) {
		const dx = x1 - x0, dy = y1 - y0;
		const len = Math.hypot(dx, dy);
		const n = Math.max(1, Math.ceil(len / S));
		for (let i = 0; i <= n; i++) {
			const t = i / n;
			this.disc(x0 + dx * t, y0 + dy * t, w / 2, c, a);
		}
	}

	/** alpha 箱式模糊（低分辨率缓冲）。原地 */
	blur(radius, vertical = false) {
		const src = Buffer.from(this.d);
		const r = radius | 0;
		const win = 2 * r + 1;
		for (let y = 0; y < IH; y++) {
			for (let x = 0; x < IW; x++) {
				let ar = 0, ag = 0, ab = 0, aa = 0;
				for (let k = -r; k <= r; k++) {
					let sx = x, sy = y;
					if (vertical) sy += k; else sx += k;
					if (sx < 0) sx = 0; if (sx >= IW) sx = IW - 1;
					if (sy < 0) sy = 0; if (sy >= IH) sy = IH - 1;
					const si = (sy * IW + sx) * 4;
					ar += src[si]; ag += src[si + 1]; ab += src[si + 2]; aa += src[si + 3];
				}
				const di = (y * IW + x) * 4;
				this.d[di] = ar / win; this.d[di + 1] = ag / win;
				this.d[di + 2] = ab / win; this.d[di + 3] = aa / win;
			}
		}
	}

	/** 放大到全分辨率：最近邻 + 半径 1 箱模糊，this.d 换成全分辨率缓冲 */
	finish() {
		const up = Buffer.alloc(W * H * 4);
		for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
			const si = (((y / S) | 0) * IW + ((x / S) | 0)) * 4;
			const di = (y * W + x) * 4;
			up[di] = this.d[si]; up[di + 1] = this.d[si + 1];
			up[di + 2] = this.d[si + 2]; up[di + 3] = this.d[si + 3];
		}
		const src = Buffer.from(up);
		for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
			let ar = 0, ag = 0, ab = 0, aa = 0, n = 0;
			for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
				let sx = x + dx, sy = y + dy;
				if (sx < 0) sx = 0; if (sx >= W) sx = W - 1;
				if (sy < 0) sy = 0; if (sy >= H) sy = H - 1;
				const si = (sy * W + sx) * 4;
				ar += src[si]; ag += src[si + 1]; ab += src[si + 2]; aa += src[si + 3]; n++;
			}
			const di = (y * W + x) * 4;
			up[di] = ar / n; up[di + 1] = ag / n; up[di + 2] = ab / n; up[di + 3] = aa / n;
		}
		this.d = up;
	}
}

/* ---------------- 噪声 ---------------- */

function h2(x, y, seed) {
	let h = (x * 374761393 + y * 668265263 + seed * 1442695040) | 0;
	h = Math.imul(h ^ (h >>> 13), 1274126177);
	return ((h ^ (h >>> 16)) >>> 0) / 4294967295;
}
function snoise(x, y, seed) {
	const xi = Math.floor(x), yi = Math.floor(y);
	const xf = x - xi, yf = y - yi;
	const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
	const a = h2(xi, yi, seed), b = h2(xi + 1, yi, seed);
	const c = h2(xi, yi + 1, seed), d = h2(xi + 1, yi + 1, seed);
	return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
}

/* ---------------- 水墨构件 ---------------- */

const INK = [26, 24, 20];

/** 一道山脊：baseY 为山脚，amp 为高度；山脊线最浓，向下淡到 0（不留硬底边）。
    直接在缓冲网格上遍历，每个缓冲像素只画一次（全分辨率行/列两两重合会叠 alpha） */
function ridge(L, baseY, amp, scale, seed, tone = INK, a = 0.5) {
	for (let bx = 0; bx < IW; bx++) {
		const x = bx * S;
		const n = snoise(x / scale, 0, seed) * 0.7 + snoise(x / (scale * 0.23), 3, seed) * 0.3;
		const top = (baseY - n * amp) | 0;
		for (let y = top; y < baseY; y += S) {
			const t = (y - top) / Math.max(1, baseY - top);
			L.put(x, y, tone, a * Math.pow(1 - t, 1.25));
		}
		L.put(x, top, tone, a * 1.1); // 山脊线
	}
}

function smooth01(t) { return t * t * (3 - 2 * t); }

/** 翘角瓦顶（剪影），中心 (cx, cy) */
function tileRoof(L, cx, cy, w, h, c, a) {
	// 屋脊主体
	for (let x = -w / 2; x <= w / 2; x++) {
		const t = Math.abs(x) / (w / 2);
		const yy = cy - Math.pow(t, 2.2) * 6;
		L.rect(cx + x, yy, 1, h, c, a);
	}
	// 翘角
	for (let k = 0; k < 8; k++) {
		L.put(cx - w / 2 - k, cy - k - 2, c, a);
		L.put(cx + w / 2 + k, cy - k - 2, c, a);
	}
	// 瓦垄
	for (let x = -w / 2 + 8; x < w / 2 - 8; x += 14)
		L.rect(cx + x, cy + 2, 1, h - 2, [c[0] - 8, c[1] - 8, c[2] - 8], a * 0.6);
}

/** 城楼（城墙 + 楼），x 为左缘 */
function gateTower(L, x, yBase, w, wallH, c, a) {
	// 墙身
	L.rect(x, yBase - wallH, w, wallH, c, a);
	// 垛口
	for (let xx = x + 6; xx < x + w - 8; xx += 22)
		L.rect(xx, yBase - wallH - 7, 12, 7, c, a);
	// 楼
	const cx = x + w / 2;
	tileRoof(L, cx, yBase - wallH - 10, w * 0.72, 12, c, a * 0.95);
	L.rect(cx - w * 0.3, yBase - wallH - 24, w * 0.6, 14, c, a * 0.85);
	tileRoof(L, cx, yBase - wallH - 28, w * 0.5, 10, c, a * 0.9);
}

/** 一棵树：干 + 点叶墨团 */
function inkTree(L, x, y, scale, c, a, leaf = true) {
	L.stroke(x, y, x + 4 * scale, y - 30 * scale, 3 * scale, c, a);
	L.stroke(x + 2 * scale, y - 16 * scale, x - 10 * scale, y - 34 * scale, 2 * scale, c, a * 0.8);
	L.stroke(x + 2 * scale, y - 18 * scale, x + 12 * scale, y - 36 * scale, 2 * scale, c, a * 0.8);
	if (leaf)
		for (let i = 0; i < 26; i++) {
			const px = x + (snoise(i, 1, 5) - 0.5) * 44 * scale;
			const py = y - 34 * scale + (snoise(i, 7, 5) - 0.5) * 22 * scale;
			L.disc(px, py, 5 * scale, c, a * 0.5);
		}
}

/** 远屋顶排（民居剪影） */
function farHouses(L, y, xs, c, a) {
	for (const x of xs) {
		tileRoof(L, x, y, 70, 8, c, a);
		L.rect(x - 30, y + 8, 60, 12, c, a * 0.8);
	}
}

/* ============================================================
   十二幅 + 通用（无房间的呈现场景）
   ============================================================ */

function P(paper, L, seed) {}

/* 一片竹叶：沿二次弧扫一串渐细的墨点 */
function leaf(L, x, y, ang, len, c, a) {
	const n = Math.max(2, Math.ceil(len / S));
	for (let i = 1; i <= n; i++) {
		const t = i / n;
		const px = x + Math.cos(ang) * len * t;
		const py = y + Math.sin(ang) * len * t + 7 * t * t;   // 叶尖微微下垂
		L.disc(px, py, Math.max(0.4, (1 - t) * 4), c, a);
	}
}

/* 广和茶楼：窗外 —— 一丛竹（左）+ 远屋顶 */
function ink_tea(L) {
	ridge(L, 470, 110, 420, 2, [70, 66, 58], 0.38);
	farHousesBig(L, 420, [330, 500, 680, 860], [55, 52, 46], 0.55);
	// 近处竹
	const bc = [44, 52, 38];
	for (let i = 0; i < 3; i++) {
		const x = 100 + i * 36, top = 200 + (i - 1) * 26;
		L.stroke(x, 660, x + 14, top, 6, bc, 0.72);
		// 竹节（短横）
		for (let k = 1; k <= 4; k++) {
			const t = k / 5;
			const px = x + 14 * t, py = 660 + (top - 660) * t;
			L.stroke(px - 5, py, px + 8, py, 2, [28, 34, 24], 0.8);
		}
		// 叶簇（上、中）
		for (const t of [0.28, 0.42, 0.58]) {
			const px = x + 14 * t, py = 660 + (top - 660) * t;
			for (let d = -1; d <= 2; d++)
				leaf(L, px, py, 0.25 + d * 0.32 + i * 0.12, 40 + (i === 0 ? 10 : 0), bc, 0.66);
		}
	}
}

/* 宣武街：远城楼 + 两侧铺面 + 枯树 */
function sideHouse(L, cx) {
	tileRoof(L, cx, 390, 360, 22, [40, 38, 34], 0.62);
	L.rect(cx - 170, 392, 340, 104, [40, 38, 34], 0.52);
	L.rect(cx - 30, 436, 60, 60, [18, 16, 12], 0.7);   // 铺门板
	for (const dx of [-150, 150])
		L.rect(cx + dx - 3, 392, 6, 104, [30, 28, 24], 0.6); // 檐柱
}
function ink_xuanwu(L) {
	ridge(L, 400, 80, 500, 4, [80, 78, 72], 0.28);
	gateTower(L, 620, 420, 200, 66, [52, 50, 46], 0.62);
	sideHouse(L, 240);
	sideHouse(L, 1200);
	inkTree(L, 1150, 580, 1.6, [36, 34, 30], 0.6, false);
}

/* 塔柏：一柱瘦墨，墨团自下而上渐细 —— 祠庙里的古柏该是这个形，
   不能拿点叶阔叶树凑（第一版画成了四根豆芽） */
function cypress(L, x, yBase, h, c, a) {
	const top = x - h * 0.05;
	L.stroke(x, yBase, top, yBase - h, 3, c, a * 0.8);
	// 密叠的墨团柱：间距必须明显小于直径，否则散成糖葫芦（第一版十颗大珠的教训）
	const n = 20;
	for (let i = 0; i < n; i++) {
		const t = i / (n - 1);                     // 0 = 根, 1 = 梢
		const yy = yBase - h * 0.9 * t;
		const jx = (snoise(i, x | 0, 7) - 0.5) * 6;
		const r = h * 0.14 - h * 0.095 * t;
		L.disc(x - h * 0.05 * t + jx, yy, r, c, a * (0.5 - 0.2 * t));
	}
}

/* 檐下悬的白绢：白幅 + 木轴 + 淡墨竖行，远看是血书那个意思 */
function whiteSilk(L, x, y, w, h) {
	L.rect(x, y, w, h, [226, 222, 206], 0.82);
	for (let i = 0; i < 3; i++)
		L.rect(x + 15 + i * 20, y + 14, 2, h - 30, [60, 56, 48], 0.3);
	L.rect(x - 4, y + h - 7, w + 8, 8, [90, 66, 40], 0.7);
}

/* 杨椒山祠：重檐山门 + 白绢 + 古柏 */
function ink_ci(L) {
	tileRoof(L, 720, 246, 540, 26, [38, 36, 32], 0.68);
	tileRoof(L, 720, 296, 450, 14, [38, 36, 32], 0.6);
	L.rect(495, 298, 450, 124, [38, 36, 32], 0.34);
	L.rect(680, 330, 82, 92, [16, 14, 10], 0.8);    // 门洞
	whiteSilk(L, 556, 306, 72, 108);
	whiteSilk(L, 812, 306, 72, 108);
	cypress(L, 350, 590, 250, [24, 32, 22], 0.72);
	cypress(L, 1090, 590, 240, [24, 32, 22], 0.72);
	cypress(L, 465, 580, 175, [34, 42, 30], 0.5);
	cypress(L, 975, 580, 168, [34, 42, 30], 0.5);
}

/* 悦来客栈：夜月疏枝 */
function ink_ke(L) {
	L.disc(1080, 160, 48, [226, 220, 198], 0.55);
	L.disc(1064, 146, 48, [20, 22, 30], 0.9);
	L.stroke(260, 600, 330, 280, 4, [22, 24, 22], 0.72);
	L.stroke(300, 400, 190, 310, 2, [22, 24, 22], 0.66);
	L.stroke(310, 360, 410, 300, 2, [22, 24, 22], 0.66);
	ridge(L, 470, 80, 600, 9, [24, 26, 30], 0.5);
}

/* 都察院：大门 + 阶 + 狮 */
function ink_gongche(L) {
	gateTower(L, 540, 420, 360, 104, [40, 38, 34], 0.66);
	// 大门内洞
	L.rect(660, 330, 120, 90, [14, 12, 10], 0.85);
	// 狮
	for (const x of [560, 880]) {
		L.disc(x, 470, 20, [34, 32, 28], 0.72);
		L.rect(x - 26, 486, 52, 13, [34, 32, 28], 0.6);
	}
}

/* 湖南会馆：正厅 + 左右回廊 + 老槐 */
function ink_hunan(L) {
	tileRoof(L, 700, 276, 470, 24, [42, 40, 36], 0.6);
	L.rect(510, 278, 380, 126, [42, 40, 36], 0.32);  // 厅墙（原来没有，屋顶像悬空）
	L.rect(670, 322, 62, 82, [16, 14, 10], 0.72);    // 厅门
	for (const x0 of [60, 1120]) {                    // 回廊：檐 + 横梁 + 柱
		tileRoof(L, x0 + 130, 336, 280, 14, [42, 40, 36], 0.5);
		L.rect(x0, 348, 260, 10, [42, 40, 36], 0.42);
		for (let k = 0; k < 4; k++)
			L.rect(x0 + 22 + k * 72, 346, 5, 66, [42, 40, 36], 0.42);
	}
	inkTree(L, 1050, 566, 2.1, [26, 38, 24], 0.6);
}

/* 永定门：城墙 + 远山 + 黄昏天光（暖调靠纸色，墨只画轮廓） */
function ink_yongding(L) {
	ridge(L, 280, 64, 700, 12, [90, 86, 78], 0.4);
	gateTower(L, 460, 440, 520, 140, [48, 44, 38], 0.7);
	L.rect(640, 310, 160, 130, [12, 10, 8], 0.9);   // 城门洞
	// 枯柳
	for (const x of [260, 1180]) {
		L.stroke(x, 560, x + 10, 400, 4, [50, 44, 34], 0.6);
		L.stroke(x + 8, 430, x - 30, 380, 2, [50, 44, 34], 0.55);
	}
}

/* 上海码头：雾江 + 帆樯 + 烟囱 */
function ink_shanghai(L) {
	ridge(L, 370, 80, 800, 14, [70, 76, 78], 0.34);
	// 货栈（远）
	farHousesBig(L, 360, [180, 320], [40, 38, 34], 0.55);
	// 帆船（左）：帆只勾轮廓不填白
	L.rect(390, 470, 170, 24, [34, 32, 28], 0.68);
	L.stroke(466, 470, 466, 290, 3, INK, 0.7);
	L.rect(430, 300, 76, 168, [196, 186, 158], 0.14);
	L.stroke(466, 470, 424, 296, 2, INK, 0.62);
	L.stroke(466, 470, 512, 296, 2, INK, 0.62);
	L.stroke(424, 296, 512, 296, 2, INK, 0.62);
	for (let yy = 330; yy < 460; yy += 26)
		L.stroke(430 + (466 - 430) * (1 - (yy - 300) / 170), yy, 466 + 46 * (yy - 300) / 170, yy, 1.5, INK, 0.42);
	// 轮船（右）
	L.rect(820, 452, 220, 38, [28, 30, 34], 0.72);
	L.rect(876, 330, 28, 122, [22, 22, 26], 0.75);      // 烟囱
	for (let k = 0; k < 4; k++)
		L.disc(912 + k * 26, 306 - k * 12, 16 - k * 2, [90, 92, 94], 0.3 - k * 0.05);
	// 水纹
	for (let k = 0; k < 8; k++) {
		const x = 300 + k * 110, y = 510 + ((k * 53) % 20);
		L.stroke(x, y, x + 50, y, 1.5, [50, 50, 48], 0.3);
	}
}

/* 老宅：旧门 + 屋檐 + 旗杆 */
function ink_oldhouse(L) {
	tileRoof(L, 720, 250, 560, 26, [42, 38, 32], 0.62);
	L.rect(440, 250, 560, 180, [42, 38, 32], 0.34);
	L.rect(690, 310, 60, 120, [16, 14, 10], 0.8);      // 门
	latticeSil(L, 540, 310, 90, 64); latticeSil(L, 810, 310, 90, 64);
	// 旗杆 + 褪了色的小旗（光一根杆看着像误画的线）
	L.stroke(300, 560, 300, 214, 3, [36, 32, 26], 0.62);
	for (let k = 0; k <= 28; k += 2)
		L.rect(302, 222 + k, 36 - k * 0.7, 2, [120, 56, 42], 0.5);
}
function latticeSil(L, x, y, w, h) {
	L.rect(x, y, w, h, [20, 18, 14], 0.35);
	for (let i = 8; i < w; i += 12) L.rect(x + i, y, 2, h, [20, 18, 14], 0.5);
	for (let j = 10; j < h; j += 16) L.rect(x, y + j, w, 2, [20, 18, 14], 0.5);
}

/* 田庄：层田 + 远山 + 牛 */
function ink_farm(L) {
	ridge(L, 260, 90, 700, 11, [70, 80, 76], 0.42);
	// 层叠田埂线
	for (let k = 0; k < 5; k++) {
		const y = 330 + k * 44;
		for (let x = 80; x < W - 80; x += 10)
			L.put(x, y + (snoise(x / 60, k, 6) - 0.5) * 14, [40, 44, 40], 0.3 + k * 0.06);
	}
	// 牛
	L.disc(330, 540, 30, [26, 25, 22], 0.72);
	L.disc(298, 522, 13, [26, 25, 22], 0.72);
}

/* 书房：大留白 —— 一窗、一悬轴（轴上淡墨兰草） */
function ink_study(L) {
	// 悬轴：绫边 + 木轴
	L.rect(236, 146, 58, 228, [110, 86, 56], 0.55);
	L.rect(242, 156, 46, 208, [226, 216, 192], 0.85);
	L.rect(232, 144, 66, 8, [120, 90, 50], 0.7);
	L.rect(232, 368, 66, 8, [120, 90, 50], 0.7);
	// 轴心一丛兰：数片向上挑的淡墨叶
	const ox = 265, oy = 344, ic = [76, 80, 70];
	for (const [ang, len, aa] of [[-1.65, 96, 0.42], [-1.35, 110, 0.46], [-1.05, 88, 0.4], [-0.7, 64, 0.34], [-2.0, 60, 0.32]])
		leaf(L, ox, oy, ang, len, ic, aa);
	L.stroke(ox, oy, ox - 2, oy - 40, 1.5, ic, 0.4);
	// 窗影
	L.rect(1000, 170, 260, 190, [30, 34, 30], 0.22);
	for (let i = 20; i < 260; i += 26) L.rect(1000 + i, 170, 3, 190, [30, 34, 30], 0.3);
	for (let j = 24; j < 190; j += 34) L.rect(1000, 170 + j, 260, 3, [30, 34, 30], 0.3);
}

/* 陈宅花厅：屏风 + 对正屋顶的花厅墙身 + 格扇门 */
function ink_chendi(L) {
	// 屏风（左）
	L.rect(230, 180, 130, 300, [36, 28, 22], 0.4);
	for (let i = 12; i < 130; i += 22) L.rect(230 + i, 180, 3, 300, [36, 28, 22], 0.48);
	// 花厅正堂（墙必须坐在屋顶下：第一版墙偏到屋脊右边，看着像屋顶悬空）
	tileRoof(L, 770, 250, 560, 26, [40, 32, 26], 0.6);
	L.rect(520, 252, 500, 150, [40, 32, 26], 0.3);
	for (let i = 0; i < 4; i++)
		latticeSil(L, 560 + i * 112, 300, 84, 90);
}

/* 通用暗墨（题记/书信等无房间呈现场景） */
function ink_dark(L) {
	ridge(L, 440, 120, 600, 6, [30, 30, 34], 0.5);
	ridge(L, 540, 100, 420, 9, [26, 26, 30], 0.58);
}

/* 远屋顶排（民居剪影），放大一号 */
function farHousesBig(L, y, xs, c, a) {
	for (const x of xs) {
		tileRoof(L, x, y, 120, 10, c, a);
		L.rect(x - 52, y + 10, 104, 18, c, a * 0.82);
	}
}

const PIECES = {
	r_tea: ink_tea,
	r_xuanwu: ink_xuanwu,
	r_ci: ink_ci,
	r_ke: ink_ke,
	r_gongche: ink_gongche,
	r_hunan: ink_hunan,
	r_yongding: ink_yongding,
	r_shanghai: ink_shanghai,
	r_oldhouse: ink_oldhouse,
	r_farm: ink_farm,
	r_study: ink_study,
	r_chendi: ink_chendi,
	dark: ink_dark,
};

/* ============================================================
   合成：宣纸 → 墨层 → 雾 → 薄面纱 → 输出
   ============================================================ */

/** 雾带直接画在成品上：横向均匀，纵向平滑淡入淡出（不碰墨层，不拖脏） */
function mistOn(out, cy, h, a, paper) {
	for (let y = cy - h; y <= cy + h; y++) {
		if (y < 0 || y >= H) continue;
		const t = 1 - Math.abs(y - cy) / h;
		const aa = a * smooth01(t);
		for (let x = 0; x < W; x++) out.blend(x, y, paper[0], paper[1], paper[2], aa);
	}
}

function render(id) {
	const L = new Layer();
	PIECES[id](L);

	// 淡墨渲染：低分辨率缓冲上两遍半径 1 模糊，再放大（finish 里还带一次柔化）
	L.blur(1);
	L.blur(1, true);
	L.finish();

	// 宣纸底
	const out = new Canvas(W, H);
	const paper = [236, 226, 200];
	out.fill(paper[0], paper[1], paper[2]);
	// 纸纤维/纸色不均
	for (let y = 0; y < H; y += 2) for (let x = 0; x < W; x += 2) {
		const n = h2(x, y, 99);
		if (n > 0.75) out.blend(x, y, paper[0] - 10, paper[1] - 8, paper[2] - 6, 0.25);
	}

	// 墨层合上去
	for (let i = 0; i < W * H; i++) {
		const a = L.d[i * 4 + 3] / 255;
		if (a > 0.004)
			out.blend(i % W, (i / W) | 0, L.d[i * 4], L.d[i * 4 + 1], L.d[i * 4 + 2], a);
	}

	// 两条雾（在墨之上）
	mistOn(out, 330, 70, 0.22, paper);
	mistOn(out, 520, 50, 0.14, paper);

	// 中央柔光面纱：椭圆衰减，没有硬边，保证文字区可读
	const cx = W / 2, cy = H * 0.46, rx = W * 0.42, ry = H * 0.42;
	for (let y = 0; y < H; y += 1) for (let x = 0; x < W; x += 1) {
		const d = Math.hypot((x - cx) / rx, (y - cy) / ry);
		if (d < 1) out.blend(x, y, 244, 236, 216, 0.14 * Math.pow(1 - d, 1.4));
	}

	if (id === "dark") {
		// 暗场：整幅压成夜
		for (let i = 0; i < out.data.length; i += 4) {
			out.data[i] *= 0.35; out.data[i + 1] *= 0.35; out.data[i + 2] *= 0.38;
		}
	}

	const dir = path.join(__dirname, "..", "art", "ink");
	fs.mkdirSync(dir, { recursive: true });
	const file = path.join(dir, id + ".png");
	writePNG(file, out);
	return { file, size: fs.statSync(file).size };
}

function main() {
	const ids = process.argv.slice(2).filter((x) => PIECES[x]);
	const list = ids.length ? ids : Object.keys(PIECES);
	for (const id of list) {
		const r = render(id);
		console.log("✓", id, r.size.toLocaleString(), "bytes");
	}
}

main();
