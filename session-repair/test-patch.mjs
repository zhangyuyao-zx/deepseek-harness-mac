// 直接调用修补后的 dsh-session-persistence-jsonl 真实读取路径做验证
import { JsonlSessionPersistence } from "/Users/zhangxin/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const noop = () => {};
const fakeCtx = new Proxy({
  sessions: { list: () => [] },
  effect: () => () => {},
  on: noop,
  get: () => undefined,
  set: noop,
  reflect: new Proxy({}, { get: () => noop }),
}, {
  get(target, key) {
    if (key in target) return target[key];
    return noop;
  },
});

// 模块要求:首帧恰好只有 header 行,后续帧放事件行
function buildCase(root, projectDir, id, headerLine, eventRows) {
  const dir = `${root}/${projectDir}/${id}`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/header.jsonl`, headerLine + "\n");
  writeFileSync(`${dir}/events.jsonl`, eventRows.join("\n") + "\n");
  execFileSync("zstd", ["-q", "-f", "-c", `${dir}/header.jsonl`, "-o", `${dir}/f1.zst`]);
  execFileSync("zstd", ["-q", "-f", "-c", `${dir}/events.jsonl`, "-o", `${dir}/f2.zst`]);
  writeFileSync(`${dir}/session.jsonl.zstd`, Buffer.concat([readFileSync(`${dir}/f1.zst`), readFileSync(`${dir}/f2.zst`)]));
  return `${dir}/session.jsonl.zstd`;
}

async function readCase(root, path, expectedId, label, expectFail = false) {
  const backend = new JsonlSessionPersistence(fakeCtx, { root, compression: "zstd" });
  try {
    const prefix = await backend.readPrefix(path, expectedId, undefined);
    const status = expectFail ? "[UNEXPECTED-OK]" : "[OK]";
    console.log(`${status} ${label}: events=${prefix.events.length} lastSeq=${prefix.events.at(-1)?.seq} torn=${prefix.tornMarker ? "yes" : "no"}`);
  } catch (e) {
    const status = expectFail ? "[OK-expected]" : "[FAIL]";
    console.log(`${status} ${label}: ${e.message.slice(0, 300)}`);
  }
}

// ---- 合成样本(自造 header,id 各异) ----
const synthRoot = "/tmp/patchtest/synthroot";
const synthCwd = "/tmp/patchtest";
const mkHeader = (id) => JSON.stringify({ type: "session", version: 0, id, createdAt: 1, cwd: synthCwd, delegationDepth: 0 });
const turnEnd = (seq) => JSON.stringify({ type: "turn/end", seq, time: 2, data: { turn: 1, reason: { kind: "completed" } } });
const stepStart = (seq, step) => JSON.stringify({ type: "step/start", seq, time: 2, data: { turn: 1, step } });

// 场景A:健康 [0,1,2]
let id = "synth-healthy";
let rows = [mkHeader(id), stepStart(0, 1), stepStart(1, 2), turnEnd(2)];
await readCase(synthRoot, buildCase(synthRoot, '--tmp-patchtest--', id, rows[0], rows.slice(1)), id, "synth-healthy");

// 场景B:重复尾部含 turn/end [0,1,2,1,2] —— 补丁前必然抛错,补丁后应跳过并读取成功
id = "synth-dup-tail";
rows = [mkHeader(id), stepStart(0, 1), stepStart(1, 2), turnEnd(2), stepStart(1, 2), turnEnd(2)];
await readCase(synthRoot, buildCase(synthRoot, '--tmp-patchtest--', id, rows[0], rows.slice(1)), id, "synth-dup-tail-turnend");

// 场景C:真正的缺失 [0,2] —— 补丁后仍应报错(防线,预期失败)
id = "synth-forward-gap";
rows = [mkHeader(id), stepStart(0, 1), stepStart(2, 3)];
await readCase(synthRoot, buildCase(synthRoot, '--tmp-patchtest--', id, rows[0], rows.slice(1)), id, "synth-forward-gap", true);

// ---- 真实数据样本(前 11 行,seq 0..9),每种损坏一个独立 id ----
const realCwd = "/Users/zhangxin/Desktop/deepseek";
const realLines = readFileSync("/tmp/session_plain2.jsonl", "utf8").split("\n").filter((l) => l.length > 0).slice(0, 11);
const realHeader = realLines[0];
const events = realLines.slice(1); // r0..r9

// 健康
let rid = "real-healthy";
await readCase(synthRoot, buildCase(synthRoot, '--Users-zhangxin-Desktop-deepseek--', rid, realHeader.replace(/"id":"[^"]+"/, `"id":"${rid}"`), events), rid, "real-healthy");

// 中部重复: [r0..r4, r2, r3, r5..r9]
rid = "real-dup-mid";
const dupMidEvents = [...events.slice(0, 5), ...events.slice(2, 4), ...events.slice(5)];
await readCase(synthRoot, buildCase(synthRoot, '--Users-zhangxin-Desktop-deepseek--', rid, realHeader.replace(/"id":"[^"]+"/, `"id":"${rid}"`), dupMidEvents), rid, "real-dup-mid");

// 尾部重复: [...r0..r9, r8, r9]
rid = "real-dup-tail";
const dupTailEvents = [...events, ...events.slice(8)];
await readCase(synthRoot, buildCase(synthRoot, '--Users-zhangxin-Desktop-deepseek--', rid, realHeader.replace(/"id":"[^"]+"/, `"id":"${rid}"`), dupTailEvents), rid, "real-dup-tail");

// ---- 真实当前会话文件(健康),只读验证 ----
const realId = "session-dedd7ab0-09ff-4885-898a-271001b4eb45";
const realPath = `/Users/zhangxin/.dsh/sessions/--Users-zhangxin-Desktop-deepseek--/${realId}/session.jsonl.zstd`;
const backend = new JsonlSessionPersistence(fakeCtx, { root: "/Users/zhangxin/.dsh/sessions", compression: "zstd" });
try {
  const prefix = await backend.readPrefix(realPath, realId, undefined);
  console.log(`[OK] real-current-session: events=${prefix.events.length} torn=${prefix.tornMarker ? "yes" : "no"}`);
} catch (e) {
  console.log(`[FAIL] real-current-session: ${e.message.slice(0, 300)}`);
}
