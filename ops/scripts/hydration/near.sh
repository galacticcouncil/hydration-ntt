#!/usr/bin/env bash
# NEAR — spoke leg: Hydration, burning mode. PRECOMPILE VARIANT: runtime asset
# 1001358 "NEAR (Wormhole)" (24 dec, register_external + TC update) at the
# currencies precompile 0x…01000f478e. Minter binding = EVMAccounts.set_ntt_minter
# (governance).
#
# The hub is NEAR (chain 15): wrap.near locked in the NEAR NTT contract
# (whm repo, migration near-ntt-near). The ntt CLI has no NEAR support, so this
# deployment.json only carries the Hydration leg, and the peering to NEAR is
# done here with cast. One NEAR contract is manager AND transceiver: both
# Hydration peers point at the same 32-byte address = sha256(<ntt account id>),
# which is also its Wormhole emitter. Pass the account id to 'peer' — the
# emitter is derived here, and the account is checked on NEAR RPC.
#
# Order (both sides deploy independently, peering needs the other's addresses):
#   NEAR  near-ntt-near 001–003           NEAR contract, emitter registered, storage
#   here  init / asset / deploy / limits
#   here  print-env                      -> HYDRATION_* for the NEAR migration (step 004)
#   NEAR  near-ntt-near 004               NEAR -> Hydration peer
#   here  peer <ntt-account>             Hydration -> NEAR peer
#
#   scripts/hydration/near.sh preflight             # no txs: CLI, balance
#   scripts/hydration/near.sh init                  # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/hydration/near.sh asset [id]            # no txs: derive+verify precompile ref (default 1001358)
#   scripts/hydration/near.sh deploy                # TX: manager+transceiver (burning), --skip-verify
#                                                  #   (verify post-hoc: scripts/hydration/_verify_sourcify.sh near)
#   scripts/hydration/near.sh limits                # TX Hydration: setOutboundLimit(LIMIT_OUT) — canary, == NEAR_INBOUND_LIMIT
#   scripts/hydration/near.sh print-env             # no txs: HYDRATION_* lines for the NEAR migration env
#   scripts/hydration/near.sh peer <ntt-account>    # TX Hydration: setPeer(15) + setWormholePeer(15) — wormhole peer SET-ONCE
#
#   scripts/hydration/near.sh pull-near <ntt-account> # no txs: record the NEAR hub in deployment.json (.external.Near)
#   scripts/hydration/near.sh minter                # no txs: print go-live governance calls
#   scripts/hydration/near.sh status [ntt-account]  # read-only: peers + capacities (+ expected emitter)
#
# Env overrides: NEAR_DECIMALS (NEAR-side token decimals, default 24 for
# wrap.near), NEAR_RPC, LIMIT_OUT / LIMIT_IN (canary, must match whm).
# Ownership handover (scripts/hydration/_handover.sh near) only after smoke tests.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

T=near
SYM=NEAR
DEPLOYMENT="$HYD_ROOT/tokens/$T/deployment.json"
TOKEN_ADDR_FILE="$HYD_ROOT/tokens/$T/hydration-token.addr"
ASSET_ID_DEFAULT=1001358
HYD_DECIMALS=24
NEAR_DECIMALS="${NEAR_DECIMALS:-24}"
NEAR_TOKEN=wrap.near
NEAR_RPC="${NEAR_RPC:-https://free.rpc.fastnear.com}"
CHAIN_NEAR=15

# 24h NTT rate limits, whole NEAR — canary, MUST MATCH the NEAR side
# (whm near-ntt-near.env), raised together later:
#   LIMIT_OUT (Hydration outbound)       == NEAR_INBOUND_LIMIT
#   LIMIT_IN  (Hydration inbound from 15) == NEAR_OUTBOUND_LIMIT
# The registry xcm_rate_limit mint fuse must be >= LIMIT_IN.
LIMIT_OUT="${LIMIT_OUT:-1000}"
LIMIT_IN="${LIMIT_IN:-1000}"

spoke_manager() { jq -r '.chains.Hydration.manager // empty' "$DEPLOYMENT" 2>/dev/null || true; }
spoke_xcvr()    { jq -r '.chains.Hydration.transceivers.wormhole.address // empty' "$DEPLOYMENT" 2>/dev/null || true; }
b32()           { printf '0x%064s' "${1#0x}" | tr ' ' '0' | tr 'A-F' 'a-f'; }
raw()           { printf '%s%0*d' "$1" "$2" 0; }   # <whole> <decimals> -> raw integer string
emitter_of()    { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }   # NEAR account id -> sha256 hex

# Account must exist on NEAR and carry a contract (code_hash != all-ones).
check_near_account() {
  local r code
  r=$(curl -sS -m 15 -X POST "$NEAR_RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"query\",\"params\":{\"request_type\":\"view_account\",\"finality\":\"final\",\"account_id\":\"$1\"}}")
  code=$(echo "$r" | jq -r '.result.code_hash // empty')
  [ -n "$code" ] || { echo "ERROR: NEAR account $1 not found ($(echo "$r" | jq -c '.error // .' | head -c 200))"; exit 1; }
  [ "$code" != "11111111111111111111111111111111" ] || { echo "ERROR: NEAR account $1 has no contract deployed"; exit 1; }
  echo "NEAR account $1: contract code_hash $code"
}

# NEAR view call -> raw JSON result (contract returns JSON bytes).
near_view() { # <account> <method> [args-json]
  local args; args=$(printf '%s' "${3:-{\}}" | base64 | tr -d '\n')
  curl -sS -m 15 -X POST "$NEAR_RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"query\",\"params\":{\"request_type\":\"call_function\",\"finality\":\"final\",\"account_id\":\"$1\",\"method_name\":\"$2\",\"args_base64\":\"$args\"}}" \
    | jq -r 'if .result.result then (.result.result | implode) else error("view \(.error // .result.error // .)") end'
}
cmp_int() { python3 -c "import sys; a,b=int(sys.argv[1]),int(sys.argv[2]); print('gt' if a>b else 'lt' if a<b else 'eq')" "$1" "$2"; }

cmd_preflight() {
  use_key HYDRATION_PRIVATE_KEY
  need_tools ntt cast jq git curl shasum
  check_cli
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Hydration balance: $(cast balance --ether "$addr" --rpc-url "$HYDRATION_RPC")"
}

cmd_asset() {
  local id="${1:-$ASSET_ID_DEFAULT}"
  need_tools cast jq
  [ ! -s "$TOKEN_ADDR_FILE" ] \
    || { echo "already set: $(cat "$TOKEN_ADDR_FILE") (delete $TOKEN_ADDR_FILE to redo)"; exit 0; }
  local addr sym dec
  addr="0x00000000000000000000000000000001$(printf '%08x' "$id")"
  echo "asset id $id → precompile $addr"
  sym=$(cast call "$addr" 'symbol()(string)' --rpc-url "$HYDRATION_RPC") \
    || { echo "ERROR: precompile call failed — is asset $id registered?"; exit 1; }
  dec=$(cast call "$addr" 'decimals()(uint8)' --rpc-url "$HYDRATION_RPC")
  echo "symbol=$sym decimals=$dec"
  [ "$dec" = "$HYD_DECIMALS" ] || { echo "ERROR: decimals $dec != $HYD_DECIMALS"; exit 1; }
  confirm "Use this asset as the $SYM representation?"
  mkdir -p "$(dirname "$TOKEN_ADDR_FILE")"
  echo "$addr" > "$TOKEN_ADDR_FILE"
  echo "saved to $TOKEN_ADDR_FILE"
}

asset_id() { local a; a=$(cat "$TOKEN_ADDR_FILE"); echo $((16#${a: -8})); }

cmd_deploy() {
  use_key HYDRATION_PRIVATE_KEY
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  # --local: compiles from this repo's tree (codeless-precompile fix in DeployWormholeNtt.s.sol)
  confirm "Deploy NTT manager+transceiver (BURNING $SYM) to HYDRATION mainnet (from local tree)?"
  (cd "$NTT_SRC" && ntt add-chain Hydration --local --mode burning \
    --token "$(cat "$TOKEN_ADDR_FILE")" --skip-verify -p "$DEPLOYMENT")
  echo "Verify NOW: ops/scripts/hydration/_verify_sourcify.sh $T"
  echo "Then: scripts/hydration/$T.sh print-env  → into the NEAR migration env (near-ntt-$T.env)"
}

# Hydration outbound limit (deploy leaves the CLI default = unlimited). Owner tx,
# re-runnable; also records it in deployment.json. Inbound is set by 'peer'.
cmd_limits() {
  use_key HYDRATION_PRIVATE_KEY
  local M; M=$(spoke_manager)
  [ -n "$M" ] || { echo "ERROR: no Hydration leg — run 'deploy' first"; exit 1; }
  echo "manager.setOutboundLimit($LIMIT_OUT $SYM)   <- must equal whm NEAR_INBOUND_LIMIT"
  confirm "Set the Hydration outbound limit?"
  cast send "$M" 'setOutboundLimit(uint256)' "$(raw "$LIMIT_OUT" "$HYD_DECIMALS")" \
    --private-key "$ETH_PRIVATE_KEY" --rpc-url "$HYDRATION_RPC"
  jq --arg o "$LIMIT_OUT.$(printf '%0*d' "$HYD_DECIMALS" 0)" '.chains.Hydration.limits.outbound = $o' \
    "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  cmd_status
}

# Lines for the NEAR migration env — its step 004 peers the NEAR contract with these.
cmd_print_env() {
  [ -n "$(spoke_manager)" ] || { echo "ERROR: no Hydration leg — run 'deploy' first"; exit 1; }
  echo "HYDRATION_NTT_MANAGER=$(spoke_manager)"
  echo "HYDRATION_NTT_TRANSCEIVER=$(spoke_xcvr)"
  echo "HYDRATION_TOKEN_DECIMALS=$HYD_DECIMALS"
}

# Hydration-side half of the cross-link, manual (CLI can't peer NEAR).
# setPeer is re-runnable; setWormholePeer is SET-ONCE.
cmd_peer() {
  local acct="${1:?usage: $T.sh peer <ntt-account>   e.g. ntt-$T.<deployer>.near}"
  use_key HYDRATION_PRIVATE_KEY
  need_tools cast jq curl shasum
  local M X E
  M=$(spoke_manager); X=$(spoke_xcvr)
  [ -n "$M" ] || { echo "ERROR: no Hydration leg — run 'deploy' first"; exit 1; }
  check_near_account "$acct"
  E=$(emitter_of "$acct")
  echo "emitter = sha256(\"$acct\") = 0x$E   NEAR-side decimals $NEAR_DECIMALS"
  echo "manager.setPeer($CHAIN_NEAR, $(b32 "$E"), $NEAR_DECIMALS, $LIMIT_IN $SYM)   <- inbound == NEAR_OUTBOUND_LIMIT"
  echo "xcvr.setWormholePeer($CHAIN_NEAR, $(b32 "$E"))  <- SET-ONCE, check the account id"
  confirm "Send the Hydration-side peering txs?"
  cast send "$M" 'setPeer(uint16,bytes32,uint8,uint256)' $CHAIN_NEAR "$(b32 "$E")" "$NEAR_DECIMALS" "$(raw "$LIMIT_IN" "$HYD_DECIMALS")" \
    --private-key "$ETH_PRIVATE_KEY" --rpc-url "$HYDRATION_RPC"
  if [ "$(cast call "$X" 'getWormholePeer(uint16)(bytes32)' $CHAIN_NEAR --rpc-url "$HYDRATION_RPC" | tr 'A-F' 'a-f')" = "$(b32 "$E")" ]; then
    echo "wormhole peer already set, skipping (set-once)"
  else
    cast send "$X" 'setWormholePeer(uint16,bytes32)' $CHAIN_NEAR "$(b32 "$E")" \
      --private-key "$ETH_PRIVATE_KEY" --rpc-url "$HYDRATION_RPC"
  fi
  cmd_status "$acct"
}

# Record the NEAR hub under .external.Near (NOT .chains — the ntt CLI would try
# to fetch it and pull/status/_handover would fail; top-level keys survive CLI
# rewrites). Same field names as the CLI ChainConfig; one NEAR contract is both
# manager and transceiver. limits = the configured canary (must match whm),
# checked against the on-chain capacities.
cmd_pull_near() {
  local acct="${1:?usage: $T.sh pull-near <ntt-account>   e.g. ntt-$T.<deployer>.near}"
  need_tools jq curl shasum python3
  local M X; M=$(spoke_manager); X=$(spoke_xcvr)
  [ -n "$M" ] || { echo "ERROR: no Hydration leg in $DEPLOYMENT"; exit 1; }
  check_near_account "$acct"
  local owner pending paused token emitter peer outcap incap uni
  owner=$(near_view "$acct" owner | jq -r .)
  pending=$(near_view "$acct" pending_owner)
  paused=$(near_view "$acct" is_paused)
  token=$(near_view "$acct" token | jq -r .)
  emitter=$(near_view "$acct" emitter | jq -r .)
  peer=$(near_view "$acct" get_peer '{"chain_id":73}')
  outcap=$(near_view "$acct" outbound_capacity | jq -r .)
  incap=$(near_view "$acct" inbound_capacity '{"chain_id":73}' | jq -r '. // "0"')
  uni=$(b32 "$(emitter_of "$acct")")

  local warn=0
  w() { echo "WARN: $*"; warn=1; }
  [ "$(b32 "$emitter")" = "$uni" ] || w "contract emitter $emitter != sha256(\"$acct\")"
  [ "$token" = "$NEAR_TOKEN" ] || w "NEAR token $token != expected $NEAR_TOKEN"
  [ "$peer" != "null" ] || w "NEAR contract has no Hydration peer (chain 73)"
  if [ "$peer" != "null" ]; then
    [ "$(b32 "$(echo "$peer" | jq -r .manager)")" = "$(b32 "$M")" ] || w "NEAR peer manager $(echo "$peer" | jq -r .manager) != Hydration manager $M"
    [ "$(b32 "$(echo "$peer" | jq -r .transceiver)")" = "$(b32 "$X")" ] || w "NEAR peer transceiver $(echo "$peer" | jq -r .transceiver) != Hydration transceiver $X"
    [ "$(echo "$peer" | jq -r .decimals)" = "$HYD_DECIMALS" ] || w "NEAR peer decimals $(echo "$peer" | jq -r .decimals) != Hydration $HYD_DECIMALS"
  fi
  # NEAR outbound == Hydration inbound (LIMIT_IN); NEAR inbound == Hydration outbound (LIMIT_OUT)
  local lo li
  lo=$(raw "$LIMIT_IN" "$NEAR_DECIMALS"); li=$(raw "$LIMIT_OUT" "$NEAR_DECIMALS")
  case "$(cmp_int "$outcap" "$lo")" in
    gt) w "NEAR outbound capacity $outcap > configured $lo — NEAR limit differs from LIMIT_IN" ;;
    lt) echo "note: NEAR outbound capacity $outcap < limit $lo (transfers in the last 24h)" ;;
  esac
  case "$(cmp_int "$incap" "$li")" in
    gt) w "NEAR inbound(73) capacity $incap > configured $li — NEAR limit differs from LIMIT_OUT" ;;
    lt) echo "note: NEAR inbound(73) capacity $incap < limit $li (transfers in the last 24h)" ;;
  esac

  local frac; frac=$(printf '%0*d' "$NEAR_DECIMALS" 0)
  jq --arg acct "$acct" --arg owner "$owner" --argjson pending "$pending" --argjson paused "$paused" \
     --arg token "$token" --arg uni "$uni" --argjson peer "$peer" \
     --arg lo "$LIMIT_IN.$frac" --arg li "$LIMIT_OUT.$frac" '
    .external.Near = {
      chainId: 15,
      mode: "locking",
      paused: $paused,
      owner: $owner,
      pendingOwner: $pending,
      manager: $acct,
      token: $token,
      transceivers: { threshold: 1, wormhole: { address: $acct } },
      limits: { outbound: $lo, inbound: { Hydration: $li } },
      universalAddress: $uni,
      peers: { Hydration: (if $peer == null then null else {
        manager: ("0x" + ($peer.manager | ltrimstr("0x"))),
        transceiver: ("0x" + ($peer.transceiver | ltrimstr("0x"))),
        decimals: $peer.decimals } end) }
    }' "$DEPLOYMENT" > "$DEPLOYMENT.tmp" && mv "$DEPLOYMENT.tmp" "$DEPLOYMENT"
  jq '.external.Near' "$DEPLOYMENT"
  [ "$warn" = 0 ] && echo "external.Near written — consistent with the Hydration leg" \
                  || echo "external.Near written WITH WARNINGS (see above)"
}

cmd_minter() {
  [ -s "$TOKEN_ADDR_FILE" ] || { echo "ERROR: run 'asset' first"; exit 1; }
  local id manager; id=$(asset_id); manager=$(spoke_manager)
  [ -n "$manager" ] || { echo "ERROR: no Hydration manager — run 'deploy' first"; exit 1; }
  cat <<EOF
Go-live (referendum — TC whitelist + whitelisted_caller, as HYPE/SPY):

  CircuitBreaker.set_asset_category($id, External)
  AssetRegistry.update($id, name: <without "(Wormhole)">, xcm_rate_limit: <>= \$100k/day, >= NEAR inbound limit>)
  EVMAccounts.set_ntt_minter($id, $manager)

Emergency unbind: EVMAccounts.clear_ntt_minter($id)
Verify after enactment: EVMAccounts.NttMinters($id) == $manager
EOF
}

cmd_status() {
  local M X; M=$(spoke_manager); X=$(spoke_xcvr)
  [ -n "$M" ] || { echo "no Hydration leg yet"; return 0; }
  echo "== Hydration ($T)  manager $M  transceiver $X"
  echo "peer(15):   $(cast call "$M" 'getPeer(uint16)((bytes32,uint8))' $CHAIN_NEAR --rpc-url "$HYDRATION_RPC")"
  echo "whPeer(15): $(cast call "$X" 'getWormholePeer(uint16)(bytes32)' $CHAIN_NEAR --rpc-url "$HYDRATION_RPC")"
  echo "out cap:    $(cast call "$M" 'getCurrentOutboundCapacity()(uint256)' --rpc-url "$HYDRATION_RPC")"
  echo "in cap(15): $(cast call "$M" 'getCurrentInboundCapacity(uint16)(uint256)' $CHAIN_NEAR --rpc-url "$HYDRATION_RPC")"
  echo "token/mode: $(cast call "$M" 'token()(address)' --rpc-url "$HYDRATION_RPC") $(cast call "$M" 'getMode()(uint8)' --rpc-url "$HYDRATION_RPC")"
  [ -z "${1:-}" ] || echo "expected NEAR peer (sha256 \"$1\"): $(b32 "$(emitter_of "$1")")"
}

case "${1:-}" in
  preflight|init|asset|deploy|limits|peer|minter|status) "cmd_$1" "${@:2}" ;;
  print-env) cmd_print_env ;;
  pull-near) cmd_pull_near "${@:2}" ;;
  *) sed -n '2,/^$/p' "$0"; exit 1 ;;
esac
