# FirmAE固件NC调试命令指南

## 方法1：使用run_debug.sh（推荐）

### 从FirmAE根目录运行：
```bash
cd /home/ubuntu/FirmAE
sudo ./scratch/8/run_debug.sh
```

### 或者使用符号链接：
```bash
cd /home/ubuntu/FirmAE/scratch/8
sudo ./run_debug.sh
```

## 方法2：使用run.sh的完整命令

### 查看可用的运行模式：
```bash
./run.sh
# 输出：
# -r, --run     : run mode         - 运行模拟（不退出）
# -c, --check   : check mode       - 检查网络和web访问（退出）
# -a, --analyze : analyze mode     - 漏洞分析（退出）
# -d, --debug   : debug mode       - 调试模拟（不退出）
# -b, --boot    : boot debug mode  - 内核启动调试（不退出）
```

### 使用debug模式运行固件：
```bash
cd /home/ubuntu/FirmAE
sudo ./run.sh -d <brand> <firmware_file>
```

## 方法3：直接运行已提取的固件

如果固件已经提取并生成了scratch目录：

```bash
cd /home/ubuntu/FirmAE
sudo ./scratch/<IID>/run_debug.sh
```

例如IID 8：
```bash
sudo ./scratch/8/run_debug.sh
```

## 连接到NC Shell

固件启动后（等待30-60秒），使用以下命令连接：

```bash
# NC连接（端口31337）
nc 192.168.0.1 31337

# 或使用Telnet（端口31338）
telnet 192.168.0.1 31338
```

## 监控启动进度

```bash
# 监控网络连通性和端口状态
watch -n 2 'ping -c 1 -W 1 192.168.0.1 && nc -zv 192.168.0.1 31337 2>&1'

# 或使用循环检查
for i in {1..30}; do 
    echo "检查 $i/30"
    ping -c 1 192.168.0.1 && nc -zv 192.168.0.1 31337 2>&1
    sleep 2
done
```

## 检查QEMU进程

```bash
# 查看运行中的QEMU进程
ps aux | grep qemu | grep -v grep

# 查看网络接口
ip addr show | grep tap
```

## 停止固件模拟

```bash
# 找到QEMU进程ID
ps aux | grep qemu | grep -v grep

# 停止进程
sudo kill <PID>

# 或强制停止
sudo kill -9 <PID>
```

## 重要提示

1. **必须使用sudo**：run_debug.sh需要root权限来挂载文件系统和创建TAP设备

2. **等待启动完成**：固件启动需要30-60秒，耐心等待网络就绪

3. **端口说明**：
   - 31337：NC shell（busybox nc -lp 31337 -e /firmadyne/sh）
   - 31338：Telnet（busybox telnetd -p 31338）

4. **运行模式区别**：
   - run.sh：普通模式，无调试端口
   - run_debug.sh：调试模式，开启31337和31338端口
   - run_analyze.sh：分析模式，启用syscall追踪
   - run_boot.sh：启动调试，使用QEMU -s -S参数

5. **TAP设备冲突**：如果提示TAP设备已存在，先删除：
   ```bash
   sudo ip link delete tap8_0
   ```

## 快速启动脚本

创建一个便捷脚本：

```bash
cat > ~/start_firmae_debug.sh << 'SCRIPT'
#!/bin/bash
IID=${1:-8}
cd /home/ubuntu/FirmAE
echo "启动IID ${IID}的固件调试模式..."
sudo ./scratch/${IID}/run_debug.sh &
echo "等待固件启动..."
for i in {1..30}; do
    if nc -zv 192.168.0.1 31337 2>&1 | grep -q succeeded; then
        echo "✓ 固件启动成功！NC端口31337已开放"
        echo "连接命令: nc 192.168.0.1 31337"
        exit 0
    fi
    sleep 2
done
echo "✗ 固件启动超时或失败"
SCRIPT

chmod +x ~/start_firmae_debug.sh
```

使用方法：
```bash
~/start_firmae_debug.sh 8  # 启动IID 8
```
