#!/usr/bin/env bash
set -euo pipefail

# Verify one contract on Hydration's EVM via Subscan.
# Shared by every token deploy — call directly once per contract.
#
# Usage: _verify.sh <address> <src/Path.sol:Contract> [compilerversion]
#   compilerversion defaults to v0.8.19+commit.7dd6d404 (evm/foundry.toml
#   pins solc 0.8.19).
#
# Four targets per spoke leg (addresses: proxies from deployment.json,
# implementations from the ERC1967 slot):
#
#   MP=$(jq -r .chains.Hydration.manager ops/tokens/<t>/deployment.json)
#   TP=$(jq -r .chains.Hydration.transceivers.wormhole.address ops/tokens/<t>/deployment.json)
#   SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
#   MI=$(cast parse-bytes32-address "$(cast storage $MP $SLOT --rpc-url <rpc>)")
#   TI=$(cast parse-bytes32-address "$(cast storage $TP $SLOT --rpc-url <rpc>)")
#
#   _verify.sh $MI src/NttManager/NttManager.sol:NttManager
#   _verify.sh $TI src/Transceiver/WormholeTransceiver/WormholeTransceiver.sol:WormholeTransceiver
#   _verify.sh $MP lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
#   _verify.sh $TP lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
#
# Spoke legs deploy with --local, so the default source tree is THIS repo's
# evm/ — override with WORKTREE for a tag-worktree deploy.
#
# The CLI deploys with `forge script --via-ir`; FOUNDRY_VIA_IR=true keeps the
# verification payload's compiler settings identical.
#
# The endpoint is x-www-form-urlencoded — a JSON request body is parsed as
# an empty form and answered with a bare {"message":"EOF"}. If a very large
# payload is ever rejected, retry with STRIP=1 (comment-strips the sources;
# costs the metadata hash → partial match).
#
# Required env: SUBSCAN_KEY  — from https://support.subscan.io/

SUBSCAN_KEY=${SUBSCAN_KEY:?Missing SUBSCAN_KEY}
ADDRESS=$1
CONTRACT=$2
COMPILER=${3:-v0.8.19+commit.7dd6d404}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKTREE="${WORKTREE:-$REPO/evm}"
[ -d "$WORKTREE" ] || { echo "ERROR: source tree not found: $WORKTREE"; exit 1; }

SUBSCAN_API="https://hydration.api.subscan.io/api/scan/evm/contract/verifysource"

# The endpoint is x-www-form-urlencoded — a JSON body parses as an empty
# form and comes back as a bare {"message":"EOF"}. Payload = forge's
# standard-json, sent verbatim (exact metadata match). STRIP=1 removes
# comments/blank lines first — fallback if a large payload gets rejected
# (costs the metadata hash → partial match).
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

(cd "$WORKTREE" && FOUNDRY_VIA_IR=true forge verify-contract "$ADDRESS" "$CONTRACT" \
  --chain 222222 --show-standard-json-input 2>/dev/null) | \
  STRIP="${STRIP:-0}" VIA_IR="${VIA_IR:-true}" python3 -c "
import json, os, re, sys

def strip(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in '\"\'':                    # string literal - copy verbatim
            q = c; out.append(c); i += 1
            while i < n:
                out.append(src[i])
                if src[i] == '\\\\': out.append(src[i+1]); i += 2; continue
                if src[i] == q: i += 1; break
                i += 1
        elif src.startswith('//', i):      # line comment
            while i < n and src[i] != '\n': i += 1
        elif src.startswith('/*', i):      # block comment
            i = src.find('*/', i) + 2
        else:
            out.append(c); i += 1
    s = ''.join(out)
    s = re.sub(r'[ \t]+\$', '', s, flags=re.M)
    s = re.sub(r'\n{2,}', '\n', s)
    return s

source = json.load(sys.stdin)
if os.environ.get('VIA_IR') == 'false':   # diagnostic only: can never verify (deployed bytecode is via-IR)
    source['settings']['viaIR'] = False
if os.environ.get('STRIP') == '1':
    for k in source['sources']:
        source['sources'][k]['content'] = strip(source['sources'][k]['content'])
    sys.stdout.write(json.dumps(source, separators=(',', ':')))
else:
    sys.stdout.write(json.dumps(source))
" > "$TMP"

echo "standard-json payload: $(wc -c < "$TMP" | tr -d ' ') bytes (STRIP=${STRIP:-0})"

curl -sS -D - \
  -w '\nHTTP %{http_code} | sent %{size_upload}B @ %{speed_upload}B/s | connect %{time_connect}s ttfb %{time_starttransfer}s total %{time_total}s\n' \
  -X POST "$SUBSCAN_API" \
  -H "X-API-Key: $SUBSCAN_KEY" \
  --data-urlencode "module=contract" \
  --data-urlencode "action=verifysourcecode" \
  --data-urlencode "contractaddress=$ADDRESS" \
  --data-urlencode "codeformat=solidity-standard-json-input" \
  --data-urlencode "contractname=$CONTRACT" \
  --data-urlencode "compilerversion=$COMPILER" \
  --data-urlencode "sourceCode@$TMP"
echo
