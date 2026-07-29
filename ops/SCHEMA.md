# Hydration NTT — architecture schemas

Companion diagrams to `DEPLOYMENT.md`. Everything here is per the DAI deployment; ETH/SOL/jitoSOL are copies of the same shapes.

## 1. Topology — one deployment per token, hub-and-spoke

`--mode` is per chain; the *combination* makes the topology. One `deployment.json` per token describes both legs; the managers are two halves of one bridge.

```
            DAI deployment (tokens/dai/deployment.json)
┌─────────────────────────────┐      ┌──────────────────────────────┐
│ ETHEREUM — hub, `locking`   │      │ HYDRATION — spoke, `burning` │
│                             │      │                              │
│  DAI (MakerDAO's, existing) │      │  DAI representation          │
│       ▲ lock / release      │      │       ▲ mint / burn          │
│  NttManager ◄───── peers ─────────►  NttManager                   │
│  WormholeTransceiver ◄─── peers ──►  WormholeTransceiver          │
└─────────────────────────────┘      └──────────────────────────────┘

invariant: representation circulating on Hydration
         == DAI locked in the Ethereum manager's custody
```

- Hub `locking`: needs zero token permissions — works with any existing token.
- Spoke `burning`: must mint/burn — a locking spoke could only release what it
  previously locked (nothing, on first inbound), so spokes are always burning.
- "Mint-and-burn" (all chains burning) needs mint authority everywhere incl.
  the home chain — impossible for tokens we don't issue.

## 2. Transfer flow

```
Ethereum → Hydration                      Hydration → Ethereum
--------------------                      --------------------
user approves + transfers                 user transfers to manager
        │                                         │
manager LOCKS DAI in custody              manager BURNS representation
        │                                         │
transceiver publishes via core bridge     transceiver publishes via core bridge
        │                                         │
guardians sign VAA                        guardians sign VAA
        │                                         │
executor delivers to Hydration            executor delivers to Ethereum
        │                                         │
transceiver verifies (emitter == peer)    transceiver verifies (emitter == peer)
manager checks sender peer + rate limit   manager checks sender peer + rate limit
        │                                         │
manager MINTS representation to user      manager RELEASES DAI from custody
```

- Executor is registered for Hydration (chain 73) — auto-delivery expected
  both directions; verify in smoke test.
- Amounts are trimmed to 8 decimals across chains; sub-1e-8 dust truncated.

### 2a. User entry point — the manager IS the user-facing contract

Two calls on the source chain, nothing in front of them (UIs/SDK just wrap
these):

```
1.  token.approve(manager, amount)         // on Hydration: approve on 0x…0001<id>
2.  manager.transfer{value: deliveryFee}(
        amount,
        recipientChain,                    // Wormhole chain id: 2 = Ethereum, 73 = Hydration
        recipient                          // bytes32 universal address
    )
```

How the manager knows how to dispatch — all from its own config, keyed by
`recipientChain`:

```
what to move   → immutable `token`         (transferFrom user, then lock or burn)
where to send  → peers[recipientChain]     (set at push; unregistered chain = revert)
how to send    → registered transceiver(s) (publish via core bridge; msg.value = fee)
how fast       → outbound rate limit       (over cap: revert, or queue w/ shouldQueue)
```

The NTT message carries amount + recipient only — never "which token": the
token is implied by which manager pair carried the message.

## 3. Contracts per EVM leg — proxy pattern

Each `add-chain` deploys four contracts. Only the two proxies matter;
implementations hold code, never state (owner()/pauser() read as 0x0 there).

```
 NttManager proxy  ◄── THE manager address (deployment.json "manager")
   │  state: owner, pauser, token ref, peers, limits, threshold
   └─ delegatecall ─► NttManager implementation      (stateless code)

 WormholeTransceiver proxy  ◄── transceivers.wormhole.address
   │  state: peers, pauser; == the VAA EMITTER guardians attest for
   └─ delegatecall ─► Transceiver implementation     (stateless code)
```

- Etherscan: use "Read as Proxy" on the proxy address.
- `--latest` compiles from the newest version tag (e.g. `v2.0.0+evm`) via a
  git worktree under `.deployments/` — not from repo HEAD.

## 4. Peering — symmetric, two layers, two signers

Each side only accepts messages from peers it registered itself. Cross-link
happens at `push`, per chain, under that chain's owner key:

```
 ntt push --only-chain Ethereum          ntt push --only-chain Hydration
 (ETHEREUM_PRIVATE_KEY)                  (HYDRATION_PRIVATE_KEY)
 ┌──────────────────────────┐            ┌──────────────────────────┐
 │ manager.setPeer(73, ...) │            │ manager.setPeer(2, ...)  │
 │ transceiver peer  (73)   │            │ transceiver peer  (2)    │
 └──────────────────────────┘            └──────────────────────────┘
```

- One peer slot per chain per manager — registering another overwrites it.
- Until BOTH pushes ran, deliveries are rejected (bridge stays inert — safe).
- `add-chain` (deploy) sets no peers at all; deployed legs sit isolated.

## 5. Hydration representation — two variants

### 5a. Currencies precompile (preferred; hydration-node PR #1488)

The representation IS a runtime asset (asset registry, governance), exposed
as ERC-20 at an address that just encodes the asset id. N ERC-20 addresses,
ONE precompile implementation, N managers — strict 1:1 through the middle:

```
N ERC-20 addresses          1 MultiCurrency precompile         N NTT managers
(asset-id encoded,          (single runtime implementation     (one per token,
 no code deployed)           + NttMinters: id → manager map)    real EVM contracts)

0x…0001<idA>  ─┐                                            ┌─ DAI manager
0x…0001<idB>  ─┼──────────►  decode id from address  ◄──────┼─ ETH manager
0x…0001<idC>  ─┤             check NttMinters[id]           ├─ SOL manager
0x…0001<idD>  ─┘                                            └─ jitoSOL manager
```

- Address = `0x00000000000000000000000000000001` + u32 asset id (big-endian),
  e.g. asset 2 → `0x…0100000002`.
- Balances live in the Substrate ledger → native in Omnipool/XCM/wallets AND
  visible as ERC-20. One asset, two views.
- Minter binding: `currencies.set_ntt_minter(asset_id, manager)` extrinsic,
  ControllerOrigin (governance). Emergency unbind: `clear_ntt_minter`
  (faster origin). NOT a token call — no key of ours can do it.
- Runtime circuit breakers on top of NTT limits: daily mint budget
  (issuance fuse via registry `xcm_rate_limit`), burns count toward
  withdrawal limits, External assets need a price route to HDX.

### 5b. PeerToken (classic ERC-20 fallback)

```
 PeerToken contract (we deploy, we own)
   minter: NTT manager   ← setMinter(), signed by our deployer key
   balances: contract's own EVM storage → INVISIBLE to Omnipool/runtime
```

Same INttToken surface from the manager's view; second-class asset on chain.

### 5c. Mint call path — same shape, different machinery

Mint is always manager→token; the token side only ever CHECKS the caller
(allowlist on the way in — nothing "dispatches to" the minter).

```
PeerToken variant                        Precompile variant
-----------------                        ------------------
NttManager                               NttManager
  │ CALL PeerToken                         │ CALL 0x…0001<id>
  │ mint(recipient, amount)                │ mint(recipient, amount)   ← same calldata
  ▼                                        ▼
contract bytecode at the address         NO code at the address:
  │                                      EVM executor matches the asset
  │                                      address pattern → routes to the
  │                                      MultiCurrency precompile (Rust),
  │                                      which decodes the asset id from
  │                                      the CALLED ADDRESS + the selector
  ▼                                      ▼ from calldata
require(msg.sender == minter)            check NttMinters[id] == caller
  │                                        │ + issuance fuse (mint budget)
  ▼                                        ▼
_mint → contract's EVM storage           credit recipient in Substrate ledger
                                         (native runtime balance)
```

Same trick as Ethereum's built-in precompiles (`ecrecover` at 0x…01: callable,
zero bytecode). `cast call 0x…0001<id> 'symbol()(string)'` works while
`cast code` returns empty — calldata in / returndata out is all a caller sees.

### Missing minter binding ≠ lost funds

If a transfer is delivered before `set_ntt_minter` (or after `clear_ntt_minter`):

```
Ethereum:  DAI locked in custody          ← already happened at send time
Guardians: VAA signed, valid              ← attestations never expire
Hydration: mint() reverts CallerNotMinter → WHOLE delivery tx reverts
           → nothing minted, nothing stranded at the token address
```

The transfer is stuck in-flight, replayable: once the binding is enacted,
redeliver the same VAA (executor retry or manual submit) and it completes.
Still: bind first, then open the gates — "every delivery reverts until the
referendum passes" is a support nightmare, not a safety feature.

### Bindings are 1:1 everywhere (why funny setups are inert)

```
manager ──► token address     fixed at deploy, never fans out
token   ──► minter            single slot (NttMinters[id] / PeerToken.minter)
manager ──► peer per chain    single slot, re-set overwrites
```

Granting an extra token's mint right to a manager is a no-op (it never calls
other tokens) — just dangling authorization to clean up.

## 6. Keys & ownership lifecycle

```
 phase        Ethereum leg                    Hydration leg
 ─────        ────────────                    ─────────────
 deploy       ETHEREUM_PRIVATE_KEY            HYDRATION_PRIVATE_KEY
              (deployer = owner = pauser)     (whitelisted; deployer = owner)
 push         same key, --only-chain          same key, --only-chain
 governance   —                               set_ntt_minter(asset, manager)
 handover     ntt transfer-ownership          ntt transfer-ownership
              → multisig (final step;         → custodian able to execute
                sweeps transceivers too)        on chain 222222 (verify first!)
```

- The CLI reads ONE `ETH_PRIVATE_KEY` for all EVM chains; scripts map the
  right variable per leg.
- After handover, `ntt push` is dead for owner-only ops — changes go through
  the multisig calling the manager directly; `ntt status` stays useful.
- Solana legs: `transfer-ownership` is EVM-only — move program upgrade
  authority manually (e.g. Squads).
