#!/usr/bin/env bash
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
PORT=$DEFAULT_PORT
BIN_PATH=$DEFAULT_BIN
ADMIN_USER="admin"
ADMIN_PASS=""
PREBUILT=""
FORCE=0
BINARY_ONLY=0
PORT_GIVEN=0
PASS_GIVEN=0
info() { printf '\033[1;32m[OK] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
cleanup() { if [[ -n "$BUILD_TMPDIR" && -d "$BUILD_TMPDIR" ]]; then rm -rf "$BUILD_TMPDIR"; fi; }
trap cleanup EXIT
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 权限: sudo $0 $*"; }
require_systemd() { command -v systemctl >/dev/null 2>&1 || die "未检测到 systemctl"; [[ -d /run/systemd/system ]] || die "systemd 未运行"; }
usage() {
  cat <<EOF
Emby 路径反代 一键安装
  sudo $0 [menu|install|update|uninstall|status|start|stop|restart]
EOF
}
parse_install_args() {
  PORT="$(installed_port)"; BIN_PATH="$(installed_bin_path)"
  [[ -n "$BIN_PATH" ]] || BIN_PATH=$DEFAULT_BIN
  ADMIN_USER="admin"; ADMIN_PASS=""; PREBUILT=""; FORCE=0; BINARY_ONLY=0
  PORT_GIVEN=0; PASS_GIVEN=0
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

var httpPorts = map[string]bool{"80": true, "8080": true, "8000": true, "8008": true, "8081": true, "8088": true, "8888": true, "3000": true, "5000": true, "7001": true, "8090": true, "8096": true, "9000": true, "9090": true, "9200": true, "10000": true, "15672": true}

func schemeForPort(port string) string {
	if port == "" || port == "443" || port == "8443" || port == "8920" || port == "9443" { return "https" }
	if httpPorts[port] { return "http" }
	return "https"
}
func schemeForAuthority(authority string) string {
	host := authority
	if i := strings.LastIndexByte(authority, '@'); i >= 0 { host = authority[i+1:] }
	var port string
	if strings.HasPrefix(host, "[") {
		if i := strings.LastIndexByte(host, ']'); i >= 0 && len(host) > i+1 && host[i+1] == ':' { port = host[i+2:] }
	} else if i := strings.LastIndexByte(host, ':'); i >= 0 { port = host[i+1:] }
	return schemeForPort(port)
}
func splitAuthority(s string) (authority, path string) {
	if i := strings.IndexByte(s, '/'); i >= 0 { return s[:i], s[i:] }
	return s, ""
}

var builtinAssets = map[string]bool{"favicon.ico": true, "favicon.png": true, "favicon.svg": true, "favicon-16x16.png": true, "favicon-32x32.png": true, "favicon-96x96.png": true, "apple-touch-icon.png": true, "apple-touch-icon-precomposed.png": true, "robots.txt": true, "sitemap.xml": true, "browserconfig.xml": true, "manifest.json": true, "site.webmanifest": true, "humans.txt": true, "security.txt": true, "crossdomain.xml": true, "app-ads.txt": true}

func isBuiltinAssetPath(p string) bool {
	p = strings.TrimPrefix(p, "/")
	if p == "" { return false }
	if !strings.Contains(p, "/") {
		if builtinAssets[p] { return true }
		return strings.HasSuffix(p, ".ico")
	}
	return strings.HasPrefix(p, ".well-known/")
}

func parseTarget(r *http.Request) (*url.URL, error) {
	raw := r.URL.EscapedPath()
	if raw == "" || raw == "/" { return nil, fmt.Errorf("请指定目标，格式: /https://域名/路径") }
	rest := strings.TrimPrefix(raw, "/")
	for strings.HasPrefix(rest, "/") { rest = rest[1:] }
	if rest == "" { return nil, fmt.Errorf("缺少目标主机") }
	var scheme, body string
	body = rest
	for i := 0; i < 3; i++ {
		lower := strings.ToLower(body)
		switch {
		case strings.HasPrefix(lower, "https:"):
			if scheme == "" { scheme = "https" }
			body = body[len("https:"):]
		case strings.HasPrefix(lower, "http:"):
			if scheme == "" { scheme = "http" }
			body = body[len("http:"):]
		default:
			i = 99
			continue
		}
		trimmed := strings.TrimLeft(body, "/")
		if trimmed == body { break }
		body = trimmed
	}
	body = strings.TrimLeft(body, "/")
	authority, pathPart := splitAuthority(body)
	if authority == "" { return nil, fmt.Errorf("缺少目标主机") }
	if scheme == "" { scheme = schemeForAuthority(authority) }
	targetStr := scheme + "://" + authority + pathPart
	if r.URL.RawQuery != "" { targetStr += "?" + r.URL.RawQuery }
	u, err := url.Parse(targetStr)
	if err != nil || u.Host == "" { return nil, fmt.Errorf("目标地址无效: %s", authority) }
	return u, nil
}

type Config struct {
	Port      int      `json:"port"`
	ChinaOnly bool     `json:"china_only"`
	Whitelist []string `json:"whitelist"`
	GeoAPI    bool     `json:"geo_api"`
	GeoAPIURL string   `json:"geo_api_url"`
}

var startedAt = time.Now()
var (
	cfgPtr  atomic.Pointer[Config]
	cfgPath string
	proxyTr = &switchTransport{}
	listenMu  sync.Mutex
	curLn     net.Listener
	curPort   int
	globalSrv *http.Server
)

func currentCfg() *Config { if p := cfgPtr.Load(); p != nil { return p }; return &Config{} }
func currentPort() int { listenMu.Lock(); defer listenMu.Unlock(); return curPort }
func startListen(srv *http.Server, port int) error {
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil { return err }
	listenMu.Lock(); old := curLn; curLn = ln; curPort = port; listenMu.Unlock()
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, net.ErrClosed) && err != http.ErrServerClosed {
			log.Printf("端口 %d 监听结束: %v", port, err)
		}
	}()
	if old != nil { _ = old.Close() }
	return nil
}
func loadConfig(path string) {
	cfgPath = path
	c := &Config{}
	if b, err := os.ReadFile(path); err == nil { _ = json.Unmarshal(b, c) }
	cfgPtr.Store(c)
	refreshRuntime()
}
func saveConfig(c *Config) error {
	if cfgPath == "" { return fmt.Errorf("配置文件路径未初始化") }
	b, _ := json.MarshalIndent(c, "", "  ")
	tmp := cfgPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil { return err }
	return os.Rename(tmp, cfgPath)
}
func refreshRuntime() { proxyTr.v.Store(newTransport()) }
func normalizeHost(hostport string) string {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil { host = h }
	return strings.ToLower(strings.TrimSpace(host))
}

var multiSuffix = map[string]bool{"co.uk": true, "org.uk": true, "me.uk": true, "ac.uk": true, "gov.uk": true, "ltd.uk": true, "plc.uk": true, "net.uk": true, "sch.uk": true, "com.cn": true, "net.cn": true, "org.cn": true, "gov.cn": true, "edu.cn": true, "ac.cn": true, "com.tw": true, "org.tw": true, "net.tw": true, "idv.tw": true, "com.hk": true, "org.hk": true, "net.hk": true, "edu.hk": true, "gov.hk": true, "co.jp": true, "or.jp": true, "ne.jp": true, "ac.jp": true, "go.jp": true, "co.kr": true, "or.kr": true, "com.au": true, "net.au": true, "org.au": true, "com.br": true, "com.sg": true, "com.my": true, "co.in": true, "com.tr": true, "com.ru": true, "com.mx": true, "com.ar": true, "co.nz": true, "co.za": true, "com.ua": true, "com.pl": true, "co.id": true, "com.sa": true, "com.eg": true}

func rootDomain(hostport string) string {
	host := normalizeHost(hostport)
	if net.ParseIP(host) != nil { return host }
	host = strings.TrimSuffix(host, ".")
	parts := strings.Split(host, ".")
	n := len(parts)
	if n <= 2 { return host }
	if multiSuffix[strings.Join(parts[n-2:], ".")] { return strings.Join(parts[n-3:], ".") }
	return strings.Join(parts[n-2:], ".")
}
func whitelistMatch(list []string, targetHost string) bool {
	if len(list) == 0 { return true }
	target := normalizeHost(targetHost)
	targetRoot := rootDomain(target)
	for _, w := range list {
		w = strings.TrimSpace(w)
		if w == "" { continue }
		if strings.EqualFold(normalizeHost(w), target) { return true }
		if strings.EqualFold(rootDomain(w), targetRoot) { return true }
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
	RecentBlocks     []BlockEvent        `json:"recent_blocks,omitempty"`
}

var (
	stats     Stats
	statsMu   sync.Mutex
	statsPath string
)

func loadStats(path string) {
	statsPath = path
	if b, err := os.ReadFile(path); err == nil { _ = json.Unmarshal(b, &stats) }
	if stats.CountryCounts == nil { stats.CountryCounts = map[string]int64{} }
	if stats.IPCounts == nil { stats.IPCounts = map[string]int64{} }
	if stats.TodayDate == "" { stats.TodayDate = time.Now().Format("2006-01-02") }
	if stats.Daily == nil { stats.Daily = map[string]*DayStat{} }
	pruneDailyLocked()
	if len(stats.Blocks) == 0 && len(stats.RecentBlocks) > 0 { stats.Blocks = stats.RecentBlocks }
	stats.RecentBlocks = nil
	pruneBlocksLocked()
}

const maxDayIPs = 300

func dayLocked() *DayStat {
	key := time.Now().Format("2006-01-02")
	if stats.Daily == nil { stats.Daily = map[string]*DayStat{} }
	d := stats.Daily[key]
	if d == nil { d = &DayStat{Countries: map[string]int64{}, IPs: map[string]int64{}}; stats.Daily[key] = d }
	if d.Countries == nil { d.Countries = map[string]int64{} }
	if d.IPs == nil { d.IPs = map[string]int64{} }
	return d
}
func pruneDailyLocked() {
	if len(stats.Daily) == 0 { return }
	cutoff := time.Now().AddDate(-1, 0, 0).Format("2006-01-02")
	for k := range stats.Daily { if k < cutoff { delete(stats.Daily, k) } }
}
func trimDayIPs(d *DayStat) {
	if len(d.IPs) <= maxDayIPs { return }
	type kv struct{ k string; v int64 }
	arr := make([]kv, 0, len(d.IPs))
	for k, v := range d.IPs { arr = append(arr, kv{k, v}) }
	sort.Slice(arr, func(i, j int) bool { return arr[i].v > arr[j].v })
	nm := make(map[string]int64, maxDayIPs/2)
	for i := 0; i < maxDayIPs/2 && i < len(arr); i++ { nm[arr[i].k] = arr[i].v }
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
	statsMu.Lock(); defer statsMu.Unlock()
	rolloverLocked()
	stats.TotalRequests++
	stats.TodayRequests++
	stats.LastProxyAt = time.Now().Format("2006-01-02 15:04:05")
	if country == "" { country = "??" }
	stats.CountryCounts[country]++
	stats.IPCounts[ip]++
	d := dayLocked()
	d.Requests++
	d.Countries[country]++
	d.IPs[ip]++
}
func recordBytes(bytes int64) {
	if bytes <= 0 { return }
	statsMu.Lock(); defer statsMu.Unlock()
	rolloverLocked()
	stats.TotalBytes += bytes
	stats.TodayBytes += bytes
	dayLocked().Bytes += bytes
}

const maxBlocks = 5000

func pruneBlocksLocked() {
	cutoff := time.Now().AddDate(-1, 0, 0).Format("2006-01-02 15:04:05")
	for len(stats.Blocks) > 0 && stats.Blocks[len(stats.Blocks)-1].Time < cutoff { stats.Blocks = stats.Blocks[:len(stats.Blocks)-1] }
}
func recordBlocked(ip, country, path, reason, ua string) {
	if country == "LO" || country == "PV" { return }
	statsMu.Lock(); defer statsMu.Unlock()
	rolloverLocked()
	d := dayLocked()
	reasonText := "目标域名不在访问白名单内"
	if reason == "cn" { stats.BlockedCN++; d.BlockedCN++; reasonText = "仅允许中国大陆 IP 访问" } else { stats.BlockedWhitelist++; d.BlockedWL++ }
	if country == "" { country = "??" }
	ev := BlockEvent{Time: time.Now().Format("2006-01-02 15:04:05"), IP: ip, Country: country, Path: path, Reason: reason, ReasonText: reasonText, UA: ua}
	stats.Blocks = append([]BlockEvent{ev}, stats.Blocks...)
	if len(stats.Blocks) > maxBlocks { stats.Blocks = stats.Blocks[:maxBlocks] }
}
func saveStatsLocked() {
	if statsPath == "" { return }
	b, _ := json.Marshal(stats)
	tmp := statsPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err == nil { _ = os.Rename(tmp, statsPath) }
}
func pruneStatsLocked() {
	pruneDailyLocked()
	pruneBlocksLocked()
	if d := stats.Daily[time.Now().Format("2006-01-02")]; d != nil { trimDayIPs(d) }
	if len(stats.IPCounts) > 2000 {
		type kv struct{ k string; v int64 }
		arr := make([]kv, 0, len(stats.IPCounts))
		for k, v := range stats.IPCounts { arr = append(arr, kv{k, v}) }
		sort.Slice(arr, func(i, j int) bool { return arr[i].v > arr[j].v })
		nm := make(map[string]int64, 500)
		for i := 0; i < 500 && i < len(arr); i++ { nm[arr[i].k] = arr[i].v }
		stats.IPCounts = nm
	}
}
func startStatsSaver() {
	go func() {
		t := time.NewTicker(30 * time.Second); defer t.Stop()
		for range t.C {
			statsMu.Lock(); pruneStatsLocked(); saveStatsLocked(); statsMu.Unlock()
			geoCacheSave()
		}
	}()
}
func getClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil { host = r.RemoteAddr }
	ip := net.ParseIP(host)
	trusted := ip != nil && (ip.IsLoopback() || ip.IsPrivate())
	if trusted {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			if i := strings.IndexByte(xff, ','); i > 0 { return strings.TrimSpace(xff[:i]) }
			return strings.TrimSpace(xff)
		}
		if xri := r.Header.Get("X-Real-IP"); xri != "" { return strings.TrimSpace(xri) }
	}
	return host
}
func countryOf(ipStr string) string {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil { return "??" }
	c := iploc.Country(ip)
	if len(c) == 0 || c == "ZZ" { return "??" }
	return c
}

var countryNames = map[string]string{
	"CN": "中国", "HK": "中国香港", "TW": "中国台湾", "MO": "中国澳门",
	"SG": "新加坡", "JP": "日本", "KR": "韩国", "US": "美国", "CA": "加拿大",
	"GB": "英国", "DE": "德国", "FR": "法国", "IT": "意大利", "ES": "西班牙",
	"NL": "荷兰", "BE": "比利时", "CH": "瑞士", "AT": "奥地利", "SE": "瑞典",
	"NO": "挪威", "DK": "丹麦", "FI": "芬兰", "PL": "波兰", "CZ": "捷克",
	"RU": "俄罗斯", "UA": "乌克兰", "TR": "土耳其", "IN": "印度", "ID": "印度尼西亚",
	"TH": "泰国", "VN": "越南", "MY": "马来西亚", "PH": "菲律宾", "AU": "澳大利亚",
	"NZ": "新西兰", "BR": "巴西", "AR": "阿根廷", "MX": "墨西哥", "ZA": "南非",
	"EG": "埃及", "AE": "阿联酋", "SA": "沙特阿拉伯", "IL": "以色列", "IR": "伊朗",
	"PV": "内网", "LO": "本机", "??": "未知",
}

func countryName(code string) string {
	if n, ok := countryNames[code]; ok { return n }
	if code == "" { return "未知" }
	return code
}

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
	geoPendingMu sync.Mutex
	geoPending   = map[string]bool{}
)

func geoCacheLoad(path string) {
	geoPath = path
	if b, err := os.ReadFile(path); err == nil { _ = json.Unmarshal(b, &geoMap) }
	if geoMap == nil { geoMap = map[string]geoEntry{} }
}
func geoCacheSave() {
	geoMu.RLock(); b, _ := json.Marshal(geoMap); geoMu.RUnlock()
	if geoPath == "" || len(b) == 0 { return }
	tmp := geoPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err == nil { _ = os.Rename(tmp, geoPath) }
}
func geoPickString(m map[string]any, keys ...string) string {
	for _, k := range keys { if v, ok := m[k].(string); ok && v != "" { return v } }
	return ""
}

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
	if ok { geoStat.ok++ } else { geoStat.fail++; geoStat.lastErr = errMsg }
	geoStat.lastAt = time.Now().Unix()
	geoStat.mu.Unlock()
}
func geoStatSnapshot() (int64, int64, string) {
	geoStat.mu.Lock(); defer geoStat.mu.Unlock()
	return geoStat.ok, geoStat.fail, geoStat.lastErr
}
func truncStr(s string, n int) string { if len(s) <= n { return s }; return s[:n] + "…" }
func geoFetch(ipStr string) (string, string, error) {
	tpl := strings.TrimSpace(currentCfg().GeoAPIURL)
	if tpl == "" { tpl = defaultGeoAPI }
	target := strings.ReplaceAll(tpl, "{ip}", ipStr)
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(target)
	if err != nil { return "", "", err }
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil { return "", "", fmt.Errorf("响应不是 JSON: %s", truncStr(string(body), 80)) }
	if st, ok := m["status"].(string); ok && st == "fail" {
		msg, _ := m["message"].(string)
		if msg == "" { msg = "接口返回 status=fail" }
		return "", "", fmt.Errorf("%s", msg)
	}
	raw := geoPickString(m, "country")
	code := geoPickString(m, "countryCode", "country_code", "code")
	if code == "" && len(raw) == 2 && strings.ToUpper(raw) == raw { code = raw; raw = "" }
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) != 2 { return "", "", fmt.Errorf("响应里没有两字母国家代码: %s", truncStr(string(body), 80)) }
	name := strings.TrimSpace(raw)
	if name == "" || len(name) == 2 { name = countryName(code) }
	return code, name, nil
}
func geoFetchAndCache(ipStr string) {
	now := time.Now().Unix()
	code, name, err := geoFetch(ipStr)
	if err != nil {
		geoStatRecord(false, err.Error())
		geoMu.Lock(); geoMap[ipStr] = geoEntry{Code: "??", At: now}; geoMu.Unlock()
		return
	}
	geoStatRecord(true, "")
	geoMu.Lock()
	geoMap[ipStr] = geoEntry{Code: code, Name: name, At: now}
	if len(geoMap) > 5000 {
		cutoff := now - 15*86400
		for k, v := range geoMap { if v.At < cutoff { delete(geoMap, k) } }
	}
	geoMu.Unlock()
}
func geoLookup(ipStr string) (string, string, bool) {
	now := time.Now().Unix()
	geoMu.RLock(); e, cached := geoMap[ipStr]; geoMu.RUnlock()
	if cached {
		if e.Code == "??" {
			if now-e.At < 3600 { return "", "", false }
		} else if now-e.At < 30*86400 { return e.Code, e.Name, true }
	}
	if !currentCfg().GeoAPI { return "", "", false }
	if atomic.LoadInt32(&geoInflight) >= 16 { return "", "", false }
	atomic.AddInt32(&geoInflight, 1); defer atomic.AddInt32(&geoInflight, -1)
	geoFetchAndCache(ipStr)
	geoMu.RLock(); e, ok := geoMap[ipStr]; geoMu.RUnlock()
	if !ok || e.Code == "??" { return "", "", false }
	return e.Code, e.Name, true
}
func geoLookupAsync(ipStr string) {
	if !currentCfg().GeoAPI { return }
	geoPendingMu.Lock()
	if geoPending[ipStr] { geoPendingMu.Unlock(); return }
	geoPending[ipStr] = true
	geoPendingMu.Unlock()
	go func() {
		defer func() { geoPendingMu.Lock(); delete(geoPending, ipStr); geoPendingMu.Unlock() }()
		if atomic.LoadInt32(&geoInflight) >= 16 { return }
		atomic.AddInt32(&geoInflight, 1); defer atomic.AddInt32(&geoInflight, -1)
		geoFetchAndCache(ipStr)
	}()
}
func ipLabel(ipStr string) (code, name string) {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil { return "??", "未知" }
	if ip.IsLoopback() { return "LO", "本机" }
	if ip.IsPrivate() || ip.IsLinkLocalUnicast() { return "PV", "内网" }
	if c := countryOf(ipStr); c != "??" { return c, countryName(c) }
	now := time.Now().Unix()
	geoMu.RLock(); e, ok := geoMap[ipStr]; geoMu.RUnlock()
	if ok {
		if e.Code != "??" && now-e.At < 30*86400 { return e.Code, e.Name }
		if e.Code == "??" && now-e.At < 3600 { return "??", "未知" }
	}
	geoLookupAsync(ipStr)
	return "??", "未知"
}
func ipLabelSync(ipStr string) (code, name string) {
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil { return "??", "未知" }
	if ip.IsLoopback() { return "LO", "本机" }
	if ip.IsPrivate() || ip.IsLinkLocalUnicast() { return "PV", "内网" }
	if c := countryOf(ipStr); c != "??" { return c, countryName(c) }
	if gc, gn, ok := geoLookup(ipStr); ok { return gc, gn }
	return "??", "未知"
}

var flagCache = struct {
	sync.RWMutex
	m map[string][]byte
}{m: map[string][]byte{}}

var flagDir string

func flagPng(code string) ([]byte, error) {
	flagCache.RLock(); b, ok := flagCache.m[code]; flagCache.RUnlock()
	if ok { return b, nil }
	if flagDir != "" {
		if d, err := os.ReadFile(filepath.Join(flagDir, code+".png")); err == nil && len(d) > 100 {
			flagCache.Lock(); flagCache.m[code] = d; flagCache.Unlock()
			return d, nil
		}
	}
	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := client.Get("https://flagcdn.com/w40/" + code + ".png")
	if err != nil { return nil, err }
	defer resp.Body.Close()
	if resp.StatusCode != 200 { return nil, fmt.Errorf("flagcdn 返回 %d", resp.StatusCode) }
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil || len(data) < 100 { return nil, fmt.Errorf("图片无效") }
	flagCache.Lock()
	if len(flagCache.m) > 400 { flagCache.m = map[string][]byte{} }
	flagCache.m[code] = data
	flagCache.Unlock()
	if flagDir != "" {
		if os.MkdirAll(flagDir, 0755) == nil { _ = os.WriteFile(filepath.Join(flagDir, code+".png"), data, 0644) }
	}
	return data, nil
}

var (
	regeoRunning int32
	regeoTotal   int32
	regeoDone    int32
)

func regeoAll() {
	statsMu.Lock()
	ips := make(map[string]int64, len(stats.IPCounts))
	for k, v := range stats.IPCounts { ips[k] = v }
	statsMu.Unlock()
	geoMu.Lock()
	for k, v := range geoMap { if v.Code == "??" { delete(geoMap, k) } }
	geoMu.Unlock()
	atomic.StoreInt32(&regeoTotal, int32(len(ips)))
	atomic.StoreInt32(&regeoDone, 0)
	type res struct { code string; cnt int64 }
	jobs := make(chan string, len(ips))
	out := make(chan res, len(ips))
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ip := range jobs {
				code, _ := ipLabelSync(ip)
				out <- res{code, ips[ip]}
				atomic.AddInt32(&regeoDone, 1)
			}
		}()
	}
	for ip := range ips { jobs <- ip }
	close(jobs)
	wg.Wait()
	close(out)
	cc := map[string]int64{}
	for r := range out { cc[r.code] += r.cnt }
	statsMu.Lock(); stats.CountryCounts = cc; saveStatsLocked(); statsMu.Unlock()
	geoCacheSave()
}

type statWriter struct {
	http.ResponseWriter
	bytes int64
}

func (w *statWriter) Write(b []byte) (int, error) { n, err := w.ResponseWriter.Write(b); w.bytes += int64(n); return n, err }
func (w *statWriter) Flush() { if f, ok := w.ResponseWriter.(http.Flusher); ok { f.Flush() } }
func (w *statWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := w.ResponseWriter.(http.Hijacker); ok { return h.Hijack() }
	return nil, nil, fmt.Errorf("hijacking not supported")
}
func (w *statWriter) ReadFrom(r io.Reader) (int64, error) {
	if rf, ok := w.ResponseWriter.(io.ReaderFrom); ok { n, err := rf.ReadFrom(r); w.bytes += n; return n, err }
	n, err := io.Copy(w.ResponseWriter, r); w.bytes += n; return n, err
}
func (w *statWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func basicAuth(next http.HandlerFunc, user, pass string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || subtle.ConstantTimeCompare([]byte(u), []byte(user)) != 1 || subtle.ConstantTimeCompare([]byte(p), []byte(pass)) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="emby-proxy admin"`)
			http.Error(w, "未登录或登录已失效，请重新登录", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

type switchTransport struct{ v atomic.Value }

func (s *switchTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	t, _ := s.v.Load().(*http.Transport)
	if t == nil { return nil, fmt.Errorf("transport 未初始化") }
	return t.RoundTrip(r)
}

type bufferPool struct{ pool sync.Pool }

func (b *bufferPool) Get() []byte {
	if v := b.pool.Get(); v != nil { return v.([]byte) }
	return make([]byte, 32*1024)
}
func (b *bufferPool) Put(p []byte) { if cap(p) >= 32*1024 { b.pool.Put(p[:32*1024]) } }

var proxyBufPool = &bufferPool{}

func newTransport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          512,
		MaxIdleConnsPerHost:   256,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 45 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		DisableCompression:    true,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12, ClientSessionCache: tls.NewLRUClientSessionCache(256)},
	}
}

var cookieDomainRE = regexp.MustCompile(`(?i);\s*domain=[^;]*`)

func rewriteOriginHeaders(out *http.Request, scheme, host string) {
	if o := out.Header.Get("Origin"); o != "" && o != "null" {
		if u, err := url.Parse(o); err == nil && u.Host != "" && !strings.EqualFold(u.Host, host) { out.Header.Set("Origin", scheme+"://"+host) }
	}
	if rf := out.Header.Get("Referer"); rf != "" {
		if u, err := url.Parse(rf); err == nil && u.Host != "" && !strings.EqualFold(u.Host, host) {
			u.Scheme = scheme; u.Host = host; out.Header.Set("Referer", u.String())
		}
	}
}
func buildProxy(tr *switchTransport) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Transport: tr,
		FlushInterval: 50 * time.Millisecond,
		BufferPool:    proxyBufPool,
		Rewrite: func(pr *httputil.ProxyRequest) {
			t, ok := pr.In.Context().Value(targetCtxKey{}).(*url.URL)
			if !ok || t == nil { return }
			pr.Out.URL.Scheme = t.Scheme
			pr.Out.URL.Host = t.Host
			pr.Out.URL.Path = t.Path
			pr.Out.URL.RawPath = ""
			pr.Out.URL.RawQuery = pr.In.URL.RawQuery
			pr.Out.Host = t.Host
			pr.SetXForwarded()
			rewriteOriginHeaders(pr.Out, t.Scheme, t.Host)
		},
		ModifyResponse: func(resp *http.Response) error {
			upHost := ""
			if resp.Request != nil && resp.Request.URL != nil { upHost = resp.Request.URL.Host }
			if loc := resp.Header.Get("Location"); loc != "" && upHost != "" {
				if lu, err := url.Parse(loc); err == nil && lu.Host != "" && strings.EqualFold(lu.Host, upHost) {
					lu.Scheme = ""; lu.Host = ""
					if lu.Path == "" { lu.Path = "/" }
					resp.Header.Set("Location", lu.String())
				}
			}
			if cks, ok := resp.Header["Set-Cookie"]; ok && len(cks) > 0 {
				for i, c := range cks { cks[i] = cookieDomainRE.ReplaceAllString(c, "") }
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
	fmt.Fprint(w, "Emby 路径反代运行中。\n用法：原地址放到路径里，例如：\n  https://www.example.com/emby/Users\n改成：\n  http://<本机地址>/https://www.example.com/emby/Users\n管理页: /admin/\n")
}

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
		c := currentCfg()
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *c, EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/save", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { http.Error(w, "该接口不支持此请求方法", http.StatusMethodNotAllowed); return }
		var req saveReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil { http.Error(w, "请求数据格式错误："+err.Error(), http.StatusBadRequest); return }
		if req.Port != 0 && (req.Port < 1 || req.Port > 65535) { http.Error(w, "端口必须是 1-65535 之间的整数", http.StatusBadRequest); return }
		oldCfg := currentCfg()
		newCfg := &Config{Port: req.Port, ChinaOnly: req.ChinaOnly, Whitelist: req.Whitelist, GeoAPI: req.GeoAPI, GeoAPIURL: strings.TrimSpace(req.GeoAPIURL)}
		if err := saveConfig(newCfg); err != nil { http.Error(w, "保存失败: "+err.Error(), http.StatusInternalServerError); return }
		cfgPtr.Store(newCfg)
		refreshRuntime()
		if newCfg.Port > 0 && newCfg.Port != currentPort() && globalSrv != nil {
			if err := startListen(globalSrv, newCfg.Port); err != nil {
				cfgPtr.Store(oldCfg); _ = saveConfig(oldCfg); refreshRuntime()
				http.Error(w, "端口 "+strconv.Itoa(newCfg.Port)+" 无法监听: "+err.Error(), http.StatusBadRequest)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *newCfg, EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/flag/", func(w http.ResponseWriter, r *http.Request) {
		code := strings.ToLower(strings.TrimPrefix(r.URL.Path, "/admin/api/flag/"))
		if len(code) != 2 || code[0] < 'a' || code[0] > 'z' || code[1] < 'a' || code[1] > 'z' { http.NotFound(w, r); return }
		data, err := flagPng(code)
		if err != nil { http.NotFound(w, r); return }
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=2592000")
		_, _ = w.Write(data)
	})
	mux.HandleFunc("/admin/api/traffic", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		from := strings.TrimSpace(q.Get("from")); to := strings.TrimSpace(q.Get("to"))
		statsMu.Lock()
		var reqs, byts, cn, wl int64
		ips := map[string]int64{}; ctry := map[string]int64{}
		type TrendItem struct{ Date string `json:"date"`; Requests int64 `json:"requests"`; Bytes int64 `json:"bytes"` }
		var trend []TrendItem
		days := make([]string, 0, len(stats.Daily))
		for k := range stats.Daily { days = append(days, k) }
		sort.Sort(sort.Reverse(sort.StringSlice(days)))
		if from == "" && to == "" {
			reqs, byts = stats.TotalRequests, stats.TotalBytes
			cn, wl = stats.BlockedCN, stats.BlockedWhitelist
			for ip, n := range stats.IPCounts { ips[ip] = n }
			for c, n := range stats.CountryCounts { ctry[c] = n }
			for _, k := range days { d := stats.Daily[k]; trend = append(trend, TrendItem{Date: k, Requests: d.Requests, Bytes: d.Bytes}) }
		} else {
			for k, d := range stats.Daily {
				if from != "" && k < from { continue }
				if to != "" && k > to { continue }
				reqs += d.Requests; byts += d.Bytes; cn += d.BlockedCN; wl += d.BlockedWL
				for ip, n := range d.IPs { ips[ip] += n }
				for c, n := range d.Countries { ctry[c] += n }
				trend = append(trend, TrendItem{Date: k, Requests: d.Requests, Bytes: d.Bytes})
			}
		}
		sort.Slice(trend, func(i, j int) bool { return trend[i].Date < trend[j].Date })
		today := time.Now().Format("2006-01-02")
		var todayReqs, todayBytes int64
		if d := stats.Daily[today]; d != nil { todayReqs, todayBytes = d.Requests, d.Bytes }
		statsMu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"today": today, "requests": reqs, "bytes": byts, "blocked_cn": cn, "blocked_whitelist": wl, "ip_counts": ips, "country_counts": ctry, "days": days, "today_requests": todayReqs, "today_bytes": todayBytes, "trend": trend})
	})
	mux.HandleFunc("/admin/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		date := strings.TrimSpace(q.Get("date")); from := strings.TrimSpace(q.Get("from")); to := strings.TrimSpace(q.Get("to"))
		if date != "" { from, to = date, date }
		page := 1
		if v, err := strconv.Atoi(q.Get("page")); err == nil && v > 0 { page = v }
		size := 20
		if v, err := strconv.Atoi(q.Get("size")); err == nil && v > 0 && v <= 200 { size = v }
		statsMu.Lock()
		matched := []BlockEvent{}
		dates := []string{}
		seen := map[string]bool{}
		for _, b := range stats.Blocks {
			d := b.Time
			if len(d) >= 10 { d = d[:10] }
			if !seen[d] { seen[d] = true; if len(dates) < 60 { dates = append(dates, d) } }
			if from != "" && d < from { continue }
			if to != "" && d > to { continue }
			matched = append(matched, b)
		}
		statsMu.Unlock()
		total := len(matched)
		pages := (total + size - 1) / size
		if pages < 1 { pages = 1 }
		if page > pages { page = pages }
		start := (page - 1) * size
		end := start + size
		if start > total { start = total }
		if end > total { end = total }
		items := append([]BlockEvent{}, matched[start:end]...)
		_ = json.NewEncoder(w).Encode(map[string]any{"total": total, "page": page, "size": size, "pages": pages, "items": items, "dates": dates, "today": time.Now().Format("2006-01-02")})
	})
	mux.HandleFunc("/admin/api/geotest", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { http.Error(w, "method not allowed", http.StatusMethodNotAllowed); return }
		var req struct{ IP string `json:"ip"` }
		_ = json.NewDecoder(r.Body).Decode(&req)
		ip := strings.TrimSpace(req.IP)
		if ip == "" { ip = "8.8.8.8" }
		if net.ParseIP(ip) == nil { http.Error(w, "IP 地址格式不正确", http.StatusBadRequest); return }
		tpl := strings.TrimSpace(currentCfg().GeoAPIURL)
		if tpl == "" { tpl = defaultGeoAPI }
		code, name, err := geoFetch(ip)
		geoStatRecord(err == nil, func() string { if err != nil { return err.Error() }; return "" }())
		out := map[string]any{"ip": ip, "url": strings.ReplaceAll(tpl, "{ip}", ip)}
		if err != nil { out["ok"] = false; out["error"] = err.Error() } else { out["ok"] = true; out["code"] = code; out["name"] = name }
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("/admin/api/regeo", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { http.Error(w, "method not allowed", http.StatusMethodNotAllowed); return }
		started := atomic.CompareAndSwapInt32(&regeoRunning, 0, 1)
		if started { go func() { defer atomic.StoreInt32(&regeoRunning, 0); regeoAll() }() }
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"started": started})
	})
	mux.HandleFunc("/admin/api/reset-config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { http.Error(w, "method not allowed", http.StatusMethodNotAllowed); return }
		newCfg := &Config{Port: currentPort(), ChinaOnly: false, Whitelist: []string{}, GeoAPI: true, GeoAPIURL: ""}
		if err := saveConfig(newCfg); err != nil { http.Error(w, "保存失败: "+err.Error(), http.StatusInternalServerError); return }
		cfgPtr.Store(newCfg)
		refreshRuntime()
		log.Printf("管理页已还原为默认设置")
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *newCfg, EffectivePort: currentPort()})
	})
	mux.HandleFunc("/admin/api/clear-stats", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost { http.Error(w, "method not allowed", http.StatusMethodNotAllowed); return }
		statsMu.Lock()
		stats = Stats{TodayDate: time.Now().Format("2006-01-02"), CountryCounts: map[string]int64{}, IPCounts: map[string]int64{}, Daily: map[string]*DayStat{}, Blocks: []BlockEvent{}}
		saveStatsLocked()
		statsMu.Unlock()
		log.Printf("管理页已清空所有统计数据")
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})
	mux.HandleFunc("/admin/api/stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		statsMu.Lock(); defer statsMu.Unlock()
		gok, gfail, glast := geoStatSnapshot()
		snap := stats
		snap.Blocks = nil; snap.RecentBlocks = nil; snap.Daily = nil
		blocksTotal := len(stats.Blocks)
		labels := map[string]string{}
		for code := range stats.CountryCounts { labels[code] = countryName(code) }
		for _, b := range stats.Blocks { if _, ok := labels[b.Country]; !ok { labels[b.Country] = countryName(b.Country) } }
		_ = json.NewEncoder(w).Encode(struct {
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
		}{Stats: snap, CountryLabels: labels, Port: currentPort(), UptimeSec: int64(time.Since(startedAt).Seconds()), GeoOK: gok, GeoFail: gfail, GeoLastErr: glast, RegeoRunning: atomic.LoadInt32(&regeoRunning) == 1, RegeoDone: atomic.LoadInt32(&regeoDone), RegeoTotal: atomic.LoadInt32(&regeoTotal), BlocksTotal: blocksTotal})
	})
	mux.HandleFunc("/admin/api/", func(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) })
	mux.HandleFunc("/admin/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		_, _ = w.Write(adminHTML)
	})
	return basicAuth(mux.ServeHTTP, user, pass)
}

func runServer(port int, adminUser, adminPass, configPath, statsFile string) {
	loadConfig(configPath)
	geoCacheLoad(filepath.Join(filepath.Dir(configPath), "geo_cache.json"))
	flagDir = filepath.Join(filepath.Dir(configPath), "flags")
	loadStats(statsFile)
	startStatsSaver()
	defer func() { statsMu.Lock(); saveStatsLocked(); statsMu.Unlock(); geoCacheSave() }()
	proxy := buildProxy(proxyTr)
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isBuiltinAssetPath(r.URL.Path) { http.NotFound(w, r); return }
		ip := getClientIP(r)
		country, _ := ipLabel(ip)
		c := currentCfg()
		if c.ChinaOnly && country != "CN" && country != "LO" && country != "PV" {
			recordBlocked(ip, country, r.URL.RequestURI(), "cn", r.UserAgent())
			http.Error(w, "仅允许中国大陆 IP 访问", http.StatusForbidden)
			return
		}
		target, err := parseTarget(r)
		if err != nil { helpPage(w); return }
		if !whitelistMatch(c.Whitelist, target.Host) {
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
	adminSrv := adminHandler(adminUser, adminPass)
	root := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/admin" { http.Redirect(w, r, "/admin/", http.StatusFound); return }
		if strings.HasPrefix(r.URL.Path, "/admin/") { adminSrv.ServeHTTP(w, r); return }
		proxyHandler(w, r)
	})
	if c := currentCfg(); c.Port > 0 { port = c.Port }
	srv := &http.Server{Handler: root, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second, MaxHeaderBytes: 32 << 10}
	globalSrv = srv
	if err := startListen(srv, port); err != nil { log.Fatalf("监听 :%d 失败: %v", port, err) }
	log.Printf("Emby 路径反代已启动 :%d  管理页: /admin/", port)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	_ = srv.Close()
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "run" { args = args[1:] }
	fs := flag.NewFlagSet("emby-proxy", flag.ExitOnError)
	port := fs.Int("port", 8520, "监听端口")
	adminUser := fs.String("admin-user", "admin", "管理页用户名")
	adminPass := fs.String("admin-pass", "", "管理页密码")
	configPath := fs.String("config", "/etc/emby-proxy/config.json", "配置文件路径")
	statsFile := fs.String("stats", "/etc/emby-proxy/stats.json", "统计文件路径")
	_ = fs.Parse(args)
	if *adminPass == "" { log.Fatal("必须通过 --admin-pass 指定管理页密码") }
	runServer(*port, *adminUser, *adminPass, *configPath, *statsFile)
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
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--d:#ef4444;--w:#f59e0b;--ok:#10b981;--mono:Consolas,monospace;--r:12px}
body{background:var(--bg);color:var(--t);font:14px/1.5 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;height:100vh;overflow:hidden}
.sb{width:230px;background:var(--card);border-right:1px solid var(--bd);display:flex;flex-direction:column}
.sb-h{padding:22px 20px 14px;display:flex;align-items:center;gap:10px}
.sb-logo{width:32px;height:32px;background:linear-gradient(135deg,var(--p),#8b5cf6);border-radius:8px;display:grid;place-items:center;color:#fff;font-weight:700}
.sb-t{font-size:16px;font-weight:700}
.nav{list-style:none;padding:0 10px;flex:1;overflow-y:auto}
.nav-i{display:flex;align-items:center;gap:10px;padding:10px 14px;border-radius:8px;color:var(--t2);cursor:pointer;margin-bottom:4px;border:0;background:transparent;font:inherit;font-size:14px;width:100%;text-align:left}
.nav-i:hover{background:#f1f5f9}
.nav-i.on{background:var(--ps);color:var(--pd);font-weight:600}
.sb-f{padding:14px 20px;border-top:1px solid var(--bd);font-size:12px;color:var(--t3)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--ok);margin-right:6px}
.mc{flex:1;display:flex;flex-direction:column;overflow:hidden}
.tb{height:60px;background:var(--bg);border-bottom:1px solid var(--bd);display:flex;align-items:center;justify-content:space-between;padding:0 28px}
.tb-l{display:flex;align-items:center;gap:14px}
.tb-t{font-size:18px;font-weight:600}
.tb-r{display:flex;align-items:center;gap:12px;font-size:13px;color:var(--t2)}
.chip{display:inline-flex;align-items:center;padding:4px 10px;border-radius:6px;background:#f1f5f9;font-family:var(--mono);font-size:12px}
.chip.p{background:var(--ps);color:var(--pd)}
.sc{flex:1;overflow-y:auto;padding:22px 28px}
.pg{display:none}
.pg.on{display:block}
.card{background:var(--card);border:1px solid var(--bd);border-radius:var(--r);padding:22px;margin-bottom:22px}
.ch{display:flex;justify-content:space-between;margin-bottom:18px;gap:16px;flex-wrap:wrap;align-items:flex-start}
.ct{font-size:15px;font-weight:600}
.cd{font-size:13px;color:var(--t3);margin-top:4px}
.g2{display:grid;grid-template-columns:1fr 1fr;gap:22px}
.g2 .card{margin-bottom:0}
.sg{display:grid;grid-template-columns:repeat(4,1fr);gap:18px;margin-bottom:22px}
.stc{background:var(--card);border:1px solid var(--bd);border-radius:var(--r);padding:18px;display:flex;align-items:flex-start;gap:14px}
.si{width:40px;height:40px;border-radius:10px;display:grid;place-items:center;flex-shrink:0}
.si.b{background:#eff6ff;color:#3b82f6}.si.g{background:#ecfdf5;color:#10b981}.si.r{background:#fef2f2;color:#ef4444}.si.o{background:#fffbeb;color:#f59e0b}
.sl{font-size:13px;color:var(--t3);font-weight:500}
.sv{font-size:24px;font-weight:700;margin:4px 0;font-variant-numeric:tabular-nums}
.ss{font-size:12px;color:var(--t2)}
.ss b{font-weight:600;color:var(--t)}
.dr{display:flex;align-items:center;gap:12px;padding:8px 0}
.dn{width:120px;flex-shrink:0;display:flex;align-items:center;gap:8px;font-size:13px;font-weight:500}
.dn .tx{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dn.m{font-family:var(--mono);font-size:12px}
.bar{flex:1;height:6px;background:#f1f5f9;border-radius:99px;overflow:hidden}
.bar>i{display:block;height:100%;border-radius:99px;transition:width .4s}
.bar.i>i{background:var(--p)}.bar.t>i{background:#10b981}
.dv{width:80px;text-align:right;font-size:13px;font-weight:500;font-variant-numeric:tabular-nums}
.dv span{color:var(--t3);font-size:12px;margin-left:6px}
.flg{width:20px;height:15px;object-fit:cover;border-radius:2px;box-shadow:0 0 0 1px rgba(0,0,0,.1)}
.fb{display:inline-grid;place-items:center;width:20px;height:15px;background:#f1f5f9;border-radius:3px;font-size:10px;font-weight:700;color:var(--t3)}
.tw{overflow-x:auto;margin:0 -22px -22px;padding:0 22px 22px}
table{width:100%;border-collapse:collapse;min-width:700px;text-align:left}
th{padding:12px 16px;border-bottom:1px solid var(--bd);font-size:12px;font-weight:600;color:var(--t3);background:#fafbfc}
td{padding:12px 16px;border-bottom:1px solid var(--bd);font-size:13px}
tbody tr:hover td{background:#f8fafc}
tbody tr:last-child td{border-bottom:0}
.ct2{color:var(--t3);font-family:var(--mono);font-size:12px}
.ci{font-family:var(--mono)}
.cp{font-family:var(--mono);font-size:12px;color:var(--t2);max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rg{display:inline-flex;align-items:center;gap:6px}
.pill{padding:2px 8px;border-radius:99px;font-size:11px;font-weight:600;display:inline-block}
.pw{background:#fffbeb;color:#b45309}.pc{background:#fef2f2;color:#b91c1c}
.fi{margin-bottom:18px}
.fl{display:block;font-size:13px;font-weight:600;margin-bottom:6px}
.inp,.tarea{width:100%;padding:10px 14px;font-size:13px;background:#fff;border:1px solid var(--bd);border-radius:8px;font-family:inherit;outline:none}
.inp:focus,.tarea:focus{border-color:var(--p);box-shadow:0 0 0 3px var(--ps)}
.inp.m,.tarea{font-family:var(--mono);font-size:12.5px}
.tarea{resize:vertical;min-height:100px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:9px 16px;border-radius:8px;font-size:13px;font-weight:500;cursor:pointer;border:1px solid transparent;font-family:inherit}
.btn.b{background:var(--p);color:#fff}
.btn.b:hover{background:var(--pd)}
.btn.b:disabled{opacity:.6;cursor:not-allowed}
.btn.g{background:#fff;border-color:var(--bd);color:var(--t2)}
.btn.g:hover{background:#f8fafc}
.btn.s{padding:6px 12px;font-size:12px;border-radius:7px}
.acts{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:14px}
.row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:14px 0;border-top:1px solid var(--bd)}
.row:first-child{border-top:0;padding-top:0}
.rl{font-size:14px;font-weight:600}
.rd{font-size:13px;color:var(--t3);margin-top:2px}
.sw{position:relative;width:44px;height:24px;flex-shrink:0}
.sw input{opacity:0;width:0;height:0}
.tr2{position:absolute;cursor:pointer;inset:0;background:#cbd5e1;border-radius:99px;transition:.3s}
.tr2::after{content:"";position:absolute;height:18px;width:18px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:.3s}
.sw input:checked+.tr2{background:var(--p)}
.sw input:checked+.tr2::after{transform:translateX(20px)}
.wl{display:flex;flex-wrap:wrap;gap:8px;min-height:40px}
.wli{display:inline-flex;background:#f1f5f9;border-radius:6px;padding:4px 10px;font-family:var(--mono);font-size:12px;color:var(--t2)}
.wle{color:var(--t3);font-size:13px}
.hint{font-size:12.5px;color:var(--t3);margin-top:8px;line-height:1.6}
.hint code{background:#f1f5f9;padding:2px 6px;border-radius:4px;font-family:var(--mono);color:#4338ca}
.flt{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.filter{border:1px solid var(--bd);background:#fff;color:var(--t2);padding:6px 12px;border-radius:8px;font-size:13px;font-weight:500;font-family:inherit;cursor:pointer}
.filter.on{background:var(--ps);border-color:var(--ps);color:var(--pd);font-weight:600}
.mo{position:fixed;inset:0;z-index:100;display:none;background:rgba(15,23,42,.4);padding:20px;overflow-y:auto}
.mo.on{display:flex;align-items:center;justify-content:center}
.mbox{background:#fff;border-radius:16px;width:100%;max-width:540px;overflow:hidden}
.mh{padding:20px 24px;border-bottom:1px solid var(--bd);display:flex;justify-content:space-between;align-items:center}
.mh h3{font-size:16px;font-weight:600}
.mcl{border:0;background:#f1f5f9;width:32px;height:32px;border-radius:8px;font-size:20px;color:var(--t2);cursor:pointer}
.mb{padding:24px}
.kv{display:flex;gap:16px;padding:12px 0;border-bottom:1px solid var(--bd);font-size:13.5px}
.kv:last-child{border-bottom:0}
.kk{width:60px;flex-shrink:0;color:var(--t3)}
.kvv{flex:1;word-break:break-all}
.kvv.m{font-family:var(--mono);font-size:13px}
.tst{position:fixed;left:50%;bottom:32px;transform:translate(-50%,16px);z-index:999;display:flex;align-items:center;gap:10px;padding:12px 20px;border-radius:10px;background:#0f172a;color:#fff;font-size:13.5px;opacity:0;pointer-events:none;transition:.2s}
.tst.on{opacity:1;transform:translate(-50%,0)}
.tst.ok{background:#059669}.tst.err{background:#dc2626}
.emp{padding:40px 20px;text-align:center;color:var(--t3);font-size:13.5px}
.emp b{display:block;color:var(--t2);font-size:14px;margin-bottom:4px}
.pg2{display:flex;align-items:center;justify-content:center;gap:12px;padding-top:20px}
.pi{font-size:13px;color:var(--t2);font-variant-numeric:tabular-nums}
.btn:disabled{opacity:.5;cursor:not-allowed}
.og{display:grid;grid-template-columns:1fr 1fr;gap:22px}
.og>.card{margin-bottom:0}
.sp2{grid-column:1/-1}
.sysg{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.sysi{padding:14px 16px;background:#f8fafc;border:1px solid var(--bd);border-radius:10px;display:flex;flex-direction:column;gap:6px;min-width:0}
.sysl{font-size:12px;color:var(--t3);font-weight:500}
.sysv{font-size:15px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sysv.m{font-family:var(--mono);font-size:13.5px}
.sysv.ok{color:var(--ok)}.sysv.warn{color:var(--w)}.sysv.err{color:var(--d)}
.obr{display:flex;align-items:center;gap:10px;padding:10px 8px;margin:0 -8px;border-top:1px solid var(--bd);font-size:13px;cursor:pointer;border-radius:6px}
.obr:first-child{border-top:0;padding-top:0;margin-top:0}
.obr:hover{background:#f8fafc}
.obip{font-family:var(--mono);font-weight:500;flex-shrink:0;font-size:12.5px}
.obp{flex:1;font-family:var(--mono);font-size:12px;color:var(--t3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.obt{font-size:11px;color:var(--t3);font-family:var(--mono);flex-shrink:0}
.mmb{display:none;background:transparent;border:0;padding:8px;cursor:pointer;color:var(--t)}
@media(max-width:900px){.sg{grid-template-columns:repeat(2,1fr)}.g2{grid-template-columns:1fr}.g2 .card{margin-bottom:22px}.og{grid-template-columns:1fr}.sysg{grid-template-columns:repeat(2,1fr)}}
@media(max-width:768px){body{flex-direction:column}.sb{position:fixed;left:0;top:0;bottom:0;transform:translateX(-100%)}.sb.on{transform:translateX(0)}.mmb{display:block}.tb{padding:0 16px}.sc{padding:16px}.card{padding:16px;margin-bottom:16px}.tw{margin:0 -16px -16px;padding:0 16px 16px}table tr{display:block;padding:12px;border-bottom:1px solid var(--bd)}thead{display:none}td{display:flex;padding:4px 0;border:0;gap:12px}td::before{content:attr(data-label);width:60px;color:var(--t3);font-size:12px;flex-shrink:0}}
@media(max-width:480px){.sg{grid-template-columns:1fr}.sysg{grid-template-columns:1fr}}
</style>
</head>
<body>
<aside class="sb" id="sb">
<div class="sb-h"><div class="sb-logo">E</div><div class="sb-t">Emby Proxy</div></div>
<ul class="nav">
<li><button class="nav-i on" data-t="overview">概览</button></li>
<li><button class="nav-i" data-t="traffic">流量</button></li>
<li><button class="nav-i" data-t="blocks">拦截</button></li>
<li><button class="nav-i" data-t="settings">设置</button></li>
</ul>
<div class="sb-f"><span class="dot"></span><span id="uptimeChip">运行中</span></div>
</aside>
<div class="mc">
<header class="tb">
<div class="tb-l"><button class="mmb" id="mmb">☰</button><h1 class="tb-t" id="pt">概览</h1></div>
<div class="tb-r"><span class="chip p" id="portChip">:—</span><span id="clock">--:--:--</span></div>
</header>
<div class="sc">
<section id="overview" class="pg on">
<div class="sg">
<div class="stc"><div class="si b">⚡</div><div style="flex:1;min-width:0"><div class="sl">今日请求</div><div class="sv" id="todayReq">-</div><div class="ss">流量 <b id="todayBytes">0 B</b></div></div></div>
<div class="stc"><div class="si g">↻</div><div style="flex:1;min-width:0"><div class="sl">累计请求</div><div class="sv" id="totalReq">-</div><div class="ss">流量 <b id="totalBytes">0 B</b></div></div></div>
<div class="stc"><div class="si r">⊘</div><div style="flex:1;min-width:0"><div class="sl">拦截</div><div class="sv" id="totalBlocked" style="color:var(--d)">-</div><div class="ss">地区 <b id="blockedCN">0</b> · 白名单 <b id="blockedWL">0</b></div></div></div>
<div class="stc"><div class="si o">◕</div><div style="flex:1;min-width:0"><div class="sl">独立 IP</div><div class="sv" id="uniqueIPs">-</div><div class="ss"><b id="uniqueCountries">0</b> 个地区</div></div></div>
</div>
<div class="og">
<div class="card sp2"><div class="ch"><div><h2 class="ct">近 7 天趋势</h2><div class="cd">每日请求数与流量消耗</div></div><button class="btn g s" data-goto="traffic">查看全部 →</button></div><div style="position:relative;height:240px"><canvas id="miniTrendChart"></canvas></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">来源地区</h2><div class="cd">Top 5</div></div><button class="btn g s" data-goto="traffic">详情 →</button></div><div id="ovRegion"></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">最新拦截</h2><div class="cd">最近 5 条</div></div><button class="btn g s" data-goto="blocks">全部 →</button></div><div id="ovBlocks"></div></div>
<div class="card sp2"><div class="ch"><div><h2 class="ct">系统状态</h2><div class="cd">运行参数与开关</div></div><button class="btn g s" data-goto="settings">设置 →</button></div><div id="ovSystem" class="sysg"></div></div>
</div>
</section>
<section id="traffic" class="pg">
<div class="card">
<div class="ch"><div><h2 class="ct">流量与请求趋势</h2><div class="cd">每日请求数与流量消耗</div></div><div class="flt" id="trRangeBar"><button class="filter on" data-r="all">全部</button><button class="filter" data-r="today">今天</button><button class="filter" data-r="7d">近 7 天</button><button class="filter" data-r="30d">近 30 天</button></div></div>
<div style="position:relative;height:340px"><canvas id="trendChart"></canvas></div>
<div style="margin-top:16px;text-align:right;font-size:13px;color:var(--t2)" id="trSummary"></div>
</div>
<div class="g2">
<div class="card"><div class="ch"><div><h2 class="ct">IP 分布</h2><div class="cd">请求次数 Top 20</div></div></div><div id="ipDist"></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">地区分布</h2><div class="cd">按来源地区</div></div></div><div id="regionDist"></div></div>
</div>
</section>
<section id="blocks" class="pg">
<div class="card" style="padding-bottom:0">
<div class="ch"><div><h2 class="ct">拦截记录</h2><div class="cd">保留一年，最新在上</div></div><div class="flt" id="rangeBar"><button class="filter on" data-r="all">全部</button><button class="filter" data-r="today">今天</button><button class="filter" data-r="7d">近 7 天</button><button class="filter" data-r="30d">近 30 天</button><span class="chip" id="cntAll">0 条</span></div></div>
<div class="tw"><table><thead><tr><th>时间</th><th>IP</th><th>地区</th><th>路径</th><th>原因</th></tr></thead><tbody id="blocksBody"><tr><td colspan="5" class="emp">暂无记录</td></tr></tbody></table></div>
<div class="pg2" style="padding-bottom:20px"><button class="btn g" id="prevPage">上一页</button><span class="pi" id="pageInfo">1 / 1</span><button class="btn g" id="nextPage">下一页</button></div>
</div>
</section>
<section id="settings" class="pg">
<div class="g2">
<div class="card">
<div class="ch"><div><h2 class="ct">基础服务</h2><div class="cd">端口修改后即时生效，无需重启</div></div></div>
<div class="fi"><label class="fl">监听端口</label><div style="display:flex;gap:12px;align-items:center;flex-wrap:wrap"><input id="portInput" class="inp m" type="number" min="1" max="65535" style="max-width:140px"><span class="chip p">当前 <span id="portNow">-</span></span><button class="btn b" id="savePort">保存修改</button></div></div>
<div class="row" style="margin-top:12px"><div><div class="rl">未知 IP 用在线接口查询</div><div class="rd">离线库查不到时调第三方 API，缓存 30 天</div></div><label class="sw"><input type="checkbox" id="geoAPI"><span class="tr2"></span></label></div>
<div class="fi" style="margin-top:14px"><label class="fl">接口地址</label><input id="geoAPIURL" class="inp m" placeholder="http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,country,countryCode"><div class="hint">用 <code>{ip}</code> 占位，留空使用默认 <code>ip-api.com</code></div><div class="acts"><button class="btn g" id="geoTest">测试接口</button><button class="btn g" id="regeoBtn">重新识别历史 IP</button><span class="hint" id="geoStatus"></span></div><div id="geoResult"></div></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct">访问控制</h2><div class="cd">限制访问来源与转发目标</div></div></div>
<div class="row" style="padding-top:0"><div><div class="rl">仅允许中国大陆 IP 访问</div><div class="rd">境外 IP 将被拒绝（内网/本机不受限）</div></div><label class="sw"><input type="checkbox" id="chinaOnly"><span class="tr2"></span></label></div>
<div style="margin-top:20px;border-top:1px solid var(--bd);padding-top:18px">
<label class="fl">目标域名白名单</label>
<div id="wlView" class="wl" style="margin-top:8px"></div>
<div id="wlEditWrap" style="display:none;margin-top:8px"><textarea id="whitelist" class="tarea" placeholder="留空 = 不限制&#10;example.com"></textarea><div class="hint">每行一个，支持根域名（放行所有子域）和精确域名</div><div class="acts"><button class="btn b" id="save">保存白名单</button><button class="btn g" id="wlCancel">取消</button></div></div>
<div class="acts" id="wlViewActions" style="margin-top:12px"><button class="btn g" id="wlEditBtn">编辑白名单</button></div>
<div class="hint" style="margin-top:12px">目标地址在页面上以 <code>***</code> 掩码显示，防止泄露源站</div>
</div>
</div>
</div>
<div class="card" style="border-color:#fecaca;margin-top:22px">
<div class="ch"><div><h2 class="ct" style="color:var(--d)">危险操作</h2><div class="cd">以下操作不可恢复，请谨慎执行</div></div></div>
<div class="row" style="padding-top:0"><div><div class="rl">还原初始化设置</div><div class="rd">白名单、大陆限制、在线查询开关恢复默认；不清空统计与密码</div></div><button class="btn g" id="resetConfigBtn" style="color:var(--d);border-color:#fecaca">还原</button></div>
<div class="row"><div><div class="rl">清空所有统计</div><div class="rd">清除请求数、流量、IP/地区分布、拦截记录；配置与密码保留</div></div><button class="btn g" id="clearStatsBtn" style="color:var(--d);border-color:#fecaca">清空</button></div>
</div>
</section>
</div>
</div>
<div class="mo" id="modal"><div class="mbox"><div class="mh"><h3 id="modalTitle">记录详情</h3><button class="mcl" id="modalClose">×</button></div><div class="mb" id="modalBody"></div></div></div>
<div class="tst" id="toast"></div>
<script>
const state={port:0,labels:{},serverToday:'',range:{from:'',to:''},page:1,pages:1,total:0};
function fmtBytes(b){if(!b)return '0 B';if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB'}
function fmtUptime(s){if(s<60)return s+' 秒';if(s<3600)return Math.floor(s/60)+' 分钟';if(s<86400)return Math.floor(s/3600)+' 小时';return Math.floor(s/86400)+' 天'}
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function toast(m,k){const t=document.getElementById('toast');t.textContent=m;t.className='tst on'+(k==='ok'?' ok':k==='err'?' err':'');clearTimeout(t._t);t._t=setTimeout(()=>t.className='tst',3500)}
const LOCAL={'LO':'本机','PV':'内网','??':'未知','':'未知'};
function regionName(c){if(!c)return '未知';return state.labels[c]||LOCAL[c]||c}
function flagBadge(t){return '<span class="fb">'+esc(t)+'</span>'}
const LOCAL_CODES={LO:1,PV:1,'??':1};
function reasonLabel(b){return b.reason==='cn'?'大陆限制':'未授权'}
function flagHtml(c){if(!c||c==='??'||LOCAL_CODES[c])return flagBadge(c==='LO'?'本':c==='PV'?'内':'?');if(!/^[A-Z]{2}$/.test(c))return flagBadge(String(c).slice(0,2));return '<img class="flg" src="/admin/api/flag/'+c.toLowerCase()+'" alt="'+c+'" loading="lazy">'}
document.addEventListener('error',e=>{const i=e.target;if(i&&i.tagName==='IMG'&&i.classList.contains('flg')){const s=document.createElement('span');s.className='fb';s.textContent=i.alt||'?';i.replaceWith(s)}},true);
function shortPath(p){if(!p)return '';const q=p.indexOf('?');if(q>0&&p.length>q+1)return p.slice(0,q)+' ?…';return p.length>96?p.slice(0,96)+'…':p}
const pageTitles={overview:'概览',traffic:'流量',blocks:'拦截记录',settings:'设置'};
function switchTab(id){document.querySelectorAll('.nav-i').forEach(b=>b.classList.toggle('on',b.dataset.t===id));document.querySelectorAll('.pg').forEach(el=>el.classList.toggle('on',el.id===id));document.getElementById('pt').textContent=pageTitles[id]||'';if(window.innerWidth<=768)document.getElementById('sb').classList.remove('on');if(id==='overview')loadOverview();if(id==='traffic')loadTraffic();if(id==='blocks'){sigBlk='';loadBlocks()}}
document.querySelectorAll('.nav-i').forEach(t=>t.addEventListener('click',()=>switchTab(t.dataset.t)));
document.getElementById('mmb').addEventListener('click',()=>document.getElementById('sb').classList.toggle('on'));
function applyPort(p){if(!p)return;state.port=p;document.getElementById('portInput').value=p;document.getElementById('portNow').textContent=p;document.getElementById('portChip').textContent=':'+p}
async function loadConfig(){try{const r=await fetch('/admin/api/config',{cache:'no-store'});if(!r.ok)throw new Error('HTTP '+r.status);const c=await r.json();const wl=c.whitelist||[];document.getElementById('whitelist').value=wl.join('\n');renderWl(wl);document.getElementById('chinaOnly').checked=!!c.china_only;document.getElementById('geoAPI').checked=!!c.geo_api;document.getElementById('geoAPIURL').value=c.geo_api_url||'';applyPort(c.effective_port)}catch(e){toast('加载配置失败: '+e.message,'err')}}
let sigIP='',sigReg='',sigBlk='';const trState={range:{from:'',to:''}};
let miniTrendChart=null,ovLoading=false;
async function loadOverview(){if(ovLoading)return;ovLoading=true;try{const[t,b,c]=await Promise.all([fetch('/admin/api/traffic',{cache:'no-store'}).then(r=>r.ok?r.json():null).catch(()=>null),fetch('/admin/api/blocks?page=1&size=5',{cache:'no-store'}).then(r=>r.ok?r.json():null).catch(()=>null),fetch('/admin/api/config',{cache:'no-store'}).then(r=>r.ok?r.json():null).catch(()=>null)]);if(t){renderMiniTrend(t.trend||[]);renderOvRegion(t.country_counts||{})}if(b)renderOvBlocks(b.items||[]);renderOvSystem(c)}catch(e){}finally{ovLoading=false}}
function renderMiniTrend(trend){const cv=document.getElementById('miniTrendChart');if(!cv||typeof Chart==='undefined')return;const data=(trend||[]).slice(-7);if(!data.length){if(miniTrendChart){miniTrendChart.destroy();miniTrendChart=null}return}const labels=data.map(d=>(d.date||'').slice(5)),bytes=data.map(d=>d.bytes||0),reqs=data.map(d=>d.requests||0);if(miniTrendChart){miniTrendChart.data.labels=labels;miniTrendChart.data.datasets[0].data=bytes;miniTrendChart.data.datasets[1].data=reqs;miniTrendChart.update('none');return}miniTrendChart=new Chart(cv,{type:'line',data:{labels,datasets:[{label:'流量',data:bytes,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.1)',borderWidth:2,fill:true,yAxisID:'y',tension:0.35,pointRadius:2},{label:'请求',data:reqs,borderColor:'#10b981',backgroundColor:'transparent',borderWidth:1.5,borderDash:[4,4],yAxisID:'y1',tension:0.35,pointRadius:0}]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{position:'top',align:'end',labels:{usePointStyle:true,boxWidth:8,font:{size:11}}},tooltip:{backgroundColor:'rgba(15,23,42,0.9)',padding:10,cornerRadius:8,callbacks:{label:c=>c.dataset.label+': '+(c.dataset.yAxisID==='y'?fmtBytes(c.parsed.y):c.parsed.y.toLocaleString())}}},scales:{x:{grid:{display:false},ticks:{font:{size:10},color:'#94a3b8'}},y:{display:false,beginAtZero:true},y1:{display:false,beginAtZero:true}}}})}
function renderOvRegion(cc){const box=document.getElementById('ovRegion');if(!box)return;const entries=Object.entries(cc||{});if(!entries.length){box.innerHTML='<div class="emp"><b>暂无数据</b>有请求后自动统计</div>';return}const rows=entries.sort((a,b)=>b[1]-a[1]).slice(0,5),total=entries.reduce((s,r)=>s+r[1],0)||1,max=rows[0][1]||1;box.innerHTML=rows.map(([code,n])=>{const nm=regionName(code);return '<div class="dr"><span class="dn" title="'+esc(nm)+'">'+flagHtml(code)+'<span class="tx">'+esc(nm)+'</span></span><div class="bar t"><i style="width:'+(n/max*100).toFixed(1)+'%"></i></div><span class="dv">'+n.toLocaleString()+'<span>'+(n/total*100).toFixed(0)+'%</span></span></div>'}).join('')}
function renderOvBlocks(items){const box=document.getElementById('ovBlocks');if(!box)return;if(!items||!items.length){box.innerHTML='<div class="emp"><b>暂无记录</b>被拦截的请求会出现在这里</div>';return}box.innerHTML=items.map((b,i)=>'<div class="obr" data-ovb="'+i+'"><span class="obip">'+esc(b.ip)+'</span><span class="obp" title="'+esc(b.path)+'">'+esc(shortPath(b.path))+'</span><span class="pill '+(b.reason==='cn'?'pc':'pw')+'">'+esc(reasonLabel(b))+'</span><span class="obt">'+esc((b.time||'').slice(11,16))+'</span></div>').join('');box.querySelectorAll('[data-ovb]').forEach(el=>el.addEventListener('click',()=>{const b=items[+el.dataset.ovb];if(b)showDetail(b)}))}
function renderOvSystem(cfg){const box=document.getElementById('ovSystem');if(!box)return;const s=state.lastStats||{},items=[];if(cfg){items.push({label:'监听端口',value:':'+(cfg.effective_port||'—'),cls:'m'});items.push({label:'大陆限制',value:cfg.china_only?'已开启':'已关闭',cls:cfg.china_only?'ok':''});items.push({label:'在线查询',value:cfg.geo_api?'已开启':'已关闭',cls:cfg.geo_api?'ok':''});const wl=(cfg.whitelist||[]).filter(Boolean).length;items.push({label:'白名单',value:wl?wl+' 个域名':'不限目标',cls:wl?'':'warn'})}items.push({label:'运行时长',value:typeof s.uptime_sec==='number'?fmtUptime(s.uptime_sec):'—'});items.push({label:'最近转发',value:s.last_proxy_at?s.last_proxy_at.slice(5,16):'尚无请求',cls:s.last_proxy_at?'m':'warn'});const bc=(s.blocked_cn||0)+(s.blocked_whitelist||0);items.push({label:'累计拦截',value:bc.toLocaleString()+' 次'});items.push({label:'独立 IP',value:Object.keys(s.ip_counts||{}).length.toLocaleString()+' 个'});box.innerHTML=items.map(it=>'<div class="sysi"><span class="sysl">'+esc(it.label)+'</span><span class="sysv '+(it.cls||'')+'">'+esc(it.value)+'</span></div>').join('')}
let trendChart=null;
function fmtChartBytes(b){if(!b)return '0';if(b<1048576)return (b/1024).toFixed(0)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB'}
function renderTrend(td){const ctx=document.getElementById('trendChart');if(!ctx)return;if(!td||!td.length){if(trendChart){trendChart.destroy();trendChart=null}return}const labels=td.map(d=>d.date),dr=td.map(d=>d.requests),db=td.map(d=>d.bytes);if(trendChart){trendChart.data.labels=labels;trendChart.data.datasets[0].data=db;trendChart.data.datasets[1].data=dr;trendChart.update();return}trendChart=new Chart(ctx,{type:'line',data:{labels,datasets:[{label:'流量',data:db,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.1)',borderWidth:2,fill:true,yAxisID:'y',tension:0.3,pointRadius:3},{label:'请求数',data:dr,borderColor:'#10b981',backgroundColor:'transparent',borderWidth:2,borderDash:[5,5],yAxisID:'y1',tension:0.3,pointRadius:2}]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},plugins:{legend:{position:'top',align:'end',labels:{usePointStyle:true,boxWidth:8,font:{size:12}}},tooltip:{backgroundColor:'rgba(15,23,42,0.9)',padding:12,cornerRadius:8,callbacks:{label:c=>c.dataset.label+': '+(c.dataset.yAxisID==='y'?fmtBytes(c.parsed.y):c.parsed.y.toLocaleString())}}},scales:{x:{grid:{display:false},ticks:{maxTicksLimit:12,font:{size:11},color:'#94a3b8'}},y:{type:'linear',position:'left',title:{display:true,text:'流量',color:'#3b82f6',font:{size:11,weight:'bold'}},ticks:{color:'#94a3b8',font:{size:11},callback:v=>fmtChartBytes(v)},grid:{color:'#f1f5f9'}},y1:{type:'linear',position:'right',title:{display:true,text:'请求数',color:'#10b981',font:{size:11,weight:'bold'}},ticks:{color:'#94a3b8',font:{size:11}},grid:{drawOnChartArea:false}}}}})}
async function loadTraffic(){const r0=trState.range||{from:'',to:''};const qs=new URLSearchParams();if(r0.from)qs.set('from',r0.from);if(r0.to)qs.set('to',r0.to);try{const r=await fetch('/admin/api/traffic'+(qs.toString()?'?'+qs.toString():''),{cache:'no-store'});if(!r.ok)return;const d=await r.json();if(d.today)state.serverToday=d.today;const sum=document.getElementById('trSummary');if(sum){const blocked=(d.blocked_cn||0)+(d.blocked_whitelist||0);sum.innerHTML='请求总计 <b>'+(d.requests||0).toLocaleString()+'</b> · 流量总计 <b>'+fmtBytes(d.bytes||0)+'</b> · 拦截总计 <b>'+blocked.toLocaleString()+'</b>'}renderIP(d.ip_counts||{});renderRegion(d.country_counts||{});if(d.trend)renderTrend(d.trend)}catch(e){}}
document.getElementById('trRangeBar').addEventListener('click',e=>{const btn=e.target.closest('.filter[data-r]');if(!btn)return;document.querySelectorAll('#trRangeBar .filter').forEach(b=>b.classList.toggle('on',b===btn));trState.range=rangeOf(btn.dataset.r);sigIP='';sigReg='';loadTraffic()});
async function loadStats(){try{const r=await fetch('/admin/api/stats',{cache:'no-store'});if(!r.ok)return;const s=await r.json();state.lastStats=s;const nl=s.country_labels||{};if(JSON.stringify(nl)!==JSON.stringify(state.labels)){state.labels=nl;sigReg='';sigBlk='';sigIP='';if(blockItems.length)drawBlocks();if(document.getElementById('traffic').classList.contains('on'))loadTraffic()}if(s.port&&!state.port)applyPort(s.port);document.getElementById('todayReq').textContent=(s.today_requests||0).toLocaleString();document.getElementById('todayBytes').textContent=fmtBytes(s.today_bytes||0);document.getElementById('totalReq').textContent=(s.total_requests||0).toLocaleString();document.getElementById('totalBytes').textContent=fmtBytes(s.total_bytes||0);const bc=s.blocked_cn||0,bw=s.blocked_whitelist||0;document.getElementById('totalBlocked').textContent=(bc+bw).toLocaleString();document.getElementById('blockedCN').textContent=bc.toLocaleString();document.getElementById('blockedWL').textContent=bw.toLocaleString();document.getElementById('uniqueIPs').textContent=Object.keys(s.ip_counts||{}).length.toLocaleString();document.getElementById('uniqueCountries').textContent=Object.keys(s.country_counts||{}).length;document.getElementById('clock').textContent=new Date().toLocaleTimeString('zh-CN',{hour12:false});if(typeof s.uptime_sec==='number')document.getElementById('uptimeChip').textContent='已运行 '+fmtUptime(s.uptime_sec);const gs=document.getElementById('geoStatus');if(s.regeo_running)gs.textContent='识别中 '+(s.regeo_done||0)+'/'+(s.regeo_total||0);else if(s.geo_ok||s.geo_fail)gs.textContent='成功 '+(s.geo_ok||0)+' · 失败 '+(s.geo_fail||0);else gs.textContent='';if(document.getElementById('traffic').classList.contains('on'))loadTraffic();if(document.getElementById('blocks').classList.contains('on'))loadBlocks();if(document.getElementById('overview').classList.contains('on')){const now=Date.now();if(!loadStats._ovAt||now-loadStats._ovAt>30000){loadStats._ovAt=now;loadOverview()}}}catch(e){}}
function renderIP(map){const rows=Object.entries(map).sort((a,b)=>b[1]-a[1]).slice(0,20);const sig=JSON.stringify(rows);if(sig===sigIP)return;sigIP=sig;const box=document.getElementById('ipDist');if(!rows.length){box.innerHTML='<div class="emp"><b>暂无数据</b>有请求后自动统计</div>';return}const max=rows[0][1]||1;box.innerHTML=rows.map(([ip,n])=>'<div class="dr"><span class="dn m" title="'+esc(ip)+'"><span class="tx">'+esc(ip)+'</span></span><div class="bar i"><i style="width:'+(n/max*100).toFixed(1)+'%"></i></div><span class="dv">'+n.toLocaleString()+'</span></div>').join('')}
function renderRegion(map){const rows=Object.entries(map).sort((a,b)=>b[1]-a[1]).slice(0,20);const sig=JSON.stringify(rows);if(sig===sigReg)return;sigReg=sig;const box=document.getElementById('regionDist');if(!rows.length){box.innerHTML='<div class="emp"><b>暂无数据</b>有请求后自动统计</div>';return}const total=rows.reduce((s,r)=>s+r[1],0)||1,max=rows[0][1]||1;box.innerHTML=rows.map(([code,n])=>{const nm=regionName(code);return '<div class="dr"><span class="dn" title="'+esc(nm)+'">'+flagHtml(code)+'<span class="tx">'+esc(nm)+'</span></span><div class="bar t"><i style="width:'+(n/max*100).toFixed(1)+'%"></i></div><span class="dv">'+n.toLocaleString()+'<span>'+(n/total*100).toFixed(0)+'%</span></span></div>'}).join('')}
function maskHost(h){h=String(h||'').trim();if(!h)return '';const port=h.includes(':')?':'+h.split(':').pop():'',host=h.split(':')[0];if(/^\d{1,3}(\.\d{1,3}){3}$/.test(host)){const p=host.split('.');return p[0]+'.'+p[1]+'.*.*'+port}const parts=host.split('.');if(parts.length<=1)return '***'+port;return '***.'+parts[parts.length-1]+port}
let blockItems=[];
const dayStr=d=>{const p=n=>String(n).padStart(2,'0');return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())};
function rangeOf(mode){const t=state.serverToday||dayStr(new Date()),base=new Date(t+'T00:00:00');if(mode==='today')return{from:t,to:t};if(mode==='7d'){const f=new Date(base);f.setDate(f.getDate()-6);return{from:dayStr(f),to:t}}if(mode==='30d'){const f=new Date(base);f.setDate(f.getDate()-29);return{from:dayStr(f),to:t}}return{from:'',to:''}}
async function loadBlocks(){const r0=state.range||{from:'',to:''};const qs=new URLSearchParams();if(r0.from)qs.set('from',r0.from);if(r0.to)qs.set('to',r0.to);qs.set('page',String(state.page||1));qs.set('size','20');try{const r=await fetch('/admin/api/blocks?'+qs.toString(),{cache:'no-store'});if(!r.ok)return;const data=await r.json();if(data.today)state.serverToday=data.today;const total=data.total||0;state.page=data.page||1;state.pages=data.pages||1;state.total=total;document.getElementById('cntAll').textContent=total.toLocaleString()+' 条';updatePager();const sig=JSON.stringify(data.items||[]);if(sig===sigBlk)return;sigBlk=sig;blockItems=data.items||[];drawBlocks()}catch(e){}}
function updatePager(){document.getElementById('pageInfo').textContent=state.page+' / '+state.pages+' 页';document.getElementById('prevPage').disabled=state.page<=1;document.getElementById('nextPage').disabled=state.page>=state.pages}
function drawBlocks(){const body=document.getElementById('blocksBody');if(!blockItems.length){body.innerHTML='<tr><td colspan="5" class="emp"><b>暂无记录</b>被拦截的请求会出现在这里</td></tr>';return}body.innerHTML=blockItems.map((b,i)=>'<tr data-i="'+i+'" style="cursor:pointer"><td class="ct2" data-label="时间">'+esc(b.time)+'</td><td class="ci" data-label="IP">'+esc(b.ip)+'</td><td data-label="地区"><span class="rg">'+flagHtml(b.country)+'<span>'+esc(regionName(b.country))+'</span></span></td><td class="cp" data-label="路径" title="'+esc(b.path)+'">'+esc(shortPath(b.path))+'</td><td data-label="原因"><span class="pill '+(b.reason==='cn'?'pc':'pw')+'" title="'+esc(b.reason_text||reasonLabel(b))+'">'+esc(reasonLabel(b))+'</span></td></tr>').join('')}
function showDetail(b){document.getElementById('modalTitle').textContent='记录详情';document.getElementById('modalBody').innerHTML=[['时间',esc(b.time),false],['IP',esc(b.ip),true],['地区',esc(regionName(b.country)),false],['原因','<span class="pill '+(b.reason==='cn'?'pc':'pw')+'">'+esc(b.reason_text||reasonLabel(b))+'</span>',false],['路径',esc(b.path),true],['UA',esc(b.ua||'（未记录）'),true]].map(([k,v,m])=>'<div class="kv"><div class="kk">'+k+'</div><div class="kvv'+(m?' m':'')+'">'+v+'</div></div>').join('');document.getElementById('modal').classList.add('on')}
document.getElementById('blocksBody').addEventListener('click',e=>{const tr=e.target.closest('tr[data-i]');if(!tr)return;const b=blockItems[+tr.dataset.i];if(b)showDetail(b)});
document.getElementById('modalClose').addEventListener('click',()=>document.getElementById('modal').classList.remove('on'));
document.getElementById('modal').addEventListener('click',e=>{if(e.target.id==='modal')e.currentTarget.classList.remove('on')});
document.addEventListener('keydown',e=>{if(e.key==='Escape')document.getElementById('modal').classList.remove('on')});
document.getElementById('rangeBar').addEventListener('click',e=>{const btn=e.target.closest('.filter[data-r]');if(!btn)return;document.querySelectorAll('#rangeBar .filter').forEach(b=>b.classList.toggle('on',b===btn));state.range=rangeOf(btn.dataset.r);state.page=1;sigBlk='';loadBlocks()});
document.getElementById('prevPage').addEventListener('click',()=>{if(state.page>1){state.page--;sigBlk='';loadBlocks()}});
document.getElementById('nextPage').addEventListener('click',()=>{if(state.page<state.pages){state.page++;sigBlk='';loadBlocks()}});
function collect(useInputPort){const raw=parseInt(document.getElementById('portInput').value,10);return{port:useInputPort?(isNaN(raw)?0:raw):state.port,china_only:document.getElementById('chinaOnly').checked,whitelist:document.getElementById('whitelist').value.split('\n').map(x=>x.trim()).filter(Boolean),geo_api:document.getElementById('geoAPI').checked,geo_api_url:document.getElementById('geoAPIURL').value.trim()}}
async function save(opts){const o=opts||{};try{const r=await fetch('/admin/api/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(collect(!!o.useInputPort))});const txt=await r.text();if(!r.ok)throw new Error(txt.trim()||('HTTP '+r.status));const c=JSON.parse(txt);if(c.effective_port)applyPort(c.effective_port);if(o.msg)toast(o.msg,'ok');return true}catch(e){toast('保存失败: '+e.message,'err');return false}}
function renderWl(list){const box=document.getElementById('wlView');if(!list||!list.length){box.innerHTML='<span class="wle">未限制，转发任意目标</span>';return}box.innerHTML=list.map(h=>'<span class="wli">'+esc(maskHost(h))+'</span>').join('')}
function wlMode(edit){document.getElementById('wlView').style.display=edit?'none':'flex';document.getElementById('wlViewActions').style.display=edit?'none':'flex';document.getElementById('wlEditWrap').style.display=edit?'block':'none'}
document.getElementById('wlEditBtn').addEventListener('click',()=>wlMode(true));
document.getElementById('wlCancel').addEventListener('click',()=>{loadConfig();wlMode(false)});
document.getElementById('save').addEventListener('click',async()=>{if(await save({msg:'白名单已保存'})){renderWl(document.getElementById('whitelist').value.split('\n').map(x=>x.trim()).filter(Boolean));wlMode(false)}});
function askJump(p){const host=location.hostname||'localhost',url=location.protocol+'//'+host+':'+p+'/admin/';document.getElementById('modalTitle').textContent='端口已切换';document.getElementById('modalBody').innerHTML='<div class="kv"><div class="kk">新地址</div><div class="kvv m">'+esc(url)+'</div></div><div class="hint" style="margin-top:16px">服务已在新端口监听，当前页面即将失效</div><div class="acts" style="margin-top:20px"><button class="btn b" id="jumpNow">立即跳转</button><button class="btn g" id="jumpLater">稍后</button></div>';document.getElementById('modal').classList.add('on');document.getElementById('jumpNow').addEventListener('click',()=>{location.href=url});document.getElementById('jumpLater').addEventListener('click',()=>{document.getElementById('modal').classList.remove('on');document.getElementById('portInput').value=state.port})}
document.getElementById('savePort').addEventListener('click',async()=>{const raw=parseInt(document.getElementById('portInput').value,10);if(isNaN(raw)||raw<1||raw>65535){toast('端口需在 1-65535 之间','err');return}if(raw===state.port){toast('端口没有变化','err');return}const old=state.port,btn=document.getElementById('savePort');btn.disabled=true;const ok=await save({useInputPort:true});btn.disabled=false;if(!ok)return;if(state.port!==old)askJump(state.port);else document.getElementById('portInput').value=state.port});
document.getElementById('chinaOnly').addEventListener('change',async()=>{const on=document.getElementById('chinaOnly').checked;if(await save({}))toast(on?'已开启：仅中国大陆可访问':'已关闭大陆限制','ok')});
document.getElementById('geoAPI').addEventListener('change',async()=>{const on=document.getElementById('geoAPI').checked;if(await save({}))toast(on?'已开启在线查询':'已关闭在线查询','ok')});
document.getElementById('geoAPIURL').addEventListener('change',async()=>{if(await save({}))toast('接口地址已保存','ok')});
document.getElementById('geoTest').addEventListener('click',async()=>{const btn=document.getElementById('geoTest'),out=document.getElementById('geoResult');btn.disabled=true;out.innerHTML='<div style="margin-top:12px;color:var(--t3);font-size:13px">正在请求接口…</div>';await save({});try{const r=await fetch('/admin/api/geotest',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});const d=await r.json();if(d.ok){out.innerHTML='<div style="margin-top:12px;color:var(--ok);font-size:13px">接口正常：'+esc(d.ip)+' → '+esc(d.name)+'（'+esc(d.code)+'）</div>'}else{out.innerHTML='<div style="margin-top:12px;color:var(--w);font-size:13px">接口失败：'+esc(d.error)+'</div>'}}catch(e){out.innerHTML='<div style="margin-top:12px;color:var(--w);font-size:13px">请求失败：'+esc(e.message)+'</div>'}btn.disabled=false});
document.getElementById('regeoBtn').addEventListener('click',async()=>{const btn=document.getElementById('regeoBtn');btn.disabled=true;try{const r=await fetch('/admin/api/regeo',{method:'POST'});const d=await r.json();toast(d.started?'开始重新识别':'正在识别中','ok');setTimeout(()=>{loadStats();btn.disabled=false},700)}catch(e){toast('启动失败: '+e.message,'err');btn.disabled=false}});
function confirmAction(opts){return new Promise(resolve=>{const modal=document.getElementById('modal');document.getElementById('modalTitle').textContent=opts.title;document.getElementById('modalBody').innerHTML='<div style="font-size:13.5px;line-height:1.75;color:var(--t2);margin-bottom:20px">'+(opts.body||'')+'</div><div class="acts" style="justify-content:flex-end;margin-top:0"><button class="btn g" id="cfCancel">取消</button><button class="btn b" id="cfOk" style="'+(opts.danger?'background:#dc2626':'')+'">'+(opts.okText||'确定')+'</button></div>';modal.classList.add('on');const close=v=>{modal.classList.remove('on');resolve(v)};document.getElementById('cfOk').onclick=()=>close(true);document.getElementById('cfCancel').onclick=()=>close(false)})}
document.getElementById('resetConfigBtn').addEventListener('click',async()=>{const ok=await confirmAction({title:'还原初始化设置',body:'将恢复为默认值：<br>· 仅允许中国大陆 IP：<b>关闭</b><br>· 目标域名白名单：<b>清空</b><br>· 在线 IP 查询：<b>开启</b><br>· 接口地址：<b>恢复默认</b><br><br>监听端口保持不变，统计数据与密码不受影响。',okText:'确认还原',danger:true});if(!ok)return;try{const r=await fetch('/admin/api/reset-config',{method:'POST'});const txt=await r.text();if(!r.ok)throw new Error(txt.trim()||('HTTP '+r.status));const c=JSON.parse(txt);if(c.effective_port)applyPort(c.effective_port);await loadConfig();loadStats();toast('已还原为默认设置','ok')}catch(e){toast('还原失败: '+e.message,'err')}});
document.getElementById('clearStatsBtn').addEventListener('click',async()=>{const ok=await confirmAction({title:'清空所有统计',body:'以下数据将被清除，<b style="color:#dc2626">不可恢复</b>：<br>· 今日/累计请求数与流量<br>· IP 与地区分布<br>· 拦截记录与拦截计数<br><br>配置、白名单、管理密码<b>不受影响</b>。',okText:'确认清空',danger:true});if(!ok)return;try{const r=await fetch('/admin/api/clear-stats',{method:'POST'});if(!r.ok){const txt=await r.text();throw new Error(txt.trim()||('HTTP '+r.status))}toast('统计已清空','ok');loadStats();if(document.getElementById('overview').classList.contains('on'))loadOverview()}catch(e){toast('清空失败: '+e.message,'err')}});
document.addEventListener('click',e=>{const btn=e.target.closest('[data-goto]');if(btn){e.preventDefault();switchTab(btn.dataset.goto)}});
loadConfig();loadStats();loadOverview();setInterval(loadStats,5000);
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
write_default_config() {
  cat > "$CONFIG_FILE" <<'JSON'
{"port":0,"china_only":false,"whitelist":[],"geo_api":true,"geo_api_url":""}
JSON
}
systemd_quote() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//%/%%}"; printf '"%s"' "$s"
}
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
Environment=GOGC=200
ExecStart=${BIN_PATH} run -port ${PORT} -admin-user ${u} -admin-pass ${p} -config ${CONFIG_FILE} -stats ${STATS_FILE}
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
    cp -f "$PREBUILT" "$out"; chmod 0755 "$out"; return
  fi
  ensure_go
  BUILD_TMPDIR="$(mktemp -d)"
  write_go_source "$BUILD_TMPDIR"
  info "初始化模块并解析依赖..."
  (
    cd "$BUILD_TMPDIR"
    export GOTOOLCHAIN=auto GOFLAGS=-mod=mod
    go mod init emby-proxy >/dev/null 2>&1 || true
    go get "github.com/phuslu/iploc@${IPLOC_VERSION}" >/dev/null 2>&1 || true
    go mod tidy >/dev/null 2>&1 || true
    grep -q "phuslu/iploc" go.mod 2>/dev/null || go get "github.com/phuslu/iploc@latest" >/dev/null 2>&1 || true
    go mod tidy >/dev/null 2>&1 || die "依赖解析失败（可设 GOPROXY=https://goproxy.cn,direct 后重试）"
  )
  info "编译中..."
  ( cd "$BUILD_TMPDIR" && CGO_ENABLED=0 GOTOOLCHAIN=auto GOFLAGS=-mod=mod go build -trimpath -ldflags "-s -w" -o "$out" . ) || die "go build 失败"
}
local_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  fi
  [[ -z "$ip" ]] && ip="127.0.0.1"
  printf '%s' "$ip"
}
port_listen() { (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null; }
installed_port() {
  local p=""
  if [[ -f "$CONFIG_FILE" ]]; then p="$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]\+' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]\+$' | head -1)"; fi
  if [[ ! "$p" =~ ^[0-9]+$ ]] || (( p == 0 )); then
    if [[ -f "$UNIT_FILE" ]]; then p="$(sed -n 's/.*-port \([0-9]\{1,5\}\).*/\1/p' "$UNIT_FILE" | head -1)"; fi
  fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; else printf '%s' "$DEFAULT_PORT"; fi
}
effective_port() {
  local p=""
  if [[ -f "$CONFIG_FILE" ]]; then p="$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$' | head -1)"; fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; return; fi
  if [[ -f "$UNIT_FILE" ]]; then
    p="$(sed -n 's/.*-port \([0-9]\{1,5\}\).*/\1/p' "$UNIT_FILE" | head -1)"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; return; fi
  fi
  printf '%s' "$PORT"
}
print_access_info() {
  local ip ep; ip="$(local_ip)"; ep="$(effective_port)"
  printf '\n   管理页:  http://%s:%s/admin/\n' "$ip" "$ep"
  printf '   用户名:  %s\n' "$ADMIN_USER"
  printf '   密  码:  %s\n' "$ADMIN_PASS"
  if [[ $GENERATED_PASS -eq 1 ]]; then printf '           （已保存到 %s）\n' "$ADMIN_PASS_FILE"; else printf '           （沿用已保存的密码，文件 %s）\n' "$ADMIN_PASS_FILE"; fi
  printf '\n   用法：http://%s:%s/https://www.example.com/emby/Users\n' "$ip" "$ep"
  printf '   配置文件: %s\n   统计文件: %s\n   查看日志: journalctl -u %s -f\n\n' "$CONFIG_FILE" "$STATS_FILE" "$SERVICE_NAME"
}
cmd_install() {
  parse_install_args "$@"
  require_root install
  require_systemd
  if [[ -t 0 ]] && [[ $BINARY_ONLY -eq 0 ]] && [[ $PORT_GIVEN -eq 0 || $PASS_GIVEN -eq 0 ]]; then
    printf '\n'
    if [[ $PORT_GIVEN -eq 0 ]]; then prompt_port "$(installed_port)" || die "已取消"; PORT="$PROMPT_RESULT"; fi
    if [[ -z "$ADMIN_PASS" ]]; then prompt_pass || die "已取消"; ADMIN_PASS="$PROMPT_RESULT"; PASS_GIVEN=1; fi
  fi
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "端口无效: $PORT"
  if [[ $BINARY_ONLY -eq 1 ]]; then info "更新模式：只替换程序"; fi
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  if [[ -n "$ADMIN_PASS" ]]; then
    ( umask 077; printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE" ); GENERATED_PASS=1
  elif [[ -f "$ADMIN_PASS_FILE" ]]; then
    ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"; GENERATED_PASS=0
  else
    ADMIN_PASS="$(genpass)"; ( umask 077; printf '%s' "$ADMIN_PASS" > "$ADMIN_PASS_FILE" ); GENERATED_PASS=1
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then write_default_config; info "已创建配置文件"; fi
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
    printf '%s\n' "$expected_unit" > "$UNIT_FILE"; chmod 0644 "$UNIT_FILE"
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
  local installed_bin=""
  if [[ -f "$UNIT_FILE" ]]; then installed_bin="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$UNIT_FILE" | head -n1)"; fi
  stop_and_disable
  [[ -f "$UNIT_FILE" ]] && { rm -f "$UNIT_FILE"; info "已删除服务单元"; }
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  [[ -n "$installed_bin" && -f "$installed_bin" ]] && { rm -f "$installed_bin"; info "已删除程序: $installed_bin"; }
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
  elif [[ -f "$ADMIN_PASS_FILE" ]]; then printf '   %s密码%s   沿用已保存的密码\n' "$C_D" "$C_0"
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
