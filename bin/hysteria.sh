#!/bin/bash

configure_hysteria() {
    local domain=$1
    local password=$2
    local port=${3:-443}
    local CONFIG_DIR='/etc/hysteria'
    local TLS_DIR=$4

    log_info "配置 Hysteria2..."
    mkdir -p "$CONFIG_DIR"

    # 写入配置
    cat > "$CONFIG_DIR/config.yaml" <<EOF
listen: $port/udp
protocol: udp
tls:
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
    log_info "Hysteria2 配置并重启完成"

    echo -e "Clash节点:"
    echo -e "\033[0;32m{
    name: '$(domain_to_agent_name_with_icon $domain)',
    type: hysteria2,
    server: $domain,
    port: $port,
    password: $password,
    sni: $domain,
    skip-cert-verify: false
}\033[0m"
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