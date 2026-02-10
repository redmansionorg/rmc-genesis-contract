#!/usr/bin/env bash
#
# sync-to-rmc-truffle.sh - 完整同步脚本：从 rmc-genesis-contract 到 rmc/tests/truffle
#
# 解决的问题：
# 1. 确保使用标准 Genesis 模板（包含 parlia 共识定义）
# 2. 同步 Genesis validator 配置和 keystore
# 3. 确保使用 chainId=192
# 4. 确保使用最新的 CopyrightRegistry 字节码
# 5. 防止 truffle/storage 目录覆盖 truffle/genesis 目录
#
# Usage:
#   ./scripts/sync-to-rmc-truffle.sh [--skip-build] [--force-keystore]
#
set -euo pipefail

# ============================================
# Configuration
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
RMC_DIR="${CONTRACT_DIR}/../rmc"
TRUFFLE_DIR="${RMC_DIR}/tests/truffle"

CHAIN_ID="192"
OTS_ADDRESS="0x0000000000000000000000000000000000009000"
VALIDATOR_ADDRESS="0x9fB29AAc15b9A4B7F17c3385939b007540f4d791"
VALIDATOR_PRIVATE_KEY="9b28f36fbd67381120752d6172ecdcf10e06ab2d9a1367aac00cdcd6ac7855d3"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Flags
SKIP_BUILD=0
FORCE_KEYSTORE=0

# ============================================
# Parse Arguments
# ============================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --force-keystore)
      FORCE_KEYSTORE=1
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --skip-build    Skip forge build (use existing output)"
      echo "  --force-keystore Force recreate validator keystore"
      echo "  --help, -h      Show this help"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

# ============================================
# Logging Functions
# ============================================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

# ============================================
# Prerequisites Check
# ============================================
check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check required commands
    for cmd in node jq forge docker; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    # Check directories
    if [ ! -d "$RMC_DIR" ]; then
        log_error "RMC directory not found: $RMC_DIR"
        exit 1
    fi

    if [ ! -d "$TRUFFLE_DIR" ]; then
        log_error "Truffle directory not found: $TRUFFLE_DIR"
        exit 1
    fi

    # Check required files
    if [ ! -f "$CONTRACT_DIR/genesis-template.json" ]; then
        log_error "Genesis template not found: genesis-template.json"
        exit 1
    fi

    if [ ! -f "$CONTRACT_DIR/scripts/validators.js" ]; then
        log_error "Validators config not found: scripts/validators.js"
        exit 1
    fi

    log_info "Prerequisites check passed ✓"
}

# ============================================
# Build Contracts
# ============================================
build_contracts() {
    if [ $SKIP_BUILD -eq 1 ]; then
        log_warn "Skipping forge build (--skip-build)"
        return
    fi

    log_step "Building contracts with forge..."
    cd "$CONTRACT_DIR"

    # Build all contracts (including OTS)
    forge build --force

    # Verify OTS contract artifact
    if [ ! -f "out/ots/CopyrightRegistry.sol/CopyrightRegistry.json" ] && \
       [ ! -f "out/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
        log_error "CopyrightRegistry artifact not found after build"
        exit 1
    fi

    log_info "Contracts built successfully ✓"
}

# ============================================
# Generate Complete Genesis
# ============================================
generate_genesis() {
    log_step "Generating complete genesis (chainId=${CHAIN_ID})..."

    cd "$CONTRACT_DIR"

    # Check which OTS artifact path exists
    OTS_ARTIFACT=""
    if [ -f "out/ots/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
        OTS_ARTIFACT="out/ots/CopyrightRegistry.sol/CopyrightRegistry.json"
        log_info "Using OTS artifact from: out/ots/"
    elif [ -f "out/CopyrightRegistry.sol/CopyrightRegistry.json" ]; then
        OTS_ARTIFACT="out/CopyrightRegistry.sol/CopyrightRegistry.json"
        log_info "Using OTS artifact from: out/"
    else
        log_error "CopyrightRegistry artifact not found"
        exit 1
    fi

    # Verify the artifact has bytecode
    BYTECODE=$(jq -r '.bytecode.object // .deployedBytecode.object' "$OTS_ARTIFACT" 2>/dev/null || echo "")
    if [ -z "$BYTECODE" ] || [ "$BYTECODE" == "null" ]; then
        log_error "CopyrightRegistry bytecode not found in artifact"
        exit 1
    fi
    log_info "CopyrightRegistry bytecode: ${#BYTECODE} bytes"

    # Generate genesis using the standard template
    # generate-genesis.js will:
    # - Read all contract bytecodes including CopyrightRegistry
    # - Use genesis-template.json which contains parlia config
    # - Set chainId from --chainId parameter
    node "$SCRIPT_DIR/generate-genesis.js" \
        --chainId "$CHAIN_ID" \
        --template "$CONTRACT_DIR/genesis-template.json" \
        --output "$CONTRACT_DIR/genesis.json"

    # Verify chainId in generated genesis
    GENESIS_CHAIN_ID=$(jq -r '.config.chainId' "$CONTRACT_DIR/genesis.json")
    if [ "$GENESIS_CHAIN_ID" != "$CHAIN_ID" ]; then
        log_error "ChainId mismatch! Expected $CHAIN_ID, got $GENESIS_CHAIN_ID"
        exit 1
    fi

    # Verify parlia config exists
    PARLIACONFIG=$(jq -r '.config.parlia // empty' "$CONTRACT_DIR/genesis.json")
    if [ -z "$PARLIACONFIG" ]; then
        log_error "Parlia consensus config not found in genesis!"
        exit 1
    fi
    log_info "Parlia config: $(echo "$PARLIACONFIG" | jq -c '.')"

    # Verify OTS contract is in alloc
    OTS_IN_ALLOC=$(jq -r ".alloc[\"$OTS_ADDRESS\"].code // empty" "$CONTRACT_DIR/genesis.json")
    if [ -z "$OTS_IN_ALLOC" ]; then
        log_error "OTS contract (0x9000) not found in genesis alloc!"
        exit 1
    fi
    log_info "OTS contract in alloc: ${#OTS_IN_ALLOC} bytes"

    log_info "Genesis generated successfully ✓"
}

# ============================================
# Setup Validator Keystore
# ============================================
setup_validator_keystore() {
    log_step "Setting up validator keystore..."

    TRUFFLE_KEYSTORE_DIR="$TRUFFLE_DIR/storage/keystore"
    TRUFFLE_ADDRESS_FILE="$TRUFFLE_DIR/storage/address"
    TRUFFLE_STORAGE_GENESIS="$TRUFFLE_DIR/storage/genesis.json"

    mkdir -p "$TRUFFLE_KEYSTORE_DIR"

    # Check if keystore already exists
    EXISTING_KEYSTORE=$(find "$TRUFFLE_KEYSTORE_DIR" -iname "*${VALIDATOR_ADDRESS:2}*" 2>/dev/null | head -1)

    if [ -n "$EXISTING_KEYSTORE" ] && [ $FORCE_KEYSTORE -eq 0 ]; then
        log_info "Validator keystore already exists: $(basename "$EXISTING_KEYSTORE")"
        log_info "Use --force-keystore to recreate"
    else
        log_info "Creating validator keystore..."

        # Check if rmc-genesis image exists
        if ! docker images | grep -q "rmc-genesis"; then
            log_warn "rmc-genesis docker image not found, building..."
            cd "$RMC_DIR"
            docker build -f ./docker/Dockerfile --target rmc-genesis -t rmc-genesis . || {
                log_warn "Failed to build rmc-genesis image, trying alternative method..."
                # Alternative: use geth directly if available
                if command -v geth &> /dev/null; then
                    log_info "Using local geth to create keystore..."
                    echo "$VALIDATOR_PRIVATE_KEY" > /tmp/tmp_pk.txt
                    echo "" > /tmp/tmp_pw.txt
                    geth account import --datadir "$TRUFFLE_DIR/storage" --password /tmp/tmp_pw.txt /tmp/tmp_pk.txt 2>/dev/null || true
                    rm -f /tmp/tmp_pk.txt /tmp/tmp_pw.txt
                else
                    log_error "Cannot create keystore - neither docker image nor local geth available"
                    exit 1
                fi
            }
        else
            # Use docker to create keystore
            docker run --rm --entrypoint /bin/bash \
                -v "${TRUFFLE_DIR}/storage:/root/storage" \
                rmc-genesis \
                -c "
                    cd /root/storage
                    mkdir -p keystore
                    echo '$VALIDATOR_PRIVATE_KEY' > /tmp/tmp_pk
                    echo '' > /tmp/tmp_pw
                    geth account import --datadir /root/storage --password /tmp/tmp_pw /tmp/tmp_pk
                    rm -f /tmp/tmp_pk /tmp/tmp_pw
                " 2>&1 | grep -v "geth version\|Starting whisper\+Starting maximum peer" || true
        fi

        # Verify keystore was created
        NEW_KEYSTORE=$(find "$TRUFFLE_KEYSTORE_DIR" -iname "*${VALIDATOR_ADDRESS:2}*" 2>/dev/null | head -1)
        if [ -n "$NEW_KEYSTORE" ]; then
            # Fix permissions if needed
            sudo chown $(whoami):$(whoami) "$TRUFFLE_KEYSTORE_DIR"/* 2>/dev/null || true
            log_info "Keystore created: $(basename "$NEW_KEYSTORE")"
        else
            log_warn "Keystore creation may have failed, continuing..."
        fi
    fi

    # Create/update address file
    if [ ! -f "$TRUFFLE_ADDRESS_FILE" ] || [ $FORCE_KEYSTORE -eq 1 ]; then
        echo "$VALIDATOR_ADDRESS" > "$TRUFFLE_ADDRESS_FILE"
        log_info "Address file created: $VALIDATOR_ADDRESS"
    else
        EXISTING_ADDRESS=$(cat "$TRUFFLE_ADDRESS_FILE")
        if [ "$EXISTING_ADDRESS" != "$VALIDATOR_ADDRESS" ]; then
            log_warn "Address file has different address: $EXISTING_ADDRESS"
        fi
    fi

    log_info "Validator keystore setup complete ✓"
}

# ============================================
# Sync Genesis Files
# ============================================
sync_genesis_files() {
    log_step "Syncing genesis files..."

    GENESIS_SOURCE="$CONTRACT_DIR/genesis.json"
    GENESIS_TRUFFLE="$TRUFFLE_DIR/genesis/genesis.json"
    GENESIS_STORAGE="$TRUFFLE_DIR/storage/genesis.json"

    # Backup existing files
    for f in "$GENESIS_TRUFFLE" "$GENESIS_STORAGE"; do
        if [ -f "$f" ]; then
            BACKUP="${f}.backup_$(date +%Y%m%d_%H%M%S)"
            cp "$f" "$BACKUP"
            log_info "Backup created: $(basename "$BACKUP")"
        fi
    done

    # Copy to both locations
    cp "$GENESIS_SOURCE" "$GENESIS_TRUFFLE"
    cp "$GENESIS_SOURCE" "$GENESIS_STORAGE"

    # Verify both files have the same content
    if ! cmp -s "$GENESIS_TRUFFLE" "$GENESIS_STORAGE"; then
        log_error "Genesis files differ after copy!"
        exit 1
    fi

    # Verify OTS contract is in both
    for f in "$GENESIS_TRUFFLE" "$GENESIS_STORAGE"; do
        OTS_CODE=$(jq -r ".alloc[\"$OTS_ADDRESS\"].code // empty" "$f")
        if [ -z "$OTS_CODE" ]; then
            log_error "OTS contract not found in $(basename "$f")"
            exit 1
        fi
        log_info "$(basename "$f"): OTS code ${#OTS_CODE} bytes ✓"
    done

    log_info "Genesis files synced successfully ✓"
}

# ============================================
# Fix bootstrap.sh to prevent reverse copy
# ============================================
fix_bootstrap_script() {
    log_step "Checking bootstrap.sh for reverse copy issue..."

    BOOTSTRAP_FILE="$TRUFFLE_DIR/scripts/bootstrap.sh"

    if [ ! -f "$BOOTSTRAP_FILE" ]; then
        log_warn "bootstrap.sh not found, skipping fix"
        return
    fi

    # Check if bootstrap.sh has the problematic line
    if grep -q "cp.*storage/genesis.json.*genesis/genesis.json" "$BOOTSTRAP_FILE"; then
        log_warn "Found problematic reverse copy in bootstrap.sh"
        log_info "Creating fixed version: bootstrap-fixed.sh"

        # Create a fixed version
        sed 's/cp \${workspace}\/storage\/genesis.json \${workspace}\/genesis\/genesis.json/# cp \${workspace}\/storage\/genesis.json \${workspace}\/genesis\/genesis.json  # DISABLED: prevent reverse copy/' \
            "$BOOTSTRAP_FILE" > "${BOOTSTRAP_FILE}.fixed"

        log_info "Fixed version saved to: bootstrap-fixed.sh"
        log_info "To apply: mv bootstrap-fixed.sh bootstrap.sh"
    else
        log_info "bootstrap.sh looks OK"
    fi
}

# ============================================
# Verify Final Configuration
# ============================================
verify_configuration() {
    log_step "Verifying final configuration..."

    GENESIS_TRUFFLE="$TRUFFLE_DIR/genesis/genesis.json"

    # Check chainId
    CHAIN_ID_CHECK=$(jq -r '.config.chainId' "$GENESIS_TRUFFLE")
    if [ "$CHAIN_ID_CHECK" != "$CHAIN_ID" ]; then
        log_error "ChainId verification failed: $CHAIN_ID_CHECK != $CHAIN_ID"
        exit 1
    fi
    log_info "✓ chainId: $CHAIN_ID_CHECK"

    # Check parlia config
    PARLIACONFIG_CHECK=$(jq -r '.config.parlia.period // empty' "$GENESIS_TRUFFLE")
    if [ -z "$PARLIACONFIG_CHECK" ]; then
        log_error "Parlia config verification failed"
        exit 1
    fi
    log_info "✓ parlia.period: $PARLIACONFIG_CHECK"

    # Check OTS contract
    OTS_CODE_CHECK=$(jq -r ".alloc[\"$OTS_ADDRESS\"].code // empty" "$GENESIS_TRUFFLE")
    OTS_CODE_SIZE=${#OTS_CODE_CHECK}
    if [ "$OTS_CODE_SIZE" -lt 1000 ]; then
        log_error "OTS contract code size too small: $OTS_CODE_SIZE"
        exit 1
    fi
    log_info "✓ OTS contract (0x9000): $OTS_CODE_SIZE bytes"

    # Check validator in alloc
    VALIDATOR_BALANCE=$(jq -r ".alloc[\"$VALIDATOR_ADDRESS\"].balance // empty" "$GENESIS_TRUFFLE")
    if [ -z "$VALIDATOR_BALANCE" ]; then
        log_warn "Validator address not in alloc (may be OK if using different validator)"
    else
        log_info "✓ Validator in alloc: $VALIDATOR_ADDRESS"
    fi

    # Check keystore
    KEYSTORE_DIR="$TRUFFLE_DIR/storage/keystore"
    if [ -d "$KEYSTORE_DIR" ] && [ -n "$(ls -A "$KEYSTORE_DIR" 2>/dev/null)" ]; then
        KEYSTORE_COUNT=$(ls -1 "$KEYSTORE_DIR" 2>/dev/null | wc -l)
        log_info "✓ Keystore files: $KEYSTORE_COUNT"
    else
        log_warn "Keystore directory empty or not found"
    fi

    log_info "Configuration verification complete ✓"
}

# ============================================
# Print Summary
# ============================================
print_summary() {
    echo ""
    echo "=========================================="
    echo "  Sync Complete!"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Chain ID:           $CHAIN_ID"
    echo "  OTS Contract:       $OTS_ADDRESS"
    echo "  Validator Address:  $VALIDATOR_ADDRESS"
    echo ""
    echo "Files updated:"
    echo "  - $TRUFFLE_DIR/genesis/genesis.json"
    echo "  - $TRUFFLE_DIR/storage/genesis.json"
    echo "  - $TRUFFLE_DIR/storage/keystore/"
    echo "  - $TRUFFLE_DIR/storage/address"
    echo ""
    echo "Next steps:"
    echo "  cd $RMC_DIR"
    echo "  make ots-test"
    echo ""
    echo "=========================================="
}

# ============================================
# Main Execution
# ============================================
main() {
    echo "=========================================="
    echo "  RMC Genesis Contract Sync"
    echo "  Contract -> Truffle Test Environment"
    echo "=========================================="
    echo ""

    check_prerequisites
    build_contracts
    generate_genesis
    setup_validator_keystore
    sync_genesis_files
    fix_bootstrap_script
    verify_configuration
    print_summary
}

main
