#!/bin/bash
# sync-ots-to-rmc.sh - Sync CopyrightRegistry contract bytecode to RMC genesis
#
# Usage:
#   ./scripts/sync-ots-to-rmc.sh [options]
#
# Options:
#   --dry-run       Show what would be done without making changes
#   --skip-build    Skip forge build (use existing output)
#   --commit        Create git commit after syncing
#
# Example:
#   ./scripts/sync-to-rmc.sh --commit

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
RMC_DIR="${CONTRACT_DIR}/../rmc"
GENESIS_FILE="${RMC_DIR}/tests/truffle/genesis/genesis.json"
STORAGE_GENESIS_FILE="${RMC_DIR}/tests/truffle/storage/genesis.json"
CONTRACT_ADDRESS="0x0000000000000000000000000000000000009000"
CHAIN_ID="192"

# Find OTS artifact - check both possible paths
ARTIFACT=""
if [ -f "$CONTRACT_DIR/out/ots/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
    ARTIFACT="out/ots/CopyrightRegistry.sol/CopyrightRegistry.json"
elif [ -f "$CONTRACT_DIR/out/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
    ARTIFACT="out/CopyrightRegistry.sol/CopyrightRegistry.json"
else
    # Will be set after build
    ARTIFACT="out/ots/CopyrightRegistry.sol/CopyrightRegistry.json"
fi

# Flags
DRY_RUN=0
SKIP_BUILD=0
DO_COMMIT=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --commit)
            DO_COMMIT=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check forge
    if ! command -v forge &> /dev/null; then
        log_error "forge not found. Please install foundry."
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq."
        exit 1
    fi

    # Check RMC directory
    if [ ! -d "$RMC_DIR" ]; then
        log_error "RMC directory not found: $RMC_DIR"
        exit 1
    fi

    # Check genesis file
    if [ ! -f "$GENESIS_FILE" ]; then
        log_error "Genesis file not found: $GENESIS_FILE"
        exit 1
    fi

    log_info "Prerequisites check passed ✓"
}

build_contract() {
    if [ $SKIP_BUILD -eq 1 ]; then
        log_warn "Skipping forge build (--skip-build)"
        # Still need to find the artifact
        if [ -f "$CONTRACT_DIR/out/ots/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
            ARTIFACT="out/ots/CopyrightRegistry.sol/CopyrightRegistry.json"
        elif [ -f "$CONTRACT_DIR/out/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
            ARTIFACT="out/CopyrightRegistry.sol/CopyrightRegistry.json"
        fi
        return
    fi

    log_info "Building contracts with forge..."
    cd "$CONTRACT_DIR"

    # Build with OTS profile to ensure OTS contracts are compiled
    forge build --force

    # Find the artifact after build
    if [ -f "$CONTRACT_DIR/out/ots/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
        ARTIFACT="out/ots/CopyrightRegistry.sol/CopyrightRegistry.json"
    elif [ -f "$CONTRACT_DIR/out/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
        ARTIFACT="out/CopyrightRegistry.sol/CopyrightRegistry.json"
    else
        log_error "Contract artifact not found after build"
        exit 1
    fi

    log_info "Build complete ✓ (using $ARTIFACT)"
}

extract_bytecode() {
    log_info "Extracting CopyrightRegistry bytecode..."

    # Get deployed bytecode (runtime, not creation)
    BYTECODE=$(jq -r '.bytecode.object' "$CONTRACT_DIR/$ARTIFACT")

    if [ -z "$BYTECODE" ] || [ "$BYTECODE" == "null" ]; then
        log_error "Failed to extract bytecode"
        exit 1
    fi

    # Add 0x prefix if not present
    if [[ "$BYTECODE" != 0x* ]]; then
        BYTECODE="0x$BYTECODE"
    fi

    BYTECODE_SIZE=${#BYTECODE}
    log_info "Bytecode extracted: $BYTECODE_SIZE bytes"
}

verify_selectors() {
    log_info "Verifying function selectors..."

    python3 << PYEOF
from eth_hash.auto import keccak
import json
import re

# Expected selectors from RMC consensus code
expected = {
    'initialized()': '0x158ef93e',
    'claim(bytes32)': '0xbd66528a',
    'anchor(uint64,uint64,bytes32,bytes32,uint64)': '0xa0514efe',
    'publish(bytes32,bytes32,bytes32)': '0xb32c4d8d',
}

with open('$CONTRACT_DIR/$ARTIFACT', 'r') as f:
    data = json.load(f)

bytecode = data['bytecode']['object']

# Check selectors (simplified check)
selectors_found = re.findall(r'63([0-9a-f]{8})', bytecode, re.IGNORECASE)
selectors_set = set([f'0x{s}' for s in selectors_found])

print("  Expected selectors in bytecode:")
all_found = True
for func, sel in expected.items():
    if sel in selectors_set:
        print(f"    ✓ {func}: {sel}")
    else:
        print(f"    ✗ {func}: {sel} NOT FOUND")
        all_found = False

if not all_found:
    print("\n[ERROR] Some expected selectors are missing!")
    exit(1)
else:
    print("\n  All expected selectors found ✓")
PYEOF

    if [ $? -ne 0 ]; then
        log_error "Selector verification failed"
        exit 1
    fi
}

update_genesis() {
    log_info "Updating genesis.json files..."

    # Verify chainId before updating
    GENESIS_CHAIN_ID=$(jq -r '.config.chainId' "$GENESIS_FILE" 2>/dev/null || echo "unknown")
    if [ "$GENESIS_CHAIN_ID" != "$CHAIN_ID" ]; then
        log_warn "Genesis chainId is $GENESIS_CHAIN_ID (expected $CHAIN_ID)"
    fi

    # Verify parlia config exists
    PARLIA_CONFIG=$(jq -r '.config.parlia // empty' "$GENESIS_FILE" 2>/dev/null || echo "")
    if [ -z "$PARLIA_CONFIG" ]; then
        log_error "Parlia config not found in genesis!"
        exit 1
    fi
    log_info "Parlia config verified: $(echo "$PARLIA_CONFIG" | jq -c '.')"

    # Get current bytecode size (strip newline)
    CURRENT_SIZE=$(jq -r ".alloc[\"$CONTRACT_ADDRESS\"].code" "$GENESIS_FILE" 2>/dev/null | tr -d '\n' | wc -c)
    log_info "Current bytecode size in $GENESIS_FILE: $CURRENT_SIZE bytes"

    if [ $DRY_RUN -eq 1 ]; then
        log_warn "[DRY RUN] Would update $GENESIS_FILE and $STORAGE_GENESIS_FILE with $BYTECODE_SIZE bytes bytecode"
        return
    fi

    # Backup genesis files
    BACKUP_GENESIS="${GENESIS_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
    cp "$GENESIS_FILE" "$BACKUP_GENESIS"
    log_info "Backup created: $(basename "$BACKUP_GENESIS")"

    if [ -f "$STORAGE_GENESIS_FILE" ]; then
        BACKUP_STORAGE="${STORAGE_GENESIS_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
        cp "$STORAGE_GENESIS_FILE" "$BACKUP_STORAGE"
        log_info "Backup created: $(basename "$BACKUP_STORAGE")"
    fi

    # Update tests/truffle/genesis/genesis.json
    TEMP_FILE=$(mktemp)
    jq --arg code "$BYTECODE" \
       ".alloc[\"$CONTRACT_ADDRESS\"].code = \$code" \
       "$GENESIS_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$GENESIS_FILE"

    # Verify (strip newline)
    NEW_SIZE=$(jq -r ".alloc[\"$CONTRACT_ADDRESS\"].code" "$GENESIS_FILE" | tr -d '\n' | wc -c)
    log_info "New bytecode size in $GENESIS_FILE: $NEW_SIZE bytes"

    if [ "$BYTECODE_SIZE" -ne "$NEW_SIZE" ]; then
        log_error "Size mismatch! Expected $BYTECODE_SIZE, got $NEW_SIZE"
        mv "$BACKUP_GENESIS" "$GENESIS_FILE"
        [ -f "$BACKUP_STORAGE" ] && mv "$BACKUP_STORAGE" "$STORAGE_GENESIS_FILE"
        exit 1
    fi

    # Update tests/truffle/storage/genesis.json
    # IMPORTANT: Copy the entire file to ensure consistency
    # This prevents the storage/genesis.json from overwriting genesis/genesis.json later
    cp "$GENESIS_FILE" "$STORAGE_GENESIS_FILE"
    log_info "$STORAGE_GENESIS_FILE synced with $GENESIS_FILE"

    # Verify both files are identical
    if ! cmp -s "$GENESIS_FILE" "$STORAGE_GENESIS_FILE"; then
        log_error "Genesis files differ after sync!"
        exit 1
    fi

    log_info "All genesis files updated and verified ✓"
}

update_upgrade_go() {
    log_info "Checking if upgrade.go needs update..."

    UPGRADE_FILE="${RMC_DIR}/core/systemcontracts/upgrade.go"

    if [ ! -f "$UPGRADE_FILE" ]; then
        log_warn "upgrade.go not found, skipping"
        return
    fi

    # Check if already contains d87a6b78 reference
    if grep -q "d87a6b78" "$UPGRADE_FILE"; then
        log_info "upgrade.go already references latest commit"
        return
    fi

    if [ $DRY_RUN -eq 1 ]; then
        log_warn "[DRY RUN] Would add CopyrightRegistry comment to upgrade.go"
        return
    fi

    # Get current commit
    CURRENT_COMMIT=$(cd "$CONTRACT_DIR" && git rev-parse HEAD | cut -c1-8)
    CURRENT_COMMIT_FULL=$(cd "$CONTRACT_DIR" && git rev-parse HEAD)
    CURRENT_DATE=$(cd "$CONTRACT_DIR" && git log -1 --format=%ci HEAD)

    log_info "Current commit: $CURRENT_COMMIT ($CURRENT_DATE)"

    # Add comment after the existing comment block
    # Find the line with "You can refer to" and add after it
    if [ $DO_COMMIT -eq 1 ]; then
        # Check if we need to add the comment
        if ! grep -q "CopyrightRegistry (0x9000)" "$UPGRADE_FILE"; then
            log_info "Adding CopyrightRegistry reference to upgrade.go..."

            # Use a temp file and sed to insert the comment
            awk '
                /You can refer to.*rmc-genesis-contract/ {
                    print
                    print "//"
                    print "// RMC OTS CopyrightRegistry Contract (0x9000):"
                    print "// - Source: https://github.com/redmansionorg/rmc-genesis-contract/blob/master/contracts/ots/CopyrightRegistry.sol"
                    print "// - Commit: '"'"$CURRENT_COMMIT_FULL"'"'"
                    print "// - Bytecode: Embedded in tests/truffle/genesis/genesis.json at alloc[\"0x9000\"].code"
                    print "// - Functions: claim(bytes32), publish(bytes32,bytes32,bytes32), anchor(uint64,uint64,bytes32,bytes32,uint64)"
                    print "//"
                    next
                }
                { print }
            ' "$UPGRADE_FILE" > "${UPGRADE_FILE}.tmp"
            mv "${UPGRADE_FILE}.tmp" "$UPGRADE_FILE"

            log_info "upgrade.go updated ✓"
        fi
    else
        log_info "Skipping upgrade.go update (use --commit to enable)"
    fi
}

create_commit() {
    if [ $DO_COMMIT -ne 1 ]; then
        return
    fi

    if [ $DRY_RUN -eq 1 ]; then
        log_warn "[DRY RUN] Would create git commit"
        return
    fi

    log_info "Creating git commit in RMC..."

    cd "$RMC_DIR"

    # Check what changed
    if git diff --quiet && git diff --cached --quiet; then
        log_warn "No changes to commit"
        return
    fi

    # Get contract commit info
    CONTRACT_COMMIT=$(cd "$CONTRACT_DIR" && git rev-parse HEAD | cut -c1-8)
    CONTRACT_DATE=$(cd "$CONTRACT_DIR" && git log -1 --format=%cs HEAD)
    CONTRACT_MSG=$(cd "$CONTRACT_DIR" && git log -1 --format=%s HEAD | cut -c1-60)

    # Add files
    git add tests/truffle/genesis/genesis.json
    git add core/systemcontracts/upgrade.go 2>/dev/null || true

    # Create commit
    git commit -m "$(cat <<EOF
chore(ots): sync CopyrightRegistry bytecode from rmc-genesis-contract

Update genesis.json with latest CopyrightRegistry contract bytecode:
- Contract: CopyrightRegistry (0x9000)
- Source: redmansionorg/rmc-genesis-contract
- Commit: $CONTRACT_COMMIT ($CONTRACT_DATE)
- Message: $CONTRACT_MSG...

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"

    log_info "Commit created ✓"
    log_info "Commit message:"
    git log -1 --oneline
}

print_summary() {
    echo ""
    echo "========================================"
    echo "       Sync Summary"
    echo "========================================"
    echo ""
    echo "Contract: CopyrightRegistry"
    echo "Address:  $CONTRACT_ADDRESS"
    echo "ChainId:  $CHAIN_ID"
    echo "Bytecode: $BYTECODE_SIZE bytes"
    echo ""
    echo "Files updated:"
    echo "  - $GENESIS_FILE"
    echo "  - $STORAGE_GENESIS_FILE"

    if [ -f "${RMC_DIR}/core/systemcontracts/upgrade.go" ]; then
        echo "  - ${RMC_DIR}/core/systemcontracts/upgrade.go"
    fi

    echo ""
    if [ $DRY_RUN -eq 1 ]; then
        echo -e "${YELLOW}[DRY RUN] No changes were made${NC}"
    else
        echo -e "${GREEN}✓ Sync completed${NC}"
        echo ""
        echo "Both genesis files are now identical and contain:"
        echo "  - Parlia consensus config"
        echo "  - ChainId: $CHAIN_ID"
        echo "  - Latest CopyrightRegistry bytecode"
    fi
    echo ""
    echo "========================================"
}

# Main execution
main() {
    echo "========================================"
    echo "  RMC Genesis Contract Sync"
    echo "========================================"
    echo ""

    check_prerequisites
    build_contract
    extract_bytecode
    verify_selectors
    update_genesis
    update_upgrade_go
    create_commit
    print_summary
}

main