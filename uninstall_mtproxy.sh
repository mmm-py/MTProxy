#!/usr/bin/env bash
set -euo pipefail

MT_DIR="/opt/MTProxy"
SYSTEMD_DIR="/etc/systemd/system"

# 可覆盖：非交互时 export SERVICE_NAME=xxx 后执行
: "${SERVICE_NAME:=}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请以 root 运行: sudo $0"
  exit 1
fi

list_mtproxy_units() {
  local f name
  for f in "${SYSTEMD_DIR}"/*.service; do
    [[ -f "$f" ]] || continue
    if grep -q 'mtproto-proxy' "$f" 2>/dev/null; then
      name="$(basename "$f" .service)"
      printf '%s\n' "${name}"
    fi
  done | sort -u
}

select_service_name() {
  local -a units
  local i choice manual

  if [[ -n "${SERVICE_NAME}" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "错误: 未指定服务名，且标准输入不是终端。用法示例:" >&2
    echo "  sudo SERVICE_NAME=mtproxy1 $0" >&2
    echo "  或在本机终端中直接: sudo $0" >&2
    exit 1
  fi

  mapfile -t units < <(list_mtproxy_units)

  if [[ "${#units[@]}" -eq 0 ]]; then
    echo "未在 ${SYSTEMD_DIR} 下发现含 mtproto-proxy 的 .service 单元。"
    read -rp "请手动输入要卸载的 systemd 服务名 (不含 .service 后缀): " manual
    manual="$(printf '%s' "${manual}" | tr -d '[:space:]' | sed 's/\.service$//')"
    if [[ -z "${manual}" ]]; then
      echo "错误: 服务名不能为空。"
      exit 1
    fi
    SERVICE_NAME="${manual}"
    return 0
  fi

  echo "检测到本机以下 MTProxy 相关 systemd 服务 (unit 内包含 mtproto-proxy):"
  echo "────────────────────────────────"
  i=1
  for u in "${units[@]}"; do
    echo "  [${i}] ${u}"
    ((i++)) || true
  done
  echo "  [0] 手动输入其它服务名"
  echo "────────────────────────────────"
  read -rp "请输入序号 [1-${#units[@]}] 或 0: " choice
  choice="$(printf '%s' "${choice}" | tr -d '[:space:]')"

  if [[ "${choice}" == "0" ]]; then
    read -rp "服务名 (不含 .service): " manual
    manual="$(printf '%s' "${manual}" | tr -d '[:space:]' | sed 's/\.service$//')"
    if [[ -z "${manual}" ]]; then
      echo "错误: 服务名不能为空。"
      exit 1
    fi
    SERVICE_NAME="${manual}"
    return 0
  fi

  if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${#units[@]}" ]]; then
    SERVICE_NAME="${units[$((choice - 1))]}"
    return 0
  fi

  echo "错误: 无效序号: ${choice}"
  exit 1
}

other_mtproto_units() {
  local f name
  for f in "${SYSTEMD_DIR}"/*.service; do
    [[ -f "$f" ]] || continue
    if grep -q 'mtproto-proxy' "$f" 2>/dev/null; then
      name="$(basename "$f" .service)"
      if [[ "${name}" != "${SERVICE_NAME}" ]]; then
        echo "${name}"
      fi
    fi
  done
}

select_service_name

SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

if [[ ! -f "${SERVICE_FILE}" ]]; then
  echo "错误: 未找到单元文件: ${SERVICE_FILE}"
  echo "     服务名: ${SERVICE_NAME}"
  exit 1
fi

REMAINING_OR="$(other_mtproto_units | tr '\n' ' ' | sed 's/ *$//')"

if [[ -n "${REMAINING_OR}" && -d "${MT_DIR}" ]]; then
  echo "提示: 本机还有其它 MTProxy 服务仍在使用同一路径: ${REMAINING_OR}"
  read -rp "是否仍删除公共目录 ${MT_DIR} (删除后需重装才能再用)? [y/N]: " del_common
  del_common="$(printf '%s' "${del_common}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${del_common}" == "y" || "${del_common}" == "yes" ]]; then
    RM_MT_DIR=1
  else
    RM_MT_DIR=0
  fi
else
  RM_MT_DIR=1
  if [[ -d "${MT_DIR}" ]]; then
    read -rp "是否删除 ${MT_DIR} (源码与编译结果)? [Y/n]: " del_common
    del_common="$(printf '%s' "${del_common}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${del_common}" || "${del_common}" == "y" || "${del_common}" == "yes" ]]; then
      RM_MT_DIR=1
    else
      RM_MT_DIR=0
    fi
  fi
fi

echo "[1/4] 正在停止并禁用: ${SERVICE_NAME} ..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

echo "[2/4] 正在移除单元文件: ${SERVICE_FILE} ..."
rm -f "${SERVICE_FILE}"
systemctl daemon-reload

echo "[3/4] 目录 /opt/MTProxy ..."
if [[ "${RM_MT_DIR}" -eq 1 && -d "${MT_DIR}" ]]; then
  rm -rf "${MT_DIR}"
  echo "已删除: ${MT_DIR}"
elif [[ -d "${MT_DIR}" ]]; then
  echo "已保留: ${MT_DIR} (其它代理实例或你选择了保留)"
else
  echo "不存在: ${MT_DIR}，跳过。"
fi

echo "[4/4] 完成。"
echo "已卸载服务: ${SERVICE_NAME}"
if [[ -n "${REMAINING_OR}" ]]; then
  echo "本机可能仍有 MTProxy 服务: ${REMAINING_OR} — 可再次执行本脚本选择卸载。"
fi
echo "若开过防火墙端口，可手动删除规则，例如: ufw status numbered 后 ufw delete <编号>"
