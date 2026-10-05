# cloud

服务器基础设施底座 + Hysteria 2 节点服务。

**设计原则**：基础设施（Platform）与扩展服务（Service）解耦但同仓。
底座可以独立运行（纯反向代理 / 数据库），`services/` 下的扩展服务按需启用。

---

## 目录结构

```text
cloud/
├── bin/                  # 扁平命令行
│   ├── cloud             #   统一管理入口（可挂载到 /usr/local/bin，支持短别名 cl）
│   ├── setup             #   新机初始化装配器
│   └── utils.sh          #   共享函数库（仅被 source）
│
├── infra/                # 底座持久化数据
│   ├── caddy/data/       #   Caddy 证书与配置（hy2 从这里取证书）
│   ├── caddy/config/
│   └── dbdata/           #   数据库数据
│
├── sites/
│   └── default/          # 默认 / 伪装站点源码
│
├── services/             # 扩展服务（与底座解耦）
│   └── hy2/              #   Hysteria 2 自治模块
│
├── compose.yaml          # 底座编排（不含任何扩展服务痕迹）
└── .env.example          # 环境变量模板
```

---

## 快速开始

### 方式一：一键远程安装（推荐，全新 VPS 即开即用）

在全新 Linux 服务器（Ubuntu / Debian / CentOS 等）终端直接运行任意一条命令：

```bash
# 推荐（使用 curl）:
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh)"

# 或使用 wget:
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/yimmr/cloudlab/main/bin/install.sh)"
```

脚本将自动完成：拉取依赖 → 克隆至 `/opt/cloudlab` → 挂载全局命令 → 启动交互配置向导。

### 方式二：手动克隆安装

```bash
git clone https://github.com/yimmr/cloudlab.git /opt/cloudlab && cd /opt/cloudlab
sudo ./bin/setup
```

`setup` 会依次完成：环境安全检查 → 依赖检查 → Docker 安装 → 全局命令挂载 → 底座配置与启动 → 询问是否安装 hy2。

> **防污染机制**：`setup` 内置 WSL / 开发机检测，如果误在非生产服务器上运行会主动告警并提供安全退出机制，避免意外污染本地开发环境。

完成后即可在**任意目录**直接使用（同时支持 `cloud` 与 2 字符短别名 `cl`）：

```bash
cloud status       # 整体状态（或简写: cl status）
cloud hy2 export   # 导出客户端节点配置（或简写: cl hy2 export）
```

---

## 命令速查

> 💡 以下所有 `cloud` 命令均可直接用短命令 **`cl`** 代替，如 `cl status`、`cl up`。

### 生命周期

| 命令 | 说明 |
| --- | --- |
| `cloud setup` | 新机初始化（环境检测 / 依赖 / Docker / 全局命令 / 底座 / 可选 hy2） |
| `cloud clean` | 下线服务并清空数据与配置（保留仓库代码，带二次确认） |
| `cloud unlink` | 仅移除 `/usr/local/bin` 下的全局命令软链（`cloud` / `cl`） |

### 底座基础设施

| 命令 | 说明 |
| --- | --- |
| `cloud up` / `down` / `restart` | 管理 Caddy 网关与数据库 |
| `cloud status` | 容器状态、端口、证书有效期、hy2 状态 |
| `cloud ps` | 容器列表 |
| `cloud logs [caddy\|db]` | 跟踪日志 |

### 更新

| 命令 | 说明 |
| --- | --- |
| `cloud update` | 查看更新说明 |
| `cloud update infra` | 仅更新 Caddy / MariaDB 镜像（**无变动则零重启**） |
| `cloud update hy2` | 仅更新 Hysteria 2 二进制（恢复加固配置并重启） |
| `cloud update all` | 依次更新两者 |
| `cloud update infra --dry-run` | 只拉取并报告，不重建容器 |

### Hysteria 2

| 命令 | 说明 |
| --- | --- |
| `cloud hy2 install` | 安装二进制 + 注册 systemd 服务 |
| `cloud hy2 config` | 交互式配置（域名 / 密码 / 端口 / 带宽 / 跳跃范围） |
| `cloud hy2 start\|stop\|restart` | 服务控制 |
| `cloud hy2 status` | 运行状态 + 端口跳跃规则 |
| `cloud hy2 log` / `debug` | 实时日志 / 前台 debug 排查 |
| `cloud hy2 export` | 输出 Clash 片段 + `hy2://` 导入链接 |
| `cloud hy2 sync-cert` | 立即同步 Caddy 证书并重启应用 |
| `cloud hy2 clear-hop` | 清理 iptables 端口跳跃规则 |
| `cloud hy2 update` | 更新 hy2 二进制（恢复加固版 unit 并重启） |
| `cloud hy2 bbr` | 应用内核 / ulimit 优化 |
| `cloud hy2 uninstall` | 干净卸载并清理 iptables 规则 |

---

## 新增网站

在同级目录建 `sites/<name>/compose.yaml`，容器加入 `web_gateway` 网络即可被 Caddy 自动发现并配置代理：

```yaml
services:
  web:
    image: nginx:alpine
    restart: unless-stopped
    env_file: ../.env
    volumes:
      - ./web:/usr/share/nginx/html
    labels:
      caddy: demo.example.com
      caddy.reverse_proxy: '{{upstreams 80}}'
    networks:
      - external_net
networks:
  external_net:
    name: ${NETWORK_ID:-web_gateway}
    external: true
```

启动该站点的 compose 后，直接访问 `demo.example.com` 即可，无需手工改 Caddy 配置。

---

## 关键设计说明

### 1. hy2 证书如何拿到

Caddy 容器把 `./infra/caddy/data` 挂载到 `/data`，证书落在
`infra/caddy/data/caddy/certificates/<CA目录>/<域名>/`。
`cloud hy2` 通过**递归检索**获取 `.crt` / `.key`，因此**不依赖具体 CA**
（Let's Encrypt / ZeroSSL 均可命中），并同步到 `/etc/hysteria/certs/` 后热载服务。

`infra/caddy/data` 目录权限为 `drwx------ root root`（容器以 root 运行），
同步逻辑以 root 执行 `install -m 644/600` 保证 hy2 非 root 用户可读。

### 2. 证书自动续期

安装 hy2 时会写入 `/etc/cron.daily/cloud-hy2-sync`，
每天执行一次 `cloud hy2 sync-cert`：比对证书 md5，有变化才自动重启 hy2 生效。
开销约几毫秒，是所有方案里最轻的做法（无需常驻进程或 inotify 句柄）。

### 3. 端口跳跃

`iptables -t nat` PREROUTING 规则按 `hysteria2-<port>` 注释标记，
配置时先清理旧规则再写入，规则数不会累积；留空或执行 `cloud hy2 clear-hop` 即可一键彻底清理。
配置后通过 `netfilter-persistent`（缺失则 `iptables-save`）持久化。

### 4. 443 端口分配

| 协议 | 端口 |
| --- | --- |
| HTTP | TCP 80 —— Caddy（ACME 校验 + 伪装站） |
| HTTPS | TCP 443 —— Caddy |
| Hysteria 2 | UDP 443 —— 宿主机原生服务 |

TCP 与 UDP 端口空间独立，故 hy2 使用 UDP 443 不会与 Caddy 冲突。

### 5. 伪装站设计：原生静态文件伪装

hy2 采用原生文件伪装（`type: file`），在配置时自动将伪装站点源码同步至 `/etc/hysteria/web`。
相较于反代宿主机 `http://127.0.0.1:80`，该设计具有核心优势：
* **彻底杜绝 308 死循环**：Caddy 默认开启 Automatic HTTPS 会对 80 端口实施 `308 Permanent Redirect`。如果 hy2 反向代理 80 端口，会导致 HTTP/3 探针收到指向自身的重定向死循环；
* **TCP 与 UDP 行为一致**：UDP 443 原生返回 200 OK 与完整的 HTTP/3 静态网页响应，与 TCP 443 完全对齐；
* **零跨进程与网络往返损耗**。

### 6. 关于自动更新

**Docker Compose 没有内建自动更新能力**：

- `docker compose up -d` 只在本地缺镜像时才拉取，**不会自动升级已存在的镜像**；
- 只有 Swarm 模式（`docker stack deploy --update-config`）才支持滚动自动更新；
- 官方推荐的替代方案是自行编排 `pull` + `up -d`。

所以本项目用 `cloud update` 封装等价流程，并额外做了两件事：

1. **镜像 ID 比对**：拉取后对比容器运行中的镜像 ID，无变化则**完全不重启**，
   避免每次检查都打断网关与数据库；
2. **`--dry-run` 只报告不落地**，便于先看有哪些更新。

若确实需要全自动，可额外部署第三方 [Watchtower](https://github.com/containrrr/watchtower)，
但它无法自定义更新前后钩子，也无法做「无更新则不重启」的判断，不建议用在生产反代上。

### 7. 网关网络的 shared 网络告警

若先启动了站点 compose（其中把 `web_gateway` 声明为 `external: true`），
底座 compose 再启动时会输出：

```text
a network with name web_gateway exists but was not created for project "cloud".
Set `external: true` to use an existing network
```

这是共享网关网络模式的**正常现象**：底座负责首次创建该网络，站点侧以 `external`
方式接入。谁先创建谁持有 label，因此后启动的一方必然出现这条告警，可以忽略。

### 8. 针对 Clash TUN 模式与网络极速调优

针对将本项目作为 Clash 全局 TUN 模式服务端的场景，进行了针对性网络强化：

1. **彻底解除服务端全局带宽限制**：
   * 原生 Hysteria 2 中，服务端 `bandwidth.up` 限制的是服务器总上传速度（即客户端的实际下载速度）。若误把客户端上行写入服务端，会导致客户端下载被死死压制。
   * 本项目将服务端 `bandwidth` 彻底留空，让服务器千兆出口全开；速率控制仅在客户端配置中声明，由 Brutal 拥塞控制根据单连接协商发挥最大威力。
2. **QUIC 大滑动窗口注入**：
   * 默认 quic-go 接收窗口较小，高延迟跨境链路（高 BDP）下单线程下载易遇瓶颈。
   * 服务端注入 `initStreamReceiveWindow: 8MB`、`maxStreamReceiveWindow: 32MB`、`initConnReceiveWindow: 32MB` 以及 `maxConnReceiveWindow: 128MB`，专为 TUN 模式下多并发连接设计。
3. **内核 Conntrack 防打爆机制与防 OOM 防护**：
   * Clash TUN 模式下，系统所有的 DNS、高频 UDP 短连接均走隧道，配合 20000~50000 端口跳跃极易占满内核连接跟踪表。
   * `cloud hy2 bbr` 会根据系统物理内存动态评估放大 `nf_conntrack_max`（26万~52万并发），并将 UDP conntrack 超时由数百秒压缩至 10~30 秒，彻底杜绝 TUN 模式突发断流，并防止小内存 VPS 发生内核 OOM。
   * 开启 IPv6 转发时同步注入 `accept_ra = 2`，杜绝 VPS 因 RA 通告失效导致 IPv6 断网。
4. **客户端导出即开即用**：
   * `cloud hy2 export` 导出的 Clash Meta (Mihomo) 片段显式包含 `hop-interval: 30` 与 `alpn: [h3]`，无需手动修改任何参数即可完美接入。

---

## 注意事项

1. 域名需已解析到本机公网 IP，且云安全组放行 TCP 80/443、UDP 443 与跳跃端口范围。
2. 数据库默认开启 `MARIADB_ALLOW_EMPTY_PASSWORD=yes`，支持使用空密码快速初始化与连接；如需高安全隔离，可在 `.env` 中指定强密码。
3. hy2 客户端带宽（`up` / `down`）不要填满，实际宽带即可，脚本按 `×0.9` 写入，
   避免触发运营商 QoS 处罚。
4. 执行过 `cloud hy2 bbr` 后建议重启服务器，使 ulimit 与 systemd 限制全局生效。
5. `.env` 含域名与配置信息，已被 `.gitignore` 排除，勿提交。
