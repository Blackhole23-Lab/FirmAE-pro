#!/bin/bash
#
# download_toolchains.sh - Download and install Bootlin cross-compiler toolchains
# Downloads Bootlin toolchains for MIPS, ARM, and AArch64 architectures
#
# Usage:
#   sudo ./download_toolchains.sh           # Download all toolchains
#   sudo ./download_toolchains.sh --force   # Force re-download
#

set -euo pipefail

#=============================================================================
# Configuration
#=============================================================================

INSTALL_DIR="/opt/cross"
ENV_FILE="${INSTALL_DIR}/env.sh"
BOOTLIN_VERSION="2024.05-1"
BOOTLIN_FALLBACK_VERSION="2024.02-1"
BOOTLIN_BASE_URL="https://toolchains.bootlin.com/downloads/releases/toolchains"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }

FORCE=false

#=============================================================================
# Toolchain definitions
#=============================================================================

declare -A TOOLCHAINS=(
    ["mips32--musl"]="mips32/tarballs/mips32--musl--stable-${BOOTLIN_VERSION}.tar.xz"
    ["mips32el--musl"]="mips32el/tarballs/mips32el--musl--stable-${BOOTLIN_VERSION}.tar.xz"
    ["armv7-eabihf--glibc"]="armv7-eabihf/tarballs/armv7-eabihf--glibc--stable-${BOOTLIN_VERSION}.tar.xz"
    ["aarch64--glibc"]="aarch64/tarballs/aarch64--glibc--stable-${BOOTLIN_VERSION}.tar.xz"
)

declare -A TOOLCHAINS_FALLBACK=(
    ["mips32--musl"]="mips32/tarballs/mips32--musl--stable-${BOOTLIN_FALLBACK_VERSION}.tar.xz"
    ["mips32el--musl"]="mips32el/tarballs/mips32el--musl--stable-${BOOTLIN_FALLBACK_VERSION}.tar.xz"
    ["armv7-eabihf--glibc"]="armv7-eabihf/tarballs/armv7-eabihf--glibc--stable-${BOOTLIN_FALLBACK_VERSION}.tar.xz"
    ["aarch64--glibc"]="aarch64/tarballs/aarch64--glibc--stable-${BOOTLIN_FALLBACK_VERSION}.tar.xz"
)

#=============================================================================
# Root check
#=============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_err "This script must be run as root (use sudo)"
        exit 1
    fi
}

#=============================================================================
# Download and install a single toolchain
#=============================================================================

download_toolchain() {
    local name="$1"
    local url_path="$2"
    local full_url="${BOOTLIN_BASE_URL}/${url_path}"
    local tarball_name=$(basename "$url_path")
    local download_path="/tmp/${tarball_name}"
    local install_path="${INSTALL_DIR}/${name}"
    
    # Check if already installed
    if [ -d "$install_path" ] && [ "$FORCE" != true ]; then
        log_info "Toolchain already installed: ${name}"
        return 0
    fi
    
    log_info "Downloading ${name} toolchain..."
    log_info "  URL: ${full_url}"
    
    # Download with wget or curl
    if command -v wget &>/dev/null; then
        if ! wget --show-progress -O "$download_path" "$full_url" 2>&1; then
            log_err "Failed to download ${name} from ${full_url}"
            return 1
        fi
    elif command -v curl &>/dev/null; then
        if ! curl -L --progress-bar -o "$download_path" "$full_url" 2>&1; then
            log_err "Failed to download ${name} from ${full_url}"
            return 1
        fi
    else
        log_err "Neither wget nor curl found. Please install one of them."
        return 1
    fi
    
    # Verify download (basic file size check)
    local file_size=$(stat -c%s "$download_path" 2>/dev/null || stat -f%z "$download_path" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 10000000 ]; then  # Less than 10MB is suspicious
        log_err "Downloaded file seems too small (${file_size} bytes), may be corrupted"
        rm -f "$download_path"
        return 1
    fi
    
    log_ok "Downloaded ${tarball_name} (${file_size} bytes)"
    
    # Extract
    log_info "Extracting to ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"
    
    # Remove old installation if forcing
    if [ -d "$install_path" ]; then
        rm -rf "$install_path"
    fi
    
    # Extract to temp location first
    local temp_extract="/tmp/bootlin_extract_$$"
    mkdir -p "$temp_extract"
    
    if ! tar -xf "$download_path" -C "$temp_extract" 2>&1; then
        log_err "Failed to extract ${tarball_name}"
        rm -rf "$temp_extract"
        rm -f "$download_path"
        return 1
    fi
    
    # Find the extracted directory (Bootlin tarballs extract to a versioned directory)
    local extracted_dir=$(find "$temp_extract" -maxdepth 1 -type d -name "${name}--*" | head -1)
    
    if [ -z "$extracted_dir" ]; then
        log_err "Could not find extracted directory for ${name}"
        rm -rf "$temp_extract"
        rm -f "$download_path"
        return 1
    fi
    
    # Move to final location
    mv "$extracted_dir" "$install_path"
    rm -rf "$temp_extract"
    
    # Clean up tarball
    rm -f "$download_path"
    
    log_ok "Installed ${name} to ${install_path}"
    
    # Show GCC version
    local gcc_bin=$(find "$install_path" -type f -name "*-gcc" | head -1)
    if [ -n "$gcc_bin" ]; then
        local gcc_version=$("$gcc_bin" --version 2>/dev/null | head -1 || echo "unknown")
        log_ok "  GCC version: ${gcc_version}"
    fi
    
    return 0
}

#=============================================================================
# Create environment setup script
#=============================================================================

create_env_script() {
    log_info "Creating environment setup script: ${ENV_FILE}"
    
    cat > "$ENV_FILE" << 'ENVEOF'
#!/bin/bash
# Source this file to add Bootlin cross-compilers to PATH
# Usage: source /opt/cross/env.sh

for dir in /opt/cross/*/bin; do
    if [ -d "$dir" ]; then
        export PATH="${dir}:${PATH}"
    fi
done

echo "Bootlin toolchains added to PATH"
ENVEOF
    
    chmod +x "$ENV_FILE"
    log_ok "Created ${ENV_FILE}"
}

#=============================================================================
# Print summary
#=============================================================================

print_summary() {
    echo ""
    log_info "=========================================="
    log_info "Toolchain Installation Summary"
    log_info "=========================================="
    echo ""
    
    local total=0
    local installed=0
    
    for name in "${!TOOLCHAINS[@]}"; do
        total=$((total + 1))
        local install_path="${INSTALL_DIR}/${name}"
        
        if [ -d "$install_path" ]; then
            installed=$((installed + 1))
            local gcc_bin=$(find "$install_path" -type f -name "*-gcc" | head -1)
            
            if [ -n "$gcc_bin" ]; then
                local gcc_version=$("$gcc_bin" --version 2>/dev/null | head -1 || echo "unknown")
                local gcc_name=$(basename "$gcc_bin")
                echo -e "  ${GREEN}✓${NC} ${name}"
                echo -e "    Path: ${install_path}"
                echo -e "    GCC: ${gcc_name}"
                echo -e "    Version: ${gcc_version}"
                echo ""
            else
                echo -e "  ${YELLOW}?${NC} ${name} (installed but gcc not found)"
                echo ""
            fi
        else
            echo -e "  ${RED}✗${NC} ${name} (not installed)"
            echo ""
        fi
    done
    
    log_info "Installed: ${installed}/${total} toolchains"
    echo ""
    log_info "To use these toolchains, run:"
    log_info "  source ${ENV_FILE}"
    echo ""
}

#=============================================================================
# Main
#=============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                echo "Usage: sudo $0 [--force]"
                echo ""
                echo "Downloads and installs Bootlin cross-compiler toolchains for FirmAE."
                echo ""
                echo "Options:"
                echo "  --force    Force re-download and reinstall"
                echo "  --help     Show this help"
                echo ""
                echo "Toolchains:"
                echo "  - MIPS big-endian (musl)"
                echo "  - MIPS little-endian (musl)"
                echo "  - ARM v7 (glibc)"
                echo "  - AArch64 (glibc)"
                echo ""
                exit 0
                ;;
            *)
                log_err "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    check_root
    
    log_info "Starting Bootlin toolchain download and installation"
    log_info "Install directory: ${INSTALL_DIR}"
    log_info "Version: ${BOOTLIN_VERSION} (fallback: ${BOOTLIN_FALLBACK_VERSION})"
    echo ""
    
    local success=0
    local failed=0
    local failed_list=()
    
    # Download each toolchain
    for name in "${!TOOLCHAINS[@]}"; do
        if download_toolchain "$name" "${TOOLCHAINS[$name]}"; then
            success=$((success + 1))
        else
            log_warn "Primary download failed, trying fallback version..."
            if download_toolchain "$name" "${TOOLCHAINS_FALLBACK[$name]}"; then
                success=$((success + 1))
                log_ok "Fallback download succeeded for ${name}"
            else
                failed=$((failed + 1))
                failed_list+=("$name")
                log_err "Both primary and fallback downloads failed for ${name}"
            fi
        fi
        echo ""
    done
    
    # Create environment script
    create_env_script
    
    # Print summary
    print_summary
    
    if [ $failed -gt 0 ]; then
        log_err "Failed to install ${failed} toolchain(s):"
        for name in "${failed_list[@]}"; do
            log_err "  - ${name}"
        done
        exit 1
    fi
    
    log_ok "All toolchains installed successfully!"
    exit 0
}

main "$@"
