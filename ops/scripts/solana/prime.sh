#!/usr/bin/env bash
# PRIME — hub leg: Solana, locking mode (standard SPL, 6 decimals).
# Hub legs deploy first; the Hydration spoke leg comes later via
# scripts/hydration/prime.sh.
#
# Solana leg specifics (vs EVM legs):
#   - signer = payer keypair: SOLANA_PRIVATE_KEY (base58 export) or
#     SOLANA_PAYER_KEYPAIR (path to keypair json)
#   - each deployment needs its OWN program-id keypair ('keys' step); the
#     program id IS that pubkey — keep the file until deploy succeeds
#   - deploy compiles the program locally: anchor + solana toolchain + rust
#     (CLI enforces exact versions), then pays ~4-6 SOL program rent
#   - deploy.ts CLI patches are REQUIRED (scripts/solana/README.md) and
#     'ntt update' wipes them — preflight/deploy check and refuse without them
#   - if the write phase stalls at 0.0% (it did for SOL and jitoSOL), use
#     Plan B: _tools/fast-deploy.ts per scripts/solana/README.md
#
#   scripts/solana/prime.sh preflight   # no txs: toolchain, payer balance, CLI patches
#   scripts/solana/prime.sh init        # no txs: NTT_COMMIT, overrides.json, deployment.json
#   scripts/solana/prime.sh keys        # no txs: generate program-id keypair
#   scripts/solana/prime.sh deploy      # TX Solana: anchor build + program deploy (locking PRIME)
#   scripts/solana/prime.sh push        # TX Solana: register Hydration peer + limits (after spoke leg)
#
#   scripts/solana/prime.sh status      # local vs on-chain drift

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_lib.sh"

DEPLOYMENT="$HYD_ROOT/tokens/prime/deployment.json"
KEYS_DIR="$HYD_ROOT/tokens/prime/keys"                # gitignored — never commit keypairs
PROGRAM_KEY="$KEYS_DIR/program.json"
PRIME=3b8X44fLF9ooXaUm3hhSgjpmVs6rZZ3pPoGnGahc3Uu7    # canonical PRIME mint, 6 decimals
SOLANA_RPC="${SOLANA_RPC:-https://api.mainnet-beta.solana.com}"
DEPLOY_TS="$HOME/.ntt-cli/.checkout/cli/src/solana/deploy.ts"

# The three deployCommand patches from scripts/solana/README.md — without
# them the deploy stalls (TPU drops), overpays rent 2x, or dies instantly
# with "invalid account data". 'ntt update' resets the checkout.
check_patches() {
  local missing=0 pat
  for pat in '"--max-len"' '"--use-rpc"'; do
    grep -qF -- "$pat" "$DEPLOY_TS" 2>/dev/null \
      || { echo "MISSING deploy.ts patch: $pat"; missing=1; }
  done
  # args are one-per-line in deployCommand — match across the line break
  grep -A2 -F -- '"--commitment"' "$DEPLOY_TS" 2>/dev/null | grep -qF '"confirmed"' \
    || { echo "MISSING deploy.ts patch: --commitment confirmed"; missing=1; }
  if [ "$missing" != 0 ]; then
    echo "re-apply per scripts/solana/README.md ('ntt update' wiped them)"
    return 1
  fi
  echo "deploy.ts patches: all present"
}

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
  check_patches || true   # informative here; 'deploy' refuses without them
  echo "== toolchain (CLI enforces exact versions at deploy) =="
  solana --version; anchor --version
  local addr; addr=$(solana-keygen pubkey "$SOLANA_PAYER_KEYPAIR")
  echo "== Payer: $addr =="
  echo "Solana balance: $(solana balance "$addr" --url "$SOLANA_RPC")  (deploy needs ~4-6 SOL program rent + fees)"
  echo "PRIME mint decimals: $(curl -sS --compressed "$SOLANA_RPC" -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getTokenSupply","params":["'$PRIME'"]}' \
    | jq -r .result.value.decimals) (expect 6)"
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
  check_patches || exit 1
  confirm "Deploy NTT program to SOLANA mainnet (anchor build + ~4-6 SOL rent)?"
  # priority fee (microlamports/CU) — without it the ~940 buffer-write txs
  # lose the inclusion auction and the deploy stalls at a frozen percentage
  (cd "$NTT_SRC" && ntt add-chain Solana --latest --mode locking \
    --token $PRIME --payer "$SOLANA_PAYER_KEYPAIR" --program-key "$PROGRAM_KEY" \
    --solana-priority-fee "${SOLANA_PRIORITY_FEE:-100000}" \
    -p "$DEPLOYMENT")
}

# Solana-side half of the cross-link: registers the Hydration manager +
# transceiver as peers ON Solana and applies Solana limits. The
# Hydration-side half runs from scripts/hydration/prime.sh push with its own key.
cmd_push() {
  payer
  cmd_status || true
  confirm "Push Solana-side config (setPeer + limits, owner-only)?"
  (cd "$NTT_SRC" && ntt push --only-chain Solana --payer "$SOLANA_PAYER_KEYPAIR" -p "$DEPLOYMENT")
  cmd_status
}

case "${1:-}" in
  preflight|init|keys|deploy|push|status) "cmd_$1" ;;
  *) sed -n '2,25p' "$0"; exit 1 ;;
esac
