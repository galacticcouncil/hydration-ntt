// fast-deploy.ts — replacement for `solana program deploy`'s write phase,
// which is unusable from this network (see ../README.md). Creates the buffer,
// streams all chunks at ~25 tx/s with a priority fee, verifies byte-for-byte,
// and finalizes (buffer -> live program). Safe to re-run: resumes the buffer,
// skips finalize if the program already exists.
//
// usage: bun fast-deploy.ts <rpc> <payer.json> <program-keypair.json> <binary.so> [buffer-keypair.json]
//   buffer keypair defaults to <dir of program keypair>/buffer.json (gitignored keys dir)
//
// after this: run the token's `sol.sh deploy` — the (patched) ntt CLI detects
// the live program, skips its own deploy, and runs NTT initialization.
import fs from "fs";
import path from "path";
import os from "os";

const web3 = await import(
  path.join(os.homedir(), ".ntt-cli/.checkout/node_modules/@solana/web3.js/lib/index.cjs")
);
const {
  Connection, Keypair, PublicKey, Transaction, TransactionInstruction,
  SystemProgram, SYSVAR_RENT_PUBKEY, SYSVAR_CLOCK_PUBKEY, ComputeBudgetProgram,
} = web3;

const LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
const HEADER = 37;      // buffer account: enum(4) + option(1) + authority(32)
const CHUNK = 800;
const RATE_MS = 40;     // ~25 tx/s
const PRICE = 100_000;  // microlamports / CU

const [rpc, payerPath, programPath, binaryPath, bufferPathArg] = process.argv.slice(2);
if (!binaryPath) {
  console.error("usage: bun fast-deploy.ts <rpc> <payer.json> <program-keypair.json> <binary.so> [buffer-keypair.json]");
  process.exit(1);
}
const bufferPath = bufferPathArg ?? path.join(path.dirname(programPath), "buffer.json");

const conn = new Connection(rpc, "confirmed");
const load = (p: string) => Keypair.fromSecretKey(new Uint8Array(JSON.parse(fs.readFileSync(p, "utf8"))));
const payer = load(payerPath);
const program = load(programPath);
const binary = fs.readFileSync(binaryPath);
console.log(`program ${program.publicKey.toBase58()} | binary ${binary.length} bytes | payer ${payer.publicKey.toBase58()}`);

const priceIx = () => ComputeBudgetProgram.setComputeUnitPrice({ microLamports: PRICE });
async function sendTx(ixs: any[], signers: any[], label: string) {
  const { blockhash, lastValidBlockHeight } = await conn.getLatestBlockhash("confirmed");
  const tx = new Transaction({ feePayer: payer.publicKey, recentBlockhash: blockhash });
  tx.add(...ixs);
  tx.sign(...signers);
  const sig = await conn.sendRawTransaction(tx.serialize(), { skipPreflight: false });
  const conf = await conn.confirmTransaction({ signature: sig, blockhash, lastValidBlockHeight }, "confirmed");
  if (conf.value.err) throw new Error(`${label} failed: ${JSON.stringify(conf.value.err)}`);
  console.log(`${label}: ${sig}`);
}

// 0. already deployed?
if (await conn.getAccountInfo(program.publicKey)) {
  console.log("program already live — nothing to do (run sol.sh deploy for NTT init)");
  process.exit(0);
}

// 1. buffer: resume or create
let buffer: any;
if (fs.existsSync(bufferPath)) {
  buffer = load(bufferPath);
  console.log(`resuming buffer ${buffer.publicKey.toBase58()}`);
} else {
  buffer = Keypair.generate();
  fs.writeFileSync(bufferPath, JSON.stringify(Array.from(buffer.secretKey)), { mode: 0o600 });
  console.log(`new buffer ${buffer.publicKey.toBase58()} (keypair saved to ${bufferPath})`);
}
const bufInfo = await conn.getAccountInfo(buffer.publicKey, { dataSlice: { offset: 0, length: 0 } });
if (!bufInfo) {
  const space = HEADER + binary.length;
  const rent = await conn.getMinimumBalanceForRentExemption(space);
  console.log(`creating buffer: ${space} bytes, rent ${(rent / 1e9).toFixed(4)} SOL`);
  const initData = Buffer.alloc(4); // InitializeBuffer = variant 0
  await sendTx(
    [
      priceIx(),
      SystemProgram.createAccount({
        fromPubkey: payer.publicKey, newAccountPubkey: buffer.publicKey,
        lamports: rent, space, programId: LOADER,
      }),
      new TransactionInstruction({
        programId: LOADER,
        keys: [
          { pubkey: buffer.publicKey, isSigner: false, isWritable: true },
          { pubkey: payer.publicKey, isSigner: false, isWritable: false },
        ],
        data: initData,
      }),
    ],
    [payer, buffer],
    "create+init buffer"
  );
}

// 2. write missing chunks until buffer bytes == binary
function writeIx(offset: number, bytes: Buffer) {
  const data = Buffer.alloc(16 + bytes.length); // Write = variant 1 | offset u32 | vec<u8>
  data.writeUInt32LE(1, 0);
  data.writeUInt32LE(offset, 4);
  data.writeBigUInt64LE(BigInt(bytes.length), 8);
  bytes.copy(data, 16);
  return new TransactionInstruction({
    programId: LOADER,
    keys: [
      { pubkey: buffer.publicKey, isSigner: false, isWritable: true },
      { pubkey: payer.publicKey, isSigner: true, isWritable: false },
    ],
    data,
  });
}
// Full-account getAccountInfo (~1.2 MB JSON) times out on this network —
// verify via small dataSlice reads instead, with retries. null value = account
// not visible yet (fresh create, lagging node) — retried like an error.
async function rpcSlice(offset: number, length: number): Promise<Buffer | null> {
  const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "getAccountInfo",
    params: [buffer.publicKey.toBase58(),
      { encoding: "base64", commitment: "confirmed", dataSlice: { offset, length } }] });
  const r = await fetch(rpc, { method: "POST", headers: { "Content-Type": "application/json" }, body });
  const j: any = await r.json();
  return j.result?.value ? Buffer.from(j.result.value.data[0], "base64") : null;
}
const WINDOW = 100 * CHUNK; // 80 KB per read
async function missingChunks(): Promise<number[]> {
  const missing: number[] = [];
  for (let base = 0; base < binary.length; base += WINDOW) {
    const len = Math.min(WINDOW, binary.length - base);
    let slice: Buffer | null = null;
    for (let a = 0; a < 8 && !slice; a++) {
      if (a > 0) await new Promise((r) => setTimeout(r, 2500));
      try { slice = await rpcSlice(HEADER + base, len); } catch {}
    }
    if (!slice) throw new Error(`slice read @${base} kept failing — re-run to resume`);
    for (let o = base; o < base + len; o += CHUNK) {
      const end = Math.min(o + CHUNK, binary.length);
      if (!slice.subarray(o - base, end - base).equals(binary.subarray(o, end))) missing.push(o);
    }
  }
  return missing;
}
let missing = await missingChunks();
console.log(`chunks: ${Math.ceil(binary.length / CHUNK)} total, ${missing.length} missing`);
for (let pass = 1; missing.length > 0 && pass <= 10; pass++) {
  console.log(`pass ${pass}: sending ${missing.length} chunks…`);
  let { blockhash } = await conn.getLatestBlockhash("finalized");
  let sent = 0;
  for (const o of missing) {
    if (sent % 150 === 149) ({ blockhash } = await conn.getLatestBlockhash("finalized"));
    const tx = new Transaction({ feePayer: payer.publicKey, recentBlockhash: blockhash });
    tx.add(ComputeBudgetProgram.setComputeUnitLimit({ units: 5_000 }), priceIx(),
           writeIx(o, binary.subarray(o, Math.min(o + CHUNK, binary.length))));
    tx.sign(payer);
    try { await conn.sendRawTransaction(tx.serialize(), { skipPreflight: true, maxRetries: 0 }); }
    catch (e: any) { console.error(`send @${o}: ${e.message?.slice(0, 100)}`); }
    if (++sent % 200 === 0) console.log(`  sent ${sent}/${missing.length}`);
    await new Promise((r) => setTimeout(r, RATE_MS));
  }
  await new Promise((r) => setTimeout(r, 10_000));
  missing = await missingChunks();
  console.log(`after pass ${pass}: ${missing.length} missing`);
}
if (missing.length > 0) { console.error("buffer incomplete after 10 passes — re-run to resume"); process.exit(1); }
console.log("buffer complete & verified byte-for-byte");

// 3. finalize: createAccount(program) + DeployWithMaxDataLen(exact size)
const [programData] = PublicKey.findProgramAddressSync([program.publicKey.toBuffer()], LOADER);
const deployData = Buffer.alloc(12); // DeployWithMaxDataLen = variant 2 | max_data_len u64
deployData.writeUInt32LE(2, 0);
deployData.writeBigUInt64LE(BigInt(binary.length), 4);
await sendTx(
  [
    priceIx(),
    SystemProgram.createAccount({
      fromPubkey: payer.publicKey, newAccountPubkey: program.publicKey,
      lamports: await conn.getMinimumBalanceForRentExemption(36), space: 36, programId: LOADER,
    }),
    new TransactionInstruction({
      programId: LOADER,
      keys: [
        { pubkey: payer.publicKey, isSigner: true, isWritable: true },
        { pubkey: programData, isSigner: false, isWritable: true },
        { pubkey: program.publicKey, isSigner: false, isWritable: true },
        { pubkey: buffer.publicKey, isSigner: false, isWritable: true },
        { pubkey: SYSVAR_RENT_PUBKEY, isSigner: false, isWritable: false },
        { pubkey: SYSVAR_CLOCK_PUBKEY, isSigner: false, isWritable: false },
        { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
        { pubkey: payer.publicKey, isSigner: true, isWritable: false },
      ],
      data: deployData,
    }),
  ],
  [payer, program],
  "finalize"
);
fs.unlinkSync(bufferPath); // buffer consumed into programdata
console.log(`PROGRAM LIVE: ${program.publicKey.toBase58()} — now run sol.sh deploy for NTT initialization`);
