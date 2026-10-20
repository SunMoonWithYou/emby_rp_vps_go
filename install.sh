#!/usr/bin/env bash
#
# emby-proxy 一键安装/卸载脚本
# ============================================================
#  纯路径反代：把目标地址塞进路径里转发
#    原:  https://www.example.com/emby/Users
#    改:  http://<本机>:8520/https://www.example.com/emby/Users
#
#  功能：
#    - 交互菜单：安装 / 更新 / 卸载 / 状态 / 日志
#    - 安装时可交互输入监听端口（默认 8520）与管理密码（默认随机）
#    - 自动安装 Go 工具链并编译静态二进制（无需预装）
#    - 适配 apt / dnf / yum / pacman / apk 各发行版
#    - WebSocket、流媒体 Range 透传；管理后台带白名单与大陆 IP 限制
#
#  用法：
#    sudo ./emby-proxy.sh                  # 交互菜单
#    sudo ./emby-proxy.sh install          # 安装或重新安装（会询问端口/密码）
#    sudo ./emby-proxy.sh install --port 9000 --admin-pass xxx
#    sudo ./emby-proxy.sh update           # 只更新程序，配置与数据不动
#    sudo ./emby-proxy.sh uninstall        # 彻底卸载（含配置、密码、统计）
#    sudo ./emby-proxy.sh status|restart
#
set -euo pipefail
SERVICE_NAME="emby-proxy"
DEFAULT_PORT=8520
DEFAULT_BIN="/usr/local/bin/emby-proxy"
CONFIG_DIR="/etc/emby-proxy"
CONFIG_FILE="${CONFIG_DIR}/config.json"
ADMIN_PASS_FILE="${CONFIG_DIR}/admin.pass"
STATS_FILE="${CONFIG_DIR}/stats.json"
BUILD_HASH_FILE="${CONFIG_DIR}/build.sha256"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GO_MIN_MAJOR=1
GO_MIN_MINOR=20
GO_FALLBACK_VERSION="1.23.4"
IPLOC_VERSION="latest"
BUILD_TMPDIR=""
GENERATED_PASS=0
# 先给默认值，避免任何函数被单独调用时变量未定义
PORT=$DEFAULT_PORT
BIN_PATH=$DEFAULT_BIN
ADMIN_USER="admin"
ADMIN_PASS=""
PREBUILT=""
FORCE=0
BINARY_ONLY=0
PORT_GIVEN=0
PASS_GIVEN=0
info() { printf '\033[1;32m✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠️  %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m❌ %s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
cleanup() { if [[ -n "$BUILD_TMPDIR" && -d "$BUILD_TMPDIR" ]]; then rm -rf "$BUILD_TMPDIR"; fi; }
trap cleanup EXIT
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 权限: sudo $0 $*"; }
require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "未检测到 systemctl"
  [[ -d /run/systemd/system ]] || die "systemd 未运行"
}
usage() {
  cat <<EOF
Emby 路径反代 一键安装（纯转发 · 管理页 + 白名单 + 大陆IP + 实时统计）

用法:
  sudo $0                     交互菜单（安装 / 更新 / 卸载）
  sudo $0 install [选项]      安装或重新安装
  sudo $0 update [选项]       只更新程序代码（配置、密码、统计不动）
  sudo $0 uninstall [--keep-config] [--yes]
  sudo $0 status|start|stop|restart

install / update 选项:
  --port N           监听端口（默认 ${DEFAULT_PORT}）
  --bin PATH         二进制路径（默认 ${DEFAULT_BIN}）
  --admin-user U     管理页用户名（默认 admin）
  --admin-pass P     管理页密码（默认随机生成，持久化复用）
  --prebuilt FILE    使用已有二进制，跳过 Go 安装与编译
  --force            强制重新编译并重启

uninstall 选项:
  --keep-config      保留配置、密码、统计（默认全部删除）
  --yes              跳过确认（非交互环境必须加）

装好后把原地址塞进路径即可，例如：
  原:  https://www.example.com/emby/Users
  改:  http://<服务器IP>:${DEFAULT_PORT}/https://www.example.com/emby/Users

示例:
  sudo $0
  sudo $0 install
  sudo $0 install --port 8520 --admin-pass mypass
  sudo $0 update --port 8520
EOF
}
parse_install_args() {
  PORT="$(installed_port)"; BIN_PATH="$(installed_bin_path)"
  [[ -n "$BIN_PATH" ]] || BIN_PATH=$DEFAULT_BIN
  ADMIN_USER="admin"; ADMIN_PASS=""; PREBUILT=""; FORCE=0; BINARY_ONLY=0
  PORT_GIVEN=0; PASS_GIVEN=0
  # 取值型参数允许空值（例如 --admin-pass "" 表示自动生成），但要防止漏传
  need_value() {
    if [[ $# -lt 2 ]]; then die "参数 $1 后面需要一个值"; fi
  }
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
stop_and_disable() {
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
}
# ============ Go 自动安装 ============
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
  if command -v apt-get >/dev/null 2>&1; then pm=apt; fi
  if command -v dnf >/dev/null 2>&1; then pm=dnf; fi
  if command -v yum >/dev/null 2>&1; then pm=yum; fi
  if command -v pacman >/dev/null 2>&1; then pm=pacman; fi
  if command -v apk >/dev/null 2>&1; then pm=apk; fi
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
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp/go.tgz"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$tmp/go.tgz"
  else
    rm -rf "$tmp"; return 1
  fi
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
  if ! go_version_ok; then
    install_go_official || true
    export PATH="/usr/local/go/bin:$PATH"
  fi
  go_version_ok || die "Go 自动安装失败"
  info "Go 就绪: $(go env GOVERSION)"
}
# ============ 内嵌 Go 源码 ============
write_go_source() {
  local dir="$1"
  cat > "$dir/main.go" <<'GO_SOURCE'
// Package main 实现一个 Emby 路径反代服务。
//
// 客户端把目标地址塞进路径，例如：
//
//	原:  https://www.example.com/emby/Users
//	改:  http://<本机>:8520/https://www.example.com/emby/Users
//
// 特性：WebSocket/流媒体透传、管理后台（白名单、大陆 IP 限制、端口热切换、
// 流量与拦截统计、IP 归属地）、按天统计与时间筛选。
package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"crypto/tls"
	_ "embed"
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

	"github.com/phuslu/iploc"
)

//go:embed admin.html
var adminHTML []byte

type targetCtxKey struct{}

var httpPorts = map[string]bool{
	"80": true, "8080": true, "8000": true, "8008": true, "8081": true,
	"8088": true, "8888": true, "3000": true, "5000": true, "7001": true,
	"8090": true, "8096": true, "9000": true, "9090": true, "9200": true,
	"10000": true, "15672": true,
}

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

// 解析 /https://host/path 形式的路径，兼容 https:/ 少写斜杠
// 浏览器会直接向反代本身要这些文件（favicon.ico / robots.txt 等），
// 它们不是转发目标；不做拦截、不写记录、不计数，直接 404
var builtinAssets = map[string]bool{
	"favicon.ico": true, "favicon.png": true, "favicon.svg": true,
	"favicon-16x16.png": true, "favicon-32x32.png": true, "favicon-96x96.png": true,
	"apple-touch-icon.png": true, "apple-touch-icon-precomposed.png": true,
	"robots.txt": true, "sitemap.xml": true, "browserconfig.xml": true,
	"manifest.json": true, "site.webmanifest": true, "humans.txt": true,
	"security.txt": true, "crossdomain.xml": true, "app-ads.txt": true,
}

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
	// ACME 等验证文件也只出现在反代自身
	return strings.HasPrefix(p, ".well-known/")
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
	// 容错：允许「/http:/host」「/http:/http://host」「//host」等写法，
	// 用户手抄地址时经常多写或少写斜杠
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

// ============ 配置 ============
type Config struct {
	Port      int      `json:"port"`       // 0 = 用启动参数
	ChinaOnly bool     `json:"china_only"` // 只允许中国大陆 IP
	Whitelist []string `json:"whitelist"`
	GeoAPI    bool     `json:"geo_api"` // 离线库查不到时用在线接口兜底
	GeoAPIURL string   `json:"geo_api_url"`
}

var startedAt = time.Now()

var (
	cfg     Config
	cfgMu   sync.RWMutex
	cfgPath string
	proxyTr = &switchTransport{}

	listenMu  sync.Mutex
	curLn     net.Listener
	curPort   int
	globalSrv *http.Server
)

func currentPort() int {
	listenMu.Lock()
	defer listenMu.Unlock()
	return curPort
}

// 在指定端口监听；成功后再关闭旧监听，失败保持原样
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

func loadConfig(path string) {
	cfgPath = path
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &cfg)
	}
	refreshRuntime()
}

func saveConfigLocked() error {
	b, _ := json.MarshalIndent(cfg, "", "  ")
	tmp := cfgPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, cfgPath)
}

func refreshRuntime() {
	proxyTr.v.Store(newTransport())
}

// ============ 白名单（针对转发目标域名）============
func normalizeHost(hostport string) string {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return strings.ToLower(strings.TrimSpace(host))
}

// 常见二级后缀，避免引入 golang.org/x/net
var multiSuffix = map[string]bool{
	"co.uk": true, "org.uk": true, "me.uk": true, "ac.uk": true, "gov.uk": true,
	"ltd.uk": true, "plc.uk": true, "net.uk": true, "sch.uk": true,
	"com.cn": true, "net.cn": true, "org.cn": true, "gov.cn": true, "edu.cn": true, "ac.cn": true,
	"com.tw": true, "org.tw": true, "net.tw": true, "idv.tw": true,
	"com.hk": true, "org.hk": true, "net.hk": true, "edu.hk": true, "gov.hk": true,
	"co.jp": true, "or.jp": true, "ne.jp": true, "ac.jp": true, "go.jp": true,
	"co.kr": true, "or.kr": true, "com.au": true, "net.au": true, "org.au": true,
	"com.br": true, "com.sg": true, "com.my": true, "co.in": true, "com.tr": true,
	"com.ru": true, "com.mx": true, "com.ar": true, "co.nz": true, "co.za": true,
	"com.ua": true, "com.pl": true, "co.id": true, "com.sa": true, "com.eg": true,
}

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

// 白名单为空 → 全部放行
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

func whitelistAllowed(targetHost string) bool {
	cfgMu.RLock()
	defer cfgMu.RUnlock()
	return whitelistMatch(cfg.Whitelist, targetHost)
}

// ============ 统计 ============
// BlockEvent 是一条被拦截的请求记录
type BlockEvent struct {
	Time       string `json:"time"`        // 拦截时间
	IP         string `json:"ip"`          // 来源 IP
	Country    string `json:"country"`     // 来源地区代码
	Path       string `json:"path"`        // 被拦截的完整请求路径
	Reason     string `json:"reason"`      // 原因代码：cn / whitelist
	ReasonText string `json:"reason_text"` // 原因的人话说明，管理页直接展示
	UA         string `json:"ua"`          // 客户端 User-Agent
}

// 按天聚合，供流量统计的时间筛选使用
type DayStat struct {
	Requests  int64            `json:"requests"`
	Bytes     int64            `json:"bytes"`
	BlockedCN int64            `json:"blocked_cn"`
	BlockedWL int64            `json:"blocked_wl"`
	Countries map[string]int64 `json:"countries,omitempty"`
	IPs       map[string]int64 `json:"ips,omitempty"`
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
	Daily            map[string]*DayStat `json:"daily,omitempty"`
	Blocks           []BlockEvent        `json:"blocks"`
	RecentBlocks     []BlockEvent        `json:"recent_blocks,omitempty"` // 仅用于读取旧文件
}

var (
	stats     Stats
	statsMu   sync.Mutex
	statsPath string
)

func loadStats(path string) {
	statsPath = path
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &stats)
	}
	if stats.CountryCounts == nil {
		stats.CountryCounts = map[string]int64{}
	}
	if stats.IPCounts == nil {
		stats.IPCounts = map[string]int64{}
	}
	if stats.TodayDate == "" {
		stats.TodayDate = time.Now().Format("2006-01-02")
	}
	if stats.Daily == nil {
		stats.Daily = map[string]*DayStat{}
	}
	pruneDailyLocked()
	// 旧版本只有 recent_blocks，迁移过来
	if len(stats.Blocks) == 0 && len(stats.RecentBlocks) > 0 {
		stats.Blocks = stats.RecentBlocks
	}
	stats.RecentBlocks = nil
	pruneBlocksLocked()
}

const maxDayIPs = 300

// 取当天聚合桶；顺带清理一年前的数据
func dayLocked() *DayStat {
	key := time.Now().Format("2006-01-02")
	if stats.Daily == nil {
		stats.Daily = map[string]*DayStat{}
	}
	d := stats.Daily[key]
	if d == nil {
		d = &DayStat{Countries: map[string]int64{}, IPs: map[string]int64{}}
		stats.Daily[key] = d
	}
	if d.Countries == nil {
		d.Countries = map[string]int64{}
	}
	if d.IPs == nil {
		d.IPs = map[string]int64{}
	}
	return d
}

func pruneDailyLocked() {
	if len(stats.Daily) == 0 {
		return
	}
	cutoff := time.Now().AddDate(-1, 0, 0).Format("2006-01-02")
	for k := range stats.Daily {
		if k < cutoff {
			delete(stats.Daily, k)
		}
	}
}

// IP 太多时只留高频的，避免 stats.json 无限膨胀
func trimDayIPs(d *DayStat) {
	if len(d.IPs) <= maxDayIPs {
		return
	}
	type kv struct {
		k string
		v int64
	}
	arr := make([]kv, 0, len(d.IPs))
	for k, v := range d.IPs {
		arr = append(arr, kv{k, v})
	}
	sort.Slice(arr, func(i, j int) bool { return arr[i].v > arr[j].v })
	nm := make(map[string]int64, maxDayIPs/2)
	for i := 0; i < maxDayIPs/2 && i < len(arr); i++ {
		nm[arr[i].k] = arr[i].v
	}
	d.IPs = nm
}

func rolloverLocked() {
	t := time.Now().Format("2006-01-02")
	if stats.TodayDate != t {
		stats.TodayDate = t
		stats.TodayRequests = 0
		stats.TodayBytes = 0
	}
}

func recordRequestStart(ip, country string) {
	statsMu.Lock()
	defer statsMu.Unlock()
	rolloverLocked()
	stats.TotalRequests++
	stats.TodayRequests++
	stats.LastProxyAt = time.Now().Format("2006-01-02 15:04:05")
	if country == "" {
		country = "??"
	}
	stats.CountryCounts[country]++
	stats.IPCounts[ip]++
	d := dayLocked()
	d.Requests++
	d.Countries[country]++
	d.IPs[ip]++
	trimDayIPs(d)
	if len(stats.IPCounts) > 2000 {
		type kv struct {
			k string
			v int64
		}
		arr := make([]kv, 0, len(stats.IPCounts))
		for k, v := range stats.IPCounts {
			arr = append(arr, kv{k, v})
		}
		sort.Slice(arr, func(i, j int) bool { return arr[i].v > arr[j].v })
		nm := make(map[string]int64, 500)
		for i := 0; i < 500 && i < len(arr); i++ {
			nm[arr[i].k] = arr[i].v
		}
		stats.IPCounts = nm
	}
}

func recordBytes(bytes int64) {
	if bytes <= 0 {
		return
	}
	statsMu.Lock()
	defer statsMu.Unlock()
	rolloverLocked()
	stats.TotalBytes += bytes
	stats.TodayBytes += bytes
	dayLocked().Bytes += bytes
}

const maxBlocks = 5000

// 只保留一年内的记录
func pruneBlocksLocked() {
	cutoff := time.Now().AddDate(-1, 0, 0).Format("2006-01-02 15:04:05")
	for len(stats.Blocks) > 0 && stats.Blocks[len(stats.Blocks)-1].Time < cutoff {
		stats.Blocks = stats.Blocks[:len(stats.Blocks)-1]
	}
}

func recordBlocked(ip, country, path, reason, ua string) {
	statsMu.Lock()
	defer statsMu.Unlock()
	rolloverLocked()
	d := dayLocked()
	reasonText := "目标域名不在访问白名单内"
	if reason == "cn" {
		stats.BlockedCN++
		d.BlockedCN++
		reasonText = "仅允许中国大陆 IP 访问"
	} else {
		stats.BlockedWhitelist++
		d.BlockedWL++
	}
	if country == "" {
		country = "??"
	}
	ev := BlockEvent{
		Time:       time.Now().Format("2006-01-02 15:04:05"),
		IP:         ip,
		Country:    country,
		Path:       path,
		Reason:     reason,
		ReasonText: reasonText,
		UA:         ua,
	}
	stats.Blocks = append([]BlockEvent{ev}, stats.Blocks...)
	if len(stats.Blocks) > maxBlocks {
		stats.Blocks = stats.Blocks[:maxBlocks]
	}
	pruneBlocksLocked()
}

func saveStatsLocked() {
	if statsPath == "" {
		return
	}
	b, _ := json.Marshal(stats)
	tmp := statsPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err == nil {
		os.Rename(tmp, statsPath)
	}
}

func startStatsSaver() {
	go func() {
		t := time.NewTicker(15 * time.Second)
		defer t.Stop()
		for range t.C {
			statsMu.Lock()
			saveStatsLocked()
			statsMu.Unlock()
			geoCacheSave()
		}
	}()
}

// 只有连接来自本机/内网（前面确实有反代）时才信任转发头，
// 否则任何人都能伪造 X-Forwarded-For 绕过「仅中国大陆」限制
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

// 注意：iploc.Country 的参数是 net.IP，不是 IP 字符串
// 注意：iploc.Country 的参数是 net.IP，不是 IP 字符串
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

// 国家/地区代码 → 中文名
var countryNames = map[string]string{
	"CN": "中国", "HK": "中国香港", "TW": "中国台湾", "MO": "中国澳门",
	"SG": "新加坡", "JP": "日本", "KR": "韩国", "KP": "朝鲜", "MN": "蒙古",
	"US": "美国", "CA": "加拿大", "MX": "墨西哥", "BR": "巴西", "AR": "阿根廷",
	"CL": "智利", "PE": "秘鲁", "CO": "哥伦比亚", "VE": "委内瑞拉", "EC": "厄瓜多尔",
	"UY": "乌拉圭", "PY": "巴拉圭", "BO": "玻利维亚", "CR": "哥斯达黎加", "PA": "巴拿马",
	"GT": "危地马拉", "CU": "古巴", "DO": "多米尼加", "JM": "牙买加", "TT": "特立尼达和多巴哥",
	"GB": "英国", "IE": "爱尔兰", "FR": "法国", "DE": "德国", "IT": "意大利",
	"ES": "西班牙", "PT": "葡萄牙", "NL": "荷兰", "BE": "比利时", "LU": "卢森堡",
	"CH": "瑞士", "AT": "奥地利", "SE": "瑞典", "NO": "挪威", "DK": "丹麦",
	"FI": "芬兰", "IS": "冰岛", "PL": "波兰", "CZ": "捷克", "SK": "斯洛伐克",
	"HU": "匈牙利", "RO": "罗马尼亚", "BG": "保加利亚", "GR": "希腊", "HR": "克罗地亚",
	"SI": "斯洛文尼亚", "RS": "塞尔维亚", "BA": "波黑", "ME": "黑山", "MK": "北马其顿",
	"AL": "阿尔巴尼亚", "UA": "乌克兰", "BY": "白俄罗斯", "MD": "摩尔多瓦", "LT": "立陶宛",
	"LV": "拉脱维亚", "EE": "爱沙尼亚", "RU": "俄罗斯", "GE": "格鲁吉亚", "AM": "亚美尼亚",
	"AZ": "阿塞拜疆", "KZ": "哈萨克斯坦", "UZ": "乌兹别克斯坦", "KG": "吉尔吉斯斯坦", "TJ": "塔吉克斯坦",
	"TM": "土库曼斯坦", "TR": "土耳其", "IL": "以色列", "SA": "沙特阿拉伯", "AE": "阿联酋",
	"QA": "卡塔尔", "KW": "科威特", "BH": "巴林", "OM": "阿曼", "JO": "约旦",
	"LB": "黎巴嫩", "SY": "叙利亚", "IQ": "伊拉克", "IR": "伊朗", "AF": "阿富汗",
	"PK": "巴基斯坦", "IN": "印度", "BD": "孟加拉国", "LK": "斯里兰卡", "NP": "尼泊尔",
	"BT": "不丹", "MV": "马尔代夫", "MM": "缅甸", "TH": "泰国", "VN": "越南",
	"LA": "老挝", "KH": "柬埔寨", "MY": "马来西亚", "ID": "印度尼西亚", "PH": "菲律宾",
	"BN": "文莱", "TL": "东帝汶", "AU": "澳大利亚", "NZ": "新西兰", "FJ": "斐济",
	"PG": "巴布亚新几内亚", "EG": "埃及", "ZA": "南非", "NG": "尼日利亚", "KE": "肯尼亚",
	"ET": "埃塞俄比亚", "GH": "加纳", "TZ": "坦桑尼亚", "UG": "乌干达", "MA": "摩洛哥",
	"DZ": "阿尔及利亚", "TN": "突尼斯", "LY": "利比亚", "SD": "苏丹", "SN": "塞内加尔",
	"CI": "科特迪瓦", "CM": "喀麦隆", "ZW": "津巴布韦", "ZM": "赞比亚", "MZ": "莫桑比克",
	"AO": "安哥拉", "MG": "马达加斯加", "MU": "毛里求斯", "RW": "卢旺达", "SO": "索马里",
	// 特殊标记
	"PV": "内网", "LO": "本机", "??": "未知",
}

func countryName(code string) string {
	if n, ok := countryNames[code]; ok {
		return n
	}
	if code == "" {
		return "未知"
	}
	return code
}

// 把 IP 归类：本机 / 内网 / 具体国家。返回统计用的代码和展示用的名称
// ============ 在线 IP 归属地（离线库查不到时兜底）============
const defaultGeoAPI = "http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,country,countryCode"

type geoEntry struct {
	Code string `json:"code"`
	Name string `json:"name"`
	At   int64  `json:"at"`
}

var (
	geoMu       sync.RWMutex
	geoMap      = map[string]geoEntry{}
	geoPath     string
	geoInflight int32
)

func geoCacheLoad(path string) {
	geoPath = path
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &geoMap)
	}
	if geoMap == nil {
		geoMap = map[string]geoEntry{}
	}
}

func geoCacheSave() {
	geoMu.RLock()
	b, _ := json.Marshal(geoMap)
	geoMu.RUnlock()
	if geoPath == "" || len(b) == 0 {
		return
	}
	tmp := geoPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err == nil {
		os.Rename(tmp, geoPath)
	}
}

func geoPickString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k].(string); ok && v != "" {
			return v
		}
	}
	return ""
}

// 在线查询的运行状态，管理页用来判断接口通不通
type geoStatT struct {
	mu      sync.Mutex
	ok      int64
	fail    int64
	lastErr string
	lastAt  int64
}

var geoStat geoStatT

func geoStatRecord(ok bool, errMsg string) {
	geoStat.mu.Lock()
	if ok {
		geoStat.ok++
	} else {
		geoStat.fail++
		geoStat.lastErr = errMsg
	}
	geoStat.lastAt = time.Now().Unix()
	geoStat.mu.Unlock()
}

func geoStatSnapshot() (int64, int64, string) {
	geoStat.mu.Lock()
	defer geoStat.mu.Unlock()
	return geoStat.ok, geoStat.fail, geoStat.lastErr
}

func truncStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// 真正发一次请求；错误信息要具体，方便判断是网络不通还是格式不对
func geoFetch(ipStr string) (string, string, error) {
	cfgMu.RLock()
	tpl := strings.TrimSpace(cfg.GeoAPIURL)
	cfgMu.RUnlock()
	if tpl == "" {
		tpl = defaultGeoAPI
	}
	target := strings.ReplaceAll(tpl, "{ip}", ipStr)
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(target)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		return "", "", fmt.Errorf("响应不是 JSON: %s", truncStr(string(body), 80))
	}
	if st, ok := m["status"].(string); ok && st == "fail" {
		msg, _ := m["message"].(string)
		if msg == "" {
			msg = "接口返回 status=fail"
		}
		return "", "", fmt.Errorf("%s", msg)
	}

	raw := geoPickString(m, "country")
	code := geoPickString(m, "countryCode", "country_code", "code")
	if code == "" && len(raw) == 2 && strings.ToUpper(raw) == raw {
		code = raw
		raw = ""
	}
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) != 2 {
		return "", "", fmt.Errorf("响应里没有两字母国家代码: %s", truncStr(string(body), 80))
	}
	name := strings.TrimSpace(raw)
	if name == "" || len(name) == 2 {
		name = countryName(code)
	}
	return code, name, nil
}

// 调第三方接口查归属地；查不到/超时返回 ok=false，绝不影响转发
func geoLookup(ipStr string) (string, string, bool) {
	now := time.Now().Unix()
	geoMu.RLock()
	e, cached := geoMap[ipStr]
	geoMu.RUnlock()
	if cached {
		if e.Code == "??" {
			if now-e.At < 3600 { // 失败过，一小时后再试
				return "", "", false
			}
		} else if now-e.At < 30*86400 {
			return e.Code, e.Name, true
		}
	}

	cfgMu.RLock()
	enabled := cfg.GeoAPI
	cfgMu.RUnlock()
	if !enabled {
		return "", "", false
	}
	// 并发保护：同时查询不超过 8 个，避免拖慢转发
	if atomic.LoadInt32(&geoInflight) > 8 {
		return "", "", false
	}
	atomic.AddInt32(&geoInflight, 1)
	defer atomic.AddInt32(&geoInflight, -1)

	code, name, err := geoFetch(ipStr)
	if err != nil {
		geoStatRecord(false, err.Error())
		geoMu.Lock()
		geoMap[ipStr] = geoEntry{Code: "??", At: now}
		geoMu.Unlock()
		return "", "", false
	}
	geoStatRecord(true, "")

	geoMu.Lock()
	geoMap[ipStr] = geoEntry{Code: code, Name: name, At: now}
	if len(geoMap) > 5000 { // 控制体积：超了就整体清掉最旧的一半
		cutoff := now - 15*86400
		for k, v := range geoMap {
			if v.At < cutoff {
				delete(geoMap, k)
			}
		}
	}
	geoMu.Unlock()
	return code, name, true
}

func ipLabel(ipStr string) (code, name string) {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil {
		return "??", "未知"
	}
	if ip.IsLoopback() {
		return "LO", "本机"
	}
	if ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return "PV", "内网"
	}
	c := countryOf(ipStr)
	if c == "??" {
		// 离线库没有这段 IP，交给在线接口
		if gc, gn, ok := geoLookup(ipStr); ok {
			return gc, gn
		}
		return "??", "未知"
	}
	return c, countryName(c)
}

// ============ 国旗图片：服务端取一次并缓存，浏览器只请求本机 ============
var flagCache = struct {
	sync.RWMutex
	m map[string][]byte
}{m: map[string][]byte{}}

var flagDir string

func flagPng(code string) ([]byte, error) {
	flagCache.RLock()
	b, ok := flagCache.m[code]
	flagCache.RUnlock()
	if ok {
		return b, nil
	}
	// 磁盘缓存：取到过一次就永久可用，重启也不用再连外网
	if flagDir != "" {
		if d, err := os.ReadFile(filepath.Join(flagDir, code+".png")); err == nil && len(d) > 100 {
			flagCache.Lock()
			flagCache.m[code] = d
			flagCache.Unlock()
			return d, nil
		}
	}
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := client.Get("https://flagcdn.com/w40/" + code + ".png")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("flagcdn 返回 %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil || len(data) < 100 {
		return nil, fmt.Errorf("图片无效")
	}
	flagCache.Lock()
	if len(flagCache.m) > 400 {
		flagCache.m = map[string][]byte{}
	}
	flagCache.m[code] = data
	flagCache.Unlock()

	if flagDir != "" {
		if os.MkdirAll(flagDir, 0755) == nil {
			_ = os.WriteFile(filepath.Join(flagDir, code+".png"), data, 0644)
		}
	}
	return data, nil
}

// ============ 重新识别历史 IP ============
var (
	regeoRunning int32
	regeoTotal   int32
	regeoDone    int32
)

func regeoAll() {
	statsMu.Lock()
	ips := make(map[string]int64, len(stats.IPCounts))
	for k, v := range stats.IPCounts {
		ips[k] = v
	}
	statsMu.Unlock()

	// 之前查失败的先清掉，让它们有机会重查
	geoMu.Lock()
	for k, v := range geoMap {
		if v.Code == "??" {
			delete(geoMap, k)
		}
	}
	geoMu.Unlock()

	atomic.StoreInt32(&regeoTotal, int32(len(ips)))
	atomic.StoreInt32(&regeoDone, 0)

	type res struct {
		code string
		cnt  int64
	}
	jobs := make(chan string, len(ips))
	out := make(chan res, len(ips))
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ip := range jobs {
				code, _ := ipLabel(ip)
				out <- res{code, ips[ip]}
				atomic.AddInt32(&regeoDone, 1)
			}
		}()
	}
	for ip := range ips {
		jobs <- ip
	}
	close(jobs)
	wg.Wait()
	close(out)

	cc := map[string]int64{}
	for r := range out {
		cc[r.code] += r.cnt
	}
	statsMu.Lock()
	stats.CountryCounts = cc
	saveStatsLocked()
	statsMu.Unlock()
	geoCacheSave()
}

// ============ 中间件 ============
type statWriter struct {
	http.ResponseWriter
	bytes int64
}

func (w *statWriter) Write(b []byte) (int, error) {
	n, err := w.ResponseWriter.Write(b)
	w.bytes += int64(n)
	return n, err
}

func (w *statWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := w.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, fmt.Errorf("hijacking not supported")
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

func (w *statWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func basicAuth(next http.HandlerFunc, user, pass string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok ||
			subtle.ConstantTimeCompare([]byte(u), []byte(user)) != 1 ||
			subtle.ConstantTimeCompare([]byte(p), []byte(pass)) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="emby-proxy admin"`)
			http.Error(w, "未登录或登录已失效，请重新登录", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// ============ 反代 ============
type switchTransport struct {
	v atomic.Value // *http.Transport
}

func (s *switchTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	t, _ := s.v.Load().(*http.Transport)
	if t == nil {
		return nil, fmt.Errorf("transport 未初始化")
	}
	return t.RoundTrip(r)
}

func newTransport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          256,
		MaxIdleConnsPerHost:   128,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 45 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		// 不做透明压缩：客户端 Accept-Encoding 原样透传，避免大文件/视频流被改写
		DisableCompression: true,
		TLSClientConfig:    &tls.Config{MinVersion: tls.VersionTLS12},
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
		Transport: tr,
		// -1：收到就往下写，视频/直播流不缓冲
		FlushInterval: -1,
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

			pr.Out.Host = t.Host
			rewriteOriginHeaders(pr.Out, t.Scheme, t.Host)
		},
		ModifyResponse: func(resp *http.Response) error {
			upHost := ""
			if resp.Request != nil && resp.Request.URL != nil {
				upHost = resp.Request.URL.Host
			}
			// 上游的绝对跳转改回相对，避免客户端跳出反代
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
			// 去掉上游 Cookie 的 Domain，否则客户端可能不认
			if cks, ok := resp.Header["Set-Cookie"]; ok && len(cks) > 0 {
				for i, c := range cks {
					cks[i] = cookieDomainRE.ReplaceAllString(c, "")
				}
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("[proxy] %s %s -> %v", r.Method, r.URL.RequestURI(), err)
			http.Error(w, "无法连接目标服务器："+err.Error(), http.StatusBadGateway)
		},
	}
}

func helpPage(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, `Emby 路径反代运行中。

用法：把原地址放到路径里即可，例如原地址
  https://www.example.com/emby/Users
改成
  http://<本机地址>/https://www.example.com/emby/Users

管理页: /admin/
`)
}

// ============ 管理接口 ============
type adminConfigResp struct {
	Config
	EffectivePort int `json:"effective_port"`
}

type saveReq struct {
	Port      int      `json:"port"`
	ChinaOnly bool     `json:"china_only"`
	Whitelist []string `json:"whitelist"`
	GeoAPI    bool     `json:"geo_api"`
	GeoAPIURL string   `json:"geo_api_url"`
}

func adminHandler(user, pass string) http.HandlerFunc {
	mux := http.NewServeMux()
	mux.HandleFunc("/admin/api/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		cfgMu.RLock()
		resp := adminConfigResp{Config: cfg, EffectivePort: currentPort()}
		cfgMu.RUnlock()
		json.NewEncoder(w).Encode(resp)
	})
	mux.HandleFunc("/admin/api/save", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "该接口不支持此请求方法", http.StatusMethodNotAllowed)
			return
		}
		var req saveReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "请求数据格式错误："+err.Error(), http.StatusBadRequest)
			return
		}
		if req.Port != 0 && (req.Port < 1 || req.Port > 65535) {
			http.Error(w, "端口必须是 1-65535 之间的整数", http.StatusBadRequest)
			return
		}
		newCfg := Config{
			Port:      req.Port,
			ChinaOnly: req.ChinaOnly,
			Whitelist: req.Whitelist,
			GeoAPI:    req.GeoAPI,
			GeoAPIURL: strings.TrimSpace(req.GeoAPIURL),
		}
		cfgMu.Lock()
		oldCfg := cfg
		cfg = newCfg
		err := saveConfigLocked()
		cfgMu.Unlock()
		if err != nil {
			http.Error(w, "保存失败: "+err.Error(), http.StatusInternalServerError)
			return
		}
		refreshRuntime()

		// 端口变更：先在新端口监听成功，再关旧端口；失败则回滚配置
		if newCfg.Port > 0 && newCfg.Port != currentPort() && globalSrv != nil {
			if err := startListen(globalSrv, newCfg.Port); err != nil {
				cfgMu.Lock()
				cfg = oldCfg
				_ = saveConfigLocked()
				cfgMu.Unlock()
				refreshRuntime()
				http.Error(w, "端口 "+strconv.Itoa(newCfg.Port)+" 无法监听（可能被占用或权限不足）: "+err.Error(), http.StatusBadRequest)
				return
			}
			log.Printf("监听端口已切换: %d -> %d", oldCfg.Port, newCfg.Port)
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(adminConfigResp{Config: newCfg, EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/flag/", func(w http.ResponseWriter, r *http.Request) {
		code := strings.ToLower(strings.TrimPrefix(r.URL.Path, "/admin/api/flag/"))
		if len(code) != 2 || code[0] < 'a' || code[0] > 'z' || code[1] < 'a' || code[1] > 'z' {
			http.NotFound(w, r)
			return
		}
		data, err := flagPng(code)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=2592000")
		w.Write(data)
	})
	mux.HandleFunc("/admin/api/traffic", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		from := strings.TrimSpace(q.Get("from"))
		to := strings.TrimSpace(q.Get("to"))

		statsMu.Lock()
		var reqs, byts, cn, wl int64
		ips := map[string]int64{}
		ctry := map[string]int64{}
		days := make([]string, 0, len(stats.Daily))
		for k := range stats.Daily {
			days = append(days, k)
		}
		sort.Sort(sort.Reverse(sort.StringSlice(days)))
		if from == "" && to == "" {
			// 不限时间：用累计值，升级前的历史数据也能算进来
			reqs, byts = stats.TotalRequests, stats.TotalBytes
			cn, wl = stats.BlockedCN, stats.BlockedWhitelist
			for ip, n := range stats.IPCounts {
				ips[ip] = n
			}
			for c, n := range stats.CountryCounts {
				ctry[c] = n
			}
		} else {
			for k, d := range stats.Daily {
				if from != "" && k < from {
					continue
				}
				if to != "" && k > to {
					continue
				}
				reqs += d.Requests
				byts += d.Bytes
				cn += d.BlockedCN
				wl += d.BlockedWL
				for ip, n := range d.IPs {
					ips[ip] += n
				}
				for c, n := range d.Countries {
					ctry[c] += n
				}
			}
		}
		today := time.Now().Format("2006-01-02")
		var todayReqs, todayBytes int64
		if d := stats.Daily[today]; d != nil {
			todayReqs, todayBytes = d.Requests, d.Bytes
		}
		statsMu.Unlock()

		json.NewEncoder(w).Encode(map[string]any{
			"today":             today,
			"requests":          reqs,
			"bytes":             byts,
			"blocked_cn":        cn,
			"blocked_whitelist": wl,
			"ip_counts":         ips,
			"country_counts":    ctry,
			"days":              days,
			"today_requests":    todayReqs,
			"today_bytes":       todayBytes,
		})
	})
	mux.HandleFunc("/admin/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		date := strings.TrimSpace(q.Get("date"))
		from := strings.TrimSpace(q.Get("from"))
		to := strings.TrimSpace(q.Get("to"))
		if date != "" {
			from, to = date, date
		}
		page := 1
		if v, err := strconv.Atoi(q.Get("page")); err == nil && v > 0 {
			page = v
		}
		size := 20
		if v, err := strconv.Atoi(q.Get("size")); err == nil && v > 0 && v <= 200 {
			size = v
		}

		statsMu.Lock()
		matched := []BlockEvent{}
		dates := []string{}
		seen := map[string]bool{}
		for _, b := range stats.Blocks {
			d := b.Time
			if len(d) >= 10 {
				d = d[:10]
			}
			if !seen[d] {
				seen[d] = true
				if len(dates) < 60 {
					dates = append(dates, d)
				}
			}
			if from != "" && d < from {
				continue
			}
			if to != "" && d > to {
				continue
			}
			matched = append(matched, b)
		}
		statsMu.Unlock()

		total := len(matched)
		pages := (total + size - 1) / size
		if pages < 1 {
			pages = 1
		}
		if page > pages {
			page = pages
		}
		start := (page - 1) * size
		end := start + size
		if start > total {
			start = total
		}
		if end > total {
			end = total
		}
		items := append([]BlockEvent{}, matched[start:end]...)
		json.NewEncoder(w).Encode(map[string]any{
			"total": total, "page": page, "size": size, "pages": pages,
			"items": items, "dates": dates, "today": time.Now().Format("2006-01-02"),
		})
	})
	mux.HandleFunc("/admin/api/geotest", func(w http.ResponseWriter, r *http.Request) {
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
			ip = "8.8.8.8"
		}
		if net.ParseIP(ip) == nil {
			http.Error(w, "IP 地址格式不正确", http.StatusBadRequest)
			return
		}
		cfgMu.RLock()
		tpl := strings.TrimSpace(cfg.GeoAPIURL)
		cfgMu.RUnlock()
		if tpl == "" {
			tpl = defaultGeoAPI
		}
		code, name, err := geoFetch(ip)
		geoStatRecord(err == nil, func() string {
			if err != nil {
				return err.Error()
			}
			return ""
		}())
		out := map[string]any{"ip": ip, "url": strings.ReplaceAll(tpl, "{ip}", ip)}
		if err != nil {
			out["ok"] = false
			out["error"] = err.Error()
		} else {
			out["ok"] = true
			out["code"] = code
			out["name"] = name
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("/admin/api/regeo", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		started := atomic.CompareAndSwapInt32(&regeoRunning, 0, 1)
		if started {
			go func() {
				defer atomic.StoreInt32(&regeoRunning, 0)
				regeoAll()
			}()
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"started": started})
	})
	mux.HandleFunc("/admin/api/stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock()
		defer statsMu.Unlock()
		gok, gfail, glast := geoStatSnapshot()
		snap := stats
		snap.Blocks = nil
		snap.RecentBlocks = nil
		// 按天数据只在流量接口里按需聚合，不塞进 5 秒一次的轮询
		snap.Daily = nil
		blocksTotal := len(stats.Blocks)
		labels := map[string]string{}
		for code := range stats.CountryCounts {
			labels[code] = countryName(code)
		}
		for _, b := range stats.Blocks {
			if _, ok := labels[b.Country]; !ok {
				labels[b.Country] = countryName(b.Country)
			}
		}
		json.NewEncoder(w).Encode(struct {
			Stats
			CountryLabels map[string]string `json:"country_labels"`
			Port          int               `json:"port"`
			UptimeSec     int64             `json:"uptime_sec"`
			GeoOK         int64             `json:"geo_ok"`
			GeoFail       int64             `json:"geo_fail"`
			GeoLastErr    string            `json:"geo_last_err"`
			RegeoRunning  bool              `json:"regeo_running"`
			RegeoDone     int32             `json:"regeo_done"`
			RegeoTotal    int32             `json:"regeo_total"`
			BlocksTotal   int               `json:"blocks_total"`
		}{Stats: snap, CountryLabels: labels, Port: currentPort(),
			UptimeSec:    int64(time.Since(startedAt).Seconds()),
			GeoOK:        gok,
			GeoFail:      gfail,
			GeoLastErr:   glast,
			RegeoRunning: atomic.LoadInt32(&regeoRunning) == 1,
			RegeoDone:    atomic.LoadInt32(&regeoDone),
			RegeoTotal:   atomic.LoadInt32(&regeoTotal),
			BlocksTotal:  blocksTotal})
	})
	mux.HandleFunc("/admin/api/", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(adminHTML)
	})
	return basicAuth(mux.ServeHTTP, user, pass)
}

// ============ 主逻辑 ============
func runServer(port int, adminUser, adminPass, configPath, statsFile string) {
	loadConfig(configPath)
	geoCacheLoad(filepath.Join(filepath.Dir(configPath), "geo_cache.json"))
	flagDir = filepath.Join(filepath.Dir(configPath), "flags")
	loadStats(statsFile)
	startStatsSaver()
	defer func() {
		statsMu.Lock()
		saveStatsLocked()
		statsMu.Unlock()
		geoCacheSave()
	}()

	proxy := buildProxy(proxyTr)

	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 站点自有文件：不算请求、不记拦截
		if isBuiltinAssetPath(r.URL.Path) {
			http.NotFound(w, r)
			return
		}
		ip := getClientIP(r)
		country, _ := ipLabel(ip)

		// 本机/内网视为可信（前面挂了 Nginx 时不至于把自己挡住）
		cfgMu.RLock()
		chinaOnly := cfg.ChinaOnly
		cfgMu.RUnlock()
		if chinaOnly && country != "CN" && country != "LO" && country != "PV" {
			recordBlocked(ip, country, r.URL.RequestURI(), "cn", r.UserAgent())
			http.Error(w, "仅允许中国大陆 IP 访问（可在管理页关闭此限制）", http.StatusForbidden)
			return
		}

		target, err := parseTarget(r)
		if err != nil {
			helpPage(w)
			return
		}
		if !whitelistAllowed(target.Host) {
			recordBlocked(ip, country, r.URL.RequestURI(), "whitelist", r.UserAgent())
			http.Error(w, "目标域名不在访问白名单内，已被拦截", http.StatusForbidden)
			return
		}

		recordRequestStart(ip, country)
		sw := &statWriter{ResponseWriter: w}
		ctx := context.WithValue(r.Context(), targetCtxKey{}, target)
		proxy.ServeHTTP(sw, r.WithContext(ctx))
		recordBytes(sw.bytes)
	})

	// 不用 ServeMux 分发：它会 cleanPath，把路径里的 // 改成 301，
	// 对反代是致命的（会改写上游路径、打断带 // 的媒体地址）
	adminSrv := adminHandler(adminUser, adminPass)
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

	// 配置文件里的端口优先于启动参数，这样后台改端口重启后仍然生效
	cfgMu.RLock()
	if cfg.Port > 0 {
		port = cfg.Port
	}
	cfgMu.RUnlock()

	srv := &http.Server{
		Handler:           root,
		ReadHeaderTimeout: 20 * time.Second,
		IdleTimeout:       300 * time.Second,
	}
	globalSrv = srv
	if err := startListen(srv, port); err != nil {
		log.Fatalf("监听 :%d 失败: %v", port, err)
	}
	log.Printf("Emby 路径反代已启动 :%d  管理页: /admin/", port)

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
	adminUser := fs.String("admin-user", "admin", "管理页用户名")
	adminPass := fs.String("admin-pass", "", "管理页密码")
	configPath := fs.String("config", "/etc/emby-proxy/config.json", "配置文件路径")
	statsFile := fs.String("stats", "/etc/emby-proxy/stats.json", "统计文件路径")
	fs.Parse(args)
	if *adminPass == "" {
		log.Fatal("必须通过 --admin-pass 指定管理页密码")
	}
	runServer(*port, *adminUser, *adminPass, *configPath, *statsFile)
}
GO_SOURCE

  cat > "$dir/admin.html" <<'ADMIN_HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0f1424">
<title>Emby Proxy</title>
<link rel="icon" type="image/png" sizes="64x64" href="data:image/png;base64,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">
<link rel="apple-touch-icon" href="data:image/png;base64,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">
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :root {
    --bg: #f5f6fa;
    --card: #ffffff;
    --border: #e9ecf3;
    --text: #101828;
    --text-2: #475467;
    --text-3: #98a2b3;
    --primary: #6366f1;
    --primary-dark: #4f46e5;
    --primary-soft: #eef2ff;
    --ok: #10b981;
    --danger: #ef4444;
    --warn: #f59e0b;
    --mono: "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
    --r-lg: 16px;
    --r: 12px;
    --shadow: 0 1px 2px rgba(16,24,40,.04), 0 1px 3px rgba(16,24,40,.03);
  }
  html { -webkit-text-size-adjust: 100%; scroll-behavior: smooth; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    font-size: 14px; line-height: 1.55; -webkit-font-smoothing: antialiased;
  }

  /* ============ 顶栏 ============ */
  .topbar {
    position: sticky; top: 0; z-index: 50;
    background: rgba(245,246,250,.96);
    backdrop-filter: saturate(180%) blur(14px);
    -webkit-backdrop-filter: saturate(180%) blur(14px);
    border-bottom: 1px solid var(--border);
  }
  .topbar-inner {
    max-width: 1180px; margin: 0 auto; padding: 10px 20px;
    display: flex; align-items: center; gap: 14px; flex-wrap: nowrap;
    min-height: 54px;
  }
  .tabs { display: flex; gap: 3px; margin-right: auto; overflow-x: auto; scrollbar-width: none; min-width: 0; }
  .tabs::-webkit-scrollbar { display: none; }
  .tab {
    border: 0; background: transparent; color: var(--text-2);
    padding: 7px 13px; border-radius: 9px; font-size: 13px; font-weight: 500;
    font-family: inherit; cursor: pointer; white-space: nowrap; transition: .15s;
  }
  .tab:hover { background: rgba(99,102,241,.08); color: var(--primary-dark); }
  .tab.active { background: var(--card); color: var(--primary-dark); font-weight: 600; box-shadow: var(--shadow); }
  .meta { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
  .chip {
    display: inline-flex; align-items: center; gap: 5px; padding: 4px 9px;
    border-radius: 7px; font-size: 11.5px; background: #e9ecf4; color: var(--text-2);
    font-variant-numeric: tabular-nums; white-space: nowrap;
  }
  .chip.p { background: var(--primary-soft); color: var(--primary-dark); font-family: var(--mono); }
  .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--ok); box-shadow: 0 0 0 3px rgba(16,185,129,.15); animation: pl 2.4s infinite; }
  @keyframes pl { 0%,100% { box-shadow: 0 0 0 3px rgba(16,185,129,.15); } 50% { box-shadow: 0 0 0 5px rgba(16,185,129,.05); } }

  /* ============ 布局 ============ */
  main { max-width: 1180px; margin: 0 auto; padding: 20px; }
  section { scroll-margin-top: 74px; }
  .page { display: block; }
  .page + .page { margin-top: 4px; }

  .range-bar {
    display: flex; align-items: center; gap: 12px; flex-wrap: wrap;
    background: var(--card); border: 1px solid var(--border); border-radius: 14px;
    padding: 11px 16px; margin-bottom: 16px; box-shadow: var(--shadow);
  }
  .range-label { font-size: 12.5px; color: var(--text-3); font-weight: 600; }
  .range-sum { margin-left: auto; font-size: 12px; color: var(--text-2); font-variant-numeric: tabular-nums; }
  .range-sum b { color: var(--text); font-weight: 650; }
  .range-sum i { color: var(--text-3); font-style: normal; margin: 0 6px; }

  .pager { display: flex; align-items: center; justify-content: center; gap: 10px; padding: 16px 0 4px; flex-wrap: wrap; }
  .page-info { font-size: 12.5px; color: var(--text-2); font-variant-numeric: tabular-nums; }
  .btn:disabled { opacity: .4; cursor: not-allowed; }
  .btn:disabled:hover { background: #f2f4f9; }
  .card {
    background: var(--card); border: 1px solid var(--border); border-radius: var(--r-lg);
    box-shadow: var(--shadow); padding: 20px; margin-bottom: 16px;
  }
  .card-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
  .card-title { font-size: 14.5px; font-weight: 650; margin: 0; letter-spacing: -.1px; }
  .card-desc { font-size: 12.5px; color: var(--text-3); margin-top: 2px; }

  /* ============ 统计卡 ============ */
  .stats { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin-bottom: 16px; }
  .stat {
    background: var(--card); border: 1px solid var(--border); border-radius: var(--r-lg);
    padding: 16px 18px; box-shadow: var(--shadow);
    display: flex; align-items: flex-start; gap: 12px; transition: transform .18s, box-shadow .18s;
  }
  .stat:hover { transform: translateY(-1px); box-shadow: 0 8px 20px -10px rgba(16,24,40,.18); }
  .stat-ico { width: 36px; height: 36px; border-radius: 10px; display: grid; place-items: center; flex-shrink: 0; }
  .stat-ico svg { width: 17px; height: 17px; }
  .c1 { background: #eef2ff; color: #4f46e5; }
  .c2 { background: #ecfdf5; color: #059669; }
  .c3 { background: #fef3f2; color: #dc2626; }
  .c4 { background: #fffaeb; color: #d97706; }
  .stat-body { min-width: 0; flex: 1; }
  .stat-label { font-size: 12px; color: var(--text-3); font-weight: 500; }
  .stat-value { font-size: 24px; font-weight: 700; letter-spacing: -.6px; line-height: 1.25; font-variant-numeric: tabular-nums; }
  .stat-value.danger { color: var(--danger); }
  .stat-sub { font-size: 11.5px; color: var(--text-3); margin-top: 3px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .stat-sub b { color: var(--text-2); font-weight: 600; }

  /* ============ 分布 ============ */
  .grid2 { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; }
  .grid2 .card { margin-bottom: 0; }
  .dist-row { display: flex; align-items: center; gap: 10px; padding: 5px 0; }
  .dist-name {
    width: 112px; flex-shrink: 0; display: flex; align-items: center; gap: 7px;
    font-size: 12.5px; color: var(--text); min-width: 0;
  }
  .dist-name .txt { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dist-name.mono .txt { font-family: var(--mono); font-size: 11.5px; }
  .flag-img {
    width: 20px; height: 15px; object-fit: cover; border-radius: 2px;
    flex-shrink: 0; box-shadow: 0 0 0 1px rgba(16,24,40,.1); background: #eef1f7;
  }
  .flag-badge {
    display: inline-grid; place-items: center; min-width: 20px; height: 15px;
    padding: 0 3px; border-radius: 3px; background: #eef1f7; color: #667085;
    font-size: 9.5px; font-weight: 700; line-height: 1; flex-shrink: 0;
    font-family: -apple-system, "PingFang SC", sans-serif;
  }
  .bar { flex: 1; height: 8px; background: #eef1f7; border-radius: 99px; overflow: hidden; min-width: 30px; }
  .bar > i { display: block; height: 100%; border-radius: 99px; min-width: 3px; transition: width .45s cubic-bezier(.4,0,.2,1); }
  .bar.ind > i { background: linear-gradient(90deg, #6366f1, #8b5cf6); }
  .bar.teal > i { background: linear-gradient(90deg, #059669, #10b981); }
  .dist-val { width: 82px; text-align: right; font-size: 12px; color: var(--text-2); flex-shrink: 0; font-variant-numeric: tabular-nums; }
  .dist-val span { color: var(--text-3); margin-left: 5px; }

  /* ============ 表格 ============ */
  .table-wrap { overflow-x: auto; margin: 0 -20px -20px; padding: 0 20px 4px; }
  table.log { width: 100%; border-collapse: separate; border-spacing: 0; table-layout: fixed; min-width: 660px; }
  table.log th {
    position: sticky; top: 0; z-index: 2; text-align: left; padding: 8px 10px;
    font-size: 11px; font-weight: 600; color: var(--text-3); letter-spacing: .3px;
    background: #fafbfd; border-bottom: 1px solid var(--border); white-space: nowrap;
  }
  table.log td {
    padding: 9px 10px; border-bottom: 1px solid #f2f4f8; font-size: 12.5px;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: middle;
  }
  table.log tbody tr:last-child td { border-bottom: 0; }
  table.log tbody tr:nth-child(even) td { background: #fcfdff; }
  table.log tbody tr:hover td { background: #f5f7ff; }
  .c-time { color: var(--text-3); font-family: var(--mono); font-size: 11.5px; font-variant-numeric: tabular-nums; }
  .c-ip { font-family: var(--mono); font-size: 12px; }
  .c-path { font-family: var(--mono); font-size: 11.5px; color: var(--text-2); }
  .rg-cell { display: inline-flex; align-items: center; gap: 6px; }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 99px; font-size: 11px; font-weight: 600; white-space: nowrap; }
  .pill-wl { background: #fffaeb; color: #b54708; }
  .pill-cn { background: #fef3f2; color: #d92d20; }

  .filters { display: flex; gap: 6px; flex-wrap: wrap; }
  .filter {
    border: 1px solid var(--border); background: #fff; color: var(--text-2);
    padding: 5px 10px; border-radius: 8px; font-size: 12px; font-weight: 500;
    font-family: inherit; cursor: pointer; transition: .15s;
    display: inline-flex; align-items: center; gap: 5px;
  }
  .filter:hover { background: #f7f8fc; }
  .filter.active { background: var(--primary-soft); border-color: #c7cbff; color: var(--primary-dark); font-weight: 600; }
  .filter b { font-variant-numeric: tabular-nums; }

  /* ============ 表单 ============ */
  .field { margin-bottom: 16px; }
  .field:last-child { margin-bottom: 0; }
  .field-label { display: block; font-size: 13px; font-weight: 600; margin-bottom: 6px; }
  .input, .textarea {
    width: 100%; padding: 9px 12px; font-size: 13px; color: var(--text);
    background: #fbfcfe; border: 1px solid #dde2ec; border-radius: 10px;
    font-family: inherit; transition: .15s;
  }
  .input:focus, .textarea:focus { outline: none; border-color: var(--primary); background: #fff; box-shadow: 0 0 0 3px rgba(99,102,241,.12); }
  .input.mono, .textarea { font-family: var(--mono); font-size: 12.5px; }
  .textarea { resize: vertical; min-height: 88px; line-height: 1.7; }
  .hint { font-size: 12px; color: var(--text-3); margin-top: 6px; line-height: 1.75; }
  .hint code { background: #f1f3f9; color: #4338ca; padding: 1px 5px; border-radius: 4px; font-family: var(--mono); font-size: 11.5px; }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 10px 0; }
  .row + .row { border-top: 1px dashed var(--border); }
  .row-main { min-width: 0; }
  .row-label { font-size: 13.5px; font-weight: 600; }
  .row-desc { font-size: 12.5px; color: var(--text-3); margin-top: 1px; }
  .switch { position: relative; width: 42px; height: 24px; flex-shrink: 0; }
  .switch input { position: absolute; opacity: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; z-index: 1; }
  .track { position: absolute; inset: 0; background: #d7dce6; border-radius: 99px; transition: background .2s; pointer-events: none; }
  .track::after { content: ""; position: absolute; width: 18px; height: 18px; left: 3px; top: 3px; background: #fff; border-radius: 50%; transition: transform .2s; box-shadow: 0 1px 2px rgba(16,24,40,.25); }
  .switch input:checked + .track { background: var(--primary); }
  .switch input:checked + .track::after { transform: translateX(18px); }

  .btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 6px;
    padding: 9px 16px; border: 0; border-radius: 9px; font-size: 13px; font-weight: 600;
    font-family: inherit; cursor: pointer; transition: .15s;
  }
  .btn:active { transform: scale(.985); }
  .btn-primary { background: var(--primary); color: #fff; box-shadow: 0 1px 2px rgba(99,102,241,.3); }
  .btn-primary:hover { background: var(--primary-dark); }
  .btn-primary:disabled { opacity: .55; cursor: not-allowed; }
  .btn-ghost { background: #f2f4f9; color: var(--text-2); }
  .btn-ghost:hover { background: #e8ebf3; }
  .actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-top: 12px; }

  .notice { display: flex; gap: 9px; padding: 11px 13px; border-radius: 10px; font-size: 12.5px; line-height: 1.75; margin-top: 12px; }
  .notice svg { width: 15px; height: 15px; flex-shrink: 0; margin-top: 2px; }
  .notice-info { background: #eff4ff; border: 1px solid #d6e0ff; color: #3538cd; }
  .notice-ok { background: #ecfdf5; border: 1px solid #a7f3d0; color: #065f46; }
  .notice-warn { background: #fffaeb; border: 1px solid #fedf89; color: #b54708; }
  .notice code { background: rgba(255,255,255,.72); padding: 1px 5px; border-radius: 4px; font-family: var(--mono); font-size: 11.5px; word-break: break-all; }
  .geo-status { font-size: 12px; color: var(--text-3); }

  /* 日期筛选 */
  .sel {
    border: 1px solid var(--border); background: #fff; color: var(--text-2);
    padding: 5px 9px; border-radius: 8px; font-size: 12px; font-family: inherit;
    cursor: pointer; max-width: 150px;
  }
  .sel:focus { outline: none; border-color: var(--primary); }

  /* 详情弹层 */
  .modal {
    position: fixed; inset: 0; z-index: 200; display: none;
    background: rgba(16,24,40,.45); backdrop-filter: blur(3px);
    padding: 20px; overflow-y: auto;
  }
  .modal.show { display: flex; align-items: center; justify-content: center; }
  .modal-box {
    background: #fff; border-radius: 16px; width: 100%; max-width: 560px;
    box-shadow: 0 24px 60px -12px rgba(16,24,40,.35); overflow: hidden;
    animation: pop .18s ease-out;
  }
  @keyframes pop { from { transform: translateY(8px) scale(.98); opacity: .6; } to { transform: none; opacity: 1; } }
  .modal-head {
    display: flex; align-items: center; justify-content: space-between;
    padding: 16px 18px; border-bottom: 1px solid var(--border);
  }
  .modal-head h3 { margin: 0; font-size: 14.5px; font-weight: 650; }
  .modal-close {
    border: 0; background: #f2f4f9; width: 28px; height: 28px; border-radius: 8px;
    font-size: 18px; line-height: 1; color: var(--text-2); cursor: pointer; font-family: inherit;
  }
  .modal-close:hover { background: #e8ebf3; }
  .modal-body { padding: 16px 18px 18px; }
  .kv { display: flex; gap: 12px; padding: 7px 0; border-bottom: 1px dashed var(--border); font-size: 13px; }
  .kv:last-child { border-bottom: 0; }
  .kv-k { color: var(--text-3); width: 56px; flex-shrink: 0; font-size: 12.5px; }
  .kv-v { flex: 1; min-width: 0; word-break: break-all; }
  .kv-v.mono { font-family: var(--mono); font-size: 12px; }
  tr.row-click { cursor: pointer; }

  /* 白名单展示 */
  .wl-list { display: flex; flex-wrap: wrap; gap: 7px; min-height: 40px; }
  .wl-item {
    display: inline-flex; align-items: center; gap: 6px;
    background: #f2f4f9; border-radius: 8px; padding: 5px 10px;
    font-family: var(--mono); font-size: 12px; color: var(--text-2);
  }
  .wl-empty { color: var(--text-3); font-size: 12.5px; }

  .empty { padding: 34px 16px; text-align: center; color: var(--text-3); font-size: 12.5px; }
  .empty svg { width: 38px; height: 38px; opacity: .3; margin-bottom: 8px; }
  .empty b { display: block; color: var(--text-2); font-size: 13px; font-weight: 600; margin-bottom: 2px; }

  .toast {
    position: fixed; left: 50%; bottom: 24px; transform: translate(-50%, 12px);
    z-index: 999; display: flex; align-items: flex-start; gap: 9px;
    padding: 11px 16px; border-radius: 11px; max-width: min(460px, calc(100vw - 32px));
    background: #101828; color: #fff; font-size: 13px; line-height: 1.6;
    box-shadow: 0 12px 32px -8px rgba(16,24,40,.4);
    opacity: 0; pointer-events: none; transition: opacity .22s, transform .22s;
  }
  .toast.show { opacity: 1; transform: translate(-50%, 0); }
  .toast.ok { background: #05603a; }
  .toast.err { background: #912018; }
  .toast svg { width: 16px; height: 16px; flex-shrink: 0; margin-top: 2px; }

  /* ============ 响应式 ============ */
  @media (max-width: 1000px) {
    .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .grid2 { grid-template-columns: 1fr; }
    .grid2 .card { margin-bottom: 16px; }
    .grid2 .card:last-child { margin-bottom: 0; }
  }
  @media (max-width: 720px) {
    main { padding: 14px; }
    .topbar-inner { padding: 9px 14px; gap: 10px; }
    .meta .chip.hide-sm { display: none; }
    .card { padding: 16px; border-radius: 14px; margin-bottom: 12px; }
    .table-wrap { margin: 0 -16px -16px; padding: 0 16px 2px; }
    .stat { padding: 13px; gap: 10px; }
    .stat-ico { width: 32px; height: 32px; border-radius: 9px; }
    .stat-value { font-size: 20px; }
    .stat-sub { font-size: 11px; }
    .dist-name { width: 96px; }
    .dist-val { width: 72px; font-size: 11.5px; }

    /* 表格变卡片 */
    table.log { min-width: 0; table-layout: auto; }
    table.log thead { display: none; }
    table.log, table.log tbody, table.log tr, table.log td { display: block; width: 100%; }
    table.log tr {
      border: 1px solid var(--border); border-radius: 12px;
      padding: 10px 12px; margin-bottom: 9px; background: #fff;
    }
    table.log tr:nth-child(even) td { background: transparent; }
    table.log td {
      border: 0; padding: 2px 0; white-space: normal; text-align: left;
      display: flex; gap: 10px; align-items: baseline; overflow: visible;
    }
    table.log td::before {
      content: attr(data-label); color: var(--text-3); font-size: 11px;
      width: 40px; flex-shrink: 0; font-family: inherit;
    }
    table.log td.c-path { word-break: break-all; }
    table.log td.c-path::before { font-family: inherit; }
    table.log td.empty::before { content: none; }
    table.log tr td:last-child { margin-top: 2px; }
    table.log tr.empty-row { border: 0; background: transparent; padding: 0; margin-bottom: 0; }
    table.log tr.empty-row td { display: block; text-align: center; }

  }
  @media (max-width: 560px) {
    .meta .clock-chip { display: none; }
  }
  @media (max-width: 380px) {
    .meta { display: none; }
    .tab { padding: 6px 9px; font-size: 12px; }
    main { padding: 12px; }
  }
  @media (max-width: 420px) {
    .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
    .stat-value { font-size: 18px; }
    .tab { padding: 6px 10px; font-size: 12.5px; }
  }
</style>
</head>
<body>

<header class="topbar">
  <div class="topbar-inner">
    <nav class="tabs">
      <button class="tab active" data-t="overview">概览</button>
      <button class="tab" data-t="traffic">流量</button>
      <button class="tab" data-t="blocks">记录</button>
      <button class="tab" data-t="settings">设置</button>
    </nav>
    <div class="meta">
      <span class="chip hide-sm" id="uptimeChip">—</span>
      <span class="chip p" id="portChip">:—</span>
      <span class="chip clock-chip"><i class="dot"></i><span id="clock">--:--:--</span></span>
    </div>
  </div>
</header>

<main>
  <section id="overview" class="page">
    <div class="stats">
      <div class="stat">
        <div class="stat-ico c1"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/></svg></div>
        <div class="stat-body">
          <div class="stat-label">今日请求</div>
          <div class="stat-value" id="todayReq">-</div>
          <div class="stat-sub">流量 <b id="todayBytes">0 B</b></div>
        </div>
      </div>
      <div class="stat">
        <div class="stat-ico c2"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-9-9"/><path d="M21 3v6h-6"/></svg></div>
        <div class="stat-body">
          <div class="stat-label">累计请求</div>
          <div class="stat-value" id="totalReq">-</div>
          <div class="stat-sub">流量 <b id="totalBytes">0 B</b></div>
        </div>
      </div>
      <div class="stat">
        <div class="stat-ico c3"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/></svg></div>
        <div class="stat-body">
          <div class="stat-label">拦截</div>
          <div class="stat-value danger" id="totalBlocked">-</div>
          <div class="stat-sub">地区 <b id="blockedCN">0</b> · 白名单 <b id="blockedWL">0</b></div>
        </div>
      </div>
      <div class="stat">
        <div class="stat-ico c4"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/></svg></div>
        <div class="stat-body">
          <div class="stat-label">独立 IP</div>
          <div class="stat-value" id="uniqueIPs">-</div>
          <div class="stat-sub"><b id="uniqueCountries">0</b> 个地区</div>
        </div>
      </div>

    </div>

  </section>

  <section id="traffic" class="page">
    <div class="range-bar">
      <span class="range-label">时间范围</span>
      <div class="filters" id="trRangeBar">
        <button class="filter active" data-r="all">全部</button>
        <button class="filter" data-r="today">今天</button>
        <button class="filter" data-r="7d">近 7 天</button>
        <button class="filter" data-r="30d">近 30 天</button>
        <input type="date" id="trDatePick" class="sel" title="选择具体日期">
      </div>
      <span class="range-sum" id="trSummary"></span>
    </div>
    <div class="grid2">
      <div class="card">
        <div class="card-head">
          <div>
            <h2 class="card-title">IP 分布</h2>
            <div class="card-desc">请求次数 Top 20</div>
          </div>
        </div>
        <div id="ipDist"></div>
      </div>
      <div class="card">
        <div class="card-head">
          <div>
            <h2 class="card-title">地区分布</h2>
            <div class="card-desc">按来源地区统计</div>
          </div>
        </div>
        <div id="regionDist"></div>
      </div>
    </div>
  </section>

  <section id="blocks" class="page">
    <div class="card">
      <div class="card-head">
        <div>
          <h2 class="card-title">拦截记录</h2>
          <div class="card-desc">保留一年，最新在上</div>
        </div>
        <div class="filters" id="rangeBar">
          <button class="filter active" data-r="all">全部</button>
          <button class="filter" data-r="today">今天</button>
          <button class="filter" data-r="7d">近 7 天</button>
          <button class="filter" data-r="30d">近 30 天</button>
          <input type="date" id="datePick" class="sel" title="选择具体日期">
          <span class="chip" id="cntAll">0 条</span>
        </div>
      </div>
      <div class="table-wrap">
        <table class="log">
          <colgroup>
            <col style="width:168px"><col style="width:140px"><col style="width:92px"><col><col style="width:88px">
          </colgroup>
          <thead><tr><th>时间</th><th>IP</th><th>地区</th><th>路径</th><th>原因</th></tr></thead>
          <tbody id="blocksBody"><tr class="empty-row"><td colspan="5" class="empty">暂无记录</td></tr></tbody>
        </table>
      </div>
      <div class="pager">
        <button class="btn btn-ghost" id="prevPage">上一页</button>
        <span class="page-info" id="pageInfo">1 / 1</span>
        <button class="btn btn-ghost" id="nextPage">下一页</button>
      </div>
    </div>
  </section>

  <section id="settings" class="page">
    <div class="grid2">
      <div class="card">
        <div class="card-head">
          <div>
            <h2 class="card-title">服务</h2>
            <div class="card-desc">端口修改后立即生效，无需重启</div>
          </div>
        </div>
        <div class="field">
          <label class="field-label">监听端口</label>
          <div style="display:flex; gap:10px; align-items:center; flex-wrap:wrap;">
            <input id="portInput" class="input mono" type="number" min="1" max="65535" style="width:120px;">
            <span class="chip p">当前 <span id="portNow">-</span></span>
            <button class="btn btn-primary" id="savePort">保存</button>
          </div>
        </div>
        <div class="field">
          <div class="row" style="padding-top:0;">
            <div class="row-main">
              <div class="row-label">未知 IP 用在线接口查询</div>
              <div class="row-desc">离线库查不到时调第三方 API，结果缓存 30 天</div>
            </div>
            <label class="switch"><input type="checkbox" id="geoAPI"><span class="track"></span></label>
          </div>
          <label class="field-label" style="margin-top:12px;">接口地址</label>
          <input id="geoAPIURL" class="input mono" spellcheck="false" placeholder="http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,country,countryCode">
          <div class="hint">用 <code>{ip}</code> 占位，留空使用默认 <code>ip-api.com</code></div>
          <div class="actions">
            <button class="btn btn-ghost" id="geoTest">测试接口</button>
            <button class="btn btn-ghost" id="regeoBtn">重新识别</button>
            <span class="geo-status" id="geoStatus"></span>
          </div>
          <div id="geoResult"></div>
        </div>
      </div>

      <div class="card">
        <div class="card-head">
          <div>
            <h2 class="card-title">访问控制</h2>
            <div class="card-desc">限制谁能访问、能转发到哪些目标</div>
          </div>
        </div>
        <div class="row" style="padding-top:0;">
          <div class="row-main">
            <div class="row-label">仅允许中国大陆 IP 访问</div>
            <div class="row-desc">开启后境外 IP 会被拒绝并记入拦截记录（本机/内网不受限）</div>
          </div>
          <label class="switch"><input type="checkbox" id="chinaOnly"><span class="track"></span></label>
        </div>
        <div class="divider" style="height:1px;background:var(--border);margin:14px 0;"></div>
        <div id="wlView" class="wl-list"></div>
        <div id="wlEditWrap" style="display:none;">
          <textarea id="whitelist" class="textarea" spellcheck="false" placeholder="留空 = 不限制&#10;example.com"></textarea>
          <div class="hint">每行一个，支持根域名（<code>example.com</code> 放行所有子域）和精确域名。</div>
          <div class="actions">
            <button class="btn btn-primary" id="save">保存</button>
            <button class="btn btn-ghost" id="wlCancel">取消</button>
          </div>
        </div>
        <div class="actions" id="wlViewActions">
          <button class="btn btn-ghost" id="wlEditBtn">编辑白名单</button>
        </div>
        <div class="hint">目标地址在页面上以 <code>***</code> 显示，不会暴露真实服务器。</div>
      </div>
    </div>
  </section>
</main>

<div class="modal" id="modal">
  <div class="modal-box">
    <div class="modal-head">
      <h3 id="modalTitle">记录详情</h3>
      <button class="modal-close" id="modalClose">×</button>
    </div>
    <div class="modal-body" id="modalBody"></div>
  </div>
</div>

<div id="toast" class="toast"></div>

<script>
const state = { port: 0, labels: {}, serverToday: '', range: { from: '', to: '' }, page: 1, pages: 1, total: 0 };

function fmtBytes(b) {
  if (!b) return '0 B';
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
  if (b < 1073741824) return (b / 1048576).toFixed(1) + ' MB';
  return (b / 1073741824).toFixed(2) + ' GB';
}
function fmtUptime(sec) {
  if (sec < 60) return sec + ' 秒';
  if (sec < 3600) return Math.floor(sec / 60) + ' 分钟';
  if (sec < 86400) return Math.floor(sec / 3600) + ' 小时 ' + Math.floor(sec % 3600 / 60) + ' 分';
  return Math.floor(sec / 86400) + ' 天';
}
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function toast(msg, kind) {
  const t = document.getElementById('toast');
  const ico = kind === 'err'
    ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6L9 17l-5-5"/></svg>';
  t.innerHTML = ico + '<div>' + esc(msg) + '</div>';
  t.className = 'toast show' + (kind === 'ok' ? ' ok' : kind === 'err' ? ' err' : '');
  clearTimeout(t._t);
  t._t = setTimeout(() => { t.className = 'toast'; }, 4000);
}
const LOCAL = { 'LO': '本机', 'PV': '内网', '??': '未知', '': '未知' };
function regionName(code) {
  if (!code) return '未知';
  return state.labels[code] || LOCAL[code] || code;
}
function flagBadge(text) {
  return '<span class="flag-badge">' + esc(text) + '</span>';
}
const LOCAL_CODES = { LO: 1, PV: 1, '??': 1 };
// 拦截原因：短标签用于表格，完整说明用于详情
function reasonLabel(b) {
  return b.reason === 'cn' ? '大陆限制' : '未授权';
}
// 用服务端代理的图片（Windows 不渲染国旗 emoji，必须用图）
function flagHtml(code) {
  if (!code) return flagBadge('?');
  if (code === 'LO') return flagBadge('本');
  if (code === 'PV') return flagBadge('内');
  if (code === '??' || LOCAL_CODES[code]) return flagBadge('?');
  if (!/^[A-Z]{2}$/.test(code)) return flagBadge(String(code).slice(0, 2));
  const lc = code.toLowerCase();
  return '<img class="flag-img" src="/admin/api/flag/' + lc + '" alt="' + code + '" width="20" height="15" loading="lazy">';
}
// 图片取不到时退回 emoji / 文字
document.addEventListener('error', e => {
  const img = e.target;
  if (img && img.tagName === 'IMG' && img.classList.contains('flag-img')) {
    const span = document.createElement('span');
    span.className = 'flag-badge';
    span.textContent = img.alt || '?';
    img.replaceWith(span);
  }
}, true);
function shortPath(p) {
  if (!p) return '';
  const q = p.indexOf('?');
  if (q > 0 && p.length > q + 1) return p.slice(0, q) + ' ?…';
  return p.length > 96 ? p.slice(0, 96) + '…' : p;
}

const SECTIONS = ['overview', 'traffic', 'blocks', 'settings'];
const visibleSections = new Set();
const navTabs = Array.from(document.querySelectorAll('.tab'));

function sectionInView(el) {
  const r = el.getBoundingClientRect();
  return r.top < window.innerHeight && r.bottom > 0;
}

function scrollToSection(id) {
  const el = document.getElementById(id);
  if (!el) return;
  if (id === 'blocks') { sigBlk = ''; loadBlocks(); }
  if (id === 'traffic') loadTraffic();
  el.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

navTabs.forEach(t => t.addEventListener('click', () => scrollToSection(t.dataset.t)));

let navTicking = false;
function updateNav() {
  navTicking = false;
  const hadTraffic = visibleSections.has('traffic');
  const hadBlocks = visibleSections.has('blocks');
  let active = SECTIONS[0];
  SECTIONS.forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    const top = el.getBoundingClientRect().top;
    if (sectionInView(el)) visibleSections.add(id); else visibleSections.delete(id);
    if (top <= 90) active = id;      // 已经划过吸顶栏的最后一个区块
  });
  // 滚到底部时强制高亮最后一个
  if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 8) {
    active = SECTIONS[SECTIONS.length - 1];
  }
  navTabs.forEach(b => b.classList.toggle('active', b.dataset.t === active));
  // 刚滚进视野时立即取一次，避免看到 5 秒前的旧数据
  if (!hadTraffic && visibleSections.has('traffic')) loadTraffic();
  if (!hadBlocks && visibleSections.has('blocks')) { sigBlk = ''; loadBlocks(); }
}

function onScroll() {
  if (navTicking) return;
  navTicking = true;
  requestAnimationFrame(updateNav);
}

window.addEventListener('scroll', onScroll, { passive: true });
window.addEventListener('resize', onScroll);

function applyPort(p) {
  if (!p) return;
  state.port = p;
  document.getElementById('portInput').value = p;
  document.getElementById('portNow').textContent = p;
  document.getElementById('portChip').textContent = ':' + p;
}

async function loadConfig() {
  try {
    const r = await fetch('/admin/api/config', { cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const c = await r.json();
    const wl = c.whitelist || [];
    document.getElementById('whitelist').value = wl.join('\n');
    renderWl(wl);
    document.getElementById('chinaOnly').checked = !!c.china_only;
    document.getElementById('geoAPI').checked = !!c.geo_api;
    document.getElementById('geoAPIURL').value = c.geo_api_url || '';
    applyPort(c.effective_port);
  } catch (e) {
    toast('加载配置失败: ' + e.message, 'err');
  }
}

let sigIP = '', sigReg = '', sigBlk = '';

// ============ 流量统计（带时间筛选）============
const trState = { range: { from: '', to: '' } };

async function loadTraffic() {
  const r0 = trState.range || { from: '', to: '' };
  const qs = new URLSearchParams();
  if (r0.from) qs.set('from', r0.from);
  if (r0.to) qs.set('to', r0.to);
  try {
    const r = await fetch('/admin/api/traffic' + (qs.toString() ? '?' + qs.toString() : ''), { cache: 'no-store' });
    if (!r.ok) return;
    const d = await r.json();
    if (d.today) state.serverToday = d.today;
    const sum = document.getElementById('trSummary');
    if (sum) {
      const blocked = (d.blocked_cn || 0) + (d.blocked_whitelist || 0);
      sum.innerHTML = '请求 <b>' + (d.requests || 0).toLocaleString() + '</b>' +
        '<i>·</i>流量 <b>' + fmtBytes(d.bytes || 0) + '</b>' +
        '<i>·</i>拦截 <b>' + blocked.toLocaleString() + '</b>';
    }
    const pick = document.getElementById('trDatePick');
    if (pick && d.days && d.days.length) pick.min = d.days[d.days.length - 1];
    renderIP(d.ip_counts || {});
    renderRegion(d.country_counts || {});
  } catch (e) { /* ignore */ }
}

document.getElementById('trRangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#trRangeBar .filter').forEach(b => b.classList.toggle('active', b === btn));
  document.getElementById('trDatePick').value = '';
  trState.range = rangeOf(btn.dataset.r);
  sigIP = ''; sigReg = '';
  loadTraffic();
});
document.getElementById('trDatePick').addEventListener('change', e => {
  const v = e.target.value;
  document.querySelectorAll('#trRangeBar .filter').forEach(b => b.classList.remove('active'));
  trState.range = v ? { from: v, to: v } : { from: '', to: '' };
  sigIP = ''; sigReg = '';
  loadTraffic();
});

async function loadStats() {
  try {
    const r = await fetch('/admin/api/stats', { cache: 'no-store' });
    if (!r.ok) return;
    const s = await r.json();
    // 地区中文名后到：变了就强制重绘，否则会一直显示 CN 这种代码
    const nl = s.country_labels || {};
    if (JSON.stringify(nl) !== JSON.stringify(state.labels)) {
      state.labels = nl;
      sigReg = ''; sigBlk = ''; sigIP = '';
      if (blockItems.length) drawBlocks();
      if (visibleSections.has('traffic')) loadTraffic();
    }
    if (s.port && !state.port) applyPort(s.port);

    document.getElementById('todayReq').textContent = (s.today_requests || 0).toLocaleString();
    document.getElementById('todayBytes').textContent = fmtBytes(s.today_bytes || 0);
    document.getElementById('totalReq').textContent = (s.total_requests || 0).toLocaleString();
    document.getElementById('totalBytes').textContent = fmtBytes(s.total_bytes || 0);
    const bc = s.blocked_cn || 0, bw = s.blocked_whitelist || 0;
    document.getElementById('totalBlocked').textContent = (bc + bw).toLocaleString();
    document.getElementById('blockedCN').textContent = bc.toLocaleString();
    document.getElementById('blockedWL').textContent = bw.toLocaleString();
    document.getElementById('uniqueIPs').textContent = Object.keys(s.ip_counts || {}).length.toLocaleString();
    document.getElementById('uniqueCountries').textContent = Object.keys(s.country_counts || {}).length;
    document.getElementById('clock').textContent = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    if (typeof s.uptime_sec === 'number') {
      document.getElementById('uptimeChip').textContent = '已运行 ' + fmtUptime(s.uptime_sec);
    }

    const gs = document.getElementById('geoStatus');
    if (s.regeo_running) gs.textContent = '识别中 ' + (s.regeo_done || 0) + '/' + (s.regeo_total || 0);
    else if (s.geo_ok || s.geo_fail) gs.textContent = '查询 成功 ' + (s.geo_ok || 0) + ' · 失败 ' + (s.geo_fail || 0);
    else gs.textContent = '';

    if (visibleSections.has('traffic')) loadTraffic();
    if (visibleSections.has('blocks')) loadBlocks();
  } catch (e) { /* ignore */ }
}
function renderIP(map) {
  const rows = Object.entries(map).sort((a, b) => b[1] - a[1]).slice(0, 20);
  const sig = JSON.stringify(rows);
  if (sig === sigIP) return;
  sigIP = sig;
  const box = document.getElementById('ipDist');
  if (!rows.length) {
    box.innerHTML = '<div class="empty"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 3v18h18"/><path d="M7 15l4-5 3 3 5-7"/></svg><b>暂无数据</b>有请求后自动统计</div>';
    return;
  }
  const max = rows[0][1] || 1;
  box.innerHTML = rows.map(([ip, n]) => `
    <div class="dist-row">
      <span class="dist-name mono" title="${esc(ip)}"><span class="txt">${esc(ip)}</span></span>
      <div class="bar ind"><i style="width:${(n / max * 100).toFixed(1)}%"></i></div>
      <span class="dist-val">${n.toLocaleString()}</span>
    </div>`).join('');
}

function renderRegion(map) {
  const rows = Object.entries(map).sort((a, b) => b[1] - a[1]).slice(0, 20);
  const sig = JSON.stringify(rows);
  if (sig === sigReg) return;
  sigReg = sig;
  const box = document.getElementById('regionDist');
  if (!rows.length) {
    box.innerHTML = '<div class="empty"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18 15 15 0 0 1 0-18"/></svg><b>暂无数据</b>有请求后自动统计</div>';
    return;
  }
  const total = rows.reduce((s, r) => s + r[1], 0) || 1;
  const max = rows[0][1] || 1;
  box.innerHTML = rows.map(([code, n]) => {
    const nm = regionName(code);
    return `
    <div class="dist-row">
      <span class="dist-name" title="${esc(nm)}（${esc(code)}）">
        ${flagHtml(code)}<span class="txt">${esc(nm)}</span>
      </span>
      <div class="bar teal"><i style="width:${(n / max * 100).toFixed(1)}%"></i></div>
      <span class="dist-val">${n.toLocaleString()}<span>${(n / total * 100).toFixed(0)}%</span></span>
    </div>`;
  }).join('');
}

function maskHost(h) {
  h = String(h || '').trim();
  if (!h) return '';
  const port = h.includes(':') ? ':' + h.split(':').pop() : '';
  const host = h.split(':')[0];
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
    const p = host.split('.');
    return p[0] + '.' + p[1] + '.*.*' + port;
  }
  const parts = host.split('.');
  if (parts.length <= 1) return '***' + port;
  return '***.' + parts[parts.length - 1] + port;
}

let blockItems = [];
const dayStr = d => {
  const p = n => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
};
// “今天”以服务器日期为准：两边时区不同时按浏览器算会差一天，
// 导致明明有数据、选今天却查不到
function rangeOf(mode) {
  const t = state.serverToday || dayStr(new Date());
  const base = new Date(t + 'T00:00:00');
  if (mode === 'today') return { from: t, to: t };
  if (mode === '7d') {
    const f = new Date(base); f.setDate(f.getDate() - 6);
    return { from: dayStr(f), to: t };
  }
  if (mode === '30d') {
    const f = new Date(base); f.setDate(f.getDate() - 29);
    return { from: dayStr(f), to: t };
  }
  return { from: '', to: '' };
}
async function loadBlocks() {
  const r0 = state.range || { from: '', to: '' };
  const qs = new URLSearchParams();
  if (r0.from) qs.set('from', r0.from);
  if (r0.to) qs.set('to', r0.to);
  qs.set('page', String(state.page || 1));
  qs.set('size', '20');
  try {
    const r = await fetch('/admin/api/blocks?' + qs.toString(), { cache: 'no-store' });
    if (!r.ok) return;
    const data = await r.json();
    if (data.today) state.serverToday = data.today;
    const total = data.total || 0;
    state.page = data.page || 1;
    state.pages = data.pages || 1;
    state.total = total;
    document.getElementById('cntAll').textContent = total.toLocaleString() + ' 条';
    updatePager();
    if (data.dates && data.dates.length) {
      document.getElementById('datePick').min = data.dates[data.dates.length - 1];
    }
    const sig = JSON.stringify(data.items || []);
    if (sig === sigBlk) return;
    sigBlk = sig;
    blockItems = data.items || [];
    drawBlocks();
  } catch (e) { /* ignore */ }
}


function updatePager() {
  document.getElementById('pageInfo').textContent =
    state.page + ' / ' + state.pages + ' 页 · 共 ' + (state.total || 0) + ' 条';
  document.getElementById('prevPage').disabled = state.page <= 1;
  document.getElementById('nextPage').disabled = state.page >= state.pages;
}

function drawBlocks() {
  const body = document.getElementById('blocksBody');
  if (!blockItems.length) {
    body.innerHTML = '<tr class="empty-row"><td colspan="5" class="empty"><b>暂无记录</b>被白名单拦下的请求会出现在这里</td></tr>';
    return;
  }
  body.innerHTML = blockItems.map((b, i) => `
    <tr class="row-click" data-i="${i}">
      <td class="c-time" data-label="时间">${esc(b.time)}</td>
      <td class="c-ip" data-label="IP">${esc(b.ip)}</td>
      <td data-label="地区" class="c-region"><span class="rg-cell">${flagHtml(b.country)}<span>${esc(regionName(b.country))}</span></span></td>
      <td class="c-path" data-label="路径" title="${esc(b.path)}">${esc(shortPath(b.path))}</td>
      <td data-label="原因"><span class="pill ${b.reason === 'cn' ? 'pill-cn' : 'pill-wl'}" title="${esc(b.reason_text || reasonLabel(b))}">${esc(reasonLabel(b))}</span></td>
    </tr>`).join('');
}

function showDetail(b) {
  document.getElementById('modalTitle').textContent = '记录详情';
  document.getElementById('modalBody').innerHTML = [
    ['时间', esc(b.time), false],
    ['IP', esc(b.ip), true],
    ['地区', esc(regionName(b.country)), false],
    ['原因', '<span class="pill ' + (b.reason === 'cn' ? 'pill-cn' : 'pill-wl') + '">' + esc(b.reason_text || reasonLabel(b)) + '</span>', false],
    ['路径', esc(b.path), true],
    ['UA', esc(b.ua || '（未记录）'), true]
  ].map(([k, v, mono]) => `<div class="kv"><div class="kv-k">${k}</div><div class="kv-v${mono ? ' mono' : ''}">${v}</div></div>`).join('')
    ;
  document.getElementById('modal').classList.add('show');
}

document.getElementById('blocksBody').addEventListener('click', e => {
  const tr = e.target.closest('tr[data-i]');
  if (!tr) return;
  const b = blockItems[+tr.dataset.i];
  if (b) showDetail(b);
});
document.getElementById('modalClose').addEventListener('click', () => document.getElementById('modal').classList.remove('show'));
document.getElementById('modal').addEventListener('click', e => {
  if (e.target.id === 'modal') e.currentTarget.classList.remove('show');
});
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') document.getElementById('modal').classList.remove('show');
});
document.getElementById('rangeBar').addEventListener('click', e => {
  const btn = e.target.closest('.filter[data-r]');
  if (!btn) return;
  document.querySelectorAll('#rangeBar .filter').forEach(b => b.classList.toggle('active', b === btn));
  document.getElementById('datePick').value = '';
  state.range = rangeOf(btn.dataset.r);
  state.page = 1;
  sigBlk = '';
  loadBlocks();
});
document.getElementById('prevPage').addEventListener('click', () => {
  if (state.page > 1) { state.page--; sigBlk = ''; loadBlocks(); }
});
document.getElementById('nextPage').addEventListener('click', () => {
  if (state.page < state.pages) { state.page++; sigBlk = ''; loadBlocks(); }
});
document.getElementById('datePick').addEventListener('change', e => {
  const v = e.target.value;
  document.querySelectorAll('#rangeBar .filter').forEach(b => b.classList.remove('active'));
  state.range = v ? { from: v, to: v } : { from: '', to: '' };
  state.page = 1;
  sigBlk = '';
  loadBlocks();
});


function collect(useInputPort) {
  const raw = parseInt(document.getElementById('portInput').value, 10);
  return {
    port: useInputPort ? (isNaN(raw) ? 0 : raw) : state.port,
    china_only: document.getElementById('chinaOnly').checked,
    whitelist: document.getElementById('whitelist').value.split('\n').map(x => x.trim()).filter(Boolean),
    geo_api: document.getElementById('geoAPI').checked,
    geo_api_url: document.getElementById('geoAPIURL').value.trim()
  };
}

async function save(opts) {
  const o = opts || {};
  try {
    const r = await fetch('/admin/api/save', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(collect(!!o.useInputPort))
    });
    const txt = await r.text();
    if (!r.ok) throw new Error(txt.trim() || ('HTTP ' + r.status));
    const c = JSON.parse(txt);
    if (c.effective_port) applyPort(c.effective_port);
    if (o.msg) toast(o.msg, 'ok');
    return true;
  } catch (e) {
    toast('保存失败: ' + e.message, 'err');
    return false;
  }
}

function renderWl(list) {
  const box = document.getElementById('wlView');
  if (!list || !list.length) {
    box.innerHTML = '<span class="wl-empty">未限制，转发任意目标</span>';
    return;
  }
  box.innerHTML = list.map(h => '<span class="wl-item">' + esc(maskHost(h)) + '</span>').join('');
}
function wlMode(edit) {
  document.getElementById('wlView').style.display = edit ? 'none' : 'flex';
  document.getElementById('wlViewActions').style.display = edit ? 'none' : 'flex';
  document.getElementById('wlEditWrap').style.display = edit ? 'block' : 'none';
}
document.getElementById('wlEditBtn').addEventListener('click', () => wlMode(true));
document.getElementById('wlCancel').addEventListener('click', () => {
  loadConfig();
  wlMode(false);
});
document.getElementById('save').addEventListener('click', async () => {
  if (await save({ msg: '白名单已保存' })) {
    renderWl(document.getElementById('whitelist').value.split('\n').map(x => x.trim()).filter(Boolean));
    wlMode(false);
  }
});
function askJump(p) {
  const host = location.hostname || 'localhost';
  const url = location.protocol + '//' + host + ':' + p + '/admin/';
  document.getElementById('modalTitle').textContent = '端口已切换';
  document.getElementById('modalBody').innerHTML =
    '<div class="kv"><div class="kv-k">新地址</div><div class="kv-v mono">' + esc(url) + '</div></div>' +
    '<div class="hint" style="margin-top:10px;">服务已在新端口监听，当前页面即将失效。</div>' +
    '<div class="actions" style="margin-top:16px;">' +
    '<button class="btn btn-primary" id="jumpNow">立即跳转</button>' +
    '<button class="btn btn-ghost" id="jumpLater">稍后</button></div>';
  document.getElementById('modal').classList.add('show');
  document.getElementById('jumpNow').addEventListener('click', () => { location.href = url; });
  document.getElementById('jumpLater').addEventListener('click', () => {
    document.getElementById('modal').classList.remove('show');
    document.getElementById('portInput').value = state.port;
  });
}

document.getElementById('savePort').addEventListener('click', async () => {
  const raw = parseInt(document.getElementById('portInput').value, 10);
  if (isNaN(raw) || raw < 1 || raw > 65535) { toast('端口需在 1-65535 之间', 'err'); return; }
  if (raw === state.port) { toast('端口没有变化', 'err'); return; }
  const old = state.port;
  const btn = document.getElementById('savePort');
  btn.disabled = true;
  const ok = await save({ useInputPort: true });
  btn.disabled = false;
  if (!ok) return;
  if (state.port !== old) askJump(state.port);
  else document.getElementById('portInput').value = state.port;
});

document.getElementById('chinaOnly').addEventListener('change', async () => {
  const on = document.getElementById('chinaOnly').checked;
  if (await save({})) toast(on ? '已开启：仅中国大陆可访问' : '已关闭大陆限制', 'ok');
});
document.getElementById('geoAPI').addEventListener('change', async () => {
  const on = document.getElementById('geoAPI').checked;
  if (await save({})) toast(on ? '已开启在线查询' : '已关闭在线查询', 'ok');
});
document.getElementById('geoAPIURL').addEventListener('change', async () => {
  if (await save({})) toast('接口地址已保存', 'ok');
});
document.getElementById('geoTest').addEventListener('click', async () => {
  const btn = document.getElementById('geoTest');
  const out = document.getElementById('geoResult');
  btn.disabled = true;
  out.innerHTML = '<div class="notice notice-info">正在请求接口…</div>';
  await save({});
  try {
    const r = await fetch('/admin/api/geotest', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    const d = await r.json();
    if (d.ok) {
      out.innerHTML = '<div class="notice notice-ok">接口正常：' + esc(d.ip) + ' → ' + esc(d.name) + '（' + esc(d.code) + '）</div>';
    } else {
      out.innerHTML = '<div class="notice notice-warn">接口失败：' + esc(d.error) + '<br><code>' + esc(d.url) + '</code></div>';
    }
  } catch (e) {
    out.innerHTML = '<div class="notice notice-warn">请求失败：' + esc(e.message) + '</div>';
  }
  btn.disabled = false;
});
document.getElementById('regeoBtn').addEventListener('click', async () => {
  const btn = document.getElementById('regeoBtn');
  btn.disabled = true;
  try {
    const r = await fetch('/admin/api/regeo', { method: 'POST' });
    const d = await r.json();
    toast(d.started ? '开始重新识别，进度见左侧' : '正在识别中', 'ok');
    setTimeout(() => { loadStats(); btn.disabled = false; }, 700);
  } catch (e) {
    toast('启动失败: ' + e.message, 'err');
    btn.disabled = false;
  }
});

updateNav();
loadConfig();
loadStats();
loadTraffic();
sigBlk = '';
loadBlocks();
setInterval(loadStats, 5000);
</script>
</body>
</html>
ADMIN_HTML
}
compute_source_hash() {
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum，无法校验源码版本"
  local d h
  d="$(mktemp -d)"
  write_go_source "$d"
  h="$(cd "$d" && sha256sum main.go admin.html | sha256sum | awk '{print $1}')"
  rm -rf "$d"
  printf '%s' "$h"
}
genpass() {
  head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20
}
write_default_config() {
  cat > "$CONFIG_FILE" <<'JSON'
{
  "port": 0,
  "china_only": false,
  "whitelist": [],
  "geo_api": true,
  "geo_api_url": ""
}
JSON
}
# systemd 的 ExecStart 用空白拆参数，密码含空格/引号/% 时必须转义，否则服务起不来
systemd_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//%/%%}"
  printf '"%s"' "$s"
}
make_unit() {
  local user_q pass_q
  user_q="$(systemd_quote "$ADMIN_USER")"
  pass_q="$(systemd_quote "$ADMIN_PASS")"
  cat <<UNIT
[Unit]
Description=Emby Path Reverse Proxy (Go)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${BIN_PATH} run -port ${PORT} -admin-user ${user_q} -admin-pass ${pass_q} -config ${CONFIG_FILE} -stats ${STATS_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
UNIT
}
build_binary() {
  local out="$1"
  if [[ -n "$PREBUILT" ]]; then
    [[ -f "$PREBUILT" ]] || die "预构建二进制不存在: $PREBUILT"
    cp -f "$PREBUILT" "$out"
    chmod 0755 "$out"
    return
  fi
  ensure_go
  BUILD_TMPDIR="$(mktemp -d)"
  write_go_source "$BUILD_TMPDIR"
  info "初始化模块并解析依赖..."
  (
    cd "$BUILD_TMPDIR"
    # 允许 Go 在需要时自动下载匹配的工具链，避免依赖要求更高版本时直接失败
    export GOTOOLCHAIN=auto
    export GOFLAGS=-mod=mod
    go mod init emby-proxy >/dev/null 2>&1 || true
    go get "github.com/phuslu/iploc@${IPLOC_VERSION}" >/dev/null 2>&1 || true
    go mod tidy >/dev/null 2>&1 || true
    grep -q "phuslu/iploc" go.mod 2>/dev/null || go get "github.com/phuslu/iploc@latest" >/dev/null 2>&1 || true
    go mod tidy >/dev/null 2>&1 || die "依赖解析失败（网络问题可设置 GOPROXY=https://goproxy.cn,direct 后重试，或用 --prebuilt 跳过）"
  )
  info "编译中..."
  ( cd "$BUILD_TMPDIR" && CGO_ENABLED=0 GOTOOLCHAIN=auto GOFLAGS=-mod=mod \
      go build -trimpath -ldflags "-s -w" -o "$out" . ) \
    || die "go build 失败"
}
local_ip() {
  local ip=""
  # hostname -I 是 GNU coreutils 的便捷写法；部分精简系统没有，逐级回退
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  fi
  if [[ -z "$ip" ]]; then ip="127.0.0.1"; fi
  printf '%s' "$ip"
}
port_listen() { (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null; }
# 重装时若没显式给 --port，沿用已装端口（配置优先，其次 unit）
installed_port() {
  local p=""
  if [[ -f "$CONFIG_FILE" ]]; then
    p="$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]\+' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]\+$' | head -1)"
  fi
  if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p == 0 )); then
    if [[ -f "$UNIT_FILE" ]]; then
      p="$(sed -n 's/.*-port \([0-9]\{1,5\}\).*/\1/p' "$UNIT_FILE" | head -1)"
    fi
  fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; else printf '%s' "$DEFAULT_PORT"; fi
}
# 实际生效的端口：配置 > 服务单元 > 本次参数
effective_port() {
  local p=""
  if [[ -f "$CONFIG_FILE" ]]; then
    p="$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$' | head -1)"
  fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; return; fi
  if [[ -f "$UNIT_FILE" ]]; then
    p="$(sed -n 's/.*-port \([0-9]\{1,5\}\).*/\1/p' "$UNIT_FILE" | head -1)"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; return; fi
  fi
  printf '%s' "$PORT"
}
print_access_info() {
  local ip; ip="$(local_ip)"
  local ep; ep="$(effective_port)"
  printf '\n'
  printf '   管理页:  http://%s:%s/admin/\n' "$ip" "$ep"
  printf '   用户名:  %s\n' "$ADMIN_USER"
  printf '   密  码:  %s\n' "$ADMIN_PASS"
  if [[ $GENERATED_PASS -eq 1 ]]; then
    printf '           （已保存到 %s）\n' "$ADMIN_PASS_FILE"
  else
    printf '           （沿用已保存的密码，文件 %s）\n' "$ADMIN_PASS_FILE"
  fi
  printf '\n   👉 用法：把原来的地址塞进路径里\n'
  printf '      原:  https://www.example.com/emby/Users\n'
  printf '      改:  http://%s:%s/https://www.example.com/emby/Users\n' "$ip" "$ep"
  printf '      （客户端里就填这一长串，反代负责转发到真实地址）\n'
  printf '\n   配置文件: %s\n' "$CONFIG_FILE"
  printf '   统计文件: %s\n' "$STATS_FILE"
  printf '   查看日志: journalctl -u %s -f\n' "$SERVICE_NAME"
  printf '\n'
}
cmd_install() {
  parse_install_args "$@"
  require_root install
  require_systemd

  # 交互终端里没显式给参数时，就地询问端口 / 密码
  # 注意用 PASS_GIVEN 判断：显式传空密码表示「自动生成」，不能再问一遍
  if [[ -t 0 ]] && [[ $BINARY_ONLY -eq 0 ]] && [[ $PORT_GIVEN -eq 0 || $PASS_GIVEN -eq 0 ]]; then
    printf '\n'
    if [[ $PORT_GIVEN -eq 0 ]]; then
      prompt_port "$(installed_port)" || die "已取消"
      PORT="$PROMPT_RESULT"
    fi
    if [[ -z "$ADMIN_PASS" ]]; then
      prompt_pass || die "已取消"
      ADMIN_PASS="$PROMPT_RESULT"
      PASS_GIVEN=1
    fi
  fi

  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口无效: $PORT"
  if [[ $BINARY_ONLY -eq 1 ]]; then
    info "更新模式：只替换程序，配置 / 密码 / 统计保持不变"
  fi
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  if [[ "$ADMIN_PASS" == *$'\n'* || "$ADMIN_PASS" == *$'\r'* ]]; then
    die "密码不能包含换行符"
  fi
  if [[ -n "$ADMIN_PASS" ]]; then
    ( umask 077; printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE" )
    GENERATED_PASS=1
  elif [[ -f "$ADMIN_PASS_FILE" ]]; then
    ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
    GENERATED_PASS=0
  else
    ADMIN_PASS="$(genpass)"
    ( umask 077; printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE" )
    GENERATED_PASS=1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    write_default_config
    info "已创建配置文件: $CONFIG_FILE"
  elif [[ $BINARY_ONLY -eq 1 ]]; then
    : # 更新模式：已有配置一律不动
  fi
  local expected_unit; expected_unit="$(make_unit)"
  local need_compile=0 need_reload=0 new_hash=""
  if [[ -n "$PREBUILT" || $FORCE -eq 1 ]]; then
    need_compile=1
  elif [[ ! -x "$BIN_PATH" || ! -f "$BUILD_HASH_FILE" ]]; then
    need_compile=1
  else
    new_hash="$(compute_source_hash)"
    if [[ "$new_hash" != "$(cat "$BUILD_HASH_FILE" 2>/dev/null || true)" ]]; then
      need_compile=1
      info "检测到源码变化，需要重新编译"
    fi
  fi
  if [[ "$(cat "$UNIT_FILE" 2>/dev/null || true)" != "$expected_unit" ]]; then
    need_reload=1
  fi
  # 更新代码时不碰 systemd unit，避免把用户手工调整过的启动参数覆盖掉
  if [[ $BINARY_ONLY -eq 1 ]]; then
    need_reload=0
  fi
  if [[ $need_compile -eq 0 && $need_reload -eq 0 ]]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      info "已是最新版本，服务运行中，跳过编译与重装"
    else
      info "已是最新版本，服务未运行，正在启动..."
      systemctl start "$SERVICE_NAME"
    fi
    print_access_info
    return
  fi
  if [[ $need_compile -eq 1 ]]; then
    local stage; stage="$(mktemp -d)/emby-proxy"
    build_binary "$stage"
    info "二进制编译完成"
    stop_and_disable
    mkdir -p "$(dirname "$BIN_PATH")"
    local tmp_dst="${BIN_PATH}.tmp.$$"
    cp -f "$stage" "$tmp_dst"
    chmod 0755 "$tmp_dst"
    mv -f "$tmp_dst" "$BIN_PATH"
    info "已安装二进制: $BIN_PATH"
    if [[ -z "$PREBUILT" ]]; then
      [[ -n "$new_hash" ]] || new_hash="$(compute_source_hash)"
      printf '%s' "$new_hash" > "$BUILD_HASH_FILE"
    else
      rm -f "$BUILD_HASH_FILE"
    fi
  fi
  if [[ $need_reload -eq 1 ]]; then
    printf '%s\n' "$expected_unit" > "$UNIT_FILE"
    chmod 0644 "$UNIT_FILE"
    info "已更新 systemd unit: $UNIT_FILE"
    systemctl daemon-reload
  fi
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    if port_listen "$(effective_port)"; then
      info "🎉 安装完成！端口 $(effective_port) 已监听"
    else
      warn "服务已启动，但端口 $(effective_port) 暂未监听（稍等几秒或查看日志）"
    fi
    print_access_info
  else
    err "服务启动失败，请查看: journalctl -u $SERVICE_NAME -n 80 --no-pager"
    exit 1
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
    if [[ ! -t 0 ]]; then
      die "非交互环境请加 --yes 确认卸载"
    fi
    printf '%s\n' "即将卸载 ${SERVICE_NAME}。"
    if [[ $keep -eq 1 ]]; then
      printf '   保留配置与统计: %s\n' "$CONFIG_DIR"
    else
      printf '%s\n' "   配置、密码、统计、缓存将一并删除（不可恢复）"
    fi
    printf '  输入 y 确认: '
    local ans=""
    read -r ans || true
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "已取消"; return 0; }
  fi

  # 从 unit 里取实际安装路径，用户可能用 --bin 装到了别处
  local installed_bin=""
  if [[ -f "$UNIT_FILE" ]]; then
    installed_bin="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$UNIT_FILE" | head -n1)"
  fi

  stop_and_disable
  if [[ -f "$UNIT_FILE" ]]; then
    rm -f "$UNIT_FILE"
    info "已删除服务单元: $UNIT_FILE"
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

  local removed_bin=0
  if [[ -n "$installed_bin" && -f "$installed_bin" ]]; then
    rm -f "$installed_bin"
    info "已删除程序: $installed_bin"
    removed_bin=1
  fi
  if [[ -f "$DEFAULT_BIN" ]]; then
    rm -f "$DEFAULT_BIN"
    info "已删除程序: $DEFAULT_BIN"
    removed_bin=1
  fi
  [[ $removed_bin -eq 1 ]] || warn "没有找到程序文件（可能已被手工删除）"

  if [[ $keep -eq 1 ]]; then
    warn "已保留配置目录: $CONFIG_DIR"
    warn "若以后要彻底清掉: rm -rf $CONFIG_DIR"
  else
    # 先统计一下，让用户知道删了什么
    if [[ -d "$CONFIG_DIR" ]]; then
      local files
      files="$(find "$CONFIG_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
      local size
      size="$(du -sh "$CONFIG_DIR" 2>/dev/null | awk '{print $1}')"
      rm -rf "$CONFIG_DIR"
      info "已删除配置目录: $CONFIG_DIR（${files} 个文件，${size:-?}）"
    fi
  fi

  # 顺手清掉可能残留的临时文件
  rm -f "${DEFAULT_BIN}.tmp."* 2>/dev/null || true

  printf '\n'
  if [[ $keep -eq 1 ]]; then
    info "卸载完成：服务与程序已删除，配置数据保留在 $CONFIG_DIR"
  else
    info "卸载完成：服务、程序、配置、统计均已清除"
  fi
  printf '   Go 工具链未删除（可能被其他程序使用）；如需清理: rm -rf /usr/local/go\n\n'
}
cmd_update() {
  require_root update
  require_systemd
  if [[ ! -f "$UNIT_FILE" ]] && ! has_binary; then
    die "还没有安装，请先执行: sudo $0 install"
  fi
  cmd_install --force --code-only "$@"
}
cmd_ctl() { require_root "$1"; require_systemd; systemctl "$1" "$SERVICE_NAME"; }
cmd_status() { require_systemd; systemctl status "$SERVICE_NAME" --no-pager -l || true; }
# ============ 交互菜单 ============
C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
C_B=$'\033[1m'; C_D=$'\033[2m'; C_C=$'\033[1;36m'; C_0=$'\033[0m'
if [[ ! -t 1 ]]; then C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_C=""; C_0=""; fi

svc_state() {
  if [[ ! -f "$UNIT_FILE" && ! -x "$BIN_PATH" && ! -x "$DEFAULT_BIN" ]]; then
    printf '未安装'
    return
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    printf '运行中'
  else
    printf '已停止'
  fi
}

svc_state_colored() {
  case "$(svc_state)" in
    运行中) printf '%s' "${C_G}● 运行中${C_0}" ;;
    已停止) printf '%s' "${C_Y}● 已停止${C_0}" ;;
    *)      printf '%s' "${C_D}○ 未安装${C_0}" ;;
  esac
}

has_binary() {
  [[ -x "$BIN_PATH" || -x "$DEFAULT_BIN" ]]
}

# 只要还留有 unit / 程序 / 配置目录，就认为有东西可卸载
has_install() {
  [[ -f "$UNIT_FILE" ]] && return 0
  has_binary && return 0
  [[ -d "$CONFIG_DIR" ]]
}

installed_bin_path() {
  if [[ -x "$BIN_PATH" ]]; then printf '%s' "$BIN_PATH"; return; fi
  if [[ -x "$DEFAULT_BIN" ]]; then printf '%s' "$DEFAULT_BIN"; fi
}

build_time() {
  local b; b="$(installed_bin_path)"
  if [[ -n "$b" ]]; then
    date -r "$b" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '未知'
  else
    printf '—'
  fi
}

menu_rule() {
  printf '  %s%s%s\n' "$C_D" "───────────────────────────────────────────────────────" "$C_0"
}

menu_banner() {
  local ip ep
  ip="$(local_ip)"; ep="$(effective_port)"
  printf '\n'
  menu_rule
  printf '   %sEmby 路径反代%s   %s管理菜单%s\n' "$C_B" "$C_0" "$C_D" "$C_0"
  menu_rule
  printf '\n'
  printf '   %s服务%s   %s    %s端口%s   %s%s\n' \
    "$C_D" "$C_0" "$(svc_state_colored)" "$C_D" "$C_0" "${C_C}:${ep}${C_0}"
  printf '   %s访问%s   %s\n' "$C_D" "$C_0" "http://${ip}:${ep}/admin/"
  printf '   %s构建%s   %s\n' "$C_D" "$C_0" "$(build_time)"
  printf '\n'
  menu_rule
  printf '\n'
  printf '   %s1%s   安装 / 重新安装    %s设置端口与密码，完整装一遍%s\n' \
    "$C_B" "$C_0" "$C_D" "$C_0"
  printf '   %s2%s   更新代码           %s重新编译并替换程序，配置与数据不动%s\n' "$C_B" "$C_0" "$C_D" "$C_0"
  printf '   %s3%s   卸载               %s停止服务，删除程序、配置、统计%s\n' "$C_B" "$C_0" "$C_D" "$C_0"
  printf '   %s4%s   运行状态           %s查看服务详细状态%s\n' "$C_B" "$C_0" "$C_D" "$C_0"
  printf '   %s5%s   查看日志           %s最近 60 行%s\n' "$C_B" "$C_0" "$C_D" "$C_0"
  printf '   %s0%s   退出\n' "$C_B" "$C_0"
  printf '\n'
  menu_rule
  printf '   %s直接回车 = 重新显示菜单%s\n' "$C_D" "$C_0"
  printf '\n'
}

press_enter() {
  printf '\n%s按回车返回菜单…%s' "$C_D" "$C_0"
  read -r _ || true
}

log_tail() {
  if ! command -v journalctl >/dev/null 2>&1; then
    warn "没有 journalctl，无法读取日志"
    return 0
  fi
  journalctl -u "$SERVICE_NAME" -n 60 --no-pager 2>/dev/null || warn "读取日志失败"
}

# 回车视为同意
ask_yes_default() {
  printf '  %s ' "$1"
  local a=""
  read -r a || a=""
  case "$a" in
    n|N|no|NO|No) return 1 ;;
    *) return 0 ;;
  esac
}

ask_yes() {
  printf '  %s ' "$1"
  local a=""
  read -r a || a=""
  [[ "$a" == "y" || "$a" == "Y" ]]
}

# 交互询问的返回值存在 PROMPT_RESULT，避免把提示文本一起捕获
PROMPT_RESULT=""
prompt_port() {
  local def="$1" port=""
  while true; do
    printf '   %s监听端口%s [%s]: ' "$C_D" "$C_0" "$def"
    if ! read -r port; then
      printf '\n'
      return 1
    fi
    port="${port//[[:space:]]/}"
    if [[ -z "$port" ]]; then
      PROMPT_RESULT="$def"
      return 0
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      warn "端口需要是 1-65535 之间的数字"
      continue
    fi
    # 被别的程序占用时提醒（自己装在上面跑属于正常）
    if port_listen "$port" && [[ "$port" != "$(effective_port)" ]]; then
      if ! ask_yes "端口 $port 已被占用，仍要使用？[y/N]"; then
        continue
      fi
    fi
    PROMPT_RESULT="$port"
    return 0
  done
}

prompt_pass() {
  local pass=""
  printf '   %s管理密码%s [留空 = 自动生成]: ' "$C_D" "$C_0"
  if ! read -r pass; then
    printf '\n'
    return 1
  fi
  if [[ "$pass" != *[![:space:]]* ]]; then
    pass=""
  fi
  PROMPT_RESULT="$pass"
  return 0
}

# 安装前询问端口与密码
menu_install_flow() {
  printf '\n'
  printf '   %s安装 / 重新安装%s\n' "$C_B" "$C_0"
  printf '   %s括号内为默认值，直接回车即可%s\n\n' "$C_D" "$C_0"

  if [[ "$(svc_state)" == "运行中" ]]; then
    warn "服务正在运行，安装会先停止服务；配置、白名单、统计都会保留"
    printf '\n'
  fi

  local def_port port pass
  def_port="$(installed_port)"
  prompt_port "$def_port" || return 1
  port="$PROMPT_RESULT"
  prompt_pass || return 1
  pass="$PROMPT_RESULT"

  printf '\n'
  menu_rule
  printf '   %s端口%s   %s\n' "$C_D" "$C_0" "$port"
  if [[ -n "$pass" ]]; then
    printf '   %s密码%s   %s\n' "$C_D" "$C_0" "$pass"
  elif [[ -f "$ADMIN_PASS_FILE" ]]; then
    printf '   %s密码%s   沿用已保存的密码\n' "$C_D" "$C_0"
  else
    printf '   %s密码%s   自动生成随机密码\n' "$C_D" "$C_0"
  fi
  printf '   %s访问%s   http://%s:%s/admin/\n' "$C_D" "$C_0" "$(local_ip)" "$port"
  menu_rule
  printf '\n'

  if ! ask_yes_default "开始安装？[Y/n]"; then
    info "已取消"
    return 0
  fi
  printf '\n'

  # 密码留空也要传：告诉 install「已经问过了，按自动生成处理」
  local args=( --port "$port" --admin-pass "$pass" )
  if ( cmd_install "${args[@]}" ); then
    return 0
  fi
  warn "安装失败，请查看上面的错误信息"
  return 1
}

cmd_menu() {
  if [[ $EUID -ne 0 ]]; then
    die "菜单需要 root 权限，请用: sudo $0"
  fi
  if [[ ! -t 0 ]]; then
    die "菜单需要在交互终端运行；非交互环境请用子命令: install / update / uninstall"
  fi

  while true; do
    if [[ -t 1 ]]; then clear 2>/dev/null || true; fi
    menu_banner
    printf '  请输入序号: '
    local choice=""
    read -r choice || { printf '\n'; return 0; }
    choice="${choice//[[:space:]]/}"

    case "$choice" in
      1)
        menu_install_flow || true
        press_enter
        ;;
      2)
        printf '\n'
        if [[ ! -f "$UNIT_FILE" ]] && ! has_binary; then
          warn "还没有安装，请先选择 1 安装"
          sleep 1
          continue
        fi
        ( cmd_update ) || warn "更新失败，请查看上面的错误信息"
        press_enter
        ;;
      3)
        printf '\n'
        if ! has_install; then
          warn "当前没有安装，也没有残留文件，无需卸载"
          sleep 1
          continue
        fi
        if [[ ! -f "$UNIT_FILE" ]] && ! has_binary; then
          warn "服务与程序已不存在，仅剩配置目录：$CONFIG_DIR"
        fi
        warn "卸载会删除：服务、程序、配置、管理密码、统计数据、地区缓存"
        warn "全部清除，不可恢复"
        if ! ask_yes "输入 y 确认卸载: [y/N]"; then info "已取消"; sleep 1; continue; fi
        ( cmd_uninstall --yes ) || warn "卸载过程中出现问题"
        press_enter
        ;;
      4)
        printf '\n'
        cmd_status
        press_enter
        ;;
      5)
        printf '\n'
        log_tail
        press_enter
        ;;
      0|q|Q|exit|quit)
        printf '\n'
        info "已退出"
        return 0
        ;;
      "")
        continue
        ;;
      *)
        warn "无效的序号: $choice"
        sleep 1
        ;;
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
    *) die "未知命令: $sub（可用: menu / install / update / uninstall / status / start / stop / restart）" ;;
  esac
}

main "$@"
