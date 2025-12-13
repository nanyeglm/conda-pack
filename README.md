# Conda Environment Transfer Tool

一个用于在多台服务器之间自动化迁移 Conda 虚拟环境的 Bash 脚本工具。

## 项目背景

在深度学习和数据科学的日常工作中，我们经常需要在不同的服务器之间同步 Conda 虚拟环境。例如：

- 在本地工作站开发调试，然后将环境迁移到 GPU 服务器进行训练
- 在高性能服务器上配置好环境后，同步到其他机器
- 团队成员之间共享完全一致的开发环境

传统的环境迁移方式（如 `conda env export` + `conda env create`）存在以下问题：

1. **依赖解析慢**：需要重新解析和下载所有依赖
2. **版本不一致**：可能因为源更新导致安装的版本与原环境不同
3. **pip 包丢失**：通过 pip 安装的包可能无法正确导出
4. **操作繁琐**：需要手动执行多个步骤

本项目使用 [conda-pack](https://conda.github.io/conda-pack/) 技术，将整个环境打包成一个 tar.gz 文件，实现：

- **完全一致的环境复制**：包括所有 conda 和 pip 安装的包
- **无需网络下载**：目标机器不需要访问 conda 源
- **自动化流程**：一键完成打包、传输、安装、路径修复

## 功能特性

### 核心功能

| 功能 | 描述 |
|------|------|
| 🔍 **自动机器识别** | 通过 IP 地址和主机名自动识别当前机器，确定传输方向 |
| 📦 **环境打包** | 使用 conda-pack 将完整环境打包为 tar.gz |
| 🚀 **高速传输** | 使用 rsync 进行增量压缩传输，支持断点续传 |
| 📂 **自动安装** | 在目标机器上自动解压并安装到正确位置 |
| 🔧 **路径修复** | 自动运行 conda-unpack 修复硬编码路径 |
| 🧹 **自动清理** | 传输完成后自动清理两端的临时文件 |

### 交互体验

- **彩色终端输出**：使用颜色区分信息类型（信息/成功/警告/错误）
- **环境列表展示**：同时显示本地和远程的环境列表及大小
- **序号/名称选择**：支持输入序号或环境名称选择要传输的环境
- **操作确认**：执行前显示详细操作步骤，需用户确认
- **覆盖提示**：目标环境已存在时提示是否覆盖

## 实现思路

### 1. 机器识别 (`detect_machine`)

```bash
detect_machine() {
    local current_ips=$(hostname -I 2>/dev/null || echo "")
    local hostname=$(hostname)
    
    if echo "$current_ips" | grep -q "$WORKSTATION_IP"; then
        echo "workstation"
    elif [[ "$hostname" == "glm-lxd" ]]; then
        echo "dgx"
    fi
}
```

**实现思路**：

- 首先通过 `hostname -I` 获取当前机器的所有 IP 地址
- 匹配预配置的 IP 地址确定机器身份
- 对于容器环境（如 LXD），IP 可能不固定，则通过主机名识别
- 识别后自动确定传输方向（当前机器 → 另一台机器）

### 2. 远程命令执行 (`run_remote`)

```bash
run_remote() {
    local machine="$1"
    shift
    if [[ "$machine" == "workstation" ]]; then
        ssh "${USER}@${DGX_HOST}" -p "${DGX_PORT}" "$@"
    else
        ssh "${USER}@${WORKSTATION_IP}" "$@"
    fi
}
```

**实现思路**：

- 封装 SSH 命令，根据当前机器类型决定连接目标
- 支持非标准 SSH 端口（如 LXD 容器的端口映射）
- 统一接口，简化后续代码

### 3. 环境列表获取

**本地环境** (`list_local_envs`)：

- 遍历 `${MINIFORGE_BASE}/envs/` 目录
- 使用 `du -sh` 获取每个环境的大小
- 带序号显示，支持序号选择

**远程环境** (`list_remote_envs`)：

- 通过 SSH 一次性执行 shell 脚本获取所有环境信息
- 避免多次 SSH 连接造成的延迟
- 关键代码：

  ```bash
  run_remote "$machine" "for d in ${ENVS_DIR}/*/; do 
      size=\$(du -sh \"\$d\" | cut -f1)
      name=\$(basename \"\$d\")
      echo \"\$name \$size\"
  done"
  ```

### 4. conda-pack 检测 (`check_conda_pack`)

```bash
check_conda_pack() {
    local conda_pack_bin="${MINIFORGE_BASE}/bin/conda-pack"
    
    if [[ ! -x "$conda_pack_bin" ]]; then
        "${MINIFORGE_BASE}/bin/conda" install -y -c conda-forge conda-pack
    fi
}
```

**实现思路**：

- 直接检查可执行文件是否存在，而非依赖 `command -v`
- 原因：非交互式 SSH 会话中 PATH 可能未正确设置
- 若未安装则自动安装

### 5. 环境打包 (`pack_environment`)

```bash
"${MINIFORGE_BASE}/bin/conda-pack" -n "$env_name" -o "$pack_file" --force
```

**实现思路**：

- 使用完整路径调用 conda-pack，避免 PATH 问题
- `--force` 参数覆盖已存在的打包文件
- 将状态信息输出到 stderr，只将文件路径输出到 stdout（供后续函数使用）

### 6. 环境传输 (`transfer_environment`)

```bash
rsync -avz --progress -e "ssh -p ${PORT}" "$pack_file" "${USER}@${HOST}:${TEMP_DIR}/"
```

**实现思路**：

- 使用 rsync 而非 scp，优势：
  - 支持增量传输和断点续传
  - 内置压缩（-z）
  - 显示传输进度（--progress）
- 通过 `-e` 参数指定 SSH 端口

### 7. 远程安装 (`install_remote_environment`)

```bash
# 解压
run_remote "$machine" "mkdir -p ${target_dir} && tar -xzf ${pack_file} -C ${target_dir}"

# 修复路径
run_remote "$machine" "source ${target_dir}/bin/activate && conda-unpack"
```

**实现思路**：

- 创建目标目录并解压 tar.gz 文件
- 使用 `--warning=no-unknown-keyword` 忽略非致命警告
- 运行 `conda-unpack` 修复硬编码的绝对路径
- 若 conda-unpack 不可用，尝试通过 Python 调用

### 8. 清理临时文件 (`cleanup`)

**实现思路**：

- 删除本地临时打包文件
- 通过 SSH 删除远程临时文件
- 使用 `|| true` 忽略删除失败（文件可能不存在）

## 环境要求

### 依赖工具

| 工具 | 用途 | 安装方式 |
|------|------|---------|
| `conda-pack` | 环境打包 | `conda install -c conda-forge conda-pack` |
| `rsync` | 文件传输 | `apt install rsync` |
| `ssh` | 远程连接 | 系统自带 |

### 前置条件

1. **SSH 免密登录**：两台机器之间需配置 SSH 密钥认证

   ```bash
   ssh-keygen -t ed25519
   ssh-copy-id user@remote_host
   ```

2. **相同的 Conda 安装路径**：两台机器的 Miniforge/Miniconda 需安装在相同路径
   - 默认：`/home/cpu/miniforge3`

3. **网络连通**：两台机器需在同一局域网或可互相访问

## 使用方法

### 1. 配置脚本

修改脚本顶部的配置部分，适配你的环境：

```bash
# ==================== 配置 ====================
MINIFORGE_BASE="/home/cpu/miniforge3"  # Conda 安装路径
ENVS_DIR="${MINIFORGE_BASE}/envs"       # 环境目录
TEMP_DIR="/tmp/conda_transfer"          # 临时文件目录
USER="cpu"                              # SSH 用户名

# 机器配置
WORKSTATION_IP="192.168.5.8"            # 机器1 IP
DGX_HOST="172.20.73.2"                  # 机器2 IP
DGX_PORT="28888"                        # 机器2 SSH端口
```

### 2. 部署脚本

将脚本复制到两台机器上（可放置在任意目录）：

```bash
# 本地
chmod +x conda_env_transfer.sh

# 复制到远程
scp -P 28888 conda_env_transfer.sh user@remote:/path/to/
```

### 3. 运行脚本

```bash
./conda_env_transfer.sh
```

### 4. 按提示操作

```text
========================================
  Conda 环境传输工具
========================================

[INFO] 当前机器: 工作站 (192.168.5.8, 14900K+5090)
[INFO] 目标机器: DGX-A100 (glm-lxd)

[INFO] 测试远程连接...
SSH连接成功
[SUCCESS] 远程连接正常

[INFO] 本地conda环境列表：

  [1] myenv (2.5G)
  [2] pytorch (4.8G)

[INFO] 远程机器conda环境列表：

  • base (1.2G)

请输入要传输的环境名称或序号: 2

[INFO] 选择的环境: pytorch

即将执行以下操作:
  1. 在本地打包环境 pytorch
  2. 传输到 DGX-A100 (glm-lxd)
  3. 安装到 /home/cpu/miniforge3/envs/pytorch
  4. 修复路径
  5. 清理临时文件

确认继续? (y/N): y
```

## 自定义扩展

### 添加新机器

1. 在配置区添加新机器的 IP 和端口
2. 修改 `detect_machine()` 添加识别逻辑
3. 修改 `get_machine_name()` 和 `get_target_name()` 添加名称映射
4. 修改 `run_remote()` 添加 SSH 连接逻辑

### 支持多台机器

可以扩展为选择目标机器的模式：

```bash
# 示例：添加机器选择
echo "可用的目标机器："
echo "  [1] DGX-A100"
echo "  [2] 工作站"
echo "  [3] 云服务器"
read -p "选择目标: " target_choice
```

## 常见问题

### Q: 传输时出现 "tar: 跳转到下一个头" 警告

**A**: 这是非致命警告，通常由于环境中存在特殊的符号链接或扩展属性。脚本已处理此情况，环境功能不受影响。

### Q: conda-pack 报告包未被管理

**A**: 这是因为部分包通过 pip 安装而非 conda。conda-pack 会将它们作为普通文件打包，功能正常。

### Q: SSH 连接失败

**A**: 请检查：

1. SSH 密钥是否已配置
2. 网络是否连通
3. 端口是否正确
4. 防火墙是否允许连接

### Q: 提示 "无法识别当前机器"

**A**: 请确认脚本中配置的 IP 地址与实际 IP 一致，或修改 `detect_machine()` 函数的识别逻辑。

## 性能参考

| 环境大小 | 打包时间 | 传输时间 (千兆网) | 解压时间 |
|---------|---------|------------------|---------|
| 1.8 GB | ~20s | ~5s | ~10s |
| 4.7 GB | ~4min | ~35s | ~2min |

## 许可证

MIT License

## 致谢

- [conda-pack](https://conda.github.io/conda-pack/) - 核心打包技术
- [rsync](https://rsync.samba.org/) - 高效文件传输
