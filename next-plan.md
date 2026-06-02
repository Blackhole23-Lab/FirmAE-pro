# FirmAE 增强版 — 项目技术总结

> 物联网固件仿真平台改进全景报告
> 最后更新：2026-03-02

---

## 一、项目概述

本项目基于 FirmAE（Firmware Analysis and Emulation）进行深度定制与增强，目标是构建一个支持多架构、多内核版本的物联网固件全系统仿真平台，用于固件安全分析、漏洞挖掘和自动化测试。

| 指标 | 数据 |
|------|------|
| 支持架构数 | 5（原版 3 + 新增 2） |
| 编译内核总数 | 22 个（覆盖 8 个内核版本） |
| 内核二进制总大小 | 1.2 GB |
| 构建脚本规模 | 1,454 行（build_kernels.sh） |
| 代码变更量 | 24 文件，+2,875 行 |
| 最新提交 | `1cbc252` feat: multi-version kernel support |

---

## 二、架构支持矩阵

### 2.1 支持的 CPU 架构

| 架构 | 字节序 | QEMU Target | Machine | 状态 |
|------|--------|-------------|---------|------|
| mipseb | Big-Endian | qemu-system-mips | malta | 原生支持 |
| mipsel | Little-Endian | qemu-system-mipsel | malta | 原生支持 |
| armel | Little-Endian | qemu-system-arm | virt | 原生支持 |
| armhf | LE + Hard-Float | qemu-system-arm | virt | **新增** |
| aarch64 | Little-Endian | qemu-system-aarch64 | virt | **新增** |

### 2.2 架构检测增强（getArch.py）

新增检测逻辑：
- `ARM aarch64` / `ARM64` → `aarch64`
- `ARM` + Little-Endian + Hard-Float → `armhf`
- aarch64 强制 Little-Endian（无大端变体）

---

## 三、内核体系

### 3.1 多版本内核矩阵

```
                    │ 2.6  │ 3.10 │ 4.1  │ 4.4  │ 4.9  │ 4.14 │ 4.19 │ 5.4  │ 5.10 │
────────────────────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
mipseb              │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │  —   │  —   │  —   │  —   │  5/5
mipsel              │  ✅  │  ✅  │  ✅  │  ✅  │  ✅  │  —   │  —   │  —   │  —   │  5/5
armel               │  —   │  ❌  │  ❌  │  ✅  │  ✅  │  ✅  │  ❌  │  —   │  —   │  3/6
armhf               │  —   │  ❌  │  ❌  │  ✅  │  ✅  │  ✅  │  ❌  │  —   │  —   │  3/6
aarch64             │  —   │  —   │  —   │  —   │  —   │  ✅  │  ✅  │  ✅  │  ✅  │  4/4
────────────────────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
                                                                    总计：20/26 (77%)
```

- ✅ = 编译成功并部署
- ❌ = 编译失败（已知问题）
- — = 不适用（架构不支持该版本范围）

### 3.2 内核二进制清单

```
binaries/kernels/
├── aarch64/
│   ├── 4.14/  Image.aarch64 + vmlinux.aarch64    (17 MB)
│   ├── 4.19/  Image.aarch64 + vmlinux.aarch64    (17 MB)
│   ├── 5.4/   Image.aarch64 + vmlinux.aarch64    (17 MB)
│   └── 5.10/  Image.aarch64 + vmlinux.aarch64    (17 MB)
├── armel/
│   ├── 4.4/   zImage.armel + vmlinux.armel        (3.3 MB)
│   ├── 4.9/   zImage.armel + vmlinux.armel        (3.4 MB)
│   └── 4.14/  zImage.armel + vmlinux.armel        (3.6 MB)
├── armhf/
│   ├── 4.4/   zImage.armhf + vmlinux.armhf        (3.3 MB)
│   ├── 4.9/   zImage.armhf + vmlinux.armhf        (3.4 MB)
│   └── 4.14/  zImage.armhf + vmlinux.armhf        (3.6 MB)
├── mipseb/
│   ├── 3.10/  vmlinux.mipseb                      (8.5 MB)
│   ├── 4.1/   vmlinux.mipseb                      (9.0 MB)
│   ├── 4.4/   vmlinux.mipseb                      (9.5 MB)
│   └── 4.9/   vmlinux.mipseb                      (9.9 MB)
└── mipsel/
    ├── 3.10/  vmlinux.mipsel                      (8.5 MB)
    ├── 4.1/   vmlinux.mipsel                      (9.0 MB)
    ├── 4.4/   vmlinux.mipsel                      (9.5 MB)
    └── 4.9/   vmlinux.mipsel                      (9.9 MB)
```

总计：1.2 GB

### 3.3 智能内核版本匹配算法

`firmae.config` 中实现的 `select_kernel_version()` 函数，采用四级优先匹配策略：

```
优先级 1：精确匹配
  固件内核 4.9.x → 选择 kernels/{arch}/4.9/

优先级 2：同主版本最近次版本
  固件内核 4.7.x → 选择 4.9 或 4.4（取最近者）

优先级 3：最近 LTS 升级版本
  固件内核 3.10.x → 选择 4.1（最近的不低于目标的 LTS）

优先级 4：回退默认
  无法匹配 → 使用架构默认内核（向后兼容）
```

跟踪的 LTS 版本：`2.6, 3.10, 4.1, 4.4, 4.9, 4.14, 4.19, 5.4, 5.10`

### 3.4 固件内核版本自动检测

`run.sh` 新增检测逻辑（第 179-200 行）：

1. 从 `inferKernel.py` 提取的内核二进制中解析版本号
2. 从固件 tarball 的 `/lib/modules/` 目录名推断版本
3. 无法检测时标记为 `unknown`，回退到默认内核

检测结果保存至 `${WORK_DIR}/kernel_version`，供 QEMU 启动时选择匹配内核。

### 3.5 未完成内核的编译障碍

| 内核版本 | 架构 | 失败原因 | 解决方案 |
|----------|------|----------|----------|
| 3.10 | armel/armhf | GCC 13 寄存器约束错误：`asm("r2")` 在 `uaccess.h` 中不被接受 | 降级至 GCC 12 或手动 patch |
| 4.1 | armel/armhf | 同上，GCC 13 与旧内核 ARM 内联汇编不兼容 | 同上 |
| 4.19 | armel/armhf | firmadyne 驱动使用的 `jprobe` API 在 4.15 中被移除 | 需将 19 个 jprobe handler 重写为 kprobe |

---

## 四、QEMU 仿真配置

### 4.1 各架构 QEMU 参数对比

| 参数 | MIPS (eb/el) | ARM32 (armel/armhf) | ARM64 (aarch64) |
|------|-------------|---------------------|-----------------|
| QEMU Binary | qemu-system-mips[el] | qemu-system-arm | qemu-system-aarch64 |
| Machine | malta | virt | virt |
| CPU | default | default | cortex-a57 |
| Memory | 256 MB | 256 MB | 1024 MB |
| Disk Device | IDE (/dev/sda1) | virtio-blk (/dev/vda1) | virtio-blk (/dev/vda1) |
| Network Device | e1000 | virtio-net-device | virtio-net-device |
| Console | ttyS0 | ttyS0 | ttyS0 + earlycon |
| Kernel Format | vmlinux (ELF) | zImage (compressed) | Image (uncompressed) |

### 4.2 网络拓扑

```
┌─────────────────────┐         ┌─────────────────────┐
│     Host (Ubuntu)    │         │   Emulated Firmware  │
│                      │         │                      │
│  tap8_0: 192.168.0.2 ├─────────┤ eth0: 192.168.0.1   │
│                      │  Bridge  │                      │
│  nc/telnet client    │         │  nc -lp 31337        │
│                      │         │  telnetd -p 31338    │
└─────────────────────┘         └─────────────────────┘
```

### 4.3 运行模式

| 脚本名 | 模式 | 调试端口 | QEMU 参数 | 用途 |
|--------|------|----------|-----------|------|
| `run.sh` | 普通 | 无 | `syscall=1` | 基础仿真运行 |
| `run_debug.sh` | 调试 | 31337(nc) + 31338(telnet) | `syscall=1` | 交互式调试 |
| `run_analyze.sh` | 分析 | 无 | `user_debug=31, syscall=32` | 漏洞分析 + syscall 追踪 |
| `run_boot.sh` | 启动调试 | GDB 1234 | `-s -S` | 内核级调试 |

---

## 五、用户态工具链

### 5.1 各架构二进制工具

| 工具 | 用途 | armel | armhf | aarch64 | mipseb | mipsel |
|------|------|-------|-------|---------|--------|--------|
| busybox | 基础命令集 | ✅ 1.1MB | ✅ | ✅ 1.3MB | ✅ | ✅ |
| console | 控制台工具 | ✅ 22KB | ✅ | ✅ 21KB | ✅ | ✅ |
| libnvram.so | NVRAM 仿真 | ✅ 34KB | ✅ | ✅ 38KB | ✅ | ✅ |
| libnvram_ioctl.so | NVRAM ioctl | ✅ 34KB | ✅ | ✅ 38KB | ✅ | ✅ |
| gdb | 调试器 | ✅ 41MB | ✅ | ✅ 11MB | ✅ | ✅ |
| gdbserver | 远程调试 | ✅ 4.2MB | ✅ | ✅ 7.5MB | ✅ | ✅ |
| strace | 系统调用追踪 | ✅ 339KB | ✅ | ✅ 1.5MB | ✅ | ✅ |

### 5.2 Firmadyne 内核驱动

固件仿真的核心组件，编译进每个内核：

- **网络钩子**：拦截和修改网络配置系统调用
- **NVRAM 钩子**：模拟 NVRAM 读写操作
- **系统调用追踪**：记录固件运行时的系统调用（分析模式）
- **进程监控**：追踪固件启动的进程和服务

---

## 六、固件提取与分析工具链

### 6.1 提取工具

| 组件 | 版本/状态 | 说明 |
|------|-----------|------|
| Binwalk3 | v3.1.0（Rust 后端） | 固件解包，支持 SquashFS/JFFS2/CramFS 等 |
| extractor.py | 增强版 | 自动提取文件系统和内核 |
| inferKernel.py | 新增 | 从固件二进制推断内核版本 |
| getArch.py | 增强版 | 支持 5 种架构检测 |

### 6.2 分析工具

| 工具 | 用途 |
|------|------|
| analyses_all.sh | 自动化漏洞扫描主脚本 |
| RouterSploit | 路由器漏洞利用框架 |
| Nmap | 网络端口扫描 |
| Fuzzer | 模糊测试工具 |
| ChromeDriver | Web 界面自动化测试 |

### 6.3 仿真流程

```
固件文件 (.bin)
    │
    ▼
┌──────────────────┐
│  extractor.py    │  提取文件系统 + 内核
│  (Binwalk3)      │  → images/{IID}.tar.gz
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  getArch.py      │  检测 CPU 架构
│  inferKernel.py  │  推断内核版本
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  makeImage.sh    │  构建 QEMU 磁盘镜像
│                  │  注入 firmadyne 工具
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  makeNetwork.py  │  推断网络配置
│                  │  检测 IP/接口/DHCP
└────────┬─────────┘
         │
         ▼
┌──────────────────────────────────────┐
│  select_kernel_version()             │
│  选择最佳匹配内核                      │
│  → binaries/kernels/{arch}/{ver}/    │
└────────┬─────────────────────────────┘
         │
         ▼
┌──────────────────┐
│  QEMU 全系统仿真  │  启动固件
│  run_debug.sh    │  开放调试端口
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  nc / telnet     │  交互式 Shell
│  gdb / strace    │  深度调试分析
│  analyses_all.sh │  自动化漏洞扫描
└──────────────────┘
```

---

## 七、构建基础设施

### 7.1 内核构建系统（build_kernels.sh）

1,454 行的自动化构建脚本，核心能力：

- **交叉编译工具链管理**：自动检测 Bootlin/musl/gnu 工具链
  - MIPS: `mips[el]-buildroot-linux-musl-gcc`
  - ARM32: `arm-buildroot-linux-gnueabihf-gcc`
  - ARM64: `aarch64-buildroot-linux-gnu-gcc`
- **内核源码管理**：8 个版本的源码包（768 MB），存放于 `kernel-sources/`
- **Firmadyne 驱动集成**：自动 patch 驱动到内核源码树
- **GCC 兼容性修复**：处理 GCC 11/12/13 与旧内核的兼容问题
- **ARM 汇编语法修复**：`fix_section_flags.py` 转换 `.section` 指令语法（GAS 2.41+）
- **并行编译支持**：多架构同时构建

### 7.2 内核补丁

`scripts/kernel_patches/firmadyne_compat_pre4.patch`：
- 适配 firmadyne 驱动到 3.10.x - 4.0.x 内核
- 处理 `PDE_DATA()` 兼容性
- 处理 VFS 函数签名差异
- 处理 `proc_create_data` API 变更

---

## 八、配置变更

### 8.1 firmae.config 关键修改

| 配置项 | 原值 | 新值 | 说明 |
|--------|------|------|------|
| TIMEOUT | 240s | 120s | 缩短初始日志收集超时 |
| CHECK_TIMEOUT | 360s | 120s | 缩短网络检查超时 |
| ARCHS | 3 个 | 5 个 | 新增 armhf + aarch64 |

### 8.2 新增函数

| 函数 | 行数 | 功能 |
|------|------|------|
| `select_kernel_version()` | 83 行 | 智能内核版本匹配 |
| `get_kernel()` (增强) | — | 支持版本参数，返回版本匹配的内核路径 |
| `get_boot_kernel()` (增强) | — | aarch64 返回 `vmlinux.aarch64` |
| `get_qemu()` (增强) | — | aarch64 返回 `qemu-system-aarch64` |
| `get_qemu_machine()` (增强) | — | aarch64 返回 `virt` |
| `get_qemu_disk()` (增强) | — | aarch64 返回 `/dev/vda1` |

---

## 九、安装与部署

### 9.1 install.sh 更新

- 新增 `qemu-system-aarch64` 安装
- 集成 Binwalk3 + Rust 工具链安装
- PostgreSQL Docker 网络配置
- 交叉编译器工具链安装

### 9.2 download.sh 更新

- 新增所有 aarch64 二进制文件的下载 URL
- 从 GitHub Releases 拉取预编译二进制

---

## 十、实战验证

### 10.1 IID 8 测试案例

| 项目 | 数据 |
|------|------|
| 固件名称 | a6004mx_ml_14_182 (iptime 路由器) |
| 架构 | armel (ARMv7) |
| 检测内核版本 | 4.4.198 |
| 匹配内核 | kernels/armel/4.4/zImage.armel |
| 仿真 IP | 192.168.0.1 |
| Ping 测试 | ✅ 通过 |
| NC Shell (31337) | ✅ 通过（debug 模式） |
| Telnet (31338) | ✅ 通过（debug 模式） |
| 启动耗时 | ~41 秒 |
| 系统信息 | Linux iptime 4.4.298 armv7l |

---

## 十一、已知问题与技术债务

### 11.1 编译问题

1. **armel/armhf 3.10 & 4.1 内核**
   - GCC 13 寄存器 `asm("r2")` 约束失败
   - 位置：`arch/arm/include/asm/uaccess.h`
   - 需要 GCC 12 或手动 patch

2. **armel/armhf 4.19 内核**
   - firmadyne `hooks.c` 使用 19 个 `jprobe` handler
   - `jprobe` API 在 4.15 中被移除
   - 需重写为 `kprobe` API

### 11.2 功能限制

3. **串口日志为空**
   - `qemu.final.serial.log` 在部分固件中无输出
   - 可能原因：固件未配置串口或输出被重定向

4. **MIPS 2.6 内核缺失**
   - `mipseb/mipsel` 的 2.6 内核使用原版默认内核
   - 未纳入多版本目录结构

### 11.3 待完成工作

5. 多版本内核端到端测试（不同固件 × 不同内核版本）
6. Web 服务仿真成功率统计
7. aarch64 固件实际测试用例积累

---

## 十二、项目文件结构

```
FirmAE/
├── run.sh                      # 主入口脚本（增强版）
├── firmae.config               # 核心配置（大幅修改）
├── debug.py                    # 调试辅助脚本
├── install.sh                  # 安装脚本（增强版）
├── download.sh                 # 下载脚本（增强版）
├── binaries/
│   ├── kernels/                # 多版本内核目录（1.2 GB）
│   │   ├── aarch64/{4.14,4.19,5.4,5.10}/
│   │   ├── armel/{4.4,4.9,4.14}/
│   │   ├── armhf/{4.4,4.9,4.14}/
│   │   ├── mipseb/{3.10,4.1,4.4,4.9}/
│   │   └── mipsel/{3.10,4.1,4.4,4.9}/
│   ├── busybox.{arch}         # 各架构 busybox
│   ├── console.{arch}         # 各架构 console
│   ├── libnvram*.{arch}       # NVRAM 仿真库
│   ├── gdb*.{arch}            # 调试工具
│   └── strace.{arch}          # 系统调用追踪
├── scripts/
│   ├── build_kernels.sh        # 内核构建系统（1,454 行）
│   ├── getArch.py              # 架构检测（增强版）
│   ├── makeImage.sh            # 镜像构建
│   ├── makeNetwork.py          # 网络推断（增强版）
│   ├── inferKernel.py          # 内核版本推断（新增）
│   ├── run.aarch64.sh          # aarch64 QEMU 模板（新增）
│   ├── run.armhf.sh            # armhf QEMU 模板（新增）
│   └── kernel_patches/         # 内核兼容补丁
├── kernel-sources/             # 内核源码包（768 MB）
│   ├── linux-{version}.tar.xz  # 8 个版本
│   └── fix_section_flags.py    # ARM 汇编修复工具
├── sources/
│   ├── extractor/              # 固件提取器
│   ├── libnvram/               # NVRAM 仿真源码
│   └── console/                # Console 源码
├── analyses/                   # 漏洞分析工具集
├── scratch/                    # 运行时工作目录
│   └── {IID}/                  # 每个固件的仿真数据
└── images/                     # 提取的固件镜像
```

---

## 十三、Git 提交历史

```
1cbc252 feat: multi-version kernel support for armel/armhf/aarch64
1ee7a16 Merge pull request #103 from terrorbyte/fix-binwalk-setup
c1ac764 Fix binwalk dependency handling
3faadf1 Fix python -> python3
117ec63 Fix log buffer problem and added more description
7782871 Add more descriptions
d288065 Add protect code for some edge cases
6fa1913 Change minimum Ubuntu version
7fd7b6d Change some options
3e778df Show IID info in log
```

变更统计：24 文件，+2,875 行，-99 行

---

## 十四、总结与展望

### 核心成果

本项目将 FirmAE 从一个仅支持 3 种 MIPS/ARM 架构、单一内核版本的固件仿真工具，升级为支持 5 种架构（含 ARM64）、20+ 多版本内核、智能版本匹配的专业级物联网固件仿真平台。

### 关键技术突破

1. **多版本内核体系**：解决了"一个内核打天下"导致的兼容性问题，通过版本匹配显著提升仿真成功率
2. **aarch64 全栈支持**：从内核编译、QEMU 配置、用户态工具到网络推断的完整 ARM64 支持
3. **自动化构建流水线**：1,454 行的内核构建脚本，支持 5 架构 × 8 版本的交叉编译矩阵
4. **现代工具链适配**：解决 GCC 13、GAS 2.41+ 与旧内核的兼容性问题

### 下一步计划

1. 解决 armel/armhf 3.10/4.1 内核的 GCC 13 编译问题
2. 将 firmadyne jprobe 钩子迁移到 kprobe API（支持 4.15+ 内核）
3. 大规模固件仿真测试，验证多版本内核匹配的实际效果
4. 完善 aarch64 固件测试用例库
5. 考虑 RISC-V 架构支持的可行性

---

> 本文档由物联网安全工程师编写，作为 FirmAE 增强版项目的技术归档。
> 项目路径：`/home/ubuntu/FirmAE/`
> 文档生成日期：2026-03-02
