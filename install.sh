#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONF_FILE="/etc/hysteria/config.yaml"
BIN_FILE="/usr/local/bin/hysteria"

# 1. 系统检测
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID # 可能是 alpine, debian, ubuntu, centos, rocky, almalinux, fedora
else
    echo -e "${RED}无法识别系统版本！${PLAIN}" && exit 1
fi

# 检查是否为 root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本${PLAIN}" && exit 1

# 2. 状态检查 (自适应)
check_status() {
    if [[ "$OS" == "alpine" ]]; then
        if [ ! -f "/etc/init.d/hysteria" ]; then return 2; fi
        rc-service hysteria status | grep -q "started" && return 0 || return 1
    else
        if ! systemctl is-active --quiet hysteria-server.service; then
            if [ ! -f "/lib/systemd/system/hysteria-server.service" ] && [ ! -f "/etc/systemd/system/hysteria-server.service" ]; then return 2; fi
            return 1
        fi
        return 0
    fi
}

# 3. 基础依赖安装 (增加 CentOS 支持)
install_deps() {
    echo -e "${YELLOW}正在安装依赖...${PLAIN}"
    case "$OS" in
        alpine)
            apk update && apk add --no-cache curl openssl ca-certificates file bash wget ;;
        debian|ubuntu)
            apt update && apt install -y curl openssl ca-certificates wget ;;
        centos|rhel|rocky|almalinux|fedora)
            yum install -y curl openssl ca-certificates wget || dnf install -y curl openssl ca-certificates wget ;;
    esac
}

# 4. BBR 开启 (增加内核版本检查)
enable_bbr() {
    if [ -f /proc/1/environ ] && grep -q "container=lxc" /proc/1/environ; then
        echo -e "${RED}LXC 容器请在宿主机开启 BBR。${PLAIN}"
    else
        echo -e "${YELLOW}正在开启 BBR...${PLAIN}"
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}BBR 开启成功！${PLAIN}"
    fi
    read -p "按回车返回..."
}

# 5. 安装 Hysteria 2
install_hy2() {
    install_deps
    read -p "请输入服务监听端口 [默认 443]: " PORT
    [ -z "${PORT}" ] && PORT="443"

    if [[ "$OS" == "alpine" ]]; then
        # Alpine 二进制安装
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && BINARY="hysteria-linux-amd64" || BINARY="hysteria-linux-arm64"
        curl -L -o $BIN_FILE "https://github.com/apernet/hysteria/releases/latest/download/${BINARY}"
        chmod +x $BIN_FILE
    else
        # 其他系统使用官方脚本
        bash <(curl -fsSL https://get.hy2.sh/)
    fi

    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" -days 36500
    
    [[ "$OS" != "alpine" ]] && chown hysteria:hysteria /etc/hysteria/server.*

    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=')
    cat <<EOF > $CONF_FILE
listen: :$PORT
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: "$PASSWORD"
quic:
  maxIdleTimeout: 30s
bandwidth:
  up: 100 mbps
  down: 100 mbps
EOF

    if [[ "$OS" == "alpine" ]]; then
        cat <<EOF > /etc/init.d/hysteria
#!/sbin/openrc-run
name="Hysteria2"
command="$BIN_FILE"
command_args="server -c $CONF_FILE"
command_background="yes"
pidfile="/run/hysteria.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/hysteria
        rc-update add hysteria default
        rc-service hysteria restart
    else
        systemctl daemon-reload
        systemctl enable hysteria-server
        systemctl restart hysteria-server
    fi

    ln -sf "$(realpath "$0")" /usr/bin/hy2
    chmod +x /usr/bin/hy2
    echo -e "${GREEN}安装完成！输入 hy2 管理。${PLAIN}"
    show_link
}

# 6. 显示配置
show_link() {
    IP=$(curl -s4 https://api.ipify.org || echo "你的IP")
    PW=$(grep 'password:' $CONF_FILE | awk '{print $2}' | tr -d '"')
    PT=$(grep 'listen:' $CONF_FILE | awk -F: '{print $NF}')
    URL="hysteria2://${PW}@${IP}:${PT}/?insecure=1&sni=bing.com#Hy2_Universal"
    echo -e "\n${BLUE}========== 配置信息 ==========${PLAIN}"
    echo -e "地址: ${GREEN}${IP}:${PT}${PLAIN}"
    echo -e "密码: ${GREEN}${PW}${PLAIN}"
    echo -e "链接: ${YELLOW}${URL}${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
    read -p "按回车返回..."
}

# 7. 主菜单
show_menu() {
    clear
    check_status
    S_RES=$?
    echo -e "${PURPLE}==============================================${PLAIN}"
    echo -e "${CYAN}    Hysteria 2 全平台管理脚本 (V5.0)    ${PLAIN}"
    echo -e "${BLUE} 系统: ${GREEN}$OS${PLAIN}  架构: ${GREEN}$(uname -m)${PLAIN}"
    if [ $S_RES -eq 0 ]; then echo -e " 状态: ${GREEN}运行中${PLAIN}"
    elif [ $S_RES -eq 1 ]; then echo -e " 状态: ${RED}已停止${PLAIN}"
    else echo -e " 状态: ${YELLOW}未安装${PLAIN}"; fi
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    echo -e " 1. 安装 Hysteria 2"
    echo -e " 2. 查看配置信息"
    echo -e " 3. 启动服务      4. 停止服务"
    echo -e " 5. 重启服务      6. 开启 BBR 加速"
    echo -e " 7. 卸载脚本      0. 退出"
    echo -e "${PURPLE}----------------------------------------------${PLAIN}"
    read -p "选择 [0-7]: " num
    case "$num" in
        1) install_hy2 ;;
        2) show_link ;;
        3) [[ "$OS" == "alpine" ]] && rc-service hysteria start || systemctl start hysteria-server ;;
        4) [[ "$OS" == "alpine" ]] && rc-service hysteria stop || systemctl stop hysteria-server ;;
        5) [[ "$OS" == "alpine" ]] && rc-service hysteria restart || systemctl restart hysteria-server ;;
        6) enable_bbr ;;
        7) 
            [[ "$OS" == "alpine" ]] && (rc-service hysteria stop; rc-update del hysteria default; rm -rf /etc/init.d/hysteria) || (systemctl stop hysteria-server; systemctl disable hysteria-server)
            rm -rf $CONF_FILE /usr/bin/hy2
            echo -e "${GREEN}卸载完成${PLAIN}" ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

show_menu
