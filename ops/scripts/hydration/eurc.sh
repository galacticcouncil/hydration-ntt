#!/usr/bin/env bash
# EURC — spoke leg: Hydration, burning mode. PRECOMPILE VARIANT (preferred):
# the representation is a runtime asset (asset registry, governance) exposed
# as ERC-20 at the currencies precompile 0x…0001<asset-id>, with NTT
# mint/burn from hydration-node PR #1488. No token contract is deployed;
# minter binding = currencies.set_ntt_minter extrinsic (governance).
#
# Run only AFTER the Base hub leg (scripts/base/eurc.sh) — first Base-hub
# token; the hub side locks EURC on Base, not Ethereum.
# Signs with HYDRATION_PRIVATE_KEY only (whitelisted Hydration deployer).
#
#   scripts/hydration/eurc.sh preflight   # no txs: hub leg present, balance, whitelist note
#   scripts/hydration/eurc.sh asset <id>  # no txs: derive+verify precompile ref from asset id
#   scripts/hydration/eurc.sh deploy      # TX: manager+transceiver (burning), --skip-verify
#                                        #   (verify post-hoc via scripts/hydration/_verify.sh)
#   scripts/hydration/eurc.sh limits      # no txs: write rate limits into deployment.json
#   scripts/hydration/eurc.sh push        # TX Hydration: register Base peer + limits
#
#   scripts/hydration/eurc.sh minter      # no txs: print set_ntt_minter governance call
#   scripts/hydration/eurc.sh status      # local vs on-chain drift
#
# Cross-link is two-sided: after 'push' here, also run scripts/base/eurc.sh
# push (signs with the Base key). Ownership transfer to the multisig is
# deliberately NOT here — DEPLOYMENT.md Step 7, only after smoke tests.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/eurc/deployment.json"
TOKEN_ADDR_FILE="$HYD_ROOT/tokens/eurc/hydration-token.addr"

# 24h NTT rate limits, whole tokens. Base side is 6-dec EURC; Hydration
# side uses the runtime asset's decimals (read live from the precompile).
LIMIT_BASE_OUT="${LIMIT_BASE_OUT:-100000}"
LIMIT_BASE_IN="${LIMIT_BASE_IN:-100000}"
LIMIT_HYDRATION_OUT="${LIMIT_HYDRATION_OUT:-184467440737}"   # ~uint64 max = unlimited (runtime fuse governs this side)
LIMIT_HYDRATION_IN="${LIMIT_HYDRATION_IN:-184467440737}"    # ~uint64 max = unlimited

hub_manager()   { jq -r '.chains.Base.manager      // empty' "$DEPLOYMENT" 2>/dev/null; }
spoke_manager() { jq -r '.chains.Hydration.manager // empty' "$DEPLOYMENT" 2>/dev/null; }

cmd_preflight() {
  use_key HYDRATION_PRIVATE_KEY
  need_tools ntt cast jq git
  check_cli
  [ -n "$(hub_manager)" ] \
    || { echo "ERROR: no Base manager in $DEPLOYMENT — run scripts/base/eurc.sh first"; exit 1; }
  echo "Base hub manager: $(hub_manager)"
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Hydration balance: $(cast balance --ether "$addr" --rpc-url "$HYDRATION_RPC")"
  echo "(deployer must be on Hydration's EVM deploy whitelist — 'deploy' step is the first real test)"
}

# Representation ref = currencies precompile: 16-byte prefix ending in 0x01,
# then the u32 asset id big-endian (erc20_mapping.rs in hydration-node).
cmd_asset() {
  local id="${1:?usage: eurc.sh asset <asset-id>}"
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
  confirm "Use this asset as the EURC representation?"
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
  # carries the codeless-precompile fix in DeployWormholeNtt.s.sol — the
  # version-tag worktree gets hard-reset by the CLI, so it can't be patched.
  # NTT_COMMIT (repo HEAD) is exactly what gets deployed. Keep the tree clean.
  confirm "Deploy NTT manager+transceiver to HYDRATION mainnet (from local tree)?"
  (cd "$NTT_SRC" && ntt add-chain Hydration --local --mode burning \
    --token "$(cat "$TOKEN_ADDR_FILE")" --skip-verify -p "$DEPLOYMENT")
}

# Minter binding is a governance extrinsic (ControllerOrigin) — we can't sign
# it. This step prints exactly what to submit and how to verify.
cmd_minter() {
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  local id manager
  id=$(asset_id)
  manager=$(spoke_manager)
  [ -n "$manager" ] || { echo "ERROR: no Hydration manager in deployment.json — run 'deploy' first"; exit 1; }
  cat <<EOF
Submit via governance (ControllerOrigin — Root/GeneralAdmin track):

  currencies.set_ntt_minter(asset_id: $id, minter: $manager)

Until this executes, the manager cannot mint — inbound transfers will fail.
Emergency unbind (faster origin): currencies.clear_ntt_minter($id)

Coordinate in the same governance effort (or verify already set):
  - asset registry xcm_rate_limit for asset $id — caps the daily
    mint budget (issuance fuse); align with the NTT inbound limit
  - price route to HDX if the asset is AssetType::External (burns revert without it)

Verify after enactment (polkadot.js → chain state):
  currencies.nttMinters($id) == $manager
EOF
}

cmd_limits() {
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  local dec
  dec=$(cast call "$(cat "$TOKEN_ADDR_FILE")" 'decimals()(uint8)' --rpc-url "$HYDRATION_RPC")
  echo "Hydration asset decimals: $dec (Base EURC: 6)"
  local bfrac hfrac
  bfrac=$(printf '%06d' 0)
  hfrac=$(printf "%0${dec}d" 0)
  jq --arg bo "$LIMIT_BASE_OUT.$bfrac"      --arg bi "$LIMIT_BASE_IN.$bfrac" \
     --arg ho "$LIMIT_HYDRATION_OUT.$hfrac" --arg hi "$LIMIT_HYDRATION_IN.$hfrac" '
    .chains.Base.limits.outbound          = $bo |
    .chains.Base.limits.inbound.Hydration = $bi |
    .chains.Hydration.limits.outbound     = $ho |
    .chains.Hydration.limits.inbound.Base = $hi
  ' "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  jq '.chains | map_values(.limits)' "$DEPLOYMENT"
}

# Hydration-side half of the cross-link; the Base-side half runs via
# scripts/base/eurc.sh push (its own key).
cmd_push() {
  use_key HYDRATION_PRIVATE_KEY
  cmd_status || true
  confirm "Push Hydration-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Hydration -p "$DEPLOYMENT")
  cmd_status
  echo "Remember: run scripts/base/eurc.sh push for the Base-side half."
}

case "${1:-}" in
  preflight|asset|deploy|minter|limits|push|status) "cmd_$1" "${@:2}" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
