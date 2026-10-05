// webcheck.js —— 把导出的 Web 包真的在浏览器里跑一遍，截图带回来。
//
// 用法：
//     node build/serve.js &                    # 先起本地服务
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

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  async evalJS(expression) {
    const r = await this.send("Runtime.evaluate", {
      expression, returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
    return r.result.value;
  }

  async shot(file) {
    const r = await this.send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(file, Buffer.from(r.data, "base64"));
    return fs.statSync(file).size;
  }

  async key(key, code, vk) {
    const base = { windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, code, key };
    await this.send("Input.dispatchKeyEvent", { type: "keyDown", ...base });
    await this.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  }

  async click(x, y) {
    const base = { x, y, button: "left", clickCount: 1 };
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
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

  const report = { url: URL_, boot_ms, booted, shots: [], errors: [], logs: [] };

  if (!booted) {
    // 没开起来的话，加载屏上通常会写原因（找不到 pck、WebGL 不支持…）
    report.notice = await cdp.evalJS(
      "(document.getElementById('status-notice')||{}).innerText || ''").catch(() => "");
    await cdp.shot(path.join(OUT, "00-没开机.png"));
    report.shots.push("00-没开机.png");
  } else {
    // 开机之后再稳两帧，让第一章的字先画上去
    await sleep(1500);
    await cdp.shot(path.join(OUT, "01-开场.png"));
    report.shots.push("01-开场.png");

    // 按空格推进。用「点击 + 空格」交替 —— 两条输入通路都要走到，
    // 网页上鼠标那条尤其重要（玩家十有八九是用鼠标点的）。
    //
    // 帧数由 argv[4] 给，默认 100。100 下大约走到第一章中段，
    // 章节卡、引文、书信、选择、立绘都该出场过了。
    const steps = Number(process.argv[4] || 100);
    const shotAt = new Set([3, 10, 20, 34, 50, 70, 90, steps]);
    const beats = [];
    for (let i = 0; i < steps; i++) {
      if (i % 2 === 0) await cdp.key(" ", "Space", 32);
      else await cdp.click(640, 620);
      await sleep(450);
      if (shotAt.has(i + 1)) {
        const name = `${String(i + 1).padStart(3, "0")}-推进${i + 1}.png`;
        await cdp.shot(path.join(OUT, name));
        report.shots.push(name);
      }
      const t = await cdp.evalJS(
        "(()=>{const c=document.querySelector('canvas');return c?c.width+'x'+c.height:'none'})()");
      beats.push(t);
    }
    report.canvas = beats[beats.length - 1];
    report.canvas_stable = beats.every((b) => b === beats[0]);
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
