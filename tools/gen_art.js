/* ============================================================
   美术出图驱动 —— 读 tools/art_manifest.json，调方舟出图，回写 status

   出图是**花钱**的操作，所以这个脚本默认不闷头跑：
   要出的张数超过 3 张时，它先把清单打出来，要你加 --yes 才真出。

   用法：
     node tools/gen_art.js --list                 看看工单，不出图
     node tools/gen_art.js --dry                  同上，但列出将要发的提示词
     node tools/gen_art.js --only bg_r_tea        只出一张
     node tools/gen_art.js --only bg_r_tea,pt_kang_youwei
     node tools/gen_art.js --kind bg              只出背景
     node tools/gen_art.js --missing --yes        补齐所有还没出的
     node tools/gen_art.js --only bg_r_tea --force --yes   已出过的也重出

   其它开关：
     --size 2K | 2048x1152        覆盖工单里的 size
     --style-ref art/portraits/shen_huaijin.png
                                  给每张都挂上这张做风格参考。
                                  想统一画风时试；若人物脸被带跑就别用。
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");
const ark = require("./ark.js");

const ROOT = path.resolve(__dirname, "..");
const MANIFEST = path.join(__dirname, "art_manifest.json");

/* ---------------------- 参数 ---------------------- */

function parseArgs(argv) {
	const a = { only: null, kind: null, dry: false, list: false, force: false, yes: false, size: null, styleRef: null };
	for (let i = 0; i < argv.length; i++) {
		const v = argv[i];
		if (v === "--dry") a.dry = true;
		else if (v === "--list") a.list = true;
		else if (v === "--missing") { /* 默认行为就是只出没出过的，这个开关只为把意图写明 */ }
		else if (v === "--force") a.force = true;
		else if (v === "--yes" || v === "-y") a.yes = true;
		else if (v === "--only") a.only = argv[++i];
		else if (v === "--kind") a.kind = argv[++i];
		else if (v === "--size") a.size = argv[++i];
		else if (v === "--style-ref") a.styleRef = argv[++i];
		else if (v.startsWith("--only=")) a.only = v.slice(7);
		else if (v.startsWith("--kind=")) a.kind = v.slice(7);
		else if (v.startsWith("--size=")) a.size = v.slice(7);
		else if (v.startsWith("--style-ref=")) a.styleRef = v.slice(12);
		else { console.error("认不出的参数：" + v); process.exit(2); }
	}
	if (a.only) a.only = a.only.split(",").map((s) => s.trim()).filter(Boolean);
	return a;
}

/* ---------------------- 选活 ---------------------- */

/* id 先校验一遍。放在选活之前，--list / --dry 也要过这道，
   否则打错 id 会被「没有要出的图」糊弄过去 —— 那是静默失败。 */
function validateIds(manifest, a) {
	if (!a.only) return;
	const got = new Set(manifest.items.map((i) => i.id));
	const miss = a.only.filter((id) => !got.has(id));
	if (miss.length) {
		console.error("工单里没有这些 id：" + miss.join(", "));
		console.error("用 --list 看全部 id。");
		process.exit(2);
	}
	if (a.kind) {
		const wrong = manifest.items.filter((i) => a.only.includes(i.id) && i.kind !== a.kind);
		if (wrong.length) {
			console.error("这些 id 不是 " + a.kind + " 类：" + wrong.map((i) => i.id + "(" + i.kind + ")").join(", "));
			process.exit(2);
		}
	}
}

function select(manifest, a) {
	let items = manifest.items;
	if (a.only) items = items.filter((i) => a.only.includes(i.id));
	if (a.kind) items = items.filter((i) => i.kind === a.kind);
	if (!a.force) items = items.filter((i) => i.status !== "done");
	return items;
}

function composePrompt(manifest, item, styleRef) {
	const base = item.kind === "bg" ? manifest.bg_base : manifest.portrait_base;
	return [manifest.style_base, base, item.prompt].filter(Boolean).join("\n\n");
}

/* ---------------------- 回写 ---------------------- */

function saveManifest(manifest) {
	// 末尾留一个换行，git diff 才干净
	fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
}

/* ---------------------- 主流程 ---------------------- */

async function main() {
	const a = parseArgs(process.argv.slice(2));

	if (!fs.existsSync(MANIFEST)) throw new Error("找不到工单：" + MANIFEST);
	const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
	validateIds(manifest, a);

	// --list / --dry 不带 --only 时看全量，不受 status 过滤
	const listing = a.list || a.dry;
	const items = listing
		? manifest.items.filter((i) => (!a.only || a.only.includes(i.id)) && (!a.kind || i.kind === a.kind))
		: select(manifest, a);

	if (!items.length) {
		console.log("没有要出的图。");
		return;
	}

	/* 清单 */
	if (a.list || a.dry) {
		const done = manifest.items.filter((i) => i.status === "done").length;
		console.log("工单共 " + manifest.items.length + " 张，已出 " + done + " 张。\n");
		for (const i of items) {
			const mark = i.status === "done" ? "✓" : i.status === "reject" ? "✗" : "·";
			console.log("  " + mark + " [" + i.kind.padEnd(8) + "] " + i.id.padEnd(20) + " → " + i.file);
			if (a.dry) console.log("        " + composePrompt(manifest, i, a.styleRef).replace(/\n+/g, " ⏎ ").slice(0, 260) + "…");
		}
		console.log("\n这次会出 " + items.length + " 张。");
		if (!a.dry) console.log("去掉 --list 就是真出图。");
		return;
	}

	/* 花钱的闸门 */
	if (items.length > 3 && !a.yes) {
		console.log("要出 " + items.length + " 张图 —— 这是要花钱的，先确认一下：\n");
		for (const i of items) console.log("  [" + i.kind + "] " + i.id);
		console.log("\n确认无误就加 --yes 重跑：");
		console.log("  node tools/gen_art.js " + process.argv.slice(2).join(" ") + " --yes");
		return;
	}

	const key = ark.getKey();                       // 早失败：没 key 就别开始
	console.log("key " + ark.mask(key) + "，开始出 " + items.length + " 张。\n");

	const failed = [];
	let n = 0;

	for (const item of items) {
		n++;
		const out = path.join(ROOT, item.file);
		const size = a.size || item.size || "2K";
		const ref = a.styleRef ? path.join(ROOT, a.styleRef) : item.ref;

		process.stdout.write("[" + n + "/" + items.length + "] " + item.id + "  (" + size + ") … ");
		const t0 = Date.now();

		try {
			const r = await ark.generate({
				prompt: composePrompt(manifest, item, a.styleRef),
				ref,
				size,
				out,
				retries: 3,
			});
			item.status = "done";
			item.bytes = r.bytes;
			item.generatedAt = new Date().toISOString().slice(0, 10);
			item.usedSize = size;
			item.usedRef = ref ? path.relative(ROOT, ref).replace(/\\/g, "/") : null;
			delete item.error;
			saveManifest(manifest);                 // 每张都存，中途断掉也不白干
			console.log("✓ " + (r.bytes / 1048576).toFixed(1) + " MB  " + ((Date.now() - t0) / 1000).toFixed(0) + "s");
		} catch (e) {
			item.status = item.status === "done" ? "done" : "todo";
			item.error = String(e.message || e).slice(0, 300);
			saveManifest(manifest);
			console.log("✗");
			console.error("    " + item.error);
			failed.push(item.id);
		}
	}

	console.log("\n完成 " + (items.length - failed.length) + "/" + items.length + " 张。");
	if (failed.length) {
		console.log("失败：" + failed.join(", "));
		console.log("重跑这几张：node tools/gen_art.js --only " + failed.join(",") + " --yes");
		process.exit(1);
	}
	console.log("看效果：直接打开 art/ 下对应的 png。不满意就 --force 重出那一张。");
}

if (require.main === module) {
	main().catch((e) => { console.error("\n✗ " + (e.message || e)); process.exit(1); });
}

module.exports = { composePrompt, select, parseArgs };
