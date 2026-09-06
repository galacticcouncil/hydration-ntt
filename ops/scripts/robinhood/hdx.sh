#!/usr/bin/env bash
# HDX — spoke leg: Robinhood (chain 72), BURNING mode. The representation is
# a PeerToken variant with decimals() OVERRIDDEN TO 12 (HDX hub is the
# 12-decimals precompile; the stock example-ntt-token-evm PeerToken is 18 and
# must NOT be used as-is). Deploy it separately and write its address into
# tokens/hdx/robinhood-token.addr before running. Preflight hard-fails on
# decimals != 12 — the manager caches token decimals as an immutable at
# construction, so this must be right BEFORE 'deploy'.
#
# Run only AFTER the Hydration hub leg (scripts/hydration/hdx.sh deploy).
# Signs with ROBINHOOD_PRIVATE_KEY only.
#
#   scripts/robinhood/hdx.sh preflight   # no txs: keys, balance, token sanity (12 dec, owner)
#   scripts/robinhood/hdx.sh deploy      # TX Robinhood: manager+transceiver (burning PeerToken),
#                                       #   --skip-verify; verify post-hoc on sourcify.dev (chain 4663)
#   scripts/robinhood/hdx.sh minter      # TX Robinhood: PeerToken.setMinter(manager) — token
#                                       #   owner key; REQUIRED before any inbound transfer
#   scripts/robinhood/hdx.sh limits      # no txs: write rate limits into deployment.json
#   scripts/robinhood/hdx.sh push        # TX Robinhood: register Hydration peer + limits
#   scripts/robinhood/hdx.sh status      # local vs on-chain drift
#
# Cross-link is two-sided: after 'push' here, run scripts/hydration/hdx.sh
# push (HYDRATION_PRIVATE_KEY). Ownership handover (manager owner, TOKEN
# OWNER — it can re-point the minter! — and pauser) per ops/TRANSFER_OWNERSHIP.md
# only after smoke tests.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/hdx/deployment.json"
TOKEN_ADDR_FILE="$HYD_ROOT/tokens/hdx/robinhood-token.addr"

# 24h NTT rate limits, whole HDX (12 decimals — fraction below must match!).
# Default 10M HDX ≈ $100k at $0.01 spot (2026-09) — the same dollar order as
# the other legs' 100k-stable limits. HDX is NOT a stable: resize as price
# moves. Real limits on this side too: Robinhood has no runtime fuse — these
# ARE the throttle.
LIMIT_ROBINHOOD_OUT="${LIMIT_ROBINHOOD_OUT:-10000000}"
LIMIT_ROBINHOOD_IN="${LIMIT_ROBINHOOD_IN:-10000000}"

token() {
  [ -f "$TOKEN_ADDR_FILE" ] || { echo "ERROR: $TOKEN_ADDR_FILE missing — deploy the 12-dec PeerToken first, write its address there" >&2; exit 1; }
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
    || { echo "ERROR: Hydration hub leg missing — run scripts/hydration/hdx.sh deploy first"; exit 1; }
  local addr T; addr=$(deployer); T=$(token)
  echo "== Deployer: $addr =="
  echo "Robinhood balance: $(cast balance --ether "$addr" --rpc-url "$ROBINHOOD_RPC") ETH"
  [ "$(cast code "$T" --rpc-url "$ROBINHOOD_RPC")" != "0x" ] \
    || { echo "ERROR: no code at PeerToken $T on Robinhood"; exit 1; }
  echo "PeerToken @ $T: $(cast call "$T" 'symbol()(string)' --rpc-url "$ROBINHOOD_RPC")"
  local dec; dec=$(cast call "$T" 'decimals()(uint8)' --rpc-url "$ROBINHOOD_RPC")
  [ "$dec" = "12" ] || { echo "ERROR: PeerToken decimals $dec != 12 (HDX hub is 12) — wrong token, do NOT deploy"; exit 1; }
  echo "decimals: 12 OK; owner: $(cast call "$T" 'owner()(address)' --rpc-url "$ROBINHOOD_RPC");" \
       "minter: $(cast call "$T" 'minter()(address)' --rpc-url "$ROBINHOOD_RPC")"
}

cmd_deploy() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  confirm "Deploy NTT manager+transceiver (BURNING 12-dec PeerToken) to ROBINHOOD mainnet?"
  # Forge simulation may fail with EvmError: NotActivated (token compiled for
  # a newer EVM than the NTT project's evm_version) — proceeding without
  # simulation is expected and safe here; hollar did the same.
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
  # 12-decimal fraction — NOT 18 like hollar
  jq --arg out "$LIMIT_ROBINHOOD_OUT.000000000000" \
     --arg in "$LIMIT_ROBINHOOD_IN.000000000000" \
     '.chains.Robinhood.limits.outbound = $out
      | .chains.Robinhood.limits.inbound.Hydration = $in' \
     "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  echo "Robinhood limits set: out $LIMIT_ROBINHOOD_OUT / in(Hydration) $LIMIT_ROBINHOOD_IN HDX"
}

# Robinhood-side half of the cross-link; the Hydration-side half runs from
# scripts/hydration/hdx.sh push with its own key.
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
  *) sed -n '2,26p' "$0"; exit 1 ;;
esac
