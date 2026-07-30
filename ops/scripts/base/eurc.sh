#!/usr/bin/env bash
# EURC — hub leg: Base, locking mode. Hub legs (ethereum/base/solana) deploy
# first; the Hydration spoke leg comes later via scripts/hydration/eurc.sh.
# Signs with BASE_PRIVATE_KEY only (may hold the same key as Ethereum's —
# still a separate env var so the wrong chain can never be signed by accident).
#
#   scripts/base/eurc.sh preflight   # no txs: keys, balances, gas price, CLI sanity
#   scripts/base/eurc.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/base/eurc.sh deploy      # TX Base: manager+transceiver (locking EURC),
#                                   #   verifies on Basescan inline (BASE_SCAN_API_KEY)
#   scripts/base/eurc.sh push        # TX Base: register Hydration peer + limits (after spoke leg)
#
#   scripts/base/eurc.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/eurc/deployment.json"
EURC=0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42   # canonical Circle EURC on Base, 6 decimals

cmd_preflight() {
  use_key BASE_PRIVATE_KEY
  need_tools ntt cast jq git
  check_cli
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Base balance: $(cast balance --ether "$addr" --rpc-url "$BASE_RPC") ETH"
  local gp; gp=$(cast gas-price --rpc-url "$BASE_RPC")
  echo "Gas price: $(cast from-wei "$gp" gwei) gwei — deploy is ~10-15M gas," \
       "est. $(cast from-wei $((gp * 15000000))) ETH (+ L1 data fee)"
  [ "$(cast code $EURC --rpc-url "$BASE_RPC")" != "0x" ] \
    || { echo "ERROR: no code at EURC address on Base"; exit 1; }
  echo "EURC @ $EURC: OK ($(cast call $EURC 'symbol()(string)' --rpc-url "$BASE_RPC"))"
}

cmd_deploy() {
  use_key BASE_PRIVATE_KEY
  # Etherscan V2 keys are chain-agnostic — the Ethereum key works for Base.
  # The CLI still resolves the per-chain var, so default it from the Ethereum one.
  export BASE_SCAN_API_KEY="${BASE_SCAN_API_KEY:-${ETHEREUM_SCAN_API_KEY:-}}"
  need_env BASE_SCAN_API_KEY   # deploy-time Basescan verification (CLI resolves <CHAIN>_SCAN_API_KEY)
  confirm "Deploy NTT manager+transceiver to BASE mainnet (~10-15M gas)?"
  (cd "$NTT_SRC" && ntt add-chain Base --latest --mode locking \
    --token $EURC -p "$DEPLOYMENT")
}

# Base-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Base and applies Base limits. The Hydration-side
# half runs from scripts/hydration/eurc.sh push with its own key.
cmd_push() {
  use_key BASE_PRIVATE_KEY
  cmd_status || true
  confirm "Push Base-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Base -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
