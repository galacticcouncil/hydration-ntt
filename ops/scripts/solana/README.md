# Solana deploy notes

The stock `ntt add-chain Solana` needs three small patches in
`~/.ntt-cli/.checkout/cli/src/solana/deploy.ts` (the `deployCommand` array).
**`ntt update` wipes them — re-apply before any Solana deploy:**

```ts
"--max-len", fs.statSync(binary).size.toString(),  // exact-size rent: ~6.45 SOL, not 12.9
                                                   // (bigger upgrades need `solana program extend` first)
"--use-rpc",                                       // send writes via RPC, not TPU (home networks drop TPU)
"--commitment", "confirmed",                       // was "finalized": stale preflight can't see the fresh
                                                   // buffer -> instant "invalid account data" on Write
```

Symptoms without them: frozen progress bar + "Blockhash expired" retries
(TPU drops / fee starvation — scripts pass `--solana-priority-fee 100000`),
or instant `Error processing Instruction 2: invalid account data`.

Facts per deployment: one full program per token (~926 KB), rent ~6.45 SOL
(a reclaimable deposit — but `solana program close` kills the program id
forever and strands any custody; decommission-only). A failed attempt parks
its rent in the buffer account: `solana program close --buffers --keypair
<payer> -u <rpc>` refunds it; repo-root `buffer.json` and the on-chain buffer
live and die together.

If write-phase throughput is still too slow to finish inside the 5-retry
budget (~0.3 tx/s was measured on the operator's home network even with all
patches), deploy from a different network — the sender in solana-cli 1.18 is
the bottleneck and no flag fixes it.

## Plan B: _tools/fast-deploy.ts

Both mainnet deploys so far (SOL 2026-07-29, jitoSOL 2026-07-30) stalled the
stock write phase completely (0.0%, "Blockhash expired" retries, zero txs
landed — network switch didn't help). The proven fallback replaces only the
write phase; the stock CLI still does everything else:

1. Run the token's `deploy` normally — it builds + patches the binary,
   verifies it, then stalls sending. Kill it, close any created buffer
   (`solana program close --buffers`), `rm buffer.json`.
2. Upload + finalize with the paced writer (idempotent — re-run to resume;
   skips finalize if the program is already live):

       RPC=$(jq -r .chains.Solana.rpc overrides.json)   # repo root
       ~/.bun/bin/bun run ops/scripts/solana/_tools/fast-deploy.ts "$RPC" \
         ops/tokens/<t>/keys/payer.json ops/tokens/<t>/keys/program.json \
         .deployments/Solana-<ver>/solana/target/deploy/example_native_token_transfers.so

3. Set `const skipDeploy = true` in ~/.ntt-cli/.checkout/cli/src/solana/deploy.ts,
   rerun the token's `deploy` (now init-only: config + transceiver registration),
   then revert the flag immediately.

Post-deploy: `_verify.sh <token>` publishes the anchor IDL on-chain so
explorers decode instruction names (cosmetic, ~0.08 SOL reclaimable; run
while the payer is still upgrade authority). `fetch` diffs on-chain vs build,
`close` refunds. Explorers decode legacy (anchor 0.29) IDLs unreliably —
"Unknown Instruction" can persist even with a correct publish.
