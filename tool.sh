#!/bin/bash
# 名称：高级端口转发管理器
# 版本：v3.1
# 特点：多规则管理 | 精准匹配

# ---------------------- 初始化设置 ----------------------
CONFIG_FILE="$(pwd)/config.conf"
LOG_FILE="$(pwd)/log.log"
RULES_FILE="/etc/iptables/rules.v4"

# ---------------------- 颜色定义 ----------------------
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'

# ---------------------- 日志记录 ----------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ---------------------- 依赖检查 ----------------------
check_deps() {
    if ! command -v iptables &>/dev/null; then
        echo -e "${RED}错误：缺少iptables，请先安装iptables！${RESET}"
        exit 1
    fi
    
    if ! dpkg -l | grep -q iptables-persistent; then
        echo -e "${YELLOW}正在安装iptables-persistent...${RESET}"
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent; then
            echo -e "${RED}安装失败，请手动安装iptables-persistent！${RESET}"
            exit 1
        fi
    fi
}

# ---------------------- 配置管理 ----------------------
save_config() {
    echo "$1" >> "$CONFIG_FILE"
    log "保存规则: $1"
}

load_rules() {
    [[ -f "$CONFIG_FILE" ]] && cat "$CONFIG_FILE" || echo ""
}

# ---------------------- 规则验证 ----------------------
validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )) && return 0
    echo -e "${RED}错误：端口号必须为1-65535之间的整数${RESET}"
    return 1
}

validate_ip() {
    local ip="$1"
    local stat=1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            (( octet > 255 )) && { stat=1; break; }
            stat=0
        done
    fi
    [ $stat -eq 0 ] && return 0
    echo -e "${RED}错误：IP地址格式无效${RESET}"
    return 1
}

# ---------------------- 接口选择 ----------------------
select_interface() {
    local interfaces=($(ip -o link show | awk -F': ' '!/lo|vir/{print $2}'))
    if (( ${#interfaces[@]} == 0 )); then
        echo -e "${RED}未找到可用网络接口！${RESET}"
        return 1
    fi
    
    PS3="请选择网络接口（输入序号）: "
    select interface in "${interfaces[@]}"; do
        [[ -n $interface ]] && break
        echo -e "${RED}无效选择，请重新输入！${RESET}"
    done
    echo "$interface"
}

# ---------------------- 核心功能 ----------------------
add_rule() {
    # 协议选择
    read -rp "协议类型 [tcp/udp] (默认tcp): " protocol
    protocol=${protocol:-tcp}
    [[ $protocol != "tcp" && $protocol != "udp" ]] && protocol="tcp"

    # 源端口范围
    while true; do
        read -rp "源端口范围（格式 开始:结束，如5000:6000）: " source_range
        if [[ $source_range =~ ^[0-9]+:[0-9]+$ ]]; then
            start_port=${source_range%%:*}
            end_port=${source_range##*:}
            if validate_port "$start_port" && validate_port "$end_port" && (( start_port < end_port )); then
                break
            else
                echo -e "${RED}错误：起始端口必须小于结束端口！${RESET}"
            fi
        else
            echo -e "${RED}格式错误！正确示例：5000:6000${RESET}"
        fi
    done

    # 目标地址
    while true; do
        read -rp "目标IP地址（默认127.0.0.1）: " dest_ip
        dest_ip=${dest_ip:-127.0.0.1}
        validate_ip "$dest_ip" && break
    done

    # 目标端口
    while true; do
        read -rp "目标端口: " dest_port
        validate_port "$dest_port" && break
    done

    # 接口选择
    interface=$(select_interface) || return

    # 生成唯一标识
    rule_hash=$(md5sum <<< "${protocol}-${source_range}-${dest_ip}:${dest_port}-${interface}" | cut -d' ' -f1)
    rule_entry="${rule_hash}:${protocol}:${source_range}:${dest_ip}:${dest_port}:${interface}"
    
    # 检查重复规则
    if grep -q "^${rule_hash}:" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}相同规则已存在，无需重复添加！${RESET}"
        return
    fi

    # 应用规则
    if ! iptables -t nat -A PREROUTING -i "$interface" -p "$protocol" \
         --dport "$source_range" -j DNAT --to-destination "${dest_ip}:${dest_port}" \
         -m comment --comment "PFM:$rule_hash"; then
        echo -e "${RED}规则添加失败，正在回滚...${RESET}"
        netfilter-persistent reload
        log "规则添加失败: $rule_entry"
        return 1
    fi

    # 保存配置
    save_config "$rule_entry"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    netfilter-persistent save
    echo -e "${GREEN}✔ 规则添加成功！${RESET}"
}

delete_rule() {
    local rules=($(load_rules))
    if [[ ${#rules[@]} -eq 0 ]]; then
        echo -e "${YELLOW}当前没有可用的转发规则${RESET}"
        return
    fi

    # 显示规则列表
    echo -e "\n${BOLD}当前规则列表：${RESET}"
    local count=1
    printf "%-4s %-8s %-15s %-20s %-15s\n" "序号" "协议" "源端口" "目标地址:端口" "接口"
    for rule in "${rules[@]}"; do
        IFS=':' read -r _ protocol source_range dest_ip dest_port interface <<< "$rule"
        printf "%-4d %-8s %-15s %-20s %-15s\n" \
               "$count" "$protocol" "$source_range" "${dest_ip}:${dest_port}" "$interface"
        ((count++))
    done

    # 选择删除项
    local choice
    while true; do
        read -rp "请输入要删除的规则序号 (0取消): " choice
        [[ $choice -eq 0 ]] && return
        if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rules[@]} )); then
            break
        else
            echo -e "${RED}无效序号，请重新输入！${RESET}"
        fi
    done

    # 提取规则信息
    local selected_rule="${rules[$((choice-1))]}"
    IFS=':' read -r hash protocol source_range dest_ip dest_port interface <<< "$selected_rule"

    # 删除iptables规则
    if iptables -t nat -C PREROUTING -i "$interface" -p "$protocol" \
       --dport "$source_range" -j DNAT --to-destination "${dest_ip}:${dest_port}" \
       -m comment --comment "PFM:$hash" &>/dev/null; then
        iptables -t nat -D PREROUTING -i "$interface" -p "$protocol" \
                 --dport "$source_range" -j DNAT --to-destination "${dest_ip}:${dest_port}" \
                 -m comment --comment "PFM:$hash"
        log "删除规则: $selected_rule"
    else
        echo -e "${YELLOW}规则不存在或已被移除${RESET}"
    fi

    # 更新配置文件
    sed -i "/^${hash}:/d" "$CONFIG_FILE"
    netfilter-persistent save
    echo -e "${GREEN}✔ 规则成功删除！${RESET}"
}

# ---------------------- 辅助功能 ----------------------
list_rules() {
    echo -e "\n${BOLD}当前生效的NAT规则：${RESET}"
    iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E 'PFM:|target'
    echo
}

# ---------------------- 主程序 ----------------------
main_menu() {
    check_deps
    while true; do
        clear
        echo -e "${BLUE}▔▔▔▔▔▔▔▔▔▔▔▔ 端口转发管理器 v3.1 ▔▔▔▔▔▔▔▔▔▔▔▔${RESET}"
        echo "1. 添加转发规则"
        echo "2. 删除规则"
        echo "3. 查看当前规则"
        echo "4. 退出程序"
        echo -e "${BLUE}▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁${RESET}"
        
        read -rp "请输入操作编号 [1-4]: " choice
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) list_rules ;;
            4) 
                echo -e "${GREEN}感谢使用，再见！${RESET}"
                exit 0 ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
        esac
        read -rp "按回车键继续..."
    done
}

# 异常处理
trap "echo -e '\n${RED}操作中断！${RESET}'; exit 1" SIGINT
main_menu
