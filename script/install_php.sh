#!/bin/bash
#
# PHP-FPM 安装与升降级脚本
#
# 描述: 用于在 Debian/Ubuntu 系统上安装或升级 PHP-FPM 及常用扩展
#       支持全新安装和版本升级、降级，自动处理依赖、服务启动和旧版本清理
#
# 注意事项:
#   - 仅支持使用 Sury 源的 Debian/Ubuntu 系统
#   - 升级时会卸载旧版本包，避免系统残留
#   - 脚本使用严格错误处理，遇到错误会立即退出
#

set -Eeuo pipefail

# 调试开关
readonly SCRIPT_DEBUG=${SCRIPT_DEBUG:-false}
if [[ "$SCRIPT_DEBUG" == "true" ]]; then
    set -x
fi

# 配置常量
readonly APP_NAME="PHP"
readonly LOG_DIR="/var/log/autoweb"
readonly LOG_FILE="$LOG_DIR/install_php.log"

# 终端颜色定义
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
# 核心函数
# ==============================================================================

# 日志函数
log() {
    local color_name="$1" message="$2"
    local color=""
    case "$color_name" in
        "CYAN")   color="$CYAN"   ;;
        "GREEN")  color="$GREEN"  ;;
        "RED")    color="$RED"    ;;
        "YELLOW") color="$YELLOW" ;;
        *)        color="$NC"     ;;
    esac
    
    echo -e "${color}${message}${NC}"
    printf "%s\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

debug_log() {
    if [[ "$SCRIPT_DEBUG" == "true" ]]; then
        log "YELLOW" "DEBUG: $1"
    fi
}

run_command() {
    local description="$1"
    shift
    {
        echo "---"
        echo "执行: $description"
        echo "命令: $*"
        if env "$@"; then
            echo "状态: 成功"
        else
            local exit_code=$?
            echo "状态: 失败 (退出码: $exit_code)"
            log "RED" "错误: '${description}' 失败。详情请查看日志: ${LOG_FILE}"
            exit $exit_code
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" hint="[Y/n]"
    if [[ "$default" == "n" ]]; then hint="[y/N]"; fi
    while true; do
        read -rp "$prompt $hint: " answer
        answer=${answer:-$default}
        case "$answer" in [Yy]*) return 0;; [Nn]*) return 1;; esac
    done
}

compare_versions() {
    local v1="$1" v2="$2"
    IFS='.' read -ra v1_parts <<< "$v1"
    IFS='.' read -ra v2_parts <<< "$v2"
    local max_len=$(( ${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]} ))
    for ((i=0; i<max_len; i++)); do
        local p1=${v1_parts[i]:-0} p2=${v2_parts[i]:-0}
        if (( 10#$p1 > 10#$p2 )); then return 1; fi
        if (( 10#$p1 < 10#$p2 )); then return 2; fi
    done
    return 0
}

perform_php_installation() {
    local php_version="$1"
    log "CYAN" "\n==> [1/2] 正在为 PHP ${php_version} 准备并安装软件包..."
    local packages_to_install=()
    local all_requested_packages=(
        "php${php_version}-fpm" "php${php_version}-mysql" "php${php_version}-redis"
        "php${php_version}-gd" "php${php_version}-igbinary" "php${php_version}-imagick"
        "php${php_version}-intl" "php${php_version}-zip" "php${php_version}-xml"
        "php${php_version}-curl" "php${php_version}-mbstring"
    )
    local available_packages
    available_packages=$(apt-cache search --names-only "^php${php_version}-" | cut -d' ' -f1 2>/dev/null || echo "")
    for pkg in "${all_requested_packages[@]}"; do
        if echo "$available_packages" | grep -q "^$pkg$"; then
            packages_to_install+=("$pkg")
        else
            log "YELLOW" "跳过不可用的扩展: $pkg"
        fi
    done
    if [ ${#packages_to_install[@]} -eq 0 ]; then
        log "RED" "错误：找不到任何与 PHP ${php_version} 相关的可用软件包。请检查版本号是否正确。"
        exit 1
    fi

    log "CYAN" "将要安装以下软件包:"
    for pkg in "${packages_to_install[@]}"; do
        log "CYAN" "  - $pkg"
    done

    log "CYAN" "\n正在安装，请耐心等待..."
    run_command "安装所有 PHP 软件包" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages_to_install[@]}"
    log "CYAN" "\n==> [2/2] 正在启动并验证 PHP-FPM 服务..."
    local fpm_service="php${php_version}-fpm"
    run_command "重启 PHP-FPM 服务" systemctl restart "$fpm_service"
    if ! systemctl is-active --quiet "$fpm_service"; then
        log "RED" "错误：PHP-FPM 服务 (${fpm_service}) 启动失败！"
        exit 1
    fi
    run_command "设置 PHP-FPM 开机自启" systemctl enable "$fpm_service" >/dev/null 2>&1
    log "GREEN" "PHP-FPM 服务 (${fpm_service}) 已启动并设为开机自启。"
    PHP_TO_INSTALL="$php_version"
}

uninstall_old_php() {
    local old_version="$1"
    log "CYAN" "正在卸载旧版本 PHP ${old_version} 包..."
    run_command "卸载旧版本 PHP 包" apt-get remove -y --purge "php${old_version}-*"
}

get_available_php_versions() {
    apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/p' | sort -V
}

handle_php_switch() {
    local current_version="$1"
    log "CYAN" "\n=== PHP 版本切换操作 ==="
    local available_versions; available_versions=$(get_available_php_versions)
    log "CYAN" "可用的 PHP 版本:"
    local i=1; local versions_array=()
    while IFS= read -r version; do
        versions_array+=("$version")
        log "CYAN" "  $i. $version$([[ "$version" == "$current_version" ]] && echo " (当前版本)")"
        ((i++))
    done <<< "$available_versions"
    local selected_index;
    while true; do
        read -rp "请选择要切换到的版本 (输入数字 1-$((i-1))): " selected_index
        if [[ "$selected_index" =~ ^[0-9]+$ && "$selected_index" -ge 1 && "$selected_index" -le $((i-1)) ]]; then break; fi
        log "RED" "无效选择，请输入 1 到 $((i-1)) 之间的数字。"
    done
    local target_version="${versions_array[$((selected_index-1))]}"
    if [[ "$current_version" == "$target_version" ]]; then log "YELLOW" "选择的版本与当前相同，已取消。"; return 1; fi
    if ! ask_yes_no "您即将从 PHP $current_version 切换到 PHP $target_version。确认吗?" "n"; then log "YELLOW" "操作已取消。"; return 1; fi
    perform_php_installation "$target_version"
    uninstall_old_php "$current_version"
    log "GREEN" "版本切换完成！"
    return 0
}

main_handler() {
    local highest_installed="$1" latest_available="$2"
    debug_log "进入 main_handler。已安装: $highest_installed, 最新: $latest_available"

    local comparison_result=0
    if compare_versions "$highest_installed" "$latest_available"; then
        comparison_result=0
    else
        comparison_result=$?
    fi
    
    debug_log "版本比较结果: $comparison_result"

    case $comparison_result in
        2) # 可升级
            log "YELLOW" "发现新版本！"
            if ask_yes_no "是否从 ${highest_installed} 升级到 ${latest_available}?" "y"; then
                perform_php_installation "$latest_available"
                uninstall_old_php "$highest_installed"
            else
                log "CYAN" "您选择了不升级。"
                if ask_yes_no "是否要切换到其他版本?" "n"; then
                    handle_php_switch "$highest_installed" || true
                else log "YELLOW" "操作已取消。"; fi
            fi
            ;;
        1) # 已是更新版
            log "GREEN" "您已是最新版 (或更新的测试版)。"
            if ask_yes_no "是否要切换到其他版本?" "n"; then
                handle_php_switch "$highest_installed" || true
            else log "YELLOW" "操作已取消。"; fi
            ;;
        0) # 版本相同
            log "GREEN" "您已是最新版。"
            if ask_yes_no "是否要切换到其他版本?" "n"; then
                handle_php_switch "$highest_installed" || true
            elif ask_yes_no "是否要强制重新安装 ${highest_installed}?" "n"; then
                perform_php_installation "$highest_installed"
            else
                log "YELLOW" "操作已取消。"
            fi
            ;;
    esac
    debug_log "已退出 main_handler"
}

# 脚本主入口
main() {
    mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" && true > "$LOG_FILE"
    if ! [[ -t 0 ]]; then
        log "RED" "错误：此脚本需要在一个交互式终端中运行。"
        exit 1
    fi
    if [[ $EUID -ne 0 ]]; then
       log "RED" "错误：请以 root 用户运行此脚本。"
       exit 1
    fi

    log "CYAN" "--- ${APP_NAME} 安装与更新工具 ---"
    log "CYAN" "==> 正在配置 Sury 第三方 PHP 源..."

    run_command "更新软件包列表" apt-get update -qq
    if ! command -v extrepo >/dev/null 2>&1; then
        run_command "安装 extrepo" DEBIAN_FRONTEND=noninteractive apt-get install -y -qq extrepo
    else
        log "CYAN" "extrepo 工具已安装。"
    fi
    run_command "启用 Sury 源" extrepo enable sury >/dev/null
    run_command "再次更新软件包列表" apt-get update -qq
    log "GREEN" "源配置完成。"

    PHP_TO_INSTALL=""
    LATEST_AVAILABLE_VERSION=$(get_available_php_versions | tail -n1 || true)
    HIGHEST_INSTALLED_VERSION=$(dpkg-query -W -f='${Package}\n' 'php*-fpm' 2>/dev/null | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/p' | sort -V | tail -n1 || true)

    if [[ -z "$LATEST_AVAILABLE_VERSION" ]]; then
        log "RED" "错误：无法从 APT 源中找到任何可用的 PHP 版本。"
        exit 1
    fi

    if [[ -z "$HIGHEST_INSTALLED_VERSION" ]]; then
        log "CYAN" "未检测到 PHP-FPM，即将开始全新安装。"
        read -rp "请输入要安装的 PHP 版本 (如 8.3, 直接回车将安装最新版 ${LATEST_AVAILABLE_VERSION}): " PHP_VERSION_INPUT
        TARGET_VERSION=${PHP_VERSION_INPUT:-$LATEST_AVAILABLE_VERSION}
        perform_php_installation "$TARGET_VERSION"
    else
        log "GREEN" "检测到已安装的最高 PHP 版本: ${HIGHEST_INSTALLED_VERSION}"
        log "CYAN" "最新可用版本: ${LATEST_AVAILABLE_VERSION}"
        main_handler "$HIGHEST_INSTALLED_VERSION" "$LATEST_AVAILABLE_VERSION"
    fi

    if [[ -n "$PHP_TO_INSTALL" ]]; then
        log "CYAN" "\n正在获取最终安装信息..."
        INI_PATH="/etc/php/${PHP_TO_INSTALL}/fpm/php.ini"
        if [ -f "$INI_PATH" ]; then
            PHP_VERSION_FULL=$(php"${PHP_TO_INSTALL}" -v 2>/dev/null | head -n1 | sed -nE 's/PHP ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' || echo "未知")
            SOCKET_PATH=$(grep -E "^\s*listen\s*=" "/etc/php/${PHP_TO_INSTALL}/fpm/pool.d/www.conf" | awk -F'=' '{print $2}' | xargs || echo "未知")
            log "GREEN" "\n--- ${APP_NAME} 操作成功！ ---"
            log "CYAN" "  当前运行版本: ${NC}${PHP_VERSION_FULL} (主版本 ${PHP_TO_INSTALL})"
            log "CYAN" "  php.ini:      ${NC}${INI_PATH}"
            log "CYAN" "  Socket 路径:  ${NC}${SOCKET_PATH}"
        fi
    else
        log "CYAN" "\n未执行任何安装或更改操作。"
    fi
}

main "$@"
exit 0
