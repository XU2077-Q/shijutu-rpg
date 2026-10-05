/* ============================================================
   读 .docx（零依赖）

   《时局图》剧本扩写读本是一份 Word 文档。要把它里面的扩写段落抽出来，
   又**不能靠手抄** —— 手抄会引入错字，而这份文本是要直接进游戏的正文。

   所以这里自己解 docx：docx 就是个 zip，里面 word/document.xml 是正文。

   【怎么认出扩写段落】
   读本的凡例说，扩写段落「左侧带朱线、宣纸黄底、以楷体排印」。
   前两条在 XML 里是 <w:pBdr><w:left .../> 和 <w:shd .../>，
   直接可判。**楷体那条不能用** —— 正文里的书信也排楷体，会误伤。

   实测：带「左边框 + 底纹」的段落共 54 个，按「连续段的最大连段」切，
   正好得到 31 段 —— 与凡例说的「全书共三十一条」吻合。
   这就是那个切分规则的依据，不是猜的。
   ============================================================ */
"use strict";

const fs = require("fs");
const zlib = require("zlib");

/* ---------------------- 最小 zip 读取 ---------------------- */

function readZipEntry(buf, wantName) {
  // 从尾部找 EOCD（0x06054b50）。注释最长 65535，所以往回找 66 KB 足够。
  const eocdMin = Math.max(0, buf.length - 65557);
  let eocd = -1;
  for (let i = buf.length - 22; i >= eocdMin; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("不是有效的 zip：找不到 EOCD");

  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16); // 中央目录起始偏移

  for (let n = 0; n < count; n++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error("中央目录条目签名不对 @" + p);
    const method   = buf.readUInt16LE(p + 10);
    const compSize = buf.readUInt32LE(p + 20);
    const fnLen    = buf.readUInt16LE(p + 28);
    const exLen    = buf.readUInt16LE(p + 30);
    const cmLen    = buf.readUInt16LE(p + 32);
    const lho      = buf.readUInt32LE(p + 42);
    const name     = buf.toString("utf8", p + 46, p + 46 + fnLen);

    if (name === wantName) {
      // 本地头里的 fnLen/exLen 可能与中央目录不同（少见但合法），以本地头为准
      if (buf.readUInt32LE(lho) !== 0x04034b50) throw new Error("本地文件头签名不对");
      const lfn = buf.readUInt16LE(lho + 26);
      const lex = buf.readUInt16LE(lho + 28);
      const start = lho + 30 + lfn + lex;
      const raw = buf.subarray(start, start + compSize);
      if (method === 0) return raw.toString("utf8");
      if (method === 8) return zlib.inflateRawSync(raw).toString("utf8");
      throw new Error("不支持的压缩方式 " + method);
    }
    p += 46 + fnLen + exLen + cmLen;
  }
  throw new Error("zip 里没有 " + wantName);
}

/* ---------------------- XML → 段落 ---------------------- */

function unescapeXml(s) {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">")
          .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
          .replace(/&amp;/g, "&"); // & 必须最后
}

/* 把一段 <w:p>…</w:p> 的 XML 变成纯文本。
   <w:tab/> 是制表符，<w:br/> 是换行 —— 都不能当空气丢掉，
   读本里书信的落款就靠这两个排版。 */
function paragraphText(p) {
  let t = p.replace(/<w:tab\s*\/>/g, "\t").replace(/<w:br\s*\/>/g, "\n");
  t = t.replace(/<[^>]+>/g, "");
  return unescapeXml(t).replace(/\s+$/, "");
}

/* 判断一个段落是不是扩写：左边框（朱线）+ 底纹（宣纸黄底）。 */
function isExpansion(p) {
  const m = p.match(/<w:pPr>([\s\S]*?)<\/w:pPr>/);
  if (!m) return false;
  return /<w:left\s/.test(m[1]) && /<w:shd\s/.test(m[1]);
}

/* ---------------------- 对外接口 ---------------------- */

/**
 * 读 docx，返回全部段落。
 * @returns {{index:number, text:string, expansion:boolean}[]}
 */
function readParagraphs(docxPath) {
  const xml = readZipEntry(fs.readFileSync(docxPath), "word/document.xml");
  // 按 </w:p> 切。第一个片段是 <w:body> 之前的东西，不含段落内容，无妨。
  const raw = xml.split("</w:p>");
  return raw.map((p, i) => ({
    index: i,
    text: paragraphText(p),
    expansion: isExpansion(p),
  }));
}

/**
 * 把扩写段落切成「连段」。每个连段 = 一条扩写条目。
 *
 * 依据：扩写在文档里是被原文隔开的一个个块。实测 54 个扩写段落切出 31 个连段，
 * 与凡例「全书共三十一条」一致。所以这个切法是**有验证的**，不是想当然。
 *
 * 注意：连段的判定只看段落序号是否相邻，不看内容 —— 内容分类是后面的事。
 */
function groupExpansionRuns(paragraphs) {
  const runs = [];
  let cur = null;
  for (const p of paragraphs) {
    if (!p.expansion) continue;
    if (cur && p.index === cur.end + 1) {
      cur.end = p.index;
      cur.paragraphs.push(p.text);
    } else {
      cur = { start: p.index, end: p.index, paragraphs: [p.text] };
      runs.push(cur);
    }
  }
  return runs;
}

module.exports = { readParagraphs, groupExpansionRuns, readZipEntry, paragraphText, isExpansion };
