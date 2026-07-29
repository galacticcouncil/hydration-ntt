#!/usr/bin/env bash
# DAI — hub leg: Ethereum, locking mode. Hub legs (ethereum/solana/sui) deploy
# first; the Hydration spoke leg comes later via scripts/hydration/dai.sh.
# Signs with ETHEREUM_PRIVATE_KEY only.
#
#   scripts/ethereum/dai.sh preflight   # no txs: keys, balances, gas price, CLI sanity
#   scripts/ethereum/dai.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/ethereum/dai.sh deploy      # TX Ethereum: manager+transceiver (locking DAI),
#                                      #   verifies on Etherscan inline (ETHEREUM_SCAN_API_KEY);
#                                      #   scripts/ethereum/_verify.sh = post-hoc fallback
#   scripts/ethereum/dai.sh push        # TX Ethereum: register Hydration peer + limits (after spoke leg)
#
#   scripts/ethereum/dai.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/dai/deployment.json"
DAI=0x6B175474E89094C44Da98b954EedeAC495271d0F

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
  [ "$(cast code $DAI --rpc-url "$ETH_RPC")" != "0x" ] \
    || { echo "ERROR: no code at DAI address on Ethereum"; exit 1; }
  echo "DAI @ $DAI: OK ($(cast call $DAI 'symbol()(string)' --rpc-url "$ETH_RPC"))"
}

cmd_deploy() {
  use_key ETHEREUM_PRIVATE_KEY
  need_env ETHEREUM_SCAN_API_KEY   # deploy-time Etherscan verification
  confirm "Deploy NTT manager+transceiver to ETHEREUM mainnet (~10-15M gas)?"
  (cd "$NTT_SRC" && ntt add-chain Ethereum --latest --mode locking \
    --token $DAI -p "$DEPLOYMENT")
}

# Ethereum-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Ethereum and applies Ethereum limits. The
# Hydration-side half runs from scripts/hydration/dai.sh push with its own key.
cmd_push() {
  use_key ETHEREUM_PRIVATE_KEY
  cmd_status || true
  confirm "Push Ethereum-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Ethereum -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
