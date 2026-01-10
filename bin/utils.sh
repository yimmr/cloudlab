#!/bin/bash

# 节点图标
declare -A NodeIconMap=(
  ["cn"]='🇨🇳'
  ["hk"]='🇭🇰'
  ["sg"]='🇸🇬'
  ["us"]='🇺🇸'
  ["jp"]='🇯🇵'
  ["kr"]='🇰🇷'
  ["gb"]='🇬🇧'
  ["fr"]='🇫🇷'
  ["de"]='🇩🇪'
  ["ie"]='🇮🇪'
  ["ca"]='🇨🇦'
  ["in"]='🇮🇳'
)

domain_to_agent_name_with_icon(){
    local icon=""
    local name=$(domain_to_agent_name "$@")
    for key in "${!NodeIconMap[@]}"; do
        if [[ "${name,,}" == "${key,,}"* ]]; then
            name="${NodeIconMap[$key]}${name}"
            break
        fi
    done
    echo "$name"
}

domain_to_agent_name() {
    local domain="$1"
    local subdomain=""
    local main_domain=""
    if [[ "$domain" =~ ^([^.]+)\.([^.]+\.[^.]+)$ ]]; then
        subdomain="${BASH_REMATCH[1]}"
        main_domain="${BASH_REMATCH[2]}"
    elif [[ "$domain" =~ ^([^.]+\.[^.]+)$ ]]; then
        main_domain="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$subdomain" ]]; then
        to_pascal_case "$subdomain"
    else
        to_pascal_case "${main_domain%.*}"
    fi
}

to_pascal_case() {
    local input="$1"
    local output=""
    local IFS='.'
    read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        output+=$(echo "${part:0:1}" | tr '[:lower:]' '[:upper:]')
        output+=$(echo "${part:1}" | tr '[:upper:]' '[:lower:]')
    done
    echo "$output"
}

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 日志函数 (类似 log.Println) ---
log_step() {
    echo -e "${GREEN}⁘${NC} $1"
}

log_info() {
    echo -e "${GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1${NC}"
}

log_err() {
    echo -e "${RED}[ERR]  $(date '+%Y-%m-%d %H:%M:%S') $1${NC}" >&2
}

die() {
    log_err "$1"
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        die "必须使用 root 权限运行此脚本"
    fi
}

load_env() {
    local env_file="$1"
    if [ -f "$env_file" ]; then
        # 自动 export 变量
        set -a
        source "$env_file"
        set +a
    else
        log_warn "未找到 .env 文件，将使用默认值或环境变量"
    fi
}

# 动态管理器
mypkm() {
    if command -v dnf &> /dev/null; then
        dnf $@
    elif command -v apt &> /dev/null; then
        apt $@
    elif command -v yum &> /dev/null; then
        yum $@
    else
        echo "没有可用包管理器"
        exit 1
    fi
}

generate_password() {
    # openssl rand -base64 12
    uuidgen
}

generate_ws_path(){
   echo "/wsol-$(shuf -i 10000-99999 -n 1)"
}

prompt() {
    local message=$1
    local default_value=$2
    local user_input
    read -e -p "$message" -i "$default_value" user_input
    echo "${user_input:-$default_value}"
}