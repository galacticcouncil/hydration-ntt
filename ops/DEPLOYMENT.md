# Hydration NTT — Step-by-Step Deployment Runbook

Bringing dest-chain-native tokens (ETH, DAI, SOL, jitoSOL, …) to Hydration via Wormhole NTT.

## Topology — hub-and-spoke, per token

We do **not** own these tokens on their home chains (no mint authority possible there), so each token's **home chain is its hub in `locking` mode** — locking works with any existing token, no mint authority needed. **Hydration is the spoke in `burning` mode**, minting/burning a token on Hydration — ERC-20 or runtime-asset precompile ref (Step 3).

**NTT is per-token: each token is its own independent 2-chain deployment** with its own `deployment.json` and its own manager pair. There is no single 4-chain mesh.

| Deployment | Hub (locking) | Token on hub | Spoke (burning) | Token on spoke |
| --- | --- | --- | --- | --- |
| ETH | Ethereum | WETH (see variant note) | Hydration | token address (ERC-20 or precompile) |
| DAI | Ethereum | DAI (existing) | Hydration | token address (ERC-20 or precompile) |
| SOL | Solana | wSOL `So1111…1112` | Hydration | token address (ERC-20 or precompile) |
| jitoSOL | Solana | jitoSOL mint (existing) | Hydration | token address (ERC-20 or precompile) |
| SUI (if wanted) | Sui | native SUI coin type | Hydration | token address (ERC-20 or precompile) |

- **ETH variant note:** ETH is not an ERC-20. Lock WETH — and consider `--manager-variant wethUnwrap` on the Ethereum side so users move native ETH without manual wrapping. Decide before deploy.
- **SOL:** lock wrapped SOL (wSOL SPL mint). Users wrap/unwrap on Solana side.
- Locking mode never needs mint authority or `TreasuryCap` on the hub — that's the point.
- Total supply of each representation is fully backed by the hub custody balance.
- **`--mode` is per-chain, the topology is the combination**: hub-and-spoke = exactly one `locking` chain (hub) + `burning` spokes — the spoke *must* burn/mint, since a locking manager can only release what it previously locked (nothing, on first inbound). "Mint-and-burn" would mean *all* chains `burning`, which requires mint authority everywhere incl. the home chain — not possible for tokens we don't issue.

## Facts

- Hydration Wormhole chain ID: **73** (Mainnet-only SDK entry — no testnet rehearsal path for the Hydration leg)
- Hydration core bridge (mainnet): `0x3792a6d63c31941B2805181771795D9176fA82A1` (guardian-observed, smoke-tested)
- Hydration EVM: RPC `https://hydration-rpc.n.dwellir.com`, EVM chain ID `222222`
- NTT trims amounts to **8 decimals** across chains (18-dec DAI/WETH and 9-dec SPL mints are fine; sub-1e-8 dust is truncated)

## Repo layout (this repo)

The repo root is the NTT source tree (fork with Hydration support) — deploys compile from its `evm/` / `solana/` / `sui/` trees. Everything we generate lives under `ops/`; the durable artifact per token is its `deployment.json`.

```
ops/
  README.md          # project context / background
  DEPLOYMENT.md      # this runbook
  SCHEMA.md          # architecture diagrams
  NTT_COMMIT         # repo HEAD used for deploys (written by init)
  scripts/
    _lib.sh          # shared config + helpers
    ethereum/        # hub legs (locking) — deploy FIRST: dai.sh, _verify.sh (Etherscan)
    solana/          #   sol.sh, jitosol.sh
    sui/             #   (if wanted)
    hydration/       # spoke legs (burning) — AFTER all hub legs: dai.sh, _verify.sh (Subscan)
  tokens/
    eth/deployment.json
    dai/deployment.json
    sol/deployment.json
    jitosol/deployment.json
```

All CLI commands accept `-p <path>` to target a specific deployment file.

## Step 0 — CLI on `main` branch (required)

Tagged CLI releases pin SDK `^4.20.0`, which **predates Hydration**. The CLI must track `main`:

```sh
ntt update --branch main        # checkout lives at ~/.ntt-cli/.checkout
ntt add-chain Hydration --help  # Hydration must appear in the chain choices
```

Do **not** `ntt update` mid-deployment.

## Step 1 — Keys

The key per chain is simultaneously **deployer** (pays `add-chain` gas), **initial owner** (of manager + transceiver), and **config signer** (`ntt push` signs owner-only calls with it). Keep keys available and funded until final ownership transfer.

| Env var / flag | Chains | Requirements |
| --- | --- | --- |
| `ETHEREUM_PRIVATE_KEY` | Ethereum | Ethereum deployer/owner; gas on Ethereum |
| `HYDRATION_PRIVATE_KEY` | Hydration | Hydration deployer/owner; gas on Hydration; **whitelisted on Hydration's EVM deploy whitelist** (governance-gated — arrange early) |
| `SUI_PRIVATE_KEY` | Sui | Funded with SUI (locking mode — no `TreasuryCap` needed) |
| `--payer payer.json` | Solana | Funded keypair file; also `--program-key` (program-id keypair, one per deployment) |
| `ETHEREUM_SCAN_API_KEY` | Ethereum | Etherscan source verification only, not a signer (CLI resolves `<CHAIN>_SCAN_API_KEY` or `ntt config set-chain Ethereum scan_api_key …`; `ETHERSCAN_API_KEY` is **not** read). Hydration uses `--skip-verify` instead |

The CLI reads a **single** `ETH_PRIVATE_KEY` for all EVM chains, and Ethereum/Hydration use **different** keys — so `ntt push` must run **once per chain** with `--only-chain <chain>` under the right key. Peer registration is symmetric (each side's owner registers the other as peer on its own chain), so the two scoped pushes together complete the cross-link. The deploy scripts map the correct env var onto `ETH_PRIVATE_KEY` per leg automatically.

**Multisig:** the CLI only signs with raw private keys (no Safe, no Ledger). The multisig never signs during deploy/config — it becomes owner only via Step 7 `transfer-ownership`. After handover, owner-only changes (limits, peers, pause, upgrades) are executed as multisig transactions against the manager directly; `ntt push` no longer works, `ntt status` stays useful read-only.

```sh
export ETHEREUM_PRIVATE_KEY=0x…      # Ethereum legs
export HYDRATION_PRIVATE_KEY=0x…  # Hydration legs (whitelisted)
export ETHEREUM_SCAN_API_KEY=…
export SUI_PRIVATE_KEY=…
```

## Step 2 — Deploy source = this repo

Deploy commands (`add-chain`, `upgrade`) must run **from an NTT source root** — they compile contracts from its `evm/` / `solana/` / `sui/` trees. This repo **is** one, so deploys run from the repo root (no throwaway clone; override with `NTT_SRC` env to use a separate clone). Config commands (`status`, `push`, `pull`, `set-mint-authority`, `transfer-ownership`) only need the deployment file.

The scripts' `init` step does the bookkeeping:

- writes `git rev-parse HEAD` to `ops/NTT_COMMIT` (deploy with a clean tree — you deploy what's on disk, not the pinned commit)
- writes `overrides.json` at the repo root pinning Ethereum/Hydration RPCs (the CLI reads it from its cwd)
- runs `ntt init Mainnet -p ops/tokens/<token>/deployment.json` once per token

## Step 3 — Hydration representations = runtime assets via the currencies precompile

**No token contract is deployed on Hydration.** Per asset, governance registers a runtime asset in the asset registry → asset id `N`; its ERC-20 view exists automatically at the currencies precompile address `0x00000000000000000000000000000001` + `N` as 4 hex bytes (e.g. id 2 → `0x…0100000002`). hydration-node **PR #1488** added NTT `mint`/`burn` to that precompile, gated by the `currencies.NttMinters[N]` binding (Step 5). Balances are native runtime balances — first-class in Omnipool/XCM/wallets, no separate registration.

- Decimals come from the registry entry; the scripts' `limits` step reads them live from the precompile.
- Runtime circuit breakers apply on top of NTT's rate limits: mint budget per registry `xcm_rate_limit` (issuance fuse); burns count toward withdrawal limits; `AssetType::External` assets need a price route to HDX or burns revert.
- Scripts: `scripts/hydration/<token>.sh asset` derives the precompile ref from the asset id and sanity-checks it on-chain (`symbol()`/`decimals()`), then saves it for the manager deploy.
- The asset **must be registered before** the Hydration manager deploys — the token address is an immutable constructor arg of the manager.
- (A classic `INttToken` ERC-20 — Wormhole's `PeerToken` — is equally supported: deploy it and bind the manager with `setMinter()` instead of Step 5's extrinsic. EVM-only, not visible to Omnipool.)

## Step 4 — Deploy managers (all hub legs first, Hydration legs after)

Operational order: deploy **all hub legs first** (Ethereum / Solana / Sui), then the Hydration legs in a second phase. Scripts under `ops/scripts/` are split per leg accordingly (`scripts/ethereum/dai.sh` now, `scripts/hydration/dai.sh` later); each mainnet tx sits behind a confirmation gate. The raw commands they wrap:

```sh
# --- ETH deployment ---
ntt add-chain Ethereum  --latest --mode locking --token <WETH> \
  --manager-variant wethUnwrap -p …/tokens/eth/deployment.json      # variant optional; decide first
ntt add-chain Hydration --latest --mode burning --token <HYDRATION_ETH_TOKEN> \
  --skip-verify -p …/tokens/eth/deployment.json

# --- DAI deployment ---
ntt add-chain Ethereum  --latest --mode locking --token <DAI>  -p …/tokens/dai/deployment.json
ntt add-chain Hydration --latest --mode burning --token <HYDRATION_DAI_ERC20> \
  --skip-verify -p …/tokens/dai/deployment.json

# --- SOL deployment ---
ntt add-chain Solana    --latest --mode locking --token So11111111111111111111111111111111111111112 \
  --payer payer.json --program-key sol-ntt-program.json -p …/tokens/sol/deployment.json
ntt add-chain Hydration --latest --mode burning --token <HYDRATION_SOL_ERC20> \
  --skip-verify -p …/tokens/sol/deployment.json

# --- jitoSOL deployment ---
ntt add-chain Solana    --latest --mode locking --token <JITOSOL_MINT> \
  --payer payer.json --program-key jitosol-ntt-program.json -p …/tokens/jitosol/deployment.json
ntt add-chain Hydration --latest --mode burning --token <HYDRATION_JITOSOL_ERC20> \
  --skip-verify -p …/tokens/jitosol/deployment.json
```

Notes:

- Hub legs in `locking` mode need **no** token permissions — any existing ERC-20/SPL/coin works.
- Each Solana deployment needs its **own** program keypair (`--program-key`).
- **Ethereum legs verify on Etherscan during deploy** (needs `ETHEREUM_SCAN_API_KEY`; `scripts/ethereum/_verify.sh` is the post-hoc fallback if deploy-time verification hiccups). **Hydration legs deploy `--skip-verify`** — no Etherscan-compatible verifier; Subscan verification is post-hoc via `scripts/hydration/_verify.sh` (Step 7). Hydration note: non-whitelisted deployer reverts with an unhelpful error.

## Step 5 — Minter binding (Hydration side, governance)

The manager must be authorized to mint/burn its asset — a **governance extrinsic** (ControllerOrigin — Root/GeneralAdmin track), not a token call; no key of ours can sign it:

```
currencies.set_ntt_minter(asset_id: <N>, minter: <HYDRATION_NTT_MANAGER>)
```

- The scripts' `minter` step prints the exact call + coordination checklist per token; verify enactment via chain state: `currencies.nttMinters(N) == manager`.
- Until enacted, the Hydration side is inert in **both** directions (`mint` *and* `burn` are gated): deliveries revert (stuck-in-flight, replayable), sends can't start. This makes the binding the **go-live switch** — it's fine (and clean) to enact it *after* Step 6's limits + push.
- Emergency off-switch: `currencies.clear_ntt_minter(N)` (faster origin) — turns the Hydration side off without touching any NTT contract.
- Batch all tokens' bindings into one governance proposal if the managers are deployed by then.
- Nothing to do on Ethereum/Solana/Sui — locking hubs never mint.

## Step 6 — Rate limits + push (per token)

Edit each `deployment.json`: `outbound` and `inbound` limits on both chains, **in the token's decimals on that chain** (what its `decimals()` returns there — not the chain's native-currency decimals). The limit string's fraction length must equal exactly that.

```sh
ntt status -p …/tokens/dai/deployment.json   # local vs on-chain drift

# One push per chain, each under its own key (CLI only reads ETH_PRIVATE_KEY):
ETH_PRIVATE_KEY=$HYDRATION_PRIVATE_KEY ntt push --only-chain Hydration -p …/tokens/dai/deployment.json
ETH_PRIVATE_KEY=$ETHEREUM_PRIVATE_KEY     ntt push --only-chain Ethereum  -p …/tokens/dai/deployment.json
# (Solana legs: ntt push --only-chain Solana --payer payer.json)
```

Repeat per token; re-run `status` until in sync. The scripts' `push` steps do exactly this per leg.

## Step 7 — Post-deploy hardening

1. **Verify contracts.** Ethereum legs verify at deploy time (Step 4), so the scripts here are: `scripts/hydration/_verify.sh` (Subscan, needs `SUBSCAN_KEY`) — always needed, per contract; `scripts/ethereum/_verify.sh` (Etherscan, needs `ETHEREUM_SCAN_API_KEY`) — only if deploy-time verification failed. Four targets per leg — proxies from the token's `deployment.json`, implementations from the ERC1967 slot:

   ```sh
   MP=$(jq -r .chains.Ethereum.manager ops/tokens/dai/deployment.json)
   TP=$(jq -r .chains.Ethereum.transceivers.wormhole.address ops/tokens/dai/deployment.json)
   SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
   MI=$(cast parse-bytes32-address "$(cast storage $MP $SLOT --rpc-url <rpc>)")
   TI=$(cast parse-bytes32-address "$(cast storage $TP $SLOT --rpc-url <rpc>)")

   scripts/ethereum/_verify.sh $MI src/NttManager/NttManager.sol:NttManager
   scripts/ethereum/_verify.sh $TI src/Transceiver/WormholeTransceiver/WormholeTransceiver.sol:WormholeTransceiver
   scripts/ethereum/_verify.sh $MP lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
   scripts/ethereum/_verify.sh $TP lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
   # Hydration leg: same four targets with .chains.Hydration.* via scripts/hydration/_verify.sh
   ```

   Both scripts run forge from the version-tag worktree `.deployments/Evm-<ver>/evm` — the source that produced the deployed bytecode (`WORKTREE` env overrides; default is `Evm-2.0.0`). Etherscan wrapper guesses constructor args from the creation tx (needed for the proxies). Subscan gotchas: `sourceCode` truncates at ~64KB (strip comments if NttManager doesn't fit); no `constructorArguements` field.
2. **Transfer ownership** — every manager/transceiver (and each Hydration token's owner) is deployer-owned after push. Move owner + `pauser` to the real custodian as the **final** step, per deployment. Ownership is per contract, so this never touches other deployments — a token added later just repeats deploy → push → transfer for itself.
   - EVM legs: `ntt transfer-ownership <chain> --destination <custodian> -p …` once per chain per deployment. The manager call propagates to all registered transceivers in one tx. Irreversible; `ETH_PRIVATE_KEY` must be the current owner.
   - Solana legs: `ntt transfer-ownership` is **EVM-only**. Move the program **upgrade authority** (`solana program set-upgrade-authority`, e.g. to a Squads multisig) and the NTT config owner manually — otherwise they silently stay with the hot payer key.
   - Hydration tokens: nothing to transfer — the representations are runtime assets; their control (minter binding, registry entry) is already governance-held.
3. **Solana source verification (optional, post-hoc)** — the CLI deploys a locally-built anchor binary; there is no deploy-time verification on Solana. Explorer "verified" badges require a byte-for-byte reproducible build (`solana-verify` docker) matching the deployed binary — a local anchor build generally won't match. If the badge matters, build with `solana-verify build` and deploy that binary manually; else rely on `NTT_COMMIT` as the audit trail.
4. **Commit all `deployment.json` files + `NTT_COMMIT`** — the write-once audit record.

## Step 8 — Smoke test + relaying

Per token: tiny transfer hub → Hydration and back; watch VAAs on Wormholescan.

**Relaying:** the Wormhole Executor is registered for Hydration (chain 73), so transfers should auto-deliver in both directions. Confirm this end-to-end in the smoke test anyway; if a leg doesn't auto-complete, `whm`'s `mrelayer` agent (poll Wormholescan for VAA → submit to receiver) is the fallback.

## Open items

- [ ] Final token list (ETH, DAI, SOL, jitoSOL — SUI? others?)
- [ ] ETH: plain WETH locking vs `wethUnwrap` manager variant?
- [ ] Per token, governance: register runtime asset (→ asset id), `set_ntt_minter(id, manager)` after manager deploy, `xcm_rate_limit` (mint budget), HDX price route if External
- [ ] DAI asset id: reuse existing MRL asset vs fresh id? (both bridges stay alive for now — shared id means dual backing; see custody-imbalance note)
- [ ] Final owner/custodian for managers + pausers (pauser should be a FAST responder — it's what turns the 24h rate-limit hold into a stop)
- [ ] Multisig mechanism **on Hydration EVM** (Safe deployed on chain 222222? Substrate multisig → EVM mapping?) — verify the custodian address can execute a tx there **before** transferring ownership
- [ ] Mainnet deployer key whitelisted on Hydration EVM?
- [x] Executor registered for Hydration — verify auto-delivery both directions during smoke test

## References

- [NTT EVM deployment](https://wormhole.com/docs/products/token-transfers/native-token-transfers/guides/deploy-to-evm/)
- [NTT Solana deployment](https://wormhole.com/docs/products/token-transfers/native-token-transfers/guides/deploy-to-solana/)
- [NTT Sui deployment](https://wormhole.com/docs/products/token-transfers/native-token-transfers/guides/deploy-to-sui/)
- [NTT CLI commands](https://wormhole.com/docs/products/token-transfers/native-token-transfers/reference/cli-commands/)
- [Wormhole SDK chain registry (Hydration = 73)](https://github.com/wormhole-foundation/wormhole-sdk-ts/blob/main/core/base/src/constants/chains.ts)
- [NTT releases](https://github.com/wormhole-foundation/native-token-transfers/releases)
