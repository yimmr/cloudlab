#!/bin/bash

# ==============================================================================
# cloud 一键安装 / 快速引导脚本入口
# ==============================================================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DIR/bin/install.sh" ]; then
    exec bash "$DIR/bin/install.sh" "$@"
fi

# 若作为独立 raw 脚本被远程运行，拉取 bin/install.sh 并执行
exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh 2>/dev/null || wget -qO- https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh)" bash "$@"
