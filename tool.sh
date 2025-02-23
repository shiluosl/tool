#!/bin/bash
# 本地端口转发管理器完整版 v4.0

# ---------------------- 配置部分 ----------------------
CONFIG_FILE="/etc/local_forward.rules"
LOG_FILE="/var/log/lpfm.log"
declare -A COLORS=(
    [reset]="\033[0m"
    [red]="\033[38;5;196m"
    [yellow]="\033[38;5;226m"
    [blue]="\033[38;5;39m"
    [cyan]="\033[38;5;51m"
    [green]="\033[38;5;46m"
    [purple]="\033[38;5;129m"
)
LINE_TOP="▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
LINE_BOT="▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁"

# ---------------------- 日志记录 ----------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ---------------------- 界面函数 ----------------------
print_header() {
    clear
    echo -e "${COLORS[blue]}${LINE_TOP}"
    printf "%35s\n" "Local Port Forward Manager v4.0"
    echo -e "${LINE_TOP}${COLORS[reset]}\n"
}

print_footer() {
    echo -e "\n${COLORS[blue]}${LINE_BOT}${COLORS[reset]}\n"
}

show_spinner() {
    local pid=$!
    local spin='⣾⣽⣻⢿⡿⣟⣯⣷'
    while kill -0 $pid 2>/dev/null; do
        for i in {0..7}; do
            echo -ne "${COLORS[yellow]}${spin:$i:1} 处理中...${COLORS[reset]}\r"
            sleep 0.1
        done
    done
    echo -ne "            \r"
}

# ---------------------- 核心功能 ----------------------
validate_input() {
    case $1 in
        proto)
            [[ "$2" =~ ^(tcp|udp)$ ]] || error "协议必须是 tcp 或 udp" 2
            ;;
        port)
            if [[ "$2" =~ ^[0-9]+-[0-9]+$ ]]; then
                local start=${2%-*} end=${2#*-}
                (( start >= 1 && end <= 65535 && start < end )) || 
                    error "端口范围 1-65535 且起始端口小于结束端口" 3
            elif [[ "$2" =~ ^[0-9]+$ ]]; then
                (( $2 >= 1 && $2 <= 65535 )) || error "端口号 1-65535" 4
            else
                error "端口格式错误" 5
            fi
            ;;
    esac
}

add_rule() {
    print_header
    echo -e "${COLORS[purple]}▶ 添加本地转发规则${COLORS[reset]}"

    # 协议选择
    read -p "协议类型 (tcp/udp) [默认 udp]: " proto
    proto=${proto:-udp}
    validate_input proto "$proto"

    # 源端口
    while : ; do
        read -p "输入外部访问端口/范围: " src_port
        validate_input port "$src_port" && break
    done
    
    #IP处理逻辑
    default_ip="127.0.0.1"
    while : ; do
        read -p "目标服务地址 [默认按回车使用本机]: " dest_ip
        dest_ip=${dest_ip:-$default_ip}
        
        # IP格式验证
        if [[ "$dest_ip" == "$default_ip" ]]; then
            echo -e "${COLORS[cyan]}› 使用本机地址 ${COLORS[green]}${default_ip}${COLORS[reset]}"
            break
        elif [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo -e "${COLORS[yellow]}⚠ 无效IP格式，请重新输入${COLORS[reset]}"
        fi
    done

    # 目标端口
    while : ; do
        read -p "输入本地服务端口: " dest_port
        validate_input port "$dest_port" && break
    done

    # 接口选择
    echo -e "\n${COLORS[cyan]}可用网络接口:${COLORS[reset]}"
    ip -o link show | awk -F': ' '!/lo/ {print $2}'
    read -p "选择网络接口 [默认 eth0]: " interface
    interface=${interface:-eth0}

    # 规则哈希生成
    local fw_hash=$(echo -n "$proto$src_port$dest_port$interface" | sha256sum | cut -c1-8)

    # 查重验证
    if grep -q "$fw_hash" "$CONFIG_FILE"; then
        error "相同规则已存在: ${COLORS[yellow]}$fw_hash${COLORS[reset]}" 6
    fi

    # 写入规则存储
    echo "${fw_hash}|${proto}|${src_port}|${dest_ip}|${dest_port}|${interface}" >> "$CONFIG_FILE"

    # 应用iptables规则
    if ! iptables -t nat -A PREROUTING \
        -i "$interface" -p "$proto" \
        --match multiport --dports "$src_port" \
        -j DNAT --to-destination "${dest_ip}:${dest_port}" \
        -m comment --comment "LPFM-${fw_hash}" 2>> "$LOG_FILE"
    then
        sed -i "/${fw_hash}/d" "$CONFIG_FILE"
        error "规则创建失败" 7
    fi

    log "新规则添加: ${proto} ${interface}:${src_port} → ${dest_ip}:${dest_port}"
    persist_rules & show_spinner
}

delete_rule() {
    print_header
    echo -e "${COLORS[purple]}▶ 删除转发规则${COLORS[reset]}"
    
    [[ ! -s "$CONFIG_FILE" ]] && error "没有可删除的规则"

    # 加载规则列表
    declare -a rules
    mapfile -t rules < "$CONFIG_FILE"
    
    # 显示规则列表
    echo -e "\n${COLORS[cyan]}已配置规则列表：${COLORS[reset]}"
    local index=1
    for rule in "${rules[@]}"; do
        IFS='|' read -r hash proto src dest_ip dest_port iface <<< "$rule"
        printf "%2d. %-4s %-15s → %-15s\n" \
               $index "$proto" "${iface}:${src}" "${dest_port}"
        ((index++))
    done

    # 选择要删除的规则
    while : ; do
        read -p "选择要删除的规则编号 (1-$((index-1))): " choice
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >=1 && choice < index )) && break
        echo -e "${COLORS[yellow]}请输入有效编号${COLORS[reset]}"
    done

    local target_rule="${rules[$((choice-1))]}"
    IFS='|' read -r target_hash proto src_port dest_ip dest_port interface <<< "$target_rule"
    
    # 删除iptables规则
    while IFS= read -r line; do
        iptables -t nat -D PREROUTING "${line%% *}" 2>> "$LOG_FILE"
    done < <(iptables -t nat -L PREROUTING --line-numbers -n | \
             awk -v hash="$target_hash" '/LPFM-/ && $0 ~ hash {print $1}' | \
             sort -nr)

    # 删除配置记录
    sed -i "/${target_hash}/d" "$CONFIG_FILE"
    
    log "规则删除: ${target_hash}"
    persist_rules & show_spinner
}

show_rules() {
    print_header
    echo -e "${COLORS[cyan]}活动转发规则：${COLORS[reset]}"
    
    iptables -t nat -L PREROUTING -n --line-numbers | awk '
        BEGIN {
            printf "%-4s %-5s %-18s %-15s %-8s\n",
                   "编号", "协议", "外部访问", "目标服务", "接口"
        }
        /LPFM-/ {
            gsub("dpt:|->", " ")
            printf "%-4s %-5s %-18s %-15s %-8s\n", 
                $1, $6, $7, $11, $5
        }' | while read -r line; do
        echo -e "  ${COLORS[yellow]}›${COLORS[reset]} $line"
    done
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

persist_rules() {
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    else
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
}

backup_config() {
    local backup_file="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup_file" 2>/dev/null
    echo -e "\n${COLORS[green]}✓ 配置已备份到: ${COLORS[cyan]}${backup_file}${COLORS[reset]}"
    sleep 1
}

flush_rules() {
    print_header
    echo -e "${COLORS[red]}⚠ 危险操作警告 ⚠${COLORS[reset]}"
    read -p "确实要清空所有转发规则？(y/N): " confirm
    
    if [[ "${confirm,,}" == "y" ]]; then
        # 清除所有规则
        while IFS= read -r line; do
            iptables -t nat -D PREROUTING "${line%% *}" 2>> "$LOG_FILE"
        done < <(iptables -t nat -L PREROUTING --line-numbers -n | awk '/LPFM-/ {print $1}' | sort -nr)

        # 清空配置文件
        > "$CONFIG_FILE"
        persist_rules
        
        echo -e "\n${COLORS[red]}所有规则已清除！${COLORS[reset]}"
        log "用户执行了清空规则操作"
        sleep 2
    fi
}

# ---------------------- 初始化检查 ----------------------
init_check() {
    [[ $EUID -ne 0 ]] && error "需要 ROOT 权限执行"
    [[ ! -x /sbin/iptables ]] && error "需要安装 iptables"
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    touch "$CONFIG_FILE" || error "无法创建规则文件"
    touch "$LOG_FILE" || error "无法创建日志文件"
}

error() {
    echo -e "${COLORS[red]}错误: $1${COLORS[reset]}" | tee -a "$LOG_FILE"
    exit ${2:-1}
}

# ---------------------- 主菜单 ----------------------
main_menu() {
    while true; do
        print_header
        echo -e "${COLORS[green]}功能菜单："
        echo
        echo "1. 创建新转发规则"
        echo "2. 删除现有规则"
        echo "3. 查看活动规则"
        echo "4. 备份当前配置"
        echo "5. 清空所有规则"
        echo
        echo -e "0. 退出系统${COLORS[reset]}"
        print_footer

        read -p "请输入操作编号: " choice
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) backup_config ;;
            5) flush_rules ;;
            0) 
                echo -e "\n${COLORS[blue]}✧ 感谢使用本地端口转发管理器 ✧${COLORS[reset]}"
                exit 0 
                ;;
            *) 
                echo -e "${COLORS[yellow]}无效操作编号，请重新输入${COLORS[reset]}"
                sleep 1
                ;;
        esac
    done
}

# ---------------------- 启动程序 ----------------------
init_check
main_menu
