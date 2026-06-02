# FirmAE 内核编译问题分析与修复方案 - 最终报告

**项目**: FirmAE 多版本内核支持增强  
**日期**: 2026-03-03  
**当前状态**: 22/28 内核编译成功 (79%)  
**目标状态**: 28/28 内核编译成功 (100%)

---

## 执行摘要

本报告完整记录了 FirmAE 项目中 6 个失败内核的深度分析过程，包括根本原因定位、技术方案设计和实施路径。

**失败内核**:
- armel: 3.10, 4.1, 4.19 (3个)
- armhf: 3.10, 4.1, 4.19 (3个，与 armel 共享)

**核心发现**:
1. **3.10/4.1 编译失败**: build_kernels.sh 的 Patch 3.5 存在 sed 命令缺陷
2. **4.19 编译失败**: firmadyne 驱动的 jprobe API 在内核 4.15 中被移除

---

## 问题 1: armel/armhf 3.10/4.1 编译失败

### 错误表现

```
/tmp/firmae_kernel_build/linux-3.10.108/arch/arm/include/asm/uaccess.h:191:9: 
error: expected identifier or '(' before '}' token
  191 |         })
      |         ^
```

### 根本原因

**文件**: `scripts/build_kernels.sh`  
**位置**: 行 1028-1046 (Patch 3.5 - ARM register barrier)

**问题代码**:
```bash
sed -i '/__put_user_check/,/^})/{
    /register int __e asm("r0");/a\
\t\tasm volatile("" : "+r"(__r2), "+r"(__p), "+r"(__l));
}' "$uaccess_h"
```

**缺陷分析**:
1. sed 的范围匹配 `/__put_user_check/,/^})/` 会匹配宏定义内的多个 `})` 结束符
2. 导致寄存器屏障 `asm volatile(...)` 被插入多次
3. 破坏了 C 宏定义的语法结构

**实际效果**:
```c
#define __put_user_check(x,p) \
    ({ \
        register const typeof(*(p)) __r2 asm("r2") = (x); \
        register const typeof(*(p)) __user *__p asm("r0") = __tmp_p; \
        register unsigned long __l asm("r1") = __limit; \
        register int __e asm("r0"); \
        asm volatile("" : "+r"(__r2), "+r"(__p), "+r"(__l));  // 第1次 ✓
        asm volatile("" : "+r"(__r2), "+r"(__p), "+r"(__l));  // 第2次 ❌ 重复！
        switch (sizeof(*(__p))) { \
        // ...
        } \
        __e; \
    })
```

### 技术背景

**为什么需要寄存器屏障？**

GCC 13 引入了更激进的 IPA-SRA (Inter-Procedural Analysis - Scalar Replacement of Aggregates) 优化，可能忽略 `register ... asm("r2")` 约束。

ARM 内核使用 `__asmeq` 宏验证寄存器分配：

```c
// arch/arm/include/asm/compiler.h
#define __asmeq(x, y)  ".ifnc " x "," y " ; .err ; .endif\n\t"
```

如果 GCC 未将变量分配到指定寄存器，汇编器会触发 `.err` 导致编译失败。

**解决方案**: 添加编译器屏障强制 GCC 实现变量到寄存器：
```c
asm volatile("" : "+r"(__r2));  // 强制 __r2 实现到 r2 寄存器
```

### 修复方案

**策略**: 使用更精确的 sed 命令或 awk，确保只添加一次屏障

**方案 A - 改进的 sed** (推荐):
```bash
# 只在第一次匹配时添加
sed -i '/__put_user_check/,/^[[:space:]]*})/{
    /register int __e asm("r0");/{
        /asm volatile.*__r2.*__p.*__l/!{
            a\
\t\tasm volatile("" : "+r"(__r2), "+r"(__p), "+r"(__l));
        }
    }
}' "$uaccess_h"
```

**方案 B - 使用 perl** (更可靠):
```bash
perl -i -pe '
    if (/__put_user_check/../^[[:space:]]*\}\)/) {
        if (/register int __e asm\("r0"\);/ && !$barrier_added) {
            $_ .= "\t\tasm volatile(\"\" : \"+r\"(__r2), \"+r\"(__p), \"+r\"(__l));\n";
            $barrier_added = 1;
        }
    }
    $barrier_added = 0 if /^[[:space:]]*\}\)/;
' "$uaccess_h"
```

**方案 C - 简单直接的方法** (最稳定):
```bash
# 检查是否已经添加过
if ! grep -q 'asm volatile.*__r2.*__p.*__l' "$uaccess_h"; then
    # 找到准确的行号并插入
    line_num=$(grep -n 'register int __e asm("r0");' "$uaccess_h" | \
               grep -A5 '__put_user_check' | head -1 | cut -d: -f1)
    if [ -n "$line_num" ]; then
        sed -i "${line_num}a\\\t\tasm volatile(\"\" : \"+r\"(__r2), \"+r\"(__p), \"+r\"(__l));" "$uaccess_h"
    fi
fi
```

---

## 问题 2: armel/armhf 4.19 编译失败

### 错误表现

```bash
error: implicit declaration of function 'register_jprobe'
error: 'struct jprobe' has no member named 'entry'
```

### 根本原因

**内核变更**: Linux 4.15 移除了 jprobe API  
**提交**: e46e31a3696ae2d4 "kprobes: remove jprobe implementation"

**firmadyne 驱动依赖**: 使用 19 个 jprobe handler 拦截系统调用

**当前的自动化 patch** (build_kernels.sh 行 518-543):
```bash
sed -i 's/struct jprobe/struct kretprobe/g' "$src_file"
sed -i 's/register_jprobe/register_kretprobe/g' "$src_file"
```

**问题**: 简单的字符串替换无法处理：
1. jprobe 和 kprobe 的函数签名完全不同
2. jprobe 的 `.entry` 字段在 kprobe 中不存在
3. 参数访问方式不同（直接访问 vs 通过 pt_regs）

### jprobe vs kprobe 对比

| 特性 | jprobe | kprobe/kretprobe |
|------|--------|------------------|
| 函数签名 | 与目标函数相同 | `int handler(struct kprobe *, struct pt_regs *)` |
| 参数访问 | 直接访问函数参数 | 通过 `pt_regs` 寄存器结构 |
| 返回值修改 | 不支持 | kretprobe 支持 |
| 内核版本 | < 4.15 | 全版本支持 |
| 性能开销 | 较低 | 略高 |

### 修复方案

**步骤 1**: 分析 firmadyne 驱动中的所有 jprobe 使用

```bash
# 驱动位于 FirmAE_kernel-v4.1 仓库
/tmp/firmae_kernel_build/FirmAE_kernel-v4.1/drivers/firmadyne/
```

**步骤 2**: 创建完整的迁移 patch

示例迁移：
```c
// === 原 jprobe handler ===
static int my_sys_open(const char __user *filename, int flags, umode_t mode) {
    printk("open: %s\n", filename);
    jprobe_return();
    return 0;
}

static struct jprobe my_jprobe = {
    .entry = my_sys_open,
    .kp = {
        .symbol_name = "sys_open",
    },
};

// === 迁移到 kprobe ===
static int my_sys_open_pre(struct kprobe *p, struct pt_regs *regs) {
    // ARM32: r0=filename, r1=flags, r2=mode
    const char __user *filename = (const char __user *)regs->ARM_r0;
    int flags = (int)regs->ARM_r1;
    umode_t mode = (umode_t)regs->ARM_r2;
    
    printk("open: %s\n", filename);
    return 0;  // 0 = 继续执行原函数
}

static struct kprobe my_kprobe = {
    .symbol_name = "sys_open",
    .pre_handler = my_sys_open_pre,
};
```

**步骤 3**: ARM 寄存器映射

| 参数位置 | ARM32 | ARM64 | MIPS | 访问方式 |
|---------|-------|-------|------|---------|
| 参数 1 | r0 | x0 | a0 | `regs->ARM_r0` / `regs->regs[0]` |
| 参数 2 | r1 | x1 | a1 | `regs->ARM_r1` / `regs->regs[1]` |
| 参数 3 | r2 | x2 | a2 | `regs->ARM_r2` / `regs->regs[2]` |
| 参数 4 | r3 | x3 | a3 | `regs->ARM_r3` / `regs->regs[3]` |
| 参数 5+ | 栈 | 栈 | 栈 | 需要栈指针计算 |

**步骤 4**: 创建 patch 文件

```bash
# 文件: scripts/kernel_patches/firmadyne_jprobe_to_kprobe.patch
# 包含所有 19 个 handler 的完整迁移
```

**步骤 5**: 更新 build_kernels.sh

```bash
# 在 apply_firmadyne_compat_patches() 函数中添加
case "$ver" in
    4.19|5.*)
        if [ -f "${PATCH_DIR}/firmadyne_jprobe_to_kprobe.patch" ]; then
            log_info "  Applying jprobe -> kprobe migration patch"
            patch -p1 -d "$src_dir" < "${PATCH_DIR}/firmadyne_jprobe_to_kprobe.patch"
            log_ok "  jprobe migration applied"
        fi
        ;;
esac
```

---

## 实施路径

### 阶段 1: 修复 3.10/4.1 (优先级: 高)

**任务**:
1. 修改 build_kernels.sh 的 Patch 3.5
2. 使用方案 C (简单直接的方法)
3. 测试 armel 3.10 编译
4. 测试 armel 4.1 编译
5. 验证 armhf 自动复制逻辑

**预期时间**: 1-2 小时

**验证命令**:
```bash
cd /home/ubuntu/FirmAE
./scripts/build_kernels.sh armel 3.10
./scripts/build_kernels.sh armel 4.1
ls -lh binaries/kernels/armel/3.10/
ls -lh binaries/kernels/armel/4.1/
```

### 阶段 2: 修复 4.19 (优先级: 中)

**任务**:
1. 克隆 FirmAE_kernel-v4.1 仓库
2. 分析 drivers/firmadyne/ 中的所有 jprobe
3. 为每个 handler 编写 kprobe 替代
4. 创建完整的 patch 文件
5. 更新 build_kernels.sh
6. 测试编译

**预期时间**: 3-4 小时

**验证命令**:
```bash
./scripts/build_kernels.sh armel 4.19
ls -lh binaries/kernels/armel/4.19/
```

### 阶段 3: 全量验证 (优先级: 高)

**任务**:
1. 编译所有 28 个内核
2. 验证每个内核的二进制文件
3. 运行 IID 8 测试用例
4. 更新项目文档

**预期时间**: 2-3 小时

**验证命令**:
```bash
./scripts/build_kernels.sh all
./scripts/build_kernels.sh list
```

---

## 预期结果

### 编译成功率提升

| 架构 | 当前 | 修复后 | 提升 |
|------|------|--------|------|
| mipseb | 4/4 (100%) | 4/4 (100%) | - |
| mipsel | 4/4 (100%) | 4/4 (100%) | - |
| armel | 3/7 (43%) | 7/7 (100%) | +57% |
| armhf | 3/7 (43%) | 7/7 (100%) | +57% |
| aarch64 | 4/4 (100%) | 4/4 (100%) | - |
| **总计** | **22/28 (79%)** | **28/28 (100%)** | **+21%** |

### 内核覆盖矩阵 (修复后)

```
                │ 2.6 │ 3.10│ 4.1 │ 4.4 │ 4.9 │ 4.14│ 4.19│ 5.4 │ 5.10│
────────────────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
mipseb          │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  —  │  —  │  —  │  —  │
mipsel          │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  —  │  —  │  —  │  —  │
armel           │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  —  │  —  │
armhf           │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  ✅ │  —  │  —  │
aarch64         │  —  │  —  │  —  │  —  │  —  │  ✅ │  ✅ │  ✅ │  ✅ │
────────────────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
                                                    总计：28/28 (100%)
```

---

## 技术要点

### 1. __asmeq 断言机制

```c
#define __asmeq(x, y)  ".ifnc " x "," y " ; .err ; .endif\n\t"
```

这个宏在汇编时验证 GCC 是否将变量分配到了指定的寄存器。

**工作流程**:
1. GCC 分配寄存器给内联汇编操作数 (`%0`, `%1`, `%2`)
2. 汇编器执行 `.ifnc` (if not equal) 指令
3. 如果不匹配，触发 `.err` 导致编译失败

### 2. GCC 13 IPA-SRA 优化

**问题**: GCC 13 可能在内联汇编之前优化掉 `register ... asm("r2")` 约束

**解决**: 编译器屏障
```c
register const typeof(*(p)) __r2 asm("r2") = (x);
asm volatile("" : "+r"(__r2));  // 强制实现
```

### 3. jprobe 迁移要点

**关键差异**:
- jprobe: 函数签名与目标相同，直接访问参数
- kprobe: 统一的 handler 签名，通过 pt_regs 访问参数

**迁移模板**:
```c
// jprobe
static int handler(type1 arg1, type2 arg2) {
    // 直接使用 arg1, arg2
}

// kprobe
static int handler_pre(struct kprobe *p, struct pt_regs *regs) {
    type1 arg1 = (type1)regs->ARM_r0;
    type2 arg2 = (type2)regs->ARM_r1;
    // 使用 arg1, arg2
}
```

---

## 文档清单

本次分析生成的文档：

1. **KERNEL_FIX_REPORT.md** - 完整的技术分析报告 (15 页)
2. **IMPLEMENTATION_SUMMARY.md** - 实施总结 (5 页)
3. **FINAL_SUMMARY.md** - 本文档 (最终总结)
4. **.omc/kernel_fix_plan.md** - 修复计划

---

## 下一步行动

### 立即执行 (优先级: 紧急)

1. 修复 build_kernels.sh 的 Patch 3.5
2. 测试 armel 3.10/4.1 编译

### 短期目标 (1-2 天)

1. 完成 4.19 jprobe 迁移
2. 编译所有 28 个内核
3. 更新项目文档

### 长期目标 (1 周)

1. 大规模固件测试
2. 性能基准测试
3. 文档完善

---

## 参考资料

### 内核文档
- [Kernel Probes (Kprobes)](https://www.kernel.org/doc/Documentation/kprobes.txt)
- [Jprobes Removal Commit](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=e46e31a3696ae2d4)
- [ARM Inline Assembly](https://www.kernel.org/doc/Documentation/arm/kernel_user_helpers.txt)

### GCC 文档
- [GCC Extended Asm](https://gcc.gnu.org/onlinedocs/gcc/Extended-Asm.html)
- [GCC Register Variables](https://gcc.gnu.org/onlinedocs/gcc/Local-Register-Variables.html)
- [GCC 13 Release Notes](https://gcc.gnu.org/gcc-13/changes.html)

### FirmAE 项目
- [FirmAE GitHub](https://github.com/pr0v3rbs/FirmAE)
- [FirmAE Paper (NDSS 2020)](https://www.ndss-symposium.org/ndss-paper/firmae-towards-large-scale-emulation-of-iot-firmware/)

---

## 结论

通过深入分析，我们定位了 FirmAE 项目中 6 个失败内核的根本原因：

1. **3.10/4.1**: build_kernels.sh 的 sed 命令缺陷导致重复插入寄存器屏障
2. **4.19**: firmadyne 驱动依赖的 jprobe API 已被移除

两个问题都有明确的技术方案，预计 6-8 小时可以完成所有修复和验证工作，最终实现 **28/28 内核 100% 编译成功率**。

---

**报告生成时间**: 2026-03-03  
**分析工具**: Claude Opus 4.6  
**项目路径**: /home/ubuntu/FirmAE/  
**版本**: 1.0 Final
