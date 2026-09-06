# Shared config + helpers for the Hydration NTT deploy scripts. Source, don't execute.

HYD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# This repo is a full NTT source tree — deploy commands compile from its
# evm/ / solana/ / sui/ trees. Override NTT_SRC to deploy from a separate clone.
NTT_SRC="${NTT_SRC:-$(cd "$HYD_ROOT/.." && pwd)}"

ETH_RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
BASE_RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
HYDRATION_RPC="${HYDRATION_RPC:-https://hydration-rpc.n.dwellir.com}"
SOLANA_RPC="${SOLANA_RPC:-https://api.mainnet-beta.solana.com}"
# JSON-RPC for read-side scripts (_peering.sh) ONLY — public Sui fullnodes
# dropped JSON-RPC (gRPC/GraphQL only), so this must be a provider that still
# serves it. The ntt CLI itself talks gRPC to the public fullnode.
SUI_JSONRPC="${SUI_JSONRPC:-https://autumn-flashy-liquid.sui-mainnet.quiknode.pro/20a018256175b53a0b6739bcf039b6070d00b904/}"
# Robinhood Chain: Arbitrum Orbit, EVM chainId 4663, native ETH gas.
# Explorer robinhoodchain.blockscout.com sits behind Cloudflare — script
# access needs a browser User-Agent; verification goes via sourcify.dev
# (chain 4663 is supported there and Blockscout imports it).
ROBINHOOD_RPC="${ROBINHOOD_RPC:-https://rpc.mainnet.chain.robinhood.com}"

confirm() {
  read -r -p "$1 [yes/NO] " reply
  [ "$reply" = "yes" ] || { echo "aborted"; exit 1; }
}

need_env() {
  [ -n "${!1:-}" ] || { echo "ERROR: $1 not set"; exit 1; }
}

need_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null || { echo "ERROR: $t not found"; exit 1; }
  done
}

# The CLI reads ONE EVM key from ETH_PRIVATE_KEY, but Ethereum and Hydration
# use different keys — each leg script maps its own env var onto it, and push
# runs per chain (--only-chain) so the wrong key can never sign a leg.
use_key() {
  need_env "$1"
  export ETH_PRIVATE_KEY="${!1}"
}

deployer() {
  cast wallet address --private-key "$ETH_PRIVATE_KEY"
}

check_cli() {
  echo "== CLI checkout branch (must be main; do not 'ntt update' mid-deploy) =="
  git -C ~/.ntt-cli/.checkout rev-parse --abbrev-ref HEAD
  ntt add-chain Hydration --help >/dev/null 2>&1 \
    || { echo "ERROR: Hydration not in CLI chain list — rerun 'ntt update --branch main'"; exit 1; }
  echo "Hydration chain: OK"
}

# CLI reads overrides.json from its cwd — pin RPCs in the NTT source root.
# Sui entry is for the read-side ops scripts only (CLI talks gRPC itself).
write_overrides() {
  cat > "$NTT_SRC/overrides.json" <<EOF
{
  "chains": {
    "Ethereum":  { "rpc": "$ETH_RPC" },
    "Base":      { "rpc": "$BASE_RPC" },
    "Hydration": { "rpc": "$HYDRATION_RPC" },
    "Solana":    { "rpc": "$SOLANA_RPC" },
    "Sui":       { "rpc": "$SUI_JSONRPC" },
    "Robinhood": { "rpc": "$ROBINHOOD_RPC" }
  }
}
EOF
}

# Shared init: pin source commit, write overrides, create the deployment file.
# Caller must set $DEPLOYMENT.
cmd_init() {
  [ -f "$NTT_SRC/evm/foundry.toml" ] || { echo "ERROR: $NTT_SRC is not an NTT source tree"; exit 1; }
  if [ -n "$(git -C "$NTT_SRC" status --porcelain -- evm solana sui 2>/dev/null)" ]; then
    echo "WARN: uncommitted changes in $NTT_SRC contract trees — you deploy what's on disk, not NTT_COMMIT"
  fi
  git -C "$NTT_SRC" rev-parse HEAD > "$HYD_ROOT/NTT_COMMIT"
  echo "NTT_COMMIT: $(cat "$HYD_ROOT/NTT_COMMIT")"
  write_overrides
  mkdir -p "$(dirname "$DEPLOYMENT")"
  if [ -f "$DEPLOYMENT" ]; then
    echo "deployment.json already exists, leaving it alone"
  else
    (cd "$NTT_SRC" && ntt init Mainnet -p "$DEPLOYMENT")
  fi
}

cmd_status() {
  (cd "$NTT_SRC" && ntt status -p "$DEPLOYMENT")
}
