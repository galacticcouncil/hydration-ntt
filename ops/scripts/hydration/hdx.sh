#!/usr/bin/env bash
# HDX — hub leg: Hydration, LOCKING mode. Like hollar.sh but the token is the
# CURRENCIES PRECOMPILE (asset id 0 = native HDX, 12 DECIMALS), not a
# contract: the address has no real bytecode (cast code returns 0x00), so
# preflight probes functions instead of code, and the deploy relies on the
# codeless-precompile fix in DeployWormholeNtt.s.sol (present in this tree —
# deploy --local, see scripts/hydration/dai.sh).
# Locking needs approve/allowance/transferFrom/transfer/balanceOf — all
# implemented by the multicurrency precompile (hydration-node
# runtime/hydradx/src/evm/precompiles/multicurrency.rs). No NttMinters
# binding: locking never mints on Hydration.
#
# Hub leg deploys FIRST; the Robinhood spoke follows via
# scripts/robinhood/hdx.sh (PeerToken there MUST be the 12-decimals variant).
# Signs with HYDRATION_PRIVATE_KEY only (whitelisted Hydration deployer).
#
#   scripts/hydration/hdx.sh preflight   # no txs: keys, balance, precompile probes, CLI
#   scripts/hydration/hdx.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/hydration/hdx.sh deploy      # TX Hydration: manager+transceiver (locking HDX),
#                                       #   --skip-verify; post-hoc: hydration/_verify_sourcify.sh hdx
#   scripts/hydration/hdx.sh limits      # no txs: write rate limits into deployment.json
#   scripts/hydration/hdx.sh push        # TX Hydration: register Robinhood peer + limits
#                                       #   (run AFTER the spoke leg exists)
#   scripts/hydration/hdx.sh status     # local vs on-chain drift
#
# Custody = the manager's native HDX balance (12 dec). Existential deposit:
# seed the manager with a little HDX before dust smoke tests so sub-ED
# custody can't be reaped. Ownership handover per ops/TRANSFER_OWNERSHIP.md
# only after smoke tests.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/hdx/deployment.json"
HDX=0x0000000000000000000000000000000100000000   # currencies precompile, asset id 0

# 24h NTT rate limits, whole HDX (12 decimals — fraction below must match!).
# Default 10M HDX ≈ $100k at $0.01 spot (2026-09) — the same dollar order as
# the other legs' 100k-stable limits. HDX is NOT a stable: resize as price
# moves. Real limits on both sides: the Robinhood spoke has no runtime fuse.
LIMIT_HYDRATION_OUT="${LIMIT_HYDRATION_OUT:-10000000}"
LIMIT_HYDRATION_IN="${LIMIT_HYDRATION_IN:-10000000}"

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
  # precompile has no bytecode — probe functions, not code
  local sym dec
  sym=$(cast call $HDX 'symbol()(string)' --rpc-url "$HYDRATION_RPC")
  dec=$(cast call $HDX 'decimals()(uint8)' --rpc-url "$HYDRATION_RPC")
  [ "$sym" = '"HDX"' ] || { echo "ERROR: precompile symbol $sym != \"HDX\""; exit 1; }
  [ "$dec" = "12" ] || { echo "ERROR: precompile decimals $dec != 12"; exit 1; }
  cast call $HDX 'allowance(address,address)(uint256)' "$addr" $HDX --rpc-url "$HYDRATION_RPC" >/dev/null \
    || { echo "ERROR: precompile allowance() probe failed — locking needs approve/transferFrom"; exit 1; }
  echo "HDX precompile @ $HDX: symbol/decimals(12)/allowance OK (Robinhood PeerToken MUST be 12 decimals)"
}

cmd_deploy() {
  use_key HYDRATION_PRIVATE_KEY
  confirm "Deploy NTT manager+transceiver (LOCKING HDX precompile) to HYDRATION mainnet?"
  # Gas multiplier balance: too low OOGs (hollar attempt 1), too high hits
  # Hydration's per-TX gas cap and the node refuses the send (hdx attempt 1:
  # precompile token skips simulation, node estimate for the manager CREATE
  # was 9.18M, x200% = 18.4M > cap). 150 clears both. GAS_MULT to override.
  (cd "$NTT_SRC" && ntt add-chain Hydration --local --mode locking \
    --token $HDX --skip-verify --gas-estimate-multiplier "${GAS_MULT:-150}" -p "$DEPLOYMENT")
  echo "Verify post-hoc: ops/scripts/hydration/_verify_sourcify.sh hdx (and _verify.sh for Subscan)"
}

cmd_limits() {
  # 12-decimal fraction — NOT 18 like hollar
  jq --arg out "$LIMIT_HYDRATION_OUT.000000000000" \
     --arg in "$LIMIT_HYDRATION_IN.000000000000" \
     '.chains.Hydration.limits.outbound = $out
      | .chains.Hydration.limits.inbound.Robinhood = $in' \
     "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  echo "Hydration limits set: out $LIMIT_HYDRATION_OUT / in(Robinhood) $LIMIT_HYDRATION_IN HDX"
}

# Hydration-side half of the cross-link; the Robinhood-side half runs from
# scripts/robinhood/hdx.sh push with its own key.
cmd_push() {
  use_key HYDRATION_PRIVATE_KEY
  jq -e '.chains.Robinhood.manager' "$DEPLOYMENT" >/dev/null \
    || { echo "ERROR: Robinhood leg missing — run scripts/robinhood/hdx.sh deploy first"; exit 1; }
  cmd_status || true
  confirm "Push Hydration-side config (setPeer Robinhood + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Hydration -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  init) cmd_init ;;
  preflight|deploy|limits|push|status) "cmd_$1" ;;
  *) sed -n '2,30p' "$0"; exit 1 ;;
esac
