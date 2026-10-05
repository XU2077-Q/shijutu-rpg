/* ============================================================
   《时局图》RPG 剧本导出器
   零依赖。把两个只读源合成成 Godot 用的 JSON。

     源一  D:\claude\时局图\index.html          ← 原文，一个字都不能改
     源二  C:\...\《时局图》剧本扩写读本.docx    ← 31 条扩写

   用法：
       node tools/export_story.js
       node tools/export_story.js --index <路径> --docx <路径>

   设计上承自 Ren'Py 版的 tools/export_data.js（那份已经跑熟了）：
   同样从 index.html 切数据层、同样在导出阶段就把问题炸出来。
   两处升级：
     1. 函数值字段不再编成 {"__fn__":"名字"} 这种符号表，
        而是编成**声明式条件 AST** —— 以后剧本加新门槛，这里不用改。
     2. 多了一个源：扩写读本。原文与扩写**永不混写**，
        扩写走独立的 xN 节点，插在场景图里。
   ============================================================ */
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const docxlib = require("./docx.js");

const ROOT = path.resolve(__dirname, "..");
const DEFAULT_INDEX = "D:/claude/时局图/index.html";
const DEFAULT_DOCX = "C:/Users/Lenovo/Desktop/《时局图》剧本扩写读本.docx";
const OUT = path.join(ROOT, "data");

function arg(name, dflt) {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}
const INDEX = arg("index", DEFAULT_INDEX);
const DOCX = arg("docx", DEFAULT_DOCX);

/* ============================================================
   一、从 index.html 抽数据层
   ============================================================ */

function loadIndex(srcPath) {
  const html = fs.readFileSync(srcPath, "utf8");
  const scriptStart = html.indexOf("<script>");
  if (scriptStart < 0) throw new Error("找不到 <script> 标签");
  const iife = html.indexOf("(function(){", scriptStart);
  if (iife < 0) throw new Error("找不到引擎 IIFE，数据层与引擎层的边界无法确定");

  const dataSrc = html.slice(scriptStart + "<script>".length, iife);
  if (dataSrc.length < 100000) {
    throw new Error("数据层只切出 " + dataSrc.length + " 字符，边界判断可能错了");
  }
  const fn = new Function(dataSrc + "\nreturn { SCRIPT, NOTES, ENDINGS, MARKERS };");
  return { data: fn(), sha256: crypto.createHash("sha256").update(html).digest("hex") };
}

/* ============================================================
   二、函数值字段 → 声明式条件 AST

   实测 index.html 里共 18 处函数值字段，6 种形状（下面每条都注了出处）。
   认不出来的**一律 throw** —— 这是承自旧导出器最重要的那条安全属性：
   宁可导出失败，也不能把一句条件悄悄丢掉，那会变成运行时的错误分支。
   ============================================================ */

const RE_FLAG_COND =
  /^\s*function\s*\(\s*s\s*\)\s*\{\s*return\s+!!\s*s\.flags\.([A-Za-z_$][\w$]*)\s*;?\s*\}\s*$/;

const RE_TERNARY_FLAG =
  /^\s*s\s*=>\s*s\.flags\.([A-Za-z_$][\w$]*)\s*\?\s*"([^"]*)"\s*:\s*"([^"]*)"\s*$/;

const RE_CMP = /^\s*s\.(shen|lin)\s*(>=|<=|>|<|===|==)\s*(-?\d+)\s*$/;

const OP_OF = { ">=": "gte", "<=": "lte", ">": "gt", "<": "lt", "===": "eq", "==": "eq" };

function cmpNode(part) {
  const m = RE_CMP.exec(part);
  if (!m) return null;
  return { op: OP_OF[m[2]], lhs: { op: "var", name: m[1] }, rhs: { op: "lit", value: Number(m[3]) } };
}

/* 把 "a" + s.x + "b" + s.y + "c" 拆成 {fmt:"a{0}b{1}c", args:[var x, var y]} */
function templateNode(src) {
  const body = src.replace(/^\s*s\s*=>\s*/, "").trim();
  const parts = body.split("+").map((s) => s.trim());
  let fmt = "";
  const args = [];
  for (const p of parts) {
    const strLit = /^"([^"]*)"$/.exec(p);
    if (strLit) { fmt += strLit[1]; continue; }
    const varRef = /^s\.(shen|lin)$/.exec(p);
    if (varRef) { fmt += "{" + args.length + "}"; args.push({ op: "var", name: varRef[1] }); continue; }
    return null;
  }
  return { op: "template", fmt, args };
}

const astLog = []; // { shape, node } —— 用于报告，去重后打印

function toAst(fnSrc) {
  const src = fnSrc.replace(/\s+/g, " ").trim();
  let node = null, shape = null;

  let m = RE_FLAG_COND.exec(src);
  if (m) { node = { op: "flag", name: m[1] }; shape = "flag"; }

  if (!node) {
    m = RE_TERNARY_FLAG.exec(src);
    if (m) {
      node = { op: "if", cond: { op: "flag", name: m[1] }, then: m[2], else: m[3] };
      shape = "if";
    }
  }

  if (!node && /&&/.test(src)) {
    const parts = src.replace(/^\s*s\s*=>\s*/, "").split("&&").map((s) => s.trim());
    const nodes = parts.map(cmpNode);
    if (nodes.every(Boolean)) { node = { op: "and", args: nodes }; shape = "and"; }
  }

  if (!node) {
    const t = templateNode(src);
    if (t) { node = t; shape = "template"; }
  }

  if (!node) {
    throw new Error(
      "发现未登记的函数值字段形状，需要给 tools/export_story.js 加识别规则：\n  " + src);
  }
  astLog.push({ shape, node });
  return node;
}

function stripFns(v) {
  if (typeof v === "function") return toAst(v.toString());
  if (Array.isArray(v)) return v.map(stripFns);
  if (v && typeof v === "object") {
    const o = {};
    for (const k of Object.keys(v)) o[k] = stripFns(v[k]);
    return o;
  }
  return v;
}

/* ============================================================
   三、扩写读本
   ============================================================ */

/* 读本的排版记号（凡例 三）：
     对话前置说话人，以朱色标出   → 「说话人（角色）」正文
     书信以〔书信〕起、〔落款〕止
     引文以 ＞ 起，后注出处
     ＊ 为原文节拍分隔      ◎ 时局图揭章      ★ 本线终局
   扩写段落里还会带 【补·xxx】 前缀，那是给人看的标记，进游戏要去掉。 */

function parseDialogue(line) {
  // 「沈怀瑾」正文   /   「周子安（同乡举子）」正文   /   「两年前，……」（无说话人）
  const m = /^「([^」]{1,12}?)(?:（([^）]*)）)?」(.+)$/s.exec(line);
  if (!m) return null;
  const head = m[1];
  // 说话人极短且不像句子开头，才认定为说话人。否则整句是台词，说话人未标。
  const looksLikeName = head.length <= 6 && !/[。！？，、；：]/.test(head);
  if (!looksLikeName) return { w: "", r: "", x: line };
  return { w: head, r: m[2] || "", x: m[3] };
}

/* 一条扩写的段落 → 节拍数组。
   目标节拍长度向原文看齐（原文 n 节拍中位数约 24 字），
   所以长段落要按句切开、再打包，不能整段塞进一个对话框。 */
const BEAT_TARGET = 44;

/* 归一化，用于「读本 vs 原文」的逐字比对。
   两处**纯排版**差异要抹平，否则会把排版差异误报成改字：

     1. 空白 —— 读本把书信按行排，原文把行并在一拍里，换行位置不同。
     2. —— / ＊ —— 同一个东西的两种排法：原文在书信正文里用行内「——」断段，
        读本把它排成独立一段的「＊」。实测原文书信体里 —— 出现 15 次，
        读本非扩写正文里 ＊ 出现 239 次。抹平之后比对才有意义。

   除这两样，其余一字不让。 */
const norm = (t) => String(t).replace(/\s/g, "").replace(/[—＊]/g, "");

function splitLong(text) {
  const out = [];
  const sentences = text.match(/[^。！？…]+[。！？…]+|[^。！？…]+$/g) || [text];
  let buf = "";
  for (const s of sentences) {
    if (buf && buf.length + s.length > BEAT_TARGET) { out.push(buf); buf = s; }
    else buf += s;
  }
  if (buf) out.push(buf);
  return out;
}

function expansionParagraphToBeats(para, run, idx) {
  let line = para.replace(/^【补·[^】]*】/, "").trim();
  if (!line) return [];
  const at = (i) => "x" + run + ":" + i;
  let i = idx;

  if (line.startsWith("＞")) {                       // 引文
    const body = line.replace(/^＞\s*/, "");
    const srcM = /——\s*([^—]+)$/.exec(body);
    return [{ bid: at(i), t: "q", x: (srcM ? body.slice(0, srcM.index) : body).trim(),
              src: srcM ? srcM[1].trim() : "" }];
  }
  if (line.startsWith("〔")) {                        // 书信片段
    return [{ bid: at(i), t: "n", x: line }];
  }
  if (line.startsWith("「")) {                        // 对话
    const d = parseDialogue(line);
    if (d) return [{ bid: at(i), t: "d", w: d.w, r: d.r, x: d.x }];
  }
  return splitLong(line).map((x) => ({ bid: at(i++), t: "n", x }));   // 旁白
}

function buildExpansions(paras, mapPath) {
  const map = JSON.parse(fs.readFileSync(mapPath, "utf8")).expansions;
  const runs = docxlib.groupExpansionRuns(paras);

  if (runs.length !== map.length) {
    throw new Error("读本切出 " + runs.length + " 条扩写，映射表登记了 " + map.length + " 条 —— 对不上");
  }

  const out = [];
  runs.forEach((r, k) => {
    const m = map[k];
    const beats = [];
    let i = 0;
    for (const p of r.paragraphs) {
      for (const b of expansionParagraphToBeats(p, m.run, i)) { beats.push(b); i = (b.bid.split(":")[1] | 0) + 1; }
    }
    if (!beats.length) throw new Error("第 " + m.run + " 条扩写抽出来是空的");
    out.push({
      run: m.run, no: m.no, chapter: m.chapter, kind: m.kind, title: m.title,
      anchor: m.anchor, at: m.at,
      docx_paragraphs: [r.start, r.end],
      beats,
    });
  });
  return out;
}

/* ============================================================
   四、把扩写插进场景图

   原文节拍是脊梁，扩写是**另起节点**插进去，两者永不混写。
   这样「原文一字未改」是结构上成立的，不是靠自觉。

   插法：
     after  X   →  X.next 指向链首，链尾接回 X 原来的 next
     before X   →  所有指向 X 的边改指链首，链尾接 X
     replace X  →  替换 X 场景里的**某一拍**（不是整个场景），见下。

   【第 14 条的 replace 是怎么定位置的】
   附录二只写「整段替换 c3_s4a」，没说替换哪一段 —— 这句话按字面理解会
   把整个场景的 24 拍全顶掉，那显然不对。真实语义是**就地续写某一拍**：
   扩写正文以那一拍的原文起句，接着往下写。
   这不是猜的，是验出来的 —— 全书 2200 个散文节拍里，只有这一拍
   「有一个学生回来说，他们乡里的塾师看了图，写了四首诗。」在读本的非扩写正文中
   找不到，因为它被并进了扩写段落。所以定位规则是：**锚点场景里，
   被扩写首段以其原文起句的那一拍**。规则可机械执行，且找不到就报错。
   ============================================================ */

function splice(script, expansions) {
  const scenes = script.scenes;
  const pending = [];

  const beforeMap = new Map(), afterMap = new Map();
  for (const e of expansions) {
    if (!scenes[e.anchor]) throw new Error("扩写锚点场景不存在：" + e.anchor + "（第 " + e.run + " 条）");
    if (e.at === "replace") continue;
    const bag = (e.at === "after" ? afterMap : beforeMap);
    if (!bag.has(e.anchor)) bag.set(e.anchor, []);
    bag.get(e.anchor).push(e);
  }

  // 建节点。31 条**全都**有节点（这样每条都可寻址），
  // 但只有 30 条会被接进脊梁图 —— 剩下的那条靠 supersede 就地顶替。
  for (const e of expansions) {
    scenes["x" + e.run] = {
      ch: e.chapter, chTitle: "", place: "", date: "",
      expansion: { run: e.run, no: e.no, kind: e.kind, title: e.title, anchor: e.anchor, at: e.at },
      beats: e.beats, next: null,
    };
  }

  // replace：定位被顶掉的那一拍，记下替换关系。
  // 注意**不删原文节拍** —— 原文照旧躺在 beats 里，一个字不动；
  // 替换关系另存 supersede 字段，由 BeatRunner 在播放时执行。
  // 这样「原文一字未改」是结构上成立的，回想屏也还能读到那一拍。
  for (const e of expansions) {
    if (e.at !== "replace") continue;
    const sc = scenes[e.anchor];
    const head = norm(e.beats.map((b) => b.x || b.body || "").join(""));
    const hits = [];
    sc.beats.forEach((b, i) => {
      const t = b.x || b.body || "";
      if (typeof t !== "string") return;
      const n = norm(t);
      if (n.length >= 6 && head.startsWith(n)) hits.push(i);
    });
    if (!hits.length) {
      throw new Error("第 " + e.run + " 条标了 replace，但在 " + e.anchor +
        " 里找不到「被它起句顶掉」的那一拍 —— 定位规则不成立，不能瞎放");
    }
    const hit = hits[hits.length - 1];   // 取最长的那一拍（最具体的匹配）
    sc.supersede = sc.supersede || [];
    sc.supersede.push({
      beat: hit, bid: e.anchor + ":" + hit, by: "x" + e.run,
      note: "第 " + e.run + " 条扩写「" + e.title + "」以该拍原文起句续写",
      candidates: hits,
    });
  }

  const chainHead = (list) => (list && list.length ? "x" + list[0].run : null);
  const link = (list, tail) => {
    for (let i = 0; i < list.length; i++) {
      scenes["x" + list[i].run].next = i + 1 < list.length ? "x" + list[i + 1].run : tail;
    }
  };

  // before X：把指向 X 的边改指链首
  for (const [anchor, list] of beforeMap) {
    const head = chainHead(list);
    link(list, anchor);
    for (const id of Object.keys(scenes)) {
      const sc = scenes[id];
      if (sc.expansion) continue;                       // 扩写节点之间的边由 link 管
      if (sc.next === anchor) sc.next = head;
      for (const b of sc.beats || []) {
        if (b.t === "choice") for (const o of b.opts || []) if (o.to === anchor) o.to = head;
      }
    }
    if (script.start === anchor) script.start = head;
  }

  // after X：X.next 改指链首
  for (const [anchor, list] of afterMap) {
    const sc = scenes[anchor];
    if (!sc) continue;
    const tail = sc.next;                               // 原 next（可能是 null / 字符串 / AST）
    link(list, tail);
    sc.next = chainHead(list);
  }

  return pending;
}

/* ============================================================
   五、校验
   ============================================================ */

const KNOWN_BEAT_TYPES = ["n", "d", "q", "letter", "choice", "map", "end"];

function collectTexts(scenes) {
  const out = [];
  for (const id of Object.keys(scenes)) {
    const sc = scenes[id];
    if (sc.card) for (const k of Object.keys(sc.card)) out.push({ where: id + "/card." + k, s: sc.card[k] });
    for (const b of sc.beats || []) {
      for (const k of Object.keys(b)) {
        if (k === "opts" || k === "reveal" || k === "bid") continue;
        if (typeof b[k] === "string") out.push({ where: id + "/" + b.t + "." + k, s: b[k] });
      }
      for (const o of b.opts || []) {
        for (const k of Object.keys(o)) if (typeof o[k] === "string") out.push({ where: id + "/choice." + k, s: o[k] });
      }
    }
  }
  return out;
}

/* ============================================================
   主流程
   ============================================================ */

const SLICE = ["p_intro", "p_tea", "p_choice1", "p_ci", "p_ke", "p_gongche", "p_night", "p_lijm", "p_end",
  "c1_shanghai", "c1_home", "c1_village", "c1_father", "c1_choice", "c1_cons", "c1_rad", "c1_yanfu",
  "c1_draft", "c1_draft_a", "c1_draft_b", "c1_draft_c", "c1_miyue", "c1_end"];

console.log("源一  " + INDEX);
console.log("源二  " + DOCX + "\n");

const { data, sha256 } = loadIndex(INDEX);
const { SCRIPT, NOTES, ENDINGS, MARKERS } = data;
if (!SCRIPT || !SCRIPT.scenes) throw new Error("SCRIPT.scenes 不存在");

/* 原文副本要**两份**，而且是彼此独立的两份。
   因为 splice() 会就地改场景图（改 next、加 x 节点），
   而「原文逐字未变」的比对必须以 splice **之前**的状态为基准。
   用同一份就会拿改过的去比改过的，那比对等于没做。 */
const pristine = stripFns(SCRIPT.scenes);   // 只读，永不改，用作保真基准
const scenes   = JSON.parse(JSON.stringify(pristine));   // 会被 splice 就地改，进 story.json
// 用深拷贝而不是再 strip 一遍：strip 会把 18 处函数值字段再转一次 AST，
// 于是「函数值字段共 18 处」这份统计会变成 36。转一次，拷一份，才是对的。
const notes = stripFns(NOTES);
const endings = stripFns(ENDINGS);
const markers = stripFns(MARKERS);

// NOTES 不是数组，是按章名分组的对象：{ "序章":[{h,b},…], "第一章":[…] , … }
// 史实注正文里有 <span class='ref'> —— 换成 Godot 认的 BBCode。
// 原文正文本身不含 [] 与 {}（下面会断言），所以这个替换不会误伤。
const refCount = { n: 0 };
const notesOut = {};
for (const ch of Object.keys(notes)) {
  notesOut[ch] = notes[ch].map((n) => ({
    ...n,
    b: String(n.b).replace(/<span class='ref'>([\s\S]*?)<\/span>/g,
      (_, x) => { refCount.n++; return "[ref]" + x + "[/ref]"; }),
  }));
}
const noteCount = Object.values(notesOut).reduce((a, arr) => a + arr.length, 0);

const docxParas = docxlib.readParagraphs(DOCX);   // 读一次，扩写抽取与逐字比对共用
const expansions = buildExpansions(docxParas, path.join(ROOT, "data", "expansion_map.json"));

if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
const write = (name, obj) => {
  const p = path.join(OUT, name);
  fs.writeFileSync(p, JSON.stringify(obj, null, 1), "utf8");
  return fs.statSync(p).size;
};

const story = {
  schema_version: 1,
  source: { index_sha256: sha256, expansions: expansions.length },
  start: SCRIPT.start,
  scenes,
};
// 先建好 story，再往它的 scenes 上插扩写 —— splice 改的就是要落盘的那一份
const pending = splice(story, expansions);

/* 切片边界。**必须由导出器出**，不能让 GDScript 再抄一份 SLICE ——
   两份清单迟早会不一致，而不一致的那天，demo 会安安静静地演到第二章去。
   这里给全：23 个原文场景 + 锚在它们身上的扩写节点。
   注意必须在 splice 之后算 —— 扩写节点是 splice 才挂进 scenes 的。 */
const sliceNodes = Object.keys(scenes).filter((id) => {
  const e = scenes[id].expansion;
  return e && SLICE.includes(e.anchor);
});
story.slice = [...SLICE.filter((id) => scenes[id]), ...sliceNodes];

const s1 = write("story.json", story);
const s2 = write("notes.json", notesOut);
const s3 = write("markers.json", markers);
const s4 = write("endings.json", endings);
const s5 = write("expansions.json", expansions);

/* 这个目录里混着两种文件：**导出器每次重写的**，和**手写的**。
   分不清的后果是真实的 —— 我自己在验证「从零重跑」时就 rm data/*.json
   把 expansion_map.json 一起删了，导出器当场 ENOENT。
   所以让导出器每次重写一份清单，它永远不会过时。 */
const GENERATED = ["story.json", "notes.json", "markers.json", "endings.json",
  "expansions.json", "origin.sha256"];
const HANDWRITTEN = [
  ["expansion_map.json", "31 条扩写的锚点表。手写，一次性。**删了就得重编。**"],
  ["rooms.json", "房间定义（空间层）。手写，里程碑 4 起用。"],
  ["story_map.json", "节拍 → 路由（叙事层）。手写，里程碑 5 起用。"],
  ["quests.json", "任务定义。手写，里程碑 6 起用。"],
];
fs.writeFileSync(path.join(OUT, "说明.md"),
  "# data/ 目录说明\n\n" +
  "> 本文件由 `tools/export_story.js` **每次自动重写**，不要手改。\n\n" +
  "这个目录里混着两种文件。**跑 `rm data/*.json` 会把两种一起删掉** —— 别那么干。\n\n" +
  "## 导出器生成（每次 `node tools/export_story.js` 都会重写）\n\n" +
  GENERATED.map((f) => "- `" + f + "`").join("\n") + "\n\n" +
  "## 手写（导出器只读，不会覆盖）\n\n" +
  HANDWRITTEN.map(([f, why]) => "- `" + f + "` —— " + why).join("\n") + "\n\n" +
  "## 源在哪\n\n" +
  "- 原文：`D:\\claude\\时局图\\index.html`（**只读，一个字都不能改**）\n" +
  "- 扩写：桌面 `《时局图》剧本扩写读本.docx`（只读）\n",
  "utf8");

/* ---------------------- 报告 ---------------------- */

const sceneIds = Object.keys(scenes);                                  // 原文 + 扩写
const origIds = Object.keys(pristine);                                 // 只有原文
const expIds = sceneIds.filter((id) => scenes[id].expansion);

let beats = 0, beatTypes = {};
for (const id of origIds) for (const b of pristine[id].beats || []) { beats++; beatTypes[b.t] = (beatTypes[b.t] || 0) + 1; }
const allExpBeats = expansions.reduce((a, e) => a + e.beats.length, 0);      // 31 条全算
const expBeats = expIds.reduce((a, id) => a + scenes[id].beats.length, 0);   // 只算插进图的

const kb = (n) => (n / 1024).toFixed(1) + " KB";
console.log("=== 输出 ===");
console.log("  story.json       " + kb(s1));
console.log("  notes.json       " + kb(s2));
console.log("  markers.json     " + kb(s3));
console.log("  endings.json     " + kb(s4));
console.log("  expansions.json  " + kb(s5));

const fnShapes = new Map();
for (const a of astLog) {
  const key = JSON.stringify(a.node).replace(/\d+/g, "#");
  if (!fnShapes.has(key)) fnShapes.set(key, { shape: a.shape, node: a.node, n: 0 });
  fnShapes.get(key).n++;
}
console.log("\n=== 函数值字段 → 条件 AST ===");
console.log("  共 " + astLog.length + " 处，去重 " + fnShapes.size + " 种形状：");
for (const v of fnShapes.values()) {
  console.log("    " + String(v.n).padStart(2) + " 处  " + v.shape.padEnd(9) + " " + JSON.stringify(v.node));
}

const flags = new Set();
for (const id of sceneIds) for (const b of scenes[id].beats || [])
  if (b.t === "choice") for (const o of b.opts || []) if (o.flag) flags.add(o.flag);

console.log("\n=== 统计 ===");
console.log("  场景      " + sceneIds.length + "  = 原文 " + origIds.length + " + 扩写节点 " + expIds.length +
  (expIds.length !== expansions.length ? "（" + (expansions.length - expIds.length) + " 条未插入，见下）" : ""));
console.log("  节拍      " + beats + " 原文 + " + expBeats + " 扩写 = " + (beats + expBeats));
console.log("  节拍类型  " + Object.keys(beatTypes).sort().map((t) => t + ":" + beatTypes[t]).join("  "));
console.log("  结局      " + endings.length + "  印章 " + markers.length + "  史实注 " +
  noteCount + " 条 / " + Object.keys(notesOut).length + " 章");
console.log("  分支旗标  " + flags.size + "   史实注 ref 标记 " + refCount.n + " 处");
console.log("  起始场景  " + SCRIPT.start);

console.log("\n=== 扩写（31 条）===");
for (const e of expansions) {
  const inSlice = SLICE.includes(e.anchor) ? "◆" : " ";
  console.log("  " + inSlice + " " + String(e.run).padStart(2) + "  " + e.chapter + "  " +
    e.kind.padEnd(4) + "  " + e.title.padEnd(20) + "  " + e.at.padEnd(8) + e.anchor +
    "  (" + e.beats.length + " 拍)");
}
for (const e of expansions) {
  if (e.at !== "replace") continue;
  const sup = scenes[e.anchor].supersede || [];
  console.log("\n  ↺ 就地替换（不接线，由 supersede 顶替）：");
  for (const s of sup) {
    console.log("      第 " + e.run + " 条「" + e.title + "」顶掉 " + s.bid +
      "（候选 " + s.candidates.length + " 拍，取最长）");
    console.log("        原拍  「" + (scenes[e.anchor].beats[s.beat].x || "").slice(0, 46) + "」");
  }
}

/* ---------------------- 校验 ---------------------- */

let bad = 0;
const fail = (msg) => { bad++; console.log("  FAIL " + msg); };
const ok = (msg) => console.log("  ok   " + msg);

console.log("\n=== 引用完整性 ===");
{
  const dangling = [];
  for (const id of sceneIds) {
    const sc = scenes[id];
    if (typeof sc.next === "string" && !scenes[sc.next]) dangling.push(id + " --next--> " + sc.next);
    if (sc.next && typeof sc.next === "object" && sc.next.op === "if") {
      for (const k of ["then", "else"]) if (!scenes[sc.next[k]]) dangling.push(id + " --next." + k + "--> " + sc.next[k]);
    }
    for (const b of sc.beats || []) if (b.t === "choice")
      for (const o of b.opts || []) if (!scenes[o.to]) dangling.push(id + " --to--> " + o.to);
  }
  if (dangling.length) { for (const d of dangling) fail("悬空 " + d); }
  else ok("所有 next / to 引用都存在");
}

console.log("\n=== 节拍类型 ===");
{
  const badTypes = [];
  for (const id of sceneIds) for (const b of scenes[id].beats || [])
    if (!KNOWN_BEAT_TYPES.includes(b.t)) badTypes.push(id + ":" + b.t);
  if (badTypes.length) fail("未知节拍类型 " + badTypes.join(" "));
  else ok("全在支持范围内：" + KNOWN_BEAT_TYPES.join(" "));
}

console.log("\n=== 文本安全（Godot BBCode）===");
{
  const texts = collectTexts(scenes);
  const badCh = texts.filter((t) => /[\[\]{}]/.test(t.s) && !/\[ref\]|\[\/ref\]/.test(t.s));
  if (badCh.length) { for (const t of badCh.slice(0, 10)) fail("含 [] {}  " + t.where + "  " + JSON.stringify(t.s.slice(0, 60))); }
  else ok(texts.length + " 个文本字段不含 [] {}（不会被当成 BBCode 标签吃掉）");
}

console.log("\n=== 脊梁完整性（I1 / I2）===");
{
  /* splice 的契约只有两条：
       (甲) 原文的**内容**一个字不动
       (乙) 它只许改**路由**（场景的 next、选项的 to），且每条改过的边必须落在扩写节点上
     所以这里分两段验。把 next 也当内容一起比是错的 —— 那会把合法的插桩报成改动。 */

  // (甲) 内容比对。唯一要摘掉的是选项的 to（路由），其余逐字比。
  const contentKey = (b) => JSON.stringify(b, (k, v) => (k === "to" ? undefined : v));
  let drift = 0, checked = 0;
  for (const id of origIds) {
    if (!scenes[id]) { fail("原文场景丢了 " + id); drift++; continue; }
    const a = pristine[id].beats, b = scenes[id].beats;
    if (a.length !== b.length) { fail(id + " 节拍数变了 " + a.length + " → " + b.length); drift++; continue; }
    for (let i = 0; i < a.length; i++) {
      checked++;
      if (contentKey(a[i]) !== contentKey(b[i])) {
        fail(id + " 第 " + i + " 拍内容被改动了");
        drift++; break;
      }
    }
  }
  if (!drift) ok("原文 " + origIds.length + " 场景 / " + checked + " 拍的内容逐字未变");

  // (乙) 路由比对
  const edgesOf = (sc, id) => {
    const out = [];
    const nx = sc.next;
    if (typeof nx === "string") out.push(id + " → " + nx);
    else if (nx && nx.op === "if") { out.push(id + " → " + nx.then); out.push(id + " → " + nx.else); }
    for (const b of sc.beats || []) if (b.t === "choice")
      for (const o of b.opts || []) out.push(id + ":choice → " + o.to);
    return out;
  };
  const isExp = (t) => typeof t === "string" && !!scenes[t] && !!scenes[t].expansion;
  const before = new Set(), after = new Set();
  for (const id of origIds) {
    for (const e of edgesOf(pristine[id], id)) before.add(e);
    for (const e of edgesOf(scenes[id], id)) after.add(e);
  }
  const added = [...after].filter((e) => !before.has(e));
  const removed = [...before].filter((e) => !after.has(e));

  const strayAdd = added.filter((e) => !isExp(e.split(" → ")[1]));
  if (strayAdd.length) { for (const s of strayAdd) fail("多出一条不指向扩写节点的边：" + s); }
  else ok("新增 " + added.length + " 条边，全部指向扩写节点");

  const strayCut = [];
  for (const e of removed) {
    const from = e.split(" → ")[0], fromId = from.split(":")[0];
    const outs = edgesOf(scenes[fromId], fromId).filter((x) => x.startsWith(from + " → "));
    if (!outs.some((x) => isExp(x.split(" → ")[1]))) strayCut.push(e);
  }
  if (strayCut.length) { for (const s of strayCut) fail("这条边被摘掉却没有换成扩写节点：" + s); }
  else ok("改写 " + removed.length + " 条边，全部换成了扩写节点");
}

console.log("\n=== 读本 ↔ 原文 逐字比对（凡例「一字未改」的机器验证）===");
{
  /* 凡例第一条：读本里不带标记的段落，均为游戏原文，一字未改。
     这是整份扩写读本的地基 —— 如果它不成立，那么「扩写是加性的」也就跟着垮。
     所以必须机器验，不能信。

     做法：把读本**非扩写**段落拼成一个整块，再拿原文每一拍去里面找。
     找到 = 原文确实原样出现在读本里。

     实测结论：全书 2200 个散文节拍，2199 个命中；
     唯一落空的那一拍正是第 14 条 replace 所顶替的（它被并进了扩写段落）。
     也就是说，这条检查与 replace 的语义**互相印证** —— 两边都对上了。 */
  const blob = docxParas.filter((p) => !p.expansion).map((p) => p.text).join("");
  const hay = norm(blob);
  const miss = [];
  let tot = 0;
  for (const id of origIds) {
    for (const b of pristine[id].beats) {
      if (b.t === "end" || b.t === "map") continue;          // 结局卡/揭章是引擎渲染的，不是散文
      if (b.t === "choice") {
        for (const o of b.opts || []) { tot++; if (!hay.includes(norm(o.x))) miss.push(id + " 选项: " + String(o.x).slice(0, 40)); }
        continue;
      }
      const t = b.x || b.body || b.text;
      if (typeof t !== "string") continue;
      tot++;
      if (!hay.includes(norm(t))) miss.push(id + "/" + b.t + ": " + t.replace(/\s+/g, " ").slice(0, 56));
    }
  }
  console.log("  读本非扩写正文 " + blob.replace(/\s/g, "").length + " 字");
  if (!miss.length) ok("原文 " + tot + " 个散文节拍全部逐字出现在读本里");
  else {
    console.log("  命中 " + (tot - miss.length) + " / " + tot + "，落空 " + miss.length + "：");
    for (const m of miss) console.log("      落空  " + m);
    // 落空必须**全部**能被 replace 解释掉，否则就是真丢了东西
    const bad = [];
    for (const m of miss) {
      const sid = m.split("/")[0];
      const sup = (scenes[sid] && scenes[sid].supersede) || [];
      if (!sup.length) bad.push(m);
    }
    if (bad.length) { for (const b of bad) fail("这一拍在读本里找不到，且没有任何 replace 解释得了：" + b); }
    else ok("落空的 " + miss.length + " 拍全部由 replace 顶替解释 —— 与第 14 条的语义互相印证");
  }
}

console.log("\n=== 扩写保真 ===");
{
  const dup = new Set(), ids = [];
  for (const e of expansions) for (const b of e.beats) { if (dup.has(b.bid)) fail("bid 重复 " + b.bid); dup.add(b.bid); ids.push(b.bid); }
  const runs = expansions.map((e) => e.run).sort((a, b) => a - b);
  if (runs.join(",") !== Array.from({ length: 31 }, (_, i) => i + 1).join(",")) fail("扩写 run 编号不是 1..31");
  else ok("31 条扩写、共 " + ids.length + " 拍，bid 无重复");

  const kinds = {};
  for (const e of expansions) kinds[e.kind] = (kinds[e.kind] || 0) + 1;
  ok("四类分布 " + Object.entries(kinds).map(([k, v]) => k + ":" + v).join("  "));
}

console.log("\n=== 切片范围 ===");
{
  let sb = 0;
  const missing = SLICE.filter((id) => !scenes[id]);
  if (missing.length) fail("切片场景不存在 " + missing.join(" "));
  for (const id of SLICE) if (scenes[id]) sb += scenes[id].beats.length;
  const sl = expansions.filter((e) => SLICE.includes(e.anchor));
  ok("切片 " + SLICE.length + " 场景 / " + sb + " 拍（原文）");
  ok("切片内扩写 " + sl.length + " 条：" + sl.map((e) => e.title).join("、"));
  const fnInSlice = SLICE.some((id) => scenes[id] && JSON.stringify(scenes[id]).includes('"op"'));
  ok(fnInSlice ? "切片内**含**条件 AST（需在里程碑 2 前实现求值器）"
               : "切片内无任何条件 AST —— 最难的求值器不在关键路径上");
}

/* ---------------------- 断言 ---------------------- */

// 期望值全部针对**原文**（pristine）。扩写是加性的，不进这几项 ——
// 这样将来往读本里再添条目，不会把这些锚定原文的断言弄红。
const EXPECT = { scenes: 81, beats: 2193, chapters: 6, endings: 5, markers: 6, notes: 52, flags: 26,
                 fnFields: 18, fnShapes: 6,
                 expansions: 31, expNodes: 31, expLinked: 30, expSupersede: 1,
                 allExpBeats: 182, expBeats: 182, pending: 0,
                 totalScenes: 112, totalBeats: 2375,
                 sliceScenes: 23, sliceBeats: 477, sliceExpansions: 9, sliceNodes: 9 };
const chapters = new Set(Object.values(pristine).map((s) => s.ch).filter(Boolean));
const ACTUAL = {
  scenes: origIds.length,
  beats: beats,
  chapters: chapters.size, endings: endings.length, markers: markers.length, notes: noteCount,
  flags: flags.size,
  fnFields: astLog.length, fnShapes: fnShapes.size,
  expansions: expansions.length, expNodes: expIds.length,
  expLinked: expansions.length - expansions.filter((e) => e.at === "replace").length,
  expSupersede: expansions.filter((e) => e.at === "replace").length,
  allExpBeats: allExpBeats, expBeats: expBeats, pending: pending.length,
  totalScenes: sceneIds.length, totalBeats: beats + expBeats,
  sliceScenes: SLICE.length,
  sliceBeats: SLICE.reduce((a, id) => a + (pristine[id] ? pristine[id].beats.length : 0), 0),
  sliceExpansions: expansions.filter((e) => SLICE.includes(e.anchor)).length,
  sliceNodes: sliceNodes.length,
};
console.log("\n=== 原文指纹 ===");
{
  /* index.html 的 sha256 太粗 —— 引擎那段 IIFE 改一个空格它也会变，
     而「不能改」指的其实是**剧本**。所以另锁一份只含原文剧本的指纹。
     这份指纹一旦变动，就是剧本漂了，必须查清原因才能刷新。 */
  const originHash = crypto.createHash("sha256")
    .update(JSON.stringify({ start: SCRIPT.start, scenes: pristine })).digest("hex");
  const lockPath = path.join(OUT, "origin.sha256");
  const prev = fs.existsSync(lockPath) ? fs.readFileSync(lockPath, "utf8").trim() : null;
  if (prev === null) {
    fs.writeFileSync(lockPath, originHash + "  《时局图》原文剧本（81 场景 / 2193 拍）\n", "utf8");
    console.log("  首次锁定  " + originHash.slice(0, 16) + "…  → data/origin.sha256");
  } else if (prev.split(/\s/)[0] === originHash) {
    ok("原文指纹未变  " + originHash.slice(0, 16) + "…");
  } else {
    fail("原文剧本漂了！\n       锁定值 " + prev.split(/\s/)[0] + "\n       当前值 " + originHash +
      "\n       index.html 是只读源。要么它被改了，要么导出器读错了地方 —— 两种都得先查清。");
  }
  console.log("  index.html 全文件 sha256  " + sha256.slice(0, 16) + "…（含引擎，仅供参考）");
}

console.log("\n=== 断言 ===");
for (const k of Object.keys(EXPECT)) {
  const good = ACTUAL[k] === EXPECT[k];
  if (!good) bad++;
  console.log("  " + (good ? "ok  " : "FAIL ") + k.padEnd(15) + "期望 " + String(EXPECT[k]).padStart(5) +
    "  实际 " + ACTUAL[k]);
}

console.log(bad ? "\n有 " + bad + " 项不合格" : "\n全部通过");
process.exit(bad ? 1 : 0);
