#!/bin/bash
# 名称：端口转发管理器（增强版）
# 版本：v2.0
# 特点：支持TCP/UDP | 多网卡选择 | 自动错误恢复

# ---------------------- 初始化设置 ----------------------
CONFIG_FILE="/etc/port_forward.conf"
RULES_FILE="/etc/iptables/rules.v4"
MAX_RETRY=3
LOG_FILE="/var/log/port_forward.log"

# ---------------------- 权限检查 ----------------------
if [[ $EUID -ne  ]]; then
    echo -e "\033[31m错误：必须使用 root 权限运行此脚本！\033[0m" >&2
    exit 1
fi

# ---------------------- 颜色定义 ----------------------
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------- 日志记录 ----------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

# ---------------------- 函数定义 ----------------------
show_menu() {
    clear
    if [[ $(tput cols) -ge 80 ]]; then
        echo -e "${BLUE}
        ███████╗██╗  ██╗██╗██╗     ██╗   ██╗ ██████╗ ███████╗██╗     
        ██╔════╝██║  ██║██║██║     ██║   ██║██╔═══██╗██╔════╝██║     
        ███████╗███████║██║██║     ██║   ██║██║   ██║███████╗██║     
        ╚════██║██╔══██║██║██║     ██║   ██║██║   ██║╚════██║██║     
        ███████║██║  ██║██║███████╗╚██████╔╝╚██████╔╝███████║███████╗
        ╚══════╝╚═╝  ╚═╝╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
        ${RESET}"
    else
        echo -e "${BLUE}[端口转发管理器 v2.0]${RESET}"
    fi
    
    echo -e "${YELLOW}==================== 功能菜单 ====================${RESET}"
    echo "1. 添加端口转发规则"
    echo "2. 删除指定规则"
    echo "3. 查看当前规则"
    echo "4. 清理所有规则"
    echo "5. 导出当前配置"
    echo "6. 流量监控看板"
    echo "7. 退出程序"
    echo -e "${YELLOW}================================================${RESET}"
}

# ---------------------- 验证函数 ----------------------
validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) && return 0
    echo -e "${RED}错误：端口必须在 1-65535 之间${RESET}"
    log "无效端口输入: $1"
    return 1
}

validate_ip() {
    local ip=$1
    local stat=1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && \
           ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]
        stat=$?
    fi
    [ $stat -eq 0 ] && return 0
    echo -e "${RED}无效IP地址格式！${RESET}"
    log "无效IP输入: $ip"
    return 1
}

# ---------------------- 网络接口选择 ----------------------
select_interface() {
    local interfaces=$(ip link show | awk -F': ' '$0 !~ "lo|vir" {print $2}')
    local count=$(wc -w <<< "$interfaces")

    if [ "$count" -gt 1 ]; then
        echo -e "${BOLD}检测到多个网络接口：${RESET}"
        PS3="请选择主网卡（输入数字）: "
        select interface in $interfaces; do
            [ -n "$interface" ] && break
            echo -e "${RED}无效选择！请重新输入${RESET}"
        done
        echo "$interface"
    else
        echo "$interfaces"
    fi
}

# ---------------------- 依赖管理 ----------------------
install_deps_with_retry() {
    echo -e "${GREEN}[系统检测] 正在检查依赖环境...${RESET}"
    
    for ((i=1; i<=$MAX_RETRY; i++)); do
        if ! command -v iptables &>/dev/null || \
           ! dpkg -l | grep -q iptables-persistent; then
            echo -e "${YELLOW}[安装尝试 $i/$MAX_RETRY] 正在安装依赖...${RESET}"
            
            if ! DEBIAN_FRONTEND=noninteractive apt update -q && \
               DEBIAN_FRONTEND=noninteractive apt install -qy \
               iptables iptables-persistent netfilter-persistent; then
                echo -e "${RED}安装失败！${RESET}"
                [ $i -eq $MAX_RETRY ] && exit 1
                sleep 2
            else
                systemctl enable netfilter-persistent >/dev/null 2>&1
                return 0
            fi
        else
            echo -e "${GREEN}[状态] 依赖检查通过${RESET}"
            return 0
        fi
    done
}

# ---------------------- 核心功能 ----------------------
add_rule() {
    # 协议选择
    read -p "协议类型 [tcp/udp] (默认udp): " protocol
    protocol=${protocol:-udp}
    [[ $protocol != "tcp" && $protocol != "udp" ]] && protocol="udp"

    # 源端口范围
    while true; do
        read -p "源端口范围（格式：开始:结束）: " source_range
        if [[ $source_range =~ ^[0-9]+:[0-9]+$ ]]; then
            start_port=${source_range%%:*}
            end_port=${source_range##*:}
            if validate_port $start_port && validate_port $end_port && (( start_port < end_port )); then
                break
            else
                echo -e "${RED}起始端口必须小于结束端口！${RESET}"
            fi
        else
            echo -e "${RED}格式错误！示例：5000:6000${RESET}"
        fi
    done

    # 目标地址
    while true; do
        read -p "目标IP地址（默认127.0.0.1）: " dest_ip
        dest_ip=${dest_ip:-127.0.0.1}
        validate_ip "$dest_ip" && break
    done

    # 目标端口
    while true; do
        read -p "目标端口: " dest_port
        validate_port $dest_port && break
    done

    # 网卡选择
    interface=$(select_interface)
    [ -z "$interface" ] && return

    # 配置保存
    rule_hash=$(md5sum <<< "${protocol}-${source_range}-${dest_ip}:${dest_port}" | cut -d' ' -f1)
    echo "RULE_HASH=$rule_hash" | tee $CONFIG_FILE >/dev/null
    echo "PROTOCOL=$protocol" >> $CONFIG_FILE
    echo "SOURCE=$source_range" >> $CONFIG_FILE
    echo "DEST_IP=$dest_ip" >> $CONFIG_FILE
    echo "DEST_PORT=$dest_port" >> $CONFIG_FILE
    chmod 600 $CONFIG_FILE

    # 应用规则
    if iptables -t nat -C PREROUTING -i $interface -p $protocol --dport $source_range -j DNAT --to-destination ${dest_ip}:${dest_port} 2>/dev/null; then
        echo -e "${YELLOW}规则已存在，无需重复添加${RESET}"
        return
    fi

    if ! iptables -t nat -A PREROUTING -i $interface -p $protocol --dport $source_range -j DNAT --to-destination ${dest_ip}:${dest_port}; then
        echo -e "${RED}规则添加失败！正在回滚...${RESET}"
        netfilter-persistent reload
        log "规则添加失败：${protocol}/${source_range}->${dest_ip}:${dest_port}"
        exit 1
    fi

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    
    if ! netfilter-persistent save; then
        echo -e "${YELLOW}规则保存异常，尝试手动保存...${RESET}"
        mkdir -p /etc/iptables
        iptables-save > $RULES_FILE
    fi
}

delete_rule() {
    [ ! -f $CONFIG_FILE ] && echo -e "${RED}未找到有效配置！${RESET}" && return

    source $CONFIG_FILE
    interface=$(ip route show default | awk '/default/ {print $5}')
    
    if iptables -t nat -C PREROUTING -i $interface -p $PROTOCOL --dport $SOURCE -j DNAT --to-destination ${DEST_IP}:${DEST_PORT} 2>/dev/null; then
        iptables -t nat -D PREROUTING -i $interface -p $PROTOCOL --dport $SOURCE -j DNAT --to-destination ${DEST_IP}:${DEST_PORT}
        netfilter-persistent save
        rm -f $CONFIG_FILE
        echo -e "${GREEN}规则成功移除${RESET}"
        log "规则删除：${PROTOCOL}/${SOURCE}->${DEST_IP}:${DEST_PORT}"
    else
        echo -e "${YELLOW}目标规则不存在或已被移除${RESET}"
    fi
}

# ---------------------- 主程序 ----------------------
trap "echo -e '${RED}\n操作已中断！${RESET}'; exit 1" SIGINT

install_deps_with_retry

while true; do
    show_menu
    read -p "请输入操作编号 [1-7]: " choice

    case $choice in
        1) add_rule ;;
        2) delete_rule ;;
        3)
            echo -e "\n${BOLD}当前 NAT 规则：${RESET}"
            iptables -t nat -L PREROUTING -n --line-numbers
            echo
            ;;
        4)
            read -p "${YELLOW}确认要清空所有转发规则？[y/N] ${RESET}" confirm
            if [[ $confirm =~ [Yy] ]]; then
                iptables -t nat -F PREROUTING
                netfilter-persistent save
                rm -f $CONFIG_FILE
                echo -e "${GREEN}所有规则已清理${RESET}"
                log "规则全集清除"
            fi
            ;;
        5)
            cp $CONFIG_FILE ./port_forward_backup_$(date +%F).conf
            echo -e "${GREEN}配置已导出到当前目录${RESET}"
            ;;
        6)
            echo -e "${BOLD}正在启动流量监控...${RESET}"
            echo -e "${YELLOW}按 Ctrl+C 返回菜单${RESET}"
            watch -n1 'iptables -t nat -L PREROUTING -v -n'
            ;;
        7)
            echo -e "${BLUE}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入！${RESET}"
            ;;
    esac

    read -p "按回车键继续..."
done
