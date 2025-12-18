#!/bin/bash
#
# Conda环境传输脚本 (生产版本)
# 用于在两台服务器之间自动打包、传输和安装conda环境
#
# 支持的机器：
#   - 192.168.5.8 (14900K+5090 工作站, Ubuntu 24.04)
#   - glm-lxd (DGX-A100, 通过 172.20.73.2:28888 访问)
#

set -e

# ==================== 配置 ====================
MINIFORGE_BASE="/home/cpu/miniforge3"
ENVS_DIR="${MINIFORGE_BASE}/envs"
TEMP_DIR="/tmp/conda_transfer"
USER="cpu"

# 机器配置
WORKSTATION_IP="192.168.5.8"
DGX_HOST="172.20.73.2"
DGX_PORT="28888"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 工具函数 ====================
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_header() {
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}========================================${NC}\n"
}

# 执行远程SSH命令
run_remote() {
    local machine="$1"
    shift
    if [[ "$machine" == "workstation" ]]; then
        ssh "${USER}@${DGX_HOST}" -p "${DGX_PORT}" "$@"
    else
        ssh "${USER}@${WORKSTATION_IP}" "$@"
    fi
}

# ==================== 机器识别 ====================
detect_machine() {
    local current_ips=$(hostname -I 2>/dev/null || echo "")
    local hostname=$(hostname)
    
    if echo "$current_ips" | grep -q "$WORKSTATION_IP"; then
        echo "workstation"
    elif [[ "$hostname" == "glm-lxd" ]]; then
        echo "dgx"
    else
        echo "unknown"
    fi
}

get_machine_name() {
    case "$1" in
        "workstation") echo "工作站 (192.168.5.8, 14900K+5090)" ;;
        "dgx")         echo "DGX-A100 (glm-lxd)" ;;
        *)             echo "未知机器" ;;
    esac
}

get_target_name() {
    case "$1" in
        "workstation") echo "DGX-A100 (glm-lxd)" ;;
        "dgx")         echo "工作站 (192.168.5.8)" ;;
    esac
}

# ==================== 环境列表 ====================
list_local_envs() {
    print_info "本地conda环境列表："
    echo ""
    
    if [[ ! -d "$ENVS_DIR" ]]; then
        print_error "环境目录不存在: $ENVS_DIR"
        return 1
    fi
    
    local i=1
    while IFS= read -r line; do
        local env_name=$(echo "$line" | awk '{print $1}')
        local env_size=$(echo "$line" | awk '{print $2}')
        if [[ -n "$env_name" && "$env_name" != "." && "$env_name" != ".." ]]; then
            echo -e "  ${GREEN}[$i]${NC} ${env_name} (${env_size})"
            ((i++))
        fi
    done < <(du -sh "${ENVS_DIR}"/*/ 2>/dev/null | sed 's|.*/||;s|/$||' | awk -F'\t' '{print $2 "\t" $1}' || true)
    
    # 备用方法：如果上面的方法失败
    if [[ $i -eq 1 ]]; then
        for env in $(ls -1 "$ENVS_DIR" 2>/dev/null | grep -v '^\.' || true); do
            local size=$(du -sh "${ENVS_DIR}/${env}" 2>/dev/null | cut -f1 || echo "?")
            echo -e "  ${GREEN}[$i]${NC} ${env} (${size})"
            ((i++))
        done
    fi
    
    if [[ $i -eq 1 ]]; then
        print_warning "没有找到conda环境"
        return 1
    fi
    echo ""
}

list_remote_envs() {
    local machine="$1"
    print_info "远程机器conda环境列表："
    echo ""
    
    # 一次性获取所有环境及其大小
    local remote_output=$(run_remote "$machine" "for d in ${ENVS_DIR}/*/; do if [ -d \"\$d\" ]; then size=\$(du -sh \"\$d\" 2>/dev/null | cut -f1); name=\$(basename \"\$d\"); echo \"\$name \$size\"; fi; done" 2>/dev/null || true)
    
    if [[ -z "$remote_output" ]]; then
        print_warning "远程机器没有找到conda环境"
        return 0
    fi
    
    while IFS= read -r line; do
        local env_name=$(echo "$line" | awk '{print $1}')
        local env_size=$(echo "$line" | awk '{print $2}')
        if [[ -n "$env_name" ]]; then
            echo -e "  ${YELLOW}•${NC} ${env_name} (${env_size})"
        fi
    done <<< "$remote_output"
    echo ""
}

get_local_envs_array() {
    ls -1 "$ENVS_DIR" 2>/dev/null | grep -v '^\.' | grep -v '^$' || true
}

# ==================== 主要功能 ====================
check_conda_pack() {
    # 直接检查conda-pack可执行文件是否存在
    local conda_pack_bin="${MINIFORGE_BASE}/bin/conda-pack"
    
    if [[ ! -x "$conda_pack_bin" ]]; then
        print_warning "conda-pack 未安装，正在安装..."
        "${MINIFORGE_BASE}/bin/conda" install -y -c conda-forge conda-pack
        
        # 验证安装成功
        if [[ ! -x "$conda_pack_bin" ]]; then
            print_error "conda-pack 安装失败"
            exit 1
        fi
        print_success "conda-pack 安装完成"
    fi
}

pack_environment() {
    local env_name="$1"
    local pack_file="${TEMP_DIR}/${env_name}.tar.gz"
    
    print_info "正在打包环境: ${env_name}" >&2
    print_info "这可能需要几分钟，取决于环境大小..." >&2
    
    mkdir -p "$TEMP_DIR"
    
    # 使用完整路径调用conda-pack
    "${MINIFORGE_BASE}/bin/conda-pack" -n "$env_name" -o "$pack_file" --force >&2
    
    # 验证打包文件完整性
    print_info "验证打包文件完整性..." >&2
    if ! gzip -t "$pack_file" 2>/dev/null; then
        print_error "打包文件损坏，gzip 校验失败" >&2
        rm -f "$pack_file"
        echo "PACK_FAILED"
        return 1
    fi
    
    # 验证 tar 归档可读 (检查是否包含关键文件，忽略 conda-pack 可能产生的尾部空记录警告)
    if ! tar -tzf "$pack_file" 2>/dev/null | grep -q "^bin/activate$"; then
        print_error "打包文件损坏，缺少关键文件 bin/activate" >&2
        rm -f "$pack_file"
        echo "PACK_FAILED"
        return 1
    fi
    print_success "文件完整性验证通过" >&2
    
    local size=$(du -sh "$pack_file" | cut -f1)
    print_success "打包完成: ${pack_file} (${size})" >&2
    
    # 计算 MD5 校验和
    local md5sum=$(md5sum "$pack_file" | awk '{print $1}')
    echo "$md5sum" > "${pack_file}.md5"
    print_info "MD5: ${md5sum}" >&2
    
    echo "$pack_file"
}

transfer_environment() {
    local pack_file="$1"
    local machine="$2"
    
    print_info "正在传输环境到远程机器..."
    
    # 创建远程临时目录
    run_remote "$machine" "mkdir -p ${TEMP_DIR}"
    
    # 使用rsync传输
    if [[ "$machine" == "workstation" ]]; then
        print_info "目标: ${USER}@${DGX_HOST}:${TEMP_DIR}/ (端口 ${DGX_PORT})"
        rsync -avz --progress -e "ssh -p ${DGX_PORT}" "$pack_file" "${USER}@${DGX_HOST}:${TEMP_DIR}/"
    else
        print_info "目标: ${USER}@${WORKSTATION_IP}:${TEMP_DIR}/"
        rsync -avz --progress -e "ssh" "$pack_file" "${USER}@${WORKSTATION_IP}:${TEMP_DIR}/"
    fi
    
    # 验证传输完整性 (MD5校验)
    local local_md5=$(cat "${pack_file}.md5" 2>/dev/null || md5sum "$pack_file" | awk '{print $1}')
    print_info "验证传输完整性 (本地 MD5: ${local_md5})..."
    local remote_md5=$(run_remote "$machine" "md5sum ${pack_file} | awk '{print \$1}'")
    
    if [[ "$local_md5" != "$remote_md5" ]]; then
        print_error "传输校验失败！"
        print_error "  本地 MD5: ${local_md5}"
        print_error "  远程 MD5: ${remote_md5}"
        exit 1
    fi
    print_success "传输校验通过 (MD5: ${remote_md5})"
}

install_remote_environment() {
    local env_name="$1"
    local machine="$2"
    local pack_file="${TEMP_DIR}/${env_name}.tar.gz"
    local target_dir="${ENVS_DIR}/${env_name}"
    
    print_info "正在远程安装环境: ${env_name}"
    
    # 检查远程是否已存在该环境
    if run_remote "$machine" "test -d ${target_dir}" 2>/dev/null; then
        print_warning "远程已存在环境: ${env_name}"
        read -p "是否覆盖? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            print_info "跳过安装"
            return 1
        fi
        print_info "删除远程旧环境..."
        run_remote "$machine" "rm -rf ${target_dir}"
    fi
    
    # 解压环境
    print_info "解压环境到: ${target_dir}"
    
    # 先验证远程文件完整性
    print_info "验证远程文件完整性..."
    if ! run_remote "$machine" "gzip -t ${pack_file}" 2>/dev/null; then
        print_error "远程文件损坏，gzip 校验失败"
        exit 1
    fi
    
    # 解压 (忽略 tar 返回码，因为 conda-pack 可能产生尾部空记录导致非零返回码)
    run_remote "$machine" "mkdir -p ${target_dir}"
    run_remote "$machine" "tar -xzf ${pack_file} -C ${target_dir} --ignore-zeros 2>/dev/null || true"
    
    # 验证解压是否成功 (检查关键文件是否存在)
    if ! run_remote "$machine" "test -f ${target_dir}/bin/activate && test -f ${target_dir}/bin/python"; then
        print_error "解压失败: 关键文件不存在"
        exit 1
    fi
    print_success "解压完成"
    
    # 修复路径
    print_info "修复环境路径..."
    run_remote "$machine" "source ${target_dir}/bin/activate && conda-unpack" 2>/dev/null || {
        print_warning "conda-unpack 未找到，尝试手动修复..."
        run_remote "$machine" "${target_dir}/bin/python -c 'import conda_pack; conda_pack.unpack()'" 2>/dev/null || true
    }
    
    print_success "环境安装完成: ${env_name}"
}

cleanup() {
    local env_name="$1"
    local machine="$2"
    local pack_file="${TEMP_DIR}/${env_name}.tar.gz"
    
    print_info "清理临时文件..."
    
    # 清理本地
    if [[ -f "$pack_file" ]]; then
        rm -f "$pack_file"
        print_info "已删除本地: ${pack_file}"
    fi
    
    # 清理远程
    run_remote "$machine" "rm -f ${pack_file}" 2>/dev/null || true
    print_info "已删除远程: ${pack_file}"
    
    print_success "清理完成"
}

# ==================== 主流程 ====================
main() {
    print_header "Conda 环境传输工具"
    
    # 检测当前机器
    local current_machine=$(detect_machine)
    local machine_name=$(get_machine_name "$current_machine")
    
    if [[ "$current_machine" == "unknown" ]]; then
        print_error "无法识别当前机器"
        print_info "支持的机器："
        print_info "  - 工作站 (192.168.5.8)"
        print_info "  - DGX-A100 (glm-lxd)"
        exit 1
    fi
    
    print_info "当前机器: ${machine_name}"
    
    local target_machine=$(get_target_name "$current_machine")
    print_info "目标机器: ${target_machine}"
    echo ""
    
    # 测试远程连接
    print_info "测试远程连接..."
    if ! run_remote "$current_machine" "echo 'SSH连接成功'" 2>/dev/null; then
        print_error "无法连接到远程机器"
        print_info "请检查SSH配置和网络连接"
        exit 1
    fi
    print_success "远程连接正常"
    echo ""
    
    # 检查conda-pack
    check_conda_pack
    
    # 显示环境列表
    echo ""
    list_local_envs || exit 1
    list_remote_envs "$current_machine"
    
    # 获取本地环境数组
    mapfile -t envs_array < <(get_local_envs_array)
    
    # 用户选择环境
    echo -ne "${CYAN}请输入要传输的环境名称或序号: ${NC}"
    read -r user_input
    
    local env_name=""
    
    if [[ "$user_input" =~ ^[0-9]+$ ]]; then
        local idx=$((user_input - 1))
        if [[ $idx -ge 0 && $idx -lt ${#envs_array[@]} ]]; then
            env_name="${envs_array[$idx]}"
        else
            print_error "无效的序号: $user_input"
            exit 1
        fi
    else
        env_name="$user_input"
    fi
    
    # 验证环境存在
    if [[ ! -d "${ENVS_DIR}/${env_name}" ]]; then
        print_error "环境不存在: ${env_name}"
        exit 1
    fi
    
    print_info "选择的环境: ${env_name}"
    echo ""
    
    # 确认操作
    echo -e "${YELLOW}即将执行以下操作:${NC}"
    echo -e "  1. 在本地打包环境 ${GREEN}${env_name}${NC}"
    echo -e "  2. 传输到 ${GREEN}${target_machine}${NC}"
    echo -e "  3. 安装到 ${GREEN}${ENVS_DIR}/${env_name}${NC}"
    echo -e "  4. 修复路径"
    echo -e "  5. 清理临时文件"
    echo ""
    read -p "确认继续? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "操作已取消"
        exit 0
    fi
    
    echo ""
    print_header "开始传输"
    
    # 执行打包
    local pack_file
    pack_file=$(pack_environment "$env_name")
    if [[ "$pack_file" == "PACK_FAILED" || -z "$pack_file" || ! -f "$pack_file" ]]; then
        print_error "打包失败，请检查环境 ${env_name}"
        print_info "建议尝试: conda install --force-reinstall -n ${env_name} <有问题的包>"
        exit 1
    fi
    echo ""
    
    # 传输
    transfer_environment "$pack_file" "$current_machine"
    echo ""
    
    # 安装
    install_remote_environment "$env_name" "$current_machine"
    echo ""
    
    # 清理
    cleanup "$env_name" "$current_machine"
    echo ""
    
    print_header "传输完成"
    print_success "环境 ${env_name} 已成功传输到 ${target_machine}"
    print_info "可以在目标机器上使用: conda activate ${env_name}"
}

# 运行
main
