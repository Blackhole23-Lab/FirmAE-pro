# FirmAE 内核编译问题修复 - 实施总结

**执行日期**: 2026-03-03  
**当前状态**: 修复进行中  
**目标**: 22/28 → 28/28 内核编译成功

---

## 已完成工作

### 1. 问题分析 ✅

**armel/armhf 3.10/4.1 失败原因**:
- build_kernels.sh 第 1034-1042 行的 sed 命令存在缺陷
- sed 范围匹配导致寄存器屏障被重复插入
- 破坏了 `__put_user_check` 宏定义的语法

**armel/armhf 4.19 失败原因**:
- firmadyne 驱动使用 19 个 jprobe handler
- jprobe API 在内核 4.15 中被移除
- 当前的自动化 patch 不完整

### 2. 修复方案设计 ✅

**3.10/4.1 修复**:
- 使用 awk 替代 sed
- 添加 `barrier_added` 标志防止重复
- 确保每个函数只添加一次屏障

**4.19 修复**:
- 需要完整的 jprobe → kprobe 迁移
- 创建专用的 patch 文件
- 更新 build_kernels.sh 的自动化逻辑

### 3. 代码修改 ✅

**文件**: `scripts/build_kernels.sh`  
**修改位置**: 行 1028-1046 (Patch 3.5)

**关键改进**:
```bash
# 原代码 (有缺陷)
sed -i '/__put_user_check/,/^})/{
    /register int __e asm("r0");/a\
\t\tasm volatile("" : "+r"(__r2), "+r"(__p), "+r"(__l));
}' "$uaccess_h"

# 新代码 (已修复)
awk '/__put_user_check/,/^[[:space:]]*})/ {
    if (/register int __e asm\("r0"\);/ && !barrier_added) {
        print
        print "\t\tasm volatile(\"\" : \"+r\"(__r2), \"+r\"(__p), \"+r\"(__l));"
        barrier_added=1
        next
    }
}
/^[[:space:]]*})/{ barrier_added=0 }
{print}' "$uaccess_h" > "$uaccess_h.tmp" && mv "$uaccess_h.tmp" "$uaccess_h"
```

### 4. 文档生成 ✅

已生成以下文档:
- `KERNEL_FIX_REPORT.md` - 完整的技术分析报告
- `IMPLEMENTATION_SUMMARY.md` - 本文档
- `.omc/kernel_fix_plan.md` - 修复计划

---

## 待完成工作

### 阶段 1: 验证 3.10/4.1 修复

```bash
# 测试命令
cd /home/ubuntu/FirmAE
./scripts/build_kernels.sh armel 3.10
./scripts/build_kernels.sh armel 4.1
./scripts/build_kernels.sh armhf 3.10  # 应该从 armel 复制
./scripts/build_kernels.sh armhf 4.1   # 应该从 armel 复制
```

**预期结果**:
- armel 3.10: 编译成功，生成 `binaries/kernels/armel/3.10/zImage.armel`
- armel 4.1: 编译成功，生成 `binaries/kernels/armel/4.1/zImage.armel`
- armhf 3.10/4.1: 从 armel 复制成功

### 阶段 2: 修复 4.19 jprobe 问题

**步骤 1**: 提取并分析 firmadyne 驱动
```bash
cd /tmp/firmae_kernel_build
git clone https://github.com/pr0v3rbs/FirmAE_kernel-v4.1
cd FirmAE_kernel-v4.1/drivers/firmadyne
grep -rn "jprobe" . > /tmp/jprobe_usage.txt
```

**步骤 2**: 创建迁移 patch
```bash
# 文件: scripts/kernel_patches/firmadyne_jprobe_to_kprobe.patch
# 内容: 完整的 jprobe → kprobe 迁移代码
```

**步骤 3**: 更新 build_kernels.sh
```bash
# 在 apply_firmadyne_compat_patches() 函数中添加:
case "$ver" in
    4.19|5.*)
        if [ -f "${PATCH_DIR}/firmadyne_jprobe_to_kprobe.patch" ]; then
            log_info "  Applying jprobe -> kprobe migration patch"
            patch -p1 -d "$src_dir" < "${PATCH_DIR}/firmadyne_jprobe_to_kprobe.patch"
        fi
        ;;
esac
```

**步骤 4**: 测试编译
```bash
./scripts/build_kernels.sh armel 4.19
./scripts/build_kernels.sh armhf 4.19
```

### 阶段 3: 全量验证

```bash
# 编译所有内核
./scripts/build_kernels.sh all

# 验证结果
./scripts/build_kernels.sh list | grep -E "armel|armhf"
```

**预期输出**:
```
armel      3.10     3.10.108       BUILT   /home/ubuntu/FirmAE/binaries/kernels/armel/3.10/
armel      4.1      4.1.17         BUILT   /home/ubuntu/FirmAE/binaries/kernels/armel/4.1/
armel      4.19     4.19.269       BUILT   /home/ubuntu/FirmAE/binaries/kernels/armel/4.19/
armhf      3.10     3.10.108       BUILT   /home/ubuntu/FirmAE/binaries/kernels/armhf/3.10/
armhf      4.1      4.1.17         BUILT   /home/ubuntu/FirmAE/binaries/kernels/armhf/4.1/
armhf      4.19     4.19.269       BUILT   /home/ubuntu/FirmAE/binaries/kernels/armhf/4.19/
```

### 阶段 4: 更新项目文档

**更新 next-plan.md**:
- 修改内核矩阵，将所有 ❌ 改为 ✅
- 更新总计为 28/28 (100%)
- 删除"未完成内核的编译障碍"章节
- 添加"修复历史"章节

**更新 MEMORY.md**:
```markdown
## Kernel Build Progress: 28/28 ✅
- mipseb 4/4 ✅, mipsel 4/4 ✅, aarch64 4/4 ✅
- armel 7/7 ✅ (新增 2.6/3.10/4.1/4.19)
- armhf 7/7 ✅ (新增 2.6/3.10/4.1/4.19)

## Fixed Issues
1. **armel/armhf 3.10/4.1 — GCC 13 register barrier**
   - 修复 build_kernels.sh Patch 3.5 的 sed 缺陷
   - 使用 awk 确保只添加一次屏障
2. **armel/armhf 4.19 — jprobe API removal**
   - 创建完整的 jprobe → kprobe 迁移 patch
   - 更新自动化构建逻辑
```

---

## 技术要点总结

### __asmeq 断言机制

```c
#define __asmeq(x, y)  ".ifnc " x "," y " ; .err ; .endif\n\t"
```

这个宏在汇编时验证 GCC 是否将变量分配到了指定的寄存器。如果不匹配，`.err` 指令会导致编译失败。

### GCC 13 寄存器约束问题

GCC 13 的 IPA-SRA 优化可能忽略 `register ... asm("r2")` 约束。解决方案是添加编译器屏障：

```c
register const typeof(*(p)) __r2 asm("r2") = (x);
asm volatile("" : "+r"(__r2));  // 强制实现到 r2
```

### jprobe vs kprobe

| 特性 | jprobe | kprobe |
|------|--------|--------|
| 函数签名 | 与目标相同 | `int handler(struct kprobe *, struct pt_regs *)` |
| 参数访问 | 直接 | 通过 `regs->ARM_r0` 等 |
| 内核支持 | < 4.15 | 全版本 |

---

## 下一步行动

1. **立即执行**: 测试 armel 3.10/4.1 编译
2. **优先级高**: 完成 4.19 jprobe 迁移
3. **最终验证**: 编译所有 28 个内核
4. **文档更新**: 更新 next-plan.md 和 MEMORY.md
5. **代码提交**: 创建 git commit

---

## 预期时间线

- **阶段 1** (3.10/4.1 验证): 30 分钟
- **阶段 2** (4.19 修复): 2-3 小时
- **阶段 3** (全量验证): 1 小时
- **阶段 4** (文档更新): 30 分钟

**总计**: 约 4-5 小时完成所有工作

---

**最后更新**: 2026-03-03  
**状态**: 修复方案已实施，等待验证
