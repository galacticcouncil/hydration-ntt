#!/usr/bin/env bash
# WETH — hub leg: Ethereum, locking mode, UNWRAP VARIANT. Native ETH is
# not lockable, so the manager locks WETH; the wethUnwrap variant (baked at
# deploy, immutable) unwraps on delivery: Hydration→Ethereum recipients get
# NATIVE ETH. Deposits Ethereum→Hydration are still in WETH (wrap + approve —
# frontends prepend the wrap tx; the manager never wraps).
# Signs with ETHEREUM_PRIVATE_KEY only.
#
#   scripts/ethereum/weth.sh preflight   # no txs: keys, balances, gas price, CLI sanity
#   scripts/ethereum/weth.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/ethereum/weth.sh deploy      # TX Ethereum: manager+transceiver (locking WETH,
#                                      #   --manager-variant wethUnwrap), verifies on
#                                      #   Etherscan inline (ETHEREUM_SCAN_API_KEY)
#   scripts/ethereum/weth.sh push        # TX Ethereum: register Hydration peer + limits (after spoke leg)
#
#   scripts/ethereum/weth.sh status      # local vs on-chain drift
#
# Post-hoc verify note: the manager impl contract is
#   src/NttManager/NttManagerWethUnwrap.sol:NttManagerWethUnwrap  (not NttManager)

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/weth/deployment.json"
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2   # canonical WETH, 18 decimals

cmd_preflight() {
  use_key ETHEREUM_PRIVATE_KEY
  need_tools ntt cast jq git
  check_cli
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Ethereum balance: $(cast balance --ether "$addr" --rpc-url "$ETH_RPC") ETH"
  local gp; gp=$(cast gas-price --rpc-url "$ETH_RPC")
  echo "Gas price: $(cast from-wei "$gp" gwei) gwei — deploy is ~10-15M gas," \
       "est. $(cast from-wei $((gp * 15000000))) ETH"
  [ "$(cast code $WETH --rpc-url "$ETH_RPC")" != "0x" ] \
    || { echo "ERROR: no code at WETH address on Ethereum"; exit 1; }
  echo "WETH @ $WETH: OK ($(cast call $WETH 'symbol()(string)' --rpc-url "$ETH_RPC"))"
}

cmd_deploy() {
  use_key ETHEREUM_PRIVATE_KEY
  need_env ETHEREUM_SCAN_API_KEY   # deploy-time Etherscan verification
  confirm "Deploy NTT manager+transceiver to ETHEREUM mainnet (wethUnwrap variant, ~10-15M gas)?"
  (cd "$NTT_SRC" && ntt add-chain Ethereum --latest --mode locking \
    --token $WETH --manager-variant wethUnwrap -p "$DEPLOYMENT")
}

# Ethereum-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Ethereum and applies Ethereum limits. The
# Hydration-side half runs from scripts/hydration/weth.sh push with its own key.
cmd_push() {
  use_key ETHEREUM_PRIVATE_KEY
  cmd_status || true
  confirm "Push Ethereum-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Ethereum -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
