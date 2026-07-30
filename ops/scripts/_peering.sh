#!/usr/bin/env bash
# Cross-check on-chain wiring vs deployment.json for every EVM<->EVM token.
# Read-only (cast call) — no keys, no txs. Per token, both directions:
#
#   manager.token()        == deployment token
#   manager.getMode()      == locking(0) on the hub / burning(1) on Hydration
#   manager.getPeer(peerChainId)          == peer manager (bytes32) + peer token decimals
#   transceiver.getWormholePeer(peerId)   == peer transceiver (bytes32)
#   manager.getTransceivers()             includes own transceiver
#
# Chain IDs are discovered from the managers themselves (chainId()); Solana's
# is the fixed wormhole id 1. An unset peer reads as 0x00…00 → FAIL = that
# side not pushed.
#
# Solana-hub tokens are checked in BOTH directions: the Hydration side via
# cast (peers = base58-decoded Solana manager / transceiver, peer decimals via
# Solana RPC getTokenSupply), the Solana side by deriving the peer PDAs
# (["peer"/"transceiver_peer", chainId BE] — seeds from solana/…/peer.rs) and
# reading them over JSON-RPC, no solana CLI needed.
#
# The EVM hub chain is read from deployment.json (Ethereum, Base, …) — its
# RPC comes from hub_rpc() below; add a line there when a new hub chain lands.
#
# Usage: scripts/_peering.sh [token ...]   # default: every tokens/<t>/deployment.json

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

need_tools cast jq curl python3
FAIL=0
SOL_WH_ID=1   # wormhole chain id of Solana (fixed, not discoverable from the EVM side)

b32()   { printf '0x%064s' "${1#0x}" | tr ' ' '0'; }   # EVM address → wormhole bytes32
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
call()  { cast call "$1" "$2" "${@:4}" --rpc-url "$3" 2>/dev/null || echo CALL_FAILED; }

b58_32() {  # Solana base58 address → wormhole bytes32
  python3 - "$1" <<'PY'
import sys
A='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
n=0
for c in sys.argv[1]: n=n*58+A.index(c)
print('0x'+n.to_bytes(32,'big').hex())
PY
}

sol_rpc() {  # method params-json → response
  curl -sS "$SOLANA_RPC" -X POST -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" 2>/dev/null
}

# Derive + read the Solana-side peer PDAs (seeds/layouts from this repo's
# solana/…/peer.rs: ["peer", u16 BE] and ["transceiver_peer", u16 BE], anchor
# data = disc(8) + bump(1) + address(32) [+ token_decimals(1)]).
# Prints two lines: "<manager peer hex>,<decimals>" and "<transceiver peer hex>".
sol_side_peers() {  # program_id_b58 peer_chain_id
  python3 - "$1" "$2" "$SOLANA_RPC" <<'PY'
import sys, json, hashlib, base64, urllib.request
A='123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
def b58d(s):
    n=0
    for c in s: n=n*58+A.index(c)
    return n.to_bytes(32,'big')
def b58e(b):
    n=int.from_bytes(b,'big'); out=''
    while n: n,r=divmod(n,58); out=A[r]+out
    return '1'*(len(b)-len(b.lstrip(b'\0')))+out
P=2**255-19
D=(-121665*pow(121666,P-2,P))%P
def on_curve(b):  # RFC 8032 point decompression succeeds ⇒ on curve
    y=int.from_bytes(b,'little'); sign=y>>255; y&=(1<<255)-1
    if y>=P: return False
    y2=y*y%P; u=(y2-1)%P; v=(D*y2+1)%P
    x2=u*pow(v,P-2,P)%P
    x=pow(x2,(P+3)//8,P)
    if (x*x-x2)%P: x=x*pow(2,(P-1)//4,P)%P
    if (x*x-x2)%P: return False
    return not (x==0 and sign)
def pda(seeds, prog):  # find_program_address: first OFF-curve candidate, bump 255→0
    for bump in range(255,-1,-1):
        h=hashlib.sha256(b''.join(seeds)+bytes([bump])+prog+b'ProgramDerivedAddress').digest()
        if not on_curve(h): return h
    sys.exit('no pda')
prog=b58d(sys.argv[1]); cid=int(sys.argv[2]).to_bytes(2,'big')
mp, tp = pda([b'peer',cid],prog), pda([b'transceiver_peer',cid],prog)
req=json.dumps({'jsonrpc':'2.0','id':1,'method':'getMultipleAccounts',
                'params':[[b58e(mp),b58e(tp)],{'encoding':'base64'}]}).encode()
r=json.load(urllib.request.urlopen(urllib.request.Request(sys.argv[3],req,{'Content-Type':'application/json'})))
for i,v in enumerate(r['result']['value']):
    if v is None: print('PEER_PDA_MISSING'); continue
    d=base64.b64decode(v['data'][0])
    print('0x'+d[9:41].hex()+(','+str(d[41]) if i==0 else ''))
PY
}

ck() { # label want got
  if [ "$(lower "$2")" = "$(lower "$3")" ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n        want %s\n        got  %s\n' "$1" "$2" "$3"
    FAIL=1
  fi
}

# manager.getPeer(id) returns (bytes32 peerAddress, uint8 tokenDecimals)
peer_of() { call "$1" 'getPeer(uint16)((bytes32,uint8))' "$3" "$2" | tr -d '() '; }

# Solana-hub token: full Hydration-side check + Solana program sanity. The
# Solana-side peer PDAs (borsh accounts) are ntt status territory.
check_sol_hub() {
  local t=$1 dep=$2 hm=$3
  local sm st stok ht htok
  sm=$(jq -r '.chains.Solana.manager // empty' "$dep")
  [ -n "$sm" ] || { echo "== $t: no Ethereum or Solana leg — skipping"; return; }
  st=$(jq -r '.chains.Solana.transceivers.wormhole.address' "$dep")
  stok=$(jq -r '.chains.Solana.token' "$dep")
  ht=$(jq -r '.chains.Hydration.transceivers.wormhole.address' "$dep")
  htok=$(jq -r '.chains.Hydration.token' "$dep")

  local hyd_id sdec hdec
  hyd_id=$(call "$hm" 'chainId()(uint16)' "$HYDRATION_RPC")
  sdec=$(sol_rpc getTokenSupply "[\"$stok\"]" | jq -r '.result.value.decimals // "RPC_FAILED"')
  hdec=$(call "$htok" 'decimals()(uint8)' "$HYDRATION_RPC")
  echo "== $t  (Solana hub; wormhole chain ids: Solana=$SOL_WH_ID Hydration=$hyd_id)"

  ck "Hydration manager token ($hdec dec)" "$htok" "$(call "$hm" 'token()(address)' "$HYDRATION_RPC")"
  ck "Hydration manager mode = burning(1)" 1 "$(call "$hm" 'getMode()(uint8)' "$HYDRATION_RPC")"
  local p; p=$(peer_of "$hm" "$SOL_WH_ID" "$HYDRATION_RPC")
  ck "Hydration manager peer → Solana manager ($sdec dec mint)" "$(b58_32 "$sm"),$sdec" "$p"
  ck "Hydration transceiver peer → Solana transceiver" "$(b58_32 "$st")" \
     "$(call "$ht" 'getWormholePeer(uint16)(bytes32)' "$HYDRATION_RPC" "$SOL_WH_ID")"
  case "$(lower "$(call "$hm" 'getTransceivers()(address[])' "$HYDRATION_RPC")")" in
    *"$(lower "${ht#0x}")"*) ck "Hydration manager registers its transceiver" x x ;;
    *) ck "Hydration manager registers its transceiver" "$ht" "not in getTransceivers()" ;;
  esac
  ck "Solana NTT program executable" true \
     "$(sol_rpc getAccountInfo "[\"$sm\",{\"encoding\":\"base64\"}]" | jq -r '.result.value.executable // "RPC_FAILED"')"

  # Solana side: read the actual peer PDAs
  local speer tpeer
  { read -r speer; read -r tpeer; } < <(sol_side_peers "$sm" "$hyd_id" || echo -e "DERIVE_FAILED\nDERIVE_FAILED")
  ck "Solana manager peer PDA → Hydration manager" "$(b32 "$hm"),$hdec" "$speer"
  ck "Solana transceiver peer PDA → Hydration transceiver" "$(b32 "$ht")" "$tpeer"
}

hub_rpc() {  # EVM hub chain name → RPC url (extend when a new hub chain lands)
  case "$1" in
    Ethereum) echo "$ETH_RPC" ;;
    Base)     echo "$BASE_RPC" ;;
    *) return 1 ;;
  esac
}

check_token() {
  local t=$1 dep="$HYD_ROOT/tokens/$1/deployment.json"
  [ -f "$dep" ] || { echo "== $t: no deployment.json — skipping"; return; }
  local hub hm
  hm=$(jq -r '.chains.Hydration.manager // empty' "$dep")
  [ -n "$hm" ] || { echo "== $t: no Hydration leg — skipping"; return; }
  hub=$(jq -r '.chains | keys[] | select(. != "Hydration")' "$dep" | head -1)
  [ -n "$hub" ] || { echo "== $t: no hub leg — skipping"; return; }
  if [ "$hub" = "Solana" ]; then
    check_sol_hub "$t" "$dep" "$hm"
    return
  fi
  local hrpc
  hrpc=$(hub_rpc "$hub") || { echo "== $t: no RPC configured for hub chain '$hub' — skipping"; return; }
  local em et ht etok htok
  em=$(jq -r --arg c "$hub" '.chains[$c].manager // empty' "$dep")
  [ -n "$em" ] || { echo "== $t: hub leg '$hub' not deployed — skipping"; return; }
  et=$(jq -r --arg c "$hub" '.chains[$c].transceivers.wormhole.address' "$dep")
  ht=$(jq -r '.chains.Hydration.transceivers.wormhole.address' "$dep")
  etok=$(jq -r --arg c "$hub" '.chains[$c].token' "$dep")
  htok=$(jq -r '.chains.Hydration.token' "$dep")

  local hub_id hyd_id edec hdec
  hub_id=$(call "$em" 'chainId()(uint16)' "$hrpc")
  hyd_id=$(call "$hm" 'chainId()(uint16)' "$HYDRATION_RPC")
  edec=$(call "$etok" 'decimals()(uint8)' "$hrpc")
  hdec=$(call "$htok" 'decimals()(uint8)' "$HYDRATION_RPC")
  echo "== $t  (wormhole chain ids: $hub=$hub_id Hydration=$hyd_id)"

  # hub side
  ck "$hub manager token ($edec dec)" "$etok" "$(call "$em" 'token()(address)' "$hrpc")"
  ck "$hub manager mode = locking(0)" 0 "$(call "$em" 'getMode()(uint8)' "$hrpc")"
  local p; p=$(peer_of "$em" "$hyd_id" "$hrpc")
  ck "$hub manager peer → Hydration manager" "$(b32 "$hm"),$hdec" "$p"
  ck "$hub transceiver peer → Hydration transceiver" "$(b32 "$ht")" \
     "$(call "$et" 'getWormholePeer(uint16)(bytes32)' "$hrpc" "$hyd_id")"
  case "$(lower "$(call "$em" 'getTransceivers()(address[])' "$hrpc")")" in
    *"$(lower "${et#0x}")"*) ck "$hub manager registers its transceiver" x x ;;
    *) ck "$hub manager registers its transceiver" "$et" "not in getTransceivers()" ;;
  esac

  # Hydration side
  ck "Hydration manager token ($hdec dec)" "$htok" "$(call "$hm" 'token()(address)' "$HYDRATION_RPC")"
  ck "Hydration manager mode = burning(1)" 1 "$(call "$hm" 'getMode()(uint8)' "$HYDRATION_RPC")"
  p=$(peer_of "$hm" "$hub_id" "$HYDRATION_RPC")
  ck "Hydration manager peer → $hub manager" "$(b32 "$em"),$edec" "$p"
  ck "Hydration transceiver peer → $hub transceiver" "$(b32 "$et")" \
     "$(call "$ht" 'getWormholePeer(uint16)(bytes32)' "$HYDRATION_RPC" "$hub_id")"
  case "$(lower "$(call "$hm" 'getTransceivers()(address[])' "$HYDRATION_RPC")")" in
    *"$(lower "${ht#0x}")"*) ck "Hydration manager registers its transceiver" x x ;;
    *) ck "Hydration manager registers its transceiver" "$ht" "not in getTransceivers()" ;;
  esac
}

if [ $# -gt 0 ]; then TOKENS=("$@"); else
  TOKENS=($(ls "$HYD_ROOT/tokens"))
fi
for t in "${TOKENS[@]}"; do check_token "$t"; done

[ "$FAIL" = 0 ] && echo "ALL OK" || { echo "MISMATCHES FOUND"; exit 1; }
