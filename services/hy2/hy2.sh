#!/bin/bash

# ==============================================================================
# Hysteria 2 扩展服务（自治模块）
#
#   由 cloud hy2 <action> 调用，也可独立执行
# ==============================================================================

set -euo pipefail

# --- 定位项目根目录 -----------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
HY2_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PROJECT_DIR="$(cd -P "$HY2_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

source "$PROJECT_DIR/bin/utils.sh"

# --- 常量 ---------------------------------------------------------------------
HY2_CONFIG_DIR="/etc/hysteria"
HY2_CERT_DIR="$HY2_CONFIG_DIR/certs"
HY2_CONFIG_FILE="$HY2_CONFIG_DIR/config.yaml"
HY2_ENV_FILE="$HY2_DIR/hy2.env"
HY2_SERVICE="hysteria-server"
HY2_CRON_FILE="/etc/cron.daily/cloud-hy2-sync"
CADDY_CERT_ROOT="$PROJECT_DIR/infra/caddy/data/caddy/certificates"
PROJECT_ENV_FILE="$PROJECT_DIR/.env"

# ==============================================================================
# 内部函数
# ==============================================================================

# --- hy2.env 读写 -------------------------------------------------------------
hy2_env_get()  { env_get "$HY2_ENV_FILE" "$1" "${2:-}"; }
hy2_env_set()  { env_set "$HY2_ENV_FILE" "$1" "${2:-}"; }

# --- 证书：智能定位 + 同步 ----------------------------------------------------
find_caddy_cert() {
    local domain=${1,,}
    [ -d "$CADDY_CERT_ROOT" ] || return 1
    find "$CADDY_CERT_ROOT" -type f -name "${domain}.crt" 2>/dev/null \
        | xargs -r ls -t 2>/dev/null | head -n 1
}

# 等待 Caddy 完成证书签发
wait_for_caddy_cert() {
    local domain=${1,,} timeout=${2:-90} elapsed=0
    log_step "等待 Caddy 完成 ${domain} 的 TLS 证书签发（最多 ${timeout}s）..."
    while [ "$elapsed" -lt "$timeout" ]; do
        local crt key
        crt=$(find_caddy_cert "$domain") || true
        if [ -n "$crt" ] && [ -s "$crt" ]; then
            key="$(dirname "$crt")/${domain}.key"
            if [ -n "$key" ] && [ -s "$key" ]; then
                log_ok "证书与私钥已就绪"
                return 0
            fi
        fi
        echo -e "  ${C_YELLOW}… 已等待 ${elapsed}s${C_NC}"
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

# 从 Caddy 同步证书到 /etc/hysteria/certs
sync_certificates() {
    local domain=${1,,}
    local crt key
    crt=$(find_caddy_cert "$domain") || true

    if [ -z "$crt" ] || [ ! -s "$crt" ]; then
        log_warn "未在 Caddy 数据目录找到 ${domain} 的证书，跳过同步"
        return 1
    fi

    # 严格匹配同目录下的对应私钥，防止多 CA 目录下证书与私钥交叉错配
    local cert_dir
    cert_dir=$(dirname "$crt")
    key="$cert_dir/${domain}.key"
    if [ ! -s "$key" ]; then
        key=$(find "$cert_dir" -type f -name "*.key" 2>/dev/null | head -n 1) || true
    fi

    if [ -z "$key" ] || [ ! -s "$key" ]; then
        log_warn "未在证书同目录找到私钥 ($key)，跳过同步"
        return 1
    fi

    mkdir -p "$HY2_CERT_DIR"
    # GNU install 默认覆盖目标
    install -m 644 "$crt" "$HY2_CERT_DIR/${domain}.crt"
    install -m 600 "$key" "$HY2_CERT_DIR/${domain}.key"

    # hy2 以非 root 用户运行时需要拥有读取权
    if id hysteria >/dev/null 2>&1; then
        chown -R hysteria:hysteria "$HY2_CERT_DIR"
    fi

    log_ok "证书已同步 -> $HY2_CERT_DIR/${domain}.{crt,key}"
}

# --- 配置生成 -----------------------------------------------------------------
generate_hy2_config() {
    local domain=$1 password=$2 port=$3

    [[ -f "$HY2_CERT_DIR/${domain}.crt" && -f "$HY2_CERT_DIR/${domain}.key" ]] \
        || die "证书文件不存在: $HY2_CERT_DIR/${domain}.{crt,key}，请先执行 cloud hy2 sync-cert"

    # 同步伪装站点资源至 /etc/hysteria/web，赋予 hysteria 权限
    # 采用本地文件伪装徹底杜绝向 80 端口反代所导致的 Caddy 308 强制跳转死循环
    local web_dir="$HY2_CONFIG_DIR/web"
    mkdir -p "$web_dir"
    if [ -d "$PROJECT_DIR/sites/default" ]; then
        cp -ru "$PROJECT_DIR/sites/default/." "$web_dir/" 2>/dev/null || true
    fi
    if id hysteria >/dev/null 2>&1; then
        chown -R hysteria:hysteria "$web_dir" 2>/dev/null || true
    fi

    cat > "$HY2_CONFIG_FILE" <<EOF
listen: :$port
tls:
  cert: $HY2_CERT_DIR/${domain}.crt
  key: $HY2_CERT_DIR/${domain}.key
auth:
  type: password
  password: $password
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 33554432
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 134217728
masquerade:
  type: file
  file:
    dir: $web_dir
EOF

    chmod 600 "$HY2_CONFIG_FILE"
    if id hysteria >/dev/null 2>&1; then
        chown hysteria:hysteria "$HY2_CONFIG_FILE" 2>/dev/null || true
    fi
    log_ok "已生成 $HY2_CONFIG_FILE (静态文件伪装+QUIC大窗口调优)"
}

# --- 二进制与运行用户 --------------------------------------------------------
# 提取版本号（hysteria version 首行是 ASCII 艺术字，需过滤 Version: 行）
hy2_version() {
    hysteria version 2>/dev/null | grep -i '^Version:' | head -n1 | tr -d '\r\t' | sed 's/^[Vv]ersion:[[:space:]]*[Vv]*//'
}

ensure_hysteria_binary() {
    if has_cmd hysteria; then
        log_info "Hysteria 2 已安装: v$(hy2_version)"
        return 0
    fi
    log_step "安装 Hysteria 2 二进制 ..."
    bash <(curl -fsSL https://get.hy2.sh/) || die "Hysteria 2 安装失败"
    has_cmd hysteria || die "Hysteria 2 安装后仍不可用"
    log_ok "Hysteria 2 安装完成: v$(hy2_version)"
}

ensure_hysteria_user() {
    # 确保 hysteria 用户组存在
    if ! getent group hysteria >/dev/null 2>&1; then
        if has_cmd groupadd; then
            groupadd -r hysteria 2>/dev/null || true
        elif has_cmd addgroup; then
            addgroup -S hysteria 2>/dev/null || true
        fi
    fi

    if ! id hysteria >/dev/null 2>&1; then
        local nologin=/sbin/nologin
        [ -x /usr/sbin/nologin ] && nologin=/usr/sbin/nologin
        [ -x /bin/false ] && [ ! -x "$nologin" ] && nologin=/bin/false

        if has_cmd useradd; then
            useradd -r -g hysteria -s "$nologin" -M hysteria 2>/dev/null \
                || useradd -r -s "$nologin" -M hysteria 2>/dev/null \
                || useradd -r hysteria 2>/dev/null || true
        elif has_cmd adduser; then
            adduser -S -G hysteria -s "$nologin" -H hysteria 2>/dev/null \
                || adduser -S -s "$nologin" -H hysteria 2>/dev/null || true
        fi
    fi
    install -d -m 755 "$HY2_CONFIG_DIR"
    if id hysteria >/dev/null 2>&1; then
        chown -R hysteria:hysteria "$HY2_CONFIG_DIR" 2>/dev/null || true
    fi
}

# --- systemd 服务 -------------------------------------------------------------
install_hy2_service() {
    local bin
    bin=$(command -v hysteria || echo /usr/local/bin/hysteria)

    cat > /etc/systemd/system/${HY2_SERVICE}.service <<EOF
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
WorkingDirectory=${HY2_CONFIG_DIR}
ExecStart=${bin} server --config ${HY2_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$HY2_SERVICE" >/dev/null 2>&1 || true
    log_ok "systemd 服务已注册: $HY2_SERVICE"
}

# --- iptables 端口跳跃 --------------------------------------------------------
hop_comment() { echo "hysteria2-$1"; }

# 删除带 hysteria2- 注释的旧规则（IPv4 + IPv6）
# 采用行号倒序删除：避免 -S 带引号的参数经 shell 拆词后失效；匹配规则包含 /* hysteria2-xx */ 注释
remove_hop_rules() {
    local comment=$1 cmd=$2
    has_cmd "$cmd" || return 0

    local nums n
    nums=$("$cmd" -t nat -L PREROUTING -n --line-numbers 2>/dev/null \
           | grep -F "$comment" \
           | awk '{print $1}' | sort -rn)

    [ -z "$nums" ] && return 0

    while IFS= read -r n; do
        [ -z "$n" ] && continue
        "$cmd" -t nat -D PREROUTING "$n" 2>/dev/null || true
    done <<< "$nums"
}

persist_iptables() {
    if has_cmd netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1 || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

apply_port_hopping() {
    local port=$1 hop_range=$2
    hop_range="${hop_range// /}"
    has_cmd iptables || die "未安装 iptables，请执行: cloud hy2 install"

    local comment
    comment=$(hop_comment "$port")

    # 无论是否设置跳跃范围，均先清理旧规则，杜绝残留
    remove_hop_rules "$comment" iptables
    remove_hop_rules "$comment" ip6tables

    if [ -z "$hop_range" ]; then
        log_info "未设置跳跃范围，已清除旧端口跳跃规则"
        persist_iptables
        return 0
    fi

    # iptables --dport 范围格式为 start:end
    local iptables_range="${hop_range//-/:}"

    log_step "配置端口跳跃 ($iptables_range -> $port UDP) ..."

    iptables -t nat -A PREROUTING -p udp --dport "$iptables_range" \
        -m comment --comment "$comment" -j REDIRECT --to-ports "$port" \
        || die "iptables 规则添加失败"

    if has_cmd ip6tables; then
        ip6tables -t nat -A PREROUTING -p udp --dport "$iptables_range" \
            -m comment --comment "$comment" -j REDIRECT --to-ports "$port" 2>/dev/null || true
    fi

    persist_iptables
    log_ok "端口跳跃规则已生效"
}

clear_port_hopping() {
    local port=${1:-443}
    local comment
    comment=$(hop_comment "$port")
    remove_hop_rules "$comment" iptables
    remove_hop_rules "$comment" ip6tables
    persist_iptables
    log_ok "端口跳跃规则已清理"
}

# --- 客户端配置导出 -----------------------------------------------------------
print_client_config() {
    local domain=$1 password=$2 port=$3 hop_range=$4 bw_up=$5 bw_down=$6
    local node_name
    node_name=$(domain_to_agent_name_with_icon "$domain")

    local up_line="" down_line="" hop_block=""
    if [[ -n "$bw_up" ]]; then
        local clean_up="${bw_up//[^0-9]/}"
        [ -n "$clean_up" ] && up_line=$'\n'"  up: \"${clean_up} Mbps\""
    fi
    if [[ -n "$bw_down" ]]; then
        local clean_down="${bw_down//[^0-9]/}"
        [ -n "$clean_down" ] && down_line=$'\n'"  down: \"${clean_down} Mbps\""
    fi
    if [[ -n "$hop_range" ]]; then
        hop_block=$'\n'"  ports: ${hop_range//:/-}"$'\n'"  hop-interval: 30"
    fi

    print_rule
    echo -e "${C_BOLD}Clash / Mihomo 节点 (推荐 TUN 模式使用)${C_NC}"
    print_rule
    cat <<EOF
- name: "${node_name}"
  type: hysteria2
  server: ${domain}
  port: ${port}${hop_block}
  password: ${password}${up_line}${down_line}
  sni: ${domain}
  alpn:
    - h3
  skip-cert-verify: false
EOF

    print_rule
    echo -e "${C_BOLD}通用导入链接 (v2rayN / Shadowrocket / Sing-box / NekoBox)${C_NC}"
    print_rule
    # 对密码做基础 URL 转义，防止特殊字符破坏 URI 结构
    local encoded_pass
    if has_cmd python3; then
        encoded_pass=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$password" 2>/dev/null || echo "$password")
    else
        encoded_pass=$(printf '%s' "$password" | sed -e 's/@/%40/g' -e 's/:/%3A/g' -e 's/\//%2F/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/&/%26/g')
    fi
    local uri="hy2://${encoded_pass}@${domain}:${port}/?sni=${domain}&alpn=h3"
    [[ -n "$hop_range" ]] && uri="${uri}&mport=${hop_range//:/-}"
    uri="${uri}#$(printf '%s' "$node_name" | sed 's/ /%20/g')"
    echo "$uri"
    print_rule
    echo -e "${C_YELLOW}提示${C_NC}: 密码与端口已保存在 $HY2_CONFIG_FILE，随时可用 cloud hy2 export 重新导出"
}

# --- 证书自动续期定时任务 -----------------------------------------------------
install_cert_sync_cron() {
    cat > "$HY2_CRON_FILE" <<EOF
#!/bin/sh
# cloud: 每日同步 Caddy 证书并重启应用 Hysteria 2（开销极低，仅做指纹比对）
"$PROJECT_DIR/bin/cloud" hy2 sync-cert >/dev/null 2>&1
EOF
    chmod 755 "$HY2_CRON_FILE"
    log_ok "已注册证书同步定时任务: $HY2_CRON_FILE"
}

remove_cert_sync_cron() {
    rm -f "$HY2_CRON_FILE"
}

# ==============================================================================
# Action 实现
# ==============================================================================
action_install() {
    check_root

    log_step "检查依赖 ..."
    local need=()
    has_cmd curl     || need+=(curl)
    has_cmd iptables || need+=(iptables)
    if [ ${#need[@]} -gt 0 ]; then
        log_info "安装缺失依赖: ${need[*]}"
        pkg_install "${need[@]}"
    fi

    ensure_hysteria_binary
    ensure_hysteria_user

    log_step "启动底座容器以便签发证书 ..."
    docker compose -f "$PROJECT_DIR/compose.yaml" up -d 2>/dev/null || true

    action_config

    install_cert_sync_cron

    log_step "Hysteria 2 安装完成"
}

action_config() {
    check_root

    # 允许直接执行 config 而无需先 install
    ensure_hysteria_binary
    ensure_hysteria_user

    local domain; domain=$(hy2_env_get HY2_DOMAIN "")
    [[ -z "$domain" ]] && domain=$(env_get "$PROJECT_ENV_FILE" SITE_DOMAIN "")

    _banner "Hysteria 2 配置"

    local new_domain
    new_domain=$(prompt "[必填]服务域名 (需已解析到本机): " "$domain")
    [ -z "$new_domain" ] && die "域名不能为空"
    domain=$new_domain

    echo ""
    local password
    password=$(prompt "客户端访问密码 (留空随机生成): " "$(hy2_env_get HY2_PASSWORD "")")
    [ -z "$password" ] && password=$(generate_password)

    local port
    port=$(prompt "监听端口 (443 推荐): " "$(hy2_env_get HY2_PORT 443)")

    local hop_range
    hop_range=$(prompt "端口跳跃范围 (留空禁用): " "$(hy2_env_get HY2_HOP_RANGE 20000:50000)")

    echo ""
    log_info "客户端 Brutal 速率控制提示 (仅写入客户端导出配置，服务端不限速以释放全部出口性能):"
    local bw_up bw_down
    bw_up=$(prompt "客户端上行带宽 Mbps (留空不限速): " "$(hy2_env_get HY2_BW_UP "")")
    bw_down=$(prompt "客户端下行带宽 Mbps (留空不限速): " "$(hy2_env_get HY2_BW_DOWN "")")

    # --- 持久化 hy2 专属环境变量 ---
    hy2_env_set HY2_DOMAIN     "$domain"
    hy2_env_set HY2_PASSWORD   "$password"
    hy2_env_set HY2_PORT       "$port"
    hy2_env_set HY2_HOP_RANGE  "$hop_range"
    hy2_env_set HY2_BW_UP      "$bw_up"
    hy2_env_set HY2_BW_DOWN    "$bw_down"

    # --- 等待并同步证书 ---
    echo ""
    if ! wait_for_caddy_cert "$domain" 90; then
        log_warn "等待证书超时。请排查 DNS 解析 / 云安全组 80·443 端口后执行:"
        log_warn "  cloud hy2 sync-cert"
        exit 1
    fi
    sync_certificates "$domain"

    # --- 生成服务端配置 ---
    generate_hy2_config "$domain" "$password" "$port"

    # --- 注册并启动服务 ---
    if systemctl list-unit-files 2>/dev/null | grep -q "^${HY2_SERVICE}"; then
        systemctl restart "$HY2_SERVICE"
    else
        install_hy2_service
        systemctl enable --now "$HY2_SERVICE"
    fi
    log_ok "Hysteria 2 服务已启动"

    # --- 端口跳跃 ---
    apply_port_hopping "$port" "$hop_range"

    echo ""
    print_client_config "$domain" "$password" "$port" "$hop_range" "$bw_up" "$bw_down"
}

action_start() {
    check_root
    systemctl enable --now "$HY2_SERVICE"
    log_ok "Hysteria 2 已启动"
}

action_stop() {
    systemctl stop "$HY2_SERVICE"
    log_ok "Hysteria 2 已停止"
}

action_restart() {
    check_root
    systemctl restart "$HY2_SERVICE"
    log_ok "Hysteria 2 已重启"
}

action_status() {
    print_rule
    echo -e "${C_BOLD}Hysteria 2 状态${C_NC}"
    print_rule

    if service_is_active "$HY2_SERVICE"; then
        echo -e "  服务    : ${C_GREEN}运行中${C_NC}"
    else
        echo -e "  服务    : ${C_RED}未运行${C_NC}"
    fi
    printf '  版本    : %s\n' "v$(hy2_version)"
    printf '  域名    : %s\n' "$(hy2_env_get HY2_DOMAIN '-')"
    printf '  端口    : %s\n' "$(hy2_env_get HY2_PORT '-')"
    printf '  跳跃    : %s\n' "$(hy2_env_get HY2_HOP_RANGE '-')"

    if has_cmd iptables; then
        echo ""
        echo -e "${C_BOLD}端口跳跃规则${C_NC}"
        local raw_rules
        if raw_rules=$(iptables -t nat -S PREROUTING 2>/dev/null); then
            echo "$raw_rules" | grep 'hysteria2-' || echo "  (无)"
        else
            echo -e "  ${C_YELLOW}(需 root 权限查看 iptables 规则)${C_NC}"
        fi
    fi

    local domain days
    domain=$(hy2_env_get HY2_DOMAIN "")
    if [ -n "$domain" ] && [ -f "$HY2_CERT_DIR/${domain}.crt" ]; then
        if days=$(cert_days_left "$HY2_CERT_DIR/${domain}.crt"); then
            echo ""
            printf '  本地证书: %s剩余 %s 天%s\n' "$(cert_color "$days")" "$days" "$C_NC"
        else
            echo ""
            echo "  本地证书: 已同步（无法解析有效期）"
        fi
    fi
    print_rule
}

action_log() { journalctl --no-pager -f -u "$HY2_SERVICE"; }

action_debug() {
    check_root
    log_warn "debug 模式前台运行，按 Ctrl+C 退出"
    hysteria server --config "$HY2_CONFIG_FILE" --log-level debug
}

action_export() {
    local domain password port hop_range bw_up bw_down
    domain=$(hy2_env_get HY2_DOMAIN "")
    password=$(hy2_env_get HY2_PASSWORD "")
    port=$(hy2_env_get HY2_PORT 443)
    hop_range=$(hy2_env_get HY2_HOP_RANGE "")
    bw_up=$(hy2_env_get HY2_BW_UP "")
    bw_down=$(hy2_env_get HY2_BW_DOWN "")

    [ -n "$domain" ] || die "尚未配置 hy2，请执行: cloud hy2 config"
    [ -n "$password" ] || die "未找到连接密码，请先执行: cloud hy2 config"
    print_client_config "$domain" "$password" "$port" "$hop_range" "$bw_up" "$bw_down"
}

action_sync_cert() {
    check_root

    local domain
    domain=$(hy2_env_get HY2_DOMAIN "")
    [ -n "$domain" ] || domain=$(env_get "$PROJECT_ENV_FILE" SITE_DOMAIN "")
    [ -n "$domain" ] || die "无法确定域名，请先执行 cloud hy2 config"

    local before=""
    [ -f "$HY2_CERT_DIR/${domain}.crt" ] && before=$(md5sum "$HY2_CERT_DIR/${domain}.crt" | cut -d' ' -f1)

    sync_certificates "$domain" || exit 1

    local after
    after=$(md5sum "$HY2_CERT_DIR/${domain}.crt" | cut -d' ' -f1)

    if [ "$before" != "$after" ]; then
        if service_is_active "$HY2_SERVICE"; then
            systemctl restart "$HY2_SERVICE"
            log_ok "证书已更新，Hysteria 2 已重启应用新证书"
        else
            log_ok "证书已同步到 $HY2_CERT_DIR"
            if [ -f "$HY2_CONFIG_FILE" ]; then
                log_info "服务未处于运行状态，可执行: cloud hy2 start"
            fi
        fi
    else
        log_info "证书无变化，无需重启"
    fi
}

action_bbr() {
    check_root
    bash "$HY2_DIR/bbr.sh"
}

action_update() {
    check_root

    # 兼容旧版 Docker 部署方式（当前重构仅支持原生 systemd 部署）
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx hysteria; then
        log_err "检测到 Docker 版 hysteria 容器，原生更新流程不适用"
        log_info "请先执行 cloud hy2 uninstall，再执行 cloud hy2 install 切换为原生部署"
        return 1
    fi

    local before after
    before=$(hy2_version)
    [ -n "$before" ] || die "尚未安装 Hysteria 2，请执行: cloud hy2 install"

    log_step "更新 Hysteria 2 二进制 ..."
    log_info "当前版本: v$before"
    bash <(curl -fsSL https://get.hy2.sh/) || die "更新失败"
    after=$(hy2_version)
    log_ok "二进制已更新: v$after"

    # 官方安装脚本会重写 systemd unit，这里恢复加固版配置
    log_step "恢复加固版 systemd 服务 ..."
    install_hy2_service
    systemctl daemon-reload

    # 配置在 /etc/hysteria/config.yaml，官方脚本不会覆盖；仍同步一次证书兜底
    local domain
    domain=$(hy2_env_get HY2_DOMAIN "")
    if [ -n "$domain" ]; then
        sync_certificates "$domain" || log_warn "证书同步失败，可稍后执行 cloud hy2 sync-cert"
    fi

    # 同步最新伪装站点源码
    local web_dir="$HY2_CONFIG_DIR/web"
    if [ -d "$PROJECT_DIR/sites/default" ]; then
        mkdir -p "$web_dir"
        cp -ru "$PROJECT_DIR/sites/default/." "$web_dir/" 2>/dev/null || true
        if id hysteria >/dev/null 2>&1; then
            chown -R hysteria:hysteria "$web_dir" 2>/dev/null || true
        fi
    fi

    systemctl restart "$HY2_SERVICE"
    sleep 1
    if service_is_active "$HY2_SERVICE"; then
        log_ok "Hysteria 2 已更新并重启 (v$(hy2_version))"
    else
        log_err "服务重启后未处于运行状态，请执行: cloud hy2 log"
        return 1
    fi
}

action_uninstall() {
    check_root
    local yes=${1:-}
    if [ "$yes" != "--yes" ]; then
        confirm "⚠️  确认卸载 Hysteria 2 并清理端口跳跃规则？(y/N)" "n" || { echo "已取消。"; exit 0; }
    fi

    systemctl disable --now "$HY2_SERVICE" 2>/dev/null || true
    rm -f /etc/systemd/system/${HY2_SERVICE}.service
    systemctl daemon-reload

    remove_cert_sync_cron
    clear_port_hopping "$(hy2_env_get HY2_PORT 443)"
    rm -rf "$HY2_CONFIG_DIR"

    if has_cmd hysteria; then
        log_info "移除 hysteria 二进制"
        rm -f "$(command -v hysteria)"
    fi

    rm -f "$HY2_ENV_FILE"
    log_ok "Hysteria 2 已完全卸载，底座基础设施未受影响"
}

# ==============================================================================
# 路由
# ==============================================================================
main() {
    local action=${1:-help}
    shift || true

    case "$action" in
        install)    action_install ;;
        config)     action_config ;;
        start)      action_start ;;
        stop)       action_stop ;;
        restart)    action_restart ;;
        status)     action_status ;;
        log|logs)   action_log ;;
        debug)      action_debug ;;
        export)     action_export ;;
        sync-cert)  action_sync_cert ;;
        bbr)        action_bbr ;;
        clear-hop)  clear_port_hopping "$(hy2_env_get HY2_PORT 443)" ;;
        update|upgrade) action_update ;;
        uninstall)  action_uninstall "$@" ;;

        help|-h|--help)
            echo "Hysteria 2 管理: install | config | start | stop | restart | status | log | debug | export | sync-cert | bbr | clear-hop | update | uninstall"
            ;;
        *)
            log_err "未知 hy2 子命令: $action"
            exit 1
            ;;
    esac
}

main "$@"