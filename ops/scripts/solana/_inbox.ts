#!/usr/bin/env bun
// @ts-nocheck — standalone bun script, not part of the SDK build.
// List InboxItem accounts (inbound Hydration→Solana transfers) per Solana
// leg, with release status — answers "is my transfer queued and until when".
//
//   NotApproved          redeem not (fully) attested yet
//   queued until <t>     over the inbound rate limit; released after 24h
//   Released             done
//
// Usage: ops/scripts/solana/_inbox.ts [token ...]   default: sol jitosol prime
//
// Layout (borsh, after 8B anchor discriminator, queue/inbox.rs): init bool,
// bump u8, amount u64 LE, recipient Pubkey, votes u128, release_status
// (tag u8: 0=NotApproved, 1=ReleaseAfter+i64 LE, 2=Released).

import { readFileSync } from "fs";
import { createHash } from "crypto";
import { join } from "path";

const ROOT = join(import.meta.dir, "..", "..", "..");
const RPC = JSON.parse(readFileSync(join(ROOT, "overrides.json"), "utf8")).chains.Solana.rpc;
const DISC = createHash("sha256").update("account:InboxItem").digest().subarray(0, 8);

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function b58encode(buf) {
  let n = 0n;
  for (const b of buf) n = (n << 8n) | BigInt(b);
  let out = "";
  while (n > 0n) { out = B58[Number(n % 58n)] + out; n /= 58n; }
  for (const b of buf) { if (b === 0) out = "1" + out; else break; }
  return out;
}

let id = 0;
async function rpc(method, params) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

const tokens = process.argv.slice(2).length ? process.argv.slice(2) : ["sol", "jitosol", "prime"];
const now = Math.floor(Date.now() / 1000);

for (const t of tokens) {
  const dep = JSON.parse(readFileSync(join(ROOT, "ops/tokens", t, "deployment.json"), "utf8"));
  const leg = dep.chains.Solana;
  if (!leg) { console.log(`== ${t}: no Solana leg`); continue; }
  const { value: supply } = await rpc("getTokenSupply", [leg.token]);
  const dec = supply.decimals;
  const accounts = await rpc("getProgramAccounts", [leg.manager, {
    encoding: "base64",
    filters: [{ memcmp: { offset: 0, bytes: b58encode(DISC) } }],
  }]);
  console.log(`== ${t}  manager ${leg.manager}  inbox items: ${accounts.length}`);
  const rows = [];
  for (const { pubkey, account } of accounts) {
    const d = Buffer.from(account.data[0], "base64");
    let o = 8 + 1 + 1; // disc, init, bump
    const amount = d.readBigUInt64LE(o); o += 8;
    const recipient = b58encode(d.subarray(o, o + 32)); o += 32 + 16; // + votes
    const tag = d[o]; o += 1;
    let status, ts = 0;
    if (tag === 0) status = "NotApproved (awaiting attestation)";
    else if (tag === 1) {
      ts = Number(d.readBigInt64LE(o));
      status = ts > now
        ? `QUEUED until ${new Date(ts * 1000).toISOString()} (${((ts - now) / 3600).toFixed(1)}h left)`
        : `releasable since ${new Date(ts * 1000).toISOString()} — run release`;
    } else status = "Released";
    rows.push({ ts: ts || 0, line: `  ${pubkey}  ${(Number(amount) / 10 ** dec).toLocaleString("en-US")} ${t}  -> ${recipient}  ${status}` });
  }
  rows.sort((a, b) => b.ts - a.ts);
  for (const r of rows) console.log(r.line);
}
