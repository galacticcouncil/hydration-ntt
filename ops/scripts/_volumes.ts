#!/usr/bin/env bun
// @ts-nocheck — standalone bun script, not part of the SDK build.
// NTT liquidity volumes IN vs OUT for Hydration (chain 73) over a date range,
// from the Wormholescan operations API. Tokens attributed via the manager
// addresses in ops/tokens/*/deployment.json. USD is best-effort (CoinGecko);
// the table prints regardless.
//
// Usage: ops/scripts/_volumes.ts <from> [to]        dates as YYYY-MM-DD (UTC)
//        ops/scripts/_volumes.ts 2026-08-01
//        ops/scripts/_volumes.ts 2026-08-01 2026-08-15
//
// Migration/treasury senders listed in EXCLUDE are not counted.

import { readdirSync, readFileSync } from "fs";
import { join } from "path";

const EXCLUDE = new Set([
  "0x9fed34580e448224db25a7ea654460d105d9c6f961d3f6861af1362cfe23c86b", // sui migration treasury
]);

const [fromArg, toArg] = process.argv.slice(2);
if (!fromArg) {
  console.error("usage: _volumes.ts <from YYYY-MM-DD> [to YYYY-MM-DD]");
  process.exit(2);
}
const SINCE = Date.parse(`${fromArg}T00:00:00Z`);
const UNTIL = toArg ? Date.parse(`${toArg}T23:59:59Z`) : Date.now();
if (Number.isNaN(SINCE) || Number.isNaN(UNTIL)) {
  console.error("bad date(s); use YYYY-MM-DD");
  process.exit(2);
}

const ROOT = join(import.meta.dir, "..", "..");
const CHAIN_IDS = { Ethereum: 2, Solana: 1, Base: 30, Sui: 21, Hydration: 73 };
const COINGECKO = {
  dai: "dai", eurc: "euro-coin", jitosol: "jito-staked-sol", prime: "echelon-prime",
  sol: "solana", sui: "sui", susds: "susds", usdc: "usd-coin", usdt: "tether",
  wbtc: "wrapped-bitcoin", weth: "weth",
};

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const b58hex = (s) => {
  let n = 0n;
  for (const c of s) n = n * 58n + BigInt(B58.indexOf(c));
  return n.toString(16).padStart(64, "0");
};

// (chainId:managerUniversalHex) -> token, for every leg of every token
const managerMap = new Map();
for (const t of readdirSync(join(ROOT, "ops/tokens"))) {
  let dep;
  try { dep = JSON.parse(readFileSync(join(ROOT, "ops/tokens", t, "deployment.json"), "utf8")); } catch { continue; }
  for (const [chain, leg] of Object.entries(dep.chains)) {
    const hex = leg.manager.startsWith("0x")
      ? leg.manager.slice(2).toLowerCase().padStart(64, "0")
      : b58hex(leg.manager);
    managerMap.set(`${CHAIN_IDS[chain]}:${hex}`, t);
  }
}

async function fetchOps(dir) {
  const param = dir === "in" ? "targetChain=73" : "sourceChain=73";
  const from = new Date(SINCE).toISOString();
  const to = new Date(UNTIL).toISOString();
  const ops = [];
  for (let page = 0; page < 200; page++) {
    const url = `https://api.wormholescan.io/api/v1/operations?appId=NATIVE_TOKEN_TRANSFER&${param}&page=${page}&pageSize=50&from=${from}&to=${to}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`wormholescan HTTP ${res.status}`);
    const data = (await res.json()).operations ?? [];
    ops.push(...data);
    if (data.length < 50) break;
  }
  return ops;
}

const opTime = (op) => {
  const t = op.sourceChain?.timestamp ?? op.vaa?.timestamp ?? op.timestamp;
  return t ? Date.parse(t) : NaN;
};

const agg = {};
let excluded = 0, unattributed = 0;
for (const dir of ["in", "out"]) {
  for (const op of await fetchOps(dir)) {
    const t = opTime(op);
    if (!Number.isNaN(t) && (t < SINCE || t > UNTIL)) continue;
    const p = op.content?.payload;
    const ta = p?.nttMessage?.trimmedAmount;
    if (!ta) continue;
    if (EXCLUDE.has((p?.nttManagerMessage?.sender ?? "").toLowerCase())) { excluded++; continue; }
    const srcMgr = (p?.transceiverMessage?.sourceNttManager ?? "").replace(/^0x/, "").toLowerCase();
    const token = managerMap.get(`${op.emitterChain ?? op.sourceChain?.chainId}:${srcMgr}`);
    if (!token) { unattributed++; continue; }
    const amt = Number(ta.amount) / 10 ** ta.decimals;
    agg[token] ??= { in: 0, out: 0, inN: 0, outN: 0 };
    agg[token][dir] += amt;
    agg[token][dir === "in" ? "inN" : "outN"]++;
  }
}

// best-effort USD
let prices = {};
try {
  const ids = Object.keys(agg).map((t) => COINGECKO[t]).filter(Boolean).join(",");
  const res = await fetch(`https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=usd`);
  if (res.ok) {
    const j = await res.json();
    for (const [t, id] of Object.entries(COINGECKO)) prices[t] = j[id]?.usd;
  }
} catch {}

const n = (x, d = 4) => x.toLocaleString("en-US", { maximumFractionDigits: d });
const usd = (t, x) => (prices[t] ? "$" + n(x * prices[t], 0) : "-");

console.log(`Hydration NTT volumes ${fromArg} → ${toArg ?? "now"} (excl. ${EXCLUDE.size} migration sender)`);
console.log(
  "token".padEnd(9), "IN → Hydr".padStart(16), "(txs)".padStart(6), "≈USD".padStart(10),
  "OUT ← Hydr".padStart(16), "(txs)".padStart(6), "≈USD".padStart(10), "net ≈USD".padStart(11),
);
let totIn = 0, totOut = 0, haveAllPrices = true;
for (const [t, v] of Object.entries(agg).sort()) {
  console.log(
    t.padEnd(9), n(v.in).padStart(16), String(v.inN).padStart(6), usd(t, v.in).padStart(10),
    n(v.out).padStart(16), String(v.outN).padStart(6), usd(t, v.out).padStart(10),
    (prices[t] ? "$" + n((v.in - v.out) * prices[t], 0) : "-").padStart(11),
  );
  if (prices[t]) { totIn += v.in * prices[t]; totOut += v.out * prices[t]; }
  else haveAllPrices = false;
}
console.log(`\nTOTAL ≈ IN $${n(totIn, 0)}  OUT $${n(totOut, 0)}  NET ${totIn - totOut >= 0 ? "+" : "-"}$${n(Math.abs(totIn - totOut), 0)}${haveAllPrices ? "" : "  (some tokens unpriced)"}`);
if (excluded || unattributed) console.log(`excluded (migration): ${excluded} ops; unattributed: ${unattributed}`);
