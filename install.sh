#!/usr/bin/env bash
# Emby 路径反代一键安装 / 管理脚本
# 功能：编译并安装 Go 反代程序、注册 systemd 服务、提供交互菜单
# 用法：sudo bash install.sh          # 进入菜单
#       sudo bash install.sh install  # 直接安装
#       sudo bash install.sh update   # 仅更新二进制
set -euo pipefail

APP_VERSION="3.5.0"

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
Emby 路径反代 v${APP_VERSION} 一键安装
  sudo $0          # 打开安装管理菜单（推荐）
  sudo $0 menu    # 同上
  sudo $0 [install|update|uninstall|status|start|stop|restart]
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
	"compress/gzip"
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
	"html"
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

	"github.com/gorilla/websocket"
	"github.com/phuslu/iploc"
	bolt "go.etcd.io/bbolt"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/sync/singleflight"
)

//go:embed admin.html
var adminHTML []byte

//go:embed chart.umd.min.js
var chartJS []byte

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

const pageCSS = `
*{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#f4f7fb;--card:#fff;--bd:#e6ebf2;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--pb:#bfdbfe;--d:#ef4444;--ds:#fef2f2;--db:#fecaca;--w:#f59e0b;--ws:#fffbeb;--wb:#fde68a;--ok:#10b981;--oks:#ecfdf5;--ob:#a7f3d0;--panel:#f8fafc;--r:18px;--mono:Consolas,"SFMono-Regular",Menlo,monospace}
html[data-theme="dark"]{--bg:#0b1220;--card:#111a2b;--bd:#1f2b3d;--t:#e6edf7;--t2:#a8b6c9;--t3:#71809a;--p:#3b82f6;--pd:#7db2ff;--ps:#152742;--pb:#264a7d;--d:#f87171;--ds:#2a1418;--db:#4c2027;--w:#fbbf24;--ws:#2a2113;--wb:#4a3a18;--ok:#34d399;--oks:#0d2b22;--ob:#1b5340;--panel:#0e1726}
body{min-height:100dvh;background:var(--bg);background-image:radial-gradient(900px 420px at 50% -12%,rgba(59,130,246,.10),transparent 72%);color:var(--t);font:15px/1.65 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;padding:28px 18px}
.wrap{width:100%;max-width:560px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:var(--r);padding:26px 32px 20px;box-shadow:0 14px 44px -14px rgba(15,23,42,.16)}
html[data-theme="dark"] .card{box-shadow:0 14px 44px -14px rgba(0,0,0,.5)}
.brand{display:flex;align-items:center;gap:11px;padding-bottom:16px;border-bottom:1px solid var(--bd);margin-bottom:24px}
.brand-logo{width:34px;height:34px;border-radius:9px;flex-shrink:0}
.brand-n{font-size:14px;font-weight:650;line-height:1.25}
.brand-s{font-size:11.5px;color:var(--t3);margin-top:2px}
.brand-r{margin-left:auto;font-size:11.5px;color:var(--t3);font-family:var(--mono);white-space:nowrap}
.hero{text-align:center}
.ico{width:62px;height:62px;border-radius:19px;display:inline-flex;align-items:center;justify-content:center;margin-bottom:15px}
.ico svg{width:30px;height:30px}
.ico.red{background:var(--ds);color:var(--d)}
.ico.amber{background:var(--ws);color:var(--w)}
.ico.green{background:var(--oks);color:var(--ok)}
.ico.blue{background:var(--ps);color:var(--p)}
.badge{display:inline-block;font:600 11.5px/1.2 var(--mono);letter-spacing:.2px;padding:5px 11px;border-radius:999px;border:1px solid var(--bd);color:var(--t2);background:var(--panel);margin-bottom:11px}
.badge.red{color:var(--d);background:var(--ds);border-color:var(--db)}
.badge.amber{color:var(--w);background:var(--ws);border-color:var(--wb)}
.badge.green{color:var(--ok);background:var(--oks);border-color:var(--ob)}
.badge.blue{color:var(--p);background:var(--ps);border-color:var(--pb)}
h1{font-size:22px;font-weight:700;letter-spacing:-.4px;margin-bottom:8px;color:var(--t)}
.sum{font-size:13.5px;font-weight:650;color:var(--pd);margin-bottom:8px}
.desc{font-size:14px;color:var(--t2);line-height:1.78;max-width:450px;margin:0 auto}
.sec{margin-top:22px;text-align:left}
.sec-t{font-size:11px;font-weight:700;letter-spacing:.8px;color:var(--t3);margin-bottom:9px;display:flex;align-items:center;gap:9px}
.sec-t:after{content:"";flex:1;height:1px;background:var(--bd)}
.kv{background:var(--panel);border:1px solid var(--bd);border-radius:12px;padding:5px 14px}
.kv-r{display:flex;gap:12px;padding:7px 0;border-bottom:1px dashed var(--bd);font-size:13px}
.kv-r:last-child{border-bottom:0}
.kv-k{color:var(--t3);width:76px;flex-shrink:0}
.kv-v{color:var(--t);word-break:break-all;font-family:var(--mono);font-size:12.5px;flex:1;line-height:1.55}
.tips{background:var(--ps);border:1px solid var(--pb);border-radius:12px;padding:12px 16px 12px 30px;margin:0;font-size:12.8px;color:var(--t2);line-height:1.8}
.tips li{margin:2px 0;padding-left:2px}
.tips li::marker{color:var(--p)}
html[data-theme="dark"] .tips{color:var(--t2)}
.tech{margin-top:9px;background:var(--panel);border:1px solid var(--bd);border-radius:10px;padding:9px 12px;font:12px/1.65 var(--mono);color:var(--t2);word-break:break-all}
.usage{background:var(--panel);border:1px solid var(--bd);border-radius:12px;padding:13px 15px;font-size:13px;color:var(--t2);line-height:1.8}
.usage code{display:block;background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:8px 11px;margin:7px 0;font:12.3px/1.6 var(--mono);color:var(--pd);word-break:break-all}
.hint{font-size:12.3px;color:var(--t3);line-height:1.7}
.acts{display:flex;gap:10px;justify-content:center;flex-wrap:wrap;margin-top:22px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;padding:10px 20px;border-radius:10px;font-size:13.5px;font-weight:600;cursor:pointer;border:1px solid transparent;font-family:inherit;text-decoration:none;transition:.18s}
.btn.b{background:var(--p);color:#fff}
.btn.b:hover{background:var(--pd);transform:translateY(-1px)}
.btn.g{background:var(--card);border-color:var(--bd);color:var(--t2)}
.btn.g:hover{background:var(--panel);color:var(--t)}
.foot{margin-top:20px;padding-top:14px;border-top:1px solid var(--bd);display:flex;justify-content:space-between;gap:10px;font-size:11.5px;color:var(--t3);font-family:var(--mono)}
@media(max-width:520px){body{padding:16px 12px}.card{padding:20px 18px 16px}h1{font-size:20px}.kv-k{width:68px}.foot{flex-direction:column;gap:3px}.brand-r{font-size:10.5px}}
`

// ---------------- 统一页面框架（首页 / 所有提示与错误页）----------------
// 所有动态内容统一经 pageEsc 转义，避免 Host、路径、UA、上游错误等用户输入造成 XSS。

type pageKV struct{ K, V string }
type pageAction struct {
	Label, Href, Kind, Copy string
	Reload                  bool
}
type pageData struct {
	Status    int
	Kind      string // red / amber / blue / green
	Title     string
	Summary   string
	Desc      string
	Rows      []pageKV
	Tips      []string
	Tech      string
	UsageHTML string
	Actions   []pageAction
	FootL     string
	FootR     string
}

var statusZh = map[int]string{
	400: "请求有误", 401: "未授权", 403: "禁止访问", 404: "页面不存在",
	405: "方法不支持", 410: "资源已失效", 429: "请求过于频繁",
	500: "服务内部错误", 502: "网关错误", 503: "服务不可用", 504: "网关超时",
}

var pageIconSVG = map[string]string{
	"red":   `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9.5 9.5 5 5M14.5 9.5l-5 5"/></svg>`,
	"amber": `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg>`,
	"blue":  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="10.5" cy="10.5" r="7"/><path d="m20 20-4.2-4.2"/><path d="M8.5 9a2.5 2.5 0 1 1 3.2 2.4c-.7.3-1.2.9-1.2 1.7v.4M10.5 16.5h.01"/></svg>`,
	"green": `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8 12 2.8 2.8L16 9.6"/></svg>`,
}

func pageEsc(s string) string { return html.EscapeString(s) }

func pageStatusLabel(status int) string {
	zh := statusZh[status]
	if zh == "" {
		zh = http.StatusText(status)
	}
	return fmt.Sprintf("%d · %s", status, zh)
}

func pageIcon(kind string) string {
	if s, ok := pageIconSVG[kind]; ok {
		return s
	}
	return pageIconSVG["red"]
}

func pageDuration(d time.Duration) string {
	sec := int64(d.Seconds())
	if sec < 0 {
		sec = 0
	}
	days, hh, mm, ss := sec/86400, (sec%86400)/3600, (sec%3600)/60, sec%60
	switch {
	case days > 0:
		return fmt.Sprintf("%d 天 %d 小时 %d 分", days, hh, mm)
	case hh > 0:
		return fmt.Sprintf("%d 小时 %d 分", hh, mm)
	case mm > 0:
		return fmt.Sprintf("%d 分 %d 秒", mm, ss)
	default:
		return fmt.Sprintf("%d 秒", ss)
	}
}

func renderPage(w http.ResponseWriter, p pageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(p.Status)
	var b strings.Builder
	b.WriteString(`<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">`)
	b.WriteString(`<link rel="icon" href="/favicon.ico` + iconVer + `"><title>` + pageEsc(p.Title) + ` · 服务</title>`)
	b.WriteString(`<script>try{var t=localStorage.getItem('ep_theme');if(t!=='dark'&&t!=='light'){t=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light'}document.documentElement.dataset.theme=t}catch(e){}</script>`)
	b.WriteString(`<style>` + pageCSS + `</style></head><body><div class="wrap"><div class="card">`)
	b.WriteString(`<div class="brand"><img class="brand-logo" src="/logo.png" alt=""><div><div class="brand-n">服务</div><div class="brand-s">Emby Proxy · v` + appVersionStr + `</div></div><div class="brand-r">` + pageEsc(pageStatusLabel(p.Status)) + `</div></div>`)
	b.WriteString(`<div class="hero"><div class="ico ` + p.Kind + `">` + pageIcon(p.Kind) + `</div>`)
	b.WriteString(`<div class="badge ` + p.Kind + `">` + pageEsc(pageStatusLabel(p.Status)) + `</div>`)
	b.WriteString(`<h1>` + pageEsc(p.Title) + `</h1>`)
	if p.Summary != "" {
		b.WriteString(`<div class="sum">` + pageEsc(p.Summary) + `</div>`)
	}
	if p.Desc != "" {
		b.WriteString(`<div class="desc">` + pageEsc(p.Desc) + `</div>`)
	}
	b.WriteString(`</div>`)
	if len(p.Rows) > 0 {
		b.WriteString(`<div class="sec"><div class="sec-t">请求详情</div><div class="kv">`)
		for _, kv := range p.Rows {
			b.WriteString(`<div class="kv-r"><div class="kv-k">` + pageEsc(kv.K) + `</div><div class="kv-v">` + pageEsc(kv.V) + `</div></div>`)
		}
		b.WriteString(`</div></div>`)
	}
	if p.UsageHTML != "" {
		b.WriteString(`<div class="sec"><div class="sec-t">使用方式</div>` + p.UsageHTML + `</div>`)
	}
	if len(p.Tips) > 0 {
		b.WriteString(`<div class="sec"><div class="sec-t">可以试试</div><ul class="tips">`)
		for _, t := range p.Tips {
			b.WriteString(`<li>` + pageEsc(t) + `</li>`)
		}
		b.WriteString(`</ul></div>`)
	}
	if p.Tech != "" {
		b.WriteString(`<div class="sec"><div class="sec-t">技术详情</div><div class="tech">` + pageEsc(p.Tech) + `</div></div>`)
	}
	if len(p.Actions) > 0 {
		b.WriteString(`<div class="acts">`)
		for _, a := range p.Actions {
			kind := a.Kind
			if kind == "" {
				kind = "g"
			}
			switch {
			case a.Reload:
				b.WriteString(`<button class="btn ` + kind + `" onclick="location.reload()">` + pageEsc(a.Label) + `</button>`)
			case a.Copy != "":
				b.WriteString(`<button class="btn ` + kind + `" data-copy="` + pageEsc(a.Copy) + `" onclick="pgCopy(this)">` + pageEsc(a.Label) + `</button>`)
			default:
				b.WriteString(`<a class="btn ` + kind + `" href="` + pageEsc(a.Href) + `">` + pageEsc(a.Label) + `</a>`)
			}
		}
		b.WriteString(`</div>`)
	}
	b.WriteString(`<div class="foot"><span>` + pageEsc(p.FootL) + `</span><span>` + pageEsc(p.FootR) + `</span></div>`)
	b.WriteString(`</div></div><script>function pgCopy(b){var t=b.getAttribute('data-copy');if(navigator.clipboard){navigator.clipboard.writeText(t).then(function(){b.textContent='已复制 \u2713'},function(){b.textContent='复制失败，请手动复制'})}else{b.textContent='请手动复制'}}</script></body></html>`)
	_, _ = w.Write([]byte(b.String()))
}

// pageRequestRows 生成每个页面共有的上下文，方便管理员按请求编号在日志中定位。
func pageRequestRows(r *http.Request, status int, reason, reqID string) []pageKV {
	ip := getClientIP(r)
	rows := []pageKV{{"状态码", fmt.Sprintf("%d %s", status, http.StatusText(status))}}
	if reason != "" {
		rows = append(rows, pageKV{"拦截原因", reason})
	}
	host := r.Host
	if host == "" {
		host = "—"
	}
	path := r.URL.RequestURI()
	if len(path) > 160 {
		path = path[:160] + "…"
	}
	rows = append(rows,
		pageKV{"访问域名", host},
		pageKV{"请求路径", path},
		pageKV{"来源 IP", ip},
		pageKV{"来源地区", countryName(countryOf(ip))},
		pageKV{"发生时间", nowBeijing().Format("2006-01-02 15:04:05") + " UTC+8"},
		pageKV{"请求编号", reqID},
	)
	return rows
}

// autoPageTips 按拦截原因码给出可操作的排查建议，不在页面里泄露白名单内容或内部配置。
func autoPageTips(status int, code string) []string {
	switch code {
	case "host_ip":
		return []string{
			"请使用管理员配置的域名访问，不要直接输入服务器 IP、localhost 或单标签主机名。",
			"若前面挂了 Nginx / CDN，确认回源保留原始 Host，或设置 proxy_set_header X-Forwarded-Host $host;",
			"如您认为当前域名应当被允许，请联系服务提供者将其加入允许列表。",
		}
	case "host_deny":
		return []string{
			"核对浏览器地址栏的域名拼写，确认与「允许访问的域名」中的条目一致。",
			"需要放行子域名时请显式填写 *.example.com；只填根域不会自动放宽到子域。",
			"前面挂了反向代理时，确认回传的原始 Host / X-Forwarded-Host 没有被改写。",
		}
	case "ban":
		return []string{
			"您的来源 IP 被管理员加入了黑名单，本次请求未进入反代流程。",
			"若经过代理或 VPN，出口 IP 变化后结果可能不同；如为误封请联系管理员移除。",
		}
	case "ua":
		return []string{
			"换用已授权的客户端（如 Infuse、Emby 官方 App）再试。",
			"如需使用当前客户端，请联系服务提供者为其授权。",
		}
	case "cn":
		return []string{
			"当前出口 IP 的归属地不在放行范围内，切换网络后重试。",
			"如需从当前地区访问，请联系服务提供者调整地区限制。",
		}
	case "whitelist":
		return []string{
			"检查 URL 路径里填写的上游域名是否正确，以及是否在「上游域名白名单」中。",
			"注意这里校验的是被反代的目标，与「访问域名白名单」是两个不同的设置。",
		}
	}
	switch {
	case status == http.StatusNotFound:
		return []string{"核对访问路径是否完整，注意不要遗漏开头的斜杠。", "反代请求的格式为 /https://上游域名/路径。"}
	case status == http.StatusGone:
		return []string{"测速链接有 7 天有效期与可用次数上限，请联系管理员重新生成。"}
	case status == http.StatusTooManyRequests:
		return []string{"请稍等片刻再试，避免短时间发起大量请求。"}
	case status >= 500:
		return []string{
			"检查上游服务是否已启动、端口与协议（http / https）是否正确、防火墙是否放行。",
			"稍后重试；若持续失败，请把下方技术详情与请求编号提供给管理员。",
		}
	}
	return []string{"请核对访问地址与请求参数后重试。"}
}

type errPageCtx struct {
	Code  string   // 原因码，用于匹配建议库；留空则按状态码给建议
	Label string   // 原因中文说明
	Tips  []string // 调用点额外补充的建议
	Tech  string   // 技术详情（主要用于 5xx）
}

// serveError 生成并返回统一风格的 HTML 错误页。
// 包含请求编号、拦截原因、排查建议；同时写一条带编号的日志方便定位。
func serveError(w http.ResponseWriter, r *http.Request, status int, title, message string, ctx ...errPageCtx) {
	var c errPageCtx
	if len(ctx) > 0 {
		c = ctx[0]
	}
	reqID := randToken(4)
	reason := ""
	if c.Code != "" {
		reason = c.Code
		if c.Label != "" {
			reason = c.Label + "（" + c.Code + "）"
		}
	}
	kind := "red"
	switch status {
	case http.StatusNotFound:
		kind = "blue"
	case http.StatusGone, http.StatusTooManyRequests, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		kind = "amber"
	}
	tips := append([]string{}, c.Tips...)
	tips = append(tips, autoPageTips(status, c.Code)...)
	tips = append(tips, "若确认是误拦截，请把上面的「请求编号」与「发生时间」提供给服务提供者，以便按编号在服务端日志中定位本次请求。")
	actions := []pageAction{{Label: "返回首页", Href: "/", Kind: "g"}}
	if status >= 500 || status == http.StatusTooManyRequests {
		actions = append([]pageAction{{Label: "重试", Kind: "b", Reload: true}}, actions...)
	}
	log.Printf("[%s] %d %s ip=%s host=%s path=%s", reqID, status, c.Code, getClientIP(r), r.Host, r.URL.RequestURI())
	renderPage(w, pageData{
		Status: status, Kind: kind, Title: title, Summary: reason,
		Desc: message, Rows: pageRequestRows(r, status, reason, reqID),
		Tips: tips, Tech: c.Tech, Actions: actions,
		FootL: "Emby Proxy · 访问受控", FootR: "ID " + reqID,
	})
}

func serveHome(w http.ResponseWriter, r *http.Request) {
	ip := getClientIP(r)
	host := r.Host
	if host == "" {
		host = "localhost"
	}
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")), "https") {
		scheme = "https"
	}
	guard := "未启用"
	if c := currentCfg(); c != nil && c.HostGuardOn {
		guard = "已启用 · 仅允许授权域名访问"
	}
	rows := []pageKV{
		{"运行状态", "运行中"},
		{"运行时长", pageDuration(time.Since(startedAt))},
		{"服务版本", "v" + appVersionStr},
		{"当前域名", host},
		{"来源 IP", ip},
		{"来源地区", countryName(countryOf(ip))},
		{"客户端", uaClassOfEx(r.UserAgent())},
		{"域名守卫", guard},
		{"当前时间", nowBeijing().Format("2006-01-02 15:04:05") + " UTC+8"},
	}
	ex1 := scheme + "://" + host + "/https://上游域名/路径"
	ex2 := scheme + "://" + host + "/http://192.168.1.10:8096/emby/Items?api_key=xxx"
	usage := `<div class="usage">在访问域名后直接拼上目标地址即可反代：<code>` + pageEsc(ex1) + `</code>示例：<code>` + pageEsc(ex2) + `</code><div class="hint">支持 http / https、查询参数与 WebSocket；目标域名需位于「上游域名白名单」中（若已启用）。</div></div>`
	renderPage(w, pageData{
		Status: http.StatusOK, Kind: "green", Title: "服务运行中",
		Summary: "网关已就绪",
		Desc:    "这是一个 Emby 路径反代网关。本页仅展示服务状态与用法，不会暴露任何媒体内容。",
		Rows:    rows, UsageHTML: usage,
		Tips: []string{
			"若访问被拒绝，错误页会显示具体拦截原因、访问域名与请求编号，按提示排查即可。",
			"反代地址格式为 /https://上游域名/路径，目标域名需在允许范围内。",
			"如遇持续失败，请把错误页上的请求编号提供给服务提供者以便定位。",
		},
		Actions: []pageAction{
			{Label: "复制示例链接", Kind: "b", Copy: ex2},
		},
		FootL: "Emby Proxy · v" + appVersionStr,
		FootR: nowBeijing().Format("2006-01-02 15:04:05") + " UTC+8",
	})
}

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
	u := &url.URL{Scheme: scheme, Host: authority, Path: pathPart, RawQuery: r.URL.RawQuery}
	if u.Host == "" {
		return nil, fmt.Errorf("目标地址无效：%s", authority)
	}
	return u, nil
}

// Config 是网关运行时配置，序列化后存入 BoltDB 的 config 桶。
// 后台保存时整份覆盖；端口变更会触发热切换监听。
type Config struct {
	Port        int      `json:"port"`
	ChinaOnly   bool     `json:"china_only"`
	Whitelist   []string `json:"whitelist"`
	BanList     []string `json:"ban_list"`
	AllowedUAs  []string `json:"allowed_uas"`
	// 访问域名守卫：校验浏览器地址栏里的 Host，禁止用服务器 IP 直连反代。
	// 与上面的 Whitelist（路径里允许反代到的上游域名）是两个不同维度，互不影响。
	HostGuardOn  bool     `json:"host_guard_on"`  // 总开关，默认 false 以兼容旧配置
	AllowedHosts []string `json:"allowed_hosts"` // 允许访问的域名；留空则只禁 IP/localhost 直连
	ReportURL   string   `json:"report_url"`
	ReportToken string   `json:"report_token"`
	ReportOn    bool     `json:"report_on"`
	ReportNote  string   `json:"report_note"`
	AdminAllow  []string `json:"admin_allow"`
	// 昨日日报自定义格式
	DailyTmplOn    bool   `json:"daily_tmpl_on"`    // 开启后日报以渲染文本发送，关闭则发送标准 JSON
	DailyTmpl      string `json:"daily_tmpl"`       // 模板内容，支持 {{date}} {{requests}} 等占位符
	DailyTmplURL   string `json:"daily_tmpl_url"`   // 日报发送地址，留空使用 report_url
	DailyTmplToken string `json:"daily_tmpl_token"` // 日报 Bearer Token，留空使用 report_token
	DailyTmplType  string `json:"daily_tmpl_type"`  // Content-Type，默认 text/plain
}

var startedAt = time.Now()

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

const (
	iconFaviconURL = "https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/img/emby_rp_vps_go.ico"
	iconLogoURL    = "https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/img/emby_rp_vps_go.PNG"
	icon192URL     = "https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/img/emby_rp_vps_go_192.png"
	icon512URL     = "https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/img/emby_rp_vps_go_512.png"
)

func redirectIcon(w http.ResponseWriter, r *http.Request, src string) {
	http.Redirect(w, r, src, http.StatusFound)
}

func currentCfg() *Config {
	if p := cfgPtr.Load(); p != nil {
		return p
	}
	return &Config{}
}

type compiledACL struct {
	exactBan  map[string]struct{}
	cidrs     []*net.IPNet
	uaNeedles []string
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

func pageParams(r *http.Request, defLimit int) (int, int) {
	limit := defLimit
	if s := r.URL.Query().Get("limit"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			limit = n
		}
	}
	if limit > 2000 {
		limit = 2000
	}
	offset := 0
	if s := r.URL.Query().Get("offset"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n >= 0 {
			offset = n
		}
	}
	return limit, offset
}

// isBannedIP 判断来源 IP 是否命中黑名单（精确 IP 或 CIDR）。
// 命中后请求在判定链早期被拒绝，不进入反代。
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

func uaWhitelistKeyword(ua string) string {
	for _, u := range currentCfg().AllowedUAs {
		k := strings.TrimSpace(u)
		if k == "" {
			continue
		}
		if strings.Contains(strings.ToLower(ua), strings.ToLower(k)) {
			return k
		}
	}
	return ""
}

func uaClassOfEx(ua string) string {
	cls := uaClassOf(ua)
	if cls == "其他" || cls == "未知" {
		if k := uaWhitelistKeyword(ua); k != "" {
			return k
		}
	}
	return cls
}

// uaAllowed 检查 User-Agent 是否命中白名单关键字。
// 白名单为空时全部放行；非空时必须包含任一关键字才放行。
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

// startListen 在指定端口启动（或热切换）HTTP 监听。
// 成功后关闭旧 Listener；失败时由调用方负责回滚配置。
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

// loadConfig 从 BoltDB 读取配置到内存，并重建 ACL 缓存。
// 首次启动或数据库为空时使用零值配置。
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

// saveConfig 将配置整份写入 BoltDB。后台保存、导入配置时调用。
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

// whitelistMatch 判断上游目标域名是否在白名单中。
// 支持精确匹配和 *.example.com 通配；空列表表示不限制。
func whitelistMatch(list []string, targetHost string) bool {
	if len(list) == 0 {
		return true
	}
	target := normalizeHost(targetHost)
	targetRoot := rootDomain(target)
	for _, w := range list {
		w = strings.TrimSpace(w)
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

// ---------------- 访问域名守卫（Host 白名单）----------------
// 与 whitelistMatch 不同：这里校验的是浏览器地址栏中的访问域名 r.Host，
// 用来禁止通过服务器 IP 直接访问反代；Whitelist 管的是路径里的上游目标域名。

// peerAddrIP 取 TCP 对端 IP（不经过 X-Forwarded-For，避免被伪造头欺骗）。
func peerAddrIP(r *http.Request) net.IP {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		h = r.RemoteAddr
	}
	return net.ParseIP(strings.Trim(h, "[]"))
}

// normalizeAccessHost 把 Host 规范化成"纯主机名"：小写、去端口、去尾点、去 IPv6 方括号。
func normalizeAccessHost(h string) string {
	h = strings.ToLower(strings.TrimSpace(h))
	if i := strings.IndexByte(h, '#'); i >= 0 {
		h = h[:i]
	}
	h = strings.TrimSpace(h)
	if strings.HasPrefix(h, "[") {
		if i := strings.IndexByte(h, ']'); i >= 0 {
			return strings.TrimSuffix(h[1:i], ".")
		}
	}
	if i := strings.LastIndexByte(h, ':'); i >= 0 && !strings.Contains(h[i+1:], ":") {
		h = h[:i]
	}
	return strings.TrimSuffix(h, ".")
}

// requestAccessHost 返回用于准入判断的访问主机名。
// 本机回环（Nginx/CDN 回源）且带 X-Forwarded-Host 时优先采信该头，
// 因为反代常把 Host 改写成 127.0.0.1:端口；公网直连一律不采信，防止伪造绕过。
func requestAccessHost(r *http.Request) string {
	h := strings.TrimSpace(r.Host)
	if peer := peerAddrIP(r); peer != nil && peer.IsLoopback() {
		xfh := strings.TrimSpace(r.Header.Get("X-Forwarded-Host"))
		if i := strings.IndexByte(xfh, ','); i >= 0 {
			xfh = xfh[:i]
		}
		if v := strings.TrimSpace(xfh); v != "" {
			h = v
		}
	}
	return normalizeAccessHost(h)
}

// isBareHost 判断是否为"裸访问"：IP 地址、localhost 或不含点号的单标签主机名。
func isBareHost(h string) bool {
	if h == "" || h == "localhost" || strings.HasSuffix(h, ".localhost") {
		return true
	}
	if net.ParseIP(h) != nil {
		return true
	}
	return !strings.Contains(h, ".")
}

// normalizeWhitelistEntry 只用于"管理员填写的白名单项"，对请求 Host 不适用。
// 容错常见写法：粘贴完整 URL（https://example.com/path）、带 userinfo、带端口等，
// 一律归一成纯主机名；保留 *. 通配前缀。请求侧仍由 normalizeAccessHost 严格处理，
// 不接受畸形 Host 头，避免被伪造绕过。
func normalizeWhitelistEntry(w string) string {
	w = strings.ToLower(strings.TrimSpace(w))
	if i := strings.Index(w, "://"); i >= 0 {
		w = w[i+3:]
	}
	if i := strings.IndexByte(w, '/'); i >= 0 {
		w = w[:i]
	}
	if i := strings.IndexByte(w, '?'); i >= 0 {
		w = w[:i]
	}
	if i := strings.LastIndexByte(w, '@'); i >= 0 {
		w = w[i+1:]
	}
	return normalizeAccessHost(w)
}

// hostAllowed 精确匹配访问域名，支持 *.example.com 通配（同时匹配根域）。
// 这里刻意不做 whitelistMatch 的"根域名自动放宽"，避免填了 example.com
// 却把任意 xxx.example.com 也一并放行。
func hostAllowed(list []string, host string) bool {
	for _, w := range list {
		w = strings.ToLower(strings.TrimSpace(w))
		if i := strings.IndexAny(w, "#;"); i >= 0 {
			w = strings.TrimSpace(w[:i])
		}
		w = normalizeWhitelistEntry(w)
		if w == "" {
			continue
		}
		if strings.HasPrefix(w, "*.") {
			suf := strings.TrimPrefix(w, "*.")
			if suf != "" && (host == suf || strings.HasSuffix(host, "."+suf)) {
				return true
			}
			continue
		}
		if host == w {
			return true
		}
	}
	return false
}

// accessHostAllowed 是守卫总入口，返回是否放行，以及被拒时的细分原因编码：
//   - host_ip：用 IP / localhost 等裸 Host 直连（拦截记录里标红）
//   - host_deny：域名不在允许列表中（拦截记录里标橙）
//   - 开关关闭：不限制（完全兼容旧配置）
//   - 开关开启 + 白名单非空：只放行白名单域名
//   - 开关开启 + 白名单为空：仅拒绝 IP/localhost 直连，任何域名都放行
func accessHostAllowed(c *Config, r *http.Request) (bool, string) {
	if c == nil || !c.HostGuardOn {
		return true, ""
	}
	h := requestAccessHost(r)
	if len(c.AllowedHosts) > 0 {
		if hostAllowed(c.AllowedHosts, h) {
			return true, ""
		}
		if isBareHost(h) {
			return false, "host_ip"
		}
		return false, "host_deny"
	}
	if isBareHost(h) {
		return false, "host_ip"
	}
	return true, ""
}

type BlockEvent struct {
	Time       string `json:"time"`
	IP         string `json:"ip"`
	Country    string `json:"country"`
	Host       string `json:"host"` // 触发拦截时浏览器使用的访问 Host（原始值，可带端口）
	Path       string `json:"path"`
	Reason     string `json:"reason"`
	ReasonText string `json:"reason_text"`
	UA         string `json:"ua"`
}

type DayStat struct {
	Requests      int64            `json:"requests"`
	Bytes         int64            `json:"bytes"`
	UpBytes       int64            `json:"up_bytes"`
	DownBytes     int64            `json:"down_bytes"`
	BlockedCN     int64            `json:"blocked_cn"`
	BlockedWL     int64            `json:"blocked_wl"`
	BlockedBan    int64            `json:"blocked_ban"`
	BlockedUA     int64            `json:"blocked_ua"`
	Countries     map[string]int64 `json:"countries,omitempty"`
	IPs           map[string]int64 `json:"ips,omitempty"`
	IPBytes       map[string]int64 `json:"ip_bytes,omitempty"`
	IPUpBytes     map[string]int64 `json:"ip_up_bytes,omitempty"`
	IPDownBytes   map[string]int64 `json:"ip_down_bytes,omitempty"`
	Hours         map[string]int64 `json:"hours,omitempty"`
	HourBytes     map[string]int64 `json:"hour_bytes,omitempty"`
	HourUpBytes   map[string]int64 `json:"hour_up_bytes,omitempty"`
	HourDownBytes map[string]int64 `json:"hour_down_bytes,omitempty"`
	Hosts         map[string]int64 `json:"hosts,omitempty"`
	UAClass       map[string]int64 `json:"ua_class,omitempty"`
	UARaw         map[string]int64 `json:"ua_raw,omitempty"`
}

const uaRawCap = 100

func uaRawKey(ua string) string {
	k := strings.Join(strings.Fields(ua), " ")
	if len(k) > 96 {
		k = k[:96]
	}
	return k
}

func newDayStat() *DayStat {
	return &DayStat{
		Countries:     map[string]int64{},
		IPs:           map[string]int64{},
		IPBytes:       map[string]int64{},
		IPUpBytes:     map[string]int64{},
		IPDownBytes:   map[string]int64{},
		Hours:         map[string]int64{},
		HourBytes:     map[string]int64{},
		HourUpBytes:   map[string]int64{},
		HourDownBytes: map[string]int64{},
		Hosts:         map[string]int64{},
		UAClass:       map[string]int64{},
		UARaw:         map[string]int64{},
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
	if d.UAClass == nil {
		d.UAClass = map[string]int64{}
	}
	if d.UARaw == nil {
		d.UARaw = map[string]int64{}
	}
}

func copyInt64Map(src map[string]int64) map[string]int64 {
	if len(src) == 0 {
		return nil
	}
	return cloneInt64Map(src)
}

func hour24(src map[string]int64) map[string]int64 {
	out := make(map[string]int64, 24)
	for h := 0; h < 24; h++ {
		k := fmt.Sprintf("%02d", h)
		out[k] = src[k]
	}
	return out
}

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

type Stats struct {
	SchemaVersion    int                 `json:"schema_version"`
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
	IP        string
	Country   string
	Host      string
	UAClass   string
	UARaw     string
	Bytes     int64
	UpBytes   int64
	DownBytes int64
	IsStart   bool
}

var statChan = make(chan statEvent, 10000)

var concurrent atomic.Int64
var liveClients atomic.Int32

type portTraffic struct {
	down atomic.Int64
	up   atomic.Int64
}

var traffic portTraffic

type reqBytes struct {
	up   atomic.Int64
	down atomic.Int64
	ip   string
}

type reqBytesKey struct{}

func withReqBytes(ctx context.Context, rb *reqBytes) context.Context {
	return context.WithValue(ctx, reqBytesKey{}, rb)
}

func reqBytesFrom(ctx context.Context) *reqBytes {
	rb, _ := ctx.Value(reqBytesKey{}).(*reqBytes)
	return rb
}

type ipLiveRate struct {
	up   atomic.Int64
	down atomic.Int64
}

var ipLiveRates sync.Map

func addIPLive(ip string, up, down int64) {
	if ip == "" || (up == 0 && down == 0) {
		return
	}
	v, _ := ipLiveRates.LoadOrStore(ip, &ipLiveRate{})
	r := v.(*ipLiveRate)
	if up > 0 {
		r.up.Add(up)
	}
	if down > 0 {
		r.down.Add(down)
	}
}

func snapshotIPRates() map[string][2]int64 {
	out := make(map[string][2]int64)
	ipLiveRates.Range(func(k, v any) bool {
		r := v.(*ipLiveRate)
		up, down := r.up.Swap(0), r.down.Swap(0)
		if up > 0 || down > 0 {
			out[k.(string)] = [2]int64{up, down}
		}
		return true
	})
	return out
}

// countingReader 统计请求体（客户端→上游）字节，计入上行。
// 只用于 pr.Out.Body，不要用于响应体，响应体由 countingWriter 按下行计，避免双计。
type countingReader struct {
	r  io.Reader
	rb *reqBytes
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if n > 0 {
		traffic.down.Add(int64(n))
		if c.rb != nil {
			c.rb.down.Add(int64(n))
			addIPLive(c.rb.ip, 0, int64(n))
		}
	}
	return n, err
}

// countingWriter 统计响应体（上游→客户端）字节，计入下行。
// 实现 Hijack / Unwrap，让 WebSocket 等协议升级能透传；
// 升级后的裸 TCP 双向 copy 由 ReverseProxy 接管，不计流量。
type countingWriter struct {
	http.ResponseWriter
	rb *reqBytes
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.ResponseWriter.Write(p)
	if n > 0 {
		traffic.up.Add(int64(n))
		if c.rb != nil {
			c.rb.up.Add(int64(n))
			addIPLive(c.rb.ip, int64(n), 0)
		}
	}
	return n, err
}

func (c *countingWriter) Flush() {
	if f, ok := c.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (c *countingWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := c.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("response writer 不支持 Hijack")
	}
	return h.Hijack()
}

func (c *countingWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

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
		return
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

func startNetSpeedSampler() {
	go func() {
		var lastRx, lastTx int64
		var lastT time.Time
		for {
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
					if liveClients.Load() > 0 && dt <= 10 {
						rxBps := int64(float64(dRx) / dt)
						txBps := int64(float64(dTx) / dt)
						netSpeedMu.Lock()
						curNetSpeed = netSpeed{RxBps: rxBps, TxBps: txBps}
						netSpeedMu.Unlock()
					}
				}
			}
			lastRx, lastTx, lastT = rx, tx, now

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

type speedToken struct {
	Token   string
	MaxUses int
	Uses    atomic.Int64
	Created string
}

var speedTokens sync.Map

const speedTokenValidity = 7 * 24 * time.Hour

func speedTokenExpired(st *speedToken) bool {
	t, err := time.Parse(time.RFC3339, st.Created)
	if err != nil {
		return false
	}
	return time.Since(t) > speedTokenValidity
}

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

type reportSnap struct {
	Date        string           `json:"date"`
	At          string           `json:"at"`
	Requests    int64            `json:"requests"`
	Up          int64            `json:"up"`
	Down        int64            `json:"down"`
	BlockedCN   int64            `json:"blocked_cn"`
	BlockedWL   int64            `json:"blocked_wl"`
	BlockedBan  int64            `json:"blocked_ban"`
	BlockedUA   int64            `json:"blocked_ua"`
	Hosts       map[string]int64 `json:"hosts,omitempty"`
	IPs         map[string]int64 `json:"ips,omitempty"`
	Countries   map[string]int64 `json:"countries,omitempty"`
	IPBytes     map[string]int64 `json:"ip_bytes,omitempty"`
	IPUpBytes   map[string]int64 `json:"ip_up_bytes,omitempty"`
	IPDownBytes map[string]int64 `json:"ip_down_bytes,omitempty"`
}

func satSub(a, b int64) int64 {
	if a > b {
		return a - b
	}
	return 0
}

func mapDelta(cur, prev map[string]int64) map[string]int64 {
	out := make(map[string]int64, len(cur))
	for k, v := range cur {
		if d := v - prev[k]; d > 0 {
			out[k] = d
		}
	}
	return out
}

type reportPayload struct {
	BatchID     string           `json:"batch_id"`
	NodeKey     string           `json:"node_key"`
	Node        string           `json:"node"`
	Note        string           `json:"note"`
	Version     string           `json:"version"`
	PeriodStart string           `json:"period_start"`
	PeriodEnd   string           `json:"period_end"`
	PeriodDate  string           `json:"period_date"`
	PeriodHour  string           `json:"period_hour"`
	ReportedAt  string           `json:"reported_at"`
	Requests    int64            `json:"requests"`
	UpBytes     int64            `json:"up_bytes"`
	DownBytes   int64            `json:"down_bytes"`
	Blocked     int64            `json:"blocked"`
	BlockedCN   int64            `json:"blocked_cn"`
	BlockedBan  int64            `json:"blocked_ban"`
	BlockedUA   int64            `json:"blocked_ua"`
	BlockedWL   int64            `json:"blocked_whitelist"`
	Hosts       map[string]int64 `json:"hosts"`
	IPs         map[string]int64 `json:"ips"`
	IPRequests  map[string]int64 `json:"ip_requests"`
	Countries   map[string]int64 `json:"countries"`
	IPBytes     map[string]int64 `json:"ip_bytes"`
	IPUpBytes   map[string]int64 `json:"ip_up_bytes"`
	IPDownBytes map[string]int64 `json:"ip_down_bytes"`
	IPStatsOK   bool             `json:"ip_stats_ok"`
	StatDropped int64            `json:"stats_dropped"`
	QueueDepth  int              `json:"queue_depth"`
}

var reportQueueMu sync.Mutex

func buildCurrentSnap() reportSnap {
	now := nowBeijing()
	date := beijingDate(now)
	sn := reportSnap{Date: date, At: beijingRFC3339(now)}
	statsMu.Lock()
	defer statsMu.Unlock()
	if d := stats.Daily[date]; d != nil {
		sn.Requests, sn.Up, sn.Down = d.Requests, d.UpBytes, d.DownBytes
		sn.BlockedCN, sn.BlockedWL, sn.BlockedBan = d.BlockedCN, d.BlockedWL, d.BlockedBan
		sn.BlockedUA = d.BlockedUA
		ensureDayMaps(d)
		sn.Hosts = copyInt64Map(d.Hosts)
		sn.IPs = copyInt64Map(d.IPs)
		sn.Countries = copyInt64Map(d.Countries)
		sn.IPBytes = copyInt64Map(d.IPBytes)
		sn.IPUpBytes = copyInt64Map(d.IPUpBytes)
		sn.IPDownBytes = copyInt64Map(d.IPDownBytes)
	}
	return sn
}

func loadReportSnaps() []reportSnap {
	var list []reportSnap
	_ = db.View(func(tx *bolt.Tx) error {
		if b := tx.Bucket([]byte("report_queue")); b != nil {
			if raw := b.Get([]byte("snaps")); raw != nil {
				_ = json.Unmarshal(raw, &list)
			}
		}
		return nil
	})
	return list
}

func saveReportSnaps(list []reportSnap) {
	raw, _ := json.Marshal(list)
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("report_queue"))
		if err != nil {
			return err
		}
		return b.Put([]byte("snaps"), raw)
	})
}

func startHourlySnapshotWorker() {
	go func() {
		for {
			now := nowBeijing()
			next := now.Truncate(time.Hour).Add(2 * time.Second)
			if !next.After(now) {
				next = next.Add(time.Hour)
			}
			time.Sleep(time.Until(next))
			reportQueueMu.Lock()
			snaps := loadReportSnaps()
			snaps = append(snaps, buildCurrentSnap())
			if len(snaps) > 3 {
				snaps = snaps[len(snaps)-3:]
			}
			saveReportSnaps(snaps)
			reportQueueMu.Unlock()
		}
	}()
}

func payloadFromDelta(base, cur reportSnap) reportPayload {
	p := reportPayload{
		NodeKey:    getNodeKey(),
		Node:       detectNodeName(),
		Note:       cfgPtr.Load().ReportNote,
		Version:    appVersionStr,
		ReportedAt: beijingRFC3339(nowBeijing()),
		QueueDepth: len(loadReportQueue()),
	}
	p.PeriodStart, p.PeriodEnd = base.At, cur.At
	p.PeriodDate, p.PeriodHour = base.Date, beijingHour(parseRFC3339(base.At))
	p.Requests = satSub(cur.Requests, base.Requests)
	p.UpBytes = satSub(cur.Up, base.Up)
	p.DownBytes = satSub(cur.Down, base.Down)
	p.BlockedCN = satSub(cur.BlockedCN, base.BlockedCN)
	p.BlockedWL = satSub(cur.BlockedWL, base.BlockedWL)
	p.BlockedBan = satSub(cur.BlockedBan, base.BlockedBan)
	p.BlockedUA = satSub(cur.BlockedUA, base.BlockedUA)
	p.Blocked = p.BlockedCN + p.BlockedWL + p.BlockedBan + p.BlockedUA
	p.Hosts = mapDelta(cur.Hosts, base.Hosts)
	pruneTopN(p.Hosts, 100)
	p.IPs = mapDelta(cur.IPs, base.IPs)
	pruneTopN(p.IPs, 100)
	p.IPRequests = p.IPs
	ctryDelta := mapDelta(cur.Countries, base.Countries)
	p.Countries = make(map[string]int64, len(ctryDelta))
	for code, v := range ctryDelta {
		name := countryName(code)
		p.Countries[name] += v
	}
	p.IPBytes = mapDelta(cur.IPBytes, base.IPBytes)
	p.IPUpBytes = mapDelta(cur.IPUpBytes, base.IPUpBytes)
	p.IPDownBytes = mapDelta(cur.IPDownBytes, base.IPDownBytes)

	keepIPs := topIPsByTotal(p.IPBytes, p.IPUpBytes, p.IPDownBytes, 100)
	p.IPBytes = alignIPStats(p.IPBytes, keepIPs)
	p.IPUpBytes = alignIPStats(p.IPUpBytes, keepIPs)
	p.IPDownBytes = alignIPStats(p.IPDownBytes, keepIPs)

	p.IPStatsOK = len(p.IPBytes) > 0
	p.StatDropped = statDropped.Load()
	p.BatchID = p.NodeKey + "-" + p.PeriodDate + "-" + p.PeriodHour
	return p
}

func topIPsByTotal(total, up, down map[string]int64, n int) map[string]struct{} {
	score := make(map[string]int64, len(total)+len(up)+len(down))
	for ip := range total {
		score[ip] = total[ip]
	}
	for ip := range up {
		if s := up[ip] + down[ip]; s > score[ip] {
			score[ip] = s
		}
	}
	for ip := range down {
		if s := up[ip] + down[ip]; s > score[ip] {
			score[ip] = s
		}
	}
	if n <= 0 || len(score) <= n {
		out := make(map[string]struct{}, len(score))
		for ip := range score {
			out[ip] = struct{}{}
		}
		return out
	}
	type kv struct {
		k string
		v int64
	}
	arr := make([]kv, 0, len(score))
	for ip, v := range score {
		arr = append(arr, kv{ip, v})
	}
	sort.Slice(arr, func(i, j int) bool { return arr[i].v > arr[j].v })
	out := make(map[string]struct{}, n)
	for i := 0; i < n; i++ {
		out[arr[i].k] = struct{}{}
	}
	return out
}

func alignIPStats(m map[string]int64, keep map[string]struct{}) map[string]int64 {
	out := make(map[string]int64, len(keep))
	for ip := range keep {
		out[ip] = m[ip]
	}
	return out
}

func lastFullHourReport() (reportPayload, bool) {
	snaps := loadReportSnaps()
	if len(snaps) < 2 {
		now := nowBeijing()
		lastFull := now.Truncate(time.Hour)
		prevFull := lastFull.Add(-time.Hour)
		base := reportSnap{Date: beijingDate(prevFull), At: beijingRFC3339(prevFull)}
		cur := buildCurrentSnap()
		cur.At = beijingRFC3339(lastFull)
		list := append(snaps, base, cur)
		if len(list) > 3 {
			list = list[len(list)-3:]
		}
		saveReportSnaps(list)
		snaps = list
	}
	if len(snaps) < 2 {
		return reportPayload{}, false
	}
	return payloadFromDelta(snaps[len(snaps)-2], snaps[len(snaps)-1]), true
}

// ---------- 昨日统计日报 ----------

// buildDailyReportPayload 汇总某一天（通常为昨天）的完整统计数据，作为日报 payload
func buildDailyReportPayload(date string) (reportPayload, bool) {
	statsMu.Lock()
	d := stats.Daily[date]
	if d == nil || (d.Requests == 0 && d.Bytes == 0 && d.BlockedCN == 0 && d.BlockedWL == 0 && d.BlockedBan == 0 && d.BlockedUA == 0) {
		statsMu.Unlock()
		return reportPayload{}, false
	}
	ensureDayMaps(d)
	p := reportPayload{
		NodeKey:     getNodeKey(),
		Node:        detectNodeName(),
		Note:        cfgPtr.Load().ReportNote,
		Version:     appVersionStr,
		ReportedAt:  beijingRFC3339(nowBeijing()),
		QueueDepth:  len(loadReportQueue()),
		PeriodDate:  date,
		PeriodHour:  "daily",
		Requests:    d.Requests,
		UpBytes:     d.UpBytes,
		DownBytes:   d.DownBytes,
		BlockedCN:   d.BlockedCN,
		BlockedWL:   d.BlockedWL,
		BlockedBan:  d.BlockedBan,
		BlockedUA:   d.BlockedUA,
		Hosts:       copyInt64Map(d.Hosts),
		IPs:         copyInt64Map(d.IPs),
		IPBytes:     copyInt64Map(d.IPBytes),
		IPUpBytes:   copyInt64Map(d.IPUpBytes),
		IPDownBytes: copyInt64Map(d.IPDownBytes),
		Countries:   copyInt64Map(d.Countries),
		StatDropped: statDropped.Load(),
	}
	statsMu.Unlock()

	if t, err := time.ParseInLocation("2006-01-02", date, beijingLoc); err == nil {
		p.PeriodStart = beijingRFC3339(t)
		p.PeriodEnd = beijingRFC3339(t.AddDate(0, 0, 1))
	} else {
		p.PeriodStart = date + "T00:00:00+08:00"
		p.PeriodEnd = date + "T23:59:59+08:00"
	}
	p.Blocked = p.BlockedCN + p.BlockedWL + p.BlockedBan + p.BlockedUA
	p.IPRequests = p.IPs
	pruneTopN(p.Hosts, 100)
	pruneTopN(p.IPs, 100)
	if p.Countries != nil {
		named := make(map[string]int64, len(p.Countries))
		for code, v := range p.Countries {
			named[countryName(code)] += v
		}
		p.Countries = named
	}
	keepIPs := topIPsByTotal(p.IPBytes, p.IPUpBytes, p.IPDownBytes, 100)
	p.IPBytes = alignIPStats(p.IPBytes, keepIPs)
	p.IPUpBytes = alignIPStats(p.IPUpBytes, keepIPs)
	p.IPDownBytes = alignIPStats(p.IPDownBytes, keepIPs)
	p.IPStatsOK = len(p.IPBytes) > 0
	p.BatchID = p.NodeKey + "-" + date + "-daily"
	return p, true
}

// lastDailyReportSent 读取已发送日报的最后日期（防重），空串表示从未发送
func lastDailyReportSent() string {
	var m struct {
		Date string `json:"date"`
	}
	_ = db.View(func(tx *bolt.Tx) error {
		if b := tx.Bucket([]byte("report_queue")); b != nil {
			if raw := b.Get([]byte("daily_sent")); raw != nil {
				_ = json.Unmarshal(raw, &m)
			}
		}
		return nil
	})
	return m.Date
}

func markDailyReportSent(date string) {
	raw, _ := json.Marshal(map[string]string{"date": date, "time": beijingRFC3339(nowBeijing())})
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("report_queue"))
		if err != nil {
			return err
		}
		return b.Put([]byte("daily_sent"), raw)
	})
}

// ---------- 昨日日报自定义发送格式 ----------

const defaultDailyTmpl = `【昨日统计】{{date}}
节点：{{node}}
请求：{{requests}} 次
流量：↓ {{down}} / ↑ {{up}}（共 {{total}}）
拦截：{{blocked}} 次（CN {{blocked_cn}} / BAN {{blocked_ban}} / UA {{blocked_ua}} / 白名单 {{blocked_wl}}）
Top IP：{{ips_top}}
Top 流量 IP：{{ip_bytes_top}}
Top 域名：{{hosts_top}}
国家/地区：{{countries_top}}`

func humanBytes(n int64) string {
	if n <= 0 {
		return "0 B"
	}
	if n < 1024 {
		return fmt.Sprintf("%d B", n)
	}
	units := []string{"KB", "MB", "GB", "TB", "PB"}
	div, exp := int64(1024), 0
	for m := n / 1024; m >= 1024 && exp < len(units)-1; m /= 1024 {
		div *= 1024
		exp++
	}
	s := fmt.Sprintf("%.2f", float64(n)/float64(div))
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	return s + " " + units[exp]
}

// topListText 取计数前 N 项，渲染为 "键×次数" 列表；asBytes 为 true 时次数显示为可读流量
func topListText(m map[string]int64, n int, asBytes bool) string {
	type kv struct {
		k string
		v int64
	}
	arr := make([]kv, 0, len(m))
	for k, v := range m {
		arr = append(arr, kv{k, v})
	}
	if len(arr) == 0 {
		return "无"
	}
	sort.Slice(arr, func(i, j int) bool {
		if arr[i].v != arr[j].v {
			return arr[i].v > arr[j].v
		}
		return arr[i].k < arr[j].k
	})
	if n <= 0 || n > len(arr) {
		n = len(arr)
	}
	parts := make([]string, 0, n)
	for i := 0; i < n; i++ {
		if asBytes {
			parts = append(parts, arr[i].k+"×"+humanBytes(arr[i].v))
		} else {
			parts = append(parts, fmt.Sprintf("%s×%d", arr[i].k, arr[i].v))
		}
	}
	s := strings.Join(parts, "、")
	if len(arr) > n {
		s += fmt.Sprintf(" 等 %d 项", len(arr))
	}
	return s
}

// renderDailyTemplate 把 payload 渲染进模板占位符
// renderDailyTemplate 渲染日报模板；jsonSafe 为 true 时（模板是 JSON，如 Telegram sendMessage）
// 会对替换值做 JSON 转义，保证多行排行占位符不会破坏 JSON 结构
func renderDailyTemplate(tmpl string, p reportPayload, date string, jsonSafe bool) string {
	total := p.UpBytes + p.DownBytes
	repl := map[string]string{
		"{{date}}":         date,
		"{{period_start}}": p.PeriodStart,
		"{{period_end}}":   p.PeriodEnd,
		"{{node}}":         p.Node,
		"{{note}}":         p.Note,
		"{{version}}":      p.Version,
		"{{requests}}":     fmt.Sprintf("%d", p.Requests),
		"{{requests_raw}}": strconv.FormatInt(p.Requests, 10),
		"{{up}}":           humanBytes(p.UpBytes),
		"{{down}}":         humanBytes(p.DownBytes),
		"{{total}}":        humanBytes(total),
		"{{up_raw}}":       strconv.FormatInt(p.UpBytes, 10),
		"{{down_raw}}":     strconv.FormatInt(p.DownBytes, 10),
		"{{blocked}}":      fmt.Sprintf("%d", p.Blocked),
		"{{blocked_cn}}":   fmt.Sprintf("%d", p.BlockedCN),
		"{{blocked_wl}}":   fmt.Sprintf("%d", p.BlockedWL),
		"{{blocked_ban}}":  fmt.Sprintf("%d", p.BlockedBan),
		"{{blocked_ua}}":   fmt.Sprintf("%d", p.BlockedUA),
		"{{ips_top}}":      topListText(p.IPs, 5, false),
		"{{ip_bytes_top}}": topListText(p.IPBytes, 5, true),
		"{{hosts_top}}":    topListText(p.Hosts, 5, false),
		"{{countries_top}}": topListText(p.Countries, 8, false),
		"{{ips_top_lines}}":       topListLines(p.IPs, 5, false),
		"{{ip_bytes_top_lines}}":  topListLines(p.IPBytes, 5, true),
		"{{hosts_top_lines}}":     topListLines(p.Hosts, 5, false),
		"{{countries_top_lines}}": topListLines(p.Countries, 8, false),
	}
	if jsonSafe {
		for k, v := range repl {
			repl[k] = jsonSafeValue(v)
		}
	}
	out := tmpl
	for k, v := range repl {
		out = strings.ReplaceAll(out, k, v)
	}
	return out
}

// looksLikeJSONTmpl 判断模板是否为 JSON 请求体（如 Telegram sendMessage 的 {"chat_id":...,"text":"..."}）
func looksLikeJSONTmpl(tmpl string) bool {
	return strings.HasPrefix(strings.TrimSpace(tmpl), "{")
}

// topListLines 取计数前 N 项，每项独占一行，格式 "键 · 值"，适合 Telegram/IM 多行展示
func topListLines(m map[string]int64, n int, asBytes bool) string {
	type kv struct {
		k string
		v int64
	}
	arr := make([]kv, 0, len(m))
	for k, v := range m {
		arr = append(arr, kv{k, v})
	}
	if len(arr) == 0 {
		return "（无）"
	}
	sort.Slice(arr, func(i, j int) bool {
		if arr[i].v != arr[j].v {
			return arr[i].v > arr[j].v
		}
		return arr[i].k < arr[j].k
	})
	if n <= 0 || n > len(arr) {
		n = len(arr)
	}
	parts := make([]string, 0, n)
	for i := 0; i < n; i++ {
		if asBytes {
			parts = append(parts, arr[i].k+" · "+humanBytes(arr[i].v))
		} else {
			parts = append(parts, fmt.Sprintf("%s · %d 次", arr[i].k, arr[i].v))
		}
	}
	return strings.Join(parts, "\n")
}

// jsonSafeValue 把值转义为可安全嵌入 JSON 字符串的形式（反斜杠/引号/换行）
func jsonSafeValue(v string) string {
	v = strings.ReplaceAll(v, "\\", "\\\\")
	v = strings.ReplaceAll(v, "\"", "\\\"")
	v = strings.ReplaceAll(v, "\n", "\\n")
	v = strings.ReplaceAll(v, "\r", "")
	return v
}

func mustJSON(v any) []byte {
	raw, _ := json.Marshal(v)
	return raw
}

// dailySendSpec 返回要发送的日报内容与触发标记：模板开启返回渲染文本，否则返回标准 JSON
func dailySendSpec(c *Config, p reportPayload, date string) (body []byte, trigger, id string) {
	raw, _ := json.Marshal(p)
	if !c.DailyTmplOn {
		return raw, "daily", p.BatchID
	}
	tmpl := c.DailyTmpl
	if strings.TrimSpace(tmpl) == "" {
		tmpl = defaultDailyTmpl
	}
	jsonMode := dailyContentType(c) == "application/json" && looksLikeJSONTmpl(tmpl)
	return []byte(renderDailyTemplate(tmpl, p, date, jsonMode)), "daily-text", p.BatchID
}

// dailyTarget 返回日报的发送地址与 Token（模板模式下可用独立地址）
func dailyTarget(c *Config) (string, string) {
	if c.DailyTmplOn && strings.TrimSpace(c.DailyTmplURL) != "" {
		return strings.TrimSpace(c.DailyTmplURL), strings.TrimSpace(c.DailyTmplToken)
	}
	return c.ReportURL, c.ReportToken
}

func dailyContentType(c *Config) string {
	if c.DailyTmplOn {
		if t := strings.TrimSpace(c.DailyTmplType); t != "" {
			return t
		}
		return "text/plain"
	}
	return "application/json"
}

// isGetUpdatesURL 判断是否误用了 Telegram 的 getUpdates 接口（只能拉取消息，发不出通知）
func isGetUpdatesURL(u string) bool {
	s := strings.ToLower(strings.TrimRight(strings.TrimSpace(u), "/"))
	return strings.HasSuffix(s, "/getupdates")
}

// notifyRejected 判断接收端是否「HTTP 200 但实际没送达」：
//   - HTTP 状态码 >= 400
//   - 响应体为 JSON 且 ok=false（取 description 作为原因）
//   - 响应体为 JSON 且 result 为空数组（如 Telegram /getUpdates 只拉取消息，POST 后返回 result:[]，消息并未发出）
func notifyRejected(status int, respBody string) (bool, string) {
	body := strings.TrimSpace(respBody)
	var m map[string]any
	parsed := json.Unmarshal([]byte(body), &m) == nil
	if parsed {
		if okv, has := m["ok"].(bool); has && !okv {
			desc, _ := m["description"].(string)
			if strings.TrimSpace(desc) == "" {
				desc = fmt.Sprintf("接收端返回 ok=false（HTTP %d）", status)
			}
			return true, desc
		}
		if arr, has := m["result"].([]any); has && len(arr) == 0 && status < 400 {
			return true, "接收端返回 result 为空数组：HTTP 200 但未执行发送动作（Telegram /getUpdates 只能拉取消息，发通知需用 /sendMessage）"
		}
	}
	if status >= 400 {
		return true, ""
	}
	return false, ""
}

// checkNotifyResult 把「假成功」转成 error；正常送达返回 nil
func checkNotifyResult(status int, respBody string) error {
	bad, why := notifyRejected(status, respBody)
	if !bad {
		return nil
	}
	if strings.TrimSpace(why) == "" {
		why = fmt.Sprintf("接收端返回 HTTP %d，请求被拒绝", status)
	}
	return fmt.Errorf("%s", why)
}

// reportChannelPlan 描述一条上报通道当前是否会执行、下一次执行时间与原因
type reportChannelPlan struct {
	Ready  bool   `json:"ready"`
	Reason string `json:"reason"`
	Next   string `json:"next"`
	Mode   string `json:"mode,omitempty"` // 通知通道：template / json / off
}

type reportPlan struct {
	API   reportChannelPlan `json:"api"`
	Daily reportChannelPlan `json:"daily"`
}

// buildReportPlan 计算两条通道的执行计划：
//   - 接口上报：需「自动上报开启」且「接收地址非空」，否则不执行
//   - 通知推送：需「按模板发送开启」且「发送地址非空」且「模板内容非空」，否则不执行
//
// 两条通道互不影响，任意一条未配置完整都只是它自己不执行。
func buildReportPlan(c *Config) reportPlan {
	if c == nil {
		c = &Config{}
	}
	now := nowBeijing()
	var pl reportPlan

	nextHour := now.Truncate(time.Hour).Add(5 * time.Second)
	if !nextHour.After(now) {
		nextHour = nextHour.Add(time.Hour)
	}
	pl.API.Next = beijingRFC3339(nextHour)
	switch {
	case strings.TrimSpace(c.ReportURL) == "":
		pl.API.Reason = "未填写接收地址，不会执行"
	case !c.ReportOn:
		pl.API.Reason = "每小时上报开关已关闭，不会执行"
	default:
		pl.API.Ready = true
		pl.API.Reason = "运行中：每小时整点发送上一小时增量"
	}

	nextDaily := time.Date(now.Year(), now.Month(), now.Day(), 0, 10, 0, 0, beijingLoc)
	if !nextDaily.After(now) {
		nextDaily = nextDaily.AddDate(0, 0, 1)
	}
	pl.Daily.Next = beijingRFC3339(nextDaily)
	tURL, _ := dailyTarget(c)
	if c.DailyTmplOn {
		pl.Daily.Mode = "template"
		switch {
		case strings.TrimSpace(tURL) == "":
			pl.Daily.Reason = "已开启模板推送但未填写发送地址，不会执行"
		case isGetUpdatesURL(tURL):
			pl.Daily.Reason = "发送地址以 /getUpdates 结尾，发不出通知，请改为 /sendMessage"
		case strings.TrimSpace(c.DailyTmpl) == "":
			pl.Daily.Reason = "已开启模板推送但模板内容为空，不会执行（填写模板后自动生效）"
		default:
			pl.Daily.Ready = true
			pl.Daily.Reason = "运行中：每天 00:10 推送模板消息"
		}
		return pl
	}
	// 未开启模板推送：日报作为接口上报通道的附带内容（JSON 日报）
	if pl.API.Ready {
		pl.Daily.Mode = "json"
		pl.Daily.Ready = true
		pl.Daily.Reason = "未开启模板推送，日报随接口上报通道发 JSON（依赖上方接收地址）"
	} else {
		pl.Daily.Mode = "off"
		pl.Daily.Reason = "未开启模板推送，且接口上报未运行，不会发送日报"
	}
	return pl
}

// sendDailyReportIfDue 检查并补发缺失的昨日日报（含服务中断期间的日期，最多回溯 7 天）
func sendDailyReportIfDue() int {
	c := cfgPtr.Load()
	if c == nil {
		return 0
	}
	// 通知与接口上报相互独立：
	//   - 自定义格式（通知通道）开启即可发日报，无需配置上报地址或开启自动上报
	//   - 未开启自定义格式时，日报仍作为接口上报的一部分，需 ReportOn 开启
	if !c.DailyTmplOn && !c.ReportOn {
		return 0
	}
	// 已开启模板推送但未填写模板内容 → 视为未配置，定时任务不执行（手动发送仍可用默认模板）
	if c.DailyTmplOn && strings.TrimSpace(c.DailyTmpl) == "" {
		return 0
	}
	tURL, _ := dailyTarget(c)
	if tURL == "" {
		return 0
	}
	if isGetUpdatesURL(tURL) {
		return 0 // 误用拉取接口，发送必然无效，跳过以免队列堆积
	}
	yd := nowBeijing().AddDate(0, 0, -1)
	end := beijingDate(yd)
	last := lastDailyReportSent()
	if last != "" && last >= end {
		return 0
	}
	var from time.Time
	if last == "" {
		from = yd.AddDate(0, 0, -6)
	} else if t, err := time.ParseInLocation("2006-01-02", last, beijingLoc); err == nil {
		from = t.AddDate(0, 0, 1)
	} else {
		from = yd
	}
	sent := 0
	for d := from; !d.After(yd); d = d.AddDate(0, 0, 1) {
		date := beijingDate(d)
		p, ok := buildDailyReportPayload(date)
		if !ok {
			continue // 该日无统计数据（无流量或服务未运行），跳过且不标记
		}
		body, trigger, id := dailySendSpec(c, p, date)
		q := queuedReport{ID: id, Payload: body, Created: p.ReportedAt, Trigger: trigger}
		if c.DailyTmplOn {
			q.URL, q.Token = dailyTarget(c)
			q.ContentType = dailyContentType(c)
		}
		reportQueueMu.Lock()
		list := loadReportQueue()
		list = append(list, q)
		if len(list) > maxReportQueue {
			list = list[len(list)-maxReportQueue:]
		}
		saveReportQueue(list)
		reportQueueMu.Unlock()
		markDailyReportSent(date)
		sent++
	}
	if sent > 0 {
		flushReportQueue()
	}
	return sent
}

// startDailyReportWorker 每天 00:10（北京时间）发送昨日统计；启动时先补发一次
func startDailyReportWorker() {
	go func() {
		sendDailyReportIfDue()
		for {
			now := nowBeijing()
			next := time.Date(now.Year(), now.Month(), now.Day(), 0, 10, 0, 0, beijingLoc)
			if !next.After(now) {
				next = next.AddDate(0, 0, 1)
			}
			time.Sleep(time.Until(next))
			sendDailyReportIfDue()
		}
	}()
}

func parseRFC3339(s string) time.Time {
	t, _ := time.Parse(time.RFC3339, s)
	return t
}

func detectNodeName() string {
	if ip, _ := selfPublicIP.Load().(string); ip != "" {
		return ip
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "unknown"
}

var nodeKeyCache atomic.Value

func getNodeKey() string {
	if v, _ := nodeKeyCache.Load().(string); v != "" {
		return v
	}
	var key string
	_ = db.View(func(tx *bolt.Tx) error {
		if b := tx.Bucket([]byte("auth")); b != nil {
			if k := b.Get([]byte("node_key")); k != nil {
				key = string(k)
			}
		}
		return nil
	})
	if key == "" {
		key = randToken(24)
		_ = db.Update(func(tx *bolt.Tx) error {
			b, err := tx.CreateBucketIfNotExists([]byte("auth"))
			if err != nil {
				return err
			}
			return b.Put([]byte("node_key"), []byte(key))
		})
	}
	nodeKeyCache.Store(key)
	return key
}

type reportRecord struct {
	ID           string `json:"id"`
	Time         string `json:"time"`
	BatchID      string `json:"batch_id"`
	Trigger      string `json:"trigger"`
	OK           bool   `json:"ok"`
	StatusCode   int    `json:"status_code"`
	Error        string `json:"error,omitempty"`
	RespBody     string `json:"resp_body,omitempty"`
	Attempts     int    `json:"attempts"`
	PeriodDate   string `json:"period_date"`
	PeriodHour   string `json:"period_hour"`
	Requests     int64  `json:"requests"`
	UpBytes      int64  `json:"up_bytes"`
	DownBytes    int64  `json:"down_bytes"`
	Blocked      int64  `json:"blocked"`
	URL          string `json:"url"`
	Note         string `json:"note"`
	IP           string `json:"ip"`
	DurationMS   int64  `json:"duration_ms"`
	Size         int    `json:"size"`
	PayloadSaved bool   `json:"payload_saved"`
}

const (
	reportRecordKeepDays = 30
	maxReportRecords     = 3000
	reportRecordBucket   = "report_records"
	reportPayloadBucket  = "report_payloads"
	maxReportPayloadLen  = 512 << 10
)

var (
	reportRecords   []reportRecord
	reportRecordsMu sync.Mutex
)

func loadReportRecords() {
	reportRecordsMu.Lock()
	defer reportRecordsMu.Unlock()
	reportRecords = nil
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(reportRecordBucket))
		if b == nil {
			return nil
		}
		if raw := b.Get([]byte("data")); raw != nil {
			_ = json.Unmarshal(raw, &reportRecords)
		}
		return nil
	})
	if pruneReportRecordsLocked() {
		persistReportRecordsLocked()
	}
	gcReportPayloadsLocked()
}

func pruneReportRecordsLocked() bool {
	cutoff := nowBeijing().AddDate(0, 0, -reportRecordKeepDays).Format(time.RFC3339)
	out := reportRecords[:0]
	var dead []string
	for _, r := range reportRecords {
		if r.Time >= cutoff {
			out = append(out, r)
		} else if r.ID != "" {
			dead = append(dead, r.ID)
		}
	}
	if len(out) > maxReportRecords {
		cut := len(out) - maxReportRecords
		for _, r := range out[:cut] {
			if r.ID != "" {
				dead = append(dead, r.ID)
			}
		}
		out = out[cut:]
	}
	reportRecords = out
	if len(dead) > 0 {
		deleteReportPayloads(dead)
		return true
	}
	return false
}

func saveReportPayload(id string, payload []byte) {
	if id == "" || len(payload) == 0 {
		return
	}
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte(reportPayloadBucket))
		if err != nil {
			return err
		}
		return b.Put([]byte(id), payload)
	})
}

func loadReportPayload(id string) (string, bool) {
	if id == "" {
		return "", false
	}
	var out []byte
	_ = db.View(func(tx *bolt.Tx) error {
		if b := tx.Bucket([]byte(reportPayloadBucket)); b != nil {
			if v := b.Get([]byte(id)); v != nil {
				out = append([]byte(nil), v...)
			}
		}
		return nil
	})
	return string(out), out != nil
}

func deleteReportPayloads(ids []string) {
	if len(ids) == 0 {
		return
	}
	_ = db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(reportPayloadBucket))
		if b == nil {
			return nil
		}
		for _, id := range ids {
			_ = b.Delete([]byte(id))
		}
		return nil
	})
}

func clearReportPayloads() {
	_ = db.Update(func(tx *bolt.Tx) error {
		if tx.Bucket([]byte(reportPayloadBucket)) != nil {
			return tx.DeleteBucket([]byte(reportPayloadBucket))
		}
		return nil
	})
}

func gcReportPayloadsLocked() {
	keep := make(map[string]struct{}, len(reportRecords))
	for _, r := range reportRecords {
		if r.ID != "" {
			keep[r.ID] = struct{}{}
		}
	}
	var orphan []string
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(reportPayloadBucket))
		if b == nil {
			return nil
		}
		return b.ForEach(func(k, _ []byte) error {
			if _, ok := keep[string(k)]; !ok {
				orphan = append(orphan, string(k))
			}
			return nil
		})
	})
	deleteReportPayloads(orphan)
}

func persistReportRecordsLocked() {
	snap := make([]reportRecord, len(reportRecords))
	copy(snap, reportRecords)
	raw, _ := json.Marshal(snap)
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte(reportRecordBucket))
		if err != nil {
			return err
		}
		return b.Put([]byte("data"), raw)
	})
}

func appendReportRecord(rec reportRecord, payload []byte) {
	if rec.Time == "" {
		rec.Time = beijingRFC3339(nowBeijing())
	}
	if rec.ID == "" {
		rec.ID = fmt.Sprintf("%d-%s", time.Now().UnixNano(), randToken(4))
	}
	if len(rec.RespBody) > 512 {
		rec.RespBody = rec.RespBody[:512]
	}
	if len(payload) > maxReportPayloadLen {
		payload = payload[:maxReportPayloadLen]
	}
	rec.PayloadSaved = len(payload) > 0
	reportRecordsMu.Lock()
	defer reportRecordsMu.Unlock()
	if rec.PayloadSaved {
		saveReportPayload(rec.ID, payload)
	}
	reportRecords = append(reportRecords, rec)
	pruneReportRecordsLocked()
	persistReportRecordsLocked()
}

func startReportRecordCleaner() {
	go func() {
		for {
			time.Sleep(time.Hour)
			reportRecordsMu.Lock()
			if pruneReportRecordsLocked() {
				persistReportRecordsLocked()
			}
			reportRecordsMu.Unlock()
		}
	}()
}

const maxReportQueue = 24

// maxQueueAttempts 单条队列项最大重试次数，超过则放弃（防止坏地址无限堆积）
const maxQueueAttempts = 50

type queuedReport struct {
	ID          string `json:"id"`
	Payload     []byte `json:"payload"`
	Created     string `json:"created"`
	Attempts    int    `json:"attempts"`
	LastErr     string `json:"last_err,omitempty"`
	Trigger     string `json:"trigger,omitempty"`
	URL         string `json:"url,omitempty"`         // 留空使用全局 report_url
	Token       string `json:"token,omitempty"`       // 留空使用全局 report_token
	ContentType string `json:"content_type,omitempty"` // 留空为 application/json
}

func loadReportQueue() []queuedReport {
	var list []queuedReport
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("report_queue"))
		if b == nil {
			return nil
		}
		if raw := b.Get([]byte("data")); raw != nil {
			_ = json.Unmarshal(raw, &list)
		}
		return nil
	})
	return list
}

func saveReportQueue(list []queuedReport) {
	raw, _ := json.Marshal(list)
	_ = db.Update(func(tx *bolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("report_queue"))
		if err != nil {
			return err
		}
		return b.Put([]byte("data"), raw)
	})
}

func sendOnceResp(url, token string, body []byte) (int, string, error) {
	return sendOnceRespCT(url, token, body, "application/json")
}

func sendOnceRespCT(url, token string, body []byte, contentType string) (int, string, error) {
	if contentType == "" {
		contentType = "application/json"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("User-Agent", "emby-proxy/"+appVersionStr)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := reportClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return resp.StatusCode, string(respBody), fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return resp.StatusCode, string(respBody), nil
}

var reportClient = &http.Client{Timeout: 25 * time.Second}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func flushReportQueue() {
	c := cfgPtr.Load()
	if c == nil {
		return
	}
	reportQueueMu.Lock()
	defer reportQueueMu.Unlock()
	list := loadReportQueue()
	if len(list) == 0 {
		return
	}
	if c.ReportURL == "" {
		// 全局接收地址为空时，仅补传自带目标地址的队列项（如日报独立发送地址）；
		// 依赖全局地址的旧队列项永远无法补传，直接清理掉（写入一条说明性记录，便于用户理解队列为何减少）
		hasOwn := false
		for _, it := range list {
			if it.URL != "" {
				hasOwn = true
				break
			}
		}
		if !hasOwn {
			if len(list) > 0 {
				rec := reportRecord{
					Time:     beijingRFC3339(nowBeijing()),
					BatchID:  "queue-cleanup",
					Trigger:  "cleanup",
					OK:       true,
					RespBody: fmt.Sprintf("接口上报未配置接收地址，清理了 %d 条无法补传的历史队列项", len(list)),
				}
				appendReportRecord(rec, nil)
			}
			saveReportQueue(nil)
			return
		}
		// 混合情况：丢弃无地址项，保留自带地址项继续补传
		kept := make([]queuedReport, 0, len(list))
		for _, it := range list {
			if it.URL == "" {
				rec := reportRecord{
					Time:     beijingRFC3339(nowBeijing()),
					BatchID:  it.ID,
					Trigger:  "cleanup",
					OK:       true,
					RespBody: "接口上报未配置接收地址，该队列项已清理",
				}
				appendReportRecord(rec, it.Payload)
				continue
			}
			kept = append(kept, it)
		}
		list = kept
		if len(list) == 0 {
			saveReportQueue(list)
			return
		}
	}
	keep := list[:0]
	stopped := false
	for _, it := range list {
		if stopped {
			keep = append(keep, it)
			continue
		}
		if it.Attempts >= maxQueueAttempts {
			rec := reportRecord{
				Time:     beijingRFC3339(nowBeijing()),
				BatchID:  it.ID,
				Trigger:  "cleanup",
				OK:       false,
				Error:    fmt.Sprintf("重试 %d 次仍失败，已放弃：%s", it.Attempts, it.LastErr),
				Attempts: it.Attempts,
			}
			appendReportRecord(rec, it.Payload)
			continue
		}
		start := time.Now()
		trigger := it.Trigger
		if trigger == "" {
			trigger = "retry"
		}
		targetURL := c.ReportURL
		targetToken := c.ReportToken
		if it.URL != "" {
			targetURL = it.URL
			targetToken = it.Token
		}
		sendCT := it.ContentType
		if sendCT == "" {
			sendCT = "application/json"
		}
		status, respBody, err := sendOnceRespCT(targetURL, targetToken, it.Payload, sendCT)
		// 通知类队列项（自带地址或模板触发）同样识别「假成功」
		if err == nil && (it.URL != "" || strings.Contains(trigger, "text")) {
			err = checkNotifyResult(status, respBody)
		}
		rec := recordFromPayload(it.Payload, it.ID, trigger, status, respBody, err, it.Attempts+1, start, "", targetURL)
		rec.Note = c.ReportNote
		appendReportRecord(rec, it.Payload)
		if err != nil {
			it.Attempts++
			it.LastErr = err.Error()
			keep = append(keep, it)
			stopped = true
			continue
		}
	}
	saveReportQueue(keep)
}

func recordFromPayload(payload []byte, batchID, trigger string, status int, respBody string, err error, attempts int, start time.Time, ip, targetURL string) reportRecord {
	var p reportPayload
	_ = json.Unmarshal(payload, &p)
	if batchID == "" {
		batchID = p.BatchID
	}
	rec := reportRecord{
		Time:       beijingRFC3339(nowBeijing()),
		BatchID:    batchID,
		Trigger:    trigger,
		OK:         err == nil,
		StatusCode: status,
		Error:      errString(err),
		RespBody:   respBody,
		Attempts:   attempts,
		PeriodDate: p.PeriodDate,
		PeriodHour: p.PeriodHour,
		Requests:   p.Requests,
		UpBytes:    p.UpBytes,
		DownBytes:  p.DownBytes,
		Blocked:    p.Blocked,
		URL:        targetURL,
		Note:       p.Note,
		IP:         ip,
		DurationMS: time.Since(start).Milliseconds(),
		Size:       len(payload),
	}
	return rec
}

func enqueueAndSend() {
	c := cfgPtr.Load()
	if c == nil || c.ReportURL == "" || !c.ReportOn {
		return
	}
	p, ok := lastFullHourReport()
	if !ok {
		return
	}
	raw, _ := json.Marshal(p)

	reportQueueMu.Lock()
	list := loadReportQueue()
	list = append(list, queuedReport{ID: p.BatchID, Payload: raw, Created: p.ReportedAt, Trigger: "auto"})
	if len(list) > maxReportQueue {
		list = list[len(list)-maxReportQueue:]
	}
	saveReportQueue(list)
	reportQueueMu.Unlock()

	flushReportQueue()
}

func startReportWorker() {
	go func() {
		for {
			now := nowBeijing()
			next := now.Truncate(time.Hour).Add(5 * time.Second)
			if !next.After(now) {
				next = next.Add(time.Hour)
			}
			time.Sleep(time.Until(next))
			enqueueAndSend()
		}
	}()
	go func() {
		for {
			time.Sleep(10 * time.Minute)
			flushReportQueue()
		}
	}()
}

func serveSpeedTest(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/speed/")
	if rest == "" {
		serveError(w, r, http.StatusNotFound, "测速链接不存在",
			"测速链接为空或格式不正确，无法找到对应的测速任务。",
			errPageCtx{Tips: []string{"请联系服务提供者重新生成链接，并完整复制地址（不要漏掉末尾的令牌）。"}})
		return
	}
	if strings.HasSuffix(rest, "/dl") {
		tok := strings.TrimSuffix(rest, "/dl")
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
				return
			}
			remain -= n
		}
		return
	}

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
		body := http.MaxBytesReader(w, r.Body, 512<<20)
		buf := make([]byte, 64<<10)
		var n int64
		for {
			m, err := body.Read(buf)
			if m > 0 {
				n += int64(m)
				traffic.up.Add(int64(m))
			}
			if err != nil {
				break
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"received": n})
		return
	}

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

	tok := rest
	if strings.Contains(tok, "/") {
		serveError(w, r, http.StatusNotFound, "测速链接不存在",
			"测速链接为空或格式不正确，无法找到对应的测速任务。",
			errPageCtx{Tips: []string{"请联系服务提供者重新生成链接，并完整复制地址（不要漏掉末尾的令牌）。"}})
		return
	}
	v, ok := speedTokens.Load(tok)
	if !ok {
		serveError(w, r, http.StatusNotFound, "测速链接不存在",
			"该链接对应的测速任务不存在或已被删除，服务中没有可匹配的令牌。",
			errPageCtx{Tips: []string{"确认链接完整无误；如已删除，请联系管理员重新生成。"}})
		return
	}
	st := v.(*speedToken)
	if speedTokenExpired(st) {
		serveError(w, r, http.StatusGone, "测速链接已过期",
			"该测速链接已超过 7 天有效期，出于安全考虑不再接受请求。",
			errPageCtx{Tips: []string{"测速链接自生成起有效期为 7 天，请联系管理员重新生成后再测。"}})
		return
	}
	if st.Uses.Load() >= int64(st.MaxUses) {
		serveError(w, r, http.StatusGone, "测速链接已用尽",
			"该测速链接的可用次数已用完，无法继续发起测速。",
			errPageCtx{Tips: []string{"每个测速链接有次数上限，请联系管理员重新生成。"}})
		return
	}
	st.Uses.Add(1)
	go saveSpeedTokens()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(strings.ReplaceAll(speedtestHTML, "__TOKEN__", tok)))
}

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
const CIRC=653.4, MAX_DISPLAY=1000;
const $=id=>document.getElementById(id);
let running=false;
function setGauge(mbps){
  const pct=Math.min(1,mbps/MAX_DISPLAY);
  $('gbar').style.strokeDashoffset=CIRC*(1-pct*0.75);
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
  await pump(1);
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
  await worker();
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
	ReadBufferSize:    1024,
	WriteBufferSize:   4096,
	EnableCompression: false,
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true
		}
		u, err := url.Parse(origin)
		if err != nil {
			return false
		}
		return u.Host == r.Host
	},
}

var statDropped atomic.Int64

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
				if ev.UAClass != "" {
					d.UAClass[ev.UAClass]++
				}
				if ev.UARaw != "" {
					d.UARaw[ev.UARaw]++
					if len(d.UARaw) > uaRawCap {
						minK, minV := "", int64(1<<62)
						for k, v := range d.UARaw {
							if v < minV {
								minK, minV = k, v
							}
						}
						delete(d.UARaw, minK)
					}
				}
			} else if ev.Bytes > 0 || ev.UpBytes > 0 || ev.DownBytes > 0 {
				up, down := ev.UpBytes, ev.DownBytes
				if up == 0 && down == 0 {
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

func recordRequestStart(ip, country, host, ua string) {
	select {
	case statChan <- statEvent{IP: ip, Country: country, Host: host, UAClass: uaClassOfEx(ua), UARaw: uaRawKey(ua), IsStart: true}:
	default:
		statDropped.Add(1)
	}
}

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

// loadStats 启动时从 BoltDB 恢复统计、拦截记录和操作记录到内存。
// 兼容旧版单桶存储，必要时做一次迁移。
func loadStats() {
	stats = emptyStats()
	if db == nil {
		return
	}
	migrated := false
	_ = db.View(func(tx *bolt.Tx) error {
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
					stats.BlockedUA = m.BlockedUA
					stats.LastProxyAt = m.LastProxyAt
				}
			}
		}
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
		if b := tx.Bucket([]byte("stats_blocks")); b != nil {
			if data := b.Get([]byte("data")); data != nil {
				var bl []BlockEvent
				if json.Unmarshal(data, &bl) == nil {
					stats.Blocks = bl
				}
			}
		}
		if b := tx.Bucket([]byte("stats_audit")); b != nil {
			if data := b.Get([]byte("data")); data != nil {
				var au []AuditEvent
				if json.Unmarshal(data, &au) == nil {
					stats.Audit = au
				}
			}
		}
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
	if migrated || (len(stats.IPCounts) == 0 && len(stats.Daily) > 0) {
		rebuildAggregatesFromDaily()
	}
	if stats.TodayDate == "" {
		stats.TodayDate = beijingDate(time.Now())
	}
	if d := stats.Daily[stats.TodayDate]; d != nil {
		if stats.TodayRequests == 0 && d.Requests > 0 {
			stats.TodayRequests = d.Requests
		}
		if stats.TodayBytes == 0 && d.Bytes > 0 {
			stats.TodayBytes = d.Bytes
		}
	}
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

type statsSnapshot struct {
	meta       []byte
	blocks     []byte
	audit      []byte
	dailyItems []struct {
		key  string
		data []byte
	}
	dailyKeys map[string]struct{}
}

// marshalStatsLocked 在已持有 statsMu 的前提下，把内存统计序列化为可落盘快照。
// 包含元数据、拦截记录、操作记录、按日统计。调用方负责加锁。
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
		BlockedUA:        stats.BlockedUA,
		LastProxyAt:      stats.LastProxyAt,
	}
	metaBytes, _ := json.Marshal(meta)
	blockBytes, _ := json.Marshal(stats.Blocks)
	auditBytes, _ := json.Marshal(stats.Audit)
	snap := &statsSnapshot{meta: metaBytes, blocks: blockBytes, audit: auditBytes, dailyKeys: map[string]struct{}{}}
	for date, d := range stats.Daily {
		if d == nil {
			continue
		}
		b, err := json.Marshal(d)
		if err != nil {
			continue
		}
		snap.dailyItems = append(snap.dailyItems, struct {
			key  string
			data []byte
		}{key: date, data: b})
		snap.dailyKeys[date] = struct{}{}
	}
	return snap
}

// persistStats 将统计快照写入 BoltDB（stats_meta / stats_daily / stats_blocks / stats_audit）。
// 由定时任务和进程退出时调用，保证重启后数据可恢复。
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
		if err := bb.Put([]byte("data"), snap.blocks); err != nil {
			return err
		}
		ab, err := tx.CreateBucketIfNotExists([]byte("stats_audit"))
		if err != nil {
			return err
		}
		return ab.Put([]byte("data"), snap.audit)
	})
}

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

func getClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(host)
	if peer == nil || !isTrustedProxy(peer) {
		return host
	}

	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			s := strings.TrimSpace(parts[i])
			if s == "" {
				continue
			}
			p := net.ParseIP(s)
			if p == nil {
				break
			}
			if !isTrustedProxy(p) {
				return s
			}
		}
	}

	if xri := strings.TrimSpace(r.Header.Get("X-Real-IP")); xri != "" {
		if p := net.ParseIP(xri); p != nil && !isTrustedProxy(p) {
			return xri
		}
	}
	return host
}

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

var (
	countryCodeOnce sync.Once
	countryCodeRev  map[string]string
)

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

// 拦截频率限制：同一 IP 短时间内被拦太多次就直接返回极简 429
// 不再记详细记录、不再渲染完整 HTML 错误页，降低持续重试带来的开销
var blockRateMu sync.Mutex
var blockRates = make(map[string]*blockRateEntry)

type blockRateEntry struct {
	count int
	start time.Time
}

const (
	blockRateWindow = 10 * time.Second
	blockRateMax    = 12 // 10 秒内超过 12 次拦截就限速
)

// blockedRateLimited 判断该 IP 在短时间窗口内被拦截次数是否超限。
// 超限返回 true，调用方应直接 drop，不再记详细记录、不再渲染完整错误页。
func blockedRateLimited(ip string) bool {
	if ip == "" {
		return false
	}
	blockRateMu.Lock()
	defer blockRateMu.Unlock()
	now := time.Now()
	e, ok := blockRates[ip]
	if !ok || now.Sub(e.start) > blockRateWindow {
		blockRates[ip] = &blockRateEntry{count: 1, start: now}
		// 简单清理，避免 map 无限增长
		if len(blockRates) > 3000 {
			for k, v := range blockRates {
				if now.Sub(v.start) > blockRateWindow*3 {
					delete(blockRates, k)
				}
			}
		}
		return false
	}
	e.count++
	return e.count > blockRateMax
}

// dropOrMinimal429 限速后优先直接断开连接（不写响应体），失败时回退极简 429
// dropOrMinimal429 在拦截频率超限时调用。
// 优先 Hijack 后直接关闭连接（不写响应），失败时回退极简 429。
func dropOrMinimal429(w http.ResponseWriter) {
	if h, ok := w.(http.Hijacker); ok {
		if conn, _, err := h.Hijack(); err == nil {
			_ = conn.Close()
			return
		}
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Retry-After", "10")
	w.Header().Set("Connection", "close")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusTooManyRequests)
	_, _ = w.Write([]byte("429 too many requests\n"))
}

func truncStr(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

// recordBlocked 记录一次拦截事件到内存统计，并计入对应原因计数。
// 本机/本地 IP 不记录；Path/UA/Host 会被截断以控制体积。
// 数据随 stats 定时落盘，重启不丢失。
func recordBlocked(ip, country, path, reason, ua, host string) {
	if isSelfOrLocalIP(ip, country) {
		return
	}
	statsMu.Lock()
	defer statsMu.Unlock()
	day := dayOf(beijingDate(time.Now()))
	switch reason {
	case "cn":
		stats.BlockedCN++
		day.BlockedCN++
	case "ban":
		stats.BlockedBan++
		day.BlockedBan++
	case "ua":
		stats.BlockedUA++
		day.BlockedUA++
	case "login_fail":
	default:
		stats.BlockedWhitelist++
		day.BlockedWL++
	}
	reasonText := blockReasonText(reason)
	if country == "" {
		country = "??"
	}
	ev := BlockEvent{Time: beijingRFC3339(time.Now()), IP: ip, Country: country, Host: truncStr(host, 120), Path: truncStr(path, 160), Reason: reason, ReasonText: reasonText, UA: truncStr(ua, 160)}
	stats.Blocks = append(stats.Blocks, ev)
	if len(stats.Blocks) > maxBlockEvents {
		stats.Blocks = stats.Blocks[len(stats.Blocks)-maxBlockEvents:]
	}
}

func blockReasonText(reason string) string {
	switch reason {
	case "cn":
		return "仅允许中国大陆 IP 访问"
	case "ban":
		return "IP 在黑名单中"
	case "ua":
		return "User-Agent 不在允许列表"
	case "host_ip":
		return "IP / localhost 直连被拒绝（未使用授权域名）"
	case "host_deny":
		return "访问域名不在允许列表中"
	case "host":
		return "访问域名未授权（旧记录，禁止 IP 直接访问）"
	case "login_fail":
		return "管理后台登录失败（用户名/密码或验证码错误）"
	default:
		return "目标域名未在白名单中"
	}
}

// reasonMatches 让下拉选总类 "host" 时能同时命中细分原因 host_ip / host_deny，
// 并兼容旧数据里的 host；其它原因仍是精确匹配。
func reasonMatches(evReason, want string) bool {
	return evReason == want || strings.HasPrefix(evReason, want+"_")
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
	geoMap   = map[string]geoEntry{}
	geoGroup singleflight.Group
)

func geoPrune() {
	const geoMaxEntries = 50000
	now := time.Now().Unix()
	geoMu.Lock()
	for k, e := range geoMap {
		if now-e.At >= 30*86400 {
			delete(geoMap, k)
		}
	}
	if len(geoMap) > geoMaxEntries {
		geoMap = map[string]geoEntry{}
	}
	geoMu.Unlock()
}

func geoParseGeneric(m map[string]any) (geoEntry, error) {
	if data, ok := m["data"].(map[string]any); ok {
		m = data
	}
	if ret, ok := m["ret"]; ok {
		if n, ok2 := toFloat(ret); ok2 && int(n) != 200 {
			msg, _ := m["msg"].(string)
			if msg == "" {
				msg, _ = m["message"].(string)
			}
			return geoEntry{}, fmt.Errorf("ip9 failed: %d %s", int(n), msg)
		}
	}
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

	raw := str("country")
	code := strings.ToUpper(str("countryCode", "country_code"))
	if len(code) > 2 {
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
		code = countryCodeByName(raw)
		if code == "" {
			code = "??"
		}
	}
	if zh := countryName(code); code != "??" && zh != code && (raw == "" || isASCIIName(raw)) {
		raw = zh
	}
	if raw == "" {
		raw = countryName(code)
	}
	return geoEntry{Code: code, Name: raw, Region: region, City: city, ISP: isp, Org: org, AS: asn, At: time.Now().Unix()}, nil
}

func isASCIIName(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

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

func geoEndpoints(ipEscaped string) []string {
	return []string{
		"https://ip9.com.cn/get?ip=" + ipEscaped,
		"http://ip-api.com/json/" + ipEscaped + "?fields=status,message,country,regionName,city,isp,as,org",
	}
}

func geoFetch(ipStr string) (geoEntry, error) {
	return geoFetchVia(geoEndpoints(url.QueryEscape(ipStr)), ipStr)
}

var geoClient = &http.Client{Timeout: 6 * time.Second}

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

func ipLabelSync(ipStr string) (string, string) {
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
	PassHash string
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
	if e.Expires.Sub(now) < sessionTTL/2 {
		sessions.Store(tok, sessionEntry{Expires: now.Add(sessionTTL)})
	}
	return true
}

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
	for i := 0; i < 8; i++ {
		x1 := int(rb[i%16]) % 160
		y1 := int(rb[(i+1)%16]) % 52
		x2 := int(rb[(i+2)%16]) % 160
		y2 := int(rb[(i+3)%16]) % 52
		lines.WriteString(fmt.Sprintf(`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#94a3b8" stroke-width="1"/>`, x1, y1, x2, y2))
	}
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

func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
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
		_ = bk.Delete([]byte("admin_pass"))
		return bk.Put([]byte("admin_pass_hash"), []byte(hash))
	})
}

// recordAudit 追加一条后台操作记录（登录、改密、保存配置、拉黑等）。
// 仅保留最近 maxAuditEvents 条；随 stats 持久化到 stats_audit 桶。
func recordAudit(ip, action, detail string) {
	statsMu.Lock()
	defer statsMu.Unlock()
	ev := AuditEvent{Time: beijingRFC3339(time.Now()), IP: ip, Action: action, Detail: detail}
	stats.Audit = append(stats.Audit, ev)
	if len(stats.Audit) > maxAuditEvents {
		stats.Audit = stats.Audit[len(stats.Audit)-maxAuditEvents:]
	}
}

type loginFailEntry struct {
	Count    atomic.Int64
	Window   atomic.Int64
	Locked   atomic.Int64
	Lockouts atomic.Int64
}

var loginFailers sync.Map

const (
	loginFailLimit   = 5
	loginFailWindow  = 10 * time.Minute
	loginLockBase    = 15 * time.Minute
	loginLockMax     = 2 * time.Hour
	captchaRateLimit = 30
)

func loginLockDuration(lockouts int64) time.Duration {
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

	ua := ""
	recordBlocked(ip, countryOf(ip), "/admin/api/login", "login_fail", ua, "")
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

// buildProxy 构造反向代理。请求经判定链放行后，由它转发到路径中指定的上游。
// 支持 http/https、查询参数、WebSocket；会统计上下行流量。
func buildProxy(tr *switchTransport) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
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
		},
		ModifyResponse: func(resp *http.Response) error {

			if resp.Body != nil {
				rb := reqBytesFrom(resp.Request.Context())
				resp.Body = struct {
					io.Reader
					io.Closer
				}{&countingReader{r: resp.Body, rb: rb}, resp.Body}
			}
			// 下行流量已在 countingWriter 中统计，不再包装 resp.Body，避免双计
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
			tech, target := "", ""
			if t, ok := r.Context().Value(targetCtxKey{}).(*url.URL); ok && t != nil {
				target = t.Scheme + "://" + t.Host
			}
			if err != nil {
				tech = err.Error()
			}
			tips := []string{}
			if target != "" {
				tips = append(tips, "本次请求的目标上游："+target+"（请确认该地址可从服务器访问）")
			}
			serveError(w, r, http.StatusBadGateway, "上游连接失败",
				"网关已通过全部访问规则，但在连接目标上游时失败，未取得任何响应内容。这通常与上游服务状态、端口、协议或网络有关，与访问白名单无关。",
				errPageCtx{Code: "upstream", Label: "上游服务连接失败", Tips: tips, Tech: tech})
		},
	}
}

type adminConfigResp struct {
	Config
	EffectivePort int    `json:"effective_port"`
	CurrentHost   string `json:"current_host"` // 当前浏览器访问后台使用的 Host，便于管理员配全白名单
}

const iconVer = "?v=4"

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

func pwaBodyExtra() string {
	return "<script>if('serviceWorker' in navigator){window.addEventListener('load',function(){navigator.serviceWorker.register('/admin/sw.js').catch(function(){})})}</script>"
}

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

const splashHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<link rel="icon" href="/favicon.ico?v=4">
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
(function () {
  var t0 = Date.now();
  var tip = document.getElementById('tip');
  var wait = Math.max(0, 400 - (Date.now() - t0));
  setTimeout(function () {
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

const swSource = `self.addEventListener('install', function (e) {
  e.waitUntil(self.skipWaiting());
});
self.addEventListener('activate', function (e) {
  e.waitUntil((self.caches ? caches.keys().then(function (ks) {
    return Promise.all(ks.map(function (k) { return caches.delete(k); }));
  }) : Promise.resolve()).then(function () { return self.clients.claim(); }));
});
`

var gzipWriterPool = sync.Pool{New: func() any { return gzip.NewWriter(nil) }}

func gzipCompressible(ct string) bool {
	ct = strings.ToLower(ct)
	for _, p := range []string{"text/", "application/json", "application/javascript", "application/manifest", "image/svg"} {
		if strings.HasPrefix(ct, p) {
			return true
		}
	}
	return false
}

type gzipResponseWriter struct {
	http.ResponseWriter
	gz      *gzip.Writer
	decided bool
	gzOn    bool
}

func (g *gzipResponseWriter) WriteHeader(code int) {
	if !g.decided {
		g.decided = true
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

func (g *gzipResponseWriter) Flush() {
	if g.gzOn {
		_ = g.gz.Flush()
	}
	if f, ok := g.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (g *gzipResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := g.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("response writer 不支持 Hijack")
	}
	g.decided = true
	g.gzOn = false
	return h.Hijack()
}

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
			_ = gz.Close()
			gz.Reset(io.Discard)
		}
		gzipWriterPool.Put(gz)
	}
}

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

const appVersionStr = "2.2.0"

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

// adminHandler 注册管理后台全部路由（登录、配置、统计、拦截记录、操作记录、上报等）。
// 除登录相关接口外，均需通过 requireAuth 校验会话。
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
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *currentCfg(), EffectivePort: currentPort(), CurrentHost: r.Host})
	})
	mux.HandleFunc("/admin/api/save", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "请求方法不支持，请刷新页面后重试", http.StatusMethodNotAllowed)
			return
		}
		var req Config
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "提交的配置格式有误，请检查各项输入后重新保存", http.StatusBadRequest)
			return
		}
		oldCfg := currentCfg()
		newCfg := &req
		if err := validateAdminAllow(newCfg.AdminAllow, getClientIP(r)); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := saveConfig(newCfg); err != nil {
			http.Error(w, "配置保存失败，可能是磁盘写入异常，请稍后重试", http.StatusInternalServerError)
			return
		}
		cfgPtr.Store(newCfg)
		rebuildACL(newCfg)
		recordAudit(getClientIP(r), "save_config", "保存网关设置")
		if newCfg.Port > 0 && newCfg.Port != currentPort() && globalSrv != nil {
			if err := startListen(globalSrv, newCfg.Port); err != nil {
				cfgPtr.Store(oldCfg)
				_ = saveConfig(oldCfg)
				http.Error(w, "新端口 "+strconv.Itoa(newCfg.Port)+" 监听失败，可能被其他程序占用或无权限；已自动恢复为原端口 "+strconv.Itoa(oldCfg.Port), http.StatusBadRequest)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(adminConfigResp{Config: *newCfg, EffectivePort: currentPort(), CurrentHost: r.Host})
	})
	mux.HandleFunc("/admin/api/system", func(w http.ResponseWriter, r *http.Request) {
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)

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

		var dbSize int64
		if fi, err := os.Stat(dbPath); err == nil {
			dbSize = fi.Size()
		}
		var diskFree, diskTotal uint64
		if du, err := diskUsage(filepath.Dir(dbPath)); err == nil {
			diskFree, diskTotal = du.free, du.total
		}

		sv := currentStatsView()
		uniqueIPs := len(sv.ipCounts)
		totalReqs := sv.totalRequests
		totalBytes := sv.totalBytes

		allowRate := 0.0
		if totalReqs > 0 {
			allowRate = 100 * float64(totalReqs-blockedTotal(sv)) / float64(totalReqs)
			if allowRate < 0 {
				allowRate = 0
			}
		}

		c := currentCfg()
		resp := map[string]any{
			"version":        appVersionStr,
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
			"host_guard_on":  c.HostGuardOn,
			"allowed_hosts":  len(c.AllowedHosts),
			"ban_list":       len(c.BanList),
			"china_only":     c.ChinaOnly,
			"allowed_uas":    len(c.AllowedUAs),
			"logins":         activeSessionCount(),
			"stat_dropped":   statDropped.Load(),
			"live_clients":   liveClients.Load(),
			"admin_allow":    len(c.AdminAllow),
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})
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
					lastSeq = delta[0].Seq
				}
				ipRates := snapshotIPRates()
				type ipSpeed struct {
					IP string `json:"ip"`
					Rx int64  `json:"rx_bps"`
					Tx int64  `json:"tx_bps"`
				}
				var speeds []ipSpeed
				for ip, b := range ipRates {
					speeds = append(speeds, ipSpeed{IP: ip, Rx: b[1], Tx: b[0]})
				}
				sort.Slice(speeds, func(i, j int) bool {
					return speeds[i].Rx+speeds[i].Tx > speeds[j].Rx+speeds[j].Tx
				})
				if len(speeds) > 20 {
					speeds = speeds[:20]
				}
				msg := map[string]any{
					"concurrent": conc,
					"rps":        rps,
					"rx_bps":     ns.RxBps,
					"tx_bps":     ns.TxBps,
					"events":     delta,
					"ip_speeds":  speeds,
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
		slim := r.URL.Query().Get("slim") == "1"
		w.Header().Set("Content-Type", "application/json")

		v := currentStatsView()
		ips, ipBytes, ctry := v.ipCounts, v.ipBytes, v.countryCounts
		if ips == nil {
			ips = map[string]int64{}
		}
		if ipBytes == nil {
			ipBytes = map[string]int64{}
		}
		if ctry == nil {
			ctry = map[string]int64{}
		}
		uniqueIPs := len(v.ipCounts)

		type TrendItem struct {
			Date          string           `json:"date"`
			Requests      int64            `json:"requests"`
			Bytes         int64            `json:"bytes"`
			UpBytes       int64            `json:"up_bytes"`
			DownBytes     int64            `json:"down_bytes"`
			Blocked       int64            `json:"blocked"`
			BlockedCN     int64            `json:"blocked_cn"`
			BlockedWL     int64            `json:"blocked_whitelist"`
			Hours         map[string]int64 `json:"hours,omitempty"`
			HourBytes     map[string]int64 `json:"hour_bytes,omitempty"`
			HourUpBytes   map[string]int64 `json:"hour_up_bytes,omitempty"`
			HourDownBytes map[string]int64 `json:"hour_down_bytes,omitempty"`
			Hosts         map[string]int64 `json:"hosts,omitempty"`
			IPs           map[string]int64 `json:"ips,omitempty"`
			Countries     map[string]int64 `json:"countries,omitempty"`
			UAClass       map[string]int64 `json:"ua_class,omitempty"`
			UARaw         map[string]int64 `json:"ua_raw,omitempty"`
		}
		var trend []TrendItem
		hostAll := map[string]int64{}
		for k, d := range v.daily {
			if d == nil {
				continue
			}
			if slim {
				trend = append(trend, TrendItem{
					Date: k, Requests: d.Requests, Bytes: d.Bytes, UpBytes: d.UpBytes, DownBytes: d.DownBytes,
					Blocked:   d.BlockedCN + d.BlockedWL + d.BlockedBan + d.BlockedUA,
					BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL,
					Hours:         hour24(d.Hours),
					HourBytes:     hour24(d.HourBytes),
					HourUpBytes:   hour24(d.HourUpBytes),
					HourDownBytes: hour24(d.HourDownBytes),
				})
				continue
			}
			for hk, hv := range d.Hosts {
				hostAll[hk] += hv
			}
			trend = append(trend, TrendItem{
				Date: k, Requests: d.Requests, Bytes: d.Bytes, UpBytes: d.UpBytes, DownBytes: d.DownBytes,
				Blocked:   d.BlockedCN + d.BlockedWL + d.BlockedBan + d.BlockedUA,
				BlockedCN: d.BlockedCN, BlockedWL: d.BlockedWL,
				Hours:         hour24(d.Hours),
				HourBytes:     hour24(d.HourBytes),
				HourUpBytes:   hour24(d.HourUpBytes),
				HourDownBytes: hour24(d.HourDownBytes),
				Hosts:         topNMap(d.Hosts, 50),
				IPs:           topNMap(d.IPs, 100),
				Countries:     topNMap(d.Countries, 50),
				UAClass:       topNMap(d.UAClass, 30),
				UARaw:         topNMap(d.UARaw, 20),
			})
		}
		sort.Slice(trend, func(i, j int) bool { return trend[i].Date < trend[j].Date })

		labels := map[string]string{}
		for code := range ctry {
			labels[code] = countryName(code)
		}
		today := beijingDate(time.Now())
		todayReqs, todayBytes := v.todayReqs, v.todayBytes
		if d := v.daily[today]; d != nil {
			if todayReqs == 0 {
				todayReqs = d.Requests
			}
			if todayBytes == 0 {
				todayBytes = d.Bytes
			}
		}
		hostTop := topNMap(hostAll, 50)

		resp := map[string]any{
			"schema_version": v.schemaVersion,
			"total_requests": v.totalRequests, "total_bytes": v.totalBytes,
			"total_up_bytes": v.totalUpBytes, "total_down_bytes": v.totalDownBytes,
			"today_date": today, "requests": v.totalRequests, "bytes": v.totalBytes,
			"blocked_cn": v.blockedCN, "blocked_whitelist": v.blockedWL,
			"blocked_ban": v.blockedBan, "blocked_ua": v.blockedUA,
			"blocked_total":  v.blockedCN + v.blockedWL + v.blockedBan + v.blockedUA,
			"today_requests": todayReqs, "today_bytes": todayBytes,
			"today_up_bytes": v.todayUp, "today_down_bytes": v.todayDown,
			"trend":        trend,
			"uptime_sec":   int64(time.Since(startedAt).Seconds()),
			"stat_dropped": statDropped.Load(),
			"viewed_at":    beijingRFC3339(v.at),
		}
		if slim {
			resp["unique_ips"] = uniqueIPs
		} else {
			resp["ip_counts"] = ips
			resp["ip_bytes"] = ipBytes
			resp["ip_up_bytes"] = v.ipUpBytes
			resp["ip_down_bytes"] = v.ipDownBytes
			resp["country_counts"] = ctry
			resp["country_labels"] = labels
			resp["host_counts"] = hostTop
		}
		_ = json.NewEncoder(w).Encode(resp)
	})
	mux.HandleFunc("/admin/api/blocks", func(w http.ResponseWriter, r *http.Request) {
		limit, offset := pageParams(r, 50)
		qIP := strings.TrimSpace(r.URL.Query().Get("ip"))
		qReason := strings.TrimSpace(r.URL.Query().Get("reason"))
		qSearch := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
		w.Header().Set("Content-Type", "application/json")

		v := currentStatsView()
		all := v.blocks
		// 全局原因分布：不受当前筛选影响，用于页面上按类型区分与计数
		reasonCounts := make(map[string]int, 8)
		for i := range all {
			reasonCounts[all[i].Reason]++
		}
		matched := make([]BlockEvent, 0, len(all))
		for i := len(all) - 1; i >= 0; i-- {
			ev := all[i]
			if qIP != "" && ev.IP != qIP {
				continue
			}
			if qReason != "" && !reasonMatches(ev.Reason, qReason) {
				continue
			}
			if qSearch != "" {
				blob := strings.ToLower(ev.IP + " " + ev.Host + " " + ev.Path + " " + ev.UA + " " + ev.ReasonText + " " + ev.Country)
				if !strings.Contains(blob, qSearch) {
					continue
				}
			}
			matched = append(matched, ev)
		}
		total := len(matched)
		start := offset
		if start > total {
			start = total
		}
		end := total
		if limit > 0 && start+limit < end {
			end = start + limit
		}
		page := matched[start:end]
		items := make([]map[string]any, len(page))
		for i, ev := range page {
			items[i] = map[string]any{
				"time": ev.Time, "ip": ev.IP, "country": ev.Country, "host": ev.Host,
				"country_name": countryName(ev.Country),
				"path":         ev.Path, "reason": ev.Reason, "reason_text": ev.ReasonText, "ua": ev.UA,
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"total": total, "returned": len(items), "offset": start, "limit": limit,
			"items": items, "reason_counts": reasonCounts,
		})
	})

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
		limit, offset := pageParams(r, 200)
		qAction := strings.TrimSpace(r.URL.Query().Get("action"))
		w.Header().Set("Content-Type", "application/json")

		v := currentStatsView()
		all := v.audit
		items := make([]AuditEvent, 0, limit)
		for i := len(all) - 1; i >= 0 && len(items) < limit; i-- {
			if qAction != "" && all[i].Action != qAction {
				continue
			}
			if offset > 0 {
				offset--
				continue
			}
			items = append(items, all[i])
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"items": items, "total": len(all), "returned": len(items),
		})
	})
	mux.HandleFunc("/admin/api/ip-detail", func(w http.ResponseWriter, r *http.Request) {
		ip := strings.TrimSpace(r.URL.Query().Get("ip"))
		if ip == "" || net.ParseIP(ip) == nil {
			http.Error(w, "IP 地址格式无效，请输入合法的 IPv4/IPv6 地址", http.StatusBadRequest)
			return
		}
		code, name := ipLabelSync(ip)
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
		sv := currentStatsView()
		reqs := sv.ipCounts[ip]
		upBytes := sv.ipUpBytes[ip]
		downBytes := sv.ipDownBytes[ip]
		blocked := 0
		for _, ev := range sv.blocks {
			if ev.IP == ip {
				blocked++
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ip": ip, "country": code, "country_name": name,
			"region": geo.Region, "city": geo.City,
			"isp": geo.ISP, "org": geo.Org, "as": geo.AS,
			"location": strings.Join(locParts, " · "),
			"requests": reqs, "blocked": blocked,
			"up_bytes": upBytes, "down_bytes": downBytes,
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
		tok := getSessionToken(r)
		destroyOtherSessions(tok)
		recordAudit(getClientIP(r), "change_password", "管理员修改了密码")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
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
				Uses   int    `json:"uses"`
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

	mux.HandleFunc("/admin/api/report", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"方法不支持"}`, http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Action string `json:"action"`
			ID     string `json:"id"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req)

		if req.Action == "records" {
			reportRecordsMu.Lock()
			list := make([]reportRecord, len(reportRecords))
			copy(list, reportRecords)
			reportRecordsMu.Unlock()
			for i, j := 0, len(list)-1; i < j; i, j = i+1, j-1 {
				list[i], list[j] = list[j], list[i]
			}
			cfg := cfgPtr.Load()
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items":     list,
				"total":     len(list),
				"keep_days": reportRecordKeepDays,
				"url":       cfg.ReportURL,
				"on":        cfg.ReportOn,
				"tmpl_on":   cfg.DailyTmplOn,
				"tmpl_url":  cfg.DailyTmplURL,
				"plan":      buildReportPlan(cfg),
			})
			return
		}
		if req.Action == "payload" {
			text, ok := loadReportPayload(req.ID)
			if !ok {
				_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "saved": false})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"ok":      true,
				"saved":   true,
				"id":      req.ID,
				"size":    len(text),
				"payload": text,
			})
			return
		}
		if req.Action == "clearrec" {
			reportRecordsMu.Lock()
			reportRecords = nil
			persistReportRecordsLocked()
			clearReportPayloads()
			reportRecordsMu.Unlock()
			recordAudit(getClientIP(r), "report_clear_records", "清空上报记录")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
			return
		}
		if req.Action == "retry" {
			c := cfgPtr.Load()
			if c == nil || c.ReportURL == "" {
				http.Error(w, `{"error":"尚未配置接收地址"}`, http.StatusBadRequest)
				return
			}
			before := len(loadReportQueue())
			flushReportQueue()
			after := len(loadReportQueue())
			recordAudit(getClientIP(r), "report_retry", fmt.Sprintf("补传上报队列，剩余 %d 批", after))
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "before": before, "after": after, "sent": before - after})
			return
		}

		c := cfgPtr.Load()
		if c == nil {
			http.Error(w, `{"error":"配置尚未加载，请稍后再试"}`, http.StatusBadRequest)
			return
		}
		if req.Action == "flush" {
			flushReportQueue()
		}
		if req.Action == "clear_queue" {
			n := len(loadReportQueue())
			_ = db.Update(func(tx *bolt.Tx) error {
				b := tx.Bucket([]byte("report_queue"))
				if b == nil {
					return nil
				}
				c2 := b.Cursor()
				for k, _ := c2.First(); k != nil; k, _ = c2.Next() {
					if string(k) == "daily_sent" {
						continue // 保留日报防重标记
					}
					if err := b.Delete(k); err != nil {
						return err
					}
				}
				return nil
			})
			recordAudit(getClientIP(r), "report_clear_queue", "清空待补传队列")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "cleared": n})
			return
		}
		if req.Action == "clear" {
			_ = db.Update(func(tx *bolt.Tx) error {
				if b := tx.Bucket([]byte("report_queue")); b != nil {
					return b.Delete([]byte("snaps"))
				}
				return nil
			})
			recordAudit(getClientIP(r), "report_clear", "清空上报快照")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
			return
		}
		if req.Action == "status" || req.Action == "flush" {
			q := loadReportQueue()
			out := make([]map[string]any, 0, len(q))
			for _, it := range q {
				out = append(out, map[string]any{"id": it.ID, "created": it.Created, "attempts": it.Attempts, "last_err": it.LastErr})
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"queue": out, "depth": len(q), "url": c.ReportURL, "on": c.ReportOn, "tmpl_on": c.DailyTmplOn, "tmpl_url": c.DailyTmplURL})
			return
		}
		if req.Action == "daily" {
			// 通知通道与接口上报相互独立：自定义格式已配置独立地址即可发送，无需配置上报地址
			tURL, tToken := dailyTarget(c)
			if tURL == "" {
				http.Error(w, `{"error":"尚未配置日报发送地址或上报地址，无法发送昨日统计"}`, http.StatusBadRequest)
				return
			}
			if isGetUpdatesURL(tURL) {
				http.Error(w, `{"error":"日报发送地址以 /getUpdates 结尾：该接口只能拉取消息，发不出通知。请改为 .../sendMessage，Content-Type 选 application/json"}`, http.StatusBadRequest)
				return
			}
			yd := beijingDate(nowBeijing().AddDate(0, 0, -1))
			p, ok := buildDailyReportPayload(yd)
			if !ok {
				http.Error(w, `{"error":"暂无昨天的统计数据（昨天无流量或服务未运行）"}`, http.StatusBadRequest)
				return
			}
			body, trigger, id := dailySendSpec(c, p, yd)
			ct := dailyContentType(c)
			start := time.Now()
			status, respBody, err := sendOnceRespCT(tURL, tToken, body, ct)
			// 通知通道：识别「HTTP 200 但实际没送达」的假成功（Telegram ok:false、result 为空数组等）
			if err == nil && c.DailyTmplOn {
				err = checkNotifyResult(status, respBody)
			}
			clientIP := getClientIP(r)
			rec := recordFromPayload(body, id, trigger, status, respBody, err, 1, start, clientIP, tURL)
			appendReportRecord(rec, body)
			recordAudit(clientIP, "report_daily", tURL)
			if err != nil {
				reportQueueMu.Lock()
				list := loadReportQueue()
				list = append(list, queuedReport{ID: id, Payload: body, Created: p.ReportedAt, Attempts: 1, LastErr: err.Error(), Trigger: trigger, URL: tURL, Token: tToken, ContentType: ct})
				if len(list) > maxReportQueue {
					list = list[len(list)-maxReportQueue:]
				}
				saveReportQueue(list)
				reportQueueMu.Unlock()
			} else {
				markDailyReportSent(yd)
			}
			var payloadObj any
			_ = json.Unmarshal(mustJSON(p), &payloadObj)
			w.WriteHeader(http.StatusOK)
			resp := map[string]any{
				"ok":          err == nil,
				"payload":     payloadObj,
				"resp_status": status,
				"resp_body":   respBody,
				"error":       errString(err),
				"queued":      err != nil,
				"record_id":   rec.ID,
				"content_type": ct,
				"target":      tURL,
			}
			if c.DailyTmplOn {
				resp["text"] = string(body)
			}
			_ = json.NewEncoder(w).Encode(resp)
			return
		}
		if c.ReportURL == "" {
			http.Error(w, `{"error":"尚未配置上报地址（接收地址）；如需推送 Telegram 等通知，请使用「发送昨日统计」"}`, http.StatusBadRequest)
			return
		}
		p, ok := lastFullHourReport()
		if !ok {
			http.Error(w, `{"error":"上个小时的快照还没生成（服务刚启动不足一小时），到下一个整点后再试"}`, http.StatusBadRequest)
			return
		}
		raw, _ := json.Marshal(p)
		start := time.Now()
		status, respBody, err := sendOnceResp(c.ReportURL, c.ReportToken, raw)
		clientIP := getClientIP(r)
		rec := recordFromPayload(raw, p.BatchID, "manual", status, respBody, err, 1, start, clientIP, c.ReportURL)
		appendReportRecord(rec, raw)
		recordAudit(clientIP, "report_test", c.ReportURL)
		if err != nil {
			reportQueueMu.Lock()
			list := loadReportQueue()
			list = append(list, queuedReport{ID: p.BatchID, Payload: raw, Created: p.ReportedAt, Attempts: 1, LastErr: err.Error()})
			if len(list) > maxReportQueue {
				list = list[len(list)-maxReportQueue:]
			}
			saveReportQueue(list)
			reportQueueMu.Unlock()
		}
		var payloadObj any
		_ = json.Unmarshal(raw, &payloadObj)
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok":          err == nil,
			"payload":     payloadObj,
			"resp_status": status,
			"resp_body":   respBody,
			"error":       errString(err),
			"queued":      err != nil,
			"record_id":   rec.ID,
		})
		return
	})

	mux.HandleFunc("/admin/api/clear-stats", func(w http.ResponseWriter, r *http.Request) {
		statsMu.Lock()
		stats = emptyStats()
		snap := marshalStatsLocked()
		statsMu.Unlock()
		invalidateStatsView()
		persistStats(snap)
		recordAudit(getClientIP(r), "clear_stats", "清空全部统计与拦截记录")
		if db != nil {
			_ = db.Update(func(tx *bolt.Tx) error {
				_ = tx.DeleteBucket([]byte("stats_daily"))
				_ = tx.DeleteBucket([]byte("stats_meta"))
				_ = tx.DeleteBucket([]byte("stats_blocks"))
				_ = tx.DeleteBucket([]byte("stats"))
				return nil
			})
			statsMu.Lock()
			snap := marshalStatsLocked()
			statsMu.Unlock()
			persistStats(snap)
		}
		w.Write([]byte(`{"ok":true}`))
	})
	registerExtraRoutes(mux)

	mux.HandleFunc("/admin/api/flag/", func(w http.ResponseWriter, r *http.Request) {
		code := strings.ToLower(strings.TrimPrefix(r.URL.Path, "/admin/api/flag/"))
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
	mux.HandleFunc("/admin/chart.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		_, _ = w.Write(chartJS)
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
		if !adminIPAllowed(getClientIP(r)) {
			serveError(w, r, http.StatusForbidden, "访问受限",
				"当前来源 IP 不在允许访问的范围内，无法打开该页面。此限制不影响代理转发。",
				errPageCtx{Code: "admin_ip", Label: "来源 IP 不在允许范围", Tips: []string{
					"如需从当前来源访问，请联系服务提供者调整允许范围。",
					"若确认被误拦，请把上面的「请求编号」与「发生时间」提供给服务提供者。",
				}})
			return
		}
		path := r.URL.Path
		if path == "/admin/login" || path == "/admin/api/captcha" || path == "/admin/api/login" || path == "/admin/api/logout" ||
			path == "/admin/splash" || path == "/admin/logo.png" || path == "/admin/icon-192.png" || path == "/admin/icon-512.png" ||
			path == "/admin/manifest.webmanifest" || path == "/admin/sw.js" || path == "/admin/chart.js" {
			mux.ServeHTTP(w, r)
			return
		}
		requireAuth(mux.ServeHTTP)(w, r)
	}
}

func startGeoDBUpdater() {
	go func() {
		time.Sleep(30 * time.Second)
		for {
			log.Println("[geo] local IP database ready (embedded iploc); next check in 24h")
			time.Sleep(24 * time.Hour)
		}
	}()
}

// runServer 是程序主入口：打开数据库、加载配置与统计、启动后台任务、监听端口。
// 收到 SIGINT/SIGTERM 时关闭服务并做最后一次统计落盘。
func runServer(port int, adminUser, adminPass, dbFile string) {
	proxyTr.v.Store(newTransport())
	var err error
	dbPath = dbFile
	db, err = bolt.Open(dbFile, 0600, &bolt.Options{Timeout: 3 * time.Second})
	if err != nil {
		log.Fatalf("无法打开数据库: %v", err)
	}
	defer db.Close()

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

	for _, legacy := range []string{"geo_cache.json", "geo_cache.json.bak", "stats.json.bak", "config.json.bak", "admin.pass.bak"} {
		_ = os.Remove(filepath.Join(filepath.Dir(dbFile), legacy))
	}

	loadConfig()
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
	loadReportRecords()
	startReportRecordCleaner()
	startSpeedTokenCleaner()
	startStatsWorker()
	startStatsSaver()

	startNetSpeedSampler()
	startHourlySnapshotWorker()
	startReportWorker()
	startDailyReportWorker()
	detectSelfPublicIP()
	publishStatsView()
	initSessionsCleanup()
	startGeoDBUpdater()
	defer saveStatsOnce()

	proxy := buildProxy(proxyTr)
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/favicon.ico" || r.URL.Path == "/favicon.png" || r.URL.Path == "/favicon.svg" {
			redirectIcon(w, r, iconFaviconURL)
			return
		}
		if isBuiltinAssetPath(r.URL.Path) {
			serveError(w, r, http.StatusNotFound, "页面不存在",
				"该路径属于浏览器自动请求的内置资源（如 favicon、robots.txt），本服务没有提供对应文件。",
				errPageCtx{Tips: []string{
					"普通访客可忽略此提示，它不影响媒体播放。",
					"管理员可在前置 Nginx 上给这些路径配置静态文件，或直接返回 204。",
				}})
			return
		}
		if r.URL.Path == "/" || r.URL.Path == "" {
			serveHome(w, r)
			return
		}
		ip := getClientIP(r)
		c := currentCfg()
		// IP 归属整条判定链只解析一次，下面各步共用
		country := countryOf(ip)

		// 判定链 ② IP 黑名单
		clientIP := net.ParseIP(ip)
		if isBannedIP(ip, clientIP) {
			if blockedRateLimited(ip) {
				dropOrMinimal429(w)
				return
			}
			recordBlocked(ip, country, r.URL.RequestURI(), "ban", r.UserAgent(), r.Host)
			serveError(w, r, http.StatusForbidden, "来源 IP 已被拉黑",
				"您的来源 IP 命中了 IP 黑名单，请求在判定链第 ② 步被拒绝，未进入反代流程。",
				errPageCtx{Code: "ban", Label: "IP 在黑名单中"})
			return
		}
		// 判定链 ③ UA 白名单
		if !uaAllowed(r.UserAgent()) {
			if blockedRateLimited(ip) {
				dropOrMinimal429(w)
				return
			}
			recordBlocked(ip, country, r.URL.RequestURI(), "ua", r.UserAgent(), r.Host)
			serveError(w, r, http.StatusForbidden, "客户端不被允许",
				"当前客户端的 User-Agent 未命中 UA 白名单关键字，请求在判定链第 ③ 步被拒绝。",
				errPageCtx{Code: "ua", Label: "User-Agent 不在允许列表"})
			return
		}
		// 判定链 ④ 地区限制
		if c.ChinaOnly && country != "CN" && country != "LO" && country != "PV" {
			if blockedRateLimited(ip) {
				dropOrMinimal429(w)
				return
			}
			recordBlocked(ip, country, r.URL.RequestURI(), "cn", r.UserAgent(), r.Host)
			serveError(w, r, http.StatusForbidden, "地区限制",
				"当前来源 IP 的归属地不在允许范围内，请求在判定链第 ④ 步被拒绝。",
				errPageCtx{Code: "cn", Label: "仅允许中国大陆 IP 访问"})
			return
		}

		// 判定链 ⑤ 上游域名白名单（需先解析出反代目标，故放在最后）
		target, err := parseTarget(r)
		if err != nil {
			serveHome(w, r)
			return
		}
		if !whitelistMatch(c.Whitelist, target.Host) {
			if blockedRateLimited(ip) {
				dropOrMinimal429(w)
				return
			}
			recordBlocked(ip, country, r.URL.RequestURI(), "whitelist", r.UserAgent(), r.Host)
			serveError(w, r, http.StatusForbidden, "目标域名未授权",
				"请求路径中的上游域名不在「上游域名白名单」内，请求在判定链第 ⑤ 步被拒绝，未向上游转发任何数据。",
				errPageCtx{Code: "whitelist", Label: "上游目标域名未授权"})
			return
		}

		recordRequestStart(ip, country, target.Host, r.UserAgent())

		concurrent.Add(1)
		defer concurrent.Add(-1)
		rb := &reqBytes{ip: ip}
		ctx := context.WithValue(r.Context(), targetCtxKey{}, target)
		ctx = withReqBytes(ctx, rb)
		proxy.ServeHTTP(&countingWriter{ResponseWriter: w, rb: rb}, r.WithContext(ctx))
		up, down := rb.up.Load(), rb.down.Load()
		if up > 0 || down > 0 {
			select {
			case statChan <- statEvent{IP: ip, UpBytes: up, DownBytes: down, Bytes: up + down}:
			default:
				statDropped.Add(1)
			}
		}
		pushLiveEvent(ip, country, target.Host, r.URL.Path)
	})

	adminSrv := adminHandler()
	adminGz := gzipMiddleware(adminSrv)
	root := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 公开页面（首页 / 所有提示页）的图标走根路径，避免 HTML 里出现 /admin 前缀。
		// 与 /admin/logo.png 指向同一资源，必须在访问域名守卫之前放行，保证 403 页也能显示。
		if r.URL.Path == "/logo.png" {
			redirectIcon(w, r, iconLogoURL)
			return
		}
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
		// ===== 访问判定链 =====
		// ① 黑名单 IP（本处提前短路）
		// ② 访问域名守卫（Host）
		// ③ UA 白名单
		// ④ 地区限制（ChinaOnly）
		// ⑤ 上游域名白名单
		// 任一环节拒绝即返回，不进入反代。高频拒绝会触发限速直接断连。
		// 提前短路：已知黑名单 IP 直接拒绝，少做后续 Host / UA 等判断
		ipEarly := getClientIP(r)
		if isBannedIP(ipEarly, net.ParseIP(ipEarly)) {
			if blockedRateLimited(ipEarly) {
				dropOrMinimal429(w)
				return
			}
			recordBlocked(ipEarly, countryOf(ipEarly), r.URL.RequestURI(), "ban", r.UserAgent(), r.Host)
			serveError(w, r, http.StatusForbidden, "来源 IP 已被拉黑",
				"您的来源 IP 命中了 IP 黑名单，请求在判定链早期被拒绝，未进入反代流程。",
				errPageCtx{Code: "ban", Label: "IP 在黑名单中"})
			return
		}
		// 判定链 ① 访问域名白名单：/health（监控）、/admin/（后台）、/speed/（测速链接）
		// 已在上面放行，其余请求（首页、favicon、所有代理转发路径）都必须用允许的域名访问。
		// 放在这里而不是 proxyHandler 内部，能保证通过 IP 打开时连首页都不暴露。
		// 顺序与 ruleChainOrder 一致，后续 ②③④⑤ 在 proxyHandler 内依次执行。
		if allowed, reason := accessHostAllowed(currentCfg(), r); !allowed {
			ip := getClientIP(r)
			if blockedRateLimited(ip) {
				dropOrMinimal429(w)
				return
			}
			recordBlocked(ip, countryOf(ip), r.URL.RequestURI(), reason, r.UserAgent(), r.Host)
			title, label, msg := "禁止 IP 直连", "IP / localhost 直连被拒绝", "您正在使用服务器 IP、localhost 或单标签主机名访问，本服务已禁止这种访问方式。"
			if reason == "host_deny" {
				title, label, msg = "访问域名未授权", "访问域名不在允许列表中", "当前浏览器使用的域名不在「允许访问的域名」列表中。"
			}
			serveError(w, r, http.StatusForbidden, title,
				msg+"该请求在判定链第 ① 步被拒绝，未进入后续规则与反代流程。",
				errPageCtx{Code: reason, Label: label})
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

// main 解析命令行参数。支持直接运行，或通过 "run" 子命令由 systemd 拉起。
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
	runServer(*port, *adminUser, *adminPass, *dbFile)
}
GO_SOURCE
  cat > "$dir/features.go" <<'FEATURES_GO'
package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	bolt "go.etcd.io/bbolt"
)

func uaClassOf(ua string) string {
	if strings.TrimSpace(ua) == "" {
		return "未知"
	}
	l := strings.ToLower(ua)
	switch {
	case strings.Contains(l, "infuse"):
		return "Infuse"
	case strings.Contains(l, "fileball"):
		return "FileBall"
	case strings.Contains(l, "senplayer"):
		return "SenPlayer"
	case strings.Contains(l, "vidhub"):
		return "VidHub"
	case strings.Contains(l, "emby theater") || strings.Contains(l, "embytheater"):
		return "Emby Theater"
	case strings.Contains(l, "emby"):
		return "Emby 客户端"
	case strings.Contains(l, "jellyfin"):
		return "Jellyfin 客户端"
	case strings.Contains(l, "android tv") || strings.Contains(l, "googletv") || strings.Contains(l, "bravia"):
		return "Android TV"
	case strings.Contains(l, "appletv") || strings.Contains(l, "apple tv"):
		return "Apple TV"
	case strings.Contains(l, "iphone") || strings.Contains(l, "ipad") || strings.Contains(l, "ios") || strings.Contains(l, "cfnetwork"):
		return "iOS"
	case strings.Contains(l, "android"):
		return "Android"
	case strings.Contains(l, "vlc") || strings.Contains(l, "potplayer") || strings.Contains(l, "mpv") || strings.Contains(l, "kodi"):
		return "播放器"
	case strings.Contains(l, "dandanplay"):
		return "弹弹play"
	case strings.Contains(l, "yamby"):
		return "Yamby"
	case strings.Contains(l, "evermedia"):
		return "EverMedia"
	case strings.Contains(l, "nplayer"):
		return "nPlayer"
	case strings.Contains(l, "mxplayer"):
		return "MX Player"
	case strings.Contains(l, "ffmpeg") || strings.Contains(l, "lavf") || strings.Contains(l, "libav"):
		return "FFmpeg"
	case strings.Contains(l, "exoplayer") || strings.Contains(l, "okhttp") || strings.Contains(l, "dalvik"):
		return "Android 应用"
	case strings.Contains(l, "mozilla") || strings.Contains(l, "chrome") || strings.Contains(l, "safari") ||
		strings.Contains(l, "firefox") || strings.Contains(l, "edg"):
		return "浏览器"
	case strings.Contains(l, "curl") || strings.Contains(l, "wget") || strings.Contains(l, "python") || strings.Contains(l, "go-http"):
		return "脚本/探针"
	default:
		return "其他"
	}
}

type statsView struct {
	at time.Time

	schemaVersion int
	lastProxyAt   string

	totalRequests  int64
	totalBytes     int64
	totalUpBytes   int64
	totalDownBytes int64

	todayDate  string
	todayReqs  int64
	todayBytes int64
	todayUp    int64
	todayDown  int64

	blockedCN  int64
	blockedWL  int64
	blockedBan int64
	blockedUA  int64

	countryCounts map[string]int64
	ipCounts      map[string]int64
	ipBytes       map[string]int64
	ipUpBytes     map[string]int64
	ipDownBytes   map[string]int64

	daily  map[string]*DayStat
	blocks []BlockEvent
	audit  []AuditEvent
}

var (
	statsViewPtr   atomic.Pointer[statsView]
	statsViewMu    sync.Mutex
	statsViewEvery = 2 * time.Second
)

func cloneInt64Map(src map[string]int64) map[string]int64 {
	dst := make(map[string]int64, len(src))
	for k, v := range src {
		dst[k] = v
	}
	return dst
}

func cloneDayStat(d *DayStat) *DayStat {
	if d == nil {
		return nil
	}
	n := *d
	n.Countries = cloneInt64Map(d.Countries)
	n.IPs = cloneInt64Map(d.IPs)
	n.IPBytes = cloneInt64Map(d.IPBytes)
	n.IPUpBytes = cloneInt64Map(d.IPUpBytes)
	n.IPDownBytes = cloneInt64Map(d.IPDownBytes)
	n.Hours = cloneInt64Map(d.Hours)
	n.HourBytes = cloneInt64Map(d.HourBytes)
	n.HourUpBytes = cloneInt64Map(d.HourUpBytes)
	n.HourDownBytes = cloneInt64Map(d.HourDownBytes)
	n.Hosts = cloneInt64Map(d.Hosts)
	n.UAClass = cloneInt64Map(d.UAClass)
	return &n
}

func buildStatsViewLocked() *statsView {
	v := &statsView{
		at:             time.Now(),
		schemaVersion:  stats.SchemaVersion,
		lastProxyAt:    stats.LastProxyAt,
		totalRequests:  stats.TotalRequests,
		totalBytes:     stats.TotalBytes,
		totalUpBytes:   stats.TotalUpBytes,
		totalDownBytes: stats.TotalDownBytes,
		todayDate:      stats.TodayDate,
		todayReqs:      stats.TodayRequests,
		todayBytes:     stats.TodayBytes,
		todayUp:        stats.TodayUpBytes,
		todayDown:      stats.TodayDownBytes,
		blockedCN:      stats.BlockedCN,
		blockedWL:      stats.BlockedWhitelist,
		blockedBan:     stats.BlockedBan,
		blockedUA:      stats.BlockedUA,
		countryCounts:  cloneInt64Map(stats.CountryCounts),
		ipCounts:       cloneInt64Map(stats.IPCounts),
		ipBytes:        cloneInt64Map(stats.IPBytes),
		ipUpBytes:      cloneInt64Map(stats.IPUpBytes),
		ipDownBytes:    cloneInt64Map(stats.IPDownBytes),
		daily:          make(map[string]*DayStat, len(stats.Daily)),
	}
	for k, d := range stats.Daily {
		if d == nil {
			continue
		}
		ensureDayMaps(d)
		v.daily[k] = cloneDayStat(d)
	}
	v.blocks = append([]BlockEvent(nil), stats.Blocks...)
	v.audit = append([]AuditEvent(nil), stats.Audit...)
	return v
}

func publishStatsView() *statsView {
	statsViewMu.Lock()
	defer statsViewMu.Unlock()
	if cur := statsViewPtr.Load(); cur != nil && time.Since(cur.at) < statsViewEvery {
		return cur
	}
	statsMu.Lock()
	v := buildStatsViewLocked()
	statsMu.Unlock()
	statsViewPtr.Store(v)
	return v
}

func currentStatsView() *statsView {
	if v := statsViewPtr.Load(); v != nil && time.Since(v.at) < statsViewEvery {
		return v
	}
	return publishStatsView()
}

func invalidateStatsView() { statsViewPtr.Store(nil) }

func blockedTotal(v *statsView) int64 {
	if v == nil {
		return 0
	}
	return v.blockedCN + v.blockedWL + v.blockedBan + v.blockedUA
}

func adminAllowList(c *Config) []string {
	if c == nil {
		return nil
	}
	out := make([]string, 0, len(c.AdminAllow))
	for _, s := range c.AdminAllow {
		s = strings.TrimSpace(s)
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func adminIPAllowed(ipStr string) bool {
	return adminAllowContains(currentCfg(), ipStr)
}

func validateAdminAllow(list []string, currentIP string) error {
	cleaned := make([]string, 0, len(list))
	for _, s := range list {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if strings.Contains(s, "/") {
			if _, _, err := net.ParseCIDR(s); err != nil {
				return fmt.Errorf("“%s”不是合法的 CIDR，例如 192.168.1.0/24", s)
			}
		} else if net.ParseIP(s) == nil {
			return fmt.Errorf("“%s”不是合法的 IP 地址", s)
		}
		cleaned = append(cleaned, s)
	}
	if len(cleaned) == 0 {
		return nil
	}
	tmp := &Config{AdminAllow: cleaned}
	if !adminAllowContains(tmp, currentIP) {
		return fmt.Errorf("当前访问来源 %s 不在列表中，保存后将无法再登录后台；请先把本机 IP 加进去", currentIP)
	}
	return nil
}

func adminAllowContains(c *Config, ipStr string) bool {
	list := adminAllowList(c)
	if len(list) == 0 {
		return true
	}
	ip := net.ParseIP(strings.TrimSpace(ipStr))
	if ip == nil {
		return false
	}
	for _, rule := range list {
		if strings.Contains(rule, "/") {
			if _, ipnet, err := net.ParseCIDR(rule); err == nil && ipnet.Contains(ip) {
				return true
			}
			continue
		}
		if r := net.ParseIP(rule); r != nil && r.Equal(ip) {
			return true
		}
	}
	return false
}

// ruleChainOrder 是全站唯一的判定链顺序定义。
// 真实请求（runServer 的 root 守卫 + proxyHandler）、规则测试 API、
// 管理后台「判定链顺序」面板三处共用此顺序，避免各写一份后逐渐漂移。
//
// 排序原则：先准入后内容，先便宜后昂贵。
//   ① 访问域名白名单：纯字符串解析，最外层准入，挡掉 IP 直连 / 盗链 / 扫描器
//   ② IP 黑名单：内存查表，明确拉黑的来源直接丢弃
//   ③ UA 白名单：内存字符串匹配
//   ④ 地区限制：要查 IP 归属库，放到便宜规则之后，只对存活下来的请求执行
//   ⑤ 上游域名白名单：需先 parseTarget 解析请求路径，只有真正反代才需要
// 例外路径（/health、/admin/、/speed/、favicon、内置资源、首页）不参与此链，
// 保持「后台与监控永远可用、首页不暴露内容」的既有行为。
type ruleStepSpec struct {
	Key    string `json:"key"`
	Name   string `json:"name"`
	Detail string `json:"detail"`
	Kind   string `json:"kind"` // block=拦截项, pass=终点
}

var ruleChainOrder = []ruleStepSpec{
	{"access_host", "访问域名白名单", "请求 Host 必须在允许列表内；开启后禁止 IP / localhost 直连", "block"},
	{"ban", "IP 黑名单", "来源 IP 精确匹配或命中 CIDR 段", "block"},
	{"ua", "UA 白名单", "客户端 UA 需包含白名单关键字，空=不限制", "block"},
	{"cn", "地区限制", "开启「仅允许中国大陆 IP」时，非大陆来源被拒", "block"},
	{"whitelist", "上游域名白名单", "路径中的目标域名需匹配白名单（支持根域名），空=不限制", "block"},
	{"forward", "放行转发", "全部通过后反代到上游，并计入流量统计", "pass"},
}

func registerExtraRoutes(mux *http.ServeMux) {
	// 判定链顺序（后台面板渲染用），与 ruleChainOrder 同源
	mux.HandleFunc("/admin/api/rules/chain", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodGet {
			http.Error(w, `{"error":"方法不支持"}`, http.StatusMethodNotAllowed)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "chain": ruleChainOrder})
	})
	mux.HandleFunc("/admin/api/rules/test", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"方法不支持"}`, http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			IP         string `json:"ip"`
			UA         string `json:"ua"`
			Host       string `json:"host"`        // 目标上游：路径里要反代的域名
			AccessHost string `json:"access_host"` // 请求 Host：浏览器地址栏用的域名
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
			http.Error(w, `{"error":"请求格式有误"}`, http.StatusBadRequest)
			return
		}
		ip := strings.TrimSpace(req.IP)
		if ip == "" {
			ip = getClientIP(r)
		}
		if net.ParseIP(ip) == nil {
			http.Error(w, `{"error":"IP 地址格式无效"}`, http.StatusBadRequest)
			return
		}
		c := currentCfg()
		ua := req.UA
		host := strings.TrimSpace(req.Host)
		// 留空时用当前后台请求自身的访问域名（含回环代理 X-Forwarded-Host 兼容），
		// 与真实守卫 requestAccessHost 取自同一份逻辑。
		accessHost := strings.TrimSpace(req.AccessHost)
		if accessHost == "" {
			accessHost = requestAccessHost(r)
		}

		type step struct {
			Key    string `json:"key"`
			Name   string `json:"name"`
			Status string `json:"status"`
			Detail string `json:"detail"`
		}
		steps := make([]step, 0, len(ruleChainOrder))
		final := "pass"
		blockedReason := ""
		add := func(idx int, status, detail string) {
			spec := ruleChainOrder[idx]
			steps = append(steps, step{spec.Key, spec.Name, status, detail})
		}

		// ① 访问域名白名单 —— 直接复用真实请求的同一个守卫函数
		fakeReq := &http.Request{Host: accessHost, RemoteAddr: ip + ":0", Header: http.Header{}}
		allowed, reason := accessHostAllowed(c, fakeReq)
		switch {
		case !allowed && reason == "host_ip":
			final, blockedReason = "block", reason
			add(0, "block", accessHost+" 为 IP / localhost 直连，已被禁止")
		case !allowed:
			final, blockedReason = "block", reason
			add(0, "block", accessHost+" 不在允许访问的域名列表中")
		case !c.HostGuardOn:
			add(0, "pass", "未启用（开关关闭，不限制访问域名）")
		case len(c.AllowedHosts) == 0:
			add(0, "pass", accessHost+" 是合法域名；白名单为空，仅禁止 IP 直连")
		default:
			add(0, "pass", accessHost+" 在允许访问的域名列表内")
		}

		// ② IP 黑名单
		if final == "pass" {
			if isBannedIP(ip, net.ParseIP(ip)) {
				final, blockedReason = "block", "ban"
				add(1, "block", ip+" 命中黑名单规则（IP 或 CIDR）")
			} else {
				add(1, "pass", "未命中")
			}
		}

		// ③ UA 白名单
		if final == "pass" {
			switch {
			case len(c.AllowedUAs) == 0:
				add(2, "pass", "未启用（空=不限制）")
			case uaAllowed(ua):
				add(2, "pass", "命中白名单关键字")
			default:
				final, blockedReason = "block", "ua"
				add(2, "block", "User-Agent 不包含任何白名单关键字")
			}
		}

		// ④ 地区限制（IP 归属只解析一次，与真实请求一致）
		country := countryOf(ip)
		cname := countryName(country)
		if final == "pass" {
			if c.ChinaOnly && country != "CN" && country != "LO" && country != "PV" {
				final, blockedReason = "block", "cn"
				add(3, "block", "来源地区为 "+cname+"，不在中国大陆放行范围")
			} else if c.ChinaOnly {
				add(3, "pass", "来源地区 "+cname+"，允许访问")
			} else {
				add(3, "pass", "未开启（仅记录来源："+cname+"）")
			}
		}

		// ⑤ 上游域名白名单（真实请求里由 parseTarget 解析路径得到目标域名）
		if final == "pass" {
			if host == "" {
				add(4, "pass", "未填写目标上游，跳过校验")
			} else if len(c.Whitelist) == 0 {
				add(4, "pass", "未启用（空=不限制）")
			} else if whitelistMatch(c.Whitelist, host) {
				add(4, "pass", host+" 在白名单内")
			} else {
				final, blockedReason = "block", "whitelist"
				add(4, "block", host+" 不在白名单内")
			}
		}

		// 前序已拦截：后续规则不再执行，但仍完整列出，便于对照判定链
		for len(steps) < len(ruleChainOrder)-1 {
			spec := ruleChainOrder[len(steps)]
			steps = append(steps, step{spec.Key, spec.Name, "skip", "前序规则已拦截，未执行"})
		}
		if final == "pass" {
			add(len(ruleChainOrder)-1, "pass", "全部规则通过，将反代到上游并计入流量统计")
		} else {
			add(len(ruleChainOrder)-1, "skip", "已被拦截，不会转发到上游")
		}

		// 后台访问限制只影响 /admin，不属于反代判定链，单独返回避免误导
		adminAccess := "unrestricted"
		if len(adminAllowList(c)) > 0 {
			if adminAllowContains(c, ip) {
				adminAccess = "allowed"
			} else {
				adminAccess = "denied"
			}
		}

		cls := uaClassOfEx(ua)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "ip": ip, "ua": ua, "host": host, "access_host": accessHost,
			"country": country, "country_name": cname, "ua_class": cls,
			"result": final, "reason": blockedReason, "admin_access": adminAccess, "steps": steps,
		})
	})

	mux.HandleFunc("/admin/api/backup", func(w http.ResponseWriter, r *http.Request) {
		if db == nil {
			http.Error(w, "数据库未就绪", http.StatusServiceUnavailable)
			return
		}
		tmp, err := os.CreateTemp("", "emby-backup-*.db")
		if err != nil {
			http.Error(w, "创建临时文件失败", http.StatusInternalServerError)
			return
		}
		tmpName := tmp.Name()
		defer func() { _ = os.Remove(tmpName) }()
		if err := db.View(func(tx *bolt.Tx) error {
			_, e := tx.WriteTo(tmp)
			return e
		}); err != nil {
			tmp.Close()
			http.Error(w, "导出失败："+errString(err), http.StatusInternalServerError)
			return
		}
		if err := tmp.Close(); err != nil {
			http.Error(w, "导出失败", http.StatusInternalServerError)
			return
		}
		f, err := os.Open(tmpName)
		if err != nil {
			http.Error(w, "读取备份失败", http.StatusInternalServerError)
			return
		}
		defer f.Close()
		fi, _ := f.Stat()
		name := "emby-" + beijingDate(nowBeijing()) + ".db"
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", "attachment; filename=\""+name+"\"")
		if fi != nil {
			w.Header().Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
		}
		recordAudit(getClientIP(r), "backup_db", "下载数据库快照")
		_, _ = io.Copy(w, f)
	})

	mux.HandleFunc("/admin/api/config/export", func(w http.ResponseWriter, r *http.Request) {
		b, err := json.MarshalIndent(currentCfg(), "", "  ")
		if err != nil {
			http.Error(w, "导出失败", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Disposition", "attachment; filename=\"emby-config-"+
			beijingDate(nowBeijing())+".json\"")
		recordAudit(getClientIP(r), "config_export", "导出配置")
		_, _ = w.Write(b)
	})

	mux.HandleFunc("/admin/api/config/import", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			http.Error(w, `{"error":"方法不支持"}`, http.StatusMethodNotAllowed)
			return
		}
		var in Config
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in); err != nil {
			http.Error(w, `{"error":"配置文件不是合法的 JSON"}`, http.StatusBadRequest)
			return
		}
		clientIP := getClientIP(r)
		if err := validateAdminAllow(in.AdminAllow, clientIP); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}
		old := currentCfg()
		in.Port = old.Port
		if err := saveConfig(&in); err != nil {
			http.Error(w, `{"error":"写入失败，请检查磁盘"}`, http.StatusInternalServerError)
			return
		}
		cfgPtr.Store(&in)
		rebuildACL(&in)
		recordAudit(clientIP, "config_import", "导入配置")
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "port_kept": in.Port})
	})

	mux.HandleFunc("/admin/api/blocks.csv", func(w http.ResponseWriter, r *http.Request) {
		qIP := strings.TrimSpace(r.URL.Query().Get("ip"))
		qReason := strings.TrimSpace(r.URL.Query().Get("reason"))
		qSearch := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))

		v := currentStatsView()
		rows := make([][]string, 0, len(v.blocks))
		for _, ev := range v.blocks {
			if qIP != "" && ev.IP != qIP {
				continue
			}
			if qReason != "" && !reasonMatches(ev.Reason, qReason) {
				continue
			}
			if qSearch != "" {
				blob := strings.ToLower(ev.IP + " " + ev.Host + " " + ev.Path + " " + ev.UA + " " + ev.ReasonText + " " + ev.Country)
				if !strings.Contains(blob, qSearch) {
					continue
				}
			}
			rows = append(rows, []string{ev.Time, ev.IP, ev.Country, countryName(ev.Country),
				blockReasonText(ev.Reason), ev.Host, ev.Path, ev.UA})
		}
		for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
			rows[i], rows[j] = rows[j], rows[i]
		}

		name := "blocked-" + beijingDate(nowBeijing()) + ".csv"
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition", "attachment; filename=\""+name+"\"")
		_, _ = w.Write([]byte("\xEF\xBB\xBF"))
		cw := csv.NewWriter(w)
		_ = cw.Write([]string{"时间", "IP", "国家/地区码", "国家/地区", "拦截原因", "访问域名(Host)", "访问路径", "User-Agent"})
		for _, row := range rows {
			_ = cw.Write(row)
		}
		cw.Flush()
		recordAudit(getClientIP(r), "blocks_export", fmt.Sprintf("导出拦截记录 %d 条", len(rows)))
	})

	mux.HandleFunc("/admin/api/ua-stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		from := strings.TrimSpace(r.URL.Query().Get("from"))
		to := strings.TrimSpace(r.URL.Query().Get("to"))
		v := currentStatsView()
		agg := map[string]int64{}
		for date, d := range v.daily {
			if d == nil {
				continue
			}
			if from != "" && date < from {
				continue
			}
			if to != "" && date > to {
				continue
			}
			for k, n := range d.UAClass {
				agg[k] += n
			}
		}
		type kv struct {
			Name  string `json:"name"`
			Count int64  `json:"count"`
		}
		list := make([]kv, 0, len(agg))
		var total int64
		for k, n := range agg {
			list = append(list, kv{k, n})
			total += n
		}
		sort.Slice(list, func(i, j int) bool { return list[i].Count > list[j].Count })
		_ = json.NewEncoder(w).Encode(map[string]any{"items": list, "total": total})
	})
}

func topNMap(m map[string]int64, n int) map[string]int64 {
	if len(m) == 0 {
		return map[string]int64{}
	}
	if n <= 0 || len(m) <= n {
		return m
	}
	type kv struct {
		k string
		v int64
	}
	list := make([]kv, 0, len(m))
	for k, v := range m {
		list = append(list, kv{k, v})
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].v != list[j].v {
			return list[i].v > list[j].v
		}
		return list[i].k < list[j].k
	})
	out := make(map[string]int64, n)
	for i := 0; i < n && i < len(list); i++ {
		out[list[i].k] = list[i].v
	}
	return out
}

func ensureDir(p string) error { return os.MkdirAll(filepath.Dir(p), 0o755) }
FEATURES_GO
  base64 -d <<'CHART_GZ_B64' | gzip -d > "$dir/chart.umd.min.js"
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
CHART_GZ_B64
  cat > "$dir/admin.html" <<'ADMIN_HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>管理后台</title>
<script defer src="/admin/chart.js" onerror="this.onerror=null;this.src='https://cdn.bootcdn.net/ajax/libs/Chart.js/4.4.1/chart.umd.min.js'"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
:root{--bg:#f8fafc;--card:#fff;--bd:#e2e8f0;--t:#0f172a;--t2:#475569;--t3:#94a3b8;--p:#3b82f6;--pd:#2563eb;--ps:#eff6ff;--d:#ef4444;--w:#f59e0b;--ok:#10b981;--mono:Consolas,monospace;--r:12px}
body{background:var(--bg);color:var(--t);font:14px/1.5 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;height:100dvh;overflow:hidden}
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
.mc{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}
.tb{height:64px;background:var(--card);border-bottom:1px solid var(--bd);display:flex;align-items:center;justify-content:space-between;padding:0 24px;flex-shrink:0;z-index:10}
.tb-l{display:flex;align-items:center;gap:16px}
.mmb{display:none;align-items:center;justify-content:center;width:36px;height:36px;border-radius:8px;border:1px solid var(--bd);background:#fff;color:var(--t);cursor:pointer;font-size:18px;transition:.2s}
.mmb:hover{background:#f1f5f9}
.tb-t{font-size:18px;font-weight:600;letter-spacing:-.3px}
.tb-r{display:flex;align-items:center;gap:12px;font-size:13px;color:var(--t2)}
.sc{flex:1;overflow-y:auto;padding:24px;scroll-behavior:smooth}
.pg{display:none}
.pg.on{display:block;animation:fadeUp .3s cubic-bezier(0.16, 1, 0.3, 1) forwards}
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
.card{background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:24px;margin-bottom:24px;box-shadow:0 2px 8px -2px rgba(15,23,42,.04);transition:box-shadow .3s ease, transform .3s ease}
.card:hover{box-shadow:0 8px 24px -4px rgba(15,23,42,.08);transform:translateY(-2px)}
.ch{display:flex;justify-content:space-between;margin-bottom:20px;gap:16px;flex-wrap:wrap;align-items:flex-start}
.ct{font-size:16px;font-weight:600;color:var(--t);letter-spacing:-.2px}
.cd{font-size:13px;color:var(--t3);margin-top:4px}
.g2{display:grid;grid-template-columns:1fr 1fr;gap:24px}
.g2 .card{margin-bottom:0}
.g3{display:grid;grid-template-columns:2fr 1fr;gap:24px}
.sg{display:grid;grid-template-columns:repeat(4,1fr);gap:20px;margin-bottom:24px}
.stc{background:var(--card);border:1px solid var(--bd);border-radius:16px;padding:20px;position:relative;overflow:hidden;transition:.3s}
.stc:hover{transform:translateY(-2px);box-shadow:0 6px 16px -4px rgba(0,0,0,.06)}
.stc::before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;border-radius:4px 0 0 4px}
.stc.b::before{background:#3b82f6}.stc.g::before{background:#10b981}.stc.r::before{background:#ef4444}.stc.o::before{background:#f59e0b}
.sl{font-size:13px;color:var(--t2);font-weight:500}
.sv{font-size:28px;font-weight:700;margin:8px 0 6px;font-variant-numeric:tabular-nums;letter-spacing:-1px;line-height:1.1;color:var(--t)}
.ss{font-size:12px;color:var(--t3);display:flex;justify-content:space-between;align-items:center}
.ss b{font-weight:600;color:var(--t2)}
.fi{margin-bottom:20px}
.fl{display:block;font-size:13px;font-weight:600;margin-bottom:8px;color:var(--t2)}
.inp,.tarea{width:100%;padding:12px 16px;font-size:14px;background:#f8fafc;border:1px solid var(--bd);border-radius:10px;font-family:inherit;outline:none;transition:.2s}
.inp:focus,.tarea:focus{background:#fff;border-color:var(--p);box-shadow:0 0 0 4px var(--ps)}
.inp.m,.tarea{font-family:var(--mono);font-size:13px}
.tarea{resize:vertical;min-height:100px;line-height:1.6}
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
.row{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px 0;border-top:1px solid var(--bd)}
.row:first-child{border-top:0;padding-top:0}
.rl{font-size:14px;font-weight:600;color:var(--t)}
.rd{font-size:13px;color:var(--t3);margin-top:4px}
.sw{position:relative;width:48px;height:28px;flex-shrink:0}
.sw input{opacity:0;width:0;height:0}
.tr2{position:absolute;cursor:pointer;inset:0;background:#cbd5e1;border-radius:99px;transition:.3s cubic-bezier(0.4, 0, 0.2, 1)}
.tr2::after{content:"";position:absolute;height:22px;width:22px;left:3px;bottom:3px;background:#fff;border-radius:50%;transition:.3s cubic-bezier(0.4, 0, 0.2, 1);box-shadow:0 1px 3px rgba(0,0,0,.15)}
.sw input:checked+.tr2{background:var(--p)}
.sw input:checked+.tr2::after{transform:translateX(20px)}
.hint{font-size:12.5px;color:var(--t3);margin-top:8px;line-height:1.6}
.emp{padding:48px 20px;text-align:center;color:var(--t3);font-size:14px}
.emp b{display:block;color:var(--t2);font-size:15px;margin-bottom:6px}
.pill{display:inline-flex;align-items:center;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:500;line-height:1.4;white-space:nowrap}
.pill.pc{background:#fff7ed;color:#c2410c;border:1px solid #fed7aa}
.pill.pw{background:#eff6ff;color:#1d4ed8;border:1px solid #bfdbfe}
.pill.po{background:#fffbeb;color:#b45309;border:1px solid #fde68a}
.pill.pb{background:#fef2f2;color:#b91c1c;border:1px solid #fecaca}
.pill.pu{background:#ecfeff;color:#0e7490;border:1px solid #a5f3fc}
.flg{width:22px;height:16px;object-fit:cover;border-radius:3px;box-shadow:0 0 0 1px rgba(0,0,0,.08);background:#e2e8f0;margin-right:8px;vertical-align:middle}
.flt{display:inline-flex;background:#f1f5f9;padding:4px;border-radius:12px;border:1px solid var(--bd);gap:4px;align-items:center;flex-wrap:wrap}
.filter{border:0;background:transparent;color:var(--t2);padding:8px 16px;border-radius:8px;font-size:13px;font-weight:500;font-family:inherit;cursor:pointer;transition:all .2s ease}
.filter:hover{color:var(--t)}
.filter.on{background:#ffffff;color:var(--pd);font-weight:600;box-shadow:0 2px 4px rgba(0,0,0,.05),0 1px 2px rgba(0,0,0,.05)}
.dr{display:flex;align-items:center;gap:12px;padding:10px 0;flex-wrap:nowrap}
.dn{width:110px;flex-shrink:0;display:flex;align-items:center;gap:6px;font-size:13px;font-weight:500;white-space:nowrap;overflow:hidden}
.dn .tx{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dn.m{font-family:var(--mono);font-size:12px}
.bar{flex:1;height:8px;background:#f1f5f9;border-radius:99px;overflow:hidden;min-width:50px}
.bar>i{display:block;height:100%;border-radius:99px;transition:width .4s ease-out}
.bar.i>i{background:var(--p)}.bar.t>i{background:#10b981}
.dv{width:80px;text-align:right;font-size:13px;font-weight:600;font-variant-numeric:tabular-nums;flex-shrink:0;white-space:nowrap}
.dv span{color:var(--t3);font-size:12px;margin-left:4px;font-weight:normal}
.dbt{width:74px;flex-shrink:0;text-align:right;font-size:11.5px;color:var(--t3);font-weight:normal;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.table-wrap{overflow-x:auto;border-radius:8px;border:1px solid var(--bd);-webkit-overflow-scrolling:touch}
table{width:100%;border-collapse:collapse;text-align:left;min-width:600px}
th{padding:14px 16px;border-bottom:1px solid var(--bd);font-size:12.5px;font-weight:600;color:var(--t2);background:#f8fafc;white-space:nowrap}
td{padding:14px 16px;border-bottom:1px solid var(--bd);font-size:13.5px;color:var(--t2)}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover td{background:#f8fafc}
.cell-v{display:inline}
td[data-label="访问路径"] .cell-v{display:inline-block;max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom}
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
.svg-title{font-size:11.5px;font-weight:600;letter-spacing:.4px;color:var(--t3);text-transform:uppercase;margin:0 0 8px}
.sv-list + .svg-title{margin-top:16px}
.kvr{display:flex;align-items:baseline;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px dashed var(--bd);font-size:13px;min-width:0}
.kvr:last-child{border-bottom:0}
.kvl{color:var(--t3);font-size:12.5px;flex-shrink:0;line-height:1.4}
.kvv{font-weight:600;color:var(--t);text-align:right;min-width:0;word-break:break-word;line-height:1.4;font-variant-numeric:tabular-nums}

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
  .dbt{display:none}
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
  tr{margin-bottom:10px;border-radius:14px}
  td{padding:8px 12px}
  .sc{padding-bottom:max(20px,env(safe-area-inset-bottom))}
  .sb{width:min(280px,85vw)}
  .nav-i{padding:12px 14px;font-size:15px}
  .mbox{border-radius:16px 16px 0 0;max-height:88dvh}
  .mo{align-items:flex-end;padding:0}
}
@media(max-width:380px){
  .sg{grid-template-columns:1fr}
  .sv{font-size:22px}
}

.stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(132px,1fr));gap:12px;margin-bottom:4px}
.stat-b{background:#f8fafc;border:1px solid var(--bd);border-radius:12px;padding:12px 14px}
.stat-b .k{font-size:12px;color:var(--t3);margin-bottom:4px}
.stat-b .v{font-size:19px;font-weight:700;letter-spacing:-.4px;color:var(--t)}
.stat-b .v small{font-size:11px;font-weight:500;color:var(--t3);margin-left:2px}
.rp-g{display:inline-flex;align-items:center;gap:4px;font-size:12px;font-weight:600;padding:3px 8px;border-radius:6px;white-space:nowrap}
.rp-chs{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media(max-width:900px){.rp-chs{grid-template-columns:1fr}}
.rp-ch{border:1px solid var(--bd);border-radius:14px;padding:16px;background:rgba(148,163,184,.06);display:flex;flex-direction:column;gap:12px}
.rp-ch.off{background:rgba(148,163,184,.03)}
.rp-ch-hd{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.rp-ch-t{font-weight:700;font-size:14px;color:var(--t)}
.rp-ch-hd .sw{margin-left:auto}
.rp-ch-kv{display:flex;flex-direction:column;gap:6px;font-size:12.5px}
.rp-ch-kv>div{display:flex;gap:10px;align-items:baseline;min-width:0}
.rp-ch-kv span{color:var(--t3);flex:0 0 62px}
.rp-ch-kv b{font-weight:600;color:var(--t2);font-size:12px;word-break:break-all;font-family:var(--mono,monospace);min-width:0}
.rp-ch-hint{font-size:12px;line-height:1.6;padding:8px 10px;border-radius:8px;background:rgba(245,158,11,.1);border:1px solid rgba(245,158,11,.25);color:#b45309}
.rp-ch-hint.ok{background:rgba(16,185,129,.09);border-color:rgba(16,185,129,.25);color:#047857}
.rp-ch-hint.bad{background:rgba(239,68,68,.08);border-color:rgba(239,68,68,.25);color:#b91c1c}
.rp-g.ok{background:rgba(16,185,129,.12);color:#047857}
.rp-g.bad{background:rgba(239,68,68,.12);color:#b91c1c}
.rp-g.wt{background:rgba(245,158,11,.14);color:#b45309}
.rp-tg{display:inline-block;font-size:11.5px;padding:2px 7px;border-radius:5px;background:#f1f5f9;color:var(--t2);white-space:nowrap}
.rp-tg.auto{background:var(--ps);color:var(--pd)}
.rp-tg.daily{background:rgba(37,99,235,.12);color:#1d4ed8}
.rp-tg.manual{background:rgba(245,158,11,.14);color:#b45309}
.rp-tg.manual-daily{background:rgba(37,99,235,.12);color:#1d4ed8}
.rp-tg.daily-text,.rp-tg.manual-daily-text{background:rgba(124,58,237,.12);color:#6d28d9}
.rp-tg.retry{background:rgba(239,68,68,.1);color:#b91c1c}
.rp-tg.cleanup{background:rgba(148,163,184,.16);color:#64748b}
.rp-row{cursor:pointer}
.rp-row:hover td{background:#f8fafc}
.rp-pre{background:#0f172a;color:#e2e8f0;border-radius:10px;padding:12px;font:12px/1.6 var(--mono);overflow:auto;max-height:300px;white-space:pre-wrap;word-break:break-all;margin-top:6px}
.pgbar{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:14px;font-size:12.5px;color:var(--t3);flex-wrap:wrap}

.tbtn{display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;border-radius:9px;border:1px solid var(--bd);background:var(--card);color:var(--t2);cursor:pointer;font-size:15px;transition:.2s;padding:0}
.tbtn:hover{background:#f1f5f9;color:var(--t)}
html[data-theme="dark"] .tbtn:hover{background:#17243a}

html[data-theme="dark"]{--bg:#0b1220;--card:#111a2b;--bd:#1f2b3d;--t:#e6edf7;--t2:#a8b6c9;--t3:#71809a;--p:#3b82f6;--pd:#7db2ff;--ps:#152742;--d:#f87171;--w:#fbbf24;--ok:#34d399}
html[data-theme="dark"] body{background:var(--bg)}
html[data-theme="dark"] .card,html[data-theme="dark"] .tb,html[data-theme="dark"] .sb,html[data-theme="dark"] .stc{background:var(--card)}
html[data-theme="dark"] .card:hover{box-shadow:0 4px 16px -2px rgba(0,0,0,.45)}
html[data-theme="dark"] .btn.g{background:var(--card);color:var(--t2);border-color:var(--bd)}
html[data-theme="dark"] .btn.g:hover{background:#17243a;color:var(--t)}
html[data-theme="dark"] .btn.d{background:#2a1418;border-color:#4c2027;color:#fca5a5}
html[data-theme="dark"] .btn.d:hover{background:#361a1f}
html[data-theme="dark"] .inp,html[data-theme="dark"] .tarea{background:#0e1726;color:var(--t);border-color:var(--bd)}
html[data-theme="dark"] .inp:focus,html[data-theme="dark"] .tarea:focus{background:#0e1726;border-color:var(--p);box-shadow:0 0 0 4px rgba(59,130,246,.15)}
html[data-theme="dark"] th{background:#0e1726;color:var(--t2)}
html[data-theme="dark"] td{color:var(--t2)}
html[data-theme="dark"] tbody tr:hover td{background:#152136}
html[data-theme="dark"] .flt{background:#0e1726}
html[data-theme="dark"] .filter{color:var(--t2)}
html[data-theme="dark"] .filter.on{background:#1b2a42;color:#9ec5ff}
html[data-theme="dark"] .mo{background:rgba(2,6,15,.72)}
html[data-theme="dark"] .mbox{background:var(--card)}
html[data-theme="dark"] .mh,html[data-theme="dark"] .kv,html[data-theme="dark"] .kvr{border-color:var(--bd)}
html[data-theme="dark"] .mcl,html[data-theme="dark"] .mmb{background:#17243a;color:var(--t2)}
html[data-theme="dark"] .bar{background:#1b2a42}
html[data-theme="dark"] .nav-i:hover{background:#17243a;color:var(--t)}
html[data-theme="dark"] .nav-i.on{background:var(--ps);color:#9ec5ff}
html[data-theme="dark"] tr{border-color:var(--bd)}
html[data-theme="dark"] .table-wrap{border-color:var(--bd)}
html[data-theme="dark"] .pill.pc{background:#3a2415;color:#fdba74;border-color:#5a3a1d}
html[data-theme="dark"] .pill.pw{background:#12274a;color:#93c5fd;border-color:#1e3f70}
html[data-theme="dark"] .pill.po{background:#3a2a0d;color:#fcd34d;border-color:#5c4416}
html[data-theme="dark"] .pill.pb{background:#331519;color:#fca5a5;border-color:#57242b}
html[data-theme="dark"] .pill.pu{background:#0d2b33;color:#67e8f9;border-color:#164e5c}
html[data-theme="dark"] .pill.pg{background:#0f2d22;color:#6ee7b7;border-color:#1b5340}
html[data-theme="dark"] .stat-b{border-color:var(--bd)}
html[data-theme="dark"] .rp-pre{background:#0a1220;color:#c7d4e6}
html[data-theme="dark"] .act-tag{background:#17243a;color:var(--t2)}
html[data-theme="dark"] .hm-cell{background:#0e1726}
html[data-theme="dark"] .dr:hover{background:transparent}

.act-tag{display:inline-flex;align-items:center;padding:2px 9px;border-radius:6px;background:#f1f5f9;color:var(--t2);font-size:12px;font-weight:500;white-space:nowrap}
.act-tag.warn{background:#fff7ed;color:#c2410c}
html[data-theme="dark"] .act-tag.warn{background:#3a2415;color:#fdba74}

.tl{display:grid;gap:0;margin-top:4px}
.tl-i{display:flex;gap:12px;padding:11px 0;border-bottom:1px dashed var(--bd);font-size:13.5px}
.tl-i:last-child{border-bottom:0}
.tl-d{width:10px;height:10px;border-radius:50%;margin-top:6px;flex-shrink:0}
.tl-i.pass .tl-d{background:var(--ok)}
.tl-i.block .tl-d{background:var(--d)}
.tl-i.skip .tl-d{background:var(--t3)}
.tl-i.skip{opacity:.45}
.tl-n{font-weight:600;color:var(--t);min-width:96px;flex-shrink:0}
.tl-v{color:var(--t2);flex:1;word-break:break-word}
.tl-res{margin-top:14px;padding:12px 14px;border-radius:10px;font-size:13.5px;font-weight:600;display:flex;align-items:center;gap:8px}
.tl-res.pass{background:#ecfdf5;color:#047857;border:1px solid #b7e8d5}
.tl-res.block{background:#fef2f2;color:#b91c1c;border:1px solid #fbd5d5}
html[data-theme="dark"] .tl-res.pass{background:#0d2b22;color:#6ee7b7;border-color:#1b5340}
html[data-theme="dark"] .tl-res.block{background:#331519;color:#fca5a5;border-color:#57242b}

.hm{display:grid;grid-template-columns:56px repeat(24,1fr);gap:3px;font-size:11px;align-items:center;min-width:0}
.hm-h{color:var(--t3);text-align:center;font-variant-numeric:tabular-nums;font-size:10.5px;overflow:hidden}
.hm-d{color:var(--t2);font-size:11.5px;white-space:nowrap;font-variant-numeric:tabular-nums}
.hm-cell{height:22px;border-radius:4px;background:#f1f5f9;position:relative;cursor:default;transition:transform .12s ease}
.hm-cell:hover{transform:scale(1.12);z-index:2;box-shadow:0 2px 8px rgba(0,0,0,.18)}
.hm-wrap{overflow-x:auto;padding-bottom:4px}
.hm-legend{display:flex;align-items:center;gap:6px;margin-top:12px;font-size:11.5px;color:var(--t3);justify-content:flex-end}
.hm+.hm{margin-top:8px}
.hm-legend i{width:16px;height:10px;border-radius:2px;display:inline-block}

.set-tabs{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:20px}
.set-tab{padding:8px 18px;border-radius:9px;border:1px solid var(--bd);background:var(--card);color:var(--t2);font-size:13.5px;font-weight:500;cursor:pointer;transition:.15s}
.set-tab:hover{color:var(--t);border-color:#c9d6e8}
.set-tab.on{background:var(--p);border-color:var(--p);color:#fff}
html[data-theme="dark"] .set-tab:hover{border-color:#33507e}
.bk-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:20px;max-width:960px}
.bk-card{display:flex;flex-direction:column;margin-bottom:0;padding:22px;transition:box-shadow .2s,transform .2s,border-color .2s}
.bk-card:hover{transform:translateY(-2px);border-color:#c9d6e8;box-shadow:0 8px 24px rgba(15,23,42,.08)}
html[data-theme="dark"] .bk-card:hover{border-color:#33507e;box-shadow:0 8px 24px rgba(0,0,0,.35)}
.bk-ic{width:44px;height:44px;border-radius:12px;display:flex;align-items:center;justify-content:center;margin-bottom:14px}
.bk-ic svg{width:21px;height:21px}
.bk-ic-a{background:rgba(59,130,246,.1);color:var(--p)}
.bk-ic-b{background:rgba(16,185,129,.12);color:#0ea371}
.bk-ic-c{background:rgba(245,158,11,.14);color:#d97706}
html[data-theme="dark"] .bk-ic-b{color:#34d399}
html[data-theme="dark"] .bk-ic-c{color:#fbbf24}
.bk-t{font-size:15px;font-weight:600;color:var(--t);margin-bottom:6px}
.bk-d{font-size:12.5px;line-height:1.7;color:var(--t3);flex:1}
.bk-btn{margin-top:16px;align-self:flex-start;gap:7px;padding:9px 16px;font-size:13px}
.bk-btn .bk-dl{width:14px;height:14px}

.ua-raw{margin-top:10px;padding:10px 12px;background:var(--bg);border:1px solid var(--bd);border-radius:8px}
.ua-raw-h{font-size:12px;color:var(--t2);font-weight:600;margin-bottom:8px}
.ua-raw-i{display:flex;gap:10px;align-items:baseline;padding:4px 0;font-size:12px;border-top:1px dashed var(--bd)}
.ua-raw-i:first-of-type{border-top:0}
.ua-raw-n{min-width:52px;text-align:right;color:var(--t3);font-variant-numeric:tabular-nums;flex-shrink:0}
.ua-raw-u{font-family:ui-monospace,Menlo,Consolas,monospace;color:var(--t2);word-break:break-all;font-size:11.5px}

.pgbar{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-top:14px;font-size:12.5px;color:var(--t3);flex-wrap:wrap}
.pgbar .acts{margin-top:0}
@media(max-width:600px){.hm{gap:2px}.hm-cell{height:16px}.hm-h{font-size:9.5px}}
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
<li><button class="nav-i" data-t="speedm"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2L3 14h7l-1 8 10-12h-7l1-8z"/></svg>测速管理</button></li>
<li><button class="nav-i" data-t="blocks"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/></svg>拦截记录</button></li>
<li><button class="nav-i" data-t="audit"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 11l3 3 8-8"/><path d="M20 12v6a2 2 0 01-2 2H6a2 2 0 01-2-2V6a2 2 0 012-2h9"/></svg>操作记录</button></li>
<li><button class="nav-i" data-t="report"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3v12"/><path d="M7 10l5-7 5 7"/><path d="M4 17v2a2 2 0 002 2h12a2 2 0 002-2v-2"/></svg>数据上报</button></li>
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
<div class="tb-r"><button type="button" class="tbtn" id="themeBtn" title="切换深色/浅色" aria-label="切换主题">◐</button></div>
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
  <!-- 1. 请求 -->
  <div class="stc b"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 14l4-4 4 4 5-6"/></svg>区间请求</div><div class="sv" id="ovReq">-</div><div class="ss">日均 <b id="ovAvgReq">-</b></div></div>
  <!-- 2. 流量 -->
  <div class="stc g"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1.06 6.69 3"/></svg>区间流量</div><div class="sv" id="ovBytes">-</div><div class="ss">日均 <b id="ovAvgBytes">0 B</b></div></div>
  <!-- 3. IP -->
  <div class="stc o"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></svg>独立 IP</div><div class="sv" id="uniqueIPs">-</div><div class="ss">实时统计</div></div>
  <!-- 4. 拦截 -->
  <div class="stc r"><div class="sl"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/></svg>拦截次数</div><div class="sv" id="ovBlocked" style="color:var(--d)">-</div><div class="ss">全部拦截类型</div></div>
</div>

<!-- 流量全宽图 -->
<div class="card">
  <div class="ch"><div><h2 class="ct" id="ovByteTitle">流量趋势</h2><div class="cd" id="ovByteDesc">今日 00:00–23:00 各时段整机端口流量（含其他进程，仅供参考）</div></div></div>
  <div style="position:relative;height:240px"><canvas id="miniByteChart"></canvas></div>
</div>

<!-- 请求全宽图 -->
<div class="card">
  <div class="ch"><div><h2 class="ct" id="ovReqTitle">请求趋势</h2><div class="cd" id="ovReqDesc">今日 00:00–23:00 各时段请求数（北京时间）</div></div></div>
  <div style="position:relative;height:220px"><canvas id="miniTrendChart"></canvas></div>
</div>

<!-- 底部并排 -->
<div class="g2">
  <div class="card"><div class="ch"><div><h2 class="ct">系统信息</h2></div></div><div id="sysInfo"></div></div>
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
<div class="ch"><div><h2 class="ct" id="tfByteTitle">流量消耗趋势</h2><div class="cd" id="tfByteDesc">仅统计经本服务转发的内容流量（不含系统与其他进程）</div></div></div>
<div style="position:relative;height:260px"><canvas id="byteChart"></canvas></div>
</div>

<div class="card">
<div class="ch"><div><h2 class="ct" id="tfReqTitle">请求量趋势</h2><div class="cd" id="tfReqDesc">按天统计请求次数</div></div></div>
<div style="position:relative;height:260px"><canvas id="reqChart"></canvas></div>
</div>
<div class="card" style="margin-top:0">
<div class="ch"><div><h2 class="ct" id="tfHostTitle">上游主机趋势</h2><div class="cd" id="tfHostDesc">筛选区间内访问最多的上游</div></div></div>
<div style="position:relative;height:240px"><canvas id="hostChart"></canvas></div>
</div>
<div class="g2" style="margin-top:22px">
<div class="card"><div class="ch"><div><h2 class="ct">请求 IP 排行</h2><div class="cd">按当前时间范围汇总</div></div></div><div id="ipDist"></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">地区来源分布</h2><div class="cd">按当前时间范围汇总</div></div></div><div id="regionDist"></div></div>
</div>
<div class="g2" style="margin-top:22px">
<div class="card"><div class="ch"><div><h2 class="ct">客户端分布</h2><div class="cd">按 User-Agent 归类 · 点击行查看原始 UA 采样，识别「其他」里的请求</div></div></div><div id="uaDist"></div></div>
<div class="card"><div class="ch"><div><h2 class="ct">时段热力图</h2><div class="cd" id="hourHeatSub">粒度随时间范围变化：单日按小时 · ≤31 天按天 · 更长按月</div></div></div><div class="hm-wrap" id="hourHeat"></div></div>
</div>
</section>
<section id="realtime" class="pg">
<div class="sg" style="margin-bottom:18px">
  <div class="stc b"><div class="sl">当前并发</div><div class="sv" id="rtConc">-</div><div class="ss">正在处理的请求</div></div>
  <div class="stc g"><div class="sl">每秒请求</div><div class="sv" id="rtRps">-</div><div class="ss">最近 1 秒</div></div>
  <div class="stc" style="box-shadow: inset 4px 0 0 #f59e0b"><div class="sl" style="color:#f59e0b">↓ 下行</div><div class="sv" id="rtRx">-</div><div class="ss">从上游接收的速率</div></div>
  <div class="stc" style="box-shadow: inset 4px 0 0 #8b5cf6"><div class="sl" style="color:#8b5cf6">↑ 上行</div><div class="sv" id="rtTx">-</div><div class="ss">发送给用户的速率</div></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct">各 IP 实时网速</h2><div class="cd">最近 1 秒内有流量的 IP（按总速率排序，最多 20 个）</div></div></div>
<div id="rtIPSpeeds" style="display:grid;gap:8px;margin-bottom:8px"><div style="color:var(--t3);font-size:13px;padding:8px 0">等待数据…</div></div>
</div>
<div class="card">
<div class="ch"><div><h2 class="ct">实时请求流</h2><div class="cd" id="rtStatus">进入页面才开始收集，退出即清空</div></div></div>
<div class="table-wrap"><table><thead><tr><th>时间</th><th>IP</th><th>地区</th><th>上游主机</th><th>路径</th></tr></thead><tbody id="rtTable"></tbody></table></div>
</div>
</section>
<section id="blocks" class="pg">
<div class="card">
<div class="ch"><div><h2 class="ct">拦截记录</h2><div class="cd">因黑名单、地区、上游/访问域名白名单或 UA 策略被拒绝的请求 · 服务端分页 · 每 5 秒自动刷新</div></div></div>
<div style="display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px;align-items:center">
  <input id="blkQ" class="inp m" type="search" placeholder="搜索 IP / 域名 / 路径 / UA" style="max-width:220px">
  <select id="blkReason" class="inp m" style="width:auto;max-width:190px">
    <option value="">全部原因</option>
    <option value="cn">地区限制</option>
    <option value="whitelist">上游域名未授权</option>
    <option value="host">访问域名未授权（全部）</option>
    <option value="host_ip">└ IP / localhost 直连</option>
    <option value="host_deny">└ 非白名单域名</option>
    <option value="ban">IP 黑名单</option>
    <option value="ua">UA 不允许</option>
    <option value="login_fail">登录失败</option>
  </select>
  <input id="blkIP" class="inp m" type="text" placeholder="精确 IP" style="max-width:150px">
  <button type="button" class="btn b s" id="blkFilterBtn">筛选</button>
  <button type="button" class="btn g s" id="blkResetBtn">重置</button>
  <span id="blkCount" style="font-size:12.5px;color:var(--t3)"></span>
  <span style="flex:1"></span>
  <button type="button" class="btn g s" id="blkExport">导出 CSV</button>
</div>
<div id="blkReasonStats" style="display:flex;flex-wrap:wrap;gap:8px;margin:-4px 0 14px"></div>
<div class="table-wrap"><table><thead><tr><th>时间</th><th>IP 地址</th><th>国家/地区</th><th>访问域名</th><th>拦截原因</th><th>访问路径</th><th>User-Agent</th><th>操作</th></tr></thead><tbody id="blockTable"></tbody></table></div>
  <div class="pgbar">
    <span id="blkPageInfo"></span>
    <div style="display:flex;gap:8px">
      <button class="btn g s" id="blkPrev">上一页</button>
      <button class="btn g s" id="blkNext">下一页</button>
    </div>
  </div>
</div>
</section>

<section id="audit" class="pg">
<div class="card">
  <div class="ch">
    <div><div class="cd" style="font-size:13px;color:var(--t2)">登录、改密、保存配置、拉黑 IP、上报与清空等后台动作留痕 · 保留最近 1000 条</div></div>
    <button type="button" class="btn g s" id="auditRefresh">刷新</button>
  </div>
  <div style="display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px;align-items:center">
    <select id="auditAction" class="inp m" style="width:auto;max-width:180px">
      <option value="">全部动作</option>
      <option value="login">登录</option>
      <option value="change_password">修改密码</option>
      <option value="save_config">保存配置</option>
      <option value="ban_ip">拉黑 IP</option>
      <option value="clear_stats">清空统计</option>
      <option value="speed_create">生成测速链接</option>
      <option value="speed_delete">删除测速链接</option>
      <option value="report_test">手动上报</option>
      <option value="report_retry">补传上报</option>
      <option value="report_clear">清空上报快照</option>
      <option value="report_clear_records">清空上报记录</option>
      <option value="backup_db">下载备份</option>
      <option value="config_export">导出配置</option>
      <option value="config_import">导入配置</option>
      <option value="blocks_export">导出拦截记录</option>
    </select>
    <span id="auditCount" style="font-size:12.5px;color:var(--t3)"></span>
  </div>
  <div class="table-wrap">
    <table><thead><tr><th>时间</th><th>动作</th><th>详情</th><th>来源 IP</th></tr></thead><tbody id="auditBody"></tbody></table>
  </div>
  <div class="pgbar">
    <span id="auditPageInfo"></span>
    <div style="display:flex;gap:8px">
      <button class="btn g s" id="auditPrev">上一页</button>
      <button class="btn g s" id="auditNext">下一页</button>
    </div>
  </div>
</div>
</section>

<section id="speedm" class="pg">
  <div class="card" style="margin-bottom:24px">
    <div class="ch">
      <div><h2 class="ct">测速链接</h2><div class="cd">生成可视化测速页链接（类似 Speedtest）· 链接 7 天后自动过期，单文件占 1 次使用次数</div></div>
      <div style="display:flex;gap:10px;align-items:center">
        <input id="spdUses" class="inp m" type="number" min="1" max="10000" value="5" style="width:90px" title="可使用次数">
        <button class="btn b" id="spdCreate">生成链接</button>
      </div>
    </div>
    <div id="spdList" style="display:grid;gap:10px"></div>
  </div>

  <div class="card" style="margin-bottom:0">
    <div class="ch"><div><h2 class="ct">测速结果</h2><div class="cd">最多保留最近 100 条 · 重启不丢失</div></div></div>
    <div class="table-wrap"><table><thead><tr><th>时间</th><th>IP</th><th>延迟</th><th>抖动</th><th>下载</th><th>上传</th><th>评级</th></tr></thead><tbody id="spdResBody"></tbody></table></div>
  </div>
</section>
<section id="report" class="pg">
<div class="card">
  <div class="ch"><div><h2 class="ct">定时任务总览</h2><div class="cd">两条通道各自独立、互不影响：任意一条未配置完整（地址 / 模板）都不会执行，也不会影响另一条</div></div></div>
  <div class="rp-chs">
    <div class="rp-ch" id="chApiCard">
      <div class="rp-ch-hd">
        <span class="rp-ch-t">📤 接口上报</span>
        <span id="chApiState" class="rp-g wt">读取中</span>
        <label class="sw" title="开启 / 关闭每小时接口上报"><input type="checkbox" id="reportOn"><span class="tr2"></span></label>
      </div>
      <div class="rp-ch-kv">
        <div><span>频率</span><b>每小时整点（:00:05）</b></div>
        <div><span>接收地址</span><b id="chApiUrl">—</b></div>
        <div><span>下次执行</span><b id="chApiNext">—</b></div>
      </div>
      <div class="rp-ch-hint" id="chApiHint">—</div>
    </div>
    <div class="rp-ch" id="chDailyCard">
      <div class="rp-ch-hd">
        <span class="rp-ch-t">🔔 通知推送</span>
        <span id="chDailyState" class="rp-g wt">读取中</span>
        <label class="sw" title="开启 / 关闭每日日报推送"><input type="checkbox" id="dailyTmplOn"><span class="tr2"></span></label>
      </div>
      <div class="rp-ch-kv">
        <div><span>频率</span><b>每天 00:10</b></div>
        <div><span>发送地址</span><b id="chDailyUrl">—</b></div>
        <div><span>下次执行</span><b id="chDailyNext">—</b></div>
      </div>
      <div class="rp-ch-hint" id="chDailyHint">—</div>
    </div>
  </div>
</div>

<div class="card">
  <div class="ch"><div><h2 class="ct">投递统计</h2><div class="cd">最近 24 小时的发送结果与待补传队列</div></div></div>
  <div class="stat-grid" id="rpStats">
    <div class="stat-b"><div class="k">近 24 小时成功</div><div class="v" id="rpOk">—</div></div>
    <div class="stat-b"><div class="k">近 24 小时失败</div><div class="v" id="rpFail">—</div></div>
    <div class="stat-b"><div class="k">成功率</div><div class="v" id="rpRate">—</div></div>
    <div class="stat-b"><div class="k">待补传队列</div><div class="v" id="rpQueue">—<small>批</small></div></div>
    <div class="stat-b"><div class="k">最近成功</div><div class="v" id="rpLast" style="font-size:13px;font-weight:600">—</div></div>
    <div class="stat-b"><div class="k">记录保留</div><div class="v">30<small>天</small></div></div>
  </div>
</div>

<div class="card">
  <div class="ch"><div><h2 class="ct">接口上报</h2><div class="cd">每小时整点把 JSON 数据发送到接收地址；服务器备注会随每批数据一起发出，便于接收端区分多台机器 · 与「通知推送」相互独立</div></div></div>
  <div class="fi"><label class="fl">接收地址</label><div class="hint" style="margin-bottom:8px">接口上报通道的接收端地址，留空则不上报，例如 https://api.example.com/collect</div><input id="reportUrl" class="inp m" type="url" placeholder="https://api.example.com/collect"></div>
  <div class="fi"><label class="fl">Bearer Token</label><div class="hint" style="margin-bottom:8px">留空则不带 Authorization 头</div><input id="reportToken" class="inp m" type="text" placeholder="可选"></div>
  <div class="fi"><label class="fl">服务器备注</label><div class="hint" style="margin-bottom:8px">如「香港节点」「家里宽带」</div><input id="reportNote" class="inp m" type="text" maxlength="60" placeholder="可选，如：香港节点"></div>
  <div class="acts" style="display:flex;gap:10px;flex-wrap:wrap">
    <button class="btn b" id="saveReport">保存配置</button>
    <button class="btn g" id="testReport">立即上报一次</button>
    <button class="btn g" id="reportRetry">补传队列</button>
    <button class="btn g" id="reportClear">清空快照</button>
    <button class="btn d" id="reportClearQueue">清空队列</button>
  </div>
  <div id="reportMsg" style="margin-top:12px;font-size:12.5px;color:var(--t3);word-break:break-all"></div>
</div>

<div class="card">
  <div class="ch"><div><h2 class="ct">通知推送（昨日日报）</h2><div class="cd">每日 00:10 把昨日统计推送到 Telegram / 微信 / 钉钉 / Bark 等 Webhook · 开关在页面顶部「定时任务总览」中控制，与接口上报互不影响</div></div></div>
  <div class="fi"><label class="fl">日报发送地址</label><div class="hint" style="margin-bottom:8px">通知 Webhook 地址，如 Telegram Bot：https://api.telegram.org/bot&lt;Token&gt;/sendMessage</div><input id="dailyTmplUrl" class="inp m" type="url" placeholder="https://api.telegram.org/bot123:ABC/sendMessage"></div>
  <div class="fi"><label class="fl">日报 Token</label><div class="hint" style="margin-bottom:8px">以 Bearer Authorization 头随请求发送；Telegram 不需要，留空即可</div><input id="dailyTmplToken" class="inp m" type="text" placeholder="可选"></div>
  <div class="fi"><label class="fl">日报 Content-Type</label><div class="hint" style="margin-bottom:8px">请求体类型：Telegram 用 application/json；Bark 用 text/plain；钉钉/企微机器人用 application/json</div><select id="dailyTmplType" class="inp m" style="width:auto"><option value="text/plain">text/plain</option><option value="text/markdown">text/markdown</option><option value="application/json">application/json</option><option value="application/x-www-form-urlencoded">application/x-www-form-urlencoded</option></select></div>
  <div class="fi"><label class="fl">消息模板（自定义格式）</label><div class="hint" style="margin-bottom:8px">占位符：{{date}}、{{node}}、{{note}}、{{requests}}、{{up}}、{{down}}、{{total}}、{{blocked}}、{{blocked_cn}}、{{blocked_wl}}、{{blocked_ban}}、{{blocked_ua}}、{{ips_top}}、{{ip_bytes_top}}、{{hosts_top}}、{{countries_top}}（*_top 挤在一行）；{{ips_top_lines}}、{{ip_bytes_top_lines}}、{{hosts_top_lines}}、{{countries_top_lines}}（每项一行，更适合 IM 展示）。模板为 JSON 时（如 Telegram）值会自动转义，可放心使用多行占位符；配合 "parse_mode":"HTML" 可用 &lt;b&gt;、&lt;code&gt; 标签美化</div>
    <div class="hint" style="margin-bottom:8px">模板留空时定时任务<span style="color:#b45309;font-weight:600">不会自动执行</span>（手动点「发送昨日统计」仍可用内置默认模板）</div>
    <textarea id="dailyTmpl" class="inp m" rows="8" style="width:100%;font-family:var(--mono,monospace);font-size:12.5px" placeholder="粘贴自定义模板，留空则定时任务不执行"></textarea></div>
  <div class="acts" style="display:flex;gap:10px;flex-wrap:wrap">
    <button class="btn b" id="saveTmpl">保存配置</button>
    <button class="btn g" id="dailyReport">发送昨日统计</button>
  </div>
  <div id="tmplMsg" style="margin-top:12px;font-size:12.5px;color:var(--t3);word-break:break-all"></div>
</div>

<div class="card">
  <div class="ch">
    <div><h2 class="ct">上传记录</h2><div class="cd">每一次 HTTP 投递的结果（自动 / 手动 / 补传）· 保留最近 30 天 · 点击行查看详情</div></div>
    <button type="button" class="btn g s" id="rpRefresh">刷新</button>
  </div>
  <div style="display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px;align-items:center">
    <input id="rpQ" class="inp m" type="search" placeholder="搜索批次 / 地址 / 错误" style="max-width:240px">
    <select id="rpResult" class="inp m" style="width:auto;max-width:150px">
      <option value="">全部结果</option>
      <option value="ok">成功</option>
      <option value="fail">失败</option>
    </select>
    <select id="rpTrigger" class="inp m" style="width:auto;max-width:150px">
      <option value="">全部触发方式</option>
      <option value="auto">整点自动</option>
      <option value="daily">昨日日报</option>
      <option value="daily-text">昨日日报(自定义)</option>
      <option value="manual">手动</option>
      <option value="manual-daily">手动日报</option>
      <option value="manual-daily-text">手动日报(自定义)</option>
      <option value="retry">补传</option>
      <option value="cleanup">队列清理</option>
    </select>
    <span id="rpCount" style="font-size:12.5px;color:var(--t3)"></span>
    <span style="flex:1"></span>
    <button type="button" class="btn d s" id="rpClearRec">清空记录</button>
  </div>
  <div class="table-wrap"><table><thead><tr><th>时间</th><th>触发</th><th>结果</th><th>数据周期</th><th>请求</th><th>下行</th><th>上行</th><th>耗时</th><th>批次</th></tr></thead><tbody id="rpBody"></tbody></table></div>
  <div class="pgbar">
    <span id="rpPageInfo"></span>
    <div style="display:flex;gap:8px">
      <button class="btn g s" id="rpPrev">上一页</button>
      <button class="btn g s" id="rpNext">下一页</button>
    </div>
  </div>
</div>
</section>
<section id="settings" class="pg">
<div class="set-tabs" role="tablist">
  <button type="button" class="set-tab on" data-st="acl">访问控制</button>
  <button type="button" class="set-tab" data-st="base">网关与账号</button>
  <button type="button" class="set-tab" data-st="rule">规则测试</button>
  <button type="button" class="set-tab" data-st="ops">备份迁移</button>
</div>

<div class="set-pane" id="pane-acl">
  <div class="card" style="margin-bottom:0;">
    <div class="ch"><div><h2 class="ct">安全与访问控制</h2><div class="cd">代理转发的准入规则；保存后立即生效并预编译匹配</div></div></div>
    <div class="row"><div><div class="rl">仅允许中国大陆 IP</div><div class="rd">非大陆来源将被拒绝</div></div><label class="sw"><input type="checkbox" id="chinaOnly"><span class="tr2"></span></label></div>
    <div class="fi"><label class="fl">UA 白名单</label><div class="hint" style="margin-bottom:8px">每行一个关键字，留空表示不限制</div><textarea id="allowedUAs" class="tarea" placeholder="Infuse&#10;Emby"></textarea></div>
    <div class="row"><div><div class="rl">禁止 IP 直连 / 访问域名白名单</div><div class="rd">开启后，只有通过下方允许的域名访问代理才被放行；用服务器 IP、localhost 或其它域名访问一律返回 403。管理后台 /admin/、健康检查 /health 与测速链接不受限制，不会被锁在门外</div></div><label class="sw"><input type="checkbox" id="hostGuardOn"><span class="tr2"></span></label></div>
    <div class="fi"><label class="fl">允许访问的域名</label><div class="hint" style="margin-bottom:8px">每行一个，支持 *.example.com 通配；也可直接粘贴完整网址（会自动忽略 https:// 与路径）。留空表示只禁止 IP / localhost 直连，任意域名均可访问。前面挂了 Nginx / CDN 时，请回传 X-Forwarded-Host 或保留原始 Host，否则后端看到的会是回环 IP。注意：只填根域不会放行子域，用到的子域请逐个添加或改用通配</div><textarea id="allowedHosts" class="tarea" placeholder="emby.example.com&#10;*.example.com"></textarea><div class="hint" id="curHostHint" style="margin-top:8px;color:var(--pd)">当前访问域名：加载中…</div></div>
    <div class="fi"><label class="fl">上游域名白名单（可反代到的目标）</label><div class="hint" style="margin-bottom:8px">每行一个域名，支持根域名匹配；限制路径里能反代到哪些上游主机，与上面的访问域名无关</div><textarea id="whitelist" class="tarea" placeholder="example.com&#10;*.cdn.example.com"></textarea></div>
    <div class="fi"><label class="fl">IP 黑名单</label><div class="hint" style="margin-bottom:8px">每行一个 IP，支持 CIDR</div><textarea id="banList" class="tarea" placeholder="1.1.1.1"></textarea></div>
    <div class="fi"><label class="fl">后台访问来源</label><div class="hint" style="margin-bottom:8px">留空表示不限制；填写后只有这些 IP/CIDR 能打开管理后台（不影响代理转发）。保存时会校验本机 IP 是否在列表内，避免把自己锁在门外。</div><textarea id="adminAllow" class="tarea" style="min-height:70px" placeholder="192.168.1.0/24&#10;203.0.113.8"></textarea></div>
    <div class="acts"><button class="btn b" id="saveAll" style="width:100%">保存设置</button></div>
  </div>
</div>

<div class="set-pane" id="pane-base" style="display:none">
  <div class="g2">
    <div class="card" style="margin-bottom:0;">
      <div class="ch"><div><h2 class="ct">基础服务设置</h2></div></div>
      <div class="fi"><label class="fl">监听端口</label><div style="display:flex;gap:12px;align-items:center"><input id="portInput" class="inp m" type="number" style="max-width:140px"><button class="btn b" id="savePort">保存并重启监听</button></div></div>
    </div>

    <div class="card" style="border-color:#fecaca;margin-bottom:0;">
      <div class="ch"><div><h2 class="ct" style="color:var(--d)">账号与数据</h2></div></div>
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
</div>

<div class="set-pane" id="pane-rule" style="display:none">
  <div class="g2">
    <div class="card" style="margin-bottom:0">
      <div class="ch"><div><h2 class="ct">规则命中测试</h2><div class="cd">按当前配置跑一遍判定链，调白名单/UA 时不用拿播放器反复试</div></div></div>
      <div class="fi"><label class="fl">访问域名 / Host</label><div class="hint" style="margin-bottom:8px">浏览器地址栏里的域名，对应「访问域名白名单」；留空则用当前后台访问域名</div><input id="rtAccessHost" class="inp m" placeholder="例如 emby.example.com:8520"></div>
      <div class="fi"><label class="fl">来源 IP</label><input id="rtIP" class="inp m" placeholder="留空则用当前浏览器出口 IP"></div>
      <div class="fi"><label class="fl">目标上游</label><input id="rtHost" class="inp m" placeholder="例如 emby.example.com:8096"></div>
      <div class="fi"><label class="fl">User-Agent</label><textarea id="rtUA" class="tarea" style="min-height:70px" placeholder="粘贴客户端的 UA，例如 Infuse/7.8 (iPhone; iOS 17.0)"></textarea></div>
      <div class="acts"><button class="btn b" id="rtRun">开始测试</button><button class="btn g" id="rtFillHost">填入当前域名</button><button class="btn g" id="rtFillUA">填入本浏览器 UA</button></div>
      <div id="rtResult" style="margin-top:6px"></div>
    </div>

    <div class="card" style="margin-bottom:0;align-self:start">
      <div class="ch"><div><h2 class="ct">判定链顺序</h2><div class="cd">请求按以下顺序依次校验，命中即拦截</div></div></div>
      <div class="tl" id="rtChain">
        <div class="tl-i block"><div class="tl-d"></div><div class="tl-n">访问域名白名单</div><div class="tl-v">请求 Host 必须在允许列表内；开启后禁止 IP / localhost 直连</div></div>
        <div class="tl-i block"><div class="tl-d"></div><div class="tl-n">IP 黑名单</div><div class="tl-v">来源 IP 精确匹配或命中 CIDR 段</div></div>
        <div class="tl-i block"><div class="tl-d"></div><div class="tl-n">UA 白名单</div><div class="tl-v">客户端 UA 需包含白名单关键字，空=不限制</div></div>
        <div class="tl-i block"><div class="tl-d"></div><div class="tl-n">地区限制</div><div class="tl-v">开启「仅允许中国大陆 IP」时，非大陆来源被拒</div></div>
        <div class="tl-i block"><div class="tl-d"></div><div class="tl-n">上游域名白名单</div><div class="tl-v">路径中的目标域名需匹配白名单（支持根域名），空=不限制</div></div>
        <div class="tl-i pass"><div class="tl-d"></div><div class="tl-n">放行转发</div><div class="tl-v">全部通过后反代到上游，并计入流量统计</div></div>
      </div>
      <div class="hint" style="margin-top:14px">顺序与真实请求、规则测试完全一致（先准入后内容、先便宜后昂贵）。例外路径（后台 /admin、监控 /health、测速 /speed、首页与静态资源）不参与此链，保证后台始终可用。被拦截的请求可在「拦截记录」页查看明细，操作变更可在「操作记录」页追溯。</div>
    </div>
  </div>
</div>

<div class="set-pane" id="pane-ops" style="display:none">
  <div class="bk-grid">
    <div class="card bk-card">
      <div class="bk-ic bk-ic-a"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v6c0 1.66 3.58 3 8 3s8-1.34 8-3V5"/><path d="M4 11v6c0 1.66 3.58 3 8 3s8-1.34 8-3v-6"/></svg></div>
      <div class="bk-t">数据库快照</div>
      <div class="bk-d">在线导出 bolt 库，包含配置、统计数据与账号信息，可直接用于完整恢复或整机搬迁。</div>
      <button class="btn g bk-btn" id="btnBackup"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="bk-dl"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>下载 .db</button>
    </div>
    <div class="card bk-card">
      <div class="bk-ic bk-ic-b"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><polyline points="12 18 12 12"/><polyline points="9 15 12 18 15 15"/></svg></div>
      <div class="bk-t">导出配置</div>
      <div class="bk-d">仅导出网关配置项（JSON），体积小、易读，适合快速搬到另一台机器或留档比对。</div>
      <button class="btn g bk-btn" id="btnExportCfg"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="bk-dl"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>下载 JSON</button>
    </div>
    <div class="card bk-card">
      <div class="bk-ic bk-ic-c"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><polyline points="12 12 12 18"/><polyline points="9 15 12 12 15 15"/></svg></div>
      <div class="bk-t">导入配置</div>
      <div class="bk-d">选择之前导出的 JSON 覆盖当前网关设置，监听端口保持不变，导入成功后自动刷新。</div>
      <label class="btn g bk-btn" style="cursor:pointer"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="bk-dl"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>选择文件<input type="file" id="importCfgFile" accept=".json,application/json" style="display:none"></label>
    </div>
  </div>
  <div id="backupMsg" style="margin-top:14px;font-size:12.5px;color:var(--t3);word-break:break-all;max-width:960px"></div>
</div>
</section>
</div>
</div>
<div class="mo" id="modal"><div class="mbox"><div class="mh"><h3 id="modalTitle">记录详情</h3><button class="mcl" id="modalClose">×</button></div><div class="mb" id="modalBody"></div></div></div>
<script>
(function initTheme(){
  let t=null;
  try{ t=localStorage.getItem('ep_theme') }catch(e){}
  if(!t) t = (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', t);
})();
function currentTheme(){ return document.documentElement.getAttribute('data-theme') || 'light' }

const state={port:0,labels:{},ovRange:'today',ovFrom:'',ovTo:'',tfRange:'today',tfFrom:'',tfTo:'',schemaVersion:2,cfgCache:null};
let ovTrendData=[];

function fmtBytes(b){if(!b)return '0 B';if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(1)+' MB';return (b/1073741824).toFixed(2)+' GB'}
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

function reasonLabel(r){return {cn:'地区限制',whitelist:'上游域名未授权',host_ip:'IP 直连被拒',host_deny:'访问域名未授权',host:'访问域名未授权(旧)',ban:'IP 黑名单',ua:'UA 不允许',login_fail:'登录失败'}[r]||'其他拦截'}
function reasonClass(r){return {cn:'pc',whitelist:'pw',host_ip:'pb',host_deny:'po',host:'pw',ban:'pb',ua:'pu',login_fail:'pb'}[r]||'pw'}
const REASON_ORDER=['host_ip','host_deny','host','whitelist','ban','ua','cn','login_fail'];
function renderReasonStats(counts){
  const box=document.getElementById('blkReasonStats'); if(!box)return;
  if(!counts){box.innerHTML='';return}
  const keys=REASON_ORDER.filter(k=>counts[k]>0);
  Object.keys(counts).forEach(k=>{if(!REASON_ORDER.includes(k)&&counts[k]>0)keys.push(k)});
  if(!keys.length){box.innerHTML='';return}
  const total=keys.reduce((s,k)=>s+counts[k],0);
  box.innerHTML=keys.map(k=>`<button type="button" class="pill ${reasonClass(k)}" data-rs="${esc(k)}" title="点击按此原因筛选" style="cursor:pointer;border-radius:8px;padding:4px 10px;font:inherit">${esc(reasonLabel(k))} <b style="margin-left:4px">${Number(counts[k]).toLocaleString()}</b></button>`).join('')+`<span style="font-size:12px;color:var(--t3);align-self:center;margin-left:4px">共 ${total.toLocaleString()} 条 · 点击标签可筛选</span>`;
  box.querySelectorAll('[data-rs]').forEach(el=>el.addEventListener('click',()=>{
    const sel=document.getElementById('blkReason'); if(sel)sel.value=el.dataset.rs;
    blkState.page=1; loadBlocks();
  }));
}

function countryLabel(code){  if(!code) return '未知';
  const c = String(code).toUpperCase();
  if(state.labels && (state.labels[c]||state.labels[code])) return state.labels[c]||state.labels[code];
  const fallback = {LO:'本机',PV:'内网','??':'未知',CN:'中国',HK:'中国香港',TW:'中国台湾',MO:'中国澳门',US:'美国',JP:'日本',KR:'韩国',SG:'新加坡',GB:'英国',DE:'德国',FR:'法国',RU:'俄罗斯'};
  return fallback[c] || code;
}

const pageTitles={overview:'概览',traffic:'流量请求',realtime:'实时监控',blocks:'拦截记录',audit:'操作记录',speedm:'测速管理',report:'数据上报',settings:'网关设置'};
let blocksTimer=null, realtimeWS=null, reportTimer=null;
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
  if(reportTimer){clearInterval(reportTimer);reportTimer=null}
  if(realtimeWS){try{realtimeWS.close()}catch(e){} realtimeWS=null; clearRealtimeUI();}
  if(id==='overview')loadOverview();
  if(id==='traffic')loadTraffic();
  if(id==='realtime') connectRealtime();
  if(id==='speedm'){loadSpeedTokens();loadSpeedResults();}
  if(id==='settings')loadSpeedTokens();
  if(id==='report')loadReportPage();
  if(id==='audit')loadAudit();
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
      const spdBox=document.getElementById('rtIPSpeeds');
      if(spdBox){
        const speeds=d.ip_speeds||[];
        if(!speeds.length){
          spdBox.innerHTML='<div style="color:var(--t3);font-size:13px;padding:8px 0">当前无活跃流量</div>';
        }else{
          spdBox.innerHTML=speeds.map(s=>`<div style="display:flex;justify-content:space-between;align-items:center;padding:6px 10px;background:#f8fafc;border-radius:8px;font-size:13px">
            <span class="mono" style="color:var(--pd);font-weight:600;cursor:pointer" onclick="showIPDetail('${esc(s.ip)}')">${esc(s.ip)}</span>
            <span style="color:var(--t2)">↓ ${fmtBytes(s.rx_bps||0)}/s　↑ ${fmtBytes(s.tx_bps||0)}/s</span>
          </div>`).join('');
        }
      }
      const evs=d.events||[];
      const tb=document.getElementById('rtTable');
      if(!evs.length) return;
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

function applyPort(p){if(!p)return;state.port=p;document.getElementById('portInput').value=p}

async function loadConfig(){
  try{
    const r=await fetch('/admin/api/config',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const c=await r.json();applyPort(c.effective_port);
    document.getElementById('chinaOnly').checked=!!c.china_only;
    const hg=document.getElementById('hostGuardOn');if(hg)hg.checked=!!c.host_guard_on;
    const ah=document.getElementById('allowedHosts');if(ah)ah.value=(c.allowed_hosts||[]).join('\n');
    const ch=document.getElementById('curHostHint');if(ch){const h=c.current_host||'';ch.textContent=h?('当前访问域名（请确认它已填在上方白名单）：'+h):'当前访问域名：未知';}
    document.getElementById('whitelist').value=(c.whitelist||[]).join('\n');document.getElementById('banList').value=(c.ban_list||[]).join('\n');
    document.getElementById('allowedUAs').value=(c.allowed_uas||[]).join('\n');
    const ro=document.getElementById('reportOn');if(ro)ro.checked=!!c.report_on;
    const ru=document.getElementById('reportUrl');if(ru)ru.value=c.report_url||'';
    const rt=document.getElementById('reportToken');if(rt)rt.value=c.report_token||'';
    const rn=document.getElementById('reportNote');if(rn)rn.value=c.report_note||'';
    const dtOn=document.getElementById('dailyTmplOn');if(dtOn)dtOn.checked=!!c.daily_tmpl_on;
    const dt=document.getElementById('dailyTmpl');if(dt)dt.value=c.daily_tmpl||'';
    const dtUrl=document.getElementById('dailyTmplUrl');if(dtUrl)dtUrl.value=c.daily_tmpl_url||'';
    const dtTok=document.getElementById('dailyTmplToken');if(dtTok)dtTok.value=c.daily_tmpl_token||'';
    const dtType=document.getElementById('dailyTmplType');if(dtType)dtType.value=c.daily_tmpl_type||'text/plain';
    const aa=document.getElementById('adminAllow');if(aa)aa.value=(c.admin_allow||[]).join('\n');

  }catch(e){console.error('loadConfig error:',e)}
}

let miniTrendChart=null,miniByteChart=null,reqChart=null,byteChart=null,hostChart=null;
let trafficTrendData=[];

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
    bTotal += (d.blocked != null) ? d.blocked : ((d.blocked_cn||0)+(d.blocked_whitelist||0));
  });
  const days = filtered.length || 1;
  document.getElementById('ovReq').textContent = reqs.toLocaleString();
  document.getElementById('ovBytes').textContent = fmtBytes(bytes);
  document.getElementById('ovAvgReq').textContent = Math.round(reqs/days).toLocaleString();
  document.getElementById('ovAvgBytes').textContent = fmtBytes(Math.round(bytes/days));
  document.getElementById('ovBlocked').textContent = bTotal.toLocaleString();

  const single = !!from && from===to;
  const dayName = state.ovRange==='yesterday' ? '昨日' : '今日';
  let spanDays = filtered.length;
  if(!single && from && to && to>=from){
    const a=new Date(from+'T00:00:00'), b=new Date(to+'T00:00:00');
    spanDays = Math.min(400, Math.round((b-a)/86400000)+1);
  }
  const spanHint = single ? (dayName + ' 分时') : (spanDays ? ('共 ' + spanDays + ' 天') : '暂无数据');
  document.getElementById('ovReqDesc').textContent = single ? (dayName + ' 00:00–23:00 各时段请求数（北京时间）') : ('区间内每日请求次数 · ' + spanHint);
  document.getElementById('ovByteDesc').textContent = single ? (dayName + ' 00:00–23:00 各时段整机端口流量（含其他进程，仅供参考）') : ('区间内每日整机端口流量（含其他进程） · ' + spanHint);
}

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
    labels.push((day.date||from||'').slice(5)||'当日');
    reqs.push(day.requests||0);
    ups.push(day.up_bytes||0); downs.push(day.down_bytes||0);
    return {labels,reqs,ups,downs,gran:'day'};
  }
  const byDate={}; filtered.forEach(d=>{byDate[d.date]=d});
  let days=Object.keys(byDate).sort();
  if(from&&to&&to>=from){
    const a=new Date(from+'T00:00:00'), bEnd=new Date(to+'T00:00:00');
    const cap=400;
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
    const r=await fetch('/admin/api/traffic?slim=1',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    document.getElementById('uniqueIPs').textContent=(t.unique_ips!=null?t.unique_ips:Object.keys(t.ip_counts||{}).length).toLocaleString();
    ovTrendData = t.trend || [];
    refreshOverview();
    
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

function renderSysInfo(sys, uptime){
  const box=document.getElementById('sysInfo');
  if(!box) return;
  const up = uptime!=null ? uptime : (sys && sys.uptime_sec) || 0;
  const d=Math.floor(up/86400), h=Math.floor(up%86400/3600), m=Math.floor(up%3600/60);
  const upStr = d>0 ? (d+' 天 '+h+' 小时') : (h>0 ? (h+' 小时 '+m+' 分') : (m+' 分钟'));

  const kv=(k,v,color)=>`<div class="kvr"><span class="kvl">${k}</span><span class="kvv"${color?' style="color:'+color+'"':''}>${v}</span></div>`;
  const group=(title,rows)=>`<div class="svg-title">${title}</div><div class="sv-list">${rows.join('')}</div>`;

  const sw = sys || {};
  const dropped = sw.stat_dropped||0;
  const run=[
    kv('运行时长', upStr),
    kv('监听端口', sw.port!=null ? (':'+sw.port) : '—'),
    kv('内存占用', fmtBytes(sw.mem_heap||0)),
    kv('在线会话', (sw.logins!=null? sw.logins : '—') + ' 个'),
    kv('统计丢弃', dropped>0 ? (Number(dropped).toLocaleString()+' 条 ⚠') : '0 条', dropped>0?'var(--w)':''),
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

function renderOvCharts(){
  if(typeof Chart==='undefined') return;
  const v=ovChartSeries();
  const ups = Array.isArray(v.ups) ? v.ups : [];
  const downs = Array.isArray(v.downs) ? v.downs : [];

  const cvReq=document.getElementById('miniTrendChart');
  if(cvReq && v.labels.length){
    const cfg={type:'line',data:{labels:v.labels.map(l=>fmtAxisLabel(l,v.gran)),datasets:[
      {label:'请求数',data:v.reqs,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.15)',borderWidth:2,fill:true,tension:0.4,pointRadius:v.gran==='hour'?0:3,pointHoverRadius:6}
    ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:false,plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(v.labels,v.gran),label:c=>'请求数：'+Number(c.parsed.y||0).toLocaleString()}}},scales:{x:{grid:{display:false},ticks:{autoSkip:true,maxTicksLimit:chartTickLimit(v.labels.length,v.gran)}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}}}}};
    miniTrendChart=upsertChart(miniTrendChart,cvReq,cfg);
  }

  const cvByte=document.getElementById('miniByteChart');
  if(cvByte && v.labels.length){
    const tot=v.labels.map((_,i)=>((ups[i])||0)+((downs[i])||0));
    const cfgByte={type:'line',data:{labels:v.labels.map(l=>fmtAxisLabel(l,v.gran)),datasets:[
      {label:'总流量',data:tot,borderColor:'#10b981',backgroundColor:'rgba(16,185,129,0.15)',borderWidth:2,fill:true,tension:0.4,pointRadius:v.gran==='hour'?0:3,pointHoverRadius:6}
    ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:false,plugins:{legend:{display:false},tooltip:{callbacks:{
      title:tooltipTitle(v.labels,v.gran),
      label:c=>{
        const i=c.dataIndex;
        const u=ups[i]||0, d=downs[i]||0;
        return [
          '总吞吐：'+fmtBytes(c.parsed.y),
          '↓ 下行：'+fmtBytes(d),
          '↑ 上行：'+fmtBytes(u)
        ];
      }
    }}},scales:{x:{grid:{display:false},ticks:{autoSkip:true,maxTicksLimit:chartTickLimit(v.labels.length,v.gran)}},y:bytesAxis(Math.max.apply(null, tot.concat([0])), 5)}}};
    miniByteChart=upsertChart(miniByteChart,cvByte,cfgByte);
  }
}

function refreshOverview(){
  updateOvStats();
  renderOvCharts();
}

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
  const ipMap={},ctryMap={},hostMap={},uaMap={},uaRawMap={};
  let totalReq=0,totalBytes=0,totalUp=0,totalDown=0,blocked=0,rawDayCount=0,gran='hour';
  filtered.forEach(d=>{
    totalReq+=d.requests||0; totalBytes+=d.bytes||0;
    totalUp+=d.up_bytes||0; totalDown+=d.down_bytes||0;
    blocked+=(d.blocked!=null)?d.blocked:((d.blocked_cn||0)+(d.blocked_whitelist||0));
    Object.entries(d.ips||{}).forEach(([k,v])=>{ipMap[k]=(ipMap[k]||0)+v});
    Object.entries(d.countries||{}).forEach(([k,v])=>{ctryMap[k]=(ctryMap[k]||0)+v});
    Object.entries(d.hosts||{}).forEach(([k,v])=>{hostMap[k]=(hostMap[k]||0)+v});
    Object.entries(d.ua_class||{}).forEach(([k,v])=>{uaMap[k]=(uaMap[k]||0)+v});
    Object.entries(d.ua_raw||{}).forEach(([k,v])=>{uaRawMap[k]=(uaRawMap[k]||0)+v});
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
  return {isToday,gran,labels,reqs,bytes,ups,downs,ipMap:ipMapTrim,ctryMap:ctryMapTrim,hostTop,totalReq,totalBytes,totalUp,totalDown,blocked,dayCount:rawDayCount,ipTotalUnique:ipEntries.length,ctryTotalUnique:ctryEntries.length,ipTopN,ctryTopN,uaMap,uaRawMap,days:filtered};
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
  const ipBytesMap={};
  if(state.ipUpBytes) for(const k in state.ipUpBytes) ipBytesMap[k]=(ipBytesMap[k]||0)+state.ipUpBytes[k];
  if(state.ipDownBytes) for(const k in state.ipDownBytes) ipBytesMap[k]=(ipBytesMap[k]||0)+state.ipDownBytes[k];
  renderIP(v.ipMap,ipBytesMap,v.ipTotalUnique,v.ipTopN);
  renderRegion(v.ctryMap,v.ctryTotalUnique,v.ctryTopN);
  renderUADist(v.uaMap,v.uaRawMap);
  renderHourHeat(v.days);
}

async function loadTraffic(){
  try{
    const r=await fetch('/admin/api/traffic',{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    if(t.country_labels) state.labels = t.country_labels;
    state.schemaVersion = (t.schema_version!=null? t.schema_version : 2);
    trafficTrendData = t.trend || [];
    state.ipUpBytes = t.ip_up_bytes || {};
    state.ipDownBytes = t.ip_down_bytes || {};
    applyTrafficView();
  }catch(e){console.error('loadTraffic error:',e)}
}

function upsertChart(prev,cv,cfg){
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
  const cfg={type:'line',data:{labels:labs,datasets:[
    {label:'请求数',data,borderColor:'#3b82f6',backgroundColor:'rgba(59,130,246,0.15)',borderWidth:2,fill:true,tension:0.4,pointRadius:dense||gran==='hour'?0:(labels.length>20?2:3),pointHoverRadius:6}
  ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:dense?false:{duration:400},plugins:{legend:{display:false},tooltip:{callbacks:{title:tooltipTitle(labels,gran),label:c=>'请求数：'+Number(c.parsed.y||0).toLocaleString()}}},scales:{x:{grid:{display:false},ticks:{maxRotation:45,minRotation:0,autoSkip:true,maxTicksLimit:chartTickLimit(labels.length,gran)}},y:{beginAtZero:true,grid:{borderDash:[4,4]},ticks:{precision:0}}}}};
  reqChart=upsertChart(reqChart,cv,cfg);
}
function renderByteChart(labels,ups,downs,gran){
  const cv=document.getElementById('byteChart');if(!cv||typeof Chart==='undefined')return;
  gran=gran||'day';
  const labs=labels.map(l=>fmtAxisLabel(l,gran));
  const dense=labels.length>40;
  const tot=(labels||[]).map((_,i)=>((ups&&ups[i])||0)+((downs&&downs[i])||0));
  const cfg={type:'line',data:{labels:labs,datasets:[
    {label:'总流量',data:tot,borderColor:'#10b981',backgroundColor:'rgba(16,185,129,0.15)',borderWidth:2,fill:true,tension:0.4,pointRadius:dense||gran==='hour'?0:(labels.length>20?2:3),pointHoverRadius:6}
  ]},options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},animation:dense?false:{duration:400},plugins:{legend:{display:false},tooltip:{callbacks:{
    title:tooltipTitle(labels,gran),
    label:c=>{
      const i=c.dataIndex;
      const u=(ups&&ups[i])||0, d=(downs&&downs[i])||0;
      return [
        '总吞吐：'+fmtBytes(c.parsed.y),
        '↓ 下行：'+fmtBytes(d),
        '↑ 上行：'+fmtBytes(u)
      ];
    }
  }}},scales:{x:{grid:{display:false},ticks:{maxRotation:45,minRotation:0,autoSkip:true,maxTicksLimit:chartTickLimit(labels.length,gran)}},y:bytesAxis(Math.max.apply(null, tot.concat([0])), 5)}}};
  byteChart=upsertChart(byteChart,cv,cfg);
}
function renderHostChart(hostTop){
  const cv=document.getElementById('hostChart');if(!cv||typeof Chart==='undefined')return;
  const labels=hostTop.map(([h])=>h.length>22?h.slice(0,20)+'…':h);
  const data=hostTop.map(([,n])=>n);
  if(!labels.length){labels.push('暂无数据');data.push(0)}
  const dense=labels.length>24;
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
  let html=rows.map(([ip,n])=>{
    const b=bytesMap&&bytesMap[ip]||0;
    const btxt='<span class="dbt">'+(b>0?fmtBytes(b):'')+'</span>';
    return `<div class="dr ip-row" data-ip="${esc(ip)}" style="cursor:pointer" title="点击查看详情"><span class="dn m"><span class="tx" style="color:var(--pd)">${esc(ip)}</span></span><div class="bar i"><i style="width:${(n/max*100).toFixed(1)}%"></i></div><span class="dv">${n.toLocaleString()}<span>次</span></span>${btxt}</div>`;
  }).join('');
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

function renderUADist(map,rawMap){
  const box=document.getElementById('uaDist');
  if(!box)return;
  const rows=Object.entries(map||{}).sort((a,b)=>b[1]-a[1]).slice(0,10);
  if(!rows.length){
    box.innerHTML='<div class="emp"><b>暂无数据</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">当前筛选条件下没有客户端记录</span></div>';
    return;
  }
  const total=Object.values(map).reduce((a,b)=>a+b,0)||1;
  const max=rows[0][1]||1;
  const raws=Object.entries(rawMap||{}).sort((a,b)=>b[1]-a[1]).slice(0,10);
  const rawHtml=raws.length?`
    <div class="ua-raw">
      <div class="ua-raw-h">原始 UA 采样 · 当前范围 Top ${raws.length}<span style="color:var(--t3);font-weight:400">（点击行收起）</span></div>
      ${raws.map(([u,n])=>`<div class="ua-raw-i"><span class="ua-raw-n">${n.toLocaleString()}</span><span class="ua-raw-u" title="${esc(u)}">${esc(u)}</span></div>`).join('')}
    </div>`:'<div class="ua-raw"><div class="ua-raw-h">暂无原始 UA 采样（仅 v3.1.2 起的新数据）</div></div>';
  box.innerHTML=rows.map(([name,n])=>
    `<div class="dr ua-row" data-cls="${esc(name)}" style="cursor:pointer" title="点击查看原始 UA 采样"><span class="dn"><span class="tx">${esc(name)}</span></span><div class="bar i"><i style="width:${(n/max*100).toFixed(1)}%"></i></div><span class="dv">${n.toLocaleString()}<span>${(n/total*100).toFixed(0)}%</span></span></div>`
  ).join('')+'<div class="ua-raw-box" style="display:none">'+rawHtml+'</div>';
  const rawBox=box.querySelector('.ua-raw-box');
  box.querySelectorAll('.ua-row').forEach(el=>el.addEventListener('click',()=>{
    if(!rawBox)return;
    const open=rawBox.style.display!=='none';
    rawBox.style.display=open?'none':'block';
  }));
}

function hmCell(v,max,title){
  const a=v?0.10+0.85*Math.pow(v/max,0.65):0;
  const bg=v?`background:rgba(59,130,246,${a.toFixed(3)})`:'';
  return `<div class="hm-cell" style="${bg}" title="${esc(title)}"></div>`;
}
let hourHeatDays=[];
function hmGrid(head,cells,label,chunk){
  const n=head.length;
  const build=(hs,cs,lb)=>`<div class="hm" style="grid-template-columns:56px repeat(${hs.length},1fr)"><div class="hm-d"></div>${hs.join('')}<div class="hm-d">${lb}</div>${cs.join('')}</div>`;
  if(!chunk||n<=chunk)return build(head,cells,esc(label));
  let out='';
  for(let i=0;i<n;i+=chunk){
    const hs=head.slice(i,i+chunk),cs=cells.slice(i,i+chunk);
    out+=build(hs,cs,i?'':esc(label));
  }
  return out;
}
function renderHourHeat(days){
  const box=document.getElementById('hourHeat');
  if(!box)return;
  hourHeatDays=days||[];
  const sub=document.getElementById('hourHeatSub');
  const list=hourHeatDays.filter(d=>d&&d.date).sort((a,b)=>a.date<b.date?-1:1);
  if(!list.length){
    if(sub)sub.textContent='当前筛选条件下没有数据';
    box.innerHTML='<div class="emp"><b>暂无数据</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">当前筛选条件下没有请求记录</span></div>';
    return;
  }
  const {from,to}=dateRangeBounds();
  const single=!!(from&&to&&from===to);
  let span=list.length||1;
  if(from&&to){span=Math.round((new Date(to)-new Date(from))/86400000)+1}

  let headCells=[],cells=[],rowLabel='',unit='',max=1,title='';
  const chunk=(window.innerWidth||1024)<=600?12:0;
  if(single){
    const d=list.find(x=>x.date===from)||list[list.length-1];
    const hours=d.hours||{};
    for(let h=0;h<24;h++){const v=hours[String(h).padStart(2,'0')]||0;if(v>max)max=v}
    for(let h=0;h<24;h++)headCells.push(`<div class="hm-h">${String(h).padStart(2,'0')}</div>`);
    for(let h=0;h<24;h++){const k=String(h).padStart(2,'0');const v=hours[k]||0;cells.push(hmCell(v,max,`${d.date} ${k}:00 · ${v.toLocaleString()} 次`))}
    rowLabel=String(d.date).slice(5);unit='次/时';
    title=`${d.date} 24 小时请求分布（北京时间）`;
  }else if(span<=31){
    list.forEach(d=>{if((d.requests||0)>max)max=d.requests||0});
    headCells=list.map(d=>`<div class="hm-h" title="${esc(d.date)}">${String(d.date).endsWith('-01')?String(d.date).slice(5):String(d.date).slice(8)}</div>`);
    list.forEach(d=>{const v=d.requests||0;cells.push(hmCell(v,max,`${d.date} · ${v.toLocaleString()} 次`))});
    rowLabel='按天';unit='次/天';
    title=`${list[0].date} ~ ${list[list.length-1].date} 按天请求分布`;
  }else{
    const months={};
    list.forEach(d=>{const m=String(d.date).slice(0,7);months[m]=(months[m]||0)+(d.requests||0)});
    const keys=Object.keys(months).sort();
    keys.forEach(m=>{if(months[m]>max)max=months[m]});
    headCells=keys.map(m=>`<div class="hm-h" title="${esc(m)}">${m}</div>`);
    keys.forEach(m=>{const v=months[m];cells.push(hmCell(v,max,`${m} · ${v.toLocaleString()} 次`))});
    rowLabel='按月';unit='次/月';
    title=`${keys[0]} ~ ${keys[keys.length-1]} 按月请求分布`;
  }
  if(sub)sub.textContent=title;
  const narrow=chunk>0&&headCells.length>chunk;
  box.innerHTML=hmGrid(headCells,cells,rowLabel,chunk)
    +`<div class="hm-legend"${narrow?' style="margin-top:6px"':''}><span>少</span>`
    +'<i style="background:rgba(59,130,246,.12)"></i><i style="background:rgba(59,130,246,.35)"></i><i style="background:rgba(59,130,246,.6)"></i><i style="background:rgba(59,130,246,.9)"></i>'
    +`<span>多（峰值 ${max.toLocaleString()} ${unit}）</span></div>`;
}
let hourHeatRz=null;
window.addEventListener('resize',()=>{clearTimeout(hourHeatRz);hourHeatRz=setTimeout(()=>{if(hourHeatDays.length)renderHourHeat(hourHeatDays)},200)});

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
    const rows=[['IP',d.ip,true],['位置',loc,false],cntRow,
      ['下行流量',fmtBytes(d.down_bytes||0),false],
      ['上行流量',fmtBytes(d.up_bytes||0),false],
      ['合计',fmtBytes((d.up_bytes||0)+(d.down_bytes||0)),false]];
    document.getElementById('modalBody').innerHTML=rows.map(([k,v,m])=>'<div class="kv"><div class="kk">'+esc(k)+'</div><div class="kvv'+(m?' m':'')+'">'+esc(v)+'</div></div>').join('');
  }catch(e){
    document.getElementById('modalBody').innerHTML='<div style="color:var(--d);font-size:13px">加载失败：'+esc(e.message||'未知错误')+'</div>';
  }
}

const blkState={page:1,size:50,total:0};
function blkParams(extra){
  const q=document.getElementById('blkQ')?.value?.trim()||'';
  const reason=document.getElementById('blkReason')?.value||'';
  const ip=document.getElementById('blkIP')?.value?.trim()||'';
  const p=new URLSearchParams();
  if(q)p.set('q',q);
  if(reason)p.set('reason',reason);
  if(ip)p.set('ip',ip);
  if(extra)Object.entries(extra).forEach(([k,v])=>p.set(k,v));
  return p;
}
async function loadBlocks(){
  try{
    const p=blkParams({limit:String(blkState.size),offset:String((blkState.page-1)*blkState.size)});
    const r=await fetch('/admin/api/blocks?'+p.toString(),{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const t=await r.json();
    const tb=document.getElementById('blockTable');
    const cnt=document.getElementById('blkCount');
    renderReasonStats(t.reason_counts);
    blkState.total=t.total||0;
    const pages=Math.max(1,Math.ceil(blkState.total/blkState.size));
    if(blkState.page>pages)blkState.page=pages;
    if(cnt) cnt.textContent='共 '+blkState.total+' 条';
    const info=document.getElementById('blkPageInfo');
    if(info) info.textContent=blkState.total?('第 '+blkState.page+' / '+pages+' 页'):'';
    const prev=document.getElementById('blkPrev'), next=document.getElementById('blkNext');
    if(prev) prev.disabled=blkState.page<=1;
    if(next) next.disabled=blkState.page>=pages;
    if(!t.items||!t.items.length){tb.innerHTML='<tr class="emp-row"><td colspan="8"><div class="emp"><b>暂无记录</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">没有匹配的拦截事件</span></div></td></tr>';return}
    tb.innerHTML=t.items.map(b=>{
      const ua=String(b.ua||'').trim();
      const uaShort=ua.length>60?ua.slice(0,58)+'…':ua;
      return `<tr>
      <td data-label="时间"><span class="cell-v muted mono">${fmtBeijing(b.time,'full')}</span></td>
      <td data-label="IP 地址"><span class="cell-v mono ip-link" data-ip="${esc(b.ip)}" style="color:var(--pd);text-decoration:underline;cursor:pointer;font-weight:600">${esc(b.ip)}</span></td>
      <td data-label="地区"><span class="cell-v"><img class="flg" src="/admin/api/flag/${(b.country||'??').toLowerCase()}" onerror="this.style.display='none'" alt="">${esc(b.country_name||countryLabel(b.country||'??'))}</span></td>
      <td data-label="访问域名"><span class="cell-v mono" style="font-size:12.5px;word-break:break-all" title="${esc(b.host||'')}">${b.host?esc(b.host):'<span style="color:var(--t3)">—</span>'}</span></td>
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
        loadConfig(); loadBlocks();
      }catch(e){alert('网络异常');}
    }));
  }catch(e){console.error('loadBlocks error:',e)}
}

const audState={page:1,size:50,total:0};
const ACT_LABEL={login:'登录',change_password:'修改密码',save_config:'保存配置',ban_ip:'拉黑 IP',clear_stats:'清空统计',speed_create:'生成测速链接',speed_delete:'删除测速链接',report_test:'手动上报',report_daily:'发送昨日统计',report_retry:'补传上报',report_clear:'清空上报快照',report_clear_records:'清空上报记录',backup_db:'下载数据库',config_export:'导出配置',config_import:'导入配置',blocks_export:'导出拦截记录'};
function actLabel(a){return ACT_LABEL[a]||a||'其他'}
async function loadAudit(){
  const tb=document.getElementById('auditBody');
  if(!tb)return;
  try{
    const action=document.getElementById('auditAction')?.value||'';
    const p=new URLSearchParams({limit:String(audState.size),offset:String((audState.page-1)*audState.size)});
    if(action)p.set('action',action);
    const r=await fetch('/admin/api/audit?'+p.toString(),{cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const d=await r.json();
    const items=d.items||[];
    const total=d.total||0;
    const pages=Math.max(1,Math.ceil(total/audState.size));
    if(audState.page>pages)audState.page=pages;
    const cnt=document.getElementById('auditCount');
    if(cnt)cnt.textContent='共 '+total+' 条';
    const info=document.getElementById('auditPageInfo');
    if(info)info.textContent=total?('第 '+audState.page+' / '+pages+' 页'):'';
    const prev=document.getElementById('auditPrev'),next=document.getElementById('auditNext');
    if(prev)prev.disabled=audState.page<=1;
    if(next)next.disabled=audState.page>=pages;
    if(!items.length){
      tb.innerHTML='<tr class="emp-row"><td colspan="4"><div class="emp"><b>暂无记录</b><span style="display:block;margin-top:4px;font-size:12.5px;color:var(--t3)">暂无匹配的后台操作</span></div></td></tr>';
      return;
    }
    const danger={clear_stats:1,ban_ip:1,change_password:1,config_import:1,report_clear:1,report_clear_records:1};
    tb.innerHTML=items.map(a=>`<tr>
      <td data-label="时间"><span class="cell-v muted mono">${fmtBeijing(a.time,'full')}</span></td>
      <td data-label="动作"><span class="cell-v"><span class="act-tag${danger[a.action]?' warn':''}">${esc(actLabel(a.action))}</span></span></td>
      <td data-label="详情"><span class="cell-v" style="word-break:break-all">${esc(a.detail||'—')}</span></td>
      <td data-label="来源 IP"><span class="cell-v mono">${a.ip?`<span class="ip-link" data-ip="${esc(a.ip)}" style="color:var(--pd);text-decoration:underline;cursor:pointer;font-weight:600" title="点击查看该 IP 详情">${esc(a.ip)}</span>`:'—'}</span></td>
    </tr>`).join('');
    tb.querySelectorAll('.ip-link').forEach(el=>el.addEventListener('click',()=>showIPDetail(el.dataset.ip)));
  }catch(e){console.error('loadAudit error:',e)}
}

function collect(){
  const raw=parseInt(document.getElementById('portInput').value,10);
  const lines=id=>((document.getElementById(id)?.value||'').split('\n')).map(x=>x.trim()).filter(Boolean);
  return{port:isNaN(raw)?0:raw,
    china_only:!!document.getElementById('chinaOnly')?.checked,
    host_guard_on:!!document.getElementById('hostGuardOn')?.checked,
    allowed_hosts:lines('allowedHosts'),
    whitelist:lines('whitelist'),
    ban_list:lines('banList'),
    allowed_uas:lines('allowedUAs'),
    admin_allow:lines('adminAllow'),
    report_on:!!document.getElementById('reportOn')?.checked,
    report_url:(document.getElementById('reportUrl')?.value||'').trim(),
    report_token:(document.getElementById('reportToken')?.value||'').trim(),
    report_note:(document.getElementById('reportNote')?.value||'').trim(),
    daily_tmpl_on:!!document.getElementById('dailyTmplOn')?.checked,
    daily_tmpl:(document.getElementById('dailyTmpl')?.value||''),
    daily_tmpl_url:(document.getElementById('dailyTmplUrl')?.value||'').trim(),
    daily_tmpl_token:(document.getElementById('dailyTmplToken')?.value||'').trim(),
    daily_tmpl_type:(document.getElementById('dailyTmplType')?.value||'text/plain'),
    }
}
async function save(){
  try{
    const r=await fetch('/admin/api/save',{method:'POST',body:JSON.stringify(collect())});
    if(!r.ok)throw new Error(await r.text());
    const c=await r.json();applyPort(c.effective_port);
    alert('配置已保存并即时生效');
  }catch(e){alert('保存失败：'+(e.message||'未知错误'))}
}
// saveSilent 静默保存当前页面配置：不弹窗、返回结果，供「立即发送/上报」类按钮先落库再执行
async function saveSilent(){
  try{
    const r=await fetch('/admin/api/save',{method:'POST',body:JSON.stringify(collect())});
    if(!r.ok)throw new Error((await r.text())||('HTTP '+r.status));
    const c=await r.json();applyPort(c.effective_port);
    return {ok:true};
  }catch(e){return {ok:false,err:e.message||'未知错误'}}
}
document.getElementById('savePort').addEventListener('click',()=>save());document.getElementById('saveAll').addEventListener('click',()=>save());

const RP_PAGE_SIZE=20;
const rpState={items:[],page:1,loaded:false};
function reportMsg(t,color,target){const el=document.getElementById(target||'reportMsg');if(el){el.textContent=t;el.style.color=color||'var(--t3)'}}
function tmplMsg(t,color){reportMsg(t,color,'tmplMsg')}
function rpTriggerLabel(t){return {auto:'整点自动',daily:'昨日日报','daily-text':'昨日日报(自定义)',manual:'手动','manual-daily':'手动日报','manual-daily-text':'手动日报(自定义)',retry:'补传',cleanup:'队列清理'}[t]||t||'—'}
function fmtDur(ms){if(!ms)return '—';if(ms<1000)return ms+' ms';return (ms/1000).toFixed(1)+' s'}
function fmtTimeSec(v){return v?fmtBeijing(v):'—'}

async function loadReportPage(){
  const st=document.getElementById('rpState');
  if(st){st.className='rp-g wt';st.textContent='读取中'}
  await Promise.all([loadReportRecords(), loadReportQueueStat()]);
  if(!reportTimer){reportTimer=setInterval(()=>{if(!document.hidden && document.getElementById('report')?.classList.contains('on')){loadReportRecords();loadReportQueueStat()}},15000)}
}

function rpFiltered(){
  const q=(document.getElementById('rpQ')?.value||'').trim().toLowerCase();
  const res=document.getElementById('rpResult')?.value||'';
  const tg=document.getElementById('rpTrigger')?.value||'';
  return rpState.items.filter(it=>{
    if(res==='ok'&&!it.ok)return false;
    if(res==='fail'&&it.ok)return false;
    if(tg&&it.trigger!==tg)return false;
    if(q){
      const hay=[it.batch_id,it.url,it.error,it.note,it.ip,it.id].join(' ').toLowerCase();
      if(!hay.includes(q))return false;
    }
    return true;
  });
}

function rpRenderTable(){
  const tb=document.getElementById('rpBody');
  if(!tb)return;
  const list=rpFiltered();
  const pages=Math.max(1,Math.ceil(list.length/RP_PAGE_SIZE));
  if(rpState.page>pages)rpState.page=pages;
  const pageItems=list.slice((rpState.page-1)*RP_PAGE_SIZE, rpState.page*RP_PAGE_SIZE);
  document.getElementById('rpCount').textContent='共 '+list.length+' 条记录';
  document.getElementById('rpPageInfo').textContent=pages>1?('第 '+rpState.page+' / '+pages+' 页'):'';
  document.getElementById('rpPrev').disabled=rpState.page<=1;
  document.getElementById('rpNext').disabled=rpState.page>=pages;
  if(!pageItems.length){
    tb.innerHTML='<tr><td colspan="9" style="text-align:center;color:var(--t3);padding:22px 0">暂无上报记录；开启自动上报后每小时形成一条，或点「立即上报一次」马上产生一条</td></tr>';
    return;
  }
  tb.innerHTML=pageItems.map(it=>{
    const okCls=it.ok?'ok':'bad';
    const okTxt=it.ok?'成功':(it.status_code?('失败 HTTP '+it.status_code):'失败');
    const period=(it.period_date||'—')+(it.period_hour!==undefined&&it.period_hour!==''?' '+it.period_hour+':00':'');
    return `<tr class="rp-row" data-rid="${esc(it.id)}">
      <td data-label="时间"><span class="cell-v mono">${fmtTimeSec(it.time)}</span></td>
      <td data-label="触发"><span class="cell-v"><span class="rp-tg ${esc(it.trigger||'')}">${rpTriggerLabel(it.trigger)}</span></span></td>
      <td data-label="结果"><span class="cell-v"><span class="rp-g ${okCls}">${okTxt}</span></span></td>
      <td data-label="数据周期"><span class="cell-v mono">${esc(period)}</span></td>
      <td data-label="请求"><span class="cell-v">${(it.requests||0).toLocaleString()}</span></td>
      <td data-label="下行"><span class="cell-v">${fmtBytes(it.down_bytes||0)}</span></td>
      <td data-label="上行"><span class="cell-v">${fmtBytes(it.up_bytes||0)}</span></td>
      <td data-label="耗时"><span class="cell-v muted">${fmtDur(it.duration_ms)}</span></td>
      <td data-label="批次"><span class="cell-v mono" style="font-size:11.5px">${esc(it.batch_id||'—')}</span></td>
    </tr>`;
  }).join('');
  tb.querySelectorAll('.rp-row').forEach(tr=>tr.addEventListener('click',()=>showReportRecord(tr.dataset.rid)));
}

function showReportRecord(id){
  const it=rpState.items.find(x=>x.id===id);
  if(!it)return;
  const rows=[
    ['投递时间',fmtTimeSec(it.time)],
    ['触发方式',rpTriggerLabel(it.trigger)+(it.ip?'（来自 '+it.ip+'）':'')],
    ['结果',(it.ok?'成功':'失败')+(it.status_code?'（HTTP '+it.status_code+'）':'')],
    ['数据周期',(it.period_date||'—')+(it.period_hour!==undefined&&it.period_hour!==''?' '+it.period_hour+':00 档':'')],
    ['批次 ID',it.batch_id||'—'],
    ['接收地址',it.url||'—'],
    ['服务器备注',it.note||'—'],
    ['请求数',(it.requests||0).toLocaleString()],
    ['下行 / 上行',fmtBytes(it.down_bytes||0)+' / '+fmtBytes(it.up_bytes||0)+((it.down_bytes||it.up_bytes)?('（'+Number(it.down_bytes||0).toLocaleString()+' / '+Number(it.up_bytes||0).toLocaleString()+' B）'):'')],
    ['拦截数',(it.blocked||0).toLocaleString()],
    ['请求体大小',(it.size||0)+' B'],
    ['耗时',fmtDur(it.duration_ms)],
    ['尝试次数','第 '+ (it.attempts||1) +' 次'],
  ];
  let html='<table style="min-width:0;width:100%;table-layout:fixed"><tbody>'
    + rows.map(([k,v])=>`<tr><td style="width:88px;color:var(--t3);font-size:12.5px;padding:6px 0;vertical-align:top">${esc(k)}</td><td style="font-size:12.5px;padding:6px 0;word-break:break-all">${esc(String(v))}</td></tr>`).join('')
    + '</tbody></table>';
  if(it.payload_saved){
    html+='<div style="font-size:12px;font-weight:600;color:var(--t2);margin-top:14px">原始上报数据 <span id="rpRawMeta" style="font-weight:normal;color:var(--t3)">· 加载中…</span></div>'
      +'<div class="rp-pre" id="rpRaw">加载中…</div>';
  }else{
    html+='<div style="font-size:12px;font-weight:600;color:var(--t2);margin-top:14px">原始上报数据</div>'
      +'<div style="font-size:12px;color:var(--t3);margin-top:4px">该记录未保存原文（由旧版本产生，或本次报文为空）。</div>';
  }
  if(it.error){
    html+='<div style="font-size:12px;font-weight:600;color:var(--d);margin-top:12px">错误信息</div><div class="rp-pre">'+esc(it.error)+'</div>';
  }
  html+='<div style="font-size:12px;font-weight:600;color:var(--t2);margin-top:12px">接收端返回</div><div class="rp-pre">'+esc(it.resp_body||'（空）')+'</div>';
  document.getElementById('modalTitle').textContent='上报记录详情';
  document.getElementById('modalBody').innerHTML=html;
  document.getElementById('modal').classList.add('on');
  if(it.payload_saved)loadRawPayload(it.id);
}

async function loadRawPayload(id){
  const box=document.getElementById('rpRaw'), meta=document.getElementById('rpRawMeta');
  if(!box)return;
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'payload',id})});
    const d=await r.json().catch(()=>({}));
    if(!d.saved){box.textContent='该记录未保存原文。';return}
    box.textContent=d.payload||'';
    if(meta)meta.textContent='· '+fmtBytes(d.size||0)+' · 原样存储，未做解析';
  }catch(e){
    box.textContent='加载失败：'+(e.message||'');
    if(meta)meta.textContent='';
  }
}

async function loadReportRecords(){
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'records'})});
    const d=await r.json().catch(()=>({}));
    if(!r.ok)throw new Error(d.error||('HTTP '+r.status));
    rpState.items=d.items||[];
    rpState.loaded=true;
    rpRenderPlan(d.plan||{}, d);
    rpRenderTable();
    rpRenderStats();
  }catch(e){
    const tb=document.getElementById('rpBody');
    if(tb)tb.innerHTML='<tr><td colspan="9" style="color:var(--d);text-align:center;padding:18px 0">加载失败：'+esc(e.message||'')+'</td></tr>';
  }
}

// rpBeijing 把 RFC3339 时间显示为「MM-DD HH:mm」
function rpBeijing(v){
  if(!v)return '—';
  const t=new Date(v);
  if(isNaN(t.getTime()))return v;
  const p=n=>String(n).padStart(2,'0');
  return p(t.getMonth()+1)+'-'+p(t.getDate())+' '+p(t.getHours())+':'+p(t.getMinutes());
}

// rpRenderPlan 渲染两条通道的状态、地址、下次执行时间与未执行原因
function rpRenderPlan(plan,d){
  const api=plan.api||{}, daily=plan.daily||{};
  const apply=(cardId,stateId,hintId,ready,reason,url,next,off)=>{
    const card=document.getElementById(cardId);
    const st=document.getElementById(stateId);
    const hint=document.getElementById(hintId);
    if(st){
      st.className='rp-g '+(ready?'ok':(reason&&reason.indexOf('不会执行')<0&&reason?'bad':'wt'));
      st.textContent=ready?'执行中':(off?'已关闭':'未执行');
    }
    if(card)card.classList.toggle('off',!ready);
    const uEl=document.getElementById(cardId==='chApiCard'?'chApiUrl':'chDailyUrl');
    if(uEl)uEl.textContent=url||'未填写';
    const nEl=document.getElementById(cardId==='chApiCard'?'chApiNext':'chDailyNext');
    if(nEl)nEl.textContent=ready?rpBeijing(next):'—（不会执行）';
    if(hint){hint.textContent=reason||'';hint.className='rp-ch-hint'+(ready?' ok':'');}
  };
  apply('chApiCard','chApiState','chApiHint',!!api.ready,api.reason||'',d.url||'',api.next,!!(d.url&&!d.on));
  const mode=daily.mode||'off';
  let dReason=daily.reason||'';
  if(mode==='json')dReason='未开启模板推送：日报随「接口上报」通道发 JSON，'+ (api.ready?'会执行':'但接口上报未运行，因此不会发送');
  apply('chDailyCard','chDailyState','chDailyHint',!!daily.ready,dReason,d.tmpl_url||d.url||'',daily.next,mode==='off');
}

function rpRenderStats(){
  const items=rpState.items||[];
  const since=Date.now()-24*3600*1000;
  const recent=items.filter(it=>{const t=new Date(it.time).getTime();return !isNaN(t)&&t>=since});
  const okN=recent.filter(it=>it.ok).length, failN=recent.length-okN;
  document.getElementById('rpOk').textContent=okN;
  document.getElementById('rpFail').textContent=failN;
  document.getElementById('rpRate').textContent=recent.length?Math.round(okN/recent.length*100)+'%':'—';
  const last=items.find(it=>it.ok);
  document.getElementById('rpLast').textContent=last?fmtTimeSec(last.time):'—';
}

async function loadReportQueueStat(){
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'status'})});
    const d=await r.json().catch(()=>({}));
    const el=document.getElementById('rpQueue');
    if(!el)return;
    const n=(r.ok&&typeof d.depth==='number')?d.depth:0;
    el.innerHTML=String(n)+'<small>批</small>';
    el.style.color=n?'var(--w)':'';
  }catch(e){}
}

document.getElementById('saveReport')?.addEventListener('click',async()=>{
  const url=(document.getElementById('reportUrl')?.value||'').trim();
  if(url && !/^https?:\/\//i.test(url)){reportMsg('接收地址需以 http:// 或 https:// 开头','var(--d)');return}
  await save();
  const on=!!document.getElementById('reportOn')?.checked;
  reportMsg(url?(on?'已保存：接口上报已开启，将每小时上报':'已保存：接口上报地址已配置，自动上报未开启'):'已保存：接口上报未配置地址（不影响下方通知推送）',url&&on?'var(--ok)':'var(--t3)');
  loadReportPage();
  setTimeout(()=>reportMsg(''),4000);
});

// 定时任务开关：切换即保存，立即反映「是否会执行」
document.getElementById('reportOn')?.addEventListener('change',async()=>{
  const on=!!document.getElementById('reportOn')?.checked;
  const sv=await saveSilent();
  if(!sv.ok){reportMsg('保存失败：'+sv.err,'var(--d)');return}
  reportMsg(on?'每小时接口上报已开启':'每小时接口上报已关闭','var(--t3)');
  loadReportPage();
});
document.getElementById('dailyTmplOn')?.addEventListener('change',async()=>{
  const on=!!document.getElementById('dailyTmplOn')?.checked;
  const sv=await saveSilent();
  if(!sv.ok){tmplMsg('保存失败：'+sv.err,'var(--d)');return}
  tmplMsg(on?'每日通知已开启':'每日通知已关闭','var(--t3)');
  loadReportPage();
});

document.getElementById('saveTmpl')?.addEventListener('click',async()=>{
  const dUrl=(document.getElementById('dailyTmplUrl')?.value||'').trim();
  if(dUrl && !/^https?:\/\//i.test(dUrl)){tmplMsg('日报发送地址需以 http:// 或 https:// 开头','var(--d)');return}
  await save();
  const tmpl=!!document.getElementById('dailyTmplOn')?.checked;
  tmplMsg(dUrl?(tmpl?'已保存：通知推送已启用，每日 00:10 发送':'已保存：发送地址已配置，但「按模板发送」未勾选'):'已保存：通知推送未配置发送地址（不影响上方接口上报）',dUrl&&tmpl?'var(--ok)':'var(--t3)');
  loadReportPage();
  setTimeout(()=>tmplMsg(''),4000);
});
// 上报回显弹窗：发送内容与接收端返回分标签页展示，避免一起滚动过高
function rpModalTab(t){
  const s=document.getElementById('rpTabSent'),rr=document.getElementById('rpTabResp');
  const bs=document.getElementById('rpTabBS'),br=document.getElementById('rpTabBR');
  if(!s||!rr)return;
  s.style.display=t==='sent'?'block':'none';
  rr.style.display=t==='resp'?'block':'none';
  if(bs){bs.style.background=t==='sent'?'var(--pd,#2563eb)':'transparent';bs.style.color=t==='sent'?'#fff':'var(--t2,#666)'}
  if(br){br.style.background=t==='resp'?'var(--pd,#2563eb)':'transparent';br.style.color=t==='resp'?'#fff':'var(--t2,#666)'}
}
function showReportModal(title,headHTML,sentHTML,respHTML){
  let tgWarn='';
  try{
    const m=(sentHTML.match(/https?:\/\/[^<\s"']*api\.telegram\.org[^<\s"']*/)||[''])[0];
    if(/getUpdates|getMe|setWebhook|deleteWebhook/.test(m)){
      tgWarn='<div style="background:rgba(239,68,68,.08);border:1px solid rgba(239,68,68,.35);color:#b91c1c;font-size:12.5px;padding:8px 10px;border-radius:8px;margin:0 0 10px">⚠️ Telegram 地址以 /getUpdates 结尾只能「收取消息」，发不出通知。请把结尾改为 <b>/sendMessage</b>，Content-Type 选 <b>application/json</b>，模板保持 JSON 格式（含 chat_id 和 text 字段）</div>';
    }else if(/api\.telegram\.org/.test(m)&&/x-www-form-urlencoded/.test(sentHTML)&&/^\s*\{/.test(sentHTML)){
      tgWarn='<div style="background:rgba(245,158,11,.1);border:1px solid rgba(245,158,11,.4);color:#b45309;font-size:12.5px;padding:8px 10px;border-radius:8px;margin:0 0 10px">提示：模板是 JSON 格式，Content-Type 建议选 <b>application/json</b>，否则 Telegram 可能解析不到 chat_id/text 参数</div>';
    }
  }catch(e){}
  document.getElementById('modalTitle').textContent=title;
  document.getElementById('modalBody').innerHTML=headHTML+tgWarn
    +'<div style="display:flex;gap:8px;margin:2px 0 10px">'
    +'<button type="button" id="rpTabBS" onclick="rpModalTab(\'sent\')" style="padding:5px 14px;border-radius:8px;border:1px solid rgba(128,128,128,.3);background:var(--pd,#2563eb);color:#fff;cursor:pointer;font-size:12.5px;font-weight:600">发送内容</button>'
    +'<button type="button" id="rpTabBR" onclick="rpModalTab(\'resp\')" style="padding:5px 14px;border-radius:8px;border:1px solid rgba(128,128,128,.3);background:transparent;color:var(--t2,#666);cursor:pointer;font-size:12.5px;font-weight:600">接收端返回</button>'
    +'</div>'
    +'<div id="rpTabSent">'+sentHTML+'</div>'
    +'<div id="rpTabResp" style="display:none">'+respHTML+'</div>';
  document.getElementById('modal').classList.add('on');
}

document.getElementById('testReport')?.addEventListener('click',async()=>{
  reportMsg('正在保存配置并上报…');
  const sv=await saveSilent();
  if(!sv.ok){reportMsg('配置保存失败，已中止上报：'+sv.err,'var(--d)');return}
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'test'})});
    const d=await r.json().catch(()=>({}));
    if(d && d.payload!==undefined){
      const head=d.ok
        ?'<div style="color:var(--ok);font-weight:600;margin-bottom:10px">✓ 上报成功（HTTP '+d.resp_status+'）</div>'
        :'<div style="color:var(--d);font-weight:600;margin-bottom:10px">✗ 上报失败：'+esc(d.error||'')+'<br><span style="font-weight:400;color:var(--t3)">数据已存入队列，稍后自动重试</span></div>';
      showReportModal('上报回显',head,
        '<div style="font-size:12px;font-weight:600;color:var(--t2);margin-bottom:4px">发送的数据</div>'
        +'<pre class="rp-pre" style="max-height:420px">'+esc(JSON.stringify(d.payload,null,2))+'</pre>',
        '<div style="font-size:12px;font-weight:600;color:var(--t2);margin-bottom:4px">接收端返回（HTTP '+d.resp_status+'）</div>'
        +'<pre class="rp-pre" style="max-height:420px">'+esc(d.resp_body||'（空）')+'</pre>');
      reportMsg(d.ok?'上报成功，详见弹窗':'上报失败，详见弹窗',d.ok?'var(--ok)':'var(--d)');
    }else{
      reportMsg(d.error||('HTTP '+r.status),'var(--d)');
    }
    loadReportRecords(); loadReportQueueStat();
  }catch(e){reportMsg('网络异常：'+e.message,'var(--d)')}
});

document.getElementById('dailyReport')?.addEventListener('click',async()=>{
  const dUrl=(document.getElementById('dailyTmplUrl')?.value||'').trim();
  if(!dUrl){tmplMsg('请先填写「日报发送地址」','var(--d)');return}
  if(/\/getUpdates\b/i.test(dUrl)){
    showReportModal('地址填写有误',
      '<div style="color:var(--d);font-weight:600;margin-bottom:10px">✗ 未发送：日报发送地址结尾是 /getUpdates</div>',
      '<div style="background:rgba(239,68,68,.08);border:1px solid rgba(239,68,68,.35);color:#b91c1c;font-size:13px;padding:10px 12px;border-radius:8px;line-height:1.7">'
      +'<b>/getUpdates</b> 是「拉取 bot 收到的消息」的接口，POST 任何内容都只会返回 <code>{"ok":true,"result":[]}</code>，<b>消息不会发出</b>。<br><br>'
      +'请把地址结尾改为 <b>/sendMessage</b>：<br><code style="word-break:break-all">https://api.telegram.org/bot&lt;Token&gt;/sendMessage</code><br><br>'
      +'同时把 Content-Type 选为 <b>application/json</b>，模板保持 JSON 格式（含 chat_id 与 text）。改完点「保存配置」再发送。</div>',
      '<div style="font-size:12.5px;color:var(--t2)">修正地址后再试。</div>');
    tmplMsg('地址结尾是 /getUpdates，发不出消息，请改为 /sendMessage','var(--d)');
    return;
  }
  tmplMsg('正在保存配置并发送昨日统计…');
  const sv=await saveSilent();
  if(!sv.ok){tmplMsg('配置保存失败，已中止发送：'+sv.err,'var(--d)');return}
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'daily'})});
    const d=await r.json().catch(()=>({}));
    if(d && d.payload!==undefined){
      const head=d.ok
        ?'<div style="color:var(--ok);font-weight:600;margin-bottom:10px">✓ 昨日统计发送成功（HTTP '+d.resp_status+'）</div>'
        :'<div style="color:var(--d);font-weight:600;margin-bottom:10px">✗ 发送失败：'+esc(d.error||'')+'<br><span style="font-weight:400;color:var(--t3)">数据已存入队列，稍后自动重试</span></div>';
      const sentHTML=d.text!==undefined
        ?'<div style="font-size:12px;font-weight:600;color:var(--t2);margin-bottom:4px">发送的内容（'+esc(d.content_type||'text/plain')+' → '+esc(d.target||'')+'）</div>'
          +'<pre class="rp-pre" style="max-height:420px">'+esc(d.text)+'</pre>'
        :'<div style="font-size:12px;font-weight:600;color:var(--t2);margin-bottom:4px">发送的数据</div>'
          +'<pre class="rp-pre" style="max-height:420px">'+esc(JSON.stringify(d.payload,null,2))+'</pre>';
      showReportModal('昨日统计上报回显',head,sentHTML,
        '<div style="font-size:12px;font-weight:600;color:var(--t2);margin-bottom:4px">接收端返回（HTTP '+d.resp_status+'）</div>'
        +'<pre class="rp-pre" style="max-height:420px">'+esc(d.resp_body||'（空）')+'</pre>');
      tmplMsg(d.ok?'昨日统计发送成功，详见弹窗':'发送失败，详见弹窗',d.ok?'var(--ok)':'var(--d)');
    }else{
      tmplMsg(d.error||('HTTP '+r.status),'var(--d)');
    }
    loadReportRecords(); loadReportQueueStat();
  }catch(e){tmplMsg('网络异常：'+e.message,'var(--d)')}
});

document.getElementById('reportRetry')?.addEventListener('click',async()=>{
  reportMsg('正在补传…');
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'retry'})});
    const d=await r.json().catch(()=>({}));
    if(!r.ok){reportMsg(d.error||'补传失败','var(--d)');return}
    if(!d.before){reportMsg('队列为空，没有需要补传的数据','var(--ok)');return}
    reportMsg(d.sent>0?('已补传 '+d.sent+' 批，剩余 '+(d.after||0)+' 批未发出'):('补传失败，仍有 '+(d.after||0)+' 批排队，请检查接收地址或网络'),d.sent>0?'var(--ok)':'var(--d)');
    loadReportRecords(); loadReportQueueStat();
  }catch(e){reportMsg('网络异常：'+e.message,'var(--d)')}
});

document.getElementById('reportClear')?.addEventListener('click',async()=>{
  if(!confirm('确定清空上报快照链？清空后：手动上报会立即补建新快照重新开始，整点自动上报从下一个整点起恢复正常。排队中未发出的数据与历史记录不受影响。'))return;
  reportMsg('清空中…');
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'clear'})});
    const d=await r.json().catch(()=>({}));
    if(!r.ok){reportMsg(d.error||'清空失败','var(--d)');return}
    reportMsg('快照已清空，到整点后会重新开始记录','var(--ok)');
  }catch(e){reportMsg('网络异常：'+e.message,'var(--d)')}
});

document.getElementById('reportClearQueue')?.addEventListener('click',async()=>{
  if(!confirm('确定清空全部待补传队列？被清空的数据不再重试发送（上传记录与日报防重标记不受影响）。通常在确认这些数据不需要了、或想清掉历史失败项时使用。'))return;
  reportMsg('清空队列中…');
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'clear_queue'})});
    const d=await r.json().catch(()=>({}));
    if(!r.ok){reportMsg(d.error||'清空失败','var(--d)');return}
    reportMsg('已清空 '+(d.cleared||0)+' 条待补传队列项','var(--ok)');
    loadReportQueueStat(); loadReportRecords();
  }catch(e){reportMsg('网络异常：'+e.message,'var(--d)')}
});

document.getElementById('rpRefresh')?.addEventListener('click',()=>{loadReportRecords();loadReportQueueStat()});
document.getElementById('rpClearRec')?.addEventListener('click',async()=>{
  if(!confirm('确定清空全部上报记录？仅删除「上传记录」列表与保存的原始报文，不影响上报配置、快照与待补传数据。'))return;
  try{
    const r=await fetch('/admin/api/report',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'clearrec'})});
    const d=await r.json().catch(()=>({}));
    if(!r.ok){alert(d.error||'清空失败');return}
    rpState.page=1; loadReportRecords();
  }catch(e){alert('网络异常：'+e.message)}
});
document.getElementById('rpQ')?.addEventListener('input',()=>{rpState.page=1;rpRenderTable()});
document.getElementById('rpResult')?.addEventListener('change',()=>{rpState.page=1;rpRenderTable()});
document.getElementById('rpTrigger')?.addEventListener('change',()=>{rpState.page=1;rpRenderTable()});
document.getElementById('rpPrev')?.addEventListener('click',()=>{if(rpState.page>1){rpState.page--;rpRenderTable()}});
document.getElementById('rpNext')?.addEventListener('click',()=>{rpState.page++;rpRenderTable()});

document.getElementById('changePassBtn').addEventListener('click',async()=>{
  const o=document.getElementById('oldPass').value,n=document.getElementById('newPass').value;
  if(!o||!n||n.length<6){alert('请先填写当前密码，新密码至少 6 位');return}
  const r=await fetch('/admin/api/change-password',{method:'POST',body:JSON.stringify({OldPass:o,NewPass:n})});
  if(r.ok){alert('密码修改成功，即将跳转到登录页，请用新密码重新登录');location.reload()}else{alert('密码修改失败：'+(await r.text()||'未知错误'))}
});
document.getElementById('blkFilterBtn')?.addEventListener('click',()=>{blkState.page=1;loadBlocks()});
document.getElementById('blkResetBtn')?.addEventListener('click',()=>{
  const q=document.getElementById('blkQ'); if(q)q.value='';
  const r=document.getElementById('blkReason'); if(r)r.value='';
  const i=document.getElementById('blkIP'); if(i)i.value='';
  blkState.page=1; loadBlocks();
});
document.getElementById('blkQ')?.addEventListener('keydown',e=>{if(e.key==='Enter'){blkState.page=1;loadBlocks()}});
document.getElementById('blkIP')?.addEventListener('keydown',e=>{if(e.key==='Enter'){blkState.page=1;loadBlocks()}});
document.getElementById('blkPrev')?.addEventListener('click',()=>{if(blkState.page>1){blkState.page--;loadBlocks()}});
document.getElementById('blkNext')?.addEventListener('click',()=>{blkState.page++;loadBlocks()});
document.getElementById('blkExport')?.addEventListener('click',()=>{
  const p=blkParams(); window.location='/admin/api/blocks.csv?'+p.toString();
});

document.getElementById('auditRefresh')?.addEventListener('click',()=>loadAudit());
document.getElementById('auditAction')?.addEventListener('change',()=>{audState.page=1;loadAudit()});
document.getElementById('auditPrev')?.addEventListener('click',()=>{if(audState.page>1){audState.page--;loadAudit()}});
document.getElementById('auditNext')?.addEventListener('click',()=>{audState.page++;loadAudit()});

document.getElementById('themeBtn')?.addEventListener('click',()=>{
  const next=currentTheme()==='dark'?'light':'dark';
  document.documentElement.setAttribute('data-theme',next);
  try{localStorage.setItem('ep_theme',next)}catch(e){}
  if(typeof Chart!=='undefined'){
    try{
      Object.values(Chart.instances||{}).forEach(c=>{ try{c.destroy()}catch(e){} });
    }catch(e){}
    miniTrendChart=miniByteChart=reqChart=byteChart=hostChart=null;
    if(document.getElementById('overview')?.classList.contains('on'))loadOverview();
    if(document.getElementById('traffic')?.classList.contains('on'))loadTraffic();
  }
});
function switchSetTab(key){
  document.querySelectorAll('.set-tab').forEach(b=>b.classList.toggle('on',b.dataset.st===key));
  document.querySelectorAll('.set-pane').forEach(pn=>{ pn.style.display = (pn.id==='pane-'+key)?'':'none'; });
  try{ localStorage.setItem('ep_set_tab',key) }catch(e){}
}
document.querySelectorAll('.set-tab').forEach(b=>b.addEventListener('click',()=>switchSetTab(b.dataset.st)));
try{ const saved=localStorage.getItem('ep_set_tab'); if(saved&&document.getElementById('pane-'+saved))switchSetTab(saved); }catch(e){}

document.getElementById('rtFillHost')?.addEventListener('click',()=>{
  const el=document.getElementById('rtAccessHost'); if(el) el.value=location.host;
});
document.getElementById('rtFillUA')?.addEventListener('click',()=>{
  const el=document.getElementById('rtUA'); if(el) el.value=navigator.userAgent;
});
// 判定链面板由后端 ruleChainOrder 渲染，保证与真实请求、规则测试同源（静态 HTML 为加载前兜底）
(async()=>{
  try{
    const r=await fetch('/admin/api/rules/chain');
    if(!r.ok)return;
    const d=await r.json();
    const box=document.getElementById('rtChain');
    if(!box||!d.chain||!d.chain.length)return;
    box.innerHTML=d.chain.map(s=>`<div class="tl-i ${s.kind==='pass'?'pass':'block'}"><div class="tl-d"></div><div class="tl-n">${esc(s.name)}</div><div class="tl-v">${esc(s.detail)}</div></div>`).join('');
  }catch(e){}
})();
document.getElementById('rtRun')?.addEventListener('click',async()=>{
  const box=document.getElementById('rtResult');
  const body={
    access_host:(document.getElementById('rtAccessHost')?.value||'').trim(),
    ip:(document.getElementById('rtIP')?.value||'').trim(),
    host:(document.getElementById('rtHost')?.value||'').trim(),
    ua:(document.getElementById('rtUA')?.value||'').trim()
  };
  box.innerHTML='<div style="color:var(--t3);font-size:13px;padding:10px 0">测试中…</div>';
  try{
    const r=await fetch('/admin/api/rules/test',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    const txt=await r.text();
    if(!r.ok)throw new Error(txt.trim()||('HTTP '+r.status));
    const d=JSON.parse(txt);
    const steps=(d.steps||[]).map(st=>`<div class="tl-i ${esc(st.status||'skip')}"><div class="tl-d"></div><div class="tl-n">${esc(st.name)}</div><div class="tl-v">${esc(st.detail)}</div></div>`).join('');
    const pass=d.result==='pass';
    const reasonTxt=d.reason?'（原因码 '+esc(d.reason)+'）':'';
    const adm=d.admin_access==='denied'?' · 后台访问：不可访问 /admin':(d.admin_access==='allowed'?' · 后台访问：允许':'');
    box.innerHTML=`<div class="tl">${steps}</div>
      <div class="tl-res ${pass?'pass':'block'}">${pass?'✓ 该请求会被放行并转发':('✕ 该请求会被拦截'+reasonTxt)}</div>
      <div style="margin-top:10px;font-size:12px;color:var(--t3);word-break:break-all">
        访问域名 ${esc(d.access_host||'—')} · 来源 ${esc(d.ip)} · 地区 ${esc(d.country_name||d.country||'—')} · 客户端归类 ${esc(d.ua_class||'—')}${adm}
      </div>`;
  }catch(e){
    box.innerHTML='<div style="color:var(--d);font-size:13px;padding:10px 0">测试失败：'+esc(e.message||'')+'</div>';
  }
});

document.getElementById('btnBackup')?.addEventListener('click',()=>{ window.location='/admin/api/backup' });
document.getElementById('btnExportCfg')?.addEventListener('click',()=>{ window.location='/admin/api/config/export' });
document.getElementById('importCfgFile')?.addEventListener('change',async(e)=>{
  const f=e.target.files&&e.target.files[0];
  const msg=document.getElementById('backupMsg');
  if(!f)return;
  if(!confirm('导入配置会覆盖当前网关设置（端口保持不变），确定继续？')){e.target.value='';return}
  msg.style.color='var(--t3)'; msg.textContent='导入中…';
  try{
    const text=await f.text();
    const r=await fetch('/admin/api/config/import',{method:'POST',body:text});
    const d=await r.json().catch(()=>({}));
    if(!r.ok){msg.style.color='var(--d)';msg.textContent='导入失败：'+(d.error||('HTTP '+r.status));return}
    msg.style.color='var(--ok)'; msg.textContent='导入成功，端口保持 :'+d.port_kept+'，正在刷新页面…';
    setTimeout(()=>location.reload(),900);
  }catch(err){
    msg.style.color='var(--d)'; msg.textContent='导入失败：'+(err.message||'未知错误');
  }finally{ e.target.value=''; }
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
  const box=document.getElementById('ovCustomBox');
  if(box) box.style.display = state.ovRange==='custom' ? 'flex' : 'none';
  if(state.ovRange==='custom'){
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

window.addEventListener('beforeinstallprompt',e=>{ e.preventDefault(); });

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
    if(document.getElementById('blocks')?.classList.contains('on'))loadBlocks();
    if(document.getElementById('audit')?.classList.contains('on'))loadAudit();
  }
});
</script>
</body>
</html>
ADMIN_HTML

  sed -i \
    -e "s/路径反代 v[0-9][0-9.]*管理控制台/路径反代 v${APP_VERSION}管理控制台/" \
    -e "s/^const appVersionStr = \".*\"\$/const appVersionStr = \"${APP_VERSION}\"/" \
    "$dir/main.go"
}

compute_source_hash() {
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"
  local d h
  d="$(mktemp -d)"
  write_go_source "$d"
  h="$(cd "$d" && sha256sum main.go features.go admin.html chart.umd.min.js | sha256sum | awk '{print $1}')"
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
# 崩溃时不要以 RestartSec=5s 无限重启：否则错误配置会每 5 秒刷一条日志，
# 既刷爆 journal 又掩盖真正原因。60 秒内失败 5 次就停下来等人处理。
StartLimitIntervalSec=60
StartLimitBurst=5
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
# installed_port 返回当前应显示的监听端口。
# 优先读正在运行进程的实际监听端口（后台改端口后 unit 不会同步），
# 其次读 unit 文件中的 -port，最后回退默认端口。
installed_port() {
  local p=""
  # 优先读正在运行进程的实际监听端口（后台改端口后 unit 文件不会同步更新）
  if command -v ss >/dev/null 2>&1; then
    p="$(ss -lntup 2>/dev/null | awk -v name="$SERVICE_NAME" '
      $0 ~ name && $1 == "tcp" {
        split($5, a, ":");
        port=a[length(a)];
        if (port ~ /^[0-9]+$/) { print port; exit }
      }')"
  fi
  # 回退：读 unit 文件里的 -port
  if [[ -z "$p" && -f "$UNIT_FILE" ]]; then
    p="$(sed -n 's/.*-port \([0-9]\{1,5\}\).*/\1/p' "$UNIT_FILE" 2>/dev/null | head -1)"
  fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then printf '%s' "$p"; else printf '%s' "$DEFAULT_PORT"; fi
}
effective_port() { installed_port; }
print_access_info() {
  local ip ep; ip="$(local_ip)"; ep="$(effective_port)"
  printf '\n   管理页:  http://%s:%s/admin/\n' "$ip" "$ep"
  printf '   用户名:  %s\n' "$ADMIN_USER"
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

# cmd_install 执行完整安装：检查环境、编译、写 unit、启动服务。
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
  if [[ ${first_boot:-0} -eq 1 ]] && systemctl is-active --quiet "$SERVICE_NAME"; then
    printf '%s\n' "$expected_unit" > "$UNIT_FILE"
    chmod 0600 "$UNIT_FILE"
    systemctl daemon-reload
    info "首次引导完成，已从 unit 中移除明文密码（后续以数据库哈希为准）"
  fi
  sleep 1
  local waited=0 ep
  ep="$(effective_port)"
  while [[ $waited -lt 20 ]]; do
    if systemctl is-active --quiet "$SERVICE_NAME" && port_listen "$ep"; then break; fi
    sleep 1; waited=$((waited + 1))
  done
  if systemctl is-active --quiet "$SERVICE_NAME" && port_listen "$ep"; then
    info "🎉 安装完成！端口 $ep 已监听"
    print_access_info
  elif systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "服务已启动，端口暂未监听（稍等几秒）"
    print_access_info
  else
    err "启动失败，最近日志如下（可直接复制给我）："
    printf '\033[0;90m%s\033[0m\n' "------------------------------------------------------------"
    journalctl -u "$SERVICE_NAME" -n 60 --no-pager -o cat 2>/dev/null || true
    printf '\033[0;90m%s\033[0m\n' "------------------------------------------------------------"
    err "常见原因：端口 $ep 被占用 / 数据库被其他进程锁住 / 二进制无执行权限"
    die "完整日志: journalctl -u $SERVICE_NAME -n 80 --no-pager"
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
  printf '  %s⚡ Emby 路径反代 v%s%s  %s·%s  %s安装管理菜单%s\n' "$C_B" "$APP_VERSION" "$C_0" "$C_D" "$C_0" "$C_D" "$C_0"
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
# cmd_menu 交互式安装管理菜单（安装 / 更新 / 卸载 / 状态 / 日志）。
# 需要终端环境；非交互场景请直接使用子命令。
cmd_menu() {
  if [[ $EUID -ne 0 ]]; then die "菜单需要 root 权限: sudo $0"; fi
  if [[ ! -t 0 ]]; then die "菜单需要交互终端。请先下载脚本再运行以使用菜单: curl -fsSL https://raw.githubusercontent.com/SunMoonWithYou/emby_rp_vps_go/main/install.sh -o install.sh && sudo bash install.sh"; fi
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
