#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mtproxy"
MT_DIR="/opt/MTProxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo $0"
  exit 1
fi

echo "[1/4] Stopping service..."
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

echo "[2/4] Removing service file..."
rm -f "${SERVICE_FILE}"
systemctl daemon-reload

echo "[3/4] Removing MTProxy files..."
rm -rf "${MT_DIR}"

echo "[4/4] Done."
echo "MTProxy has been removed from this server."
echo "If needed, manually close firewall port (example: ufw delete allow 443/tcp)."
