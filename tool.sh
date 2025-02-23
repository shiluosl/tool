#!/bin/bash
# 智能端口转发管理器 v3.2
# 完整功能正式版

# ---------------------- 初始化配置 ----------------------
CONFIG_FILE="/etc/port_forward.rules"
LOG_FILE="/var/log/pfm.log"
declare -A COLORS=(
    [reset]="\033[0m"
    [red]="\033[38;5;196m"
    [yellow]="\033[38;5;226m"
    [blue]="\033[38;5;39m"
    [cyan]="\033[38;5;51m"
    [purple]="\033[38;5;129m"
)
LINE_TOP="▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
LINE_BOT="▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁"

# ---------------------- 通用函数 ----------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${COLORS[red]}错误: $1${COLORS[reset]}" | tee -a "$LOG_FILE"
    exit ${2:-1}
}

print_header() {
    clear
    echo -e "${COLORS[blue]}${LINE_TOP}"
    printf "%34s\n" "端口转发管理器 v3.2"
    echo -e "${LINE_TOP}${COLORS[reset]}\n"
}

print_footer() {
    echo -e "\n${COLORS[blue]}${LINE_BOT}${COLORS[reset]}\n"
}

# ---------------------- 网络函数 ----------------------
get_default_ip() {
    local interface="eth0"
    local ip_address
    
    # 检测主网络接口
    local main_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}')
    [[ -n "$main_iface" ]] && interface="$main_iface"

    # 多方法获取IPv4地址
    ip_address=$(
        ip -4 addr show "$interface" 2>/dev/null |
        grep -oP '(?<=inet\s)\d+(\.\d+){3}' ||
        hostname -I 2>/dev/null | awk '{print $1}' ||
        echo "127.0.0.1"
    )

    echo "${ip_address:-127.0.0.1}"
}

get_default_interface() {
    local default_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}')
    echo "${default_iface:-eth0}"
}

# ---------------------- 核心功能 ----------------------
gen_hash() {
    echo -n "$1$2$3$4$5" | sha256sum | awk '{print substr($1,1,8)}'
}

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
        ip)
            if [[ ! "$2" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                error "IP地址格式错误" 6
            fi
            IFS='.' read -ra octets <<< "$2"
            for octet in "${octets[@]}"; do
                (( octet <= 255 )) || error "IP地址无效" 7
            done
            ;;
    esac
}

add_rule() {
    print_header
    echo -e "${COLORS[purple]}▶ 添加转发规则${COLORS[reset]}"

    # 协议类型（默认udp）
    read -p "协议类型 (tcp/udp) [默认udp]: " proto
    proto=${proto:-udp}
    validate_input proto "$proto"

    # 源端口
    while : ; do
        read -p "源端口或范围 (如 80-443): " src_port
        [[ -n "$src_port" ]] && validate_input port "$src_port" && break
        echo -e "${COLORS[yellow]}必须输入源端口${COLORS[reset]}"
    done

    # 目标IP（本机IP）
    default_ip=$(get_default_ip)
    read -p "目标IP [默认$default_ip]: " dest_ip
    dest_ip=${dest_ip:-$default_ip}
    validate_input ip "$dest_ip"

    # 目标端口
    while : ; do
        read -p "目标端口: " dest_port
        validate_input port "$dest_port" && break
    done

    # 网络接口
    default_iface=$(get_default_interface)
    read -p "网络接口 [默认$default_iface]: " interface
    interface=${interface:-$default_iface}

    # 生成唯一哈希
    local fw_hash=$(gen_hash "$proto" "$src_port" "$dest_ip" "$dest_port" "$interface")

    # 查重验证
    if grep -q "$fw_hash" "$CONFIG_FILE"; then
        error "规则已存在: ${COLORS[yellow]}$fw_hash${COLORS[reset]}" 8
    fi

    # 写入配置
    echo "${fw_hash}|${proto}|${src_port}|${dest_ip}|${dest_port}|${interface}" >> "$CONFIG_FILE"

    # 生成iptables规则
    if ! iptables -t nat -A PREROUTING \
        -i "$interface" -p "$proto" \
        --match multiport --dports "$src_port" \
        -j DNAT --to-destination "${dest_ip}:${dest_port}" \
        -m comment --comment "PFM-${fw_hash}" 2>> "$LOG_FILE"
    then
        # 回滚配置
        sed -i "/${fw_hash}/d" "$CONFIG_FILE"
        error "规则添加失败，检查输入参数" 9
    fi

    # 清除连接跟踪
    conntrack -D -d "$dest_ip" -p "$proto" --dport "$dest_port" &>> "$LOG_FILE"

    log "规则添加成功: ${fw_hash}"
    persist_rules
    sleep 1
}

delete_rule() {
    print_header
    echo -e "${COLORS[purple]}▶ 删除转发规则${COLORS[reset]}"
    
    [[ ! -s "$CONFIG_FILE" ]] && error "没有可删除的规则"

    # 加载规则列表
    declare -a rules
    mapfile -t rules < "$CONFIG_FILE"
    
    # 显示规则列表
    echo -e "\n${COLORS[cyan]}现有规则列表：${COLORS[reset]}"
    local count=1
    for rule in "${rules[@]}"; do
        IFS='|' read -r hash proto src dest_ip dest_port iface <<< "$rule"
        printf "%2d. %-4s %-18s → %-15s:%-5s (%s)\n" \
               $count "$proto" "$src" "$dest_ip" "$dest_port" "$iface"
        ((count++))
    done

    # 选择删除
    while : ; do
        read -p "选择要删除的规则编号 (1-$((count-1))): " choice
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >=1 && choice < count )) && break
        echo -e "${COLORS[yellow]}输入有效编号${COLORS[reset]}"
    done

    local target_rule="${rules[$((choice-1))]}"
    IFS='|' read -r target_hash proto src_port dest_ip dest_port interface <<< "$target_rule"
    
    # 删除iptables规则
    while IFS= read -r line; do
        iptables -t nat -D PREROUTING "${line%% *}"
    done < <(iptables -t nat -L PREROUTING --line-numbers -n | \
             awk -v hash="$target_hash" '/PFM-/ && $0 ~ hash {print $1}' | \
             sort -nr)

    # 删除配置记录
    sed -i "/${target_hash}/d" "$CONFIG_FILE"
    
    # 清理连接跟踪
    conntrack -D -d "$dest_ip" -p "$proto" --dport "$dest_port" &>> "$LOG_FILE"
    
    log "规则删除成功: ${target_hash}"
    persist_rules
    sleep 1
}

# ---------------------- 工具函数 ----------------------
show_rules() {
    print_header
    echo -e "${COLORS[cyan]}当前生效规则：${COLORS[reset]}"
    
    iptables -t nat -L PREROUTING -n --line-numbers | awk '
        BEGIN {
            printf "%-4s %-5s %-18s %-22s %-15s %-8s\n",
                   "编号", "协议", "源端口", "目标地址", "接口", "备注"
        }
        /PFM-/ {
            gsub("dpt:", "", $7)
            printf "%-4s %-5s %-18s %-22s %-15s %-8s\n", 
                $1, $6, $7, $11"->"$12, $5, $NF
        }' | while read -r line; do
        echo -e "  ${COLORS[yellow]}›${COLORS[reset]} $line"
    done
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

backup_config() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${timestamp}"
    echo -e "\n${COLORS[cyan]}配置已备份到: ${COLORS[blue]}${CONFIG_FILE}.bak.${timestamp}${COLORS[reset]}"
    sleep 1
}

flush_rules() {
    print_header
    echo -e "${COLORS[red]}⚠ 危险操作警告 ⚠${COLORS[reset]}"
    read -p "确实要清空所有规则？(y/N): " confirm
    
    if [[ "${confirm,,}" == "y" ]]; then
        # 清除所有PFM规则
        while IFS= read -r line; do
            iptables -t nat -D PREROUTING "${line%% *}"
        done < <(iptables -t nat -L PREROUTING --line-numbers -n | \
                 awk '/PFM-/ {print $1}' | sort -nr)

        # 清空配置文件
        > "$CONFIG_FILE"
        persist_rules
        
        echo -e "\n${COLORS[red]}所有规则已清除！${COLORS[reset]}"
        log "用户执行了清空规则操作"
        sleep 2
    fi
}

persist_rules() {
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save &>> "$LOG_FILE"
    else
        iptables-save > /etc/iptables/rules.v4 2>> "$LOG_FILE"
        ip6tables-save > /etc/iptables/rules.v6 2>> "$LOG_FILE"
    fi
}

init_check() {
    [[ $EUID -ne 0 ]] && error "需要ROOT权限运行"
    [[ ! -x /sbin/iptables ]] && error "请先安装iptables"
    
    # 初始化配置文件
    mkdir -p "$(dirname "$CONFIG_FILE")"
    touch "$CONFIG_FILE" || error "无法写入配置文件"
    touch "$LOG_FILE" || error "无法创建日志文件"
}

# ---------------------- 主程序 ----------------------
main_menu() {
    while true; do
        print_header
        echo -e "${COLORS[cyan]}主菜单："
        echo
        echo "1. 添加转发规则"
        echo "2. 删除现有规则"
        echo "3. 查看生效规则"
        echo "4. 备份当前配置"
        echo "5. 清空所有规则"
        echo
        echo -e "0. 退出系统${COLORS[reset]}"
        print_footer

        read -p "请输入选项: " choice
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) backup_config ;;
            5) flush_rules ;;
            0) 
                echo -e "\n${COLORS[blue]}感谢使用，再见！${COLORS[reset]}"
                exit 0 
                ;;
            *) 
                echo -e "${COLORS[yellow]}无效选项，请重新输入${COLORS[reset]}"
                sleep 1
                ;;
        esac
    done
}

# ---------------------- 启动程序 ----------------------
init_check
main_menu
