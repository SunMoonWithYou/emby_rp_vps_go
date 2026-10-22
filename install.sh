#!/usr/bin/env bash
# =============================================================================
# Emby 路径反代 — 一键安装 / 管理脚本
# =============================================================================
#
# 功能概览
#   · 内嵌完整 Go 源码（路径反代服务 + 管理后台 HTML）
#   · 自动检测/安装 Go，编译为静态二进制并注册 systemd 服务
#   · 子命令：menu | install | update | uninstall | status | start|stop|restart
#
# 数据目录（默认）
#   /etc/emby-proxy/emby.db     bolt 库：配置、统计、认证、geo 缓存
#   /usr/local/bin/emby-proxy   编译产物
#   /etc/systemd/system/emby-proxy.service
#
# 常用
#   sudo bash $0                # 交互菜单
#   sudo bash $0 install        # 安装/重装
#   sudo bash $0 update         # 仅重编译替换二进制
#   sudo bash $0 uninstall -y   # 卸载
#
# =============================================================================
set -euo pipefail

# ---------- 默认路径与版本（可通过 install 参数覆盖端口/路径等）----------
SERVICE_NAME="emby-proxy"
DEFAULT_PORT=8520
DEFAULT_BIN="/usr/local/bin/emby-proxy"
CONFIG_DIR="/etc/emby-proxy"
DB_FILE="${CONFIG_DIR}/emby.db"
BUILD_HASH_FILE="${CONFIG_DIR}/build.sha256"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GO_MIN_MAJOR=1
GO_MIN_MINOR=20
GO_FALLBACK_VERSION="1.23.4"
IPLOC_VERSION="latest"

# ---------- 运行时状态 ----------
BUILD_TMPDIR=""
GENERATED_PASS=0
PORT=$DEFAULT_PORT
BIN_PATH=$DEFAULT_BIN
ADMIN_USER="admin"
ADMIN_PASS=""
PREBUILT=""
FORCE=0
BINARY_ONLY=0
PORT_GIVEN=0
PASS_GIVEN=0

# ---------- 日志辅助 ----------
info() { printf '\033[1;32m[OK] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() {
  if [[ -n "$BUILD_TMPDIR" && -d "$BUILD_TMPDIR" ]]; then rm -rf "$BUILD_TMPDIR"; fi
}
trap cleanup EXIT

require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 权限: sudo $0 $*"; }
require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "未检测到 systemctl"
  [[ -d /run/systemd/system ]] || die "systemd 未运行"
}

usage() {
  cat <<EOF
Emby 路径反代 一键安装
  sudo $0 [menu|install|update|uninstall|status|start|stop|restart]
EOF
}

parse_install_args() {
  PORT="$(installed_port)"
  BIN_PATH="$(installed_bin_path)"
  [[ -n "$BIN_PATH" ]] || BIN_PATH=$DEFAULT_BIN
  ADMIN_USER="admin"
  ADMIN_PASS=""
  PREBUILT=""
  FORCE=0
  BINARY_ONLY=0
  PORT_GIVEN=0
  PASS_GIVEN=0

  need_value() { if [[ $# -lt 2 ]]; then die "参数 $1 后面需要一个值"; fi; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code-only) BINARY_ONLY=1; shift ;;
      --port) need_value "$@"; PORT="$2"; PORT_GIVEN=1; shift 2 ;;
      --bin) need_value "$@"; BIN_PATH="$2"; shift 2 ;;
      --admin-user) need_value "$@"; ADMIN_USER="$2"; shift 2 ;;
      --admin-pass) need_value "$@"; ADMIN_PASS="$2"; PASS_GIVEN=1; shift 2 ;;
      --prebuilt) need_value "$@"; PREBUILT="$2"; shift 2 ;;
      --force) FORCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
}

stop_and_disable() { systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true; systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; }
go_version_ok() {
  command -v go >/dev/null 2>&1 || return 1
  local v major minor; v="$(go env GOVERSION 2>/dev/null || true)"; v="${v#go}"
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > GO_MIN_MAJOR || (major == GO_MIN_MAJOR && minor >= GO_MIN_MINOR) ))
}
detect_go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv6l) echo armv6l ;;
    i386|i686) echo 386 ;;
    *) return 1 ;;
  esac
}
install_go_from_pkg() {
  local pm=""
  command -v apt-get >/dev/null 2>&1 && pm=apt
  command -v dnf >/dev/null 2>&1 && pm=dnf
  command -v yum >/dev/null 2>&1 && pm=yum
  command -v pacman >/dev/null 2>&1 && pm=pacman
  command -v apk >/dev/null 2>&1 && pm=apk
  [[ -n "$pm" ]] || return 1
  info "使用 $pm 安装 Go..."
  case "$pm" in
    apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq golang-go ;;
    dnf|yum) $pm install -y golang ;;
    pacman) pacman -Sy --noconfirm go ;;
    apk) apk add --no-cache go ;;
  esac
  hash -r 2>/dev/null || true
}
install_go_official() {
  local arch url tmp
  arch="$(detect_go_arch)" || { warn "未知架构 $(uname -m)"; return 1; }
  url="https://go.dev/dl/go${GO_FALLBACK_VERSION}.linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  info "下载官方 Go: $url"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$tmp/go.tgz"
  elif command -v wget >/dev/null 2>&1; then wget -q "$url" -O "$tmp/go.tgz"
  else rm -rf "$tmp"; return 1; fi
  rm -rf /usr/local/go && tar -C /usr/local -xzf "$tmp/go.tgz" && rm -rf "$tmp"
  export PATH="/usr/local/go/bin:$PATH"
  hash -r 2>/dev/null || true
}
ensure_go() {
  export PATH="$PATH:/usr/local/go/bin"
  hash -r 2>/dev/null || true
  if go_version_ok; then info "Go 就绪: $(go env GOVERSION)"; return; fi
  info "未检测到 Go ${GO_MIN_MAJOR}.${GO_MIN_MINOR}+，自动安装..."
  install_go_from_pkg || warn "包管理器失败，改用官方二进制"
  export PATH="$PATH:/usr/local/go/bin"
  hash -r 2>/dev/null || true
  if ! go_version_ok; then install_go_official || true; export PATH="/usr/local/go/bin:$PATH"; fi
  go_version_ok || die "Go 自动安装失败"
  info "Go 就绪: $(go env GOVERSION)"
}

# 将内嵌的 main.go + admin.html 写出到临时目录，供 go build 使用
write_go_source() {
  local dir="$1"
  cat > "$dir/main.go" <<'GO_SOURCE'
package main

/*
Emby 路径反代服务（单文件）

访问模型
  客户端请求：  GET /https://emby.example.com:8096/web/index.html
  本服务解析路径中的目标 URL，按白名单/地区/限流校验后反代到上游。

主要模块
  · parseTarget / buildProxy     路径解析与 httputil.ReverseProxy
  · Config + bolt DB            持久化配置与统计
  · 访问控制                    白名单、ChinaOnly、黑名单、UA、限流（ACL 预编译）
  · 统计                        异步 channel 聚合，按日分桶，定期落盘
  · 实时监控                    liveConn + WebSocket(/admin/api/live/ws) 推送活跃连接
  · 管理后台                    /admin/ 嵌入 admin.html，会话 Cookie + 验证码登录
  · PWA 模式                    可选开启：manifest + Service Worker，后台可安装为独立应用、离线打开
  · 品牌图标                    favicon / Logo / PWA 图标（192、512）启动预热，本地提供

时区
  统计分日/分时与对外时间字段统一按 Asia/Shanghai（北京时间）。

内存与资源
  · 图片 LRU 缓存有条数与总字节上限
  · 统计 map 定期 pruneTopN，防止无限增长
  · GOMEMLIMIT 由 systemd unit 设为 256MiB 软限制
*/

import (
	"bufio"
	"bytes"
	"container/list"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"compress/gzip"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/phuslu/iploc"
	bolt "go.etcd.io/bbolt"
	"golang.org/x/sync/singleflight"
)

//go:embed admin.html
// adminHTML 为管理后台单页（构建时由脚本写入同目录 admin.html 后 embed）
var adminHTML []byte

// 上下文键：在 ReverseProxy.Rewrite 中取回目标 URL / 上行字节计数 / 实时连接
type targetCtxKey struct{}
type upBytesCtxKey struct{}

var httpPorts = map[string]bool{"80": true, "8080": true, "8000": true, "8008": true, "8081": true, "8088": true, "8888": true, "3000": true, "5000": true, "7001": true, "8090": true, "8096": true, "9000": true, "9090": true, "9200": true, "10000": true, "15672": true}

func schemeForPort(port string) string {
	if port == "" || port == "443" || port == "8443" || port == "8920" || port == "9443" {
		return "https"
	}
	if httpPorts[port] {
		return "http"
	}
	return "https"
}
func schemeForAuthority(authority string) string {
	host := authority
	if i := strings.LastIndexByte(authority, '@'); i >= 0 {
		host = authority[i+1:]
	}
	var port string
	if strings.HasPrefix(host, "[") {
		if i := strings.LastIndexByte(host, ']'); i >= 0 && len(host) > i+1 && host[i+1] == ':' {
			port = host[i+2:]
		}
	} else if i := strings.LastIndexByte(host, ':'); i >= 0 {
		port = host[i+1:]
	}
	return schemeForPort(port)
}
func splitAuthority(s string) (authority, path string) {
	if i := strings.IndexByte(s, '/'); i >= 0 {
		return s[:i], s[i:]
	}
	return s, ""
}

var builtinAssets = map[string]bool{"favicon.ico": true, "favicon.png": true, "favicon.svg": true, "favicon-16x16.png": true, "favicon-32x32.png": true, "favicon-96x96.png": true, "apple-touch-icon.png": true, "apple-touch-icon-precomposed.png": true, "robots.txt": true, "sitemap.xml": true, "browserconfig.xml": true, "manifest.json": true, "site.webmanifest": true, "humans.txt": true, "security.txt": true, "crossdomain.xml": true, "app-ads.txt": true}

func isBuiltinAssetPath(p string) bool {
	p = strings.TrimPrefix(p, "/")
	if p == "" {
		return false
	}
	if !strings.Contains(p, "/") {
		if builtinAssets[p] {
			return true
		}
		return strings.HasSuffix(p, ".ico")
	}
	return strings.HasPrefix(p, ".well-known/")
}

// ---------- 对外非管理页：首页与错误页（与管理后台独立的轻量样式）----------
const pageCSS = `
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--d:#ef4444;--w:#f59e0b;--ok:#10b981;--r:16px}
body{min-height:100dvh;background:var(--bg);color:var(--t);font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:var(--r);padding:40px 36px;max-width:520px;width:100%;box-shadow:0 4px 24px -4px rgba(15,23,42,.06);text-align:center}
/* 品牌区：与登录页 brand 结构一致（Logo + 名称 + 副标题） */
.brand{text-align:center;margin-bottom:22px}
.brand-logo{width:56px;height:56px;border-radius:14px;display:block;margin:0 auto 14px}
.brand h1{font-size:20px;font-weight:700;letter-spacing:-.3px}
.brand p{font-size:13px;color:var(--t3);margin-top:4px}
.icon{width:56px;height:56px;border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 auto 18px;font-size:24px}
.icon.blue{background:var(--ps);color:var(--p)}
.icon.red{background:#fef2f2;color:var(--d)}
.icon.amber{background:#fffbeb;color:var(--w)}
h2{font-size:22px;font-weight:700;letter-spacing:-.3px;margin-bottom:10px;color:var(--t)}
.desc{color:var(--t2);font-size:14.5px;line-height:1.7;margin-bottom:28px}
.ex{background:#f8fafc;border:1px solid var(--bd);border-radius:12px;padding:16px 18px;text-align:left;margin-bottom:24px;font-size:13.5px}
.ex-t{font-size:12px;color:var(--t3);margin-bottom:8px;font-weight:600}
.ex code{display:block;word-break:break-all;line-height:1.7;font-family:Consolas,monospace;color:var(--pd)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:12px 22px;border-radius:10px;font-size:14px;font-weight:500;cursor:pointer;border:0;font-family:inherit;text-decoration:none;transition:.2s}
.btn.b{background:var(--p);color:#fff;box-shadow:0 2px 6px rgba(59,130,246,.25)}
.btn.b:hover{background:var(--pd)}
.btn.g{background:#fff;border:1px solid var(--bd);color:var(--t2)}
.btn.g:hover{background:#f8fafc;color:var(--t)}
.acts{display:flex;gap:12px;justify-content:center;flex-wrap:wrap}
.foot{margin-top:28px;font-size:12.5px;color:var(--t3)}
@media(max-width:480px){.card{padding:28px 20px}h2{font-size:20px}}
`

// writePage 统一风格的公共页面（首页/错误页）：
// 品牌区（Logo + Emby Proxy + 副标题）与登录页结构一致；
// icon 非空时展示状态图标（错误页），title 非空时展示页面标题。
func writePage(w http.ResponseWriter, status int, iconClass, icon, title, desc, extraHTML string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	statusHTML, titleHTML := "", ""
	if icon != "" {
		statusHTML = `<div class="icon ` + iconClass + `">` + icon + `</div>`
	}
	if title != "" {
		titleHTML = `<h2>` + title + `</h2>`
	}
	pageTitle := title
	if pageTitle == "" {
		pageTitle = "首页"
	}
	html := `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><link rel="icon" href="/favicon.ico` + iconVer + `"><title>` + pageTitle + ` · Emby Proxy</title><style>` + pageCSS + `</style></head><body><div class="card"><div class="brand"><img class="brand-logo" src="/admin/logo.png" alt="Emby Proxy"><h1>Emby Proxy</h1><p>路径反代</p></div>` + statusHTML + titleHTML + `<div class="desc">` + desc + `</div>` + extraHTML + `<div class="foot">Emby Proxy · 路径反代</div></div></body></html>`
	_, _ = w.Write([]byte(html))
}

func serveHome(w http.ResponseWriter, r *http.Request) {
	extra := `
<div class="ex"><div class="ex-t">访问格式</div><code>/https://域名:端口/路径</code></div>
<div class="ex" style="margin-bottom:28px"><div class="ex-t">示例</div><code>/https://emby.example.com:8096/web/index.html</code></div>
<div class="acts"><a class="btn b" href="/admin/">管理后台</a></div>`
	writePage(w, http.StatusOK, "", "", "",
		"按路径将请求转发到指定上游，可配置域名白名单、地区限制、限流与缓存。", extra)
}

func serveError(w http.ResponseWriter, status int, title, message string) {
	iconClass, icon := "red", "✕"
	switch status {
	case http.StatusTooManyRequests:
		iconClass, icon = "amber", "⏱"
	case http.StatusBadGateway, http.StatusServiceUnavailable:
		iconClass, icon = "amber", "⚠"
	case http.StatusNotFound:
		iconClass, icon = "blue", "?"
	}
	extra := `<div class="acts"><a class="btn g" href="/">返回首页</a></div>`
	writePage(w, status, iconClass, icon, title, message, extra)
}

// parseTarget 从请求路径解析上游目标。
// 支持：/https://host/path、/http://host/path，或省略协议时按端口推断 scheme。
func parseTarget(r *http.Request) (*url.URL, error) {
	raw := r.URL.EscapedPath()
	if raw == "" || raw == "/" {
		return nil, fmt.Errorf("请指定目标，格式：/https://域名/路径")
	}
	rest := strings.TrimPrefix(raw, "/")
	for strings.HasPrefix(rest, "/") {
		rest = rest[1:]
	}
	if rest == "" {
		return nil, fmt.Errorf("缺少目标主机")
	}
	var scheme, body string
	body = rest
	for i := 0; i < 3; i++ {
		lower := strings.ToLower(body)
		switch {
		case strings.HasPrefix(lower, "https:"):
			if scheme == "" {
				scheme = "https"
			}
			body = body[len("https:"):]
		case strings.HasPrefix(lower, "http:"):
			if scheme == "" {
				scheme = "http"
			}
			body = body[len("http:"):]
		default:
			i = 99
			continue
		}
		trimmed := strings.TrimLeft(body, "/")
		if trimmed == body {
			break
		}
		body = trimmed
	}
	body = strings.TrimLeft(body, "/")
	authority, pathPart := splitAuthority(body)
	if authority == "" {
		return nil, fmt.Errorf("缺少目标主机")
	}
	if scheme == "" {
		scheme = schemeForAuthority(authority)
	}
	targetStr := scheme + "://" + authority + pathPart
	if r.URL.RawQuery != "" {
		targetStr += "?" + r.URL.RawQuery
	}
	u, err := url.Parse(targetStr)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("目标地址无效：%s", authority)
	}
	return u, nil
}

// Config 网关运行时配置（JSON 存入 bolt bucket "config"）
type Config struct {
	Port        int      `json:"port"`         // 监听端口；保存后可热切换
	ChinaOnly   bool     `json:"china_only"`   // 仅允许中国大陆 IP（本地 iploc 判断）
	Whitelist   []string `json:"whitelist"`    // 上游域名白名单，空=不限制；支持根域匹配
	GeoAPI      bool     `json:"geo_api"`      // 管理端 IP 详情是否拉远程 geo
	GeoAPIURL   string   `json:"geo_api_url"`  // 预留，当前使用内置 ip-api
	BanList     []string `json:"ban_list"`     // IP 或 CIDR
	AutoBan     bool     `json:"auto_ban"`     // 触发地区拦截时自动写入黑名单
	RateLimit   int      `json:"rate_limit"`   // 每 IP 每分钟请求上限，0=关闭
	AllowedUAs  []string `json:"allowed_uas"`  // UA 关键字白名单，空=不限制
	EnableCache bool     `json:"enable_cache"` // 缓存 /Images/ 小图
	CORS        bool     `json:"cors"`         // 是否添加宽松 CORS 头
	PWA         bool     `json:"pwa"`          // 管理后台 PWA 模式（可安装到桌面、全屏运行、离线壳）
}

// rateLimitEntry：每 IP 限流窗口（Count/WindowStart 须 atomic 访问）。
type rateLimitEntry struct {
	Count       atomic.Int64
	WindowStart atomic.Int64 // UnixNano，窗口起始时间
}

var startedAt = time.Now()

// 统一使用北京时间（Asia/Shanghai）做日期分桶与对外时间展示
var beijingLoc = func() *time.Location {
	loc, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		return time.FixedZone("CST", 8*3600)
	}
	return loc
}()

func nowBeijing() time.Time { return time.Now().In(beijingLoc) }
func beijingDate(t time.Time) string { return t.In(beijingLoc).Format("2006-01-02") }
func beijingHour(t time.Time) string { return t.In(beijingLoc).Format("15") }
func beijingRFC3339(t time.Time) string { return t.In(beijingLoc).Format(time.RFC3339) }

var (
	db         *bolt.DB
	dbPath     string
	faviconData atomic.Pointer[cachedIcon] // 启动时后台预热，处理器只读，避免首次请求阻塞
	logoData    atomic.Pointer[cachedIcon] // 品牌 Logo（登录页/侧边栏）
	icon192Data atomic.Pointer[cachedIcon] // PWA 192x192 图标
	icon512Data atomic.Pointer[cachedIcon] // PWA 512x512 图标
	cfgPtr     atomic.Pointer[Config]
	proxyTr    = &switchTransport{}
	listenMu   sync.Mutex
	curLn      net.Listener
	curPort    int
	globalSrv  *http.Server

	ipLimiters sync.Map
)

// ---------- 品牌图标资源（启动时预热，本地缓存后由 /admin/* 提供）----------
const (
	iconFaviconURL = "https://i.ibb.co/H9QXXb8/emby-rp-icon.jpg"   // 网页 favicon（32x32）
	iconLogoURL    = "https://i.ibb.co/KxByc0q8/emby-rp-logo.png"  // 品牌 Logo（512x512）
	icon192URL     = "https://i.ibb.co/84fwCqPj/emby-rp-logo-192.png" // PWA 192x192
	icon512URL     = "https://i.ibb.co/RkTFtq4n/emby-rp-logo-512.png" // PWA 512x512
)

// cachedIcon 带正确 Content-Type 的图标缓存（favicon 为 jpeg，其余为 png）
type cachedIcon struct {
	data  []byte
	ctype string
}

// fetchIcon 拉取远端图标；失败返回 nil（调用方回退 302 源站）
func fetchIcon(url string) *cachedIcon {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil || len(data) == 0 {
		return nil
	}
	ct := strings.TrimSpace(resp.Header.Get("Content-Type"))
	if ct == "" {
		if strings.HasSuffix(strings.ToLower(url), ".jpg") || strings.HasSuffix(strings.ToLower(url), ".jpeg") {
			ct = "image/jpeg"
		} else {
			ct = "image/png"
		}
	}
	return &cachedIcon{data: data, ctype: ct}
}

// serveCachedIcon 输出预热缓存；未预热完成则 302 到源站，不阻塞请求
func serveCachedIcon(w http.ResponseWriter, r *http.Request, p *atomic.Pointer[cachedIcon], fallbackURL string) {
	if ic := p.Load(); ic != nil {
		w.Header().Set("Content-Type", ic.ctype)
		w.Header().Set("Cache-Control", "public, max-age=86400")
		_, _ = w.Write(ic.data)
		return
	}
	http.Redirect(w, r, fallbackURL, http.StatusFound)
}

// ---------- 图片缓存（仅 GET 且路径含 /Images/ 的小响应）----------
// 双上限：条数 + 总字节；单条过大直接不入队。缓存键为完整请求 URL。
const (
	imgCacheMaxCount = 500
	imgCacheMaxBytes = 50 << 20 // 50MB
)

var imgCache = struct {
	mu    sync.Mutex
	ll    *list.List               // 前端 = 最旧，后端 = 最新
	items map[string]*list.Element // key -> element(值为 *imgCacheItem)
	size  int64
}{
	ll:    list.New(),
	items: map[string]*list.Element{},
}

type imgCacheItem struct {
	key  string
	data []byte
}

func imageCacheGet(key string) ([]byte, bool) {
	imgCache.mu.Lock()
	defer imgCache.mu.Unlock()
	el, ok := imgCache.items[key]
	if !ok {
		return nil, false
	}
	imgCache.ll.MoveToBack(el) // 命中即提升为最新
	return el.Value.(*imgCacheItem).data, true
}

func imageCachePut(key string, data []byte) {
	if len(data) > imgCacheMaxBytes/imgCacheMaxCount*4 { // 单条超过 400KB 一般不是小图标，不缓存
		return
	}
	imgCache.mu.Lock()
	defer imgCache.mu.Unlock()
	if el, ok := imgCache.items[key]; ok { // 已存在则更新并移动到队尾
		it := el.Value.(*imgCacheItem)
		imgCache.size += int64(len(data) - len(it.data))
		it.data = data
		imgCache.ll.MoveToBack(el)
	} else {
		el := imgCache.ll.PushBack(&imgCacheItem{key: key, data: data})
		imgCache.items[key] = el
		imgCache.size += int64(len(data))
	}
	// 逐个淘汰最旧条目，直到满足双重上限
	for imgCache.size > imgCacheMaxBytes || imgCache.ll.Len() > imgCacheMaxCount {
		oldest := imgCache.ll.Front()
		if oldest == nil {
			break
		}
		it := oldest.Value.(*imgCacheItem)
		imgCache.size -= int64(len(it.data))
		delete(imgCache.items, it.key)
		imgCache.ll.Remove(oldest)
	}
}

func currentCfg() *Config {
	if p := cfgPtr.Load(); p != nil {
		return p
	}
	return &Config{}
}

// compiledACL 由 rebuildACL 在配置加载/保存时生成，供每个请求快速检查，
// 避免在热路径上反复 net.ParseCIDR 与 strings.ToLower。
type compiledACL struct {
	exactBan map[string]struct{}
	cidrs    []*net.IPNet
	uaNeedles []string // 已小写；空 = 不限制
}

var aclPtr atomic.Pointer[compiledACL]

func rebuildACL(c *Config) {
	a := &compiledACL{exactBan: map[string]struct{}{}}
	if c == nil {
		aclPtr.Store(a)
		return
	}
	for _, b := range c.BanList {
		b = strings.TrimSpace(b)
		if b == "" {
			continue
		}
		if strings.Contains(b, "/") {
			if _, ipnet, err := net.ParseCIDR(b); err == nil {
				a.cidrs = append(a.cidrs, ipnet)
			}
			continue
		}
		a.exactBan[b] = struct{}{}
	}
	for _, u := range c.AllowedUAs {
		u = strings.ToLower(strings.TrimSpace(u))
		if u != "" {
			a.uaNeedles = append(a.uaNeedles, u)
		}
	}
	aclPtr.Store(a)
}
func currentACL() *compiledACL {
	if p := aclPtr.Load(); p != nil {
		return p
	}
	return &compiledACL{exactBan: map[string]struct{}{}}
}
func isBannedIP(ipStr string, clientIP net.IP) bool {
	a := currentACL()
	if _, ok := a.exactBan[ipStr]; ok {
		return true
	}
	if clientIP == nil || len(a.cidrs) == 0 {
		return false
	}
	for _, n := range a.cidrs {
		if n.Contains(clientIP) {
			return true
		}
	}
	return false
}
func uaAllowed(ua string) bool {
	a := currentACL()
	if len(a.uaNeedles) == 0 {
		return true
	}
	ua = strings.ToLower(ua)
	for _, n := range a.uaNeedles {
		if strings.Contains(ua, n) {
			return true
		}
	}
	return false
}

func currentPort() int { listenMu.Lock(); defer listenMu.Unlock(); return curPort }

func startListen(srv *http.Server, port int) error {
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return err
	}
	listenMu.Lock()
	old := curLn
	curLn = ln
	curPort = port
	listenMu.Unlock()
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, net.ErrClosed) && err != http.ErrServerClosed {
			log.Printf("端口 %d 监听结束: %v", port, err)
		}
	}()
	if old != nil {
		_ = old.Close()
	}
	return nil
}

func loadConfig() {
	c := &Config{}
	if db != nil {
		_ = db.View(func(tx *bolt.Tx) error {
			b := tx.Bucket([]byte("config"))
			if b != nil {
				if data := b.Get([]byte("data")); data != nil {
					_ = json.Unmarshal(data, c)
				}
			}
			return nil
		})
	}
	cfgPtr.Store(c)
	rebuildACL(c)
}
func saveConfig(c *Config) error {
	if db == nil {
		return fmt.Errorf("db not ready")
	}
	b, _ := json.Marshal(c)
	err := db.Update(func(tx *bolt.Tx) error {
		bk, err := tx.CreateBucketIfNotExists([]byte("config"))
		if err != nil {
			return err
		}
		return bk.Put([]byte("data"), b)
	})
	if err == nil {
		rebuildACL(c)
	}
	return err
}


func normalizeHost(hostport string) string {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return strings.ToLower(strings.TrimSpace(host))
}

var multiSuffix = map[string]bool{"co.uk": true, "org.uk": true, "me.uk": true, "ac.uk": true, "gov.uk": true, "ltd.uk": true, "plc.uk": true, "net.uk": true, "sch.uk": true, "com.cn": true, "net.cn": true, "org.cn": true, "gov.cn": true, "edu.cn": true, "ac.cn": true, "com.tw": true, "org.tw": true, "net.tw": true, "idv.tw": true, "com.hk": true, "org.hk": true, "net.hk": true, "edu.hk": true, "gov.hk": true, "co.jp": true, "or.jp": true, "ne.jp": true, "ac.jp": true, "go.jp": true, "co.kr": true, "or.kr": true, "com.au": true, "net.au": true, "org.au": true, "com.br": true, "com.sg": true, "com.my": true, "co.in": true, "com.tr": true, "com.ru": true, "com.mx": true, "com.ar": true, "co.nz": true, "co.za": true, "com.ua": true, "com.pl": true, "co.id": true, "com.sa": true, "com.eg": true}

func rootDomain(hostport string) string {
	host := normalizeHost(hostport)
	if net.ParseIP(host) != nil {
		return host
	}
	host = strings.TrimSuffix(host, ".")
	parts := strings.Split(host, ".")
	n := len(parts)
	if n <= 2 {
		return host
	}
	if multiSuffix[strings.Join(parts[n-2:], ".")] {
		return strings.Join(parts[n-3:], ".")
	}
	return strings.Join(parts[n-2:], ".")
}
// whitelistMatch 空列表表示不限制；否则匹配完整 host 或与规则相同的根域名。
func whitelistMatch(list []string, targetHost string) bool {
	if len(list) == 0 {
		return true
	}
	target := normalizeHost(targetHost)
	targetRoot := rootDomain(target)
	for _, w := range list {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		if strings.EqualFold(normalizeHost(w), target) {
			return true
		}
		if strings.EqualFold(rootDomain(w), targetRoot) {
			return true
		}
	}
	return false
}

type BlockEvent struct {
	Time       string `json:"time"`
	IP         string `json:"ip"`
	Country    string `json:"country"`
	Path       string `json:"path"`
	Reason     string `json:"reason"`
	ReasonText string `json:"reason_text"`
	UA         string `json:"ua"`
}

// DayStat：按天统计
type DayStat struct {
	Requests  int64            `json:"requests"`
	Bytes     int64            `json:"bytes"`
	BlockedCN int64            `json:"blocked_cn"`
	BlockedWL int64            `json:"blocked_wl"`
	BlockedBan int64            `json:"blocked_ban"`  // IP 黑名单拦截
	BlockedRate int64           `json:"blocked_rate"` // 触发限流
	BlockedUA int64            `json:"blocked_ua"`   // UA 不在白名单
	Countries map[string]int64 `json:"countries,omitempty"` // 国家码 -> 请求数
	IPs       map[string]int64 `json:"ips,omitempty"`       // IP -> 请求数
	IPBytes   map[string]int64 `json:"ip_bytes,omitempty"`  // IP -> 流量
	Hours     map[string]int64 `json:"hours,omitempty"`      // "00"-"23" -> 请求数
	HourBytes map[string]int64 `json:"hour_bytes,omitempty"` // "00"-"23" -> 真实流量字节
	Hosts     map[string]int64 `json:"hosts,omitempty"`      // 上游主机 -> 请求数
}

func newDayStat() *DayStat {
	return &DayStat{
		Countries: map[string]int64{},
		IPs:       map[string]int64{},
		IPBytes:   map[string]int64{},
		Hours:     map[string]int64{},
		HourBytes: map[string]int64{},
		Hosts:     map[string]int64{},
	}
}

func ensureDayMaps(d *DayStat) {
	if d.Countries == nil {
		d.Countries = map[string]int64{}
	}
	if d.IPs == nil {
		d.IPs = map[string]int64{}
	}
	if d.IPBytes == nil {
		d.IPBytes = map[string]int64{}
	}
	if d.Hours == nil {
		d.Hours = map[string]int64{}
	}
	if d.HourBytes == nil {
		d.HourBytes = map[string]int64{}
	}
	if d.Hosts == nil {
		d.Hosts = map[string]int64{}
	}
}

func copyInt64Map(src map[string]int64) map[string]int64 {
	if len(src) == 0 {
		return nil
	}
	out := make(map[string]int64, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

// dayOf 需在持有 statsMu 时调用。
func dayOf(date string) *DayStat {
	if stats.Daily == nil {
		stats.Daily = map[string]*DayStat{}
	}
	d := stats.Daily[date]
	if d == nil {
		d = newDayStat()
		stats.Daily[date] = d
	}
	ensureDayMaps(d)
	return d
}

// ---------- 访问统计 ----------
// 写入：recordRequestStart/recordBytes → statChan → startStatsWorker 单协程聚合
// 落盘：startStatsSaver 每 5 分钟 prune + 写入 stats_meta / stats_daily / stats_blocks
type Stats struct {
	TodayDate        string              `json:"today_date"`
	TodayRequests    int64               `json:"today_requests"`
	TodayBytes       int64               `json:"today_bytes"`
	TotalRequests    int64               `json:"total_requests"`
	TotalBytes       int64               `json:"total_bytes"`
	BlockedCN        int64               `json:"blocked_cn"`
	BlockedWhitelist int64               `json:"blocked_whitelist"`
	BlockedBan       int64               `json:"blocked_ban"`
	BlockedRate      int64               `json:"blocked_rate"`
	BlockedUA        int64               `json:"blocked_ua"`
	LastProxyAt      string              `json:"last_proxy_at"`
	CountryCounts    map[string]int64    `json:"country_counts"`
	IPCounts         map[string]int64    `json:"ip_counts"`
	IPBytes          map[string]int64    `json:"ip_bytes"`
	Daily            map[string]*DayStat `json:"daily,omitempty"`
	Blocks           []BlockEvent        `json:"blocks"`
}

var (
	stats   Stats
	statsMu sync.Mutex
)

type statEvent struct {
	IP      string
	Country string
	Host    string // 上游目标主机，写入 DayStat.Hosts
	Bytes   int64
	IsStart bool
}

var statChan = make(chan statEvent, 10000)

// statDropped：统计通道满时丢弃计数
var statDropped atomic.Int64

// pruneTopN：仅保留 map 中值最大的前 n 条。
func pruneTopN[K comparable](m map[K]int64, n int) {
	if len(m) <= n {
		return
	}
	type kv struct {
		k K
		v int64
	}
	arr := make([]kv, 0, len(m))
	for k, v := range m {
		arr = append(arr, kv{k, v})
	}
	sort.Slice(arr, func(i, j int) bool { return arr[i].v > arr[j].v })
	newMap := make(map[K]int64, n)
	for i := 0; i < n; i++ {
		newMap[arr[i].k] = arr[i].v
	}
	for k := range m {
		if _, ok := newMap[k]; !ok {
			delete(m, k)
		}
	}
	for k, v := range newMap {
		m[k] = v
	}
}

// 裁剪过大的统计数据，防止内存与磁盘耗尽
func pruneStatsLocked() {
	pruneTopN(stats.IPCounts, 1000)
	pruneTopN(stats.IPBytes, 1000)
	cutoff := time.Now().AddDate(-1, 0, 0).Format("2006-01-02")
	for k := range stats.Daily {
		if k < cutoff {
			delete(stats.Daily, k)
		}
	}
	for _, day := range stats.Daily {
		ensureDayMaps(day)
		pruneTopN(day.IPs, 500)
		pruneTopN(day.IPBytes, 500)
		pruneTopN(day.Hosts, 300)
		pruneTopN(day.Countries, 200)
	}
}

// startStatsWorker 单消费者聚合统计，避免多协程抢 statsMu；通道满则丢弃并计数。
func startStatsWorker() {
	go func() {
		for ev := range statChan {
			statsMu.Lock()
			now := nowBeijing()
			t := beijingDate(now)
			hour := beijingHour(now)
			if stats.TodayDate != t {
				stats.TodayDate = t
				stats.TodayRequests = 0
				stats.TodayBytes = 0
			}
			if ev.IsStart {
				stats.TotalRequests++
				stats.TodayRequests++
				stats.LastProxyAt = beijingRFC3339(now)
				c := ev.Country
				if c == "" {
					c = "??"
				}
				stats.CountryCounts[c]++
				if ev.IP != "" {
					stats.IPCounts[ev.IP]++
				}
				d := dayOf(t)
				d.Requests++
				d.Countries[c]++
				if ev.IP != "" {
					d.IPs[ev.IP]++
				}
				d.Hours[hour]++
				if ev.Host != "" {
					d.Hosts[ev.Host]++
				}
			} else if ev.Bytes > 0 {
				stats.TotalBytes += ev.Bytes
				stats.TodayBytes += ev.Bytes
				d := dayOf(t)
				d.Bytes += ev.Bytes
				d.HourBytes[hour] += ev.Bytes
				if ev.IP != "" {
					stats.IPBytes[ev.IP] += ev.Bytes
					d.IPBytes[ev.IP] += ev.Bytes
				}
			}
			statsMu.Unlock()
		}
	}()
}

func recordRequestStart(ip, country, host string) {
	select {
	case statChan <- statEvent{IP: ip, Country: country, Host: host, IsStart: true}:
	default:
		statDropped.Add(1) // 通道满：丢弃但不阻塞请求
	}
}
func recordBytes(ip string, bytes int64) {
	if bytes > 0 {
		select {
		case statChan <- statEvent{IP: ip, Bytes: bytes, IsStart: false}:
		default:
			statDropped.Add(1)
		}
	}
}

// 磁盘分桶：stats_meta / stats_daily / stats_blocks（兼容旧版 stats/data 迁移）

type statsMetaDisk struct {
	TodayDate        string `json:"today_date"`
	TodayRequests    int64  `json:"today_requests"`
	TodayBytes       int64  `json:"today_bytes"`
	TotalRequests    int64  `json:"total_requests"`
	TotalBytes       int64  `json:"total_bytes"`
	BlockedCN        int64  `json:"blocked_cn"`
	BlockedWhitelist int64  `json:"blocked_whitelist"`
	BlockedBan       int64  `json:"blocked_ban"`
	BlockedRate      int64  `json:"blocked_rate"`
	BlockedUA        int64  `json:"blocked_ua"`
	LastProxyAt      string `json:"last_proxy_at"`
}

func emptyStats() Stats {
	return Stats{
		TodayDate:     beijingDate(time.Now()),
		CountryCounts: map[string]int64{},
		IPCounts:      map[string]int64{},
		IPBytes:       map[string]int64{},
		Daily:         map[string]*DayStat{},
		Blocks:        []BlockEvent{},
	}
}

func rebuildAggregatesFromDaily() {
	stats.CountryCounts = map[string]int64{}
	stats.IPCounts = map[string]int64{}
	stats.IPBytes = map[string]int64{}
	for _, d := range stats.Daily {
		if d == nil {
			continue
		}
		ensureDayMaps(d)
		for k, v := range d.Countries {
			stats.CountryCounts[k] += v
		}
		for k, v := range d.IPs {
			stats.IPCounts[k] += v
		}
		for k, v := range d.IPBytes {
			stats.IPBytes[k] += v
		}
	}
	pruneTopN(stats.IPCounts, 1000)
	pruneTopN(stats.IPBytes, 1000)
}

func loadStats() {
	stats = emptyStats()
	if db == nil {
		return
	}
	migrated := false
	_ = db.View(func(tx *bolt.Tx) error {
		// 新结构：meta
		if b := tx.Bucket([]byte("stats_meta")); b != nil {
			if data := b.Get([]byte("data")); data != nil {
				var m statsMetaDisk
				if json.Unmarshal(data, &m) == nil {
					stats.TodayDate = m.TodayDate
					stats.TodayRequests = m.TodayRequests
					stats.TodayBytes = m.TodayBytes
					stats.TotalRequests = m.TotalRequests
					stats.TotalBytes = m.TotalBytes
				stats.BlockedCN = m.BlockedCN
				stats.BlockedWhitelist = m.BlockedWhitelist
				stats.BlockedBan = m.BlockedBan
				stats.BlockedRate = m.BlockedRate
				stats.BlockedUA = m.BlockedUA
					stats.LastProxyAt = m.LastProxyAt
				}
			}
		}
		// 新结构：daily 分键
		if b := tx.Bucket([]byte("stats_daily")); b != nil {
			_ = b.ForEach(func(k, v []byte) error {
				d := newDayStat()
				if json.Unmarshal(v, d) == nil {
					ensureDayMaps(d)
					stats.Daily[string(k)] = d
				}
				return nil
			})
		}
		// 新结构：blocks
		if b := tx.Bucket([]byte("stats_blocks")); b != nil {
			if data := b.Get([]byte("data")); data != nil {
				var bl []BlockEvent
				if json.Unmarshal(data, &bl) == nil {
					stats.Blocks = bl
				}
			}
		}
		// 旧版整包迁移
		if len(stats.Daily) == 0 && stats.TotalRequests == 0 {
			if b := tx.Bucket([]byte("stats")); b != nil {
				if data := b.Get([]byte("data")); data != nil {
					old := emptyStats()
					if json.Unmarshal(data, &old) == nil {
						stats = old
						migrated = true
					}
				}
			}
		}
		return nil
	})
	if stats.CountryCounts == nil {
		stats.CountryCounts = map[string]int64{}
	}
	if stats.IPCounts == nil {
		stats.IPCounts = map[string]int64{}
	}
	if stats.IPBytes == nil {
		stats.IPBytes = map[string]int64{}
	}
	if stats.Daily == nil {
		stats.Daily = map[string]*DayStat{}
	}
	if stats.Blocks == nil {
		stats.Blocks = []BlockEvent{}
	}
	for _, d := range stats.Daily {
		ensureDayMaps(d)
	}
	// 若从旧包迁入或 daily 有数据但全局 IP/国家为空，按日重算聚合
	if migrated || (len(stats.IPCounts) == 0 && len(stats.Daily) > 0) {
		rebuildAggregatesFromDaily()
	}
	if stats.TodayDate == "" {
		stats.TodayDate = beijingDate(time.Now())
	}
	// 今日计数与 daily 对齐（避免跨进程后今日字段漂移）
	if d := stats.Daily[stats.TodayDate]; d != nil {
		if stats.TodayRequests == 0 && d.Requests > 0 {
			stats.TodayRequests = d.Requests
		}
		if stats.TodayBytes == 0 && d.Bytes > 0 {
			stats.TodayBytes = d.Bytes
		}
	}
	if migrated {
		statsMu.Lock()
		snap := marshalStatsLocked()
		statsMu.Unlock()
		persistStats(snap)
		_ = db.Update(func(tx *bolt.Tx) error {
			_ = tx.DeleteBucket([]byte("stats"))
			return nil
		})
	}
}

// statsSnapshot 统计落盘快照：锁内序列化（纯内存、快）→ 锁外写盘（磁盘 IO）。
// 原实现 db.Update 全程持 statsMu，慢盘时统计 worker 与 recordBlocked 全部阻塞，
// 极端情况下 statChan 塞满导致丢实时数据。
type statsSnapshot struct {
	meta       []byte
	blocks     []byte
	dailyItems []struct{ key string; data []byte }
	dailyKeys  map[string]struct{}
}

// marshalStatsLocked 持锁序列化统计快照（调用方必须已持有 statsMu）
func marshalStatsLocked() *statsSnapshot {
	meta := statsMetaDisk{
		TodayDate:        stats.TodayDate,
		TodayRequests:    stats.TodayRequests,
		TodayBytes:       stats.TodayBytes,
		TotalRequests:    stats.TotalRequests,
		TotalBytes:       stats.TotalBytes,
		BlockedCN:        stats.BlockedCN,
		BlockedWhitelist: stats.BlockedWhitelist,
		BlockedBan:       stats.BlockedBan,
		BlockedRate:      stats.BlockedRate,
		BlockedUA:        stats.BlockedUA,
		LastProxyAt:      stats.LastProxyAt,
	}
	metaBytes, _ := json.Marshal(meta)
	blockBytes, _ := json.Marshal(stats.Blocks)
	snap := &statsSnapshot{meta: metaBytes, blocks: blockBytes, dailyKeys: map[string]struct{}{}}
	for date, d := range stats.Daily {
		if d == nil {
			continue
		}
		b, err := json.Marshal(d)
		if err != nil {
			continue
		}
		snap.dailyItems = append(snap.dailyItems, struct{ key string; data []byte }{key: date, data: b})
		snap.dailyKeys[date] = struct{}{}
	}
	return snap
}

// persistStats 锁外写盘（磁盘 IO 不阻塞统计）
func persistStats(snap *statsSnapshot) {
	if db == nil || snap == nil {
		return
	}
	_ = db.Update(func(tx *bolt.Tx) error {
		mb, err := tx.CreateBucketIfNotExists([]byte("stats_meta"))
		if err != nil {
			return err
		}
		if err := mb.Put([]byte("data"), snap.meta); err != nil {
			return err
		}
		dbkt, err := tx.CreateBucketIfNotExists([]byte("stats_daily"))
		if err != nil {
			return err
		}
		// 先清掉已过期键（与快照一致）
		_ = dbkt.ForEach(func(k, _ []byte) error {
			if _, ok := snap.dailyKeys[string(k)]; !ok {
				_ = dbkt.Delete(k)
			}
			return nil
		})
		for _, it := range snap.dailyItems {
			_ = dbkt.Put([]byte(it.key), it.data)
		}
		bb, err := tx.CreateBucketIfNotExists([]byte("stats_blocks"))
		if err != nil {
			return err
		}
		return bb.Put([]byte("data"), snap.blocks)
	})
}

// saveStatsOnce 常规落盘入口：锁内序列化快照 → 释放锁 → 锁外写盘
func saveStatsOnce() {
	statsMu.Lock()
	snap := marshalStatsLocked()
	statsMu.Unlock()
	persistStats(snap)
}
func startStatsSaver() {
	go func() {
		t := time.NewTicker(5 * time.Minute)
		for range t.C {
			statsMu.Lock()
			pruneStatsLocked()
			snap := marshalStatsLocked()
			statsMu.Unlock()
			persistStats(snap)
			geoCacheSave()
			geoPrune()

			now := time.Now().UnixNano()
			ipLimiters.Range(func(k, v interface{}) bool {
				entry := v.(*rateLimitEntry)
				// 10 分钟未活跃（以窗口起点为准）的限流器予以回收
				if now-entry.WindowStart.Load() > int64(10*time.Minute) {
					ipLimiters.Delete(k)
				}
				return true
			})
		}
	}()
}

// getClientIP 取客户端 IP。仅当直连方为 loopback/私网时才信任 X-Forwarded-For / X-Real-IP。
func getClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	trusted := ip != nil && (ip.IsLoopback() || ip.IsPrivate())
	if trusted {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			if i := strings.IndexByte(xff, ','); i > 0 {
				return strings.TrimSpace(xff[:i])
			}
			return strings.TrimSpace(xff)
		}
		if xri := r.Header.Get("X-Real-IP"); xri != "" {
			return strings.TrimSpace(xri)
		}
	}
	return host
}

var selfPublicIP atomic.Value

func detectSelfPublicIP() {
	go func() {
		client := &http.Client{Timeout: 4 * time.Second}
		urls := []string{"https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"}
		for _, u := range urls {
			resp, err := client.Get(u)
			if err != nil {
				continue
			}
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 64))
			resp.Body.Close()
			if resp.StatusCode != 200 {
				continue
			}
			ipStr := strings.TrimSpace(string(body))
			if net.ParseIP(ipStr) != nil {
				selfPublicIP.Store(ipStr)
				return
			}
		}
	}()
}
// countryOf 使用嵌入的 iploc 本地库，不发起网络请求；失败返回 "??"。
func countryOf(ipStr string) string {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil {
		return "??"
	}
	c := iploc.Country(ip)
	if len(c) == 0 || c == "ZZ" {
		return "??"
	}
	return c
}

var countryNames = map[string]string{
		"??": "未知",
		"AD": "安道尔",
		"AE": "阿联酋",
		"AF": "阿富汗",
		"AG": "安提瓜和巴布达",
		"AI": "安圭拉",
		"AL": "阿尔巴尼亚",
		"AM": "亚美尼亚",
		"AO": "安哥拉",
		"AQ": "南极洲",
		"AR": "阿根廷",
		"AS": "美属萨摩亚",
		"AT": "奥地利",
		"AU": "澳大利亚",
		"AW": "阿鲁巴",
		"AX": "奥兰群岛",
		"AZ": "阿塞拜疆",
		"BA": "波黑",
		"BB": "巴巴多斯",
		"BD": "孟加拉国",
		"BE": "比利时",
		"BF": "布基纳法索",
		"BG": "保加利亚",
		"BH": "巴林",
		"BI": "布隆迪",
		"BJ": "贝宁",
		"BL": "圣巴泰勒米",
		"BM": "百慕大",
		"BN": "文莱",
		"BO": "玻利维亚",
		"BQ": "荷属加勒比",
		"BR": "巴西",
		"BS": "巴哈马",
		"BT": "不丹",
		"BV": "布韦岛",
		"BW": "博茨瓦纳",
		"BY": "白俄罗斯",
		"BZ": "伯利兹",
		"CA": "加拿大",
		"CC": "科科斯群岛",
		"CD": "刚果（金）",
		"CF": "中非",
		"CG": "刚果（布）",
		"CH": "瑞士",
		"CI": "科特迪瓦",
		"CK": "库克群岛",
		"CL": "智利",
		"CM": "喀麦隆",
		"CN": "中国",
		"CO": "哥伦比亚",
		"CR": "哥斯达黎加",
		"CU": "古巴",
		"CV": "佛得角",
		"CW": "库拉索",
		"CX": "圣诞岛",
		"CY": "塞浦路斯",
		"CZ": "捷克",
		"DE": "德国",
		"DJ": "吉布提",
		"DK": "丹麦",
		"DM": "多米尼克",
		"DO": "多米尼加",
		"DZ": "阿尔及利亚",
		"EC": "厄瓜多尔",
		"EE": "爱沙尼亚",
		"EG": "埃及",
		"EH": "西撒哈拉",
		"ER": "厄立特里亚",
		"ES": "西班牙",
		"ET": "埃塞俄比亚",
		"FI": "芬兰",
		"FJ": "斐济",
		"FK": "福克兰群岛",
		"FM": "密克罗尼西亚",
		"FO": "法罗群岛",
		"FR": "法国",
		"GA": "加蓬",
		"GB": "英国",
		"GD": "格林纳达",
		"GE": "格鲁吉亚",
		"GF": "法属圭亚那",
		"GG": "根西岛",
		"GH": "加纳",
		"GI": "直布罗陀",
		"GL": "格陵兰",
		"GM": "冈比亚",
		"GN": "几内亚",
		"GP": "瓜德罗普",
		"GQ": "赤道几内亚",
		"GR": "希腊",
		"GS": "南乔治亚",
		"GT": "危地马拉",
		"GU": "关岛",
		"GW": "几内亚比绍",
		"GY": "圭亚那",
		"HK": "中国香港",
		"HM": "赫德岛",
		"HN": "洪都拉斯",
		"HR": "克罗地亚",
		"HT": "海地",
		"HU": "匈牙利",
		"ID": "印度尼西亚",
		"IE": "爱尔兰",
		"IL": "以色列",
		"IM": "马恩岛",
		"IN": "印度",
		"IO": "英属印度洋领地",
		"IQ": "伊拉克",
		"IR": "伊朗",
		"IS": "冰岛",
		"IT": "意大利",
		"JE": "泽西岛",
		"JM": "牙买加",
		"JO": "约旦",
		"JP": "日本",
		"KE": "肯尼亚",
		"KG": "吉尔吉斯斯坦",
		"KH": "柬埔寨",
		"KI": "基里巴斯",
		"KM": "科摩罗",
		"KN": "圣基茨和尼维斯",
		"KP": "朝鲜",
		"KR": "韩国",
		"KW": "科威特",
		"KY": "开曼群岛",
		"KZ": "哈萨克斯坦",
		"LA": "老挝",
		"LB": "黎巴嫩",
		"LC": "圣卢西亚",
		"LI": "列支敦士登",
		"LK": "斯里兰卡",
		"LO": "本机",
		"LR": "利比里亚",
		"LS": "莱索托",
		"LT": "立陶宛",
		"LU": "卢森堡",
		"LV": "拉脱维亚",
		"LY": "利比亚",
		"MA": "摩洛哥",
		"MC": "摩纳哥",
		"MD": "摩尔多瓦",
		"ME": "黑山",
		"MF": "法属圣马丁",
		"MG": "马达加斯加",
		"MH": "马绍尔群岛",
		"MK": "北马其顿",
		"ML": "马里",
		"MM": "缅甸",
		"MN": "蒙古",
		"MO": "中国澳门",
		"MP": "北马里亚纳",
		"MQ": "马提尼克",
		"MR": "毛里塔尼亚",
		"MS": "蒙特塞拉特",
		"MT": "马耳他",
		"MU": "毛里求斯",
		"MV": "马尔代夫",
		"MW": "马拉维",
		"MX": "墨西哥",
		"MY": "马来西亚",
		"MZ": "莫桑比克",
		"NA": "纳米比亚",
		"NC": "新喀里多尼亚",
		"NE": "尼日尔",
		"NF": "诺福克岛",
		"NG": "尼日利亚",
		"NI": "尼加拉瓜",
		"NL": "荷兰",
		"NO": "挪威",
		"NP": "尼泊尔",
		"NR": "瑙鲁",
		"NU": "纽埃",
		"NZ": "新西兰",
		"OM": "阿曼",
		"PA": "巴拿马",
		"PE": "秘鲁",
		"PF": "法属波利尼西亚",
		"PG": "巴布亚新几内亚",
		"PH": "菲律宾",
		"PK": "巴基斯坦",
		"PL": "波兰",
		"PM": "圣皮埃尔",
		"PN": "皮特凯恩",
		"PR": "波多黎各",
		"PS": "巴勒斯坦",
		"PT": "葡萄牙",
		"PV": "内网",
		"PW": "帕劳",
		"PY": "巴拉圭",
		"QA": "卡塔尔",
		"RE": "留尼汪",
		"RO": "罗马尼亚",
		"RS": "塞尔维亚",
		"RU": "俄罗斯",
		"RW": "卢旺达",
		"SA": "沙特阿拉伯",
		"SB": "所罗门群岛",
		"SC": "塞舌尔",
		"SD": "苏丹",
		"SE": "瑞典",
		"SG": "新加坡",
		"SH": "圣赫勒拿",
		"SI": "斯洛文尼亚",
		"SJ": "斯瓦尔巴",
		"SK": "斯洛伐克",
		"SL": "塞拉利昂",
		"SM": "圣马力诺",
		"SN": "塞内加尔",
		"SO": "索马里",
		"SR": "苏里南",
		"SS": "南苏丹",
		"ST": "圣多美和普林西比",
		"SV": "萨尔瓦多",
		"SX": "荷属圣马丁",
		"SY": "叙利亚",
		"SZ": "斯威士兰",
		"TC": "特克斯和凯科斯",
		"TD": "乍得",
		"TF": "法属南部领地",
		"TG": "多哥",
		"TH": "泰国",
		"TJ": "塔吉克斯坦",
		"TK": "托克劳",
		"TL": "东帝汶",
		"TM": "土库曼斯坦",
		"TN": "突尼斯",
		"TO": "汤加",
		"TR": "土耳其",
		"TT": "特立尼达和多巴哥",
		"TV": "图瓦卢",
		"TW": "中国台湾",
		"TZ": "坦桑尼亚",
		"UA": "乌克兰",
		"UG": "乌干达",
		"UM": "美国本土外小岛屿",
		"US": "美国",
		"UY": "乌拉圭",
		"UZ": "乌兹别克斯坦",
		"VA": "梵蒂冈",
		"VC": "圣文森特和格林纳丁斯",
		"VE": "委内瑞拉",
		"VG": "英属维尔京群岛",
		"VI": "美属维尔京群岛",
		"VN": "越南",
		"VU": "瓦努阿图",
		"WF": "瓦利斯和富图纳",
		"WS": "萨摩亚",
		"XK": "科索沃",
		"YE": "也门",
		"YT": "马约特",
		"ZA": "南非",
		"ZM": "赞比亚",
		"ZW": "津巴布韦",
		"ZZ": "未知",
	}

func countryName(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" || code == "ZZ" {
		return "未知"
	}
	if n, ok := countryNames[code]; ok {
		return n
	}
	return code
}


func isSelfOrLocalIP(ip, country string) bool {
	if country == "LO" || country == "PV" {
		return true
	}
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return false
	}
	if self := selfPublicIP.Load(); self != nil {
		if s, ok := self.(string); ok && s != "" && s == ip {
			return true
		}
	}
	return false
}
func recordBlocked(ip, country, path, reason, ua string) {
	if isSelfOrLocalIP(ip, country) {
		return
	}
	statsMu.Lock()
	defer statsMu.Unlock()
	day := dayOf(beijingDate(time.Now()))
	// 五类拦截原因全部计数并展示到拦截记录（对应"安全与访问控制"各开关）：
	// cn=地区限制 whitelist=域名白名单 ban=IP黑名单 rate_limit=限流 ua=UA白名单
	switch reason {
	case "cn":
		stats.BlockedCN++
		day.BlockedCN++
	case "ban":
		stats.BlockedBan++
		day.BlockedBan++
	case "rate_limit":
		stats.BlockedRate++
		day.BlockedRate++
	case "ua":
		stats.BlockedUA++
		day.BlockedUA++
	default:
		stats.BlockedWhitelist++
		day.BlockedWL++
	}
	reasonText := blockReasonText(reason)
	if country == "" {
		country = "??"
	}
	ev := BlockEvent{Time: beijingRFC3339(time.Now()), IP: ip, Country: country, Path: path, Reason: reason, ReasonText: reasonText, UA: ua}
	stats.Blocks = append(stats.Blocks, ev)
	if len(stats.Blocks) > maxBlockEvents {
		stats.Blocks = stats.Blocks[len(stats.Blocks)-maxBlockEvents:]
	}
}

// blockReasonText 拦截原因中文描述（后端落盘 ReasonText，前端按 reason 实时渲染）
func blockReasonText(reason string) string {
	switch reason {
	case "cn":
		return "仅允许中国大陆 IP 访问"
	case "ban":
		return "IP 在黑名单中"
	case "rate_limit":
		return "请求超过限流阈值"
	case "ua":
		return "User-Agent 不在允许列表"
	default:
		return "目标域名未在白名单中"
	}
}

const maxBlockEvents = 5000

type geoEntry struct {
	Code   string  `json:"code"`
	Name   string  `json:"name"`
	Region string  `json:"region,omitempty"`
	City   string  `json:"city,omitempty"`
	ISP    string  `json:"isp,omitempty"`
	Org    string  `json:"org,omitempty"`
	AS     string  `json:"as,omitempty"`
	Lat    float64 `json:"lat,omitempty"`
	Lon    float64 `json:"lon,omitempty"`
	At     int64   `json:"at"`
}

var (
	geoMu       sync.RWMutex
	geoMap      = map[string]geoEntry{}
	geoPath     string
	geoInflight int32
	geoGroup    singleflight.Group
)

func geoCacheLoad() {
	if db != nil {
		_ = db.View(func(tx *bolt.Tx) error {
			b := tx.Bucket([]byte("geo"))
			if b != nil {
				if data := b.Get([]byte("data")); data != nil {
					_ = json.Unmarshal(data, &geoMap)
				}
			}
			return nil
		})
	}
	if geoMap == nil {
		geoMap = map[string]geoEntry{}
	}
}
func geoCacheSave() {
	if db == nil {
		return
	}
	geoMu.RLock()
	b, _ := json.Marshal(geoMap)
	geoMu.RUnlock()
	_ = db.Update(func(tx *bolt.Tx) error {
		bk, err := tx.CreateBucketIfNotExists([]byte("geo"))
		if err != nil {
			return err
		}
		return bk.Put([]byte("data"), b)
	})
}

// geoPrune：清理过期与超量 geo 缓存
func geoPrune() {
	const geoMaxEntries = 50000
	now := time.Now().Unix()
	geoMu.Lock()
	for k, e := range geoMap {
		if now-e.At >= 30*86400 {
			delete(geoMap, k)
		}
	}
	// 极端情况兜底：仍超上限则整体重置（下次请求会重新按需拉取）
	if len(geoMap) > geoMaxEntries {
		geoMap = map[string]geoEntry{}
	}
	geoMu.Unlock()
}
func geoParseGeneric(m map[string]any) (geoEntry, error) {
	if data, ok := m["data"].(map[string]any); ok {
		m = data
	}
	if st, ok := m["status"].(string); ok && st == "fail" {
		msg, _ := m["message"].(string)
		return geoEntry{}, fmt.Errorf("api failed: %s", msg)
	}
	raw := ""
	if v, ok := m["country"].(string); ok {
		raw = v
	}
	code := ""
	if v, ok := m["countryCode"].(string); ok {
		code = v
	}
	if code == "" {
		code = raw
	}
	if len(code) > 2 {
		code = ""
	}
	region := ""
	if v, ok := m["regionName"].(string); ok {
		region = v
	}
	city := ""
	if v, ok := m["city"].(string); ok {
		city = v
	}
	if code == "" {
		return geoEntry{}, fmt.Errorf("no code")
	}
	if raw == "" {
		raw = countryName(code)
	}
	return geoEntry{Code: code, Name: raw, Region: region, City: city, At: time.Now().Unix()}, nil
}
func geoFetch(ipStr string) (geoEntry, error) {
	client := &http.Client{Timeout: 4 * time.Second}
	urls := []string{
		"http://ip-api.com/json/" + url.QueryEscape(ipStr) + "?lang=zh-CN&fields=status,message,country,countryCode,regionName,city,isp,org,as,lat,lon,query",
	}
	var last error
	for _, u := range urls {
		resp, err := client.Get(u)
		if err != nil {
			last = err
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		resp.Body.Close()
		var m map[string]any
		if err := json.Unmarshal(body, &m); err == nil {
			if e, err := geoParseGeneric(m); err == nil {
				return e, nil
			} else {
				last = err
			}
		}
	}
	return geoEntry{}, last
}
// ipLabelSync 返回 (国家码, 中文名)。先查缓存/本地库，必要时 singleflight 拉 geo API。
func ipLabelSync(ipStr string) (string, string) {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil {
		return "??", "未知"
	}
	// 严禁 isSelfOrLocalIP(ip, "LO")：传入 "LO" 会恒为 true
	if ip.IsLoopback() {
		return "LO", "本机"
	}
	if ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return "PV", "内网"
	}

	geoMu.RLock()
	e, ok := geoMap[ipStr]
	geoMu.RUnlock()
	if ok && e.Code != "??" && time.Now().Unix()-e.At < 30*86400 {
		return e.Code, e.Name
	}

	v, err, _ := geoGroup.Do(ipStr, func() (interface{}, error) {
		geoMu.RLock()
		cached, ok := geoMap[ipStr]
		geoMu.RUnlock()
		if ok && cached.Code != "??" && time.Now().Unix()-cached.At < 30*86400 {
			return cached, nil
		}
		e, err := geoFetch(ipStr)
		if err == nil {
			geoMu.Lock()
			geoMap[ipStr] = e
			geoMu.Unlock()
		}
		return e, err
	})
	if err == nil {
		e := v.(geoEntry)
		return e.Code, e.Name
	}
	if c := countryOf(ipStr); c != "??" {
		return c, countryName(c)
	}
	return "??", "未知"
}

// checkRateLimit 每 IP 固定 1 分钟窗口；窗口起点与计数均用 atomic，避免热路径加锁。
func checkRateLimit(ip string, limit int) bool {
	if limit <= 0 {
		return true
	}
	val, _ := ipLimiters.LoadOrStore(ip, &rateLimitEntry{})
	entry := val.(*rateLimitEntry)
	now := time.Now().UnixNano()
	// 滑动窗口重置：全部用原子操作，避免并发请求间的 data race
	start := entry.WindowStart.Load()
	if start == 0 || now-start > int64(time.Minute) {
		if entry.WindowStart.CompareAndSwap(start, now) {
			entry.Count.Store(1)
			return 1 <= int64(limit)
		}
		// CAS 失败说明另一并发请求刚重置过窗口，走正常计数
	}
	return entry.Count.Add(1) <= int64(limit)
}

// ---------- 实时连接监控 ----------
// 每个代理请求 liveStart → 结束后 liveEnd 写入环形历史。
// WebSocket /admin/api/live/ws 高频推送 liveSnapshotActive（仅活跃）；
// HTTP /admin/api/live 返回含历史的完整快照。管理端可 liveKill 取消 context。
type liveCtxKey struct{}

type liveConn struct {
	ID      string
	IP      string
	Country string
	Host    string
	Method  string
	Path    string
	Start   time.Time
	Up      atomic.Int64
	Down    atomic.Int64
	cancel  context.CancelFunc // 管理端可主动断开
}

func liveKill(id string) bool {
	if id == "" {
		return false
	}
	v, ok := liveConns.Load(id)
	if !ok {
		return false
	}
	c := v.(*liveConn)
	if c.cancel != nil {
		c.cancel()
		return true
	}
	return false
}

var (
	liveConns    sync.Map // id -> *liveConn
	liveActive   atomic.Int64
	liveUpSum    atomic.Int64
	liveDownSum  atomic.Int64
	liveUpRate   atomic.Int64 // 近 1 秒上行字节
	liveDownRate atomic.Int64
	liveSeq      atomic.Uint64
)

func startLiveRateSampler() {
	go func() {
		var prevU, prevD int64
		t := time.NewTicker(time.Second)
		for range t.C {
			u, d := liveUpSum.Load(), liveDownSum.Load()
			liveUpRate.Store(max64(0, u-prevU))
			liveDownRate.Store(max64(0, d-prevD))
			prevU, prevD = u, d
		}
	}()
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func liveStart(ip, country, host, method, path string) *liveConn {
	id := fmt.Sprintf("%d", liveSeq.Add(1))
	if len(path) > 160 {
		path = path[:160] + "…"
	}
	c := &liveConn{ID: id, IP: ip, Country: country, Host: host, Method: method, Path: path, Start: time.Now()}
	liveConns.Store(id, c)
	liveActive.Add(1)
	return c
}

const liveHistMax = 2000

type liveRow struct {
	ID          string `json:"id"`
	IP          string `json:"ip"`
	Country     string `json:"country"`
	CountryName string `json:"country_name"`
	Host        string `json:"host"`
	Method      string `json:"method"`
	Path        string `json:"path"`
	Up          int64  `json:"up"`
	Down        int64  `json:"down"`
	DurationMs  int64  `json:"duration_ms"`
	Start       string `json:"start"`
	Active      bool   `json:"active"`
	Ended       string `json:"ended,omitempty"`
}

var (
	liveHistMu sync.Mutex
	liveHist   []liveRow // 已结束连接的环形缓冲，供监控页累计展示
)

func liveEnd(c *liveConn) {
	if c == nil {
		return
	}
	now := time.Now()
	row := liveRow{
		ID: c.ID, IP: c.IP, Country: c.Country, CountryName: countryName(c.Country),
		Host: c.Host, Method: c.Method, Path: c.Path,
		Up: c.Up.Load(), Down: c.Down.Load(),
		DurationMs: now.Sub(c.Start).Milliseconds(),
		Start: beijingRFC3339(c.Start),
		Active: false, Ended: beijingRFC3339(now),
	}
	liveHistMu.Lock()
	liveHist = append(liveHist, row)
	if len(liveHist) > liveHistMax {
		liveHist = liveHist[len(liveHist)-liveHistMax:]
	}
	liveHistMu.Unlock()
	liveConns.Delete(c.ID)
	liveActive.Add(-1)
}

// liveSnapshotActive 仅包含当前活跃连接，供 WebSocket 约 500ms 推送一次。
// 前端本页会话自行累计已结束连接，服务端不必每次序列化 liveHist。
func liveSnapshotActive() map[string]any {
	var list []liveRow
	now := time.Now()
	liveConns.Range(func(_, v any) bool {
		c := v.(*liveConn)
		up, down := c.Up.Load(), c.Down.Load()
		list = append(list, liveRow{
			ID: c.ID, IP: c.IP, Country: c.Country, CountryName: countryName(c.Country),
			Host: c.Host, Method: c.Method, Path: c.Path, Up: up, Down: down,
			DurationMs: now.Sub(c.Start).Milliseconds(),
			Start: beijingRFC3339(c.Start), Active: true,
		})
		return true
	})
	// 活跃连接通常很少，按下行排序即可
	sort.Slice(list, func(i, j int) bool { return list[i].Down > list[j].Down })
	return map[string]any{
		"active":      liveActive.Load(),
		"up_bps":      liveUpRate.Load(),
		"down_bps":    liveDownRate.Load(),
		"up_total":    liveUpSum.Load(),
		"down_total":  liveDownSum.Load(),
		"connections": list,
		"history":     0,
		"active_only": true,
	}
}

func liveSnapshot() map[string]any {
	var list []liveRow
	ipAgg := map[string]struct {
		Count   int
		Up      int64
		Down    int64
		Country string
	}{}
	now := time.Now()
	liveConns.Range(func(_, v any) bool {
		c := v.(*liveConn)
		up, down := c.Up.Load(), c.Down.Load()
		list = append(list, liveRow{
			ID: c.ID, IP: c.IP, Country: c.Country, CountryName: countryName(c.Country),
			Host: c.Host, Method: c.Method, Path: c.Path, Up: up, Down: down,
			DurationMs: now.Sub(c.Start).Milliseconds(),
			Start: beijingRFC3339(c.Start), Active: true,
		})
		a := ipAgg[c.IP]
		a.Count++
		a.Up += up
		a.Down += down
		a.Country = c.Country
		ipAgg[c.IP] = a
		return true
	})
	liveHistMu.Lock()
	hist := append([]liveRow(nil), liveHist...)
	liveHistMu.Unlock()
	// 历史在前（旧→新），活跃接在后面；前端会按 id 合并
	list = append(hist, list...)
	for _, r := range hist {
		a := ipAgg[r.IP]
		a.Count++
		a.Up += r.Up
		a.Down += r.Down
		if a.Country == "" {
			a.Country = r.Country
		}
		ipAgg[r.IP] = a
	}
	sort.SliceStable(list, func(i, j int) bool {
		// 活跃优先，再按下行
		if list[i].Active != list[j].Active {
			return list[i].Active
		}
		return list[i].Down > list[j].Down
	})
	type ipRow struct {
		IP          string `json:"ip"`
		Country     string `json:"country"`
		CountryName string `json:"country_name"`
		Conns       int    `json:"conns"`
		Up          int64  `json:"up"`
		Down        int64  `json:"down"`
	}
	var ips []ipRow
	for ip, a := range ipAgg {
		ips = append(ips, ipRow{IP: ip, Country: a.Country, CountryName: countryName(a.Country), Conns: a.Count, Up: a.Up, Down: a.Down})
	}
	sort.Slice(ips, func(i, j int) bool {
		if ips[i].Down != ips[j].Down {
			return ips[i].Down > ips[j].Down
		}
		return ips[i].Conns > ips[j].Conns
	})
	return map[string]any{
		"active":      liveActive.Load(),
		"up_bps":      liveUpRate.Load(),
		"down_bps":    liveDownRate.Load(),
		"up_total":    liveUpSum.Load(),
		"down_total":  liveDownSum.Load(),
		"connections": list,
		"ips":         ips,
		"history":     len(hist),
	}
}

var (
	adminCredPtr atomic.Pointer[adminCred]
)

type adminCred struct{ User, Pass string }

func setAdminCred(u, p string) { adminCredPtr.Store(&adminCred{u, p}) }
func getAdminCred() (string, string) {
	c := adminCredPtr.Load()
	if c == nil {
		return "", ""
	}
	return c.User, c.Pass
}

const (
	sessionCookie = "emby_admin_sid"
	sessionTTL    = 24 * time.Hour
	captchaTTL    = 5 * time.Minute
)

type sessionEntry struct{ Expires time.Time }
type captchaEntry struct {
	Answer  string
	Expires time.Time
}

var (
	sessions sync.Map
	captchas sync.Map
)

func randToken(n int) string {
	b := make([]byte, n)
	_, _ = io.ReadFull(rand.Reader, b)
	return hex.EncodeToString(b)
}

func initSessionsCleanup() {
	go func() {
		t := time.NewTicker(10 * time.Minute)
		for range t.C {
			now := time.Now()
			sessions.Range(func(k, v interface{}) bool {
				if e, ok := v.(sessionEntry); ok && now.After(e.Expires) {
					sessions.Delete(k)
				}
				return true
			})
			captchas.Range(func(k, v interface{}) bool {
				if e, ok := v.(captchaEntry); ok && now.After(e.Expires) {
					captchas.Delete(k)
				}
				return true
			})
		}
	}()
}

func createSession() string {
	tok := randToken(16)
	sessions.Store(tok, sessionEntry{Expires: time.Now().Add(sessionTTL)})
	return tok
}
func validSession(tok string) bool {
	if tok == "" {
		return false
	}
	v, ok := sessions.Load(tok)
	if !ok {
		return false
	}
	e := v.(sessionEntry)
	if time.Now().After(e.Expires) {
		sessions.Delete(tok)
		return false
	}
	return true
}
func destroySession(tok string) {
	if tok != "" {
		sessions.Delete(tok)
	}
}
func getSessionToken(r *http.Request) string {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return ""
	}
	return c.Value
}
func setSessionCookie(w http.ResponseWriter, tok string) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: tok, Path: "/admin", HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: int(sessionTTL.Seconds())})
}
func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/admin", HttpOnly: true, MaxAge: -1})
}

// generateCaptchaSVG 生成 4 位干扰验证码 SVG，答案存 captchas map，TTL 5 分钟。
func generateCaptchaSVG() (id, answer, svg string) {
	const digits = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	rb := make([]byte, 8)
	_, _ = io.ReadFull(rand.Reader, rb)
	ans := make([]byte, 4)
	for i := 0; i < 4; i++ {
		ans[i] = digits[int(rb[i])%len(digits)]
	}
	answer = string(ans)
	id = randToken(8)
	var lines, texts strings.Builder
	for i := 0; i < 6; i++ {
		x1 := (i*20 + int(rb[i%4])) % 140
		y1 := (i*7 + int(rb[(i+1)%4])) % 48
		x2 := (x1 + 30 + int(rb[(i+2)%4])) % 140
		y2 := (y1 + 15 + int(rb[(i+3)%4])) % 48
		lines.WriteString(fmt.Sprintf(`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#cbd5e1" stroke-width="1.2"/>`, x1, y1, x2, y2))
	}
	colors := []string{"#3b82f6", "#2563eb", "#1d4ed8", "#0f172a"}
	for i, ch := range answer {
		x := 18 + i*32 + int(rb[i%4])%6
		y := 32 + int(rb[(i+1)%4])%8
		rot := int(rb[i%4])%20 - 10
		texts.WriteString(fmt.Sprintf(`<text x="%d" y="%d" fill="%s" font-size="28" font-family="Consolas,monospace" font-weight="700" transform="rotate(%d %d %d)">%c</text>`, x, y, colors[i%len(colors)], rot, x, y, ch))
	}
	svg = fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="150" height="48" viewBox="0 0 150 48"><rect width="150" height="48" fill="#f8fafc" rx="8"/>%s%s</svg>`, lines.String(), texts.String())
	captchas.Store(id, captchaEntry{Answer: strings.ToUpper(answer), Expires: time.Now().Add(captchaTTL)})
	return id, answer, svg
}

func verifyCaptcha(id, input string) bool {
	if id == "" || input == "" {
		return false
	}
	v, ok := captchas.Load(id)
	if !ok {
		return false
	}
	captchas.Delete(id)
	e := v.(captchaEntry)
	if time.Now().After(e.Expires) {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(input), e.Answer)
}

// ---------- 管理端认证 ----------
// 会话：Cookie emby_admin_sid，内存 map，TTL 24h；登录需图形验证码。
func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if validSession(getSessionToken(r)) {
			next(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/admin/api/") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"请先登录","redirect":"/admin/login"}`))
			return
		}
		http.Redirect(w, r, "/admin/login", http.StatusFound)
	}
}

const loginHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>登录 · Emby Proxy</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--d:#ef4444;--r:16px}
body{min-height:100dvh;background:var(--bg);color:var(--t);font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:var(--r);padding:40px 36px;max-width:400px;width:100%;box-shadow:0 4px 24px -4px rgba(15,23,42,.06)}
.brand{text-align:center;margin-bottom:28px}
.brand-icon{width:56px;height:56px;border-radius:14px;background:var(--ps);color:var(--p);display:flex;align-items:center;justify-content:center;font-size:26px;margin:0 auto 14px}
.brand h1{font-size:20px;font-weight:700;letter-spacing:-.3px}
.brand p{font-size:13px;color:var(--t3);margin-top:4px}
.fi{margin-bottom:18px}
.fl{display:block;font-size:13px;font-weight:600;margin-bottom:8px;color:var(--t2)}
.inp{width:100%;padding:12px 16px;font-size:14px;background:#f8fafc;border:1px solid var(--bd);border-radius:10px;font-family:inherit;outline:none;transition:.2s}
.inp:focus{background:#fff;border-color:var(--p);box-shadow:0 0 0 4px var(--ps)}
.cap-row{display:flex;gap:12px;align-items:center}
.cap-row .inp{flex:1}
.cap-img{height:48px;border-radius:10px;border:1px solid var(--bd);cursor:pointer;background:#f8fafc;flex-shrink:0}
.cap-img:hover{border-color:var(--p)}
.btn{display:flex;align-items:center;justify-content:center;width:100%;padding:13px 20px;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer;border:0;font-family:inherit;background:var(--p);color:#fff;box-shadow:0 2px 6px rgba(59,130,246,.25);transition:.2s;margin-top:8px}
.btn:hover{background:var(--pd)}
.btn:disabled{opacity:.6;cursor:not-allowed}
.err{background:#fef2f2;color:var(--d);border:1px solid #fecaca;border-radius:10px;padding:10px 14px;font-size:13px;margin-bottom:16px;display:none}
.err.on{display:block}
.foot{text-align:center;margin-top:24px;font-size:12.5px;color:var(--t3)}
</style>
</head>
<body>
<div class="card">
  <div class="brand">
    <div class="brand-icon"><img src="/admin/logo.png" alt="Emby Proxy" style="width:46px;height:46px;border-radius:11px"></div>
    <h1>Emby Proxy</h1>
    <p>管理后台</p>
  </div>
  <div class="err" id="errBox"></div>
  <form id="loginForm" autocomplete="on">
    <div class="fi">
      <label class="fl" for="user">用户名</label>
      <input class="inp" id="user" name="username" type="text" autocomplete="username" required placeholder="用户名">
    </div>
    <div class="fi">
      <label class="fl" for="pass">密码</label>
      <input class="inp" id="pass" name="password" type="password" autocomplete="current-password" required placeholder="密码">
    </div>
    <div class="fi">
      <label class="fl" for="captcha">验证码</label>
      <div class="cap-row">
        <input class="inp" id="captcha" name="captcha" type="text" autocomplete="off" required placeholder="验证码" maxlength="6">
        <img class="cap-img" id="capImg" alt="验证码" title="点击刷新">
      </div>
    </div>
    <button type="submit" class="btn" id="submitBtn">登 录</button>
  </form>
  <div class="foot">Emby Proxy · 路径反代</div>
</div>
<script>
let captchaId = '';
async function loadCaptcha() {
  try {
    const r = await fetch('/admin/api/captcha?t=' + Date.now(), {cache:'no-store'});
    if (!r.ok) throw new Error('验证码加载失败');
    captchaId = r.headers.get('X-Captcha-Id') || '';
    const blob = await r.blob();
    document.getElementById('capImg').src = URL.createObjectURL(blob);
  } catch(e) { console.error(e); }
}
document.getElementById('capImg').addEventListener('click', () => { document.getElementById('captcha').value=''; loadCaptcha(); });
document.getElementById('loginForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errBox = document.getElementById('errBox');
  errBox.classList.remove('on');
  const btn = document.getElementById('submitBtn');
  btn.disabled = true; btn.textContent = '登录中…';
  try {
    const r = await fetch('/admin/api/login', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({
        username: document.getElementById('user').value.trim(),
        password: document.getElementById('pass').value,
        captcha: document.getElementById('captcha').value.trim(),
        captcha_id: captchaId
      })
    });
    const data = await r.json().catch(()=>({}));
    if (!r.ok) {
      errBox.textContent = data.error || '登录失败，请稍后重试';
      errBox.classList.add('on');
      document.getElementById('captcha').value = '';
      loadCaptcha();
      return;
    }
    location.href = '/admin/';
  } catch(err) {
    errBox.textContent = '网络异常，无法连接服务器，请检查网络后重试';
    errBox.classList.add('on');
    loadCaptcha();
  } finally {
    btn.disabled = false; btn.textContent = '登 录';
  }
});
loadCaptcha();
</script>
</body>
</html>`

func saveAdminPassFile(pass string) error {
	if db == nil {
		return fmt.Errorf("db not ready")
	}
	return db.Update(func(tx *bolt.Tx) error {
		bk, err := tx.CreateBucketIfNotExists([]byte("auth"))
		if err != nil {
			return err
		}
		return bk.Put([]byte("admin_pass"), []byte(pass))
	})
}

type statWriter struct {
	http.ResponseWriter
	bytes int64
	live  *liveConn
}

func (w *statWriter) noteDown(n int) {
	if n <= 0 {
		return
	}
	w.bytes += int64(n)
	if w.live != nil {
		w.live.Down.Add(int64(n))
		liveDownSum.Add(int64(n))
	}
}

func (w *statWriter) Write(b []byte) (int, error) {
	n, err := w.ResponseWriter.Write(b)
	w.noteDown(n)
	return n, err
}
func (w *statWriter) WriteHeader(code int) { w.ResponseWriter.WriteHeader(code) }
func (w *statWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func (w *statWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := w.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, fmt.Errorf("no hijacker")
}
func (w *statWriter) ReadFrom(r io.Reader) (int64, error) {
	if rf, ok := w.ResponseWriter.(io.ReaderFrom); ok {
		n, err := rf.ReadFrom(r)
		w.noteDown(int(n))
		return n, err
	}
	buf := make([]byte, 32*1024)
	var total int64
	for {
		nr, er := r.Read(buf)
		if nr > 0 {
			nw, ew := w.Write(buf[:nr])
			total += int64(nw)
			if ew != nil {
				return total, ew
			}
		}
		if er != nil {
			if er == io.EOF {
				return total, nil
			}
			return total, er
		}
	}
}
func (w *statWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// cacheRecorder：仅用于“可缓存候选请求”（GET /Images/...）。
// 关键修复：原实现给【所有】代理请求都套了 io.MultiWriter + bytes.Buffer，
// 即便缓存关闭，视频流等大响应也会在内存里完整复制一份，内存占用巨大。
// 现在：
//   - 非缓存请求直接用 statWriter，零额外内存；
//   - 缓存候选请求才缓冲，且缓冲超过 cacheBodyLimit 后自动停止（不再复制），
//     并记录状态码，只有 200 才写入 LRU。
const cacheBodyLimit = 5 << 20 // 5MB，超过则放弃缓存

type cacheRecorder struct {
	*statWriter
	buf    *bytes.Buffer
	status int
}

func (c *cacheRecorder) WriteHeader(code int) {
	c.status = code
	c.statWriter.WriteHeader(code)
}

func (c *cacheRecorder) Write(b []byte) (int, error) {
	if c.buf != nil && c.status/100 == 2 && c.buf.Len()+len(b) <= cacheBodyLimit {
		c.buf.Write(b) // 尽力而为地缓冲；超限后 buf 置 nil 停止复制
	} else {
		c.buf = nil
	}
	n, err := c.statWriter.Write(b)
	return n, err
}

func (c *cacheRecorder) Flush() {
	// 出现过 Flush（流式响应）说明不是可整体缓存的小图片，停止缓冲
	c.buf = nil
	c.statWriter.Flush()
}

func (c *cacheRecorder) ReadFrom(r io.Reader) (int64, error) {
	// 大体量拷贝（如视频）不走缓冲
	c.buf = nil
	return c.statWriter.ReadFrom(r)
}

type statReadCloser struct {
	io.ReadCloser
	bytes *int64
	live  *liveConn
}

func (r *statReadCloser) Read(p []byte) (int, error) {
	n, err := r.ReadCloser.Read(p)
	if n > 0 {
		if r.bytes != nil {
			atomic.AddInt64(r.bytes, int64(n))
		}
		if r.live != nil {
			r.live.Up.Add(int64(n))
			liveUpSum.Add(int64(n))
		}
	}
	return n, err
}

type switchTransport struct{ v atomic.Value }

func (s *switchTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	t, _ := s.v.Load().(*http.Transport)
	if t == nil {
		return nil, fmt.Errorf("transport nil")
	}
	return t.RoundTrip(r)
}

type bufferPool struct{ pool sync.Pool }

func (b *bufferPool) Get() []byte {
	if v := b.pool.Get(); v != nil {
		return v.([]byte)
	}
	return make([]byte, 32*1024)
}
func (b *bufferPool) Put(p []byte) {
	if cap(p) >= 32*1024 {
		b.pool.Put(p[:32*1024])
	}
}

var proxyBufPool = &bufferPool{}

func newTransport() *http.Transport {
	return &http.Transport{
		Proxy:             http.ProxyFromEnvironment,
		DialContext:       (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2: true, MaxIdleConns: 512, MaxIdleConnsPerHost: 256, IdleConnTimeout: 90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 45 * time.Second, ExpectContinueTimeout: 1 * time.Second,
		DisableCompression: true, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, ClientSessionCache: tls.NewLRUClientSessionCache(256)},
	}
}

var cookieDomainRE = regexp.MustCompile(`(?i);\s*domain=[^;]*`)

func rewriteOriginHeaders(out *http.Request, scheme, host string) {
	if o := out.Header.Get("Origin"); o != "" && o != "null" {
		if u, err := url.Parse(o); err == nil && u.Host != "" && !strings.EqualFold(u.Host, host) {
			out.Header.Set("Origin", scheme+"://"+host)
		}
	}
	if rf := out.Header.Get("Referer"); rf != "" {
		if u, err := url.Parse(rf); err == nil && u.Host != "" && !strings.EqualFold(u.Host, host) {
			u.Scheme = scheme
			u.Host = host
			out.Header.Set("Referer", u.String())
		}
	}
}

// buildProxy 构造反向代理：
//   Rewrite        把路径中的目标写到 Out.URL，并统计上行 Body
//   ModifyResponse 剥离 Set-Cookie Domain、把指回上游的 Location 改成相对路径
//   ErrorHandler   上游失败时返回统一错误页
func buildProxy(tr *switchTransport) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Transport: tr, FlushInterval: 50 * time.Millisecond, BufferPool: proxyBufPool,
		Rewrite: func(pr *httputil.ProxyRequest) {
			t, ok := pr.In.Context().Value(targetCtxKey{}).(*url.URL)
			if !ok || t == nil {
				return
			}
			pr.Out.URL.Scheme = t.Scheme
			pr.Out.URL.Host = t.Host
			pr.Out.URL.Path = t.Path
			pr.Out.URL.RawPath = ""
			pr.Out.URL.RawQuery = pr.In.URL.RawQuery
			pr.Out.Host = t.Host
			pr.SetXForwarded()
			rewriteOriginHeaders(pr.Out, t.Scheme, t.Host)
			if pr.In.Body != nil && pr.In.Body != http.NoBody {
				var upPtr *int64
				if p, ok := pr.In.Context().Value(upBytesCtxKey{}).(*int64); ok {
					upPtr = p
				}
				var lc *liveConn
				if v, ok := pr.In.Context().Value(liveCtxKey{}).(*liveConn); ok {
					lc = v
				}
				if upPtr != nil || lc != nil {
					pr.Out.Body = &statReadCloser{ReadCloser: pr.In.Body, bytes: upPtr, live: lc}
				}
			}
		},
		ModifyResponse: func(resp *http.Response) error {
			upHost := ""
			if resp.Request != nil && resp.Request.URL != nil {
				upHost = resp.Request.URL.Host
			}
			if loc := resp.Header.Get("Location"); loc != "" && upHost != "" {
				if lu, err := url.Parse(loc); err == nil && lu.Host != "" && strings.EqualFold(lu.Host, upHost) {
					lu.Scheme = ""
					lu.Host = ""
					if lu.Path == "" {
						lu.Path = "/"
					}
					resp.Header.Set("Location", lu.String())
				}
			}
			if cks, ok := resp.Header["Set-Cookie"]; ok && len(cks) > 0 {
				for i, c := range cks {
					cks[i] = cookieDomainRE.ReplaceAllString(c, "")
				}
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			msg := "无法连接到上游服务，可能是上游服务器暂时不可用或网络波动，请稍后重试。"
			if err != nil {
				msg += "<br><span style=\"font-size:12px;color:#94a3b8;font-family:Consolas,monospace\">技术详情：" + strings.ReplaceAll(strings.ReplaceAll(err.Error(), "<", "&lt;"), ">", "&gt;") + "</span>"
			}
			serveError(w, http.StatusBadGateway, "上游服务连接失败", msg)
		},
	}
}

type adminConfigResp struct {
	Config
	EffectivePort int `json:"effective_port"`
}

// ---------- PWA：manifest 与 Service Worker ----------
// iconVer 图标资源版本参数：URL 带版本可强制浏览器/系统刷新顽固的 favicon 缓存。
// 更换图标时递增版本号即可。
const iconVer = "?v=3"

// pwaHeadExtra 返回注入到 <head> 的图标/PWA 标签；关闭 PWA 时仅注入基本图标。
func pwaHeadExtra(pwaOn bool) string {
	s := "<link rel=\"icon\" href=\"/favicon.ico" + iconVer + "\">\n" +
		"<link rel=\"apple-touch-icon\" href=\"/admin/icon-192.png" + iconVer + "\">\n"
	if pwaOn {
		s += "<link rel=\"manifest\" href=\"/admin/manifest.webmanifest\">\n" +
			"<meta name=\"theme-color\" content=\"#3b82f6\">\n" +
			"<meta name=\"mobile-web-app-capable\" content=\"yes\">\n" +
			"<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n" +
			"<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n" +
			"<meta name=\"apple-mobile-web-app-title\" content=\"Emby Proxy\">\n"
	}
	return s
}

// pwaBodyExtra 返回注入到 </body> 前的 SW 注册脚本；关闭 PWA 时为空。
func pwaBodyExtra(pwaOn bool) string {
	if !pwaOn {
		return ""
	}
	return "<script>if('serviceWorker' in navigator){window.addEventListener('load',function(){navigator.serviceWorker.register('/admin/sw.js').catch(function(){})})}</script>"
}

// pwaManifestJSON 生成 Web App Manifest（start_url 指向秒开的静态启动页）。
func pwaManifestJSON() []byte {
	m := map[string]any{
		"name":             "Emby Proxy 管理后台",
		"short_name":       "Emby Proxy",
		"description":      "Emby 路径反代管理控制台",
		"start_url":        "/admin/splash",
		"scope":            "/admin/",
		"display":          "standalone",
		"orientation":      "any",
		"background_color": "#f8fafc",
		"theme_color":      "#3b82f6",
		"icons": []map[string]any{
			{"src": "/admin/icon-192.png" + iconVer, "sizes": "192x192", "type": "image/png", "purpose": "any"},
			{"src": "/admin/icon-512.png" + iconVer, "sizes": "512x512", "type": "image/png", "purpose": "any"},
			{"src": "/admin/icon-512.png" + iconVer, "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
		},
	}
	b, _ := json.MarshalIndent(m, "", "  ")
	return b
}

// splashHTML PWA 启动页：纯静态、极轻量（无外链脚本、无 API 阻塞渲染），
// 由 SW 预缓存后秒开；页面显示后并行预热 Chart.js 与登录态检测，就绪即跳转。
const splashHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<link rel="icon" href="/favicon.ico?v=3">
<title>启动中 · Emby Proxy</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100dvh;background:#f8fafc;display:flex;align-items:center;justify-content:center;font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
.wrap{text-align:center}
.logo{width:72px;height:72px;border-radius:18px;display:block;margin:0 auto 18px;box-shadow:0 6px 20px -6px rgba(15,23,42,.15)}
h1{font-size:19px;font-weight:700;color:#0f172a;letter-spacing:-.3px}
.sub{font-size:13px;color:#94a3b8;margin-top:4px}
.spinner{width:30px;height:30px;margin:26px auto 0;border:3px solid #e2e8f0;border-top-color:#3b82f6;border-radius:50%;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.tip{font-size:12px;color:#94a3b8;margin-top:16px}
</style>
</head>
<body>
<div class="wrap">
  <img class="logo" src="/admin/logo.png" alt="Emby Proxy">
  <h1>Emby Proxy</h1>
  <div class="sub">管理控制台</div>
  <div class="spinner"></div>
  <div class="tip" id="tip">正在加载…</div>
</div>
<script>
/* 启动流程：
 * 1. 页面本身零网络依赖（Logo/HTML 均在 SW 预缓存），立即渲染；
 * 2. 后台并行预热 Chart.js（SW cache-first，命中即完成）与登录态探测；
 * 3. 全部就绪或超时（2.5s）后跳转：已登录 → /admin/，未登录 → /admin/login。
 * 跳转用 replace，避免后退键回到启动页。 */
(function () {
  var t0 = Date.now();
  var tip = document.getElementById('tip');
  var CHART_URL = 'https://cdn.bootcdn.net/ajax/libs/Chart.js/4.4.1/chart.umd.min.js';
  function done() {
    var wait = Math.max(0, 400 - (Date.now() - t0)); // 最短展示 400ms，避免闪烁
    setTimeout(function () {
      // 探测登录态：config 需要会话，401/302 → 登录页
      fetch('/admin/api/config', { cache: 'no-store' }).then(function (r) {
        location.replace(r.ok ? '/admin/' : '/admin/login');
      }).catch(function () {
        location.replace('/admin/');
      });
    }, wait);
  }
  // 预热 Chart.js：SW 命中缓存时立即完成；首次访问走网络，超时不阻塞跳转
  var warm;
  if (typeof fetch !== 'undefined') {
    warm = fetch(CHART_URL, { mode: 'no-cors', cache: 'force-cache' }).catch(function () {});
  } else {
    warm = Promise.resolve();
  }
  var timeout = new Promise(function (res) { setTimeout(res, 2500); });
  Promise.race([warm, timeout]).then(function () {
    tip.textContent = '即将进入…';
    done();
  });
})();
</script>
</body>
</html>
`

// swSource 管理后台 Service Worker：
//   · 预缓存应用壳（后台页 + 登录页 + 图标）
//   · 导航请求 stale-while-revalidate：缓存即时返回（PWA 秒开），后台静默更新
//   · Chart.js 等 CDN 脚本运行时缓存（cache-first），二次访问零网络等待
//   · /admin/api/* 一律直连网络，绝不缓存（保证数据实时性）
const swSource = `const CACHE = 'emby-proxy-admin-v4';
const SHELL = ['/admin/splash', '/admin/', '/admin/login', '/admin/logo.png?v=3', '/admin/icon-192.png?v=3', '/admin/icon-512.png?v=3'];
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
function cachePut(req, res) {
  var cp = res.clone();
  caches.open(CACHE).then(function (c) { c.put(req, cp); });
}
self.addEventListener('fetch', function (e) {
  if (e.request.method !== 'GET') return;
  var url;
  try { url = new URL(e.request.url); } catch (err) { return; }
  // Chart.js 等静态 CDN 资源：cache-first，命中即零网络等待
  if (url.origin !== location.origin) {
    if (url.hostname === 'cdn.bootcdn.net') {
      e.respondWith(caches.match(e.request).then(function (hit) {
        if (hit) return hit;
        return fetch(e.request).then(function (res) { cachePut(e.request, res); return res; });
      }));
    }
    return;
  }
  if (url.pathname.indexOf('/admin/api/') === 0) return;
  if (url.pathname === '/admin/sw.js' || url.pathname === '/admin/manifest.webmanifest') return;
  if (e.request.mode === 'navigate') {
    // stale-while-revalidate：有缓存立即返回（秒开），同时后台拉最新版供下次使用；
    // 无缓存时走网络并顺手缓存；离线且无缓存时回退应用壳
    e.respondWith(caches.match(e.request).then(function (hit) {
      if (hit) {
        fetch(e.request).then(function (res) { if (res && res.ok) cachePut(e.request, res); }).catch(function () {});
        return hit;
      }
      return fetch(e.request).then(function (res) {
        if (res && res.ok) cachePut(e.request, res);
        return res;
      }).catch(function () {
        return caches.match('/admin/').then(function (shell) {
          return shell || new Response('当前离线，请连接网络后重试', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
        });
      });
    }));
    return;
  }
  e.respondWith(caches.match(e.request).then(function (hit) {
    if (hit) return hit;
    return fetch(e.request).then(function (res) {
      if (res.ok) cachePut(e.request, res);
      return res;
    });
  }));
});
`

// ---------- gzip 压缩中间件 ----------
// 仅用于管理后台路由（HTML ~80KB / JSON 统计可达 MB 级，压缩后传输量降 70%+）。
// 代理流量（视频流等）不经过本中间件；WS 升级与图片等不可压缩类型自动跳过。
var gzipWriterPool = sync.Pool{New: func() any { return gzip.NewWriter(nil) }}

// gzipCompressible 是否为可压缩类型
func gzipCompressible(ct string) bool {
	ct = strings.ToLower(ct)
	for _, p := range []string{"text/", "application/json", "application/javascript", "application/manifest", "image/svg"} {
		if strings.HasPrefix(ct, p) {
			return true
		}
	}
	return false
}

// gzipResponseWriter 惰性压缩：首个 Write/WriteHeader 时按 Content-Type 决定
type gzipResponseWriter struct {
	http.ResponseWriter
	gz      *gzip.Writer
	decided bool // 已决定是否压缩
	gzOn    bool // 实际启用压缩
}

func (g *gzipResponseWriter) WriteHeader(code int) {
	if !g.decided {
		g.decided = true
		// 处理器已自行输出压缩内容（预压缩缓存）则直接透传，避免二次压缩
		if gzipCompressible(g.Header().Get("Content-Type")) && g.Header().Get("Content-Encoding") == "" {
			h := g.Header()
			h.Set("Content-Encoding", "gzip")
			h.Del("Content-Length")
			h.Add("Vary", "Accept-Encoding")
			g.gz.Reset(g.ResponseWriter)
			g.gzOn = true
		}
	}
	g.ResponseWriter.WriteHeader(code)
}

func (g *gzipResponseWriter) Write(b []byte) (int, error) {
	if !g.decided {
		g.WriteHeader(http.StatusOK)
	}
	if g.gzOn {
		return g.gz.Write(b)
	}
	return g.ResponseWriter.Write(b)
}

// Flush 流式响应透传（压缩时先 flush gzip 缓冲）
func (g *gzipResponseWriter) Flush() {
	if g.gzOn {
		_ = g.gz.Flush()
	}
	if f, ok := g.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack WebSocket 升级透传（升级后数据绕过 gzip 直写底层连接）
func (g *gzipResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := g.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("response writer 不支持 Hijack")
	}
	g.decided = true
	g.gzOn = false
	return h.Hijack()
}

// gzipMiddleware 包装管理后台处理器：客户端支持且非升级请求时启用压缩
func gzipMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") || r.Header.Get("Upgrade") != "" {
			next(w, r)
			return
		}
		gz := gzipWriterPool.Get().(*gzip.Writer)
		gw := &gzipResponseWriter{ResponseWriter: w, gz: gz}
		next(gw, r)
		if gw.gzOn {
			_ = gz.Close() // 写入 gzip 尾部
			gz.Reset(io.Discard)
		}
		gzipWriterPool.Put(gz)
	}
}

// ---------- 预压缩 HTML 缓存 ----------
// 后台/登录/启动页内容固定（仅随 PWA 开关产生 2 个变体），没必要每次请求都 gzip 78KB；
// 首次请求时压缩并缓存，后续直接写字节，省去每请求 ~2-3ms CPU。
var precompressedHTML sync.Map // key: 变体名 -> []byte（gzip 后）

// serveHTMLPrecompressed 输出（预压缩缓存的）HTML：客户端支持 gzip 时命中缓存直写。
func serveHTMLPrecompressed(w http.ResponseWriter, r *http.Request, variant, html, contentType, cacheControl string) {
	w.Header().Set("Content-Type", contentType)
	if cacheControl != "" {
		w.Header().Set("Cache-Control", cacheControl)
	}
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		var data []byte
		if v, ok := precompressedHTML.Load(variant); ok {
			data = v.([]byte)
		} else {
			var buf bytes.Buffer
			gz := gzip.NewWriter(&buf)
			_, _ = gz.Write([]byte(html))
			_ = gz.Close()
			data = buf.Bytes()
			precompressedHTML.Store(variant, data)
		}
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Vary", "Accept-Encoding")
		_, _ = w.Write(data)
		return
	}
	_, _ = w.Write([]byte(html))
}

// adminHandler 注册 /admin 下全部路由（登录页、API、静态后台页）。
func adminHandler() http.HandlerFunc {
	mux := http.NewServeMux()

	mux.HandleFunc("/admin/login", func(w http.ResponseWriter, r *http.Request) {
		if validSession(getSessionToken(r)) {
			http.Redirect(w, r, "/admin/", http.StatusFound)
			return
		}
		pwaOn := currentCfg().PWA
		html := strings.Replace(string(loginHTML), "<head>", "<head>\n"+pwaHeadExtra(pwaOn), 1)
		if extra := pwaBodyExtra(pwaOn); extra != "" {
			html = strings.Replace(html, "</body>", extra+"</body>", 1)
		}
		// 按 PWA 开关两个变体做预压缩缓存（登录页内容固定，无需每次压缩）
		variant := "login-pwa-off"
		if pwaOn {
			variant = "login-pwa-on"
		}
		serveHTMLPrecompressed(w, r, variant, html, "text/html; charset=utf-8", "no-store")
	})
	mux.HandleFunc("/admin/api/captcha", func(w http.ResponseWriter, r *http.Request) {
		id, _, svg := generateCaptchaSVG()
		w.Header().Set("Content-Type", "image/svg+xml")
		w.Header().Set("Cache-Control", "no-store, no-cache")
		w.Header().Set("X-Captcha-Id", id)
		_, _ = w.Write([]byte(svg))
	})
	mux.HandleFunc("/admin/api/login", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "请求方法不支持，请刷新页面后重新登录", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Username  string `json:"username"`
			Password  string `json:"password"`
			Captcha   string `json:"captcha"`
			CaptchaID string `json:"captcha_id"`
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"提交的数据格式有误，请刷新页面后重新登录"}`))
			return
		}
		if !verifyCaptcha(req.CaptchaID, req.Captcha) {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"验证码不正确或已过期，点击图片可刷新验证码后重试"}`))
			return
		}
		u, p := getAdminCred()
		if subtle.ConstantTimeCompare([]byte(req.Username), []byte(u)) != 1 ||
			subtle.ConstantTimeCompare([]byte(req.Password), []byte(p)) != 1 {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"用户名或密码不正确，请注意大小写；忘记密码可在服务器上重置"}`))
			return
		}
		tok := createSession()
		setSessionCookie(w, tok)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/admin/api/logout", func(w http.ResponseWriter, r *http.Request) {
		destroySession(getSessionToken(r))
		clearSessionCookie(w)
		http.Redirect(w, r, "/admin/login", http.StatusFound)
	})

	mux.HandleFunc("/admin/api/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *currentCfg(), EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/save", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "请求方法不支持，请刷新页面后重试", http.StatusMethodNotAllowed)
			return
		}
		// 复用 Config 结构体（与 saveReq 字段完全一致，去掉重复定义）
		var req Config
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "提交的配置格式有误，请检查各项输入后重新保存", http.StatusBadRequest)
			return
		}
		req.GeoAPIURL = strings.TrimSpace(req.GeoAPIURL)
		oldCfg := currentCfg()
		newCfg := &req
		if err := saveConfig(newCfg); err != nil {
			http.Error(w, "配置保存失败，可能是磁盘写入异常，请稍后重试", http.StatusInternalServerError)
			return
		}
		cfgPtr.Store(newCfg)
		rebuildACL(newCfg)
		if newCfg.Port > 0 && newCfg.Port != currentPort() && globalSrv != nil {
			if err := startListen(globalSrv, newCfg.Port); err != nil {
				// 端口切换失败：回滚配置。Transport 与配置无关，无需重建。
				cfgPtr.Store(oldCfg)
				_ = saveConfig(oldCfg)
				http.Error(w, "新端口 "+strconv.Itoa(newCfg.Port)+" 监听失败，可能被其他程序占用或无权限；已自动恢复为原端口 "+strconv.Itoa(oldCfg.Port), http.StatusBadRequest)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *newCfg, EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/traffic", func(w http.ResponseWriter, r *http.Request) {
		// slim=1 轻量模式：概览页 5 秒轮询专用——trend 只含每日汇总（不带分时/主机/IP/国家明细），
		// 避免每次轮询都序列化/传输全量历史明细（长周期下可达 MB 级）；流量页用完整模式。
		slim := r.URL.Query().Get("slim") == "1"
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		var ips, ipBytes, ctry map[string]int64
		var uniqueIPs int
		if slim {
			uniqueIPs = len(stats.IPCounts)
		} else {
			ips = copyInt64Map(stats.IPCounts)
			if ips == nil {
				ips = map[string]int64{}
			}
			ipBytes = copyInt64Map(stats.IPBytes)
			if ipBytes == nil {
				ipBytes = map[string]int64{}
			}
			ctry = copyInt64Map(stats.CountryCounts)
			if ctry == nil {
				ctry = map[string]int64{}
			}
		}

		type TrendItem struct {
			Date      string           `json:"date"`
			Requests  int64            `json:"requests"`
			Bytes     int64            `json:"bytes"`
			Blocked   int64            `json:"blocked"` // 当日全部拦截（五种原因之和）
			BlockedCN int64            `json:"blocked_cn"`
			BlockedWL int64            `json:"blocked_whitelist"`
			Hours     map[string]int64 `json:"hours,omitempty"`
			HourBytes map[string]int64 `json:"hour_bytes,omitempty"`
			Hosts     map[string]int64 `json:"hosts,omitempty"`
			IPs       map[string]int64 `json:"ips,omitempty"`
			Countries map[string]int64 `json:"countries,omitempty"`
		}
		var trend []TrendItem
		hostAll := map[string]int64{}
		for k, d := range stats.Daily {
			if d == nil {
				continue
			}
			if slim {
				// 轻量模式：只带每日汇总数字，跳过全部明细复制（锁内 O(天) 而非 O(全明细)）
				trend = append(trend, TrendItem{
					Date: k, Requests: d.Requests, Bytes: d.Bytes,
					Blocked: d.BlockedCN + d.BlockedWL + d.BlockedBan + d.BlockedRate + d.BlockedUA,
					BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL,
				})
				continue
			}
			ensureDayMaps(d)
			for hk, hv := range d.Hosts {
				hostAll[hk] += hv
			}
			hoursCopy := copyInt64Map(d.Hours)
			hourBytesCopy := copyInt64Map(d.HourBytes)
			hostsCopy := copyInt64Map(d.Hosts)
			ipsCopy := copyInt64Map(d.IPs)
			ctryCopy := copyInt64Map(d.Countries)
			pruneTopN(ipsCopy, 100)
			pruneTopN(ctryCopy, 50)
			pruneTopN(hostsCopy, 50)
		trend = append(trend, TrendItem{
			Date: k, Requests: d.Requests, Bytes: d.Bytes,
			Blocked: d.BlockedCN + d.BlockedWL + d.BlockedBan + d.BlockedRate + d.BlockedUA,
			BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL,
			Hours: hoursCopy, HourBytes: hourBytesCopy, Hosts: hostsCopy,
			IPs: ipsCopy, Countries: ctryCopy,
		})
		}
		sort.Slice(trend, func(i, j int) bool { return trend[i].Date < trend[j].Date })

		labels := map[string]string{}
		for code := range ctry {
			labels[code] = countryName(code)
		}
		today := beijingDate(time.Now())
		todayReqs, todayBytes := stats.TodayRequests, stats.TodayBytes
		if d := stats.Daily[today]; d != nil {
			if todayReqs == 0 {
				todayReqs = d.Requests
			}
			if todayBytes == 0 {
				todayBytes = d.Bytes
			}
		}
		reqs, byts := stats.TotalRequests, stats.TotalBytes
		cn, wl := stats.BlockedCN, stats.BlockedWhitelist
		ban, rate, ua := stats.BlockedBan, stats.BlockedRate, stats.BlockedUA
		pruneTopN(hostAll, 50)
		statsMu.Unlock()

		resp := map[string]any{
			"total_requests": reqs, "total_bytes": byts,
			"today_date": today, "requests": reqs, "bytes": byts,
			"blocked_cn": cn, "blocked_whitelist": wl,
			"blocked_ban": ban, "blocked_rate": rate, "blocked_ua": ua,
			"blocked_total": cn + wl + ban + rate + ua,
			"today_requests": todayReqs, "today_bytes": todayBytes, "trend": trend,
			"uptime_sec":   int64(time.Since(startedAt).Seconds()),
			"stat_dropped": statDropped.Load(),
		}
		if slim {
			resp["unique_ips"] = uniqueIPs
		} else {
			resp["ip_counts"] = ips
			resp["ip_bytes"] = ipBytes
			resp["country_counts"] = ctry
			resp["country_labels"] = labels
			resp["host_counts"] = hostAll // 全周期上游主机汇总，便于后续排行页
		}
		_ = json.NewEncoder(w).Encode(resp)
	})
	mux.HandleFunc("/admin/api/live", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(liveSnapshot())
	})
	mux.HandleFunc("/admin/api/live/close", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost && r.Method != http.MethodDelete {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		id := strings.TrimSpace(r.URL.Query().Get("id"))
		if id == "" {
			var body struct {
				ID string `json:"id"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			id = strings.TrimSpace(body.ID)
		}
		w.Header().Set("Content-Type", "application/json")
		if !liveKill(id) {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"ok":false,"error":"该连接已结束或不存在，可能刚刚已被断开"}`))
			return
		}
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	// WebSocket 实时推送（约 500ms 一帧），失败时前端回退到 HTTP 轮询
	mux.HandleFunc("/admin/api/live/ws", func(w http.ResponseWriter, r *http.Request) {
		if !validSession(getSessionToken(r)) {
			http.Error(w, "请先登录后再操作", http.StatusUnauthorized)
			return
		}
		upgrader := websocket.Upgrader{
			// 管理页同源；允许反代后 Host 不一致时的同站场景
			CheckOrigin:       func(r *http.Request) bool { return true },
			EnableCompression: true,
		}
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(90 * time.Second))
		conn.SetPongHandler(func(string) error {
			_ = conn.SetReadDeadline(time.Now().Add(90 * time.Second))
			return nil
		})
		// 读协程：消费客户端 ping/关闭，避免写阻塞
		done := make(chan struct{})
		go func() {
			defer close(done)
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
					return
				}
			}
		}()
		ticker := time.NewTicker(500 * time.Millisecond)
		pingTicker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		defer pingTicker.Stop()
		writeJSON := func() error {
			_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			// 仅推活跃连接，历史由前端本页会话自行累计
			return conn.WriteJSON(liveSnapshotActive())
		}
		if err := writeJSON(); err != nil {
			return
		}
		for {
			select {
			case <-done:
				return
			case <-pingTicker.C:
				_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			case <-ticker.C:
				if err := writeJSON(); err != nil {
					return
				}
			}
		}
	})
	mux.HandleFunc("/admin/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		// limit 控制返回条数（最新 N 条）：概览轮询只需几条，避免每次全量序列化/传输
		// 最多 5000 条历史；默认 1000，limit=0 表示全部
		limit := 1000
		if s := r.URL.Query().Get("limit"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n >= 0 {
				limit = n
			}
		}
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		n := len(stats.Blocks)
		total := n
		if limit > 0 && n > limit {
			n = limit
		}
		items := make([]map[string]any, n)
		for i := range n {
			// 倒序：最新在前
			src := stats.Blocks[total-1-i]
			items[i] = map[string]any{
				"time": src.Time, "ip": src.IP, "country": src.Country,
				"country_name": countryName(src.Country),
				"path": src.Path, "reason": src.Reason, "reason_text": src.ReasonText, "ua": src.UA,
			}
		}
		statsMu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"total": total, "returned": len(items), "items": items})
	})
	mux.HandleFunc("/admin/api/ip-detail", func(w http.ResponseWriter, r *http.Request) {
		ip := strings.TrimSpace(r.URL.Query().Get("ip"))
		if ip == "" || net.ParseIP(ip) == nil {
			http.Error(w, "IP 地址格式无效，请输入合法的 IPv4/IPv6 地址", http.StatusBadRequest)
			return
		}
		code, name := ipLabelSync(ip)
		geo := geoEntry{}
		if currentCfg().GeoAPI {
			v, err, _ := geoGroup.Do(ip, func() (interface{}, error) {
				geoMu.RLock()
				cached, ok := geoMap[ip]
				geoMu.RUnlock()
				if ok && cached.Code != "??" && time.Now().Unix()-cached.At < 30*86400 {
					return cached, nil
				}
				return geoFetch(ip)
			})
			if err == nil {
				geo = v.(geoEntry)
				geoMu.Lock()
				geoMap[ip] = geo
				geoMu.Unlock()
			}
		}
		if geo.Code != "" {
			code = geo.Code
			name = countryName(code)
		}
		locParts := []string{}
		if name != "未知" {
			locParts = append(locParts, name)
		}
		if geo.Region != "" {
			locParts = append(locParts, geo.Region)
		}
		if geo.City != "" && geo.City != geo.Region {
			locParts = append(locParts, geo.City)
		}
		statsMu.Lock()
		reqs := stats.IPCounts[ip]
		bytes := stats.IPBytes[ip]
		statsMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ip": ip, "country": code, "country_name": name, "region": geo.Region, "city": geo.City, "location": strings.Join(locParts, " · "), "requests": reqs, "bytes": bytes})
	})
	mux.HandleFunc("/admin/api/change-password", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ OldPass, NewPass string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		// 新密码做基本强度校验（原实现允许空密码，会把后台门户大开）
		if len(req.NewPass) < 6 {
			http.Error(w, "新密码至少需要 6 位，请重新输入", http.StatusBadRequest)
			return
		}
		_, pass := getAdminCred()
		if subtle.ConstantTimeCompare([]byte(req.OldPass), []byte(pass)) != 1 {
			http.Error(w, "当前密码不正确，修改未生效，请核对后重试", http.StatusForbidden)
			return
		}
		_ = saveAdminPassFile(req.NewPass)
		setAdminCred("admin", req.NewPass)
		w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/admin/api/clear-stats", func(w http.ResponseWriter, r *http.Request) {
		statsMu.Lock()
		stats = emptyStats()
		snap := marshalStatsLocked()
		statsMu.Unlock()
		persistStats(snap)
		// 物理清空分桶，避免残留日键
		if db != nil {
			_ = db.Update(func(tx *bolt.Tx) error {
				_ = tx.DeleteBucket([]byte("stats_daily"))
				_ = tx.DeleteBucket([]byte("stats_meta"))
				_ = tx.DeleteBucket([]byte("stats_blocks"))
				_ = tx.DeleteBucket([]byte("stats")) // 旧桶兜底
				return nil
			})
			statsMu.Lock()
			snap := marshalStatsLocked()
			statsMu.Unlock()
			persistStats(snap)
		}
		w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/admin/api/flag/", func(w http.ResponseWriter, r *http.Request) {
		code := strings.ToLower(strings.TrimPrefix(r.URL.Path, "/admin/api/flag/"))
		// 本机 / 内网 / 未知：内置 SVG 图标
		if code == "lo" || code == "pv" || code == "??" || code == "%3f%3f" {
			w.Header().Set("Content-Type", "image/svg+xml")
			w.Header().Set("Cache-Control", "public, max-age=86400")
			var svg string
			switch code {
			case "lo":
				svg = `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30" viewBox="0 0 40 30"><rect width="40" height="30" rx="4" fill="#dbeafe"/><text x="20" y="20" text-anchor="middle" font-size="16">💻</text></svg>`
			case "pv":
				svg = `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30" viewBox="0 0 40 30"><rect width="40" height="30" rx="4" fill="#e0e7ff"/><text x="20" y="20" text-anchor="middle" font-size="16">🏠</text></svg>`
			default:
				svg = `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="30" viewBox="0 0 40 30"><rect width="40" height="30" rx="4" fill="#f1f5f9"/><text x="20" y="20" text-anchor="middle" font-size="16">❓</text></svg>`
			}
			_, _ = w.Write([]byte(svg))
			return
		}
		if len(code) != 2 {
			http.NotFound(w, r)
			return
		}
		http.Redirect(w, r, "https://flagcdn.com/w40/"+code+".png", http.StatusFound)
	})
	// ---------- PWA 静态资源（免鉴权：图标/清单/Worker 不含敏感信息，且安装时浏览器可能无 Cookie 拉取）----------
	mux.HandleFunc("/admin/logo.png", func(w http.ResponseWriter, r *http.Request) {
		serveCachedIcon(w, r, &logoData, iconLogoURL)
	})
	mux.HandleFunc("/admin/icon-192.png", func(w http.ResponseWriter, r *http.Request) {
		serveCachedIcon(w, r, &icon192Data, icon192URL)
	})
	mux.HandleFunc("/admin/icon-512.png", func(w http.ResponseWriter, r *http.Request) {
		serveCachedIcon(w, r, &icon512Data, icon512URL)
	})
	mux.HandleFunc("/admin/manifest.webmanifest", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/manifest+json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(pwaManifestJSON())
	})
	mux.HandleFunc("/admin/sw.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		_, _ = w.Write([]byte(swSource))
	})
	mux.HandleFunc("/admin/splash", func(w http.ResponseWriter, r *http.Request) {
		// 预压缩缓存直写；允许 SW 缓存实现秒开，版本随二进制更新
		serveHTMLPrecompressed(w, r, "splash", splashHTML, "text/html; charset=utf-8", "")
	})
	mux.HandleFunc("/admin/api/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		pwaOn := currentCfg().PWA
		html := strings.Replace(string(adminHTML), "<head>", "<head>\n"+pwaHeadExtra(pwaOn), 1)
		if extra := pwaBodyExtra(pwaOn); extra != "" {
			html = strings.Replace(html, "</body>", extra+"</body>", 1)
		}
		// 按 PWA 开关两个变体做预压缩缓存（78KB 页面无需每请求压缩）
		variant := "admin-pwa-off"
		if pwaOn {
			variant = "admin-pwa-on"
		}
		serveHTMLPrecompressed(w, r, variant, html, "text/html; charset=utf-8", "no-cache")
	})
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if path == "/admin/login" || path == "/admin/api/captcha" || path == "/admin/api/login" || path == "/admin/api/logout" ||
			path == "/admin/splash" || path == "/admin/logo.png" || path == "/admin/icon-192.png" || path == "/admin/icon-512.png" ||
			path == "/admin/manifest.webmanifest" || path == "/admin/sw.js" {
			mux.ServeHTTP(w, r)
			return
		}
		requireAuth(mux.ServeHTTP)(w, r)
	}
}

// runServer 进程入口（systemd：… run -port … -admin-pass …）：
// 打开 DB → 迁移旧 JSON → 加载配置/统计 → 启动后台协程 → 监听并阻塞等信号。
func runServer(port int, adminUser, adminPass, dbFile string) {
	// Transport 与配置无关，只在启动时创建一次（见 newTransport 上方说明）
	proxyTr.v.Store(newTransport())
	var err error
	db, err = bolt.Open(dbFile, 0600, &bolt.Options{Timeout: 3 * time.Second})
	if err != nil {
		log.Fatalf("无法打开数据库: %v", err)
	}
	defer db.Close()

	// 数据迁移
	_ = db.Update(func(tx *bolt.Tx) error {
		cfgB := tx.Bucket([]byte("config"))
		if cfgB == nil || cfgB.Get([]byte("data")) == nil {
			cfgPath := filepath.Join(filepath.Dir(dbFile), "config.json")
			if b, err := os.ReadFile(cfgPath); err == nil {
				bk, _ := tx.CreateBucketIfNotExists([]byte("config"))
				_ = bk.Put([]byte("data"), b)
				_ = os.Rename(cfgPath, cfgPath+".bak")
			}
			statsPath := filepath.Join(filepath.Dir(dbFile), "stats.json")
			if b, err := os.ReadFile(statsPath); err == nil {
				bk, _ := tx.CreateBucketIfNotExists([]byte("stats"))
				_ = bk.Put([]byte("data"), b)
				_ = os.Rename(statsPath, statsPath+".bak")
			}
			passPath := filepath.Join(filepath.Dir(dbFile), "admin.pass")
			if b, err := os.ReadFile(passPath); err == nil {
				bk, _ := tx.CreateBucketIfNotExists([]byte("auth"))
				_ = bk.Put([]byte("admin_pass"), b)
				_ = os.Rename(passPath, passPath+".bak")
			}
			geoPath := filepath.Join(filepath.Dir(dbFile), "geo_cache.json")
			if b, err := os.ReadFile(geoPath); err == nil {
				bk, _ := tx.CreateBucketIfNotExists([]byte("geo"))
				_ = bk.Put([]byte("data"), b)
				_ = os.Rename(geoPath, geoPath+".bak")
			}
		}
		return nil
	})

	loadConfig()
	var dbPass string
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("auth"))
		if b != nil {
			dbPass = string(b.Get([]byte("admin_pass")))
		}
		return nil
	})
	if dbPass == "" {
		dbPass = adminPass
		_ = saveAdminPassFile(adminPass)
	}
	setAdminCred(adminUser, dbPass)

	geoCacheLoad()
	loadStats()
	startStatsWorker()
	startLiveRateSampler()
	startStatsSaver()
	detectSelfPublicIP()
	// 图标改为启动时后台预热（favicon/Logo/PWA 图标）：
	// 原实现 faviconOnce.Do 在【第一个请求的处理器里】同步外网 GET（4s 超时），
	// 会把第一个请求卡住数秒。现在启动即拉取，处理器直接读内存。
	go func() {
		faviconData.Store(fetchIcon(iconFaviconURL))
	}()
	go func() {
		logoData.Store(fetchIcon(iconLogoURL))
		icon192Data.Store(fetchIcon(icon192URL))
		icon512Data.Store(fetchIcon(icon512URL))
	}()
	defer func() { saveStatsOnce(); geoCacheSave() }()

	proxy := buildProxy(proxyTr)
	// 代理主处理：静态资源 → ACL → 地区 → 解析目标 → 白名单 → 可选缓存 → 反代并记流量
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/favicon.ico" || r.URL.Path == "/favicon.png" || r.URL.Path == "/favicon.svg" {
			// 读启动时预热的缓存；未预热完成则直接 302 到源站，不阻塞请求
			serveCachedIcon(w, r, &faviconData, iconFaviconURL)
			return
		}
		if isBuiltinAssetPath(r.URL.Path) {
			serveError(w, http.StatusNotFound, "页面不存在", "您访问的地址没有对应的页面，请检查链接是否完整、有无多余或缺失的字符。")
			return
		}
		if r.URL.Path == "/" || r.URL.Path == "" {
			serveHome(w, r)
			return
		}
		ip := getClientIP(r)
		c := currentCfg()

		// 黑名单 & 限流 & UA（ACL 已在保存配置时预编译）；拦截全部记入拦截记录
		clientIP := net.ParseIP(ip)
		if isBannedIP(ip, clientIP) {
			recordBlocked(ip, countryOf(ip), r.URL.RequestURI(), "ban", r.UserAgent())
			serveError(w, http.StatusForbidden, "访问被拒绝", "您的 IP（"+ip+"）已被管理员加入黑名单。如果这是误封，请联系管理员解除。")
			return
		}
		if !checkRateLimit(ip, c.RateLimit) {
			recordBlocked(ip, countryOf(ip), r.URL.RequestURI(), "rate_limit", r.UserAgent())
			serveError(w, http.StatusTooManyRequests, "操作太频繁了", "您在短时间内发送了太多请求，已触发限流保护。请等待约 1 分钟后再试。")
			return
		}
		if !uaAllowed(r.UserAgent()) {
			recordBlocked(ip, countryOf(ip), r.URL.RequestURI(), "ua", r.UserAgent())
			serveError(w, http.StatusForbidden, "客户端不受支持", "您使用的应用（User-Agent）不在允许列表中。请使用 Emby 客户端等已授权应用访问，或联系管理员调整设置。")
			return
		}

		// 地区：热路径优先本地库；仅在需要展示名或 ChinaOnly 不确定时再走 geo
		country := countryOf(ip)
		if c.ChinaOnly && country != "CN" && country != "LO" && country != "PV" {
			// 本地库已能判定非 CN 时不再同步拉 geo API
			recordBlocked(ip, country, r.URL.RequestURI(), "cn", r.UserAgent())
			if c.AutoBan {
				// AutoBan 修复：
				// 1. 原实现持 statsMu（统计锁）时做 saveConfig（bbolt 磁盘写），会卡住所有统计写入；
				// 2. 直接在共享的 cfg.BanList 上 append，与主路径遍历 BanList 并发构成 data race。
				// 现改为 copy-on-write：复制配置生成新 BanList，再原子替换指针，全程不碰统计锁。
				go func(banIP string) {
					old := currentCfg()
					for _, b := range old.BanList {
						if strings.TrimSpace(b) == banIP {
							return
						}
					}
					nc := *old
					nc.BanList = append(append([]string{}, old.BanList...), banIP)
					if err := saveConfig(&nc); err != nil {
						return
					}
					cfgPtr.Store(&nc)
					rebuildACL(&nc)
				}(ip)
			}
			serveError(w, http.StatusForbidden, "地区访问受限", "本服务仅面向中国大陆网络开放，检测到您的 IP 来自其他地区，因此无法访问。")
			return
		}

		target, err := parseTarget(r)
		if err != nil {
			serveHome(w, r)
			return
		}
		if !whitelistMatch(c.Whitelist, target.Host) {
			recordBlocked(ip, country, r.URL.RequestURI(), "whitelist", r.UserAgent())
			serveError(w, http.StatusForbidden, "目标站点未授权", "您要访问的目标域名未在白名单中。请确认地址是否正确；若该站点应被允许，请联系管理员将其加入白名单。")
			return
		}

		if c.CORS {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "*")
			if r.Method == "OPTIONS" {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}

		if c.EnableCache && strings.Contains(r.URL.Path, "/Images/") && r.Method == "GET" {
			if cached, ok := imageCacheGet(r.URL.String()); ok {
				w.Header().Set("Content-Type", "image/jpeg")
				_, _ = w.Write(cached)
				return
			}
		}

		recordRequestStart(ip, country, target.Host)

		reqCtx, cancel := context.WithCancel(r.Context())
		lc := liveStart(ip, country, target.Host, r.Method, r.URL.RequestURI())
		lc.cancel = cancel
		defer cancel()
		defer liveEnd(lc)

		sw := &statWriter{ResponseWriter: w, live: lc}
		var w2 http.ResponseWriter = sw
		if c.EnableCache && strings.Contains(r.URL.Path, "/Images/") && r.Method == "GET" {
			rec := &cacheRecorder{statWriter: sw, buf: &bytes.Buffer{}}
			w2 = rec
		}

		upBytes := new(int64)
		ctx := context.WithValue(reqCtx, targetCtxKey{}, target)
		ctx = context.WithValue(ctx, upBytesCtxKey{}, upBytes)
		ctx = context.WithValue(ctx, liveCtxKey{}, lc)

		proxy.ServeHTTP(w2, r.WithContext(ctx))

		if r2, ok := w2.(*cacheRecorder); ok && r2.status == http.StatusOK && r2.buf != nil && r2.buf.Len() > 0 {
			imageCachePut(r.URL.String(), r2.buf.Bytes())
		}
		recordBytes(ip, sw.bytes+atomic.LoadInt64(upBytes))
	})

	adminSrv := adminHandler()
	// 管理后台全部走 gzip（HTML/JSON 压缩 70%+，WS 与图片自动跳过）
	adminGz := gzipMiddleware(adminSrv)
	root := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/admin" {
			http.Redirect(w, r, "/admin/", http.StatusFound)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/admin/") {
			adminGz.ServeHTTP(w, r)
			return
		}
		proxyHandler(w, r)
	})
	if c := currentCfg(); c.Port > 0 {
		port = c.Port
	}
	srv := &http.Server{Handler: root, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second, MaxHeaderBytes: 32 << 10}
	globalSrv = srv
	if err := startListen(srv, port); err != nil {
		log.Fatalf("监听失败: %v", err)
	}
	log.Printf("服务启动 :%d", port)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	_ = srv.Close()
}

// main 二进制入口。安装脚本以「emby-proxy run -port … -admin-pass …」拉起。
func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "run" {
		args = args[1:]
	}
	fs := flag.NewFlagSet("emby-proxy", flag.ExitOnError)
	port := fs.Int("port", 8520, "监听端口")
	adminUser := fs.String("admin-user", "admin", "用户名")
	adminPass := fs.String("admin-pass", "", "密码")
	dbFile := fs.String("db", "/etc/emby-proxy/emby.db", "数据库")
	_ = fs.Parse(args)
	if *adminPass == "" {
		log.Fatal("必须指定 --admin-pass")
	}
	runServer(*port, *adminUser, *adminPass, *dbFile)
}
GO_SOURCE

  cat > "$dir/admin.html" <<'ADMIN_HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>管理后台 · Emby Proxy</title>
<script defer src="https://cdn.bootcdn.net/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--d:#ef4444;--w:#f59e0b;--ok:#10b981;--mono:Consolas,monospace;--r:12px}
body{background:var(--bg);color:var(--t);font:14px/1.5 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;height:100dvh;overflow:hidden}
/* 侧边栏 */
.sb{width:240px;background:var(--card);border-right:1px solid var(--bd);display:flex;flex-direction:column;transition:transform .3s ease;z-index:100;flex-shrink:0}
.sb-h{padding:24px 20px 16px;display:flex;align-items:center}
.sb-brand{min-width:0;display:flex;flex-direction:column;gap:3px}
.sb-t{font-size:16px;font-weight:700;letter-spacing:-.3px;line-height:1.2;color:var(--t)}
.sb-sub{font-size:12px;color:var(--t3);font-weight:500;letter-spacing:.2px}
.nav{list-style:none;padding:0 12px;flex:1;overflow-y:auto}
.nav-i{display:flex;align-items:center;gap:10px;padding:10px 14px;border-radius:8px;color:var(--t2);cursor:pointer;margin-bottom:4px;border:0;background:transparent;font:inherit;font-size:14px;width:100%;text-align:left;transition:.2s}
.nav-i:hover{background:#f1f5f9;color:var(--t)}
.nav-i.on{background:var(--ps);color:var(--pd);font-weight:600}
.nav-i svg{width:18px;height:18px;flex-shrink:0;opacity:.75}
.nav-i.on svg{opacity:1}
.stc .sl{display:flex;align-items:center;gap:6px}
.stc .sl svg{width:16px;height:16px;opacity:.7}
.sb-brand-icon{width:36px;height:36px;border-radius:10px;background:var(--ps);color:var(--pd);display:flex;align-items:center;justify-content:center;font-size:18px;margin-right:12px;flex-shrink:0}
.sb-f{padding:14px 20px;border-top:1px solid var(--bd);font-size:12px;color:var(--t3)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--ok);margin-right:6px;box-shadow:0 0 0 2px rgba(16,185,129,.2)}
.sb-mask{display:none;position:fixed;inset:0;background:rgba(15,23,42,.4);z-index:90;opacity:0;transition:opacity .3s ease;border:0;padding:0;cursor:pointer;backdrop-filter:blur(2px)}
/* 主内容区 */
.mc{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}
.tb{height:64px;background:var(--card);border-bottom:1px solid var(--bd);display:flex;align-items:center;justify-content:space-between;padding:0 24px;flex-shrink:0;z-index:10}
.tb-l{display:flex;align-items:center;gap:16px}
.mmb{display:none;align-items:center;justify-content:center;width:36px;height:36px;border-radius:8px;border:1px solid var(--bd);background:#fff;color:var(--t);cursor:pointer;font-size:18px;transition:.2s}
.mmb:hover{background:#f1f5f9}
.tb-t{font-size:18px;font-weight:600;letter-spacing:-.3px}
.tb-r{display:flex;align-items:center;gap:12px;font-size:13px;color:var(--t2)}
.chip{display:inline-flex;align-items:center;padding:4px 10px;border-radius:6px;background:#f1f5f9;font-family:var(--mono);font-size:12px;font-weight:500}
.chip.p{background:var(--ps);color:var(--pd);border:1px solid #dbeafe}
.sc{flex:1;overflow-y:auto;padding:24px;scroll-behavior:smooth}
.pg{display:none}
.pg.on{display:block;animation:fadeUp .3s cubic-bezier(0.16, 1, 0.3, 1) forwards}
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
/* 卡片 */
.card{background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:24px;margin-bottom:24px;box-shadow:0 2px 8px -2px rgba(15,23,42,.04);transition:box-shadow .3s ease, transform .3s ease}
.card:hover{box-shadow:0 8px 24px -4px rgba(15,23,42,.08);transform:translateY(-2px)}
.ch{display:flex;justify-content:space-between;margin-bottom:20px;gap:16px;flex-wrap:wrap;align-items:flex-start}
.ct{font-size:16px;font-weight:600;color:var(--t);letter-spacing:-.2px}
.cd{font-size:13px;color:var(--t3);margin-top:4px}
/* 栅格系统 */
.g2{display:grid;grid-template-columns:1fr 1fr;gap:24px}
.g2 .card{margin-bottom:0}
.g3{display:grid;grid-template-columns:2fr 1fr;gap:24px}
.sg{display:grid;grid-template-columns:repeat(4,1fr);gap:20px;margin-bottom:24px}
/* 状态卡片 */
.stc{background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:20px;position:relative;overflow:hidden;transition:.3s}
.stc:hover{transform:translateY(-2px);box-shadow:0 6px 16px -4px rgba(0,0,0,.06)}
.stc::before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;border-radius:4px 0 0 4px}
.stc.b::before{background:#3b82f6}.stc.g::before{background:#10b981}.stc.r::before{background:#ef4444}.stc.o::before{background:#f59e0b}
.sl{font-size:13px;color:var(--t2);font-weight:500}
.sv{font-size:28px;font-weight:700;margin:8px 0 6px;font-variant-numeric:tabular-nums;letter-spacing:-1px;line-height:1.1;color:var(--t)}
.ss{font-size:12px;color:var(--t3);display:flex;justify-content:space-between;align-items:center}
.ss b{font-weight:600;color:var(--t2)}
/* 表单控件 */
.fi{margin-bottom:20px}
.fl{display:block;font-size:13px;font-weight:600;margin-bottom:8px;color:var(--t2)}
.inp,.tarea{width:100%;padding:12px 16px;font-size:14px;background:#f8fafc;border:1px solid var(--bd);border-radius:10px;font-family:inherit;outline:none;transition:.2s}
.inp:focus,.tarea:focus{background:#fff;border-color:var(--p);box-shadow:0 0 0 4px var(--ps)}
.inp.m,.tarea{font-family:var(--mono);font-size:13px}
.tarea{resize:vertical;min-height:100px;line-height:1.6}
/* 按钮 */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:10px 18px;border-radius:10px;font-size:14px;font-weight:500;cursor:pointer;border:1px solid transparent;font-family:inherit;transition:all .2s;white-space:nowrap}
.btn:active{transform:scale(.97)}
.btn.b{background:var(--p);color:#fff;box-shadow:0 2px 4px rgba(59,130,246,.2)}
.btn.b:hover{background:var(--pd);box-shadow:0 4px 8px rgba(59,130,246,.3)}
.btn.g{background:#fff;border-color:var(--bd);color:var(--t2)}
.btn.g:hover{background:#f8fafc;color:var(--t);border-color:#cbd5e1}
.btn.d{background:#fef2f2;color:var(--d);border-color:#fecaca}
.btn.s{padding:8px 14px;font-size:13px}
.btn.d:hover{background:#fee2e2}
.acts{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-top:16px}
/* 行内设置 */
.row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px 0;border-top:1px solid var(--bd)}
.row:first-child{border-top:0;padding-top:0}
.rl{font-size:14px;font-weight:600;color:var(--t)}
.rd{font-size:13px;color:var(--t3);margin-top:4px}
/* 开关 */
.sw{position:relative;width:48px;height:28px;flex-shrink:0}
.sw input{opacity:0;width:0;height:0}
.tr2{position:absolute;cursor:pointer;inset:0;background:#cbd5e1;border-radius:99px;transition:.3s cubic-bezier(0.4, 0, 0.2, 1)}
.tr2::after{content:"";position:absolute;height:22px;width:22px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:.3s cubic-bezier(0.4, 0, 0.2, 1);box-shadow:0 1px 3px rgba(0,0,0,.15)}
.sw input:checked+.tr2{background:var(--p)}
.sw input:checked+.tr2::after{transform:translateX(20px)}
/* 其他 */
.hint{font-size:12.5px;color:var(--t3);margin-top:8px;line-height:1.6}
.emp{padding:48px 20px;text-align:center;color:var(--t3);font-size:14px}
.emp b{display:block;color:var(--t2);font-size:15px;margin-bottom:6px}
/* 拦截原因标签：五类拦截（地区/白名单/黑名单/限流/UA）统一配色 */
.pill{display:inline-flex;align-items:center;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:500;line-height:1.4;white-space:nowrap}
.pill.pc{background:#fff7ed;color:#c2410c;border:1px solid #fed7aa}
.pill.pw{background:#eff6ff;color:#1d4ed8;border:1px solid #bfdbfe}
.pill.pb{background:#fef2f2;color:#b91c1c;border:1px solid #fecaca}
.pill.pl{background:#fdf4ff;color:#a21caf;border:1px solid #f5d0fe}
.pill.pu{background:#ecfeff;color:#0e7490;border:1px solid #a5f3fc}
.flg{width:22px;height:16px;object-fit:cover;border-radius:3px;box-shadow:0 0 0 1px rgba(0,0,0,.08);background:#e2e8f0;margin-right:8px;vertical-align:middle}
/* 分段器 */
.flt{display:inline-flex;background:#f1f5f9;padding:4px;border-radius:12px;border:1px solid var(--bd);gap:4px;align-items:center;flex-wrap:wrap}
.filter{border:0;background:transparent;color:var(--t2);padding:8px 16px;border-radius:8px;font-size:13px;font-weight:500;font-family:inherit;cursor:pointer;transition:all .2s ease}
.filter:hover{color:var(--t)}
.filter.on{background:#ffffff;color:var(--pd);font-weight:600;box-shadow:0 2px 4px rgba(0,0,0,.05),0 1px 2px rgba(0,0,0,.05)}
/* 进度条 */
.dr{display:flex;align-items:center;gap:12px;padding:10px 0;flex-wrap:nowrap}
.dn{width:110px;flex-shrink:0;display:flex;align-items:center;gap:6px;font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden}
.dn .tx{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dn.m{font-family:var(--mono);font-size:12px}
.bar{flex:1;height:8px;background:#f1f5f9;border-radius:99px;overflow:hidden;min-width:50px}
.bar>i{display:block;height:100%;border-radius:99px;transition:width .4s ease-out}
.bar.i>i{background:var(--p)}.bar.t>i{background:#10b981}
.dv{width:80px;text-align:right;font-size:13px;font-weight:600;font-variant-numeric:tabular-nums;flex-shrink:0}
.dv span{color:var(--t3);font-size:12px;margin-left:4px;font-weight:normal}
/* 表格 */
.table-wrap{overflow-x:auto;border-radius:8px;border:1px solid var(--bd);-webkit-overflow-scrolling:touch}
table{width:100%;border-collapse:collapse;text-align:left;min-width:600px}
th{padding:14px 16px;border-bottom:1px solid var(--bd);font-size:12.5px;font-weight:600;color:var(--t2);background:#f8fafc;white-space:nowrap}
td{padding:14px 16px;border-bottom:1px solid var(--bd);font-size:13.5px;color:var(--t2)}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover td{background:#f8fafc}
/* 实时监控 · 连接面板风格 */
.live-conn-table{min-width:960px;font-size:13px}
.live-conn-table th{padding:10px 12px;font-size:12px;font-weight:500;color:var(--t3)}
.live-conn-table td{padding:10px 12px;font-size:13px;vertical-align:middle}
.live-conn-table tbody tr.lv-active td{background:rgba(59,130,246,.03)}
.live-conn-table .lv-host{font-family:var(--mono);font-weight:600;color:var(--t);word-break:break-all}
.live-conn-table .lv-path{font-family:var(--mono);font-size:12px;color:var(--t3);max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:inline-block;vertical-align:bottom}
.live-conn-table .lv-rate{font-family:var(--mono);font-variant-numeric:tabular-nums;white-space:nowrap}
.live-conn-table .lv-rate.on{color:var(--ok);font-weight:600}
.live-conn-table .lv-bytes{font-family:var(--mono);font-variant-numeric:tabular-nums;white-space:nowrap;color:var(--t2)}
.live-conn-table .lv-ago{color:var(--t3);white-space:nowrap;font-size:12.5px}
.live-conn-table .lv-src{display:flex;flex-direction:column;gap:2px;min-width:0}
.live-conn-table .lv-src .ip{font-family:var(--mono);color:var(--pd);font-weight:600}
.live-conn-table .lv-src .rg{font-size:12px;color:var(--t3)}
.lv-x{width:28px;height:28px;border:0;border-radius:8px;background:transparent;color:var(--t3);cursor:pointer;font-size:16px;line-height:1;display:inline-flex;align-items:center;justify-content:center;transition:.15s}
.lv-x:hover{background:#fef2f2;color:var(--d)}
.lv-x:disabled{opacity:.35;cursor:default;pointer-events:none}
.lv-type{display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:6px;background:#f1f5f9;font-size:12px;font-weight:500;color:var(--t2);white-space:nowrap}
.lv-type.on{background:var(--ps);color:var(--pd)}
.cell-v{display:inline}
td[data-label="访问路径"] .cell-v{display:inline-block;max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom}
/* 弹窗 */
.mo{position:fixed;inset:0;z-index:1000;display:none;background:rgba(15,23,42,.5);padding:20px;overflow-y:auto;backdrop-filter:blur(4px)}
.mo.on{display:flex;align-items:center;justify-content:center;animation:moFadeIn .2s ease}
@keyframes moFadeIn{from{opacity:0}to{opacity:1}}
.mbox{background:#fff;border-radius:20px;width:100%;max-width:540px;max-height:90dvh;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 20px 40px -10px rgba(0,0,0,.2);animation:mboxScaleIn .3s cubic-bezier(0.16, 1, 0.3, 1)}
@keyframes mboxScaleIn{from{opacity:0;transform:scale(0.95) translateY(10px)}to{opacity:1;transform:scale(1) translateY(0)}}
.mh{padding:20px 24px;border-bottom:1px solid var(--bd);display:flex;justify-content:space-between;align-items:center;flex-shrink:0}
.mh h3{font-size:17px;font-weight:600;color:var(--t)}
.mcl{border:0;background:#f1f5f9;width:36px;height:36px;border-radius:10px;font-size:20px;color:var(--t2);cursor:pointer;display:flex;align-items:center;justify-content:center;transition:.2s}
.mcl:hover{background:#e2e8f0;color:var(--t)}
.mb{padding:24px;overflow-y:auto;overflow-x:hidden;flex:1;min-height:0}
.kv{display:flex;gap:16px;padding:14px 0;border-bottom:1px solid var(--bd);font-size:14px}
.kv:last-child{border-bottom:0}
.kk{width:70px;flex-shrink:0;color:var(--t3)}
.kvv{flex:1;word-break:break-all;font-weight:500;color:var(--t)}
.kvv.m{font-family:var(--mono);font-size:13px}

/* --- 响应式适配 --- */
@media(max-width:1024px){
  .sb{position:fixed;top:0;bottom:0;left:0;transform:translateX(-100%);box-shadow:20px 0 40px rgba(0,0,0,.1)}
  .sb.open{transform:translateX(0)}
  .sb-mask.on{display:block;opacity:1}
  .mmb{display:inline-flex}
  .mc{width:100%}
}
@media(max-width:900px){
  .sg{grid-template-columns:repeat(2,1fr);gap:16px}
  .g2,.g3{grid-template-columns:1fr;gap:20px}
  .g2 .card,.g3 .card{margin-bottom:0}
}
@media(max-width:600px){
  .tb{padding:0 12px;padding-left:max(12px,env(safe-area-inset-left));padding-right:max(12px,env(safe-area-inset-right));height:56px}
  .tb-t{font-size:16px}
  .sc{padding:12px;padding-bottom:max(16px,env(safe-area-inset-bottom));padding-left:max(12px,env(safe-area-inset-left));padding-right:max(12px,env(safe-area-inset-right))}
  .card{padding:16px;border-radius:12px;margin-bottom:14px}
  .sg{grid-template-columns:1fr;gap:10px;margin-bottom:14px}
  .stc{padding:14px}
  .sv{font-size:22px}
  .flt{width:100%;justify-content:space-between;flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch}
  .filter{padding:6px 8px;font-size:12px;flex:1;text-align:center;min-width:0}
  .dn{width:min(90px,28vw);font-size:12px}
  .dv{width:auto;min-width:52px;font-size:12px}
  .dr{gap:8px;padding:10px 0}
  .bar{min-width:36px}
  .ch{flex-wrap:wrap;gap:8px}
  .row{flex-wrap:wrap;gap:10px;padding:14px 0}
  .rl{font-size:13.5px}
  .rd{font-size:12.5px}
  .acts{margin-top:12px}
  .btn{padding:10px 14px;font-size:13px}
  .inp,.tarea{font-size:16px}
  .inp.m,.tarea{font-size:15px}
  
  .table-wrap{border:0;overflow:visible;width:100%}
  table{min-width:0!important;width:100%}
  table, thead, tbody, th, td, tr{display:block;width:100%}
  thead{display:none}
  tbody{width:100%}
  tr{border:1px solid var(--bd);border-radius:12px;margin-bottom:12px;padding:4px 0;background:#fff;box-shadow:0 1px 2px rgba(15,23,42,.04)}
  tr:last-child{margin-bottom:0}
  td{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;padding:10px 14px;border:0;font-size:13px;line-height:1.45;color:var(--t);min-width:0}
  td::before{content:attr(data-label);font-weight:600;color:var(--t3);font-size:12px;flex:0 0 auto;max-width:38%;line-height:1.45}
  td .cell-v{flex:1;min-width:0;text-align:right;word-break:break-word;overflow-wrap:anywhere;color:var(--t)}
  td .cell-v.mono{font-family:var(--mono);font-size:12.5px}
  td .cell-v.muted{color:var(--t3);font-size:12.5px}
  td[data-label="访问路径"]{flex-direction:column;align-items:stretch;gap:6px}
  td[data-label="访问路径"]::before{max-width:none}
  td[data-label="访问路径"] .cell-v{text-align:left;white-space:normal;overflow:visible;max-width:none!important;font-family:var(--mono);font-size:12px;color:var(--t2);background:#f8fafc;border:1px solid var(--bd);border-radius:8px;padding:8px 10px}
  tr.emp-row, td[colspan]{display:block;border:0;padding:24px 12px;text-align:center}
  tr.emp-row::before, td[colspan]::before{display:none;content:none}
  
  .mo{padding:max(12px,env(safe-area-inset-top)) max(12px,env(safe-area-inset-right)) max(12px,env(safe-area-inset-bottom)) max(12px,env(safe-area-inset-left))}
  .mbox{max-height:92dvh;border-radius:16px}
  .mh{padding:14px 16px}
  .mb{padding:16px}
  .kv{flex-wrap:wrap;gap:6px 12px}
  .kk{width:auto;min-width:64px}
  
  .card canvas{max-width:100%}
  
  .sb{padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}
}
</style>
</head>
<body>
<button class="sb-mask" id="sbMask" aria-label="关闭菜单"></button>
<aside class="sb" id="sb">
<div class="sb-h" style="display:flex;align-items:center">
  <div class="sb-brand-icon"><img src="/admin/logo.png" alt="Emby Proxy" style="width:30px;height:30px;border-radius:7px"></div>
  <div class="sb-brand"><div class="sb-t">Emby Proxy</div><div class="sb-sub">管理控制台</div></div>
</div>
<ul class="nav">
<li><button class="nav-i on" data-t="overview"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>概览</button></li>
<li><button class="nav-i" data-t="traffic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 14l4-4 4 4 5-6"/></svg>流量请求</button></li>
<li><button class="nav-i" data-t="live"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 12h-4l-3 9L9 3l-3 9H2"/></svg>实时监控</button></li>
<li><button class="nav-i" data-t="blocks"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/></svg>拦截记录</button></li>
<li><button class="nav-i" data-t="settings"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/></svg>网关设置</button></li>
</ul>
<div class="sb-f" style="display:flex;align-items:center;justify-content:space-between;gap:8px">
  <span><span class="dot"></span><span id="uptimeChip">运行中</span></span>
  <button type="button" id="logoutBtn" style="border:0;background:transparent;color:var(--t3);font-size:12px;cursor:pointer;padding:4px 8px;border-radius:6px" title="退出登录">退出</button>
</div>
</aside>
<div class="mc">
<header class="tb">
<div class="tb-l"><button class="mmb" id="mmb">☰</button><h1 class="tb-t" id="pt">概览</h1></div>
<div class="tb-r"><span class="chip p" id="portChip">:—</span></div>
</header>
<div class="sc">
<section id="overview" class="pg on">
<div class="ch" style="margin-bottom:14px;justify-content:flex-start;">
  <div class="flt" id="ovRangeBar">
    <button class="filter on" data-r="today">今天</button>
    <button class="filter" data-r="yesterday">昨天</button>
    <button class="filter" data-r="7d">近 7 天</button>
    <button class="filter" data-r="30d">近 30 天</button>
    <button class="filter" data-r="all">全部</button>
  </div>
</div>
<div class="sg">
<div class="stc b"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 14l4-4 4 4 5-6"/></svg>请求总数</div><div class="sv" id="ovReq">-</div><div class="ss">流量 <b id="ovBytes">0 B</b></div></div>
<div class="stc g"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>平均每日请求</div><div class="sv" id="ovAvgReq">-</div><div class="ss">日均流量 <b id="ovAvgBytes">0 B</b></div></div>
<div class="stc r"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/></svg>拦截次数</div><div class="sv" id="ovBlocked" style="color:var(--d)">-</div><div class="ss">全部拦截类型</div></div>
<div class="stc o"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></svg>独立 IP</div><div class="sv" id="uniqueIPs">-</div><div class="ss">实时统计</div></div>
</div>
<div class="g3">
<div>
<div class="card" style="margin-bottom:22px;"><div class="ch"><div><h2 class="ct">请求趋势</h2></div></div><div style="position:relative;height:220px"><canvas id="miniTrendChart"></canvas></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">系统信息</h2></div></div><div id="sysInfo"></div></div>
</div>
<div class="card"><div class="ch"><div><h2 class="ct">最新拦截</h2></div><button class="btn g s" data-goto="blocks">查看全部</button></div><div id="ovBlocks"></div></div>
</div>
</section>
<section id="traffic" class="pg">
<div class="ch" style="margin-bottom:14px;justify-content:flex-start;flex-wrap:wrap;gap:10px">
  <div class="flt" id="tfRangeBar">
    <button class="filter on" data-r="today">今天</button>
    <button class="filter" data-r="7d">近 7 天</button>
    <button class="filter" data-r="30d">近 30 天</button>
    <button class="filter" data-r="365d">近一年</button>
    <button class="filter" data-r="all">全部</button>
    <button class="filter" data-r="custom">自定义</button>
  </div>
  <div id="tfCustomBox" style="display:none;align-items:center;gap:8px;flex-wrap:wrap">
    <input type="date" id="tfFrom" class="inp m" style="width:auto;padding:8px 10px;font-size:13px">
    <span style="color:var(--t3)">至</span>
    <input type="date" id="tfTo" class="inp m" style="width:auto;padding:8px 10px;font-size:13px">
    <button class="btn b s" id="tfApplyCustom" type="button">应用</button>
  </div>
</div>
<div class="sg" style="margin-bottom:18px">
  <div class="stc b"><div class="sl">区间请求</div><div class="sv" id="tfReq">-</div><div class="ss" id="tfReqHint">—</div></div>
  <div class="stc g"><div class="sl">区间流量</div><div class="sv" id="tfBytes">-</div><div class="ss" id="tfBytesHint">—</div></div>
  <div class="stc o"><div class="sl">独立 IP</div><div class="sv" id="tfIPs">-</div><div class="ss">当前筛选</div></div>
  <div class="stc r"><div class="sl">拦截次数</div><div class="sv" id="tfBlocked" style="color:var(--d)">-</div><div class="ss">当前筛选</div></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct" id="tfReqTitle">请求量趋势</h2><div class="cd" id="tfReqDesc">按天统计请求次数</div></div></div>
<div style="position:relative;height:260px"><canvas id="reqChart"></canvas></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct" id="tfByteTitle">流量消耗趋势</h2><div class="cd" id="tfByteDesc">按天统计上下行流量</div></div></div>
<div style="position:relative;height:260px"><canvas id="byteChart"></canvas></div>
</div>
<div class="card" style="margin-top:0">
<div class="ch"><div><h2 class="ct" id="tfHostTitle">上游主机趋势</h2><div class="cd" id="tfHostDesc">筛选区间内访问最多的上游</div></div></div>
<div style="position:relative;height:240px"><canvas id="hostChart"></canvas></div>
</div>
<div class="g2" style="margin-top:22px">
<div class="card"><div class="ch"><div><h2 class="ct">请求 IP 排行</h2><div class="cd">按当前时间范围汇总</div></div></div><div id="ipDist"></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">地区来源分布</h2><div class="cd">按当前时间范围汇总</div></div></div><div id="regionDist"></div></div>
</div>
</section>
<section id="live" class="pg">
<div class="sg" style="margin-bottom:18px">
  <div class="stc b"><div class="sl">当前连接</div><div class="sv" id="lvActive">0</div><div class="ss">正在代理的请求</div></div>
  <div class="stc g"><div class="sl">下行速率</div><div class="sv" id="lvDown">0 B/s</div><div class="ss">近 1 秒</div></div>
  <div class="stc o"><div class="sl">上行速率</div><div class="sv" id="lvUp">0 B/s</div><div class="ss">近 1 秒</div></div>
  <div class="stc r"><div class="sl">记录数</div><div class="sv" id="lvIPCount">0</div><div class="ss">本页累计连接</div></div>
</div>
<div class="card">
  <div class="ch"><div><h2 class="ct">连接记录</h2><div class="cd">风格参考代理连接面板 · 离开本页即清空 · 可断开进行中的连接</div></div>
    <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
      <span class="chip" id="lvRefreshHint" style="font-size:12px;color:var(--t3)">连接中…</span>
      <button type="button" class="btn g s" id="lvClearBtn">清空本页记录</button>
    </div>
  </div>
  <div class="table-wrap"><table class="live-conn-table"><thead><tr>
    <th style="width:40px"></th>
    <th>主机</th>
    <th>类型</th>
    <th>来源</th>
    <th>路径</th>
    <th>下载速度</th>
    <th>上传速度</th>
    <th>下载</th>
    <th>上传</th>
    <th>连接时间</th>
  </tr></thead><tbody id="lvConnTable"></tbody></table></div>
  <div id="lvConnPager" style="display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:12px;flex-wrap:wrap;font-size:13px;color:var(--t2)"></div>
</div>
<div class="card">
  <div class="ch"><div><h2 class="ct">按 IP 汇总</h2><div class="cd">基于本页累计记录</div></div></div>
  <div class="table-wrap"><table><thead><tr><th>IP</th><th>地区</th><th>连接</th><th>下行</th><th>上行</th></tr></thead><tbody id="lvIPTable"></tbody></table></div>
  <div id="lvIPPager" style="display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:12px;flex-wrap:wrap;font-size:13px;color:var(--t2)"></div>
</div>
</section>
<section id="blocks" class="pg">
<div class="card">
<div class="ch"><div><h2 class="ct">拦截记录</h2><div class="cd">因黑名单、地区、白名单、限流或 UA 策略被拒绝的请求 · 每 5 秒自动刷新</div></div></div>
<div class="table-wrap"><table><thead><tr><th>时间</th><th>IP 地址</th><th>国家/地区</th><th>拦截原因</th><th>访问路径</th><th>User-Agent</th></tr></thead><tbody id="blockTable"></tbody></table></div>
</div>
</section>
<section id="settings" class="pg">
<div class="g2">
  <div style="display:flex;flex-direction:column;gap:24px;">
    <div class="card" style="margin-bottom:0;">
      <div class="ch"><div><h2 class="ct">基础服务设置</h2></div></div>
      <div class="fi"><label class="fl">监听端口</label><div style="display:flex;gap:12px;align-items:center"><input id="portInput" class="inp m" type="number" style="max-width:140px"><button class="btn b" id="savePort">保存并重启监听</button></div></div>
      <div class="row"><div><div class="rl">开启 CORS 跨域</div><div class="rd">缓解部分播放器跨域拉流失败</div></div><label class="sw"><input type="checkbox" id="corsToggle"><span class="tr2"></span></label></div>
      <div class="row"><div><div class="rl">缓存海报图片</div><div class="rd">缓存上游图片资源，减轻回源压力</div></div><label class="sw"><input type="checkbox" id="cacheToggle"><span class="tr2"></span></label></div>
      <div class="row"><div><div class="rl">PWA 模式</div><div class="rd">后台可安装到手机/电脑桌面，全屏运行并支持离线打开；保存后刷新页面生效</div></div><label class="sw"><input type="checkbox" id="pwaToggle"><span class="tr2"></span></label></div>
      <div class="row" id="pwaInstallRow" style="display:none"><div><div class="rl">安装到主屏幕</div><div class="rd">安装后从桌面图标秒开启动页进入后台</div></div><button type="button" class="btn b s" id="pwaInstallBtn">安装应用</button></div>
    </div>
    
    <div class="card" style="border-color:#fecaca;margin-bottom:0;">
      <div class="ch"><div><h2 class="ct" style="color:var(--d)">安全设置</h2></div></div>
      <div class="fi"><label class="fl">修改管理密码</label>
        <div style="display:grid;gap:10px">
          <input id="oldPass" class="inp m" type="password" placeholder="当前密码">
          <input id="newPass" class="inp m" type="password" placeholder="新密码（至少 6 位）">
        </div>
        <div class="acts"><button class="btn d" id="changePassBtn">修改密码</button></div>
      </div>
      <div class="row" style="margin-top:20px"><div><div class="rl" style="color:var(--d)">清空统计数据</div><div class="rd">将删除请求、流量与拦截记录，不可恢复</div></div><button class="btn d" id="clearStatsBtn">清空数据</button></div>
    </div>
  </div>
  
  <div class="card" style="margin-bottom:0;">
    <div class="ch"><div><h2 class="ct">安全与访问控制</h2></div></div>
    <div class="row"><div><div class="rl">仅允许中国大陆 IP</div><div class="rd">非大陆来源将被拒绝</div></div><label class="sw"><input type="checkbox" id="chinaOnly"><span class="tr2"></span></label></div>
    <div class="row"><div><div class="rl">自动封禁异常 IP</div><div class="rd">触发地区或白名单拦截时写入黑名单</div></div><label class="sw"><input type="checkbox" id="autoBan"><span class="tr2"></span></label></div>
    <div class="fi" style="margin-top:14px"><label class="fl">限流（次/分钟，0 为关闭）</label><input id="rateLimit" type="number" class="inp m" placeholder="例如 120"></div>
    <div class="fi"><label class="fl">UA 白名单</label><div class="hint" style="margin-bottom:8px">每行一个关键字，留空表示不限制</div><textarea id="allowedUAs" class="tarea" placeholder="Infuse&#10;Emby"></textarea></div>
    <div class="fi"><label class="fl">域名白名单</label><div class="hint" style="margin-bottom:8px">每行一个域名，支持根域名匹配</div><textarea id="whitelist" class="tarea" placeholder="example.com"></textarea></div>
    <div class="fi"><label class="fl">IP 黑名单</label><div class="hint" style="margin-bottom:8px">每行一个 IP，支持 CIDR</div><textarea id="banList" class="tarea" placeholder="1.1.1.1"></textarea></div>
    <div class="acts"><button class="btn b" id="saveAll" style="width:100%">保存设置</button></div>
  </div>
</div>
</section>
</div>
</div>
<div class="mo" id="modal"><div class="mbox"><div class="mh"><h3 id="modalTitle">记录详情</h3><button class="mcl" id="modalClose">×</button></div><div class="mb" id="modalBody"></div></div></div>
<script>
/* ========== 管理后台前端逻辑 ==========
 * 页面：overview / traffic / live / blocks / settings
 * 实时监控：优先 WebSocket，失败回退轮询；离开页清空本页累计
 * 时间：fmtBeijing → Asia/Shanghai；流量图大跨度按周/月聚合
 */
const state={port:0,labels:{},ovRange:'today',tfRange:'today',tfFrom:'',tfTo:''};
let ovTrendData=[];

function fmtBytes(b){if(!b)return '0 B';if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB'}
/**
 * 统一按北京时间展示。
 * @param {string|Date} iso
 * @param {'full'|'date'|'time'|'hm'} [mode]
 */
function fmtBeijing(iso, mode){
  if(iso==null||iso==='') return '-';
  let d;
  if(iso instanceof Date) d=iso;
  else {
    const s=String(iso).trim();
    if(/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/.test(s) && !/[zZ]|[+-]\d{2}:?\d{2}$/.test(s)){
      const norm=s.replace('T',' ').replace(/\.\d+$/,'');
      if(mode==='time') return norm.slice(11,19);
      if(mode==='hm') return norm.slice(11,16);
      if(mode==='date') return norm.slice(0,10);
      return norm.slice(0,19);
    }
    d=new Date(s);
  }
  if(isNaN(d.getTime())){
    const s=String(iso).replace('T',' ').replace('Z','');
    if(mode==='time') return s.slice(11,19)||s;
    if(mode==='hm') return s.slice(11,16)||s;
    if(mode==='date') return s.slice(0,10)||s;
    return s.slice(0,19)||s;
  }
  const parts=new Intl.DateTimeFormat('en-GB',{
    timeZone:'Asia/Shanghai',
    year:'numeric',month:'2-digit',day:'2-digit',
    hour:'2-digit',minute:'2-digit',second:'2-digit',
    hour12:false
  }).formatToParts(d);
  const g=t=>(parts.find(p=>p.type===t)||{}).value||'';
  const date=`${g('year')}-${g('month')}-${g('day')}`;
  const time=`${g('hour')}:${g('minute')}:${g('second')}`;
  if(mode==='date') return date;
  if(mode==='time') return time;
  if(mode==='hm') return `${g('hour')}:${g('minute')}`;
  return `${date} ${time}`;
}
function nowBeijingDateStr(){ return fmtBeijing(new Date(), 'date'); }

/* 拦截原因统一映射：cn=地区限制 whitelist=域名白名单 ban=IP黑名单 rate_limit=限流 ua=UA白名单 */
function reasonLabel(r){return {cn:'地区限制',whitelist:'域名未授权',ban:'IP 黑名单',rate_limit:'触发限流',ua:'UA 不允许'}[r]||'其他拦截'}
function reasonClass(r){return {cn:'pc',whitelist:'pw',ban:'pb',rate_limit:'pl',ua:'pu'}[r]||'pw'}
function reasonFull(r){return {cn:'地区限制：仅允许中国大陆 IP',whitelist:'域名未授权：目标域名不在白名单',ban:'IP 黑名单：命中黑名单规则',rate_limit:'触发限流：超过每分钟请求上限',ua:'UA 不允许：User-Agent 不在白名单'}[r]||'其他拦截'}

function countryLabel(code){  if(!code) return '未知';
  const c = String(code).toUpperCase();
  if(state.labels && (state.labels[c]||state.labels[code])) return state.labels[c]||state.labels[code];
  const fallback = {LO:'本机',PV:'内网','??':'未知',CN:'中国',HK:'中国香港',TW:'中国台湾',MO:'中国澳门',US:'美国',JP:'日本',KR:'韩国',SG:'新加坡',GB:'英国',DE:'德国',FR:'法国',RU:'俄罗斯'};
  return fallback[c] || code;
}

const pageTitles={overview:'概览',traffic:'流量请求',live:'实时监控',blocks:'拦截记录',settings:'网关设置'};
/* ----- 实时监控会话 -----
 * liveSession.map：本页停留期间累计的连接（含已结束）
 * liveMode：ws | poll | idle；离开页 stopLiveTimers + resetLiveSession
 */
let liveTimer=null;
let liveTickTimer=null;
let liveWS=null;
let liveWSRetry=null;
let blocksTimer=null; // 拦截记录页轮询：停留期间每 5s 自动刷新，切走即清除
let liveMode='idle'; // ws | poll | idle
const liveSession={map:new Map(), connPage:1, ipPage:1, pageSize:20};
function resetLiveSession(){liveSession.map.clear();liveSession.connPage=1;liveSession.ipPage=1}
function setLiveHint(t){ const el=document.getElementById('lvRefreshHint'); if(el) el.textContent=t; }
function stopLiveTimers(){
  if(liveTimer){clearInterval(liveTimer);liveTimer=null}
  if(liveTickTimer){clearInterval(liveTickTimer);liveTickTimer=null}
  if(liveWSRetry){clearTimeout(liveWSRetry);liveWSRetry=null}
  if(liveWS){
    try{ liveWS.onclose=null; liveWS.onerror=null; liveWS.onmessage=null; liveWS.close(); }catch(e){}
    liveWS=null;
  }
  liveMode='idle';
}
/** 进行中连接本地推算时长：只改 DOM 文案，避免整表 innerHTML */
function tickLiveDurations(){
  if(document.hidden) return;
  const now=Date.now();
  liveSession.map.forEach((v)=>{
    if(!v||!v.active||!v.start) return;
    const t=new Date(v.start).getTime();
    if(isNaN(t)) return;
    v.duration_ms=Math.max(0, now-t);
  });
  // 连接时间列（相对时间）+ title 时长
  document.querySelectorAll('#lvConnTable tr.live-row[data-live-id]').forEach(tr=>{
    const id=tr.getAttribute('data-live-id');
    const row=liveSession.map.get(id);
    if(!row||!row.active) return;
    const agoEl=tr.querySelector('.lv-ago');
    if(agoEl){
      const next=fmtAgo(row.start);
      if(agoEl.textContent!==next) agoEl.textContent=next;
      agoEl.title=fmtBeijing(row.start,'full')+' · 时长 '+fmtDur(row.duration_ms||0);
    }
  });
}
/** 合并一帧监控数据：活跃覆盖；已结束仅更新本页已见 id；并估算单连接速率 */
function applyLiveData(d){
  if(!d||typeof d!=='object') return;
  document.getElementById('lvActive').textContent=(d.active||0).toLocaleString();
  document.getElementById('lvDown').textContent=fmtRate(d.down_bps||0);
  document.getElementById('lvUp').textContent=fmtRate(d.up_bps||0);
  const now=Date.now();
  (d.connections||[]).forEach(c=>{
    if(!c||!c.id) return;
    const prev=liveSession.map.get(c.id);
    let downRate=0, upRate=0;
    if(prev && prev._sampleAt && c.active){
      const dt=(now-(prev._sampleAt||now))/1000;
      if(dt>0.05){
        downRate=Math.max(0, ((c.down||0)-(prev.down||0))/dt);
        upRate=Math.max(0, ((c.up||0)-(prev.up||0))/dt);
      }else{
        downRate=prev.downRate||0;
        upRate=prev.upRate||0;
      }
    }else if(prev && !c.active){
      downRate=0; upRate=0;
    }
    if(c.active){
      let dur=c.duration_ms||0;
      if(c.start){
        const t=new Date(c.start).getTime();
        if(!isNaN(t)) dur=Math.max(dur, now-t);
      }
      liveSession.map.set(c.id,{...c, duration_ms:dur, downRate, upRate, _sampleAt:now});
    }else if(prev){
      liveSession.map.set(c.id,{
        ...prev, ...c, active:false, downRate:0, upRate:0,
        up:Math.max(prev.up||0,c.up||0),
        down:Math.max(prev.down||0,c.down||0),
        duration_ms:Math.max(prev.duration_ms||0,c.duration_ms||0),
        _sampleAt:now
      });
    }
  });
  const serverIds=new Set((d.connections||[]).map(c=>c.id));
  liveSession.map.forEach((v,id)=>{
    if(v.active && !serverIds.has(id)){
      liveSession.map.set(id,{...v,active:false,downRate:0,upRate:0,ended:v.ended||fmtBeijing(new Date(),'full')});
    }
  });
  renderLiveTables();
}
function startLivePoll(){
  if(liveMode==='poll' && liveTimer) return;
  liveMode='poll';
  setLiveHint('轮询 · 约 0.8 秒');
  loadLive();
  if(liveTimer) clearInterval(liveTimer);
  liveTimer=setInterval(()=>{if(!document.hidden)loadLive()},800);
}
function connectLiveWS(){
  if(!window.WebSocket){ startLivePoll(); return; }
  // 已有连接在连或已打开则不重复
  if(liveWS && (liveWS.readyState===WebSocket.CONNECTING || liveWS.readyState===WebSocket.OPEN)) return;
  const proto = location.protocol==='https:' ? 'wss:' : 'ws:';
  const url = proto + '//' + location.host + '/admin/api/live/ws';
  setLiveHint('WebSocket 连接中…');
  let ws;
  try{ ws = new WebSocket(url); }catch(e){ startLivePoll(); return; }
  liveWS = ws;
  let opened=false;
  ws.onopen = ()=>{
    opened=true;
    liveMode='ws';
    setLiveHint('WebSocket · 实时');
    // WS 模式下仍本地推算时长，秒数更顺滑
    if(liveTimer){ clearInterval(liveTimer); liveTimer=null; }
  };
  ws.onmessage = (ev)=>{
    try{
      const d = JSON.parse(ev.data);
      applyLiveData(d);
    }catch(e){}
  };
  ws.onerror = ()=>{};
  ws.onclose = ()=>{
    liveWS=null;
    if(liveMode==='idle') return; // 已离开监控页
    // 断线：先试一次 HTTP，再退避重连 WS
    setLiveHint('已断开，重连中…');
    loadLive();
    if(liveWSRetry) clearTimeout(liveWSRetry);
    liveWSRetry=setTimeout(()=>{
      if(liveMode==='idle') return;
      connectLiveWS();
    }, 1500);
    // 重连前短暂轮询兜底
    if(!liveTimer){
      liveMode='poll';
      liveTimer=setInterval(()=>{if(!document.hidden)loadLive()},800);
    }
  };
}
function switchTab(id){
  document.querySelectorAll('.nav-i').forEach(b=>b.classList.toggle('on',b.dataset.t===id));
  document.querySelectorAll('.pg').forEach(el=>el.classList.toggle('on',el.id===id));
  document.getElementById('pt').textContent=pageTitles[id]||'';
  if(window.innerWidth<=1024)closeSidebar();
  stopLiveTimers();
  if(blocksTimer){clearInterval(blocksTimer);blocksTimer=null}
  if(id==='overview')loadOverview();
  if(id==='traffic')loadTraffic();
  if(id==='blocks'){
    loadBlocks();
    // 停留在拦截记录页期间自动轮询，新拦截事件无需手动刷新即实时上屏
    blocksTimer=setInterval(()=>{if(!document.hidden)loadBlocks()},5000);
  }
  if(id==='live'){
    resetLiveSession();
    liveTickTimer=setInterval(tickLiveDurations,500);
    connectLiveWS();
  } else {
    resetLiveSession();
  }
}
function openSidebar(){document.getElementById('sb').classList.add('open');document.getElementById('sbMask').classList.add('on')}
function closeSidebar(){document.getElementById('sb').classList.remove('open');document.getElementById('sbMask').classList.remove('on')}
document.getElementById('mmb').addEventListener('click',(e)=>{e.stopPropagation();openSidebar()});
document.getElementById('sbMask').addEventListener('click',closeSidebar);

document.querySelectorAll('.nav-i').forEach(t=>t.addEventListener('click',()=>switchTab(t.dataset.t)));
document.addEventListener('click',e=>{const btn=e.target.closest('[data-goto]');if(btn){e.preventDefault();switchTab(btn.dataset.goto)}});
// 连接表事件委托：避免每次 render 重新绑大量监听
document.getElementById('lvConnTable')?.addEventListener('click',e=>{
  const closeBtn=e.target.closest('[data-close-id]');
  if(closeBtn){ closeLiveConn(closeBtn.getAttribute('data-close-id'), e); return; }
  const tr=e.target.closest('tr.live-row[data-live-id]');
  if(!tr) return;
  const row=liveSession.map.get(tr.getAttribute('data-live-id'));
  if(row) showLiveDetail(row);
});

function applyPort(p){if(!p)return;state.port=p;document.getElementById('portInput').value=p;document.getElementById('portChip').textContent=':'+p}

async function loadConfig(){
  try{
    const r=await fetch('/admin/api/config',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const c=await r.json();applyPort(c.effective_port);
    document.getElementById('chinaOnly').checked=!!c.china_only;document.getElementById('corsToggle').checked=!!c.cors;document.getElementById('cacheToggle').checked=!!c.enable_cache;document.getElementById('pwaToggle').checked=!!c.pwa;state.pwaOn=!!c.pwa;
    document.getElementById('whitelist').value=(c.whitelist||[]).join('\n');document.getElementById('banList').value=(c.ban_list||[]).join('\n');document.getElementById('autoBan').checked=!!c.auto_ban;
    document.getElementById('rateLimit').value=c.rate_limit||0;document.getElementById('allowedUAs').value=(c.allowed_uas||[]).join('\n');
  }catch(e){console.error('loadConfig error:',e)}
}

let miniTrendChart=null,reqChart=null,byteChart=null,hostChart=null;
let trafficTrendData=[];

function updateOvStats() {
  if (!ovTrendData.length) return;
  const localISOTime = nowBeijingDateStr();
  const bjNow = new Date(new Date().toLocaleString('en-US',{timeZone:'Asia/Shanghai'}));
  const y = new Date(bjNow); y.setDate(bjNow.getDate()-1);
  const yISOTime = fmtBeijing(y,'date');
  const d7 = new Date(bjNow); d7.setDate(bjNow.getDate()-6);
  const d7Str = fmtBeijing(d7,'date');
  const d30 = new Date(bjNow); d30.setDate(bjNow.getDate()-29);
  const d30Str = fmtBeijing(d30,'date');

  let filterFn = () => true;
  if (state.ovRange === 'today') filterFn = d => d.date === localISOTime;
  else if (state.ovRange === 'yesterday') filterFn = d => d.date === yISOTime;
  else if (state.ovRange === '7d') filterFn = d => d.date >= d7Str;
  else if (state.ovRange === '30d') filterFn = d => d.date >= d30Str;
  
  const filtered = ovTrendData.filter(filterFn);
  let reqs = 0, bytes = 0, bTotal = 0;
  filtered.forEach(d => {
    reqs += d.requests || 0;
    bytes += d.bytes || 0;
    // 优先用后端汇总字段（五种拦截之和）；旧数据无 blocked 字段时回退老两字段
    bTotal += (d.blocked != null) ? d.blocked : ((d.blocked_cn||0)+(d.blocked_whitelist||0));
  });
  
  const days = filtered.length || 1;
  document.getElementById('ovReq').textContent = reqs.toLocaleString();
  document.getElementById('ovBytes').textContent = fmtBytes(bytes);
  document.getElementById('ovAvgReq').textContent = Math.round(reqs/days).toLocaleString();
  document.getElementById('ovAvgBytes').textContent = fmtBytes(Math.round(bytes/days));
  document.getElementById('ovBlocked').textContent = bTotal.toLocaleString();
}

async function loadOverview(){
  try{
    // slim=1：trend 只含每日汇总，避免 5 秒轮询拉全量明细（分时/主机/IP/国家）
    const r=await fetch('/admin/api/traffic?slim=1',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    document.getElementById('uniqueIPs').textContent=(t.unique_ips!=null?t.unique_ips:Object.keys(t.ip_counts||{}).length).toLocaleString();
    ovTrendData = t.trend || [];
    renderMiniTrend(ovTrendData);
    updateOvStats();
    
    // 概览只需最新几条拦截，limit=5 大幅减少轮询传输
    const r2=await fetch('/admin/api/blocks?limit=5',{cache:'no-store'});
    if(r2.ok){const b=await r2.json();renderOvBlocks(b.items||[]);}
    
    const r3=await fetch('/admin/api/config',{cache:'no-store'});
    if(r3.ok){const c=await r3.json();renderSysInfo(c, t.uptime_sec||0);}
  }catch(e){console.error('loadOverview error:',e)}
}

function renderSysInfo(c, uptime){
  let fw = "已开启"; if(!c.ban_list?.length && !c.china_only && !c.rate_limit) fw="未启用";
  const html = `
  <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px dashed #eee"><span style="color:#94a3b8">运行时长</span><span>${Math.floor(uptime/3600)} 小时</span></div>
  <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px dashed #eee"><span style="color:#94a3b8">访问防护</span><span style="color:var(--ok)">${fw}</span></div>
  <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px dashed #eee"><span style="color:#94a3b8">域名白名单</span><span>${c.whitelist?.length||0} 个</span></div>
  <div style="display:flex;justify-content:space-between;padding:8px 0"><span style="color:#94a3b8">图片缓存</span><span>${c.enable_cache?"已开启":"已关闭"}</span></div>
  `;
  document.getElementById('sysInfo').innerHTML = html;
}

function renderMiniTrend(trend){const cv=document.getElementById('miniTrendChart');if(!cv || typeof Chart==='undefined')return;const data=(trend||[]).slice(-7);if(!data.length)return;const labels=data.map(d=>(d.date||'').slice(5)),reqs=data.map(d=>d.requests||0);
if(miniTrendChart){miniTrendChart.data.labels=labels;miniTrendChart.data.datasets[0].data=reqs;miniTrendChart.update('none');return}
miniTrendChart=new Chart(cv,{type:'line',data:{labels,datasets:[{label:'请求',data:reqs,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.1)',borderWidth:2,fill:true,tension:0.35,pointRadius:3}]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{display:false}},scales:{x:{grid:{display:false}},y:{beginAtZero:true,grid:{borderDash:[4,4]}}}}})}

// esc：HTML 转义，防 XSS
const esc = s => String(s==null?'':s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

function renderOvBlocks(items){
  const box=document.getElementById('ovBlocks');
  if(!items.length){box.innerHTML='<div class="emp"><b>暂无记录</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">近期没有拦截事件</span></div>';return}
  box.innerHTML=items.slice(0,5).map(b=>`<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;padding:10px 0;border-bottom:1px solid #f1f5f9;font-size:13px">
    <div style="min-width:0;flex:1"><span style="font-family:var(--mono);color:#3b82f6;font-weight:600;word-break:break-all">${esc(b.ip)}</span><br><span class="pill ${reasonClass(b.reason)}" style="margin-top:4px;display:inline-block">${esc(reasonLabel(b.reason))}</span></div>
    <div style="color:#94a3b8;font-size:12px;flex-shrink:0">${fmtBeijing(b.time,'time')}</div>
  </div>`).join('');
}

function localDateStr(d){
  return fmtBeijing(d instanceof Date ? d : new Date(d), 'date');
}
function dateRangeBounds(){
  const today=new Date();
  const tStr=nowBeijingDateStr();
  let from=null,to=tStr;
  const r=state.tfRange;
  if(r==='today'){from=tStr}
  else if(r==='7d'){const d=new Date(today);d.setDate(today.getDate()-6);from=localDateStr(d)}
  else if(r==='30d'){const d=new Date(today);d.setDate(today.getDate()-29);from=localDateStr(d)}
  else if(r==='365d'){const d=new Date(today);d.setDate(today.getDate()-364);from=localDateStr(d)}
  else if(r==='all'){from=null;to=null}
  else if(r==='custom'){
    from=state.tfFrom||null;to=state.tfTo||null;
    if(from&&to&&from>to){const x=from;from=to;to=x}
  }
  return {from,to,today:tStr};
}
function filterTrendByRange(trend){
  const {from,to}=dateRangeBounds();
  return (trend||[]).filter(d=>{
    if(!d||!d.date)return false;
    if(from&&d.date<from)return false;
    if(to&&d.date>to)return false;
    return true;
  }).sort((a,b)=>a.date<b.date?-1:a.date>b.date?1:0);
}
function weekStartKey(dateStr){
  const d=new Date(dateStr+'T00:00:00');
  const day=d.getDay()||7;
  d.setDate(d.getDate()-day+1);
  return localDateStr(d);
}
function monthKey(dateStr){ return (dateStr||'').slice(0,7); }
/** 按区间跨度选择图表粒度：日 → 周(>60) → 月(>180) */
function pickGranularity(dayCount){
  if(dayCount>180) return 'month';
  if(dayCount>60) return 'week';
  return 'day';
}
function buildTrafficView(trend){
  const filtered=filterTrendByRange(trend);
  const {from,to,today}=dateRangeBounds();
  const isToday = state.tfRange === 'today' || (state.tfRange === 'custom' && from && to && from === to && from === today);
  const labels=[],reqs=[],bytes=[];
  const ipMap={},ctryMap={},hostMap={};
  let totalReq=0,totalBytes=0,blocked=0,rawDayCount=0,gran='hour';
  filtered.forEach(d=>{
    totalReq+=d.requests||0; totalBytes+=d.bytes||0;
    blocked+=(d.blocked!=null)?d.blocked:((d.blocked_cn||0)+(d.blocked_whitelist||0));
    Object.entries(d.ips||{}).forEach(([k,v])=>{ipMap[k]=(ipMap[k]||0)+v});
    Object.entries(d.countries||{}).forEach(([k,v])=>{ctryMap[k]=(ctryMap[k]||0)+v});
    Object.entries(d.hosts||{}).forEach(([k,v])=>{hostMap[k]=(hostMap[k]||0)+v});
  });
  if(isToday){
    gran='hour';
    const day=filtered.find(d=>d.date===today)||filtered[0]||{hours:{},hour_bytes:{}};
    const hours=day.hours||{}, hourBytes=day.hour_bytes||{};
    for(let h=0;h<24;h++){
      const key=String(h).padStart(2,'0');
      labels.push(key+':00'); reqs.push(hours[key]||0); bytes.push(hourBytes[key]||0);
    }
    rawDayCount=1;
  }else{
    const byDate={}; filtered.forEach(d=>{byDate[d.date]=d});
    let days=[];
    if(from&&to){
      const a=new Date(from+'T00:00:00'), b=new Date(to+'T00:00:00');
      for(let t=new Date(a);t<=b;t.setDate(t.getDate()+1)) days.push(localDateStr(new Date(t)));
    }else days=Object.keys(byDate).sort();
    rawDayCount=days.length||1;
    gran=pickGranularity(rawDayCount);
    if(gran==='day'){
      days.forEach(date=>{ const d=byDate[date]||{}; labels.push(date); reqs.push(d.requests||0); bytes.push(d.bytes||0); });
    }else{
      const buckets={}, order=[];
      days.forEach(date=>{
        const key=gran==='week'?weekStartKey(date):monthKey(date);
        if(!buckets[key]){ buckets[key]={req:0,bytes:0}; order.push(key); }
        const d=byDate[date]||{};
        buckets[key].req+=(d.requests||0); buckets[key].bytes+=(d.bytes||0);
      });
      order.forEach(key=>{ labels.push(key); reqs.push(buckets[key].req); bytes.push(buckets[key].bytes); });
    }
  }
  const hostTop=Object.entries(hostMap).sort((a,b)=>b[1]-a[1]).slice(0,12);
  const ipTopN=30, ctryTopN=25;
  const ipEntries=Object.entries(ipMap).sort((a,b)=>b[1]-a[1]);
  const ctryEntries=Object.entries(ctryMap).sort((a,b)=>b[1]-a[1]);
  const ipMapTrim={}, ctryMapTrim={};
  ipEntries.slice(0,ipTopN).forEach(([k,v])=>{ipMapTrim[k]=v});
  ctryEntries.slice(0,ctryTopN).forEach(([k,v])=>{ctryMapTrim[k]=v});
  return {isToday,gran,labels,reqs,bytes,ipMap:ipMapTrim,ctryMap:ctryMapTrim,hostTop,totalReq,totalBytes,blocked,dayCount:rawDayCount,ipTotalUnique:ipEntries.length,ctryTotalUnique:ctryEntries.length,ipTopN,ctryTopN};
}
function applyTrafficView(){
  const v=buildTrafficView(trafficTrendData);
  document.getElementById('tfReq').textContent=v.totalReq.toLocaleString();
  document.getElementById('tfBytes').textContent=fmtBytes(v.totalBytes);
  document.getElementById('tfIPs').textContent=v.ipTotalUnique.toLocaleString();
  document.getElementById('tfBlocked').textContent=v.blocked.toLocaleString();
  const granHint={hour:'今日分时段',day:'共 '+v.dayCount+' 天',week:'共 '+v.dayCount+' 天 · 按周汇总',month:'共 '+v.dayCount+' 天 · 按月汇总'};
  document.getElementById('tfReqHint').textContent=granHint[v.gran]||('共 '+v.dayCount+' 天');
  document.getElementById('tfBytesHint').textContent=v.isToday?'今日真实分时流量':('日均 '+fmtBytes(Math.round(v.totalBytes/(v.dayCount||1))));
  const titleMap={hour:['请求量趋势（分时）','流量消耗趋势（分时）'],day:['请求量趋势','流量消耗趋势'],week:['请求量趋势（按周）','流量消耗趋势（按周）'],month:['请求量趋势（按月）','流量消耗趋势（按月）']};
  const descMap={hour:['今天 00:00–23:00 各时段请求数（北京时间）','今天 00:00–23:00 各时段真实流量（北京时间）'],day:['筛选区间内每日请求次数（北京时间）','筛选区间内每日上下行流量（北京时间）'],week:['区间超过 60 天，已按周汇总','区间超过 60 天，已按周汇总流量'],month:['区间超过 180 天，已按月汇总','区间超过 180 天，已按月汇总流量']};
  const tt=titleMap[v.gran]||titleMap.day, dd=descMap[v.gran]||descMap.day;
  document.getElementById('tfReqTitle').textContent=tt[0];
  document.getElementById('tfReqDesc').textContent=dd[0];
  document.getElementById('tfByteTitle').textContent=tt[1];
  document.getElementById('tfByteDesc').textContent=dd[1];
  document.getElementById('tfHostDesc').textContent=v.isToday?'今日访问量最高的上游主机':'当前范围内访问量最高的上游主机';
  renderReqChart(v.labels,v.reqs,v.gran);
  renderByteChart(v.labels,v.bytes,v.gran);
  renderHostChart(v.hostTop);
  renderIP(v.ipMap,{},v.ipTotalUnique,v.ipTopN);
  renderRegion(v.ctryMap,v.ctryTotalUnique,v.ctryTopN);
}

async function loadTraffic(){
  try{
    const r=await fetch('/admin/api/traffic',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    if(t.country_labels) state.labels = t.country_labels;
    trafficTrendData = t.trend || [];
    // 自定义日期输入默认最近 7 天
    if(!state.tfFrom||!state.tfTo){
      const today=new Date();
      const d7=new Date(today);d7.setDate(today.getDate()-6);
      const elF=document.getElementById('tfFrom'),elT=document.getElementById('tfTo');
      if(elF&&!elF.value) elF.value=localDateStr(d7);
      if(elT&&!elT.value) elT.value=localDateStr(today);
    }
    applyTrafficView();
  }catch(e){console.error('loadTraffic error:',e)}
}

function upsertChart(prev,cv,cfg){
  // 分时(bar) 与按天(line) 切换时必须重建，否则会一直保留小时轴
  if(prev){
    const sameType = prev.config && prev.config.type === cfg.type;
    if(sameType){
      prev.data.labels = cfg.data.labels;
      prev.data.datasets = cfg.data.datasets;
      if(cfg.options) Object.assign(prev.options, cfg.options);
      prev.update();
      return prev;
    }
    prev.destroy();
  }
  return new Chart(cv, cfg);
}
function fmtAxisLabel(lab,gran){
  if(gran==='hour') return lab;
  if(gran==='month' && /^\d{4}-\d{2}$/.test(lab)) return lab.slice(5)+'月';
  if(/^\d{4}-\d{2}-\d{2}$/.test(lab)) return lab.slice(5);
  return lab;
}
function tooltipTitle(labels,gran){
  return (items)=>{
    const raw=labels[items[0].dataIndex]||'';
    if(gran==='week' && /^\d{4}-\d{2}-\d{2}$/.test(raw)) return raw+' 起一周';
    if(gran==='month' && /^\d{4}-\d{2}$/.test(raw)) return raw;
    return raw;
  };
}
function chartTickLimit(n,gran){
  if(gran==='hour') return 12;
  if(n<=14) return n;
  if(gran==='month') return Math.min(18,n);
  if(gran==='week') return Math.min(16,n);
  return 14;
}
function renderReqChart(labels,data,gran){
  const cv=document.getElementById('reqChart');if(!cv||typeof Chart==='undefined')return;
  gran=gran||'day';
  const labs=labels.map(l=>fmtAxisLabel(l,gran));
  const dense=labels.length>40;
  const cfg={type:'bar',data:{labels:labs,datasets:[{label:'请求数',data,borderColor:'#10b981',backgroundColor:gran==='hour'?'rgba(16,185,129,0.75)':'rgba(16,185,129,0.65)',borderWidth:1,borderRadius:dense?2:4,maxBarThickness:dense?10:28}]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:dense?false:{duration:400},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(labels,gran)}}},scales:{x:{grid:{display:false},ticks:{maxRotation:45,minRotation:0,autoSkip:true,maxTicksLimit:chartTickLimit(labels.length,gran)}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}}}}};
  reqChart=upsertChart(reqChart,cv,cfg);
}
function renderByteChart(labels,data,gran){
  const cv=document.getElementById('byteChart');if(!cv||typeof Chart==='undefined')return;
  gran=gran||'day';
  const labs=labels.map(l=>fmtAxisLabel(l,gran));
  const dense=labels.length>40;
  const cfg={type:'line',data:{labels:labs,datasets:[{label:'流量',data,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.15)',fill:true,tension:0.3,pointRadius:dense||gran==='hour'?0:(labels.length>20?2:3),borderWidth:2,pointHoverRadius:4}]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:dense?false:{duration:400},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(labels,gran),label:c=>fmtBytes(c.parsed.y)}}},scales:{x:{grid:{display:false},ticks:{maxRotation:45,minRotation:0,autoSkip:true,maxTicksLimit:chartTickLimit(labels.length,gran)}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{callback:v=>fmtBytes(v)}}}}};
  byteChart=upsertChart(byteChart,cv,cfg);
}
function renderHostChart(hostTop){
  const cv=document.getElementById('hostChart');if(!cv||typeof Chart==='undefined')return;
  const labels=hostTop.map(([h])=>h.length>28?h.slice(0,26)+'…':h);
  const data=hostTop.map(([,n])=>n);
  if(!labels.length){labels.push('暂无数据');data.push(0)}
  const cfg={type:'bar',data:{labels,datasets:[{label:'请求',data,backgroundColor:'rgba(59,130,246,0.7)',borderRadius:4}]},options:{indexAxis:'y',responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{display:false}},scales:{x:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}},y:{grid:{display:false},ticks:{font:{size:11}}}}}};
  hostChart=upsertChart(hostChart,cv,cfg);
}
function renderIP(map,bytesMap,totalUnique,topN){
  topN=topN||20;
  const rows=Object.entries(map).sort((a,b)=>b[1]-a[1]).slice(0,topN);
  const box=document.getElementById('ipDist');
  if(!rows.length){box.innerHTML='<div class="emp"><b>暂无数据</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">当前筛选条件下没有 IP 记录</span></div>';return}
  const max=rows[0][1]||1;
  const more=(totalUnique||rows.length)>rows.length;
  let html=rows.map(([ip,n])=>`<div class="dr ip-row" data-ip="${esc(ip)}" style="cursor:pointer" title="点击查看详情"><span class="dn m"><span class="tx" style="color:var(--pd)">${esc(ip)}</span></span><div class="bar i"><i style="width:${(n/max*100).toFixed(1)}%"></i></div><span class="dv">${n.toLocaleString()}<span>次</span></span></div>`).join('');
  if(more) html+=`<div style="margin-top:10px;font-size:12px;color:var(--t3);text-align:center">仅展示 Top ${rows.length} · 共 ${Number(totalUnique).toLocaleString()} 个 IP</div>`;
  box.innerHTML=html;
  box.querySelectorAll('.ip-row').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
}
function renderRegion(map,totalUnique,topN){
  topN=topN||20;
  const rows=Object.entries(map).sort((a,b)=>b[1]-a[1]).slice(0,topN);
  const box=document.getElementById('regionDist');
  if(!rows.length){box.innerHTML='<div class="emp"><b>暂无数据</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">当前筛选条件下没有地区记录</span></div>';return}
  const total=rows.reduce((s,r)=>s+r[1],0)||1,max=rows[0][1]||1;
  const more=(totalUnique||rows.length)>rows.length;
  let html=rows.map(([code,n])=>{
    const nm=countryLabel(code);
    return `<div class="dr"><span class="dn" title="${nm}"><img class="flg" src="/admin/api/flag/${code.toLowerCase()}" onerror="this.style.display='none'"> <span class="tx">${nm}</span></span><div class="bar t"><i style="width:${(n/max*100).toFixed(1)}%"></i></div><span class="dv">${n.toLocaleString()}<span>${(n/total*100).toFixed(0)}%</span></span></div>`;
  }).join('');
  if(more) html+=`<div style="margin-top:10px;font-size:12px;color:var(--t3);text-align:center">仅展示 Top ${rows.length} · 共 ${Number(totalUnique).toLocaleString()} 个地区</div>`;
  box.innerHTML=html;
}

async function showLiveDetail(c){
  if(!c)return;
  document.getElementById('modalTitle').textContent='连接详情';
  const rows=[
    ['状态',c.active?'进行中':'已结束',false],
    ['IP',c.ip||'-',true],
    ['地区',c.country_name||countryLabel(c.country)||'-',false],
    ['上游主机',c.host||'-',true],
    ['请求方法',c.method||'-',false],
    ['访问路径',c.path||'-',true],
    ['下行流量',fmtBytes(c.down||0),false],
    ['上行流量',fmtBytes(c.up||0),false],
    ['持续时长',fmtDur(c.duration_ms||0),false],
    ['开始时间',fmtBeijing(c.start,'full'),false],
  ];
  if(c.ended) rows.push(['结束时间',fmtBeijing(c.ended,'full'),false]);
  let html=rows.map(([k,v,m])=>'<div class="kv"><div class="kk">'+esc(k)+'</div><div class="kvv'+(m?' m':'')+'">'+esc(v)+'</div></div>').join('');
  if(c.ip){
    html+='<div style="margin-top:16px;display:flex;gap:8px;flex-wrap:wrap"><button type="button" class="btn b s" id="liveToIpBtn">查看 IP 详情</button></div>';
  }
  document.getElementById('modalBody').innerHTML=html;
  document.getElementById('modal').classList.add('on');
  document.getElementById('liveToIpBtn')?.addEventListener('click',()=>showIPDetail(c.ip));
}
async function showIPDetail(ip){
  if(!ip)return;
  document.getElementById('modalTitle').textContent='IP 详情';
  document.getElementById('modalBody').innerHTML='<div style="color:var(--t3);font-size:13px;padding:12px 0">正在加载…</div>';
  document.getElementById('modal').classList.add('on');
  try{
    const r=await fetch('/admin/api/ip-detail?ip='+encodeURIComponent(ip),{cache:'no-store'});
    const txt=await r.text();
    if(!r.ok)throw new Error(txt.trim()||('HTTP '+r.status));
    const d=JSON.parse(txt);
    const loc=d.location||d.country_name||'未知';
    const rows=[['IP',d.ip,true],['位置',loc,false],['请求次数',(d.requests||0).toLocaleString()+' 次',false],['流量',fmtBytes(d.bytes||0),false]];
    document.getElementById('modalBody').innerHTML=rows.map(([k,v,m])=>'<div class="kv"><div class="kk">'+esc(k)+'</div><div class="kvv'+(m?' m':'')+'">'+esc(v)+'</div></div>').join('');
  }catch(e){
    document.getElementById('modalBody').innerHTML='<div style="color:var(--d);font-size:13px">加载失败：'+esc(e.message||'未知错误')+'</div>';
  }
}

function fmtRate(b){if(!b||b<0)return '0 B/s';if(b<1024)return b+' B/s';if(b<1048576)return (b/1024).toFixed(1)+' KB/s';if(b<1073741824)return (b/1048576).toFixed(1)+' MB/s';return (b/1073741824).toFixed(2)+' GB/s'}
function fmtDur(ms){ms=Math.max(0,Math.floor(ms||0));if(ms<1000)return ms+'ms';const s=Math.floor(ms/1000);if(s<60)return s+'s';const m=Math.floor(s/60),rs=s%60;if(m<60)return m+'m '+String(rs).padStart(2,'0')+'s';const h=Math.floor(m/60),rm=m%60;return h+'h '+String(rm).padStart(2,'0')+'m '+String(rs).padStart(2,'0')+'s'}
/** 相对时间：几秒前 / 2分钟前 / 1小时前 */
function fmtAgo(iso){
  if(!iso) return '-';
  const t=new Date(iso).getTime();
  if(isNaN(t)) return '-';
  const sec=Math.max(0,Math.floor((Date.now()-t)/1000));
  if(sec<5) return '几秒前';
  if(sec<60) return sec+'秒前';
  if(sec<3600) return Math.floor(sec/60)+'分钟前';
  if(sec<86400) return Math.floor(sec/3600)+'小时前';
  return Math.floor(sec/86400)+'天前';
}
async function closeLiveConn(id, ev){
  if(ev){ ev.stopPropagation(); ev.preventDefault(); }
  if(!id) return;
  try{
    const r=await fetch('/admin/api/live/close?id='+encodeURIComponent(id),{method:'POST'});
    const d=await r.json().catch(()=>({}));
    if(!r.ok){ alert(d.error||'断开失败，该连接可能已结束'); return; }
    const prev=liveSession.map.get(id);
    if(prev) liveSession.map.set(id,{...prev,active:false,downRate:0,upRate:0,ended:fmtBeijing(new Date(),'full')});
    renderLiveTables();
  }catch(e){ alert('断开失败：网络异常，请稍后重试'); }
}
function livePagerHtml(prefix,page,total,pageSize){
  const pages=Math.max(1,Math.ceil(total/pageSize));
  const p=Math.min(Math.max(1,page),pages);
  return `<span>共 ${total} 条 · 第 ${p}/${pages} 页</span><span style="display:flex;gap:8px">
    <button type="button" class="btn g s" data-live-page="${prefix}" data-to="1" ${p<=1?'disabled':''}>首页</button>
    <button type="button" class="btn g s" data-live-page="${prefix}" data-to="${p-1}" ${p<=1?'disabled':''}>上一页</button>
    <button type="button" class="btn g s" data-live-page="${prefix}" data-to="${p+1}" ${p>=pages?'disabled':''}>下一页</button>
    <button type="button" class="btn g s" data-live-page="${prefix}" data-to="${pages}" ${p>=pages?'disabled':''}>末页</button>
  </span>`;
}
/** 渲染连接表（代理面板风格列）与按 IP 汇总；点击事件由 #lvConnTable 委托 */
function renderLiveTables(){
  const all=[...liveSession.map.values()];
  all.sort((a,b)=>{
    if(!!a.active!==!!b.active) return a.active?-1:1;
    const ar=(a.downRate||0)+(a.upRate||0), br=(b.downRate||0)+(b.upRate||0);
    if(ar!==br) return br-ar;
    return (b.down||0)-(a.down||0);
  });
  const ps=liveSession.pageSize;
  const total=all.length;
  const pages=Math.max(1,Math.ceil(total/ps));
  if(liveSession.connPage>pages) liveSession.connPage=pages;
  const start=(liveSession.connPage-1)*ps;
  const slice=all.slice(start,start+ps);
  const ct=document.getElementById('lvConnTable');
  if(!total){
    ct.innerHTML='<tr class="emp-row"><td colspan="10"><div class="emp"><b>暂无记录</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">有代理请求后将在此累计展示</span></div></td></tr>';
  }else{
    ct.innerHTML=slice.map(c=>{
      const path=(c.path||'').replace(/^\/https?:\/\/[^/]+/i,'')||'/';
      const pathShort=path.length>48?path.slice(0,46)+'…':path;
      const dRate=c.active?(c.downRate||0):0;
      const uRate=c.active?(c.upRate||0):0;
      const agoTitle=esc(fmtBeijing(c.start,'full')+(c.ended?' ~ '+fmtBeijing(c.ended,'full'):'')+' · 时长 '+fmtDur(c.duration_ms||0));
      return `<tr class="live-row ${c.active?'lv-active':''}" data-live-id="${esc(c.id)}" style="cursor:pointer" title="点击查看详情">
      <td data-label="操作"><span class="cell-v">${c.active?`<button type="button" class="lv-x" data-close-id="${esc(c.id)}" title="断开连接">×</button>`:'<button type="button" class="lv-x" disabled title="已结束">×</button>'}</span></td>
      <td data-label="主机"><span class="cell-v lv-host">${esc(c.host||'-')}</span></td>
      <td data-label="类型"><span class="cell-v"><span class="lv-type ${c.active?'on':''}">${esc(c.method||'GET')}${c.active?' · 进行中':' · 已结束'}</span></span></td>
      <td data-label="来源"><span class="cell-v"><span class="lv-src"><span class="ip">${esc(c.ip||'-')}</span><span class="rg">${esc(c.country_name||countryLabel(c.country))}</span></span></span></td>
      <td data-label="路径"><span class="cell-v"><span class="lv-path" title="${esc(c.path||path)}">${esc(pathShort)}</span></span></td>
      <td data-label="下载速度"><span class="cell-v lv-rate ${dRate>0?'on':''}">${fmtRate(dRate)}</span></td>
      <td data-label="上传速度"><span class="cell-v lv-rate ${uRate>0?'on':''}">${fmtRate(uRate)}</span></td>
      <td data-label="下载"><span class="cell-v lv-bytes">${fmtBytes(c.down||0)}</span></td>
      <td data-label="上传"><span class="cell-v lv-bytes">${fmtBytes(c.up||0)}</span></td>
      <td data-label="连接时间"><span class="cell-v lv-ago" title="${agoTitle}">${fmtAgo(c.start)}</span></td>
    </tr>`;
    }).join('');
  }
  document.getElementById('lvConnPager').innerHTML=livePagerHtml('conn',liveSession.connPage,total,ps);
  document.getElementById('lvIPCount').textContent=total.toLocaleString();

  const ipAgg={};
  all.forEach(c=>{
    const k=c.ip||'';
    if(!ipAgg[k]) ipAgg[k]={ip:k,country:c.country,country_name:c.country_name,conns:0,up:0,down:0};
    ipAgg[k].conns++; ipAgg[k].up+=c.up||0; ipAgg[k].down+=c.down||0;
  });
  const ips=Object.values(ipAgg).sort((a,b)=>b.down-a.down);
  const ipTotal=ips.length;
  const ipPages=Math.max(1,Math.ceil(ipTotal/ps));
  if(liveSession.ipPage>ipPages) liveSession.ipPage=ipPages;
  const ipStart=(liveSession.ipPage-1)*ps;
  const ipSlice=ips.slice(ipStart,ipStart+ps);
  const it=document.getElementById('lvIPTable');
  if(!ipTotal){
    it.innerHTML='<tr class="emp-row"><td colspan="5"><div class="emp"><b>暂无数据</b></div></td></tr>';
  }else{
    it.innerHTML=ipSlice.map(c=>`<tr>
      <td data-label="IP"><span class="cell-v mono ip-link" data-ip="${esc(c.ip)}" style="color:var(--pd);cursor:pointer;text-decoration:underline">${esc(c.ip)}</span></td>
      <td data-label="地区"><span class="cell-v">${esc(c.country_name||countryLabel(c.country))}</span></td>
      <td data-label="连接"><span class="cell-v">${c.conns||0}</span></td>
      <td data-label="下行"><span class="cell-v mono">${fmtBytes(c.down||0)}</span></td>
      <td data-label="上行"><span class="cell-v mono">${fmtBytes(c.up||0)}</span></td>
    </tr>`).join('');
    it.querySelectorAll('.ip-link').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
  }
  document.getElementById('lvIPPager').innerHTML=livePagerHtml('ip',liveSession.ipPage,ipTotal,ps);
}
async function loadLive(){
  try{
    const r=await fetch('/admin/api/live',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    applyLiveData(await r.json());
  }catch(e){console.error('loadLive',e)}
}

async function loadBlocks(){
  try{
    // 默认拉最新 500 条（服务端上限 5000；轮询模式下全量传输既慢又浪费）
    const r=await fetch('/admin/api/blocks?limit=500',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    const tb=document.getElementById('blockTable');
    if(!t.items.length){tb.innerHTML='<tr class="emp-row"><td colspan="6"><div class="emp"><b>暂无记录</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">尚未产生拦截事件；触发黑名单、地区、白名单、限流或 UA 拦截后将在此显示</span></div></td></tr>';return}
    tb.innerHTML=t.items.map(b=>{
      const ua=String(b.ua||'').trim();
      const uaShort=ua.length>60?ua.slice(0,58)+'…':ua;
      return `<tr>
      <td data-label="时间"><span class="cell-v muted mono">${fmtBeijing(b.time,'full')}</span></td>
      <td data-label="IP 地址"><span class="cell-v mono ip-link" data-ip="${esc(b.ip)}" style="color:var(--pd);text-decoration:underline;cursor:pointer;font-weight:600">${esc(b.ip)}</span></td>
      <td data-label="地区"><span class="cell-v"><img class="flg" src="/admin/api/flag/${(b.country||'??').toLowerCase()}" onerror="this.style.display='none'" alt="">${esc(b.country_name||countryLabel(b.country||'??'))}</span></td>
      <td data-label="拦截原因"><span class="cell-v"><span class="pill ${reasonClass(b.reason)}" title="${esc(b.reason_text||'')}">${esc(reasonLabel(b.reason))}</span></span></td>
      <td data-label="访问路径"><span class="cell-v" title="${esc(b.path)}">${esc(b.path)}</span></td>
      <td data-label="User-Agent"><span class="cell-v mono" style="font-size:12px;color:var(--t2);word-break:break-all" title="${esc(ua)}">${ua?esc(uaShort):'<span style="color:var(--t3)">—</span>'}</span></td>
    </tr>`}).join('');
    tb.querySelectorAll('.ip-link').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
  }catch(e){console.error('loadBlocks error:',e)}
}


function collect(){
  const raw=parseInt(document.getElementById('portInput').value,10);
  return{port:isNaN(raw)?0:raw,china_only:document.getElementById('chinaOnly').checked,whitelist:document.getElementById('whitelist').value.split('\n').map(x=>x.trim()).filter(Boolean),geo_api:true,ban_list:document.getElementById('banList').value.split('\n').map(x=>x.trim()).filter(Boolean),auto_ban:document.getElementById('autoBan').checked,rate_limit:parseInt(document.getElementById('rateLimit').value,10)||0,allowed_uas:document.getElementById('allowedUAs').value.split('\n').map(x=>x.trim()).filter(Boolean),enable_cache:document.getElementById('cacheToggle').checked,cors:document.getElementById('corsToggle').checked,pwa:document.getElementById('pwaToggle').checked}
}
async function save(){
  try{
    const r=await fetch('/admin/api/save',{method:'POST',body:JSON.stringify(collect())});
    if(!r.ok)throw new Error(await r.text());
    const c=await r.json();applyPort(c.effective_port);
    // 开启 PWA 模式时：提示是否把启动页安装到主屏幕/桌面（安装后桌面图标秒开）
    const nowOn=document.getElementById('pwaToggle').checked;
    if(nowOn && !state.pwaOn){
      state.pwaOn=true;
      if(confirm('PWA 模式已开启！\n\n是否把启动页安装到主屏幕/桌面？\n\n· 安装后桌面会出现 Emby Proxy 图标\n· 点击图标从快速启动页直接进入后台\n· 需刷新页面后弹出安装提示')){ 
        sessionStorage.setItem('pwaInstallAsk','1');
        location.reload();
        return;
      }
    }else if(!nowOn && state.pwaOn){
      state.pwaOn=false;
      alert('PWA 模式已关闭，页面即将刷新生效');
      location.reload();
      return;
    }
    alert('配置已保存并即时生效');
  }catch(e){alert('保存失败：'+(e.message||'未知错误'))}
}
document.getElementById('savePort').addEventListener('click',save);document.getElementById('saveAll').addEventListener('click',save);

document.getElementById('changePassBtn').addEventListener('click',async()=>{
  const o=document.getElementById('oldPass').value,n=document.getElementById('newPass').value;
  if(!o||!n||n.length<6){alert('请先填写当前密码，新密码至少 6 位');return}
  const r=await fetch('/admin/api/change-password',{method:'POST',body:JSON.stringify({OldPass:o,NewPass:n})});
  if(r.ok){alert('密码修改成功，即将跳转到登录页，请用新密码重新登录');location.reload()}else{alert('密码修改失败：'+(await r.text()||'未知错误'))}
});
document.getElementById('clearStatsBtn').addEventListener('click',async()=>{
  if(!confirm('确定清空全部统计数据？此操作不可恢复。'))return;
  await fetch('/admin/api/clear-stats',{method:'POST'});alert('统计数据已清空');loadOverview();
});

document.getElementById('ovRangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#ovRangeBar .filter').forEach(b => b.classList.toggle('on', b === btn));
  state.ovRange = btn.dataset.r;
  updateOvStats();
});

document.getElementById('tfRangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#tfRangeBar .filter').forEach(b => b.classList.toggle('on', b === btn));
  state.tfRange = btn.dataset.r;
  const box=document.getElementById('tfCustomBox');
  if(box) box.style.display = state.tfRange==='custom' ? 'flex' : 'none';
  if(state.tfRange!=='custom') applyTrafficView();
});
document.getElementById('tfApplyCustom')?.addEventListener('click',()=>{
  state.tfFrom=document.getElementById('tfFrom').value||'';
  state.tfTo=document.getElementById('tfTo').value||'';
  if(!state.tfFrom||!state.tfTo){alert('请选择开始和结束日期');return}
  applyTrafficView();
});

document.getElementById('lvClearBtn')?.addEventListener('click',()=>{
  if(!confirm('清空本页累计的连接记录？'))return;
  resetLiveSession();
  renderLiveTables();
});
document.addEventListener('click',e=>{
  const btn=e.target.closest('[data-live-page]');
  if(!btn)return;
  const to=parseInt(btn.getAttribute('data-to'),10);
  if(!to||to<1)return;
  if(btn.getAttribute('data-live-page')==='conn') liveSession.connPage=to;
  else liveSession.ipPage=to;
  renderLiveTables();
});

document.getElementById('modalClose').addEventListener('click',()=>document.getElementById('modal').classList.remove('on'));
document.getElementById('modal').addEventListener('click',e=>{if(e.target.id==='modal')e.currentTarget.classList.remove('on')});

const _origFetch = window.fetch;
window.fetch = async function(...args) {
  const res = await _origFetch.apply(this, args);
  if (res.status === 401) {
    const url = (typeof args[0] === 'string') ? args[0] : (args[0] && args[0].url) || '';
    if (url.includes('/admin/api/') && !url.includes('/admin/api/login')) {
      location.href = '/admin/login';
      return res;
    }
  }
  return res;
};
document.getElementById('logoutBtn')?.addEventListener('click', async () => {
  try { await fetch('/admin/api/logout', {method:'POST'}); } catch(e) {}
  location.href = '/admin/login';
});

/* ----- PWA 安装提示 -----
 * 浏览器满足安装条件（PWA 开启 + SW 就绪）时触发 beforeinstallprompt；
 * · 设置页出现“安装应用”按钮，随时可安装；
 * · 若刚开启 PWA（sessionStorage 标记，刷新后），自动弹出系统安装对话框，
 *   询问“是否把启动页添加到主屏幕/桌面”。 */
let pwaInstallPrompt=null;
function showInstallBtn(){
  const row=document.getElementById('pwaInstallRow');
  if(row) row.style.display='flex';
}
async function pwaInstall(){
  if(!pwaInstallPrompt){
    alert('当前浏览器暂未就绪或已安装。\n提示：可使用浏览器的“添加到主屏幕/安装应用”菜单功能手动安装。');
    return;
  }
  pwaInstallPrompt.prompt();
  try{
    const choice=await pwaInstallPrompt.userChoice;
    if(choice&&choice.outcome==='accepted'){
      alert('安装成功！\n桌面/主屏幕已出现 Emby Proxy 图标，点击即可从快速启动页进入后台。');
      document.getElementById('pwaInstallRow').style.display='none';
    }
  }catch(e){}
  pwaInstallPrompt=null;
}
window.addEventListener('beforeinstallprompt',e=>{
  e.preventDefault();
  pwaInstallPrompt=e;
  // PWA 开启状态才显示安装入口（关闭时浏览器也不会触发该事件，双保险）
  if(document.getElementById('pwaToggle')&&document.getElementById('pwaToggle').checked) showInstallBtn();
  // 刚开启 PWA 并刷新进来：自动弹出系统级“添加到主屏幕”提示
  if(sessionStorage.getItem('pwaInstallAsk')==='1'){
    sessionStorage.removeItem('pwaInstallAsk');
    setTimeout(()=>{ if(pwaInstallPrompt) pwaInstall(); },600);
  }
});
window.addEventListener('appinstalled',()=>{
  pwaInstallPrompt=null;
  const row=document.getElementById('pwaInstallRow');
  if(row) row.style.display='none';
});
document.getElementById('pwaInstallBtn')?.addEventListener('click',pwaInstall);
// 已作为独立应用运行时隐藏安装入口
if(window.matchMedia&&window.matchMedia('(display-mode: standalone)').matches){
  const row=document.getElementById('pwaInstallRow');
  if(row) row.style.display='none';
}

loadConfig();
// Chart.js 使用 defer 异步加载：先并行下载，等就绪后再拉概览（趋势图依赖）；
// 首屏 HTML 解析不再被外部脚本阻塞，最快 10 秒后无论如何继续（图表等切页时再渲染）
(function waitForChart(){
  if(typeof Chart!=='undefined'){ loadOverview(); return; }
  var n=0;
  var t=setInterval(function(){
    n++;
    if(typeof Chart!=='undefined'||n>200){ clearInterval(t); loadOverview(); }
  },50);
})();
let ovTimer=setInterval(()=>{if(!document.hidden)loadOverview()},5000);
document.addEventListener('visibilitychange',()=>{
  if(!document.hidden){
    loadOverview();
    // 拦截记录页处于激活状态时，回到页面立即刷新一次
    if(document.getElementById('blocks')?.classList.contains('on'))loadBlocks();
  }
});
</script>
</body>
</html>
ADMIN_HTML
}

compute_source_hash() {
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"
  local d h
  d="$(mktemp -d)"
  write_go_source "$d"
  h="$(cd "$d" && sha256sum main.go admin.html | sha256sum | awk '{print $1}')"
  rm -rf "$d"
  printf '%s' "$h"
}
genpass() { head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20; }
systemd_quote() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//%/%%}"; printf '"%s"' "$s"; }
make_unit() {
  local u p
  u="$(systemd_quote "$ADMIN_USER")"
  p="$(systemd_quote "$ADMIN_PASS")"
  cat <<UNIT
[Unit]
Description=Emby Path Reverse Proxy (Go)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
# GOGC=100 保持默认 GC 节奏；GOMEMLIMIT 设软内存上限 256MiB，
# 超出后 GC 加速回收，避免堆无节制增长挤占小内存 VPS
Environment=GOGC=100
Environment=GOMEMLIMIT=256MiB
ExecStart=${BIN_PATH} run -port ${PORT} -admin-user ${u} -admin-pass ${p} -db ${DB_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
UNIT
}
# 编译二进制：可选用 --prebuilt；否则写源码、go mod、CGO_ENABLED=0 静态链接
build_binary() {
  local out="$1"
  if [[ -n "$PREBUILT" ]]; then [[ -f "$PREBUILT" ]] || die "预构建二进制不存在: $PREBUILT"; cp -f "$PREBUILT" "$out"; chmod 0755 "$out"; return; fi
  ensure_go
  BUILD_TMPDIR="$(mktemp -d)"
  write_go_source "$BUILD_TMPDIR"
  info "初始化模块并解析依赖..."
  (
    cd "$BUILD_TMPDIR"
    export GOTOOLCHAIN=auto GOFLAGS=-mod=mod
    go mod init emby-proxy >/dev/null 2>&1 || true
    go get "github.com/phuslu/iploc@${IPLOC_VERSION}" >/dev/null 2>&1 || true
    go get "go.etcd.io/bbolt@latest" >/dev/null 2>&1 || true
    go get "golang.org/x/sync/singleflight@v0.10.0" >/dev/null 2>&1 || true
    go get "github.com/gorilla/websocket@v1.5.3" >/dev/null 2>&1 || true
    go mod tidy >/dev/null 2>&1 || die "依赖解析失败（可设 GOPROXY=https://goproxy.cn,direct 后重试）"
  )
  info "编译中..."
  ( cd "$BUILD_TMPDIR" && CGO_ENABLED=0 GOTOOLCHAIN=auto GOFLAGS=-mod=mod go build -trimpath -ldflags "-s -w" -o "$out" . ) || die "go build 失败"
}
local_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"; fi
  [[ -z "$ip" ]] && ip="127.0.0.1"
  printf '%s' "$ip"
}
port_listen() { (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null; }
installed_port() {
  local p=""
  if [[ -f "$DB_FILE" ]]; then p="$(sed -n 's/.*-port \([0-9]\{1,5\}\).*/\1/p' "$UNIT_FILE" 2>/dev/null | head -1)"; fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; else printf '%s' "$DEFAULT_PORT"; fi
}
effective_port() { installed_port; }
print_access_info() {
  local ip ep; ip="$(local_ip)"; ep="$(effective_port)"
  printf '\n   管理页:  http://%s:%s/admin/\n' "$ip" "$ep"
  printf '   用户名:  %s\n' "$ADMIN_USER"
  printf '   密  码:  %s\n' "$ADMIN_PASS"
  printf '   查看日志: journalctl -u %s -f\n\n' "$SERVICE_NAME"
}

# 限制系统 journal 日志大小，防止磁盘撑爆
setup_journal_limit() {
  local conf_dir="/etc/systemd/journald.conf.d"
  local conf_file="${conf_dir}/size.conf"
  if [[ ! -f "$conf_file" ]]; then
    mkdir -p "$conf_dir"
    cat > "$conf_file" <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    info "已配置系统日志限制 (SystemMaxUse=200M)"
  fi
}

# 安装/重装：编译（若源码或 unit 有变）→ 写 systemd unit → enable --now
# 支持：--port --admin-pass --bin --prebuilt --force --code-only
cmd_install() {
  parse_install_args "$@"
  require_root install
  require_systemd
  setup_journal_limit
  
  if [[ -t 0 ]] && [[ $BINARY_ONLY -eq 0 ]] && [[ $PORT_GIVEN -eq 0 || $PASS_GIVEN -eq 0 ]]; then
    printf '\n'
    if [[ $PORT_GIVEN -eq 0 ]]; then prompt_port "$(installed_port)" || die "已取消"; PORT="$PROMPT_RESULT"; fi
    if [[ -z "$ADMIN_PASS" ]]; then prompt_pass || die "已取消"; ADMIN_PASS="$PROMPT_RESULT"; PASS_GIVEN=1; fi
  fi
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口无效: $PORT"
  if [[ $BINARY_ONLY -eq 1 ]]; then info "更新模式：只替换程序"; fi
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  if [[ ! -f "$DB_FILE" ]]; then
    if [[ -n "$ADMIN_PASS" ]]; then GENERATED_PASS=1
    else ADMIN_PASS="$(genpass)"; GENERATED_PASS=1; fi
  else
    if [[ -f "$UNIT_FILE" ]]; then ADMIN_PASS="$(sed -n 's/.*-admin-pass "\(.*\)".*/\1/p' "$UNIT_FILE" | head -1)"; fi
    [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="$(genpass)"
    GENERATED_PASS=0
  fi
  local expected_unit; expected_unit="$(make_unit)"
  local need_compile=0 need_reload=0 new_hash=""
  if [[ -n "$PREBUILT" || $FORCE -eq 1 ]]; then need_compile=1
  elif [[ ! -x "$BIN_PATH" || ! -f "$BUILD_HASH_FILE" ]]; then need_compile=1
  else
    new_hash="$(compute_source_hash)"
    if [[ "$new_hash" != "$(cat "$BUILD_HASH_FILE" 2>/dev/null || true)" ]]; then need_compile=1; info "检测到源码变化"; fi
  fi
  if [[ "$(cat "$UNIT_FILE" 2>/dev/null || true)" != "$expected_unit" ]]; then need_reload=1; fi
  if [[ $BINARY_ONLY -eq 1 ]]; then need_reload=0; fi
  if [[ $need_compile -eq 0 && $need_reload -eq 0 ]]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then info "已是最新版本，服务运行中"
    else info "已是最新版本，正在启动..."; systemctl start "$SERVICE_NAME"; fi
    print_access_info; return
  fi
  if [[ $need_compile -eq 1 ]]; then
    local stage; stage="$(mktemp -d)/emby-proxy"
    build_binary "$stage"
    info "二进制编译完成"
    stop_and_disable
    mkdir -p "$(dirname "$BIN_PATH")"
    local tmp_dst="${BIN_PATH}.tmp.$$"
    cp -f "$stage" "$tmp_dst"; chmod 0755 "$tmp_dst"; mv -f "$tmp_dst" "$BIN_PATH"
    info "已安装二进制: $BIN_PATH"
    if [[ -z "$PREBUILT" ]]; then [[ -n "$new_hash" ]] || new_hash="$(compute_source_hash)"; printf '%s' "$new_hash" > "$BUILD_HASH_FILE"; else rm -f "$BUILD_HASH_FILE"; fi
  fi
  if [[ $need_reload -eq 1 ]]; then
    printf '%s\n' "$expected_unit" > "$UNIT_FILE"; chmod 0600 "$UNIT_FILE"  # unit 内含明文管理密码，禁止其他用户读取
    info "已更新 systemd unit"; systemctl daemon-reload
  fi
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    if port_listen "$(effective_port)"; then info "🎉 安装完成！端口 $(effective_port) 已监听"
    else warn "服务已启动，端口暂未监听（稍等几秒）"; fi
    print_access_info
  else
    err "启动失败: journalctl -u $SERVICE_NAME -n 80 --no-pager"; exit 1
  fi
}
cmd_uninstall() {
  local keep=0 assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-config) keep=1; shift ;;
      -y|--yes) assume_yes=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1" ;;
    esac
  done
  require_root uninstall
  require_systemd
  if [[ $assume_yes -eq 0 ]]; then
    if [[ ! -t 0 ]]; then die "非交互请加 --yes"; fi
    if [[ $keep -eq 1 ]]; then printf '即将卸载（保留配置）。输入 y 确认: '; else printf '即将卸载并删除所有配置。输入 y 确认: '; fi
    local ans=""; read -r ans || true
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "已取消"; return 0; }
  fi
  stop_and_disable
  [[ -f "$UNIT_FILE" ]] && { rm -f "$UNIT_FILE"; info "已删除服务单元"; }
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  [[ -f "$DEFAULT_BIN" ]] && { rm -f "$DEFAULT_BIN"; info "已删除程序: $DEFAULT_BIN"; }
  if [[ $keep -eq 1 ]]; then warn "已保留配置目录: $CONFIG_DIR"
  else [[ -d "$CONFIG_DIR" ]] && { rm -rf "$CONFIG_DIR"; info "已删除配置目录"; }; fi
  rm -f "${DEFAULT_BIN}.tmp."* 2>/dev/null || true
  info "卸载完成"
}
# 更新：强制重编译并只替换程序（保留配置与 unit 中的端口/密码）
cmd_update() {
  require_root update
  require_systemd
  if [[ ! -f "$UNIT_FILE" ]] && ! has_binary; then die "还没有安装，请先执行: sudo $0 install"; fi
  cmd_install --force --code-only "$@"
}
cmd_ctl() { require_root "$1"; require_systemd; systemctl "$1" "$SERVICE_NAME"; }
cmd_status() { require_systemd; systemctl status "$SERVICE_NAME" --no-pager -l || true; }
C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_C=$'\033[1;36m'; C_0=$'\033[0m'; C_M=$'\033[0;35m'
if [[ ! -t 1 ]]; then C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_C=""; C_0=""; C_M=""; fi
term_cols() {
  local c=""
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then c="$(tput cols 2>/dev/null || true)"; fi
  [[ "$c" =~ ^[0-9]+$ ]] && (( c > 0 )) || c=68
  (( c > 88 )) && c=88
  (( c < 52 )) && c=52
  printf '%s' "$((c - 2))"
}
hline() { local n="$1" ch="${2:-─}" s=""; (( n > 0 )) || return 0; printf -v s '%*s' "$n" ''; printf '%s' "${s// /$ch}"; }
if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]* ]]; then BOX_H1='━'; BOX_H2='─'; else BOX_H1='='; BOX_H2='-'; fi
svc_state() {
  if [[ ! -f "$UNIT_FILE" && ! -x "$BIN_PATH" && ! -x "$DEFAULT_BIN" ]]; then printf '未安装'; return; fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then printf '运行中'; else printf '已停止'; fi
}
svc_state_colored() {
  case "$(svc_state)" in
    运行中) printf '%s' "${C_G}● 运行中${C_0}" ;;
    已停止) printf '%s' "${C_Y}● 已停止${C_0}" ;;
    *)      printf '%s' "${C_D}○ 未安装${C_0}" ;;
  esac
}
has_binary() { [[ -x "$BIN_PATH" || -x "$DEFAULT_BIN" ]]; }
has_install() { [[ -f "$UNIT_FILE" ]] && return 0; has_binary && return 0; [[ -d "$CONFIG_DIR" ]]; }
installed_bin_path() { if [[ -x "$BIN_PATH" ]]; then printf '%s' "$BIN_PATH"; return; fi; if [[ -x "$DEFAULT_BIN" ]]; then printf '%s' "$DEFAULT_BIN"; fi; }
build_time() { local b; b="$(installed_bin_path)"; if [[ -n "$b" ]]; then date -r "$b" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '未知'; else printf '—'; fi; }
menu_rule() { printf '   %s%s%s\n' "$C_D" "$(hline "$(term_cols)" "$BOX_H2")" "$C_0"; }
menu_banner() {
  local ip ep svc bt W
  ip="$(local_ip)"; ep="$(effective_port)"; svc="$(svc_state_colored)"; bt="$(build_time)"; W="$(term_cols)"
  printf '\n%s%s%s\n' "$C_M" "$(hline "$W" "$BOX_H1")" "$C_0"
  printf '  %s⚡ Emby 路径反代%s  %s·%s  %s管理菜单%s\n' "$C_B" "$C_0" "$C_D" "$C_0" "$C_D" "$C_0"
  printf '%s%s%s\n\n' "$C_M" "$(hline "$W" "$BOX_H1")" "$C_0"
  printf '   %s服务%s   %s\n' "$C_D" "$C_0" "$svc"
  printf '   %s端口%s   %s:%s%s\n' "$C_D" "$C_0" "$C_C" "$ep" "$C_0"
  printf '   %s访问%s   %s\n' "$C_D" "$C_0" "$C_C" "http://${ip}:${ep}/admin/"
  printf '   %s构建%s   %s\n\n' "$C_D" "$C_0" "$bt"
  menu_rule; printf '\n'
  printf '   %s[1]%s  安装 / 重新安装    %s设置端口与密码，完整装一遍%s\n' "$C_B$C_C" "$C_0" "$C_D" "$C_0"
  printf '   %s[2]%s  更新代码           %s重新编译并替换程序%s\n' "$C_B$C_C" "$C_0" "$C_D" "$C_0"
  printf '   %s[3]%s  卸载               %s停止服务，删除程序、配置、统计%s\n' "$C_B$C_C" "$C_0" "$C_D" "$C_0"
  printf '   %s[4]%s  运行状态           %s查看服务状态%s\n' "$C_B$C_C" "$C_0" "$C_D" "$C_0"
  printf '   %s[5]%s  查看日志           %s最近 60 行%s\n' "$C_B$C_C" "$C_0" "$C_D" "$C_0"
  printf '   %s[0]%s  退出\n\n' "$C_B" "$C_0"
  printf '%s%s%s\n\n' "$C_M" "$(hline "$W" "$BOX_H1")" "$C_0"
}
press_enter() { printf '\n   %s↵ 按回车返回菜单…%s' "$C_D" "$C_0"; read -r _ || true; }
log_tail() { if ! command -v journalctl >/dev/null 2>&1; then warn "没有 journalctl"; return 0; fi; journalctl -u "$SERVICE_NAME" -n 60 --no-pager 2>/dev/null || warn "读取日志失败"; }
ask_yes_default() { printf '  %s ' "$1"; local a=""; read -r a || a=""; case "$a" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac; }
ask_yes() { printf '  %s ' "$1"; local a=""; read -r a || a=""; [[ "$a" == "y" || "$a" == "Y" ]]; }
PROMPT_RESULT=""
prompt_port() {
  local def="$1" port=""
  while true; do
    printf '   %s监听端口%s [%s]: ' "$C_D" "$C_0" "$def"
    if ! read -r port; then printf '\n'; return 1; fi
    port="${port//[[:space:]]/}"
    if [[ -z "$port" ]]; then PROMPT_RESULT="$def"; return 0; fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then warn "端口需在 1-65535"; continue; fi
    if port_listen "$port" && [[ "$port" != "$(effective_port)" ]]; then
      if ! ask_yes "端口 $port 已被占用，仍要使用？[y/N]"; then continue; fi
    fi
    PROMPT_RESULT="$port"; return 0
  done
}
prompt_pass() {
  local pass=""
  printf '   %s管理密码%s [留空 = 自动生成]: ' "$C_D" "$C_0"
  if ! read -r pass; then printf '\n'; return 1; fi
  if [[ "$pass" != *[![:space:]]* ]]; then pass=""; fi
  PROMPT_RESULT="$pass"; return 0
}
menu_install_flow() {
  printf '\n   %s安装 / 重新安装%s\n\n' "$C_B" "$C_0"
  if [[ "$(svc_state)" == "运行中" ]]; then warn "服务正在运行，安装会先停止服务；配置、白名单、统计都会保留"; printf '\n'; fi
  local def_port port pass
  def_port="$(installed_port)"
  prompt_port "$def_port" || return 1
  port="$PROMPT_RESULT"
  prompt_pass || return 1
  pass="$PROMPT_RESULT"
  printf '\n'; menu_rule
  printf '   %s端口%s   %s\n' "$C_D" "$C_0" "$port"
  if [[ -n "$pass" ]]; then printf '   %s密码%s   %s\n' "$C_D" "$C_0" "$pass"
  elif [[ -f "$DB_FILE" ]]; then printf '   %s密码%s   沿用已保存的密码\n' "$C_D" "$C_0"
  else printf '   %s密码%s   自动生成\n' "$C_D" "$C_0"; fi
  printf '   %s访问%s   http://%s:%s/admin/\n' "$C_D" "$C_0" "$(local_ip)" "$port"
  menu_rule; printf '\n'
  if ! ask_yes_default "   $C_G❯$C_0 开始安装？[Y/n]"; then info "已取消"; return 0; fi
  printf '\n'
  local args=( --port "$port" --admin-pass "$pass" )
  if ( cmd_install "${args[@]}" ); then return 0; fi
  warn "安装失败"; return 1
}
cmd_menu() {
  if [[ $EUID -ne 0 ]]; then die "菜单需要 root 权限: sudo $0"; fi
  if [[ ! -t 0 ]]; then die "菜单需要交互终端；非交互请用子命令"; fi
  while true; do
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    menu_banner
    printf '   %s❯%s 选择 %s[0-5]%s: ' "$C_G" "$C_0" "$C_D" "$C_0"
    local choice=""; read -r choice || { printf '\n'; return 0; }
    choice="${choice//[[:space:]]/}"
    case "$choice" in
      1) menu_install_flow || true; press_enter ;;
      2) printf '\n'; if [[ ! -f "$UNIT_FILE" ]] && ! has_binary; then warn "还没有安装"; sleep 1; continue; fi; ( cmd_update ) || warn "更新失败"; press_enter ;;
      3) printf '\n'; if ! has_install; then warn "当前没有安装"; sleep 1; continue; fi; warn "卸载会删除：服务、程序、配置、管理密码、统计数据、地区缓存"; if ! ask_yes "   $C_R❯$C_0 输入 y 确认: [y/N]"; then info "已取消"; sleep 1; continue; fi; ( cmd_uninstall --yes ) || warn "卸载出错"; press_enter ;;
      4) printf '\n'; cmd_status; press_enter ;;
      5) printf '\n'; log_tail; press_enter ;;
      0|q|Q|exit|quit) printf '\n'; info "已退出"; return 0 ;;
      "") continue ;;
      *) warn "无效序号: $choice"; sleep 1 ;;
    esac
  done
}
# 入口：无参数默认进入交互菜单
main() {
  local sub="${1:-menu}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$sub" in
    menu) cmd_menu ;;
    install) cmd_install "$@" ;;
    update|upgrade) cmd_update "$@" ;;
    uninstall|remove) cmd_uninstall "$@" ;;
    status) cmd_status ;;
    start|stop|restart) cmd_ctl "$sub" ;;
    -h|--help|help) usage ;;
    *) die "未知命令: $sub" ;;
  esac
}
main "$@"
