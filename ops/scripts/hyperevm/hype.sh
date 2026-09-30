#!/usr/bin/env bash
# HYPE — hub leg: HyperEVM (chain 47), locking mode over WHYPE
# 0x5555…5555 (WETH9-style "Wrapped HYPE", 18 dec). Variant defaults to
# wethUnwrap: Hydration→HyperEVM recipients get NATIVE HYPE, same pattern as
# WETH on Ethereum/Robinhood. Fresh two-leg deployment (ops/tokens/hype):
# HyperEVM locking <-> Hydration burning (runtime asset 1001355,
# scripts/hydration/hype.sh). Hub first. Signs with HYPEREVM_PRIVATE_KEY only.
#
# HyperEVM specifics:
#   * the manager deploy doesn't fit a small (2M gas) block — the deployer
#     must be on big blocks (per-address HyperCore flag, 30M gas, ~1 min
#     blocks). 'bigblocks on' before deploy, 'bigblocks off' after.
#   * the deployer needs a HyperCore account for the flag (any prior
#     HyperCore activity/deposit) and HYPE on HyperEVM for gas.
#   * NO custodian exists here yet (Safe/multisig on chain 999 is an open
#     decision) — ownership handover is blocked until it does.
#
#   scripts/hyperevm/hype.sh preflight        # no txs: keys, balance, WHYPE sanity, CLI chain list
#   scripts/hyperevm/hype.sh init             # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/hyperevm/hype.sh bigblocks on|off # HyperCore action: toggle big blocks for the deployer
#   scripts/hyperevm/hype.sh deploy           # TX HyperEVM: manager+transceiver (locking WHYPE),
#                                             #   --skip-verify; verify post-hoc on sourcify.dev (chain 999)
#   scripts/hyperevm/hype.sh limits           # no txs: write HyperEVM rate limits into deployment.json
#   scripts/hyperevm/hype.sh push             # TX HyperEVM: register Hydration peer + limits (after spoke leg)
#
#   scripts/hyperevm/hype.sh status           # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/hype/deployment.json"
WHYPE=0x5555555555555555555555555555555555555555
VARIANT="${VARIANT:-wethUnwrap}"   # or 'standard' (recipients get WHYPE)

# 24h NTT rate limits, whole HYPE (18 dec). Real limits on the hub — only the
# Hydration leg is unlimited. Floor is >= $100k/day, as for every token:
# 1200 HYPE ≈ $105k at $87.50 (the $100k floor is 1143 HYPE). The registry
# xcm_rate_limit mint fuse must be raised to match (it was set at 500 HYPE).
LIMIT_HYPEREVM_OUT="${LIMIT_HYPEREVM_OUT:-1200}"
LIMIT_HYPEREVM_IN="${LIMIT_HYPEREVM_IN:-1200}"
UNLIMITED=184467440737.095516150000000000   # CLI default — must never be pushed on a hub

cmd_preflight() {
  use_key HYPEREVM_PRIVATE_KEY
  need_tools ntt cast jq git
  ntt add-chain HyperEVM -p /nonexistent 2>&1 | grep -q "Invalid values" \
    && { echo "ERROR: HyperEVM not in CLI chain list"; exit 1; }
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "HyperEVM balance: $(cast balance --ether "$addr" --rpc-url "$HYPEREVM_RPC") HYPE"
  local code; code=$(cast code $WHYPE --rpc-url "$HYPEREVM_RPC")
  [ "$code" != "0x" ] || { echo "ERROR: no code at WHYPE on HyperEVM"; exit 1; }
  local sym dec sup bal
  sym=$(cast call $WHYPE 'symbol()(string)' --rpc-url "$HYPEREVM_RPC")
  dec=$(cast call $WHYPE 'decimals()(uint8)' --rpc-url "$HYPEREVM_RPC")
  echo "WHYPE @ $WHYPE: symbol=$sym decimals=$dec variant=$VARIANT"
  [ "$dec" = "18" ] || { echo "ERROR: WHYPE decimals $dec != 18 (Hydration asset 1001355 is 18)"; exit 1; }
  if [ "$VARIANT" = "wethUnwrap" ]; then
    # wethUnwrap calls weth.withdraw(uint256) on unlock: selector 0x2e1a7d4d
    echo "$code" | grep -q 2e1a7d4d || { echo "ERROR: WHYPE has no withdraw(uint256) — use VARIANT=standard"; exit 1; }
    local bn; bn=$(cast block-number --rpc-url "$HYPEREVM_RPC")
    sup=$(cast call $WHYPE 'totalSupply()(uint256)' --block "$bn" --rpc-url "$HYPEREVM_RPC" | awk '{print $1}')
    bal=$(cast balance $WHYPE --block "$bn" --rpc-url "$HYPEREVM_RPC")
    python3 -c "import sys; sys.exit(0 if int('$bal') >= int('$sup') else 1)" \
      || { echo "ERROR: WHYPE wrap invariant broken at block $bn: supply $sup > native $bal"; exit 1; }
    echo "WHYPE withdraw() present, native>=supply ✓ at block $bn"
  fi
}

cmd_bigblocks() {
  use_key HYPEREVM_PRIVATE_KEY
  case "${1:-}" in
    on)  (cd "$NTT_SRC" && ntt hype set-big-blocks -p "$DEPLOYMENT") ;;
    off) (cd "$NTT_SRC" && ntt hype set-big-blocks --disable -p "$DEPLOYMENT") ;;
    *)   echo "usage: hype.sh bigblocks on|off"; exit 1 ;;
  esac
}

cmd_deploy() {
  use_key HYPEREVM_PRIVATE_KEY
  confirm "Deploy NTT manager+transceiver (LOCKING WHYPE, $VARIANT) to HYPEREVM mainnet? (big blocks must be ON)"
  (cd "$NTT_SRC" && ntt add-chain HyperEVM --local --mode locking \
    --manager-variant "$VARIANT" --token $WHYPE --skip-verify -p "$DEPLOYMENT")
  echo "Verify NOW on sourcify.dev (chain 999) — a similar match blocks exact verification forever"
  echo "Then: scripts/hyperevm/hype.sh bigblocks off"
}

# HyperEVM-side half of the cross-link. The Hydration-side half runs from
# scripts/hydration/hype.sh push with its own key. Small blocks are fine here.
cmd_limits() {
  jq -e '.chains.HyperEVM' "$DEPLOYMENT" >/dev/null || { echo "ERROR: HyperEVM leg missing — run deploy first"; exit 1; }
  local frac; frac=$(printf '%018d' 0)
  jq --arg out "$LIMIT_HYPEREVM_OUT.$frac" --arg in "$LIMIT_HYPEREVM_IN.$frac" '
    .chains.HyperEVM.limits.outbound          = $out |
    .chains.HyperEVM.limits.inbound.Hydration = $in
  ' "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  jq '.chains.HyperEVM.limits' "$DEPLOYMENT"
}

# Refuse to push an unlimited or missing hub limit.
guard_limits() {
  local out in
  out=$(jq -r '.chains.HyperEVM.limits.outbound // empty' "$DEPLOYMENT")
  in=$(jq -r '.chains.HyperEVM.limits.inbound.Hydration // empty' "$DEPLOYMENT")
  [ -n "$out" ] && [ "$out" != "$UNLIMITED" ] && [ -n "$in" ] && [ "$in" != "$UNLIMITED" ] \
    || { echo "ERROR: HyperEVM limits unset/unlimited (out=$out in=$in) — run 'limits' first"; exit 1; }
}

cmd_push() {
  use_key HYPEREVM_PRIVATE_KEY
  guard_limits
  cmd_status || true
  confirm "Push HyperEVM-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain HyperEVM -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|deploy|limits|push|status) "cmd_$1" ;;
  bigblocks) cmd_bigblocks "${@:2}" ;;
  *) sed -n '2,27p' "$0"; exit 1 ;;
esac
