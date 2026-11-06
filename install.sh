#!/usr/bin/env bash
# =============================================================================
# Emby 路径反代 v2.2.0 — 一键安装 / 管理脚本
# =============================================================================
#
# 功能概览
#   · 内嵌完整 Go 源码（路径反代服务 + 管理后台 HTML）
#   · 自动检测/安装 Go，编译为静态二进制并注册 systemd 服务
#   · 子命令：menu | install | update | uninstall | status | start|stop|restart
#
# 数据目录（默认）
#   /etc/emby-proxy/emby.db     bolt 库：配置、统计、认证（唯一的本地持久化数据）
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
Emby 路径反代 v2.2.0 一键安装
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
Emby 路径反代 v2.2.0服务（单文件）

访问模型
  客户端请求：  GET /https://emby.example.com:8096/web/index.html
  本服务解析路径中的目标 URL，按白名单/地区/限流校验后反代到上游。

上下行口径（服务端视角）
  · 下行 down = 上游→本机（从源站读到的字节）
  · 上行 up   = 本机→客户端（写给客户端的字节）

主要模块
  · parseTarget / buildProxy     路径解析与 httputil.ReverseProxy
  · Config + bolt DB            持久化配置与统计
  · 访问控制                    白名单、ChinaOnly、黑名单、UA、限流（ACL 预编译）
  · 统计                        异步 channel 聚合，按日分桶，定期落盘
  · 管理后台                    /admin/ 嵌入 admin.html，会话 Cookie + 验证码登录
  · PWA 模式                    内置常开：manifest + Service Worker（不含离线缓存），后台可安装为独立应用
  · 品牌图标                    favicon / Logo / PWA 图标（192、512）一律 302 到源站，本地不留副本
  · CORS                        不提供跨域响应头（功能已移除，预检按普通请求转发上游）

时区
  统计分日/分时与对外时间字段统一按 Asia/Shanghai（北京时间）。

内存与资源
  · 除 bolt 数据库外不做任何本地缓存（图标/HTML/SW/geo 均不落盘、不驻留副本）
  · geo 查询结果仅放在进程内 map，随进程退出丢弃
  · 统计 map 定期 pruneTopN，防止无限增长
  · GOMEMLIMIT 由 systemd unit 设为 256MiB 软限制
*/

import (
	"bufio"
	"bytes"
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
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/phuslu/iploc"
	"github.com/gorilla/websocket"
	bolt "go.etcd.io/bbolt"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/sync/singleflight"
)

//go:embed admin.html
// adminHTML 为管理后台单页（构建时由脚本写入同目录 admin.html 后 embed）
var adminHTML []byte

// 上下文键：在 ReverseProxy.Rewrite 中取回目标 URL
type targetCtxKey struct{}

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
	html := `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><link rel="icon" href="/favicon.ico` + iconVer + `"><title>` + pageTitle + `</title><style>` + pageCSS + `</style></head><body><div class="card"><div class="brand"><img class="brand-logo" src="/admin/logo.png" alt=""><h1>服务</h1><p>运行中</p></div>` + statusHTML + titleHTML + `<div class="desc">` + desc + `</div>` + extraHTML + `<div class="foot">服务</div></div></body></html>`
	_, _ = w.Write([]byte(html))
}

func serveHome(w http.ResponseWriter, r *http.Request) {
	extra := `<div class="acts" style="margin-top:8px"><a class="btn g" href="/admin/">管理</a></div>`
	writePage(w, http.StatusOK, "", "", "",
		"服务运行中。", extra)
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
	extra := `<div class="acts"><a class="btn g" href="/">返回</a></div>`
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
	for len(rest) > 0 && rest[0] == '/' {
		rest = rest[1:]
	}
	if rest == "" {
		return nil, fmt.Errorf("缺少目标主机")
	}
	var scheme, body string
	body = rest
	// 避免整段 ToLower：只看前缀
	for i := 0; i < 3; i++ {
		if len(body) >= 6 && strings.EqualFold(body[:6], "https:") {
			if scheme == "" {
				scheme = "https"
			}
			body = body[6:]
		} else if len(body) >= 5 && strings.EqualFold(body[:5], "http:") {
			if scheme == "" {
				scheme = "http"
			}
			body = body[5:]
		} else {
			break
		}
		for len(body) > 0 && body[0] == '/' {
			body = body[1:]
		}
	}
	authority, pathPart := splitAuthority(body)
	if authority == "" {
		return nil, fmt.Errorf("缺少目标主机")
	}
	if scheme == "" {
		scheme = schemeForAuthority(authority)
	}
	// 用 url.URL 直接构造，少一次字符串拼接 + Parse
	u := &url.URL{Scheme: scheme, Host: authority, Path: pathPart, RawQuery: r.URL.RawQuery}
	if u.Host == "" {
		return nil, fmt.Errorf("目标地址无效：%s", authority)
	}
	return u, nil
}

// Config 网关运行时配置（JSON 存入 bolt bucket "config"）
type Config struct {
	Port        int      `json:"port"`         // 监听端口；保存后可热切换
	ChinaOnly   bool     `json:"china_only"`   // 仅允许中国大陆 IP（本地 iploc 判断）
	Whitelist   []string `json:"whitelist"`    // 上游域名白名单，空=不限制；支持根域匹配
	BanList     []string `json:"ban_list"`     // IP 或 CIDR
	AutoBan     bool     `json:"auto_ban"`     // 触发地区拦截时自动写入黑名单
	RateLimit   int      `json:"rate_limit"`   // 每 IP 每分钟请求上限，0=关闭
	AllowedUAs  []string `json:"allowed_uas"`  // UA 关键字白名单，空=不限制
	// 说明：CORS 与 PWA 已固化为程序常量（CORS 关闭、PWA 常开），不再作为可配置项，
	// 也不再出现在后台设置中；旧数据库里遗留的 cors/pwa 字段会被自动忽略。
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
	db        *bolt.DB
	dbPath    string
	cfgPtr    atomic.Pointer[Config]
	proxyTr   = &switchTransport{}
	listenMu  sync.Mutex
	curLn     net.Listener
	curPort   int
	globalSrv *http.Server
)

// ---------- 品牌图标资源 ----------
// 不再在本地缓存图标：一律 302 到源站，由浏览器自行缓存（省去进程内的图标副本与启动预热请求）。
const (
	iconFaviconURL = "https://i.ibb.co/H9QXXb8/emby-rp-icon.jpg"      // 网页 favicon（32x32）
	iconLogoURL    = "https://i.ibb.co/KxByc0q8/emby-rp-logo.png"    // 品牌 Logo（512x512）
	icon192URL     = "https://i.ibb.co/84fwCqPj/emby-rp-logo-192.png" // PWA 192x192
	icon512URL     = "https://i.ibb.co/RkTFtq4n/emby-rp-logo-512.png" // PWA 512x512
)

// redirectIcon 直接 302 到源站图标，不在本地保存任何副本
func redirectIcon(w http.ResponseWriter, r *http.Request, src string) {
	http.Redirect(w, r, src, http.StatusFound)
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
// whitelistMatch 空列表表示不限制；支持完整 host、根域、以及 *.example.com 通配。
func whitelistMatch(list []string, targetHost string) bool {
	if len(list) == 0 {
		return true
	}
	target := normalizeHost(targetHost)
	targetRoot := rootDomain(target)
	for _, w := range list {
		w = strings.TrimSpace(w)
		// 允许行内注释
		if i := strings.IndexAny(w, "#;"); i >= 0 {
			w = strings.TrimSpace(w[:i])
		}
		if w == "" {
			continue
		}
		if strings.HasPrefix(w, "*.") {
			suf := strings.ToLower(strings.TrimPrefix(w, "*."))
			if target == suf || strings.HasSuffix(target, "."+suf) {
				return true
			}
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

// DayStat：按天统计（UpBytes=本机→客户端，DownBytes=上游→本机，Bytes=上下行合计）
type DayStat struct {
	Requests   int64            `json:"requests"`
	Bytes      int64            `json:"bytes"`       // 上下行合计（兼容旧字段）
	UpBytes    int64            `json:"up_bytes"`    // 上行（本机→客户端）
	DownBytes  int64            `json:"down_bytes"`  // 下行（上游→本机）
	BlockedCN  int64            `json:"blocked_cn"`
	BlockedWL  int64            `json:"blocked_wl"`
	BlockedBan int64            `json:"blocked_ban"`
	BlockedRate int64           `json:"blocked_rate"`
	BlockedUA  int64            `json:"blocked_ua"`
	Countries  map[string]int64 `json:"countries,omitempty"`
	IPs        map[string]int64 `json:"ips,omitempty"`
	IPBytes    map[string]int64 `json:"ip_bytes,omitempty"`
	IPUpBytes  map[string]int64 `json:"ip_up_bytes,omitempty"`
	IPDownBytes map[string]int64 `json:"ip_down_bytes,omitempty"`
	Hours      map[string]int64 `json:"hours,omitempty"`
	HourBytes  map[string]int64 `json:"hour_bytes,omitempty"`
	HourUpBytes map[string]int64 `json:"hour_up_bytes,omitempty"`
	HourDownBytes map[string]int64 `json:"hour_down_bytes,omitempty"`
	Hosts      map[string]int64 `json:"hosts,omitempty"`
}

func newDayStat() *DayStat {
	return &DayStat{
		Countries: map[string]int64{},
		IPs:       map[string]int64{},
		IPBytes:   map[string]int64{},
		IPUpBytes: map[string]int64{},
		IPDownBytes: map[string]int64{},
		Hours:     map[string]int64{},
		HourBytes: map[string]int64{},
		HourUpBytes: map[string]int64{},
		HourDownBytes: map[string]int64{},
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
	if d.IPUpBytes == nil {
		d.IPUpBytes = map[string]int64{}
	}
	if d.IPDownBytes == nil {
		d.IPDownBytes = map[string]int64{}
	}
	if d.Hours == nil {
		d.Hours = map[string]int64{}
	}
	if d.HourBytes == nil {
		d.HourBytes = map[string]int64{}
	}
	if d.HourUpBytes == nil {
		d.HourUpBytes = map[string]int64{}
	}
	if d.HourDownBytes == nil {
		d.HourDownBytes = map[string]int64{}
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

// hour24 把分时 map 规整成固定 24 个键（00~23），缺值为 0。
// 前端按 0~23 点直接取键作图，缺键会导致整条曲线退化为全 0 直线。
func hour24(src map[string]int64) map[string]int64 {
	out := make(map[string]int64, 24)
	for h := 0; h < 24; h++ {
		k := fmt.Sprintf("%02d", h)
		out[k] = src[k]
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
// 写入：recordRequestStart → statChan → startStatsWorker 单协程聚合
// 落盘：startStatsSaver 每 5 分钟 prune + 写入 stats_meta / stats_daily / stats_blocks
type Stats struct {
	SchemaVersion    int                 `json:"schema_version"` // 2 = 上下行新口径（下行=上游→本机，上行=本机→客户端）
	TodayDate        string              `json:"today_date"`
	TodayRequests    int64               `json:"today_requests"`
	TodayBytes       int64               `json:"today_bytes"`
	TodayUpBytes     int64               `json:"today_up_bytes"`
	TodayDownBytes   int64               `json:"today_down_bytes"`
	TotalRequests    int64               `json:"total_requests"`
	TotalBytes       int64               `json:"total_bytes"`
	TotalUpBytes     int64               `json:"total_up_bytes"`
	TotalDownBytes   int64               `json:"total_down_bytes"`
	BlockedCN        int64               `json:"blocked_cn"`
	BlockedWhitelist int64               `json:"blocked_whitelist"`
	BlockedBan       int64               `json:"blocked_ban"`
	BlockedRate      int64               `json:"blocked_rate"`
	BlockedUA        int64               `json:"blocked_ua"`
	LastProxyAt      string              `json:"last_proxy_at"`
	CountryCounts    map[string]int64    `json:"country_counts"`
	IPCounts         map[string]int64    `json:"ip_counts"`
	IPBytes          map[string]int64    `json:"ip_bytes"`
	IPUpBytes        map[string]int64    `json:"ip_up_bytes"`
	IPDownBytes      map[string]int64    `json:"ip_down_bytes"`
	Daily            map[string]*DayStat `json:"daily,omitempty"`
	Blocks           []BlockEvent        `json:"blocks"`
	Audit            []AuditEvent        `json:"audit,omitempty"`
}

// AuditEvent 管理操作审计
type AuditEvent struct {
	Time   string `json:"time"`
	IP     string `json:"ip"`
	Action string `json:"action"`
	Detail string `json:"detail"`
}

var (
	stats   Stats
	statsMu sync.Mutex
)

type statEvent struct {
	IP       string
	Country  string
	Host     string
	Bytes    int64
	UpBytes  int64
	DownBytes int64
	IsStart  bool
}

var statChan = make(chan statEvent, 10000)

// ---------- 实时监控（仅在有 WS 客户端时收集，退出即清空，不落盘） ----------
var concurrent atomic.Int64
var liveClients atomic.Int32

// ---------- 端口级流量计数 ----------
// /proc/net/dev 只能按网卡统计，同一网卡上其他进程的流量无法剔除，
// 导致后台显示的“流量”远大于本服务实际转发量。
// 改为在转发链路上自行计数：只有真正经过本服务的字节才计入，
// 与整机网卡、其他进程彻底无关，跨平台且零依赖。
type portTraffic struct {
	down atomic.Int64 // 上游→本机（下行，从源站读到的字节）
	up   atomic.Int64 // 本机→客户端（上行）
}

var traffic portTraffic

// countingReader 包装响应体，读取时累计下行字节。
// 反代是边读边写的同步拷贝，读多少基本等于写给客户端多少。
type countingReader struct{ r io.Reader }

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if n > 0 {
		traffic.down.Add(int64(n))
	}
	return n, err
}

// countingWriter 包装 ResponseWriter，写出时累计上行字节。
type countingWriter struct {
	http.ResponseWriter
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.ResponseWriter.Write(p)
	if n > 0 {
		traffic.up.Add(int64(n))
	}
	return n, err
}

// Flush 透传，保证 FlushInterval 逻辑与 SSE 场景不被包装破坏
func (c *countingWriter) Flush() {
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// netSpeedWake 用于唤醒空闲期长睡的采样器：
// 有人打开实时监控时立刻投递信号，采样器不必等长睡结束就能马上采集一次，
// 避免“刚进页面要等几分钟才出数”。带缓冲 1，重复投递不会阻塞。
var netSpeedWake = make(chan struct{}, 1)

func wakeNetSpeedSampler() {
	select {
	case netSpeedWake <- struct{}{}:
	default:
	}
}

type liveEvent struct {
	Time    string `json:"time"`
	IP      string `json:"ip"`
	Country string `json:"country"`
	Host    string `json:"host"`
	Path    string `json:"path"`
	Seq     int64  `json:"seq"`
}

const liveCap = 80

var (
	liveMu   sync.Mutex
	liveBuf  []liveEvent
	liveHead int
	rpsCount atomic.Int64
	rpsLast  atomic.Int64
	liveSeq  atomic.Int64
)

func pushLiveEvent(ip, country, host, path string) {
	if liveClients.Load() == 0 {
		return // 无人观看时不收集
	}
	now := time.Now()
	sec := now.Unix()
	if rpsLast.Load() != sec {
		rpsLast.Store(sec)
		rpsCount.Store(1)
	} else {
		rpsCount.Add(1)
	}
	ev := liveEvent{
		Time:    now.In(beijingLoc).Format("15:04:05"),
		IP:      ip,
		Country: country,
		Host:    host,
		Path:    path,
		Seq:     liveSeq.Add(1),
	}
	liveMu.Lock()
	if len(liveBuf) < liveCap {
		liveBuf = append(liveBuf, ev)
	} else {
		liveBuf[liveHead] = ev
		liveHead = (liveHead + 1) % liveCap
	}
	liveMu.Unlock()
}

func clearLive() {
	liveMu.Lock()
	liveBuf = nil
	liveHead = 0
	liveMu.Unlock()
	rpsCount.Store(0)
}

func snapshotLive() (events []liveEvent, conc int64, rps int64) {
	liveMu.Lock()
	n := len(liveBuf)
	events = make([]liveEvent, n)
	if n == liveCap {
		copy(events, liveBuf[liveHead:])
		copy(events[liveCap-liveHead:], liveBuf[:liveHead])
	} else {
		copy(events, liveBuf)
	}
	liveMu.Unlock()
	for i, j := 0, len(events)-1; i < j; i, j = i+1, j-1 {
		events[i], events[j] = events[j], events[i]
	}
	return events, concurrent.Load(), rpsCount.Load()
}

type netSpeed struct {
	RxBps int64 `json:"rx_bps"`
	TxBps int64 `json:"tx_bps"`
}
var (
	netSpeedMu  sync.RWMutex
	curNetSpeed netSpeed
)

// 说明：不再保留 readNetBytes（/proc/net/dev 整机网卡统计）。
// 该口径会把同机其他进程的流量一并计入，与“本服务转发量”严重不符，
// 现统一改用 traffic 计数器（见 portTraffic）在转发链路上精确累计。

func startNetSpeedSampler() {
	go func() {
		var lastRx, lastTx int64
		var lastT time.Time
		for {
			// 只统计经过本服务的端口流量，不再读整机网卡
			rx, tx := traffic.down.Load(), traffic.up.Load()
			now := time.Now()
			if !lastT.IsZero() {
				dt := now.Sub(lastT).Seconds()
				if dt > 0.1 {
					dRx := rx - lastRx
					dTx := tx - lastTx
					if dRx < 0 {
						dRx = 0
					}
					if dTx < 0 {
						dTx = 0
					}
					// 仅在有实时客户端时才更新“瞬时速率”。
					// 空闲期采样间隔长达 5 分钟，若也写入，页面上会显示一个
					// 跨 5 分钟的平均值，与真实瞬时网速完全对不上。
					// 另外要求 dt <= 10s：刚从长睡被唤醒时 dt 可能是几分钟，
					// 这一次算出来的是长周期均值，跳过不写，等下一秒的 1 秒窗口。
					if liveClients.Load() > 0 && dt <= 10 {
						rxBps := int64(float64(dRx) / dt)
						txBps := int64(float64(dTx) / dt)
						netSpeedMu.Lock()
						curNetSpeed = netSpeed{RxBps: rxBps, TxBps: txBps}
						netSpeedMu.Unlock()
					}
					// 流量累计：
					// 端口计数下 down（上游→本机）与 up（本机→客户端）是同一份数据的
					// 两端，相加即为重复计算。这里只上报 down 作为真实业务流量，
					// up 置 0，使 total = down 等于实际转发字节数。
					if dRx > 0 {
						select {
						case statChan <- statEvent{DownBytes: dRx, Bytes: dRx}:
						default:
						}
					}
				}
			}
			lastRx, lastTx, lastT = rx, tx, now

			// 有人看实时监控：1 秒一次，保证数字实时跳动。
			// 无人观看：5 分钟一次，省电省 IO，流量累计不丢（只是粒度变粗）。
			var nap time.Duration
			if liveClients.Load() > 0 {
				nap = time.Second
			} else {
				nap = 5 * time.Minute
			}
			if nap == time.Second {
				time.Sleep(nap)
				continue
			}
			// 长睡期间可被“有人打开监控”唤醒，醒来后立即补测一次
			timer := time.NewTimer(nap)
			select {
			case <-timer.C:
			case <-netSpeedWake:
				timer.Stop()
			}
		}
	}()
}

func getNetSpeed() netSpeed {
	netSpeedMu.RLock()
	defer netSpeedMu.RUnlock()
	return curNetSpeed
}

// ---------- 测速链接 ----------
// 后台生成一次性/限次测速链接：/speed/<token>，下载 N 次后自动失效。
// 令牌仅存内存（重启清空，属临时性质，无需落盘）。
type speedToken struct {
	Token   string
	MaxUses int
	Uses    atomic.Int64
	Created string
}

var speedTokens sync.Map // token -> *speedToken

// 测速链接有效期：创建 7 天后自动过期（惰性校验 + 定时清理）
const speedTokenValidity = 7 * 24 * time.Hour

func speedTokenExpired(st *speedToken) bool {
	t, err := time.Parse(time.RFC3339, st.Created)
	if err != nil {
		return false // 老数据解析失败则不过期，保持兼容
	}
	return time.Since(t) > speedTokenValidity
}

// startSpeedTokenCleaner 每小时清理一次已过期 7 天的测速链接
func startSpeedTokenCleaner() {
	go func() {
		for {
			time.Sleep(time.Hour)
			deleted := false
			speedTokens.Range(func(k, v any) bool {
				if speedTokenExpired(v.(*speedToken)) {
					speedTokens.Delete(k)
					deleted = true
				}
				return true
			})
			if deleted {
				saveSpeedTokens()
			}
		}
	}()
}

// ---------- 测速链接持久化（bolt 落盘，重启不丢失） ----------

// saveSpeedTokens 全量保存当前链接到 bolt（链接数量少，全量写开销可忽略）
func saveSpeedTokens() {
	type tokRec struct {
		Token   string `json:"token"`
		MaxUses int    `json:"max_uses"`
		Uses    int64  `json:"uses"`
		Created string `json:"created"`
	}
	var list []tokRec
	speedTokens.Range(func(_, v any) bool {
		st := v.(*speedToken)
		list = append(list, tokRec{st.Token, st.MaxUses, st.Uses.Load(), st.Created})
		return true
	})
	raw, _ := json.Marshal(list)
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("speed_tokens"))
		if err != nil {
			return err
		}
		return b.Put([]byte("data"), raw)
	})
}

// loadSpeedTokens 启动时从 bolt 恢复链接（含已用次数）
func loadSpeedTokens() {
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("speed_tokens"))
		if b == nil {
			return nil
		}
		raw := b.Get([]byte("data"))
		if raw == nil {
			return nil
		}
		var list []struct {
			Token   string `json:"token"`
			MaxUses int    `json:"max_uses"`
			Uses    int64  `json:"uses"`
			Created string `json:"created"`
		}
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil
		}
		for _, t := range list {
			st := &speedToken{Token: t.Token, MaxUses: t.MaxUses, Created: t.Created}
			st.Uses.Store(t.Uses)
			speedTokens.Store(t.Token, st)
		}
		return nil
	})
}

// ---------- 测速结果历史（bolt 落盘，最多保留 100 条） ----------
type speedResult struct {
	Time     string  `json:"time"`
	Token    string  `json:"token"`
	IP       string  `json:"ip"`
	PingMS   float64 `json:"ping_ms"`
	JitterMS float64 `json:"jitter_ms"`
	DownMbps float64 `json:"down_mbps"`
	UpMbps   float64 `json:"up_mbps"`
}

var (
	speedResults   []speedResult
	speedResultsMu sync.Mutex
)

const maxSpeedResults = 100

func loadSpeedResults() {
	speedResults = nil
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("speed_results"))
		if b == nil {
			return nil
		}
		var list []speedResult
		if raw := b.Get([]byte("data")); raw != nil {
			if err := json.Unmarshal(raw, &list); err == nil {
				speedResults = list
			}
		}
		return nil
	})
}

func appendSpeedResult(r speedResult) {
	speedResultsMu.Lock()
	speedResults = append(speedResults, r)
	if len(speedResults) > maxSpeedResults {
		speedResults = speedResults[len(speedResults)-maxSpeedResults:]
	}
	snap := make([]speedResult, len(speedResults))
	copy(snap, speedResults)
	speedResultsMu.Unlock()
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("speed_results"))
		if err != nil {
			return err
		}
		raw, _ := json.Marshal(snap)
		return b.Put([]byte("data"), raw)
	})
}

// serveSpeedTest 处理测速链接：
//   GET /speed/<token>       测速页面（占用一次使用次数）
//   GET /speed/<token>/dl    测速数据流（不计次数，仅页面会话内使用）
func serveSpeedTest(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/speed/")
	if rest == "" {
		serveError(w, http.StatusNotFound, "链接不存在", "测速链接无效或已失效。")
		return
	}
	// 数据流端点：/speed/<token>/dl
	if strings.HasSuffix(rest, "/dl") {
		tok := strings.TrimSuffix(rest, "/dl")
		// 允许“当前会话”：打开页面已消耗 1 次，Uses==MaxUses 时页面测速仍在进行，
		// 不能拒绝（否则限 1 次的链接打开页面后测速恒为 0）；仅当超出后才失效。
		if v, ok := speedTokens.Load(tok); !ok || v.(*speedToken).Uses.Load() > int64(v.(*speedToken).MaxUses) || speedTokenExpired(v.(*speedToken)) {
			http.Error(w, "链接已失效", http.StatusGone)
			return
		}
		sizeMB := int64(1024)
		if s := r.URL.Query().Get("size"); s != "" {
			if n, err := strconv.ParseInt(s, 10, 64); err == nil && n >= 1 && n <= 1024 {
				sizeMB = n
			}
		}
		total := sizeMB << 20
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		buf := make([]byte, 256<<10)
		for remain := total; remain > 0; {
			n := int64(len(buf))
			if remain < n {
				n = remain
			}
			if _, err := w.Write(buf[:n]); err != nil {
				return // 客户端停止读取（测速结束）即退出
			}
			remain -= n
		}
		return
	}

	// 上传测速端点：/speed/<token>/up（丢弃数据，仅统计字节数）
	if strings.HasSuffix(rest, "/up") {
		tok := strings.TrimSuffix(rest, "/up")
		if v, ok := speedTokens.Load(tok); !ok || v.(*speedToken).Uses.Load() > int64(v.(*speedToken).MaxUses) || speedTokenExpired(v.(*speedToken)) {
			http.Error(w, "链接已失效", http.StatusGone)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "方法不支持", http.StatusMethodNotAllowed)
			return
		}
		// 上限 512MB，防止滥用；边读边丢弃，不落盘不驻留
		body := http.MaxBytesReader(w, r.Body, 512<<20)
		buf := make([]byte, 64<<10)
		var n int64
		for {
			m, err := body.Read(buf)
			if m > 0 {
				n += int64(m)
				traffic.up.Add(int64(m)) // 计入端口上行流量
			}
			if err != nil {
				break
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"received": n})
		return
	}

	// 测速结果上报：/speed/<token>/report（页面测完自动上报）
	if strings.HasSuffix(rest, "/report") {
		tok := strings.TrimSuffix(rest, "/report")
		if v, ok := speedTokens.Load(tok); !ok || speedTokenExpired(v.(*speedToken)) {
			http.Error(w, "链接已失效", http.StatusGone)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "方法不支持", http.StatusMethodNotAllowed)
			return
		}
		var rep struct {
			Ping   float64 `json:"ping"`
			Jitter float64 `json:"jitter"`
			Down   float64 `json:"down"`
			Up     float64 `json:"up"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&rep); err != nil || rep.Down < 0 || rep.Down > 1e6 || rep.Up < 0 || rep.Up > 1e6 {
			http.Error(w, "数据格式有误", http.StatusBadRequest)
			return
		}
		appendSpeedResult(speedResult{
			Time: beijingRFC3339(nowBeijing()), Token: tok, IP: getClientIP(r),
			PingMS: rep.Ping, JitterMS: rep.Jitter, DownMbps: rep.Down, UpMbps: rep.Up,
		})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
		return
	}

	// 测速页面
	tok := rest
	if strings.Contains(tok, "/") {
		serveError(w, http.StatusNotFound, "链接不存在", "测速链接无效或已失效。")
		return
	}
	v, ok := speedTokens.Load(tok)
	if !ok {
		serveError(w, http.StatusNotFound, "链接不存在", "测速链接无效或已被删除。")
		return
	}
	st := v.(*speedToken)
	if speedTokenExpired(st) {
		serveError(w, http.StatusGone, "链接已过期", "该测速链接已超过 7 天有效期，请联系管理员重新生成。")
		return
	}
	if st.Uses.Load() >= int64(st.MaxUses) {
		serveError(w, http.StatusGone, "链接已失效", "该测速链接的可用次数已用完，请联系管理员重新生成。")
		return
	}
	st.Uses.Add(1)
	go saveSpeedTokens() // 异步落盘，不阻塞页面响应
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(strings.ReplaceAll(speedtestHTML, "__TOKEN__", tok)))
}

// speedtestHTML 测速页：输入令牌后渲染，自动完成延迟→下载测速，仪表盘样式。
const speedtestHTML = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>测速</title><style>
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--ok:#10b981;--r:16px}
body{min-height:100dvh;background:linear-gradient(180deg,#f0f7ff 0%,var(--bg) 60%);color:var(--t);font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:24px;padding:44px 40px;max-width:480px;width:100%;box-shadow:0 8px 40px -8px rgba(15,23,42,.10);text-align:center}
.gauge{position:relative;width:240px;height:240px;margin:0 auto}
.gauge svg{transform:rotate(-90deg)}
.gauge .track{stroke:#eef2f7}
.gauge .bar{stroke:var(--p);stroke-linecap:round;transition:stroke-dashoffset .25s ease,stroke .3s}
.gauge .txt{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}
.gauge .val{font-size:44px;font-weight:800;letter-spacing:-1px;font-variant-numeric:tabular-nums;line-height:1.05}
.gauge .unit{font-size:13px;color:var(--t3);margin-top:2px}
.phase{margin-top:22px;font-size:14px;font-weight:600;color:var(--t2);min-height:22px}
.sub{font-size:12.5px;color:var(--t3);margin-top:4px;min-height:18px}
.btn{margin-top:28px;display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:13px 34px;border-radius:12px;font-size:15px;font-weight:600;cursor:pointer;border:0;color:#fff;background:var(--p);box-shadow:0 4px 14px rgba(59,130,246,.35);transition:.2s;font-family:inherit}
.btn:hover{background:var(--pd)}
.btn:disabled{opacity:.5;cursor:default;box-shadow:none}
.foot{margin-top:26px;font-size:12px;color:var(--t3)}
.grade{display:inline-block;padding:3px 12px;border-radius:99px;font-size:12.5px;font-weight:600;margin-top:10px}
.g-g{background:#ecfdf5;color:var(--ok)}.g-m{background:#fffbeb;color:#d97706}.g-b{background:#fef2f2;color:#ef4444}
.done{margin-top:14px}
.dt{font-size:14px;font-weight:600;color:var(--t2)}
.dico{width:52px;height:52px;border-radius:50%;background:var(--ok);display:flex;align-items:center;justify-content:center;margin:0 auto 14px;box-shadow:0 6px 20px rgba(16,185,129,.35);animation:pop .45s cubic-bezier(.34,1.56,.64,1)}
@keyframes pop{0%{transform:scale(.3);opacity:0}100%{transform:scale(1);opacity:1}}
.srow{display:flex;justify-content:center;gap:56px;margin-top:18px}
.sc .sl{font-size:12.5px;font-weight:700;letter-spacing:.4px;color:var(--t2);display:flex;align-items:center;gap:6px;justify-content:center}
.sc .sl .u{font-weight:400;color:var(--t3)}
.sc .sv{font-size:42px;font-weight:700;letter-spacing:-1px;font-variant-numeric:tabular-nums;line-height:1.15;margin-top:4px}
.sc .sv.d{color:var(--pd)}.sc .sv.u{color:var(--ok)}
.smini{display:flex;justify-content:center;gap:28px;margin-top:14px;font-size:13px;color:var(--t3)}
.smini b{color:var(--t);font-weight:600;font-variant-numeric:tabular-nums}
.ic{display:inline-flex;width:16px;height:16px;border-radius:50%;align-items:center;justify-content:center;vertical-align:-3px;margin-right:4px}
.ic svg{width:9px;height:9px}
.ic-red{background:#fee2e2}.ic-red svg path{stroke:#ef4444}
.ic-green{background:#d1fae5}.ic-green svg path{stroke:#10b981}
</style></head><body><div class="card">
<div class="gauge" id="gauge">
<svg width="240" height="240" viewBox="0 0 240 240">
<circle class="track" cx="120" cy="120" r="104" fill="none" stroke-width="14"/>
<circle class="bar" id="gbar" cx="120" cy="120" r="104" fill="none" stroke-width="14" stroke-dasharray="653.4" stroke-dashoffset="653.4"/>
</svg>
<div class="txt"><div class="val" id="gval">--</div><div class="unit" id="gunit">Mbps</div></div>
</div>
<div class="phase" id="phase">准备就绪</div>
<div class="sub" id="sub"></div>
<div class="done" id="done" style="display:none">
<div class="dico"><svg width="26" height="26" viewBox="0 0 24 24" fill="none"><path d="M4 12.5l5 5L20 6.5" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg></div>
<div class="dt">测速完成 · 结果已记录 <span class="grade" id="dGrade" style="margin-top:0"></span></div>
<div class="srow">
<div class="sc"><div class="sl"><span class="ic ic-red"><svg viewBox="0 0 10 10" fill="none"><path d="M5 1v6M2.5 4.5L5 7l2.5-2.5" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>DOWNLOAD <span class="u">Mbps</span></div><div class="sv d" id="sDown">-</div></div>
<div class="sc"><div class="sl"><span class="ic ic-green"><svg viewBox="0 0 10 10" fill="none"><path d="M5 9V3M2.5 5.5L5 3l2.5 2.5" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>UPLOAD <span class="u">Mbps</span></div><div class="sv u" id="sUp">-</div></div>
</div>
<div class="smini"><span><span class="ic ic-red"><svg viewBox="0 0 10 10" fill="none"><path d="M5 1v6M2.5 4.5L5 7l2.5-2.5" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>Ping <b id="sPing">-</b> ms</span><span><span class="ic ic-green"><svg viewBox="0 0 10 10" fill="none"><path d="M2 5h6M5 2v6" stroke-width="1.4" stroke-linecap="round"/></svg></span>抖动 <b id="sJit">-</b> ms</span></div>
</div>
<button class="btn" id="go">开始测速</button>
<div class="foot">本页占用 1 次测速次数 · 结果仅供参考</div>
</div>
<script>
const TOKEN='__TOKEN__', DL='/speed/'+TOKEN+'/dl';
const CIRC=653.4, MAX_DISPLAY=1000; // 仪表满刻度 Mbps
const $=id=>document.getElementById(id);
let running=false;
function setGauge(mbps){
  const pct=Math.min(1,mbps/MAX_DISPLAY);
  $('gbar').style.strokeDashoffset=CIRC*(1-pct*0.75); // 最大到 3/4 圈更有冲刺感
  $('gval').textContent=mbps>=100?Math.round(mbps):mbps.toFixed(1);
}
function grade(m){return m>=200?['g-g','极佳']:m>=50?['g-g','良好']:m>=20?['g-m','一般']:['g-b','较差']}
async function pingTest(){
  const times=[];
  for(let i=0;i<4;i++){
    const t0=performance.now();
    await fetch(DL+'?size=1',{cache:'no-store'});
    times.push(performance.now()-t0);
  }
  times.sort((a,b)=>a-b);
  return {ping:Math.round(times[0]), jit:Math.round(times[2]-times[0])};
}
async function downTest(seconds){
  const deadline=performance.now()+seconds*1000;
  let bytes=0, winBytes=0, winT0=performance.now(), live=0, peak=0, downErr=null;
  const pump=async(id)=>{
    while(performance.now()<deadline){
      try{
        const resp=await fetch(DL+'?size=1024&t='+Math.random(),{cache:'no-store'});
        if(!resp.ok) throw new Error('数据流 HTTP '+resp.status);
        const rd=resp.body.getReader();
        for(;;){
          const {done,value}=await rd.read();
          if(done)break;
          bytes+=value.byteLength; winBytes+=value.byteLength;
          const dt=performance.now()-winT0;
          if(dt>=500){
            live=winBytes*8/(dt/1000)/1e6;
            peak=Math.max(peak,live); setGauge(live);
            winBytes=0; winT0=performance.now();
          }
        }
      }catch(e){
        if(!downErr) downErr=e.message||'网络错误';
        break;
      }
    }
  };
  await pump(1); // 单线程测试
  if(bytes===0){
    const msg=downErr||'未收到数据';
    if(/410/.test(msg)) throw new Error('链接已失效，请重新生成测速链接');
    throw new Error(msg);
  }
  const secs=(performance.now()-(deadline-seconds*1000))/1000;
  return {mbps:bytes*8/secs/1e6, peak};
}

async function upTest(seconds){
  const t0=performance.now(), deadline=t0+seconds*1000;
  // 8MB 随机块：随机内容防止中间层压缩，预生成一次反复使用；
  // 用 XHR 的 upload.onprogress 逐块回报已发字节，仪表才能平滑跳动
  const chunk=new Uint8Array(8*1048576);
  for(let off=0;off<chunk.length;off+=65536){
    crypto.getRandomValues(chunk.subarray(off,Math.min(off+65536,chunk.length)));
  }
  let upErr=null, done=false, total=0;
  const send=()=>{
    return new Promise((res)=>{
      const xhr=new XMLHttpRequest();
      xhr._last=0;
      xhr.open('POST','/speed/'+TOKEN+'/up');
      xhr.setRequestHeader('Content-Type','application/octet-stream');
      xhr.upload.onprogress=e=>{ total+=e.loaded-xhr._last; xhr._last=e.loaded; };
      const fin=()=>{ xhr._last=0; res(); };
      xhr.onload=fin; xhr.onerror=fin; xhr.ontimeout=fin; xhr.onabort=fin;
      xhr.send(chunk);
    });
  };
  const worker=async()=>{
    while(!done && !upErr && performance.now()<deadline){
      try{ await send(); }catch(e){ if(!upErr)upErr=e.message||'网络错误'; }
    }
  };
  const meter=setInterval(()=>{
    const el=(performance.now()-t0)/1000;
    if(el>0) setGauge(total*8/el/1e6);
  },250);
  await worker(); // 单线程测试
  done=true; clearInterval(meter);
  const secs=(performance.now()-t0)/1000;
  if(total===0){
    const msg=upErr||'未发出数据';
    if(/410/.test(msg)) throw new Error('链接已失效，请重新生成测速链接');
    throw new Error(msg);
  }
  return {mbps:total*8/secs/1e6};
}
$('go').addEventListener('click',async()=>{
  if(running)return; running=true;
  $('go').disabled=true; $('done').style.display='none';
  $('gauge').style.display=''; $('phase').style.display=''; $('sub').style.display='';
  $('gbar').style.stroke='var(--p)';
  try{
    $('phase').textContent='正在测延迟…'; $('sub').textContent=''; setGauge(0);
    const {ping,jit}=await pingTest();
    $('phase').textContent='正在测下载…'; $('sub').textContent='单线程下载测试，约 10 秒';
    const t0=performance.now();
    const timer=setInterval(()=>{
      const el=(performance.now()-t0)/1000;
      $('sub').textContent='已进行 '+Math.min(10,el).toFixed(0)+' 秒 / 10 秒';
    },250);
    const {mbps}=await downTest(10);
    clearInterval(timer);
    setGauge(mbps);
    $('phase').textContent='正在测上传…'; $('sub').textContent='单线程上传测试，约 8 秒';
    const {mbps:upMbps}=await upTest(8);
    const [gc,gt]=grade(mbps);
    $('gbar').style.stroke=gc==='g-g'?'var(--ok)':gc==='g-m'?'#f59e0b':'var(--d)';
    $('phase').innerHTML='测速完成 <span class="grade '+gc+'">'+gt+'</span>';
    $('sub').textContent='';
    try{ await fetch('/speed/'+TOKEN+'/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ping:ping,jitter:jit,down:mbps,up:upMbps})}); }catch(e){}
    // 完成态：隐藏仪表（避免误读为实时速率），按 Speedtest 风格展示结果
    $('gauge').style.display='none'; $('phase').style.display='none'; $('sub').style.display='none';
    $('dGrade').className='grade '+gc; $('dGrade').textContent=gt;
    const fmt=v=>v>=100?Math.round(v).toString():v.toFixed(2);
    $('sDown').textContent=fmt(mbps); $('sUp').textContent=fmt(upMbps);
    $('sPing').textContent=Math.round(ping); $('sJit').textContent=Math.round(jit);
    $('done').style.display='block';
  }catch(e){
    $('phase').textContent='测速失败'; $('sub').textContent=(e&&e.message)||'网络错误';
  }
  $('go').disabled=false; $('go').textContent='再测一次'; running=false;
});
</script></body></html>`

var wsUpgrader = websocket.Upgrader{
	// 后台实时监控是单向小包推送（服务端→浏览器，每秒一帧），
	// 默认 4KB 读缓冲对“只发不收”的场景属于纯浪费，调小到 1KB；
	// 写缓冲保持 4KB 以合并一帧内的多次小写入，避免逐条 syscall。
	ReadBufferSize:  1024,
	WriteBufferSize: 4096,
	// 不做 per-message 压缩：帧很小，压缩收益抵不过 CPU 开销
	EnableCompression: false,
	CheckOrigin: func(r *http.Request) bool {
		// 仅允许同源，降低 CSRF / 跨站连接风险
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true // 非浏览器客户端
		}
		u, err := url.Parse(origin)
		if err != nil {
			return false
		}
		return u.Host == r.Host
	},
}

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
	pruneTopN(stats.IPUpBytes, 1000)
	pruneTopN(stats.IPDownBytes, 1000)
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
		pruneTopN(day.IPUpBytes, 500)
		pruneTopN(day.IPDownBytes, 500)
		pruneTopN(day.Hosts, 300)
		pruneTopN(day.Countries, 200)
	}
	if len(stats.Audit) > maxAuditEvents {
		stats.Audit = stats.Audit[len(stats.Audit)-maxAuditEvents:]
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
				stats.TodayUpBytes = 0
				stats.TodayDownBytes = 0
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
			} else if ev.Bytes > 0 || ev.UpBytes > 0 || ev.DownBytes > 0 {
				up, down := ev.UpBytes, ev.DownBytes
				if up == 0 && down == 0 {
					// 兼容旧调用：只传合计
					down = ev.Bytes
				}
				total := up + down
				if total == 0 {
					total = ev.Bytes
				}
				stats.TotalBytes += total
				stats.TodayBytes += total
				stats.TotalUpBytes += up
				stats.TotalDownBytes += down
				stats.TodayUpBytes += up
				stats.TodayDownBytes += down
				d := dayOf(t)
				d.Bytes += total
				d.UpBytes += up
				d.DownBytes += down
				d.HourBytes[hour] += total
				d.HourUpBytes[hour] += up
				d.HourDownBytes[hour] += down
				if ev.IP != "" {
					stats.IPBytes[ev.IP] += total
					stats.IPUpBytes[ev.IP] += up
					stats.IPDownBytes[ev.IP] += down
					d.IPBytes[ev.IP] += total
					d.IPUpBytes[ev.IP] += up
					d.IPDownBytes[ev.IP] += down
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

// 磁盘分桶：stats_meta / stats_daily / stats_blocks（兼容旧版 stats/data 迁移）

type statsMetaDisk struct {
	SchemaVersion    int    `json:"schema_version"`
	TodayDate        string `json:"today_date"`
	TodayRequests    int64  `json:"today_requests"`
	TodayBytes       int64  `json:"today_bytes"`
	TodayUpBytes     int64  `json:"today_up_bytes"`
	TodayDownBytes   int64  `json:"today_down_bytes"`
	TotalRequests    int64  `json:"total_requests"`
	TotalBytes       int64  `json:"total_bytes"`
	TotalUpBytes     int64  `json:"total_up_bytes"`
	TotalDownBytes   int64  `json:"total_down_bytes"`
	BlockedCN        int64  `json:"blocked_cn"`
	BlockedWhitelist int64  `json:"blocked_whitelist"`
	BlockedBan       int64  `json:"blocked_ban"`
	BlockedRate      int64  `json:"blocked_rate"`
	BlockedUA        int64  `json:"blocked_ua"`
	LastProxyAt      string `json:"last_proxy_at"`
}

func emptyStats() Stats {
	return Stats{
		SchemaVersion: 2,
		TodayDate:     beijingDate(time.Now()),
		CountryCounts: map[string]int64{},
		IPCounts:      map[string]int64{},
		IPBytes:       map[string]int64{},
		IPUpBytes:     map[string]int64{},
		IPDownBytes:   map[string]int64{},
		Daily:         map[string]*DayStat{},
		Blocks:        []BlockEvent{},
		Audit:         []AuditEvent{},
	}
}

func rebuildAggregatesFromDaily() {
	stats.CountryCounts = map[string]int64{}
	stats.IPCounts = map[string]int64{}
	stats.IPBytes = map[string]int64{}
	stats.IPUpBytes = map[string]int64{}
	stats.IPDownBytes = map[string]int64{}
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
		for k, v := range d.IPUpBytes {
			stats.IPUpBytes[k] += v
		}
		for k, v := range d.IPDownBytes {
			stats.IPDownBytes[k] += v
		}
	}
	pruneTopN(stats.IPCounts, 1000)
	pruneTopN(stats.IPBytes, 1000)
	pruneTopN(stats.IPUpBytes, 1000)
	pruneTopN(stats.IPDownBytes, 1000)
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
					stats.SchemaVersion = m.SchemaVersion
					stats.TodayDate = m.TodayDate
					stats.TodayRequests = m.TodayRequests
					stats.TodayBytes = m.TodayBytes
					stats.TodayUpBytes = m.TodayUpBytes
					stats.TodayDownBytes = m.TodayDownBytes
					stats.TotalRequests = m.TotalRequests
					stats.TotalBytes = m.TotalBytes
					stats.TotalUpBytes = m.TotalUpBytes
					stats.TotalDownBytes = m.TotalDownBytes
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
	if stats.IPUpBytes == nil {
		stats.IPUpBytes = map[string]int64{}
	}
	if stats.IPDownBytes == nil {
		stats.IPDownBytes = map[string]int64{}
	}
	if stats.Daily == nil {
		stats.Daily = map[string]*DayStat{}
	}
	if stats.Blocks == nil {
		stats.Blocks = []BlockEvent{}
	}
	if stats.Audit == nil {
		stats.Audit = []AuditEvent{}
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
	// 旧数据无 schema_version：标记为 1（旧口径），保留但不与新数据混算语义
	if stats.SchemaVersion == 0 {
		stats.SchemaVersion = 1
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
		SchemaVersion:    stats.SchemaVersion,
		TodayDate:        stats.TodayDate,
		TodayRequests:    stats.TodayRequests,
		TodayBytes:       stats.TodayBytes,
		TodayUpBytes:     stats.TodayUpBytes,
		TodayDownBytes:   stats.TodayDownBytes,
		TotalRequests:    stats.TotalRequests,
		TotalBytes:       stats.TotalBytes,
		TotalUpBytes:     stats.TotalUpBytes,
		TotalDownBytes:   stats.TotalDownBytes,
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
			geoPrune()
		}
	}()
}

// getClientIP 取客户端 IP。
//
// 安全模型：
//  1. 直连方（RemoteAddr）不是 loopback/私网时，它是唯一可信来源，直接返回，
//     完全忽略请求头——否则任何公网客户端都能靠伪造 XFF 冒充任意 IP。
//  2. 直连方是 loopback/私网时，说明前面有反代（Nginx/宝塔/1Panel 等）。
//     此时 X-Forwarded-For 形如 "客户端, 代理1, 代理2"，**左侧内容可被客户端完全伪造**，
//     必须从右往左逐跳回溯：跳过所有可信（私网/loopback）代理，取第一个不可信地址。
//     例：真实客户端 1.2.3.4 经 Nginx 转发并伪造 XFF，到达时头为 "9.9.9.9, 1.2.3.4"
//     —— 左侧 9.9.9.9 是伪造值，从右往左第一个不可信地址才是 1.2.3.4。
//  3. 全部为可信地址（如健康检查、本机管理）时，回退到 X-Real-IP（由反代 302 覆盖写入，
//     客户端无法伪造），最后回退到直连地址。
func getClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(host)
	// 直连方不可信（公网直连）：不采信任何转发头
	if peer == nil || !isTrustedProxy(peer) {
		return host
	}

	// 有反代：从右往左找第一个不可信地址
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			s := strings.TrimSpace(parts[i])
			if s == "" {
				continue
			}
			p := net.ParseIP(s)
			if p == nil {
				// 非法值：不再向左回溯（左侧更不可信），直接中断
				break
			}
			if !isTrustedProxy(p) {
				return s
			}
		}
	}

	// 兜底：X-Real-IP 由反代写入（proxy_set_header 会覆盖客户端原值）
	if xri := strings.TrimSpace(r.Header.Get("X-Real-IP")); xri != "" {
		if p := net.ParseIP(xri); p != nil && !isTrustedProxy(p) {
			return xri
		}
	}
	return host
}

// isTrustedProxy 判断地址是否属于可信反代（loopback / 私网 / 链路本地）。
// 说明：这里用「地址段」而非「精确 IP 列表」，覆盖同机、Docker 网桥、
// 内网反代集群等常见拓扑；代价是内网内任意主机都被视为可信，
// 因此 VPS 必须禁止外部直接访问内网网段（云厂商默认已隔离）。
func isTrustedProxy(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
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

// countryCodeByName 由国家中文名反查两位国家码（ip9 等接口偶尔只给名字不给码）。
// 首次调用时构建反向表，之后只读。
var (
	countryCodeOnce sync.Once
	countryCodeRev  map[string]string
)

// countryCodeByEnglishName 常见英文国名 → 两位国家码（ip-api 兜底时只给英文名）
var countryCodeByEnglishName = map[string]string{
	"China": "CN", "United States": "US", "United States of America": "US",
	"Japan": "JP", "South Korea": "KR", "Korea": "KR", "North Korea": "KP",
	"Hong Kong": "HK", "Macao": "MO", "Macau": "MO", "Taiwan": "TW",
	"Singapore": "SG", "Malaysia": "MY", "Thailand": "TH", "Vietnam": "VN",
	"Philippines": "PH", "Indonesia": "ID", "India": "IN", "Pakistan": "PK",
	"Australia": "AU", "New Zealand": "NZ", "Canada": "CA", "Mexico": "MX",
	"Brazil": "BR", "Argentina": "AR", "Chile": "CL", "Peru": "PE",
	"United Kingdom": "GB", "UK": "GB", "Germany": "DE", "France": "FR",
	"Italy": "IT", "Spain": "ES", "Portugal": "PT", "Netherlands": "NL",
	"Belgium": "BE", "Switzerland": "CH", "Austria": "AT", "Sweden": "SE",
	"Norway": "NO", "Denmark": "DK", "Finland": "FI", "Ireland": "IE",
	"Poland": "PL", "Czechia": "CZ", "Czech Republic": "CZ", "Hungary": "HU",
	"Romania": "RO", "Bulgaria": "BG", "Greece": "GR", "Turkey": "TR",
	"Russia": "RU", "Ukraine": "UA", "Belarus": "BY", "Kazakhstan": "KZ",
	"Israel": "IL", "Saudi Arabia": "SA", "United Arab Emirates": "AE",
	"Qatar": "QA", "Kuwait": "KW", "Iran": "IR", "Iraq": "IQ",
	"Egypt": "EG", "South Africa": "ZA", "Nigeria": "NG", "Kenya": "KE",
	"Morocco": "MA", "Algeria": "DZ", "Tunisia": "TN", "Ethiopia": "ET",
}

func countryCodeByName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	countryCodeOnce.Do(func() {
		countryCodeRev = make(map[string]string, len(countryNames))
		for code, n := range countryNames {
			if n == "" || n == "未知" {
				continue
			}
			if _, dup := countryCodeRev[n]; !dup {
				countryCodeRev[n] = code
			}
		}
	})
	if c, ok := countryCodeRev[name]; ok {
		return c
	}
	if c, ok := countryCodeByEnglishName[name]; ok {
		return c
	}
	return ""
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
	case "login_fail":
		// 登录失败单独记入拦截列表，不计入白名单类计数
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
	case "login_fail":
		return "管理后台登录失败（用户名/密码或验证码错误）"
	default:
		return "目标域名未在白名单中"
	}
}

const maxBlockEvents = 5000
const maxAuditEvents = 1000

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
	geoMu    sync.RWMutex
	geoMap   = map[string]geoEntry{} // 纯内存，进程退出即丢弃，不落盘
	geoGroup singleflight.Group
)

// geoPrune：清理过期与超量 geo 缓存（纯内存，不涉及磁盘）
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
// geoParseGeneric 把上游 JSON 归一化成 geoEntry。
//   · 主接口 ip9.com.cn：{ret:200, data:{country, country_code, prov, city, isp, ...}}
//   · 兜底 ip-api.com：{status:"success", country, countryCode, regionName, city, isp, org, as}
// 两种结构字段名不同（country_code vs countryCode、prov vs regionName），这里统一兼容。
func geoParseGeneric(m map[string]any) (geoEntry, error) {
	// ip9 把业务数据放在 data 里；ip-api 是平铺结构
	if data, ok := m["data"].(map[string]any); ok {
		m = data
	}
	// ip9 的失败标记：ret != 200
	if ret, ok := m["ret"]; ok {
		if n, ok2 := toFloat(ret); ok2 && int(n) != 200 {
			msg, _ := m["msg"].(string)
			if msg == "" {
				msg, _ = m["message"].(string)
			}
			return geoEntry{}, fmt.Errorf("ip9 failed: %d %s", int(n), msg)
		}
	}
	// ip-api 的失败标记：status == fail
	if st, ok := m["status"].(string); ok && (st == "fail" || st == "error") {
		msg, _ := m["message"].(string)
		return geoEntry{}, fmt.Errorf("ip-api failed: %s", msg)
	}

	str := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
				return strings.TrimSpace(v)
			}
		}
		return ""
	}

	raw := str("country") // 国家名（ip9 为中文，ip-api 为英文）
	code := strings.ToUpper(str("countryCode", "country_code"))
	if len(code) > 2 {
		// 某些接口把国家名塞进国家码字段，长度异常则直接丢弃（下方会用国家名反查）
		code = ""
	}
	region := str("regionName", "prov", "region", "big_area")
	city := str("city")
	isp := str("isp")
	org := str("org", "isp")
	asn := str("as", "asn")

	if code == "" && raw == "" {
		return geoEntry{}, fmt.Errorf("no code")
	}
	if code == "" {
		// 只有国家名时反查国家码，失败则标记为未知
		code = countryCodeByName(raw)
		if code == "" {
			code = "??"
		}
	}
	// 统一成中文国家名：ip-api 只给英文（China / United States），ip9 给中文。
	// isASCII 判断：只要原始名是纯 ASCII，就用国家码换成中文名。
	if zh := countryName(code); code != "??" && zh != code && (raw == "" || isASCIIName(raw)) {
		raw = zh
	}
	if raw == "" {
		raw = countryName(code)
	}
	return geoEntry{Code: code, Name: raw, Region: region, City: city, ISP: isp, Org: org, AS: asn, At: time.Now().Unix()}, nil
}

// isASCIIName 判断国家名是否为纯 ASCII（即英文名，需要转中文）
func isASCIIName(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// toFloat 把任意 JSON 数字（float64 / int / json.Number）转成 float64
func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	}
	return 0, false
}

// geoEndpoints 返回按优先级排列的查询地址：ip9 优先，失效再由 ip-api.com 兜底
func geoEndpoints(ipEscaped string) []string {
	return []string{
		"https://ip9.com.cn/get?ip=" + ipEscaped,
		"http://ip-api.com/json/" + ipEscaped + "?fields=status,message,country,regionName,city,isp,as,org",
	}
}

func geoFetch(ipStr string) (geoEntry, error) {
	return geoFetchVia(geoEndpoints(url.QueryEscape(ipStr)), ipStr)
}

// 共享 Geo Client，复用连接
var geoClient = &http.Client{Timeout: 6 * time.Second}

// geoFetchVia 按给定地址顺序逐个尝试，任一成功即返回（便于测试与自定义顺序）
func geoFetchVia(urls []string, ipStr string) (geoEntry, error) {
	var last error
	for _, u := range urls {
		resp, err := geoClient.Get(u)
		if err != nil {
			last = err
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			last = fmt.Errorf("%s: HTTP %d", u, resp.StatusCode)
			continue
		}
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			last = err
			continue
		}
		if e, err := geoParseGeneric(m); err == nil {
			return e, nil
		} else {
			last = err
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

var (
	adminCredPtr atomic.Pointer[adminCred]
)

type adminCred struct {
	User     string
	PassHash string // bcrypt hash；兼容迁移期可能短暂存明文再被覆盖
}

func setAdminCred(u, hash string) { adminCredPtr.Store(&adminCred{User: u, PassHash: hash}) }
func getAdminUser() string {
	c := adminCredPtr.Load()
	if c == nil {
		return "admin"
	}
	return c.User
}
func getAdminHash() string {
	c := adminCredPtr.Load()
	if c == nil {
		return ""
	}
	return c.PassHash
}

func hashPassword(plain string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func verifyPassword(hash, plain string) bool {
	if hash == "" || plain == "" {
		return false
	}
	// 兼容旧版明文：若不是 bcrypt 格式则做常量时间比较并提示升级
	if !strings.HasPrefix(hash, "$2a$") && !strings.HasPrefix(hash, "$2b$") && !strings.HasPrefix(hash, "$2y$") {
		return subtle.ConstantTimeCompare([]byte(hash), []byte(plain)) == 1
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}

func isBcryptHash(s string) bool {
	return strings.HasPrefix(s, "$2a$") || strings.HasPrefix(s, "$2b$") || strings.HasPrefix(s, "$2y$")
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
	now := time.Now()
	if now.After(e.Expires) {
		sessions.Delete(tok)
		return false
	}
	// 滑动续期：剩余不足一半 TTL 时自动延长
	if e.Expires.Sub(now) < sessionTTL/2 {
		sessions.Store(tok, sessionEntry{Expires: now.Add(sessionTTL)})
	}
	return true
}

// destroyOtherSessions 踢出除当前外的所有会话
func destroyOtherSessions(keep string) {
	sessions.Range(func(k, _ interface{}) bool {
		if ks, ok := k.(string); ok && ks != keep {
			sessions.Delete(ks)
		}
		return true
	})
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
func requestIsHTTPS(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	if strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		return true
	}
	return false
}

func setSessionCookie(w http.ResponseWriter, r *http.Request, tok string) {
	c := &http.Cookie{
		Name: sessionCookie, Value: tok, Path: "/admin",
		HttpOnly: true, SameSite: http.SameSiteLaxMode,
		MaxAge: int(sessionTTL.Seconds()),
	}
	if requestIsHTTPS(r) {
		c.Secure = true
	}
	http.SetCookie(w, c)
}
func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/admin", HttpOnly: true, MaxAge: -1})
}

// generateCaptchaSVG 生成 5 位干扰验证码 SVG（更多噪声点与干扰线），答案存 captchas map，TTL 5 分钟。
func generateCaptchaSVG() (id, answer, svg string) {
	const digits = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	rb := make([]byte, 16)
	_, _ = io.ReadFull(rand.Reader, rb)
	ans := make([]byte, 5)
	for i := 0; i < 5; i++ {
		ans[i] = digits[int(rb[i])%len(digits)]
	}
	answer = string(ans)
	id = randToken(8)
	var lines, dots, texts strings.Builder
	// 干扰线
	for i := 0; i < 8; i++ {
		x1 := int(rb[i%16]) % 160
		y1 := int(rb[(i+1)%16]) % 52
		x2 := int(rb[(i+2)%16]) % 160
		y2 := int(rb[(i+3)%16]) % 52
		lines.WriteString(fmt.Sprintf(`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#94a3b8" stroke-width="1"/>`, x1, y1, x2, y2))
	}
	// 噪声点
	for i := 0; i < 40; i++ {
		x := int(rb[i%16]) % 170
		y := int(rb[(i+5)%16]) % 50
		dots.WriteString(fmt.Sprintf(`<circle cx="%d" cy="%d" r="1.2" fill="#cbd5e1"/>`, x, y))
	}
	colors := []string{"#1e40af", "#1d4ed8", "#2563eb", "#0f172a", "#1e3a8a"}
	for i, ch := range answer {
		x := 12 + i*28 + int(rb[i%16])%5
		y := 34 + int(rb[(i+1)%16])%6
		rot := int(rb[i%16])%30 - 15
		texts.WriteString(fmt.Sprintf(`<text x="%d" y="%d" fill="%s" font-size="26" font-family="Consolas,monospace" font-weight="700" transform="rotate(%d %d %d)">%c</text>`, x, y, colors[i%len(colors)], rot, x, y, ch))
	}
	svg = fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="170" height="52" viewBox="0 0 170 52"><rect width="170" height="52" fill="#f8fafc" rx="8"/>%s%s%s</svg>`, lines.String(), dots.String(), texts.String())
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
		// CSRF: 写操作要求自定义头（前端全局 fetch 已自动附加）
		if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions {
			if r.Header.Get("X-Emby-CSRF") != "1" && r.Header.Get("X-Requested-With") != "XMLHttpRequest" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"error":"缺少 CSRF 防护头"}`))
				return
			}
		}
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

func saveAdminPassHash(hash string) error {
	if db == nil {
		return fmt.Errorf("db not ready")
	}
	return db.Update(func(tx *bolt.Tx) error {
		bk, err := tx.CreateBucketIfNotExists([]byte("auth"))
		if err != nil {
			return err
		}
		// 清除旧明文键，只保留哈希
		_ = bk.Delete([]byte("admin_pass"))
		return bk.Put([]byte("admin_pass_hash"), []byte(hash))
	})
}

// recordAudit 写入管理操作审计（持锁或不持锁均可，内部自取锁）
func recordAudit(ip, action, detail string) {
	statsMu.Lock()
	defer statsMu.Unlock()
	ev := AuditEvent{Time: beijingRFC3339(time.Now()), IP: ip, Action: action, Detail: detail}
	stats.Audit = append(stats.Audit, ev)
	if len(stats.Audit) > maxAuditEvents {
		stats.Audit = stats.Audit[len(stats.Audit)-maxAuditEvents:]
	}
}

// loginFail 登录失败拦截：短窗口计数 + 逐步加长锁定 + 多次锁定后自动拉黑
type loginFailEntry struct {
	Count    atomic.Int64
	Window   atomic.Int64 // UnixNano，计数窗口起点
	Locked   atomic.Int64 // 锁定截止 UnixNano
	Lockouts atomic.Int64 // 累计被锁定次数（用于自动拉黑）
}

var loginFailers sync.Map // ip -> *loginFailEntry

const (
	loginFailLimit    = 5                // 窗口内失败次数上限
	loginFailWindow   = 10 * time.Minute // 计数窗口
	loginLockBase     = 15 * time.Minute // 首次锁定时长
	loginLockMax      = 2 * time.Hour    // 锁定上限
	captchaRateLimit  = 30               // 每分钟每 IP 验证码请求上限
)

func loginLockDuration(lockouts int64) time.Duration {
	// 15m → 30m → 60m → 120m（封顶）
	d := loginLockBase
	for i := int64(1); i < lockouts && d < loginLockMax; i++ {
		d *= 2
		if d > loginLockMax {
			d = loginLockMax
		}
	}
	return d
}

func checkLoginAllowed(ip string) (ok bool, retryAfterSec int) {
	now := time.Now().UnixNano()
	val, _ := loginFailers.LoadOrStore(ip, &loginFailEntry{})
	e := val.(*loginFailEntry)
	if until := e.Locked.Load(); until > now {
		return false, int((until-now)/int64(time.Second)) + 1
	}
	return true, 0
}

// recordLoginFail 记录一次失败；返回 (已锁定, 还需等待秒数, 本窗失败次数)
func recordLoginFail(ip, reason string) (locked bool, retryAfterSec int, fails int64) {
	now := time.Now().UnixNano()
	val, _ := loginFailers.LoadOrStore(ip, &loginFailEntry{})
	e := val.(*loginFailEntry)
	start := e.Window.Load()
	if start == 0 || now-start > int64(loginFailWindow) {
		if e.Window.CompareAndSwap(start, now) {
			e.Count.Store(1)
			fails = 1
		} else {
			fails = e.Count.Add(1)
		}
	} else {
		fails = e.Count.Add(1)
	}

	// 写入拦截记录 + 审计，便于在后台查看暴力尝试
	ua := ""
	recordBlocked(ip, countryOf(ip), "/admin/api/login", "login_fail", ua)
	recordAudit(ip, "login_fail", reason)

	if fails >= loginFailLimit {
		lockouts := e.Lockouts.Add(1)
		dur := loginLockDuration(lockouts)
		e.Locked.Store(now + int64(dur))
		e.Count.Store(0)
		e.Window.Store(now)
		locked = true
		retryAfterSec = int(dur / time.Second)
		recordAudit(ip, "login_lock", fmt.Sprintf("失败 %d 次，锁定 %s（第 %d 次锁定）", loginFailLimit, dur, lockouts))
		return locked, retryAfterSec, fails
	}
	return false, 0, fails
}

func clearLoginFail(ip string) {
	loginFailers.Delete(ip)
}

// captcha 接口限流，防止刷验证码
type captchaRateEntry struct {
	Count       atomic.Int64
	WindowStart atomic.Int64
}

var captchaLimiters sync.Map

func checkCaptchaRate(ip string) bool {
	val, _ := captchaLimiters.LoadOrStore(ip, &captchaRateEntry{})
	e := val.(*captchaRateEntry)
	now := time.Now().UnixNano()
	start := e.WindowStart.Load()
	if start == 0 || now-start > int64(time.Minute) {
		if e.WindowStart.CompareAndSwap(start, now) {
			e.Count.Store(1)
			return true
		}
	}
	return e.Count.Add(1) <= captchaRateLimit
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

// buildProxy 构造反向代理（纯透传）：
//   Rewrite        把路径中的目标写到 Out.URL
//   ModifyResponse 只改写 Location / Set-Cookie Domain，不包装响应体
//   ErrorHandler   上游失败时返回统一错误页
func buildProxy(tr *switchTransport) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		// FlushInterval = 0：不做定时强制 flush，由底层 bufio 写满自然下发。
		// 这样下游读取慢时写操作会阻塞，形成真实背压，上游随之被按住；
		// 而流式响应（ContentLength == -1，媒体流/SSE）标准库会自动用 -1 立即 flush，
		// 播放不会因为该设置变卡。
		Transport: tr, FlushInterval: 0, BufferPool: proxyBufPool,
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
			// 转发头必须由本机重写，不能沿用 pr.SetXForwarded()：
			// 它会把 Out 上已存在的（客户端伪造的）X-Forwarded-For 原样拼在前面，
			// 使伪造链路直达上游。这里先清空，再用已校验的客户端 IP 重新写入。
			outIP := getClientIP(pr.In)
			pr.Out.Header.Del("X-Forwarded-For")
			pr.Out.Header.Del("X-Real-IP")
			pr.Out.Header.Del("Forwarded")
			pr.Out.Header.Set("X-Forwarded-For", outIP)
			pr.Out.Header.Set("X-Real-IP", outIP)
			if pr.In.TLS == nil {
				pr.Out.Header.Set("X-Forwarded-Proto", "http")
			} else {
				pr.Out.Header.Set("X-Forwarded-Proto", "https")
			}
			rewriteOriginHeaders(pr.Out, t.Scheme, t.Host)
			// 请求体不做上下行统计（客户端上传量不属于上下行定义）
		},
		ModifyResponse: func(resp *http.Response) error {
			// 响应体包一层计数 Reader：仅统计真正经过本服务的下行字节。
			// 不改变传输语义（纯流式透传，不缓冲、不预读）。
			if resp.Body != nil {
				resp.Body = struct {
					io.Reader
					io.Closer
				}{&countingReader{r: resp.Body}, resp.Body}
			}
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
			serveError(w, http.StatusBadGateway, "请求失败", "暂时无法完成请求，请稍后重试。")
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

// pwaHeadExtra 返回注入到 <head> 的图标/PWA 标签。
// PWA 已固化为常开（不再提供后台开关），因此这里恒定输出完整标签。
func pwaHeadExtra() string {
	return "<link rel=\"icon\" href=\"/favicon.ico" + iconVer + "\">\n" +
		"<link rel=\"apple-touch-icon\" href=\"/admin/icon-192.png" + iconVer + "\">\n" +
		"<link rel=\"manifest\" href=\"/admin/manifest.webmanifest\">\n" +
		"<meta name=\"theme-color\" content=\"#3b82f6\">\n" +
		"<meta name=\"mobile-web-app-capable\" content=\"yes\">\n" +
		"<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n" +
		"<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n" +
		"<meta name=\"apple-mobile-web-app-title\" content=\"Emby Proxy\">\n"
}

// pwaBodyExtra 返回注入到 </body> 前的 SW 注册脚本（PWA 常开，始终注入）。
func pwaBodyExtra() string {
	return "<script>if('serviceWorker' in navigator){window.addEventListener('load',function(){navigator.serviceWorker.register('/admin/sw.js').catch(function(){})})}</script>"
}

// pwaManifestJSON 生成 Web App Manifest（start_url 指向秒开的静态启动页）。
func pwaManifestJSON() []byte {
	m := map[string]any{
		"name":             "Emby Proxy 管理后台",
		"short_name":       "Emby Proxy",
		"description":      "Emby 路径反代 v2.2.0管理控制台",
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
// 渲染后直接探测登录态并跳转（不做任何预缓存/预热）。
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
 * 1. 页面本身零外链依赖，立即渲染；
 * 2. 直接探测登录态（不做任何缓存/预热）：
 *    已登录 → /admin/，未登录 → /admin/login。
 * 3. 最短展示 400ms，避免闪烁；跳转用 replace，避免后退键回到启动页。 */
(function () {
  var t0 = Date.now();
  var tip = document.getElementById('tip');
  var wait = Math.max(0, 400 - (Date.now() - t0));
  setTimeout(function () {
    // 探测登录态：config 需要会话，401/302 → 登录页
    fetch('/admin/api/config', { cache: 'no-store' }).then(function (r) {
      location.replace(r.ok ? '/admin/' : '/admin/login');
    }).catch(function () {
      location.replace('/admin/');
    });
  }, wait);
})();
</script>
</body>
</html>
`

// swSource 管理后台 Service Worker（仅保留 PWA 安装能力，不做任何缓存）：
//   · 不预缓存应用壳、不缓存导航请求、不缓存 CDN 脚本、不调用 caches API
//   · fetch 事件直接放行（浏览器默认行为），保证页面与数据永远是最新版本
//   · install 时立即激活并清理历史版本遗留的缓存（老版本 SW 缓存的旧页面）
const swSource = `self.addEventListener('install', function (e) {
  e.waitUntil(self.skipWaiting());
});
self.addEventListener('activate', function (e) {
  e.waitUntil((self.caches ? caches.keys().then(function (ks) {
    // 清掉任意遗留缓存（含本 SW 之前的各版本应用壳缓存）
    return Promise.all(ks.map(function (k) { return caches.delete(k); }));
  }) : Promise.resolve()).then(function () { return self.clients.claim(); }));
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
		// 处理器已自行输出压缩内容则直接透传，避免二次压缩
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

// ---------- 压缩输出 HTML ----------
// 不做任何进程内缓存：每次请求现场 gzip（仅管理后台几处低频页面，CPU 开销可忽略）。

// serveHTML 输出 HTML：客户端支持 gzip 时现场压缩后写出。
func serveHTML(w http.ResponseWriter, r *http.Request, html, contentType, cacheControl string) {
	w.Header().Set("Content-Type", contentType)
	if cacheControl != "" {
		w.Header().Set("Cache-Control", cacheControl)
	}
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		var buf bytes.Buffer
		gz := gzip.NewWriter(&buf)
		_, _ = gz.Write([]byte(html))
		_ = gz.Close()
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Vary", "Accept-Encoding")
		_, _ = w.Write(buf.Bytes())
		return
	}
	_, _ = w.Write([]byte(html))
}

// ---------- 系统信息辅助 ----------

// diskUsage 返回磁盘剩余/总量（仅 unix，用 syscall.Statfs；失败返回 0）
type diskSpace struct{ free, total uint64 }

func diskUsage(path string) (diskSpace, error) {
var st syscall.Statfs_t
if err := syscall.Statfs(path, &st); err != nil {
	return diskSpace{}, err
}
return diskSpace{
	free:  st.Bavail * uint64(st.Bsize),
	total: st.Blocks * uint64(st.Bsize),
}, nil
}

// appVersion 程序版本号（发版时改这里即可，后台「系统信息」会展示）
const appVersionStr = "2.2.0"

func appVersion() string { return appVersionStr }

// blockedAll 五种拦截之和（调用方需自行持有 statsMu 或接受轻微误差）
func blockedAll() int64 {
statsMu.Lock()
defer statsMu.Unlock()
return stats.BlockedCN + stats.BlockedWhitelist + stats.BlockedBan + stats.BlockedRate + stats.BlockedUA
}

// activeSessionCount 当前未过期的后台登录会话数
func activeSessionCount() int {
now := time.Now()
n := 0
sessions.Range(func(_, v interface{}) bool {
	if e, ok := v.(sessionEntry); ok && now.Before(e.Expires) {
		n++
	}
	return true
})
return n
}


// adminHandler 注册 /admin 下全部路由（登录页、API、静态后台页）。
func adminHandler() http.HandlerFunc {
	mux := http.NewServeMux()

	mux.HandleFunc("/admin/login", func(w http.ResponseWriter, r *http.Request) {
		if validSession(getSessionToken(r)) {
			http.Redirect(w, r, "/admin/", http.StatusFound)
			return
		}
		html := strings.Replace(string(loginHTML), "<head>", "<head>\n"+pwaHeadExtra(), 1)
		html = strings.Replace(html, "</body>", pwaBodyExtra()+"</body>", 1)
		serveHTML(w, r, html, "text/html; charset=utf-8", "no-store")
	})
	mux.HandleFunc("/admin/api/captcha", func(w http.ResponseWriter, r *http.Request) {
		ip := getClientIP(r)
		if !checkCaptchaRate(ip) {
			http.Error(w, "验证码请求过于频繁，请稍后再试", http.StatusTooManyRequests)
			return
		}
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
		clientIP := getClientIP(r)
		w.Header().Set("Content-Type", "application/json")
		// 已被代理黑名单拦截的 IP 直接拒绝登录
		if isBannedIP(clientIP, net.ParseIP(clientIP)) {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"您的 IP 已被加入黑名单，无法登录"}`))
			return
		}
		if ok, wait := checkLoginAllowed(clientIP); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(wait))
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(fmt.Sprintf(`{"error":"登录失败次数过多，已暂时锁定，请 %d 秒后再试"}`, wait)))
			return
		}
		var req struct {
			Username  string `json:"username"`
			Password  string `json:"password"`
			Captcha   string `json:"captcha"`
			CaptchaID string `json:"captcha_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"提交的数据格式有误，请刷新页面后重新登录"}`))
			return
		}
		failMsg := func(msg string, reason string) {
			locked, wait, fails := recordLoginFail(clientIP, reason)
			if locked {
				w.Header().Set("Retry-After", strconv.Itoa(wait))
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = w.Write([]byte(fmt.Sprintf(`{"error":"登录失败次数过多，已锁定 %d 秒。连续多次锁定将自动拉黑 IP"}`, wait)))
				return
			}
			remain := loginFailLimit - int(fails)
			if remain < 0 {
				remain = 0
			}
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(fmt.Sprintf(`{"error":"%s（还可尝试 %d 次）"}`, msg, remain)))
		}
		if !verifyCaptcha(req.CaptchaID, req.Captcha) {
			failMsg("验证码不正确或已过期，点击图片可刷新后重试", "captcha")
			return
		}
		u := getAdminUser()
		hash := getAdminHash()
		userOK := subtle.ConstantTimeCompare([]byte(req.Username), []byte(u)) == 1
		passOK := verifyPassword(hash, req.Password)
		if !userOK || !passOK {
			failMsg("用户名或密码不正确，请注意大小写", "password")
			return
		}
		// 旧明文迁移：登录成功后升级为 bcrypt
		if hash != "" && !isBcryptHash(hash) {
			if nh, err := hashPassword(req.Password); err == nil {
				_ = saveAdminPassHash(nh)
				setAdminCred(u, nh)
			}
		}
		clearLoginFail(clientIP)
		tok := createSession()
		setSessionCookie(w, r, tok)
		recordAudit(clientIP, "login", "管理后台登录成功")
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
		oldCfg := currentCfg()
		newCfg := &req
		if err := saveConfig(newCfg); err != nil {
			http.Error(w, "配置保存失败，可能是磁盘写入异常，请稍后重试", http.StatusInternalServerError)
			return
		}
		cfgPtr.Store(newCfg)
		rebuildACL(newCfg)
		recordAudit(getClientIP(r), "save_config", "保存网关设置")
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
// /admin/api/system：概览「系统信息」卡片的运行态数据（全部来自本进程与 os，不依赖外部命令）
	mux.HandleFunc("/admin/api/system", func(w http.ResponseWriter, r *http.Request) {
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)

		// 构建信息：优先取 embed 的 buildinfo（Go 1.18+ 自动写入）
		goVer := runtime.Version()
		buildSum := ""
		if bi, ok := debug.ReadBuildInfo(); ok {
			if bi.GoVersion != "" {
				goVer = bi.GoVersion
			}
			for _, st := range bi.Settings {
				if st.Key == "vcs.revision" {
					buildSum = st.Value
				}
			}
		}
		if len(buildSum) > 8 {
			buildSum = buildSum[:8]
		}

		// 数据库文件大小与所在磁盘剩余空间
		var dbSize int64
		if fi, err := os.Stat(dbPath); err == nil {
			dbSize = fi.Size()
		}
		var diskFree, diskTotal uint64
		if du, err := diskUsage(filepath.Dir(dbPath)); err == nil {
			diskFree, diskTotal = du.free, du.total
		}

		// 独立 IP 数（快速估算，避免再复制全量 map）
		statsMu.Lock()
		uniqueIPs := len(stats.IPCounts)
		totalReqs := stats.TotalRequests
		totalBytes := stats.TotalBytes
		statsMu.Unlock()

		// 命中率：允许的请求 / 总请求
		allowRate := 0.0
		if totalReqs > 0 {
			allowRate = 100 * float64(totalReqs-blockedAll()) / float64(totalReqs)
			if allowRate < 0 {
				allowRate = 0
			}
		}

		c := currentCfg()
		resp := map[string]any{
			"version":        appVersion(),
			"go_version":     goVer,
			"build_rev":      buildSum,
			"os_arch":        runtime.GOOS + "/" + runtime.GOARCH,
			"num_cpu":        runtime.NumCPU(),
			"gomaxprocs":     runtime.GOMAXPROCS(0),
			"goroutines":     runtime.NumGoroutine(),
			"uptime_sec":     int64(time.Since(startedAt).Seconds()),
			"mem_alloc":      ms.Alloc,
			"mem_sys":        ms.Sys,
			"mem_heap":       ms.HeapAlloc,
			"mem_stack":      ms.StackInuse,
			"heap_objects":   ms.HeapObjects,
			"gc_count":       ms.NumGC,
			"gc_pause_last":  ms.PauseNs[(ms.NumGC+255)%256],
			"db_size":        dbSize,
			"disk_free":      diskFree,
			"disk_total":     diskTotal,
			"port":           currentPort(),
			"unique_ips":     uniqueIPs,
			"total_requests": totalReqs,
			"total_bytes":    totalBytes,
			"allow_rate":     allowRate,
			"whitelist":      len(c.Whitelist),
			"ban_list":       len(c.BanList),
			"rate_limit":     c.RateLimit,
			"china_only":     c.ChinaOnly,
			"auto_ban":       c.AutoBan,
			"allowed_uas":    len(c.AllowedUAs),
			"logins":         activeSessionCount(),
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})
	// /admin/api/realtime/ws：进入页面才开始收集，断开即清空；增量推送
	mux.HandleFunc("/admin/api/realtime/ws", func(w http.ResponseWriter, r *http.Request) {
		if !validSession(getSessionToken(r)) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		conn, err := wsUpgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		liveClients.Add(1)
		// 立即唤醒采样器：否则它会睡满 5 分钟空闲周期，页面长时间没有网速数据
		wakeNetSpeedSampler()
		defer func() {
			if liveClients.Add(-1) == 0 {
				clearLive()
			}
		}()
		var lastSeq int64
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		for {
			select {
			case <-tick.C:
				events, conc, rps := snapshotLive()
				ns := getNetSpeed()
				var delta []liveEvent
				for _, e := range events {
					if e.Seq > lastSeq {
						delta = append(delta, e)
					}
				}
				if len(delta) > 0 {
					lastSeq = delta[0].Seq // events 是 newest-first
				}
				msg := map[string]any{
					"concurrent": conc,
					"rps":        rps,
					"rx_bps":     ns.RxBps,
					"tx_bps":     ns.TxBps,
					"events":     delta,
				}
				conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if err := conn.WriteJSON(msg); err != nil {
					return
				}
			case <-r.Context().Done():
				return
			}
		}
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
			UpBytes   int64            `json:"up_bytes"`
			DownBytes int64            `json:"down_bytes"`
			Blocked   int64            `json:"blocked"`
			BlockedCN int64            `json:"blocked_cn"`
			BlockedWL int64            `json:"blocked_whitelist"`
			Hours         map[string]int64 `json:"hours,omitempty"`
			HourBytes     map[string]int64 `json:"hour_bytes,omitempty"`
			HourUpBytes   map[string]int64 `json:"hour_up_bytes,omitempty"`
			HourDownBytes map[string]int64 `json:"hour_down_bytes,omitempty"`
			Hosts         map[string]int64 `json:"hosts,omitempty"`
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
				// 轻量模式：只带每日汇总 + 分时汇总（概览「单日」视图按 0~23 点画图，
				// 缺了 hours/hour_*_bytes 就会退化成一条全 0 的直线）；IP/国家/主机明细仍跳过。
				trend = append(trend, TrendItem{
					Date: k, Requests: d.Requests, Bytes: d.Bytes, UpBytes: d.UpBytes, DownBytes: d.DownBytes,
					Blocked: d.BlockedCN + d.BlockedWL + d.BlockedBan + d.BlockedRate + d.BlockedUA,
					BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL,
					Hours:         hour24(d.Hours),
					HourBytes:     hour24(d.HourBytes),
					HourUpBytes:   hour24(d.HourUpBytes),
					HourDownBytes: hour24(d.HourDownBytes),
				})
				continue
			}
			ensureDayMaps(d)
			for hk, hv := range d.Hosts {
				hostAll[hk] += hv
			}
			hoursCopy := copyInt64Map(d.Hours)
			hourBytesCopy := copyInt64Map(d.HourBytes)
			hourUpCopy := copyInt64Map(d.HourUpBytes)
			hourDownCopy := copyInt64Map(d.HourDownBytes)
			hostsCopy := copyInt64Map(d.Hosts)
			ipsCopy := copyInt64Map(d.IPs)
			ctryCopy := copyInt64Map(d.Countries)
			pruneTopN(ipsCopy, 100)
			pruneTopN(ctryCopy, 50)
			pruneTopN(hostsCopy, 50)
		trend = append(trend, TrendItem{
			Date: k, Requests: d.Requests, Bytes: d.Bytes, UpBytes: d.UpBytes, DownBytes: d.DownBytes,
			Blocked: d.BlockedCN + d.BlockedWL + d.BlockedBan + d.BlockedRate + d.BlockedUA,
			BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL,
			Hours: hoursCopy, HourBytes: hourBytesCopy,
			HourUpBytes: hourUpCopy, HourDownBytes: hourDownCopy, Hosts: hostsCopy,
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
		totalUp, totalDown := stats.TotalUpBytes, stats.TotalDownBytes
		todayUp, todayDown := stats.TodayUpBytes, stats.TodayDownBytes
		cn, wl := stats.BlockedCN, stats.BlockedWhitelist
		ban, rate, ua := stats.BlockedBan, stats.BlockedRate, stats.BlockedUA
		schemaVersion := stats.SchemaVersion
		ipUp := copyInt64Map(stats.IPUpBytes)
		ipDown := copyInt64Map(stats.IPDownBytes)
		pruneTopN(hostAll, 50)
		statsMu.Unlock()

		resp := map[string]any{
			"schema_version": schemaVersion,
			"total_requests": reqs, "total_bytes": byts,
			"total_up_bytes": totalUp, "total_down_bytes": totalDown,
			"today_date": today, "requests": reqs, "bytes": byts,
			"blocked_cn": cn, "blocked_whitelist": wl,
			"blocked_ban": ban, "blocked_rate": rate, "blocked_ua": ua,
			"blocked_total": cn + wl + ban + rate + ua,
			"today_requests": todayReqs, "today_bytes": todayBytes,
			"today_up_bytes": todayUp, "today_down_bytes": todayDown,
			"trend": trend,
			"uptime_sec":   int64(time.Since(startedAt).Seconds()),
			"stat_dropped": statDropped.Load(),
		}
		if slim {
			resp["unique_ips"] = uniqueIPs
		} else {
			resp["ip_counts"] = ips
			resp["ip_bytes"] = ipBytes
			resp["ip_up_bytes"] = ipUp
			resp["ip_down_bytes"] = ipDown
			resp["country_counts"] = ctry
			resp["country_labels"] = labels
			resp["host_counts"] = hostAll
		}
		_ = json.NewEncoder(w).Encode(resp)
	})
	mux.HandleFunc("/admin/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		limit := 1000
		if s := r.URL.Query().Get("limit"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n >= 0 {
				limit = n
			}
		}
		qIP := strings.TrimSpace(r.URL.Query().Get("ip"))
		qReason := strings.TrimSpace(r.URL.Query().Get("reason"))
		qSearch := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		all := stats.Blocks
		matched := make([]BlockEvent, 0, len(all))
		for i := len(all) - 1; i >= 0; i-- {
			ev := all[i]
			if qIP != "" && ev.IP != qIP {
				continue
			}
			if qReason != "" && ev.Reason != qReason {
				continue
			}
			if qSearch != "" {
				blob := strings.ToLower(ev.IP + " " + ev.Path + " " + ev.UA + " " + ev.ReasonText + " " + ev.Country)
				if !strings.Contains(blob, qSearch) {
					continue
				}
			}
			matched = append(matched, ev)
		}
		total := len(matched)
		n := total
		if limit > 0 && n > limit {
			n = limit
		}
		items := make([]map[string]any, n)
		for i := 0; i < n; i++ {
			ev := matched[i]
			items[i] = map[string]any{
				"time": ev.Time, "ip": ev.IP, "country": ev.Country,
				"country_name": countryName(ev.Country),
				"path": ev.Path, "reason": ev.Reason, "reason_text": ev.ReasonText, "ua": ev.UA,
			}
		}
		statsMu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"total": total, "returned": len(items), "items": items})
	})

	// 一键将 IP 加入黑名单
	mux.HandleFunc("/admin/api/ban-ip", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			IP string `json:"ip"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		ip := strings.TrimSpace(req.IP)
		if ip == "" {
			ip = strings.TrimSpace(r.URL.Query().Get("ip"))
		}
		if net.ParseIP(ip) == nil {
			http.Error(w, "IP 地址无效", http.StatusBadRequest)
			return
		}
		old := currentCfg()
		for _, b := range old.BanList {
			if strings.TrimSpace(b) == ip {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"ok":true,"existed":true}`))
				return
			}
		}
		nc := *old
		nc.BanList = append(append([]string{}, old.BanList...), ip)
		if err := saveConfig(&nc); err != nil {
			http.Error(w, "保存失败", http.StatusInternalServerError)
			return
		}
		cfgPtr.Store(&nc)
		rebuildACL(&nc)
		recordAudit(getClientIP(r), "ban_ip", ip)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	mux.HandleFunc("/admin/api/audit", func(w http.ResponseWriter, r *http.Request) {
		limit := 200
		if s := r.URL.Query().Get("limit"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n > 0 {
				limit = n
			}
		}
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		all := stats.Audit
		n := len(all)
		if n > limit {
			n = limit
		}
		items := make([]AuditEvent, n)
		for i := 0; i < n; i++ {
			items[i] = all[len(all)-1-i]
		}
		statsMu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
	})
	mux.HandleFunc("/admin/api/ip-detail", func(w http.ResponseWriter, r *http.Request) {
		ip := strings.TrimSpace(r.URL.Query().Get("ip"))
		if ip == "" || net.ParseIP(ip) == nil {
			http.Error(w, "IP 地址格式无效，请输入合法的 IPv4/IPv6 地址", http.StatusBadRequest)
			return
		}
		code, name := ipLabelSync(ip)
		// IP 归属查询：固定走 ip9.com.cn，失效自动回落 ip-api.com（见 geoFetch）
		geo := geoEntry{}
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
		// 被拦截的 IP 请求不会进入代理统计，IPCounts 恒为 0；
		// 从拦截事件中统计该 IP 的拦截次数（仅限保留的最近事件窗口内）。
		blocked := 0
		for _, ev := range stats.Blocks {
			if ev.IP == ip {
				blocked++
			}
		}
		statsMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ip": ip, "country": code, "country_name": name,
			"region": geo.Region, "city": geo.City,
			"isp": geo.ISP, "org": geo.Org, "as": geo.AS,
			"location": strings.Join(locParts, " · "),
			"requests": reqs, "blocked": blocked,
		})
	})
	mux.HandleFunc("/admin/api/change-password", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ OldPass, NewPass string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		if len(req.NewPass) < 6 {
			http.Error(w, "新密码至少需要 6 位，请重新输入", http.StatusBadRequest)
			return
		}
		if !verifyPassword(getAdminHash(), req.OldPass) {
			http.Error(w, "当前密码不正确，修改未生效，请核对后重试", http.StatusForbidden)
			return
		}
		nh, err := hashPassword(req.NewPass)
		if err != nil {
			http.Error(w, "密码处理失败，请稍后重试", http.StatusInternalServerError)
			return
		}
		if err := saveAdminPassHash(nh); err != nil {
			http.Error(w, "保存失败，请稍后重试", http.StatusInternalServerError)
			return
		}
		setAdminCred(getAdminUser(), nh)
		// 踢出其他会话，强制重新登录
		tok := getSessionToken(r)
		destroyOtherSessions(tok)
		recordAudit(getClientIP(r), "change_password", "管理员修改了密码")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	// 测速链接管理：列出 / 生成 / 删除
	mux.HandleFunc("/admin/api/speed-tokens", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			type tokView struct {
				Token   string `json:"token"`
				URL     string `json:"url"`
				MaxUses int    `json:"max_uses"`
				Uses    int64  `json:"uses"`
				Created string `json:"created"`
				Expired bool   `json:"expired"`
			}
			var list []tokView
			speedTokens.Range(func(_, v any) bool {
				st := v.(*speedToken)
				list = append(list, tokView{st.Token, "/speed/" + st.Token, st.MaxUses, st.Uses.Load(), st.Created, speedTokenExpired(st)})
				return true
			})
			sort.Slice(list, func(i, j int) bool { return list[i].Created > list[j].Created })
			_ = json.NewEncoder(w).Encode(map[string]any{"items": list})
			return
		}
		if r.Method == http.MethodPost {
			var req struct {
				Uses   int `json:"uses"`
				Action string `json:"action"`
				Token  string `json:"token"`
			}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				http.Error(w, `{"error":"请求格式有误"}`, http.StatusBadRequest)
				return
			}
			if req.Action == "delete" {
				speedTokens.Delete(req.Token)
				saveSpeedTokens()
				recordAudit(getClientIP(r), "speed_delete", req.Token)
				_, _ = w.Write([]byte(`{"ok":true}`))
				return
			}
			if req.Uses < 1 || req.Uses > 10000 {
				http.Error(w, `{"error":"次数需在 1–10000 之间"}`, http.StatusBadRequest)
				return
			}
			tok := randToken(12)
			st := &speedToken{Token: tok, MaxUses: req.Uses, Created: beijingRFC3339(nowBeijing())}
			speedTokens.Store(tok, st)
			saveSpeedTokens()
			recordAudit(getClientIP(r), "speed_create", fmt.Sprintf("%s x%d", tok, req.Uses))
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "token": tok, "url": "/speed/" + tok, "max_uses": req.Uses})
			return
		}
		http.Error(w, "方法不支持", http.StatusMethodNotAllowed)
	})

	// 测速结果历史（最新在前，最多 100 条）
	mux.HandleFunc("/admin/api/speed-results", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodGet {
			http.Error(w, "方法不支持", http.StatusMethodNotAllowed)
			return
		}
		speedResultsMu.Lock()
		list := make([]speedResult, len(speedResults))
		copy(list, speedResults)
		speedResultsMu.Unlock()
		for i, j := 0, len(list)-1; i < j; i, j = i+1, j-1 {
			list[i], list[j] = list[j], list[i]
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"items": list, "total": len(list)})
	})

	mux.HandleFunc("/admin/api/clear-stats", func(w http.ResponseWriter, r *http.Request) {
		statsMu.Lock()
		stats = emptyStats()
		snap := marshalStatsLocked()
		statsMu.Unlock()
		persistStats(snap)
		recordAudit(getClientIP(r), "clear_stats", "清空全部统计与拦截记录")
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
	// 图标本地不做任何缓存，直接 302 到源站。
	mux.HandleFunc("/admin/logo.png", func(w http.ResponseWriter, r *http.Request) {
		redirectIcon(w, r, iconLogoURL)
	})
	mux.HandleFunc("/admin/icon-192.png", func(w http.ResponseWriter, r *http.Request) {
		redirectIcon(w, r, icon192URL)
	})
	mux.HandleFunc("/admin/icon-512.png", func(w http.ResponseWriter, r *http.Request) {
		redirectIcon(w, r, icon512URL)
	})
	mux.HandleFunc("/admin/manifest.webmanifest", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/manifest+json; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(pwaManifestJSON())
	})
	mux.HandleFunc("/admin/sw.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(swSource))
	})
	mux.HandleFunc("/admin/splash", func(w http.ResponseWriter, r *http.Request) {
		serveHTML(w, r, splashHTML, "text/html; charset=utf-8", "no-store")
	})
	mux.HandleFunc("/admin/api/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		html := strings.Replace(string(adminHTML), "<head>", "<head>\n"+pwaHeadExtra(), 1)
		html = strings.Replace(html, "</body>", pwaBodyExtra()+"</body>", 1)
		serveHTML(w, r, html, "text/html; charset=utf-8", "no-cache")
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


// startGeoDBUpdater 启动时确保本地 IP 库存在，并每 24h 尝试更新一次。
// 当前使用 phuslu/iploc（已嵌入）；此处预留从网络拉取更新包的扩展点。
func startGeoDBUpdater() {
	go func() {
		// 首次延迟 30s，避免启动高峰
		time.Sleep(30 * time.Second)
		for {
			// 可在此下载新的 iploc 数据或 ip2region.xdb 等
			// 示例：检查并下载 https://github.com/phuslu/iploc 相关更新
			log.Println("[geo] local IP database ready (embedded iploc); next check in 24h")
			time.Sleep(24 * time.Hour)
		}
	}()
}

// runServer 进程入口（systemd：… run -port … -admin-pass …）：
// 打开 DB → 迁移旧 JSON → 加载配置/统计 → 启动后台协程 → 监听并阻塞等信号。
func runServer(port int, adminUser, adminPass, dbFile string) {
	// Transport 与配置无关，只在启动时创建一次（见 newTransport 上方说明）
	proxyTr.v.Store(newTransport())
	var err error
	dbPath = dbFile
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
		}
		return nil
	})

	// 清理历史版本遗留在数据目录里的本地缓存文件（只保留 emby.db 这一份必要数据库）。
	// 旧版曾把 geo 结果落盘成 geo_cache.json，现已改为纯内存，直接删除不再保留 .bak。
	for _, legacy := range []string{"geo_cache.json", "geo_cache.json.bak", "stats.json.bak", "config.json.bak", "admin.pass.bak"} {
		_ = os.Remove(filepath.Join(filepath.Dir(dbFile), legacy))
	}

	loadConfig()
	// 密码：优先使用 DB 中的 bcrypt 哈希；兼容旧明文 admin_pass；无则用启动参数写入哈希
	var storedHash string
	var legacyPlain string
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("auth"))
		if b == nil {
			return nil
		}
		storedHash = string(b.Get([]byte("admin_pass_hash")))
		legacyPlain = string(b.Get([]byte("admin_pass")))
		return nil
	})
	finalHash := storedHash
	if finalHash == "" && legacyPlain != "" {
		if isBcryptHash(legacyPlain) {
			finalHash = legacyPlain
		} else if h, err := hashPassword(legacyPlain); err == nil {
			finalHash = h
			_ = saveAdminPassHash(h)
		}
	}
	if finalHash == "" {
		if adminPass == "" {
			log.Fatal("必须指定管理密码（--admin-pass）或已在数据库中保存密码哈希")
		}
		h, err := hashPassword(adminPass)
		if err != nil {
			log.Fatalf("密码哈希失败: %v", err)
		}
		finalHash = h
		_ = saveAdminPassHash(h)
	}
	setAdminCred(adminUser, finalHash)

	loadStats()
	loadSpeedResults()
	loadSpeedTokens()
	startSpeedTokenCleaner()
	startStatsWorker()
	startStatsSaver()

	startNetSpeedSampler()
	detectSelfPublicIP()
	initSessionsCleanup()
	startGeoDBUpdater() // 定时更新本地 IP 库
	// 图标不再预热/缓存：/favicon.ico 与 /admin/*.png 均直接 302 到源站
	defer saveStatsOnce()

	proxy := buildProxy(proxyTr)
	// 代理主处理：静态资源 → ACL → 地区 → 解析目标 → 白名单 → 反代并记流量
	// 纯透传：不包装响应，不统计字节
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/favicon.ico" || r.URL.Path == "/favicon.png" || r.URL.Path == "/favicon.svg" {
			redirectIcon(w, r, iconFaviconURL)
			return
		}
		if isBuiltinAssetPath(r.URL.Path) {
			serveError(w, http.StatusNotFound, "页面不存在", "未找到请求的资源。")
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
			serveError(w, http.StatusForbidden, "访问被拒绝", "当前请求无法继续。")
			return
		}
		if !uaAllowed(r.UserAgent()) {
			recordBlocked(ip, countryOf(ip), r.URL.RequestURI(), "ua", r.UserAgent())
			serveError(w, http.StatusForbidden, "访问被拒绝", "当前请求无法继续。")
			return
		}

		// 地区：热路径优先本地库；仅在需要展示名或 ChinaOnly 不确定时再走 geo
		country := countryOf(ip)
		if c.ChinaOnly && country != "CN" && country != "LO" && country != "PV" {
			// 本地库已能判定非 CN 时不再同步拉 geo API
			recordBlocked(ip, country, r.URL.RequestURI(), "cn", r.UserAgent())
			serveError(w, http.StatusForbidden, "访问被拒绝", "当前请求无法继续。")
			return
		}

		target, err := parseTarget(r)
		if err != nil {
			serveHome(w, r)
			return
		}
		if !whitelistMatch(c.Whitelist, target.Host) {
			recordBlocked(ip, country, r.URL.RequestURI(), "whitelist", r.UserAgent())
			serveError(w, http.StatusForbidden, "访问被拒绝", "当前请求无法继续。")
			return
		}

		// CORS 跨域功能已移除：不再注入任何 Access-Control-* 响应头，
		// 跨域预检（OPTIONS）按普通请求转发到上游，由上游自行决定如何响应。
		// 注意：这会让部分依赖宽松 CORS 头的播放器无法跨域拉流，属预期行为。

		recordRequestStart(ip, country, target.Host)

		concurrent.Add(1)
		defer concurrent.Add(-1)
		ctx := context.WithValue(r.Context(), targetCtxKey{}, target)
		// 包一层计数 Writer 统计上行字节（本机→客户端）。
		// Hijack 场景（如内部 WebSocket 升级）不经过这里，但媒体流均为普通 HTTP，
		// 其计数落点就是客户端的 TCP 写出。
		proxy.ServeHTTP(&countingWriter{ResponseWriter: w}, r.WithContext(ctx))
		pushLiveEvent(ip, country, target.Host, r.URL.Path)
	})

	adminSrv := adminHandler()
	// 管理后台全部走 gzip（HTML/JSON 压缩 70%+，WS 与图片自动跳过）
	adminGz := gzipMiddleware(adminSrv)
	root := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(fmt.Sprintf(`{"ok":true,"uptime_sec":%d}`, int64(time.Since(startedAt).Seconds()))))
			return
		}
		if r.URL.Path == "/admin" {
			http.Redirect(w, r, "/admin/", http.StatusFound)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/admin/") {
			adminGz.ServeHTTP(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/speed/") {
			serveSpeedTest(w, r)
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
<title>管理后台</title>
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
/* --- 系统信息卡片 --- */
.svg-title{font-size:11.5px;font-weight:600;letter-spacing:.4px;color:var(--t3);text-transform:uppercase;margin:0 0 8px}
.sv-list + .svg-title{margin-top:16px}
.kvr{display:flex;align-items:baseline;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px dashed var(--bd);font-size:13px;min-width:0}
.kvr:last-child{border-bottom:0}
.kvl{color:var(--t3);font-size:12.5px;flex-shrink:0;line-height:1.4}
.kvv{font-weight:600;color:var(--t);text-align:right;min-width:0;word-break:break-word;line-height:1.4;font-variant-numeric:tabular-nums}

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

/* ===== 美化增强 + 手机端优化 ===== */
.card{box-shadow:0 1px 3px rgba(15,23,42,.04),0 4px 12px -2px rgba(15,23,42,.05);transition:box-shadow .25s ease,transform .25s ease}
.card:hover{box-shadow:0 4px 16px -2px rgba(15,23,42,.08);transform:translateY(-1px)}
.stc{border-radius:14px;transition:transform .2s ease}
.stc:hover{transform:translateY(-2px)}
.btn{border-radius:10px;font-weight:500;transition:all .2s ease}
.btn:active{transform:scale(.98)}
.nav-i{border-radius:10px;transition:all .2s ease}
.filter{border-radius:8px;transition:all .15s ease}
.inp,.tarea{border-radius:10px;transition:border-color .2s,box-shadow .2s}
.inp:focus,.tarea:focus{box-shadow:0 0 0 3px var(--ps)}

/* 手机端进一步优化 */
@media(max-width:600px){
  body{font-size:15px}
  .tb{height:52px;box-shadow:0 1px 0 var(--bd)}
  .tb-t{font-size:17px;font-weight:600}
  .sc{padding:10px 12px 24px}
  .card{padding:14px;margin-bottom:12px;border-radius:14px}
  .sg{grid-template-columns:1fr 1fr;gap:10px}
  .stc{padding:12px 14px}
  .sv{font-size:20px}
  .sl{font-size:12px}
  .ss{font-size:11px}
  .ch{margin-bottom:12px}
  .ct{font-size:15px}
  .cd{font-size:12px}
  .flt{gap:4px;padding-bottom:4px}
  .filter{padding:8px 6px;font-size:12.5px;border-radius:8px}
  .btn{min-height:40px;padding:10px 16px}
  .btn.s{min-height:34px;padding:6px 12px}
  .inp,.tarea{min-height:42px;padding:10px 12px}
  .row{padding:12px 0}
  /* 表格卡片化已有，增强间距 */
  tr{margin-bottom:10px;border-radius:14px}
  td{padding:8px 12px}
  /* 底部安全区 */
  .sc{padding-bottom:max(20px,env(safe-area-inset-bottom))}
  /* 侧边栏更宽一点方便点击 */
  .sb{width:min(280px,85vw)}
  .nav-i{padding:12px 14px;font-size:15px}
  /* 模态框全屏感 */
  .mbox{border-radius:16px 16px 0 0;max-height:88dvh}
  .mo{align-items:flex-end;padding:0}
}
@media(max-width:380px){
  .sg{grid-template-columns:1fr}
  .sv{font-size:22px}
}
</style>
</head>
<body>
<button class="sb-mask" id="sbMask" aria-label="关闭菜单"></button>
<aside class="sb" id="sb">
<div class="sb-h" style="display:flex;align-items:center">
  <div class="sb-brand-icon"><img src="/admin/logo.png" alt="Emby Proxy" style="width:30px;height:30px;border-radius:7px"></div>
  <div class="sb-brand"><div class="sb-t">管理后台</div><div class="sb-sub">控制台</div></div>
</div>
<ul class="nav">
<li><button class="nav-i on" data-t="overview"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>概览</button></li>
<li><button class="nav-i" data-t="traffic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 14l4-4 4 4 5-6"/></svg>流量请求</button></li>
<li><button class="nav-i" data-t="realtime"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2"/></svg>实时监控</button></li>
<li><button class="nav-i" data-t="blocks"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/></svg>拦截记录</button></li>
<li><button class="nav-i" data-t="speedm"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h7l-1 8 10-12h-7l1-8z"/></svg>测速管理</button></li>
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
<div class="ch" style="margin-bottom:14px;justify-content:flex-start;flex-wrap:wrap;gap:10px">
  <div class="flt" id="ovRangeBar">
    <button class="filter on" data-r="today">今天</button>
    <button class="filter" data-r="yesterday">昨天</button>
    <button class="filter" data-r="7d">近 7 天</button>
    <button class="filter" data-r="30d">近 30 天</button>
    <button class="filter" data-r="all">全部</button>
    <button class="filter" data-r="custom">自定义</button>
  </div>
  <div id="ovCustomBox" style="display:none;align-items:center;gap:8px;flex-wrap:wrap">
    <input type="date" id="ovFrom" class="inp m" style="width:auto;padding:8px 10px;font-size:13px">
    <span style="color:var(--t3)">至</span>
    <input type="date" id="ovTo" class="inp m" style="width:auto;padding:8px 10px;font-size:13px">
    <button class="btn b s" id="ovApplyCustom" type="button">应用</button>
  </div>
</div>
<div class="sg">
<div class="stc b"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 14l4-4 4 4 5-6"/></svg>请求总数</div><div class="sv" id="ovReq">-</div><div class="ss">流量 <b id="ovBytes">0 B</b></div></div>
<div class="stc g"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>平均每日请求</div><div class="sv" id="ovAvgReq">-</div><div class="ss">日均流量 <b id="ovAvgBytes">0 B</b></div></div>
<div class="stc r"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/></svg>拦截次数</div><div class="sv" id="ovBlocked" style="color:var(--d)">-</div><div class="ss">全部拦截类型</div></div>
<div class="stc o"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></svg>独立 IP</div><div class="sv" id="uniqueIPs">-</div><div class="ss">实时统计</div></div>
</div>
<div class="card" style="margin-bottom:22px">
<div class="ch"><div><h2 class="ct" id="ovByteTitle">流量趋势</h2><div class="cd" id="ovByteDesc">仅统计经本服务转发的内容流量（不含系统与其他进程）</div></div></div>
<div style="position:relative;height:240px"><canvas id="miniByteChart"></canvas></div>
</div>
<div class="g3">
<div>
<div class="card" style="margin-bottom:22px;"><div class="ch"><div><h2 class="ct" id="ovReqTitle">请求趋势</h2><div class="cd" id="ovReqDesc">按天统计请求次数</div></div></div><div style="position:relative;height:220px"><canvas id="miniTrendChart"></canvas></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">系统信息</h2></div></div><div id="sysInfo"></div></div>
</div>
<div class="card"><div class="ch"><div><h2 class="ct">最新拦截</h2></div><button class="btn g s" data-goto="blocks">查看全部</button></div><div id="ovBlocks"></div></div>
</div>
</section>
<section id="traffic" class="pg">
<div class="ch" style="margin-bottom:14px;justify-content:flex-start;flex-wrap:wrap;gap:10px">
  <div class="flt" id="tfRangeBar">
    <button class="filter on" data-r="today">今天</button>
    <button class="filter" data-r="yesterday">昨天</button>
    <button class="filter" data-r="7d">近 7 天</button>
    <button class="filter" data-r="30d">近 30 天</button>
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
  <div class="stc g"><div class="sl">区间流量</div><div class="sv" id="tfBytes">-</div><div class="ss" id="tfBytesHint">—</div>
    <div style="display:flex;flex-wrap:wrap;gap:4px 14px;margin-top:8px;padding-top:8px;border-top:1px solid #f1f5f9;font-size:12px;color:var(--t3);white-space:nowrap">
      <span>↑ 上行<b id="tfUp" style="color:var(--t);font-family:var(--mono);font-weight:600;margin-left:4px">-</b></span>
      <span>↓ 下行<b id="tfDown" style="color:var(--t);font-family:var(--mono);font-weight:600;margin-left:4px">-</b></span>
    </div>
  </div>
  <div class="stc o"><div class="sl">独立 IP</div><div class="sv" id="tfIPs">-</div><div class="ss">当前筛选</div></div>
  <div class="stc r"><div class="sl">拦截次数</div><div class="sv" id="tfBlocked" style="color:var(--d)">-</div><div class="ss">当前筛选</div></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct" id="tfReqTitle">请求量趋势</h2><div class="cd" id="tfReqDesc">按天统计请求次数</div></div></div>
<div style="position:relative;height:260px"><canvas id="reqChart"></canvas></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct" id="tfByteTitle">流量消耗趋势</h2><div class="cd" id="tfByteDesc">仅统计经本服务转发的内容流量（不含系统与其他进程）</div></div></div>
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
<section id="realtime" class="pg">
<div class="sg" style="margin-bottom:18px">
  <div class="stc b"><div class="sl">当前并发</div><div class="sv" id="rtConc">-</div><div class="ss">正在处理的请求</div></div>
  <div class="stc g"><div class="sl">每秒请求</div><div class="sv" id="rtRps">-</div><div class="ss">最近 1 秒</div></div>
  <div class="stc o"><div class="sl">↓ 接收</div><div class="sv" id="rtRx">-</div><div class="ss">转发速率</div></div>
  <div class="stc r"><div class="sl">↑ 发送</div><div class="sv" id="rtTx">-</div><div class="ss">转发速率</div></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct">实时请求流</h2><div class="cd" id="rtStatus">进入页面才开始收集，退出即清空</div></div></div>
<div class="table-wrap"><table><thead><tr><th>时间</th><th>IP</th><th>地区</th><th>上游主机</th><th>路径</th></tr></thead><tbody id="rtTable"></tbody></table></div>
</div>
</section>
<section id="blocks" class="pg">
<div class="card">
<div class="ch"><div><h2 class="ct">拦截记录</h2><div class="cd">因黑名单、地区、白名单、限流或 UA 策略被拒绝的请求 · 每 5 秒自动刷新</div></div></div>
<div style="display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px;align-items:center">
  <input id="blkQ" class="inp m" type="search" placeholder="搜索 IP / 路径 / UA" style="max-width:220px">
  <select id="blkReason" class="inp m" style="width:auto;max-width:160px">
    <option value="">全部原因</option>
    <option value="cn">地区限制</option>
    <option value="whitelist">域名未授权</option>
    <option value="ban">IP 黑名单</option>
    <option value="rate_limit">触发限流</option>
    <option value="ua">UA 不允许</option>
    <option value="login_fail">登录失败</option>
  </select>
  <input id="blkIP" class="inp m" type="text" placeholder="精确 IP" style="max-width:150px">
  <button type="button" class="btn b s" id="blkFilterBtn">筛选</button>
  <button type="button" class="btn g s" id="blkResetBtn">重置</button>
  <span id="blkCount" style="font-size:12.5px;color:var(--t3)"></span>
</div>
<div class="table-wrap"><table><thead><tr><th>时间</th><th>IP 地址</th><th>国家/地区</th><th>拦截原因</th><th>访问路径</th><th>User-Agent</th><th>操作</th></tr></thead><tbody id="blockTable"></tbody></table></div>
</div>
</section>
<section id="speedm" class="pg">
<div class="g2">
  <div style="display:flex;flex-direction:column;gap:24px;">
    <div class="card" style="margin-bottom:0;">
      <div class="ch"><div><h2 class="ct">测速链接</h2><div class="cd">生成可视化测速页链接，可限制使用次数</div></div></div>
      <div class="fi"><label class="fl">可使用次数</label>
        <div style="display:flex;gap:12px;align-items:center">
          <input id="spdUses" class="inp m" type="number" min="1" max="10000" value="5" style="max-width:120px">
          <button class="btn b" id="spdCreate">生成链接</button>
        </div>
      </div>
      <div id="spdList" style="display:grid;gap:10px"></div>
    </div>
  </div>

  <div class="card" style="margin-bottom:0;">
    <div class="ch"><div><h2 class="ct">测速结果</h2><div class="cd">最多保留最近 100 条，重启不丢失</div></div></div>
    <div class="table-wrap"><table><thead><tr><th>时间</th><th>IP</th><th>延迟</th><th>抖动</th><th>下载</th><th>上传</th><th>评级</th></tr></thead><tbody id="spdResBody"></tbody></table></div>
  </div>
</div>
</section>
<section id="settings" class="pg">
<div class="g2">
  <div style="display:flex;flex-direction:column;gap:24px;">
    <div class="card" style="margin-bottom:0;">
      <div class="ch"><div><h2 class="ct">基础服务设置</h2></div></div>
      <div class="fi"><label class="fl">监听端口</label><div style="display:flex;gap:12px;align-items:center"><input id="portInput" class="inp m" type="number" style="max-width:140px"><button class="btn b" id="savePort">保存并重启监听</button></div></div>
      <div class="row"><div><div class="rl">PWA 安装</div><div class="rd">后台已内置 PWA，可安装到手机/电脑桌面，全屏运行</div></div><button type="button" class="btn b s" id="pwaInstallBtn">安装应用</button></div>
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
    <div class="fi"><label class="fl">UA 白名单</label><div class="hint" style="margin-bottom:8px">每行一个关键字，留空表示不限制</div><textarea id="allowedUAs" class="tarea" placeholder="Infuse&#10;Emby"></textarea></div>
    <div class="fi"><label class="fl">域名白名单</label><div class="hint" style="margin-bottom:8px">每行一个域名，支持根域名匹配</div><textarea id="whitelist" class="tarea" placeholder="example.com&#10;*.cdn.example.com"></textarea></div>
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
 * 页面：overview / traffic / blocks / settings
 * 时间：fmtBeijing → Asia/Shanghai；流量图大跨度按周/月聚合
 * 上下行口径：下行=上游→本机，上行=本机→客户端
 */
const state={port:0,labels:{},ovRange:'today',ovFrom:'',ovTo:'',tfRange:'today',tfFrom:'',tfTo:'',schemaVersion:2,cfgCache:null};
let ovTrendData=[];

function fmtBytes(b){if(!b)return '0 B';if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB'}
/* 字节坐标轴：先按数据最大值定一个统一单位，再在该单位下取整齐步长，
   避免 Chart.js 自动步长造成「1000 B / 1.95 KB」这类同轴混排 */
function bytesAxis(maxVal, tickCount){
  const units=[1,1024,1048576,1073741824,1099511627776];
  const names=['B','KB','MB','GB','TB'];
  let hi=0;
  while(hi<units.length-1 && maxVal/units[hi] >= 1024) hi++;
  const scale=units[hi], label=names[hi];
  const top=Math.max(maxVal,1)/scale;
  const ticks=Math.max(2, Math.min(8, tickCount||5));
  const raw=top/ticks;
  const mag=Math.pow(10, Math.floor(Math.log10(raw||1)));
  const norm=raw/(mag||1);
  const stepN=(norm<=1?1:(norm<=2?2:(norm<=5?5:10)))*mag;
  const fmt=n=>{
    // 整数直接输出，小数保留 1~2 位，去掉尾随 0
    const s=(Number.isInteger(n)? String(n) : (n>=10? n.toFixed(1) : n.toFixed(2)));
    return (s.indexOf('.')>=0 ? s.replace(/0+$/,'').replace(/\.$/,'') : s) + ' ' + label;
  };
  return {
    beginAtZero:true,
    max: Math.ceil(top/stepN)*stepN*scale,
    grid:{borderDash:[4,4]},
    ticks:{stepSize: stepN*scale, maxTicksLimit: ticks+1, callback:v=>fmt(v/scale)}
  };
}
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
function reasonLabel(r){return {cn:'地区限制',whitelist:'域名未授权',ban:'IP 黑名单',rate_limit:'触发限流',ua:'UA 不允许',login_fail:'登录失败'}[r]||'其他拦截'}
function reasonClass(r){return {cn:'pc',whitelist:'pw',ban:'pb',rate_limit:'pl',ua:'pu',login_fail:'pb'}[r]||'pw'}
function reasonFull(r){return {cn:'地区限制：仅允许中国大陆 IP',whitelist:'域名未授权：目标域名不在白名单',ban:'IP 黑名单：命中黑名单规则',rate_limit:'触发限流：超过每分钟请求上限',ua:'UA 不允许：User-Agent 不在白名单'}[r]||'其他拦截'}

function countryLabel(code){  if(!code) return '未知';
  const c = String(code).toUpperCase();
  if(state.labels && (state.labels[c]||state.labels[code])) return state.labels[c]||state.labels[code];
  const fallback = {LO:'本机',PV:'内网','??':'未知',CN:'中国',HK:'中国香港',TW:'中国台湾',MO:'中国澳门',US:'美国',JP:'日本',KR:'韩国',SG:'新加坡',GB:'英国',DE:'德国',FR:'法国',RU:'俄罗斯'};
  return fallback[c] || code;
}

const pageTitles={overview:'概览',traffic:'流量请求',realtime:'实时监控',blocks:'拦截记录',speedm:'测速管理',settings:'网关设置'};
let blocksTimer=null, realtimeWS=null;
function clearRealtimeUI(){
  const ids=['rtConc','rtRps','rtRx','rtTx'];
  ids.forEach(id=>{const el=document.getElementById(id);if(el)el.textContent='-';});
  const tb=document.getElementById('rtTable'); if(tb) tb.innerHTML='';
  const st=document.getElementById('rtStatus'); if(st) st.textContent='已退出，数据已清空';
}
function switchTab(id){
  document.querySelectorAll('.nav-i').forEach(b=>b.classList.toggle('on',b.dataset.t===id));
  document.querySelectorAll('.pg').forEach(el=>el.classList.toggle('on',el.id===id));
  document.getElementById('pt').textContent=pageTitles[id]||'';
  if(window.innerWidth<=1024)closeSidebar();
  if(blocksTimer){clearInterval(blocksTimer);blocksTimer=null}
  if(realtimeWS){try{realtimeWS.close()}catch(e){} realtimeWS=null; clearRealtimeUI();}
  if(id==='overview')loadOverview();
  if(id==='traffic')loadTraffic();
  if(id==='realtime') connectRealtime();
  if(id==='speedm'){loadSpeedTokens();loadSpeedResults();}
  if(id==='settings')loadSpeedTokens();
  if(id==='blocks'){
    loadBlocks();
    blocksTimer=setInterval(()=>{if(!document.hidden)loadBlocks()},5000);
  }
}
function connectRealtime(){
  clearRealtimeUI();
  const proto = location.protocol==='https:' ? 'wss:' : 'ws:';
  const url = proto+'//'+location.host+'/admin/api/realtime/ws';
  const st=document.getElementById('rtStatus');
  if(st) st.textContent='连接中…';
  const ws = new WebSocket(url);
  realtimeWS = ws;
  ws.onopen=()=>{ if(st) st.textContent='已连接 · 仅本页收集'; };
  ws.onclose=()=>{ if(document.getElementById('realtime')?.classList.contains('on')) clearRealtimeUI(); };
  ws.onerror=()=>{ if(st) st.textContent='连接失败'; };
  ws.onmessage=(ev)=>{
    try{
      const d=JSON.parse(ev.data);
      document.getElementById('rtConc').textContent=(d.concurrent||0).toLocaleString();
      document.getElementById('rtRps').textContent=(d.rps||0).toLocaleString();
      document.getElementById('rtRx').textContent=fmtBytes(d.rx_bps||0)+'/s';
      document.getElementById('rtTx').textContent=fmtBytes(d.tx_bps||0)+'/s';
      const evs=d.events||[];
      const tb=document.getElementById('rtTable');
      if(!evs.length) return;
      // 增量：新事件插到顶部，保留最多 80 条
      const html=evs.map(e=>`<tr>
        <td data-label="时间"><span class="cell-v muted mono">${esc(e.time)}</span></td>
        <td data-label="IP"><span class="cell-v mono ip-link" data-ip="${esc(e.ip)}" style="color:var(--pd);text-decoration:underline;cursor:pointer;font-weight:600">${esc(e.ip)}</span></td>
        <td data-label="地区"><span class="cell-v">${esc(countryLabel(e.country||'??'))}</span></td>
        <td data-label="上游"><span class="cell-v mono">${esc(e.host)}</span></td>
        <td data-label="路径"><span class="cell-v mono" style="font-size:12px;word-break:break-all">${esc(e.path)}</span></td>
      </tr>`).join('');
      const empty=tb.querySelector('.emp-row');
      if(empty) tb.innerHTML='';
      tb.insertAdjacentHTML('afterbegin', html);
      while(tb.rows.length>80) tb.deleteRow(tb.rows.length-1);
      tb.querySelectorAll('.ip-link').forEach(el=>{
        if(!el.dataset.bound){
          el.dataset.bound='1';
          el.addEventListener('click',()=>showIPDetail(el.dataset.ip));
        }
      });
    }catch(e){}
  };
}
function openSidebar(){document.getElementById('sb').classList.add('open');document.getElementById('sbMask').classList.add('on')}
function closeSidebar(){document.getElementById('sb').classList.remove('open');document.getElementById('sbMask').classList.remove('on')}
document.getElementById('mmb').addEventListener('click',(e)=>{e.stopPropagation();openSidebar()});
document.getElementById('sbMask').addEventListener('click',closeSidebar);

document.querySelectorAll('.nav-i').forEach(t=>t.addEventListener('click',()=>switchTab(t.dataset.t)));
document.addEventListener('click',e=>{const btn=e.target.closest('[data-goto]');if(btn){e.preventDefault();switchTab(btn.dataset.goto)}});

function applyPort(p){if(!p)return;state.port=p;document.getElementById('portInput').value=p;document.getElementById('portChip').textContent=':'+p}

async function loadConfig(){
  try{
    const r=await fetch('/admin/api/config',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const c=await r.json();applyPort(c.effective_port);
    document.getElementById('chinaOnly').checked=!!c.china_only;
    document.getElementById('whitelist').value=(c.whitelist||[]).join('\n');document.getElementById('banList').value=(c.ban_list||[]).join('\n');
    document.getElementById('allowedUAs').value=(c.allowed_uas||[]).join('\n');
  }catch(e){console.error('loadConfig error:',e)}
}

let miniTrendChart=null,miniByteChart=null,reqChart=null,byteChart=null,hostChart=null;
let trafficTrendData=[];

/* 概览区间边界：与流量页同一套口径（北京时间，单日=分时，多日=按天） */
function ovRangeBounds(){
  const tStr=nowBeijingDateStr();
  let from=null,to=tStr;
  const r=state.ovRange;
  if(r==='today'){from=tStr}
  else if(r==='yesterday'){const y=beijingDateStrBefore(1);from=y;to=y}
  else if(r==='7d'){from=beijingDateStrBefore(6)}
  else if(r==='30d'){from=beijingDateStrBefore(29)}
  else if(r==='all'){from=null;to=null}
  else if(r==='custom'){
    from=state.ovFrom||null;to=state.ovTo||null;
    if(from&&to&&from>to){const x=from;from=to;to=x}
  }
  return {from,to,today:tStr};
}
/* 概览趋势数据按区间过滤 */
function ovFilteredTrend(){
  const {from,to}=ovRangeBounds();
  return (ovTrendData||[]).filter(d=>{
    if(!d||!d.date)return false;
    if(from&&d.date<from)return false;
    if(to&&d.date>to)return false;
    return true;
  }).sort((a,b)=>a.date<b.date?-1:a.date>b.date?1:0);
}

function updateOvStats() {
  if (!ovTrendData.length) return;
  const {from,to}=ovRangeBounds();
  const filtered = ovFilteredTrend();
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

  // 标题/说明随区间变化（单日给分时提示，多日给天数）
  const single = !!from && from===to;
  const dayName = state.ovRange==='yesterday' ? '昨日' : '今日';
  // 多日：跨度按区间自然日算（与图上 X 轴一致），无数据的天按 0 计
  let spanDays = filtered.length;
  if(!single && from && to && to>=from){
    const a=new Date(from+'T00:00:00'), b=new Date(to+'T00:00:00');
    spanDays = Math.min(400, Math.round((b-a)/86400000)+1);
  }
  const spanHint = single ? (dayName + ' 分时') : (spanDays ? ('共 ' + spanDays + ' 天') : '暂无数据');
  document.getElementById('ovReqDesc').textContent = single ? (dayName + ' 00:00–23:00 各时段请求数（北京时间）') : ('区间内每日请求次数 · ' + spanHint);
  document.getElementById('ovByteDesc').textContent = single ? (dayName + ' 00:00–23:00 各时段整机端口流量（含其他进程，仅供参考）') : ('区间内每日整机端口流量（含其他进程） · ' + spanHint);
}

/* 概览趋势：单日→0~23 点；多日→按天（过长则按周/月汇总） */
function ovChartSeries(){
  const {from,to}=ovRangeBounds();
  const filtered=ovFilteredTrend();
  const single = !!from && from===to;
  const labels=[],reqs=[],ups=[],downs=[];
  if(single){
    const day=filtered[0]||{};
    const hours=day.hours||{}, hourUp=day.hour_up_bytes||{}, hourDown=day.hour_down_bytes||{};
    const hasHourly = Object.keys(hours).length || Object.keys(hourUp).length;
    if(hasHourly){
      for(let h=0;h<24;h++){
        const k=String(h).padStart(2,'0');
        labels.push(k+':00'); reqs.push(hours[k]||0);
        ups.push(hourUp[k]||0); downs.push(hourDown[k]||0);
      }
      return {labels,reqs,ups,downs,gran:'hour'};
    }
    // 兼容：拿不到分时明细时（老数据/极简响应），退化为单点当日汇总，避免全 0 空图
    labels.push((day.date||from||'').slice(5)||'当日');
    reqs.push(day.requests||0);
    ups.push(day.up_bytes||0); downs.push(day.down_bytes||0);
    return {labels,reqs,ups,downs,gran:'day'};
  }
  const byDate={}; filtered.forEach(d=>{byDate[d.date]=d});
  let days=Object.keys(byDate).sort();
  // 补全区间内每个自然日（无数据填 0），否则「近 7 天」只有 1 天有记录时
  // 图上只剩一个孤立圆点，看不出趋势
  if(from&&to&&to>=from){
    const a=new Date(from+'T00:00:00'), bEnd=new Date(to+'T00:00:00');
    const cap=400; // 防止自定义超大区间生成过多点
    let n=0; const full=[];
    for(let t=new Date(a); t<=bEnd && n<cap; t.setDate(t.getDate()+1), n++) full.push(localDateStr(new Date(t)));
    if(full.length) days=full;
  }
  if(!days.length) return {labels:[],reqs:[],ups:[],downs:[],gran:'day'};
  const gran=pickGranularity(days.length);
  if(gran==='day'){
    days.forEach(date=>{
      const d=byDate[date]||{};
      labels.push(date); reqs.push(d.requests||0);
      ups.push(d.up_bytes||0); downs.push(d.down_bytes||0);
    });
    return {labels,reqs,ups,downs,gran};
  }
  const buckets={},order=[];
  days.forEach(date=>{
    const key=gran==='week'?weekStartKey(date):monthKey(date);
    if(!buckets[key]){buckets[key]={req:0,up:0,down:0};order.push(key);}
    const d=byDate[date]||{};
    buckets[key].req+=(d.requests||0);
    buckets[key].up+=(d.up_bytes||0);
    buckets[key].down+=(d.down_bytes||0);
  });
  order.forEach(key=>{
    labels.push(key); reqs.push(buckets[key].req);
    ups.push(buckets[key].up); downs.push(buckets[key].down);
  });
  return {labels,reqs,ups,downs,gran};
}

async function loadOverview(){
  try{
    // slim=1：trend 只含每日汇总，避免 5 秒轮询拉全量明细（分时/主机/IP/国家）
    const r=await fetch('/admin/api/traffic?slim=1',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    document.getElementById('uniqueIPs').textContent=(t.unique_ips!=null?t.unique_ips:Object.keys(t.ip_counts||{}).length).toLocaleString();
    ovTrendData = t.trend || [];
    refreshOverview();
    
    // 概览只需最新几条拦截，limit=5 大幅减少轮询传输
    const r2=await fetch('/admin/api/blocks?limit=5',{cache:'no-store'});
    if(r2.ok){const b=await r2.json();renderOvBlocks(b.items||[]);}
    
    const r3=await fetch('/admin/api/config',{cache:'no-store'});
    if(r3.ok){const c=await r3.json();state.cfgCache=c;}
    let sys=null;
    try{
      const r4=await fetch('/admin/api/system',{cache:'no-store'});
      if(r4.ok) sys=await r4.json();
    }catch(e){}
    renderSysInfo(sys, sys&&sys.uptime_sec!=null?sys.uptime_sec:(t.uptime_sec||0));
  }catch(e){console.error('loadOverview error:',e)}
}

/* 系统信息卡片：仅保留运维最关心的少量指标，单列紧凑排布 */
function renderSysInfo(sys, uptime){
  const box=document.getElementById('sysInfo');
  if(!box) return;
  const up = uptime!=null ? uptime : (sys && sys.uptime_sec) || 0;
  const d=Math.floor(up/86400), h=Math.floor(up%86400/3600), m=Math.floor(up%3600/60);
  const upStr = d>0 ? (d+' 天 '+h+' 小时') : (h>0 ? (h+' 小时 '+m+' 分') : (m+' 分钟'));

  const kv=(k,v,color)=>`<div class="kvr"><span class="kvl">${k}</span><span class="kvv"${color?' style="color:'+color+'"':''}>${v}</span></div>`;
  const group=(title,rows)=>`<div class="svg-title">${title}</div><div class="sv-list">${rows.join('')}</div>`;

  const sw = sys || {};
  const run=[
    kv('运行时长', upStr),
    kv('监听端口', sw.port!=null ? (':'+sw.port) : '—'),
    kv('内存占用', fmtBytes(sw.mem_heap||0)),
    kv('在线会话', (sw.logins!=null? sw.logins : '—') + ' 个'),
  ];
  const diskPct = sw.disk_total ? Math.max(0, Math.round(sw.disk_free/sw.disk_total*100)) : 0;
  const env=[
    kv('版本', sw.version ? ('v'+esc(sw.version)) : '—'),
    kv('运行环境', (sw.go_version||'—') + (sw.os_arch? ' · '+esc(sw.os_arch) : '')),
    kv('数据库', fmtBytes(sw.db_size||0)),
    kv('磁盘剩余', fmtBytes(sw.disk_free||0) + (sw.disk_total? ` <span style="color:var(--t3);font-weight:500">${diskPct}%</span>` : '')),
  ];

  box.innerHTML = group('运行状态', run) + group('环境', env);
}

/* 概览两张图共用：按当前区间渲染请求趋势 + 流量趋势（上下行） */
function renderOvCharts(){
  if(typeof Chart==='undefined') return;
  const v=ovChartSeries();

  // --- 请求趋势 ---
  const cvReq=document.getElementById('miniTrendChart');
  if(cvReq && v.labels.length){
    const cfg={type:'line',data:{labels:v.labels.map(l=>fmtAxisLabel(l,v.gran)),datasets:[
      {label:'请求',data:v.reqs,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.1)',borderWidth:2,fill:true,tension:0.35,pointRadius:v.gran==='hour'?0:3}
    ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(v.labels,v.gran)}}},scales:{x:{grid:{display:false},ticks:{autoSkip:true,maxTicksLimit:chartTickLimit(v.labels.length,v.gran)}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}}}}};
    miniTrendChart=upsertChart(miniTrendChart,cvReq,cfg);
  }

  // --- 流量趋势（上下行合计，单条平滑曲线）---
  const cvByte=document.getElementById('miniByteChart');
  if(cvByte && v.labels.length){
    const tot=v.ups.map((u,i)=>(u||0)+(v.downs[i]||0));
    const cfgByte={type:'line',data:{labels:v.labels.map(l=>fmtAxisLabel(l,v.gran)),datasets:[
      {label:'流量',data:tot,borderColor:'#10b981',backgroundColor:'rgba(16,185,129,0.12)',borderWidth:2,fill:true,tension:0.4,pointRadius:v.gran==='hour'?0:3,pointHoverRadius:5}
    ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(v.labels,v.gran),label:c=>'流量：'+fmtBytes(c.parsed.y)}}},scales:{x:{grid:{display:false},ticks:{autoSkip:true,maxTicksLimit:chartTickLimit(v.labels.length,v.gran)}},y:bytesAxis(Math.max.apply(null, tot.concat([0])), 5)}}};
    miniByteChart=upsertChart(miniByteChart,cvByte,cfgByte);
  }
}

/* 概览区间切换后统一刷新（统计 + 两张图） */
function refreshOverview(){
  updateOvStats();
  renderOvCharts();
}

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
/* 按北京时间取「今天往前 n 天」的日期字符串 */
function beijingDateStrBefore(days){
  const now = new Date();
  const bj = new Date(now.getTime() + (now.getTimezoneOffset() + 480) * 60000);
  bj.setDate(bj.getDate() - days);
  return bj.getFullYear() + '-' + String(bj.getMonth()+1).padStart(2,'0') + '-' + String(bj.getDate()).padStart(2,'0');
}
function dateRangeBounds(){
  const tStr=nowBeijingDateStr();
  let from=null,to=tStr;
  const r=state.tfRange;
  if(r==='today'){from=tStr}
  else if(r==='yesterday'){const y=beijingDateStrBefore(1);from=y;to=y}
  else if(r==='7d'){from=beijingDateStrBefore(6)}
  else if(r==='30d'){from=beijingDateStrBefore(29)}
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
  const {from,to}=dateRangeBounds();
  const isToday = !!from && from === to;
  const labels=[],reqs=[],bytes=[],ups=[],downs=[];
  const ipMap={},ctryMap={},hostMap={};
  let totalReq=0,totalBytes=0,totalUp=0,totalDown=0,blocked=0,rawDayCount=0,gran='hour';
  filtered.forEach(d=>{
    totalReq+=d.requests||0; totalBytes+=d.bytes||0;
    totalUp+=d.up_bytes||0; totalDown+=d.down_bytes||0;
    blocked+=(d.blocked!=null)?d.blocked:((d.blocked_cn||0)+(d.blocked_whitelist||0));
    Object.entries(d.ips||{}).forEach(([k,v])=>{ipMap[k]=(ipMap[k]||0)+v});
    Object.entries(d.countries||{}).forEach(([k,v])=>{ctryMap[k]=(ctryMap[k]||0)+v});
    Object.entries(d.hosts||{}).forEach(([k,v])=>{hostMap[k]=(hostMap[k]||0)+v});
  });
  if(isToday){
    gran='hour';
    const byDate={}; filtered.forEach(d=>{byDate[d.date]=d});
    const day=byDate[from]||filtered[0]||{hours:{},hour_bytes:{}};
    const hours=day.hours||{}, hourBytes=day.hour_bytes||{};
    const hourUp=day.hour_up_bytes||{}, hourDown=day.hour_down_bytes||{};
    for(let h=0;h<24;h++){
      const key=String(h).padStart(2,'0');
      const up=hourUp[key]||0, down=hourDown[key]||0;
      labels.push(key+':00'); reqs.push(hours[key]||0);
      // 真实分时：优先上下行明细，缺失时回落到合计
      ups.push(up); downs.push(down);
      bytes.push((up||down)?(up+down):(hourBytes[key]||0));
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
      days.forEach(date=>{
        const d=byDate[date]||{};
        labels.push(date); reqs.push(d.requests||0); bytes.push(d.bytes||0);
        ups.push(d.up_bytes||0); downs.push(d.down_bytes||0);
      });
    }else{
      const buckets={}, order=[];
      days.forEach(date=>{
        const key=gran==='week'?weekStartKey(date):monthKey(date);
        if(!buckets[key]){ buckets[key]={req:0,bytes:0,up:0,down:0}; order.push(key); }
        const d=byDate[date]||{};
        buckets[key].req+=(d.requests||0); buckets[key].bytes+=(d.bytes||0);
        buckets[key].up+=(d.up_bytes||0); buckets[key].down+=(d.down_bytes||0);
      });
      order.forEach(key=>{
        labels.push(key); reqs.push(buckets[key].req); bytes.push(buckets[key].bytes);
        ups.push(buckets[key].up); downs.push(buckets[key].down);
      });
    }
  }
  const hostTop=Object.entries(hostMap).sort((a,b)=>b[1]-a[1]).slice(0,12);
  const ipTopN=30, ctryTopN=25;
  const ipEntries=Object.entries(ipMap).sort((a,b)=>b[1]-a[1]);
  const ctryEntries=Object.entries(ctryMap).sort((a,b)=>b[1]-a[1]);
  const ipMapTrim={}, ctryMapTrim={};
  ipEntries.slice(0,ipTopN).forEach(([k,v])=>{ipMapTrim[k]=v});
  ctryEntries.slice(0,ctryTopN).forEach(([k,v])=>{ctryMapTrim[k]=v});
  return {isToday,gran,labels,reqs,bytes,ups,downs,ipMap:ipMapTrim,ctryMap:ctryMapTrim,hostTop,totalReq,totalBytes,totalUp,totalDown,blocked,dayCount:rawDayCount,ipTotalUnique:ipEntries.length,ctryTotalUnique:ctryEntries.length,ipTopN,ctryTopN};
}
function applyTrafficView(){
  const v=buildTrafficView(trafficTrendData);
  document.getElementById('tfReq').textContent=v.totalReq.toLocaleString();
  document.getElementById('tfBytes').textContent=fmtBytes(v.totalBytes);
  const elUp=document.getElementById('tfUp'), elDown=document.getElementById('tfDown');
  if(elUp) elUp.textContent=fmtBytes(v.totalUp);
  if(elDown) elDown.textContent=fmtBytes(v.totalDown);
  document.getElementById('tfIPs').textContent=v.ipTotalUnique.toLocaleString();
  document.getElementById('tfBlocked').textContent=v.blocked.toLocaleString();
  const dayName=v.isToday?(state.tfRange==='yesterday'?'昨日':'今日'):'';
  const granHint={hour:dayName+'分时段',day:'共 '+v.dayCount+' 天',week:'共 '+v.dayCount+' 天 · 按周汇总',month:'共 '+v.dayCount+' 天 · 按月汇总'};
  document.getElementById('tfReqHint').textContent=granHint[v.gran]||('共 '+v.dayCount+' 天');
  document.getElementById('tfBytesHint').textContent=v.isToday?(dayName+'真实分时流量 · 上行+下行合计'):('日均 '+fmtBytes(Math.round(v.totalBytes/(v.dayCount||1)))+' · 上行+下行合计');
  const titleMap={hour:['请求量趋势（分时）','流量消耗趋势（分时）'],day:['请求量趋势','流量消耗趋势'],week:['请求量趋势（按周）','流量消耗趋势（按周）'],month:['请求量趋势（按月）','流量消耗趋势（按月）']};
  const descMap={hour:[dayName+' 00:00–23:00 各时段请求数（北京时间）',dayName+' 00:00–23:00 各时段上下行流量（上行=本机→客户端，下行=上游→本机）'],day:['筛选区间内每日请求次数（北京时间）','筛选区间内每日上下行流量（下行=上游→本机，上行=本机→客户端）'],week:['区间超过 60 天，已按周汇总','区间超过 60 天，已按周汇总流量'],month:['区间超过 180 天，已按月汇总','区间超过 180 天，已按月汇总流量']};
  const tt=titleMap[v.gran]||titleMap.day, dd=descMap[v.gran]||descMap.day;
  document.getElementById('tfReqTitle').textContent=tt[0];
  document.getElementById('tfReqDesc').textContent=dd[0];
  document.getElementById('tfByteTitle').textContent=tt[1];
  document.getElementById('tfByteDesc').textContent=dd[1];
  document.getElementById('tfHostDesc').textContent=v.isToday?(dayName+'访问量最高的上游主机'):'当前范围内访问量最高的上游主机';
  renderReqChart(v.labels,v.reqs,v.gran);
  renderByteChart(v.labels,v.ups,v.downs,v.gran);
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
    state.schemaVersion = (t.schema_version!=null? t.schema_version : 2);
    trafficTrendData = t.trend || [];
    // 自定义日期输入默认最近 7 天
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
  const cfg={type:'line',data:{labels:labs,datasets:[{label:'请求数',data,borderColor:'#10b981',backgroundColor:'rgba(16,185,129,0.13)',borderWidth:2,fill:true,tension:0.4,pointRadius:dense||gran==='hour'?0:(labels.length>20?2:3),pointHoverRadius:5}]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:dense?false:{duration:400},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(labels,gran),label:c=>'请求数：'+Number(c.parsed.y||0).toLocaleString()}}},scales:{x:{grid:{display:false},ticks:{maxRotation:45,minRotation:0,autoSkip:true,maxTicksLimit:chartTickLimit(labels.length,gran)}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}}}}};
  reqChart=upsertChart(reqChart,cv,cfg);
}
function renderByteChart(labels,ups,downs,gran){
  const cv=document.getElementById('byteChart');if(!cv||typeof Chart==='undefined')return;
  gran=gran||'day';
  const labs=labels.map(l=>fmtAxisLabel(l,gran));
  const dense=labels.length>40;
  // 上下行合并展示：total = 上行 + 下行，一条平滑曲线
  const tot=(labels||[]).map((_,i)=>((ups&&ups[i])||0)+((downs&&downs[i])||0));
  const cfg={type:'line',data:{labels:labs,datasets:[
    {label:'流量',data:tot,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.13)',borderWidth:2,fill:true,tension:0.4,pointRadius:dense||gran==='hour'?0:(labels.length>20?2:3),pointHoverRadius:5}
  ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:dense?false:{duration:400},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(labels,gran),label:c=>'流量：'+fmtBytes(c.parsed.y)}}},scales:{x:{grid:{display:false},ticks:{maxRotation:45,minRotation:0,autoSkip:true,maxTicksLimit:chartTickLimit(labels.length,gran)}},y:bytesAxis(Math.max.apply(null, tot.concat([0])), 5)}}};
  byteChart=upsertChart(byteChart,cv,cfg);
}
function renderHostChart(hostTop){
  const cv=document.getElementById('hostChart');if(!cv||typeof Chart==='undefined')return;
  const labels=hostTop.map(([h])=>h.length>22?h.slice(0,20)+'…':h);
  const data=hostTop.map(([,n])=>n);
  if(!labels.length){labels.push('暂无数据');data.push(0)}
  const dense=labels.length>24;
  // 横向树状图：主机名较长，横条比折线更易读
  const cfg={type:'bar',data:{labels,datasets:[{label:'请求',data,backgroundColor:'rgba(139,92,246,0.75)',hoverBackgroundColor:'#8b5cf6',borderRadius:4,maxBarThickness:22}]},options:{indexAxis:'y',responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false},tooltip:{callbacks:{label:c=>'请求：'+Number(c.parsed.x||0).toLocaleString()}}},scales:{x:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}},y:{grid:{display:false},ticks:{autoSkip:true,maxTicksLimit:14,font:{size:11}}}}}};
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
    let cntRow;
    if((d.requests||0)>0){
      cntRow=['请求次数',d.requests.toLocaleString()+' 次',false];
    }else{
      cntRow=['拦截次数',(d.blocked||0).toLocaleString()+' 次',false];
    }
    const rows=[['IP',d.ip,true],['位置',loc,false],cntRow];
    document.getElementById('modalBody').innerHTML=rows.map(([k,v,m])=>'<div class="kv"><div class="kk">'+esc(k)+'</div><div class="kvv'+(m?' m':'')+'">'+esc(v)+'</div></div>').join('');
  }catch(e){
    document.getElementById('modalBody').innerHTML='<div style="color:var(--d);font-size:13px">加载失败：'+esc(e.message||'未知错误')+'</div>';
  }
}

async function loadBlocks(){
  try{
    const q=document.getElementById('blkQ')?.value?.trim()||'';
    const reason=document.getElementById('blkReason')?.value||'';
    const ip=document.getElementById('blkIP')?.value?.trim()||'';
    const params=new URLSearchParams({limit:'500'});
    if(q) params.set('q',q);
    if(reason) params.set('reason',reason);
    if(ip) params.set('ip',ip);
    const r=await fetch('/admin/api/blocks?'+params.toString(),{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    const tb=document.getElementById('blockTable');
    const cnt=document.getElementById('blkCount');
    if(cnt) cnt.textContent='共 '+(t.total||0)+' 条'+(t.returned<t.total?' · 显示最新 '+t.returned:'');
    if(!t.items||!t.items.length){tb.innerHTML='<tr class="emp-row"><td colspan="7"><div class="emp"><b>暂无记录</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">没有匹配的拦截事件</span></div></td></tr>';return}
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
      <td data-label="操作"><span class="cell-v"><button type="button" class="btn d s ban-ip-btn" data-ip="${esc(b.ip)}" style="padding:4px 8px;font-size:12px">拉黑</button></span></td>
    </tr>`}).join('');
    tb.querySelectorAll('.ip-link').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
    tb.querySelectorAll('.ban-ip-btn').forEach(el=>el.addEventListener('click',async(ev)=>{
      ev.stopPropagation();
      const ip=el.dataset.ip;
      if(!ip||!confirm('确认将 '+ip+' 加入黑名单？'))return;
      try{
        const r=await fetch('/admin/api/ban-ip',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip})});
        const d=await r.json().catch(()=>({}));
        if(!r.ok){alert(d.error||'拉黑失败');return;}
        alert(d.existed?'该 IP 已在黑名单中':'已加入黑名单');
        loadConfig();
      }catch(e){alert('网络异常');}
    }));
  }catch(e){console.error('loadBlocks error:',e)}
}


function collect(){
  const raw=parseInt(document.getElementById('portInput').value,10);
  return{port:isNaN(raw)?0:raw,china_only:document.getElementById('chinaOnly').checked,whitelist:document.getElementById('whitelist').value.split('\n').map(x=>x.trim()).filter(Boolean),geo_api:true,ban_list:document.getElementById('banList').value.split('\n').map(x=>x.trim()).filter(Boolean),allowed_uas:document.getElementById('allowedUAs').value.split('\n').map(x=>x.trim()).filter(Boolean)}
}
async function save(){
  try{
    const r=await fetch('/admin/api/save',{method:'POST',body:JSON.stringify(collect())});
    if(!r.ok)throw new Error(await r.text());
    const c=await r.json();applyPort(c.effective_port);
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
document.getElementById('blkFilterBtn')?.addEventListener('click',()=>loadBlocks());
document.getElementById('blkResetBtn')?.addEventListener('click',()=>{
  const q=document.getElementById('blkQ'); if(q)q.value='';
  const r=document.getElementById('blkReason'); if(r)r.value='';
  const i=document.getElementById('blkIP'); if(i)i.value='';
  loadBlocks();
});
document.getElementById('blkQ')?.addEventListener('keydown',e=>{if(e.key==='Enter')loadBlocks()});
document.getElementById('clearStatsBtn').addEventListener('click',async()=>{
  if(!confirm('确定清空全部统计数据？此操作不可恢复。'))return;
  await fetch('/admin/api/clear-stats',{method:'POST'});alert('统计数据已清空');loadOverview();
});

document.getElementById('ovRangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#ovRangeBar .filter').forEach(b => b.classList.toggle('on', b === btn));
  state.ovRange = btn.dataset.r;
  const box=document.getElementById('ovCustomBox');
  if(box) box.style.display = state.ovRange==='custom' ? 'flex' : 'none';
  if(state.ovRange==='custom'){
    // 首次切到自定义：预填最近 7 天，避免空输入框
    const fEl=document.getElementById('ovFrom'), tEl=document.getElementById('ovTo');
    if(fEl && !fEl.value) fEl.value=beijingDateStrBefore(6);
    if(tEl && !tEl.value) tEl.value=nowBeijingDateStr();
    if(state.ovFrom&&state.ovTo) refreshOverview();
  }else{
    refreshOverview();
  }
});
document.getElementById('ovApplyCustom')?.addEventListener('click',()=>{
  const f=document.getElementById('ovFrom').value||'', t=document.getElementById('ovTo').value||'';
  if(!f||!t){alert('请选择开始和结束日期');return}
  state.ovFrom=f; state.ovTo=t;
  refreshOverview();
});

document.getElementById('tfRangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#tfRangeBar .filter').forEach(b => b.classList.toggle('on', b === btn));
  state.tfRange = btn.dataset.r;
  const box=document.getElementById('tfCustomBox');
  if(box) box.style.display = state.tfRange==='custom' ? 'flex' : 'none';
  if(state.tfRange==='custom'){
    // 首次切到自定义：预填最近 7 天，避免空输入框
    const fEl=document.getElementById('tfFrom'), tEl=document.getElementById('tfTo');
    if(fEl && !fEl.value) fEl.value=beijingDateStrBefore(6);
    if(tEl && !tEl.value) tEl.value=nowBeijingDateStr();
    if(state.tfFrom&&state.tfTo){applyTrafficView();return}
  }
  applyTrafficView();
});
document.getElementById('tfApplyCustom')?.addEventListener('click',()=>{
  const f=document.getElementById('tfFrom').value||'', t=document.getElementById('tfTo').value||'';
  if(!f||!t){alert('请选择开始和结束日期');return}
  state.tfFrom=f; state.tfTo=t;
  applyTrafficView();
});

document.getElementById('modalClose').addEventListener('click',()=>document.getElementById('modal').classList.remove('on'));
document.getElementById('modal').addEventListener('click',e=>{if(e.target.id==='modal')e.currentTarget.classList.remove('on')});

const _origFetch = window.fetch;
window.fetch = async function(...args) {
  let url = args[0];
  let opts = args[1] || {};
  if (typeof url === 'string' && url.includes('/admin/api/') && (opts.method||'GET').toUpperCase() !== 'GET') {
    opts.headers = Object.assign({'X-Emby-CSRF':'1','X-Requested-With':'XMLHttpRequest'}, opts.headers||{});
    args[1] = opts;
  }
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
 * PWA 恒为开启（内置 manifest + Service Worker）：浏览器满足安装条件时触发
 * beforeinstallprompt，设置页的“安装应用”按钮即可随时安装；
 * 已作为独立应用运行时按钮自动隐藏。 */
let pwaInstallPrompt=null;
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
    }
  }catch(e){}
  pwaInstallPrompt=null;
}
window.addEventListener('beforeinstallprompt',e=>{
  e.preventDefault();
  pwaInstallPrompt=e;
});
window.addEventListener('appinstalled',()=>{
  pwaInstallPrompt=null;
});
document.getElementById('pwaInstallBtn')?.addEventListener('click',pwaInstall);

/* ---------- 测速链接 ---------- */
let spdPage=1;const SPD_PAGE_SIZE=5;
async function loadSpeedTokens(){
  const box=document.getElementById('spdList');
  if(!box)return;
  try{
    const r=await fetch('/admin/api/speed-tokens',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    const items=t.items||[];
    if(!items.length){spdPage=1;box.innerHTML='<div style="font-size:12.5px;color:var(--t3)">暂无测速链接。生成后打开 /speed/xxx 即是测速页（仪表盘样式），每次打开占用 1 次，用完自动失效；创建 7 天后也会自动过期删除。</div>';return}
    const pages=Math.max(1,Math.ceil(items.length/SPD_PAGE_SIZE));
    if(spdPage>pages)spdPage=pages;
    const pageItems=items.slice((spdPage-1)*SPD_PAGE_SIZE,spdPage*SPD_PAGE_SIZE);
    let html=pageItems.map(it=>{
      const used=it.uses>=it.max_uses;
      const dead=it.expired||used;
      const pct=it.max_uses?Math.round(it.uses/it.max_uses*100):0;
      const state=it.expired?'<span style="color:var(--d)">已过期（7 天）</span>':used?'<span style="color:var(--d)">已失效</span>':'使用中';
      return `<div style="border:1px solid var(--bd);border-radius:12px;padding:12px 14px">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
          <code style="font-size:12.5px;color:var(--pd);word-break:break-all">${location.origin}/speed/${it.token}</code>
          <div style="display:flex;gap:8px;flex-shrink:0">
            <button class="btn g s" onclick="copySpeedUrl('${it.token}')">复制</button>
            <button class="btn d s" onclick="delSpeedToken('${it.token}')">删除</button>
          </div>
        </div>
        <div style="display:flex;justify-content:space-between;margin-top:8px;font-size:12px;color:var(--t3)">
          <span>${state} · ${it.uses}/${it.max_uses} 次 · ${esc(it.created)}</span>
          <span>${pct}%</span>
        </div>
        <div style="height:4px;background:#f1f5f9;border-radius:2px;margin-top:6px;overflow:hidden"><i style="display:block;height:100%;width:${pct}%;background:${dead?'var(--d)':'var(--ok)'}"></i></div>
      </div>`;
    }).join('');
    if(pages>1){
      html+=`<div style="display:flex;justify-content:space-between;align-items:center;margin-top:12px;font-size:12.5px;color:var(--t3)">
        <button class="btn g s" ${spdPage<=1?'disabled style="opacity:.5;cursor:not-allowed"':''} onclick="spdGo(${spdPage-1})">上一页</button>
        <span>第 ${spdPage} / ${pages} 页 · 共 ${items.length} 条</span>
        <button class="btn g s" ${spdPage>=pages?'disabled style="opacity:.5;cursor:not-allowed"':''} onclick="spdGo(${spdPage+1})">下一页</button>
      </div>`;
    }
    box.innerHTML=html;
  }catch(e){box.innerHTML='<div style="color:var(--d);font-size:12.5px">加载失败：'+esc(e.message)+'</div>'}
}
function spdGo(p){spdPage=p;loadSpeedTokens();}
async function createSpeedToken(){
  const uses=parseInt(document.getElementById('spdUses').value,10)||5;
  try{
    const r=await fetch('/admin/api/speed-tokens',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({uses})});
    const t=await r.json();
    if(!r.ok)throw new Error(t.error||('HTTP '+r.status));
    spdPage=1;loadSpeedTokens();
  }catch(e){alert('生成失败：'+e.message)}
}
async function delSpeedToken(tok){
  await fetch('/admin/api/speed-tokens',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'delete',token:tok})});
  loadSpeedTokens();
}
function copySpeedUrl(tok){
  const url=location.origin+'/speed/'+tok;
  (navigator.clipboard?navigator.clipboard.writeText(url):Promise.reject()).then(()=>{}).catch(()=>{
    const ta=document.createElement('textarea');ta.value=url;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();
  });
}
document.getElementById('spdCreate')?.addEventListener('click',createSpeedToken);

async function loadSpeedResults(){
  const tb=document.getElementById('spdResBody');
  if(!tb)return;
  try{
    const r=await fetch('/admin/api/speed-results',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    const items=t.items||[];
    const cnt=document.getElementById('spdResCount');
    if(cnt)cnt.textContent='共 '+t.total+' 条 · 最多保留 100 条 · 重启不丢失';
    if(!items.length){tb.innerHTML='<tr><td colspan="7" style="text-align:center;color:var(--t3);padding:18px 0">暂无测速记录，生成链接测速后自动记录</td></tr>';return}
    const grade=m=>m>=200?['g-g','极佳']:m>=50?['g-g','良好']:m>=20?['g-m','一般']:['g-b','较差'];
    tb.innerHTML=items.map(it=>{
      const [gc,gt]=grade(it.down_mbps);
      const dt=(it.time||'').replace('T',' ').slice(0,19);
      return `<tr><td data-label="时间">${esc(dt)}</td><td data-label="IP"><span class="cell-v mono ip-link" data-ip="${esc(it.ip)}" style="color:var(--pd);text-decoration:underline;cursor:pointer;font-weight:600">${esc(it.ip)}</span></td><td data-label="延迟"><span class="cell-v">${it.ping_ms.toFixed(0)} ms</span></td><td data-label="抖动"><span class="cell-v">${it.jitter_ms.toFixed(0)} ms</span></td><td data-label="下载"><span class="cell-v"><b>${it.down_mbps>=100?Math.round(it.down_mbps):it.down_mbps.toFixed(1)}</b> Mbps</span></td><td data-label="上传"><span class="cell-v"><b>${it.up_mbps>=100?Math.round(it.up_mbps):(it.up_mbps||0).toFixed(1)}</b> Mbps</span></td><td data-label="评级"><span class="cell-v"><span class="grade ${gc}" style="margin-top:0">${gt}</span></span></td></tr>`;
    }).join('');
    tb.querySelectorAll('.ip-link').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
  }catch(e){
    tb.innerHTML='<tr><td colspan="7" style="color:var(--d)">加载失败：'+esc(e.message||'')+'</td></tr>';
  }
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
ExecStart=${BIN_PATH} run -port ${PORT} -admin-user ${u} -db ${DB_FILE}
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
    go get "golang.org/x/crypto/bcrypt@v0.31.0" >/dev/null 2>&1 || true
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
  # 密码以数据库为准（后台「修改密码」只更新 DB 哈希，不会改 unit 里的启动参数）
  # 因此：仅在本次新生成/用户显式指定密码时打印；更新/已有安装不打印 unit 中的旧明文，避免误导
  if [[ ${GENERATED_PASS:-0} -eq 1 ]] || [[ ${PASS_GIVEN:-0} -eq 1 ]]; then
    if [[ -n "$ADMIN_PASS" ]]; then
      printf '   密  码:  %s\n' "$ADMIN_PASS"
      printf '   %s（请立即保存；之后可在管理后台修改，修改后以后台为准）%s\n' "$C_D" "$C_0"
    fi
  else
    printf '   密  码:  %s沿用数据库中已保存的密码%s\n' "$C_D" "$C_0"
    printf '            %s若曾在管理后台修改过，请用修改后的密码登录%s\n' "$C_D" "$C_0"
    printf '            %s（unit 中的 -admin-pass 仅作首次引导，改密后不再使用）%s\n' "$C_D" "$C_0"
  fi
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
    # 首次安装（尚无 DB 哈希）时临时写入密码引导；启动成功后立即剥离
    local unit_content="$expected_unit"
    local first_boot=0
    if [[ ! -f "$DB_FILE" ]] || ! grep -q "admin_pass_hash" "$DB_FILE" 2>/dev/null; then
      first_boot=1
      unit_content="${unit_content/ -db / -admin-pass $(systemd_quote "$ADMIN_PASS") -db }"
    fi
    printf '%s\n' "$unit_content" > "$UNIT_FILE"
    chmod 0600 "$UNIT_FILE"
    info "已更新 systemd unit"; systemctl daemon-reload
  fi
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 2
  # 首次启动成功后，剥离 unit 中的明文密码并重载
  if [[ ${first_boot:-0} -eq 1 ]] && systemctl is-active --quiet "$SERVICE_NAME"; then
    printf '%s\n' "$expected_unit" > "$UNIT_FILE"
    chmod 0600 "$UNIT_FILE"
    systemctl daemon-reload
    info "首次引导完成，已从 unit 中移除明文密码（后续以数据库哈希为准）"
  fi
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
  printf '  %s⚡ Emby 路径反代 v2.2.0%s  %s·%s  %s管理菜单%s\n' "$C_B" "$C_0" "$C_D" "$C_0" "$C_D" "$C_0"
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
      3) printf '\n'; if ! has_install; then warn "当前没有安装"; sleep 1; continue; fi; warn "卸载会删除：服务、程序、配置、管理密码、统计数据"; if ! ask_yes "   $C_R❯$C_0 输入 y 确认: [y/N]"; then info "已取消"; sleep 1; continue; fi; ( cmd_uninstall --yes ) || warn "卸载出错"; press_enter ;;
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
