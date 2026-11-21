#!/bin/bash

# ==============================================================================
# VLESS-Reality 扩展服务（自治模块，纯 TCP 直连，借用大厂 TLS 证书伪装）
#
#   由 cloud reality <action> 调用，也可独立执行
#   架构: 客户端 --TCP:8443 (Reality)--> xray-reality (直连 VPS，无 CDN，抗主动探测)
# ==============================================================================

set -euo pipefail

# --- 定位项目根目录 -----------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
REALITY_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PROJECT_DIR="$(cd -P "$REALITY_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

source "$PROJECT_DIR/bin/utils.sh"

# --- 常量 ---------------------------------------------------------------------
REALITY_ENV_FILE="$REALITY_DIR/reality.env"
REALITY_CONFIG_FILE="$REALITY_DIR/config.json"
REALITY_COMPOSE_FILE="$REALITY_DIR/compose.yaml"
REALITY_CONTAINER="xray-reality"
DEFAULT_PORT=8443
DEFAULT_DEST="addons.mozilla.org:443"
DEFAULT_SNI="addons.mozilla.org"

# ==============================================================================
# 内部函数
# ==============================================================================

reality_env_get() { env_get "$REALITY_ENV_FILE" "$1" "${2:-}"; }
reality_env_set() { env_set "$REALITY_ENV_FILE" "$1" "${2:-}"; }

ensure_env() {
    [ -f "$REALITY_ENV_FILE" ] || cp "$REALITY_DIR/reality.env.example" "$REALITY_ENV_FILE"
}

reality_compose() {
    set -a
    # shellcheck disable=SC1090
    [ -f "$REALITY_ENV_FILE" ] && source "$REALITY_ENV_FILE"
    if [ -f "$PROJECT_DIR/.env" ]; then
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/.env"
    fi
    set +a
    docker compose -f "$REALITY_COMPOSE_FILE" "$@"
}

get_server_ip() {
    local ip
    ip=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || curl -s -m 5 https://ifconfig.me 2>/dev/null || ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || echo "")
    if [ -z "$ip" ]; then
        ip="<服务器公网IP>"
    fi
    echo "$ip"
}

get_node_name() {
    local vless_domain
    vless_domain=$(env_get "$PROJECT_DIR/services/vless/vless.env" VLESS_DOMAIN "")
    if [ -n "$vless_domain" ]; then
        local base
        base=$(domain_to_agent_name_with_icon "$vless_domain")
        echo "${base}-Reality"
    else
        echo "🇺🇸 Us-Reality"
    fi
}

generate_keys() {
    local out
    out=$(docker run --rm teddysun/xray xray x25519 2>/dev/null) || die "无法生成 x25519 密钥，请确保 Docker 可运行 teddysun/xray"
    REALITY_GEN_PRIV=$(echo "$out" | grep -i 'PrivateKey:' | awk '{print $2}')
    REALITY_GEN_PUB=$(echo "$out" | grep -i 'Password (PublicKey):' | awk '{print $NF}')
    [ -n "$REALITY_GEN_PRIV" ] && [ -n "$REALITY_GEN_PUB" ] || die "解析 x25519 密钥对失败"
}

generate_config() {
    local port=$1 uuid=$2 dest=$3 sni=$4 priv_key=$5 short_id=$6
    cat > "$REALITY_CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}",
          "xver": 0,
          "serverNames": [
            "${sni}"
          ],
          "privateKey": "${priv_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    chmod 600 "$REALITY_CONFIG_FILE"
    log_ok "已生成 $REALITY_CONFIG_FILE (VLESS-Reality :${port})"
}

# --- 客户端配置导出 -----------------------------------------------------------
print_client_config() {
    local ip=$1 port=$2 uuid=$3 sni=$4 pub_key=$5 short_id=$6
    local node_name
    node_name=$(get_node_name)

    print_rule
    echo -e "${C_BOLD}Clash / Mihomo 节点 (推荐 TUN 或代理模式使用)${C_NC}"
    print_rule
    cat <<EOF
- name: "${node_name}"
  type: vless
  server: ${ip}
  port: ${port}
  uuid: ${uuid}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${sni}
  reality-opts:
    public-key: ${pub_key}
    short-id: ${short_id}
  client-fingerprint: chrome
EOF

    print_rule
    echo -e "${C_BOLD}通用导入链接 (v2rayN / Shadowrocket / Sing-box / NekoBox)${C_NC}"
    print_rule
    local encoded_name
    encoded_name=$(printf '%s' "$node_name" | sed 's/ /%20/g')
    echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pub_key}&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=${sni}&sid=${short_id}#${encoded_name}"
    print_rule
    echo -e "${C_YELLOW}提示${C_NC}: 配置保存在 $REALITY_ENV_FILE，随时可用 cloud reality export 重新导出"
    echo -e "${C_YELLOW}提示${C_NC}: 请确保云服务商安全组已放行 TCP ${port} 端口"
}

# ==============================================================================
# Action 实现
# ==============================================================================

action_install() {
    check_root
    has_cmd docker || die "需要 Docker"
    docker compose version >/dev/null 2>&1 || die "需要 docker compose 插件"

    ensure_env

    local port uuid dest sni priv_key pub_key short_id

    port=$(reality_env_get REALITY_PORT "$DEFAULT_PORT")
    [ -n "$port" ] || { port="$DEFAULT_PORT"; reality_env_set REALITY_PORT "$port"; }

    dest=$(reality_env_get REALITY_DEST "$DEFAULT_DEST")
    [ -n "$dest" ] || { dest="$DEFAULT_DEST"; reality_env_set REALITY_DEST "$dest"; }

    sni=$(reality_env_get REALITY_SNI "$DEFAULT_SNI")
    [ -n "$sni" ] || { sni="$DEFAULT_SNI"; reality_env_set REALITY_SNI "$sni"; }

    uuid=$(reality_env_get REALITY_UUID "")
    if [ -z "$uuid" ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
        reality_env_set REALITY_UUID "$uuid"
        log_ok "已生成 UUID: $uuid"
    fi

    short_id=$(reality_env_get REALITY_SHORT_ID "")
    if [ -z "$short_id" ]; then
        short_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        reality_env_set REALITY_SHORT_ID "$short_id"
        log_ok "已生成 ShortID: $short_id"
    fi

    priv_key=$(reality_env_get REALITY_PRIVATE_KEY "")
    pub_key=$(reality_env_get REALITY_PUBLIC_KEY "")
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        log_step "生成 x25519 密钥对 ..."
        generate_keys
        priv_key="$REALITY_GEN_PRIV"
        pub_key="$REALITY_GEN_PUB"
        reality_env_set REALITY_PRIVATE_KEY "$priv_key"
        reality_env_set REALITY_PUBLIC_KEY  "$pub_key"
        log_ok "已生成 x25519 密钥对"
    fi

    generate_config "$port" "$uuid" "$dest" "$sni" "$priv_key" "$short_id"

    log_step "启动 xray-reality 容器 ..."
    reality_compose up -d
    log_ok "xray-reality 容器已启动 (VLESS-Reality :${port})"

    local ip
    ip=$(get_server_ip)
    echo ""
    print_client_config "$ip" "$port" "$uuid" "$sni" "$pub_key" "$short_id"
}

action_config() {
    check_root
    ensure_env

    _banner "VLESS-Reality 配置向导"

    local port dest sni uuid short_id priv_key pub_key

    port=$(prompt "服务端口 (默认: ${DEFAULT_PORT}): " "$(reality_env_get REALITY_PORT "$DEFAULT_PORT")")
    [ -n "$port" ] || port="$DEFAULT_PORT"

    dest=$(prompt "伪装目标 dest (默认: ${DEFAULT_DEST}): " "$(reality_env_get REALITY_DEST "$DEFAULT_DEST")")
    [ -n "$dest" ] || dest="$DEFAULT_DEST"

    sni=$(prompt "伪装域名 SNI (默认: ${DEFAULT_SNI}): " "$(reality_env_get REALITY_SNI "$DEFAULT_SNI")")
    [ -n "$sni" ] || sni="$DEFAULT_SNI"

    uuid=$(prompt "UUID (直接回车保留/生成): " "$(reality_env_get REALITY_UUID "")")
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

    short_id=$(reality_env_get REALITY_SHORT_ID "")
    [ -z "$short_id" ] && short_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')

    priv_key=$(reality_env_get REALITY_PRIVATE_KEY "")
    pub_key=$(reality_env_get REALITY_PUBLIC_KEY "")
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        log_step "生成 x25519 密钥对 ..."
        generate_keys
        priv_key="$REALITY_GEN_PRIV"
        pub_key="$REALITY_GEN_PUB"
    fi

    reality_env_set REALITY_PORT        "$port"
    reality_env_set REALITY_DEST        "$dest"
    reality_env_set REALITY_SNI         "$sni"
    reality_env_set REALITY_UUID        "$uuid"
    reality_env_set REALITY_SHORT_ID    "$short_id"
    reality_env_set REALITY_PRIVATE_KEY "$priv_key"
    reality_env_set REALITY_PUBLIC_KEY  "$pub_key"

    generate_config "$port" "$uuid" "$dest" "$sni" "$priv_key" "$short_id"

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$REALITY_CONTAINER"; then
        log_step "重启 xray-reality 容器 ..."
        reality_compose up -d --force-recreate
    else
        reality_compose up -d
    fi
    log_ok "xray-reality 容器已更新"

    local ip
    ip=$(get_server_ip)
    echo ""
    print_client_config "$ip" "$port" "$uuid" "$sni" "$pub_key" "$short_id"
}

action_resetpass() {
    check_root
    ensure_env

    local port dest sni uuid short_id priv_key pub_key
    port=$(reality_env_get REALITY_PORT "$DEFAULT_PORT")
    dest=$(reality_env_get REALITY_DEST "$DEFAULT_DEST")
    sni=$(reality_env_get REALITY_SNI "$DEFAULT_SNI")

    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
    short_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')

    log_step "重新生成 x25519 密钥对 ..."
    generate_keys
    priv_key="$REALITY_GEN_PRIV"
    pub_key="$REALITY_GEN_PUB"

    reality_env_set REALITY_UUID        "$uuid"
    reality_env_set REALITY_SHORT_ID    "$short_id"
    reality_env_set REALITY_PRIVATE_KEY "$priv_key"
    reality_env_set REALITY_PUBLIC_KEY  "$pub_key"

    log_ok "UUID 与 Key 已重置"

    generate_config "$port" "$uuid" "$dest" "$sni" "$priv_key" "$short_id"

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$REALITY_CONTAINER"; then
        log_step "重建 xray-reality 容器 ..."
        reality_compose up -d --force-recreate
    else
        reality_compose up -d
    fi
    log_ok "xray-reality 容器已更新"

    local ip
    ip=$(get_server_ip)
    echo ""
    print_client_config "$ip" "$port" "$uuid" "$sni" "$pub_key" "$short_id"
}

action_status() {
    print_rule
    echo -e "${C_BOLD}VLESS-Reality 状态${C_NC}"
    print_rule

    local port uuid dest sni pub_key short_id
    port=$(reality_env_get REALITY_PORT "$DEFAULT_PORT")
    uuid=$(reality_env_get REALITY_UUID '-')
    dest=$(reality_env_get REALITY_DEST "$DEFAULT_DEST")
    sni=$(reality_env_get REALITY_SNI "$DEFAULT_SNI")
    pub_key=$(reality_env_get REALITY_PUBLIC_KEY '-')
    short_id=$(reality_env_get REALITY_SHORT_ID '-')

    printf '  端口    : %s (TCP)\n' "$port"
    printf '  伪装 SNI: %s\n' "$sni"
    printf '  目标 dest: %s\n' "$dest"
    printf '  UUID    : %s\n' "$uuid"
    printf '  公钥    : %s\n' "$pub_key"
    printf '  ShortID : %s\n' "$short_id"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$REALITY_CONTAINER"; then
        echo -e "  容器    : ${C_GREEN}运行中${C_NC} ($REALITY_CONTAINER)"
    else
        echo -e "  容器    : ${C_RED}未运行${C_NC}"
    fi
    print_rule
}

action_export() {
    local port uuid sni pub_key short_id ip
    port=$(reality_env_get REALITY_PORT "$DEFAULT_PORT")
    uuid=$(reality_env_get REALITY_UUID "")
    sni=$(reality_env_get REALITY_SNI "$DEFAULT_SNI")
    pub_key=$(reality_env_get REALITY_PUBLIC_KEY "")
    short_id=$(reality_env_get REALITY_SHORT_ID "")

    [ -n "$uuid" ]    || die "尚未配置，请执行: cloud reality install"
    [ -n "$pub_key" ] || die "缺少公钥，请执行: cloud reality install"

    ip=$(get_server_ip)
    print_client_config "$ip" "$port" "$uuid" "$sni" "$pub_key" "$short_id"
}

action_log() {
    docker logs -f --tail 200 "$REALITY_CONTAINER"
}

action_update() {
    check_root
    ensure_env
    [ -f "$REALITY_CONFIG_FILE" ] || die "尚未配置，请执行: cloud reality install"

    log_step "更新 xray 镜像 ..."
    reality_compose pull
    reality_compose up -d --force-recreate
    log_ok "xray-reality 已更新并重启"
}

action_uninstall() {
    check_root
    local yes=${1:-}
    if [ "$yes" != "--yes" ]; then
        confirm "⚠️  确认卸载 VLESS-Reality 服务？(y/N)" "n" || { echo "已取消。"; exit 0; }
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$REALITY_CONTAINER"; then
        reality_compose down || true
    fi
    rm -f "$REALITY_CONFIG_FILE" "$REALITY_ENV_FILE"
    log_ok "VLESS-Reality 已卸载"
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
        resetpass|reset-pass|rotate) action_resetpass ;;
        status)     action_status ;;
        export)     action_export ;;
        log|logs)   action_log ;;
        update|upgrade) action_update ;;
        uninstall)  action_uninstall "$@" ;;
        help|-h|--help)
            echo "VLESS-Reality 管理: install | config | resetpass | status | export | log | update | uninstall"
            ;;
        *)
            log_err "未知 reality 子命令: $action"
            exit 1
            ;;
    esac
}

main "$@"
