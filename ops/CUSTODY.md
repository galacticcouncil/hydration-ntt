# Adding backing to a locking leg

Custody is per-token and lives on the locking hub only (see `ops/DEPLOYMENT.md`: "locking hubs
never mint"). Normally it accrues at first user transfer and needs no intervention. This doc
covers the deliberate top-up — reconciling a shared-asset-id gap, or seeding a leg.

**Never use `manager.transfer()` for this.** It locks the tokens *and* emits a mint message, so
it adds custody plus an equal amount of fresh representation on Hydration. It cannot close a
gap.

The right mechanism is a plain token transfer. The target differs per chain, and Sui will eat
the funds.

## EVM — transfer to the manager address

Ethereum `dai` / `wbtc` / `weth` / `usdc` / `usdt` / `susds`, Base `eurc`.

A plain ERC-20 transfer to the `manager` address in the token's `deployment.json` is
sufficient. Custody is literally the manager's own balance:

- lock: `safeTransferFrom(msg.sender, address(this), amount)` — `evm/src/NttManager/NttManager.sol:409`
- unlock: `safeTransfer(recipient, untrimmedAmount)` — `evm/src/NttManager/NttManager.sol:650`

There is **no `totalLocked` counter**, so there is no internal accounting to desync — a
donation just raises the pool releases draw from. The `balanceBefore`/`balanceAfter` reads at
`NttManager.sol:406-415` are within-call fee-on-transfer detection and are unaffected.

## Solana — transfer to the custody token account, not the program

`sol` / `jitosol` / `prime`.

Custody is the associated token account of the `token_authority` PDA for the mint
(`solana/programs/example-native-token-transfers/src/instructions/initialize.rs:80-90`),
enforced on release by `address = config.custody`
(`solana/programs/example-native-token-transfers/src/instructions/release_inbound.rs:50`).
Release transfers out of that account, balance-based, so a plain SPL transfer to it works.

Sending to the program id instead does nothing useful. **The custody address is not recorded in
any `deployment.json`** — resolve it from `config.custody` before sending, and consider adding
it to the deployment records, since it is the custody of three legs.

## Sui — do not send funds to the manager object

`sui`. Manager `0xa0bc45e0384140dc125f273eda89cad1434f5dee430726cf6364bdcceba1e9a3`.

**A transfer to the manager object is unrecoverable.** Custody is a `Balance<T>` field *inside*
the `State` object (`sui/packages/ntt/sources/state.move:35`), reachable only through
`borrow_balance_mut`, which is `public(package)` (`state.move:111`) with exactly two call
sites: `coin::put` in `transfer_impl` (`sui/packages/ntt/sources/ntt.move:143`) and
`coin::take` in `release` (`ntt.move:306`). There is **no donation entry point**.

That value is an object ID, not a creditable account. A `public_transfer` to it yields a coin
owned by an address nobody holds a key for — stranded permanently.

Adding Sui custody requires either a real bridge send through `transfer_impl` (which mints on
Hydration, so it does not close a gap) or a package upgrade adding a deposit function.

## After topping up

On EVM and Solana these transfers are permissionless and unattributable — nothing on-chain
records who added backing or why. Log the tx hash, leg, amount and reason out of band, or the
next reconciliation reads it as an unexplained surplus.
