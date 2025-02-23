#!/bin/bash
# 智能端口转发管理器 v2.1
# 支持IPv4/IPv6双栈 | 自动连接跟踪清理 | 规则持久化

# ---------------------- 配置区 ----------------------
CONFIG_FILE="/etc/port_forward.rules"
LOG_FILE="/var/log/pfm.log"
declare -A COLORS=(
    [reset]="\033[0m"
    [red]="\033[38;5;196m"
    [green]="\033[38;5;046m"
    [yellow]="\033[38;5;226m"
    [cyan]="\033[38;5;051m"
    [blue]="\033[38;5;027m"
)
COL1=8    # 序号列
COL2=10   # 协议列
COL3=24   # 源端口
COL4=32   # 目标地址
COL5=18   # 接口

# ---------------------- 初始化检查 ----------------------
init_check() {
    [[ $EUID -ne 0 ]] && error "必须使用root权限运行"
    [[ ! -x /sbin/iptables ]] && error "iptables未安装"
    mkdir -p "${CONFIG_FILE%/*}"
    touch "$CONFIG_FILE" || error "配置文件不可写"
}

# ---------------------- 日志系统 ----------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ---------------------- 美观输出函数 ----------------------
print_header() {
    clear
    printf "%${COL1}s" "序号" 
    printf "%-${COL2}s" "协议"
    printf "%-${COL3}s" "源端口范围"
    printf "%-${COL4}s" "目标地址 ➜ 端口"
    printf "%-${COL5}s\n" "网络接口"
    
    # 动态生成分隔线
    sepline() {
        yes "▔" | head -n $1 | tr -d '\n'
    }
    echo -e "${COLORS[blue]}$(sepline $COL1) $(sepline $COL2) $(sepline $COL3) $(sepline $COL4) $(sepline $COL5)${COLORS[reset]}"
}

print_rule() {
    printf "%${COL1}d" "$1"
    printf "%-${COL2}s" "$2"
    printf "%-${COL3}s" "${3:0:24}"
    printf "%-${COL4}s" "${4:0:28}"
    printf "%-${COL5}s\n" "$5"
}

# ---------------------- 规则生成器 ----------------------
gen_hash() {
    sha256sum <<< "${1}${2}${3}${4}${5}" | cut -c1-32 | tee -a "$LOG_FILE"
}

add_rule() {
    read -p "协议类型 (tcp/udp): " proto
    read -p "源端口范围 (如 1000-2000): " src_port
    read -p "目标IP地址: " dest_ip
    read -p "目标端口: " dest_port
    read -p "网络接口: " interface

    # 输入校验
    [[ ! "$proto" =~ ^(tcp|udp)$ ]] && error "无效协议类型"
    [[ ! "$src_port" =~ ^[0-9]+(-[0-9]+)?$ ]] && error "端口格式错误"
    [[ ! "$dest_port" =~ ^[0-9]+$ ]] && error "目标端口需为数字"

    local fw_hash=$(gen_hash "$proto" "$src_port" "$dest_ip" "$dest_port" "$interface")
    
    # 查重机制
    if grep -q "$fw_hash" "$CONFIG_FILE"; then
        error "重复规则已存在" 3
    fi

    # 写入配置
    echo "${fw_hash}|${proto}|${src_port}|${dest_ip}|${dest_port}|${interface}" >> "$CONFIG_FILE"

    # 动态生成iptables规则
    iptables_cmd="iptables -t nat -A PREROUTING -i $interface -p $proto --match multiport --dports ${src_port} -j DNAT --to-destination ${dest_ip}:${dest_port} -m comment --comment \"PFM:${fw_hash}\""
    
    if eval "$iptables_cmd"; then
        log "规则添加成功: $fw_hash"
        persist_rules
    else
        error "规则应用失败" 4
    fi
}

# ---------------------- 规则删除器 ----------------------
delete_rule() {
    mapfile -t rules < "$CONFIG_FILE"
    [[ ${#rules[@]} -eq 0 ]] && error "没有可删除的规则"

    print_header
    local count=1
    declare -A rule_map
    for rule in "${rules[@]}"; do
        IFS='|' read -r hash proto src_range dest_ip dest_port iface <<< "$rule"
        print_rule $count "$proto" "$src_range" "${dest_ip}:${dest_port}" "$iface"
        rule_map[$count]="$hash"
        ((count++))
    done

    read -p "输入要删除的规则序号: " choice
    [[ -z "${rule_map[$choice]}" ]] && error "无效的选择"
    
    local target_hash="${rule_map[$choice]}"
    
    # 从配置文件中删除
    sed -i "/^${target_hash}/d" "$CONFIG_FILE"
    
    # 清理iptables规则
    while read -r line_num; do
        iptables -t nat -D PREROUTING "$line_num" 2>/dev/null || \
        log "规则索引变化，尝试哈希清除..." && \
        iptables -t nat -D PREROUTING -m comment --comment "PFM:${target_hash}" 2>/dev/null
    done < <(iptables -t nat --line-numbers -L PREROUTING | grep "PFM:${target_hash}" | awk '{print $1}' | tac)

    # 清空相关连接追踪
    conntrack -D -d "$dest_ip" -p "$proto" --dport "$dest_port" &>/dev/null
    
    persist_rules
    log "规则 ${target_hash} 已移除"
}

# ---------------------- 规则持久化 ----------------------
persist_rules() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save || error "持久化失败"
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 || error "保存失败"
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    fi
}

# ---------------------- 动态宽度版本 ----------------------
dynamic_menu() {
    local term_width=$(tput cols)
    local title=" 端口转发管理器 v3.1 "
    local line_length=$(( (term_width - ${#title}) / 2 - 2 ))
    
    # 生成动态装饰线
    gen_line() {
        yes $1 | head -n $line_length | tr -d '\n'
    }
    
    clear
    echo -e "${COLORS[blue]}$(gen_line '▔')${title}$(gen_line '▔')${COLORS[reset]}"
    echo
    echo "1. 添加端口转发规则"
    echo "2. 删除现有规则"
    echo "3. 查看生效中的规则"
    echo "4. 导出当前配置"
    echo "5. 清空所有规则"
    echo "0. 退出管理系统"
    echo
    echo -e "${COLORS[blue]}$(gen_line '▁')${COLORS[reset]}"
}


# ---------------------- 执行入口 ----------------------
init_check
while true; do
    main_menu
    read -p "请选择操作: " opt
    case $opt in
        1) add_rule ;;
        2) delete_rule ;;
        3) print_header; cat "$CONFIG_FILE" | awk -F'|' '{print $1,$2,$3,$4":"$5,$6}' | column -t ;;
        4) persist_rules ;;
        5) iptables -t nat -F PREROUTING ; rm "$CONFIG_FILE" ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
