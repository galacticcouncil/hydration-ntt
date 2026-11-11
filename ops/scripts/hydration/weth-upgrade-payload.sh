#!/usr/bin/env bash
# WETH — upgrade the Hydration manager in place to NttManagerWithPayload
# (adds transferWithPayload; storage, peers, limits and owner are untouched).
#
# The proxy is owned by the TC emergency admin (0xAA7e…AA7E1), so the upgrade
# itself is a Technical Committee motion — nothing here can sign it:
#
#   technicalCommittee.propose(threshold,
#     dispatcher.dispatchAsEmergencyAdmin(
#       evm.call(admin, manager, upgrade(impl), 0, gasLimit, maxFee, None, None, [], [])),
#     lengthBound)
#
# Only the implementation deploy is signed here (HYDRATION_PRIVATE_KEY,
# whitelisted deployer). The motion's SCALE bytes come from WHM's probe
# (chopsticks/probes/_probeWethNttPayloadUpgrade.ts): it encodes them against
# live metadata, enacts them on a Hydration fork and sends a transfer and a
# transferWithPayload on both routes.
#
#   scripts/hydration/weth-upgrade-payload.sh preflight  # no txs: live manager, library, size, admin gas
#   scripts/hydration/weth-upgrade-payload.sh deploy     # TX: the implementation (via-IR), linked to
#                                                        #   the live TransceiverStructs library
#   scripts/hydration/weth-upgrade-payload.sh verify     # neckwork explorer (Sourcify API): the
#                                                        #   implementation + library — run right after deploy
#   scripts/hydration/weth-upgrade-payload.sh motion     # no txs: print the TC motion, then enact it on
#                                                        #   a fork via the WHM probe (NO_FORK=1 skips)
#   scripts/hydration/weth-upgrade-payload.sh check      # no txs: after enactment — impl, owner, immutables
#
# The deployed implementation is recorded in tokens/weth/payload-upgrade.json.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/weth/deployment.json"
RECORD="$HYD_ROOT/tokens/weth/payload-upgrade.json"
EVM_DIR="$NTT_SRC/evm"
WHM_DIR="${WHM_DIR:-$NTT_SRC/../../evm/whm}"
WHM_DIR="$(cd "$WHM_DIR" 2>/dev/null && pwd || echo "$WHM_DIR")"
PROBE="chopsticks/probes/_probeWethNttPayloadUpgrade.ts"

CONTRACT="src/NttManager/NttManagerWithPayload.sol:NttManagerWithPayload"
LIB_ID="src/libraries/TransceiverStructs.sol:TransceiverStructs"
# The library the live implementation links (7 link sites). Its code is
# identical to this tree's build, so the new implementation links it too.
LIB="${TRANSCEIVER_STRUCTS:-0x37745928d3e6fcc766ab965a3e3114c0b00d2745}"

# Hydration's explorer verifies through a Sourcify API (as _verify_sourcify.sh).
VERIFIER_URL="${VERIFIER_URL:-https://hydration-explorer.neckwork.net/api/}"

GOV=0xAA7e0000000000000000000000000000000AA7E1
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
# The probe's evm.call values. The emergency admin pays gasLimit × maxFee in
# WETH up front; short of it, the dispatch still returns Ok and the manager
# stays on the old implementation.
GAS_LIMIT=500000
MAX_FEE_WEI=10000000000
EIP170=24576
# Matches the user's build setup; forge 1.9.0 breaks this tree's test build.
FORGE_VERSION=1.5.1

manager() { jq -r '.chains.Hydration.manager' "$DEPLOYMENT"; }

impl_of() {
  cast parse-bytes32-address "$(cast storage "$1" "$IMPL_SLOT" --rpc-url "$HYDRATION_RPC")"
}

# token mode chainId rateLimitDuration — what upgrade() asserts unchanged.
immutables() {
  local a=$1 f out=()
  for f in 'token()(address)' 'mode()(uint8)' 'chainId()(uint16)' 'rateLimitDuration()(uint64)'; do
    out+=("$(cast call "$a" "$f" --rpc-url "$HYDRATION_RPC" | awk '{print $1}')")
  done
  echo "${out[*]}"
}

recorded_impl() {
  [ -s "$RECORD" ] || { echo "ERROR: no $RECORD — run 'deploy' first" >&2; exit 1; }
  jq -r .implementation "$RECORD"
}

lc() { tr '[:upper:]' '[:lower:]' <<< "$1"; }

ge() { python3 -c "import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)" "$1" "$2"; }

check_forge() {
  forge --version | head -1 | grep -q "$FORGE_VERSION" \
    || { echo "ERROR: forge $FORGE_VERSION required ($(forge --version | head -1)) — foundryup -u $FORGE_VERSION"; exit 1; }
}

check_owner() {
  local owner; owner=$(cast call "$(manager)" 'owner()(address)' --rpc-url "$HYDRATION_RPC")
  echo "owner: $owner"
  [ "$(lc "$owner")" = "$(lc "$GOV")" ] || { echo "ERROR: owner is not the TC emergency admin"; exit 1; }
}

# The live library must be byte-identical to this tree's (ignoring its
# address guard and metadata), or the linked implementation calls other code.
check_library() {
  local out=$1 live built
  live=$(cast code "$LIB" --rpc-url "$HYDRATION_RPC")
  built=$(jq -r '.deployedBytecode.object' "$out/TransceiverStructs.sol/TransceiverStructs.json")
  strip() { local s=${1#0x}; s=${s:42}; echo "${s%a264*}"; }
  [ "$live" != 0x ] && [ "$(strip "$live")" = "$(strip "$built")" ] \
    || { echo "ERROR: $LIB is not this tree's TransceiverStructs — set TRANSCEIVER_STRUCTS"; exit 1; }
  echo "TransceiverStructs $LIB: matches this tree"
}

# via-IR build into a temp dir: the CLI deploys via-IR, the default build is
# over EIP-170. Echoes the output dir.
build() {
  local out; out=$(mktemp -d)
  (cd "$EVM_DIR" && forge build --via-ir --out "$out" --cache-path "$out/cache" \
    src/NttManager/NttManagerWithPayload.sol >&2)
  local art="$out/NttManagerWithPayload.sol/NttManagerWithPayload.json" size links
  size=$(( ($(jq -r '.deployedBytecode.object' "$art" | wc -c) - 3) / 2 ))
  links=$(jq -r '.bytecode.linkReferences | to_entries[] | .key + ":" + (.value | keys[])' "$art")
  echo "NttManagerWithPayload runtime size: $size / $EIP170 bytes" >&2
  [ "$size" -le "$EIP170" ] || { echo "ERROR: over EIP-170" >&2; exit 1; }
  [ "$links" = "$LIB_ID" ] || { echo "ERROR: unexpected link references: $links" >&2; exit 1; }
  echo "$out"
}

cmd_preflight() {
  need_tools forge cast jq git python3
  check_forge
  local m impl; m=$(manager); impl=$(impl_of "$m")
  echo "== Hydration WETH manager $m =="
  check_owner
  echo "version: $(cast call "$m" 'NTT_MANAGER_VERSION()(string)' --rpc-url "$HYDRATION_RPC")"
  echo "paused: $(cast call "$m" 'isPaused()(bool)' --rpc-url "$HYDRATION_RPC")"
  echo "implementation: $impl"
  echo "immutables (token mode chainId rateLimitDuration): $(immutables "$m")"

  echo "== Build =="
  local out; out=$(build)
  check_library "$out"
  rm -rf "$out"

  echo "== TC emergency admin gas =="
  local bal reserve=$((GAS_LIMIT * MAX_FEE_WEI))
  bal=$(cast balance "$GOV" --rpc-url "$HYDRATION_RPC")
  echo "balance $(cast from-wei "$bal") WETH, the motion reserves $(cast from-wei "$reserve") WETH"
  ge "$bal" "$reserve" || echo "WARN: top up the emergency admin before the motion closes"

  if [ -n "${HYDRATION_PRIVATE_KEY:-}" ]; then
    use_key HYDRATION_PRIVATE_KEY
    local addr; addr=$(deployer)
    echo "== Deployer $addr: $(cast balance --ether "$addr" --rpc-url "$HYDRATION_RPC") WETH =="
    echo "(must hold an EVMAccounts.ContractDeployer slot)"
  fi
  [ ! -s "$RECORD" ] || echo "already deployed: $(recorded_impl) ($RECORD)"
}

cmd_deploy() {
  use_key HYDRATION_PRIVATE_KEY
  need_tools forge cast jq git python3
  check_forge
  [ ! -s "$RECORD" ] || { echo "ERROR: already deployed: $(recorded_impl) — delete $RECORD to redo"; exit 1; }
  [ -z "$(git -C "$NTT_SRC" status --porcelain -- evm)" ] \
    || { echo "ERROR: uncommitted changes under evm/ — the record pins HEAD, deploy a clean tree"; exit 1; }
  check_owner
  local out; out=$(build)
  check_library "$out"
  rm -rf "$out"

  local m; m=$(manager)
  read -r token mode chain duration <<< "$(immutables "$m")"
  local skip=false; [ "$duration" != 0 ] || skip=true
  echo "constructor: token=$token mode=$mode chainId=$chain rateLimitDuration=$duration skipRateLimiting=$skip"
  confirm "Deploy NttManagerWithPayload to HYDRATION mainnet (from $(git -C "$NTT_SRC" rev-parse --short HEAD))?"

  local res impl tx
  res=$(cd "$EVM_DIR" && forge create "$CONTRACT" --via-ir --broadcast --json \
    --libraries "$LIB_ID:$LIB" \
    --rpc-url "$HYDRATION_RPC" --private-key "$ETH_PRIVATE_KEY" \
    --constructor-args "$token" "$mode" "$chain" "$duration" "$skip")
  impl=$(jq -r .deployedTo <<< "$res")
  tx=$(jq -r .transactionHash <<< "$res")
  echo "implementation: $impl (tx $tx)"

  [ "$(immutables "$impl")" = "$(immutables "$m")" ] \
    || { echo "ERROR: implementation immutables differ from the manager's — upgrade() would revert"; exit 1; }

  jq -n --arg manager "$m" --arg previous "$(impl_of "$m")" --arg impl "$impl" --arg lib "$LIB" \
    --arg tx "$tx" --arg commit "$(git -C "$NTT_SRC" rev-parse HEAD)" \
    --arg token "$token" --arg mode "$mode" --arg chain "$chain" --arg duration "$duration" --arg skip "$skip" '{
      manager: $manager, previousImplementation: $previous, implementation: $impl,
      transceiverStructs: $lib, deployTx: $tx, commit: $commit,
      constructorArgs: { token: $token, mode: ($mode | tonumber), chainId: ($chain | tonumber),
        rateLimitDuration: ($duration | tonumber), skipRateLimiting: ($skip == "true") }
    }' > "$RECORD"
  echo "recorded in $RECORD — run 'verify' now, then 'motion'"
}

verified() { # <address> -> exact_match | match | NOT_VERIFIED
  curl -sS -m 15 "${VERIFIER_URL%/}/v2/contract/222222/$1" | jq -r '.match // "NOT_VERIFIED"'
}

# Submits unless already an exact match. Via-IR as deployed (the CLI and
# 'deploy' both build via-IR).
verify_one() { # <address> <src/Path.sol:Contract> [forge args...]
  local addr=$1 id=$2 s; shift 2
  s=$(verified "$addr")
  if [ "$s" = exact_match ]; then echo "$id @ $addr: already verified"; return 0; fi
  echo "--- $id @ $addr ($s)"
  (cd "$EVM_DIR" && FOUNDRY_VIA_IR=true forge verify-contract "$addr" "$id" \
    --chain-id 222222 --verifier sourcify --verifier-url "$VERIFIER_URL" "$@")
}

cmd_verify() {
  need_tools forge curl jq
  local impl; impl=$(recorded_impl)
  verify_one "$impl" "$CONTRACT" --libraries "$LIB_ID:$LIB"
  verify_one "$LIB" "$LIB_ID"
  echo "implementation $impl: $(verified "$impl")"
  echo "TransceiverStructs $LIB: $(verified "$LIB")"
  echo "explorer: ${VERIFIER_URL%/api/}/address/$impl"
}

cmd_motion() {
  need_tools cast jq python3
  local m impl current input gas bal reserve=$((GAS_LIMIT * MAX_FEE_WEI))
  m=$(manager); impl=${IMPL:-$(recorded_impl)}; current=$(impl_of "$m")
  check_owner
  [ "$(lc "$current")" != "$(lc "$impl")" ] || { echo "ERROR: $impl is already the implementation"; exit 1; }
  [ "$(immutables "$impl")" = "$(immutables "$m")" ] \
    || { echo "ERROR: $impl immutables differ from the manager's — upgrade() would revert"; exit 1; }

  input=$(cast calldata 'upgrade(address)' "$impl")
  gas=$(cast estimate --from "$GOV" "$m" 'upgrade(address)' "$impl" --rpc-url "$HYDRATION_RPC")
  [ "$gas" -lt "$GAS_LIMIT" ] || { echo "ERROR: upgrade needs $gas gas, the motion gives $GAS_LIMIT"; exit 1; }
  bal=$(cast balance "$GOV" --rpc-url "$HYDRATION_RPC")

  cat <<EOF
== TC motion: upgrade the Hydration WETH manager to NttManagerWithPayload ==

technicalCommittee.propose(threshold, proposal, lengthBound)
  threshold    TC majority: yes × 2 >= members (the probe reads Members live)
  proposal     dispatcher.dispatchAsEmergencyAdmin(
                 evm.call(
                   source                    $GOV
                   target                    $m   (WETH NttManager proxy)
                   input                     $input
                                             = upgrade($impl)
                   value                     0
                   gas_limit                 $GAS_LIMIT   (estimate $gas)
                   max_fee_per_gas           $MAX_FEE_WEI   (10 gwei)
                   max_priority_fee_per_gas  None
                   nonce                     None
                   access_list               []
                   authorization_list        []))

implementation  $current -> $impl
admin gas       $(cast from-wei "$bal") WETH, reserves $(cast from-wei "$reserve") WETH

After enactment: the manager emits Upgraded($impl); owner, peers,
limits and sequence are unchanged. Then run '$(basename "$0") check'.
EOF
  ge "$bal" "$reserve" || echo "WARN: the emergency admin cannot pay the reservation — top it up first"

  local cmd="npx tsx $PROBE --impl $impl"
  if [ "${NO_FORK:-0}" = 1 ]; then
    echo -e "\nSCALE bytes + fork enactment (WHM): cd $WHM_DIR && $cmd"
  elif [ -f "$WHM_DIR/$PROBE" ]; then
    echo -e "\n== SCALE bytes from live metadata + enactment on a Hydration fork (WHM probe) =="
    (cd "$WHM_DIR" && $cmd)
  else
    echo -e "\nERROR: WHM probe not found at $WHM_DIR/$PROBE — set WHM_DIR, or run there:\n  $cmd"
    exit 1
  fi
}

cmd_check() {
  local m impl now; m=$(manager); impl=$(recorded_impl); now=$(impl_of "$m")
  echo "implementation: $now"
  [ "$(lc "$now")" = "$(lc "$impl")" ] || { echo "ERROR: expected $impl — motion not enacted yet?"; exit 1; }
  check_owner
  echo "version: $(cast call "$m" 'NTT_MANAGER_VERSION()(string)' --rpc-url "$HYDRATION_RPC")"
  echo "paused: $(cast call "$m" 'isPaused()(bool)' --rpc-url "$HYDRATION_RPC")"
  echo "immutables: $(immutables "$m")"
  local sel; sel=$(cast sig 'transferWithPayload(uint256,uint16,bytes32,bytes)')
  cast code "$now" --rpc-url "$HYDRATION_RPC" | grep -q "63${sel#0x}" \
    || { echo "ERROR: $now has no transferWithPayload ($sel)"; exit 1; }
  echo "upgraded: transferWithPayload ($sel) is live on $m"
}

case "${1:-}" in
  preflight|deploy|verify|motion|check) "cmd_$1" "${@:2}" ;;
  *) sed -n '2,28p' "$0"; exit 1 ;;
esac
