/* ============================================================
   像素行走图生成器 —— 读 tools/sprites.json 的颜色网格，出 PNG

   为什么不用 AI 生成：图像模型画不出前后一致的四向行走序列，
   三帧之间衣服会变、脸会变、身高会变。而像素画本来就是从颜色网格
   直接长出来的东西，手写网格反而可控。

   网格格式：每行一个字符串，每个字符是一个调色板键，"." 是透明。
   严格校验 —— 行宽不对、行数不对、用了没定义的键，一律当场报错。
   手写的网格一定会数错，靠肉眼查是查不过来的，必须让机器查。

   用法：
     node tools/gen_sprites.js --check     只校验网格，不出图
     node tools/gen_sprites.js             出图到 art/walk/
     node tools/gen_sprites.js --only shen
     node tools/gen_sprites.js --scale 6   改放大倍数（默认 4）
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");
const { writePNG, Canvas } = require("./png.js");

const ROOT = path.resolve(__dirname, "..");
const SRC = path.join(__dirname, "sprites.json");
const OUT = path.join(ROOT, "art", "walk");

const DIRS = ["down", "up", "left", "right"];
const FRAMES = 3;

/* ---------------------- 调色板 ---------------------- */

/* 收 #RRGGBB 和 #RRGGBBAA 两种写法。透明色要能写出来，
   否则调色板里没法给「.」留一个名分。 */
function parseHex(s) {
	const m = /^#?([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(s.trim());
	if (!m) throw new Error("颜色写错了：" + s);
	const n = parseInt(m[1], 16);
	return [(n >> 16) & 255, (n >> 8) & 255, n & 255, m[2] ? parseInt(m[2], 16) : 255];
}

/* ---------------------- 网格校验 ---------------------- */

function checkGrid(rows, w, h, palette, where) {
	if (!Array.isArray(rows)) throw new Error(where + "：不是数组");
	if (rows.length !== h) throw new Error(where + "：有 " + rows.length + " 行，应该是 " + h + " 行");
	rows.forEach((r, y) => {
		if (typeof r !== "string") throw new Error(where + " 第 " + y + " 行不是字符串");
		if (r.length !== w) throw new Error(where + " 第 " + y + " 行有 " + r.length + " 个字符，应该是 " + w + " 个\n    " + r);
		for (const ch of r) {
			if (ch === ".") continue;
			if (!(ch in palette)) throw new Error(where + " 第 " + y + " 行用了调色板里没有的键「" + ch + "」");
		}
	});
}

/* ---------------------- 画 ---------------------- */

/* 直接写 canvas.data，不走 blend。
   像素画要的是硬边 —— 一旦混色就会出现半透明的脏边，
   放大 4 倍以后那些脏边全变成灰点。 */
function setPx(c, x, y, px) {
	if (x < 0 || y < 0 || x >= c.width || y >= c.height) return;
	const i = (y * c.width + x) * 4;
	c.data[i] = px[0]; c.data[i + 1] = px[1]; c.data[i + 2] = px[2]; c.data[i + 3] = px[3];
}

function getPx(c, x, y) {
	const i = (y * c.width + x) * 4;
	return [c.data[i], c.data[i + 1], c.data[i + 2], c.data[i + 3]];
}

function blit(rows, palette, canvas, ox, oy) {
	for (let y = 0; y < rows.length; y++) {
		const row = rows[y];
		for (let x = 0; x < row.length; x++) {
			const ch = row[x];
			if (ch === ".") continue;
			const c = palette[ch];
			if (!c) continue;
			setPx(canvas, ox + x, oy + y, c);
		}
	}
}

const mirrorRows = (rows) => rows.map((r) => [...r].reverse().join(""));

/* 最近邻整数放大。**必须**是整数倍 —— 非整数倍会把像素糊掉，
   像素画一糊就不是像素画了。 */
function upscale(canvas, k) {
	const out = new Canvas(canvas.width * k, canvas.height * k);
	for (let y = 0; y < canvas.height; y++) {
		for (let x = 0; x < canvas.width; x++) {
			const c = getPx(canvas, x, y);
			if (c[3] === 0) continue;
			for (let dy = 0; dy < k; dy++) for (let dx = 0; dx < k; dx++) setPx(out, x * k + dx, y * k + dy, c);
		}
	}
	return out;
}

/* 一帧 = 身体（上 26 行）+ 腿（下 6 行），整体按 bob 上移。
   抬起来那一帧（passing pose）整个小人上移 1 像素 —— 这是三帧行走
   里唯一能让人「看出在动」的廉价手段。 */
function renderFrame(body, legs, palette, W, H, bob) {
	const c = new Canvas(W, H);
	blit(body, palette, c, 0, -bob);
	blit(legs, palette, c, 0, H - legs.length - bob);
	return c;
}

/* ---------------------- 主流程 ---------------------- */

function main() {
	const argv = process.argv.slice(2);
	const onlyCheck = argv.includes("--check");
	const only = (() => { const i = argv.indexOf("--only"); return i >= 0 ? argv[i + 1] : null; })();
	const si = argv.indexOf("--scale");
	const scale = si >= 0 ? parseInt(argv[si + 1], 10) : null;

	const spec = JSON.parse(fs.readFileSync(SRC, "utf8"));
	const W = spec.grid.w, H = spec.grid.h;
	const bodyH = spec.grid.body_h;
	const legH = H - bodyH;
	const k = scale || spec.scale || 4;

	if (!Number.isInteger(k) || k < 1) throw new Error("放大倍数必须是正整数，收到 " + k);

	let nChk = 0, nPng = 0;
	const problems = [];

	for (const [cid, ch] of Object.entries(spec.characters)) {
		if (only && cid !== only) continue;

		const palette = {};
		for (const [key, hex] of Object.entries(ch.palette)) palette[key] = parseHex(hex);

		// 先把 left 画好，right 直接镜像 —— 省一半手工，也保证左右一致
		const byDir = {};
		for (const d of DIRS) {
			const src = d === "right" ? ch.dirs.left : ch.dirs[d];
			if (!src) throw new Error(cid + " 缺方向 " + d);
			const dir = {};
			for (const part of ["body", "legs"]) {
				const v = src[part];
				if (!v) throw new Error(cid + "." + d + " 缺 " + part);
				dir[part] = d === "right"
					? (part === "body" ? mirrorRows(v) : v.map(mirrorRows))
					: v;
			}
			byDir[d] = dir;
		}

		/* --- 校验 --- */
		for (const d of DIRS) {
			const where = cid + "." + d;
			try {
				checkGrid(byDir[d].body, W, bodyH, palette, where + ".body");
				if (byDir[d].legs.length !== FRAMES) {
					throw new Error(where + ".legs 有 " + byDir[d].legs.length + " 组，应该是 " + FRAMES + " 组");
				}
				byDir[d].legs.forEach((l, i) => checkGrid(l, W, legH, palette, where + ".legs[" + i + "]"));
				nChk++;
			} catch (e) { problems.push(e.message); }
		}

		if (onlyCheck || problems.length) continue;

		/* --- 出图 --- */
		const sheet = new Canvas(W * FRAMES, H * DIRS.length);
		DIRS.forEach((d, di) => {
			for (let f = 0; f < FRAMES; f++) {
				const bob = f === 1 ? 1 : 0;
				const c = renderFrame(byDir[d].body, byDir[d].legs[f], palette, W, H, bob);

				const file = path.join(OUT, cid + "_" + d + "_" + f + ".png");
				writePNG(file, upscale(c, k));
				nPng++;

				// 拼一张总览图，方便肉眼验收
				for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
					const px = getPx(c, x, y);
					if (px[3] !== 0) setPx(sheet, f * W + x, di * H + y, px);
				}
			}
		});
		writePNG(path.join(OUT, cid + "_sheet.png"), upscale(sheet, k));
		console.log(cid + "（" + ch.name + "）：4 向 × 3 帧 = 12 帧，" + (W * k) + "×" + (H * k) + " 像素");
	}

	if (problems.length) {
		console.error("\n网格有问题，一张都没出：\n");
		for (const p of problems) console.error("  ✗ " + p);
		process.exit(1);
	}

	if (onlyCheck) console.log("\n✓ 网格全部合格（" + nChk + " 组）。");
	else console.log("\n出了 " + nPng + " 张，在 art/walk/。");
}

if (require.main === module) {
	try { main(); } catch (e) { console.error("✗ " + (e.message || e)); process.exit(1); }
}
