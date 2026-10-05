#!/bin/bash

# ==============================================================================
# Hysteria 2 内核 / 网络调优
#   面向 QUIC(UDP) 传输，启用 BBR + fq，放大 UDP 缓冲区，降低丢包与抖动
#   针对 Clash TUN 模式强化：放大 conntrack 连接跟踪表、缩短 UDP 连接超时、
#   放宽本地端口范围、避免端口跳跃与高并发下断流
#   幂等：可重复执行
# ==============================================================================

set -euo pipefail

[[ "$(id -u)" -ne 0 ]] && { echo "❌ 请使用 root 权限运行"; exit 1; }

SYSCTL_FILE=/etc/sysctl.d/99-hy2-optimize.conf
LIMITS_FILE=/etc/security/limits.d/99-hy2-limits.conf
NOFILE=1048576
NPROC=512000

log_step() { echo -e "🚀 $1"; }
log_ok()   { echo -e "✅ $1"; }

# 提前尝试加载内核模块（若系统支持）
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# 根据系统物理内存动态评估 conntrack 最大值，防止 1GB 以下 VPS 发生内核 OOM
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 1048576)
if [ "$MEM_TOTAL_KB" -ge 2097152 ]; then
    CONNTRACK_MAX=524288
else
    CONNTRACK_MAX=262144
fi

log_step "写入内核参数 -> $SYSCTL_FILE (Conntrack Max: $CONNTRACK_MAX)"
cat > "$SYSCTL_FILE" <<EOF
# ---------- UDP / QUIC 缓冲区 (面向高吞吐与高延迟链路) ----------
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.optmem_max = 2097152
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# ---------- 队列与高并发 (应对 Clash TUN 模式并发连接) ----------
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 65535
# 预留 50000 以下端口（避开 20000~50000 端口跳跃范围与常用服务监听端口），避免出向连接与跳跃规则冲突
net.ipv4.ip_local_port_range = 50001 65535

# ---------- 连接跟踪表防打爆 (针对 TUN 模式高频 UDP & 端口跳跃) ----------
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_udp_timeout = 10
net.netfilter.nf_conntrack_udp_timeout_stream = 30

# ---------- 拥塞控制 ----------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---------- 转发与句柄 ----------
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
# 关键防御：开启 IPv6 转发时必须显式接受 RA 通告，防止 VPS 丢失 IPv6 默认路由断网
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
fs.file-max = 2097152

# ---------- 缓解 SSH 卡顿 / 断流 ----------
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

# ---------- 降低延迟 ----------
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_tw_reuse = 1
EOF

log_step "写入系统句柄限制 -> $LIMITS_FILE"
cat > "$LIMITS_FILE" <<EOF
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
* soft nproc $NPROC
* hard nproc $NPROC
root soft nproc $NPROC
root hard nproc $NPROC
EOF

# systemd 全局默认限制（覆盖注释行或已有行，不存在则追加）
if [ -f /etc/systemd/system.conf ]; then
    if grep -qE "^#?DefaultLimitNOFILE=" /etc/systemd/system.conf 2>/dev/null; then
        sed -i "s/^#\?DefaultLimitNOFILE=.*/DefaultLimitNOFILE=$NOFILE/" /etc/systemd/system.conf 2>/dev/null || true
    else
        echo "DefaultLimitNOFILE=$NOFILE" >> /etc/systemd/system.conf
    fi
fi

# 调整 conntrack 哈希桶大小
if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
    echo $((CONNTRACK_MAX / 4)) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
fi

log_step "应用内核参数"
sysctl --system >/dev/null 2>&1 || true
sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true

# 确保所有现有网卡运行时立即接受 RA，防止等待重启期间 IPv6 默认路由失效
for ra_file in /proc/sys/net/ipv6/conf/*/accept_ra; do
    [ -w "$ra_file" ] && echo 2 > "$ra_file" 2>/dev/null || true
done

log_ok "优化完成：BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?') qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"

cat <<'EOF'

⚠️ 请务必重启服务器 (reboot) 以确保 limits 与 systemd 限制全局生效。
   重启后执行 `cloud status` (或 `cl status`) 确认服务正常。
EOF
