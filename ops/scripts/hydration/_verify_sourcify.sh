#!/usr/bin/env bash
set -euo pipefail

# Verify Hydration EVM legs on the neckwork explorer (Sourcify API).
# Companion to _verify.sh (Subscan) — same four targets per token:
# manager impl, transceiver impl, and the two ERC1967 proxies.
#
# Usage: _verify_sourcify.sh [token ...]
#   no args = every ops/tokens/* with a Hydration leg
#   _verify_sourcify.sh prime sui
#
# Env overrides:
#   VERIFIER      default sourcify
#   VERIFIER_URL  default https://hydration-explorer.neckwork.net/api/
#   WORKTREE      source tree, default this repo's evm/ (spoke legs deploy
#                 with --local, so this matches the deployed bytecode)
#   RPC           default .chains.Hydration.rpc from overrides.json
#
# FOUNDRY_VIA_IR=true — the CLI deploys with `forge script --via-ir`; the
# verification build must use identical compiler settings (see _verify.sh).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKTREE="${WORKTREE:-$REPO/evm}"
VERIFIER="${VERIFIER:-sourcify}"
VERIFIER_URL="${VERIFIER_URL:-https://hydration-explorer.neckwork.net/api/}"
RPC="${RPC:-$(jq -r '.chains.Hydration.rpc' "$REPO/overrides.json")}"
CHAIN=222222
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
[ -d "$WORKTREE" ] || { echo "ERROR: source tree not found: $WORKTREE"; exit 1; }

tokens=("$@")
if [ ${#tokens[@]} -eq 0 ]; then
  for d in "$REPO"/ops/tokens/*/deployment.json; do
    jq -e '.chains.Hydration' "$d" >/dev/null 2>&1 && tokens+=("$(basename "$(dirname "$d")")")
  done
fi

fail=0
verify() { # <address> <src/Path.sol:Contract>
  echo "--- $2 @ $1"
  (cd "$WORKTREE" && FOUNDRY_VIA_IR=true forge verify-contract "$1" "$2" \
    --chain-id "$CHAIN" --verifier "$VERIFIER" --verifier-url "$VERIFIER_URL") \
    || { echo "FAILED: $1 $2"; fail=1; }
}

for t in "${tokens[@]}"; do
  D="$REPO/ops/tokens/$t/deployment.json"
  MP=$(jq -r .chains.Hydration.manager "$D")
  TP=$(jq -r .chains.Hydration.transceivers.wormhole.address "$D")
  MI=$(cast parse-bytes32-address "$(cast storage "$MP" "$SLOT" --rpc-url "$RPC")")
  TI=$(cast parse-bytes32-address "$(cast storage "$TP" "$SLOT" --rpc-url "$RPC")")
  echo "== $t  manager $MP (impl $MI)  transceiver $TP (impl $TI)"
  verify "$MI" src/NttManager/NttManager.sol:NttManager
  verify "$TI" src/Transceiver/WormholeTransceiver/WormholeTransceiver.sol:WormholeTransceiver
  verify "$MP" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
  verify "$TP" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
done

exit $fail
