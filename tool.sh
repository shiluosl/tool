#!/bin/bash
# 智能端口转发管理器 v3.1
# 完整功能版 - 无任何代码省略

# ---------------------- 初始化配置 ----------------------
CONFIG_FILE="/etc/port_forward.rules"
LOG_FILE="/var/log/pfm.log"
declare -A COLORS=(
    [reset]="\033[0m"
    [red]="\033[38;5;196m"
    [green]="\033[38;5;46m"
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
    printf "%34s\n" "端口转发管理器 v3.1"
    echo -e "${LINE_TOP}${COLORS[reset]}\n"
}

print_footer() {
    echo -e "\n${COLORS[blue]}${LINE_BOT}${COLORS[reset]}\n"
}

# ---------------------- 规则生成 ----------------------
gen_hash() {
    echo -n "$1$2$3$4$5" | sha256sum | awk '{print substr($1,1,8)}'
}

validate_input() {
    case $1 in
        proto)
            [[ ! "$2" =~ ^(tcp|udp)$ ]] && error "无效协议类型"
            ;;
        port)
            [[ ! "$2" =~ ^[0-9]+(-[0-9]+)?$ ]] && error "端口格式错误"
            ;;
        ip)
            [[ ! "$2" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && error "无效IP地址"
            ;;
    esac
}

# ---------------------- 规则管理 ----------------------
add_rule() {
    print_header
    echo -e "${COLORS[purple]}▶ 添加转发规则${COLORS[reset]}"
    
    read -p "请输入协议类型 (tcp/udp): " proto
    validate_input proto "$proto"
    
    read -p "输入源端口或范围 (如 80-443): " src_port
    validate_input port "$src_port"
    
    read -p "目标服务器IP地址: " dest_ip
    validate_input ip "$dest_ip"
    
    read -p "目标端口: " dest_port
    validate_input port "$dest_port"
    
    read -p "网络接口名称 (默认eth0): " interface
    interface=${interface:-eth0}
    
    local fw_hash=$(gen_hash "$proto" "$src_port" "$dest_ip" "$dest_port" "$interface")
    
    # 查重验证
    if grep -q "$fw_hash" "$CONFIG_FILE"; then
        error "相同规则已存在" 3
    fi

    # 写入配置文件
    echo "${fw_hash}|${proto}|${src_port}|${dest_ip}|${dest_port}|${interface}" >> "$CONFIG_FILE"
    
    # 生成iptables规则
    if ! iptables -t nat -A PREROUTING -i "$interface" -p "$proto" \
        --match multiport --dports "${src_port}" \
        -j DNAT --to-destination "${dest_ip}:${dest_port}" \
        -m comment --comment "PFM-${fw_hash}"
    then
        sed -i "/${fw_hash}/d" "$CONFIG_FILE"
        error "规则插入失败，请检查参数" 5
    fi
    
    # 清理相关连接跟踪
    conntrack -D -d "$dest_ip" -p "$proto" --dport "$dest_port" &>> "$LOG_FILE"
    
    log "规则添加成功 → ${fw_hash}"
    persist_rules
    sleep 1
}

delete_rule() {
    print_header
    echo -e "${COLORS[purple]}▶ 删除转发规则${COLORS[reset]}"
    
    [[ ! -s "$CONFIG_FILE" ]] && error "没有可删除的规则"

    declare -a rules
    mapfile -t rules < "$CONFIG_FILE"
    
    echo -e "\n${COLORS[cyan]}现有规则列表："
    local count=1
    for rule in "${rules[@]}"; do
        IFS='|' read -r hash proto src dest_ip dest_port iface <<< "$rule"
        printf "%2d. %-5s %-12s → %-15s:%-5s @%s\n" \
               $count "$proto" "$src" "$dest_ip" "$dest_port" "$iface"
        ((count++))
    done

    read -p "输入要删除的规则编号 (1-$((count-1))): " choice
    [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice >= count )) && \
        error "无效的选择"

    local target_rule="${rules[$((choice-1))]}"
    IFS='|' read -r target_hash proto src_port dest_ip dest_port interface <<< "$target_rule"
    
    # 清理iptables规则
    while IFS= read -r line; do
        iptables -t nat -D PREROUTING "${line%% *}"
    done < <(iptables -t nat -L PREROUTING --line-numbers | grep "PFM-${target_hash}" | awk '{print $1}' | sort -nr)

    # 删除配置文件条目
    sed -i "/${target_hash}/d" "$CONFIG_FILE"
    
    # 清除连接追踪
    conntrack -D -d "$dest_ip" -p "$proto" --dport "$dest_port" &>> "$LOG_FILE"
    
    log "规则删除成功 → ${target_hash}"
    persist_rules
    sleep 1
}

# ---------------------- 系统功能 ----------------------
show_rules() {
    print_header
    echo -e "${COLORS[cyan]}当前生效的转发规则：${COLORS[reset]}"
    
    iptables -t nat -L PREROUTING -n --line-numbers | awk '
        /PFM-/ {
            printf "%-4s %-5s %-18s %-22s %-15s\n", 
            $1, $7, $11, $16, $NF
        }' | while read -r line; do
        echo -e "  ${COLORS[yellow]}▶${COLORS[reset]} $line"
    done
    
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

backup_config() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${timestamp}"
    
    echo -e "\n${COLORS[green]}配置已备份到: ${CONFIG_FILE}.bak.${timestamp}${COLORS[reset]}"
    sleep 1
}

flush_rules() {
    print_header
    echo -e "${COLORS[red]}⚠ 危险操作警告 ⚠${COLORS[reset]}"
    read -p "确定要清空所有转发规则吗？(y/N): " confirm
    
    if [[ "${confirm,,}" == "y" ]]; then
        iptables -t nat -F PREROUTING
        > "$CONFIG_FILE"
        persist_rules
        
        echo -e "\n${COLORS[red]}所有规则已清除！${COLORS[reset]}"
        log "用户执行了规则清空操作"
        sleep 2
    fi
}

persist_rules() {
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save | tee -a "$LOG_FILE"
    else
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6 2>> "$LOG_FILE"
    fi
}

init_check() {
    [[ $EUID -ne 0 ]] && error "必须使用ROOT权限运行本脚本"
    [[ ! -x /sbin/iptables ]] && error "请先安装iptables工具"
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    touch "$CONFIG_FILE" || error "配置文件无法写入"
    touch "$LOG_FILE" || error "日志文件无法创建"
}

# ---------------------- 主程序 ----------------------
main_menu() {
    while true; do
        print_header
        echo -e "${COLORS[green]}请选择操作："
        echo
        echo "1. 添加端口转发规则"
        echo "2. 删除现有规则"
        echo "3. 查看生效规则"
        echo "4. 备份当前配置"
        echo "5. 清空所有规则"
        echo
        echo -e "0. 退出管理系统${COLORS[reset]}"
        print_footer

        read -p "操作选项: " choice
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) backup_config ;;
            5) flush_rules ;;
            0) echo -e "${COLORS[blue]}已退出系统${COLORS[reset]}"; exit 0 ;;
            *) echo -e "${COLORS[red]}无效选项，请重新输入${COLORS[reset]}"; sleep 1 ;;
        esac
    done
}

# ---------------------- 启动程序 ----------------------
init_check
main_menu
