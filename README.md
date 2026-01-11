## 目录结构

- bin 自定义命令
- caddy caddy 相关文件
- dbdata 数据库挂载卷
- site 默认网站目录
- .env 公共环境变量，减少重复写
- compose.yaml 公共服务（caddy、数据库等）

新增网站的方法是：

- 新建目录如 `site2`
- 目录下创建 `compose.yaml` 配置独立容器（启动服务后，代理自动发现并配置好，直接访问即可）

```yaml
# 配置参考
services:
  web:
    image: nginx:alpine
    restart: unless-stopped
    env_file: ./../.env
    volumes:
      - ./web:/usr/share/nginx/html
    labels:
      caddy: demo.localhost
      caddy.reverse_proxy: '{{upstreams 80}}'
    networks:
      - external_net
networks:
  external_net:
    name: ${NETWORK_ID:-web_gateway}
    external: true
```

## 简易脚本

项目的 `bin` 目录的脚本如下：

- log_conf 查看 `hy2` 配置报错信息
- log_hy2 查看 `hy2` 运行日志
- bbr 一键网络线路优化
- clean 下线容器、暂停服务，清理数据，不删除软件，以便重新生成配置
- config 安装后可以重写配置，并重启服务
- restart 重启服务

## 优化

- 1. 脚本会同时配置 BBR 优化，安装完成后，建议重启服务器以确保所有配置（尤其是 ULIMIT）全局生效。
- 2. Hysteria2 客户端配置时，务必设置一个合理的上传 `up_mbps` 和 下载 `down_mbps`。
  - 带宽如果填得过大，会导致严重的运营商丢包处罚 (QoS)。
  - 安装时输入实际宽带即可，最终配置是上行/下行分别乘以 `0.9` 的结果
- 3. 强烈建议配合 `Port Hopping` (端口跳跃) 使用。

## 项目状况

- docker 安装 `hy2` 时网络比较慢，多端口无法使用（未解决暂不考虑）
