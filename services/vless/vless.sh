#!/bin/bash

# ==============================================================================
# VLESS + WebSocket 扩展服务（自治模块，经 Cloudflare 橙云回源）
#
#   由 cloud vless <action> 调用，也可独立执行
#   架构: 客户端 --TLS--> Cloudflare --> Caddy:80/443 --> xray:10088 (WS)
# ==============================================================================

set -euo pipefail

# --- 定位项目根目录 -----------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
VLESS_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PROJECT_DIR="$(cd -P "$VLESS_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

source "$PROJECT_DIR/bin/utils.sh"

# --- 常量 ---------------------------------------------------------------------
VLESS_ENV_FILE="$VLESS_DIR/vless.env"
VLESS_CONFIG_FILE="$VLESS_DIR/config.json"
VLESS_COMPOSE_FILE="$VLESS_DIR/compose.yaml"
VLESS_CONTAINER="xray"
VLESS_PORT=10088

# ==============================================================================
# 内部函数
# ==============================================================================

vless_env_get() { env_get "$VLESS_ENV_FILE" "$1" "${2:-}"; }
vless_env_set() { env_set "$VLESS_ENV_FILE" "$1" "${2:-}"; }

ensure_env() {
    [ -f "$VLESS_ENV_FILE" ] || cp "$VLESS_DIR/vless.env.example" "$VLESS_ENV_FILE"
}

# compose 调用：导出 vless.env 与 .env 供 label 变量插值
vless_compose() {
    set -a
    # shellcheck disable=SC1090
    source "$VLESS_ENV_FILE"
    if [ -f "$PROJECT_DIR/.env" ]; then
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/.env"
    fi
    set +a
    docker compose -f "$VLESS_COMPOSE_FILE" "$@"
}

generate_config() {
    local uuid=$1 path=$2
    cat > "$VLESS_CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${path}" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    chmod 600 "$VLESS_CONFIG_FILE"
    log_ok "已生成 $VLESS_CONFIG_FILE (VLESS + WS :${VLESS_PORT})"
}

# 等待经 Cloudflare 回源可用（525/526/521/522 = 回源未就绪）
wait_https_ready() {
    local domain=$1 timeout=${2:-120} elapsed=0 code
    log_step "等待 https://${domain} 回源就绪（Caddy 经 CF 签发证书，最多 ${timeout}s）..."
    while [ "$elapsed" -lt "$timeout" ]; do
        code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://${domain}/" 2>/dev/null || echo "000")
        case "$code" in
            521|522|523|525|526|530|000)
                echo -e "  ${C_YELLOW}… 已等待 ${elapsed}s (HTTP ${code})${C_NC}"
                ;;
            *)
                log_ok "回源就绪 (HTTP ${code})"
                return 0
                ;;
        esac
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

# --- 客户端配置导出 -----------------------------------------------------------
print_client_config() {
    local domain=$1 uuid=$2 path=$3
    local node_name
    node_name=$(domain_to_agent_name_with_icon "$domain")

    print_rule
    echo -e "${C_BOLD}Clash / Mihomo 节点${C_NC}"
    print_rule
    cat <<EOF
- name: "${node_name}"
  type: vless
  server: ${domain}
  port: 443
  uuid: ${uuid}
  tls: true
  servername: ${domain}
  network: ws
  udp: true
  ws-opts:
    path: ${path}
    headers:
      Host: ${domain}
  skip-cert-verify: false
EOF

    print_rule
    echo -e "${C_BOLD}通用导入链接 (v2rayNG / v2rayN / Shadowrocket)${C_NC}"
    print_rule
    local encoded_path
    encoded_path=$(printf '%s' "$path" | sed 's|/|%2F|g')
    echo "vless://${uuid}@${domain}:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${encoded_path}#$(printf '%s' "$node_name" | sed 's/ /%20/g')"
    print_rule
    echo -e "${C_YELLOW}提示${C_NC}: 配置保存在 $VLESS_ENV_FILE，随时可用 cloud vless export 重新导出"
    echo -e "${C_YELLOW}提示${C_NC}: 若延迟测试失败，先运行 cloud netcheck 检查线路质量"
}

# ==============================================================================
# Action 实现
# ==============================================================================

action_install() {
    check_root
    has_cmd docker || die "需要 Docker"
    docker compose version >/dev/null 2>&1 || die "需要 docker compose 插件"

    ensure_env

    local domain uuid path
    domain=$(vless_env_get VLESS_DOMAIN "us2.yimmx.xyz")
    [ -n "$domain" ] || { domain="us2.yimmx.xyz"; vless_env_set VLESS_DOMAIN "$domain"; }

    uuid=$(vless_env_get VLESS_UUID "")
    if [ -z "$uuid" ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
        vless_env_set VLESS_UUID "$uuid"
        log_ok "已生成 UUID: $uuid"
    fi

    path=$(vless_env_get VLESS_PATH "")
    if [ -z "$path" ]; then
        path="/ray-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        vless_env_set VLESS_PATH "$path"
        log_ok "已生成 WS 路径: $path"
    fi

    generate_config "$uuid" "$path"

    log_step "启动 xray 容器 ..."
    vless_compose up -d
    log_ok "xray 容器已启动 (VLESS + WS :${VLESS_PORT})"

    echo ""
    if ! wait_https_ready "$domain" 120; then
        log_warn "回源尚未就绪。请检查:"
        log_warn "  1. CF DNS: us2 的 A 记录源站是否为本机公网 IP（保持橙云）"
        log_warn "  2. CF SSL/TLS 加密模式是否为 Full"
        log_warn "  3. cloud logs caddy 查看证书签发日志"
        exit 1
    fi

    echo ""
    print_client_config "$domain" "$uuid" "$path"
}

action_config() {
    check_root
    ensure_env

    _banner "VLESS + WebSocket 配置"

    local domain uuid path
    domain=$(prompt "[必填]服务域名 (需已解析且经 CF 代理): " "$(vless_env_get VLESS_DOMAIN us2.yimmx.xyz)")
    [ -n "$domain" ] || die "域名不能为空"
    domain=$(printf '%s' "$domain" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

    uuid=$(prompt "UUID (直接回车保留/生成): " "$(vless_env_get VLESS_UUID "")")
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

    path=$(prompt "WebSocket 路径 (直接回车保留/生成): " "$(vless_env_get VLESS_PATH "")")
    if [ -z "$path" ]; then
        path="/ray-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    [[ "$path" == /* ]] || path="/$path"

    vless_env_set VLESS_DOMAIN "$domain"
    vless_env_set VLESS_UUID   "$uuid"
    vless_env_set VLESS_PATH   "$path"

    generate_config "$uuid" "$path"

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$VLESS_CONTAINER"; then
        log_step "重启 xray 容器 ..."
        vless_compose up -d --force-recreate
    else
        vless_compose up -d
    fi
    log_ok "xray 容器已更新"

    echo ""
    if wait_https_ready "$domain" 60; then
        echo ""
        print_client_config "$domain" "$uuid" "$path"
    else
        log_warn "回源未就绪，可稍后执行 cloud vless export 获取配置"
    fi
}

action_status() {
    print_rule
    echo -e "${C_BOLD}VLESS + WebSocket 状态${C_NC}"
    print_rule

    local domain uuid path
    domain=$(vless_env_get VLESS_DOMAIN '-')
    uuid=$(vless_env_get VLESS_UUID '-')
    path=$(vless_env_get VLESS_PATH '-')
    printf '  域名    : %s\n' "$domain"
    printf '  UUID    : %s\n' "$uuid"
    printf '  WS 路径 : %s\n' "$path"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$VLESS_CONTAINER"; then
        echo -e "  容器    : ${C_GREEN}运行中${C_NC} ($VLESS_CONTAINER)"
    else
        echo -e "  容器    : ${C_RED}未运行${C_NC}"
    fi

    if [ "$domain" != "-" ]; then
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://${domain}/" 2>/dev/null || echo "000")
        case "$code" in
            521|522|523|525|526|530)
                echo -e "  回源    : ${C_RED}失败 (HTTP $code)${C_NC} — 检查 CF 源站 IP / SSL 模式"
                ;;
            000)
                echo -e "  回源    : ${C_YELLOW}无法连接${C_NC}"
                ;;
            *)
                echo -e "  回源    : ${C_GREEN}正常 (HTTP $code)${C_NC}"
                ;;
        esac
        if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/infra/caddy/data/caddy/certificates" ]; then
            local crt days
            crt=$(find "$PROJECT_DIR/infra/caddy/data/caddy/certificates" -type f -name "${domain}.crt" 2>/dev/null \
                | xargs -r ls -t 2>/dev/null | head -n 1)
            if [ -n "$crt" ] && days=$(cert_days_left "$crt"); then
                printf '  证书    : %s剩余 %s 天%s\n' "$(cert_color "$days")" "$days" "$C_NC"
            fi
        fi
    fi
    print_rule
}

action_export() {
    local domain uuid path
    domain=$(vless_env_get VLESS_DOMAIN "")
    uuid=$(vless_env_get VLESS_UUID "")
    path=$(vless_env_get VLESS_PATH "")

    [ -n "$domain" ] || die "尚未配置，请执行: cloud vless install"
    [ -n "$uuid" ]   || die "未找到 UUID，请执行: cloud vless config"
    [ -n "$path" ]   || path="/ray-default"
    print_client_config "$domain" "$uuid" "$path"
}

action_log() {
    docker logs -f --tail 200 "$VLESS_CONTAINER"
}

action_update() {
    check_root
    ensure_env
    [ -f "$VLESS_CONFIG_FILE" ] || die "尚未配置，请执行: cloud vless install"

    log_step "更新 xray 镜像 ..."
    vless_compose pull
    vless_compose up -d --force-recreate
    log_ok "xray 已更新并重启"
}

action_uninstall() {
    check_root
    local yes=${1:-}
    if [ "$yes" != "--yes" ]; then
        confirm "⚠️  确认卸载 VLESS + WebSocket 服务？(y/N)" "n" || { echo "已取消。"; exit 0; }
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$VLESS_CONTAINER"; then
        vless_compose down || true
    fi
    rm -f "$VLESS_CONFIG_FILE" "$VLESS_ENV_FILE"
    log_ok "VLESS + WebSocket 已卸载（Caddy 路由与证书将随容器标签消失自动移除）"
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
        status)     action_status ;;
        export)     action_export ;;
        log|logs)   action_log ;;
        update|upgrade) action_update ;;
        uninstall)  action_uninstall "$@" ;;
        help|-h|--help)
            echo "VLESS + WebSocket 管理: install | config | status | export | log | update | uninstall"
            ;;
        *)
            log_err "未知 vless 子命令: $action"
            exit 1
            ;;
    esac
}

main "$@"
