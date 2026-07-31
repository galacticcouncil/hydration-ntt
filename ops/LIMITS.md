# NTT rate limits — what users actually experience

24h sliding-window limits, per chain, per direction (`outbound` + per-peer
`inbound`), set in each token's `deployment.json` and applied with `ntt push`.
Capacity refills **continuously** (linearly over the window) — hitting the
limit is never a hard until-midnight stop. Our config: real limits on the hub
legs, Hydration side ~unlimited (the runtime mint fuse governs that side).

Queued transfers consume their capacity when they *enter* the queue, so
queued volume doesn't stack on top of the live limit when it completes.

## The `shouldQueue` flag

Only exists at **send** time; the receive side has no flag. Defaults are
`false` (= revert on limit) everywhere:

- contract: the simple `transfer(amount, chain, recipient)` overload
  hardcodes `false` (evm/src/NttManager/NttManager.sol, `transfer` overloads);
  the full overload has no default
- SDK NTT route (Portal/Connect and most integrators): `queue: false`
  (sdk/route/src/manual.ts); the route pre-checks capacity and warns the
  transfer is "likely to be queued/delayed" instead of opting in
- `ntt` CLI token-transfer: inherits the SDK default

## Hub → Hydration (Ethereum / Base / Solana / Sui → Hydration)

Only the **hub outbound limit** can hit, at send time:

| Case | Funds taken? | Wait | Completion | Automatic? |
|---|---|---|---|---|
| Under limit | yes | none | Executor delivers to Hydration | ✅ fully automatic |
| Over limit, `queue=false` (default) | **no — reverts in wallet** | — | user retries smaller / later | — |
| Over limit, `queue=true` | yes (locked on hub) | 24h on hub | sender calls `completeOutboundQueuedTransfer` (pays that day's delivery fee); sender may `cancelOutboundQueuedTransfer` for a refund while queued; delivery afterwards is automatic | ❌ manual release |

Hydration's inbound is unlimited → never a second wait on arrival. Only
exception: the runtime mint fuse (`xcm_rate_limit` / deposit limit) — if it
trips, delivery fails and retries later; the user acts on nothing.

## Hydration → hub (Hydration → Ethereum / Base / Solana / Sui)

Hydration outbound is unlimited, so the send **always succeeds and burns
instantly**; only the **hub inbound limit** can hit, on arrival:

| Case | Funds taken? | Wait | Completion | Automatic? |
|---|---|---|---|---|
| Under limit | yes | none | Executor delivers on hub | ✅ fully automatic |
| Over limit (no flag exists here) | **yes — already burned** | 24h on hub | recipient claims (`completeInboundQueuedTransfer`, "claim" in Connect) | ❌ manual claim, **no cancel** |

## Takeaways

- Going **in**, users only lose time if a frontend explicitly opts into
  queueing — the default is a harmless revert.
- Going **out**, a limit hit always means committed funds waiting 24h plus a
  manual claim — size the hub **inbound** limits generously; they are the
  support-ticket generator.
- Worst case is a double wait (queued outbound → completed → lands over the
  destination's inbound limit). With Hydration unlimited it can't happen
  going in; going out only the hub inbound wait applies.
- The rate limit only *slows* an attacker's exit; `pause()` (owner or
  pauser) is what stops it — that's why the pauser should be a fast
  responder.

Changing limits after the ownership handover = owner-only txs from the
custodian: Safe Transaction Builder JSONs via demo-ntt-evm-multisig-tools
(EVM hubs), Squads proposals via manageLimits.ts (Solana), governance
dispatch on Hydration — see ops/TRANSFER_OWNERSHIP.md.
