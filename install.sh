#!/usr/bin/env bash
# =============================================================================
# Emby 路径反代 — 一键安装 / 管理脚本 (最终完美版)
# =============================================================================
set -euo pipefail

# ---------- 默认路径与版本 ----------
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

write_go_source() {
  local dir="$1"
  cat > "$dir/main.go" <<'GO_SOURCE'
package main

import (
	"bufio"
	"bytes"
	"container/list"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
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
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/phuslu/iploc"
	bolt "go.etcd.io/bbolt"
	"golang.org/x/sync/singleflight"
)

//go:embed admin.html
var adminHTML []byte

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

// ---------- 统一主题页面（首页 / 错误提示）----------
const pageCSS = `
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--d:#ef4444;--w:#f59e0b;--ok:#10b981;--r:16px}
body{min-height:100dvh;background:var(--bg);color:var(--t);font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:var(--r);padding:40px 36px;max-width:520px;width:100%;box-shadow:0 4px 24px -4px rgba(15,23,42,.06);text-align:center}
.icon{width:64px;height:64px;border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 auto 20px;font-size:28px}
.icon.blue{background:var(--ps);color:var(--p)}
.icon.red{background:#fef2f2;color:var(--d)}
.icon.amber{background:#fffbeb;color:var(--w)}
h1{font-size:22px;font-weight:700;letter-spacing:-.3px;margin-bottom:10px;color:var(--t)}
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
.brand{font-weight:600;color:var(--t2)}
@media(max-width:480px){.card{padding:28px 20px}h1{font-size:20px}}
`

func writePage(w http.ResponseWriter, status int, iconClass, icon, title, desc, extraHTML string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	html := `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>` + title + ` · Emby Proxy</title><style>` + pageCSS + `</style></head><body><div class="card"><div class="icon ` + iconClass + `">` + icon + `</div><h1>` + title + `</h1><div class="desc">` + desc + `</div>` + extraHTML + `<div class="foot"><span class="brand">Emby Proxy</span> · 路径反代网关</div></div></body></html>`
	_, _ = w.Write([]byte(html))
}

func serveHome(w http.ResponseWriter, r *http.Request) {
	extra := `
<div class="ex"><div class="ex-t">使用方式</div><code>/https://你的Emby域名:端口/路径</code></div>
<div class="ex" style="margin-bottom:28px"><div class="ex-t">示例</div><code>/https://emby.example.com:8096/web/index.html</code></div>
<div class="acts"><a class="btn b" href="/admin/">进入管理后台</a></div>`
	writePage(w, http.StatusOK, "blue", "⚡", "Emby 路径反代",
		"将请求按路径转发到指定上游服务，支持白名单、地区限制、限流与缓存加速。", extra)
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

func parseTarget(r *http.Request) (*url.URL, error) {
	raw := r.URL.EscapedPath()
	if raw == "" || raw == "/" {
		return nil, fmt.Errorf("请指定目标，格式: /https://域名/路径")
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
		return nil, fmt.Errorf("目标地址无效: %s", authority)
	}
	return u, nil
}

type Config struct {
	Port        int      `json:"port"`
	ChinaOnly   bool     `json:"china_only"`
	Whitelist   []string `json:"whitelist"`
	GeoAPI      bool     `json:"geo_api"`
	GeoAPIURL   string   `json:"geo_api_url"`
	BanList     []string `json:"ban_list"`
	AutoBan     bool     `json:"auto_ban"`
	RateLimit   int      `json:"rate_limit"`
	AllowedUAs  []string `json:"allowed_uas"`
	EnableCache bool     `json:"enable_cache"`
	CORS        bool     `json:"cors"`
}

// rateLimitEntry：每个 IP 一个限流窗口。
// 注意：Count/WindowStart 必须用 atomic 访问——sync.Map 返回的是共享指针，
// 并发请求同时读写会构成 data race（原实现直接 ++ 是有竞态的）。
type rateLimitEntry struct {
	Count       atomic.Int64
	WindowStart atomic.Int64 // UnixNano，窗口起始时间
}

var startedAt = time.Now()
var (
	db          *bolt.DB
	dbPath      string
	faviconData atomic.Pointer[[]byte] // 启动时后台预热，处理器只读，避免首次请求阻塞
	cfgPtr      atomic.Pointer[Config]
	proxyTr     = &switchTransport{}
	listenMu    sync.Mutex
	curLn       net.Listener
	curPort     int
	globalSrv   *http.Server

	ipLimiters sync.Map
	logClients sync.Map
	logChan    = make(chan string, 1000)
)

// ---------- 图片缓存：固定容量 LRU（替代原 sync.Map 整表清空方案） ----------
// 原实现每次写入都要 Range 全表统计大小（O(n)），满了直接替换 sync.Map（并发丢数据）。
// 这里改为 mutex + container/list 标准 LRU：超过条数/字节上限时只淘汰最旧条目。
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
}
func saveConfig(c *Config) error {
	if db == nil {
		return fmt.Errorf("db not ready")
	}
	b, _ := json.Marshal(c)
	return db.Update(func(tx *bolt.Tx) error {
		bk, err := tx.CreateBucketIfNotExists([]byte("config"))
		if err != nil {
			return err
		}
		return bk.Put([]byte("data"), b)
	})
}

// 说明： Transport 与配置无关（不走配置项），因此只在启动时创建一次。
// 原实现每次保存配置都 refreshRuntime() 重建 Transport，
// 会丢掉已建立的连接池 / TLS 会话缓存，导致保存后一段时间内所有请求重新握手。

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
type DayStat struct {
	Requests  int64            `json:"requests"`
	Bytes     int64            `json:"bytes"`
	BlockedCN int64            `json:"blocked_cn"`
	BlockedWL int64            `json:"blocked_wl"`
	Countries map[string]int64 `json:"countries,omitempty"`
	IPs       map[string]int64 `json:"ips,omitempty"`
	IPBytes   map[string]int64 `json:"ip_bytes,omitempty"`
}
type Stats struct {
	TodayDate        string              `json:"today_date"`
	TodayRequests    int64               `json:"today_requests"`
	TodayBytes       int64               `json:"today_bytes"`
	TotalRequests    int64               `json:"total_requests"`
	TotalBytes       int64               `json:"total_bytes"`
	BlockedCN        int64               `json:"blocked_cn"`
	BlockedWhitelist int64               `json:"blocked_whitelist"`
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
	Bytes   int64
	IsStart bool
}

var statChan = make(chan statEvent, 10000)

// statDropped：统计通道满时被丢弃的事件数（避免阻塞请求热路径，丢弃有损但可观测）
var statDropped atomic.Int64

// pruneTopN：当 map 超过 n 条时，仅保留值最大的前 n 条。
// 抽成泛型辅助函数，替代原 pruneStatsLocked 里 4 段几乎相同的裁剪代码。
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
		pruneTopN(day.IPs, 500)
		pruneTopN(day.IPBytes, 500)
	}
}

func startStatsWorker() {
	go func() {
		for ev := range statChan {
			statsMu.Lock()
			t := time.Now().Format("2006-01-02")
			if stats.TodayDate != t {
				stats.TodayDate = t
				stats.TodayRequests = 0
				stats.TodayBytes = 0
			}
			if ev.IsStart {
				stats.TotalRequests++
				stats.TodayRequests++
				stats.LastProxyAt = time.Now().UTC().Format(time.RFC3339)
				c := ev.Country
				if c == "" {
					c = "??"
				}
				stats.CountryCounts[c]++
				stats.IPCounts[ev.IP]++
				if stats.Daily == nil {
					stats.Daily = map[string]*DayStat{}
				}
				d := stats.Daily[t]
				if d == nil {
					d = &DayStat{Countries: map[string]int64{}, IPs: map[string]int64{}, IPBytes: map[string]int64{}}
					stats.Daily[t] = d
				}
				d.Requests++
				d.Countries[c]++
				d.IPs[ev.IP]++
			} else if ev.Bytes > 0 {
				stats.TotalBytes += ev.Bytes
				stats.TodayBytes += ev.Bytes
				if stats.Daily == nil {
					stats.Daily = map[string]*DayStat{}
				}
				d := stats.Daily[t]
				if d == nil {
					d = &DayStat{Countries: map[string]int64{}, IPs: map[string]int64{}, IPBytes: map[string]int64{}}
					stats.Daily[t] = d
				}
				d.Bytes += ev.Bytes
				if ev.IP != "" {
					stats.IPBytes[ev.IP] += ev.Bytes
					d.IPBytes[ev.IP] += ev.Bytes
				}
			}
			statsMu.Unlock()
		}
	}()
}

func recordRequestStart(ip, country string) {
	select {
	case statChan <- statEvent{IP: ip, Country: country, IsStart: true}:
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

func loadStats() {
	stats = Stats{TodayDate: time.Now().Format("2006-01-02"), CountryCounts: map[string]int64{}, IPCounts: map[string]int64{}, IPBytes: map[string]int64{}, Daily: map[string]*DayStat{}, Blocks: []BlockEvent{}}
	if db != nil {
		_ = db.View(func(tx *bolt.Tx) error {
			b := tx.Bucket([]byte("stats"))
			if b != nil {
				if data := b.Get([]byte("data")); data != nil {
					_ = json.Unmarshal(data, &stats)
				}
			}
			return nil
		})
	}
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
}
func saveStatsLocked() {
	if db == nil {
		return
	}
	b, _ := json.Marshal(stats)
	_ = db.Update(func(tx *bolt.Tx) error {
		bk, err := tx.CreateBucketIfNotExists([]byte("stats"))
		if err != nil {
			return err
		}
		return bk.Put([]byte("data"), b)
	})
}
func startStatsSaver() {
	go func() {
		t := time.NewTicker(5 * time.Minute)
		for range t.C {
			statsMu.Lock()
			pruneStatsLocked()
			saveStatsLocked()
			statsMu.Unlock()
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

var countryNames = map[string]string{"CN": "中国", "HK": "中国香港", "TW": "中国台湾", "MO": "中国澳门", "SG": "新加坡", "JP": "日本", "KR": "韩国", "US": "美国", "GB": "英国", "DE": "德国", "FR": "法国", "RU": "俄罗斯", "LO": "本机", "PV": "内网", "??": "未知"}

func countryName(code string) string {
	if n, ok := countryNames[code]; ok {
		return n
	}
	if code == "" {
		return "未知"
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
	d := time.Now().Format("2006-01-02")
	if stats.Daily == nil {
		stats.Daily = map[string]*DayStat{}
	}
	day := stats.Daily[d]
	if day == nil {
		day = &DayStat{Countries: map[string]int64{}, IPs: map[string]int64{}, IPBytes: map[string]int64{}}
		stats.Daily[d] = day
	}
	reasonText := "目标域名不在访问白名单内"
	if reason == "cn" {
		stats.BlockedCN++
		day.BlockedCN++
		reasonText = "仅允许中国大陆 IP 访问"
	} else {
		stats.BlockedWhitelist++
		day.BlockedWL++
	}
	if country == "" {
		country = "??"
	}
	ev := BlockEvent{Time: time.Now().UTC().Format(time.RFC3339), IP: ip, Country: country, Path: path, Reason: reason, ReasonText: reasonText, UA: ua}
	// 追加到尾部 + 超限时从头裁剪：均摊 O(1)。
	// 原实现 append([]BlockEvent{ev}, stats.Blocks...) 每次全量拷贝 5000 条，O(n)。
	stats.Blocks = append(stats.Blocks, ev)
	if len(stats.Blocks) > maxBlockEvents {
		stats.Blocks = stats.Blocks[len(stats.Blocks)-maxBlockEvents:]
	}
}

// maxBlockEvents：内存/落盘中保留的拦截事件上限
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

// geoPrune：定期清理 geoMap。
// 原实现 30 天过期但从不删除内存条目，公网代理长期运行会积累数十万条目造成内存泄漏。
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

func logSSE(msg string) {
	select {
	case logChan <- msg:
	default:
	}
}
func broadcastLog() {
	for msg := range logChan {
		logClients.Range(func(k, v interface{}) bool {
			ch := v.(chan string)
			select {
			case ch <- msg:
			default:
			}
			return true
		})
	}
}
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

func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if validSession(getSessionToken(r)) {
			next(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/admin/api/") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"未登录","redirect":"/admin/login"}`))
			return
		}
		http.Redirect(w, r, "/admin/login", http.StatusFound)
	}
}

const loginHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
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
    <div class="brand-icon">⚡</div>
    <h1>Emby Proxy</h1>
    <p>管理后台登录</p>
  </div>
  <div class="err" id="errBox"></div>
  <form id="loginForm" autocomplete="on">
    <div class="fi">
      <label class="fl" for="user">用户名</label>
      <input class="inp" id="user" name="username" type="text" autocomplete="username" required placeholder="请输入用户名">
    </div>
    <div class="fi">
      <label class="fl" for="pass">密码</label>
      <input class="inp" id="pass" name="password" type="password" autocomplete="current-password" required placeholder="请输入密码">
    </div>
    <div class="fi">
      <label class="fl" for="captcha">验证码</label>
      <div class="cap-row">
        <input class="inp" id="captcha" name="captcha" type="text" autocomplete="off" required placeholder="点击图片刷新" maxlength="6">
        <img class="cap-img" id="capImg" alt="验证码" title="点击刷新">
      </div>
    </div>
    <button type="submit" class="btn" id="submitBtn">登 录</button>
  </form>
  <div class="foot">Emby Proxy · 路径反代网关</div>
</div>
<script>
let captchaId = '';
async function loadCaptcha() {
  try {
    const r = await fetch('/admin/api/captcha?t=' + Date.now(), {cache:'no-store'});
    if (!r.ok) throw new Error('加载失败');
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
      errBox.textContent = data.error || '登录失败';
      errBox.classList.add('on');
      document.getElementById('captcha').value = '';
      loadCaptcha();
      return;
    }
    location.href = '/admin/';
  } catch(err) {
    errBox.textContent = '网络错误，请重试';
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
}

func (w *statWriter) Write(b []byte) (int, error) {
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
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
		w.bytes += n
		return n, err
	}
	n, err := io.Copy(w.ResponseWriter, r)
	w.bytes += n
	return n, err
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
}

func (r *statReadCloser) Read(p []byte) (int, error) {
	n, err := r.ReadCloser.Read(p)
	if n > 0 {
		atomic.AddInt64(r.bytes, int64(n))
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
			if upPtr, ok := pr.In.Context().Value(upBytesCtxKey{}).(*int64); ok && pr.In.Body != nil && pr.In.Body != http.NoBody {
				pr.Out.Body = &statReadCloser{ReadCloser: pr.In.Body, bytes: upPtr}
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
			msg := "上游服务暂时不可达，请稍后重试。"
			if err != nil {
				msg += "<br><span style=\"font-size:12px;color:#94a3b8;font-family:Consolas,monospace\">" + strings.ReplaceAll(strings.ReplaceAll(err.Error(), "<", "&lt;"), ">", "&gt;") + "</span>"
			}
			serveError(w, http.StatusBadGateway, "无法连接目标", msg)
		},
	}
}

type adminConfigResp struct {
	Config
	EffectivePort int `json:"effective_port"`
}

func adminHandler() http.HandlerFunc {
	mux := http.NewServeMux()

	mux.HandleFunc("/admin/login", func(w http.ResponseWriter, r *http.Request) {
		if validSession(getSessionToken(r)) {
			http.Redirect(w, r, "/admin/", http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(loginHTML))
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
			http.Error(w, "不支持", http.StatusMethodNotAllowed)
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
			_, _ = w.Write([]byte(`{"error":"参数错误"}`))
			return
		}
		if !verifyCaptcha(req.CaptchaID, req.Captcha) {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"验证码错误或已过期"}`))
			return
		}
		u, p := getAdminCred()
		if subtle.ConstantTimeCompare([]byte(req.Username), []byte(u)) != 1 ||
			subtle.ConstantTimeCompare([]byte(req.Password), []byte(p)) != 1 {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"用户名或密码错误"}`))
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
			http.Error(w, "不支持", http.StatusMethodNotAllowed)
			return
		}
		// 复用 Config 结构体（与 saveReq 字段完全一致，去掉重复定义）
		var req Config
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "参数错误", http.StatusBadRequest)
			return
		}
		req.GeoAPIURL = strings.TrimSpace(req.GeoAPIURL)
		oldCfg := currentCfg()
		newCfg := &req
		if err := saveConfig(newCfg); err != nil {
			http.Error(w, "保存失败", http.StatusInternalServerError)
			return
		}
		cfgPtr.Store(newCfg)
		if newCfg.Port > 0 && newCfg.Port != currentPort() && globalSrv != nil {
			if err := startListen(globalSrv, newCfg.Port); err != nil {
				// 端口切换失败：回滚配置。Transport 与配置无关，无需重建。
				cfgPtr.Store(oldCfg)
				_ = saveConfig(oldCfg)
				http.Error(w, "端口监听失败", http.StatusBadRequest)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *newCfg, EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/logs", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "SSE 不支持", http.StatusInternalServerError)
			return
		}
		ch := make(chan string, 100)
		logClients.Store(ch, ch)
		defer logClients.Delete(ch)
		for {
			select {
			case msg := <-ch:
				fmt.Fprintf(w, "data: %s\n\n", msg)
				flusher.Flush()
			case <-r.Context().Done():
				return
			}
		}
	})
	mux.HandleFunc("/admin/api/traffic", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		ips := make(map[string]int64, len(stats.IPCounts))
		for k, v := range stats.IPCounts {
			ips[k] = v
		}
		ipBytes := make(map[string]int64, len(stats.IPBytes))
		for k, v := range stats.IPBytes {
			ipBytes[k] = v
		}
		ctry := make(map[string]int64, len(stats.CountryCounts))
		for k, v := range stats.CountryCounts {
			ctry[k] = v
		}

		type TrendItem struct {
			Date      string `json:"date"`
			Requests  int64  `json:"requests"`
			Bytes     int64  `json:"bytes"`
			BlockedCN int64  `json:"blocked_cn"`
			BlockedWL int64  `json:"blocked_whitelist"`
		}
		var trend []TrendItem
		for k, d := range stats.Daily {
			if d != nil {
				trend = append(trend, TrendItem{Date: k, Requests: d.Requests, Bytes: d.Bytes, BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL})
			}
		}
		sort.Slice(trend, func(i, j int) bool { return trend[i].Date < trend[j].Date })
		todayReqs, todayBytes := int64(0), int64(0)
		if d := stats.Daily[time.Now().Format("2006-01-02")]; d != nil {
			todayReqs, todayBytes = d.Requests, d.Bytes
		}

		labels := map[string]string{}
		for code := range ctry {
			labels[code] = countryName(code)
		}

		reqs, byts := stats.TotalRequests, stats.TotalBytes
		cn, wl := stats.BlockedCN, stats.BlockedWhitelist
		statsMu.Unlock()

		_ = json.NewEncoder(w).Encode(map[string]any{
			"today": time.Now().Format("2006-01-02"), "requests": reqs, "bytes": byts,
			"blocked_cn": cn, "blocked_whitelist": wl,
			"ip_counts": ips, "ip_bytes": ipBytes, "country_counts": ctry, "country_labels": labels,
			"today_requests": todayReqs, "today_bytes": todayBytes, "trend": trend,
			"uptime_sec":   int64(time.Since(startedAt).Seconds()),
			"stat_dropped": statDropped.Load(), // 统计事件因通道满被丢弃的数量（有损观测）
		})
	})
	mux.HandleFunc("/admin/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		// recordBlocked 现在是按时间正序追加存储的，这里倒序输出（最新在前）保持前端展示不变
		matched := make([]BlockEvent, len(stats.Blocks))
		copy(matched, stats.Blocks)
		statsMu.Unlock()
		for i, j := 0, len(matched)-1; i < j; i, j = i+1, j-1 {
			matched[i], matched[j] = matched[j], matched[i]
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"total": len(matched), "items": matched})
	})
	mux.HandleFunc("/admin/api/ip-detail", func(w http.ResponseWriter, r *http.Request) {
		ip := strings.TrimSpace(r.URL.Query().Get("ip"))
		if ip == "" || net.ParseIP(ip) == nil {
			http.Error(w, "IP 无效", http.StatusBadRequest)
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
			http.Error(w, "新密码至少 6 位", http.StatusBadRequest)
			return
		}
		_, pass := getAdminCred()
		if subtle.ConstantTimeCompare([]byte(req.OldPass), []byte(pass)) != 1 {
			http.Error(w, "旧密码错误", http.StatusForbidden)
			return
		}
		_ = saveAdminPassFile(req.NewPass)
		setAdminCred("admin", req.NewPass)
		w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/admin/api/clear-stats", func(w http.ResponseWriter, r *http.Request) {
		statsMu.Lock()
		stats = Stats{TodayDate: time.Now().Format("2006-01-02"), CountryCounts: map[string]int64{}, IPCounts: map[string]int64{}, IPBytes: map[string]int64{}, Daily: map[string]*DayStat{}, Blocks: []BlockEvent{}}
		saveStatsLocked()
		statsMu.Unlock()
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
	mux.HandleFunc("/admin/api/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		html := strings.Replace(string(adminHTML), "<head>", "<head>\n<link rel=\"icon\" href=\"/favicon.ico\" type=\"image/png\">\n", 1)
		_, _ = w.Write([]byte(html))
	})
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if path == "/admin/login" || path == "/admin/api/captcha" || path == "/admin/api/login" || path == "/admin/api/logout" {
			mux.ServeHTTP(w, r)
			return
		}
		requireAuth(mux.ServeHTTP)(w, r)
	}
}

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
	startStatsSaver()
	go broadcastLog()
	detectSelfPublicIP()
	// favicon 改为启动时后台预热：
	// 原实现 faviconOnce.Do 在【第一个请求的处理器里】同步外网 GET（4s 超时），
	// 会把第一个请求卡住数秒。现在启动即拉取，处理器直接读内存。
	go func() {
		resp, err := http.Get("https://i.ibb.co/99QbT1X3/icons8-64.png")
		if err == nil && resp.StatusCode == 200 {
			if data, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024)); err == nil {
				faviconData.Store(&data)
			}
		}
		if resp != nil {
			resp.Body.Close()
		}
	}()
	defer func() { statsMu.Lock(); saveStatsLocked(); statsMu.Unlock(); geoCacheSave() }()

	proxy := buildProxy(proxyTr)
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/favicon.ico" || r.URL.Path == "/favicon.png" || r.URL.Path == "/favicon.svg" {
			// 读启动时预热的缓存；未预热完成则直接 302 到源站，不阻塞请求
			if p := faviconData.Load(); p != nil {
				w.Header().Set("Content-Type", "image/png")
				w.Header().Set("Cache-Control", "public, max-age=86400")
				_, _ = w.Write(*p)
				return
			}
			http.Redirect(w, r, "https://i.ibb.co/99QbT1X3/icons8-64.png", http.StatusFound)
			return
		}
		if isBuiltinAssetPath(r.URL.Path) {
			serveError(w, http.StatusNotFound, "页面不存在", "请求的资源未找到。")
			return
		}
		if r.URL.Path == "/" || r.URL.Path == "" {
			serveHome(w, r)
			return
		}
		ip := getClientIP(r)
		c := currentCfg()

		// 黑名单 & 限流 & UA
		isBanned := false
		clientIP := net.ParseIP(ip)
		for _, b := range c.BanList {
			b = strings.TrimSpace(b)
			if b == "" {
				continue
			}
			if b == ip {
				isBanned = true
				break
			}
			if strings.Contains(b, "/") {
				if _, ipnet, err := net.ParseCIDR(b); err == nil && clientIP != nil && ipnet.Contains(clientIP) {
					isBanned = true
					break
				}
			}
		}
		if isBanned {
			serveError(w, http.StatusForbidden, "访问被拒绝", "您的 IP 已被加入黑名单，无法继续访问。")
			return
		}
		if !checkRateLimit(ip, c.RateLimit) {
			serveError(w, http.StatusTooManyRequests, "请求过于频繁", "当前请求频率超过限制，请稍后再试。")
			return
		}
		if len(c.AllowedUAs) > 0 {
			ua := strings.ToLower(r.UserAgent())
			ok := false
			for _, u := range c.AllowedUAs {
				if u != "" && strings.Contains(ua, strings.ToLower(u)) {
					ok = true
					break
				}
			}
			if !ok {
				serveError(w, http.StatusForbidden, "UA 不被允许", "当前客户端 User-Agent 不在白名单内。")
				return
			}
		}

		country, _ := ipLabelSync(ip)
		if c.ChinaOnly && country != "CN" && country != "LO" && country != "PV" {
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
						} // 已存在，无需重复添加
					}
					nc := *old
					nc.BanList = append(append([]string{}, old.BanList...), banIP)
					if err := saveConfig(&nc); err != nil {
						return
					}
					cfgPtr.Store(&nc)
				}(ip)
			}
			serveError(w, http.StatusForbidden, "地区限制", "当前仅允许中国大陆 IP 访问本服务。")
			return
		}

		target, err := parseTarget(r)
		if err != nil {
			serveHome(w, r)
			return
		}
		if !whitelistMatch(c.Whitelist, target.Host) {
			recordBlocked(ip, country, r.URL.RequestURI(), "whitelist", r.UserAgent())
			serveError(w, http.StatusForbidden, "域名不在白名单", "目标域名未被授权，请联系管理员添加白名单。")
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

		logSSE(fmt.Sprintf("[%s] %s %s -> %s", ip, r.Method, r.URL.Path, target.Host))
		recordRequestStart(ip, country)

		// 只有“缓存候选请求”才包 cacheRecorder（小内存缓冲 + 状态码记录），
		// 其余请求零额外内存开销（原实现所有请求都被 MultiWriter 全量复制到内存）。
		sw := &statWriter{ResponseWriter: w}
		var w2 http.ResponseWriter = sw
		if c.EnableCache && strings.Contains(r.URL.Path, "/Images/") && r.Method == "GET" {
			rec := &cacheRecorder{statWriter: sw, buf: &bytes.Buffer{}}
			w2 = rec
		}

		upBytes := new(int64)
		ctx := context.WithValue(r.Context(), targetCtxKey{}, target)
		ctx = context.WithValue(ctx, upBytesCtxKey{}, upBytes)

		proxy.ServeHTTP(w2, r.WithContext(ctx))

		if r2, ok := w2.(*cacheRecorder); ok && r2.status == http.StatusOK && r2.buf != nil && r2.buf.Len() > 0 {
			imageCachePut(r.URL.String(), r2.buf.Bytes())
		}
		recordBytes(ip, sw.bytes+atomic.LoadInt64(upBytes))
	})

	adminSrv := adminHandler()
	root := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/admin" {
			http.Redirect(w, r, "/admin/", http.StatusFound)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/admin/") {
			adminSrv.ServeHTTP(w, r)
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
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Emby Proxy</title>
<script src="https://cdn.bootcdn.net/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
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
.table-wrap{overflow-x:auto;border-radius:8px;border:1px solid var(--bd)}
table{width:100%;border-collapse:collapse;text-align:left;min-width:600px}
th{padding:14px 16px;border-bottom:1px solid var(--bd);font-size:12.5px;font-weight:600;color:var(--t2);background:#f8fafc;white-space:nowrap}
td{padding:14px 16px;border-bottom:1px solid var(--bd);font-size:13.5px;color:var(--t2)}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover td{background:#f8fafc}
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
  .tb{padding:0 16px;height:60px}
  .tb-t{font-size:16px}
  .sc{padding:16px}
  .card{padding:18px;border-radius:12px;margin-bottom:16px}
  .sg{grid-template-columns:1fr;gap:12px;margin-bottom:16px}
  .stc{padding:16px}
  .sv{font-size:24px}
  .flt{width:100%;justify-content:space-between}
  .filter{padding:6px 10px;font-size:12px;flex:1;text-align:center}
  .dn{width:90px;font-size:12px}
  .dv{width:60px;font-size:12px}
  
  .table-wrap{border:0;overflow:visible}
  table, thead, tbody, th, td, tr{display:block}
  th{display:none}
  tr{border:1px solid var(--bd);border-radius:10px;margin-bottom:12px;padding:8px 0;background:#fff}
  td{display:flex;justify-content:space-between;align-items:center;padding:8px 16px;border:0;font-size:13px}
  td::before{content:attr(data-label);font-weight:600;color:var(--t3);font-size:12.5px;margin-right:16px;flex-shrink:0}
  td>span, td>div, td>img{text-align:right;word-break:break-all}
  td[data-label="访问路径"]{flex-direction:column;align-items:flex-start;gap:4px}
  td[data-label="访问路径"]>span{text-align:left;white-space:normal}
  
  .mo{padding:12px}
  .mbox{max-height:95dvh}
  .mh{padding:16px 20px}
  .mb{padding:20px}
}
</style>
</head>
<body>
<button class="sb-mask" id="sbMask" aria-label="关闭菜单"></button>
<aside class="sb" id="sb">
<div class="sb-h" style="display:flex;align-items:center">
  <div class="sb-brand-icon">⚡</div>
  <div class="sb-brand"><div class="sb-t">Emby Proxy</div><div class="sb-sub">管理后台</div></div>
</div>
<ul class="nav">
<li><button class="nav-i on" data-t="overview"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>概览</button></li>
<li><button class="nav-i" data-t="traffic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 14l4-4 4 4 5-6"/></svg>流量与请求</button></li>
<li><button class="nav-i" data-t="blocks"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/></svg>拦截记录</button></li>
<li><button class="nav-i" data-t="logs"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>实时日志</button></li>
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
<div class="stc r"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/></svg>拦截次数</div><div class="sv" id="ovBlocked" style="color:var(--d)">-</div><div class="ss">大陆限制 <b id="ovBlockedCN">0</b></div></div>
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
<div class="card">
<div class="ch"><div><h2 class="ct">请求量趋势</h2><div class="cd">每天的请求次数变化</div></div></div>
<div style="position:relative;height:250px"><canvas id="reqChart"></canvas></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct">流量消耗趋势</h2><div class="cd">每天的上下行总流量</div></div></div>
<div style="position:relative;height:250px"><canvas id="byteChart"></canvas></div>
</div>
<div class="g2" style="margin-top:22px">
<div class="card"><div class="ch"><div><h2 class="ct">请求 IP 排行</h2><div class="cd">点击可查看详细地理位置与流量</div></div></div><div id="ipDist"></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">地区来源分布</h2><div class="cd">按独立 IP 归属地统计</div></div></div><div id="regionDist"></div></div>
</div>
</section>
<section id="blocks" class="pg">
<div class="card">
<div class="ch"><div><h2 class="ct">拦截记录</h2><div class="cd">触发黑名单、限制或异常访问的请求</div></div></div>
<div class="table-wrap"><table><thead><tr><th>时间</th><th>IP 地址</th><th>国家/地区</th><th>拦截原因</th><th>访问路径</th></tr></thead><tbody id="blockTable"></tbody></table></div>
</div>
</section>
<section id="logs" class="pg">
<div class="card">
<div class="ch"><div><h2 class="ct">实时访问日志</h2><div class="cd">所有成功代理经过本网关的请求</div></div><button class="btn g" id="clearLogBtn">清空</button></div>
<div id="logTerminal" style="background:#0f172a;color:#a7f3d0;font-family:var(--mono);font-size:12px;height:500px;overflow-y:auto;border-radius:8px;padding:16px;line-height:1.6;white-space:pre-wrap;"></div>
</div>
</section>
<section id="settings" class="pg">
<div class="g2">
  <div style="display:flex;flex-direction:column;gap:24px;">
    <div class="card" style="margin-bottom:0;">
      <div class="ch"><div><h2 class="ct">基础服务设置</h2></div></div>
      <div class="fi"><label class="fl">监听端口</label><div style="display:flex;gap:12px;align-items:center"><input id="portInput" class="inp m" type="number" style="max-width:140px"><button class="btn b" id="savePort">保存并重启监听</button></div></div>
      <div class="row"><div><div class="rl">开启 CORS 跨域</div><div class="rd">解决部分网页播放器拉流报错</div></div><label class="sw"><input type="checkbox" id="corsToggle"><span class="tr2"></span></label></div>
      <div class="row"><div><div class="rl">自动缓存海报资源</div><div class="rd">缓存 Emby 图片，大幅降低上游压力</div></div><label class="sw"><input type="checkbox" id="cacheToggle"><span class="tr2"></span></label></div>
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
      <div class="row" style="margin-top:20px"><div><div class="rl" style="color:var(--d)">清空所有统计数据</div><div class="rd">不可恢复，包含请求、流量、拦截记录</div></div><button class="btn d" id="clearStatsBtn">立即清空</button></div>
    </div>
  </div>
  
  <div class="card" style="margin-bottom:0;">
    <div class="ch"><div><h2 class="ct">安全与访问控制</h2></div></div>
    <div class="row"><div><div class="rl">仅允许中国大陆 IP 访问</div></div><label class="sw"><input type="checkbox" id="chinaOnly"><span class="tr2"></span></label></div>
    <div class="row"><div><div class="rl">自动封禁异常 IP</div><div class="rd">触发限制或白名单时自动拉黑</div></div><label class="sw"><input type="checkbox" id="autoBan"><span class="tr2"></span></label></div>
    <div class="fi" style="margin-top:14px"><label class="fl">防 CC 限流（次/分钟，0=关闭）</label><input id="rateLimit" type="number" class="inp m" placeholder="例如 120"></div>
    <div class="fi"><label class="fl">UA 白名单（每行一个关键字，留空不限）</label><textarea id="allowedUAs" class="tarea" placeholder="Infuse&#10;Emby"></textarea></div>
    <div class="fi"><label class="fl">域名白名单（每行一个，支持根域名）</label><textarea id="whitelist" class="tarea" placeholder="example.com"></textarea></div>
    <div class="fi"><label class="fl">IP 黑名单（每行一个，支持 CIDR）</label><textarea id="banList" class="tarea" placeholder="1.1.1.1"></textarea></div>
    <div class="acts"><button class="btn b" id="saveAll" style="width:100%">保存安全设置</button></div>
  </div>
</div>
</section>
</div>
</div>
<div class="mo" id="modal"><div class="mbox"><div class="mh"><h3 id="modalTitle">记录详情</h3><button class="mcl" id="modalClose">×</button></div><div class="mb" id="modalBody"></div></div></div>
<script>
const state={port:0,labels:{},ovRange:'today'};
let ovTrendData=[];

function fmtBytes(b){if(!b)return '0 B';if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB'}
const pageTitles={overview:'概览',traffic:'流量与请求',blocks:'拦截记录',logs:'实时日志',settings:'网关设置'};
function switchTab(id){document.querySelectorAll('.nav-i').forEach(b=>b.classList.toggle('on',b.dataset.t===id));document.querySelectorAll('.pg').forEach(el=>el.classList.toggle('on',el.id===id));document.getElementById('pt').textContent=pageTitles[id]||'';if(window.innerWidth<=1024)closeSidebar();if(id==='overview')loadOverview();if(id==='traffic')loadTraffic();if(id==='blocks')loadBlocks();if(id==='logs')connectLogs();else if(logSource){logSource.close();logSource=null}}
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
    document.getElementById('chinaOnly').checked=!!c.china_only;document.getElementById('corsToggle').checked=!!c.cors;document.getElementById('cacheToggle').checked=!!c.enable_cache;
    document.getElementById('whitelist').value=(c.whitelist||[]).join('\n');document.getElementById('banList').value=(c.ban_list||[]).join('\n');document.getElementById('autoBan').checked=!!c.auto_ban;
    document.getElementById('rateLimit').value=c.rate_limit||0;document.getElementById('allowedUAs').value=(c.allowed_uas||[]).join('\n');
  }catch(e){console.error('loadConfig error:',e)}
}

let miniTrendChart=null,reqChart=null,byteChart=null;

function updateOvStats() {
  if (!ovTrendData.length) return;
  const today = new Date();
  const tzOffset = today.getTimezoneOffset() * 60000;
  const localISOTime = (new Date(today - tzOffset)).toISOString().slice(0,10);
  const yesterday = new Date(today); yesterday.setDate(today.getDate() - 1);
  const yISOTime = (new Date(yesterday - tzOffset)).toISOString().slice(0,10);

  let filterFn = () => true;
  if (state.ovRange === 'today') filterFn = d => d.date === localISOTime;
  else if (state.ovRange === 'yesterday') filterFn = d => d.date === yISOTime;
  else if (state.ovRange === '7d') {
    const d7 = new Date(today); d7.setDate(today.getDate() - 6);
    const d7Str = (new Date(d7 - tzOffset)).toISOString().slice(0,10);
    filterFn = d => d.date >= d7Str;
  } else if (state.ovRange === '30d') {
    const d30 = new Date(today); d30.setDate(today.getDate() - 29);
    const d30Str = (new Date(d30 - tzOffset)).toISOString().slice(0,10);
    filterFn = d => d.date >= d30Str;
  }
  
  const filtered = ovTrendData.filter(filterFn);
  let reqs = 0, bytes = 0, bCN = 0, bWL = 0;
  filtered.forEach(d => {
    reqs += d.requests || 0;
    bytes += d.bytes || 0;
    bCN += d.blocked_cn || 0;
    bWL += d.blocked_whitelist || 0;
  });
  
  const days = filtered.length || 1;
  document.getElementById('ovReq').textContent = reqs.toLocaleString();
  document.getElementById('ovBytes').textContent = fmtBytes(bytes);
  document.getElementById('ovAvgReq').textContent = Math.round(reqs/days).toLocaleString();
  document.getElementById('ovAvgBytes').textContent = fmtBytes(Math.round(bytes/days));
  document.getElementById('ovBlocked').textContent = (bCN + bWL).toLocaleString();
  document.getElementById('ovBlockedCN').textContent = bCN.toLocaleString();
}

async function loadOverview(){
  try{
    const r=await fetch('/admin/api/traffic',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    document.getElementById('uniqueIPs').textContent=Object.keys(t.ip_counts||{}).length.toLocaleString();
    ovTrendData = t.trend || [];
    renderMiniTrend(ovTrendData);
    updateOvStats();
    
    const r2=await fetch('/admin/api/blocks',{cache:'no-store'});
    if(r2.ok){const b=await r2.json();renderOvBlocks(b.items||[]);}
    
    const r3=await fetch('/admin/api/config',{cache:'no-store'});
    if(r3.ok){const c=await r3.json();renderSysInfo(c, t.uptime_sec||0);}
  }catch(e){console.error('loadOverview error:',e)}
}

function renderSysInfo(c, uptime){
  let fw = "已开启"; if(!c.ban_list?.length && !c.china_only && !c.rate_limit) fw="基础模式";
  const html = `
  <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px dashed #eee"><span style="color:#94a3b8">运行时长</span><span>${Math.floor(uptime/3600)} 小时</span></div>
  <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px dashed #eee"><span style="color:#94a3b8">防护状态</span><span style="color:var(--ok)">${fw}</span></div>
  <div style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px dashed #eee"><span style="color:#94a3b8">白名单</span><span>${c.whitelist?.length||0} 个域名</span></div>
  <div style="display:flex;justify-content:space-between;padding:8px 0"><span style="color:#94a3b8">缓存加速</span><span>${c.enable_cache?"已开启":"已关闭"}</span></div>
  `;
  document.getElementById('sysInfo').innerHTML = html;
}

function renderMiniTrend(trend){const cv=document.getElementById('miniTrendChart');if(!cv || typeof Chart==='undefined')return;const data=(trend||[]).slice(-7);if(!data.length)return;const labels=data.map(d=>(d.date||'').slice(5)),reqs=data.map(d=>d.requests||0);
if(miniTrendChart){miniTrendChart.data.labels=labels;miniTrendChart.data.datasets[0].data=reqs;miniTrendChart.update('none');return}
miniTrendChart=new Chart(cv,{type:'line',data:{labels,datasets:[{label:'请求',data:reqs,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.1)',borderWidth:2,fill:true,tension:0.35,pointRadius:3}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{grid:{display:false}},y:{beginAtZero:true,grid:{borderDash:[4,4]}}}}})}

// esc：HTML 转义。拦截记录的 ip/path/ua 等字段来自外部可控输入，
// 直接拼进 innerHTML 存在存储型 XSS 风险，展示前必须转义。
const esc = s => String(s==null?'':s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

function renderOvBlocks(items){
  const box=document.getElementById('ovBlocks');
  if(!items.length){box.innerHTML='<div class="emp"><b>暂无记录</b></div>';return}
  box.innerHTML=items.slice(0,5).map(b=>`<div style="display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid #f1f5f9;font-size:13px">
    <div><span style="font-family:var(--mono);color:#3b82f6;font-weight:600">${esc(b.ip)}</span><br><span class="pill pw" style="margin-top:4px">${b.reason==='cn'?'大陆限制':'白名单'}</span></div>
    <div style="color:#94a3b8;font-size:12px">${(b.time||'').slice(11,19)}</div>
  </div>`).join('');
}

async function loadTraffic(){
  try{
    const r=await fetch('/admin/api/traffic',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    if(t.country_labels) state.labels = t.country_labels;
    renderReqChart(t.trend||[]); renderByteChart(t.trend||[]);
    renderIP(t.ip_counts||{}, t.ip_bytes||{});
    renderRegion(t.country_counts||{});
  }catch(e){console.error('loadTraffic error:',e)}
}

function renderReqChart(td){const cv=document.getElementById('reqChart');if(!cv || typeof Chart==='undefined')return;const labels=td.map(d=>d.date),dr=td.map(d=>d.requests);
if(reqChart){reqChart.data.labels=labels;reqChart.data.datasets[0].data=dr;reqChart.update();return}
reqChart=new Chart(cv,{type:'bar',data:{labels,datasets:[{label:'请求数',data:dr,backgroundColor:'#10b981',borderRadius:4}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{x:{grid:{display:false}},y:{beginAtZero:true,grid:{borderDash:[4,4]}}}}})}
function renderByteChart(td){const cv=document.getElementById('byteChart');if(!cv || typeof Chart==='undefined')return;const labels=td.map(d=>d.date),db=td.map(d=>d.bytes);
if(byteChart){byteChart.data.labels=labels;byteChart.data.datasets[0].data=db;byteChart.update();return}
byteChart=new Chart(cv,{type:'line',data:{labels,datasets:[{label:'流量',data:db,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.15)',fill:true,tension:0.3,pointRadius:3}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false},tooltip:{callbacks:{label:c=>fmtBytes(c.parsed.y)}}},scales:{x:{grid:{display:false}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{callback:v=>fmtBytes(v)}}}}})}

function renderIP(map,bytesMap){
  const rows=Object.entries(map).sort((a,b)=>b[1]-a[1]).slice(0,20);
  const box=document.getElementById('ipDist');
  if(!rows.length){box.innerHTML='<div class="emp"><b>暂无数据</b></div>';return}
  const max=rows[0][1]||1;
  box.innerHTML=rows.map(([ip,n])=>{
    return `<div class="dr ip-row" data-ip="${esc(ip)}" style="cursor:pointer" title="点击查看详情"><span class="dn m"><span class="tx" style="color:var(--pd)">${esc(ip)}</span></span><div class="bar i"><i style="width:${(n/max*100).toFixed(1)}%"></i></div><span class="dv">${n.toLocaleString()}<span>次</span></span></div>`;
  }).join('');
  box.querySelectorAll('.ip-row').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
}

function renderRegion(map){
  const rows=Object.entries(map).sort((a,b)=>b[1]-a[1]).slice(0,20);
  const box=document.getElementById('regionDist');
  if(!rows.length){box.innerHTML='<div class="emp"><b>暂无数据</b></div>';return}
  const total=rows.reduce((s,r)=>s+r[1],0)||1,max=rows[0][1]||1;
  box.innerHTML=rows.map(([code,n])=>{
    const nm=state.labels[code]||code;
    return `<div class="dr"><span class="dn" title="${nm}"><img class="flg" src="/admin/api/flag/${code.toLowerCase()}" onerror="this.style.display='none'"> <span class="tx">${nm}</span></span><div class="bar t"><i style="width:${(n/max*100).toFixed(1)}%"></i></div><span class="dv">${n.toLocaleString()}<span>${(n/total*100).toFixed(0)}%</span></span></div>`;
  }).join('');
}

async function showIPDetail(ip){
  if(!ip)return;
  document.getElementById('modalTitle').textContent='IP 详情';
  document.getElementById('modalBody').innerHTML='<div style="color:var(--t3);font-size:13px;padding:12px 0">加载中…</div>';
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
    document.getElementById('modalBody').innerHTML='<div style="color:var(--d);font-size:13px">加载失败：'+esc(e.message)+'</div>';
  }
}

async function loadBlocks(){
  try{
    const r=await fetch('/admin/api/blocks',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    const tb=document.getElementById('blockTable');
    if(!t.items.length){tb.innerHTML='<tr><td colspan="5"><div class="emp"><b>暂无拦截记录</b></div></td></tr>';return}
    tb.innerHTML=t.items.map(b=>`<tr>
      <td data-label="时间" style="font-family:var(--mono);font-size:12px;color:#94a3b8">${(b.time||'').replace('T',' ').slice(0,19)}</td>
      <td data-label="IP 地址" style="font-family:var(--mono);font-weight:600"><span class="ip-link" data-ip="${esc(b.ip)}" style="color:var(--pd);text-decoration:underline;cursor:pointer">${esc(b.ip)}</span></td>
      <td data-label="地区"><span><img class="flg" src="/admin/api/flag/${(b.country||'??').toLowerCase()}" onerror="this.style.display='none'"> ${esc(b.country)}</span></td>
      <td data-label="拦截原因"><span class="pill ${b.reason==='cn'?'pc':'pw'}">${b.reason==='cn'?'大陆限制':'未授权白名单'}</span></td>
      <td data-label="访问路径"><span style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(b.path)}">${esc(b.path)}</span></td>
    </tr>`).join('');
    tb.querySelectorAll('.ip-link').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
  }catch(e){console.error('loadBlocks error:',e)}
}

let logSource=null;
function connectLogs(){if(logSource)logSource.close();const term=document.getElementById('logTerminal');if(!term)return;
logSource=new EventSource('/admin/api/logs');
logSource.onmessage=function(e){const time=new Date().toLocaleTimeString();term.innerHTML+='['+time+'] '+e.data+'\n';term.scrollTop=term.scrollHeight;
if(term.innerHTML.length>50000)term.innerHTML=term.innerHTML.slice(-30000)}}
document.getElementById('clearLogBtn').addEventListener('click',()=>{document.getElementById('logTerminal').innerHTML=''});

function collect(){
  const raw=parseInt(document.getElementById('portInput').value,10);
  return{port:isNaN(raw)?0:raw,china_only:document.getElementById('chinaOnly').checked,whitelist:document.getElementById('whitelist').value.split('\n').map(x=>x.trim()).filter(Boolean),geo_api:true,ban_list:document.getElementById('banList').value.split('\n').map(x=>x.trim()).filter(Boolean),auto_ban:document.getElementById('autoBan').checked,rate_limit:parseInt(document.getElementById('rateLimit').value,10)||0,allowed_uas:document.getElementById('allowedUAs').value.split('\n').map(x=>x.trim()).filter(Boolean),enable_cache:document.getElementById('cacheToggle').checked,cors:document.getElementById('corsToggle').checked}
}
async function save(){
  try{
    const r=await fetch('/admin/api/save',{method:'POST',body:JSON.stringify(collect())});
    if(!r.ok)throw new Error(await r.text());
    const c=await r.json();applyPort(c.effective_port);alert('配置保存成功！');
  }catch(e){alert('保存失败: '+e.message)}
}
document.getElementById('savePort').addEventListener('click',save);document.getElementById('saveAll').addEventListener('click',save);

document.getElementById('changePassBtn').addEventListener('click',async()=>{
  const o=document.getElementById('oldPass').value,n=document.getElementById('newPass').value;
  if(!o||!n||n.length<6){alert('新密码至少6位且不能为空');return}
  const r=await fetch('/admin/api/change-password',{method:'POST',body:JSON.stringify({OldPass:o,NewPass:n})});
  if(r.ok){alert('密码已修改，请重新登录');location.reload()}else{alert('修改失败：'+await r.text())}
});
document.getElementById('clearStatsBtn').addEventListener('click',async()=>{
  if(!confirm('确定要清空所有统计数据吗？此操作不可恢复！'))return;
  await fetch('/admin/api/clear-stats',{method:'POST'});alert('已清空');loadOverview();
});

document.getElementById('ovRangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#ovRangeBar .filter').forEach(b => b.classList.toggle('on', b === btn));
  state.ovRange = btn.dataset.r;
  updateOvStats();
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

loadConfig();
loadOverview();
// 轮询优化：页面不可见（切走标签页）时暂停 5s 轮询，回前台立即刷新
let ovTimer=setInterval(()=>{if(!document.hidden)loadOverview()},5000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden)loadOverview()});
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
    go get "golang.org/x/sync/singleflight@latest" >/dev/null 2>&1 || true
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
