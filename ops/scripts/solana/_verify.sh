#!/usr/bin/env bash
set -euo pipefail

# "Verification" for Solana legs = publish the program's anchor IDL on-chain
# so explorers can decode instruction names (there is no Etherscan-style
# source verification for Solana programs). Cosmetic only — the protocol
# doesn't need it.
#
# Usage: _verify.sh <token> [init|fetch|close]
#   init   publish the build's IDL on-chain (~0.08 SOL rent, reclaimable)
#   fetch  pull the on-chain IDL and diff it against the local build
#   close  close the IDL account and refund the rent
#
#   e.g. _verify.sh sol            # after the sol hub leg deployed
#        _verify.sh jitosol fetch
#
# Notes (learned on the SOL deploy, 2026-07-29):
#   - run `init` while the payer is still the program's upgrade authority —
#     after Step 7 moves authority to a multisig, the multisig must sign
#   - NTT v3 builds with anchor 0.29 => LEGACY IDL format; Solscan and
#     explorer.solana.com decode the new (0.30+) spec reliably but legacy
#     only sometimes — instructions may still show "Unknown". That's an
#     explorer parser limitation, not a failed publish; `fetch` is the truth.
#
# Env: SOLANA_RPC (else overrides.json chains.Solana.rpc, else public),
#      WORKTREE (else .deployments/Solana-3.0.0/solana)

TOKEN=${1:?usage: _verify.sh <token> [init|fetch|close]}
ACTION=${2:-init}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEPLOYMENT="$REPO/ops/tokens/$TOKEN/deployment.json"
PAYER="$REPO/ops/tokens/$TOKEN/keys/payer.json"

PROGRAM=$(jq -r '.chains.Solana.manager // empty' "$DEPLOYMENT" 2>/dev/null)
[ -n "$PROGRAM" ] || { echo "ERROR: no Solana manager in $DEPLOYMENT"; exit 1; }

RPC="${SOLANA_RPC:-$(jq -r '.chains.Solana.rpc // empty' "$REPO/overrides.json" 2>/dev/null)}"
[ -n "$RPC" ] || RPC=https://api.mainnet-beta.solana.com

WORKTREE="${WORKTREE:-$REPO/.deployments/Solana-3.0.0/solana}"
IDL="$WORKTREE/target/idl/example_native_token_transfers.json"
cd "$WORKTREE"   # anchor wants an Anchor.toml around

case "$ACTION" in
  init)
    [ -f "$IDL" ] || { echo "ERROR: IDL not found: $IDL — run a build first"; exit 1; }
    [ -f "$PAYER" ] || { echo "ERROR: payer keypair not found: $PAYER"; exit 1; }
    anchor idl init "$PROGRAM" --filepath "$IDL" \
      --provider.cluster "$RPC" --provider.wallet "$PAYER"
    ;;
  fetch)
    TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
    anchor idl fetch "$PROGRAM" --provider.cluster "$RPC" > "$TMP"
    python3 - "$TMP" "$IDL" <<'PY'
import json, sys
onchain = json.load(open(sys.argv[1]))
print(f"on-chain IDL: {onchain.get('name')} | {len(onchain.get('instructions', []))} instructions")
try:
    local = json.load(open(sys.argv[2]))
    print("matches local build IDL:", onchain == local)
except FileNotFoundError:
    print("(no local build IDL to compare)")
PY
    ;;
  close)
    [ -f "$PAYER" ] || { echo "ERROR: payer keypair not found: $PAYER"; exit 1; }
    anchor idl close "$PROGRAM" --provider.cluster "$RPC" --provider.wallet "$PAYER"
    ;;
  *)
    echo "unknown action: $ACTION (init|fetch|close)"; exit 1
    ;;
esac
