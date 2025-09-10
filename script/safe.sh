#!/bin/bash
#
# 服务器安全加固脚本
#

set -Eeuo pipefail

# --- 全局配置与样式 ---
readonly LOG_DIR="/var/log/autoweb"
readonly LOG_FILE="${LOG_DIR}/safe.log"
readonly SSH_CONFIG_FILE="/etc/ssh/sshd_config"

# shellcheck disable=SC2034
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

CURRENT_SSH_PORT="22"

# --- 核心框架函数 ---

log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    
    echo -e "${color}${message}${NC}" > /dev/tty
    # 为日志文件剥离颜色代码
    printf "%b\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

run_command() {
    local description="$1"
    local command_str="$2"

    {
        echo "---"
        echo "任务: $description"
        echo "命令: $command_str"
        if bash -c "$command_str"; then
            echo "状态: 成功"
        else
            local exit_code=$?
            echo "状态: 失败 (退出码: $exit_code)"
            log "RED" "错误: 任务 '${description}' 执行失败。详情请查看日志: ${LOG_FILE}"
            exit "$exit_code"
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

ask_yes_no() {
    local question="$1"
    local default_answer="$2"
    local prompt="[y/N]"
    [[ "$default_answer" == "y" ]] && prompt="[Y/n]"
    
    local answer
    while true; do
        echo -n -e "${question} ${prompt}: " > /dev/tty
        read -r answer < /dev/tty
        answer="${answer:-$default_answer}"
        case "${answer,,}" in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "输入无效, 请输入 'y' 或 'n'。" > /dev/tty ;;
        esac
    done
}

# --- UFW 防火墙转发设置 ---
configure_ufw_forwarding() {
    log "CYAN" "--- [步骤 4/5] 正在检查 UFW 防火墙转发设置 ---"
    
    # 检查 ufw 命令是否存在且可执行
    if ! command -v ufw &> /dev/null; then
        log "YELLOW" "系统未安装 UFW 防火墙，跳过此步骤。"
        return
    fi
    
    # 检查 ufw 是否启用
    if ! ufw status | grep -qw "active"; then
        log "YELLOW" "UFW 防火墙当前未启用，跳过此步骤。"
        return
    fi
    
    local ufw_config_file="/etc/default/ufw"
    
    # 检查当前转发策略是否已为 ACCEPT
    if grep -q '^\s*DEFAULT_FORWARD_POLICY\s*=\s*"ACCEPT"' "$ufw_config_file"; then
        log "GREEN" "UFW 转发策略已正确配置为 'ACCEPT'，容器端口映射可正常工作。"
        return
    fi

    log "YELLOW" "警告：检测到您的 UFW 防火墙会阻止容器的端口映射！"
    log "YELLOW" "为了通过主机 IP 正常访问容器服务，需要开启 UFW 的转发功能。"
    
    if ask_yes_no "是否要自动修改配置开启 UFW 转发功能? (本地使用请开启，否则端口映射无效)" "n"; then
        log "CYAN" "正在修改 UFW 配置文件: ${ufw_config_file}..."
        # 使用 sed 精确替换，避免意外修改
        if sed -i 's/^\(DEFAULT_FORWARD_POLICY\s*=\s*\).*/\1"ACCEPT"/' "$ufw_config_file"; then
            log "GREEN" "配置文件修改成功。"
            log "CYAN" "正在重新加载 UFW 以应用新配置..."
            if ufw reload >> "$LOG_FILE" 2>&1; then
                log "GREEN" "UFW 已成功重载。端口转发现已永久开启。"
            else
                log "RED" "错误：UFW 重载失败。请稍后手动执行 'sudo ufw reload'。"
            fi
        else
            log "RED" "错误：修改 UFW 配置文件失败。请检查文件权限。"
        fi
    else
        log "YELLOW" "操作已取消。请注意：您将无法从外部网络访问此主机上容器的映射端口。"
    fi
}

# --- 主逻辑区 ---

main() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以root权限运行。${NC}"
       exit 1
    fi
    mkdir -p "$LOG_DIR"
    truncate -s 0 "$LOG_FILE"

    log "CYAN" "--- 服务器安全加固脚本已启动 ---"

    # --- 模块 1: 系统更新 ---
    log "CYAN" "\n[1/3] 更新系统软件包..."
    run_command "更新软件包列表" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq"
    if ask_yes_no "是否要升级已安装的软件包? (此操作可能需要较长时间)" "y"; then
        run_command "升级已安装的软件包" "export DEBIAN_FRONTEND=noninteractive; apt-get upgrade -y -qq"
    else
        log "YELLOW" "已跳过软件包升级步骤。"
    fi
    
    # --- 模块 2: SSH 服务加固 ---
    log "CYAN" "\n[2/3] 配置 SSH 服务..."
    local ssh_service_needs_restart=false
    local target_user="${SUDO_USER:-$(who am i | awk '{print $1}')}"

    # 修改 SSH 端口
    if ask_yes_no "是否需要更改默认的SSH端口(22)?" "n"; then
        local new_port
        while true; do
            echo -n "请输入新的SSH端口号 (1024-65535): " > /dev/tty
            read -r new_port < /dev/tty
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -gt 1023 ] && [ "$new_port" -le 65535 ]; then
                run_command "设置SSH端口为 ${new_port}" "sed -i.bak -E \"s/^[#\\s]*Port\\s+[0-9]+$/Port ${new_port}/\" \"$SSH_CONFIG_FILE\""
                if ! grep -q "^Port " "$SSH_CONFIG_FILE"; then
                    run_command "添加SSH端口配置" "echo 'Port ${new_port}' >> \"$SSH_CONFIG_FILE\""
                fi
                log "GREEN" "SSH端口已修改为: ${new_port}"
                CURRENT_SSH_PORT="$new_port"
                ssh_service_needs_restart=true
                break
            else
                log "RED" "输入无效, 请输入一个 1024 到 65535 之间的数字。"
            fi
        done
    fi

    # 启用密钥认证模式
    if ask_yes_no "是否启用密钥认证模式? (推荐、将禁用所有密码登录)" "n"; then
        {
            echo -e "\n${YELLOW}--- SSH 密钥生成指南 ---${NC}"
            echo -e "在您本地的电脑终端上运行: ${GREEN}ssh-keygen -t ed25519${NC}"
            echo -e "然后, 复制公钥文件的内容: ${GREEN}cat ~/.ssh/id_ed25519.pub${NC}"
            echo -e "${YELLOW}--------------------------${NC}\n"
        } > /dev/tty
        
        local public_key
        echo -n "请粘贴您的公钥内容用于登录授权: " > /dev/tty
        read -r public_key < /dev/tty

        if ! echo "$public_key" | ssh-keygen -l -f /dev/stdin &>/dev/null; then
            log "RED" "公钥格式无效或不完整。跳过 SSH 密钥配置。"
            log "YELLOW" "密码登录方式将保持启用状态。"
        else
            log "YELLOW" "此公钥将被添加给用户: '${target_user}'"
            if ! ask_yes_no "确认是此用户吗?" "y"; then
                echo -n "请输入目标用户名: " > /dev/tty
                read -r target_user_input < /dev/tty
                if ! id "$target_user_input" &>/dev/null; then
                    log "RED" "用户 '${target_user_input}' 不存在。中止密钥添加操作。"
                    public_key=""
                else
                    target_user="$target_user_input"
                    log "CYAN" "目标用户已指定为: ${target_user}"
                fi
            fi
            
            if [[ -n "$public_key" ]]; then
                local target_home
                target_home=$(getent passwd "$target_user" | cut -d: -f6)
                local target_ssh_dir="$target_home/.ssh"
                local authorized_keys_file="$target_ssh_dir/authorized_keys"

                run_command "为用户 ${target_user} 创建 .ssh 目录" "mkdir -p \"$target_ssh_dir\""
                run_command "设置 .ssh 目录权限为 700" "chmod 700 \"$target_ssh_dir\""
                run_command "添加公钥到 authorized_keys" "echo \"$public_key\" >> \"$authorized_keys_file\""
                run_command "设置 authorized_keys 文件权限为 600" "chmod 600 \"$authorized_keys_file\""
                run_command "设置 .ssh 目录的所有权" "chown -R \"$target_user:$target_user\" \"$target_ssh_dir\""
                
                log "CYAN" "正在应用 SSH 安全配置..."
                local sed_cmd_base="sed -i.bak -E"
                run_command "启用公钥认证" "$sed_cmd_base 's/^[#\\s]*PubkeyAuthentication\\s+\\w+$/PubkeyAuthentication yes/' \"$SSH_CONFIG_FILE\""
                run_command "禁用密码认证" "$sed_cmd_base 's/^[#\\s]*PasswordAuthentication\\s+\\w+$/PasswordAuthentication no/' \"$SSH_CONFIG_FILE\""
                run_command "设置 PermitRootLogin 为 prohibit-password" "$sed_cmd_base 's/^[#\\s]*PermitRootLogin\\s+.*$/PermitRootLogin prohibit-password/' \"$SSH_CONFIG_FILE\""

                local sshd_config_dir="/etc/ssh/sshd_config.d"
                if [ -d "$sshd_config_dir" ]; then
                    log "YELLOW" "正在检查并修改 ${sshd_config_dir} 目录下的配置文件..."
                    find "$sshd_config_dir" -type f -name "*.conf" -print0 | while IFS= read -r -d '' conf_file; do
                        log "CYAN" "  -> 正在处理文件: ${conf_file}"
                        run_command "在文件 ${conf_file} 中禁用密码认证" "$sed_cmd_base 's/^[#\\s]*PasswordAuthentication\\s+\\w+$/PasswordAuthentication no/' \"$conf_file\""
                    done
                fi

                log "GREEN" "密钥认证已成功启用。"
                ssh_service_needs_restart=true
            fi
        fi
    fi

    if [ "$ssh_service_needs_restart" = true ]; then
        log "CYAN" "正在重启 SSH 服务以应用配置..."
        if systemctl restart ssh; then
            log "GREEN" "SSH 服务已成功重启。"
            {
                echo -e "\n${YELLOW}重要提示:${NC} 请不要关闭当前的 SSH 会话!"
                echo -e "请打开一个新的终端窗口, 使用以下命令测试新连接:"
                echo -e "${GREEN}ssh -p ${CURRENT_SSH_PORT} ${target_user}@<您的服务器IP>${NC}"
                echo -e "确认新连接成功后, 再关闭此窗口。"
            } > /dev/tty
        else
            log "RED" "SSH 服务重启失败! 请手动检查配置文件并使用 'systemctl restart ssh' 重启服务。"
        fi
    fi

    # --- 模块 3: UFW 防火墙配置 ---
    log "CYAN" "\n[3/3] 配置 UFW 防火墙..."
    
    if ! command -v ufw &>/dev/null; then
      log "CYAN" "检测到 UFW 未安装, 正在自动安装..."
      run_command "安装 UFW" "apt-get install -y -qq ufw"
    fi

    local allowed_ports=("$CURRENT_SSH_PORT" "80" "443")
    
    log "CYAN" "默认将放行的 TCP 端口: ${allowed_ports[*]}"
    echo -n "请输入需要额外放行的 TCP 端口 (多个端口请用空格分隔): " > /dev/tty
    read -r -a extra_ports < /dev/tty
    
    if [ ${#extra_ports[@]} -gt 0 ]; then
        for port in "${extra_ports[@]}"; do
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                allowed_ports+=("$port")
            else
                log "YELLOW" "已跳过无效的端口输入: ${port}"
            fi
        done
    fi
    
    local unique_ports
    mapfile -t unique_ports < <(printf "%s\n" "${allowed_ports[@]}" | sort -nu)

    if ufw status | grep -q "Status: active"; then
      log "YELLOW" "UFW 防火墙当前已激活。"
      if ask_yes_no "是否需要重置所有现有的防火墙规则?" "y"; then
        run_command "重置 UFW 规则" "ufw --force reset"
      fi
    fi

    run_command "设置默认入站策略为 '拒绝'" "ufw default deny incoming"
    run_command "设置默认出站策略为 '允许'" "ufw default allow outgoing"

    log "CYAN" "正在为以下 TCP 端口添加入站规则: ${unique_ports[*]}"
    for port in "${unique_ports[@]}"; do
        run_command "允许 TCP 端口 ${port}" "ufw allow $port/tcp"
    done
    run_command "允许 UDP 端口 443 (用于 HTTP/3)" "ufw allow 443/udp"

    log "GREEN" "防火墙规则配置完毕。"

    if ask_yes_no "是否立即启用 UFW 防火墙?" "y"; then
      run_command "启用 UFW" "ufw --force enable"
      log "GREEN" "防火墙已启用, 并已设置为开机自启动。"
    else
      log "YELLOW" "防火墙规则已配置, 但未启用。"
    fi

    log "CYAN" "\n--- 防火墙最终状态 ---"
    ufw status verbose > /dev/tty

    log "CYAN" "\n--- 配置UFW转发策略 ---"
    configure_ufw_forwarding

    log "GREEN" "\n--- 服务器安全加固脚本执行完毕 ---"
}

main "$@"
