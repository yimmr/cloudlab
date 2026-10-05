#!/bin/bash

# ==============================================================================
# cloud 通用函数库
# 该文件仅被 source，不单独执行
# ==============================================================================

# ------------------------------------------------------------------------------
# UI / 日志
# ------------------------------------------------------------------------------
# shellcheck disable=SC2034  # 颜色变量供 source 后的其他脚本使用
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_NC='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_NC=''
fi

_banner() { echo -e "${C_CYAN}(oﾟvﾟ)ノ${C_NC} $1"; }
log_step() { echo -e "${C_GREEN}⁘${C_NC} $1"; }
log_info() { echo -e "${C_BLUE}[INFO]${C_NC} $1"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $1" >&2; }
log_err()  { echo -e "${C_RED}[ERR ]${C_NC} $1" >&2; }
log_ok()   { echo -e "${C_GREEN}[ OK ]${C_NC} $1"; }

die() { log_err "$1"; exit 1; }

# 带默认值的交互式提问
# 交互环境下 read -i 已经将默认值填入行缓冲，若用户特意按退格键清空，则尊重清空结果
prompt() {
    local message=$1 default_value=${2:-} user_input
    if [ -t 0 ]; then
        read -e -r -p "$message" -i "$default_value" user_input
        echo "$user_input"
    else
        read -r user_input 2>/dev/null || true
        echo "${user_input:-$default_value}"
    fi
}

# 是/否确认（支持 y/yes/Y/YES）
confirm() {
    local message=$1 default=${2:-y} user_input
    read -e -r -p "$message" -i "$default" user_input
    user_input=${user_input:-$default}
    [[ "$user_input" =~ ^[Yy]([Ee][Ss])?$ ]]
}

print_rule() {
    printf "${C_CYAN}%s${C_NC}\n" "════════════════════════════════════════════════════════════"
}

# ------------------------------------------------------------------------------
# 系统检测
# ------------------------------------------------------------------------------
# 注意: 必须用 if 语句而非 `[ ... ] && die`——
# 后者在"当前已是 root"时函数返回 1，配合调用方的 set -e 会静默中断整个脚本
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "必须使用 root 权限运行此命令"
    fi
    return 0
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 跨发行版包管理器封装
pkm() {
    if   has_cmd apt-get; then apt-get "$@"
    elif has_cmd dnf;     then dnf "$@"
    elif has_cmd yum;     then yum "$@"
    elif has_cmd apk;     then apk "$@"
    elif has_cmd pacman;  then pacman "$@"
    else die "没有找到可用的包管理器 (apt/dnf/yum/apk/pacman)"
    fi
}

os_id() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# 安装系统包（自动适配发行版包名）
pkg_install() {
    local pkgs=()
    for p in "$@"; do pkgs+=("$p"); done
    case "$(os_id)" in
        debian|ubuntu) pkm install -y "${pkgs[@]}" ;;
        centos|rhel|rocky|almalinux|fedora) pkm install -y "${pkgs[@]}" ;;
        alpine) pkm add "${pkgs[@]}" ;;
        arch) pkm -Sy --needed --noconfirm "${pkgs[@]}" ;;
        *)   pkm install -y "${pkgs[@]}" ;;
    esac
}

# 默认出口网卡名（修复历史脚本中 $INTERFACE 未定义的问题）
get_default_interface() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' \
        || ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}'
}

# 端口是否被监听（精准匹配端口，避免误判 IP 末尾数字）
port_in_use() {
    local port=$1
    if has_cmd ss; then
        ss -tulnH "( sport = :${port} )" 2>/dev/null | grep -q . \
            || ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    else
        netstat -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    fi
}

# ------------------------------------------------------------------------------
# .env 安全读写（替换脆弱的 sed 覆写方案）
# ------------------------------------------------------------------------------
# 从 .env 文件读取变量
env_get() {
    local file=$1 key=$2 default=${3:-}
    [[ -f "$file" ]] || { echo "$default"; return; }
    local line value
    line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n 1) || true
    if [[ -z "$line" ]]; then echo "$default"; return; fi
    value=${line#*=}
    # 去除首尾空白
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    # 处理成对引号或剥离行尾注释
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value=${value#\"}; value=${value%\"}
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value=${value#\'}; value=${value%\'}
    else
        # 未被引号完全包裹的值，剥离 # 后的行尾注释
        value=$(printf '%s' "$value" | sed -e 's/[[:space:]]*#.*$//')
    fi
    printf '%s' "$value"
}

# 写入 .env 变量：变量已存在则原地替换，否则追加；保留注释与顺序
env_set() {
    local file=$1 key=$2 value=${3:-}
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || : > "$file"

    # value 中的换行与 sed 分隔符做转义
    local escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')

    if grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${escaped}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# 加载 .env 到当前 shell（不覆盖已存在的变量）
load_env() {
    local file=$1
    [[ -f "$file" ]] || return 0
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
}

# ------------------------------------------------------------------------------
# 随机与节点命名
# ------------------------------------------------------------------------------
generate_password() {
    # uuidgen 不一定存在，兜底使用 /proc/sys/kernel/random/uuid
    if has_cmd uuidgen; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16
    fi
}

declare -A NodeIconMap=(
    ["cn"]='🇨🇳' ["hk"]='🇭🇰' ["sg"]='🇸🇬' ["us"]='🇺🇸' ["jp"]='🇯🇵'
    ["kr"]='🇰🇷' ["gb"]='🇬🇧' ["fr"]='🇫🇷' ["de"]='🇩🇪' ["ie"]='🇮🇪'
    ["ca"]='🇨🇦' ["in"]='🇮🇳' ["au"]='🇦🇺' ["ru"]='🇷🇺' ["br"]='🇧🇷'
)

# example.com -> Example; hk-node -> HkNode
to_pascal_case() {
    local input=$1 output="" part
    local IFS='.-_'
    read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        [ -z "$part" ] && continue
        local first="${part:0:1}"
        local rest="${part:1}"
        output+="${first^^}${rest,,}"
    done
    printf '%s' "$output"
}

# a.b.example.com -> AB; example.com -> Example
domain_to_agent_name() {
    local domain=$1
    local IFS='.'
    read -ra parts <<< "$domain"
    local n=${#parts[@]}
    if [ "$n" -ge 3 ]; then
        local sub=""
        for ((i=0; i<n-2; i++)); do
            sub+="${parts[i]}."
        done
        to_pascal_case "${sub%.}"
    elif [ "$n" -eq 2 ]; then
        to_pascal_case "${parts[0]}"
    else
        to_pascal_case "$domain"
    fi
}

# 节点名 + 国旗图标（精确识别，防止 internal->印度、auth->澳洲 等前缀误判）
domain_to_agent_name_with_icon() {
    local domain=$1
    local name icon=""
    name=$(domain_to_agent_name "$domain")

    # 提取首个子域名分词 (如 hk-01 -> hk; us.node -> us)
    local token
    token=$(printf '%s' "$domain" | awk -F'[._-]' '{print tolower($1)}')

    if [ -n "${NodeIconMap[$token]:-}" ]; then
        icon="${NodeIconMap[$token]} "
    else
        local prefix2="${name:0:2}"
        prefix2="${prefix2,,}"
        if [ -n "${NodeIconMap[$prefix2]:-}" ]; then
            local remainder="${name:2}"
            if [ -z "$remainder" ] || [[ "$remainder" =~ ^[0-9] ]]; then
                icon="${NodeIconMap[$prefix2]} "
            fi
        fi
    fi
    printf '%s' "${icon}${name}"
}

# ------------------------------------------------------------------------------
# systemd
# ------------------------------------------------------------------------------
restart_service() {
    local name=$1
    if has_cmd systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^${name}"; then
        systemctl restart "$name"
    else
        log_err "未找到 systemd 服务: $name"
        return 1
    fi
}

service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 证书
# ------------------------------------------------------------------------------
# 输出证书剩余有效天数；无法解析时返回非 0
cert_days_left() {
    local crt=$1
    [ -f "$crt" ] || return 1
    has_cmd openssl || return 1
    local end exp
    end=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2) || true
    [ -n "$end" ] || return 1
    exp=$(date -d "$end" +%s 2>/dev/null) || return 1
    echo $(( (exp - $(date +%s)) / 86400 ))
}

# 按剩余天数着色输出
cert_color() {
    local days=$1
    if   [ "$days" -lt 15 ]; then echo "$C_RED"
    elif [ "$days" -lt 30 ]; then echo "$C_YELLOW"
    else echo "$C_GREEN"; fi
}