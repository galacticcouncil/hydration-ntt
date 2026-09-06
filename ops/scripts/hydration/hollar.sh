#!/usr/bin/env bash
# HOLLAR — hub leg: Hydration, LOCKING mode. First deployment where Hydration
# is the hub: HOLLAR is a real ERC-20 contract on Hydration EVM (GHO-style,
# 18 dec), so this is a plain EVM locking leg — custody = the manager's own
# HOLLAR balance. No runtime asset, NO currencies.set_ntt_minter binding.
#
# Hub leg deploys FIRST; the Robinhood spoke follows via
# scripts/robinhood/hollar.sh. Signs with HYDRATION_PRIVATE_KEY only
# (whitelisted Hydration deployer).
#
# Deploys --local from this repo's evm/ tree — sync the fork with upstream
# first so new managers are born 2.0.1 (executeMsg peer check, #918).
#
#   scripts/hydration/hollar.sh preflight   # no txs: keys, balance, token sanity, CLI
#   scripts/hydration/hollar.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/hydration/hollar.sh deploy      # TX Hydration: manager+transceiver (locking HOLLAR),
#                                          #   --skip-verify; post-hoc: hydration/_verify_sourcify.sh hollar
#   scripts/hydration/hollar.sh limits      # no txs: write rate limits into deployment.json
#   scripts/hydration/hollar.sh push        # TX Hydration: register Robinhood peer + limits
#                                          #   (run AFTER the spoke leg exists)
#   scripts/hydration/hollar.sh status      # local vs on-chain drift
#
# Ownership handover is deliberately NOT here — ops/TRANSFER_OWNERSHIP.md,
# only after smoke tests. Until then owner+pauser = deployer key.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/hollar/deployment.json"
HOLLAR=0x531a654d1696ed52e7275a8cede955e82620f99a

# 24h NTT rate limits, whole tokens. Unlike our burning spoke legs, BOTH sides
# get real limits: the Robinhood spoke has no runtime fuse (no clear_ntt_minter
# there), so its limits are the only throttle on that side.
LIMIT_HYDRATION_OUT="${LIMIT_HYDRATION_OUT:-100000}"
LIMIT_HYDRATION_IN="${LIMIT_HYDRATION_IN:-100000}"

cmd_preflight() {
  use_key HYDRATION_PRIVATE_KEY
  need_tools ntt cast jq git
  check_cli
  # NB: '--help' exits 0 without validating the chain name — probe for real.
  ntt add-chain Robinhood -p /nonexistent 2>&1 | grep -q "Invalid values" \
    && { echo "ERROR: Robinhood not in CLI chain list (needs sdk-base >= 6.1.5 in ~/.ntt-cli/.checkout)"; exit 1; }
  echo "Robinhood chain: OK"
  local addr; addr=$(deployer)
  echo "== Deployer: $addr (must be on Hydration's EVM deploy whitelist) =="
  echo "Hydration balance: $(cast balance --ether "$addr" --rpc-url "$HYDRATION_RPC") WETH-gas"
  [ "$(cast code $HOLLAR --rpc-url "$HYDRATION_RPC")" != "0x" ] \
    || { echo "ERROR: no code at HOLLAR address"; exit 1; }
  echo "HOLLAR @ $HOLLAR: $(cast call $HOLLAR 'symbol()(string)' --rpc-url "$HYDRATION_RPC")," \
       "decimals $(cast call $HOLLAR 'decimals()(uint8)' --rpc-url "$HYDRATION_RPC")" \
       "(Robinhood PeerToken must match)"
}

cmd_deploy() {
  use_key HYDRATION_PRIVATE_KEY
  confirm "Deploy NTT manager+transceiver (LOCKING HOLLAR) to HYDRATION mainnet?"
  # --gas-estimate-multiplier: Hydration's eth_estimateGas undershoots on
  # CREATE — first attempt died out-of-gas with gasUsed == gasLimit.
  (cd "$NTT_SRC" && ntt add-chain Hydration --local --mode locking \
    --token $HOLLAR --skip-verify --gas-estimate-multiplier 200 -p "$DEPLOYMENT")
  echo "Verify post-hoc: ops/scripts/hydration/_verify_sourcify.sh hollar (and _verify.sh for Subscan)"
}

cmd_limits() {
  jq --arg out "$LIMIT_HYDRATION_OUT.000000000000000000" \
     --arg in "$LIMIT_HYDRATION_IN.000000000000000000" \
     '.chains.Hydration.limits.outbound = $out
      | .chains.Hydration.limits.inbound.Robinhood = $in' \
     "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  echo "Hydration limits set: out $LIMIT_HYDRATION_OUT / in(Robinhood) $LIMIT_HYDRATION_IN HOLLAR"
}

# Hydration-side half of the cross-link: registers the Robinhood manager +
# transceiver as peers ON Hydration and applies Hydration limits. The
# Robinhood-side half runs from scripts/robinhood/hollar.sh push.
cmd_push() {
  use_key HYDRATION_PRIVATE_KEY
  jq -e '.chains.Robinhood.manager' "$DEPLOYMENT" >/dev/null \
    || { echo "ERROR: Robinhood leg missing — run scripts/robinhood/hollar.sh deploy first"; exit 1; }
  cmd_status || true
  confirm "Push Hydration-side config (setPeer Robinhood + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Hydration -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  init) need_env ROBINHOOD_RPC; cmd_init ;;   # overrides.json must carry Robinhood for push
  preflight|deploy|limits|push|status) "cmd_$1" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
