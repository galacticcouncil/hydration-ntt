#!/usr/bin/env bash
# SPY — hub leg: Robinhood (chain 72), locking mode, standard manager over the
# canonical Robinhood Stock Token 0x117cc213… (SPDR S&P 500 ETF, 18 dec).
# Fresh two-leg deployment (ops/tokens/spy): Robinhood locking <-> Hydration
# burning (runtime asset 1001356, scripts/hydration/spy.sh). Hub first.
# Signs with ROBINHOOD_PRIVATE_KEY only.
#
# Token caveats (checked 2026-09-28, re-check in preflight):
#   * beacon proxy (beacon 0xe10b…1b00) + pausable — Robinhood can pause or
#     add transfer compliance by upgrade; custody would then be stuck
#   * ERC-8056 scaled-UI multiplier (splits/dividends) — raw amounts move,
#     the multiplier does not; Hydration pricing must use raw units
#   * simulated transfers holder -> contract/EOA succeeded (no allowlist)
#
#   scripts/robinhood/spy.sh preflight   # no txs: keys, balance, SPY sanity, CLI chain list
#   scripts/robinhood/spy.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/robinhood/spy.sh deploy      # TX Robinhood: manager+transceiver (locking SPY),
#                                        #   --skip-verify; verify post-hoc on sourcify.dev (chain 4663)
#   scripts/robinhood/spy.sh limits      # no txs: write Robinhood rate limits into deployment.json
#   scripts/robinhood/spy.sh push        # TX Robinhood: register Hydration peer + limits (after spoke leg)
#
#   scripts/robinhood/spy.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/spy/deployment.json"
SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C

# 24h NTT rate limits, whole SPY (18 dec). Real limits on the hub — only the
# Hydration leg is unlimited. Floor is >= $100k/day, as for every token:
# 150 SPY ≈ $115k at $765 (the $100k floor is 131 SPY). The registry
# xcm_rate_limit mint fuse must be raised to match (it was set at 60 SPY).
LIMIT_ROBINHOOD_OUT="${LIMIT_ROBINHOOD_OUT:-130}"
LIMIT_ROBINHOOD_IN="${LIMIT_ROBINHOOD_IN:-130}"
UNLIMITED=184467440737.095516150000000000   # CLI default — must never be pushed on a hub

cmd_preflight() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_tools ntt cast jq git
  # NB: '--help' exits 0 without validating the chain name — probe for real.
  ntt add-chain Robinhood -p /nonexistent 2>&1 | grep -q "Invalid values" \
    && { echo "ERROR: Robinhood not in CLI chain list (needs sdk-base >= 6.1.5 in ~/.ntt-cli/.checkout)"; exit 1; }
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Robinhood balance: $(cast balance --ether "$addr" --rpc-url "$ROBINHOOD_RPC") ETH"
  [ "$(cast code $SPY --rpc-url "$ROBINHOOD_RPC")" != "0x" ] \
    || { echo "ERROR: no code at SPY address on Robinhood"; exit 1; }
  local sym dec paused
  sym=$(cast call $SPY 'symbol()(string)' --rpc-url "$ROBINHOOD_RPC")
  dec=$(cast call $SPY 'decimals()(uint8)' --rpc-url "$ROBINHOOD_RPC")
  paused=$(cast call $SPY 'paused()(bool)' --rpc-url "$ROBINHOOD_RPC")
  echo "SPY @ $SPY: symbol=$sym decimals=$dec paused=$paused"
  [ "$dec" = "18" ] || { echo "ERROR: SPY decimals $dec != 18 (Hydration asset 1001356 is 18)"; exit 1; }
  [ "$paused" = "false" ] || { echo "ERROR: SPY is paused"; exit 1; }
}

cmd_deploy() {
  use_key ROBINHOOD_PRIVATE_KEY
  confirm "Deploy NTT manager+transceiver (LOCKING SPY) to ROBINHOOD mainnet?"
  (cd "$NTT_SRC" && ntt add-chain Robinhood --local --mode locking \
    --token $SPY --skip-verify -p "$DEPLOYMENT")
  echo "Verify NOW on sourcify.dev (chain 4663) — a similar match blocks exact verification forever"
}

# Robinhood-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Robinhood and applies Robinhood limits. The
# Hydration-side half runs from scripts/hydration/spy.sh push with its own key.
cmd_limits() {
  jq -e '.chains.Robinhood' "$DEPLOYMENT" >/dev/null || { echo "ERROR: Robinhood leg missing — run deploy first"; exit 1; }
  local frac; frac=$(printf '%018d' 0)
  jq --arg out "$LIMIT_ROBINHOOD_OUT.$frac" --arg in "$LIMIT_ROBINHOOD_IN.$frac" '
    .chains.Robinhood.limits.outbound          = $out |
    .chains.Robinhood.limits.inbound.Hydration = $in
  ' "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  jq '.chains.Robinhood.limits' "$DEPLOYMENT"
}

# Refuse to push an unlimited or missing hub limit.
guard_limits() {
  local out in
  out=$(jq -r '.chains.Robinhood.limits.outbound // empty' "$DEPLOYMENT")
  in=$(jq -r '.chains.Robinhood.limits.inbound.Hydration // empty' "$DEPLOYMENT")
  [ -n "$out" ] && [ "$out" != "$UNLIMITED" ] && [ -n "$in" ] && [ "$in" != "$UNLIMITED" ] \
    || { echo "ERROR: Robinhood limits unset/unlimited (out=$out in=$in) — run 'limits' first"; exit 1; }
}

cmd_push() {
  use_key ROBINHOOD_PRIVATE_KEY
  guard_limits
  cmd_status || true
  confirm "Push Robinhood-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Robinhood -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|deploy|limits|push|status) "cmd_$1" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
