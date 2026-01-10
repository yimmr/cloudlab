#!/bin/bash

export LANG=en_US.UTF-8

PROJECT_NAME='cloudlab'

set -euo pipefail

trap 'echo "发生错误。请检查上面的错误消息并重试。"; exit 1' ERR

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# 日志函数
log_step() {
    echo -e "${GREEN}⁘${NC} $1"
}

log_err() {
    echo -e "${RED}[ERR]  $(date '+%Y-%m-%d %H:%M:%S') $1${NC}" >&2
}

die() {
    log_err "$1"
    exit 1
}

# 用户输入提示函数
prompt() {
    local message=$1
    local default_value=$2
    local user_input
    read -e -p "$message" -i "$default_value" user_input
    echo "${user_input:-$default_value}"
}

# 动态包管理器
mypkm() {
    if command -v dnf &> /dev/null; then
        dnf "$@"
    elif command -v apt &> /dev/null; then
        apt "$@"
    elif command -v yum &> /dev/null; then
        yum "$@"
    else
        echo "没有可用包管理器"
        exit 1
    fi
}

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    die "必须使用 root 权限运行此脚本"
fi

echo -e "\033[36m(oﾟvﾟ)ノ\033[0m 欢迎使用一键安装脚本！"
echo -e "\033[36m(oﾟvﾟ)ノ\033[0m 根据下列每个提示\033[36m输入内容并回车\033[0m或\033[36m直接按回车跳过非必填\033[0m即可完成安装！"
echo -e "\033[36m(oﾟvﾟ)ノ\033[0m 当提示出现[y/n]时，请\033[36m输入y或n来选择是或否\033[0m！"
echo -e "\033[36m(oﾟvﾟ)ノ\033[0m 部分选项提供了默认值，确认无误后可直接按回车！"
echo -e "\033[36m(oﾟvﾟ)ノ\033[0m 安装启动成功后，密码仅在容器内，请手动保存客户端连接信息！"

if ! command -v docker &> /dev/null
then
    can_ins_docker=$(prompt "未安装Docker，是否安装？[y/n] : " "")
    if [ "$can_ins_docker" == "y" ]; then
        log_step "卸载所有Docker冲突的软件包 ..."
        packages=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null | cut -f1 | grep -v "^$" || true)
        if [ -n "$packages" ]; then
            apt remove -y $packages || true
        fi

        log_step "设置 Docker 的 apt 仓库 ..."
        # Add Docker's official GPG key:
        apt update -y
        apt install -y ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        # Add the repository to Apt sources:
        tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        apt update -y

        log_step "安装Docker和组件 ..."
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        if ! command -v docker &> /dev/null
        then
            log_step "安装Docker失败"
            exit 1
        fi

        systemctl start docker
        systemctl enable docker
    else
        log_step "请先安装Docker"
        exit 1
    fi
fi

if ! command -v git &> /dev/null
then
    log_step "正在安装Git"
    mypkm install -y git-all
fi

if ! command -v uuidgen &> /dev/null
then
    log_step "正在安装uuidgen"
    apt update -y && apt install -y uuid-runtime
fi


if [ -d "./$PROJECT_NAME" ]; then
    echo -e "当前目录下存在同名目录 \033[0;31m$PROJECT_NAME\033[0m ！如果是此项目，请删除后重试或进入该目录下执行此脚本，反之更换到其他目录执行脚本"
    exit 1
fi

# 确定脚本位置，如果空则可能是远程脚本
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$DIR" ]; then
    PROJECT_DIR="$(pwd)"
else
    PROJECT_DIR="$(dirname "$DIR")"
fi

log_step "开始部署项目..."

# 如果不在项目目录下则创建项目
if [[ "$(basename "$DIR")" != "bin" ]] && [[ ! -d "$PROJECT_DIR/.git" ]]; then
    git clone "https://github.com/yimmr/$PROJECT_NAME.git" $PROJECT_NAME
    cd "$PROJECT_NAME"
    PROJECT_DIR=$(pwd)
    DIR="$PROJECT_DIR/bin"
fi

cd $PROJECT_DIR

chmod +x bin/*

./bin/config