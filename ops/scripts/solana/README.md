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

Post-deploy: `_verify.sh <token>` publishes the anchor IDL on-chain so
explorers decode instruction names (cosmetic, ~0.08 SOL reclaimable; run
while the payer is still upgrade authority). `fetch` diffs on-chain vs build,
`close` refunds. Explorers decode legacy (anchor 0.29) IDLs unreliably —
"Unknown Instruction" can persist even with a correct publish.
