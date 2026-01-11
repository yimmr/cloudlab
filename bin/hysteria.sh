#!/bin/bash

# 主入口函数
# 参数: domain password port tlsdir bw_up bw_down hop_range by_docker
setup_hysteria() {
    FINAL_CLASH_OUTPUT=""

    if [[ $8 =~ ^[Yy]$ ]]; then
        log_step "配置 Hysteria2 ..."
        configure_hysteria "$@"
        install_hysteria_docker "$3"
    else
        install_hysteria_local
        log_step "配置 Hysteria2 ..."
        configure_hysteria "$@"
        systemctl enable --now hysteria-server.service
        systemctl restart hysteria-server.service
        log_step "Hysteria2 完成配置并重启"
    fi

    if [ -n "$FINAL_CLASH_OUTPUT" ]; then
        echo -e "\n========================================"
        echo -e "Clash节点配置:"
        echo "\033[0;32m$FINAL_CLASH_OUTPUT\033[0m"
        echo -e "========================================\n"
    fi
}

# Docker 配置函数
configure_hysteria() {
    local domain=$1
    local password=$2
    local port=${3:-443}
    local tlsdir=$4
    local bw_up=$5
    local bw_down=$6
    local hop_range=$7
    local CONFIG_DIR='/etc/hysteria'

    mkdir -p "$CONFIG_DIR"

    multiple_ports $port $hop_range

    # 写入配置
    local listen_line=""
    if [ "$port" != "443" ]; then
        listen_line="listen: :$port"$'\n'
    fi

    cat > "$CONFIG_DIR/config.yaml" <<EOF
${listen_line}tls:
  cert: $tlsdir/$domain.crt
  key: $tlsdir/$domain.key
auth:
  type: password
  password: $password
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:80
    rewriteHost: true
EOF

    # 构建 Clash 多端口配置
    local ports_line=""
    if [ -n "$hop_range" ]; then
        ports_line="  ports: ${hop_range//:/-}"
    fi

    # 构建带宽配置选项
    local bandwidth_opts=""
    if [ -n "$bw_up" ]; then
        local up_value=$(awk "BEGIN {printf \"%.0f\", $bw_up * 0.9}")
        bandwidth_opts="${bandwidth_opts}  up: ${up_value}"$'\n'
    fi
    if [ -n "$bw_down" ]; then
        local down_value=$(awk "BEGIN {printf \"%.0f\", $bw_down * 0.9}")
        bandwidth_opts="${bandwidth_opts}  down: ${down_value}"$'\n'
    fi

    local node_name=$(domain_to_agent_name_with_icon "$domain")

    FINAL_CLASH_OUTPUT=$(cat <<CLASH_EOF
- name: ${node_name}
  type: hysteria2
  server: ${domain}
  port: ${port}
${ports_line}
  password: ${password}
${bandwidth_opts}  sni: ${domain}
  skip-cert-verify: false
CLASH_EOF
)
}

# Docker 安装/启动函数
install_hysteria_docker() {
    if docker ps -a --format '{{.Names}}' | grep -q "^hysteria$"; then
        log_step "删除旧容器..."
        docker rm -f hysteria >/dev/null 2>&1
    fi

    log_step "正在启动 Hysteria2 容器..."
    docker run -d \
        --name hysteria \
        --restart unless-stopped \
        --net=host \
        -v "/etc/hysteria:/etc/hysteria" \
        tobyxdd/hysteria \
        server -c /etc/hysteria/config.yaml || die "Hysteria2 容器启动失败"

    log_info "Hysteria2 容器已启动"
}

# 本机安装函数
install_hysteria_local() {
    if command -v hysteria &> /dev/null; then
        log_info "Hysteria2 已安装，跳过安装步骤"
        return
    fi

    log_step "开始安装 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) || die "Hysteria2 安装失败"
    log_info "Hysteria2 安装完成"
}

# 移除 Hysteria2
remove_hysteria() {
    bash <(curl -fsSL https://get.hy2.sh/) --remove
}

# 配置多端口转发
multiple_ports() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2

    if [[ -z "$TARGET_PORT" ]] || [[ -z "$HOP_RANGE" ]]; then
        return
    fi

    if ! command -v iptables &> /dev/null; then
        log_step "正在安装 iptables..."
        apt-get install -y iptables
    fi

    if ! dpkg -s iptables-persistent &> /dev/null; then
        log_step "正在安装 iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent
    fi

    # 开启 IP Forwarding (端口转发通常需要)
    if [ "$(sysctl -n net.ipv4.ip_forward)" -eq 0 ]; then
        log_step "开启 IPv4 转发..."
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    if [[ -z "$INTERFACE" ]]; then
        log_err "无法检测到主网卡"
        return 1
    fi

    log_step "配置 iptables 端口跳跃 (网卡: $INTERFACE, 范围: $HOP_RANGE -> $TARGET_PORT)..."

    # 清理旧规则 (抑制错误)
    iptables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null || true

    # 添加新规则
    if ! iptables -t nat -A PREROUTING -i "$INTERFACE" -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$TARGET_PORT" 2>&1; then
        log_err "iptables IPv4 规则添加失败"
        return 1
    fi

    # IPv6 尝试添加，失败不报错
    ip6tables -t nat -A PREROUTING -i "$INTERFACE" -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null || true

    # 持久化
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
        log_step "端口跳跃规则已持久化保存"
    else
        log_warn "未找到 netfilter-persistent，重启后规则可能丢失"
    fi
}

