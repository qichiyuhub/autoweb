#!/bin/bash
#
# ==============================================================================
#  Podman 管理面板
# ==============================================================================
#  描述: 一个功能全面的、交互式的命令行工具，用于简化 Podman 容器、镜像、
#        网络和 Compose 项目的日常管理
#
#  特性:
#  - 仪表盘式主菜单，实时显示系统状态。
#  - 纯数字菜单，统一交互逻辑。
#  - 全生命周期容器管理 (启/停/重启/日志/终端/删除/开机自启)。
#  - 完整的 Compose 项目工作流 (创建/管理/删除)。
#  - 完整的镜像和网络管理模块。
#  - 全局自动更新服务的状态管理，需要创建容器是添加更新标签 --label "io.containers.autoupdate=registry"，并且规范命名镜像名称： docker.io/xream/sub-store:latest
# ==============================================================================
set -Eeuo pipefail

# --- 全局常量与配置 ---
readonly COMPOSE_BASE_DIR="/opt/podman-compose"
readonly COMPOSE_FILE_NAME="docker-compose.yml"
readonly RUN_HISTORY_FILE="/opt/autoweb/podman_run_history.conf"

# --- 颜色定义 ---
readonly C_RESET='\033[0m'
readonly C_CYAN='\033[0;36m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[1;33m'
readonly C_GRAY='\033[0;90m'

# ==============================================================================
#  核心工具函数 (Core Utilities)
# ==============================================================================

# 统一日志记录
log() {
    local color_name="$1" message="$2" color_code
    case "${color_name^^}" in
        CYAN)   color_code="$C_CYAN"   ;;
        GREEN)  color_code="$C_GREEN"  ;;
        RED)    color_code="$C_RED"    ;;
        YELLOW) color_code="$C_YELLOW" ;;
        GRAY)   color_code="$C_GRAY"   ;;
        *)      color_code="$C_RESET"  ;;
    esac
    echo -e "${color_code}${message}${C_RESET}"
}

# 暂停脚本，等待用户按键
press_any_key_to_continue() {
    log "YELLOW" "\n-> 按任意键返回..."
    read -n 1 -s -r
}

# 检查依赖项
check_dependencies() {
    local missing_deps=0
    for cmd in podman podman-compose; do
        if ! command -v "$cmd" &> /dev/null; then
            log "RED" "错误: 核心依赖 '$cmd' 未找到。"
            missing_deps=1
        fi
    done
    if ! command -v jq &> /dev/null; then
        log "YELLOW" "警告: 'jq' 未安装。JSON 输出将不会被格式化。"
    fi
    if [[ "$missing_deps" -eq 1 ]]; then
        log "YELLOW" "请先安装所需依赖后再运行此脚本。"
        exit 1
    fi
}

# Yes/No 确认
confirm() {
    local prompt="${1:-您确定吗？}"
    while true; do
        read -r -p "$(echo -e "${C_YELLOW}${prompt} (y/n): ${C_RESET}")" choice
        case "$choice" in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            *     ) log "RED" "请输入 'y' 或 'n'。" ;;
        esac
    done
}

# 执行并记录 Podman 命令
run_podman_command() {
    log "CYAN" "  \$ podman $*"
    if podman "$@"; then
        return 0
    else
        log "RED" "  命令执行失败。"
        return 1
    fi
}

# 检查是否以 root 身份运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "RED" "错误: 此操作需要 root 权限。请使用 'sudo' 运行此脚本。"
        return 1
    fi
    return 0
}

# 统一管理 systemd 服务 (开机自启)
manage_systemd_service() {
    local container_name="$1" action="$2"
    if [ -z "$container_name" ]; then log "RED" "内部错误: 未提供容器名称。"; return 1; fi

    local service_name="container-${container_name}.service"
    local service_file="/etc/systemd/system/${service_name}"

    case "$action" in
        enable)
            if ! check_root; then return 1; fi
            log "YELLOW" "正在为容器 '${container_name}' 生成最新的 systemd 服务文件..."
            if ! podman generate systemd --name "$container_name" --files --new --restart-policy=always --container-prefix=container >/dev/null 2>&1; then
                log "RED" "生成 systemd 文件失败。"
                return 1
            fi
            
            log "YELLOW" "移动服务文件到 ${service_file}..."
            if ! mv -f "./${service_name}" "${service_file}"; then
                 log "RED" "移动文件失败，请检查权限。"
                 rm -f "./${service_name}" # 清理生成的垃圾文件
                 return 1
            fi

            log "YELLOW" "重新加载 systemd 并启用服务..."
            systemctl daemon-reload
            systemctl enable --now "${service_name}" >/dev/null 2>&1
            log "GREEN" "容器 '${container_name}' 的开机自启动已成功启用！"
            ;;
        status_text)
            if systemctl is-enabled "container-${container_name}.service" &>/dev/null; then
                echo -e "${C_GREEN}✔ 已启用${C_RESET}"
            else
                echo -e "${C_GRAY}✘ 未启用${C_RESET}" 
            fi
            ;;
        *)
            log "RED" "未知的 systemd 操作: $action"
            return 1
            ;;
    esac
}

# ==============================================================================
#  1. 容器管理 (Container Management)
# ==============================================================================
container_menu() {
    while true; do
        clear
        log "CYAN" "--- 1. 容器管理 ---"
        
        local containers=()
        mapfile -t containers < <(podman ps -a --format "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}" --no-trunc)

        printf "  %-4s %-15s %-25s %-30s %-22s %s\n" "编号" "ID" "NAMES" "IMAGE" "STATUS" "开机自启"
        echo "----------------------------------------------------------------------------------------------------------------------"
        if [ ${#containers[@]} -eq 0 ]; then
            log "YELLOW" "  没有找到任何容器。"
        else
            for i in "${!containers[@]}"; do
                IFS=$'\t' read -r id names image status <<< "${containers[$i]}"
                local color="$C_GRAY"
                if [[ "$status" =~ ^Up ]]; then color="$C_GREEN"
                elif [[ "$status" =~ ^Exited ]]; then color="$C_YELLOW"
                fi
                local autostart_status
                autostart_status=$(manage_systemd_service "$names" "status_text")
                printf "  [%-2d] %-15.12s ${C_CYAN}%-25s${C_RESET} %-30s ${color}%-22s${C_RESET} %s\n" "$((i+1))" "$id" "$names" "$image" "$status" "$autostart_status"
            done
        fi
        echo "----------------------------------------------------------------------------------------------------------------------"

        log "YELLOW" "\n请选择操作:"
        echo "  [1] 启动    [2] 停止    [3] 重启    [4] 日志"
        echo "  [5] 终端    [6] 详情    [7] 删除    [8] 开机自启"
        echo "  [0] 返回主菜单"
        read -r -p "输入选项: " sub_choice

        case "$sub_choice" in
            0) return ;;
            [1-8]) 
                if [ ${#containers[@]} -eq 0 ]; then
                    log "YELLOW" "没有可操作的容器。"
                else
                    local num
                    read -r -p "请输入要操作的容器编号: " num
                    
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#containers[@]}" ]; then
                        local index=$((num-1))
                        local id names
                        IFS=$'\t' read -r id names _ _ <<< "${containers[$index]}"

                        case "$sub_choice" in
                            1) run_podman_command start "$id" && log "GREEN" "容器 ${names} 已启动。";;
                            2) run_podman_command stop "$id" && log "GREEN" "容器 ${names} 已停止。";;
                            3) run_podman_command restart "$id" && log "GREEN" "容器 ${names} 已重启。";;
                            4) clear; log "CYAN" "查看容器 ${names} 日志 (按 Ctrl+C 退出)..."; podman logs -f "$id" || true;;
                            5) clear; log "CYAN" "正进入容器 ${names} (输入 'exit' 退出)..."; if ! podman exec -it "$id" /bin/bash 2>/dev/null; then podman exec -it "$id" /bin/sh; fi;;
                            6) clear; log "CYAN" "容器 ${names} (${id:0:12}) 详细信息:"; if command -v jq &> /dev/null; then podman inspect "$id" | jq; else podman inspect "$id"; fi;;
                            7) 
                                if confirm "警告：此操作将永久删除容器 ${names} 及其所有数据！确定吗？"; then
                                    
                                    local service_name="container-${names}.service"
                                    local service_file="/etc/systemd/system/${service_name}"
                                    
                                    log "YELLOW" "正在检查并彻底清理相关的开机自启服务..."
                                    systemctl disable --now "${service_name}" >/dev/null 2>&1 || true
                                    if [ -f "$service_file" ]; then
                                        log "YELLOW" "正在删除服务文件 ${service_file}..."
                                        rm -f "${service_file}"
                                        systemctl daemon-reload >/dev/null 2>&1
                                    fi
                                    
                                    log "YELLOW" "服务清理完成，正在删除容器 '${names}'..."
                                    if run_podman_command rm -f "$id"; then
                                        log "GREEN" "容器 '${names}' 及相关服务已成功删除。"
                                    else
                                        log "RED" "删除容器 '${names}' 失败，请手动检查。"
                                    fi
                                fi
                                ;;
                            8) 
                                local service_name="container-${names}.service"
                                if systemctl is-enabled "${service_name}" &>/dev/null; then
                                    log "GREEN" "容器 '${names}' 的开机自启已经启用，无需操作。"
                                else
                                    if confirm "要为容器 '${names}' 启用开机自启吗？"; then
                                        manage_systemd_service "$names" "enable"
                                    fi
                                fi
                                ;;
                        esac
                    else
                        log "RED" "无效的编号。"
                    fi
                fi
                press_any_key_to_continue
                ;;
            *) log "RED" "无效输入。"; press_any_key_to_continue ;;
        esac
    done
}

# ==============================================================================
#  2. 镜像管理 (Image Management)
# ==============================================================================
image_menu() {
    while true; do
        clear
        log "CYAN" "--- 2. 镜像管理 ---"
        
        local images=()
        mapfile -t images < <(podman images --format "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}" --no-trunc)

        printf "  %-4s %-15s %-40s %-20s %s\n" "编号" "IMAGE ID" "REPOSITORY" "TAG" "SIZE"
        echo "----------------------------------------------------------------------------------------------------"
        if [ ${#images[@]} -eq 0 ]; then
            log "YELLOW" "  没有找到任何镜像。"
        else
            for i in "${!images[@]}"; do
                IFS=$'\t' read -r id repo tag size <<< "${images[$i]}"
                printf "  [%-2d] %-15.12s %-40s %-20s %s\n" "$((i+1))" "$id" "$repo" "$tag" "$size"
            done
        fi
        echo "----------------------------------------------------------------------------------------------------"

        log "YELLOW" "\n请选择操作:"
        echo "  [1] 查看详情    [2] 删除镜像    [3] 清理空悬镜像"
        echo "  [0] 返回主菜单"
        read -r -p "输入选项: " sub_choice

        case "$sub_choice" in
            0) return ;;
            1|2) # Inspect and Delete
                if [ ${#images[@]} -eq 0 ]; then log "YELLOW" "没有可操作的镜像。"; else
                    local num
                    read -r -p "请输入要操作的镜像编号: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#images[@]}" ]; then
                        local index=$((num-1))
                        local id repo tag
                        IFS=$'\t' read -r id repo tag _ <<< "${images[$index]}"
                        if [ "$sub_choice" -eq 1 ]; then
                            clear; log "CYAN" "镜像 ${repo}:${tag} (${id:0:12}) 详细信息:";
                            if command -v jq &> /dev/null; then podman inspect "$id" | jq; else podman inspect "$id"; fi
                        else
                            if confirm "确定要强制删除镜像 ${repo}:${tag} (${id:0:12}) 吗？"; then
                                run_podman_command rmi -f "$id" && log "GREEN" "镜像 ${id:0:12} 已删除。"
                            fi
                        fi
                    else
                        log "RED" "无效的编号。"
                    fi
                fi
                press_any_key_to_continue
                ;;
            3) # Prune
                if confirm "确定要删除所有未被使用的和空悬(dangling)的镜像吗？"; then
                    run_podman_command image prune -af && log "GREEN" "镜像清理完成。"
                fi
                press_any_key_to_continue
               ;;
            *) log "RED" "无效输入。"; press_any_key_to_continue ;;
        esac
    done
}

# ==============================================================================
#  3. 网络管理 (Network Management)
# ==============================================================================
network_menu() {
    while true; do
        clear
        log "CYAN" "--- 3. 网络管理 ---"
        local networks=()
        mapfile -t networks < <(podman network ls --format "{{.ID}}\t{{.Name}}\t{{.Driver}}")

        printf "  %-4s %-15s %-25s %s\n" "编号" "NETWORK ID" "NAME" "DRIVER"
        echo "--------------------------------------------------------------------------------"
        if [ ${#networks[@]} -eq 0 ]; then
            log "YELLOW" "  没有找到任何网络。"
        else
            for i in "${!networks[@]}"; do
                IFS=$'\t' read -r id name driver <<< "${networks[$i]}"
                printf "  [%-2d] %-15.12s %-25s %s\n" "$((i+1))" "$id" "$name" "$driver"
            done
        fi
        echo "--------------------------------------------------------------------------------"

        log "YELLOW" "\n请选择操作:"
        echo "  [1] 查看详情    [2] 删除网络    [3] 创建网络    [4] 清理未使用"
        echo "  [0] 返回主菜单"
        read -r -p "输入选项: " sub_choice

        case "$sub_choice" in
            0) return ;;
            1|2) # Inspect and Delete
                if [ ${#networks[@]} -eq 0 ]; then log "YELLOW" "没有可操作的网络。"; else
                    local num
                    read -r -p "请输入要操作的网络编号: " num
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#networks[@]}" ]; then
                        local index=$((num-1))
                        local name
                        IFS=$'\t' read -r _ name _ <<< "${networks[$index]}"
                        if [ "$sub_choice" -eq 1 ]; then
                            clear; log "CYAN" "网络 ${name} 详细信息:";
                            if command -v jq &> /dev/null; then podman network inspect "$name" | jq; else podman network inspect "$name"; fi
                        else
                            if confirm "确定要删除网络 ${name} 吗？"; then
                                run_podman_command network rm "$name" && log "GREEN" "网络 ${name} 已删除。"
                            fi
                        fi
                    else
                        log "RED" "无效的编号。"
                    fi
                fi
                press_any_key_to_continue
                ;;
            3) # Create
                local network_name network_driver
                log "CYAN" "\n--- 创建新网络 ---"
                read -r -p "请输入新网络的名称: " network_name
                if [ -z "$network_name" ]; then
                    log "RED" "网络名称不能为空。"
                else
                    read -r -p "请输入驱动 (默认为 bridge): " network_driver
                    network_driver=${network_driver:-bridge}
                    log "YELLOW" "正在创建网络: 名称=${network_name}, 驱动=${network_driver} ..."
                    run_podman_command network create --driver "${network_driver}" "${network_name}"
                fi
                press_any_key_to_continue
                ;;
            4) # Prune
                if confirm "确定要删除所有未被容器使用的网络吗？"; then
                    run_podman_command network prune -f && log "GREEN" "网络清理完成。"
                fi
                press_any_key_to_continue
                ;;
            *) log "RED" "无效输入。"; press_any_key_to_continue ;;
        esac
    done
}

# ==============================================================================
#  4. Compose 项目管理 (Compose Project Management)
# ==============================================================================

_manage_compose_autostart() {
    local project_name="$1"
    local project_dir="${COMPOSE_BASE_DIR}/${project_name}"
    
    local container_names=()
    mapfile -t container_names < <(cd "$project_dir" && podman-compose ps -q | xargs -r podman inspect --format '{{.Name}}' | sed 's|^/||')
    
    if [ ${#container_names[@]} -eq 0 ]; then
        log "YELLOW" "项目 '${project_name}' 中没有找到可操作的容器。"
        return
    fi
    
    log "CYAN" "将为项目 '${project_name}' 下的以下容器设置开机自启:"
    for container_name in "${container_names[@]}"; do
        echo " - $container_name"
    done

    if confirm "您确定要为以上所有容器启用开机自启吗?"; then
        for container_name in "${container_names[@]}"; do
            manage_systemd_service "$container_name" "enable"
            # shellcheck disable=SC2181
            if [ $? -ne 0 ]; then
                log "RED" "在为 ${container_name} 启用自启时发生错误，操作中止。"
                return 1
            fi
        done
        log "GREEN" "项目 '${project_name}' 的所有容器均已启用开机自启。"
    fi
}

_add_compose_project() {
    log "CYAN" "--- 添加新的 Compose 项目 ---"
    read -r -p "请输入新项目的名称 (例如: my-app): " project_name
    [[ -z "$project_name" ]] && { log "RED" "项目名不能为空。"; return; }

    local project_dir="${COMPOSE_BASE_DIR}/${project_name}"
    local compose_file="${project_dir}/${COMPOSE_FILE_NAME}"
    [[ -d "$project_dir" ]] && { log "RED" "目录 '${project_dir}' 已存在。"; return; }

    log "GREEN" "> 创建项目目录: ${project_dir}"
    mkdir -p "$project_dir"
    log "YELLOW" "请将您的 '${COMPOSE_FILE_NAME}' 内容粘贴到下方。按 Ctrl+D 保存。"
    echo -e "${C_CYAN}--- 开始粘贴 ---${C_RESET}"
    cat > "$compose_file"
    echo -e "${C_CYAN}--- 粘贴结束 ---${C_RESET}"

    if [[ ! -s "$compose_file" ]]; then
        log "RED" "配置文件为空，操作已取消。"
        rm -rf "$project_dir"; return
    fi

    log "GREEN" "配置文件已保存。内容预览:"
    log "GRAY" "--------------------------------------"
    cat "$compose_file"
    log "GRAY" "--------------------------------------"
    
    if confirm "内容确认无误，是否立即启动 (up -d)?"; then
        log "CYAN" "在 '${project_dir}' 中执行 'podman-compose up -d'..."
        if (cd "$project_dir" && podman-compose up -d); then
            log "GREEN" "项目 '$project_name' 已成功启动！"
            _manage_compose_autostart "$project_name"
        else
            log "RED" "项目启动失败。"
        fi
    else
        log "YELLOW" "项目已创建但未启动。"
    fi
}

_manage_single_compose_project() {
    local project_name="$1"
    local project_dir="${COMPOSE_BASE_DIR}/${project_name}"
    
    while true; do
        clear
        log "CYAN" "--- 管理 Compose 项目: ${project_name} ---"
        log "YELLOW" "项目路径: ${project_dir}"
        echo; log "GRAY" "--- 项目状态 (podman-compose ps) ---"
        (cd "$project_dir" && podman-compose ps)
        log "GRAY" "------------------------------------"
        
        log "YELLOW" "\n请选择操作:"
        echo "  [1] 启动/更新    [2] 停止并移除    [3] 查看日志    [4] 重启"
        echo "  [5] 设置开机自启"
        echo "  [0] 返回项目列表"
        read -r -p "输入选项: " sub_choice
        
        case "$sub_choice" in
            0) return ;;
            1) (cd "$project_dir" && podman-compose up -d);;
            2) if confirm "要同时移除关联的匿名卷吗 (down -v)?"; then
                   (cd "$project_dir" && podman-compose down -v --timeout 0)
               else
                   (cd "$project_dir" && podman-compose down --timeout 0)
               fi;;
            3) clear; log "CYAN" "查看项目日志 (Ctrl+C 退出)..."; (cd "$project_dir" && podman-compose logs -f || true);;
            4) (cd "$project_dir" && podman-compose restart);;
            5) _manage_compose_autostart "$project_name";;
            *) log "RED" "无效输入。";;
        esac
        press_any_key_to_continue
    done
}

compose_menu() {
    while true; do
        clear
        log "CYAN" "--- 4. Compose 项目管理 ---"
        log "YELLOW" "项目根目录: ${COMPOSE_BASE_DIR}"
        echo
        
        local projects=()
        if [ -d "$COMPOSE_BASE_DIR" ]; then
            while IFS= read -r -d '' dir; do
                if [ -f "${dir}/${COMPOSE_FILE_NAME}" ]; then
                    projects+=("$(basename "$dir")")
                fi
            done < <(find "$COMPOSE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
        fi
        
        log "YELLOW" "选择要管理的项目，或选择一项操作:"
        if [[ ${#projects[@]} -gt 0 ]]; then
            for i in "${!projects[@]}"; do
                printf "  [%-2d] %s\n" "$((i+1))" "${projects[$i]}"
            done
        fi
        
        echo "----------------------------------------"
        # 动态计算菜单项编号
        local add_option_num=$(( ${#projects[@]} + 1 ))
        local del_option_num=$(( ${#projects[@]} + 2 ))
        echo "  [${add_option_num}] 添加新项目"
        echo "  [${del_option_num}] 删除项目"
        echo "  [0] 返回主菜单"
        read -r -p "输入选项或编号: " choice
       
        # 输入验证和分发
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log "RED" "无效输入。"; press_any_key_to_continue; continue
        fi

        if [[ "$choice" -eq 0 ]]; then
            return
        elif [[ "$choice" -ge 1 && "$choice" -le ${#projects[@]} ]]; then
            _manage_single_compose_project "${projects[$((choice-1))]}"
        elif [[ "$choice" -eq "$add_option_num" ]]; then
            _add_compose_project; press_any_key_to_continue
        elif [[ "$choice" -eq "$del_option_num" ]]; then
            if [[ ${#projects[@]} -eq 0 ]]; then log "YELLOW" "没有可删除的项目。"; else
                local num
                read -r -p "请输入要删除的项目编号 (1-${#projects[@]}): " num
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#projects[@]}" ]; then
                    local proj_to_del="${projects[$((num-1))]}"
                    local proj_dir="${COMPOSE_BASE_DIR}/${proj_to_del}"
                    if confirm "将要删除项目 '${proj_to_del}' 及其目录，此操作不可逆！确定吗？"; then
                       log "CYAN" "正在停止并清理项目 '${proj_to_del}'..."
                       (cd "$proj_dir" && podman-compose down -v --timeout 0) &>/dev/null || true
                       log "CYAN" "正在删除目录 '$proj_dir'..."
                       rm -rf "$proj_dir"
                       log "GREEN" "项目 '${proj_to_del}' 已被彻底删除。"
                    fi
                else
                    log "RED" "无效的编号。"
                fi
            fi
            press_any_key_to_continue
        else
            log "RED" "无效输入。"; press_any_key_to_continue
        fi
    done
}

# ==============================================================================
#  辅助函数: 从 Podman 命令中解析并创建宿主机目录 (模拟 Docker 行为)
# ==============================================================================
create_host_dirs_from_command() {
    local command_string="$1"
    local host_paths
    host_paths=$(echo "$command_string" | grep -oP '(-v|--volume)\s+\K([^\s:]+|"[^"]+"|'\''[^'\'']+'\'' )' | cut -d: -f1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

    if [[ -z "$host_paths" ]]; then
        return 0 # 没有找到卷映射，正常返回
    fi

    log "CYAN" "检测到卷映射，正在检查宿主机目录是否存在..."

    local status=0
    while IFS= read -r host_path; do
        if [[ -z "$host_path" ]]; then
            continue
        fi

        # 只处理绝对路径
        if [[ "$host_path" == /* ]]; then
            # 检查路径是否存在，并且不是一个已存在的文件
            if [ -e "$host_path" ] && [ ! -d "$host_path" ]; then
                log "RED" "错误: 路径 '$host_path' 已存在但不是一个目录。无法创建。"
                status=1
                break
            fi

            if [ ! -d "$host_path" ]; then
                log "YELLOW" "目录 '$host_path' 不存在。正在自动创建..."
                if mkdir -p "$host_path"; then
                    log "GREEN" "目录 '$host_path' 创建成功。"
                else
                    log "RED" "错误: 无法创建目录 '$host_path'！请检查权限。"
                    status=1
                    break
                fi
            fi
        else
            log "YELLOW" "警告: 忽略相对路径或命名卷 '$host_path'。脚本只处理绝对路径绑定。"
        fi
    done <<< "$host_paths"
    return "$status"
}


# ==============================================================================
#  5. 直接运行 Podman 命令（自动创建映射目录）
# ==============================================================================
add_run_container() {
    log "CYAN" "--- 5. 通过 'run' 命令添加新容器 ---"
    log "YELLOW" "请将您完整的 'podman run' 命令粘贴到下方，按 Ctrl+D 结束输入。"
    log "GREEN" "注意如需容器自动更新，添加更新标签参数，镜像名字添加仓库地址以及latest版本，以及启用开启自启动，再从主脚本菜单启用自动更新即可。"
    echo -e "${C_CYAN}--- 开始粘贴 ---${C_RESET}"
    local run_command
    run_command=$(cat)
    echo -e "${C_CYAN}--- 粘贴结束 ---${C_RESET}"

    if [[ -z "$(echo -n "$run_command" | tr -d '[:space:]')" ]]; then
        log "RED" "命令为空，操作已取消。"; return
    fi
    
    local single_line_command
    single_line_command=$(echo -n "$run_command" | tr -s '[:space:]' ' ')

    log "CYAN" "将要执行以下命令"
    log "YELLOW" "$single_line_command"
    if confirm "确认执行吗？"; then
        if ! create_host_dirs_from_command "$single_line_command"; then
            log "RED" "由于目录准备失败，Podman 命令已中止。"
            return 1
        fi

        log "CYAN" "所有宿主机目录已就绪，正在执行 Podman 命令..."
        if eval "$run_command"; then
            log "GREEN" "命令执行成功！"
            log "CYAN" "正在将命令记录到 ${RUN_HISTORY_FILE} 文件中..."
            {
                echo "======================================================================"
                echo "执行时间: $(date '+%Y-%m-%d %H:%M:%S')"
                echo "执行的原始命令:"
                echo "${run_command}"
                echo "======================================================================"
                echo ""
            } >> "$RUN_HISTORY_FILE"

            local container_name
            container_name=$(echo "$single_line_command" | grep -oP '(--name\s*=?\s*)\K[^\s]+' | head -n 1)
            
            if [ -n "$container_name" ]; then
                if confirm "是否为新容器 '${container_name}' 启用开机自启动?"; then
                    manage_systemd_service "$container_name" "enable"
                fi
            else
                log "YELLOW" "警告: 未在命令中找到 '--name' 参数，无法自动设置开机自启。"
                log "YELLOW" "您可以在 '容器管理' 菜单中手动为该容器启用自启。"
            fi
        else
            log "RED" "命令执行失败，请检查上面的错误信息。"
        fi
    else
        log "YELLOW" "操作已取消。"
    fi
}

# ==============================================================================
#  6. 清理系统 (Prune System)
# ==============================================================================
prune_system() {
    log "CYAN" "--- 6. 清理系统 ---"
    log "YELLOW" "此操作将删除所有未使用的容器、网络和空悬镜像。"
    if confirm "这是一个安全的清理操作，您确定要执行吗？"; then
      run_podman_command system prune -f
      log "GREEN" "系统清理完成！"
    else
      log "YELLOW" "操作已取消。"
    fi
}

# ==============================================================================
#  7. 管理全局自动更新服务
# ==============================================================================
manage_global_autoupdate_menu() {
    if ! check_root; then return 1; fi
    
    while true; do
        clear
        log "CYAN" "--- 7. 管理全局自动更新服务 ---"
        log "YELLOW" "此服务会定时检查所有带\"更新标签\"的容器，并自动拉取新镜像、重建容器。"
        
        local timer_status_active timer_status_enabled status_color
        if systemctl is-active --quiet podman-auto-update.timer; then
            timer_status_active="活动 (Active)"
            status_color="$C_GREEN"
        else
            timer_status_active="非活动 (Inactive)"
            status_color="$C_RED"
        fi
        
        if systemctl is-enabled --quiet podman-auto-update.timer 2>/dev/null; then
            timer_status_enabled="已启用 (Enabled)"
        else
            timer_status_enabled="已禁用 (Disabled)"
        fi
        
        echo -e "\n当前状态: ${status_color}${timer_status_active}${C_RESET} | ${timer_status_enabled}"

        log "YELLOW" "\n请选择操作:"
        echo "  [1] 启用并立即启动"
        echo "  [2] 禁用并立即停止"
        echo "  [3] 查看最近一次更新记录"
        echo "  [4] 手动立即触发一次更新"
        echo "  [0] 返回主菜单"
        read -r -p "输入选项: " choice

        case "$choice" in
            1)
                log "YELLOW" "正在启用并启动 'podman-auto-update.timer'..."
                systemctl enable --now podman-auto-update.timer
                log "GREEN" "服务已启用并启动！"
                press_any_key_to_continue
                ;;
            2)
                log "YELLOW" "正在禁用并停止 'podman-auto-update.timer'..."
                systemctl disable --now podman-auto-update.timer
                log "GREEN" "服务已禁用并停止。"
                press_any_key_to_continue
                ;;
            3)
                clear
                log "CYAN" "--- 最近一次 Podman Auto-Update 执行记录 ---"
                journalctl -u podman-auto-update.service -n 50 --no-pager
                press_any_key_to_continue
                ;;
            4)
                clear
                log "CYAN" "--- 手动触发 Podman Auto-Update ---"
                local labeled_containers
                labeled_containers=$(podman ps -a --filter "label=io.containers.autoupdate" --format "{{.ID}}")
                if [[ -z "$labeled_containers" ]]; then
                    log "YELLOW" "未检测到任何配置了 \"io.containers.autoupdate=registry\" 标签的容器。"
                else
                    log "CYAN" "检测到已配置更新标签的容器，正在执行更新..."
                    podman auto-update
                    log "GREEN" "手动更新已完成（可通过 [3] 查看日志）。"
                fi
                press_any_key_to_continue
                ;;
            0)
                return
                ;;
            *)
                log "RED" "无效输入。"
                press_any_key_to_continue
                ;;
        esac
    done
}

# ==============================================================================
#  主菜单与执行逻辑 (Main Menu & Logic)
# ==============================================================================
show_main_menu() {
    clear
    local running_containers total_images total_networks
    running_containers=$(podman ps --format "{{.ID}}" | wc -l)
    total_images=$(podman images --format "{{.ID}}" | wc -l)
    total_networks=$(podman network ls --format "{{.ID}}" | wc -l)

    log "CYAN"   "========================================================"
    log "CYAN"   "               Podman 管理面板"
    log "YELLOW" "   状态 | 运行中容器: ${running_containers} | 镜像: ${total_images} | 网络: ${total_networks}"
    log "CYAN"   "========================================================"
    log "GREEN"  " [1] 容器管理 (查看/启停/日志/终端)"
    log "GREEN"  " [2] 镜像管理 (查看/删除/清理)"
    log "GREEN"  " [3] 网络管理 (查看/删除/清理)"
    log "GREEN"  " [4] Compose 项目管理 (创建/管理/删除)"
    log "CYAN"   " ------------------------------------------------------"
    log "GREEN"  " [5] 直接运行 'podman run' 命令"
    log "YELLOW" " [6] 一键清理系统 (Prune System)"
    log "CYAN"   " [7] 管理全局自动更新服务"
    log "CYAN"   " ------------------------------------------------------"
    log "RED"    " [0] 退出脚本"
    log "CYAN"   "========================================================"
    read -r -p "请输入您的选择: " main_choice
}

main() {
    check_dependencies
    mkdir -p "$COMPOSE_BASE_DIR"

    while true; do
        show_main_menu
        case "$main_choice" in
            1) container_menu ;;
            2) image_menu ;;
            3) network_menu ;;
            4) compose_menu ;;
            5) add_run_container; press_any_key_to_continue ;;
            6) prune_system; press_any_key_to_continue ;;
            7) manage_global_autoupdate_menu ;;
            0) log "CYAN" "感谢使用，再见！"; exit 0 ;;
            *) log "RED" "无效的输入，请重新选择。"; press_any_key_to_continue ;;
        esac
    done
}

# --- 脚本入口 ---
trap 'echo -e "${C_RESET}"; log "YELLOW" "\n操作已中断。"; exit 130' INT TERM

# 执行主函数
main "$@"
