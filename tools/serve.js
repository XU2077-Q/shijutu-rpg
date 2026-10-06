// serve.js —— 零依赖静态服务，专供浏览器自查（tools/webcheck.js）。
//
// 用法：
//     node tools/serve.js [端口] [目录]
// 默认：127.0.0.1:8765，根目录 build/web。
//
// 【为什么自己写一个，不装 http-server / live-server】
// 整个工程到现在是零运行时依赖的（tools/*.js 只用 Node 内建模块）。
// 为「起个静态目录」拉几十兆依赖，不值当；几十行 Node 足够。
//
// 【为什么发 no-store】
// 自查要反复重新导出、反复跑。浏览器若把 44 MB 的 index.pck 缓存住，
// 跑的就是旧包，截图全对但验的是昨天的代码 —— 最糟的那种假绿。

const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.argv[2] || 8765);
const ROOT = path.resolve(process.argv[3] || path.join(__dirname, "..", "build", "web"));

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split("?")[0]);
  // 手拼路径、不许出根：防的是手滑与脚本拼错，不是真攻击者（只绑回环）。
  const file = path.normalize(path.join(ROOT, rel));
  if (!file.startsWith(ROOT)) {
    res.writeHead(403); res.end("forbidden"); return;
  }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("没有这个文件：" + rel);
      return;
    }
    res.writeHead(200, {
      "Content-Type": TYPES[path.extname(file).toLowerCase()] || "application/octet-stream",
      "Content-Length": st.size,
      "Cache-Control": "no-store",
    });
    fs.createReadStream(file).pipe(res);
  });
}).listen(PORT, "127.0.0.1", () => {
  console.log(`  静态服务：http://127.0.0.1:${PORT}/  →  ${ROOT}`);
});
