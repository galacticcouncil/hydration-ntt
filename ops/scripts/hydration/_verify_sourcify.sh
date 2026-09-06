#!/usr/bin/env bash
set -euo pipefail

# Verify Hydration EVM legs on the neckwork explorer (Sourcify API).
# Companion to _verify.sh (Subscan) — same four targets per token:
# manager impl, transceiver impl, and the two ERC1967 proxies.
#
# Usage:
#   _verify_sourcify.sh --check [token ...]   status sweep only, no submissions
#   _verify_sourcify.sh --fix   [token ...]   verify ONLY contracts not yet verified
#   _verify_sourcify.sh         [token ...]   verify all four contracts per token
#   no tokens = every ops/tokens/* with a Hydration leg
#
# Env overrides:
#   VERIFIER_URL  default https://hydration-explorer.neckwork.net/api/
#   WORKTREE      source tree, default this repo's evm/ (spoke legs deploy
#                 with --local, so this matches the deployed bytecode)
#   RPC           default .chains.Hydration.rpc from overrides.json
#   PAUSE         seconds between submissions, default 20 (the explorer
#                 429s after ~10 rapid submissions)
#
# FOUNDRY_VIA_IR=true — the CLI deploys with `forge script --via-ir`; the
# verification build must use identical compiler settings.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKTREE="${WORKTREE:-$REPO/evm}"
VERIFIER_URL="${VERIFIER_URL:-https://hydration-explorer.neckwork.net/api/}"
RPC="${RPC:-$(jq -r '.chains.Hydration.rpc' "$REPO/overrides.json")}"
PAUSE="${PAUSE:-20}"
CHAIN=222222
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
[ -d "$WORKTREE" ] || { echo "ERROR: source tree not found: $WORKTREE"; exit 1; }

MODE=verify
case "${1:-}" in
  --check) MODE=check; shift ;;
  --fix)   MODE=fix;   shift ;;
esac

tokens=("$@")
if [ ${#tokens[@]} -eq 0 ]; then
  for d in "$REPO"/ops/tokens/*/deployment.json; do
    jq -e '.chains.Hydration' "$d" >/dev/null 2>&1 && tokens+=("$(basename "$(dirname "$d")")")
  done
fi

status() { # <address> -> exact_match | NOT_VERIFIED | ...
  curl -sS -m 10 "${VERIFIER_URL%/}/v2/contract/$CHAIN/$1" | jq -r '.match // "NOT_VERIFIED"'
}

submitted=0
verify() { # <address> <src/Path.sol:Contract> <label>
  if [ "$MODE" = check ]; then
    printf '  %-10s %s  %s\n' "$3" "$1" "$(status "$1")"
    return 0
  fi
  if [ "$MODE" = fix ] && [ "$(status "$1")" = exact_match ]; then
    printf '  %-10s %s  already verified\n' "$3" "$1"
    return 0
  fi
  [ "$submitted" -gt 0 ] && sleep "$PAUSE"
  submitted=$((submitted + 1))
  echo "--- $3: $2 @ $1"
  (cd "$WORKTREE" && FOUNDRY_VIA_IR=true forge verify-contract "$1" "$2" \
    --chain-id "$CHAIN" --verifier sourcify --verifier-url "$VERIFIER_URL") \
    || { echo "FAILED: $1 $2"; fail=1; }
}

fail=0
for t in "${tokens[@]}"; do
  D="$REPO/ops/tokens/$t/deployment.json"
  MP=$(jq -r .chains.Hydration.manager "$D")
  TP=$(jq -r .chains.Hydration.transceivers.wormhole.address "$D")
  MI=$(cast parse-bytes32-address "$(cast storage "$MP" "$SLOT" --rpc-url "$RPC")")
  TI=$(cast parse-bytes32-address "$(cast storage "$TP" "$SLOT" --rpc-url "$RPC")")
  echo "== $t"
  verify "$MI" src/NttManager/NttManager.sol:NttManager mgr-impl
  verify "$TI" src/Transceiver/WormholeTransceiver/WormholeTransceiver.sol:WormholeTransceiver xcvr-impl
  verify "$MP" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy mgr-proxy
  verify "$TP" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy xcvr-proxy
done

exit $fail
