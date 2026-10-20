# Emby Proxy

一个用于 Emby 的**路径反代**服务：把目标服务器的地址塞进 URL 路径里，由本机统一转发，客户端只需要填一个地址。

- 单文件安装脚本，自动装 Go、自动编译成静态二进制
- 纯 Go 实现，无 Nginx / 无运行时依赖
- 内置管理后台：白名单、大陆 IP 限制、流量与拦截统计、IP 归属地
- 支持 WebSocket 与流媒体 Range 透传

## 目录

- [快速开始](#快速开始)
- [怎么用](#怎么用)
- [命令说明](#命令说明)
- [管理后台](#管理后台)
- [配置文件](#配置文件)
- [数据文件](#数据文件)
- [常见问题](#常见问题)
- [从源码构建](#从源码构建)
- [免责声明](#免责声明)

## 快速开始

环境要求：Linux + systemd，root 权限，首次编译需要能访问网络（或本机已装 Go / 用 `--prebuilt` 跳过编译）。

```bash
# 运行脚本
bash <(curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/install.sh)
```

如果需要配合Nginx使用域名，可以使用这个脚本安装Nginx管理，仓库地址：https://github.com/SunMoonWithYou/nginx_manage
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/nginx_manage/main/install.sh)
```

安装过程会询问：

```
   监听端口 [8520]: 18973
   管理密码 [留空 = 自动生成]: pw456
```

- 端口直接回车 = 用默认 / 当前端口
- 密码直接回车 = 自动生成随机密码（已装过则沿用原密码）

装完后：

```
   管理页   http://服务器IP:18973/admin/
   用户名   admin
   密  码   pw456
```

也可以直接带参数安装：

```bash
sudo ./emby-proxy.sh install --port 8520 --admin-pass mypass
```

## 怎么用

把原地址塞进路径里：

```
原:  https://www.example.com/emby/Users
改:  http://服务器IP:8520/https://www.example.com/emby/Users
```

客户端（Emby 客户端 / 网页 / 播放器）里就填这一长串地址，反代负责转发到真实服务器。

容错写法：少写一条斜杠（`/https:/host/...`）、重复写 scheme（`/https:/https://host/...`）都能正确解析。

## 命令说明

不带参数运行会进入交互菜单：

```bash
sudo ./emby-proxy.sh
```

| 菜单          | 说明                        |
| ----------- | ------------------------- |
| 1 安装 / 重新安装 | 询问端口与密码后完整装一遍，配置、白名单、统计保留 |
| 2 更新代码      | 只替换程序二进制，配置、密码、统计不动       |
| 3 卸载        | 停止服务并删除程序、配置、密码、统计（不可恢复）  |
| 4 运行状态      | 查看 systemd 状态             |
| 5 查看日志      | 查看最近 60 行日志               |
| 0 退出        | 退出菜单                      |

也支持直接子命令：

```bash
sudo ./emby-proxy.sh install                        # 安装（交互询问端口/密码）
sudo ./emby-proxy.sh install --port 9000 --admin-pass xxx
sudo ./emby-proxy.sh update                         # 只更新代码
sudo ./emby-proxy.sh uninstall                      # 彻底卸载（含数据）
sudo ./emby-proxy.sh uninstall --keep-config        # 卸载但保留配置
sudo ./emby-proxy.sh status | start | stop | restart
```

`install` / `update` 其它选项：

| 选项                | 说明                                    |
| ----------------- | ------------------------------------- |
| `--port N`        | 监听端口（默认 8520）                         |
| `--bin PATH`      | 二进制路径（默认 `/usr/local/bin/emby-proxy`） |
| `--admin-user U`  | 管理页用户名（默认 admin）                      |
| `--admin-pass P`  | 管理页密码（默认随机）                           |
| `--prebuilt FILE` | 使用已有二进制，跳过 Go 安装与编译                   |
| `--force`         | 强制重新编译                                |

## 管理后台

地址：`http://服务器IP:端口/admin/`，支持电脑与手机。

- **概览**：今日 / 累计请求与流量、拦截数、独立 IP
- **流量**：IP 分布、地区分布（国旗 + 中文名），支持「全部 / 今天 / 近 7 天 / 近 30 天 / 日历」时间筛选
- **记录**：拦截记录，分页、按日期筛选、点开看完整详情（含 UA 与原因）
- **设置**：
  - 监听端口（保存即生效，无需重启，失败自动回滚）
  - 访问控制：目标域名白名单、仅允许中国大陆 IP
  - 未知 IP 在线查询（离线库查不到时用第三方接口兜底，带缓存）
  - 重新识别历史 IP

## 配置文件

配置文件位于 `/etc/emby-proxy/config.json`：

```json
{
  "port": 0,
  "china_only": false,
  "whitelist": [],
  "geo_api": true,
  "geo_api_url": ""
}
```

| 字段            | 说明                               |
| ------------- | -------------------------------- |
| `port`        | 监听端口，`0` 表示用启动参数                 |
| `china_only`  | 仅允许中国大陆 IP 访问（本机 / 内网不受限）        |
| `whitelist`   | 目标域名白名单，留空 = 不限制，支持根域名匹配         |
| `geo_api`     | 离线库查不到 IP 归属地时用在线接口兜底            |
| `geo_api_url` | 归属地接口，用 `{ip}` 占位，留空用 ip-api.com |

白名单里的目标地址在页面默认打码显示，点「编辑白名单」可看明文。

## 数据文件

全部存放在 `/etc/emby-proxy/`：

| 文件               | 说明                       |
| ---------------- | ------------------------ |
| `config.json`    | 配置                       |
| `admin.pass`     | 管理密码                     |
| `stats.json`     | 请求、流量、拦截与按天统计数据          |
| `geo_cache.json` | IP 归属地缓存                 |
| `flags/`         | 国旗图片缓存                   |
| `build.sha256`   | 当前已编译源码的校验值（用于判断是否需要重编译） |

拦截记录与按天流量数据默认只保留一年。

## 常见问题

**打开是 403 / Cloudflare 页面？**

- 先确认不是自己开的「仅允许中国大陆 IP」把境外访问拦了
- 目标站按 User-Agent 分流时，浏览器会被踢到错误页，Emby 客户端正常；这是目标站行为
- 目标站在 Cloudflare 层拦截机房 IP 时，需要换出口、让站点方加白名单，或联系站点方

**「今天」筛选没数据？**

服务端与浏览器时区不同时会差一天。程序已按**服务器日期**计算，升级到最新版即可。

**地区显示「未知」？**

内网 / 本机 IP 本来就没有归属地，会单独显示「本机 / 内网」；公网 IP 查不到时开启「未知 IP 用在线接口查询」，再点「重新识别历史 IP」。

**端口改完连不上了？**

管理页改端口是热切换，保存后页面会提示跳转到新地址。若新端口被占用会自动回滚。

**没有 systemd 怎么办？**

目前仅支持 systemd 环境（Debian / Ubuntu / CentOS / Fedora / Arch 等）。非 systemd 环境请直接运行二进制：

```bash
/usr/local/bin/emby-proxy run -port 8520 -admin-user admin -admin-pass 你的密码 -config /etc/emby-proxy/config.json -stats /etc/emby-proxy/stats.json
```

## 从源码构建

脚本本身就是源码：它内嵌了 Go 源码与管理页，安装时解包编译。也可以手动抽出构建：

```bash
# 从脚本抽出源码
python3 - <<'PY'
s = open('emby-proxy.sh').read()
for tag in ('GO_SOURCE', 'ADMIN_HTML'):
    a = s.index("<<'%s'\n" % tag) + len("<<'%s'\n" % tag)
    b = s.index("\n%s\n" % tag, a)
    ext = 'go' if tag == 'GO_SOURCE' else 'html'
    open('main.' + ext if ext == 'go' else 'admin.' + ext, 'w').write(s[a:b] + '\n')
PY

# 编译
go mod init emby-proxy
go get github.com/phuslu/iploc@latest
go mod tidy
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o emby-proxy .
```

产物是静态二进制，可直接拷到任意同架构 Linux 上运行。

## 免责声明

本项目仅提供通用的路径反代能力，请遵守当地法律法规及目标服务的使用条款，勿用于任何未经授权的访问。使用者需对自身行为负责。
