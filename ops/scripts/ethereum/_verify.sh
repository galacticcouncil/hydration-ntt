#!/usr/bin/env bash
set -euo pipefail

# Verify one contract on Etherscan, post-deploy (deploys run --skip-verify to
# keep them fast). Shared by every token deploy.
#
# Usage: _verify.sh <address> <src/Path.sol:Contract>
#   e.g. _verify.sh 0x804F… src/NttManager/NttManager.sol:NttManager
#        _verify.sh <proxy> lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
#
#        _verify.sh link <proxy>   # (re)link an already-verified proxy to its impl
#
# Proxies are additionally LINKED to their implementation (verifyproxycontract)
# — source verification alone doesn't make Etherscan decode the proxy's events
# and reads with the impl ABI. CHAINID=8453 targets Base (same Etherscan v2 key).
#
# Same four targets per hub leg as the Hydration variant (proxies from
# deployment.json, implementations from the ERC1967 slot).
#
# --guess-constructor-args fetches the args from the creation tx via RPC —
# needed for the proxies (impl address + init calldata).
#
# forge runs from the version-tag worktree that produced the deployed
# bytecode (NOT repo HEAD) — override with WORKTREE if the tag differs.
#
# Required env: ETHEREUM_SCAN_API_KEY. Optional: ETH_RPC_URL.

ETHEREUM_SCAN_API_KEY=${ETHEREUM_SCAN_API_KEY:?Missing ETHEREUM_SCAN_API_KEY}
CHAINID="${CHAINID:-1}"

link_proxy() {
  local guid status
  guid=$(curl -sS "https://api.etherscan.io/v2/api?chainid=$CHAINID" \
    -d module=contract -d action=verifyproxycontract -d address="$1" \
    -d apikey="$ETHEREUM_SCAN_API_KEY" | jq -r .result)
  echo "proxy link submitted: $guid"
  for _ in 1 2 3 4 5; do
    sleep 5
    status=$(curl -sS "https://api.etherscan.io/v2/api?chainid=$CHAINID" \
      -d module=contract -d action=checkproxyverification -d guid="$guid" \
      -d apikey="$ETHEREUM_SCAN_API_KEY" | jq -r .result)
    echo "  $status"
    case "$status" in *"successfully updated"*|*"already"*) return 0 ;; *Pending*) ;; *) return 1 ;; esac
  done
}

if [ "${1:-}" = "link" ]; then link_proxy "${2:?usage: _verify.sh link <proxy-address>}"; exit; fi

ADDRESS=$1
CONTRACT=$2
ETH_RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKTREE="${WORKTREE:-$REPO/.deployments/Evm-2.0.0/evm}"
[ -d "$WORKTREE" ] || { echo "ERROR: worktree not found: $WORKTREE"; exit 1; }

# CLI deploys with `forge script --via-ir` — verification must compile the same way.
# LIBRARIES (path:Name:address) is required for impls linked against an external
# library (TransceiverStructs). NOTE: deploys compile with EMPTY settings.libraries
# (forge script links post-compilation), so a --libraries build differs in the
# metadata tail → forge's local pre-check for --guess-constructor-args fails.
# For those, pass CONSTRUCTOR_ARGS (cast abi-encode 'constructor(...)' …) to skip
# the guess; args are recorded in the broadcast run-*.json ("arguments").
# Etherscan then verifies as a partial match (metadata differs, code identical).
if [ -n "${CONSTRUCTOR_ARGS:-}" ]; then
  ARGS_FLAGS=(--constructor-args "$CONSTRUCTOR_ARGS")
else
  ARGS_FLAGS=(--guess-constructor-args)
fi
# FORCE=1 skips forge's already-verified pre-check — needed when Etherscan shows
# only a "Similar Match" (auto-matched clone): forge treats that as verified,
# but it attaches no ABI to the address, so proxy linking stays broken.
cd "$WORKTREE" && FOUNDRY_VIA_IR=true forge verify-contract "$ADDRESS" "$CONTRACT" \
  --chain mainnet \
  --etherscan-api-key "$ETHEREUM_SCAN_API_KEY" \
  "${ARGS_FLAGS[@]}" \
  --rpc-url "$ETH_RPC" \
  ${LIBRARIES:+--libraries "$LIBRARIES"} \
  ${FORCE:+--skip-is-verified-check} \
  --watch

case "$CONTRACT" in
  *ERC1967Proxy*) link_proxy "$ADDRESS" ;;
esac
