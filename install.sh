#!/bin/bash
# ================================================================
# Cài đặt Psiphon Panel Web Dashboard - chạy 1 lệnh duy nhất.
# Chạy từ thư mục gốc của repo (chứa psiphon-panel.sh + webpanel/):
#   sudo bash install.sh
# ================================================================
set -e

R='\033[1;31m' G='\033[1;32m' Y='\033[1;33m' C='\033[1;36m' N='\033[0m'
say()  { echo -e "${C}==>${N} $1"; }
ok()   { echo -e "${G}  ✓${N} $1"; }
fail() { echo -e "${R}  ✗ $1${N}"; exit 1; }

[ "$EUID" -ne 0 ] && fail "Cần chạy với quyền root (sudo bash install.sh)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/psiphon-panel.sh" ] || fail "Không thấy psiphon-panel.sh trong $SCRIPT_DIR"
[ -d "$SCRIPT_DIR/webpanel" ] || fail "Không thấy thư mục webpanel/ trong $SCRIPT_DIR"

PANEL_DEST="/root/psiphon-panel.sh"
APP_DIR="/opt/psiphon-dashboard"
ENV_FILE="/etc/psiphon-dashboard.env"

# ---------------------------------------------------------------
say "1/6 - Copy psiphon-panel.sh -> $PANEL_DEST"
cp "$SCRIPT_DIR/psiphon-panel.sh" "$PANEL_DEST"
chmod +x "$PANEL_DEST"
ok "Đã copy"

# ---------------------------------------------------------------
say "2/6 - Copy webpanel/ -> $APP_DIR"
mkdir -p "$APP_DIR"
cp -r "$SCRIPT_DIR/webpanel/"* "$APP_DIR/"
ok "Đã copy"

# ---------------------------------------------------------------
say "3/6 - Cài Python venv + dependencies"
if ! command -v python3 >/dev/null 2>&1; then
    fail "Chưa có python3, cài trước: apt install -y python3 python3-venv"
fi
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
ok "Đã cài venv + Flask/gunicorn"

# ---------------------------------------------------------------
say "4/6 - Đặt mật khẩu dashboard"
if [ -f "$ENV_FILE" ] && grep -q "^DASHBOARD_PASSWORD_HASH=" "$ENV_FILE" 2>/dev/null; then
    echo -ne "  ${Y}Đã có mật khẩu cấu hình sẵn. Đặt lại? (y/N): ${N}"
    read -r reset_pw
else
    reset_pw="y"
fi

if [[ "$reset_pw" =~ ^[Yy]$ ]]; then
    while true; do
        read -rs -p "  Nhập mật khẩu mới cho dashboard: " PW1; echo
        read -rs -p "  Nhập lại: " PW2; echo
        [ "$PW1" = "$PW2" ] || { echo -e "${R}  Không khớp, thử lại.${N}"; continue; }
        [ ${#PW1} -ge 8 ] || { echo -e "${R}  Mật khẩu nên >= 8 ký tự.${N}"; continue; }
        break
    done
    PW_HASH=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$PW1")
    SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    cat > "$ENV_FILE" << EOF
DASHBOARD_PASSWORD_HASH=$PW_HASH
DASHBOARD_SECRET_KEY=$SECRET_KEY
PANEL_SCRIPT_PATH=$PANEL_DEST
EOF
    chmod 600 "$ENV_FILE"
    ok "Đã lưu mật khẩu vào $ENV_FILE (chmod 600)"
    unset PW1 PW2 PW_HASH
else
    ok "Giữ nguyên mật khẩu cũ"
fi

# ---------------------------------------------------------------
say "5/6 - Cài systemd service"
cp "$APP_DIR/psiphon-dashboard.service" /etc/systemd/system/psiphon-dashboard.service
systemctl daemon-reload
systemctl enable --now psiphon-dashboard
ok "Đã start service"

# ---------------------------------------------------------------
say "6/6 - Kiểm tra"
sleep 1
if systemctl is-active --quiet psiphon-dashboard; then
    ok "psiphon-dashboard đang chạy (127.0.0.1:8088)"
else
    echo -e "${R}  Service KHÔNG chạy được. Xem log: journalctl -u psiphon-dashboard -n 50${N}"
    exit 1
fi

echo ""
echo -e "${G}Xong.${N} Dashboard đang chạy nội bộ tại 127.0.0.1:8088 (chưa public ra ngoài, an toàn)."
echo -e "Truy cập nhanh bằng SSH tunnel từ máy cá nhân:"
echo -e "  ${C}ssh -L 8088:127.0.0.1:8088 root@<IP_VPS_này>${N}"
echo -e "rồi mở ${C}http://127.0.0.1:8088${N} trên trình duyệt máy mình."
echo -e "Muốn truy cập trực tiếp qua domain + HTTPS, xem phần 'Cách B' trong webpanel/README.md."
