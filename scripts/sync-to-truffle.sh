#!/usr/bin/env bash
#
# sync-to-truffle.sh - Build genesis with chainId=192 and sync to truffle test env.
#
# Outputs:
#   - ../rmc/tests/truffle/genesis/genesis.json
#   - ../rmc/tests/truffle/storage/genesis.json
#
# Usage:
#   ./scripts/sync-to-truffle.sh [--skip-build]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
RMC_DIR="${CONTRACT_DIR}/../rmc"
TRUFFLE_GENESIS_DIR="${RMC_DIR}/tests/truffle/genesis"
TRUFFLE_STORAGE_DIR="${RMC_DIR}/tests/truffle/storage"

CHAIN_ID="192"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_cmd node
require_cmd jq

if [[ $SKIP_BUILD -eq 0 ]]; then
  require_cmd forge
fi

cd "$CONTRACT_DIR"

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "[sync-to-truffle] forge build"
  forge build
else
  echo "[sync-to-truffle] skip forge build (--skip-build)"
fi

echo "[sync-to-truffle] generate genesis (chainId=${CHAIN_ID})"
node "$SCRIPT_DIR/generate-genesis.js" \
  --chainId "$CHAIN_ID" \
  --template "$CONTRACT_DIR/genesis-template.json" \
  --output "$CONTRACT_DIR/genesis.json"

echo "[sync-to-truffle] merge OTS alloc into genesis"
node "$SCRIPT_DIR/generate-ots.js" \
  --merge "$CONTRACT_DIR/genesis.json" \
  --output "$CONTRACT_DIR/genesis.json"

if [[ ! -d "$TRUFFLE_GENESIS_DIR" ]]; then
  echo "Truffle genesis dir not found: $TRUFFLE_GENESIS_DIR"
  exit 1
fi

if [[ ! -d "$TRUFFLE_STORAGE_DIR" ]]; then
  echo "Truffle storage dir not found: $TRUFFLE_STORAGE_DIR"
  exit 1
fi

echo "[sync-to-truffle] sync genesis.json to truffle dirs"
cp "$CONTRACT_DIR/genesis.json" "$TRUFFLE_GENESIS_DIR/genesis.json"
cp "$CONTRACT_DIR/genesis.json" "$TRUFFLE_STORAGE_DIR/genesis.json"

echo "[sync-to-truffle] done"
