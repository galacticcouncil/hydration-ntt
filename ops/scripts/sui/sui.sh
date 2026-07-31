#!/usr/bin/env bash
# SUI — hub leg: Sui, locking mode (native SUI coin type 0x2::sui::SUI).
# Hub legs deploy first; the Hydration spoke leg comes later via
# scripts/hydration/sui.sh.
#
# Sui leg specifics (vs EVM/Solana legs):
#   - signer = SUI_PRIVATE_KEY (bech32 suiprivkey… from 'sui keytool export');
#     the CLI imports it into the sui keystore at deploy and signs pushes
#     with it directly — no keypair file, no payer flag
#   - deploy builds + publishes THREE Move packages (ntt_common, ntt,
#     wormhole_transceiver) with the sui CLI from THIS repo's sui/ tree
#     (--local — see cmd_deploy for why not the tag worktree);
#     Published.toml files land in sui/packages/* as the on-disk deploy
#     record — a re-run offers "continue setup" vs "redeploy fresh"
#   - locking mode needs no TreasuryCap (that's burning-only)
#
#   scripts/sui/sui.sh preflight   # no txs: toolchain, key format, CLI sanity
#   scripts/sui/sui.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/sui/sui.sh deploy      # TX Sui: publish 3 packages + init (locking SUI)
#   scripts/sui/sui.sh push        # TX Sui: register Hydration peer + limits (after spoke leg)
#
#   scripts/sui/sui.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/sui/deployment.json"
SUI_COIN="0x2::sui::SUI"        # native SUI, 9 decimals

cmd_preflight() {
  need_env SUI_PRIVATE_KEY
  need_tools ntt sui jq git
  check_cli
  case "$SUI_PRIVATE_KEY" in
    suiprivkey*) echo "SUI_PRIVATE_KEY: bech32 export format OK" ;;
    *) echo "WARN: SUI_PRIVATE_KEY doesn't start with 'suiprivkey' — expected the 'sui keytool export' format" ;;
  esac
  sui --version
  # </dev/null: a fresh sui install has no client.yaml and would otherwise
  # launch its interactive first-run wizard inside the command substitution
  echo "active sui env: $(sui client active-env </dev/null 2>/dev/null || echo '<none — the CLI sets one up at deploy>')"
  echo "(deployer address needs SUI for gas: 3 package publishes + setup txs;"
  echo " default budget 0.1 SUI per publish — keep a few SUI available)"
}

cmd_deploy() {
  need_env SUI_PRIVATE_KEY
  [ -f "$DEPLOYMENT" ] || { echo "ERROR: run 'init' first"; exit 1; }
  # --local (not --latest): the v1.0.0+sui tag predates the new Sui package
  # management system (#814) that the CLI's -e mainnet build flow expects,
  # and pins wormhole to rev "sui/testnet" — whose testnet package id does
  # not exist on mainnet ("Object 0xf473… not found" at publish). This
  # repo's sui/ tree pins a wormhole rev with per-env address resolution.
  # NTT_COMMIT (repo HEAD) is the audit ref. Keep the tree clean.
  confirm "Deploy NTT (3 Move packages) to SUI mainnet (locking $SUI_COIN, from local tree)?"
  (cd "$NTT_SRC" && ntt add-chain Sui --local --mode locking \
    --token "$SUI_COIN" \
    ${SUI_GAS_BUDGET:+--sui-gas-budget "$SUI_GAS_BUDGET"} \
    -p "$DEPLOYMENT")
}

# Sui-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Sui and applies Sui limits. The Hydration-side
# half runs from scripts/hydration/sui.sh push with its own key.
cmd_push() {
  need_env SUI_PRIVATE_KEY
  cmd_status || true
  confirm "Push Sui-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Sui -p "$DEPLOYMENT")
  cmd_status
  echo "Remember: run scripts/hydration/sui.sh push for the Hydration-side half."
}

case "${1:-}" in
  preflight|init|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
