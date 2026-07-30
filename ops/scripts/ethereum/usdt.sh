#!/usr/bin/env bash
# USDT — hub leg: Ethereum, locking mode. Hub legs (ethereum/solana/sui) deploy
# first; the Hydration spoke leg comes later via scripts/hydration/usdt.sh.
# Signs with ETHEREUM_PRIVATE_KEY only.
#
# USDT quirks: non-standard ERC-20 (transfer/approve return no bool — fine,
# the manager uses SafeERC20) and a dormant fee-on-transfer switch
# (basisPointsRate). A nonzero fee would break lock/unlock accounting, so
# preflight hard-fails if Tether ever turns it on.
#
#   scripts/ethereum/usdt.sh preflight   # no txs: keys, balances, gas price, CLI sanity, fee switch
#   scripts/ethereum/usdt.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/ethereum/usdt.sh deploy      # TX Ethereum: manager+transceiver (locking USDT),
#                                       #   verifies on Etherscan inline (ETHEREUM_SCAN_API_KEY);
#                                       #   scripts/ethereum/_verify.sh = post-hoc fallback
#   scripts/ethereum/usdt.sh push        # TX Ethereum: register Hydration peer + limits (after spoke leg)
#
#   scripts/ethereum/usdt.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/usdt/deployment.json"
USDT=0xdAC17F958D2ee523a2206206994597C13D831ec7   # canonical Tether USDT, 6 decimals

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
  [ "$(cast code $USDT --rpc-url "$ETH_RPC")" != "0x" ] \
    || { echo "ERROR: no code at USDT address on Ethereum"; exit 1; }
  echo "USDT @ $USDT: OK ($(cast call $USDT 'symbol()(string)' --rpc-url "$ETH_RPC"))"
  local fee; fee=$(cast call $USDT 'basisPointsRate()(uint256)' --rpc-url "$ETH_RPC")
  [ "$fee" = "0" ] \
    || { echo "ERROR: USDT fee-on-transfer is LIVE (basisPointsRate=$fee) — breaks locking accounting"; exit 1; }
  echo "USDT fee switch: off (basisPointsRate=0)"
}

cmd_deploy() {
  use_key ETHEREUM_PRIVATE_KEY
  need_env ETHEREUM_SCAN_API_KEY   # deploy-time Etherscan verification
  confirm "Deploy NTT manager+transceiver to ETHEREUM mainnet (~10-15M gas)?"
  (cd "$NTT_SRC" && ntt add-chain Ethereum --latest --mode locking \
    --token $USDT -p "$DEPLOYMENT")
}

# Ethereum-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Ethereum and applies Ethereum limits. The
# Hydration-side half runs from scripts/hydration/usdt.sh push with its own key.
cmd_push() {
  use_key ETHEREUM_PRIVATE_KEY
  cmd_status || true
  confirm "Push Ethereum-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Ethereum -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,19p' "$0"; exit 1 ;;
esac
