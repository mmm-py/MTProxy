#!/usr/bin/env bash
set -euo pipefail

MT_DIR="/opt/MTProxy"
PID_MAX_FILE="/etc/sysctl.d/99-mtproxy-pidmax.conf"
INSTALL_LOG="/tmp/mtproxy_nbzai_install.log"

install_log_init() {
  : > "${INSTALL_LOG}"
  {
    echo "=== NBZAI MTProxy install log ==="
    date -Is 2>/dev/null || date
    echo "================================="
  } >>"${INSTALL_LOG}"
}

draw_progress() {
  local pct=$1 msg=$2
  local width=20 filled empty fills dashes
  width=20
  filled=$((width * pct / 100))
  [[ "${filled}" -gt "${width}" ]] && filled="${width}"
  empty=$((width - filled))
  fills="$(printf '%*s' "${filled}" '' | tr ' ' '=')"
  dashes="$(printf '%*s' "${empty}" '' | tr ' ' '-')"
  printf '  [%s%s] %3d%%  %s\n' "${fills}" "${dashes}" "${pct}" "${msg}"
}

install_fail_tail() {
  echo "" >&2
  echo "安装步骤失败。日志尾部 (${INSTALL_LOG}):" >&2
  tail -n 60 "${INSTALL_LOG}" >&2
  exit 1
}

show_nbzai_banner() {
  local bold="" reset=""
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    bold="$(tput bold 2>/dev/null || true)"
    reset="$(tput sgr0 2>/dev/null || true)"
  fi

  printf '\n%s' "${bold}"
  cat <<'BANNER'
================================================================================
                                                                                
     NNNN         BBBBB       ZZZZZ       AAA        III                        
     N   N        B   B          Z       A   A        I                         
     N   N        BBBB          Z        AAAAA        I                         
     N   N        B   B        Z         A   A        I                         
     N   N        BBBBB       ZZZZZ      A   A       III                        
                                                                                
BANNER
  printf '%s\n' "${reset}"

  cat <<'META'
--------------------------------------------------------------------------------
  MTProxy 一键安装脚本
  牛逼仔开发
  Telegram: https://t.me/nbzai   (@nbzai)
--------------------------------------------------------------------------------
META
  printf '\n'
}

gen_hex32() {
  head -c 16 /dev/urandom | xxd -p -c 256 | tr -d '\n'
}

detect_public_ipv4() {
  local ip=""
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    if ip="$(curl -fsS --max-time 6 "${url}" 2>/dev/null | tr -d '[:space:]')"; then
      if [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf '%s' "${ip}"
        return 0
      fi
    fi
  done
  return 1
}

ensure_pid_compatibility() {
  local current_pid_max current_pid
  current_pid_max="$(cat /proc/sys/kernel/pid_max)"
  current_pid="$(cat /proc/sys/kernel/ns_last_pid 2>/dev/null || echo 0)"

  if [[ "${current_pid_max}" -gt 65535 ]]; then
    echo "Adjusting kernel.pid_max to 65535 for MTProxy compatibility..." >>"${INSTALL_LOG}"
    printf 'kernel.pid_max = 65535\n' > "${PID_MAX_FILE}"
    sysctl --load "${PID_MAX_FILE}" >>"${INSTALL_LOG}" 2>&1 || true
  fi

  if [[ -w /proc/sys/kernel/ns_last_pid && "${current_pid}" -ge 65535 ]]; then
    echo "Resetting ns_last_pid to 30000 to avoid PID assertion crash..." >>"${INSTALL_LOG}"
    echo 30000 > /proc/sys/kernel/ns_last_pid || true
  fi
}

check_tls_domain() {
  echo "Checking TLS_DOMAIN: ${TLS_DOMAIN}" >>"${INSTALL_LOG}"
  if ! getent ahosts "${TLS_DOMAIN}" >>"${INSTALL_LOG}" 2>&1; then
    echo "错误: 无法解析 TLS 伪装域名 ${TLS_DOMAIN}（DNS）。" | tee -a "${INSTALL_LOG}" >&2
    exit 1
  fi
  if ! timeout 8 openssl s_client -connect "${TLS_DOMAIN}:443" -servername "${TLS_DOMAIN}" </dev/null >>"${INSTALL_LOG}" 2>&1; then
    echo "错误: 与 ${TLS_DOMAIN} 的 TLS 握手检测失败。" | tee -a "${INSTALL_LOG}" >&2
    echo "请换一个可正常访问 HTTPS 的域名，例如: www.cloudflare.com" >&2
    exit 1
  fi
  echo "TLS_DOMAIN check passed." >>"${INSTALL_LOG}"
}

issue_letsencrypt_cert() {
  local domain="$1" email="$2"
  echo "Installing certbot (if needed)..." >>"${INSTALL_LOG}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 install -y -qq certbot >>"${INSTALL_LOG}" 2>&1; then
    echo "错误: certbot 安装失败。" | tee -a "${INSTALL_LOG}" >&2
    exit 1
  fi

  if ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "UFW active: allowing 80/tcp for ACME." >>"${INSTALL_LOG}"
    ufw allow 80/tcp >>"${INSTALL_LOG}" 2>&1 || true
    ufw reload >>"${INSTALL_LOG}" 2>&1 || true
  fi

  if ss -lntp 2>/dev/null | grep -qE ':80\s'; then
    echo "错误: TCP 80 端口已被占用，certbot standalone 需要空闲的 80 端口。" | tee -a "${INSTALL_LOG}" >&2
    exit 1
  fi

  echo "Requesting certificate for ${domain} (standalone HTTP-01)..." >>"${INSTALL_LOG}"
  if ! certbot certonly \
    --standalone \
    --non-interactive \
    --quiet \
    --agree-tos \
    -m "${email}" \
    -d "${domain}" \
    --preferred-challenges http >>"${INSTALL_LOG}" 2>&1; then
    echo "错误: certbot 申请证书失败。" | tee -a "${INSTALL_LOG}" >&2
    exit 1
  fi

  {
    echo "Certificate path: /etc/letsencrypt/live/${domain}/"
    echo "Note: MTProxy does not load this certificate by default."
  } >>"${INSTALL_LOG}"
}

sanitize_display_name() {
  printf '%s' "$1" | tr -d '\r\n$`'
}

collect_interactive_config() {
  local detected_ip public_ip_input bind_domain_raw bind_choice le_choice acme_email
  local port_in stats_in workers_in mode_in tls_dom_in secret_in tag_in svc_in name_in

  if detected_ip="$(detect_public_ipv4)"; then
    echo "已检测到公网 IPv4: ${detected_ip}"
  else
    detected_ip=""
    echo "未能自动检测公网 IPv4（请检查本机对外的 HTTPS 访问），可手动输入。"
  fi

  read -rp "本机公网 IPv4（回车 = 使用上方检测值）: " public_ip_input
  DETECTED_PUBLIC_IP="${public_ip_input:-${detected_ip}}"
  if [[ -z "${DETECTED_PUBLIC_IP}" ]]; then
    echo "错误: 未填写公网 IP，且自动检测也失败。"
    exit 1
  fi

  read -rp "导入链接里「服务器」是否使用域名? [y/N]: " bind_choice
  bind_choice="$(printf '%s' "${bind_choice}" | tr '[:upper:]' '[:lower:]')"

  BIND_DOMAIN=""
  APPLY_LE_CERT="n"
  ACME_EMAIL=""

  if [[ "${bind_choice}" == "y" || "${bind_choice}" == "yes" ]]; then
    read -rp "该域名（导入链接中 server=，A 记录须指向本机）: " bind_domain_raw
    BIND_DOMAIN="$(printf '%s' "${bind_domain_raw}" | sed -e 's|^\s*||' -e 's|\s*$||' -e 's|^https\?://||' -e 's|/.*$||')"
    if [[ -z "${BIND_DOMAIN}" ]]; then
      echo "错误: 已选择使用域名，但未填写域名。"
      exit 1
    fi

    resolved="$(getent ahosts "${BIND_DOMAIN}" 2>/dev/null | awk 'NR == 1 { print $1; exit }')"
    if [[ -n "${resolved}" && "${resolved}" != "${DETECTED_PUBLIC_IP}" ]]; then
      echo "警告: ${BIND_DOMAIN} 解析为 ${resolved}，与当前填写的公网 IP ${DETECTED_PUBLIC_IP} 不一致。"
      echo "      请修正 DNS 后再让客户端使用域名，否则可能无法连接。"
    fi

    read -rp "是否为此域名申请 Let's Encrypt 证书? [y/N]: " le_choice
    le_choice="$(printf '%s' "${le_choice}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${le_choice}" == "y" || "${le_choice}" == "yes" ]]; then
      APPLY_LE_CERT="y"
      read -rp "用于 Let's Encrypt 的邮箱: " acme_email
      ACME_EMAIL="${acme_email}"
      if [[ -z "${ACME_EMAIL}" ]]; then
        echo "错误: 申请证书必须填写邮箱。"
        exit 1
      fi
    fi
  fi

  PROXY_SERVER="${BIND_DOMAIN:-${DETECTED_PUBLIC_IP}}"

  read -rp "systemd 服务名 [mtproxy]: " svc_in
  SERVICE_NAME="${svc_in:-mtproxy}"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

  read -rp "代理显示名称（写入 systemd 描述与结尾摘要；回车 = 与上项服务名相同）: " name_in
  PROXY_NAME="$(sanitize_display_name "${name_in:-${SERVICE_NAME}}")"
  if [[ -z "${PROXY_NAME}" ]]; then
    PROXY_NAME="${SERVICE_NAME}"
  fi

  read -rp "客户端连接端口 -H [443]: " port_in
  PORT="${port_in:-443}"

  read -rp "本机统计端口 -p [8888]: " stats_in
  STATS_PORT="${stats_in:-8888}"

  read -rp "工作进程 -M，TLS 模式建议 0 [0]: " workers_in
  WORKERS="${workers_in:-0}"

  read -rp "模式 tls / classic [tls]: " mode_in
  MODE="$(printf '%s' "${mode_in:-tls}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${MODE}" == "tls" ]]; then
    read -rp "TLS 伪装域名 -D [www.cloudflare.com]: " tls_dom_in
    TLS_DOMAIN="${tls_dom_in:-www.cloudflare.com}"
  else
    TLS_DOMAIN=""
  fi

  read -rp "连接密钥 SECRET，32 位十六进制（回车 = 随机）: " secret_in
  if [[ -z "${secret_in}" ]]; then
    SECRET="$(gen_hex32)"
    echo "已生成 SECRET: ${SECRET}"
  else
    SECRET="${secret_in}"
  fi

  read -rp "推广标签 TAG（@MTProxybot 获取，32 位十六进制；回车 = 随机）: " tag_in
  if [[ -z "${tag_in}" ]]; then
    TAG="$(gen_hex32)"
    echo "已生成 TAG: ${TAG}"
  else
    TAG="${tag_in}"
  fi

  if [[ ! "${SECRET}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    echo "错误: SECRET 必须为 32 位十六进制字符。"
    exit 1
  fi
  if [[ ! "${TAG}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    echo "错误: TAG 必须为 32 位十六进制字符。"
    exit 1
  fi
  if [[ ! "${PORT}" =~ ^[0-9]+$ || "${PORT}" -lt 1 || "${PORT}" -gt 65535 ]]; then
    echo "错误: 端口须为 1–65535 的整数。"
    exit 1
  fi
  if [[ ! "${STATS_PORT}" =~ ^[0-9]+$ || "${STATS_PORT}" -lt 1 || "${STATS_PORT}" -gt 65535 ]]; then
    echo "错误: 统计端口须为 1–65535 的整数。"
    exit 1
  fi
  if [[ "${PORT}" == "${STATS_PORT}" ]]; then
    echo "错误: 客户端端口与统计端口不能相同。"
    exit 1
  fi
  if [[ ! "${WORKERS}" =~ ^[0-9]+$ || "${WORKERS}" -gt 64 ]]; then
    echo "错误: WORKERS 须为 0–64 的整数。"
    exit 1
  fi
  if [[ "${MODE}" != "tls" && "${MODE}" != "classic" ]]; then
    echo "错误: 模式只支持 tls 或 classic。"
    exit 1
  fi
  if [[ "${MODE}" == "tls" && -z "${TLS_DOMAIN}" ]]; then
    echo "错误: tls 模式必须配置 TLS 伪装域名。"
    exit 1
  fi
  if [[ "${MODE}" == "tls" && "${WORKERS}" -gt 0 ]]; then
    echo "提示: TLS 下 WORKERS>0 在部分环境可能异常，一般建议 0。"
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "请以 root 运行: sudo $0"
  exit 1
fi

if [[ ! -t 0 ]]; then
  echo "错误: 本安装程序为交互式，请在真实终端中直接执行，勿通过管道重定向 stdin。"
  exit 1
fi

show_nbzai_banner

install_log_init
echo "安装过程详情写入: ${INSTALL_LOG} (出错时会自动显示尾部)"
echo ""

draw_progress 4 "更新软件包索引..."
if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 update -qq >>"${INSTALL_LOG}" 2>&1; then
  install_fail_tail
fi

draw_progress 12 "安装编译与网络依赖..."
if ! DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 install -y -qq \
  git curl build-essential libssl-dev zlib1g-dev ufw ca-certificates openssl >>"${INSTALL_LOG}" 2>&1; then
  install_fail_tail
fi

draw_progress 18 "内核 PID 兼容性 (MTProxy)..."
ensure_pid_compatibility

echo ""
echo "────────────────────────────────"
echo "  交互式配置"
echo "  请按提示输入；方括号内为默认项，直接回车即采用默认。"
echo "────────────────────────────────"
echo ""
collect_interactive_config

draw_progress 28 "同步 MTProxy 源码..."
if [[ ! -d "${MT_DIR}" ]]; then
  if ! git clone -q https://github.com/TelegramMessenger/MTProxy.git "${MT_DIR}" >>"${INSTALL_LOG}" 2>&1; then
    install_fail_tail
  fi
else
  git -C "${MT_DIR}" pull -q --ff-only >>"${INSTALL_LOG}" 2>&1 || true
fi

draw_progress 36 "下载 Telegram 代理配置..."
if ! curl -fsSL https://core.telegram.org/getProxySecret -o "${MT_DIR}/proxy-secret" >>"${INSTALL_LOG}" 2>&1; then
  install_fail_tail
fi
if ! curl -fsSL https://core.telegram.org/getProxyConfig -o "${MT_DIR}/proxy-multi.conf" >>"${INSTALL_LOG}" 2>&1; then
  install_fail_tail
fi

draw_progress 42 "编译 MTProxy (可能较久)..."
if ! make -C "${MT_DIR}" -j"$(nproc)" -s >>"${INSTALL_LOG}" 2>&1; then
  install_fail_tail
fi

draw_progress 72 "检测 proxy tag 参数..."
HELP_TEXT="$("${MT_DIR}/objs/bin/mtproto-proxy" --help 2>&1 || true)"
{
  echo "---- mtproto-proxy --help (excerpt) ----"
  printf '%s\n' "${HELP_TEXT}" | head -n 40
} >>"${INSTALL_LOG}" 2>&1
if echo "${HELP_TEXT}" | grep -q -- "--proxy-tag"; then
  TAG_FLAG="--proxy-tag"
elif echo "${HELP_TEXT}" | grep -q -- "--tag"; then
  TAG_FLAG="--tag"
else
  echo "错误: 无法从 mtproto-proxy --help 中识别 --proxy-tag / --tag。" | tee -a "${INSTALL_LOG}" >&2
  exit 1
fi

if [[ "${MODE}" == "tls" ]]; then
  draw_progress 78 "校验 TLS 伪装域名..."
  check_tls_domain
else
  draw_progress 78 "MODE=classic (跳过 TLS 伪装校验)"
fi

if [[ "${APPLY_LE_CERT}" == "y" && -n "${BIND_DOMAIN}" ]]; then
  draw_progress 84 "申请 Let's Encrypt 证书..."
  issue_letsencrypt_cert "${BIND_DOMAIN}" "${ACME_EMAIL}"
fi

draw_progress 90 "写入 systemd 单元..."
TLS_ARGS=""
CLIENT_SECRET="${SECRET}"
if [[ "${MODE}" == "tls" ]]; then
  TLS_ARGS="-D ${TLS_DOMAIN}"
  DOMAIN_HEX="$(printf '%s' "${TLS_DOMAIN}" | od -An -tx1 | tr -d ' \n')"
  CLIENT_SECRET="ee${SECRET}${DOMAIN_HEX}"
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=MTProxy - ${PROXY_NAME}
After=network.target

[Service]
Type=simple
WorkingDirectory=${MT_DIR}
ExecStart=${MT_DIR}/objs/bin/mtproto-proxy -u nobody -p ${STATS_PORT} -H ${PORT} -S ${SECRET} ${TLS_ARGS} --aes-pwd ${MT_DIR}/proxy-secret ${MT_DIR}/proxy-multi.conf -M ${WORKERS} ${TAG_FLAG} ${TAG}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

draw_progress 94 "防火墙 (UFW)..."
if ufw status 2>/dev/null | grep -qi "Status: active"; then
  {
    echo "UFW: allow ${PORT}/tcp"
    ufw allow "${PORT}/tcp" || true
    ufw reload || true
  } >>"${INSTALL_LOG}" 2>&1
else
  echo "UFW not active, skip." >>"${INSTALL_LOG}"
fi

draw_progress 97 "注册并启动 systemd 服务..."
systemctl daemon-reload >>"${INSTALL_LOG}" 2>&1
if ! systemctl enable --now "${SERVICE_NAME}" >>"${INSTALL_LOG}" 2>&1; then
  echo "错误: systemctl 启用/启动服务失败。" | tee -a "${INSTALL_LOG}" >&2
  tail -n 40 "${INSTALL_LOG}" >&2 || true
  systemctl status "${SERVICE_NAME}" --no-pager -l || true
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
  exit 1
fi
sleep 1

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "错误: 服务 ${SERVICE_NAME} 未能成功启动。" | tee -a "${INSTALL_LOG}" >&2
  systemctl status "${SERVICE_NAME}" --no-pager -l || true
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
  exit 1
fi

if ! ss -lnt | grep -q ":${PORT} "; then
  echo "错误: 服务已跑但端口 ${PORT} 未在监听。" | tee -a "${INSTALL_LOG}" >&2
  systemctl status "${SERVICE_NAME}" --no-pager -l || true
  exit 1
fi

draw_progress 100 "安装完成"

echo
echo "安装成功。"
echo "完整安装日志: ${INSTALL_LOG}"
echo "代理显示名称: ${PROXY_NAME}"
systemctl status "${SERVICE_NAME}" --no-pager -l || true
echo
echo "导入链接中的服务器: ${PROXY_SERVER}"
echo "代理导入链接:"
echo "https://t.me/proxy?server=${PROXY_SERVER}&port=${PORT}&secret=${CLIENT_SECRET}"
echo "tg://proxy?server=${PROXY_SERVER}&port=${PORT}&secret=${CLIENT_SECRET}"
if [[ "${MODE}" == "tls" ]]; then
  echo "TLS 伪装域名 (-D): ${TLS_DOMAIN}"
fi
if [[ -n "${BIND_DOMAIN}" ]]; then
  echo "已绑定客户端域名: ${BIND_DOMAIN}"
fi
if [[ "${APPLY_LE_CERT}" == "y" ]]; then
  echo "Let's Encrypt 已为该域名签发证书: ${BIND_DOMAIN}"
fi
echo
echo "常用命令:"
echo "journalctl -u ${SERVICE_NAME} -f"
echo "systemctl restart ${SERVICE_NAME}"
echo "wget -qO- http://127.0.0.1:${STATS_PORT}/stats"
