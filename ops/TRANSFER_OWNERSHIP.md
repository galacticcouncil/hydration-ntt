# Ownership handover (DEPLOYMENT.md Step 7, final step)

Move every role the hot deployer keys still hold to the multisigs — per
token, only **after** smoke tests (Step 8). What exists per leg:

| Leg | Roles on the hot key | Tool |
| --- | --- | --- |
| EVM (Ethereum / Base / Hydration) | manager owner + pauser, transceiver owner + pauser | initial: `ntt transfer-ownership` + `cast` (deployer-signed); after: [demo-ntt-evm-multisig-tools] |
| Solana (sol, jitosol, prime) | NTT config owner + program upgrade authority | [demo-ntt-solana-multisig-tools] |
| Hydration representations (runtime assets) | nothing — minter binding + registry entry are governance-held | — |

## Before anything

- The multisig must be able to **execute a tx on that chain** — Safe:
  deployed there (Hydration EVM, chain 222222, is the open item); Squads:
  vault live on mainnet. Prove it with a harmless tx before the
  irreversible step.
- The owner transfer is **IRREVERSIBLE** and cuts off `ntt push` for that
  chain — afterwards owner-only changes (limits, peers, pause, upgrades)
  execute as multisig txs against the manager; `ntt status` stays useful
  read-only.
- The pauser is a **separate role** on both manager and transceiver — the
  owner transfer does NOT move it. Pauser should be a fast responder: it is
  what turns the 24h rate-limit hold into a stop.

## EVM legs — initial handover (deployer key)

[demo-ntt-evm-multisig-tools] can't do this part: it only builds txs the
Safe executes, and the roles sit on the deployer EOA. So the initial
transfer is signed with the leg's key (`HYDRATION_`/`ETHEREUM_`/
`BASE_PRIVATE_KEY` → `ETH_PRIVATE_KEY`), per token, per chain.

Pausers first, on manager AND transceiver:

```sh
D=ops/tokens/<t>/deployment.json; C=<Ethereum|Base|Hydration>; RPC=<rpc>
M=$(jq -r ".chains.$C.manager" $D)
X=$(jq -r ".chains.$C.transceivers.wormhole.address" $D)
cast send $M 'transferPauserCapability(address)' <PAUSER_MULTISIG> --private-key $ETH_PRIVATE_KEY --rpc-url $RPC
cast send $X 'transferPauserCapability(address)' <PAUSER_MULTISIG> --private-key $ETH_PRIVATE_KEY --rpc-url $RPC
```

Then owner — one manager tx that propagates to every registered transceiver
(`ManagerBase.transferOwnership`); run from the repo root so
`overrides.json` pins the RPCs:

```sh
ntt transfer-ownership $C --destination <OWNER_MULTISIG> -p $D
```

The CLI checks the signer is the current owner and triple-confirms.
Alternative, same signer: edit `owner` / `pauser` in `deployment.json` and
`ntt push --only-chain $C` — push knows `setOwner` / `setPauser`
(cli/src/config-mgmt.ts).

## EVM legs — after handover

<https://github.com/wormhole-foundation/demo-ntt-evm-multisig-tools> —
generates **Safe Transaction Builder JSONs** (no private keys; signers
approve in the Safe UI) via the Wormhole ts-sdk: register EVM/SVM peers,
set rate limits, pause/unpause, further ownership transfers. Configure per
token + chain from `deployment.json`: `network`, `rpcUrl`, `wormholeChain`,
`evmChainId`, `safeAddress`, `nttManager`, `wormholeTransceiver`.

## Solana legs (sol, jitosol, prime)

`ntt transfer-ownership` is EVM-only. Use
<https://github.com/wormhole-foundation/demo-ntt-solana-multisig-tools>:

1. Configure it: manager program id (`.chains.Solana.manager`), the Squads
   multisig + vault PDA, `keys.json` = the payer key
   (`ops/tokens/<t>/keys/payer.json` — currently config owner AND program
   upgrade authority).
2. `npm run transfer-ownership-mainnet` — the payer signs
   `transfer_ownership` (pending owner = vault; the program upgrade
   authority is parked in the `upgrade_lock` PDA), then the wrapped
   `claim_ownership` is approved + executed in the **Squads UI**: the vault
   becomes config owner AND upgrade authority in one flow
   (solana/…/instructions/admin/transfer_ownership.rs).

Do **NOT** `solana program set-upgrade-authority` to the vault beforehand —
`transfer_ownership` moves the authority into the lock itself and fails if
it is already gone.

Post-handover ops (limits, pause) as Squads proposals: the repo's
`manageLimits.ts`.

## Sync deployment.json afterwards (audit record)

The transfers above happen outside this repo, so the committed `owner` /
`pauser` / `paused` fields go stale. Resync from chain — read-only, no keys
— and commit:

```sh
cd <repo root>                                # overrides.json pins the RPCs
ntt pull -p ops/tokens/<t>/deployment.json
git add ops/tokens/<t>/deployment.json && git commit
```

`ntt status -p …` shows the same drift without writing. Verify while you're
at it: owner + pauser on manager and transceiver = the multisigs (EVM);
`solana program show <program>` authority = vault and config owner = vault
(Solana).

[demo-ntt-evm-multisig-tools]: https://github.com/wormhole-foundation/demo-ntt-evm-multisig-tools
[demo-ntt-solana-multisig-tools]: https://github.com/wormhole-foundation/demo-ntt-solana-multisig-tools
