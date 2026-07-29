#!/usr/bin/env bash
# SOL — hub leg: Solana, locking mode (wSOL; native SOL isn't lockable).
# Hub legs deploy first; the Hydration spoke leg comes later via
# scripts/hydration/sol.sh.
#
# Solana leg specifics (vs EVM legs):
#   - signer = payer keypair: SOLANA_PRIVATE_KEY (base58 export) or
#     SOLANA_PAYER_KEYPAIR (path to keypair json)
#   - each deployment needs its OWN program-id keypair ('keys' step); the
#     program id IS that pubkey — keep the file until deploy succeeds
#   - deploy compiles the program locally: anchor + solana toolchain + rust
#     (CLI enforces exact versions), then pays ~4-6 SOL program rent
#
#   scripts/solana/sol.sh preflight   # no txs: toolchain, payer balance, CLI sanity
#   scripts/solana/sol.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/solana/sol.sh keys        # no txs: generate program-id keypair
#   scripts/solana/sol.sh deploy      # TX Solana: anchor build + program deploy (locking wSOL)
#   scripts/solana/sol.sh push        # TX Solana: register Hydration peer + limits (after spoke leg)
#
#   scripts/solana/sol.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/sol/deployment.json"
KEYS_DIR="$HYD_ROOT/tokens/sol/keys"                 # gitignored — never commit keypairs
PROGRAM_KEY="$KEYS_DIR/program.json"
WSOL=So11111111111111111111111111111111111111112     # canonical wrapped SOL, 9 decimals
SOLANA_RPC="${SOLANA_RPC:-https://api.mainnet-beta.solana.com}"

# Payer: SOLANA_PAYER_KEYPAIR (path to keypair json) or SOLANA_PRIVATE_KEY
# (base58 64-byte secret, e.g. a Phantom export) — the CLI's deploy path only
# reads a keypair FILE, so the key is materialized into the gitignored keys
# dir (0600) and used from there.
payer() {
  if [ -n "${SOLANA_PAYER_KEYPAIR:-}" ]; then
    [ -f "$SOLANA_PAYER_KEYPAIR" ] || { echo "ERROR: payer keypair not found: $SOLANA_PAYER_KEYPAIR"; exit 1; }
    return
  fi
  need_env SOLANA_PRIVATE_KEY
  local f="$KEYS_DIR/payer.json"
  if [ ! -f "$f" ]; then
    mkdir -p "$KEYS_DIR"
    python3 - "$f" <<'PY'
import json, os, sys
key = os.environ['SOLANA_PRIVATE_KEY'].strip()
if key.startswith('['):
    arr = json.loads(key)                      # already a solana json array
else:                                          # base58 secret key
    A = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    n = 0
    for c in key: n = n*58 + A.index(c)
    b = n.to_bytes((n.bit_length()+7)//8, 'big')
    b = b'\x00' * (len(key) - len(key.lstrip('1'))) + b
    arr = list(b)
if len(arr) != 64:
    sys.exit(f"ERROR: decoded key is {len(arr)} bytes, expected 64 (need the full base58 secret-key export, not a seed)")
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as out: json.dump(arr, out)
PY
    echo "payer keypair written to $f (from SOLANA_PRIVATE_KEY)"
  fi
  export SOLANA_PAYER_KEYPAIR="$f"
}

cmd_preflight() {
  payer
  need_tools ntt solana solana-keygen anchor cargo jq git
  check_cli
  echo "== toolchain (CLI enforces exact versions at deploy) =="
  solana --version; anchor --version
  local addr; addr=$(solana-keygen pubkey "$SOLANA_PAYER_KEYPAIR")
  echo "== Payer: $addr =="
  echo "Solana balance: $(solana balance "$addr" --url "$SOLANA_RPC")  (deploy needs ~4-6 SOL program rent + fees)"
  [ -f "$PROGRAM_KEY" ] && echo "program id: $(solana-keygen pubkey "$PROGRAM_KEY")" \
    || echo "program keypair not generated yet — run 'keys'"
}

# One fresh program-id keypair PER deployment — its pubkey becomes the NTT
# program address on Solana.
cmd_keys() {
  need_tools solana-keygen
  [ ! -f "$PROGRAM_KEY" ] \
    || { echo "already exists: $PROGRAM_KEY (program id $(solana-keygen pubkey "$PROGRAM_KEY"))"; exit 0; }
  mkdir -p "$KEYS_DIR"
  solana-keygen new --no-bip39-passphrase -o "$PROGRAM_KEY"
  echo "program id: $(solana-keygen pubkey "$PROGRAM_KEY")"
}

cmd_deploy() {
  payer
  [ -f "$PROGRAM_KEY" ] || { echo "ERROR: run 'keys' first"; exit 1; }
  confirm "Deploy NTT program to SOLANA mainnet (anchor build + ~4-6 SOL rent)?"
  # priority fee (microlamports/CU) — without it the ~940 buffer-write txs
  # lose the inclusion auction and the deploy stalls at a frozen percentage
  (cd "$NTT_SRC" && ntt add-chain Solana --latest --mode locking \
    --token $WSOL --payer "$SOLANA_PAYER_KEYPAIR" --program-key "$PROGRAM_KEY" \
    --solana-priority-fee "${SOLANA_PRIORITY_FEE:-100000}" \
    -p "$DEPLOYMENT")
}

# Solana-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Solana and applies Solana limits. The
# Hydration-side half runs from scripts/hydration/sol.sh push with its own key.
cmd_push() {
  payer
  cmd_status || true
  confirm "Push Solana-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Solana --payer "$SOLANA_PAYER_KEYPAIR" -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|keys|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
