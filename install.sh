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

# Dò tìm 1 bản python3 >= 3.8 để tạo venv. Flask 3.x/gunicorn 22.x yêu cầu
# Python >= 3.8; VPS Ubuntu cũ (18.04 trở xuống) mặc định "python3" là
# 3.6/3.7 khiến "pip install Flask==3.0.3" báo "Could not find a version
# that satisfies..." - trông như lỗi mạng/PyPI nhưng thực ra do Python quá
# cũ bị pip tự lọc bỏ hết bản mới.
pick_python_bin() {
    local cand best="" best_ver=0 ver
    for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
        command -v "$cand" >/dev/null 2>&1 || continue
        ver=$("$cand" -c 'import sys; print(sys.version_info.major*100+sys.version_info.minor)' 2>/dev/null) || continue
        [ -z "$ver" ] && continue
        if [ "$ver" -ge 308 ]; then echo "$cand"; return 0; fi
        if [ "$ver" -gt "$best_ver" ]; then best="$cand"; best_ver="$ver"; fi
    done
    for pkg in python3.12 python3.11 python3.10 python3.9 python3.8; do
        if apt-get install -y -qq "$pkg" "${pkg}-venv" >/dev/null 2>&1 && command -v "$pkg" >/dev/null 2>&1; then
            echo "$pkg"; return 0
        fi
    done
    echo "${best:-python3}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/psiphon-panel.sh" ] || fail "Không thấy psiphon-panel.sh trong $SCRIPT_DIR"
[ -d "$SCRIPT_DIR/webpanel" ] || fail "Không thấy thư mục webpanel/ trong $SCRIPT_DIR"


# QUAN TRỌNG: phải khớp với đường dẫn "/usr/local/bin/psiphon-panel" mà
# chính psiphon-panel.sh dùng ở mọi nơi khác (PANEL_URL fetch đích, menu [8]
# "Cập nhật Panel", và default PANEL_SCRIPT_PATH khi cài dashboard từ trong
# menu CLI [7]). Nếu để khác đi (VD /root/psiphon-panel.sh như trước đây),
# sau này chạy "Cập nhật Panel" từ menu CLI sẽ cập nhật NHẦM file, còn
# dashboard vẫn chạy mãi bản cũ vì PANEL_SCRIPT_PATH trỏ chỗ khác.
PANEL_DEST="/usr/local/bin/psiphon-panel"
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
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq python3 python3-venv python3-pip >/dev/null 2>&1 || true
if ! command -v python3 >/dev/null 2>&1; then
    fail "Chưa có python3, cài trước: apt install -y python3 python3-venv"
fi
PYBIN=$(pick_python_bin)
echo -e "  ${C}Dùng interpreter: $PYBIN ($($PYBIN --version 2>&1))${N}"
rm -rf "$APP_DIR/venv"
"$PYBIN" -m venv "$APP_DIR/venv" 2>/tmp/psiphon-venv-err.log
if [ ! -x "$APP_DIR/venv/bin/pip" ]; then
    # Ubuntu/Debian: gói "python3-venv" đôi khi không kéo theo đúng bản
    # "python3.X-venv" cần cho ensurepip -> venv tạo ra nhưng thiếu pip.
    # Dò đúng version đang dùng rồi cài đúng gói đó.
    PYVER=$("$PYBIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    echo -e "  ${Y}venv thiếu ensurepip, thử cài python${PYVER}-venv...${N}"
    apt-get install -y -qq "python${PYVER}-venv" >/dev/null 2>&1 || true
    rm -rf "$APP_DIR/venv"
    "$PYBIN" -m venv "$APP_DIR/venv" 2>/tmp/psiphon-venv-err.log
fi
if [ ! -x "$APP_DIR/venv/bin/pip" ]; then
    echo -e "${R}  ✗ Không tạo được venv (thiếu pip trong venv). Lỗi:${N}"
    sed 's/^/    /' /tmp/psiphon-venv-err.log
    fail "Thử cài tay: apt install python${PYVER:-3}-venv    rồi chạy lại install.sh"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
if ! "$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt" 2>/tmp/psiphon-pip-err.log; then
    # Interpreter cũ hơn 3.8 và không apt cài thêm được bản mới hơn (VD
    # không có internet ra ngoài apt mirror chuẩn) -> pip lọc bỏ hết bản
    # Flask/gunicorn mới. Hạ xuống dải version cũ hơn thay vì fail cứng.
    echo -e "  ${Y}⚠ Cài bản pin trong requirements.txt thất bại (có thể do Python < 3.8: $($PYBIN --version 2>&1)).${N}"
    echo -e "  ${Y}Thử lại với dải version cũ hơn, tương thích rộng hơn...${N}"
    if ! "$APP_DIR/venv/bin/pip" install --quiet "Flask>=2.0,<3" "gunicorn>=20,<21" 2>>/tmp/psiphon-pip-err.log; then
        echo -e "${R}  ✗ Cài dependencies thất bại. Lỗi:${N}"
        sed 's/^/    /' /tmp/psiphon-pip-err.log | tail -20
        fail "VPS đang dùng Python quá cũ ($($PYBIN --version 2>&1)). Cài: apt install python3.10 python3.10-venv   rồi chạy lại install.sh"
    fi
    echo -e "  ${Y}✓ Đã cài bản Flask/gunicorn cũ hơn (tương thích Python < 3.8). Nên nâng cấp Python khi có dịp.${N}"
fi
ok "Đã cài venv + Flask/gunicorn"

# ---------------------------------------------------------------
say "4/6 - Đặt mật khẩu dashboard"
# Script này hay được chạy kiểu "curl ... | sudo bash" - lúc đó stdin đã bị
# curl chiếm, "read" thường sẽ đọc phải EOF, trả về lỗi, và vì có "set -e"
# script sẽ thoát NGAY LẬP TỨC ở đây mà không có thông báo gì rõ ràng (tưởng
# treo/lỗi vô cớ). Đọc thẳng từ /dev/tty để luôn hỏi được, bất kể stdin.
if [ ! -r /dev/tty ]; then
    fail "Không có TTY để nhập mật khẩu (đang chạy qua pipe không tương tác?). Tải script về rồi chạy trực tiếp: curl -fsSL <url> -o install.sh && sudo bash install.sh"
fi

if [ -f "$ENV_FILE" ] && grep -q "^DASHBOARD_PASSWORD_HASH=" "$ENV_FILE" 2>/dev/null; then
    echo -ne "  ${Y}Đã có mật khẩu cấu hình sẵn. Đặt lại? (y/N): ${N}"
    read -r reset_pw < /dev/tty
else
    reset_pw="y"
fi

if [[ "$reset_pw" =~ ^[Yy]$ ]]; then
    while true; do
        read -r -p "  Nhập mật khẩu mới cho dashboard: " PW1 < /dev/tty; echo
        read -r -p "  Nhập lại: " PW2 < /dev/tty; echo
        [ -n "$PW1" ] || { echo -e "${R}  Mật khẩu không được để trống.${N}"; continue; }
        [ "$PW1" = "$PW2" ] || { echo -e "${R}  Không khớp, thử lại.${N}"; continue; }
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
