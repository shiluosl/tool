#!/bin/bash
# 智能端口转发管理器 v3.6 稳定版
# 更新日志：增加规则去重机制、优化用户退出操作

# ---------------------- 初始化配置 ----------------------
CONFIG_FILE="$(pwd)/config.conf"
LOG_FILE="$(pwd)/log.log"
declare -A COLORS=( 
    [reset]=$'\033[0m'        # 重置颜色
    [red]=$'\033[38;5;196m'   # 错误提示
    [yellow]=$'\033[38;5;226m' # 警告信息
    [blue]=$'\033[38;5;39m'   # 界面元素
    [cyan]=$'\033[38;5;51m'   # 次级信息
    [purple]=$'\033[38;5;129m' # 功能标题
)
LINE_TOP="▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
LINE_BOT="▁▁▁▁▁▁▁▔▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁"

# ---------------------- 通用函数 ----------------------
color_printf() {
    local color=$1
    printf "%b" "${COLORS[$color]}"
    printf "${@:2}"
    printf "%b" "${COLORS[reset]}"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    color_printf "red" "错误: %s\n" "$1" | tee -a "$LOG_FILE"
    exit "${2:-1}"
}

# ---------------------- 界面函数 ----------------------
print_header() {
    clear
    color_printf "blue" "%s\n" "$LINE_TOP"
    printf "%34s\n" "端口转发管理器 v3.6"
    color_printf "blue" "%s\n\n" "$LINE_TOP"
}

print_footer() {
    printf "\n"
    color_printf "blue" "%s\n" "$LINE_BOT"
}

show_spinner() {
    local spin=('⣾' '⣽' '⣻' '⢿' '⡿' '⣟' '⣯' '⣷')
    local pid=$!
    local i=0
    while kill -0 $pid 2>/dev/null; do
        printf "\r%s 处理中..." "${spin[i++ % ${#spin[@]}]}"
        sleep 0.1
    done
    printf "\r%20s\r" ""
}

# ---------------------- 网络函数 ----------------------
get_default_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}

# ---------------------- 核心模块 ----------------------
gen_hash() {
    printf "%s" "$1$2$3$4$5" | sha256sum | cut -c1-8
}

validate_input() {
    case $1 in
        proto)
            [[ "$2" =~ ^(tcp|udp)$ ]] || error "协议类型错误 (必须为 tcp/udp)" 2
            ;;
        port)
            local re_range='^[0-9]+[:-][0-9]+$'
            if [[ "$2" =~ $re_range ]]; then
                local sep=$(tr -dc '-' <<< "$2")
                IFS="$sep" read -ra parts <<< "$2"
                (( parts[0] >= 1 && parts[-1] <= 65535 && parts[0] < parts[-1] )) || 
                    error "端口范围错误 (1~65535 且起始<结束)" 3
            elif [[ "$2" =~ ^[0-9]+$ ]]; then
                (( $2 >= 1 && $2 <= 65535 )) || error "单个端口错误 (1~65535)" 4
            else
                error "端口格式错误 (使用 X-Y 或 X:Y 或 X)" 5
            fi
            ;;
        ip) 
            [[ "$2" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && {
                IFS='.' read -ra oct <<< "$2"
                for i in "${oct[@]}"; do ((i <= 255)) || return 1; done
            } || error "IP地址无效" 6
            ;;
    esac
}

add_rule() {
    print_header
    color_printf "purple" "▶ 添加转发规则\n"

    read -p "$(color_printf "cyan" "协议类型 (tcp/udp) [默认udp]: ")" proto
    proto=${proto:-udp}
    validate_input proto "$proto"

    while : ; do
        read -p "$(color_printf "cyan" "源端口或范围 (如 5000-6000): ")" src_port
        [[ -n "$src_port" ]] && validate_input port "${src_port//:/-}" && break
        color_printf "yellow" "必须输入源端口!\n"
    done
    src_port="${src_port//-/:}"

    read -p "$(color_printf "cyan" "目标IP [默认127.0.0.1]: ")" dest_ip
    dest_ip=${dest_ip:-127.0.0.1}
    validate_input ip "$dest_ip"

    while : ; do
        read -p "$(color_printf "cyan" "目标端口: ")" dest_port
        validate_input port "$dest_port" && break
    done

    iface=$(get_default_interface)
    read -p "$(color_printf "cyan" "网络接口 [默认$iface]: ")" input_iface
    interface=${input_iface:-$iface}

    local fw_hash=$(gen_hash "$proto" "$src_port" "$dest_ip" "$dest_port" "$interface")
    if grep -q "^${fw_hash}|" "$CONFIG_FILE"; then
        error "规则已存在: $fw_hash" 8
    fi

    if ! iptables -t nat -A PREROUTING \
        -i "$interface" -p "$proto" \
        -m multiport --dports "$src_port" \
        -j DNAT --to-destination "${dest_ip}:${dest_port}" \
        -m comment --comment "PFM-${fw_hash}" 2>> "$LOG_FILE"
    then
        error "规则添加失败，请检查参数" 9
    fi

    echo "${fw_hash}|${proto}|${src_port}|${dest_ip}|${dest_port}|${interface}" >> "$CONFIG_FILE"
    log "规则添加: $fw_hash"
    persist_rules & show_spinner

    color_printf "green" "\n规则添加成功！\n"
    sleep 1
}

delete_rule() {
    print_header
    color_printf "purple" "▶ 删除转发规则\n"

    [[ ! -s "$CONFIG_FILE" ]] && {
        color_printf "yellow" "没有可删除的规则！\n"
        read -n 1 -s -r -p "$(color_printf "cyan" "按任意键返回...")"
        return
    }

    declare -a rules=()
    mapfile -t rules < "$CONFIG_FILE"

    color_printf "cyan" "\n已配置规则列表：\n"
    local i=1
    for rule in "${rules[@]}"; do
        IFS='|' read -r hash proto src dest_ip dest_port iface <<< "$rule"
        printf "%2d. %-4s %-15s → %-15s\n" $i "$proto" "${iface}:${src}" "${dest_ip}:${dest_port}"
        ((i++))
    done

    color_printf "yellow" "\n输入 q 返回主菜单\n"

    while : ; do
        read -p "$(color_printf "cyan" "选择要删除的规则编号 (1-$(( ${#rules[@]} )) 或 q): ")" choice
        [[ "$choice" =~ ^[Qq]$ ]] && {
            color_printf "blue" "\n已取消删除操作\n"
            sleep 1
            return
        }
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >=1 && choice <= ${#rules[@]} )) && break
        color_printf "yellow" "请输入有效编号或 q 退出！\n"
    done

    target_hash=$(cut -d'|' -f1 <<< "${rules[$((choice-1))]}")

    iptables -t nat -L PREROUTING --line-number -n | \
    awk -v h="PFM-$target_hash" '$0 ~ h {print $1}' | sort -nr | \
    while read -r num; do
        iptables -t nat -D PREROUTING "$num" 2>> "$LOG_FILE"
    done

    sed -i "/^$target_hash|/d" "$CONFIG_FILE"
    log "规则删除: $target_hash"
    persist_rules & show_spinner

    color_printf "green" "\n规则删除成功！\n"
    sleep 1
}

show_rules() {
    print_header
    color_printf "cyan" "活动转发规则（从持久化配置读取）：\n\n"

    # 表格标题
    printf "  %-4s  %-5s  %-18s  %-25s  %-10s\n" \
           "ID" "协议" "外部访问" "目标地址" "接口"
    color_printf "blue" "%s\n" "-------------------------------------------------------------"

    # 从规则文件解析（关键逻辑）
    awk '
    BEGIN {
        rule_id = 0
        OFS = "  "
    }
    # 筛选 NAT 表的 PREROUTING 链且包含 PFM- 注释
    /^\*nat/,/^COMMIT/ {
        if ($0 ~ /^:PREROUTING/) { in_prerouting = 1 }
        if ($0 ~ /^-A PREROUTING .*PFM-/) {
            rule_id++
            proto = "any"
            ext_port = "any"
            dest = "unknown"
            iface = "any"

            # 逐字段解析
            for (i=3; i<=NF; i++) {
                if ($i == "-p") { proto = $(i+1) }
                if ($i == "-i") { iface = $(i+1) }
                if ($i == "--dport") { ext_port = $(i+1) }
                if ($i == "--to-destination") { dest = $(i+1) }
                if ($i == "-m" && $(i+1) == "multiport" && $(i+2) == "--dports") {
                    ext_port = $(i+3)
                }
            }

            # 转换端口格式（如 80:443 转为 80-443）
            gsub(":", "-", ext_port)
            printf "  %-4s  %-5s  %-18s  %-25s  %-10s\n", 
                rule_id, toupper(proto), iface ":" ext_port, dest, iface
        }
    }' /etc/iptables/rules.v4 | while read -r line; do
        color_printf "yellow" "› %s\n" "$line"
    done

    read -n 1 -s -r -p "$(color_printf "cyan" "按任意键返回...")"
}

persist_rules() {
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save &>> "$LOG_FILE" || error "规则持久保存失败" 10
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4.new 2>> "$LOG_FILE" || error "iptables保存失败" 11
        # 防止重复：对比新旧文件后覆盖
        if ! diff -q /etc/iptables/rules.v4.new /etc/iptables/rules.v4 &>/dev/null; then
            mv /etc/iptables/rules.v4.new /etc/iptables/rules.v4
        fi
        ip6tables-save > /etc/iptables/rules.v6 2>> "$LOG_FILE"
    fi
}

init_check() {
    [[ $EUID -ne 0 ]] && error "需要ROOT权限运行"
    [[ -x /usr/sbin/iptables ]] || error "缺少iptables组件"

    # 清理旧规则
    color_printf "cyan" "清理旧规则..."
    iptables -t nat -L PREROUTING --line-numbers -n | \
        awk '/PFM-/ {print $1}' | sort -nr | \
        while read -r num; do
            iptables -t nat -D PREROUTING "$num"
        done 2>/dev/null
    color_printf "green" "完成\n"

    # 加载配置文件
    color_printf "cyan" "加载配置规则..."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    touch "$CONFIG_FILE" "$LOG_FILE" || error "无法创建配置文件"
    while IFS='|' read -r hash proto ports dest_ip dest_port iface; do
        [[ -z "$hash" ]] && continue
        iptables -t nat -A PREROUTING \
            -i "$iface" -p "$proto" \
            -m multiport --dports "${ports//:/,}" \
            -j DNAT --to-destination "$dest_ip:$dest_port" \
            -m comment --comment "PFM-$hash" 2>> "$LOG_FILE"
    done < "$CONFIG_FILE"
    color_printf "green" "完成\n"

    # 持久化到文件
    persist_rules &>/dev/null
}

backup_config() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.${timestamp}"
    color_printf "cyan" "\n配置已备份至: %b%s%b\n" \
        "${COLORS[blue]}" "${CONFIG_FILE}.bak.${timestamp}" "${COLORS[reset]}"
    sleep 1
}

flush_rules() {
    print_header
    color_printf "red" "⚠ 危险操作警告 ⚠\n"
    read -p "$(color_printf "yellow" "确实要清空所有规则？(y/N/q): ")" confirm
    
    case "${confirm,,}" in
        y)
            color_printf "cyan" "正在清除规则..."
            iptables -t nat -L PREROUTING --line-numbers -n | \
                awk '/PFM-/ {print $1}' | sort -nr | \
                while read -r num; do
                    iptables -t nat -D PREROUTING "$num"
                done
            > "$CONFIG_FILE"
            persist_rules & show_spinner
            color_printf "green" "\n所有规则已安全清除！\n"
            log "用户执行了清空规则操作"
            sleep 2
            ;;
        q)
            color_printf "blue" "\n操作已取消\n"
            sleep 1
            ;;
        *)
            color_printf "yellow" "\n输入未识别，操作已取消\n"
            sleep 1
            ;;
    esac
}

main_menu() {
    while true; do
        print_header
        color_printf "cyan" "主菜单功能：\n\n"
        printf "1. 添加转发规则\n"
        printf "2. 删除现有规则\n"
        printf "3. 查看生效规则\n"
        printf "4. 备份当前配置\n"
        printf "5. 清空所有规则\n\n"
        color_printf "red" "0. 退出系统\n"
        print_footer
        
        read -p "请输入选项: " choice
        case "$choice" in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) backup_config ;;
            5) flush_rules ;;
            0) color_printf "blue" "\n再见，安全退出！\n"; exit 0 ;;
            *) color_printf "yellow" "\n无效选项，请重新输入！\n"; sleep 1 ;;
        esac
    done
}

# ---------------------- 执行入口 ----------------------
init_check
main_menu
