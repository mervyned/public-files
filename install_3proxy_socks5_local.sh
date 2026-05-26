#!/usr/bin/env bash
set -Eeuo pipefail

# 在云服务器本机安装多 IP SOCKS5 代理，使用 3proxy 并强制账号密码认证。

DEB_URL="${DEB_URL:-https://raw.githubusercontent.com/mervyned/public-files/refs/heads/main/3proxy-0.9.6.x86_64.deb}"
SOCKS_PORT="${SOCKS_PORT:-11088}"
PROXY_USER="${PROXY_USER:-dfm}"
PROXY_PASS="${PROXY_PASS:-dfm2026}"
ALLOW_CIDR="${ALLOW_CIDR:-0.0.0.0/0}"
ENABLE_UDP="${ENABLE_UDP:-1}"
UDP_PORT_RANGE="${UDP_PORT_RANGE:-20000-50000}"
BIND_IPS_RAW="${BIND_IPS_RAW:-auto}"
RUN_TEST="${RUN_TEST:-0}"

# 打印脚本使用帮助。
usage() {
  cat <<'EOF'
用法:
  sudo ./install_3proxy_socks5_local.sh [选项]

常用选项:
  --bind-ips "ip1/ip2/ip3"    手动指定绑定 IP；默认 auto，自动绑定非 127.0.0.1 的 IPv4
  --socks-port 11088          SOCKS5 端口，默认 11088
  --proxy-user dfm            SOCKS5 用户名，默认 dfm
  --proxy-pass dfm2026        SOCKS5 密码，默认 dfm2026
  --allow-cidr CIDR           允许访问代理的来源网段，默认 0.0.0.0/0
  --udp-port-range A-B        UDP relay 端口范围，默认 20000-50000
  --disable-udp               关闭 UDP 支持
  --deb-url URL               3proxy deb 下载地址
  --test                      安装后测试 TCP SOCKS5 出口
  -h, --help                  查看帮助

输出格式:
  ip/端口/用户名/密码
EOF
}

# 输出错误并退出。
die() {
  echo "错误: $*" >&2
  exit 1
}

# 输出当前执行进度。
info() {
  echo "==> $*" >&2
}

# 检查命令是否存在。
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

# 校验端口范围。
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

# 粗略校验 IPv4 格式。
is_valid_ip_like() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# 解析 / 分隔的 IP 列表。
normalize_ips() {
  printf "%s" "$1" | tr '/' ' ' | xargs
}

# 解析命令行参数。
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bind-ips)
        BIND_IPS_RAW="${2:-}"
        shift 2
        ;;
      --socks-port)
        SOCKS_PORT="${2:-}"
        shift 2
        ;;
      --proxy-user)
        PROXY_USER="${2:-}"
        shift 2
        ;;
      --proxy-pass)
        PROXY_PASS="${2:-}"
        shift 2
        ;;
      --allow-cidr)
        ALLOW_CIDR="${2:-}"
        shift 2
        ;;
      --udp-port-range)
        UDP_PORT_RANGE="${2:-}"
        shift 2
        ;;
      --disable-udp)
        ENABLE_UDP=0
        shift
        ;;
      --deb-url)
        DEB_URL="${2:-}"
        shift 2
        ;;
      --test)
        RUN_TEST=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
}

# 检查参数和运行环境。
prepare() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 或 sudo 执行"
  is_valid_port "$SOCKS_PORT" || die "SOCKS5 端口不合法: $SOCKS_PORT"
  [[ "$ENABLE_UDP" == "0" || "$ENABLE_UDP" == "1" ]] || die "ENABLE_UDP 只能是 0 或 1"
  [[ "$UDP_PORT_RANGE" =~ ^[0-9]+[-:][0-9]+$ ]] || die "UDP 端口范围格式应为 A-B"
  [[ -n "$PROXY_USER" ]] || die "SOCKS5 用户名不能为空"
  [[ -n "$PROXY_PASS" ]] || die "SOCKS5 密码不能为空"
  [[ "$PROXY_USER" != *":"* && "$PROXY_USER" != *" "* ]] || die "SOCKS5 用户名不能包含空白或冒号"
  [[ "$PROXY_PASS" != *":"* && "$PROXY_PASS" != *" "* ]] || die "SOCKS5 密码不能包含空白或冒号"
  need_cmd ip
}

# 解析需要绑定的本机 IPv4 地址。
resolve_bind_ips() {
  if [[ "$BIND_IPS_RAW" == "auto" ]]; then
    BIND_IPS="$(ip -o -4 addr show scope global | awk '{split($4,a,"/"); if (a[1] != "127.0.0.1") print a[1]}' | xargs)"
  else
    [[ "$BIND_IPS_RAW" != *","* && "$BIND_IPS_RAW" != *" "* ]] || die "--bind-ips 仅支持 / 分隔"
    BIND_IPS="$(normalize_ips "$BIND_IPS_RAW")"
  fi

  [[ -n "$BIND_IPS" ]] || die "未发现可绑定的非 127.0.0.1 IPv4 地址"
  local ip
  for ip in $BIND_IPS; do
    is_valid_ip_like "$ip" || die "IP 格式不合法: $ip"
  done
}

# 使用当前系统包管理器安装基础依赖。
install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    #apt-get update -y
    apt-get install -y ca-certificates curl
  else
    die "当前版本只支持 apt-get 系统"
  fi
}

# 下载并安装 3proxy deb 包。
install_3proxy() {
  if command -v 3proxy >/dev/null 2>&1; then
    info "3proxy 已安装"
    return
  fi

  install_deps
  local tmp_deb="/tmp/3proxy-0.9.6.x86_64.deb"
  info "下载 3proxy deb 包"
  curl -fL "$DEB_URL" -o "$tmp_deb"
  info "安装 3proxy deb 包"
  apt-get install -y "$tmp_deb"
  command -v 3proxy >/dev/null 2>&1 || die "3proxy 安装失败"
}

# 设置 UDP relay 临时端口范围。
configure_udp_range() {
  [[ "$ENABLE_UDP" == "1" ]] || return 0
  UDP_PORT_RANGE="${UDP_PORT_RANGE/:/-}"
  local start_port end_port
  start_port="${UDP_PORT_RANGE%-*}"
  end_port="${UDP_PORT_RANGE#*-}"
  [[ "$start_port" =~ ^[0-9]+$ && "$end_port" =~ ^[0-9]+$ ]] || die "UDP 端口范围不合法: $UDP_PORT_RANGE"
  (( start_port >= 1024 && start_port <= end_port && end_port <= 65535 )) || die "UDP 端口范围应在 1024-65535 内: $UDP_PORT_RANGE"

  # 让 3proxy 动态 UDP relay 端口落在云安全组放行范围内。
  sysctl -w "net.ipv4.ip_local_port_range=${start_port} ${end_port}" >/dev/null
  cat >/etc/sysctl.d/99-3proxy-udp-port-range.conf <<EOF
net.ipv4.ip_local_port_range = ${start_port} ${end_port}
EOF
}

# 写入 3proxy 配置文件。
write_config() {
  local cfg="/etc/3proxy/3proxy.cfg"
  mkdir -p /etc/3proxy /var/log/3proxy
  touch /var/log/3proxy/3proxy.log

  cat >"$cfg" <<EOF
daemon
pidfile /run/3proxy.pid
maxconn 4096
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
log /var/log/3proxy/3proxy.log D
rotate 14
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
allow ${PROXY_USER} ${ALLOW_CIDR}
EOF

  local ip
  for ip in $BIND_IPS; do
    # 每个本机 IP 独立监听，并指定同一 IP 作为出口。
    printf "socks -p%s -i%s -e%s\n" "$SOCKS_PORT" "$ip" "$ip" >>"$cfg"
  done

  printf "flush\n" >>"$cfg"
  chmod 600 "$cfg"
}

# 写入 systemd 服务文件。
write_service() {
  local bin_path
  bin_path="$(command -v 3proxy)"

  cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy SOCKS5 service
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=${bin_path} /etc/3proxy/3proxy.cfg
PIDFile=/run/3proxy.pid
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# 启动并校验 3proxy 服务。
start_service() {
  systemctl daemon-reload
  systemctl enable 3proxy >/dev/null
  systemctl restart 3proxy
  sleep 1
  systemctl is-active --quiet 3proxy || {
    systemctl --no-pager --full status 3proxy >&2 || true
    die "3proxy 启动失败"
  }
}

# 可选测试 TCP SOCKS5 出口。
test_endpoints() {
  [[ "$RUN_TEST" == "1" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local ip output
  for ip in $BIND_IPS; do
    info "测试 SOCKS5: ${ip}:${SOCKS_PORT}"
    if output="$(curl --silent --show-error --max-time 15 --socks5-hostname "${PROXY_USER}:${PROXY_PASS}@${ip}:${SOCKS_PORT}" https://api.ipify.org 2>&1)"; then
      echo "    出口 IP: $output" >&2
    else
      echo "    测试失败: $output" >&2
    fi
  done
}

# 按 ip/端口/用户名/密码 格式打印结果。
print_summary() {
  local ip
  for ip in $BIND_IPS; do
    echo "${ip}/${SOCKS_PORT}/${PROXY_USER}/${PROXY_PASS}"
  done
}

# 执行主流程。
main() {
  parse_args "$@"
  prepare
  resolve_bind_ips
  install_3proxy
  configure_udp_range
  write_config
  write_service
  start_service
  test_endpoints
  print_summary
}

main "$@"
