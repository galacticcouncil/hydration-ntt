#!/usr/bin/env bash
# HYPE — spoke leg: Hydration, burning mode. PRECOMPILE VARIANT: the
# representation is runtime asset 1001355 "Hyperliquid (Wormhole)" (registered via
# register_external + TC update, 18 dec) exposed as ERC-20 at the currencies
# precompile 0x…01000f478b. No token contract is deployed; minter binding =
# EVMAccounts.set_ntt_minter (governance).
#
# Run only AFTER the HyperEVM hub leg (scripts/hyperevm/hype.sh).
# Signs with HYDRATION_PRIVATE_KEY only (whitelisted Hydration deployer).
#
#   scripts/hydration/hype.sh preflight   # no txs: hub leg present, balance, whitelist note
#   scripts/hydration/hype.sh asset [id]  # no txs: derive+verify precompile ref (default 1001355)
#   scripts/hydration/hype.sh deploy      # TX: manager+transceiver (burning), --skip-verify
#                                        #   (verify post-hoc via scripts/hydration/_verify_sourcify.sh hype)
#   scripts/hydration/hype.sh limits      # no txs: write rate limits into deployment.json
#   scripts/hydration/hype.sh push        # TX Hydration: register HyperEVM peer + limits
#
#   scripts/hydration/hype.sh minter      # no txs: print go-live governance calls
#   scripts/hydration/hype.sh status      # local vs on-chain drift
#
# Cross-link is two-sided: after 'push' here, also run scripts/hyperevm/hype.sh
# push (signs with the HyperEVM key). Ownership handover
# (scripts/hydration/_handover.sh hype) only after smoke tests.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/hype/deployment.json"
TOKEN_ADDR_FILE="$HYD_ROOT/tokens/hype/hydration-token.addr"
ASSET_ID_DEFAULT=1001355

# 24h NTT rate limits, whole HYPE. Hydration leg only — unlimited, the runtime
# fuse governs this side. Hub limits live in scripts/hyperevm/hype.sh limits.
LIMIT_HYDRATION_OUT="${LIMIT_HYDRATION_OUT:-184467440737}"   # ~uint64 max = unlimited (runtime fuse governs this side)
LIMIT_HYDRATION_IN="${LIMIT_HYDRATION_IN:-184467440737}"    # ~uint64 max = unlimited

hub_manager()   { jq -r '.chains.HyperEVM.manager // empty' "$DEPLOYMENT" 2>/dev/null; }
spoke_manager() { jq -r '.chains.Hydration.manager // empty' "$DEPLOYMENT" 2>/dev/null; }

cmd_preflight() {
  use_key HYDRATION_PRIVATE_KEY
  need_tools ntt cast jq git
  check_cli
  [ -n "$(hub_manager)" ] \
    || { echo "ERROR: no HyperEVM manager in $DEPLOYMENT — run scripts/hyperevm/hype.sh first"; exit 1; }
  echo "HyperEVM hub manager: $(hub_manager)"
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Hydration balance: $(cast balance --ether "$addr" --rpc-url "$HYDRATION_RPC")"
  echo "(deployer must be on Hydration's EVM deploy whitelist — 'deploy' step is the first real test)"
}

# Representation ref = currencies precompile: 16-byte prefix ending in 0x01,
# then the u32 asset id big-endian (erc20_mapping.rs in hydration-node).
cmd_asset() {
  local id="${1:-$ASSET_ID_DEFAULT}"
  need_tools cast jq
  [ ! -s "$TOKEN_ADDR_FILE" ] \
    || { echo "already set: $(cat "$TOKEN_ADDR_FILE") (delete $TOKEN_ADDR_FILE to redo)"; exit 0; }
  local addr
  addr="0x00000000000000000000000000000001$(printf '%08x' "$id")"
  echo "asset id $id → precompile $addr"
  local sym dec
  sym=$(cast call "$addr" 'symbol()(string)' --rpc-url "$HYDRATION_RPC") \
    || { echo "ERROR: precompile call failed — is asset $id registered?"; exit 1; }
  dec=$(cast call "$addr" 'decimals()(uint8)' --rpc-url "$HYDRATION_RPC")
  echo "symbol=$sym decimals=$dec"
  [ "$dec" = "18" ] || { echo "ERROR: decimals $dec != 18 (HyperEVM WHYPE is 18)"; exit 1; }
  confirm "Use this asset as the HYPE representation?"
  mkdir -p "$(dirname "$TOKEN_ADDR_FILE")"
  echo "$addr" > "$TOKEN_ADDR_FILE"
  echo "saved to $TOKEN_ADDR_FILE"
}

# Asset id is recoverable from the saved ref — last 4 bytes of the address.
asset_id() {
  local addr; addr=$(cat "$TOKEN_ADDR_FILE")
  echo $((16#${addr: -8}))
}

cmd_deploy() {
  use_key HYDRATION_PRIVATE_KEY
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  # --local (not --latest): compiles from THIS repo's working tree, which
  # carries the codeless-precompile fix in DeployWormholeNtt.s.sol.
  confirm "Deploy NTT manager+transceiver to HYDRATION mainnet (from local tree)?"
  (cd "$NTT_SRC" && ntt add-chain Hydration --local --mode burning \
    --token "$(cat "$TOKEN_ADDR_FILE")" --skip-verify -p "$DEPLOYMENT")
  echo "Verify NOW: ops/scripts/hydration/_verify_sourcify.sh hype"
}

# Go-live is governance — we can't sign it. Print exactly what to submit.
cmd_minter() {
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  local id manager
  id=$(asset_id)
  manager=$(spoke_manager)
  [ -n "$manager" ] || { echo "ERROR: no Hydration manager in deployment.json — run 'deploy' first"; exit 1; }
  cat <<EOF
Go-live (referendum — ControllerOrigin, Root/GeneralAdmin; fastest via TC
whitelist + whitelisted_caller, as DAI):

  EVMAccounts.set_ntt_minter(asset_id: $id, minter: $manager)

Until this executes, the manager cannot mint or burn — the go-live switch.
Emergency unbind (faster origin): EVMAccounts.clear_ntt_minter($id)

Before go-live (TC majority is enough, can precede the referendum):
  - CircuitBreaker.set_asset_category($id, External) — every existing NTT
    asset carries this override (global withdraw-limit accounting); asset
    $id has none yet
  - registry xcm_rate_limit is already set (500 HYPE/day) — keep aligned
    with the NTT hub limits

Verify after enactment (chain state): EVMAccounts.nttMinters($id) == $manager
EOF
}

cmd_limits() {
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  local frac; frac=$(printf '%018d' 0)
  jq --arg ho "$LIMIT_HYDRATION_OUT.$frac" --arg hi "$LIMIT_HYDRATION_IN.$frac" '
    .chains.Hydration.limits.outbound          = $ho |
    .chains.Hydration.limits.inbound.HyperEVM = $hi
  ' "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  jq '.chains | map_values(.limits)' "$DEPLOYMENT"
}

# Hydration-side half of the cross-link; the HyperEVM-side half runs via
# scripts/hyperevm/hype.sh push (its own key).
cmd_push() {
  use_key HYDRATION_PRIVATE_KEY
  cmd_status || true
  confirm "Push Hydration-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Hydration -p "$DEPLOYMENT")
  cmd_status
  echo "Remember: run scripts/hyperevm/hype.sh push for the HyperEVM-side half."
}

case "${1:-}" in
  preflight|asset|deploy|minter|limits|push|status) "cmd_$1" "${@:2}" ;;
  *) sed -n '2,23p' "$0"; exit 1 ;;
esac
