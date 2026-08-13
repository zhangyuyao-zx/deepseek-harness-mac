// 会话日志扫描/诊断脚本 —— 与 dsh-session-persistence-jsonl 的 SessionLogScanner 逻辑一致
// 用法: node scan.mjs <plaintext.jsonl> [--repair-out <file>]
import { readFileSync, writeFileSync } from "node:fs";
import { decodeStorageRecord } from "/Users/zhangxin/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session/lib/index.js";

class SessionLogScanner {
  constructor(headerRecord) {
    this.meta = JSON.parse(headerRecord.toString("utf8"));
    this.inputBytes = headerRecord.length;
    this.committedBytes = headerRecord.length;
    this.events = [];
    this.fragments = [];
    this.fragmentBytes = 0;
    this.eventLine = 0;
    this.issue = undefined;
    this.finished = false;
    // 诊断扩展
    this.anomalies = [];
    this.lines = [];
  }
  write(chunk) {
    if (this.finished) throw new Error("cannot write to a finished session log scanner");
    const chunkStart = this.inputBytes;
    this.inputBytes += chunk.length;
    let lineStart = 0;
    for (let newline = chunk.indexOf(10); newline !== -1; newline = chunk.indexOf(10, lineStart)) {
      const fragment = chunk.subarray(lineStart, newline);
      let line = fragment;
      if (this.fragments.length > 0) {
        if (fragment.length > 0) this.fragments.push(fragment);
        line = Buffer.concat(this.fragments, this.fragmentBytes + fragment.length);
        this.fragments = [];
        this.fragmentBytes = 0;
      }
      this.consumeEventLine(line, chunkStart + newline + 1);
      lineStart = newline + 1;
    }
    if (lineStart < chunk.length) {
      const fragment = Buffer.from(chunk.subarray(lineStart));
      this.fragments.push(fragment);
      this.fragmentBytes += fragment.length;
    }
  }
  finish() {
    this.finished = true;
    return { meta: this.meta, events: this.events, committedBytes: this.committedBytes };
  }
  consumeEventLine(line, endByte) {
    this.eventLine += 1;
    let decoded;
    try {
      decoded = decodeStorageRecord(JSON.parse(line.toString("utf8")));
    } catch (e) {
      this.issue ??= new Error(`corrupt session log: unparsable committed event at line ${this.eventLine}: ${e.message}`);
      this.anomalies.push({ line: this.eventLine, kind: "unparsable", detail: e.message });
      return;
    }
    if (this.issue !== undefined) {
      if (decoded.some((event) => event.type === "turn/end")) throw this.issue;
      return;
    }
    const rowStart = this.events.length;
    for (const event of decoded) {
      if (event.seq !== this.events.length) {
        const expected = this.events.length;
        this.events.length = rowStart;
        this.issue = new Error(`corrupt session log: seq gap in committed region at line ${this.eventLine} (expected ${expected}, got ${event.seq})`);
        this.anomalies.push({ line: this.eventLine, kind: "seq-gap", expected, got: event.seq });
        if (decoded.some((candidate) => candidate.type === "turn/end")) throw this.issue;
        return;
      }
      this.events.push(event);
    }
    this.committedBytes = endByte;
    this.lines.push({ eventLine: this.eventLine, endByte, firstSeq: decoded[0]?.seq, count: decoded.length });
  }
}

const path = process.argv[2];
const buf = readFileSync(path);
const headerEnd = buf.indexOf(10);
if (headerEnd === -1) { console.log("FAIL: empty or header-less log"); process.exit(1); }
const scanner = new SessionLogScanner(buf.subarray(0, headerEnd + 1));
scanner.write(buf.subarray(headerEnd + 1));
let result;
let threw = null;
try {
  result = scanner.finish();
} catch (e) {
  threw = e;
  result = { events: scanner.events, committedBytes: scanner.committedBytes };
}

console.log("meta.id:", scanner.meta?.id);
console.log("total plaintext bytes:", buf.length);
console.log("committedBytes:", scanner.committedBytes);
console.log("events (good prefix):", scanner.events.length);
console.log("last good line:", scanner.lines.length ? JSON.stringify(scanner.lines[scanner.lines.length - 1]) : "(none)");
console.log("anomalies:", JSON.stringify(scanner.anomalies, null, 0));
console.log(threw ? `THREW: ${threw.message}` : "scan OK");

// 诊断扩展:异常之后剩余文件是否自洽(用于判断该丢弃还是保留)
if (scanner.anomalies.length > 0) {
  const first = scanner.anomalies[0];
  console.log(`\n--- anomaly region detail (around line ${first.line}) ---`);
  // 重扫:跳过异常行继续,看剩余 seq 是否连续
  const scanner2 = new SessionLogScanner(buf.subarray(0, headerEnd + 1));
  let skipMode = false;
  let postGapFirstSeq = null;
  let postGapLines = 0;
  let postGapOk = true;
  // 用同样的 consumeEventLine 逻辑,但手工迭代行
  const lines = buf.subarray(headerEnd + 1).toString("utf8").split("\n").filter((l) => l.length > 0);
  let expected = 0;
  let seenGap = false;
  for (let i = 0; i < lines.length; i++) {
    let decoded;
    try { decoded = decodeStorageRecord(JSON.parse(lines[i])); } catch (e) { continue; }
    if (!seenGap) {
      for (const ev of decoded) {
        if (ev.seq !== expected) {
          seenGap = true;
          postGapFirstSeq = ev.seq;
          break;
        }
        expected = ev.seq + 1;
      }
    } else {
      // 从异常行开始,要求后续严格连续(基于该行的第一个 seq)
      let firstSeq = decoded[0]?.seq;
      if (postGapFirstSeq === null) postGapFirstSeq = firstSeq;
      // 检查这一行内部是否连续
      let prev = null;
      for (const ev of decoded) {
        if (prev !== null && ev.seq !== prev + 1) { postGapOk = false; console.log(`  row ${i + 1} internal discontinuity at seq ${ev.seq}`); break; }
        prev = ev.seq;
      }
      if (!postGapOk) break;
      postGapLines++;
    }
  }
  console.log("post-gap first seq:", postGapFirstSeq, "post-gap contiguous rows:", postGapLines, "post-gap internally contiguous:", postGapOk);
  console.log("file total lines:", lines.length);
}
