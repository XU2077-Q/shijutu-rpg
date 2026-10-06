// webcheck.js —— 把导出的 Web 包真的在浏览器里跑一遍，截图带回来。
//
// 用法：
//     node tools/serve.js &                    # 先起本地服务（默认 :8765 → build/web）
//     node tools/webcheck.js [url] [outdir]
//
// 【为什么非得真跑一遍浏览器】
// headless 的 Godot 用的是**哑渲染器**：它跑测试、跑逻辑都对，但一个像素都不出。
// 于是有一整类问题它永远看不见 —— 中文是不是豆腐块、立绘有没有画到屏幕外、
// 网页上打字机会不会因为 rAF 的节奏不同而卡住。这些只有真的浏览器能验。
//
// 【为什么不用 --screenshot】
// Edge 自带的 `--screenshot` 配 `--virtual-time-budget` 是**按虚拟时间**截的：
// 计时器被快进了，但 39 MB 的 wasm 编译是真实的 CPU 时间，快进不了。
// 结果每次都在「GODOT 加载中」那一屏截到。所以这里改成用 CDP 说话 ——
// 可以等真的开机、可以读控制台、可以按键，最后才截图。
//
// 【Godot 开机的信号是什么】
// index.html 里那段加载器在游戏起来时会 `statusOverlay.remove()`。
// 所以「开机了」= `document.getElementById('status') === null`。
// 不是等一个固定的秒数 —— 等秒数在慢机器上会假阴性。

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const URL_ = process.argv[2] || "http://127.0.0.1:8765/index.html";
const OUT = process.argv[3] || "build/shots";
const PORT = 9333;
const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";

// 开机上限。wasm 编译在冷机器上可能十几秒，给足。
const BOOT_TIMEOUT_MS = 180000;

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// ---------------------------------------------------------------- CDP 小客户端
//
// 只用得到四五个方法，犯不着拉一个 puppeteer 进来（那会带几十兆的依赖，
// 而整个工程到目前为止是零依赖的）。WebSocket 是 Node 22 起的内建全局。

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
    this.logs = [];
    this.errors = [];
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id !== undefined) {
        const p = this.pending.get(msg.id);
        if (!p) return;
        this.pending.delete(msg.id);
        msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
        return;
      }
      this._event(msg);
    });
  }

  _event(msg) {
    const m = msg.method;
    if (m === "Runtime.consoleAPICalled") {
      const text = (msg.params.args || [])
        .map((a) => (a.value !== undefined ? String(a.value) : a.description || a.type))
        .join(" ");
      this.logs.push({ kind: msg.params.type, text });
    } else if (m === "Runtime.exceptionThrown") {
      const d = msg.params.exceptionDetails;
      this.errors.push(
        (d.exception && (d.exception.description || d.exception.value)) || d.text || "未知异常");
    } else if (m === "Log.entryAdded") {
      const e = msg.params.entry;
      const text = `${e.level}: ${e.text}`;
      this.logs.push({ kind: e.level, text });
      if (e.level === "error") this.errors.push(text);
    }
  }

  // 【为什么每条消息都要有超时】
  // CDP 是「发了不一定有人应」的：页面在编译 wasm、截图时卡住、
  // 或者浏览器进程刚好没了，那条 send() 就**永远不 resolve**。
  // 表现出来是整个自查脚本挂死，不报错、不退出 —— 上一次就挂在这儿，
  // 只能靠人盯着文件列表发呆。所以给它一个上限，超时就把
  // 「是哪一条消息没回话」说出来。
  send(method, params = {}, timeoutMs = 45000) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} 超过 ${timeoutMs}ms 没回话`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
    });
  }

  async evalJS(expression) {
    const r = await this.send("Runtime.evaluate", {
      expression, returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result.value;
  }

  // 截图。**会重试，失败了也不抛**。
  //
  // 【为什么不能让它把整趟走查带崩】Page.captureScreenshot 偶发不回话
  // （SwiftShader 软件渲染下更常见：正好在切场景、编译着色器的时候截，
  // 浏览器那头会卡住不答）。一次没截到不该让后面十几张全没了 ——
  // 自查的目的是「看一眼画面对不对」，不是「截图本身必须成功」。
  // 所以：试两遍，还不行就记进 report 里，继续往下走。
  async shot(file, report) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const r = await this.send("Page.captureScreenshot", { format: "png" }, 20000);
        fs.writeFileSync(file, Buffer.from(r.data, "base64"));
        return fs.statSync(file).size;
      } catch (e) {
        if (attempt === 2) {
          const msg = `截图失败 ${path.basename(file)}：${e.message}`;
          console.error(`  ! ${msg}`);
          if (report) report.shot_errors.push(msg);
          return 0;
        }
        await sleep(800);
      }
    }
  }

  async key(key, code, vk) {
    const base = { windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, code, key };
    await this.send("Input.dispatchKeyEvent", { type: "keyDown", ...base });
    await this.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  }

  // 按住一段时间再抬 —— 验「暂停时不许走」要用：走不走得动，得给够一帧以上
  // 才看得出。瞬间 down+up 即便没被挡住，也只挪得动几像素，截图分不出来。
  async holdKey(key, code, vk, ms) {
    const base = { windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, code, key };
    await this.send("Input.dispatchKeyEvent", { type: "keyDown", ...base });
    await sleep(ms);
    await this.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  }

  async click(x, y) {
    const base = { x, y, button: "left", clickCount: 1 };
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
  }

  // 画布在页面里的位置和大小（CSS 像素 —— dispatchMouseEvent 用的就是这套）。
  //
  // 【为什么每次点之前都要问一遍，而不是量一次存下来】
  // 页面尺寸会因为浏览器窗口、缩放、甚至截图时机而变。量一次存下来的话，
  // 一旦它变了，后面所有点击都会**静默地**落在错的地方 ——
  // 截图上只表现为「点了没反应」，看起来像是走路的代码坏了。
  async canvasBox() {
    return this.evalJS(`(() => {
      const c = document.querySelector('canvas');
      if (!c) return null;
      const r = c.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height,
               vw: window.innerWidth, vh: window.innerHeight, dpr: window.devicePixelRatio,
               bw: c.width, bh: c.height };
    })()`);
  }

  // 按**画布比例**点，不写死像素。
  //
  // 【写死像素踩过什么】房间里所有坐标都是 0~1 归一化的，映射到画布上是
  //   画布CSS位置 + 比例 × 画布CSS尺寸
  // 而画布的 CSS 尺寸**不等于** Godot 的视口尺寸：工程用 stretch/aspect=expand，
  // 视口会被撑到「基准尺寸与窗口尺寸的较大者」（这里实测是 1440×720），
  // 画布再把它整体缩到 CSS 尺寸（1248×624，约 0.867 倍）。
  // 上一版按 1280×720 写死坐标，于是 (860, 640) 这个 y 直接落到画布**外面** ——
  // 浏览器把点击给了 body，游戏一个事件都没收到。按比例点就没有这个问题：
  // 不管缩放多少，0.68 永远是 0.68。
  async clickAtFraction(box, fx, fy) {
    if (!box) throw new Error("页面上找不到 canvas");
    await this.click(Math.round(box.x + fx * box.w), Math.round(box.y + fy * box.h));
  }
}

// ---------------------------------------------------------------- 起浏览器

async function launch() {
  if (!fs.existsSync(EDGE)) throw new Error("找不到 Edge：" + EDGE);
  const profile = path.join(__dirname, "..", "build", "_webcheck_profile");
  const child = spawn(EDGE, [
    "--headless=new",
    "--no-first-run",
    "--no-default-browser-check",
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    // 无头环境没有真显卡，走 SwiftShader 软件渲染。
    // 不显式开这个的话 WebGL2 上下文会直接创建失败，
    // 页面停在加载屏上，看起来像是「游戏坏了」，其实是浏览器没给画布。
    "--enable-unsafe-swiftshader",
    "--use-angle=swiftshader",
    "--window-size=1280,720",
    "about:blank",
  ], { stdio: "ignore" });

  // 等调试端口起来
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const list = await r.json();
      const page = list.find((t) => t.type === "page");
      if (page) return { child, page };
    } catch (_) { /* 还没起来 */ }
    await sleep(200);
  }
  child.kill();
  throw new Error("Edge 的调试端口一直没起来");
}

// ---------------------------------------------------------------- 主流程

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const { child, page } = await launch();
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener("open", res, { once: true });
    ws.addEventListener("error", rej, { once: true });
  });
  const cdp = new CDP(ws);

  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Log.enable");

  const t0 = Date.now();
  await cdp.send("Page.navigate", { url: URL_ });

  // 等开机
  let booted = false;
  while (Date.now() - t0 < BOOT_TIMEOUT_MS) {
    await sleep(500);
    try {
      booted = await cdp.evalJS(
        "document.getElementById('status') === null && !!document.querySelector('canvas')");
    } catch (_) { /* 导航中，DOM 还不在 */ }
    if (booted) break;
  }
  const boot_ms = Date.now() - t0;

  const report = {
    url: URL_, boot_ms, booted,
    shots: [], shot_errors: [], errors: [], logs: [],
  };

  if (!booted) {
    // 没开起来的话，加载屏上通常会写原因（找不到 pck、WebGL 不支持…）
    report.notice = await cdp.evalJS(
      "(document.getElementById('status-notice')||{}).innerText || ''").catch(() => "");
    await cdp.shot(path.join(OUT, "00-没开机.png"), report);
    report.shots.push("00-没开机.png");
  } else {
    // 开机之后再稳两帧，让标题屏画上去
    await sleep(1500);
    await cdp.shot(path.join(OUT, "01-标题屏.png"), report);
    report.shots.push("01-标题屏.png");

    // 标题屏上「新 的 一 局」默认拿着焦点 —— 回车就是开局。
    // 等两秒让场景切换、第一拍摆出来，再进推进循环。
    await cdp.key("Enter", "Enter", 13);
    await sleep(2000);

    // 按空格推进。用「点击 + 空格」交替 —— 两条输入通路都要走到，
    // 网页上鼠标那条尤其重要（玩家十有八九是用鼠标点的）。
    //
    // 帧数由 argv[4] 给，默认 100。100 下大约走到第一章中段，
    // 章节卡、引文、书信、选择、立绘都该出场过了。
    const steps = Number(process.argv[4] || 100);
    const shotAt = new Set([3, 10, 20, 34, 50, 70, 80, 85, 90, steps]);
    const beats = [];
    for (let i = 0; i < steps; i++) {
      if (i % 2 === 0) await cdp.key(" ", "Space", 32);
      // 【为什么点屏幕正中，不点底下】
      // 原来是 (640, 620) —— 贴着画布底边。那时靠空格也能过选择，
      // 所以点哪儿无所谓。后来空格在选项摆着的时候被 ChoiceMenu 吞了
      // （理由见 choice_menu.gd：一路按空格的玩家会把选项按掉），
      // 过选择就只剩鼠标这一条路 —— 而选项按钮是**居中**摆的，
      // 底下那一下落在按钮外面，只是把遮罩点了一下，什么也没发生。
      // 于是这段 VN 走查会停在第一个选择上，后面几十张截图全是同一屏。
      // 点正中：平时落在对话框上照常推进，摆着选项时正好落在第一颗按钮上。
      else await cdp.click(640, 310);
      await sleep(450);
      if (shotAt.has(i + 1)) {
        const name = `${String(i + 1).padStart(3, "0")}-推进${i + 1}.png`;
        await cdp.shot(path.join(OUT, name), report);
        report.shots.push(name);
      }
      const t = await cdp.evalJS(
        "(()=>{const c=document.querySelector('canvas');return c?c.width+'x'+c.height:'none'})()");
      beats.push(t);
    }
    report.canvas = beats[beats.length - 1];
    report.canvas_stable = beats.every((b) => b === beats[0]);

    // ---------------------------------------------------------------- 走动演示
    //
    // 【为什么要单跑这一段】
    // 上面那一段走的是纯 VN。里程碑 5 的成品是「读一场 → 走一段 → 查一查」，
    // 它有一整类 headless 看不见的问题：小人画没画出来、热点框对不对得上、
    // 点一下会不会走过去、剧情在缝里等的时候 NPC 还说不说得上话。
    // 这些只有真浏览器 + 截图能验。
    //
    // 【里程碑 5 改了入口，这一段跟着改了】
    // 里程碑 4 时「走 动」直接把人丢进广和茶楼乱走。现在它走的是**脊梁**：
    // 起点是题记（p_intro，没有房间，压在一块暗底上演），
    // 演完自动接上广和茶楼（p_tea，36 拍），演到那儿**停住**，
    // 等玩家自己走到下一场戏所在的房间。所以这里要多一段「按过前两场」。
    //
    // 【里程碑 6 改了 Esc 的去处】
    // Esc 不再直接回标题 —— 它在 VN / 房间两个屏里都开**暂停菜单**
    // （继续游戏 / 存档 / 读档 / 时局图 / 史实注 / 任务 / 设置 / 返回标题）。
    // 所以先在 VN 里把暂停菜单和它的子面板挨个验一遍，再点「返 回 标 题」
    // 回标题屏；然后方向键两下把焦点移到「走 动」。
    // 按钮顺序是 新的一局 / 续前一局 / 走动 / 设置，开局时焦点在第一颗，
    // 所以 Down 两下 = 走动。
    //
    // 【为什么要先确认「续 前 一 局」是亮的】Godot 的焦点导航**跳过禁用控件**。
    // 自动存档不在的时候「续 前 一 局」是灰的，两下 Down 会落到「设 置」上。
    // 上面那一段 VN 走查必然落了自动存档，所以这里两下是准的 ——
    // 但这条依赖要写下来，不然哪天改了 VN 屏的存档时机，这里会莫名其妙地
    // 走进设置面板，而截图上只是「多了一个面板」，不容易一眼看出是这儿的问题。
    if (process.argv.includes("--room")) {
      // 暂停按钮在面板里的纵向比例（fx 一律 0.5：按钮 320 宽、面板居中）。
      // 布局：标题 + 间隔 + 八颗 48px 按钮、间隔 12，整体在视口里垂直居中。
      // 紧边距按钮（46px）+ 间隔 10，整面板 ≈556 高、垂直居中。
      const B = { save: 0.349, load: 0.426, map: 0.504, notes: 0.582,
                  quests: 0.660, settings: 0.738, title: 0.815 };
      const vbox = await cdp.canvasBox();
      const clickPause = async (fy, name) => {
        const b = (await cdp.canvasBox()) || vbox;
        await cdp.clickAtFraction(b, 0.5, fy);
        await sleep(900);
        await cdp.shot(path.join(OUT, name), report);
        report.shots.push(name);
      };

      // 万一百拍走完时正摆着选项，先点掉它（选项摆着时 Esc 不开暂停）。
      await cdp.click(640, 310);
      await sleep(700);

      await cdp.key("Escape", "Escape", 27);
      await sleep(1000);
      await cdp.shot(path.join(OUT, "40-VN中暂停（八个按钮）.png"), report);
      report.shots.push("40-VN中暂停（八个按钮）.png");

      // 挨个开子面板再 Esc：Esc 先关子面板、回主菜单，不能连带继续游戏
      //（这条在单测里按真实派发顺序验过，浏览器里再看一眼画面）。
      await clickPause(B.map, "41-时局图（未揭的只显问号）.png");
      await cdp.key("Escape", "Escape", 27);
      await sleep(600);
      await clickPause(B.notes, "42-史实注一览.png");
      await cdp.key("Escape", "Escape", 27);
      await sleep(600);
      await clickPause(B.quests, "43-任务一览.png");
      await cdp.key("Escape", "Escape", 27);
      await sleep(600);
      await clickPause(B.save, "44-存档格（覆写要两下）.png");
      await cdp.key("Escape", "Escape", 27);
      await sleep(600);
      await clickPause(B.settings, "45-设置（文字速度与全屏）.png");
      await cdp.key("Escape", "Escape", 27);
      await sleep(600);
      await cdp.shot(path.join(OUT, "46-Esc后回到暂停主菜单.png"), report);
      report.shots.push("46-Esc后回到暂停主菜单.png");

      // 返回标题，再进「走动」。
      await clickPause(B.title, "47-返回标题屏.png");
      await sleep(1200);
      for (let i = 0; i < 2; i++) { await cdp.key("ArrowDown", "ArrowDown", 40); await sleep(250); }
      await cdp.shot(path.join(OUT, "50-标题屏-焦点在走动.png"), report);
      report.shots.push("50-标题屏-焦点在走动.png");
      await cdp.key("Enter", "Enter", 13);
      await sleep(2500);
      await cdp.shot(path.join(OUT, "51-题记（没有房间，压在暗底上）.png"), report);
      report.shots.push("51-题记（没有房间，压在暗底上）.png");

      const box = await cdp.canvasBox();
      report.canvas_box = box;
      if (box) {
        console.log(`  画布：CSS ${box.w}×${box.h} @(${box.x},${box.y})，`
          + `缓冲区 ${box.bw}×${box.bh}，页面 ${box.vw}×${box.vh} @${box.dpr}x`);
      }

      // 按过题记 + 广和茶楼，直到剧情停在场景缝里。
      //
      // 【为什么是 110 下】
      // 题记 7 拍 + 茶楼 36 拍 = 43 拍，而**每拍最多要按两下**
      // （第一下收完打字机，第二下才翻页），最坏 86 下。
      // 再加两处余量：进茶楼会先出序章「春 愁」那张章节卡，
      // 卡摆着的时候按空格只是让它淡出（0.7 秒），那几下的间隔里按了不算数。
      //
      // 【按多了会不会出事】不会。剧情停下来之后 press() 走到底
      // `if not _playing: return`，多按的每一下都是空操作。
      // 所以这里宁可多按 —— 少按才会截出「还停在茶楼第一句」的假现场。
      for (let i = 0; i < 110; i++) { await cdp.key(" ", "Space", 32); await sleep(160); }
      await sleep(1200);
      await cdp.shot(path.join(OUT, "52-茶楼·剧情停在缝里（左上任务条）.png"), report);
      report.shots.push("52-茶楼·剧情停在缝里（左上任务条）.png");

      // ---- 里程碑 6 的房间侧验收：暂停锁走路、空格落空有提示 ----------------
      //
      // 先在暂停里按住「下」1.2 秒。PauseMenu 吞掉所有 walk_* 键 —— 若没吞，
      // 小人会往下挪约 250px，截图跟 52 一对就看得出来。
      await cdp.key("Escape", "Escape", 27);
      await sleep(900);
      await cdp.shot(path.join(OUT, "52-1-房间里暂停.png"), report);
      report.shots.push("52-1-房间里暂停.png");
      await cdp.holdKey("ArrowDown", "ArrowDown", 40, 1200);
      await cdp.key("Escape", "Escape", 27);
      await sleep(700);
      await cdp.shot(path.join(OUT, "52-2-继续后小人应当还在出生点.png"), report);
      report.shots.push("52-2-继续后小人应当还在出生点.png");

      // 玩家反馈：脊梁缝里按空格，附近没有热点时不再是「按了没反应」，
      // 而会闪一句「附近没有能看的东西，走一走试试」。
      await cdp.key(" ", "Space", 32);
      await sleep(350);
      await cdp.shot(path.join(OUT, "52-3-空格落空的提示.png"), report);
      report.shots.push("52-3-空格落空的提示.png");
      await sleep(1400); // 等提示淡出，免得遮后面的截图

      // 点几处地方：一个 NPC、一个可查物件、一个出口。
      // 坐标是**归一化比例**，与 rooms.json 里写的同一套数：
      // 顺子 [0.30..0.38, 0.58..0.80]、茶盏 [0.12..0.19, 0.60..0.66]、
      // 楼梯 [0.62..0.74, 0.86..0.95]。点在热点上会「走过去 + 自动开口」。
      //
      // 第三处（楼梯）是**里程碑 5 的验收点**：楼梯通向宣武门外大街，
      // 而下一场戏 p_choice1 正好在那儿 —— 走过去的瞬间剧情自动接上，
      // 演四拍之后把选项摆出来。截出来就是「走对了地方，剧情自己接着演」。
      const spots = [
        [0.34, 0.69, "53-点顺子（走过去+开口）"],
        [0.155, 0.63, "54-点茶盏（翻史实注）"],
        [0.68, 0.90, "55-点楼梯（走进宣武门，剧情接上）"],
      ];
      for (const [fx, fy, name] of spots) {
        const b = (await cdp.canvasBox()) || box;
        console.error(`  · 走动自查：点画布 ${(fx * 100).toFixed(1)}% / ${(fy * 100).toFixed(1)}%`
          + ` → ${name}`);
        await cdp.clickAtFraction(b, fx, fy);
        // 【为什么是 4.5 秒】
        // 点到物件不是「瞬移」：小人要先走过去，走到了才开口 / 换房间。
        // 最远的一段（茶盏 → 楼梯）在视口坐标里约 785 px，按 Walker.SPEED=215
        // 算要 3.6 秒。上一版等 2.6 秒 —— 截出来的是**半路上的一帧**：
        // 房间还没换，看起来像是「点了没反应」，其实只是还没走到。
        // 这种假失败最费时间：会让人去查一段根本没坏的代码。
        await sleep(4500);
        await cdp.shot(path.join(OUT, `${name}.png`), report);
        report.shots.push(`${name}.png`);

        // 把对话框 / 史实注按掉，好让下一次点击真的落在房间里。
        //
        // 【为什么是 14 下，不是 6 下 —— 这个数是用错出来的】
        // 上一版按 6 下，结果第三次点击什么也没发生。原因是顺子那段扩写有四拍，
        // 而**每一拍要按两下**：第一下收完打字机，第二下才翻页。
        // 6 下正好停在第四拍上，`_playing` 还是 true —— 于是第三次点击
        // 被这段还没播完的对话吃掉了（进了 press()，不是走进房间）。
        // 屏幕上看只是「点了没反应」，像是走路坏了。
        // 14 下 = 四拍 × 2 + 余量，足够把最长的一段按干净。
        //
        // 【这一段的头几秒在验里程碑 5 修的那个漏洞】
        // 剧情停在缝里的时候跟顺子说话，press() 一度被 `if _spine` 那条分支
        // 抢去调 BeatRunner.advance() —— 而推进器正停着，那是个空操作，
        // 于是顺子那四拍永远翻不过去。下面这 14 下真能按完，
        // 说明修对了；截图上「53-点顺子…按掉之后」若还停在第一句，就是又坏了。
        for (let i = 0; i < 14; i++) { await cdp.key(" ", "Space", 32); await sleep(300); }
        await cdp.shot(path.join(OUT, `${name}-按掉之后.png`), report);
        report.shots.push(`${name}-按掉之后.png`);
      }

      // 走到宣武门之后剧情自己接上：p_choice1 四拍，第四拍是选项。
      for (let i = 0; i < 8; i++) { await cdp.key(" ", "Space", 32); await sleep(400); }
      await cdp.shot(path.join(OUT, "56-选项摆在房间里.png"), report);
      report.shots.push("56-选项摆在房间里.png");
    }
  }

  report.logs = cdp.logs;
  report.errors = cdp.errors;
  fs.writeFileSync(path.join(OUT, "report.json"), JSON.stringify(report, null, 2));

  ws.close();
  child.kill();

  // 打印一份给人看的
  console.log(`\n  开机：${booted ? "成功" : "**失败**"}（${(boot_ms / 1000).toFixed(1)} 秒）`);
  if (report.canvas) console.log(`  画布：${report.canvas}${report.canvas_stable ? "" : "（尺寸在变）"}`);
  if (report.notice) console.log(`  页面提示：${report.notice}`);
  console.log(`  截图：${report.shots.length} 张 → ${OUT}`);
  const godotLogs = report.logs.filter((l) => l.kind !== "verbose");
  if (godotLogs.length) {
    console.log(`  控制台：`);
    for (const l of godotLogs.slice(0, 30)) console.log(`    [${l.kind}] ${l.text}`);
  }
  if (report.errors.length) {
    console.log(`  **报错 ${report.errors.length} 条**：`);
    for (const e of report.errors.slice(0, 20)) console.log(`    ${e.split("\n")[0]}`);
    process.exitCode = 1;
  } else {
    console.log(`  控制台没有报错。`);
  }
  console.log("");
}

main().catch((e) => { console.error(e); process.exit(2); });
