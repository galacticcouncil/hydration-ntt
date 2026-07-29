# Hydration NTT project context

Background and session knowledge for the Hydration ↔ Wormhole NTT effort. The step-by-step runbook lives in `DEPLOYMENT.md`; this file is everything around it — decisions, verified facts, CLI internals, gotchas, and open risks — so a fresh assistant can pick up without re-deriving.

## Mission

Bring tokens native to other chains (ETH, DAI on Ethereum; SOL, jitoSOL on Solana; possibly SUI) onto **Hydration** (Polkadot parachain with an EVM, galacticcouncil) via **Wormhole NTT (Native Token Transfers)**. Hydration recently got a first-class Wormhole integration. Operator: Pavol (palo@intergalactic.limited), works in the `galacticcouncil/whm` monorepo (cross-chain messaging: Wormhole contracts, migrations, off-chain agents).

## Topology decision (important — was corrected once)

- **Per token, hub-and-spoke:** the token's **home chain is the hub in `locking` mode** (we don't own ETH/DAI/SOL/jitoSOL, so mint authority there is impossible; locking works with any existing token, zero token permissions needed). **Hydration is the spoke in `burning` mode** with a fresh ERC-20 representation we deploy and control (`INttToken`: `mint`/`burn`/`setMinter`, minter = NTT manager).
- **NTT is per-token**: each asset is an independent 2-chain deployment with its own `deployment.json` + manager pair. There is NO single multi-chain mesh.
- An earlier draft had this inverted (Hydration as locking hub). That was wrong — do not resurrect it.

## Verified facts (checked this session, July 2026)

### Hydration ↔ Wormhole

- Hydration is registered in `wormhole-sdk-ts` (main branch): **Wormhole chain ID 73**, platform Evm. **Mainnet entry only** — no Testnet entry, so no CLI-driven testnet rehearsal for Hydration legs.
- Core bridge (mainnet): `0x3792a6d63c31941B2805181771795D9176fA82A1`. Verified live: a bare `publishMessage` smoke test exists in the whm repo (`contracts/scripts/wormhole-core/publish.ts`, viem-based) and guardians observe the messages. Default consistencyLevel used there: 200 (finalized... 200 = instant in Wormhole terms; the script defaults `--finality 200`).
- Hydration EVM: RPC `https://hydration-rpc.n.dwellir.com`, EVM chain ID `222222`.
- Moonbeam is the only other Polkadot parachain in the registry (chain ID 16).

### NTT CLI (user's install, inspected locally)

- Installed via bun: symlink `~/.bun/bin/ntt` → source checkout at `~/.ntt-cli/.checkout` (runs TS directly under bun).
- **Tagged releases are too old for Hydration**: checkout was `cli v1.7.0` (commit f7f65d37, 2026-05-22, "precompile token deployment + Tempo gas limit"), pinning `@wormhole-foundation/sdk-* ^4.20.0` via `overrides` — sdk-base 4.20.0 has **no** Hydration. Published sdk-base versions checked (4.21/4.24/5.2/6.1.4 via jsdelivr) didn't show it either in cjs paths (newer versions are ESM-only, `dist/esm/...`); Hydration exists on sdk-ts **main**.
- **Fix (applied by user): update CLI to the `main` branch** (`ntt update` with the main/branch flag). After that `ntt add-chain Hydration` appears in choices. Consequence: prod deploys run from a moving branch — pin the checkout commit and don't `ntt update` mid-deployment.
- `ntt new <path>` is literally `git clone -b main …/native-token-transfers.git <path>` (cli/src/commands/new.ts) and **refuses to run inside an existing git repo**.
- Deploy commands (`add-chain`, `upgrade`) call `ensureNttRoot(pwd)` → require `evm/foundry.toml` + `solana/Anchor.toml` in cwd; they compile from the clone's `evm/`/`solana/`/`sui/` trees. Config commands (`status`, `pull`, `push`, `set-mint-authority`, `transfer-ownership`) do NOT need the source tree — only the deployment file. Every command takes `-p <path>` to the deployment file. → Clone is throwaway; `deployment.json` is the durable audit artifact.
- Supported platforms in CLI: Evm, Solana, Sui (`SUPPORTED_PLATFORMS` in cli/src/validation.ts).
- `add-chain` flags of note: `--latest | --ver | --local`, `--mode locking|burning`, `--skip-verify`, `--manager-variant standard|noRateLimiting|wethUnwrap` (EVM only), `--sui-treasury-cap` (Sui **burning** only), `--payer` + `--program-key` (SVM), `--gas-estimate-multiplier`, `--unsafe-custom-finality`.

### Key roles (from docs + CLI behavior)

Per chain, one key is simultaneously: deployer (gas for add-chain), initial owner (manager + transceiver), and config signer (`ntt push` sends owner-only txs). `ETH_PRIVATE_KEY` covers BOTH EVM chains (Hydration + Ethereum) in a single push run, so keep one EVM key throughout and transfer ownership at the very end. `ETHERSCAN_API_KEY` = verification only. `SUI_PRIVATE_KEY` from `sui keytool export`. Solana uses `--payer` keypair path, plus one fresh `--program-key` program-id keypair **per deployment**.

## Hydration-specific gotchas (from prior work in whm repo)

- **EVM deploy whitelist**: contract deployment on Hydration EVM is permissioned. The mainnet deployer key must be whitelisted (governance-gated — arrange early). Dev key `0x222222ff…` is funded+whitelisted on **Lark testnet only**. Non-whitelisted deploys revert with an unhelpful error.
- **No Etherscan** on Hydration → deploy with `--skip-verify`, then verify on Subscan. A working simple JSON-body verify flow exists: whm repo `sh/verify-hydration.sh`. Gotchas: `sourceCode` truncates at ~64KB (strip comments first — NTT manager sources are large), no `constructorArguements` field.
- **anvil forks of Hydration lack the precompiles** — don't rely on an anvil fork to rehearse Hydration behavior; chopsticks-based forking has its own quirks (EVM calls must go via pallet_ethereum eth-tx path).
- **Runtime asset registration (unverified assumption, flag to Hydration runtime team)**: an ERC-20 deployed on Hydration EVM is not automatically a Substrate runtime asset; to be usable in Omnipool/pools it presumably needs asset-registry registration (governance). Start in parallel; verify the exact mechanism.

## NTT protocol facts relevant to design

- Amounts are **trimmed to `min(8, tokenDecimals)`** across chains (rate limits in `deployment.json` are expressed in the token's decimals on that chain — not the chain's native-currency decimals).
- Locking mode never needs mint authority / TreasuryCap on the hub — supply stays custodied there; representations are fully backed by hub custody.
- Native gas tokens aren't lockable directly: ETH → lock **WETH** (decide `wethUnwrap` manager variant BEFORE deploying — it's baked into the manager and lets users move native ETH), SOL → lock **wSOL** (`So11111111111111111111111111111111111111112`).
- Sui coins must originate via legacy `coin::create_currency` (`CoinMetadata`); relevant only if a Sui-side token were ever burning-mode (not our case — Sui would lock).
- `ntt push` cross-registers peers + applies limits + threshold in one run; `ntt status`/`ntt pull` reconcile local vs on-chain.

## Open risks / undecided

1. **Relayer/executor coverage for chain 73 is UNVERIFIED.** SDK registration ≠ automatic delivery. If Wormhole's standard executor doesn't serve Hydration, transfers into (and possibly out of) Hydration need manual redemption or a custom relayer. The whm repo's `mrelayer` agent (built on `@wormhole-foundation/relayer-engine`) already implements poll-Wormholescan→submit-VAA and can be adapted. Test with one real transfer first.
2. Final token list (ETH, DAI, SOL, jitoSOL confirmed intent; SUI undecided).
3. `wethUnwrap` vs plain WETH for the ETH deployment.
4. Final custodian/owner for managers, pausers, and the Hydration representation tokens.
5. Whether the mainnet deployer key is already whitelisted on Hydration EVM.

## Related infra in `galacticcouncil/whm` (the operator's main repo)

- `contracts/scripts/wormhole-core/publish.ts` — Hydration core-bridge smoke test (publishMessage + LogMessagePublished decode).
- `sh/verify-hydration.sh` — Subscan source verification.
- `agents/mrelayer` — Wormhole VAA relayer (candidate for Hydration redemption legs).
- Existing Wormhole products there: oracle relay (Solana/Ethereum → Moonbeam → Hydration via XCM), Basejump bridging, NEAR-Intents (WTT payload-3 via TokenBridge). The NTT effort is separate and lives in its own new repo; whm conventions (write-once deployment records, ownership transfer as final step) carry over in spirit.

## Update (2026-07-28) — repo structure & deploy phasing

- This repo is itself an NTT source tree (fork with the Hydration mainnet commit). Deploys run **from the repo root** — the earlier "throwaway clone" plan is superseded; `NTT_COMMIT` = repo HEAD at deploy time. `NTT_SRC` env overrides.
- Everything generated lives in `ops/` (runbook, scripts, `tokens/*/deployment.json`); root stays pure NTT source.
- Deploy scripts are split **per leg** under `ops/scripts/<chain>/<token>.sh`: all hub legs (ethereum/solana/sui) deploy first, Hydration spoke legs in a second phase.
- Wormhole **Executor is registered for Hydration (chain 73)** — relaying open risk (#1 above) largely resolved; still confirm both directions in the smoke test.
- **Two EVM keys, not one** (supersedes "Key roles" above): Ethereum uses `ETHEREUM_PRIVATE_KEY`, Hydration uses `HYDRATION_PRIVATE_KEY` (the whitelisted deployer). The CLI still only reads `ETH_PRIVATE_KEY`, so scripts map the right var per leg and `ntt push` runs per chain via `--only-chain` — the cross-link (peer registration) is completed by the two scoped pushes together.

## Provenance legend

- "Verified" = inspected locally (CLI source at `~/.ntt-cli/.checkout`, whm repo files) or fetched from wormhole-sdk-ts main / Wormhole docs this session.
- Hydration whitelist / Subscan / precompile gotchas = from prior hands-on work in the whm repo (reliable).
- Runtime asset registration + executor coverage = **assumptions to verify**, called out above.

