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
