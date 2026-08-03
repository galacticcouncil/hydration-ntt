# Emergency pause — fast path per leg

Goal: any single TC member can halt a leg within minutes of an alert, without
gathering a full multisig round. Pausing is grief-limited by design — on EVM
`pause()` is `onlyOwnerOrPauser` but `unpause()` is `onlyOwner`
(`evm/src/NttManager/ManagerBase.sol:338-343`), so the fast path can stop the
bridge but never resume it. **Unpause is always a full-threshold owner action,
after root cause.**

Pause order in an incident: **hub leg first** — custody unlocks happen there
(pause gates inbound releases too, incl. queued completions,
`evm/src/NttManager/NttManager.sol:192-359`) — then the Hydration side.

## Ethereum / Base — pauser role, NOT pre-approved Safe txs

A pre-signed Safe tx sits at one nonce; any other executed tx invalidates it,
and re-collecting 4/7 across manager+transceiver per token will rot. Instead:

1. Deploy a **Pauser Safe, threshold 1/N**, all TC members as owners, on
   Ethereum and Base.
2. Owner Safe (4/7) calls `transferPauserCapability(pauserSafe)` on **every
   manager and transceiver** (currently pauser = owner Safe, see
   `deployment.json`s). Tx JSONs via demo-ntt-evm-multisig-tools.
3. Any member then pauses any leg in one Safe action, any time. Nothing to
   keep fresh.

Compromised single key worst case: grief-pause + move the pauser role
(`transferPauserCapability` is `onlyOwnerOrPauser`) — owner reclaims both.

## Solana (sol, jitosol, prime) — pre-approved Squads proposals

No pauser role: `set_paused` is config-owner-only
(`solana/…/instructions/admin/mod.rs:245-257`). Squads suits pre-approval:
pending vault txs survive other vault executions and only go stale on a
**config transaction** (member/threshold change).

1. Create 3 vault txs — `set_paused(true)` per program — approve to
   threshold, leave un-executed.
2. Verify **every TC member has Executor permission**.
3. **Re-create all 3 after any Squads config change** (mandatory step of any
   member/threshold runbook).

## Hydration — `clear_ntt_minter`, not the EVM pause

Owner/pauser on Hydration legs is the aave-gov account — an EVM `pause()` is a
governance dispatch, slow. The faster lever (`ops/DEPLOYMENT.md` Step 5):
`currencies.clear_ntt_minter(N)` gates mint **and** burn — the whole Hydration
side of asset `N` goes inert both directions, deliveries stay replayable.
Confirm the exact origin + latency and record per-asset ids here.

## Sui — pre-signed multisig blob (stopgap, discipline required)

Native k-of-n multisig: no on-chain proposal state. Pre-approval = tx bytes +
4 offline signatures stored for later broadcast. The bytes pin owned inputs by
`(id, version, digest)` — the blob is invalidated by **any admin op touching
the AdminCap** (every admin fn takes `&AdminCap`) and by **any spend of the
gas coin**. Failure shows up only at broadcast time.

1. Split a **dedicated gas coin** owned by the multisig; never touch it.
2. Build pause tx (`ntt::state::pause`, needs `AdminCap`,
   `sui/packages/ntt/sources/state.move:322`), collect 4 sigs (multisig
   toolkit), no expiration; store bytes + sigs in the TC vault.
3. **Re-sign after every Sui admin action** — closing step of every Sui
   runbook.
4. Watchdog **dry-runs the stored bytes daily** — staleness becomes an alert,
   not an incident-time surprise.
5. Execute: `sui client execute-combined-signed-tx` — any member, anywhere.

Sui is the locking hub for the `sui` leg (custody lives there). Long-term fix:
package upgrade adding a pause-only `PauserCap` held 1/N — the only variant
that can't rot. On roadmap, not urgent.

## Watchdog

P1 — page every member + group message (pause candidates):

- **Supply invariant per token**: Hydration representation supply vs hub
  custody (manager balance EVM / `config.custody` ATA Solana / `State`
  balance Sui — locations in `ops/CUSTODY.md`). Custody drop without matching
  burn, or drift beyond in-flight tolerance.
- **Unmatched mint**: every Hydration mint must trace to a VAA from the
  expected emitter (Wormholescan API) + a hub lock event.
- **Admin events with no TC decision**: EVM `OwnershipTransferred`,
  `PauserTransferred`, `Upgraded`, `PeerUpdated`, `TransceiverAdded/Removed`,
  `ThresholdChanged`, limit updates; Solana program upgrades / config owner
  change / `SetPaused` / **IDL writes** (IDL authority = hot payer keys);
  Sui txs touching `UpgradeCap` or `AdminCap`.
- **Pause flag flip either direction** — an unpause nobody ordered is the
  alarm of alarms.
- **Multisig events**: every new Safe/Squads proposal (all members hear about
  all proposals), signer/threshold changes, **Safe module enabled / guard
  changed** (bypasses threshold).
- **Hot key activity**: any tx from payer/deployer keys that should be
  dormant.

P2 — group channel:

- Rate-limit pressure: outbound utilization > 50% / 80%;
  `Outbound/InboundTransferQueued` (pause turns the 24h hold into a stop —
  queue events are when a human looks).
- Large single transfer (> ~25% of daily limit); velocity anomalies; many
  transfers sized just under the large-transfer threshold.
- Watchdog self-health: per-chain heartbeat + head-lag; silence itself pages
  (dead-man switch).

Plumbing: TS poller per chain (RPCs from `overrides.json`, Dwellir for
Hydration) → Telegram/Discord bot; or Tenderly/Defender (EVM), Helius
webhooks (Solana programs + Squads), Sui object-change subscription.
**P1 alerts embed the action link** (Pauser-Safe tx / Squads proposal /
stored Sui blob location) — reaction is one click from the phone.

## Drill

Quarterly, one low-traffic token, end to end: fire the fast path, verify
transfers revert on-chain, unpause via full owner threshold. The fast path is
only real once it has been fired. Log date + tx hashes below.

| Date | Leg | Pause tx | Unpause tx | Notes |
| ---- | --- | -------- | ---------- | ----- |
