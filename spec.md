# Spec: ZEC / NEAR → Hydration via Omni Bridge + Solana forwarder + NTT

## Goal

Move ZEC and NEAR between NEAR/Zcash and Hydration (Wormhole chain 73), in both directions, with **one user signature** per transfer. Omni Bridge is used as-is; we don't need NEAR's cooperation. The only new on-chain code is a **forwarder program on Solana** that connects Omni and NTT.

## Why this design

- Zcash has no smart contracts and NTT has no NEAR implementation, so NTT can't run at either origin.
- Omni Bridge already bridges ZEC and NEAR to Solana as **Omni mints**. Their mint authority belongs to Omni, so NTT on Solana runs in **locking** mode and Hydration runs in **burning** mode.
- Omni is permissionless on chains it already supports: any recipient, including a PDA, and permissionless token deployment. Making Hydration an Omni chain would need NEAR governance and is out of scope.
- Omni's Solana payload has **no message field**, and `finalize_transfer` makes no CPI into the recipient. So there's no callback: a keeper has to trigger the forwarding.

## Flows

### Inbound: NEAR/Zcash → Hydration
1. **User signs once**: an Omni transfer (NEAR `ft_transfer_call`, or a Zcash deposit via Omni/Intents) with recipient = `PDA(["fwd", hydration_recipient])` on Solana, and the quoted Omni relayer fee attached.
2. An Omni relayer finalizes on Solana, and the tokens land in the PDA's ATA. **Omni creates that ATA and pays its rent** (verified, see below), funded by the user's Omni fee.
3. The keeper calls `flush_inbound(hydration_recipient, signed_executor_quote)`. The program re-derives the PDA, and the PDA signs via `invoke_signed` into NTT `transfer` (locking) plus `ntt-with-executor` `relay_ntt_message`.
4. The Executor delivers on Hydration and the NTT token is minted to `hydration_recipient`.

### Outbound: Hydration → NEAR/Zcash
1. **User signs once**: an NTT transfer on Hydration with recipient = `PDA(["out", near_recipient])` on Solana. It pays the Executor delivery, which includes the ATA rent (verified), plus an optional SOL gas drop-off to the PDA.
2. The Executor redeems on Solana: it creates the PDA's ATA if missing, and `release_inbound` unlocks the tokens into it.
3. The keeper calls `flush_outbound(near_recipient)`. The PDA does a CPI into Omni `init_transfer` to `near_recipient`, paying the Omni fee in-kind from the token (`fee`) or from the drop-off SOL (`native_fee`).
4. An Omni relayer finalizes on NEAR, or on Zcash via Omni's chain-signature withdrawal.

## Recipient binding (security core)

- The destination address is **never carried in a payload**. It is a PDA seed:
  - inbound: `seeds = ["fwd", hydration_recipient: [u8; 32]]` (Wormhole universal address; Hydration EVM H160 left-padded)
  - outbound: `seeds = ["out", hash(near_recipient)]` (NEAR account IDs are variable-length strings up to 64 bytes, so hash them; the instruction takes the raw string and hashes it on-chain)
- `flush_*` takes the recipient as an instruction argument, re-derives the PDA, and requires it to own the source ATA. A wrong recipient derives a different, empty PDA and the call fails. **The keeper can trigger funds but can never redirect them.**
- `flush_*` is **permissionless**: anyone can crank, so the keeper is not a liveness dependency.

## Discovery (how the keeper learns the recipient)

A PDA is a one-way hash, so the keeper needs the preimage from somewhere. Every hint is untrusted, and the keeper checks it by re-deriving the PDA.

| Source | Mechanism | Covers |
|---|---|---|
| **Frontend registration** (primary) | Frontend POSTs `(pda, recipient, direction)` to the keeper API when it shows the deposit address | everything, including native Zcash deposits |
| NEAR-side hint (optional) | Recipient carried in the user's Omni message on NEAR; keeper indexes NEAR | NEAR-origin inbound. **Unverified**: check whether Omni's NEAR transfer message has a free-form field |
| NTT additional payload (optional) | `near_recipient` in the NTT transfer payload from Hydration | outbound. **Unverified**: check whether our NTT version supports additional payloads |
| Manual | Anyone calls `flush_*` with the known recipient | fallback |

A lost hint only delays a transfer; the funds stay in the PDA until someone flushes.

## Who pays what

| Cost | Payer | Status |
|---|---|---|
| Omni relayer fee (includes PDA ATA rent on Solana) | user, in their Omni tx | verified that Omni creates the ATA with its relayer as payer; **check with a real quote that the fee covers the rent** |
| Executor delivery Hydration → Solana (includes PDA ATA rent) | user, in their Hydration NTT tx (`msgValue`) | verified in SDK |
| NTT `outbox_item` rent (inbound, ~139 B ≈ 0.0019 SOL) | **fee vault PDA** | verified: `init, payer = payer`, and NTT has no close instruction, so the rent is permanent |
| Wormhole message account rent (inbound, ~300 B ≈ 0.003 SOL) + core bridge fee | **fee vault PDA** | verified: `post_message` in `release_wormhole_outbound`, seeded per outbox item, permanent |
| Executor `exec_amount` Solana → Hydration | **fee vault PDA** | — |
| `flush_*` tx signature + priority fees | keeper | the only thing the keeper pays |
| Omni `init_transfer` accounts/fees on Solana (outbound) | fee vault PDA, or the user's Executor SOL drop-off | **open**: check the rent that Omni's Solana `init_transfer` creates |
| Omni fee Solana → NEAR (outbound) | in-kind from the token (`fee`) | — |

The rent figures are estimates from account sizes; measure them on the first real transfer.

**Hard requirement: the off-chain bot must never pay account rent.** ATA creation is covered by Omni or the Executor, as described above. Every other SOL cost goes to an on-chain **fee vault PDA** (`["fee_vault"]`, system-owned, zero data), which signs as NTT `payer` via `invoke_signed`. Hydration's treasury funds it.

**How `flush_inbound` executes:**
1. The forwarder PDA signs SPL `approve(session_authority, amount)`, where `session_authority = PDA(NTT, ["session_authority", from.owner, keccak(transfer_args)])`.
2. CPI into NTT `transfer_lock` with `payer = fee_vault`. The `outbox_item` is a fresh keypair that the keeper includes as a co-signer of the outer tx.
3. CPI into `release_wormhole_outbound` with `payer = fee_vault`.
4. CPI into `ntt-with-executor` `relay_ntt_message` with `payer = fee_vault`, using the keeper-supplied signed quote. Enforce a config cap on `exec_amount` so a malicious caller can't drain the vault.

**Fee model:** launch with the treasury funding the fee vault, so users pay only Omni/Executor fees. The config carries a per-mint `forward_fee` (initially 0) that `flush_*` sends to a treasury ATA. The treasury periodically swaps those fees to SOL to refill the vault, which gets Hydration to break-even with no oracle and no program upgrade. Also enforce a per-mint `min_amount` (dust threshold) so fees can't eat a transfer. Because `flush_*` is permissionless, every vault-funded instruction must be bounded: one flush per non-empty PDA balance at or above `min_amount`, and `exec_amount` at or below the cap.

## Verified facts (with sources)

- **Omni Solana `finalize_transfer`** (`Near-One/omni-bridge`, `solana/programs/bridge_token_factory/src/instructions/user/finalize_transfer.rs`):
  - `recipient: UncheckedAccount`, so a PDA recipient is allowed
  - `token_account` is `init_if_needed`, `payer = common.payer` (the relayer), `associated_token::authority = recipient`
  - `FinalizeTransferPayload { destination_nonce, transfer_id, amount, fee_recipient }`: no message, no CPI to the recipient
- **NTT Solana `release_inbound`** (`solana/programs/example-native-token-transfers/src/instructions/release_inbound.rs:23-29`): requires an existing recipient ATA; it doesn't create one.
- **NTT-with-Executor SDK** (`solana/ts/sdk/nttWithExecutor.ts:324-364`): `estimateMsgValueAndGasLimit` adds the 165-byte ATA rent to `msgValue` when the recipient ATA is missing, and derives the ATA with `allowOwnerOffCurve = true`, so PDA recipients work. The sender pays it on the source chain.
- The Executor is registered for Hydration (chain 73) (`ops/README.md`, `ops/DEPLOYMENT.md`). Auto-delivery in both directions is **still to be confirmed in a smoke test**.

## Open items (resolve before or during implementation)

1. Which Omni mints on Solana: the exact mint addresses for ZEC and NEAR, and their liquidity. Intents historically holds ZEC as a PoA token (`zec.omft.near`), and Omni has its own chain-signature Zcash path. Confirm which one has a Solana Omni mint.
2. Whether a native Zcash deposit can reach a Solana recipient in **one user action** (Omni Zcash path, or an Intents/1Click deposit address with a Solana destination). The same question applies to outbound to a native Zcash address.
3. Whether the Omni fee quote covers the ATA rent for a fresh PDA recipient (test with a real quote).
4. ~~Whether the NTT outbox item rent can be reclaimed.~~ Resolved: it can't, and it's paid from the fee vault (see Who pays what). Still open: the rent created by Omni's Solana `init_transfer` on outbound.
5. The NEAR-side and NTT additional-payload hint channels (see Discovery).
6. A real round-trip smoke test of Executor auto-delivery Solana ↔ Hydration.

## Deliverables

1. **Solana forwarder program** (Anchor):
   - `initialize(config)`: admin, per-mint `forward_fee`, `min_amount`, and the NTT manager/transceiver/executor program IDs for each mint
   - `flush_inbound(hydration_recipient, executor_quote…)` → NTT `transfer` (locking) + Executor relay
   - `flush_outbound(near_recipient)` → Omni `init_transfer`
   - `set_config` (admin only), `pause`
   - No refund path in v1. Funds wait in the PDA until a flush succeeds. A timeout refund to the Omni origin could come later.
2. **NTT deployments** for `zec` and `near`: Solana (locking, Omni mint) ↔ Hydration (burning), following the existing `ops/tokens/*` pipeline and deployment-record conventions.
3. **Keeper service**: registration API, a watcher for PDA ATA balances (from Omni finalize events or `NTT release`), Executor quote fetching, and flush submission. Its hot key holds SOL only. Base it on whm's `mrelayer`.
4. **Frontend integration**: derive the PDA, fetch the Omni or Executor quote, register the hint, and track status.

## Repo and ops constraints (must follow)

- **Solana deploys:** `ntt update` wipes the local Solana deploy patches. Re-apply them before any Solana deploy.
- **Solana IDLs** are on-chain, and their authority is the hot payer keys, not the Squads vault. Handle the forwarder's IDL the same way and document it.
- **Custody:** program upgrade authority and NTT ownership go to the existing custodians only: Squads vault on Solana, and the `aave-gov` account on Hydration. Never transfer them anywhere else. Transferring ownership is the last deploy step.
- **Hydration RPC:** always use Dwellir, never `rpc.hydradx.cloud`.
- **Commits:** plain house-style messages, no AI co-author trailers.
- Deployment records are write-once and follow `ops/SCHEMA.md`. Set rate limits in `ops/LIMITS.md` conservatively, because Omni-wrapped assets carry Omni's bridge risk.
