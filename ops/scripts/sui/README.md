# Sui deploy notes

Everything below was hit on the SUI mainnet deploy (2026-07-31) — the first
Sui NTT deploy anyone ran after the fork's @mysten/sui v2 gRPC migration
(#899). Sui support upstream was tested on testnet only.

## 0. Native binary (Apple Silicon)

An Intel-Homebrew `sui` dies with `Illegal instruction: 4` (SIGILL) under
Rosetta — but only in the network paths (`client new-env`, publish), so
`sui --version` "working" proves nothing. Symptom inside the ntt CLI: the
real error is swallowed and surfaces as
`Environment config not found for [Some("mainnet")]`.
Fix: the arm64 release binary (`sui-mainnet-vX.Y.Z-macos-arm64.tgz` from
MystenLabs' GitHub releases) — `brew`/`suiup` under a Rosetta shell both
pick x86_64 again.

## 1. Deploy `--local`, never `--latest`

The `v1.0.0+sui` tag pins the wormhole Move dependency to `rev =
"sui/testnet"` — its package id does not exist on mainnet
(`Failed to fetch package Wormhole … Object 0xf473… not found` at publish) —
and predates the Sui 1.63+ package-management system (#814) that the CLI's
`-e mainnet` build flow expects. This repo's `sui/` tree has both fixes;
`scripts/sui/sui.sh deploy` therefore uses `--local`. `NTT_COMMIT` +
`sui/packages/*/Published.toml` are the audit refs (deployment.json shows
`"version": "dev"` — the CLI's placeholder for Sui, cosmetic; `ntt pull`
rewrites it, don't fight it).

## 2. CLI patches (committed in this repo; `ntt update` wipes the checkout)

The gRPC migration left the Sui deploy/push paths calling the removed
JSON-RPC API. Fixed in this repo — **after any `ntt update`, re-sync into
`~/.ntt-cli/.checkout` before touching a Sui leg:**

```sh
cp cli/src/sui/deploy.ts  ~/.ntt-cli/.checkout/cli/src/sui/deploy.ts
cp cli/src/sui/signer.ts  ~/.ntt-cli/.checkout/cli/src/sui/signer.ts
cp cli/src/query.ts       ~/.ntt-cli/.checkout/cli/src/query.ts
cp sui/ts/src/ntt.ts      ~/.ntt-cli/.checkout/sui/ts/src/ntt.ts
# the CLI imports the COMPILED dist of sui/ts — patch it too:
#   getMode() must read modeField["@variant"] ?? modeField.variant
vi ~/.ntt-cli/.checkout/sui/ts/dist/esm/ntt.js
```

What they fix (symptom → cause):

1. `client.getOwnedObjects is not a function` (deploy, after packages
   published) → v2 client is `listOwnedObjects({owner, type})`, result
   `.objects[i].objectId`.
2. Old `signAndExecuteTransaction({options:{showObjectChanges}})` +
   `.objectChanges` → `signAndExecuteWithObjectChanges()` helper in
   deploy.ts rebuilds objectChanges from `effects.changedObjects`
   (`idOperation === 'Created'`) + the `objectTypes` map.
3. `CommandArgumentError { arg_idx: 1, kind: TypeMismatch }` registering the
   transceiver → `state::register_transceiver<Transceiver, T>` takes a pure
   `ID`, so `tx.pure.id(stateId)`, not `tx.object(...)` (pre-existing bug).
4. `TypeError: options.signatures.map` on push → the CLI signer must return
   `{transaction: Uint8Array, signatures: [sig]}` (v2 executeTransaction
   options), not `{transactionBlock, signature}`; sdk-sui's `sendWait`
   passes it through verbatim.
5. `Invalid mode in NTT state` on pull/status → gRPC json renders Move enums
   as `{"@variant": "Locking"}`, not `{variant: …}` (sui/ts getMode).

## 3. Resume gotchas

- Publishes are recorded in `sui/packages/*/Published.toml` — a deploy
  re-run offers "1) Continue setup" (packages stay, no double gas) vs
  "2) Redeploy fresh". These (+ `Move.lock`) are deployment output, so they
  are gitignored in the source tree and ARCHIVED at
  `ops/tokens/sui/sui-publish/` (they also hold the on-chain PACKAGE ids —
  deployment.json only has the state object ids). The CLI needs live copies
  on disk — restore before any Sui resume/upgrade if missing:

      for p in ntt ntt_common wormhole_transceiver; do
        cp ops/tokens/sui/sui-publish/$p.Published.toml sui/packages/$p/Published.toml
        cp ops/tokens/sui/sui-publish/$p.Move.lock      sui/packages/$p/Move.lock
      done
- Setup progress lives in `sui/packages/.sui-deploy-progress.mainnet.json`
  but the success path DELETES it even when transceiver registration only
  warn-failed. The setup DeployerCaps are consumed, so a resume then throws
  "deployment may be in an inconsistent state" — recreate the file by hand
  with the ids from the deploy log (nttStateId, nttAdminCapId,
  transceiverStateId, whTransceiverAdminCapId, transceiverRegistered).

## 4. RPC landscape

Public Sui fullnodes dropped JSON-RPC entirely (gRPC/GraphQL only):

- the ntt CLI talks **gRPC** to the public fullnode — leave `overrides.json`
  without a Sui entry; a JSON-RPC-only provider there breaks it;
- read-side bash tooling (`scripts/_peering.sh`) needs **JSON-RPC** →
  `SUI_JSONRPC` (default in `_lib.sh` = QuickNode endpoint).

## 5. Ownership

No `transferOwnership` and **no pauser role** (the SDK's `getPauser()`
returns the owner) — control is three capability objects, transferred with
plain `sui client transfer` to the custodian multisig (see
`ops/TRANSFER_OWNERSHIP.md`): the NTT `state::AdminCap` (= owner AND
pauser — pausing costs a multisig quorum), the NTT `upgrades::UpgradeCap`
(wraps the raw package cap, which no longer exists as its own object), and
the `wormhole_transceiver::AdminCap`. Registration of who-holds-what:
`deployment.json` tracks only owner/pauser; the cap object ids live
on-chain in the State object (`admin_cap_id` / `upgrade_cap_id`).
