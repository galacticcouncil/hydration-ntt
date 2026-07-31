#!/usr/bin/env bash
# Hydration-leg handover to governance (0xAA7e…AA7E1, the Aave-manager
# account dispatched via dispatch_as_aave_manager) — one token per run:
#
#   ops/scripts/hydration/handover.sh <token>      # or: T=<token> …/handover.sh
#
# pauser fields → push → transfer-ownership (IRREVERSIBLE, CLI re-confirms)
# → pull + git add. A ❌ "verification failed" after the transfer can be a
# stale RPC read — the receipt's two OwnershipTransferred events are the truth.
set -euo pipefail

T="${T:-${1:?usage: $0 <token>   (or T=<token> $0)}}"
GOV=0xAA7e0000000000000000000000000000000AA7E1

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root: paths + overrides.json
D=ops/tokens/$T/deployment.json
[ -s "$D" ] || { echo "ERROR: $D not found"; exit 1; }
: "${HYDRATION_PRIVATE_KEY:?HYDRATION_PRIVATE_KEY not set}"

# 1. both pauser fields in the file
jq --arg p "$GOV" '.chains.Hydration.pauser = $p
  | .chains.Hydration.transceivers.wormhole.pauser = $p' "$D" > "$D.tmp" && mv "$D.tmp" "$D"

# 2. review the diff — only the two Hydration pausers should show
ntt status -p "$D" || true
read -r -p "Diff above only the two Hydration pausers? push + transfer owner? [yes/NO] " r
[ "$r" = yes ] || { echo "aborted (file edit kept — git checkout $D to undo)"; exit 1; }

ETH_PRIVATE_KEY=$HYDRATION_PRIVATE_KEY ntt push --only-chain Hydration -p "$D"

# 3. owner — irreversible; the CLI triple-checks the destination
ETH_PRIVATE_KEY=$HYDRATION_PRIVATE_KEY ntt transfer-ownership Hydration --destination "$GOV" -p "$D"

# 4. resync audit record
ntt pull --yes -p "$D"
git add "$D"
echo "done: $T — review 'git diff --cached -- $D' and commit"
