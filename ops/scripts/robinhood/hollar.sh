#!/usr/bin/env bash
# HOLLAR — spoke leg: Robinhood (chain 72), BURNING mode. The representation
# is a PeerToken (example-ntt-token-evm) deployed separately; write its
# address into tokens/hollar/robinhood-token.addr before running.
#
# Run only AFTER the Hydration hub leg (scripts/hydration/hollar.sh deploy).
# Signs with ROBINHOOD_PRIVATE_KEY only. ROBINHOOD_RPC required.
#
#   scripts/robinhood/hollar.sh preflight   # no txs: keys, balance, token sanity (18 dec, owner)
#   scripts/robinhood/hollar.sh deploy      # TX Robinhood: manager+transceiver (burning PeerToken),
#                                          #   --skip-verify; verify post-hoc once explorer known
#   scripts/robinhood/hollar.sh minter      # TX Robinhood: PeerToken.setMinter(manager) — token
#                                          #   owner key; REQUIRED before any inbound transfer
#   scripts/robinhood/hollar.sh limits      # no txs: write rate limits into deployment.json
#   scripts/robinhood/hollar.sh push        # TX Robinhood: register Hydration peer + limits
#   scripts/robinhood/hollar.sh status      # local vs on-chain drift
#
# Cross-link is two-sided: after 'push' here, run scripts/hydration/hollar.sh
# push (HYDRATION_PRIVATE_KEY). Ownership handover (manager owner, TOKEN
# OWNER — it can re-point the minter! — and pauser) per ops/TRANSFER_OWNERSHIP.md
# only after smoke tests.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/hollar/deployment.json"
TOKEN_ADDR_FILE="$HYD_ROOT/tokens/hollar/robinhood-token.addr"

# 24h NTT rate limits, whole tokens. Real limits on this side too: Robinhood
# has no runtime fuse — these ARE the throttle (see scripts/hydration/hollar.sh).
LIMIT_ROBINHOOD_OUT="${LIMIT_ROBINHOOD_OUT:-100000}"
LIMIT_ROBINHOOD_IN="${LIMIT_ROBINHOOD_IN:-100000}"

token() {
  [ -f "$TOKEN_ADDR_FILE" ] || { echo "ERROR: $TOKEN_ADDR_FILE missing — deploy PeerToken first, write its address there" >&2; exit 1; }
  tr -d ' \n' < "$TOKEN_ADDR_FILE"
}

spoke_manager() { jq -r '.chains.Robinhood.manager // empty' "$DEPLOYMENT" 2>/dev/null; }

cmd_preflight() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  need_tools ntt cast jq git
  # NB: '--help' exits 0 without validating the chain name — probe for real.
  ntt add-chain Robinhood -p /nonexistent 2>&1 | grep -q "Invalid values" \
    && { echo "ERROR: Robinhood not in CLI chain list (needs sdk-base >= 6.1.5 in ~/.ntt-cli/.checkout)"; exit 1; }
  jq -e '.chains.Hydration.manager' "$DEPLOYMENT" >/dev/null 2>&1 \
    || { echo "ERROR: Hydration hub leg missing — run scripts/hydration/hollar.sh deploy first"; exit 1; }
  local addr T; addr=$(deployer); T=$(token)
  echo "== Deployer: $addr =="
  echo "Robinhood balance: $(cast balance --ether "$addr" --rpc-url "$ROBINHOOD_RPC") ETH"
  [ "$(cast code "$T" --rpc-url "$ROBINHOOD_RPC")" != "0x" ] \
    || { echo "ERROR: no code at PeerToken $T on Robinhood"; exit 1; }
  echo "PeerToken @ $T: $(cast call "$T" 'symbol()(string)' --rpc-url "$ROBINHOOD_RPC")"
  local dec; dec=$(cast call "$T" 'decimals()(uint8)' --rpc-url "$ROBINHOOD_RPC")
  [ "$dec" = "18" ] || { echo "ERROR: PeerToken decimals $dec != 18 (HOLLAR hub is 18)"; exit 1; }
  echo "decimals: 18 OK; owner: $(cast call "$T" 'owner()(address)' --rpc-url "$ROBINHOOD_RPC");" \
       "minter: $(cast call "$T" 'minter()(address)' --rpc-url "$ROBINHOOD_RPC")"
}

cmd_deploy() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  confirm "Deploy NTT manager+transceiver (BURNING PeerToken) to ROBINHOOD mainnet?"
  (cd "$NTT_SRC" && ntt add-chain Robinhood --local --mode burning \
    --token "$(token)" --skip-verify -p "$DEPLOYMENT")
}

cmd_minter() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  local T M; T=$(token); M=$(spoke_manager)
  [ -n "$M" ] || { echo "ERROR: no Robinhood manager in deployment.json — deploy first"; exit 1; }
  local cur; cur=$(cast call "$T" 'minter()(address)' --rpc-url "$ROBINHOOD_RPC")
  [ "$(echo "$cur" | tr 'A-F' 'a-f')" = "$(echo "$M" | tr 'A-F' 'a-f')" ] \
    && { echo "minter already = manager $M, nothing to do"; return 0; }
  confirm "PeerToken.setMinter($M) on Robinhood (token owner tx)?"
  cast send "$T" 'setMinter(address)' "$M" --private-key "$ETH_PRIVATE_KEY" --rpc-url "$ROBINHOOD_RPC"
  echo "minter now: $(cast call "$T" 'minter()(address)' --rpc-url "$ROBINHOOD_RPC")"
}

cmd_limits() {
  jq --arg out "$LIMIT_ROBINHOOD_OUT.000000000000000000" \
     --arg in "$LIMIT_ROBINHOOD_IN.000000000000000000" \
     '.chains.Robinhood.limits.outbound = $out
      | .chains.Robinhood.limits.inbound.Hydration = $in' \
     "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  echo "Robinhood limits set: out $LIMIT_ROBINHOOD_OUT / in(Hydration) $LIMIT_ROBINHOOD_IN HOLLAR"
}

# Robinhood-side half of the cross-link; the Hydration-side half runs from
# scripts/hydration/hollar.sh push with its own key.
cmd_push() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  cmd_status || true
  confirm "Push Robinhood-side config (setPeer Hydration + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Robinhood -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|deploy|minter|limits|push|status) "cmd_$1" ;;
  *) sed -n '2,23p' "$0"; exit 1 ;;
esac
