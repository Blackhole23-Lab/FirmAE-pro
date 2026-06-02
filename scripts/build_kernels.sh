#!/bin/bash
#
# build_kernels.sh - Automated kernel cross-compilation for FirmAE
# FirmAE 自动内核交叉编译脚本
#
# Builds Linux kernels with the firmadyne driver for firmware emulation.
# 为固件仿真构建带有 firmadyne 驱动的 Linux 内核。
#
# Usage / 用法:
#   ./build_kernels.sh all              # Build all arch/version combinations
#                                       # 构建所有架构/版本组合
#   ./build_kernels.sh <arch> <version> # Build specific (e.g., mipsel 4.9)
#                                       # 构建指定组合
#   ./build_kernels.sh list             # List available/built combinations
#                                       # 列出所有可用/已构建的组合
#   ./build_kernels.sh clean            # Remove build temp files
#                                       # 清理构建临时文件
#
# Options / 选项:
#   --force    Force rebuild even if kernel already exists / 强制重新构建
#   --jobs N   Parallel make jobs (default: nproc) / 并行编译任务数
#

set -euo pipefail

#=============================================================================
# Configuration / 配置
#=============================================================================

FIRMAE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${FIRMAE_DIR}/scripts"
KERNEL_OUT_DIR="${FIRMAE_DIR}/binaries/kernels"
BUILD_DIR="/tmp/firmae_kernel_build"
LOG_DIR="${BUILD_DIR}/logs"
PATCH_DIR="${SCRIPT_DIR}/kernel_patches"

# Source Bootlin toolchain environment if available
if [ -f /opt/cross/env.sh ]; then
    source /opt/cross/env.sh
fi

# FirmAE kernel repos (contain firmadyne driver + configs)
# FirmAE 内核仓库（包含 firmadyne 驱动和配置文件）
FIRMAE_KERNEL_V41="https://github.com/pr0v3rbs/FirmAE_kernel-v4.1"
FIRMAE_KERNEL_V26="https://github.com/pr0v3rbs/FirmAE_kernel-v2.6"

# Vanilla kernel source CDN / 原版内核源码 CDN
KERNEL_CDN="https://cdn.kernel.org/pub/linux/kernel"

# Default parallel jobs / 默认并行编译数
JOBS=$(nproc 2>/dev/null || echo 4)
FORCE=false

#=============================================================================
# Color output helpers / 彩色输出辅助函数
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color / 无颜色

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_build() { echo -e "${CYAN}[BUILD]${NC} $*"; }

#=============================================================================
# Kernel version mapping / 内核版本映射
# Maps major version to exact release version
# 将主版本号映射到精确的发布版本
#=============================================================================

declare -A KERNEL_VERSIONS=(
    ["2.6"]="2.6.32.71"
    ["3.10"]="3.10.108"
    ["4.1"]="4.1.17"
    ["4.4"]="4.4.298"
    ["4.9"]="4.9.337"
    ["4.14"]="4.14.302"
    ["4.19"]="4.19.269"
    ["5.4"]="5.4.228"
    ["5.10"]="5.10.163"
)

#=============================================================================
# Architecture / version matrix / 架构-版本矩阵
# Defines which kernel versions are valid for each architecture
# 定义每个架构支持的内核版本
#=============================================================================

declare -A ARCH_VERSIONS=(
    ["mipseb"]="2.6 3.10 4.1 4.4 4.9"
    ["mipsel"]="2.6 3.10 4.1 4.4 4.9"
    ["armel"]="2.6 3.10 4.1 4.4 4.9 4.14 4.19"
    ["armhf"]="2.6 3.10 4.1 4.4 4.9 4.14 4.19"
    ["aarch64"]="4.14 4.19 5.4 5.10"
)

#=============================================================================
# Cross-compiler mapping / 交叉编译器映射
# Maps FirmAE arch names to kernel ARCH and CROSS_COMPILE values
# 将 FirmAE 架构名映射到内核 ARCH 和 CROSS_COMPILE 值
#=============================================================================

get_kernel_arch() {
    case "$1" in
        mipseb|mipsel) echo "mips" ;;
        armel|armhf)   echo "arm" ;;
        aarch64)       echo "arm64" ;;
        *) log_err "Unknown architecture: $1"; return 1 ;;
    esac
}

get_cross_compile() {
    case "$1" in
        mipseb)
            # Try Bootlin musl, then standard musl, fall back to gnu
            # 尝试 Bootlin musl，然后标准 musl，回退到 gnu
            if command -v mips-buildroot-linux-musl-gcc &>/dev/null; then
                echo "mips-buildroot-linux-musl-"
            elif command -v mipseb-linux-musl-gcc &>/dev/null; then
                echo "mipseb-linux-musl-"
            elif command -v mips-linux-musl-gcc &>/dev/null; then
                echo "mips-linux-musl-"
            elif command -v mips-linux-gnu-gcc &>/dev/null; then
                echo "mips-linux-gnu-"
            else
                echo ""
            fi
            ;;
        mipsel)
            # Try Bootlin musl, then standard musl, fall back to gnu
            if command -v mipsel-buildroot-linux-musl-gcc &>/dev/null; then
                echo "mipsel-buildroot-linux-musl-"
            elif command -v mipsel-linux-musl-gcc &>/dev/null; then
                echo "mipsel-linux-musl-"
            elif command -v mipsel-linux-gnu-gcc &>/dev/null; then
                echo "mipsel-linux-gnu-"
            else
                echo ""
            fi
            ;;
        armel|armhf)
            # armhf shares armel kernel; try Bootlin, then standard toolchains
            # armhf 与 armel 共享内核，尝试 Bootlin，然后标准工具链
            if command -v arm-buildroot-linux-gnueabihf-gcc &>/dev/null; then
                echo "arm-buildroot-linux-gnueabihf-"
            elif command -v arm-linux-gnueabihf-gcc &>/dev/null; then
                echo "arm-linux-gnueabihf-"
            elif command -v arm-linux-gnueabi-gcc &>/dev/null; then
                echo "arm-linux-gnueabi-"
            else
                echo ""
            fi
            ;;
        aarch64)
            # Try Bootlin, then standard toolchain
            if command -v aarch64-buildroot-linux-gnu-gcc &>/dev/null; then
                echo "aarch64-buildroot-linux-gnu-"
            elif command -v aarch64-linux-gnu-gcc &>/dev/null; then
                echo "aarch64-linux-gnu-"
            else
                echo ""
            fi
            ;;
        *) echo "" ;;
    esac
}

#=============================================================================
# Output binary naming / 输出二进制文件命名
# Returns the expected kernel binary filename for a given architecture
# 返回给定架构的预期内核二进制文件名
#=============================================================================

get_kernel_binary_name() {
    local arch="$1"
    case "$arch" in
        mipseb)  echo "vmlinux.mipseb" ;;
        mipsel)  echo "vmlinux.mipsel" ;;
        armel)   echo "zImage.armel" ;;
        armhf)   echo "zImage.armhf" ;;
        aarch64) echo "Image.aarch64" ;;
    esac
}

# Also get the vmlinux (uncompressed) name for ARM/ARM64
# 同时获取 ARM/ARM64 的 vmlinux（未压缩）名称
get_vmlinux_name() {
    local arch="$1"
    case "$arch" in
        mipseb)  echo "vmlinux.mipseb" ;;
        mipsel)  echo "vmlinux.mipsel" ;;
        armel)   echo "vmlinux.armel" ;;
        armhf)   echo "vmlinux.armhf" ;;
        aarch64) echo "vmlinux.aarch64" ;;
    esac
}

#=============================================================================
# Toolchain check / 工具链检查
# Verifies required cross-compilers are installed
# 验证所需的交叉编译器是否已安装
#=============================================================================

check_toolchain() {
    local arch="$1"
    local cc
    cc=$(get_cross_compile "$arch")

    if [ -z "$cc" ]; then
        log_err "No cross-compiler found for ${arch}"
        case "$arch" in
            mipseb)
                log_err "  Install: apt-get install gcc-mips-linux-gnu"
                log_err "  Or Bootlin: run scripts/download_toolchains.sh"
                ;;
            mipsel)
                log_err "  Install: apt-get install gcc-mipsel-linux-gnu"
                log_err "  Or Bootlin: run scripts/download_toolchains.sh"
                ;;
            armel|armhf)
                log_err "  Install: apt-get install gcc-arm-linux-gnueabi"
                log_err "  Or Bootlin: run scripts/download_toolchains.sh"
                ;;
            aarch64)
                log_err "  Install: apt-get install gcc-aarch64-linux-gnu"
                log_err "  Or Bootlin: run scripts/download_toolchains.sh"
                ;;
        esac
        return 1
    fi

    log_ok "Cross-compiler for ${arch}: ${cc}gcc"
    return 0
}

check_all_toolchains() {
    local missing=0
    local checked=()

    for arch in "${!ARCH_VERSIONS[@]}"; do
        # armhf shares armel toolchain, skip duplicate check
        # armhf 与 armel 共享工具链，跳过重复检查
        if [ "$arch" = "armhf" ]; then
            continue
        fi
        if check_toolchain "$arch"; then
            checked+=("$arch")
        else
            missing=$((missing + 1))
        fi
    done

    if [ $missing -gt 0 ]; then
        log_warn "${missing} toolchain(s) missing. Builds for those architectures will be skipped."
        log_warn "缺少 ${missing} 个工具链。相关架构的构建将被跳过。"
    fi
    return 0
}

#=============================================================================
# Kernel source download / 内核源码下载
# Downloads vanilla kernel tarball from kernel.org
# 从 kernel.org 下载原版内核压缩包
#=============================================================================

get_kernel_url() {
    local full_ver="$1"
    local major="${full_ver%%.*}"
    # kernel.org layout: v2.6/ for 2.x, v3.x/ for 3.x, v4.x/ for 4.x, etc.
    # kernel.org 目录结构
    if [ "$major" = "2" ]; then
        echo "${KERNEL_CDN}/v2.6/linux-${full_ver}.tar.xz"
    else
        echo "${KERNEL_CDN}/v${major}.x/linux-${full_ver}.tar.xz"
    fi
}

download_kernel_source() {
    local ver="$1"
    local full_ver="${KERNEL_VERSIONS[$ver]}"
    local tarball="${BUILD_DIR}/linux-${full_ver}.tar.xz"
    local src_dir="${BUILD_DIR}/linux-${full_ver}"

    if [ -d "$src_dir" ] && [ ! "$FORCE" = true ]; then
        log_info "Kernel source already exists: ${src_dir}"
        log_info "内核源码已存在: ${src_dir}"
        return 0
    fi

    mkdir -p "$BUILD_DIR"

    if [ ! -f "$tarball" ]; then
        local url
        url=$(get_kernel_url "$full_ver")
        log_info "Downloading kernel ${full_ver} from ${url}"
        log_info "正在下载内核 ${full_ver}"
        if ! wget -q --show-progress -O "$tarball" "$url"; then
            log_err "Failed to download kernel ${full_ver}"
            log_err "下载内核 ${full_ver} 失败"
            rm -f "$tarball"
            return 1
        fi
        log_ok "Downloaded: ${tarball}"
    fi

    if [ -d "$src_dir" ]; then
        rm -rf "$src_dir"
    fi

    # Verify tarball is valid before extracting
    # 解压前验证 tarball 是否有效
    local filesize
    filesize=$(stat -c%s "$tarball" 2>/dev/null || echo 0)
    if [ "$filesize" -lt 1000000 ]; then
        log_err "Downloaded file too small (${filesize} bytes), likely corrupted"
        log_err "下载文件过小（${filesize} 字节），可能已损坏"
        rm -f "$tarball"
        # Retry download once
        log_info "Retrying download..."
        if ! wget -q --show-progress -O "$tarball" "$url"; then
            log_err "Retry download also failed"
            rm -f "$tarball"
            return 1
        fi
    fi

    # Verify tarball integrity
    if ! xz -t "$tarball" 2>/dev/null; then
        log_err "Tarball integrity check failed: ${tarball}"
        log_err "Tarball 完整性检查失败"
        rm -f "$tarball"
        return 1
    fi

    log_info "Extracting kernel source..."
    log_info "正在解压内核源码..."
    if ! tar -xf "$tarball" -C "$BUILD_DIR"; then
        log_err "Failed to extract tarball: ${tarball}"
        log_err "解压 tarball 失败"
        rm -f "$tarball"
        return 1
    fi
    log_ok "Extracted to: ${src_dir}"
    return 0
}

#=============================================================================
# FirmAE kernel repo management / FirmAE 内核仓库管理
# Clones the FirmAE kernel repos to get firmadyne driver and configs
# 克隆 FirmAE 内核仓库以获取 firmadyne 驱动和配置文件
#=============================================================================

clone_firmae_kernel_repos() {
    local repo_v41_dir="${BUILD_DIR}/FirmAE_kernel-v4.1"
    local repo_v26_dir="${BUILD_DIR}/FirmAE_kernel-v2.6"

    mkdir -p "$BUILD_DIR"

    # Clone v4.1 repo (has firmadyne driver for ARM + MIPS)
    # 克隆 v4.1 仓库（包含 ARM + MIPS 的 firmadyne 驱动）
    if [ ! -d "$repo_v41_dir" ]; then
        log_info "Cloning FirmAE_kernel-v4.1 repository..."
        log_info "正在克隆 FirmAE_kernel-v4.1 仓库..."
        if ! git clone --depth 1 "$FIRMAE_KERNEL_V41" "$repo_v41_dir" 2>&1; then
            log_err "Failed to clone FirmAE_kernel-v4.1"
            return 1
        fi
        log_ok "Cloned FirmAE_kernel-v4.1"
    else
        log_info "FirmAE_kernel-v4.1 already cloned"
    fi

    # Clone v2.6 repo (MIPS-specific for 2.6.x kernels)
    # 克隆 v2.6 仓库（2.6.x 内核专用，仅 MIPS）
    if [ ! -d "$repo_v26_dir" ]; then
        log_info "Cloning FirmAE_kernel-v2.6 repository..."
        log_info "正在克隆 FirmAE_kernel-v2.6 仓库..."
        if ! git clone --depth 1 "$FIRMAE_KERNEL_V26" "$repo_v26_dir" 2>&1; then
            log_err "Failed to clone FirmAE_kernel-v2.6"
            return 1
        fi
        log_ok "Cloned FirmAE_kernel-v2.6"
    else
        log_info "FirmAE_kernel-v2.6 already cloned"
    fi

    return 0
}

#=============================================================================
# Install firmadyne driver into kernel tree / 将 firmadyne 驱动安装到内核树
# Copies the firmadyne driver source from the FirmAE kernel repo into
# the vanilla kernel source tree and hooks it into the build system.
# 将 firmadyne 驱动源码从 FirmAE 内核仓库复制到原版内核源码树中，
# 并将其接入构建系统。
#=============================================================================

install_firmadyne_driver() {
    local src_dir="$1"   # vanilla kernel source directory
    local ver="$2"       # major version (e.g., "4.1")
    local arch="$3"      # FirmAE arch name

    local repo_v41_dir="${BUILD_DIR}/FirmAE_kernel-v4.1"
    local repo_v26_dir="${BUILD_DIR}/FirmAE_kernel-v2.6"
    local driver_dest="${src_dir}/drivers/firmadyne"

    # For 2.6.x MIPS: use the v2.6 repo directly (it has the right driver)
    # 对于 2.6.x MIPS：直接使用 v2.6 仓库（它有正确的驱动）
    if [ "$ver" = "2.6" ]; then
        if [ -d "${repo_v26_dir}/drivers/firmadyne" ]; then
            log_info "Installing firmadyne driver from v2.6 repo"
            rm -rf "$driver_dest"
            cp -r "${repo_v26_dir}/drivers/firmadyne" "$driver_dest"
        else
            log_err "firmadyne driver not found in v2.6 repo"
            return 1
        fi
    else
        # For all other versions: use the v4.1 repo driver as base
        # 对于其他版本：使用 v4.1 仓库的驱动作为基础
        if [ -d "${repo_v41_dir}/drivers/firmadyne" ]; then
            log_info "Installing firmadyne driver from v4.1 repo"
            rm -rf "$driver_dest"
            cp -r "${repo_v41_dir}/drivers/firmadyne" "$driver_dest"
        else
            log_err "firmadyne driver not found in v4.1 repo"
            return 1
        fi
    fi

    # Hook firmadyne into the kernel build system
    # 将 firmadyne 接入内核构建系统
    # Add to drivers/Makefile if not already present
    if ! grep -q "firmadyne" "${src_dir}/drivers/Makefile" 2>/dev/null; then
        log_info "Adding firmadyne to drivers/Makefile"
        echo 'obj-y += firmadyne/' >> "${src_dir}/drivers/Makefile"
    fi

    # Add to drivers/Kconfig if not already present
    if ! grep -q "firmadyne" "${src_dir}/drivers/Kconfig" 2>/dev/null; then
        log_info "Adding firmadyne to drivers/Kconfig"
        # Insert before the final endmenu
        sed -i '/^endmenu/i source "drivers/firmadyne/Kconfig"' \
            "${src_dir}/drivers/Kconfig" 2>/dev/null || true
    fi

    # Ensure firmadyne has a Kconfig if missing
    # 确保 firmadyne 有 Kconfig 文件
    if [ ! -f "${driver_dest}/Kconfig" ]; then
        cat > "${driver_dest}/Kconfig" << 'KCONFIG_EOF'
config FIRMADYNE
    bool "Firmadyne firmware analysis kernel module"
    default y
    help
      Kernel hooks for firmware emulation (FirmAE/firmadyne).
KCONFIG_EOF
    fi

    # Ensure firmadyne has a Makefile
    if [ ! -f "${driver_dest}/Makefile" ]; then
        cat > "${driver_dest}/Makefile" << 'MAKE_EOF'
obj-y := firmadyne.o
MAKE_EOF
    fi

    log_ok "firmadyne driver installed into kernel tree"
    return 0
}

#=============================================================================
# Compatibility patching / 兼容性补丁
# Adapts the firmadyne driver for different kernel versions.
# 为不同内核版本适配 firmadyne 驱动。
#
# Version ranges and required changes / 版本范围和所需更改:
#   2.6.x  : Use v2.6 repo directly (different kprobe/VFS API)
#             直接使用 v2.6 仓库
#   3.10.x : Similar to 4.1, minor API differences
#             与 4.1 类似，少量 API 差异
#   4.1.x  : Reference version, no patches needed
#             参考版本，无需补丁
#   4.4-4.9: Very similar to 4.1, minimal changes
#             与 4.1 非常相似，极少更改
#   4.14.x : Last version with jprobes
#             最后一个支持 jprobes 的版本
#   4.15+  : jprobes removed, need kretprobes
#             jprobes 已移除，需要 kretprobes
#   5.x    : access_ok() signature change, set_fs() changes
#             access_ok() 签名变更，set_fs() 变更
#=============================================================================

apply_firmadyne_compat_patches() {
    local src_dir="$1"
    local ver="$2"
    local driver_dir="${src_dir}/drivers/firmadyne"

    # No driver source to patch
    if [ ! -d "$driver_dir" ]; then
        log_warn "No firmadyne driver directory found, skipping patches"
        return 0
    fi

    local firmadyne_c="${driver_dir}/firmadyne.c"
    if [ ! -f "$firmadyne_c" ]; then
        log_warn "firmadyne.c not found in ${driver_dir}"
        return 0
    fi

    log_info "Applying compatibility patches for kernel ${ver}"
    log_info "正在应用内核 ${ver} 的兼容性补丁"

    # --- Kernel 4.15+: Replace jprobes with kretprobes ---
    # --- 内核 4.15+：将 jprobes 替换为 kretprobes ---
    # jprobes were removed in 4.15. We replace them with kretprobes/kprobes.
    # jprobes 在 4.15 中被移除，用 kretprobes/kprobes 替代。
    # Patch ALL .c files in the firmadyne driver directory (not just firmadyne.c)
    # 补丁应用到 firmadyne 驱动目录中的所有 .c 文件
    case "$ver" in
        4.19|5.4|5.10)
            log_info "  Patching: jprobes -> kretprobes (4.15+ compat)"
            local patched_jprobe=false
            for src_file in "${driver_dir}"/*.c; do
                [ -f "$src_file" ] || continue
                if grep -q "jprobe" "$src_file" 2>/dev/null; then
                    log_info "    Patching $(basename $src_file)"
                    sed -i 's/struct jprobe/struct kretprobe/g' "$src_file"
                    sed -i 's/register_jprobe/register_kretprobe/g' "$src_file"
                    sed -i 's/unregister_jprobe/unregister_kretprobe/g' "$src_file"
                    sed -i 's/jprobe_return/kretprobe_return/g' "$src_file"
                    sed -i 's/\.entry\s*=/.handler =/g' "$src_file"
                    sed -i 's|#include <linux/jprobes.h>|#include <linux/kprobes.h>|g' \
                        "$src_file" 2>/dev/null || true
                    patched_jprobe=true
                fi
            done
            if $patched_jprobe; then
                log_ok "  jprobes -> kretprobes patching done"
            else
                log_info "  No jprobe references found, skipping"
            fi
            ;;&  # fall through to check more patches
    esac

    # --- Kernel 5.x: access_ok() signature change ---
    # --- 内核 5.x：access_ok() 签名变更 ---
    # In 5.0+, access_ok() lost its first 'type' argument:
    #   Old: access_ok(type, addr, size)
    #   New: access_ok(addr, size)
    # 在 5.0+ 中，access_ok() 移除了第一个 'type' 参数
    case "$ver" in
        5.4|5.10)
            log_info "  Patching: access_ok() signature (5.0+ compat)"
            # Remove VERIFY_READ/VERIFY_WRITE first arg from access_ok calls
            sed -i 's/access_ok(\s*VERIFY_READ\s*,\s*/access_ok(/g' "$firmadyne_c"
            sed -i 's/access_ok(\s*VERIFY_WRITE\s*,\s*/access_ok(/g' "$firmadyne_c"
            log_ok "  access_ok() patching done"
            ;;&
    esac

    # --- Kernel 5.10+: set_fs() / get_fs() removal ---
    # --- 内核 5.10+：set_fs() / get_fs() 移除 ---
    # set_fs()/get_fs() were removed in 5.10 for most architectures.
    # Replace with kernel_read/kernel_write or remove addr_limit manipulation.
    # set_fs()/get_fs() 在 5.10 中被移除（大多数架构）
    case "$ver" in
        5.10)
            log_info "  Patching: set_fs/get_fs removal (5.10+ compat)"
            # Comment out set_fs/get_fs calls and replace with safe alternatives
            sed -i 's/^\(\s*\)mm_segment_t\s\+old_fs/\1\/\/ mm_segment_t old_fs/' \
                "$firmadyne_c" 2>/dev/null || true
            sed -i 's/^\(\s*\)old_fs\s*=\s*get_fs/\1\/\/ old_fs = get_fs/' \
                "$firmadyne_c" 2>/dev/null || true
            sed -i 's/^\(\s*\)set_fs\s*(KERNEL_DS)/\1\/\/ set_fs(KERNEL_DS)/' \
                "$firmadyne_c" 2>/dev/null || true
            sed -i 's/^\(\s*\)set_fs\s*(old_fs)/\1\/\/ set_fs(old_fs)/' \
                "$firmadyne_c" 2>/dev/null || true
            log_ok "  set_fs/get_fs patching done"
            ;;&
    esac

    # --- Kernel 4.14+: timer API changes ---
    # --- 内核 4.14+：定时器 API 变更 ---
    # setup_timer() was replaced with timer_setup() in 4.14
    # setup_timer() 在 4.14 中被 timer_setup() 替代
    case "$ver" in
        4.14|4.19|5.4|5.10)
            if grep -q "setup_timer" "$firmadyne_c" 2>/dev/null; then
                log_info "  Patching: setup_timer -> timer_setup (4.14+ compat)"
                sed -i 's/setup_timer(\([^,]*\),\s*\([^,]*\),\s*\([^)]*\))/timer_setup(\1, \2, 0)/g' \
                    "$firmadyne_c" 2>/dev/null || true
                log_ok "  timer API patching done"
            fi
            ;;&
    esac

    # --- Kernel 3.10.x: proc_create compatibility ---
    # --- 内核 3.10.x：proc_create 兼容性 ---
    case "$ver" in
        3.10)
            log_info "  Applying 3.10.x compatibility adjustments"
            # 3.10 may need PDE_DATA -> PDE()->data for older proc API
            # Typically the v4.1 driver already handles this, but just in case
            if grep -q "PDE_DATA" "$firmadyne_c" 2>/dev/null; then
                # Check if PDE_DATA is defined in this kernel
                if ! grep -rq "PDE_DATA" "${src_dir}/include/" 2>/dev/null; then
                    log_info "  Patching: PDE_DATA -> PDE()->data"
                    sed -i 's/PDE_DATA(\([^)]*\))/PDE(\1)->data/g' "$firmadyne_c"
                fi
            fi
            log_ok "  3.10.x compatibility done"
            ;;
    esac

    log_ok "Compatibility patches applied for kernel ${ver}"
    return 0
}

#=============================================================================
# GCC 10+ compatibility / GCC 10+ 兼容性
# Old kernels (< 4.9) include compiler-gcc{N}.h which may not exist for
# newer GCC versions. Create missing headers by copying the latest one.
# 旧内核（< 4.9）会包含 compiler-gcc{N}.h，新版 GCC 可能缺少该文件。
#=============================================================================

fix_gcc_compat() {
    local KERNEL_SRC="${1}"
    local GCC_VER=$(${CROSS_COMPILE}gcc -dumpversion | cut -d. -f1)
    local COMPILER_DIR="${KERNEL_SRC}/include/linux"

    # For kernels that don't have compiler-gcc{N}.h for our GCC version
    for ver in $(seq 10 ${GCC_VER}); do
        if [ ! -f "${COMPILER_DIR}/compiler-gcc${ver}.h" ]; then
            # Find the highest existing compiler-gcc*.h and copy it
            local LATEST=$(ls ${COMPILER_DIR}/compiler-gcc*.h 2>/dev/null | sort -V | tail -1)
            if [ -n "${LATEST}" ]; then
                cp "${LATEST}" "${COMPILER_DIR}/compiler-gcc${ver}.h"
                log_info "Created ${COMPILER_DIR}/compiler-gcc${ver}.h from $(basename ${LATEST})"
            fi
        fi
    done
}

#=============================================================================
# Kernel config generation / 内核配置生成
# Generates .config for the target arch/version combination.
# Uses existing configs from FirmAE kernel repos as base, then adapts.
# 为目标架构/版本组合生成 .config。
# 使用 FirmAE 内核仓库中的现有配置作为基础，然后进行适配。
#=============================================================================

generate_kernel_config() {
    local src_dir="$1"
    local ver="$2"
    local arch="$3"
    local karch
    karch=$(get_kernel_arch "$arch")

    local repo_v41_dir="${BUILD_DIR}/FirmAE_kernel-v4.1"
    local repo_v26_dir="${BUILD_DIR}/FirmAE_kernel-v2.6"
    local config_src=""

    # Find the best matching config from FirmAE kernel repos
    # 从 FirmAE 内核仓库中找到最匹配的配置
    local config_name=""
    case "$arch" in
        mipseb)  config_name="config.mipseb" ;;
        mipsel)  config_name="config.mipsel" ;;
        armel)   config_name="config.armel" ;;
        armhf)   config_name="config.armel" ;;  # armhf uses armel config
        aarch64) config_name="config.aarch64" ;;
    esac

    # Try to find config in the appropriate repo
    # 尝试在相应的仓库中查找配置
    if [ "$ver" = "2.6" ]; then
        config_src="${repo_v26_dir}/${config_name}"
        if [ ! -f "$config_src" ]; then
            # Try alternate naming
            config_src=$(find "${repo_v26_dir}" -maxdepth 1 -name "config.*${arch}*" \
                -o -name ".config.*${arch}*" 2>/dev/null | head -1)
        fi
    else
        config_src="${repo_v41_dir}/${config_name}"
        if [ ! -f "$config_src" ]; then
            config_src=$(find "${repo_v41_dir}" -maxdepth 1 -name "config.*${arch}*" \
                -o -name ".config.*${arch}*" 2>/dev/null | head -1)
        fi
    fi

    if [ -n "$config_src" ] && [ -f "$config_src" ]; then
        log_info "Using base config: ${config_src}"
        cp "$config_src" "${src_dir}/.config"
    else
        log_warn "No base config found for ${arch}, generating default"
        log_warn "未找到 ${arch} 的基础配置，生成默认配置"
        # Generate a default config with essential options
        # 生成包含基本选项的默认配置
        local cross_compile
        cross_compile=$(get_cross_compile "$arch")
        make -C "$src_dir" ARCH="$karch" CROSS_COMPILE="$cross_compile" \
            defconfig 2>&1 | tail -5
    fi

    # Ensure essential options for FirmAE are enabled
    # 确保 FirmAE 所需的基本选项已启用
    local config_file="${src_dir}/.config"

    # Enable kprobes (required for firmadyne driver)
    # 启用 kprobes（firmadyne 驱动所需）
    ensure_config_option "$config_file" "CONFIG_KPROBES" "y"
    ensure_config_option "$config_file" "CONFIG_MODULES" "y"
    ensure_config_option "$config_file" "CONFIG_MODULE_UNLOAD" "y"

    # Enable networking essentials / 启用网络基本功能
    ensure_config_option "$config_file" "CONFIG_NET" "y"
    ensure_config_option "$config_file" "CONFIG_INET" "y"
    ensure_config_option "$config_file" "CONFIG_PACKET" "y"
    ensure_config_option "$config_file" "CONFIG_UNIX" "y"
    ensure_config_option "$config_file" "CONFIG_BRIDGE" "y"

    # Enable block device support / 启用块设备支持
    ensure_config_option "$config_file" "CONFIG_BLK_DEV" "y"
    ensure_config_option "$config_file" "CONFIG_EXT2_FS" "y"
    ensure_config_option "$config_file" "CONFIG_EXT3_FS" "y"
    ensure_config_option "$config_file" "CONFIG_EXT4_FS" "y"

    # Enable proc/sys filesystems / 启用 proc/sys 文件系统
    ensure_config_option "$config_file" "CONFIG_PROC_FS" "y"
    ensure_config_option "$config_file" "CONFIG_SYSFS" "y"

    # Enable NAND simulator (used by FirmAE for flash emulation)
    # 启用 NAND 模拟器（FirmAE 用于闪存仿真）
    ensure_config_option "$config_file" "CONFIG_MTD" "y"
    ensure_config_option "$config_file" "CONFIG_MTD_NAND" "y"

    # Architecture-specific options / 架构特定选项
    case "$arch" in
        mipseb|mipsel)
            ensure_config_option "$config_file" "CONFIG_MIPS_MALTA" "y"
            # E1000 network driver for MIPS Malta
            ensure_config_option "$config_file" "CONFIG_E1000" "y"
            # IDE for MIPS disk
            ensure_config_option "$config_file" "CONFIG_IDE" "y"
            ensure_config_option "$config_file" "CONFIG_BLK_DEV_IDE" "y"
            # Disable ATA/AHCI - causes BUILD_BUG_ON on 32-bit MIPS (kernel 4.9+)
            # MIPS Malta uses IDE, not SATA
            ensure_config_option "$config_file" "CONFIG_ATA" "n"
            ;;
        armel|armhf)
            # Virtio for ARM virt machine
            ensure_config_option "$config_file" "CONFIG_VIRTIO" "y"
            ensure_config_option "$config_file" "CONFIG_VIRTIO_BLK" "y"
            ensure_config_option "$config_file" "CONFIG_VIRTIO_NET" "y"
            ensure_config_option "$config_file" "CONFIG_ARCH_VIRT" "y"
            ;;
        aarch64)
            # Virtio for ARM64 virt machine
            ensure_config_option "$config_file" "CONFIG_VIRTIO" "y"
            ensure_config_option "$config_file" "CONFIG_VIRTIO_BLK" "y"
            ensure_config_option "$config_file" "CONFIG_VIRTIO_NET" "y"
            ;;
    esac

    # Run olddefconfig (or silentoldconfig for older kernels) to resolve dependencies
    # 运行 olddefconfig（或旧内核的 silentoldconfig）解决缺失的依赖
    local cross_compile
    cross_compile=$(get_cross_compile "$arch")

    # olddefconfig was introduced in kernel 3.12, use alternatives for older kernels
    # olddefconfig 在 3.12 引入，旧内核使用替代方案
    local config_target="olddefconfig"
    local major_ver=$(echo "$ver" | cut -d. -f1)
    local minor_ver=$(echo "$ver" | cut -d. -f2)
    if [ "$major_ver" -lt 3 ] || ([ "$major_ver" -eq 3 ] && [ "$minor_ver" -lt 12 ]); then
        config_target="oldconfig"
    fi

    if [ "$config_target" = "oldconfig" ]; then
        # Use yes "" to auto-accept defaults for oldconfig
        yes "" 2>/dev/null | make -C "$src_dir" ARCH="$karch" CROSS_COMPILE="$cross_compile" \
            oldconfig 2>&1 | tail -3 || true
    else
        make -C "$src_dir" ARCH="$karch" CROSS_COMPILE="$cross_compile" \
            olddefconfig 2>&1 | tail -3 || true
    fi

    log_ok "Kernel config generated for ${arch} ${ver}"
    return 0
}

# Helper: ensure a config option is set / 辅助函数：确保配置选项已设置
ensure_config_option() {
    local config_file="$1"
    local option="$2"
    local value="$3"

    if grep -q "^${option}=" "$config_file" 2>/dev/null; then
        # Option exists, update it / 选项已存在，更新它
        sed -i "s/^${option}=.*/${option}=${value}/" "$config_file"
    elif grep -q "^# ${option} is not set" "$config_file" 2>/dev/null; then
        # Option is explicitly disabled, enable it / 选项被显式禁用，启用它
        sed -i "s/^# ${option} is not set/${option}=${value}/" "$config_file"
    else
        # Option not present, add it / 选项不存在，添加它
        echo "${option}=${value}" >> "$config_file"
    fi
}

#=============================================================================
# Main build function / 主构建函数
# Builds a single kernel for a given arch/version combination.
# 为给定的架构/版本组合构建单个内核。
#=============================================================================

build_kernel() {
    local arch="$1"
    local ver="$2"
    local full_ver="${KERNEL_VERSIONS[$ver]}"
    local karch
    karch=$(get_kernel_arch "$arch")
    local cross_compile
    cross_compile=$(get_cross_compile "$arch")

    local src_dir="${BUILD_DIR}/linux-${full_ver}"
    local out_dir="${KERNEL_OUT_DIR}/${arch}/${ver}"
    local log_file="${LOG_DIR}/${arch}_${ver}.log"
    local kernel_bin
    kernel_bin=$(get_kernel_binary_name "$arch")
    local vmlinux_name
    vmlinux_name=$(get_vmlinux_name "$arch")

    log_build "=========================================="
    log_build "Building kernel: ${arch} ${ver} (${full_ver})"
    log_build "构建内核: ${arch} ${ver} (${full_ver})"
    log_build "=========================================="

    # armhf shares armel kernel - just copy if armel is already built
    # armhf 与 armel 共享内核 - 如果 armel 已构建则直接复制
    if [ "$arch" = "armhf" ]; then
        local armel_dir="${KERNEL_OUT_DIR}/armel/${ver}"
        if [ -f "${armel_dir}/zImage.armel" ]; then
            log_info "armhf shares armel kernel, copying from armel build"
            log_info "armhf 与 armel 共享内核，从 armel 构建复制"
            mkdir -p "$out_dir"
            cp "${armel_dir}/zImage.armel" "${out_dir}/zImage.armhf"
            cp "${armel_dir}/vmlinux.armel" "${out_dir}/vmlinux.armhf" 2>/dev/null || true
            log_ok "Copied armel kernel to armhf: ${out_dir}"
            return 0
        else
            log_warn "armel kernel not yet built for ${ver}, building as armel first"
            build_kernel "armel" "$ver"
            # Now copy
            if [ -f "${armel_dir}/zImage.armel" ]; then
                mkdir -p "$out_dir"
                cp "${armel_dir}/zImage.armel" "${out_dir}/zImage.armhf"
                cp "${armel_dir}/vmlinux.armel" "${out_dir}/vmlinux.armhf" 2>/dev/null || true
                log_ok "Copied armel kernel to armhf: ${out_dir}"
                return 0
            else
                log_err "Failed to build armel kernel for armhf copy"
                return 1
            fi
        fi
    fi

    # Check if already built (skip unless --force)
    # 检查是否已构建（除非使用 --force 否则跳过）
    if [ -f "${out_dir}/${kernel_bin}" ] && [ "$FORCE" != true ]; then
        log_ok "Kernel already exists: ${out_dir}/${kernel_bin} (use --force to rebuild)"
        log_ok "内核已存在（使用 --force 强制重新构建）"
        return 0
    fi

    # Check cross-compiler availability
    # 检查交叉编译器是否可用
    if [ -z "$cross_compile" ]; then
        log_err "No cross-compiler for ${arch}, skipping"
        log_err "没有 ${arch} 的交叉编译器，跳过"
        return 1
    fi

    # Create log directory / 创建日志目录
    mkdir -p "$LOG_DIR"

    # Step 1: Download kernel source / 步骤 1：下载内核源码
    log_info "Step 1/5: Downloading kernel source"
    log_info "步骤 1/5：下载内核源码"
    if ! download_kernel_source "$ver"; then
        log_err "Failed to download kernel ${full_ver}"
        return 1
    fi

    # For 2.6.x with MIPS: use the FirmAE v2.6 repo tree directly
    # 对于 2.6.x MIPS：直接使用 FirmAE v2.6 仓库树
    if [ "$ver" = "2.6" ] && [[ "$arch" == mips* ]]; then
        local repo_v26_dir="${BUILD_DIR}/FirmAE_kernel-v2.6"
        if [ -d "$repo_v26_dir" ]; then
            log_info "Using FirmAE_kernel-v2.6 repo directly for ${arch} 2.6"
            src_dir="$repo_v26_dir"
        fi
    fi

    # Step 2: Install firmadyne driver / 步骤 2：安装 firmadyne 驱动
    log_info "Step 2/5: Installing firmadyne driver"
    log_info "步骤 2/5：安装 firmadyne 驱动"
    if ! install_firmadyne_driver "$src_dir" "$ver" "$arch"; then
        log_err "Failed to install firmadyne driver"
        return 1
    fi

    # Step 3: Apply compatibility patches / 步骤 3：应用兼容性补丁
    log_info "Step 3/6: Applying compatibility patches"
    log_info "步骤 3/6：应用兼容性补丁"
    if ! apply_firmadyne_compat_patches "$src_dir" "$ver"; then
        log_err "Failed to apply compatibility patches"
        return 1
    fi

    #=========================================================================
    # Step 3.5: Apply GCC/GAS/toolchain compatibility patches (BEFORE config)
    # 步骤 3.5：应用 GCC/GAS/工具链兼容性补丁（在生成配置之前）
    # All source-level patches must happen here, before any make command.
    # 所有源码级补丁必须在此处完成，在任何 make 命令之前。
    #=========================================================================
    log_info "Applying toolchain compatibility patches"

    local gcc_major
    gcc_major=$(${cross_compile}gcc -dumpversion 2>/dev/null | cut -d. -f1)

    # --- Patch 1: Remove -Werror globally ---
    # GCC 8+ produces new warnings that old kernels treat as errors.
    # Remove -Werror from all Kbuild/Makefile files and inject -Wno-error.
    # GCC 8+ 产生新警告，旧内核将其视为错误。全局移除 -Werror 并注入 -Wno-error。
    if [ -n "$gcc_major" ] && [ "$gcc_major" -ge 8 ] 2>/dev/null; then
        log_info "  [Patch 1/4] Removing -Werror for GCC ${gcc_major}"
        # Remove -Werror from arch/ Kbuild/Makefile files
        if [ -f "$src_dir/arch/mips/Kbuild" ]; then
            sed -i 's/-Werror//g' "$src_dir/arch/mips/Kbuild"
        fi
        find "$src_dir/arch" "$src_dir/drivers" \
            \( -name "Kbuild" -o -name "Makefile" \) 2>/dev/null | \
            xargs grep -l -- '-Werror' 2>/dev/null | while read -r f; do
                # Only remove standalone -Werror, not -Werror-foo (specific warning flags)
                sed -i 's/ -Werror / /g; s/ -Werror$//; s/^-Werror //; s/:= -Werror/:= /' "$f"
            done
        # Append -Wno-error to top-level Makefile (at the very end, safe from line-continuation)
        if ! grep -q '^KBUILD_CFLAGS += -Wno-error$' "$src_dir/Makefile" 2>/dev/null; then
            printf '\n# build_kernels.sh: suppress -Werror for modern GCC\nKBUILD_CFLAGS += -Wno-error\n' \
                >> "$src_dir/Makefile"
        fi
        # GCC 10+ changed default to -fno-common, breaking dtc (yylloc multiple definition)
        # Add -fcommon to HOSTCFLAGS to fix scripts/dtc build
        if ! grep -q '^HOSTCFLAGS += -fcommon$' "$src_dir/Makefile" 2>/dev/null; then
            printf '# build_kernels.sh: fix dtc yylloc multiple definition (GCC 10+)\nHOSTCFLAGS += -fcommon\n' \
                >> "$src_dir/Makefile"
        fi
        log_ok "  -Werror removed, -Wno-error injected"
    fi

    # --- Patch 1.5: ARM GCC 13+ register constraint fix ---
    # GCC 13 doesn't always respect 'register ... asm("r2")' constraints,
    # causing __put_user_x inline assembly to fail with .err in older kernels.
    # Inject -fno-ipa-sra into KBUILD_CFLAGS to prevent this optimization.
    # GCC 13 不总是尊重 register asm("r2") 约束，导致旧内核 __put_user_x 失败。
    if [[ "$arch" == arm* ]] && [ -n "$gcc_major" ] && [ "$gcc_major" -ge 13 ] 2>/dev/null; then
        if ! grep -q 'fno-ipa-sra' "$src_dir/Makefile" 2>/dev/null; then
            log_info "  [Patch 1.5] Adding -fno-ipa-sra for ARM GCC ${gcc_major}"
            printf '\n# build_kernels.sh: fix ARM register asm() constraint with GCC 13+\nKBUILD_CFLAGS += -fno-ipa-sra\n' \
                >> "$src_dir/Makefile"
            log_ok "  -fno-ipa-sra injected into Makefile"
        fi
    fi

    # --- Patch 2: MIPS -msoft-float vs FPU assembly ---
    # arch/mips/Makefile passes -msoft-float to KBUILD_AFLAGS via $(cflags-y).
    # Newer GAS (binutils 2.35+) strictly enforces this and rejects ALL FPU
    # data-transfer instructions (sdc1/ldc1/swc1/lwc1/mtc1) in assembly files.
    # Fix: filter out -msoft-float from KBUILD_AFLAGS at the Makefile level.
    # This covers ALL assembly files including headers like asmmacro-32.h.
    # arch/mips/Makefile 通过 $(cflags-y) 将 -msoft-float 传给 KBUILD_AFLAGS。
    # 新版 GAS 严格执行此标志，拒绝所有 FPU 数据传输指令。
    # 修复：在 Makefile 层面从 KBUILD_AFLAGS 中过滤掉 -msoft-float。
    if [[ "$arch" == mips* ]]; then
        local mips_makefile="$src_dir/arch/mips/Makefile"
        if [ -f "$mips_makefile" ]; then
            if ! grep -q 'filter-out.*-msoft-float.*KBUILD_AFLAGS' "$mips_makefile" 2>/dev/null; then
                log_info "  [Patch 2/4] Filtering -msoft-float from KBUILD_AFLAGS + setting -mfp32"
                # Replace: KBUILD_AFLAGS += $(cflags-y)
                # With:    KBUILD_AFLAGS += $(filter-out -msoft-float,$(cflags-y)) -Wa,-mfp32
                # -mfp32 sets FR=0 mode (32-bit FPU regs), allowing mtc1 to odd registers.
                # Without it, newer GAS defaults to -mfpxx which rejects odd FPU registers.
                sed -i 's|^KBUILD_AFLAGS\s*+=\s*$(cflags-y)|KBUILD_AFLAGS\t+= $(filter-out -msoft-float,$(cflags-y)) -Wa,-mfp32|' \
                    "$mips_makefile"
                log_ok "  -msoft-float filtered, -mfp32 added to KBUILD_AFLAGS"
            else
                log_info "  [Patch 2/4] KBUILD_AFLAGS already patched"
            fi
        fi
    fi

    # --- Patch 3: ARM assembly section flags (GAS 2.35+) ---
    # GAS 2.41 rejects BOTH #alloc and %alloc in .section directives.
    # Must convert to standard ELF string syntax: "ax", "aw", "a" etc.
    # GAS 2.41 拒绝 #alloc 和 %alloc。转换为标准 ELF 字符串语法。
    if [[ "$arch" == arm* ]]; then
        log_info "  [Patch 3/5] Fixing ARM assembly section flags -> ELF string syntax"
        # Use project-local copy (survives reboots), fallback to /tmp copy
        local FIX_SCRIPT="${FIRMAE_DIR}/kernel-sources/fix_section_flags.py"
        if [ ! -f "$FIX_SCRIPT" ]; then
            FIX_SCRIPT="/tmp/firmae_kernel_build/fix_section_flags.py"
        fi
        python3 "$FIX_SCRIPT" "$src_dir"
        log_ok "  ARM section flags converted to ELF string syntax"

        # --- Patch 3.5: ARM __put_user register constraint fix (GCC 13+) ---
        # GCC 13 doesn't always respect 'register ... asm("r2")' constraints
        # in __put_user_check macro, causing __asmeq verification to fail.
        # Fix: add compiler barrier after register variable declarations to
        # force GCC to materialize values in their declared registers.
        # GCC 13 不总是尊重 register asm("r2") 约束。
        # 修复：在寄存器变量声明后添加编译器屏障。
        if [ -n "$gcc_major" ] && [ "$gcc_major" -ge 13 ] 2>/dev/null; then
            local uaccess_h="$src_dir/arch/arm/include/asm/uaccess.h"
            if [ -f "$uaccess_h" ] && grep -q '__put_user_check' "$uaccess_h" 2>/dev/null; then
                if ! grep -q 'asm volatile.*__r2.*__p.*__l' "$uaccess_h" 2>/dev/null; then
                    log_info "  [Patch 3.5] Adding register barrier to __put_user_check"
                    # Use awk to insert barrier only in __put_user_check (not __get_user_check)
                    awk '
                    /^#define __put_user_check/ { in_put_user=1 }
                    in_put_user && /register int __e asm\("r0"\);/ && !barrier_added {
                        print
                        print "\t\tasm volatile(\"\" : : \"r\"(__r2), \"r\"(__p), \"r\"(__l));\t\t\\"
                        barrier_added=1
                        next
                    }
                    in_put_user && /^\})/ { in_put_user=0 }
                    { print }
                    ' "$uaccess_h" > "$uaccess_h.tmp" && mv "$uaccess_h.tmp" "$uaccess_h"
                    log_ok "  Register barrier added to __put_user_check"
                fi
            fi

            # Disable __asmeq checks for GCC 13+ (IPA-SRA breaks register constraints)
            # Skip if already using the enhanced 4.4-style __asmeq with register aliases
            local compiler_h="$src_dir/arch/arm/include/asm/compiler.h"
            if [ -f "$compiler_h" ] && grep -q '__asmeq' "$compiler_h" 2>/dev/null; then
                if grep -q 'fpr11\|r11fp' "$compiler_h" 2>/dev/null; then
                    log_info "  [Patch 3.6] Enhanced __asmeq already present (4.4-style)"
                elif ! grep -q '__asmeq.*""' "$compiler_h" 2>/dev/null; then
                    log_info "  [Patch 3.6] Disabling __asmeq for GCC 13+"
                    sed -i 's/#define __asmeq(x, y).*/#define __asmeq(x, y)  ""/' "$compiler_h"
                    log_ok "  __asmeq disabled for GCC 13+"
                fi
            fi
        fi
    fi
    if [[ "$arch" == mips* ]]; then
        local cp1emu="$src_dir/arch/mips/math-emu/cp1emu.c"
        if [ -f "$cp1emu" ] && grep -q '~(cop1_64bit' "$cp1emu" 2>/dev/null; then
            log_info "  [Patch 3/5] Fixing cp1emu.c ~(bool) expression"
            sed -i 's/~(cop1_64bit(xcp) == 0)/~(unsigned int)(cop1_64bit(xcp) == 0)/g' "$cp1emu"
            log_ok "  cp1emu.c patched"
        fi
    fi

    # --- Patch 4: GCC 10+ compiler-gcc{N}.h headers ---
    # Old kernels include version-specific compiler-gcc{N}.h that don't exist for GCC 10+.
    # Must be done before ANY make command (including make oldconfig).
    # 旧内核包含版本特定的 compiler-gcc{N}.h，GCC 10+ 缺少这些文件。
    log_info "  [Patch 4/4] Fixing GCC compatibility headers"
    CROSS_COMPILE="$cross_compile" fix_gcc_compat "$src_dir"
    log_ok "All toolchain patches applied"

    # Step 4: Clean previous build artifacts / 步骤 4：清理之前的构建产物
    log_info "Step 4/6: Cleaning build tree (mrproper)"
    log_info "步骤 4/6：清理构建树"
    make -C "$src_dir" ARCH="$karch" CROSS_COMPILE="$cross_compile" \
        mrproper 2>&1 | tail -3 || true

    # Re-apply GCC compat headers after mrproper (it removes generated files but not source)
    # mrproper removes .o/.cmd files but NOT source patches. However compiler-gcc*.h
    # headers we created might be in include/linux/ which mrproper doesn't touch.
    # Re-apply just in case.
    CROSS_COMPILE="$cross_compile" fix_gcc_compat "$src_dir"

    # Step 5: Generate kernel config / 步骤 5：生成内核配置
    log_info "Step 5/6: Generating kernel config"
    log_info "步骤 5/6：生成内核配置"
    if ! generate_kernel_config "$src_dir" "$ver" "$arch"; then
        log_err "Failed to generate kernel config"
        return 1
    fi

    # Step 6: Compile / 步骤 6：编译
    log_info "Step 6/6: Compiling kernel (jobs=${JOBS})"
    log_info "步骤 6/6：编译内核（并行数=${JOBS}）"
    log_info "Build log: ${log_file}"

    # Determine the make target based on architecture
    local make_target=""
    case "$arch" in
        mipseb|mipsel) make_target="vmlinux" ;;
        armel|armhf)   make_target="zImage vmlinux" ;;
        aarch64)       make_target="Image vmlinux" ;;
    esac

    # Extra KCFLAGS
    local kcflags=""
    if [ -n "$gcc_major" ] && [ "$gcc_major" -ge 8 ] 2>/dev/null; then
        kcflags="-Wno-error"
    fi
    if [ "$arch" = "mipseb" ]; then
        kcflags="${kcflags:+${kcflags} }-EB"
    fi
    # ARM + GCC 13: -fno-ipa-sra prevents GCC from optimizing away
    # register asm("rN") variable assignments, fixing __put_user_x
    # inline assembly register constraint failures in older kernels.
    # ARM + GCC 13：-fno-ipa-sra 防止 GCC 优化掉 register asm("rN")
    # 变量赋值，修复旧内核中 __put_user_x 内联汇编寄存器约束失败。
    if [[ "$arch" == arm* ]] && [ -n "$gcc_major" ] && [ "$gcc_major" -ge 13 ] 2>/dev/null; then
        kcflags="${kcflags:+${kcflags} }-fno-ipa-sra"
    fi

    # Build
    local build_failed=false
    if [ -n "$kcflags" ]; then
        if ! make -C "$src_dir" ARCH="$karch" CROSS_COMPILE="$cross_compile" \
            KCFLAGS="$kcflags" $make_target -j"$JOBS" >> "$log_file" 2>&1; then
            build_failed=true
        fi
    else
        if ! make -C "$src_dir" ARCH="$karch" CROSS_COMPILE="$cross_compile" \
            $make_target -j"$JOBS" >> "$log_file" 2>&1; then
            build_failed=true
        fi
    fi

    if $build_failed; then
        log_err "Kernel compilation failed! Check log: ${log_file}"
        log_err "内核编译失败！查看日志: ${log_file}"
        # Show last 20 lines of log for quick diagnosis
        # 显示日志最后 20 行以便快速诊断
        log_err "--- Last 20 lines of build log ---"
        tail -20 "$log_file" >&2
        return 1
    fi

    log_ok "Kernel compilation succeeded"
    log_ok "内核编译成功"

    # Step 6: Copy output binaries / 步骤 6：复制输出二进制文件
    mkdir -p "$out_dir"

    case "$arch" in
        mipseb|mipsel)
            # MIPS: vmlinux is the kernel binary
            if [ -f "${src_dir}/vmlinux" ]; then
                cp "${src_dir}/vmlinux" "${out_dir}/${vmlinux_name}"
                log_ok "Installed: ${out_dir}/${vmlinux_name}"
            else
                log_err "vmlinux not found after build"
                return 1
            fi
            ;;
        armel)
            # ARM: zImage (compressed) + vmlinux (uncompressed)
            if [ -f "${src_dir}/arch/arm/boot/zImage" ]; then
                cp "${src_dir}/arch/arm/boot/zImage" "${out_dir}/zImage.armel"
                log_ok "Installed: ${out_dir}/zImage.armel"
            else
                log_err "zImage not found after build"
                return 1
            fi
            if [ -f "${src_dir}/vmlinux" ]; then
                cp "${src_dir}/vmlinux" "${out_dir}/vmlinux.armel"
                log_ok "Installed: ${out_dir}/vmlinux.armel"
            fi
            ;;
        aarch64)
            # ARM64: Image (compressed) + vmlinux (uncompressed)
            if [ -f "${src_dir}/arch/arm64/boot/Image" ]; then
                cp "${src_dir}/arch/arm64/boot/Image" "${out_dir}/Image.aarch64"
                log_ok "Installed: ${out_dir}/Image.aarch64"
            else
                log_err "Image not found after build"
                return 1
            fi
            if [ -f "${src_dir}/vmlinux" ]; then
                cp "${src_dir}/vmlinux" "${out_dir}/vmlinux.aarch64"
                log_ok "Installed: ${out_dir}/vmlinux.aarch64"
            fi
            ;;
    esac

    log_ok "Build complete: ${arch} ${ver} -> ${out_dir}"
    log_ok "构建完成: ${arch} ${ver} -> ${out_dir}"
    return 0
}

#=============================================================================
# Build all kernels / 构建所有内核
# Iterates through all valid arch/version combinations.
# 遍历所有有效的架构/版本组合。
#=============================================================================

build_all() {
    local total=0
    local success=0
    local failed=0
    local skipped=0
    local failed_list=()

    log_info "Building all kernel combinations"
    log_info "构建所有内核组合"
    log_info "Force rebuild: ${FORCE}"

    # Clone FirmAE kernel repos first / 先克隆 FirmAE 内核仓库
    if ! clone_firmae_kernel_repos; then
        log_err "Failed to clone FirmAE kernel repos"
        return 1
    fi

    # Check toolchains / 检查工具链
    check_all_toolchains

    for arch in mipseb mipsel armel armhf aarch64; do
        local versions="${ARCH_VERSIONS[$arch]}"
        for ver in $versions; do
            total=$((total + 1))

            # Check if cross-compiler is available
            local cc
            cc=$(get_cross_compile "$arch")
            if [ -z "$cc" ] && [ "$arch" != "armhf" ]; then
                log_warn "Skipping ${arch} ${ver}: no cross-compiler"
                skipped=$((skipped + 1))
                continue
            fi

            if build_kernel "$arch" "$ver"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
                failed_list+=("${arch}/${ver}")
            fi

            echo ""  # blank line between builds
        done
    done

    log_info "=========================================="
    log_info "Build Summary / 构建摘要"
    log_info "=========================================="
    log_info "Total: ${total}  Success: ${success}  Failed: ${failed}  Skipped: ${skipped}"
    log_info "总计: ${total}  成功: ${success}  失败: ${failed}  跳过: ${skipped}"

    if [ ${#failed_list[@]} -gt 0 ]; then
        log_err "Failed builds / 失败的构建:"
        for item in "${failed_list[@]}"; do
            log_err "  - ${item}"
        done
        return 1
    fi

    log_ok "All builds completed successfully!"
    log_ok "所有构建均已成功完成！"
    return 0
}

#=============================================================================
# List command / 列表命令
# Shows all arch/version combinations and their build status.
# 显示所有架构/版本组合及其构建状态。
#=============================================================================

list_kernels() {
    echo ""
    echo "FirmAE Kernel Build Matrix / FirmAE 内核构建矩阵"
    echo "================================================="
    echo ""
    printf "%-10s %-8s %-14s %-8s %s\n" "ARCH" "VER" "FULL_VER" "STATUS" "PATH"
    printf "%-10s %-8s %-14s %-8s %s\n" "----" "---" "--------" "------" "----"

    for arch in mipseb mipsel armel armhf aarch64; do
        local versions="${ARCH_VERSIONS[$arch]}"
        for ver in $versions; do
            local full_ver="${KERNEL_VERSIONS[$ver]}"
            local out_dir="${KERNEL_OUT_DIR}/${arch}/${ver}"
            local kernel_bin
            kernel_bin=$(get_kernel_binary_name "$arch")
            local status

            if [ -f "${out_dir}/${kernel_bin}" ]; then
                status="${GREEN}BUILT${NC}"
            else
                status="${YELLOW}-----${NC}"
            fi

            printf "%-10s %-8s %-14s " "$arch" "$ver" "$full_ver"
            echo -e "${status}   ${out_dir}/"
        done
    done

    echo ""

    # Show toolchain status / 显示工具链状态
    echo "Toolchain Status / 工具链状态:"
    echo "-------------------------------"
    for arch in mipseb mipsel armel aarch64; do
        local cc
        cc=$(get_cross_compile "$arch")
        if [ -n "$cc" ]; then
            echo -e "  ${arch}: ${GREEN}${cc}gcc${NC}"
        else
            echo -e "  ${arch}: ${RED}NOT FOUND${NC}"
        fi
    done
    echo -e "  armhf: (shares armel toolchain)"
    echo ""
}

#=============================================================================
# Clean command / 清理命令
# Removes temporary build files from /tmp/firmae_kernel_build/
# 从 /tmp/firmae_kernel_build/ 删除临时构建文件
#=============================================================================

clean_build() {
    if [ -d "$BUILD_DIR" ]; then
        log_info "Removing build directory: ${BUILD_DIR}"
        log_info "正在删除构建目录: ${BUILD_DIR}"
        rm -rf "$BUILD_DIR"
        log_ok "Build directory cleaned"
        log_ok "构建目录已清理"
    else
        log_info "Build directory does not exist: ${BUILD_DIR}"
    fi
}

#=============================================================================
# Argument parsing and main entry point / 参数解析和主入口
#=============================================================================

usage() {
    echo "Usage: $(basename "$0") [OPTIONS] <COMMAND>"
    echo ""
    echo "Commands / 命令:"
    echo "  all              Build all arch/version combinations / 构建所有组合"
    echo "  <arch> <version> Build specific combination / 构建指定组合"
    echo "  list             List all combinations and status / 列出所有组合和状态"
    echo "  clean            Remove temp build files / 清理临时构建文件"
    echo ""
    echo "Options / 选项:"
    echo "  --force          Force rebuild existing kernels / 强制重新构建"
    echo "  --jobs N         Parallel make jobs (default: $(nproc)) / 并行编译数"
    echo "  --help           Show this help / 显示帮助"
    echo ""
    echo "Architectures / 架构: mipseb, mipsel, armel, armhf, aarch64"
    echo "Versions / 版本: 2.6, 3.10, 4.1, 4.4, 4.9, 4.14, 4.19, 5.4, 5.10"
    echo ""
    echo "Examples / 示例:"
    echo "  $(basename "$0") list"
    echo "  $(basename "$0") mipsel 4.9"
    echo "  $(basename "$0") --force armel 4.1"
    echo "  $(basename "$0") --jobs 8 all"
}

# Parse options / 解析选项
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        --jobs)
            if [ -n "${2:-}" ] && [ "${2:0:1}" != "-" ]; then
                JOBS="$2"
                shift 2
            else
                log_err "--jobs requires a number"
                exit 1
            fi
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore positional args / 恢复位置参数
set -- "${POSITIONAL_ARGS[@]}"

# Validate and dispatch command / 验证并分发命令
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"

case "$COMMAND" in
    all)
        build_all
        ;;
    list)
        list_kernels
        ;;
    clean)
        clean_build
        ;;
    --help|-h)
        usage
        ;;
    *)
        # Expect <arch> <version> / 期望 <arch> <version>
        if [ $# -lt 2 ]; then
            log_err "Usage: $(basename "$0") <arch> <version>"
            log_err "Run '$(basename "$0") list' to see valid combinations"
            exit 1
        fi

        ARCH="$1"
        VER="$2"

        # Validate architecture / 验证架构
        if [ -z "${ARCH_VERSIONS[$ARCH]+x}" ]; then
            log_err "Invalid architecture: ${ARCH}"
            log_err "Valid architectures: mipseb, mipsel, armel, armhf, aarch64"
            exit 1
        fi

        # Validate version / 验证版本
        if [ -z "${KERNEL_VERSIONS[$VER]+x}" ]; then
            log_err "Invalid kernel version: ${VER}"
            log_err "Valid versions: ${!KERNEL_VERSIONS[*]}"
            exit 1
        fi

        # Validate arch/version combination / 验证架构/版本组合
        if ! echo "${ARCH_VERSIONS[$ARCH]}" | grep -qw "$VER"; then
            log_err "Invalid combination: ${ARCH} does not support kernel ${VER}"
            log_err "Valid versions for ${ARCH}: ${ARCH_VERSIONS[$ARCH]}"
            exit 1
        fi

        # Clone repos and build / 克隆仓库并构建
        if ! clone_firmae_kernel_repos; then
            log_err "Failed to clone FirmAE kernel repos"
            exit 1
        fi

        if ! build_kernel "$ARCH" "$VER"; then
            log_err "Build failed for ${ARCH} ${VER}"
            exit 1
        fi
        ;;
esac
