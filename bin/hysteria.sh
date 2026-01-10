#!/bin/bash


configure_hysteria() {
    local domain=$1
    local password=$2
    local port=${3:-443}
    local CONFIG_DIR='/etc/hysteria'
    local TLS_DIR=$4
    local bw_up=$5
    local bw_down=$6
    local HOP_RANGE=$7

    log_step "配置 Hysteria2..."
    mkdir -p "$CONFIG_DIR"

    # 写入配置
    local listen_line=""
    if [ "$port" != "443" ]; then
        listen_line="# listen: $port"$'\n'
    fi

    cat > "$CONFIG_DIR/config.yaml" <<EOF
${listen_line}tls:
  cert: $TLS_DIR/$domain.crt
  key: $TLS_DIR/$domain.key
auth:
  type: password
  password: $password
masquerade:
  type: proxy
  proxy:
    url: http://127.0.0.1:80
    rewriteHost: true
EOF

    systemctl enable --now hysteria-server.service
    systemctl restart hysteria-server.service
    log_step "Hysteria2 配置并重启完成"

    multiple_ports $port $HOP_RANGE

    # 构建带宽配置选项
    local bandwidth_opts=""
    if [ -n "$bw_up" ]; then
        local up_value=$(awk "BEGIN {printf \"%.0f\", $bw_up * 0.9}")
        bandwidth_opts="${bandwidth_opts} up: ${up_value},"$'\n'
    fi
    if [ -n "$bw_down" ]; then
        local down_value=$(awk "BEGIN {printf \"%.0f\", $bw_down * 0.9}")
        bandwidth_opts="${bandwidth_opts} down: ${down_value},"$'\n'
    fi

    echo -e "Clash节点:"
    echo -e "\033[0;32m
- {
    name: '$(domain_to_agent_name_with_icon $domain)',
    type: hysteria2,
    server: $domain,
    port: "${port}${HOP_RANGE:+,${HOP_RANGE}}",
    password: $password,
    sni: $domain,
    ${bandwidth_opts}
    skip-cert-verify: false
}\033[0m" | tr -s '[:space:]' ' '
    echo ""
}


install_hysteria_if() {
    if command -v hysteria &> /dev/null; then
        log_info "Hysteria2 已安装，跳过"
        return
    fi

    log_step "开始安装 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) || die "Hysteria2 安装失败"
}

remove_hysteria() {
    bash <(curl -fsSL https://get.hy2.sh/) --remove
}

multiple_ports() {
    local TARGET_PORT=$1
    local HOP_RANGE=$2

    if [[ -z "$TARGET_PORT" ]]; then
        return
    fi

    if [[ -z "$HOP_RANGE" ]]; then
        return
    fi

    if ! command -v iptables &> /dev/null; then
        log_step "正在安装 iptables..."
        apt-get install -y iptables
    fi

    if ! dpkg -s iptables-persistent &> /dev/null; then
        log_step "正在安装 iptables-persistent 以便重启自动生效..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y iptables-persistent
    fi

    INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    log_step "检测到主网卡: $INTERFACE"

    log_step "正在配置 iptables 规则..."

    # 幂等性处理：先尝试删除旧规则，防止重复追加
    # 无论是否存在，先删一遍（抑制错误输出）
    iptables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null
    ip6tables -t nat -D PREROUTING -i "$INTERFACE" -p udp --dport "$HOP_RANGE" -j REDIRECT --to-ports "$TARGET_PORT" 2>/dev/null

    # 添加新规则
    iptables -t nat -A PREROUTING -i $INTERFACE -p udp --dport $HOP_RANGE -j REDIRECT --to-ports $TARGET_PORT
    ip6tables -t nat -A PREROUTING -i $INTERFACE -p udp --dport $HOP_RANGE -j REDIRECT --to-ports $TARGET_PORT

    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
        log_step "规则已通过 netfilter-persistent 持久化保存。"
    fi
}