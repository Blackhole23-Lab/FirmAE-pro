# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FirmAE is an IoT firmware emulation and vulnerability analysis framework that uses QEMU to emulate firmware across 5 architectures (mipseb, mipsel, armel, armhf, aarch64) with multi-version kernel support. It achieves 79.36% emulation success rate through five arbitration techniques (FIRMAE_BOOT, FIRMAE_NET, FIRMAE_NVRAM, FIRMAE_KERNEL, FIRMAE_ETC).

## Essential Commands

### Initial Setup
```bash
./download.sh          # Download precompiled binaries
./install.sh           # Install dependencies (QEMU, PostgreSQL, Binwalk3, cross-compilers)
./init.sh              # Initialize PostgreSQL database
```

### Firmware Emulation
```bash
# Check emulation (quick test, exits after network check)
sudo ./run.sh -c <brand> <firmware>

# Run mode (keeps emulation running for manual testing)
sudo ./run.sh -r <brand> <firmware>

# Analyze mode (automated vulnerability scanning)
sudo ./run.sh -a <brand> <firmware>

# Debug mode (opens nc shell on port 31337, telnet on 31338)
sudo ./run.sh -d <brand> <firmware>

# Boot debug mode (kernel-level debugging with GDB on port 1234)
sudo ./run.sh -b <brand> <firmware>
```

### Kernel Building
```bash
# Build all kernels for all architectures
./scripts/build_kernels.sh all

# Build specific architecture/version
./scripts/build_kernels.sh armel 4.9

# List available/built kernel combinations
./scripts/build_kernels.sh list

# Clean build artifacts
./scripts/build_kernels.sh clean

# Force rebuild even if kernel exists
./scripts/build_kernels.sh --force armel 4.9

# Parallel compilation (default: nproc)
./scripts/build_kernels.sh --jobs 8 all
```

### Database Operations
```bash
# Query firmware metadata
./scripts/util.py get_iid <firmware_path> <psql_ip>
./scripts/util.py get_brand <firmware_path> <psql_ip>

# Check database connection
./scripts/util.py check_connection _ 127.0.0.1
```

## Architecture Overview

### Firmware Processing Pipeline

```
Firmware Binary (.bin, .zip, etc.)
    ↓
[extractor.py] → Binwalk3 extraction
    ↓
images/{IID}.tar.gz (filesystem) + images/{IID}.kernel (optional)
    ↓
[getArch.py] → Architecture detection (ELF analysis)
    ↓
[inferKernel.py] → Kernel version inference
    ↓
[tar2db.py] → PostgreSQL import (file metadata)
    ↓
[makeImage.sh] → QEMU disk image creation (1GB ext2)
    ↓
[makeNetwork.py] → Network configuration inference
    ↓
[select_kernel_version()] → Smart kernel matching (firmae.config)
    ↓
[run.{arch}.sh] → QEMU emulation with firmadyne driver
    ↓
[analyses_all.sh] → Vulnerability analysis (optional)
```

### Multi-Version Kernel System

**Kernel Matching Algorithm** (in `firmae.config:select_kernel_version()`):
1. **Exact match**: firmware 4.9.x → kernels/armel/4.9/
2. **Same major, nearest minor**: firmware 4.7 → 4.9 or 4.4 (closest)
3. **Nearest LTS upgrade**: firmware 3.10 → 4.1 (next LTS)
4. **Fallback to default**: use architecture default kernel

**Kernel Storage**: `binaries/kernels/{arch}/{version}/`
- ARM32: `zImage.{arch}` (compressed) + `vmlinux.{arch}` (debug symbols)
- ARM64: `Image.aarch64` (uncompressed) + `vmlinux.aarch64`
- MIPS: `vmlinux.{arch}` (ELF format)

**Current Status**: 22/28 kernels built (79%)
- mipseb: 5/5 ✅ (2.6, 3.10, 4.1, 4.4, 4.9)
- mipsel: 5/5 ✅ (2.6, 3.10, 4.1, 4.4, 4.9)
- armel: 3/7 ⚠️ (4.4, 4.9, 4.14) - 3.10/4.1/4.19 fail
- armhf: 3/7 ⚠️ (4.4, 4.9, 4.14) - 3.10/4.1/4.19 fail
- aarch64: 4/4 ✅ (4.14, 4.19, 5.4, 5.10)

### Firmadyne Kernel Driver

**Location**: Integrated into kernel builds from FirmAE_kernel-v4.1/v2.6 repos

**Core Functions**:
- **System call interception**: 19 jprobe/kprobe handlers for syscall tracing
- **NVRAM emulation**: Intercepts nvram_get/nvram_set, loads from `/firmadyne/nvram.ini`
- **Network injection**: Modifies network syscalls to force IP configuration
- **Process monitoring**: Tracks all spawned processes and command lines

**Key Files**:
- `drivers/firmadyne/hooks.c` - System call hooks
- `drivers/firmadyne/nvram.c` - NVRAM emulation
- `drivers/firmadyne/syscall.c` - Syscall logging

### Database Schema

**PostgreSQL Tables**:
- `image`: Firmware metadata (id, filename, brand_id, hash, arch, kernel_version)
- `object`: Deduplicated file objects (id, hash)
- `object_to_image`: Filesystem mapping (oid, iid, filename, permissions)
- `brand`: Vendor information (id, name)
- `product`: Product metadata (iid, url, version, build)

**Connection**: Default 127.0.0.1:5432, Docker mode uses 172.17.0.1

### QEMU Configuration

**Architecture-Specific Settings**:
- **MIPS**: malta machine, IDE disk (/dev/sda1), e1000 NIC
- **ARM32**: virt machine, virtio-blk (/dev/vda1), virtio-net-device
- **ARM64**: virt machine, cortex-a57 CPU, 1GB RAM, virtio devices

**Network Topology**: Host tap8_0 (192.168.0.2) ↔ Guest eth0 (192.168.0.1)

## Critical Implementation Details

### Kernel Build System (build_kernels.sh)

**Cross-Compiler Detection**:
- Bootlin toolchains: `/opt/cross/bin/` (source `/opt/cross/env.sh`)
- MIPS: `mips[el]-buildroot-linux-musl-gcc`
- ARM32: `arm-buildroot-linux-gnueabihf-gcc`
- ARM64: `aarch64-buildroot-linux-gnu-gcc`

**GCC Compatibility Patches** (7 patches applied):
1. `-fno-ipa-sra` for ARM GCC 13+ (disables IPA-SRA optimization)
2. `fix_section_flags.py` for GAS 2.41+ (adds section type flags)
3. Firmadyne driver compatibility for 3.10-4.0 kernels
4. jprobe → kprobe migration for 4.15+ kernels (WIP)
5. `-Wno-error=` flags to downgrade warnings
6. `__DATE__`/`__TIME__` macro fixes
7. `fallthrough` attribute fixes for GCC 7+

**Build Artifacts**:
- Source: `kernel-sources/linux-{version}.tar.xz` (753 MB total)
- Build dir: `/tmp/firmae_kernel_build/` (temporary, lost on reboot)
- Output: `binaries/kernels/{arch}/{version}/` (persistent)
- Logs: `kernel-sources/logs/{arch}_{version}.log`

### Known Build Failures

**armel/armhf 3.10 & 4.1** (4 kernels):
- **Issue**: Patch 3.5 uses sed with range `/^})/` that matches multiple times
- **Result**: Register barrier `asm volatile("" : "+r"(__r2)...)` inserted multiple times
- **Root cause**: GCC 13 IPA-SRA doesn't respect `register ... asm("r2")` constraints
- **Fix**: Replace sed with awk using `barrier_added` flag (see KERNEL_FIX_REPORT.md)

**armel/armhf 4.19** (2 kernels):
- **Issue**: jprobe API removed in Linux 4.15
- **Impact**: 19 jprobe handlers in firmadyne driver fail to compile
- **Fix**: Rewrite handlers as kprobe pre_handlers, access args via `pt_regs`
  - ARM32: r0=arg1, r1=arg2, r2=arg3, r3=arg4
  - ARM64: x0=arg1, x1=arg2, x2=arg3, x3=arg4

### Configuration Files

**firmae.config**:
- Arbitration flags: `FIRMAE_BOOT`, `FIRMAE_NET`, `FIRMAE_NVRAM`, `FIRMAE_KERNEL`, `FIRMAE_ETC`
- Timeouts: `TIMEOUT=120`, `CHECK_TIMEOUT=120`
- Architecture list: `ARCHS=("armel" "armhf" "mipseb" "mipsel" "aarch64")`
- Functions: `select_kernel_version()`, `get_kernel()`, `get_qemu()`, `check_network()`

**Key Paths**:
- `FIRMAE_DIR`: Project root
- `BINARY_DIR`: `${FIRMAE_DIR}/binaries/`
- `KERNEL_OUT_DIR`: `${FIRMAE_DIR}/binaries/kernels/`
- `SCRATCH_DIR`: `${FIRMAE_DIR}/scratch/` (runtime work directory)
- `TARBALL_DIR`: `${FIRMAE_DIR}/images/` (extracted firmware)

### Runtime Work Directory Structure

`scratch/{IID}/`:
- `image.raw` - QEMU disk image (1GB)
- `run.sh` - Generated QEMU launch script
- `qemu.final.serial.log` - Serial console output
- `architecture` - Detected architecture
- `kernel_version` - Detected kernel version
- `ip` - Assigned IP address
- `result` - Emulation result (true/false)
- `ping` - Network reachability status
- `web` - Web service status

## Development Workflow

### Adding New Architecture Support

1. Update `firmae.config`:
   - Add to `ARCHS` array
   - Add `get_kernel()` case
   - Add `get_qemu()` case
   - Add `get_qemu_machine()` case
   - Add `get_qemu_disk()` case

2. Update `scripts/getArch.py`:
   - Add ELF machine type detection
   - Add endianness/ABI detection

3. Create `scripts/run.{arch}.sh`:
   - Set QEMU binary and machine type
   - Configure memory and CPU
   - Set disk and network devices
   - Set kernel command line

4. Update `scripts/build_kernels.sh`:
   - Add to `ARCH_VERSIONS` array
   - Add cross-compiler detection
   - Add architecture-specific patches

### Modifying Kernel Build Process

**Location**: `scripts/build_kernels.sh` (1,469 lines)

**Key Functions**:
- `build_kernel()` - Main build logic with 7 patch stages
- `download_kernel_source()` - Fetch vanilla kernel from kernel.org
- `clone_firmae_repos()` - Clone FirmAE kernel repos with firmadyne driver
- `apply_firmadyne_driver()` - Integrate driver into kernel source tree

**Adding New Patch**:
1. Create patch file in `scripts/kernel_patches/`
2. Add patch application in `build_kernel()` function
3. Use version conditionals: `case "$ver" in 4.19|5.*) ... esac`
4. Test on all affected architectures

### Debugging Emulation Issues

**Serial Console**: `scratch/{IID}/qemu.final.serial.log`
- Check kernel boot messages
- Look for firmadyne driver initialization
- Check for filesystem mount errors

**Network Issues**:
- Verify tap device: `ip addr show tap8_0`
- Check bridge: `brctl show`
- Test connectivity: `ping 192.168.0.1`
- Check makeNetwork.py output: `scratch/{IID}/makeNetwork.log`

**Kernel Selection**:
- Check detected version: `cat scratch/{IID}/kernel_version`
- Verify matched kernel: Look for "Matched kernel" in logs
- Test with different kernel: Manually edit `scratch/{IID}/run.sh`

**GDB Debugging**:
```bash
# Terminal 1: Start boot debug mode
sudo ./run.sh -b <brand> <firmware>

# Terminal 2: Connect GDB
gdb-multiarch -q binaries/vmlinux.armel -ex='target remote:1234'
```

## Important Constraints

- **Root required**: All `run.sh` commands need sudo (QEMU networking, loop devices)
- **PostgreSQL dependency**: Database must be running before emulation
- **Kernel persistence**: Built kernels in `binaries/kernels/` survive reboots
- **Build dir ephemeral**: `/tmp/firmae_kernel_build/` is lost on reboot
- **Source preservation**: Keep `kernel-sources/*.tar.xz` for rebuilds
- **Architecture detection**: Requires valid ELF binaries in firmware
- **Kernel version inference**: Best-effort, may fall back to default kernel

## File Locations Reference

**User-facing scripts**: `run.sh`, `init.sh`, `install.sh`, `download.sh`
**Core scripts**: `scripts/` (getArch.py, inferKernel.py, makeImage.sh, makeNetwork.py, tar2db.py, util.py)
**Kernel build**: `scripts/build_kernels.sh`, `scripts/kernel_patches/`
**Binaries**: `binaries/` (kernels/, busybox.*, console.*, libnvram*.*, gdb*, strace.*)
**Source code**: `sources/` (extractor/, libnvram/, console/)
**Analysis tools**: `analyses/` (analyses_all.sh, initializer.py, fuzzer/, routersploit/)
**Database**: `database/schema`
**Configuration**: `firmae.config`
**Runtime data**: `scratch/{IID}/`, `images/`
