#!/usr/bin/env bash
set -euo pipefail

# Verify one contract on Etherscan, post-deploy (deploys run --skip-verify to
# keep them fast). Shared by every token deploy.
#
# Usage: _verify.sh <address> <src/Path.sol:Contract>
#   e.g. _verify.sh 0x804F… src/NttManager/NttManager.sol:NttManager
#        _verify.sh <proxy> lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
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
ADDRESS=$1
CONTRACT=$2
ETH_RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKTREE="${WORKTREE:-$REPO/.deployments/Evm-2.0.0/evm}"
[ -d "$WORKTREE" ] || { echo "ERROR: worktree not found: $WORKTREE"; exit 1; }

# CLI deploys with `forge script --via-ir` — verification must compile the same way.
cd "$WORKTREE" && FOUNDRY_VIA_IR=true forge verify-contract "$ADDRESS" "$CONTRACT" \
  --chain mainnet \
  --etherscan-api-key "$ETHEREUM_SCAN_API_KEY" \
  --guess-constructor-args \
  --rpc-url "$ETH_RPC" \
  --watch
