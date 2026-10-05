#!/bin/bash

# ==============================================================================
# cloud 一键安装 / 快速引导脚本
#
# 用法 (在终端直接执行任意一条):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh)"
#   sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh)"
# ==============================================================================

set -euo pipefail
export LANG=en_US.UTF-8

REPO_URL="${CLOUD_REPO_URL:-https://github.com/yimmr/cloudlab.git}"
DEFAULT_INSTALL_DIR="/opt/cloudlab"

# --- 权限检查 -----------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误: 必须使用 root 权限运行此脚本，例如:"
    echo "   sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh)\""
    exit 1
fi

# --- 终端输入接管（保障 curl | bash 管道交互）--------------------------------
if [ ! -t 0 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
fi

# --- 基础工具预检与自动安装 --------------------------------------------------
install_deps() {
    local missing=()
    command -v git  >/dev/null 2>&1 || missing+=(git)
    command -v curl >/dev/null 2>&1 || missing+=(curl)

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    echo "🚀 正在安装基础依赖 (${missing[*]})..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y -q >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${missing[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${missing[@]}" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "${missing[@]}" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${missing[@]}" >/dev/null 2>&1
    fi
}

install_deps

# --- 确定安装目录 -------------------------------------------------------------
# 若当前目录已存在项目关键文件，则在当前目录执行；否则克隆到 /opt/cloudlab
TARGET_DIR=""
if [ -f "./compose.yaml" ] && [ -f "./bin/setup" ]; then
    TARGET_DIR="$(pwd)"
elif [ -d "$DEFAULT_INSTALL_DIR" ] && [ -f "$DEFAULT_INSTALL_DIR/compose.yaml" ]; then
    TARGET_DIR="$DEFAULT_INSTALL_DIR"
    echo "📦 检测到已有安装目录: $TARGET_DIR，正在更新代码..."
    git -C "$TARGET_DIR" pull --ff-only 2>/dev/null || true
else
    TARGET_DIR="$DEFAULT_INSTALL_DIR"
    echo "📦 正在拉取 cloud 项目代码至 $TARGET_DIR ..."
    mkdir -p "$(dirname "$TARGET_DIR")"
    if [ -d "$TARGET_DIR" ]; then
        rm -rf "$TARGET_DIR"
    fi
    git clone --depth 1 "$REPO_URL" "$TARGET_DIR" || {
        echo "❌ 代码克隆失败，请检查网络或 GitHub 连通性。"
        exit 1
    }
fi

# --- 赋予执行权限并挂载全局命令 ----------------------------------------------
chmod +x "$TARGET_DIR"/bin/* 2>/dev/null || true
if [ -d "$TARGET_DIR/services/hy2" ]; then
    chmod +x "$TARGET_DIR/services/hy2/"*.sh 2>/dev/null || true
fi

ln -sf "$TARGET_DIR/bin/cloud" /usr/local/bin/cloud
ln -sf "$TARGET_DIR/bin/cloud" /usr/local/bin/cl

# --- 进入项目并启动 setup 向导 -----------------------------------------------
cd "$TARGET_DIR"
exec "$TARGET_DIR/bin/setup" "$@"
