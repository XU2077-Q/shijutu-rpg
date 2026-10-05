/* ============================================================
   立绘去水印 + 降采样

   豆包出的 15 张立绘右下角都有一行「豆包 AI 生成」。这是要上架的游戏，
   不能带着别人家的水印发出去。

   ------------------------------------------------------------
   先量清楚，再动手。逐张扫出来的事实：

   · 水印位置一致：265×61 的方块，距右 38px、距下 33px。
     （15 张的「框内暗像素」都在 3200~4800，说明这个锚点全中。）

   · 水印**不是黑墨**，是**白字 + 淡描边**。实测笔画最暗只到 150~171，
     而纸底在 215~250。也就是说水印是一层**低对比**的半透明覆盖，
     不是能靠「找黑点」抠掉的东西。

   · 真笔触暗得多（黑墨 40~80）。所以 130 这个坎能把
     「水印」和「画」干净地分开 —— 这是整套做法的支点。

   ------------------------------------------------------------
   做法：不找「干净纸块」，改用**从框的四周往内插值**。

   一开始试的是「从上方挪一块干净纸盖上去」，15 张里 8 张找不到 ——
   因为纸的明暗逐张不同（165~235 都有），固定阈值根本判不准「干不干净」。
   更要命的是 湖南蒙学先生：画里的手杖**斜穿过水印框**，
   附近根本没有一块不含笔触的矩形。硬盖就会把手杖削断。

   改成 Coons 曲面插值：取框的上下左右四条边（每条边遇画就让开、
   继续往外找最近的纸），再按双线性把它们缝成一个曲面填进去。
   · 纸是平滑的，所以插值出来的和真的几乎一样，四边天然对齐、无缝。
   · 不用搜索、不用阈值判断「干净」，对那 8 张和 湖南蒙学先生 一视同仁。

   再加一层**护画遮罩**：框内本来就暗于 130 的像素（真笔触）原样保留。
   所以 湖南蒙学先生 穿过来的手杖**不会被抹掉**，只抹掉压在它上面的水印。

   ------------------------------------------------------------
   降采样：原图 1696×2576、每张 5~6 MB。压到高 1280（约 843×1280），
   面积平均（box filter）—— 缩小时比最近邻干净得多。

   用法：node tools/dewatermark.js
         node tools/dewatermark.js --dry    只报告，不写文件
         node tools/dewatermark.js --qa     另存右下角前后对照图，供肉眼复核
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");
const { readPNG } = require("./png_read.js");
const { writePNG, Canvas } = require("./png.js");

const ROOT = path.resolve(__dirname, "..");
const SRC_DIR = "C:/Users/Lenovo/Desktop/时局图图片生成/";
const OUT_DIR = path.join(ROOT, "art", "portraits");

/* 实测的水印几何。换模型或换尺寸就得重新量。 */
const WM = { w: 265, h: 61, right: 38, bottom: 33 };
const PAD = 16;          // 往外多盖一圈，吃掉描边的抗锯齿
const TARGET_H = 1280;

/* 明暗三档 —— 这三个数是量出来的，别凭感觉改：
   < 130      真笔触（黑墨实测 40~80）
   130~150    水印描边与笔触的抗锯齿过渡带
   ≥ 150      纸（实测干净纸面最低 163，留了余量） */
const ART_LUM = 130;
const MASK_RAMP = 20;
const PAPER_OK = 150;

/* 「这里有没有水印」的判据：框内暗于 200 的像素数。
   实测有水印的都在 3200 以上，纯纸纹远低于此。 */
const INK_LUM = 200;
const INK_MIN_COUNT = 1500;

/* 原文件名 → 游戏里的 id。原名带括号和长注解，不能直接当资源名。 */
const MAP = [
	["沈怀瑾.png", "shen_huaijin", "沈怀瑾"],
	["林婉如.png", "lin_wanru", "林婉如"],
	["沈鹤龄.png", "shen_heling", "沈鹤龄"],
	["黎景明.png", "li_jingming", "黎景明"],
	["黎景高.png", "li_jinggao", "黎景高"],
	["佃农何伯.png", "he_bo", "佃农何伯"],
	["湖南蒙学先生.png", "mengxue_xiansheng", "湖南蒙学先生"],
	["守门士兵.png", "gate_soldier", "守门士兵"],
	["顺子（茶楼跑堂）.png", "shunzi", "顺子（茶楼跑堂）"],
	["报童小满.png", "xiaoman", "报童小满"],
	["豆腐老倌.png", "doufu_laoguan", "豆腐老倌"],
	["阿巧（带着弟弟和祖父相依为命，后来成为大生纱厂女工）.png", "a_qiao", "阿巧"],
	["林家洋行职员.png", "lin_clerk", "林家洋行职员"],
	["台湾母子.png", "taiwan_mother", "台湾母子"],
	["日本士兵.png", "jp_soldier", "日本士兵"],
];

const DRY = process.argv.includes("--dry");
const QA = process.argv.includes("--qa");
const FORCE = process.argv.includes("--force");   // 校验不过也照写，只为把图拿出来看

const lum = (b, i) => (b[i] * 299 + b[i + 1] * 587 + b[i + 2] * 114) / 1000;

function smoothstep(a, b, x) {
	const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
	return t * t * (3 - 2 * t);
}


/* ---------------------- 读进缓冲区 ---------------------- */
/* readPNG 只暴露逐像素的 at()，是闭包调用。一张 440 万像素、还要扫好几遍，
   直接用会慢得难受。先摊平进 Uint8Array，后面全在缓冲区上跑。 */

function toBuffer(img) {
	const buf = new Uint8Array(img.w * img.h * 4);
	for (let y = 0; y < img.h; y++) {
		for (let x = 0; x < img.w; x++) {
			const p = img.at(x, y);
			const i = (y * img.w + x) * 4;
			buf[i] = p[0]; buf[i + 1] = p[1]; buf[i + 2] = p[2]; buf[i + 3] = p[3];
		}
	}
	return buf;
}

function watermarkBox(w, h) {
	return {
		x0: w - WM.right - WM.w - PAD,
		y0: h - WM.bottom - WM.h - PAD,
		x1: w - WM.right + PAD,
		y1: h - WM.bottom + PAD,
	};
}

/** 框内暗于 lim 的像素数 */
function darkCount(buf, w, box, lim) {
	let n = 0;
	for (let y = box.y0; y < box.y1; y++) {
		for (let x = box.x0; x < box.x1; x++) {
			if (lum(buf, (y * w + x) * 4) < lim) n++;
		}
	}
	return n;
}

/** 框内亮于 lim 的像素数 —— 用来抓水印的白字填充（它比纸还亮） */
function brightCount(buf, w, box, lim) {
	let n = 0;
	for (let y = box.y0; y < box.y1; y++) {
		for (let x = box.x0; x < box.x1; x++) {
			if (lum(buf, (y * w + x) * 4) > lim) n++;
		}
	}
	return n;
}


/* ---------------------- 填 ---------------------- */

/** 全图纸面基准亮度：取图像外圈 8px 的中位数。
    外圈几乎总是纸（立绘的人物都在中间），比任何固定阈值都稳。
    纸的明暗逐张不同（实测 165~235 都有），所以「什么算纸」必须逐张定，
    不能用写死的数 —— 这正是第一版 8 张找不到样本块的原因。 */
function paperLevel(buf, W, H) {
	const v = [];
	const push = (x, y) => v.push(lum(buf, (y * W + x) * 4));
	for (let x = 0; x < W; x += 3) { for (let d = 0; d < 8; d++) { push(x, d); push(x, H - 1 - d); } }
	for (let y = 0; y < H; y += 3) { for (let d = 0; d < 8; d++) { push(d, y); push(W - 1 - d, y); } }
	v.sort((a, b) => a - b);
	return v[v.length >> 1];
}

/** 在框附近找若干块「最像纸」的等大矩形当样本，按干净程度排序。
    必须整块不重叠（否则会把水印自己复制进来）。
    打分 = 样本里非纸像素的占比，越低越好；同分取离框最近的
    （近处的纸纹和明暗最接近）。

    返回的是一**组**而不是一块 —— 因为单块样本难免有地方被画压住，
    多备几块就能逐像素挑第一个干净的，不必退化成「整列取中位数」
    （那样每列一个常数，会留下竖条纹）。 */
function pickSources(buf, W, box, contamLim, K = 10) {
	const bw = box.x1 - box.x0, bh = box.y1 - box.y0;
	const cands = [];
	for (let dy = -bh; dy >= -bh - 700; dy -= 20) {
		const sy = box.y0 + dy;
		if (sy < 0) break;
		for (let dx = 0; dx >= -300; dx -= 20) {
			const sx = box.x0 + dx;
			if (sx < 0) break;
			let bad = 0, n = 0;
			for (let j = 0; j < bh; j += 2) {
				for (let i = 0; i < bw; i += 2) {
					if (lum(buf, ((sy + j) * W + sx + i) * 4) < contamLim) bad++;
					n++;
				}
			}
			cands.push({ dx, dy, sx, sy, score: bad / n, dist: -dy + Math.abs(dx) * 2 });
		}
	}
	cands.sort((a, b) => a.score - b.score || a.dist - b.dist);
	return cands.slice(0, K);
}

/* ---------------------- 护画遮罩 ---------------------- */

/* 这一层是整套做法里唯一需要「看懂画面」的地方，也是最容易做错的地方。

   第一版用亮度判：暗于 130 的算画，其余一律抹掉。结果是
   湖南蒙学先生 的长衫**被洗白了一块** —— 因为长衫是中调（150~200），
   而水印的描边也在同一档（150~171）。**光靠亮度这两者根本分不开。**

   分开它们的是**结构**不是明暗：
   · 水印描边是细线，周围大片是纸；
   · 长衫是成片的暗块，周围也暗。
   所以改成看**邻域的「纸占比」**：先做一张「亮像素」的积分图，
   任意窗口的纸占比 O(1) 就能查出来。
       · 亮像素（白字填充、纸）           → 直接抹
       · 暗像素，但周围大半是纸（描边）   → 抹
       · 暗像素，周围也暗（长衫、手杖）   → 留
   窗口半径 12，比描边宽得多、比衣块窄得多，正好卡在两者中间。 */

const MASK_R = 12;

function buildSAT(buf, W, H, brightLim) {
	const sat = new Int32Array((W + 1) * (H + 1));
	for (let y = 0; y < H; y++) {
		let row = 0;
		for (let x = 0; x < W; x++) {
			if (lum(buf, (y * W + x) * 4) >= brightLim) row++;
			sat[(y + 1) * (W + 1) + (x + 1)] = sat[y * (W + 1) + (x + 1)] + row;
		}
	}
	return sat;
}

function winFrac(sat, W, x0, y0, x1, y1) {
	const g = (x, y) => sat[y * (W + 1) + x];
	return (g(x1, y1) - g(x0, y1) - g(x1, y0) + g(x0, y0)) / ((x1 - x0) * (y1 - y0));
}


/** 用样本块盖掉水印。
    · 纹理是真的：逐像素从样本搬，不做插值，纸纹原样保留。
      （先试过 Coons 曲面插值，结果框内变成一块平滑亮斑 —— 纸纹没了，
      而且左边界取到的是手杖，把黑当成边界条件抹成一整条横向渐变。）
    · 逐像素挑来源：按候选顺序找第一个「这里是纸」的样本像素。
      单块样本里被画压住的位置，就换下一块去取 —— 既不搬进笔触，
      也不会留下整列的竖条纹（那是「整列取中位数」兜底的毛病）。 */
function patchBox(buf, W, H, box, cands, contamLim, paper, fallback) {
	const bw = box.x1 - box.x0, bh = box.y1 - box.y0;
	const brightLim = paper - 35;
	const sat = buildSAT(buf, W, H, brightLim);
	let touched = 0, borrowed = 0;

	for (let j = 0; j < bh; j++) {
		for (let i = 0; i < bw; i++) {
			const x = box.x0 + i, y = box.y0 + j;
			const di = (y * W + x) * 4;

			const bright = lum(buf, di) >= brightLim;
			const m = bright ? 1 : smoothstep(0.45, 0.75,
				winFrac(sat, W, Math.max(0, x - MASK_R), Math.max(0, y - MASK_R),
					Math.min(W, x + MASK_R + 1), Math.min(H, y + MASK_R + 1)));
			if (m <= 0) continue;
			touched++;

			let src = null;
			for (const c of cands) {
				const si = ((c.sy + j) * W + c.sx + i) * 4;
				if (lum(buf, si) >= contamLim) { src = si; break; }
			}
			if (src === null) { borrowed++; }
			for (let k = 0; k < 3; k++) {
				const val = src === null ? fallback[k] : buf[src + k];
				buf[di + k] = buf[di + k] * (1 - m) + val * m;
			}
		}
	}
	return { touched, borrowed };
}

/** 框周围「干净纸边」的中位亮度 —— 用来验补完之后亮暗对不对。
    只取纸（≥ contamLim）的样本，避开左边界那截手杖。 */
function ringLevel(buf, W, H, box, contamLim) {
	const v = [];
	const push = (x, y) => {
		const l = lum(buf, (y * W + x) * 4);
		if (l >= contamLim) v.push(l);
	};
	for (let i = 0; i < box.x1 - box.x0; i++) { push(box.x0 + i, box.y0 - 1); push(box.x0 + i, box.y1); }
	for (let j = 0; j < box.y1 - box.y0; j++) { push(box.x0 - 1, box.y0 + j); push(box.x1, box.y0 + j); }
	if (!v.length) return null;
	v.sort((a, b) => a - b);
	return v[v.length >> 1];
}


/* ---------------------- 缩 ---------------------- */

/** 面积平均缩放：每个目标像素取源图对应矩形的均值。 */
function downscale(buf, w, h, targetH) {
	const ow = Math.max(1, Math.round(w * targetH / h));
	const oh = targetH;
	const out = new Uint8Array(ow * oh * 4);

	for (let oy = 0; oy < oh; oy++) {
		const sy0 = Math.floor(oy * h / oh);
		const sy1 = Math.max(sy0 + 1, Math.floor((oy + 1) * h / oh));
		for (let ox = 0; ox < ow; ox++) {
			const sx0 = Math.floor(ox * w / ow);
			const sx1 = Math.max(sx0 + 1, Math.floor((ox + 1) * w / ow));
			let r = 0, g = 0, b = 0, n = 0;
			for (let sy = sy0; sy < sy1; sy++) {
				for (let sx = sx0; sx < sx1; sx++) {
					const i = (sy * w + sx) * 4;
					r += buf[i]; g += buf[i + 1]; b += buf[i + 2]; n++;
				}
			}
			const o = (oy * ow + ox) * 4;
			out[o] = Math.round(r / n);
			out[o + 1] = Math.round(g / n);
			out[o + 2] = Math.round(b / n);
			out[o + 3] = 255;
		}
	}
	return { buf: out, w: ow, h: oh };
}

function toCanvas(img) {
	const c = new Canvas(img.w, img.h);
	for (let y = 0; y < img.h; y++) {
		for (let x = 0; x < img.w; x++) {
			const i = (y * img.w + x) * 4;
			c.blend(x, y, img.buf[i], img.buf[i + 1], img.buf[i + 2], 1);
		}
	}
	return c;
}

/** 右下角前后对照，供肉眼复核。左=前，右=后，红框是水印位置。 */
function qaCrop(before, after, W, H, box, label) {
	const CW = 420, CH = 200, S = 2;
	const x0 = W - CW, y0 = H - CH;
	const c = new Canvas(CW * 2 * S + 8, CH * S);
	const put = (src, ox) => {
		for (let y = 0; y < CH; y++) for (let x = 0; x < CW; x++) {
			const i = ((y0 + y) * W + x0 + x) * 4;
			const l = (src[i] * 299 + src[i + 1] * 587 + src[i + 2] * 114) / 1000;
			const e = Math.max(0, Math.min(255, (l - 140) * (255 / 115)));   // 拉对比，让水印显形
			for (let dy = 0; dy < S; dy++) for (let dx = 0; dx < S; dx++)
				c.blend(ox + x * S + dx, y * S + dy, e, e, e, 1);
		}
	};
	put(before, 0);
	put(after, CW * S + 8);
	const bx0 = (box.x0 - x0) * S, by0 = (box.y0 - y0) * S;
	const bx1 = (box.x1 - x0) * S, by1 = (box.y1 - y0) * S;
	for (const ox of [0, CW * S + 8]) {
		for (let t = 0; t <= bx1 - bx0; t++) {
			for (const [px, py] of [[bx0 + t, by0], [bx0 + t, by1], [bx0, by0 + t * (by1 - by0) / (bx1 - bx0)], [bx1, by0 + t * (by1 - by0) / (bx1 - bx0)]]) {
				for (let d = 0; d < 2; d++) c.blend(ox + px + d, py, 255, 0, 0, 1);
			}
		}
	}
	return c;
}


/* ---------------------- 主流程 ---------------------- */

console.log("源  " + SRC_DIR);
console.log("出  " + OUT_DIR + "\n");
if (!DRY && !fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
if (QA && !fs.existsSync(path.join(ROOT, "tools", "_qa"))) fs.mkdirSync(path.join(ROOT, "tools", "_qa"));

let bad = 0;
const report = [];

for (const [file, id, label] of MAP) {
	const src = path.join(SRC_DIR, file);
	if (!fs.existsSync(src)) {
		console.log("  ✗ " + label + "  —— 源文件不在：" + file);
		bad++;
		continue;
	}

	const img = readPNG(src);
	const buf = toBuffer(img);
	const box = watermarkBox(img.w, img.h);
	const before = darkCount(buf, img.w, box, INK_LUM);
	const beforeArt = darkCount(buf, img.w, box, ART_LUM);
	const snapshot = QA ? buf.slice() : null;

	if (before < INK_MIN_COUNT) {
		console.log("  ! " + label.padEnd(14) + " 框内只有 " + before + " 个暗像素 —— " +
			"这里可能本来就没有水印，或者水印挪了位置。**没动它**，请人工看一眼。");
		bad++;
		continue;
	}

	const paper = paperLevel(buf, img.w, img.h);
	const contamLim = Math.min(200, paper - 30);
	const cands = pickSources(buf, img.w, box, contamLim);
	if (!cands.length) {
		console.log("  ✗ " + label.padEnd(14) + " 框周围找不到可用的样本块 —— 不硬补。");
		bad++;
		continue;
	}
	const ring = ringLevel(buf, img.w, img.h, box, contamLim);
	const fb = [paper, paper, paper];        // 全无干净来源时的兜底：直接铺纸面基准亮度
	const beforeBright = brightCount(buf, img.w, box, paper + 20);
	const fill = patchBox(buf, img.w, img.h, box, cands, contamLim, paper, fb);

	const after = darkCount(buf, img.w, box, INK_LUM);
	const afterArt = darkCount(buf, img.w, box, ART_LUM);
	const afterBright = brightCount(buf, img.w, box, paper + 20);
	const boxArea = (box.x1 - box.x0) * (box.y1 - box.y0);

	// 先出对照图 —— 判失败时最需要看图，所以放在检查之前
	if (QA) writePNG(path.join(ROOT, "tools", "_qa", id + ".png"),
		qaCrop(snapshot, buf, img.w, img.h, box, label));

	// 不变量一：护画遮罩不许吃掉真笔触。留 20% 余量 ——
	// 画的边缘走的是软遮罩，最外圈抗锯齿像素会被冲淡、跨过阈值，
	// 实测约 7%，属正常。但**成片**被洗掉（比如长衫整块变白）会掉到近乎归零，
	// 那才是遮罩判错了，必须拦住 —— 这条就是为抓那个而设的。
	if (afterArt < beforeArt * 0.80) {
		console.log("  ✗ " + label.padEnd(14) + " 真笔触被吃掉了（" + beforeArt + " → " + afterArt +
			"）—— 遮罩没护住，不写文件。");
		bad++;
		if (!FORCE) continue;
	}
	// 不变量二：水印那一档的暗像素必须塌下去。
	// **只对框内本来没有画的图成立。** 框里若压着人物（长衫是中调 150~200，
	// 和水印描边同一档），「暗像素还剩多少」就分不清是没抹干净还是本来就有画 ——
	// 对这类图改用不变量四，别拿错尺子量。
	const residual = after - afterArt;
	const limit = Math.max(40, Math.round(before * 0.03));
	if (beforeArt < boxArea * 0.01 && residual > limit) {
		console.log("  ✗ " + label.padEnd(14) + " 抹完还剩 " + residual +
			" 个可疑暗像素（护住笔触 " + beforeArt + "，上限 " + limit + "）—— 没抹干净，不写文件。");
		bad++;
		if (!FORCE) continue;
	}
	// 不变量四：白字填充必须清光。水印是**比纸更亮**的白字 ——
	// 这条专治「框里压着画」的图：长衫再暗也不比纸亮，量不进来。
	const brightLeft = afterBright;
	if (brightLeft > Math.max(30, beforeBright * 0.05)) {
		console.log("  ✗ " + label.padEnd(14) + " 还剩 " + brightLeft +
			" 个比纸更亮的像素（原先 " + beforeBright + "）—— 白字没清干净，不写文件。");
		bad++;
		if (!FORCE) continue;
	}
	// 不变量三：补完的亮暗必须跟周围纸面对得上。
	// 这条是补出来的 —— 第二版把样本取在手杖的阴影里，水印是没了，
	// 但框内变成一块明显发灰的方块，光看「暗像素归零」根本发现不了。
	let drift = 0;
	if (ring !== null) {
		let s = 0, n = 0;
		for (let y = box.y0; y < box.y1; y++) {
			for (let x = box.x0; x < box.x1; x++) {
				const l = lum(buf, (y * img.w + x) * 4);
				if (l < ART_LUM) continue;      // 真笔触不参与
				s += l; n++;
			}
		}
		drift = n ? s / n - ring : 0;
		if (Math.abs(drift) > 12) {
			console.log("  ✗ " + label.padEnd(14) + " 补完的框内比周围纸面" +
				(drift > 0 ? "亮" : "暗") + "了 " + Math.abs(drift).toFixed(1) +
				"（周围 " + ring.toFixed(0) + "）—— 样本取偏了，不写文件。");
			bad++;
			continue;
		}
	}

	const small = downscale(buf, img.w, img.h, TARGET_H);
	if (!DRY) writePNG(path.join(OUT_DIR, id + ".png"), toCanvas(small));

	console.log("  ok " + label.padEnd(14) +
		" " + img.w + "×" + img.h + " → " + small.w + "×" + small.h +
		"   水印档暗像素 " + String(before).padStart(5) + " → " + String(after).padStart(4) +
		"   护住笔触 " + String(beforeArt).padStart(4) + " px" +
		"   样本 " + cands.length + " 块（最好 " + (cands[0].score * 100).toFixed(1) + "% 非纸）" +
		"   兜底 " + fill.borrowed + " px" +
		"   亮暗差 " + drift.toFixed(1));

	report.push({ id, label, file, before, after, art: beforeArt, drift,
		candidates: cands.length, bestNonPaper: cands[0].score, borrowed: fill.borrowed,
		w: small.w, h: small.h });
}

console.log("");
if (bad === 0) {
	console.log("全部 " + MAP.length + " 张处理完毕。");
	if (!DRY) {
		fs.writeFileSync(path.join(OUT_DIR, "manifest.json"),
			JSON.stringify({ generated_by: "tools/dewatermark.js", target_height: TARGET_H,
				watermark: WM, thresholds: { art: ART_LUM, paper: PAPER_OK, ink: INK_LUM },
				portraits: report }, null, 1), "utf8");
	}
} else {
	console.log("有 " + bad + " 张需要人工处理。");
}
process.exit(bad ? 1 : 0);
