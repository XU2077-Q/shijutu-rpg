/* ============================================================
   火山方舟（豆包）图像生成客户端 —— 零依赖

   【API Key 怎么给】
   只认一个来源：环境变量 ARK_API_KEY。没设就读仓库根目录的 .env
   （.env 已在 .gitignore 里，**不会进版本库**）。
   key 绝不出现在命令行参数里 —— 那会被记进 shell 历史和进程列表。

   用法：
     const ark = require("./ark.js");
     await ark.generate({ prompt, ref, size, out });

   或者命令行自查：
     node tools/ark.js --check         只验 key 能不能用
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const ENDPOINT = "https://ark.cn-beijing.volces.com/api/v3/images/generations";
const MODEL = "doubao-seedream-5-0-pro-260628";

/* 极简 .env 解析。只认 KEY=VALUE，忽略注释和空行，
   两侧成对的引号剥掉。不搞变量展开 —— 用不着，展开只会多一类出错方式。 */
function loadEnv(file) {
	const out = {};
	if (!fs.existsSync(file)) return out;
	for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
		if (/^\s*(#|$)/.test(line)) continue;
		const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
		if (!m) continue;
		let v = m[2];
		if (v.length >= 2 && ((v[0] === '"' && v.endsWith('"')) || (v[0] === "'" && v.endsWith("'")))) {
			v = v.slice(1, -1);
		}
		out[m[1]] = v;
	}
	return out;
}

function getKey() {
	const k = process.env.ARK_API_KEY || loadEnv(path.join(ROOT, ".env")).ARK_API_KEY;
	if (!k) {
		throw new Error(
			"没找到 ARK_API_KEY。\n" +
			"  在 " + path.join(ROOT, ".env") + " 里写一行：\n" +
			"      ARK_API_KEY=你的密钥\n" +
			"  或者设成系统环境变量。（.env 不会进版本库。）");
	}
	if (/^(你的|xxx|<|$)/i.test(k) || k.length < 20) {
		throw new Error("ARK_API_KEY 看起来还是占位符（长度 " + k.length + "），请填真key。");
	}
	return k;
}

/** 日志用。**永远不要直接打印 key。** */
const mask = (k) => (k ? k.slice(0, 7) + "…" + k.slice(-4) + "（" + k.length + " 字符）" : "（未设）");


const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * 生成一张图并落盘。
 * @param {string}  o.prompt  提示词
 * @param {string=} o.ref     参考图路径（角色定妆图），用于跨图一致性
 * @param {string=} o.size    默认 "2K"
 * @param {string}  o.out     输出 png 路径
 * @param {number=} o.retries 默认 3
 */
async function generate(o) {
	const key = getKey();
	const body = {
		model: MODEL,
		prompt: o.prompt,
		size: o.size || "2K",
		watermark: false,          // 必须关。开着就又给我们盖一行「豆包 AI 生成」。
		response_format: "url",
		output_format: "png",
	};

	// 角色一致性靠参考图：同一角色先出一张定妆图，之后所有差分都带上它
	if (o.ref) {
		const abs = path.isAbsolute(o.ref) ? o.ref : path.join(ROOT, o.ref);
		if (!fs.existsSync(abs)) throw new Error("参考图不在：" + abs);
		const ext = path.extname(abs).slice(1).toLowerCase();
		const mime = ext === "jpg" || ext === "jpeg" ? "image/jpeg" : "image/png";
		body.image = "data:" + mime + ";base64," + fs.readFileSync(abs).toString("base64");
	}

	const retries = o.retries === undefined ? 3 : o.retries;
	let lastErr = null;

	for (let attempt = 1; attempt <= retries; attempt++) {
		try {
			const res = await fetch(ENDPOINT, {
				method: "POST",
				headers: { "Content-Type": "application/json", Authorization: "Bearer " + key },
				body: JSON.stringify(body),
			});

			const text = await res.text();
			if (!res.ok) {
				// 4xx 是我们自己写错了（提示词违规、模型没权限），重试没意义，直接抛
				if (res.status >= 400 && res.status < 500 && res.status !== 429) {
					throw new Error("方舟返回 " + res.status + "：" + text.slice(0, 400));
				}
				throw new Error("方舟返回 " + res.status + "（可重试）：" + text.slice(0, 200));
			}

			let json;
			try { json = JSON.parse(text); }
			catch { throw new Error("方舟返回的不是 JSON：" + text.slice(0, 300)); }

			const item = json && json.data && json.data[0];
			if (!item) throw new Error("方舟没给图：" + text.slice(0, 300));

			fs.mkdirSync(path.dirname(o.out), { recursive: true });

			if (item.b64_json) {
				fs.writeFileSync(o.out, Buffer.from(item.b64_json, "base64"));
			} else if (item.url) {
				const img = await fetch(item.url);
				if (!img.ok) throw new Error("下载生成的图失败：" + img.status);
				fs.writeFileSync(o.out, Buffer.from(await img.arrayBuffer()));
			} else {
				throw new Error("方舟给的条目里既没有 url 也没有 b64_json");
			}
			return { file: o.out, bytes: fs.statSync(o.out).size };
		} catch (e) {
			lastErr = e;
			if (attempt < retries) {
				const wait = 2000 * attempt;
				process.stderr.write("    第 " + attempt + " 次失败：" + e.message + " —— " + (wait / 1000) + " 秒后重试\n");
				await sleep(wait);
			}
		}
	}
	throw lastErr;
}


/* ---------------------- 自查 ---------------------- */
/* 出图要花钱，所以先用一次最小的调用确认 key、模型权限、网络都通。 */

async function check() {
	const key = getKey();
	console.log("endpoint  " + ENDPOINT);
	console.log("model     " + MODEL);
	console.log("key       " + mask(key));

	const res = await fetch(ENDPOINT, {
		method: "POST",
		headers: { "Content-Type": "application/json", Authorization: "Bearer " + key },
		body: JSON.stringify({
			model: MODEL, prompt: "一张纯白的纸", size: "1K",
			watermark: false, response_format: "url", output_format: "png",
		}),
	});
	const text = await res.text();
	if (!res.ok) {
		console.log("\n✗ 调用失败 " + res.status);
		console.log(text.slice(0, 600));
		process.exit(1);
	}
	console.log("\n✓ key 可用，模型有权限。");
}

if (require.main === module) {
	if (process.argv.includes("--check")) {
		check().catch((e) => { console.error("✗ " + e.message); process.exit(1); });
	} else {
		console.log("这是库，不是命令。用法：\n" +
			"  node tools/ark.js --check      验 key\n" +
			"  node tools/gen_art.js          出美术");
	}
}

module.exports = { generate, getKey, mask, loadEnv, MODEL, ENDPOINT };
