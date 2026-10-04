#!/usr/bin/env bun
// @ts-nocheck — standalone bun script, not part of the SDK build; the repo
// tsconfig has no node/bun types for ops/.
// Custody status: per token, total custody across every `locking` leg vs total
// circulating supply across every `burning` leg. Legs pair by mode, never by
// chain name — a token may have several hubs (weth locks on Ethereum *and*
// Robinhood) and the hub may itself be Hydration (hdx, hollar, where Robinhood
// is the spoke).
// Read-only, zero deps. RPCs from overrides.json; Sui via SUI_RPC or the
// public fullnode. Custody locations per ops/CUSTODY.md:
//   EVM    — manager's own token balance
//   Solana — config.custody token account (config PDA parsed on the fly)
//   Sui    — State.balance field of the manager object
// Usage: ./ops/scripts/_status.ts

import { readdirSync, readFileSync } from "fs";
import { createHash } from "crypto";
import { join } from "path";

const ROOT = join(import.meta.dir, "..", "..");
const overrides = JSON.parse(readFileSync(join(ROOT, "overrides.json"), "utf8"));
const RPC: Record<string, string> = Object.fromEntries(
  Object.entries(overrides.chains).map(([c, v]: [string, any]) => [c, v.rpc])
);
// Sui: official fullnode has dropped JSON-RPC — needs a provider that still
// serves it. Order: SUI_RPC env, overrides.json, publicnode.
const SUI_RPCS = [process.env.SUI_RPC, RPC.Sui, "https://sui-rpc.publicnode.com"].filter(Boolean) as string[];

let rpcId = 0;
const RPC_TIMEOUT_MS = 20_000;
async function rpc(url: string, method: string, params: unknown[]): Promise<any> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
    signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
  const j: any = await res.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

// ---------- EVM ----------

const SEL = { balanceOf: "0x70a08231", decimals: "0x313ce567", totalSupply: "0x18160ddd" };
const padAddr = (a: string) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");

async function ethCall(url: string, to: string, data: string): Promise<bigint> {
  const r = await rpc(url, "eth_call", [{ to, data }, "latest"]);
  if (!r || r === "0x") throw new Error(`empty eth_call result from ${to}`);
  return BigInt(r);
}

async function evmCustody(chain: string, leg: any) {
  const url = RPC[chain];
  const [bal, dec, native] = await Promise.all([
    ethCall(url, leg.token, SEL.balanceOf + padAddr(leg.manager)),
    ethCall(url, leg.token, SEL.decimals),
    rpc(url, "eth_getBalance", [leg.manager, "latest"]).then(BigInt),
  ]);
  return { raw: bal, decimals: Number(dec), note: native > 0n ? `+${fmt(native, 18)} native ETH on manager` : "" };
}

// Gap-closing mints are sent to 0x…dEaD: out of circulation forever, but
// still counted by totalSupply(). Circulating = issuance - dEaD balance.
const DEAD = "0x000000000000000000000000000000000000dEaD";

async function evmSupply(chain: string, leg: any) {
  if (chain === "Solana" || chain === "Sui") {
    throw new Error(`burning leg on ${chain} not supported by this script`);
  }
  const url = RPC[chain];
  if (!url) throw new Error(`no RPC for ${chain} in overrides.json`);
  const [supply, dec, dead] = await Promise.all([
    ethCall(url, leg.token, SEL.totalSupply),
    ethCall(url, leg.token, SEL.decimals),
    ethCall(url, leg.token, SEL.balanceOf + padAddr(DEAD)),
  ]);
  return {
    raw: supply - dead,
    decimals: Number(dec),
    note: dead > 0n ? `excl. ${fmt(dead, Number(dec))} @dEaD` : "",
  };
}

// ---------- Solana ----------

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function b58decode(s: string): Buffer {
  let n = 0n;
  for (const c of s) {
    const i = B58.indexOf(c);
    if (i < 0) throw new Error(`bad base58: ${s}`);
    n = n * 58n + BigInt(i);
  }
  const bytes: number[] = [];
  while (n > 0n) { bytes.unshift(Number(n & 0xffn)); n >>= 8n; }
  let zeros = 0;
  for (const c of s) { if (c === "1") zeros++; else break; }
  return Buffer.concat([Buffer.alloc(zeros), Buffer.from(bytes)]);
}

function b58encode(buf: Uint8Array): string {
  let n = 0n;
  for (const b of buf) n = (n << 8n) | BigInt(b);
  let out = "";
  while (n > 0n) { out = B58[Number(n % 58n)] + out; n /= 58n; }
  for (const b of buf) { if (b === 0) out = "1" + out; else break; }
  return out;
}

// ed25519 decompression check — a PDA must NOT be a valid curve point.
const P = 2n ** 255n - 19n;
const modp = (a: bigint) => ((a % P) + P) % P;
function powp(b: bigint, e: bigint): bigint {
  let r = 1n; b = modp(b);
  while (e > 0n) { if (e & 1n) r = (r * b) % P; b = (b * b) % P; e >>= 1n; }
  return r;
}
const D = modp(-121665n * powp(121666n, P - 2n));

function isOnCurve(bytes: Uint8Array): boolean {
  let y = 0n;
  for (let i = 31; i >= 0; i--) y = (y << 8n) | BigInt(bytes[i]);
  const sign = (y >> 255n) & 1n;
  y &= (1n << 255n) - 1n;
  if (y >= P) return false;
  const y2 = (y * y) % P;
  const u = modp(y2 - 1n);
  const v = modp(D * y2 + 1n);
  let x = (((u * powp(v, 3n)) % P) * powp((u * powp(v, 7n)) % P, (P - 5n) / 8n)) % P;
  const vxx = (((v * x) % P) * x) % P;
  if (vxx !== u) {
    if (vxx !== modp(-u)) return false;
    x = (x * powp(2n, (P - 1n) / 4n)) % P;
  }
  return !(x === 0n && sign === 1n);
}

function configPda(programId: string): string {
  const prog = b58decode(programId);
  for (let bump = 255; bump >= 0; bump--) {
    const h = createHash("sha256")
      .update(Buffer.from("config"))
      .update(Buffer.from([bump]))
      .update(prog)
      .update(Buffer.from("ProgramDerivedAddress"))
      .digest();
    if (!isOnCurve(h)) return b58encode(h);
  }
  throw new Error(`no valid config bump for ${programId}`);
}

// Config layout (borsh, solana/…/src/config.rs): 8B discriminator, bump u8,
// owner 32B, pending_owner Option<Pubkey> (1B tag + 0/32B), mint 32B,
// token_program 32B, mode 1B, chain_id u16, next_transceiver_id u8,
// threshold u8, bitmap u128, paused bool, custody 32B.
async function solanaCustody(leg: any) {
  const url = RPC.Solana;
  const pda = configPda(leg.manager);
  const acc = await rpc(url, "getAccountInfo", [pda, { encoding: "base64" }]);
  if (!acc?.value) throw new Error(`config account ${pda} not found`);
  const data = Buffer.from(acc.value.data[0], "base64");
  let o = 8 + 1 + 32; // discriminator, bump, owner
  const hasPending = data[o]; o += 1 + (hasPending ? 32 : 0);
  o += 32 + 32 + 1 + 2 + 1 + 1 + 16; // mint, token_program, mode, chain_id, next_id, threshold, bitmap
  const paused = !!data[o]; o += 1;
  const custody = b58encode(data.subarray(o, o + 32));
  const bal = await rpc(url, "getTokenAccountBalance", [custody]);
  return { raw: BigInt(bal.value.amount), decimals: bal.value.decimals, note: paused ? "PAUSED" : "", custody };
}

// ---------- Sui ----------

async function suiCustody(leg: any) {
  let lastErr = "";
  for (const url of SUI_RPCS) {
    let obj: any, meta: any;
    try {
      [obj, meta] = await Promise.all([
        rpc(url, "sui_getObject", [leg.manager, { showContent: true }]),
        rpc(url, "suix_getCoinMetadata", [leg.token]),
      ]);
    } catch (e: any) {
      lastErr = `${url}: ${e.message}`;
      continue;
    }
    const fields = obj?.data?.content?.fields;
    if (!fields) throw new Error(`no content for state object ${leg.manager}`);
    return {
      raw: BigInt(fields.balance),
      decimals: meta?.decimals ?? 9,
      note: fields.paused ? "PAUSED" : "",
    };
  }
  throw new Error(`sui rpc unreachable: ${lastErr}`);
}

// ---------- formatting ----------

function fmt(raw: bigint, decimals: number): string {
  const neg = raw < 0n;
  const s = (neg ? -raw : raw).toString().padStart(decimals + 1, "0");
  const int = s.slice(0, s.length - decimals).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = decimals ? s.slice(-decimals).replace(/0+$/, "") : "";
  return (neg ? "-" : "") + int + (frac ? "." + frac : "");
}

// Δ in a common scale (hub and Hydration decimals may differ)
function delta(a: { raw: bigint; decimals: number }, b: { raw: bigint; decimals: number }) {
  const dec = Math.max(a.decimals, b.decimals);
  const scale = (x: { raw: bigint; decimals: number }) => x.raw * 10n ** BigInt(dec - x.decimals);
  return { raw: scale(a) - scale(b), decimals: dec };
}

// Sum legs that may be denominated in different decimals, in a common scale.
function sumScaled(parts: { raw: bigint; decimals: number }[]) {
  const decimals = Math.max(...parts.map((p) => p.decimals));
  const raw = parts.reduce((a, p) => a + p.raw * 10n ** BigInt(decimals - p.decimals), 0n);
  return { raw, decimals };
}

function custodyOf(chain: string, leg: any) {
  if (chain === "Solana") return solanaCustody(leg);
  if (chain === "Sui") return suiCustody(leg);
  return evmCustody(chain, leg);
}

// Never throws: a failed leg becomes { err } so one dead RPC can't sink the run.
async function settle(chain: string, run: () => Promise<any>) {
  try {
    return { chain, ...(await run()) };
  } catch (e: any) {
    return { chain, err: e.message };
  }
}

// ---------- main ----------

const tokensDir = join(ROOT, "ops", "tokens");
const tokens = readdirSync(tokensDir).sort();
const rows: string[][] = [
  ["token", "hubs (locking)", "custody", "spokes (burning)", "supply", "Δ custody-supply", "notes"],
];
const NUMERIC = new Set([2, 4, 5]);
const COLS = rows[0].length;
// A side with several legs (weth locks on Ethereum *and* Robinhood) prints its
// total on the token row, then one indented row per leg, so it's visible how
// much sits on each chain. Single-leg sides stay on one line as before.
const sideLabel = (names: string[]) => (names.length > 1 ? `${names.length} legs` : names[0]);
// col is the chain column; col + 1 is its amount. Hubs are 1/2, spokes 3/4.
function legRow(col: number, p: any): string[] {
  const r: string[] = Array(COLS).fill("");
  r[col] = "  " + p.chain;
  r[col + 1] = p.err ? "ERR" : fmt(p.raw, p.decimals);
  return r;
}
const custodyAddrs: string[] = [];
let alarm = false;

for (const t of tokens) {
  let dep: any;
  try {
    dep = JSON.parse(readFileSync(join(tokensDir, t, "deployment.json"), "utf8"));
  } catch { continue; }

  const chains = Object.keys(dep.chains);
  const hubs = chains.filter((c) => dep.chains[c].mode === "locking");
  const spokes = chains.filter((c) => dep.chains[c].mode === "burning");
  // Progress on stderr: the table only prints once every leg has resolved.
  process.stderr.write(`  … ${t} (${hubs.join("+") || "?"} → ${spokes.join("+") || "?"})\n`);
  if (!hubs.length || !spokes.length) {
    rows.push([t, hubs.join(", ") || "-", "-", spokes.join(", ") || "-", "-", "-", "missing leg"]);
    continue;
  }

  const [custParts, supParts] = await Promise.all([
    Promise.all(hubs.map((c) => settle(c, () => custodyOf(c, dep.chains[c])))),
    Promise.all(spokes.map((c) => settle(c, () => evmSupply(c, dep.chains[c])))),
  ]);

  const notes: string[] = [];
  for (const p of [...custParts, ...supParts]) {
    if (p.custody) custodyAddrs.push(`  ${t} (${p.chain}): ${p.custody}`);
    if (p.note) notes.push(`${p.chain}: ${p.note}`);
    if (p.err) notes.push(`${p.chain}: ${p.err}`);
  }

  // A partial sum reads as a deficit, so only compare when every leg resolved.
  const cust = custParts.every((p) => !p.err) ? sumScaled(custParts as any) : null;
  const sup = supParts.every((p) => !p.err) ? sumScaled(supParts as any) : null;

  let dS = "-";
  if (cust && sup) {
    const d = delta(cust, sup);
    dS = (d.raw > 0n ? "+" : "") + fmt(d.raw, d.decimals);
    if (d.raw < 0n) { notes.push("!! supply exceeds custody"); alarm = true; }
  }

  rows.push([
    t,
    sideLabel(hubs),
    cust ? fmt(cust.raw, cust.decimals) : "ERR",
    sideLabel(spokes),
    sup ? fmt(sup.raw, sup.decimals) : "ERR",
    dS,
    notes.join("; "),
  ]);
  if (custParts.length > 1) for (const p of custParts) rows.push(legRow(1, p));
  if (supParts.length > 1) for (const p of supParts) rows.push(legRow(3, p));
}

const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
const line = (r: string[]) =>
  r.map((c, i) => (NUMERIC.has(i) ? c.padStart(widths[i]) : c.padEnd(widths[i]))).join("  ").trimEnd();
console.log(line(rows[0]));
console.log(widths.map((w) => "-".repeat(w)).join("  "));
for (const r of rows.slice(1)) console.log(line(r));

if (custodyAddrs.length) {
  console.log("\nSolana custody token accounts (not in deployment.json, see ops/CUSTODY.md):");
  for (const l of custodyAddrs) console.log(l);
}
if (alarm) { console.error("\nALARM: at least one leg has supply > custody"); process.exit(1); }
