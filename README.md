# Emby 路径反代

按路径将请求转发到指定上游的轻量反向代理，面向 Emby / Jellyfin 等媒体服务场景，自带管理后台、访问控制、流量统计与实时连接监控。

```text
客户端  →  http://你的服务器:8520/https://emby.example.com:8096/web/index.html
              │
              ▼
         Emby Proxy（本服务）
              │  白名单 / 地区 / 限流 / UA
              ▼
         上游 Emby / 任意 HTTP(S) 服务
```

---

## 功能特性

| 类别           | 说明                                                     |
| -------------- | -------------------------------------------------------- |
| **路径反代**   | 访问格式 `/https://域名:端口/路径`，自动推断 http/https  |
| **域名白名单** | 支持根域名匹配；空列表表示不限制                         |
| **地区限制**   | 可选「仅中国大陆 IP」（本地 IP 库，不依赖外网）          |
| **黑名单**     | IP / CIDR；可选在地区拦截时自动封禁                      |
| **限流**       | 按 IP 每分钟请求上限                                     |
| **UA 白名单**  | 按关键字过滤客户端                                       |
| **图片缓存**   | 可选缓存上游 `/Images/` 小图（LRU，有容量上限）          |
| **CORS**       | 可选宽松跨域头，方便部分播放器                           |
| **管理后台**   | 概览、流量趋势、实时监控、拦截记录、网关设置             |
| **实时监控**   | WebSocket 推送活跃连接；单连接速率、相对时间、可主动断开 |
| **统计**       | 按日/时聚合请求与流量，IP / 地区 / 上游排行              |
| **安全**       | 管理端验证码登录、会话 Cookie；systemd 限制内存          |

时间相关展示与统计分桶统一为 **北京时间（Asia/Shanghai）**。

---

## 环境要求

- Linux（systemd）
- root 权限（安装服务）
- 出网（首次编译拉 Go 模块；可选）
- Go 1.20+（脚本可自动安装）

架构支持：`amd64` / `arm64` 等（与官方 Go 发行版一致）。

---
## 一键脚本安装
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/install.sh)
```

## 快速安装

```bash
# 下载安装脚本后
chmod +x install.sh
sudo bash install.sh
```

进入交互菜单，选择 **安装 / 重新安装**，按提示设置端口与管理密码。

非交互示例：

```bash
sudo bash install.sh install \
  --port 8520 \
  --admin-pass '你的强密码'
```

安装完成后访问：

```text
http://<服务器IP>:<端口>/admin/
```

默认用户名：`admin`（密码为安装时设置或自动生成的值）。

---

## 命令说明

| 命令                              | 说明                               |
| --------------------------------- | ---------------------------------- |
| `sudo bash install.sh` | 交互菜单（默认）                   |
| `… install`                       | 安装 / 重装                        |
| `… update`                        | 重新编译并替换程序（保留配置）     |
| `… uninstall`                     | 卸载（可加 `-y`、`--keep-config`） |
| `… status`                        | 查看 systemd 状态                  |
| `… start` / `stop` / `restart`    | 控制服务                           |

### install 常用参数

| 参数                  | 说明                                     |
| --------------------- | ---------------------------------------- |
| `--port <端口>`       | 监听端口（默认 `8520`）                  |
| `--admin-pass <密码>` | 管理密码                                 |
| `--admin-user <用户>` | 管理用户名（默认 `admin`）               |
| `--bin <路径>`        | 二进制安装路径                           |
| `--prebuilt <文件>`   | 使用已有二进制，跳过编译                 |
| `--force`             | 强制重新编译                             |
| `--code-only`         | 只更新程序，不重写 unit（`update` 使用） |

查看日志：

```bash
journalctl -u emby-proxy -f
```

---

## 使用方式

### 代理访问

在浏览器或播放器中把原来的上游地址改成「代理前缀 + 原 URL」：

```text
# 原地址
https://emby.example.com:8096/web/index.html

# 经本代理
http://<代理主机>:8520/https://emby.example.com:8096/web/index.html
```

也支持 `http://` 前缀；若省略协议，会按端口常见习惯推断（如 `8096` → http，`443` → https）。

### 管理后台

登录后包含：

1. **概览** — 请求量、流量、拦截、趋势与系统信息  
2. **流量与请求** — 分时/按日/按周/按月趋势，IP 与地区排行  
3. **实时监控** — 当前连接、上下行速率、累计流量；可断开进行中连接  
4. **拦截记录** — 地区 / 白名单拒绝明细  
5. **网关设置** — 端口、CORS、缓存、中国大陆限制、限流、UA/域名/IP 名单、改密、清空统计  

实时监控优先使用 **WebSocket**（`/admin/api/live/ws`），不可用时自动回退 HTTP 轮询。离开监控页会清空本页累计记录。

---

## 配置项说明

在后台「网关设置」保存，持久化到本地数据库。

| 配置              | 说明                      |
| ----------------- | ------------------------- |
| 监听端口          | 保存后尝试热切换监听      |
| CORS              | 缓解部分播放器跨域问题    |
| 缓存海报图片      | 缓存上游图片资源          |
| 仅允许中国大陆 IP | 非 CN（及本机/内网）拒绝  |
| 自动封禁异常 IP   | 地区拦截时写入黑名单      |
| 限流              | 次/分钟，`0` 关闭         |
| UA 白名单         | 每行一个关键字，空=不限制 |
| 域名白名单        | 每行一个域名，支持根域    |
| IP 黑名单         | 每行 IP 或 CIDR           |

---

## 目录与文件

| 路径                                     | 说明                                 |
| ---------------------------------------- | ------------------------------------ |
| `/usr/local/bin/emby-proxy`              | 服务二进制                           |
| `/etc/emby-proxy/emby.db`                | BoltDB（配置、统计、密码、geo 缓存） |
| `/etc/emby-proxy/build.sha256`           | 源码哈希，用于判断是否需重编译       |
| `/etc/systemd/system/emby-proxy.service` | systemd 单元                         |

服务环境变量（unit 内）：

- `GOGC=100`
- `GOMEMLIMIT=256MiB`（软内存上限，利于小内存 VPS）

---

## 反向代理（可选）

若前面还有 Nginx，且要使用管理端 WebSocket，需开启 Upgrade，例如：

```nginx
location / {
    proxy_pass http://127.0.0.1:8520;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400;
}
```

本服务仅在直连方为回环/私网时信任 `X-Forwarded-For` / `X-Real-IP`。

---

## 架构简述

```text
┌─────────────────────────────────────────────────────────┐
│  emby-proxy-install.sh                                  │
│    写出 main.go + admin.html → go build → systemd       │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│  emby-proxy                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │ 路径解析    │→ │ 访问控制 ACL │→ │ ReverseProxy   │  │
│  └─────────────┘  └──────────────┘  └────────────────┘  │
│         │                  │                  │         │
│         ▼                  ▼                  ▼         │
│   统计 channel      实时 liveConn        图片 LRU       │
│   按日落盘          WS 推送活跃连接                      │
│                                                         │
│  /admin/*  会话认证 + 嵌入式管理页 + REST/WS API        │
└─────────────────────────────────────────────────────────┘
```

- **ACL**：配置保存时预编译黑名单 CIDR 与 UA 关键字，降低请求热路径开销。  
- **统计**：异步写入，定期裁剪 Top-N，避免内存膨胀。  
- **监控**：WS 只推活跃连接；已结束记录由浏览器本页会话累计。

---

## 更新与卸载

```bash
# 更新到脚本内嵌的最新源码并重编译
sudo bash emby-proxy-install.sh update

# 卸载（删除服务、程序、配置与统计）
sudo bash emby-proxy-install.sh uninstall -y

# 卸载但保留配置目录
sudo bash emby-proxy-install.sh uninstall -y --keep-config
```

---

## 安全建议

1. 使用强管理密码，并仅在可信网络或经 HTTPS 反代后暴露管理端。  
2. 生产环境建议配置 **域名白名单**，避免开放任意上游代理。  
3. 按需开启 **中国大陆限制**、**限流** 与 **UA 白名单**。  
4. 不要把 systemd unit 中的明文密码提交到公开仓库；unit 权限为 `0600`。  
5. 若公网暴露，请配合防火墙或反代鉴权。

---

## 故障排查

| 现象               | 建议                                                         |
| ------------------ | ------------------------------------------------------------ |
| 服务起不来         | `journalctl -u emby-proxy -n 80 --no-pager`                  |
| 编译失败           | 设置 `GOPROXY=https://goproxy.cn,direct` 后重试 `update`     |
| 管理页打不开       | 检查端口监听、`systemctl status emby-proxy`                  |
| WebSocket 一直轮询 | 检查反代是否支持 `Upgrade`；看后台提示是否为「WebSocket · 实时」 |
| 地区判断不准       | 本机/内网显示为特殊码；公网依赖本地 IP 库                    |

---

## 许可证

请根据你的发布意向自行补充（例如 MIT / Apache-2.0 / 仅个人使用等）。

---

## 致谢

- [Go](https://go.dev/)
- [bbolt](https://github.com/etcd-io/bbolt)
- [iploc](https://github.com/phuslu/iploc)
- [gorilla/websocket](https://github.com/gorilla/websocket)
- [Chart.js](https://www.chartjs.org/)（管理页趋势图）
