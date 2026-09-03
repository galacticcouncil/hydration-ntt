#!/usr/bin/env bun
// @ts-nocheck — standalone bun script, not part of the SDK build.
// EVM counterpart of solana/_inbox.ts: list inbound queued transfers on the
// EVM hub legs (Hydration→Ethereum/Base unlocks that exceeded the inbound
// rate limit).
//
// Unlike Solana, the EVM queue mapping only holds PENDING transfers —
// completed entries are deleted (NttManager.completeInboundQueuedTransfer).
// So this scans InboundTransferQueued events for digests, then probes
// getInboundQueuedTransfer(digest): txTimestamp == 0 → already completed.
//
//   QUEUED until <t>     waiting out the 24h rate-limit delay
//   RELEASABLE since <t> delay passed, nobody called completeInboundQueuedTransfer
//   completed            released (mapping entry deleted)
//
// Usage: ops/scripts/_inbox_evm.ts [token ...]     default: all tokens
// Env:   CHAINS=Ethereum,Base (default)   DAYS=30 event-scan lookback

import { readdirSync, readFileSync } from "fs";
import { join } from "path";

const ROOT = join(import.meta.dir, "..", "..");
const RPC = Object.fromEntries(
  Object.entries(JSON.parse(readFileSync(join(ROOT, "overrides.json"), "utf8")).chains)
    .map(([c, v]) => [c, v.rpc])
);
const CHAINS = (process.env.CHAINS ?? "Ethereum,Base").split(",");
const DAYS = Number(process.env.DAYS ?? 30);

// Log scans need endpoints that serve historical eth_getLogs (publicnode
// gates them; every free tier caps ranges at 10k blocks — hence CHUNK).
const LOGS_RPC = {
  Ethereum: process.env.ETH_LOGS_RPC ?? "https://eth.drpc.org",
  Base: process.env.BASE_LOGS_RPC ?? "https://base.drpc.org",
};

// precomputed (cast): selectors + event topic
const SEL_GET_INBOUND = "0xfd96063c";   // getInboundQueuedTransfer(bytes32)
const SEL_DURATION = "0x74aa7bfc";      // rateLimitDuration()
const TOPIC_QUEUED = "0x7f63c9251d82a933210c2b6d0b0f116252c3c116788120e64e8e8215df6f3162"; // InboundTransferQueued(bytes32)

let id = 0;
async function rpc(url, method, params) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

const fmt = (raw, dec) => (Number(raw) / 10 ** dec).toLocaleString("en-US", { maximumFractionDigits: dec });

const tokens = process.argv.slice(2).length
  ? process.argv.slice(2)
  : readdirSync(join(ROOT, "ops/tokens")).sort();
const now = Math.floor(Date.now() / 1000);

for (const chain of CHAINS) {
  const url = RPC[chain];
  if (!url) { console.log(`!! no RPC for ${chain} in overrides.json`); continue; }

  // per-chain block time → lookback window
  const latest = await rpc(url, "eth_getBlockByNumber", ["latest", false]);
  const head = Number(latest.number), headTs = Number(latest.timestamp);
  const older = await rpc(url, "eth_getBlockByNumber", ["0x" + (head - 10000).toString(16), false]);
  const blockTime = (headTs - Number(older.timestamp)) / 10000;
  const from = Math.max(0, head - Math.ceil((DAYS * 86400) / blockTime));
  const CHUNK = 10000;
  const logsUrl = LOGS_RPC[chain] ?? url;

  for (const t of tokens) {
    let dep;
    try { dep = JSON.parse(readFileSync(join(ROOT, "ops/tokens", t, "deployment.json"), "utf8")); } catch { continue; }
    const leg = dep.chains[chain];
    if (!leg) continue;

    const duration = Number(await rpc(url, "eth_call", [{ to: leg.manager, data: SEL_DURATION }, "latest"]));
    const logs = [];
    for (let s = from; s <= head; s += CHUNK) {
      const e = Math.min(s + CHUNK - 1, head);
      const chunk = await rpc(logsUrl, "eth_getLogs", [{
        address: leg.manager, topics: [TOPIC_QUEUED],
        fromBlock: "0x" + s.toString(16), toBlock: "0x" + e.toString(16),
      }]).catch((err) => { console.log(`  !! getLogs ${s}-${e}: ${err.message}`); return []; });
      logs.push(...chunk);
      await new Promise((r) => setTimeout(r, 60));
    }
    console.log(`== ${t} @ ${chain}  manager ${leg.manager}  queued-events (last ${DAYS}d): ${logs.length}`);

    for (const log of logs) {
      const digest = log.data.length === 66 ? log.data : "0x" + log.data.slice(-64);
      const r = await rpc(url, "eth_call", [{ to: leg.manager, data: SEL_GET_INBOUND + digest.slice(2) }, "latest"]);
      const trimmed = BigInt("0x" + r.slice(2, 66));
      const txTs = Number(BigInt("0x" + r.slice(66, 130)));
      const recipient = "0x" + r.slice(130 + 24, 194);
      const amount = trimmed >> 8n, dec = Number(trimmed & 0xffn);
      if (txTs === 0) {
        console.log(`  ${digest}  completed (queued at block ${Number(log.blockNumber)})`);
      } else {
        const releaseAt = txTs + duration;
        const status = releaseAt > now
          ? `QUEUED until ${new Date(releaseAt * 1000).toISOString()} (${((releaseAt - now) / 3600).toFixed(1)}h left)`
          : `RELEASABLE since ${new Date(releaseAt * 1000).toISOString()} — call completeInboundQueuedTransfer(digest)`;
        console.log(`  ${digest}  ${fmt(amount, dec)} ${t}  -> ${recipient}  ${status}`);
      }
    }
  }
}
