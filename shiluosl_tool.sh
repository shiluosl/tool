#!/bin/bash
# 名称：智能端口转发管理器
# 版本：v1.1
# 特点：自动依赖安装 + 菜单式交互

# ---------------------- 初始化设置 ----------------------
CONFIG_FILE="/etc/port_forward.conf"
RULES_FILE="/etc/iptables/rules.v4"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RESET='\033[0m'

# ---------------------- 函数定义 ----------------------
show_menu() {
    clear
    echo -e "${BLUE}
    ███████╗██╗  ██╗██╗██╗     ██╗   ██╗ ██████╗ ███████╗██╗     
    ██╔════╝██║  ██║██║██║     ██║   ██║██╔═══██╗██╔════╝██║     
    ███████╗███████║██║██║     ██║   ██║██║   ██║███████╗██║     
    ╚════██║██╔══██║██║██║     ██║   ██║██║   ██║╚════██║██║     
    ███████║██║  ██║██║███████╗╚██████╔╝╚██████╔╝███████║███████╗
    ╚══════╝╚═╝  ╚═╝╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
    ${RESET}"
    echo -e "${YELLOW}============== 端口转发管理器 v1.1 ==============${RESET}"
    echo "1. 配置端口转发规则"
    echo "2. 删除转发规则"
    echo "3. 查看当前规则"
    echo "4. 退出"
    echo -e "${YELLOW}===============================================${RESET}"
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) && return 0
    echo -e "${RED}错误：端口必须在1-65535之间${RESET}"
    return 1
}

check_install_deps() {
    echo -e "${GREEN}[步骤 1/3] 正在检查系统依赖...${RESET}"
    
    if ! command -v iptables &>/dev/null || \
       ! dpkg -l | grep -q iptables-persistent; then
        echo -e "${YELLOW}[提示] 需要安装 iptables 相关依赖${RESET}"
        
        # 非交互式安装
        DEBIAN_FRONTEND=noninteractive apt update -q
        if ! DEBIAN_FRONTEND=noninteractive apt install -qy iptables iptables-persistent netfilter-persistent; then
            echo -e "${RED}依赖安装失败，请检查网络连接！${RESET}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}[状态] 依赖检查通过${RESET}"
}

# ---------------------- 主逻辑 ----------------------
while true; do
    show_menu
    read -p "请选择操作 [1-4]: " choice

    case $choice in
        1)
            # 自动安装依赖
            check_install_deps
            
            # 获取配置信息
            while true; do
                read -p "请输入源端口范围（如 50000:65535）: " SOURCE_RANGE
                if [[ $SOURCE_RANGE =~ ^[0-9]+:[0-9]+$ ]]; then
                    START_PORT=${SOURCE_RANGE%%:*}
                    END_PORT=${SOURCE_RANGE##*:}
                    if validate_port $START_PORT && validate_port $END_PORT && (( START_PORT < END_PORT )); then
                        break
                    else
                        echo -e "${RED}起始端口必须小于结束端口！${RESET}"
                    fi
                else
                    echo -e "${RED}格式错误！请使用冒号分隔端口范围${RESET}"
                fi
            done

            while true; do
                read -p "请输入目标端口: " DEST_PORT
                validate_port $DEST_PORT && break
            done

            # 保存配置
            echo "SOURCE_RANGE=$SOURCE_RANGE" > $CONFIG_FILE
            echo "DEST_PORT=$DEST_PORT" >> $CONFIG_FILE

            # 获取网卡
            INTERFACE=$(ip route show default | awk '/default/ {print $5}')
            [ -z "$INTERFACE" ] && echo -e "${RED}获取默认网卡失败！${RESET}" && exit 1

            echo -e "\n${GREEN}[步骤 2/3] 正在配置规则...${RESET}"
            iptables -t nat -A PREROUTING -i $INTERFACE -p udp --dport $SOURCE_RANGE -j DNAT --to-destination :$DEST_PORT
            
            echo -e "${GREEN}[步骤 3/3] 保存配置...${RESET}"
            sysctl -w net.ipv4.ip_forward=1 >/dev/null
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            netfilter-persistent save
            
            echo -e "\n${GREEN}✔ 规则已生效！重启后仍然有效${RESET}"
            ;;
        2)
            [ ! -f $CONFIG_FILE ] && echo -e "${RED}未找到配置文件！${RESET}" && continue
            
            source $CONFIG_FILE
            INTERFACE=$(ip route show default | awk '/default/ {print $5}')
            
            if iptables -t nat -C PREROUTING -i $INTERFACE -p udp --dport $SOURCE_RANGE -j DNAT --to-destination :$DEST_PORT 2>/dev/null; then
                iptables -t nat -D PREROUTING -i $INTERFACE -p udp --dport $SOURCE_RANGE -j DNAT --to-destination :$DEST_PORT
                netfilter-persistent save
                rm $CONFIG_FILE
                echo -e "${GREEN}成功删除转发规则！${RESET}"
            else
                echo -e "${YELLOW}未找到匹配的转发规则${RESET}"
            fi
            ;;
        3)
            echo -e "${BLUE}当前生效规则：${RESET}"
            iptables -t nat -L PREROUTING -n --line-numbers | grep -A 10 "Chain"
            ;;
        4)
            echo -e "${BLUE}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入！${RESET}"
            ;;
    esac

    echo
    read -p "按回车键返回主菜单..."
done
