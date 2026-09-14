#!/usr/bin/env bash
# WETH — SECOND locking hub: Robinhood (chain 72), wethUnwrap variant over
# canonical WETH 0x0Bd7D308… (users deposit/receive native ETH). Added to the
# EXISTING ops/tokens/weth/deployment.json as a third leg:
#   Ethereum  locking (untouched — no Safe round, no Robinhood peer)
#   Hydration burning (same manager mints the same WETH asset — owner is the
#                      aave emergency admin 0xAA7e…AA7E1, so its peer setup is
#                      a governance dispatch: see 'govref')
#   Robinhood locking (this script)
#
# DUAL-HUB TOPOLOGY — deliberate deviations from the usual runbook:
#   * deploy needs WL_NTT_ALLOW_SECOND_HUB=1 (CLI guard patched to allow it;
#     ntt update wipes the patch — see memory/ops notes)
#   * NEVER run `ntt push` on the weth deployment again: push meshes ALL
#     chains — it would register Ethereum<->Robinhood peers (hub<->hub drain
#     surface, deliberately unpeered) and try to sign as the Safe. Peers are
#     set manually: 'peer' (Robinhood side, hot key) + 'govref' (Hydration
#     side, governance calldata).
#   * custody drift: Ethereum custody + Robinhood custody back Hydration WETH
#     supply; keep Robinhood outbound + Hydration inbound(72) conservative
#     (Ethereum-custody drain is the slow-heal direction, ~7d canonical exit).
#
#   scripts/robinhood/weth.sh preflight   # no txs: keys, WETH sanity, hub legs present
#   scripts/robinhood/weth.sh deploy      # TX Robinhood: manager+transceiver
#                                        #   (LOCKING canonical WETH, wethUnwrap)
#   scripts/robinhood/weth.sh peer        # TX Robinhood: setPeer(Hydration) + setWormholePeer
#                                        #   + setOutboundLimit — manual, NOT push
#   scripts/robinhood/weth.sh govref      # no txs: print the aave-emergency-admin dispatch
#                                        #   calldata for the Hydration side (2 calls)
#   scripts/robinhood/weth.sh status      # read-only peer/limit check, both sides

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/weth/deployment.json"
RH_WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73   # canonical (aeWETH-style proxy; supply == native balance)
CHAIN_HYDRATION=73
CHAIN_ROBINHOOD=72

# 24h NTT rate limits, whole WETH (18 dec). 69/day on the Robinhood leg
# (sized 2026-09-14) — also the dual-hub custody-drift throttle. The
# Ethereum hub leg stays at its own 10k limits.
LIMIT_RH_OUT="${LIMIT_RH_OUT:-69}"
LIMIT_RH_IN="${LIMIT_RH_IN:-69}"
LIMIT_HYD_IN="${LIMIT_HYD_IN:-69}"   # only used by govref (setPeer param)

hyd_manager() { jq -r '.chains.Hydration.manager' "$DEPLOYMENT"; }
hyd_xcvr()    { jq -r '.chains.Hydration.transceivers.wormhole.address' "$DEPLOYMENT"; }
rh_manager()  { jq -r '.chains.Robinhood.manager // empty' "$DEPLOYMENT"; }
rh_xcvr()     { jq -r '.chains.Robinhood.transceivers.wormhole.address // empty' "$DEPLOYMENT"; }
b32() { printf '0x%064s' "${1#0x}" | tr ' ' '0'; }
raw18() { cast to-wei "$1" ether; }

cmd_preflight() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  need_tools ntt cast jq git
  jq -e '.chains.Ethereum.manager and .chains.Hydration.manager' "$DEPLOYMENT" >/dev/null \
    || { echo "ERROR: weth deployment.json missing existing legs"; exit 1; }
  local addr; addr=$(deployer)
  echo "== Deployer: $addr =="
  echo "Robinhood balance: $(cast balance --ether "$addr" --rpc-url "$ROBINHOOD_RPC") ETH"
  # wrap invariant must be read at ONE block (fast chain — sequential reads
  # race withdrawals). aeWETH-style: native >= supply (forced sends allowed).
  local bn sup bal
  bn=$(cast block-number --rpc-url "$ROBINHOOD_RPC")
  sup=$(cast call $RH_WETH 'totalSupply()(uint256)' --block "$bn" --rpc-url "$ROBINHOOD_RPC" | awk '{print $1}')
  bal=$(cast balance $RH_WETH --block "$bn" --rpc-url "$ROBINHOOD_RPC")
  python3 -c "import sys; sys.exit(0 if int('$bal') >= int('$sup') else 1)" \
    || { echo "ERROR: WETH wrap invariant broken at block $bn: supply $sup > native $bal"; exit 1; }
  echo "canonical WETH @ $RH_WETH: native>=supply ✓ at block $bn ($(cast from-wei "$sup") ETH wrapped)"
  echo "Hydration peer targets: manager $(hyd_manager) / transceiver $(hyd_xcvr) (owner = aave emergency admin)"
}

cmd_deploy() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  confirm "Deploy SECOND LOCKING HUB (wethUnwrap, canonical WETH) to ROBINHOOD mainnet?"
  (cd "$NTT_SRC" && WL_NTT_ALLOW_SECOND_HUB=1 ntt add-chain Robinhood --local --mode locking \
    --manager-variant wethUnwrap --token $RH_WETH --skip-verify -p "$DEPLOYMENT")
}

# Robinhood-side wiring, manual on purpose (see header). Idempotence: setPeer
# and setOutboundLimit are re-runnable; setWormholePeer is SET-ONCE.
cmd_peer() {
  use_key ROBINHOOD_PRIVATE_KEY
  need_env ROBINHOOD_RPC
  local M X; M=$(rh_manager); X=$(rh_xcvr)
  [ -n "$M" ] || { echo "ERROR: Robinhood leg missing — run deploy first"; exit 1; }
  echo "manager.setPeer(73, $(hyd_manager), 18, $LIMIT_RH_IN WETH)"
  echo "xcvr.setWormholePeer(73, $(hyd_xcvr))  <- SET-ONCE, check the address"
  confirm "Send the 3 Robinhood-side wiring txs?"
  cast send "$M" 'setPeer(uint16,bytes32,uint8,uint256)' $CHAIN_HYDRATION "$(b32 "$(hyd_manager)")" 18 "$(raw18 "$LIMIT_RH_IN")" \
    --private-key "$ETH_PRIVATE_KEY" --rpc-url "$ROBINHOOD_RPC"
  if [ "$(cast call "$X" 'getWormholePeer(uint16)(bytes32)' $CHAIN_HYDRATION --rpc-url "$ROBINHOOD_RPC" | tr 'A-F' 'a-f')" = "$(b32 "$(hyd_xcvr)" | tr 'A-F' 'a-f')" ]; then
    echo "wormhole peer already set, skipping (set-once)"
  else
    cast send "$X" 'setWormholePeer(uint16,bytes32)' $CHAIN_HYDRATION "$(b32 "$(hyd_xcvr)")" \
      --private-key "$ETH_PRIVATE_KEY" --rpc-url "$ROBINHOOD_RPC"
  fi
  cast send "$M" 'setOutboundLimit(uint256)' "$(raw18 "$LIMIT_RH_OUT")" \
    --private-key "$ETH_PRIVATE_KEY" --rpc-url "$ROBINHOOD_RPC"
  echo "done — verify with 'status'"
}

# The Hydration side is owned by the aave emergency admin (0xAA7e…AA7E1):
# two calls, dispatched via governance. Print targets + calldata.
cmd_govref() {
  local M X; M=$(rh_manager); X=$(rh_xcvr)
  [ -n "$M" ] || { echo "ERROR: Robinhood leg missing — run deploy first"; exit 1; }
  echo "## Hydration governance dispatch (origin: aave emergency admin 0xAA7e0000000000000000000000000000000AA7E1)"
  echo
  echo "# 1) register Robinhood manager as peer (carries inbound limit $LIMIT_HYD_IN WETH)"
  echo "target:   $(hyd_manager)   (weth NttManager, Hydration)"
  echo "calldata: $(cast calldata 'setPeer(uint16,bytes32,uint8,uint256)' $CHAIN_ROBINHOOD "$(b32 "$M")" 18 "$(raw18 "$LIMIT_HYD_IN")")"
  echo
  echo "# 2) register Robinhood transceiver as wormhole peer (SET-ONCE!)"
  echo "target:   $(hyd_xcvr)   (weth WormholeTransceiver, Hydration)"
  echo "calldata: $(cast calldata 'setWormholePeer(uint16,bytes32)' $CHAIN_ROBINHOOD "$(b32 "$X")")"
  echo
  echo "# decoded, for reviewers:"
  echo "#   setPeer(72, $(b32 "$M"), 18, $(raw18 "$LIMIT_HYD_IN"))"
  echo "#   setWormholePeer(72, $(b32 "$X"))"
}

cmd_status() {
  need_env ROBINHOOD_RPC
  local M X; M=$(rh_manager); X=$(rh_xcvr)
  echo "== Robinhood side"
  echo "peer(73):   $(cast call "$M" 'getPeer(uint16)((bytes32,uint8))' $CHAIN_HYDRATION --rpc-url "$ROBINHOOD_RPC")"
  echo "whPeer(73): $(cast call "$X" 'getWormholePeer(uint16)(bytes32)' $CHAIN_HYDRATION --rpc-url "$ROBINHOOD_RPC")"
  echo "out cap:    $(cast call "$M" 'getCurrentOutboundCapacity()(uint256)' --rpc-url "$ROBINHOOD_RPC")"
  echo "in cap(73): $(cast call "$M" 'getCurrentInboundCapacity(uint16)(uint256)' $CHAIN_HYDRATION --rpc-url "$ROBINHOOD_RPC")"
  echo "== Hydration side (set via governance)"
  echo "peer(72):   $(cast call "$(hyd_manager)" 'getPeer(uint16)((bytes32,uint8))' $CHAIN_ROBINHOOD --rpc-url "$HYDRATION_RPC")"
  echo "whPeer(72): $(cast call "$(hyd_xcvr)" 'getWormholePeer(uint16)(bytes32)' $CHAIN_ROBINHOOD --rpc-url "$HYDRATION_RPC")"
  echo "in cap(72): $(cast call "$(hyd_manager)" 'getCurrentInboundCapacity(uint16)(uint256)' $CHAIN_ROBINHOOD --rpc-url "$HYDRATION_RPC")"
}

case "${1:-}" in
  preflight|deploy|peer|govref|status) "cmd_$1" ;;
  *) sed -n '2,33p' "$0"; exit 1 ;;
esac
