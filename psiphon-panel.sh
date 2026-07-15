#!/bin/bash
# ================================================================
#  PSIPHON SERVER PANEL v2.1
#  Cài đặt & quản lý Psiphon Server trên Ubuntu/Debian
# ================================================================

VERSION="2.1.0"
PANEL_DIR="/etc/psiphon-panel"
CONFIG_FILE="$PANEL_DIR/panel.conf"
INSTALL_DIR="/usr/local/psiphon"
BINARY="$INSTALL_DIR/psiphond"
LOG_FILE="/var/log/psiphon.log"
SERVICE_FILE="/etc/systemd/system/psiphond.service"
PATCH_SCRIPT="$INSTALL_DIR/patch_entry.py"
ENTRY_RAW="$INSTALL_DIR/server-entry.dat"
ENTRY_PATCHED="$INSTALL_DIR/server-entry.dat.patched"

# --- Chứng chỉ TLS gốc (thay cho cert self-signed psiphond tự sinh) ---
# Dùng field MeekServerCertificate/MeekServerPrivateKey đã có sẵn trong
# psiphond (xem psiphon/server/websocket.go & meek.go, getWebServerCertificate):
# nếu 2 field này có giá trị trong psiphond.config, psiphond dùng cert đó cho
# CẢ meek lẫn FRONTED-WS(S)-OSSH thay vì tự generate self-signed ngẫu nhiên.
# Đây KHÔNG phải cert cho browser/client thấy (đó là edge cert của Cloudflare) -
# đây là cert cho chặng Cloudflare→origin (VPS này), chỉ áp dụng nếu bạn để
# SSL/TLS mode = "Full (strict)" trên Cloudflare (mode "Full" thường thì
# Cloudflare không kiểm cert origin, không bắt buộc phải làm bước này).
CF_ORIGIN_CERT_FILE="$INSTALL_DIR/cf-origin-cert.pem"
CF_ORIGIN_KEY_FILE="$INSTALL_DIR/cf-origin-key.pem"
INJECT_CERT_SCRIPT="$INSTALL_DIR/inject_cert.py"

# --- Giới hạn băng thông + psiphonAuth (accesscontrol) ---
TRAFFIC_RULES_FILE="$INSTALL_DIR/traffic-rules.json"
AUTHGEN_BINARY="$INSTALL_DIR/psiphon-authgen"
SIGNING_KEY_FILE="$INSTALL_DIR/signing-key.json"      # BÍ MẬT - không public
VERIFY_KEY_FILE="$INSTALL_DIR/verification-key.json"  # public, nhúng vào server.config
TOKENS_LOG="$PANEL_DIR/tokens.log"
# File gộp tất cả token đã cấp, dạng 1 mảng JSON duy nhất
# (VD ["token1", "token2"]), dán thẳng vào field "Authorizations" của
# config client Psiphon. Mỗi lần issue token mới sẽ đọc file này (nếu
# có), thêm token mới vào, rồi ghi đè lại.
AUTH_ARRAY_FILE="/root/authorizations.json"
# File thứ 2: mỗi token là 1 khối mảng JSON riêng, mỗi khối 1 dòng
# (VD dòng 1: ["token1"], dòng 2: ["token2"]). Chỉ append, không đọc
# lại/ghi đè toàn bộ như AUTH_ARRAY_FILE.
AUTH_BLOCKS_FILE="/root/authorizations-blocks.json"
DEVICE_LIMITS_FILE="$INSTALL_DIR/device-limits.json"
KICK_REQUESTS_FILE="$INSTALL_DIR/kick-requests.json"
INJECT_SCRIPT="$INSTALL_DIR/inject_config.py"
# psiphon-authgen là công cụ Go tự build (dùng package
# psiphon/common/accesscontrol trong chính repo psiphon-tunnel-core của bạn),
# KHÔNG có sẵn trong binary psiphond thường. Nếu đã tự build, host lên đâu đó
# rồi điền URL vào đây; nếu để trống, panel sẽ nhắc bạn copy tay vào
# $AUTHGEN_BINARY.
#
# LƯU Ý AN TOÀN: đây là binary thực thi với quyền root (qua script này).
# Link dưới trỏ tới repo GitHub của bên thứ ba (không phải repo chính thức
# Psiphon Inc.) — bạn tự chịu trách nhiệm xác minh nguồn/tác giả trước khi
# dùng trên server thật. Nếu có thể, nên tự build từ mã nguồn thay vì tải
# binary dựng sẵn.
AUTHGEN_URLS=(
    "https://raw.githubusercontent.com/caothemanh/psiphond/main/psiphon-authgen"
    "https://cdn.jsdelivr.net/gh/caothemanh/psiphond@main/psiphon-authgen"
    "https://github.com/caothemanh/psiphond/raw/main/psiphon-authgen"
)

PSIPHOND_URLS=(
    "https://raw.githubusercontent.com/caothemanh/psiphond/main/psiphond"
    "https://cdn.jsdelivr.net/gh/caothemanh/psiphond@main/psiphond"
    "https://github.com/caothemanh/psiphond/raw/main/psiphond"
)
PANEL_URL="https://raw.githubusercontent.com/caothemanh/psiphon-panel/main/psiphon-panel.sh"

# --- Web Dashboard (webpanel/) ---
WEBPANEL_BASE_URL="https://raw.githubusercontent.com/caothemanh/psiphon-panel/main/webpanel"
WEBPANEL_DIR="/opt/psiphon-dashboard"
WEBPANEL_ENV="/etc/psiphon-dashboard.env"
WEBPANEL_SERVICE_FILE="/etc/systemd/system/psiphon-dashboard.service"
WEBPANEL_PORT=8088

# Màu (dùng bản BOLD cho tất cả để chữ hiển thị đậm/to/rõ hơn trên terminal)
R='\033[1;31m' G='\033[1;32m' Y='\033[1;33m'
C='\033[1;36m' W='\033[1;37m' N='\033[0m' BOLD='\033[1m'

# ================================================================
# CONFIG
# ================================================================
default_config() {
    SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    WEB_PORT=3000
    CF_DOMAIN=""
    CF_IP=""
    REGION=""
    # Giới hạn tốc độ mặc định (KB/s) cho client KHÔNG có psiphonAuth hợp lệ.
    # 0 = không giới hạn (tắt tính năng limit).
    DEFAULT_LIMIT_KBPS=256
    # Nhãn AccessType dùng để cấp/khớp token psiphonAuth. Client trình token
    # có AccessType này (còn hạn, chưa revoke) sẽ được bỏ giới hạn hoàn toàn.
    AUTH_ACCESS_TYPE="premium"
    PROTO_LIST=(
        "SSH:3001:true"
        "OSSH:3002:true"
        "FRONTED-MEEK-OSSH:443:false"
        "FRONTED-WSS-OSSH:443:true"
        "FRONTED-MEEK-HTTP-OSSH:8080:false"
        "FRONTED-WS-OSSH:80:true"
        "FRONTED-MEEK-QUIC-OSSH:5300:false"
        "UNFRONTED-MEEK-OSSH:8888:false"
        "UNFRONTED-WS-OSSH:8889:false"
        "UNFRONTED-MEEK-HTTPS-OSSH:8443:false"
        "UNFRONTED-WSS-OSSH:9443:false"
        "UNFRONTED-MEEK-SESSION-TICKET-OSSH:8880:false"
        "TLS-OSSH:8843:false"
        "QUIC-OSSH:1194:false"
    )
}

# Các protocol WebSocket-OSSH là bản custom (patch từ psiphon-tunnel-core),
# KHÔNG có trong binary psiphond mặc định tải về từ $PSIPHOND_URLS.
# Bật + generate mà chưa thay binary tùy biến sẽ khiến "psiphond generate"
# báo lỗi "invalid tunnel protocol" hoặc tương tự.
WS_EXPERIMENTAL_PROTOS=(
    "UNFRONTED-WS-OSSH"
    "UNFRONTED-WSS-OSSH"
    "FRONTED-WS-OSSH"
    "FRONTED-WSS-OSSH"
)

is_ws_experimental() {
    local p="$1"
    local w
    for w in "${WS_EXPERIMENTAL_PROTOS[@]}"; do
        [ "$p" = "$w" ] && return 0
    done
    return 1
}

# FRONTED-MEEK-QUIC-OSSH KHÔNG có listener riêng trên server (đã xác nhận
# trong source psiphon-tunnel-core: tunnelServer.go bỏ qua tạo listener cho
# protocol này — xem TunnelProtocolUsesFrontedMeekNonHTTPS). Nó dùng CHUNG
# port HTTPS với FRONTED-MEEK-OSSH; khác biệt chỉ nằm ở chặng client↔CDN
# (client dial bằng QUIC/HTTP-3 tới CDN, CDN vẫn forward về origin bằng
# HTTPS như bình thường). Vì vậy:
#   - Port của nó phải LUÔN đồng bộ với port của FRONTED-MEEK-OSSH.
#   - Không mở firewall UDP riêng cho nó (không có gì lắng nghe ở đó).
#   - Không được coi là "trùng port" với FRONTED-MEEK-OSSH (đó là chủ đích).
#   - Chỉ nên bật nếu FRONTED-MEEK-OSSH cũng đang bật.
SHARED_MEEK_PORT_PROTOS=(
    "FRONTED-MEEK-QUIC-OSSH"
)
SHARED_MEEK_PORT_PARENT="FRONTED-MEEK-OSSH"

is_shared_meek_port_protocol() {
    local p="$1"
    local w
    for w in "${SHARED_MEEK_PORT_PROTOS[@]}"; do
        [ "$p" = "$w" ] && return 0
    done
    return 1
}

# Trả về "true"/"false" xem $SHARED_MEEK_PORT_PARENT có đang BẬT không
is_parent_meek_enabled() {
    local entry proto port enabled
    for entry in "${PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "$entry"
        if [ "$proto" = "$SHARED_MEEK_PORT_PARENT" ]; then
            [ "$enabled" = "true" ] && return 0 || return 1
        fi
    done
    return 1
}

load_config() {
    default_config
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        PROTO_LIST=()
        local i=0
        while true; do
            local var="PROTO_$i"
            [ -z "${!var}" ] && break
            PROTO_LIST+=("${!var}")
            ((i++))
        done
    fi
}

save_config() {
    mkdir -p "$PANEL_DIR"
    {
        echo "SERVER_IP=\"$SERVER_IP\""
        echo "WEB_PORT=$WEB_PORT"
        echo "CF_DOMAIN=\"$(echo $CF_DOMAIN | tr -d '[:space:]')\""
        echo "CF_IP=\"$(echo $CF_IP | tr -d '[:space:]')\""
        echo "REGION=\"$(echo $REGION | tr -d '[:space:]')\""
        echo "DEFAULT_LIMIT_KBPS=$DEFAULT_LIMIT_KBPS"
        echo "AUTH_ACCESS_TYPE=\"$AUTH_ACCESS_TYPE\""
        local i=0
        for entry in "${PROTO_LIST[@]}"; do
            echo "PROTO_$i=\"$entry\""
            ((i++))
        done
    } > "$CONFIG_FILE"
}

# ================================================================
# TIỆN ÍCH
# ================================================================
check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${R}Cần chạy với quyền root!${N}"; exit 1; }
}

is_installed() { [ -f "$BINARY" ]; }

# In toàn bộ trạng thái cần cho dashboard web dưới dạng 1 JSON duy nhất,
# tránh phải gọi nhiều lệnh rời rạc rồi tự parse text màu ANSI.
# Dữ liệu được truyền cho python qua biến môi trường (không nội suy thẳng
# vào source code python) để tránh vỡ cú pháp/injection khi giá trị có
# ký tự đặc biệt (dấu nháy, backslash...).
web_status_json() {
    load_config
    local running="false" installed="false"
    is_running && running="true"
    is_installed && installed="true"

    WS_RUNNING="$running" \
    WS_INSTALLED="$installed" \
    WS_PID="$(pgrep -x psiphond | head -1)" \
    WS_SERVER_IP="$SERVER_IP" \
    WS_WEB_PORT="$WEB_PORT" \
    WS_ACCESS_TYPE="$AUTH_ACCESS_TYPE" \
    WS_LIMIT_KBPS="$DEFAULT_LIMIT_KBPS" \
    WS_HAS_SIGNING_KEY="$([ -f "$SIGNING_KEY_FILE" ] && echo true || echo false)" \
    WS_HAS_VERIFY_KEY="$([ -f "$VERIFY_KEY_FILE" ] && echo true || echo false)" \
    WS_CONFIG_PATH="$INSTALL_DIR/psiphond.config" \
    WS_TRAFFIC_RULES_PATH="$TRAFFIC_RULES_FILE" \
    python3 -c "
import json, os

def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

cfg = read_json(os.environ['WS_CONFIG_PATH']) or {}

print(json.dumps({
    'running': os.environ['WS_RUNNING'] == 'true',
    'installed': os.environ['WS_INSTALLED'] == 'true',
    'pid': os.environ['WS_PID'],
    'server_ip': os.environ['WS_SERVER_IP'],
    'web_port': os.environ['WS_WEB_PORT'],
    'access_type': os.environ['WS_ACCESS_TYPE'],
    'default_limit_kbps': os.environ['WS_LIMIT_KBPS'],
    'has_signing_key': os.environ['WS_HAS_SIGNING_KEY'] == 'true',
    'has_verify_key': os.environ['WS_HAS_VERIFY_KEY'] == 'true',
    'verify_key_ring': cfg.get('AccessControlVerificationKeyRing'),
    'traffic_rules': read_json(os.environ['WS_TRAFFIC_RULES_PATH']),
}))
"
}

is_running() {
    systemctl is-active --quiet psiphond 2>/dev/null || pgrep -x psiphond >/dev/null 2>&1
}

run_badge()    { is_running   && echo -e "${G}● ĐANG CHẠY${N}" || echo -e "${R}● DỪNG${N}"; }
install_badge(){ is_installed && echo -e "${G}✓ Đã cài${N}"    || echo -e "${R}✗ Chưa cài${N}"; }

press_enter() { echo ""; echo -e "${Y}Nhấn Enter để tiếp tục...${N}"; read -r; }

confirm() {
    echo -ne "${Y}$1 (y/N): ${N}"
    read -r a; [[ "$a" =~ ^[Yy]$ ]]
}

header() {
    clear
    echo -e "${C}╔═══════════════════════════════════════════════════╗${N}"
    echo -e "${C}║   ${W}${BOLD}⚡ PSIPHON SERVER PANEL v${VERSION}${N}${C}                  ║${N}"
    echo -e "${C}╠═══════════════════════════════════════════════════╣${N}"
    printf "${C}║${N}  IP: ${G}%-20s${N}  Status: %-20s${C}║${N}\n" \
        "$SERVER_IP" "$(run_badge)"
    printf "${C}║${N}  Install: %-15s  Web Port: ${G}%-14s${N}${C}║${N}\n" \
        "$(install_badge)" "$WEB_PORT"
    if [ -n "$CF_DOMAIN" ]; then
        printf "${C}║${N}  CF Domain: ${G}%-38s${N}${C}║${N}\n" "$CF_DOMAIN"
    fi
    echo -e "${C}╚═══════════════════════════════════════════════════╝${N}"
    echo ""
}

# ================================================================
# PATCH SCRIPT (Python)
# ================================================================
create_patch_script() {
    cat > "$PATCH_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
# Công cụ chỉ để XEM nội dung server-entry.dat (không sửa gì cả).
# Entry được dùng nguyên bản như psiphond đã generate ra.
import sys, json

def decode(path):
    raw = open(path).read().strip()
    b = bytes.fromhex(raw)
    s = b.decode('utf-8')
    j = s.find('{')
    return s[:j], json.loads(s[j:])

def show(path):
    _, obj = decode(path)
    keys = ['ipAddress', 'tag', 'region', 'sshPort', 'sshObfuscatedPort',
            'meekServerPort', 'meekFrontingAddresses', 'meekFrontingHosts',
            'capabilities']
    for k in keys:
        v = obj.get(k)
        if v is not None:
            print(f"{k}: {v}")

cmd = sys.argv[1]
if cmd == 'show':
    show(sys.argv[2])
elif cmd == 'hex':
    print(open(sys.argv[2]).read().strip())
PYEOF
    chmod +x "$PATCH_SCRIPT"
}

# ================================================================
# GIỚI HẠN BĂNG THÔNG (traffic-rules.json) + PSIPHONAUTH
# ================================================================

# Ghi $TRAFFIC_RULES_FILE:
#  - DefaultRules: áp dụng cho MỌI client (kể cả không có token)
#  - FilteredRules: client trình psiphonAuth hợp lệ với AccessType =
#    $AUTH_ACCESS_TYPE (còn hạn, chưa bị revoke) -> bỏ giới hạn hoàn toàn
write_traffic_rules() {
    local bps=0
    if [ "${DEFAULT_LIMIT_KBPS:-0}" -gt 0 ] 2>/dev/null; then
        bps=$((DEFAULT_LIMIT_KBPS * 1024))
    fi

    local filtered_block=""
    if [ -f "$VERIFY_KEY_FILE" ]; then
        filtered_block=$(cat <<EOF
  "FilteredRules": [
    {
      "Filter": { "AuthorizedAccessTypes": ["$AUTH_ACCESS_TYPE"] },
      "Rules": {
        "RateLimits": {
          "ReadUnthrottledBytes": 0,
          "ReadBytesPerSecond": 0,
          "WriteUnthrottledBytes": 0,
          "WriteBytesPerSecond": 0,
          "CloseAfterExhausted": false,
          "EstablishmentReadBytesPerSecond": 0,
          "EstablishmentWriteBytesPerSecond": 0,
          "UnthrottleFirstTunnelOnly": false
        },
        "MaxTCPPortForwardCount": 0,
        "MaxUDPPortForwardCount": 0
      }
    }
  ]
EOF
)
    else
        filtered_block='  "FilteredRules": []'
    fi

    cat > "$TRAFFIC_RULES_FILE" <<EOF
{
  "DefaultRules": {
    "RateLimits": {
      "ReadUnthrottledBytes": 0,
      "ReadBytesPerSecond": $bps,
      "WriteUnthrottledBytes": 0,
      "WriteBytesPerSecond": $bps,
      "CloseAfterExhausted": false,
      "EstablishmentReadBytesPerSecond": $bps,
      "EstablishmentWriteBytesPerSecond": $bps,
      "UnthrottleFirstTunnelOnly": false
    },
    "MaxTCPPortForwardCount": 512,
    "MaxUDPPortForwardCount": 32
  },
$filtered_block
}
EOF
}

# Tạo helper Python để tiêm 2 field vào psiphond.config sau khi generate:
#   - TrafficRulesFilename -> trỏ tới $TRAFFIC_RULES_FILE
#   - AccessControlVerificationKeyRing -> nội dung $VERIFY_KEY_FILE (nếu có)
# Làm bằng cách sửa trực tiếp JSON, không phụ thuộc psiphond có flag CLI
# tương ứng hay không (config chỉ là json.Unmarshal lúc runtime).
create_inject_script() {
    cat > "$INJECT_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import sys, json, os

config_path, traffic_rules_path, verify_key_path, device_limits_path, kick_requests_path = sys.argv[1:6]

with open(config_path) as f:
    cfg = json.load(f)

cfg["TrafficRulesFilename"] = traffic_rules_path
cfg["AuthorizationDeviceLimitsFilename"] = device_limits_path
cfg["KickRequestsFilename"] = kick_requests_path

if os.path.exists(verify_key_path):
    try:
        with open(verify_key_path) as f:
            verify_key = json.load(f)
        cfg["AccessControlVerificationKeyRing"] = {"Keys": [verify_key]}
    except Exception as e:
        sys.exit(f"ERROR reading verify key {verify_key_path}: {e}")

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    chmod +x "$INJECT_SCRIPT"
}

# Tiêm (hoặc gỡ) MeekServerCertificate/MeekServerPrivateKey vào psiphond.config.
# Cách gọi:
#   inject_cert.py <config.json> set <cert.pem> <key.pem>   -> ghi cert/key vào config
#   inject_cert.py <config.json> unset                       -> xóa 2 field, quay lại self-signed
# json.dump tự escape \n trong chuỗi PEM đúng chuẩn JSON, không cần xử lý tay.
create_inject_cert_script() {
    cat > "$INJECT_CERT_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import sys, json

config_path = sys.argv[1]
action = sys.argv[2]

with open(config_path) as f:
    cfg = json.load(f)

if action == "set":
    cert_path, key_path = sys.argv[3], sys.argv[4]
    with open(cert_path) as f:
        cfg["MeekServerCertificate"] = f.read()
    with open(key_path) as f:
        cfg["MeekServerPrivateKey"] = f.read()
elif action == "unset":
    cfg.pop("MeekServerCertificate", None)
    cfg.pop("MeekServerPrivateKey", None)
else:
    sys.exit("unknown action: " + action)

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    chmod +x "$INJECT_CERT_SCRIPT"
}

inject_server_config() {
    local cfg="$INSTALL_DIR/psiphond.config"
    if [ ! -f "$cfg" ]; then
        echo -e "${R}  Không tìm thấy $cfg, bỏ qua bước tiêm config.${N}"
        return 1
    fi
    [ -f "$DEVICE_LIMITS_FILE" ] || echo '{}' > "$DEVICE_LIMITS_FILE"
    [ -f "$KICK_REQUESTS_FILE" ] || echo '[]' > "$KICK_REQUESTS_FILE"
    create_inject_script
    if ! python3 "$INJECT_SCRIPT" "$cfg" "$TRAFFIC_RULES_FILE" "$VERIFY_KEY_FILE" "$DEVICE_LIMITS_FILE" "$KICK_REQUESTS_FILE"; then
        echo -e "${R}  ✗ Tiêm config thất bại (xem lỗi Python ở trên). psiphond.config CHƯA được cập nhật.${N}"
        return 1
    fi
}

# Tải psiphon-authgen (nếu có URL cấu hình) hoặc yêu cầu copy tay.
ensure_authgen() {
    [ -x "$AUTHGEN_BINARY" ] && return 0

    if [ "${#AUTHGEN_URLS[@]}" -eq 0 ]; then
        echo -e "${R}  Chưa có psiphon-authgen tại $AUTHGEN_BINARY${N}"
        echo -e "${Y}  Tool này phải tự build từ package accesscontrol trong${N}"
        echo -e "${Y}  chính repo psiphon-tunnel-core bạn dùng để build psiphond custom.${N}"
        echo -e "${Y}  Build xong, copy binary vào: $AUTHGEN_BINARY${N}"
        return 1
    fi

    for url in "${AUTHGEN_URLS[@]}"; do
        echo -e "  → Thử tải psiphon-authgen: $url"
        if curl -fL --retry 2 --retry-delay 3 -o "$AUTHGEN_BINARY.tmp" "$url" \
            && [ -s "$AUTHGEN_BINARY.tmp" ] \
            && file "$AUTHGEN_BINARY.tmp" | grep -qE "ELF|executable"; then
            mv "$AUTHGEN_BINARY.tmp" "$AUTHGEN_BINARY"
            chmod +x "$AUTHGEN_BINARY"
            return 0
        fi
        rm -f "$AUTHGEN_BINARY.tmp"
    done

    echo -e "${R}  Tải psiphon-authgen thất bại. Copy binary thủ công vào: $AUTHGEN_BINARY${N}"
    return 1
}

# Sinh cặp khóa ký (chỉ nên chạy 1 lần). Ghi đè sẽ khiến MỌI token đã cấp
# trước đó không còn verify được (vì SigningKeyID thay đổi).
# Xuất verification key ra để copy sang VPS khác - đây là phần PUBLIC,
# an toàn để chia sẻ (khác hẳn SIGNING_KEY_FILE, tuyệt đối không đưa đi).
# Nhiều VPS cùng nhúng đúng 1 verification key này vào
# AccessControlVerificationKeyRing -> 1 token do SIGNING_KEY_FILE (chỉ giữ
# ở 1 nơi bạn issue token) cấp ra sẽ được CẢ hai VPS chấp nhận.
export_verification_key() {
    if [ ! -f "$VERIFY_KEY_FILE" ]; then
        echo -e "${R}  Chưa có verification key trên VPS này (chưa sinh keypair ở menu [2]).${N}"
        press_enter; return
    fi
    local export_path="/root/psiphon-verification-key-export.json"
    cp "$VERIFY_KEY_FILE" "$export_path"
    echo -e "${G}  ✓ Đã lưu ra: $export_path${N}"
    echo ""
    echo -e "  ${Y}Copy file này sang VPS thứ 2 (VD: scp), rồi ở VPS đó vào${N}"
    echo -e "  ${Y}menu [6] → [9] Import verification key, dán đường dẫn file.${N}"
    echo ""
    echo -e "  ${C}Nội dung (để copy tay nếu không dùng scp được):${N}"
    echo ""
    cat "$export_path"
    echo ""
    press_enter
}

# Nhập verification key ĐÃ CÓ SẴN từ 1 VPS khác - dùng khi bạn muốn VPS này
# chấp nhận CHUNG token với VPS kia, thay vì mỗi VPS tự sinh 1 key riêng
# (2 key riêng thì token cấp ở VPS A sẽ KHÔNG verify được ở VPS B).
#
# LƯU Ý: import key không tự đưa SIGNING_KEY_FILE (bí mật) sang - bạn vẫn
# chỉ issue token ở đúng 1 nơi đang giữ SIGNING_KEY_FILE gốc. VPS import
# key này chỉ có khả năng XÁC MINH token, không cấp được token mới.
import_verification_key() {
    header
    echo -e "${W}${BOLD}  IMPORT VERIFICATION KEY (dùng chung psiphonAuth)${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""
    if [ -f "$VERIFY_KEY_FILE" ]; then
        echo -e "${Y}  ⚠ VPS này đã có verification key riêng. Import sẽ GHI ĐÈ -${N}"
        echo -e "${Y}    token đã cấp bằng signing key CŨ của VPS này sẽ không${N}"
        echo -e "${Y}    còn verify được nữa (nếu key cũ khác key sắp import).${N}"
        confirm "  Vẫn tiếp tục?" || { press_enter; return; }
    fi

    echo -e "  ${Y}→ Chọn file verification key:${N}"; sleep 1
    if ! browse_file "/root" "*.json"; then press_enter; return; fi
    local src="$BROWSE_RESULT"

    echo ""
    echo -e "${Y}  QUAN TRỌNG: AccessType phải khớp CHÍNH XÁC với AccessType đã${N}"
    echo -e "${Y}  dùng lúc sinh keypair (gen-keys) ở VPS GỐC, nếu không client sẽ${N}"
    echo -e "${Y}  KHÔNG BAO GIỜ được unlimit dù token hợp lệ.${N}"
    echo -e "  AccessType hiện tại trên VPS này: ${G}$AUTH_ACCESS_TYPE${N}"
    echo -ne "  ${Y}Nhập AccessType của VPS gốc (Enter để giữ nguyên \"$AUTH_ACCESS_TYPE\"): ${N}"
    read -r new_access_type

    local do_restart_flag=0
    if is_running && confirm "  Restart server để áp dụng?"; then
        do_restart_flag=1
    fi

    if ! import_verification_key_core "$src" "${new_access_type:-$AUTH_ACCESS_TYPE}" "$do_restart_flag"; then
        press_enter; return 1
    fi
    press_enter
}

# Phần LÕI của import verification key, KHÔNG hỏi gì (không read/confirm) -
# để web dashboard (hoặc bất kỳ script khác) gọi lại được, tái dùng ĐÚNG
# logic đã kiểm chứng ở trên thay vì viết lại và có nguy cơ lệch bug.
# Tham số: $1 = đường dẫn file verification-key.json nguồn
#          $2 = AccessType muốn dùng (rỗng = giữ nguyên $AUTH_ACCESS_TYPE)
#          $3 = "1" nếu muốn tự restart server sau khi nhúng, "0"/rỗng nếu không
# In ra stdout các dòng "OK: ..." / "ERR: ..." để caller (vd. Flask) parse dễ.
import_verification_key_core() {
    local src="$1" new_access_type="$2" do_restart_flag="$3"

    if [ ! -f "$src" ]; then
        echo "ERR: Không tìm thấy file $src"
        return 1
    fi
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$src" 2>/dev/null; then
        echo "ERR: File không phải JSON hợp lệ"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$src" "$VERIFY_KEY_FILE"
    echo "OK: Đã lưu vào $VERIFY_KEY_FILE"

    if [ -n "$new_access_type" ] && [ "$new_access_type" != "$AUTH_ACCESS_TYPE" ]; then
        AUTH_ACCESS_TYPE="$new_access_type"
        save_config
        echo "OK: Đã đặt AccessType = $AUTH_ACCESS_TYPE"
    fi

    write_traffic_rules
    echo "OK: Đã ghi lại traffic-rules.json"

    if [ ! -f "$INSTALL_DIR/psiphond.config" ]; then
        echo "OK: Chưa có psiphond.config - key sẽ được nhúng lần generate/inject kế tiếp"
        return 0
    fi

    if ! inject_server_config; then
        echo "ERR: Import thất bại ở bước nhúng config - key chưa có hiệu lực"
        return 1
    fi
    echo "OK: Đã nhúng vào AccessControlVerificationKeyRing"

    if [ "$do_restart_flag" = "1" ]; then
        if is_running; then
            if do_restart; then
                echo "OK: Đã restart"
            else
                echo "ERR: Restart thất bại - SERVER CÓ THỂ ĐANG DỪNG, kiểm tra: systemctl status psiphond"
                return 1
            fi
        else
            echo "OK: Server đang dừng sẵn, không cần restart"
        fi
    fi
    return 0
}

generate_signing_keypair() {
    ensure_authgen || { press_enter; return 1; }

    if [ -f "$SIGNING_KEY_FILE" ]; then
        echo -e "${R}  Đã có signing key! Ghi đè sẽ vô hiệu hóa TẤT CẢ token cũ.${N}"
        confirm "  Vẫn tiếp tục ghi đè?" || return 1
    fi

    local do_restart_flag=0
    if is_running && confirm "  Restart server để áp dụng ngay sau khi sinh key?"; then
        do_restart_flag=1
    fi

    generate_signing_keypair_core "$do_restart_flag" "1"
    press_enter
}

# Phần LÕI sinh keypair, KHÔNG hỏi gì (không confirm ghi đè, không hỏi
# restart) - dùng cho web dashboard. In "OK: ..."/"ERR: ..." ra stdout.
# Tham số: $1 = "1" nếu muốn tự restart server sau khi sinh key.
#          $2 = "1" nếu ĐỒNG Ý ghi đè signing key đã có (bắt buộc phải
#               truyền đúng "1" nếu đã tồn tại key, để tránh caller nào đó
#               vô tình ghi đè và vô hiệu hoá toàn bộ token cũ).
generate_signing_keypair_core() {
    local do_restart_flag="$1" force_overwrite="$2"

    if [ -f "$SIGNING_KEY_FILE" ] && [ "$force_overwrite" != "1" ]; then
        echo "ERR: Đã có signing key. Ghi đè sẽ vô hiệu hoá TẤT CẢ token cũ - cần xác nhận force_overwrite=1"
        return 1
    fi

    ensure_authgen || { echo "ERR: Không có psiphon-authgen (xem hướng dẫn build tool)"; return 1; }

    "$AUTHGEN_BINARY" gen-keys "$AUTH_ACCESS_TYPE" "$SIGNING_KEY_FILE" "$VERIFY_KEY_FILE"
    if [ $? -ne 0 ]; then
        echo "ERR: Sinh keypair thất bại"
        return 1
    fi

    chmod 600 "$SIGNING_KEY_FILE"
    echo "OK: Đã sinh keypair. AccessType: $AUTH_ACCESS_TYPE"
    echo "OK: $SIGNING_KEY_FILE là BÍ MẬT - không chia sẻ, không đưa lên client"

    write_traffic_rules
    inject_server_config
    echo "OK: Đã cập nhật traffic-rules.json + psiphond.config"

    if [ "$do_restart_flag" = "1" ]; then
        if is_running; then
            if do_restart; then
                echo "OK: Đã restart"
            else
                echo "ERR: Restart thất bại - SERVER CÓ THỂ ĐANG DỪNG, kiểm tra: systemctl status psiphond"
                return 1
            fi
        else
            echo "OK: Server đang dừng sẵn, không cần restart"
        fi
    fi
    return 0
}

# Ghi/sửa giới hạn số thiết bị cho 1 authorization ID cụ thể vào
# $DEVICE_LIMITS_FILE (map "authID_base64" -> số thiết bị, 0 = không giới hạn).
# Không có entry cho 1 ID -> psiphond dùng mặc định 1 thiết bị.
set_device_limit() {
    local auth_id="$1"
    local limit="$2"
    [ -f "$DEVICE_LIMITS_FILE" ] || echo '{}' > "$DEVICE_LIMITS_FILE"
    python3 -c "
import json
with open('$DEVICE_LIMITS_FILE') as f:
    d = json.load(f)
d['$auth_id'] = $limit
with open('$DEVICE_LIMITS_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
}

issue_auth_token() {
    if [ ! -f "$SIGNING_KEY_FILE" ]; then
        echo -e "${R}  Chưa có signing key. Sinh keypair trước (menu này, mục [2]).${N}"
        press_enter; return 1
    fi
    ensure_authgen || { press_enter; return 1; }

    echo -ne "  ${Y}Ghi chú/ID user (để bạn tự theo dõi, VD: user_khach01): ${N}"
    read -r note
    [ -z "$note" ] && note="token_$(date +%s)"

    echo -ne "  ${Y}Số ngày hiệu lực [30]: ${N}"
    read -r days
    days="${days:-30}"

    echo -ne "  ${Y}Số thiết bị dùng đồng thời (0 = không giới hạn) [1]: ${N}"
    read -r devices
    [[ "$devices" =~ ^[0-9]+$ ]] || devices=1

    local result token authid
    result=$("$AUTHGEN_BINARY" issue "$SIGNING_KEY_FILE" "$note" "$days")
    if [ -z "$result" ]; then
        echo -e "${R}  Sinh token thất bại.${N}"; press_enter; return 1
    fi
    # psiphon-authgen (bản hiện tại) trả về field "authorizations" là MẢNG
    # JSON (VD ["eyJ..."]), đúng chuẩn field "Authorizations" trong config
    # client Psiphon. Bản binary cũ hơn có thể vẫn trả field "token" dạng
    # chuỗi thuần hoặc mảng 1 phần tử -> đoạn dưới nhận diện cả 3 trường hợp.
    token=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
auths = d.get('authorizations')
if auths is None:
    auths = d.get('token')
if isinstance(auths, str):
    auths = [auths]
auths = auths or []
print(auths[0] if auths else '')
")
    authid=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
a = d.get('authorizationId')
if isinstance(a, list):
    a = a[0] if a else ''
print(a)
")

    set_device_limit "$authid" "$devices"

    mkdir -p "$PANEL_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $note | ${days}d | devices=${devices} | authID=${authid} | $token" >> "$TOKENS_LOG"

    # Gộp token mới vào AUTH_ARRAY_FILE (mảng JSON tại "root" của panel).
    # Đọc mảng cũ (nếu file chưa tồn tại hoặc lỗi parse thì coi như rỗng),
    # thêm token mới vào cuối, rồi ghi đè lại toàn bộ file.
    python3 -c "
import json, sys

path = sys.argv[1]
new_token = sys.argv[2]

try:
    with open(path, 'r') as f:
        arr = json.load(f)
    if not isinstance(arr, list):
        arr = []
except (FileNotFoundError, json.JSONDecodeError):
    arr = []

arr.append(new_token)

with open(path, 'w') as f:
    json.dump(arr, f, separators=(', ', ': '))
    f.write('\n')
" "$AUTH_ARRAY_FILE" "$token"

    # File thứ 2: mỗi token 1 khối mảng JSON riêng, mỗi khối 1 dòng.
    # Chỉ cần append dòng mới, không cần đọc lại file cũ.
    python3 -c "
import json, sys

new_token = sys.argv[2]
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps([new_token], separators=(', ', ': ')))
    f.write('\n')
" "$AUTH_BLOCKS_FILE" "$token"

    # Config client Psiphon yêu cầu field "Authorizations" là MẢNG JSON,
    # kể cả khi chỉ có 1 token -> dòng bên dưới cho ra dạng sẵn để copy
    # thẳng vào config, khác với chuỗi thuần lưu trong tokens.log.
    local token_array
    token_array=$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$token")

    echo ""
    echo -e "${G}  ✓ psiphonAuth token (chuỗi thuần, để bạn tự lưu/theo dõi):${N}"
    echo ""
    echo "$token"
    echo ""
    echo -e "${G}  ✓ Dạng mảng JSON (dán thẳng vào \"Authorizations\" trong config client):${N}"
    echo ""
    echo "$token_array"
    echo ""
    echo -e "  ${Y}→ Đã gộp token này vào: ${G}${AUTH_ARRAY_FILE}${N}"
    echo -e "  ${Y}→ Đã append khối riêng vào: ${G}${AUTH_BLOCKS_FILE}${N}"
    echo ""
    echo -e "  ${Y}Giới hạn thiết bị: ${G}${devices}${N}${Y} (0 = không giới hạn), AuthID: $authid${N}"
    press_enter
}

# Ngắt kết nối ngay lập tức thiết bị đang giữ 1 authorization ID cụ thể,
# KHÔNG thu hồi vĩnh viễn - token vẫn còn hiệu lực, slot sẽ trống ngay để
# thiết bị tiếp theo (chủ thật hoặc không) chiếm lại theo đúng device limit.
# Yêu cầu: psiphond đã build với patch_device_limits.py bản có KickRequestsSet.
kick_authorization() {
    if ! is_running; then
        echo -e "${R}  psiphond đang không chạy.${N}"
        press_enter; return 1
    fi

    echo ""
    echo -e "${Y}  Dán AuthorizationID cần kick (xem ở menu [4] - cột AuthID):${N}"
    echo -ne "  ${Y}AuthorizationID: ${N}"
    read -r auth_id
    if [ -z "$auth_id" ]; then
        press_enter; return 1
    fi

    confirm "  Kick thiết bị đang giữ token này ngay bây giờ?" || { press_enter; return 1; }

    [ -f "$KICK_REQUESTS_FILE" ] || echo '[]' > "$KICK_REQUESTS_FILE"
    python3 -c "
import json
with open('$KICK_REQUESTS_FILE') as f:
    d = json.load(f)
if '$auth_id' not in d:
    d.append('$auth_id')
with open('$KICK_REQUESTS_FILE', 'w') as f:
    json.dump(d, f)
"

    local pid
    pid=$(pgrep -f "$INSTALL_DIR/psiphond" | head -1)
    if [ -z "$pid" ]; then
        echo -e "${R}  Không tìm thấy tiến trình psiphond đang chạy để gửi tín hiệu.${N}"
        press_enter; return 1
    fi

    kill -USR1 "$pid"
    echo -e "${G}  ✓ Đã gửi yêu cầu kick. Thiết bị đang giữ token sẽ bị ngắt trong giây lát.${N}"
    echo -e "  ${Y}Token vẫn còn hiệu lực - ai connect lại trước sẽ chiếm slot (kể cả kẻ lạ).${N}"
    press_enter
}

list_auth_tokens() {
    echo ""
    if [ ! -f "$TOKENS_LOG" ]; then
        echo -e "${Y}  Chưa cấp token nào.${N}"
    else
        echo -e "${W}  Ngày cấp             | Ghi chú          | Hạn  | Token (chuỗi thuần)${N}"
        echo -e "${C}  ─────────────────────────────────────────────────────${N}"
        cat "$TOKENS_LOG"
        echo ""
        echo -e "${Y}  → Dán thẳng vào \"Authorizations\" của config client: dùng${N}"
        echo -e "${Y}    dạng [\"<token>\"] (mảng JSON), kể cả khi chỉ 1 token.${N}"
    fi
    press_enter
}

# Đặt lại giới hạn băng thông mặc định (KB/s, 0 = tắt limit) - KHÔNG hỏi gì,
# dùng cho web dashboard. In "OK: ..."/"ERR: ..." ra stdout.
# Tham số: $1 = số KB/s (số nguyên >= 0)
#          $2 = "1" nếu muốn tự restart server sau khi áp dụng
set_default_limit_core() {
    local kbps="$1" do_restart_flag="$2"

    if ! [[ "$kbps" =~ ^[0-9]+$ ]]; then
        echo "ERR: Giá trị KB/s không hợp lệ: $kbps"
        return 1
    fi

    DEFAULT_LIMIT_KBPS="$kbps"
    save_config
    write_traffic_rules
    echo "OK: Đã đặt giới hạn mặc định = ${kbps} KB/s (0 = tắt)"
    echo "OK: Đã cập nhật traffic-rules.json"

    if [ -f "$INSTALL_DIR/psiphond.config" ]; then
        inject_server_config
    fi

    if [ "$do_restart_flag" = "1" ]; then
        if is_running; then
            if do_restart; then
                echo "OK: Đã restart"
            else
                echo "ERR: Restart thất bại - SERVER CÓ THỂ ĐANG DỪNG, kiểm tra: systemctl status psiphond"
                return 1
            fi
        else
            echo "OK: Server đang dừng sẵn, không cần restart"
        fi
    fi
    return 0
}

# In thông tin server entry (JSON) cho web dashboard: có tồn tại không,
# thông tin human-readable (từ patch_entry.py show), và nội dung hex đầy đủ
# (để hiển thị/copy/tải trên web).
web_server_entry_info() {
    if [ ! -f "$ENTRY_PATCHED" ]; then
        echo '{"exists": false}'
        return 0
    fi
    local info hex
    info=$(python3 "$PATCH_SCRIPT" show "$ENTRY_PATCHED" 2>/dev/null)
    hex=$(cat "$ENTRY_PATCHED")
    ENTRY_INFO_TEXT="$info" ENTRY_HEX_TEXT="$hex" python3 -c "
import json, os
print(json.dumps({
    'exists': True,
    'info': os.environ.get('ENTRY_INFO_TEXT', ''),
    'hex': os.environ.get('ENTRY_HEX_TEXT', ''),
}))
"
}

menu_limit_auth() {
    while true; do
        header
        echo -e "${W}${BOLD}  [6] GIỚI HẠN BĂNG THÔNG & PSIPHONAUTH${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        if [ "${DEFAULT_LIMIT_KBPS:-0}" -gt 0 ] 2>/dev/null; then
            echo -e "  Giới hạn mặc định : ${G}${DEFAULT_LIMIT_KBPS} KB/s${N} (client không có token)"
        else
            echo -e "  Giới hạn mặc định : ${Y}Không giới hạn (tính năng đang tắt)${N}"
        fi
        echo -e "  AccessType token  : ${G}$AUTH_ACCESS_TYPE${N}"
        if [ -f "$SIGNING_KEY_FILE" ]; then
            echo -e "  Signing key       : ${G}✓ đã có${N}"
        else
            echo -e "  Signing key       : ${R}✗ chưa sinh${N}"
        fi
        echo ""
        echo -e "  ${W}[1]${N} Đặt/sửa giới hạn mặc định (KB/s, 0 = tắt)"
        echo -e "  ${W}[2]${N} Sinh cặp khóa ký (bắt buộc trước khi cấp token)"
        echo -e "  ${W}[3]${N} Cấp psiphonAuth token mới cho 1 user"
        echo -e "  ${W}[4]${N} Xem danh sách token đã cấp"
        echo -e "  ${W}[5]${N} Sửa AccessType (nhãn token)"
        echo -e "  ${W}[6]${N} Sửa số thiết bị của 1 token đã cấp"
        echo -e "  ${W}[7]${N} Kick thiết bị đang giữ 1 token (khẩn cấp - nghi lộ token)"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo -e "  ${W}[8]${N} Export verification key (dùng chung psiphonAuth cho nhiều VPS)"
        echo -e "  ${W}[9]${N} Import verification key từ VPS khác (thay vì tự sinh key riêng)"
        echo -e "  ${W}[0]${N} Quay lại"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r c

        case "$c" in
            1)
                echo -ne "  ${Y}Giới hạn KB/s (0 = không giới hạn) [$DEFAULT_LIMIT_KBPS]: ${N}"
                read -r inp
                if [[ "$inp" =~ ^[0-9]+$ ]]; then
                    local do_restart_flag=0
                    if is_running && confirm "  Restart server để áp dụng ngay?"; then
                        do_restart_flag=1
                    fi
                    set_default_limit_core "$inp" "$do_restart_flag"
                fi
                press_enter ;;
            2) generate_signing_keypair ;;
            3) issue_auth_token ;;
            4) list_auth_tokens ;;
            5)
                echo -ne "  ${Y}AccessType mới [$AUTH_ACCESS_TYPE]: ${N}"
                read -r inp
                if [ -n "$inp" ]; then
                    echo -e "${Y}  ⚠ Đổi AccessType KHÔNG đổi key hiện có -${N}"
                    echo -e "${Y}    token đã cấp trước đó dùng AccessType cũ vẫn hợp lệ,${N}"
                    echo -e "${Y}    nhưng traffic-rules.json sẽ chỉ khớp AccessType mới.${N}"
                    confirm "  Tiếp tục?" && {
                        AUTH_ACCESS_TYPE="$inp"
                        save_config
                        write_traffic_rules
                        echo -e "${G}  ✓ Đã đổi. Cần sinh lại keypair + token mới nếu muốn dùng AccessType này.${N}"
                    }
                fi
                press_enter ;;
            6)
                echo -ne "  ${Y}AuthorizationID (xem ở menu [4]): ${N}"
                read -r auth_id
                if [ -n "$auth_id" ]; then
                    echo -ne "  ${Y}Số thiết bị mới (0 = không giới hạn): ${N}"
                    read -r new_limit
                    if [[ "$new_limit" =~ ^[0-9]+$ ]]; then
                        set_device_limit "$auth_id" "$new_limit"
                        echo -e "${G}  ✓ Đã cập nhật (hot-reload tự động, không cần restart).${N}"
                    fi
                fi
                press_enter ;;
            7) kick_authorization ;;
            8) export_verification_key ;;
            9) import_verification_key ;;
            0) return ;;
        esac
    done
}

# ================================================================
# SYSTEMD SERVICE
# ================================================================
create_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Psiphon Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$BINARY run
Restart=on-failure
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable psiphond 2>/dev/null
}

# ================================================================
# CHỌN PROTOCOL KIỂU CHECKBOX (dùng lúc cài đặt)
# ================================================================
select_protocols_checkbox() {
    local selected=()
    local idx
    for idx in "${!PROTO_LIST[@]}"; do
        local proto port enabled
        IFS=':' read -r proto port enabled <<< "${PROTO_LIST[$idx]}"
        selected[$idx]="$enabled"
    done

    while true; do
        header
        echo -e "${W}${BOLD}  CHỌN PROTOCOL MUỐN CÀI ĐẶT${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo -e "  ${Y}Gõ số để tích/bỏ tích, cách nhau bằng dấu cách (VD: 1 3 5)${N}"
        echo -e "  ${Y}[A] Chọn tất cả   [K] Bỏ chọn tất cả   [Enter] Xong${N}"
        echo ""

        idx=0
        for entry in "${PROTO_LIST[@]}"; do
            local proto port enabled box tag
            IFS=':' read -r proto port enabled <<< "$entry"
            [ "${selected[$idx]}" = "true" ] && box="${G}[x]${N}" || box="${R}[ ]${N}"
            tag=""
            is_ws_experimental "$proto" && tag=" ${Y}(🧪 cần psiphond custom)${N}"
            is_shared_meek_port_protocol "$proto" && tag=" ${Y}(cần $SHARED_MEEK_PORT_PARENT đang BẬT)${N}"
            printf "  %b  %-2d  %-36s port %s%b\n" "$box" "$((idx+1))" "$proto" "$port" "$tag"
            ((idx++))
        done
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r input

        case "${input^^}" in
            "") break ;;
            A) for i in "${!selected[@]}"; do selected[$i]="true"; done ;;
            K) for i in "${!selected[@]}"; do selected[$i]="false"; done ;;
            *)
                for num in $input; do
                    [[ "$num" =~ ^[0-9]+$ ]] || continue
                    local i=$((num-1))
                    if [ "$i" -ge 0 ] && [ "$i" -lt "${#PROTO_LIST[@]}" ]; then
                        if [ "${selected[$i]}" = "true" ]; then
                            selected[$i]="false"
                        else
                            selected[$i]="true"
                        fi
                    fi
                done
                ;;
        esac
    done

    # Ghi trạng thái tích chọn ngược lại vào PROTO_LIST
    for idx in "${!PROTO_LIST[@]}"; do
        local proto port enabled
        IFS=':' read -r proto port enabled <<< "${PROTO_LIST[$idx]}"
        PROTO_LIST[$idx]="$proto:$port:${selected[$idx]}"
    done

    # Đồng bộ port + tự tắt các protocol dùng-chung-port (VD FRONTED-MEEK-QUIC-OSSH)
    # nếu FRONTED-MEEK-OSSH không được chọn cùng.
    sync_shared_meek_children

    save_config

    # Chỉ CẢNH BÁO nếu có nhóm protocol đang BẬT trùng port (không tự tắt).
    warn_all_port_conflicts
}

# ================================================================
# MENU 1: CÀI ĐẶT
# ================================================================
menu_install() {
    header
    echo -e "${W}${BOLD}  [1] CÀI ĐẶT PSIPHON SERVER${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""

    if is_installed; then
        echo -e "${Y}  Psiphon đã được cài đặt.${N}"
        confirm "  Cài đặt lại từ đầu?" || return
        systemctl stop psiphond 2>/dev/null
    fi

    echo -e "${Y}  [1/7] Cài đặt dependencies...${N}"
    apt-get update -qq
    apt-get install -y -qq curl wget python3 dnsutils >/dev/null 2>&1
    echo -e "${G}  ✓ OK${N}"

    echo -e "${Y}  [2/7] Tải psiphond...${N}"
    mkdir -p "$INSTALL_DIR"
    DOWNLOAD_OK=0
    for url in "${PSIPHOND_URLS[@]}"; do
        echo -e "  → Thử: $url"
        for attempt in 1 2 3; do
            if curl -fL --retry 2 --retry-delay 3 --progress-bar -o "$BINARY.tmp" "$url" \
                && [ -s "$BINARY.tmp" ] \
                && file "$BINARY.tmp" | grep -qE "ELF|executable"; then
                DOWNLOAD_OK=1
                break 2
            fi
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -L "$url")
            if [ "$HTTP_CODE" = "429" ]; then
                echo -e "${Y}    Bị rate-limit (429), đợi 10s rồi thử lại (lần $attempt/3)...${N}"
                rm -f "$BINARY.tmp"
                sleep 10
            else
                rm -f "$BINARY.tmp"
                break
            fi
        done
        [ "$DOWNLOAD_OK" = "1" ] && break
    done

    if [ "$DOWNLOAD_OK" = "1" ]; then
        mv "$BINARY.tmp" "$BINARY"
        chmod +x "$BINARY"
        echo -e "${G}  ✓ Tải xong${N}"
    else
        echo -e "${R}  Không tải được từ bất kỳ nguồn nào (GitHub/jsDelivr đều lỗi hoặc rate-limit)!${N}"
        rm -f "$BINARY.tmp"
        echo -e "${R}  Copy thủ công file psiphond vào: $INSTALL_DIR/${N}"
        press_enter; return
    fi

    echo -e "${Y}  [3/7] Tải psiphon-authgen (dùng cho psiphonAuth / giới hạn băng thông)...${N}"
    if ensure_authgen; then
        echo -e "${G}  ✓ Tải xong${N}"
    else
        echo -e "${Y}  ⚠ Không tải được psiphon-authgen ngay bây giờ — không sao, cài đặt${N}"
        echo -e "${Y}    vẫn tiếp tục. Panel sẽ tự thử tải lại khi bạn vào menu [6] → [2].${N}"
    fi

    echo -e "${Y}  [4/7] Chọn protocol muốn cài đặt...${N}"
    sleep 1
    select_protocols_checkbox

    echo -e "${Y}  [5/7] Giới hạn băng thông mặc định...${N}"
    echo -e "  Client KHÔNG có psiphonAuth token sẽ bị giới hạn tốc độ này."
    echo -e "  Client có token hợp lệ (AccessType: $AUTH_ACCESS_TYPE) sẽ được bỏ giới hạn."
    echo -ne "  ${Y}Giới hạn KB/s (0 = không giới hạn) [$DEFAULT_LIMIT_KBPS]: ${N}"
    read -r inp
    [[ "$inp" =~ ^[0-9]+$ ]] && DEFAULT_LIMIT_KBPS="$inp"
    echo -e "${G}  ✓ OK ($DEFAULT_LIMIT_KBPS KB/s)${N}"

    echo -e "${Y}  [6/7] Tạo công cụ hỗ trợ...${N}"
    create_patch_script
    echo -e "${G}  ✓ OK${N}"

    echo -e "${Y}  [7/7] Cài systemd service...${N}"
    create_service
    echo -e "${G}  ✓ OK${N}"

    save_config


    # Tạo lệnh shortcut psiphon-panel
    curl -s "$PANEL_URL" -o /usr/local/bin/psiphon-panel
    chmod +x /usr/local/bin/psiphon-panel

    echo ""
    echo -e "${G}  ✓ Cài đặt hoàn tất!${N}"
    echo -e "${Y}  → Vào menu [2] để generate server entry (có thể đổi protocol bất cứ lúc nào).${N}"
    echo -e "${C}  → Lần sau gõ: ${W}psiphon-panel${N}${C} để mở lại panel.${N}"
    press_enter
}

# ================================================================
# MENU 2: CẤU HÌNH PROTOCOL & PORT
# ================================================================
menu_config() {
    while true; do
        header
        echo -e "${W}${BOLD}  [2] CẤU HÌNH SERVER & PROTOCOL${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        echo -e "  IP Server  : ${G}$SERVER_IP${N}"
        echo -e "  Web Port   : ${G}$WEB_PORT${N}"
        echo -e "  Region     : ${G}${REGION:-"(chưa đặt)"}${N}"
        echo ""

        # Cloudflare info
        if [ -n "$CF_DOMAIN" ]; then
            echo -e "  CF Domain  : ${G}$CF_DOMAIN${N}  (Host header)"
            echo -e "  Fronting   : ${G}$CF_IP${N}  (CDN address)"
        else
            echo -e "  CF Domain  : ${Y}(chưa cấu hình - FRONTED-MEEK không có fronting)${N}"
        fi
        echo ""

        echo -e "${W}  Protocol & Port:${N}"
        echo -e "${C}  ┌────┬──────────────────────────────────────┬───────┬────────┐${N}"
        echo -e "${C}  │ No │ Protocol                             │ Port  │ Trạng  │${N}"
        echo -e "${C}  ├────┼──────────────────────────────────────┼───────┼────────┤${N}"

        local i=0
        for entry in "${PROTO_LIST[@]}"; do
            local proto port enabled
            IFS=':' read -r proto port enabled <<< "$entry"
            local badge label
            [ "$enabled" = "true" ] && badge="${G}✓ BẬT ${N}" || badge="${R}✗ TẮT ${N}"
            label="$proto"
            is_ws_experimental "$proto" && label="🧪 $proto"
            is_shared_meek_port_protocol "$proto" && label="⇄ $proto"
            printf "  ${C}│${N} ${W}%-2d${N} ${C}│${N} %-38s ${C}│${N} %-5s ${C}│${N} %b ${C}│${N}\n" \
                "$((i+1))" "$label" "$port" "$badge"
            ((i++))
        done
        echo -e "${C}  └────┴──────────────────────────────────────┴───────┴────────┘${N}"
        echo ""
        warn_all_port_conflicts
        echo -e "  ${Y}🧪 = protocol WebSocket-OSSH thử nghiệm, cần bản psiphond tùy biến${N}"
        echo -e "  ${Y}   (binary mặc định tải về CHƯA hỗ trợ, generate sẽ lỗi nếu bật).${N}"
        echo -e "  ${Y}⇄ = không có listener riêng (port chỉ để gắn capability), yêu cầu${N}"
        echo -e "  ${Y}   $SHARED_MEEK_PORT_PARENT phải đang BẬT thì mới BẬT được — port tự chọn riêng.${N}"
        echo -e "  ${W}[I]${N} Sửa IP Server    ${W}[W]${N} Sửa Web Port    ${W}[R]${N} Sửa Region"
        echo -e "  ${W}[C]${N} Cấu hình Cloudflare Fronting"
        echo -e "  ${W}[T]${N} Chứng chỉ TLS gốc (Cloudflare Origin CA) cho FRONTED-WSS/MEEK"
        echo -e "  ${W}[số]${N} Bật/Tắt protocol & sửa port"
        echo -e "  ${W}[G]${N} Generate Server Entry ngay"
        echo -e "  ${W}[0]${N} Quay lại"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r choice

        case "${choice^^}" in
            I)
                echo -ne "  ${Y}Nhập IP mới [$SERVER_IP]: ${N}"
                read -r inp; [ -n "$inp" ] && SERVER_IP="$inp"
                save_config ;;
            W)
                echo -ne "  ${Y}Web Port [$WEB_PORT]: ${N}"
                read -r inp; [ -n "$inp" ] && WEB_PORT="$inp"
                save_config ;;
            R)
                echo -ne "  ${Y}Region (VD: VN, JP, US) [$REGION]: ${N}"
                read -r inp; [ -n "$inp" ] && REGION="${inp^^}"
                save_config
                echo -e "${G}  ✓ Region: $REGION${N}"; sleep 1 ;;
            C) menu_cloudflare ;;
            T) menu_origin_cert ;;
            G) do_generate; return ;;
            0) return ;;
            ''|*[!0-9]*) ;;
            *)
                local idx=$((choice-1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#PROTO_LIST[@]}" ]; then
                    edit_protocol "$idx"
                fi ;;
        esac
    done
}

# ================================================================
# TIỆN ÍCH: DUYỆT FILE DẠNG TEXT (không cần gõ full đường dẫn)
# ================================================================
# Dùng: browse_file "/thư/mục/bắt đầu"
# Kết quả: đường dẫn file chọn được đặt vào biến toàn cục BROWSE_RESULT
# Trả về: 0 = đã chọn được file, 1 = người dùng hủy
browse_file() {
    local dir="${1:-/root}"
    # $2: danh sách pattern lọc file, cách nhau bởi khoảng trắng
    # (mặc định lọc file chứng chỉ nếu không truyền gì)
    local patterns=(${2:-"*.pem" "*.crt" "*.key" "*.cer"})
    [ -d "$dir" ] || dir="/root"
    BROWSE_RESULT=""

    while true; do
        dir=$(cd "$dir" 2>/dev/null && pwd) || dir="/root"

        local entries=() display=() f
        local find_expr=()
        local p first=1
        for p in "${patterns[@]}"; do
            if [ "$first" -eq 1 ]; then
                find_expr+=(-iname "$p")
                first=0
            else
                find_expr+=(-o -iname "$p")
            fi
        done

        entries+=("..")
        display+=("${C}[..]${N} (lên 1 cấp thư mục)")

        while IFS= read -r f; do
            [ -z "$f" ] && continue
            entries+=("$f")
            display+=("${C}[DIR]${N} $f")
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

        # Ưu tiên hiện file khớp pattern cho gọn; nếu thư mục không có file
        # loại này thì hiện luôn tất cả file để không bị "trống rỗng"
        local matched
        matched=$(find "$dir" -maxdepth 1 -mindepth 1 -type f \( "${find_expr[@]}" \) 2>/dev/null)
        if [ -n "$matched" ]; then
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                entries+=("$f"); display+=("$f")
            done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f \( "${find_expr[@]}" \) \
                -printf '%f\n' 2>/dev/null | sort)
        else
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                entries+=("$f"); display+=("$f")
            done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f -printf '%f\n' 2>/dev/null | sort)
        fi

        header
        echo -e "${W}${BOLD}  DUYỆT FILE${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo -e "  Thư mục hiện tại: ${Y}$dir${N}"
        echo ""
        local i=1
        for d in "${display[@]}"; do
            echo -e "  ${W}[$i]${N} $d"
            ((i++))
        done
        echo ""
        echo -e "  ${W}[P]${N} Gõ tay đường dẫn đầy đủ"
        echo -e "  ${W}[0]${N} Hủy"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r sel

        case "$sel" in
            0) return 1 ;;
            [Pp])
                echo -ne "  ${Y}Đường dẫn file: ${N}"
                read -r manual
                if [ -f "$manual" ]; then
                    BROWSE_RESULT="$manual"; return 0
                else
                    echo -e "${R}  File không tồn tại.${N}"; sleep 1
                fi ;;
            ''|*[!0-9]*) : ;;
            *)
                if [ "$sel" -ge 1 ] && [ "$sel" -le "${#entries[@]}" ]; then
                    local chosen="${entries[$((sel-1))]}"
                    if [ "$chosen" = ".." ]; then
                        dir="$(dirname "$dir")"
                    elif [ -d "$dir/$chosen" ]; then
                        dir="$dir/$chosen"
                    else
                        BROWSE_RESULT="$dir/$chosen"
                        return 0
                    fi
                fi ;;
        esac
    done
}

# ================================================================
# MENU CHỨNG CHỈ TLS GỐC (CLOUDFLARE ORIGIN CA)
# ================================================================
menu_origin_cert() {
    header
    echo -e "${W}${BOLD}  [T] CHỨNG CHỈ TLS GỐC (CLOUDFLARE ORIGIN CA)${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""
    echo -e "  Thay cho cert self-signed mà psiphond tự sinh ra cho chặng"
    echo -e "  ${W}Cloudflare → VPS này${N} (dùng cho meek + FRONTED-WS(S)-OSSH)."
    echo -e "  ${Y}Chỉ thật sự cần nếu Cloudflare SSL/TLS mode = Full (strict).${N}"
    echo -e "  ${Y}Ở mode Full, Cloudflare không kiểm cert origin, không bắt buộc.${N}"
    echo ""

    if [ -f "$CF_ORIGIN_CERT_FILE" ]; then
        echo -e "  Trạng thái hiện tại: ${G}✓ Đang dùng Origin CA cert${N}"
        echo -e "  $(openssl x509 -in "$CF_ORIGIN_CERT_FILE" -noout -subject -enddate 2>/dev/null | sed 's/^/  /')"
    else
        echo -e "  Trạng thái hiện tại: ${Y}Đang dùng cert self-signed (psiphond tự sinh)${N}"
    fi
    echo ""
    echo -e "  ${W}[1]${N} Nạp cert/key mới từ đường dẫn file trên VPS"
    echo -e "  ${W}[2]${N} Dán trực tiếp nội dung PEM (cert rồi key)"
    echo -e "  ${W}[3]${N} Gỡ Origin CA cert, quay lại self-signed"
    echo -e "  ${W}[0]${N} Quay lại"
    echo ""
    echo -ne "  ${Y}Chọn: ${N}"
    read -r c

    local tmp_cert="" tmp_key=""
    case "$c" in
        1)
            echo -e "  ${Y}→ Chọn file CERT (.pem/.crt):${N}"; sleep 1
            if ! browse_file "/root"; then press_enter; return; fi
            tmp_cert="$BROWSE_RESULT"

            echo -e "  ${Y}→ Chọn file PRIVATE KEY (.pem/.key):${N}"; sleep 1
            if ! browse_file "$(dirname "$tmp_cert")"; then press_enter; return; fi
            tmp_key="$BROWSE_RESULT"

            if [ ! -f "$tmp_cert" ] || [ ! -f "$tmp_key" ]; then
                echo -e "${R}  Không tìm thấy file.${N}"; press_enter; return
            fi
            ;;
        2)
            echo -e "  ${Y}Dán nội dung CERT (kết thúc bằng dòng chỉ có EOF):${N}"
            tmp_cert=$(mktemp)
            while IFS= read -r line; do
                [ "$line" = "EOF" ] && break
                echo "$line" >> "$tmp_cert"
            done
            echo -e "  ${Y}Dán nội dung PRIVATE KEY (kết thúc bằng dòng chỉ có EOF):${N}"
            tmp_key=$(mktemp)
            while IFS= read -r line; do
                [ "$line" = "EOF" ] && break
                echo "$line" >> "$tmp_key"
            done
            ;;
        3)
            rm -f "$CF_ORIGIN_CERT_FILE" "$CF_ORIGIN_KEY_FILE"
            create_inject_cert_script
            if [ -f "$INSTALL_DIR/psiphond.config" ]; then
                python3 "$INJECT_CERT_SCRIPT" "$INSTALL_DIR/psiphond.config" unset
                echo -e "${G}  ✓ Đã gỡ, quay lại cert self-signed.${N}"
            fi
            if is_running && confirm "  Restart server để áp dụng?"; then
                do_restart
            fi
            press_enter; return ;;
        0) return ;;
        *) return ;;
    esac

    # Validate: cert phải là cert hợp lệ, key phải khớp modulus với cert
    if ! openssl x509 -in "$tmp_cert" -noout -subject &>/dev/null; then
        echo -e "${R}  File cert không hợp lệ (không parse được bằng openssl x509).${N}"
        press_enter; return
    fi
    local cert_mod key_mod
    cert_mod=$(openssl x509 -in "$tmp_cert" -noout -modulus 2>/dev/null | openssl md5)
    key_mod=$(openssl rsa -in "$tmp_key" -noout -modulus 2>/dev/null | openssl md5)
    if [ -z "$key_mod" ]; then
        # thử EC key nếu không phải RSA
        key_mod=$(openssl ec -in "$tmp_key" -noout -text 2>/dev/null | openssl md5)
    fi
    if [ "$cert_mod" != "$key_mod" ]; then
        echo -e "${R}  Cảnh báo: cert và private key có vẻ KHÔNG khớp nhau!${N}"
        confirm "  Vẫn tiếp tục?" || { press_enter; return; }
    fi

    if [ ! -f "$INSTALL_DIR/psiphond.config" ]; then
        echo -e "${R}  Chưa có psiphond.config — cài đặt/generate trước đã.${N}"
        press_enter; return
    fi

    cp "$tmp_cert" "$CF_ORIGIN_CERT_FILE"
    cp "$tmp_key" "$CF_ORIGIN_KEY_FILE"
    chmod 600 "$CF_ORIGIN_KEY_FILE"

    create_inject_cert_script
    python3 "$INJECT_CERT_SCRIPT" "$INSTALL_DIR/psiphond.config" set \
        "$CF_ORIGIN_CERT_FILE" "$CF_ORIGIN_KEY_FILE"

    echo -e "${G}  ✓ Đã ghi Origin CA cert/key vào psiphond.config${N}"
    echo -e "${G}    (áp dụng cho meek + FRONTED-WS(S)-OSSH, dùng chung field).${N}"

    if is_running && confirm "  Restart server để áp dụng?"; then
        do_restart
    fi
    press_enter
}

# ================================================================
# MENU CLOUDFLARE FRONTING
# ================================================================
menu_cloudflare() {
    header
    echo -e "${W}${BOLD}  [C] CẤU HÌNH CLOUDFLARE FRONTING${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""
    echo -e "  Client kết nối đến ${W}Fronting Address${N} (domain CDN bất kỳ trên Cloudflare),"
    echo -e "  gửi Host header = ${W}CF Domain${N} (domain của bạn đã proxy qua Cloudflare),"
    echo -e "  Cloudflare forward về VPS."
    echo ""
    echo -e "${Y}  Lưu ý: giá trị này CHỈ để bạn ghi nhớ / dùng cấu hình client thủ công.${N}"
    echo -e "${Y}  Panel không còn tự vá vào server entry — entry dùng nguyên bản psiphond sinh ra.${N}"
    echo ""

    if [ -n "$CF_DOMAIN" ]; then
        echo -e "  CF Domain (Host header) : ${G}$CF_DOMAIN${N}"
        echo -e "  Fronting Address        : ${G}$CF_IP${N}"
        echo ""
    fi

    echo -ne "  ${Y}CF Domain - Host header (VD: bug.mpsi.io.vn) [${CF_DOMAIN}]: ${N}"
    read -r inp
    inp=$(echo "$inp" | tr -d '[:space:]')
    [ -n "$inp" ] && CF_DOMAIN="$inp"

    if [ -z "$CF_DOMAIN" ]; then
        echo -e "${R}  Chưa nhập domain!${N}"
        press_enter; return
    fi

    echo -ne "  ${Y}Fronting Address - domain CDN bất kỳ trên Cloudflare${N}"
    echo ""
    echo -ne "  ${Y}(VD: support.appsflyer.com) [${CF_IP}]: ${N}"
    read -r inp2
    inp2=$(echo "$inp2" | tr -d '[:space:]')
    [ -n "$inp2" ] && CF_IP="$inp2"

    if [ -z "$CF_IP" ]; then
        echo -e "${R}  Chưa nhập Fronting Address!${N}"
        press_enter; return
    fi

    save_config

    echo ""
    echo -e "${G}  ✓ Đã lưu cấu hình Cloudflare!${N}"
    echo -e "  CF Domain (Host)  : ${G}$CF_DOMAIN${N}"
    echo -e "  Fronting Address  : ${G}$CF_IP${N}"
    echo -e "${Y}  (Chỉ lưu để tham khảo, không tự vá vào server entry)${N}"
    press_enter
}

# Tự TẮT các protocol phụ thuộc (VD FRONTED-MEEK-QUIC-OSSH) nếu
# $SHARED_MEEK_PORT_PARENT (FRONTED-MEEK-OSSH) đang TẮT. Port của các protocol
# này ĐỘC LẬP, không bị ép trùng port với cha — chỉ trạng thái BẬT/TẮT là phụ
# thuộc (FRONTED-MEEK-OSSH phải BẬT thì FRONTED-MEEK-QUIC-OSSH mới được BẬT).
# Gọi hàm này sau MỌI thay đổi tới protocol cha hoặc protocol con phụ thuộc,
# trước khi save_config.
sync_shared_meek_children() {
    local parent_enabled entry proto port enabled i
    is_parent_meek_enabled && parent_enabled="true" || parent_enabled="false"

    for i in "${!PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "${PROTO_LIST[$i]}"
        if is_shared_meek_port_protocol "$proto"; then
            if [ "$parent_enabled" != "true" ] && [ "$enabled" = "true" ]; then
                PROTO_LIST[$i]="$proto:$port:false"
                echo -e "  ${Y}⚠ Tự động TẮT $proto (yêu cầu $SHARED_MEEK_PORT_PARENT phải BẬT trước)${N}"
            fi
        fi
    done
}

# Tìm các protocol KHÁC đang BẬT mà dùng cùng port với "$port_to_check"
# (bỏ qua chính protocol tại $skip_idx). In ra danh sách index, mỗi dòng 1 số.
#
# LƯU Ý: các protocol trong SHARED_MEEK_PORT_PROTOS (VD: FRONTED-MEEK-QUIC-OSSH)
# CHỦ ĐÍCH dùng chung port với $SHARED_MEEK_PORT_PARENT (không có listener
# riêng) — cặp này KHÔNG được tính là xung đột, không cảnh báo.
find_port_conflicts() {
    local port_to_check="$1"
    local skip_idx="$2"
    local skip_proto=""
    if [ -n "$skip_idx" ] && [ "$skip_idx" -ge 0 ] 2>/dev/null; then
        local se sp sen
        IFS=':' read -r se sp sen <<< "${PROTO_LIST[$skip_idx]}"
        skip_proto="$se"
    fi
    local i=0
    for entry in "${PROTO_LIST[@]}"; do
        if [ "$i" -ne "$skip_idx" ]; then
            local p pt en
            IFS=':' read -r p pt en <<< "$entry"
            if [ "$en" = "true" ] && [ "$pt" = "$port_to_check" ]; then
                # Bỏ qua cặp share-port chủ đích (theo cả 2 chiều)
                if { is_shared_meek_port_protocol "$p" && [ "$skip_proto" = "$SHARED_MEEK_PORT_PARENT" ]; } || \
                   { is_shared_meek_port_protocol "$skip_proto" && [ "$p" = "$SHARED_MEEK_PORT_PARENT" ]; }; then
                    ((i++)); continue
                fi
                echo "$i"
            fi
        fi
        ((i++))
    done
}

# CHỈ CẢNH BÁO (không tự tắt) nếu protocol tại $idx trùng port với protocol
# khác đang BẬT. psiphond không thể lắng nghe 2 protocol thường trên cùng 1
# port, nhưng việc bật/tắt là do người dùng tự quyết định — panel chỉ nhắc.
# Không áp dụng cho cặp share-port chủ đích (xem find_port_conflicts).
warn_port_conflicts() {
    local idx="$1"
    local entry="${PROTO_LIST[$idx]}"
    local proto port enabled
    IFS=':' read -r proto port enabled <<< "$entry"
    [ "$enabled" != "true" ] && return

    local conflicts cidx names="" cproto
    conflicts=$(find_port_conflicts "$port" "$idx")
    for cidx in $conflicts; do
        IFS=':' read -r cproto _ _ <<< "${PROTO_LIST[$cidx]}"
        names+="${names:+, }$cproto"
    done
    if [ -n "$names" ]; then
        echo -e "  ${Y}⚠ CẢNH BÁO: $proto đang BẬT trùng port $port với: $names${N}"
        echo -e "  ${Y}  psiphond sẽ LỖI khi generate/start nếu 2 protocol thường cùng${N}"
        echo -e "  ${Y}  lắng nghe 1 port. Panel KHÔNG tự tắt — bạn tự vào tắt bớt nếu cần.${N}"
    fi
}

# Quét TOÀN BỘ PROTO_LIST, cảnh báo mọi nhóm protocol đang BẬT trùng port
# (bỏ qua cặp share-port chủ đích FRONTED-MEEK-OSSH / FRONTED-MEEK-QUIC-OSSH).
# Trả về 1 nếu có ít nhất 1 nhóm trùng port, 0 nếu không (để nơi gọi tự quyết
# định có chặn hành động tiếp theo hay không — bản thân hàm này KHÔNG tự tắt
# protocol nào).
warn_all_port_conflicts() {
    local i entry proto port enabled seen_ports="|" found=1
    for i in "${!PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "${PROTO_LIST[$i]}"
        [ "$enabled" = "true" ] || continue
        # Đã cảnh báo cho port này rồi thì bỏ qua (tránh lặp thông báo)
        [[ "$seen_ports" == *"|$port|"* ]] && continue
        local conflicts
        conflicts=$(find_port_conflicts "$port" "$i")
        if [ -n "$conflicts" ]; then
            warn_port_conflicts "$i"
            seen_ports+="$port|"
            found=0
        fi
    done
    return "$found"
}

edit_protocol() {
    local idx=$1
    while true; do
        local entry="${PROTO_LIST[$idx]}"
        local proto port enabled
        IFS=':' read -r proto port enabled <<< "$entry"
        local is_shared=false
        is_shared_meek_port_protocol "$proto" && is_shared=true

        header
        echo -e "${W}${BOLD}  Chỉnh sửa Protocol: ${G}$proto${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        if [ "$enabled" = "true" ]; then
            echo -e "  Trạng thái     : ${G}✓ BẬT${N}"
        else
            echo -e "  Trạng thái     : ${R}✗ TẮT${N}"
        fi
        echo -e "  Port hiện tại  : ${G}$port${N}"
        if $is_shared; then
            echo ""
            echo -e "  ${Y}ℹ $proto KHÔNG có listener riêng trên server — psiphond không${N}"
            echo -e "  ${Y}  bind port này, chỉ dùng nó để gắn capability QUIC vào server${N}"
            echo -e "  ${Y}  entry (client dial QUIC/HTTP-3 tới CDN, CDN forward về server${N}"
            echo -e "  ${Y}  bạn bằng HTTPS qua $SHARED_MEEK_PORT_PARENT như bình thường).${N}"
            echo -e "  ${Y}   • Port có thể đặt tùy ý, KHÔNG bắt buộc trùng $SHARED_MEEK_PORT_PARENT.${N}"
            echo -e "  ${Y}   • Yêu cầu $SHARED_MEEK_PORT_PARENT phải đang BẬT thì mới BẬT được.${N}"
            echo -e "  ${Y}   • Không cần mở thêm port UDP ở firewall (không có gì lắng nghe ở đó).${N}"
        fi
        echo ""
        echo -e "  ${W}[1]${N} Bật/Tắt protocol"
        echo -e "  ${W}[2]${N} Đổi port ${C}(đổi trực tiếp, không cần tắt rồi bật lại)${N}"
        echo -e "  ${W}[0]${N} Quay lại"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r c

        case "$c" in
            1)
                if [ "$enabled" = "true" ]; then
                    confirm "  Tắt $proto?" && {
                        PROTO_LIST[$idx]="$proto:$port:false"
                        if [ "$proto" = "$SHARED_MEEK_PORT_PARENT" ]; then
                            sync_shared_meek_children
                        fi
                        save_config
                        echo -e "${G}  ✓ Đã tắt $proto${N}"
                    }
                else
                    if is_ws_experimental "$proto"; then
                        echo ""
                        echo -e "  ${Y}⚠ $proto là protocol thử nghiệm, chưa có trong binary${N}"
                        echo -e "  ${Y}  psiphond mặc định tải về từ caothemanh/psiphond.${N}"
                        echo -e "  ${Y}  Bật + Generate lúc này sẽ LỖI trừ khi bạn đã thay${N}"
                        echo -e "  ${Y}  binary bằng bản psiphond đã patch hỗ trợ WS-OSSH.${N}"
                        echo ""
                    fi
                    if $is_shared && ! is_parent_meek_enabled; then
                        echo ""
                        echo -e "  ${R}✗ Chưa thể bật $proto: $SHARED_MEEK_PORT_PARENT đang TẮT.${N}"
                        echo -e "  ${Y}  Vào bật $SHARED_MEEK_PORT_PARENT trước, rồi quay lại đây.${N}"
                        sleep 2
                    else
                        confirm "  Bật $proto?" && {
                            PROTO_LIST[$idx]="$proto:$port:true"
                            save_config
                            warn_port_conflicts "$idx"
                            echo -e "${G}  ✓ Đã bật $proto (port $port)${N}"
                        }
                    fi
                fi
                sleep 1 ;;
            2)
                echo -ne "  ${Y}Port mới [$port]: ${N}"
                read -r inp
                if [ -n "$inp" ] && [ "$inp" != "$port" ]; then
                    PROTO_LIST[$idx]="$proto:$inp:$enabled"
                    save_config
                    warn_port_conflicts "$idx"
                    echo -e "${G}  ✓ Đã đổi port $proto → $inp${N}"
                fi
                sleep 1 ;;
            0) return ;;
        esac
    done
}

# ================================================================
# GENERATE & VÁ ENTRY
# ================================================================
do_generate() {
    if ! is_installed; then
        echo -e "${R}  Psiphon chưa được cài đặt!${N}"; press_enter; return
    fi

    header
    echo -e "${W}${BOLD}  GENERATE SERVER ENTRY (mặc định psiphond)${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""

    sync_shared_meek_children
    warn_all_port_conflicts
    echo ""

    local proto_args=""
    local has_proto=false
    for entry in "${PROTO_LIST[@]}"; do
        local proto port enabled
        IFS=':' read -r proto port enabled <<< "$entry"
        [ "$enabled" = "true" ] && has_proto=true
    done
    if ! $has_proto; then
        echo -e "${R}  Chưa bật protocol nào! Vào menu [2] để bật ít nhất 1 protocol.${N}"
        press_enter; return
    fi

    echo -e "${Y}  Protocol sẽ dùng:${N}"
    local has_ws_experimental=false
    for entry in "${PROTO_LIST[@]}"; do
        local proto port enabled
        IFS=':' read -r proto port enabled <<< "$entry"
        if [ "$enabled" = "true" ]; then
            if is_ws_experimental "$proto"; then
                echo -e "  ${Y}✓ 🧪 $proto : $port${N}"
                has_ws_experimental=true
            elif is_shared_meek_port_protocol "$proto"; then
                echo -e "  ${G}✓${N} $proto : $port ${C}(không listener riêng, port chỉ để gắn capability)${N}"
            else
                echo -e "  ${G}✓${N} $proto : $port"
            fi
        fi
    done
    echo ""
    if $has_ws_experimental; then
        echo -e "  ${Y}⚠ Có protocol WebSocket-OSSH thử nghiệm đang bật. Nếu binary${N}"
        echo -e "  ${Y}  psiphond hiện tại chưa hỗ trợ, lệnh generate bên dưới sẽ${N}"
        echo -e "  ${Y}  báo lỗi (thường là \"invalid tunnel protocol\").${N}"
        echo ""
    fi
    echo -e "  IP     : ${G}$SERVER_IP${N}"
    echo -e "  Web    : ${G}$WEB_PORT${N}"
    echo -e "  Region : ${G}${REGION:-"(không đặt - server entry sẽ không có field region)"}${N}"
    echo ""

    confirm "  Xác nhận generate? (config cũ sẽ bị xóa)" || return

    echo ""
    if ! do_generate_core; then
        press_enter; return 1
    fi
    press_enter
}

# Phần LÕI của generate, KHÔNG hỏi gì (không confirm) - dùng cho web dashboard
# hoặc gọi lại từ nơi khác. In "OK: ..."/"ERR: ..." ra stdout để caller parse.
do_generate_core() {
    if ! is_installed; then
        echo "ERR: Psiphon chưa được cài đặt"
        return 1
    fi

    sync_shared_meek_children

    local proto_args=""
    local has_proto=false
    for entry in "${PROTO_LIST[@]}"; do
        local proto port enabled
        IFS=':' read -r proto port enabled <<< "$entry"
        if [ "$enabled" = "true" ]; then
            proto_args="$proto_args --protocol $proto:$port"
            has_proto=true
        fi
    done
    if ! $has_proto; then
        echo "ERR: Chưa bật protocol nào - vào Cấu hình Protocol trước"
        return 1
    fi

    echo "OK: [1/3] Dọn tiến trình psiphond cũ..."
    force_cleanup_psiphond 1

    echo "OK: [2/3] Xóa config cũ..."
    rm -f "$INSTALL_DIR"/psiphond.config \
          "$INSTALL_DIR"/psiphond-osl.config \
          "$INSTALL_DIR"/psiphond-tactics.config \
          "$INSTALL_DIR"/psiphond-traffic-rules.config \
          "$ENTRY_RAW" "$ENTRY_PATCHED"

    echo "OK: [3/3] Đang generate..."
    cd "$INSTALL_DIR" || { echo "ERR: Không cd được vào $INSTALL_DIR"; return 1; }
    local region_arg=""
    [ -n "$REGION" ] && region_arg="--region $REGION"
    eval "$BINARY --ipaddress $SERVER_IP --web $WEB_PORT $region_arg $proto_args generate" >/tmp/psiphon-generate.log 2>&1

    if [ ! -f "$ENTRY_RAW" ]; then
        echo "ERR: Generate thất bại"
        tail -20 /tmp/psiphon-generate.log
        return 1
    fi
    echo "OK: Generate xong"

    cp "$ENTRY_RAW" "$ENTRY_PATCHED"
    cp "$ENTRY_RAW" "/root/server-entry.dat"

    write_traffic_rules
    inject_server_config
    echo "OK: Đã ghi traffic-rules.json (limit ${DEFAULT_LIMIT_KBPS}KB/s) + tiêm vào psiphond.config"

    do_start
    if ! systemctl is-enabled --quiet psiphond 2>/dev/null; then
        systemctl enable psiphond >/dev/null 2>&1 && echo "OK: Đã bật autostart khi reboot"
    fi
    if is_running; then
        echo "OK: Server đang chạy"
    else
        echo "ERR: Generate xong nhưng server không tự chạy được - kiểm tra: systemctl status psiphond"
        return 1
    fi
    return 0
}

# ================================================================
# MENU 3: QUẢN LÝ SERVER
# ================================================================

# Dọn sạch MỌI tiến trình psiphond cũ (kể cả tiến trình "mồ côi" không do
# systemd quản lý, hoặc đứng process không chịu thoát khi bị stop bình
# thường). Lý do bug "thêm protocol/port mới -> không chạy": nếu còn 1
# tiến trình psiphond cũ đang giữ port (do lần trước stop không sạch),
# lần start mới sẽ bind fail ngay ở port trùng với tiến trình cũ đó, dù
# trong PROTO_LIST không hề trùng port với nhau (script chỉ so PROTO_LIST
# với chính nó, không so với port THẬT đang bị chiếm trên hệ thống).
force_cleanup_psiphond() {
    local quiet="$1"   # "1" = không in log chi tiết
    local pids

    # 1) Dừng qua systemd trước (đường tắt sạch sẽ, đúng chuẩn)
    systemctl stop psiphond 2>/dev/null

    # 2) Chờ tối đa 5s cho tiến trình tự thoát
    local waited=0
    while pgrep -x psiphond >/dev/null 2>&1 && [ "$waited" -lt 5 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    # 3) Vẫn còn -> SIGTERM trực tiếp mọi PID psiphond (kể cả process mồ côi
    #    không nằm trong cgroup của systemd, ví dụ do trước đó chạy tay
    #    "./psiphond run" để test rồi tắt terminal không đúng cách).
    pids=$(pgrep -x psiphond 2>/dev/null)
    if [ -n "$pids" ]; then
        [ "$quiet" != "1" ] && echo -e "${Y}  Còn tiến trình psiphond cũ (PID: $pids) chưa thoát, gửi SIGTERM...${N}"
        kill $pids 2>/dev/null
        sleep 2
    fi

    # 4) Vẫn cứng đầu không chết -> SIGKILL (-9), triệt để
    pids=$(pgrep -x psiphond 2>/dev/null)
    if [ -n "$pids" ]; then
        [ "$quiet" != "1" ] && echo -e "${R}  Vẫn không thoát, buộc SIGKILL (PID: $pids)...${N}"
        kill -9 $pids 2>/dev/null
        sleep 1
    fi

    pids=$(pgrep -x psiphond 2>/dev/null)
    if [ -n "$pids" ]; then
        [ "$quiet" != "1" ] && echo -e "${R}  CẢNH BÁO: vẫn còn PID $pids sau SIGKILL (bất thường, kiểm tra tay bằng 'ps aux | grep psiphond').${N}"
        return 1
    fi
    return 0
}

# Kiểm tra port THẬT đang bị chiếm trên hệ thống (không phải chỉ so trong
# PROTO_LIST với nhau) trước khi start, để báo lỗi rõ ràng thay vì để
# psiphond tự bind fail rồi thoát im lặng.
check_real_port_conflicts() {
    local entry proto port enabled owner
    local ok=0
    for entry in "${PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "$entry"
        [ "$enabled" != "true" ] && continue
        owner=$(ss -tlnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print}')
        if [ -n "$owner" ] && ! echo "$owner" | grep -q "psiphond"; then
            echo -e "${R}  ✗ Port $port ($proto) đang bị tiến trình KHÁC chiếm:${N}"
            echo "      $owner"
            ok=1
        fi
    done
    return $ok
}

do_start() {
    # Dọn sạch triệt để trước, tránh trường hợp tiến trình cũ còn giữ port
    force_cleanup_psiphond

    # check_real_port_conflicts trả về 0 = KHÔNG có xung đột, 1 = CÓ xung đột.
    # (Trước đây có dấu "!" thừa khiến logic bị đảo ngược: không xung đột lại
    # đi vào nhánh cảnh báo và KHÔNG start; đây là nguyên nhân chính khiến
    # service không tự chạy dù mọi thứ đều bình thường.)
    if check_real_port_conflicts; then
        systemctl start psiphond
        sleep 1
        is_running \
            && echo -e "${G}  ✓ Server đang chạy (PID=$(pgrep -x psiphond))${N}" \
            || { echo -e "${R}  Khởi động thất bại!${N}"; tail -20 "$LOG_FILE"; }
    else
        echo -e "${Y}  Cần tắt tiến trình đang chiếm port ở trên, hoặc đổi port trong menu [2] rồi generate lại.${N}"
        return 1
    fi
}

do_restart() {
    local old_pid new_pid
    old_pid=$(pgrep -x psiphond | head -1)

    # Ưu tiên systemctl restart: atomic, do chính systemd xử lý stop+start,
    # đáng tin cậy hơn nhiều so với tự stop rồi tự start (khoảng hở giữa 2
    # bước là lúc server bị treo ở trạng thái DỪNG nếu có gì bất thường).
    if systemctl restart psiphond 2>/dev/null; then
        sleep 1
        new_pid=$(pgrep -x psiphond | head -1)
        if is_running && [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ]; then
            echo -e "${G}  ✓ Đã restart! (PID mới: $new_pid)${N}"
            return 0
        fi
    fi

    # Fallback: systemctl restart không đủ (ví dụ còn tiến trình mồ côi
    # ngoài quản lý của systemd, do trước đó chạy tay). Dọn sạch rồi start.
    echo -e "${Y}  systemctl restart chưa đủ, thử dọn tiến trình cũ rồi start lại...${N}"
    if ! force_cleanup_psiphond; then
        echo -e "${R}  ✗ Không dừng được tiến trình cũ (PID: $old_pid). SERVER ĐANG DỪNG - kiểm tra tay: ps aux | grep psiphond${N}"
        return 1
    fi
    if ! check_real_port_conflicts; then
        echo -e "${R}  ✗ Port bị chiếm, không start lại được. SERVER ĐANG DỪNG.${N}"
        return 1
    fi
    systemctl start psiphond
    sleep 1
    new_pid=$(pgrep -x psiphond | head -1)
    if is_running && [ -n "$new_pid" ]; then
        echo -e "${G}  ✓ Đã restart! (PID mới: $new_pid)${N}"
    else
        echo -e "${R}  ✗ Restart thất bại. SERVER ĐANG DỪNG, cần xử lý tay.${N}"
        tail -20 "$LOG_FILE" 2>/dev/null
        return 1
    fi
}

# Liệt kê MỌI tiến trình psiphond đang chạy (kể cả process mồ côi không do
# systemd quản lý) + MỌI tiến trình lạ (không phải psiphond) đang chiếm các
# port đã cấu hình trong PROTO_LIST/WEB_PORT. Dùng cho menu dọn tay bên dưới.
list_stale_processes() {
    echo -e "${Y}  ── Tiến trình psiphond đang chạy ──${N}"
    local found_psiphond=0
    if pgrep -x psiphond >/dev/null 2>&1; then
        found_psiphond=1
        ps -o pid,ppid,etimes,cmd -C psiphond --no-headers 2>/dev/null \
            | while read -r line; do echo -e "  ${G}$line${N}"; done
    else
        echo -e "  ${C}(không có)${N}"
    fi

    echo ""
    echo -e "${Y}  ── Tiến trình KHÁC đang chiếm port Psiphon (không phải psiphond) ──${N}"
    local entry proto port enabled owner found_other=0
    local all_ports="$WEB_PORT"
    for entry in "${PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "$entry"
        [ "$enabled" = "true" ] && all_ports="$all_ports $port"
    done
    for port in $all_ports; do
        owner=$(ss -tlnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print}')
        if [ -n "$owner" ] && ! echo "$owner" | grep -q "psiphond"; then
            found_other=1
            echo -e "  ${R}Port $port:${N} $owner"
        fi
    done
    [ "$found_other" -eq 0 ] && echo -e "  ${C}(không có)${N}"

    return $((found_psiphond == 0 && found_other == 0 ? 1 : 0))
}

# Rút PID từ output "ss -tlnp" cho 1 port cụ thể (dạng users:(("proc",pid=1234,fd=5)))
pid_on_port() {
    local port="$1"
    ss -tlnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print}' \
        | grep -oP 'pid=\K[0-9]+' | sort -u
}

menu_cleanup() {
    while true; do
        header
        echo -e "${W}${BOLD}  [3.9] DỌN TIẾN TRÌNH CŨ (THỦ CÔNG)${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        list_stale_processes
        echo ""
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo -e "  ${W}[1]${N} Dọn sạch TẤT CẢ tiến trình psiphond (SIGTERM → SIGKILL)"
        echo -e "  ${W}[2]${N} Kill theo PID cụ thể"
        echo -e "  ${W}[3]${N} Kill tiến trình đang chiếm 1 port cụ thể"
        echo -e "  ${W}[4]${N} Làm mới danh sách"
        echo -e "  ${W}[0]${N} Quay lại"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r c

        case "$c" in
            1)
                echo ""
                force_cleanup_psiphond
                echo -e "${G}  ✓ Đã dọn xong.${N}"
                press_enter ;;
            2)
                echo -ne "  ${Y}Nhập PID (cách nhau bởi dấu cách): ${N}"
                read -r pidlist
                if [ -z "$pidlist" ]; then
                    echo -e "${R}  Chưa nhập PID.${N}"; press_enter; continue
                fi
                confirm "  Xác nhận kill PID: $pidlist ?" || continue
                kill $pidlist 2>/dev/null
                sleep 1
                for p in $pidlist; do
                    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
                done
                echo -e "${G}  ✓ Đã gửi tín hiệu kill.${N}"
                press_enter ;;
            3)
                echo -ne "  ${Y}Nhập port cần dọn: ${N}"
                read -r p
                if [ -z "$p" ]; then
                    echo -e "${R}  Chưa nhập port.${N}"; press_enter; continue
                fi
                local pids
                pids=$(pid_on_port "$p")
                if [ -z "$pids" ]; then
                    echo -e "${C}  Không có tiến trình nào đang chiếm port $p.${N}"
                    press_enter; continue
                fi
                echo -e "  Tiến trình đang chiếm port $p: ${Y}$pids${N}"
                confirm "  Xác nhận kill?" || continue
                kill $pids 2>/dev/null
                sleep 1
                for pd in $pids; do
                    kill -0 "$pd" 2>/dev/null && kill -9 "$pd" 2>/dev/null
                done
                echo -e "${G}  ✓ Đã dọn port $p.${N}"
                press_enter ;;
            4) ;;
            0) return ;;
        esac
    done
}

# ================================================================
# CHẨN ĐOÁN NHANH — gộp toàn bộ chuỗi lệnh debug thủ công thành 1 lệnh:
# service status -> process -> port thật -> config đã sinh -> log ->
# nếu service không chạy thì tự chạy tay 3s để bắt lỗi thật -> kết luận.
# ================================================================
run_diagnostics() {
    header
    echo -e "${W}${BOLD}  CHẨN ĐOÁN NHANH${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""

    local problems=()

    # 1) Trạng thái service
    echo -e "${Y}[1/7] Trạng thái systemd${N}"
    systemctl status psiphond --no-pager -l 2>&1 | head -6 | sed 's/^/  /'
    local svc_active=0
    systemctl is-active --quiet psiphond && svc_active=1
    if [ "$svc_active" -eq 1 ]; then
        echo -e "  ${G}✓ service đang active${N}"
    else
        echo -e "  ${R}✗ service KHÔNG active${N}"
        problems+=("service_dead")
    fi
    echo ""

    # 2) Tiến trình thật
    echo -e "${Y}[2/7] Tiến trình psiphond${N}"
    local pids
    pids=$(pgrep -x psiphond 2>/dev/null)
    if [ -n "$pids" ]; then
        echo -e "  ${G}✓ Đang chạy, PID: $pids${N}"
    else
        echo -e "  ${R}✗ Không có tiến trình psiphond nào${N}"
        problems+=("no_process")
    fi
    echo ""

    # 3) Port thật đang listen so với PROTO_LIST đang bật
    echo -e "${Y}[3/7] Port thực tế đang lắng nghe${N}"
    local entry proto port enabled missing_ports=()
    for entry in "${PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "$entry"
        [ "$enabled" != "true" ] && continue
        is_shared_meek_port_protocol "$proto" && continue   # không có listener riêng, bỏ qua
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            echo -e "  ${G}✓${N} $proto : $port đang listen"
        else
            echo -e "  ${R}✗${N} $proto : $port KHÔNG thấy listen"
            missing_ports+=("$proto:$port")
        fi
    done
    [ "${#missing_ports[@]}" -gt 0 ] && problems+=("missing_ports")
    echo ""

    # 4) Port có bị process lạ chiếm không
    echo -e "${Y}[4/7] Xung đột port với tiến trình khác${N}"
    if check_real_port_conflicts; then
        echo -e "  ${G}✓ Không có xung đột${N}"
    else
        problems+=("port_conflict")
    fi
    echo ""

    # 5) Config đã generate có chứa đủ protocol đang bật không
    echo -e "${Y}[5/7] Protocol trong psiphond.config${N}"
    if [ -f "$INSTALL_DIR/psiphond.config" ]; then
        for entry in "${PROTO_LIST[@]}"; do
            IFS=':' read -r proto port enabled <<< "$entry"
            [ "$enabled" != "true" ] && continue
            if grep -q "$proto" "$INSTALL_DIR/psiphond.config" 2>/dev/null; then
                echo -e "  ${G}✓${N} $proto có trong config"
            else
                echo -e "  ${R}✗${N} $proto KHÔNG có trong config (chưa generate lại sau khi bật?)"
                problems+=("config_missing_proto")
            fi
        done
    else
        echo -e "  ${R}✗ Chưa có psiphond.config — chưa generate lần nào${N}"
        problems+=("no_config")
    fi
    echo ""

    # 6) CF fronting đã cấu hình chưa (chỉ cảnh báo, không phải lỗi cứng)
    echo -e "${Y}[6/7] Cấu hình Cloudflare fronting${N}"
    if [ -n "$CF_DOMAIN" ] && [ -n "$CF_IP" ]; then
        echo -e "  ${G}✓${N} CF_DOMAIN=$CF_DOMAIN  CF_IP=$CF_IP"
    else
        echo -e "  ${Y}⚠ Chưa cấu hình CF_DOMAIN/CF_IP (chỉ cần nếu dùng domain fronting qua CDN)${N}"
    fi
    echo ""

    # 7) Nếu service không active -> tự chạy tay 3s để bắt lỗi thật ngay
    echo -e "${Y}[7/7] Log gần nhất${N}"
    if [ "$svc_active" -eq 0 ]; then
        echo -e "  Service không chạy — thử start tay 3 giây để bắt lỗi thật..."
        local out
        out=$(cd "$INSTALL_DIR" && timeout 3 ./psiphond run 2>&1)
        if echo "$out" | grep -qi '"level":"error"\|panic\|fatal'; then
            echo -e "  ${R}Tìm thấy lỗi khi chạy tay:${N}"
            echo "$out" | grep -i '"level":"error"\|panic\|fatal' | tail -10 | sed 's/^/    /'
            problems+=("runtime_error")
        elif echo "$out" | grep -q '"msg":"running"'; then
            echo -e "  ${G}✓ Chạy tay THÀNH CÔNG (bind port OK). Vấn đề là service bị dừng chủ động,${N}"
            echo -e "  ${G}  không phải lỗi cấu hình. Dùng menu [1] để start qua systemd.${N}"
            problems+=("service_stopped_not_crashed")
        else
            echo -e "  ${Y}Không rõ, xem output đầy đủ:${N}"
            echo "$out" | tail -15 | sed 's/^/    /'
        fi
    elif [ -f "$LOG_FILE" ]; then
        tail -15 "$LOG_FILE" | sed 's/^/  /'
    else
        echo -e "  ${C}(chưa có file log, service đang chạy nên tạm coi là bình thường)${N}"
    fi
    echo ""

    # KẾT LUẬN
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo -e "${W}${BOLD}  KẾT LUẬN${N}"
    if [ "${#problems[@]}" -eq 0 ]; then
        echo -e "  ${G}✓ Không phát hiện vấn đề gì. Nếu client vẫn không kết nối được,${N}"
        echo -e "  ${G}  khả năng cao là do domain fronting bị CDN chặn — test bằng:${N}"
        echo -e "  ${C}  curl -v -H \"Host: <CF_DOMAIN>\" http://<CF_IP>:<port>/${N}"
    else
        for p in "${problems[@]}"; do
            case "$p" in
                service_dead) echo -e "  ${R}• Service không active${N} → chạy: ${C}systemctl start psiphond${N}" ;;
                no_process) echo -e "  ${R}• Không có tiến trình${N} → xem mục 7 ở trên để biết lý do" ;;
                missing_ports) echo -e "  ${R}• Có protocol bật nhưng không listen${N} → cần generate lại (Menu [2] → G) rồi restart" ;;
                port_conflict) echo -e "  ${R}• Có process khác chiếm port${N} → dùng Menu [3] → [9] để dọn" ;;
                config_missing_proto) echo -e "  ${R}• Config chưa có protocol vừa bật${N} → vào Menu [2] → Generate lại" ;;
                no_config) echo -e "  ${R}• Chưa generate config lần nào${N} → vào Menu [2] → Generate" ;;
                runtime_error) echo -e "  ${R}• Lỗi runtime khi chạy tay${N} → xem chi tiết lỗi ở mục [7/7] phía trên" ;;
                service_stopped_not_crashed) echo -e "  ${Y}• Binary/config ỔN, chỉ là service đang bị dừng${N} → Menu [3] → [1] để start lại, rồi [8] để bật autostart" ;;
            esac
        done
    fi
    press_enter
}

menu_server() {
    while true; do
        header
        echo -e "${W}${BOLD}  [3] QUẢN LÝ SERVER${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        echo -e "  ${W}[1]${N} Khởi động server"
        echo -e "  ${W}[2]${N} Dừng server"
        echo -e "  ${W}[3]${N} Restart server"
        echo -e "  ${W}[4]${N} Xem trạng thái & port đang mở"
        echo -e "  ${W}[5]${N} Xem log realtime"
        echo -e "  ${W}[6]${N} Xem 50 dòng log cuối"
        echo -e "  ${W}[7]${N} Xóa log"
        echo -e "  ${W}[8]${N} Bật/Tắt tự chạy khi reboot"
        echo -e "  ${W}[9]${N} Dọn tiến trình cũ (thủ công)"
        echo -e "  ${W}[D]${N} ${BOLD}Chẩn đoán nhanh (tự động)${N}"
        echo -e "  ${W}[0]${N} Quay lại"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r c

        case "$c" in
            1) do_start; press_enter ;;
            2)
                systemctl stop psiphond
                echo -e "${G}  ✓ Đã dừng.${N}"; press_enter ;;
            3)
                do_restart
                press_enter ;;
            4)
                echo ""
                echo -e "  Trạng thái: $(run_badge)"
                echo -e "  PID: $(pgrep -x psiphond || echo 'N/A')"
                echo ""
                echo -e "${Y}  Port đang lắng nghe:${N}"
                ss -tlnp | grep psiphond | awk '{print "  " $0}' || echo "  (không có)"
                echo ""
                echo -e "${Y}  Protocol đã cấu hình:${N}"
                for entry in "${PROTO_LIST[@]}"; do
                    IFS=':' read -r proto port enabled <<< "$entry"
                    if [ "$enabled" = "true" ]; then
                        echo -e "  ${G}✓${N} $proto : $port"
                    else
                        echo -e "  ${R}✗${N} $proto : $port"
                    fi
                done
                press_enter ;;
            5)
                echo -e "${Y}  Ctrl+C để thoát${N}"; sleep 1
                tail -f "$LOG_FILE" ;;
            6) tail -50 "$LOG_FILE" | less ;;
            7)
                confirm "  Xóa toàn bộ log?" && > "$LOG_FILE" && echo -e "${G}  ✓ Đã xóa${N}"
                press_enter ;;
            8)
                if systemctl is-enabled --quiet psiphond 2>/dev/null; then
                    confirm "  Tắt tự chạy khi reboot?" && systemctl disable psiphond \
                        && echo -e "${G}  ✓ Đã tắt autostart${N}"
                else
                    confirm "  Bật tự chạy khi reboot?" && systemctl enable psiphond \
                        && echo -e "${G}  ✓ Đã bật autostart${N}"
                fi
                press_enter ;;
            9) menu_cleanup ;;
            [Dd]) run_diagnostics ;;
            0) return ;;
        esac
    done
}

# ================================================================
# MENU 4: XEM SERVER ENTRY
# ================================================================
menu_entry() {
    header
    echo -e "${W}${BOLD}  [4] SERVER ENTRY${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""

    if [ ! -f "$ENTRY_PATCHED" ]; then
        echo -e "${R}  Chưa có server entry! Vào menu [2] → Generate trước.${N}"
        press_enter; return
    fi

    echo -e "${Y}  Thông tin server entry:${N}"
    python3 "$PATCH_SCRIPT" show "$ENTRY_PATCHED" 2>/dev/null | while read -r line; do
        echo -e "  ${G}$line${N}"
    done

    echo ""
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo -e "  ${W}[1]${N} Hiển thị hex (copy vào app)"
    echo -e "  ${W}[2]${N} Lưu ra file /root/server-entry-export.txt"
    echo -e "  ${W}[0]${N} Quay lại"
    echo ""
    echo -ne "  ${Y}Chọn: ${N}"
    read -r c

    case "$c" in
        1)
            echo ""
            echo -e "${Y}  ── Nội dung hex ──${N}"
            echo ""
            cat "$ENTRY_PATCHED"
            echo ""
            press_enter ;;
        2)
            cp "$ENTRY_PATCHED" /root/server-entry-export.txt
            echo -e "${G}  ✓ Đã lưu ra /root/server-entry-export.txt${N}"
            press_enter ;;
        0) return ;;
    esac
}

# ================================================================
# MENU 5: FIREWALL
# ================================================================
menu_firewall() {
    header
    echo -e "${W}${BOLD}  [5] CẤU HÌNH FIREWALL (UFW)${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""

    if ! command -v ufw &>/dev/null; then
        confirm "  UFW chưa cài. Cài đặt?" && apt-get install -y ufw && echo -e "${G}  ✓ Đã cài UFW${N}"
    fi

    echo -e "  Trạng thái UFW: $(ufw status | head -1)"
    echo ""
    echo -e "${W}  Port sẽ được mở:${N}"
    echo -e "  ${G}$WEB_PORT${N} (web)"
    for entry in "${PROTO_LIST[@]}"; do
        IFS=':' read -r proto port enabled <<< "$entry"
        if [ "$enabled" = "true" ]; then
            if is_shared_meek_port_protocol "$proto"; then
                echo -e "  ${C}(bỏ qua)${N} $proto ${C}— port $port chỉ để gắn capability, không có listener nên không cần mở${N}"
            else
                echo -e "  ${G}$port${N} ($proto)"
            fi
        fi
    done
    echo ""
    echo -e "  ${W}[1]${N} Mở tất cả port Psiphon"
    echo -e "  ${W}[2]${N} Bật UFW (với SSH port 22)"
    echo -e "  ${W}[3]${N} Tắt UFW"
    echo -e "  ${W}[0]${N} Quay lại"
    echo ""
    echo -ne "  ${Y}Chọn: ${N}"
    read -r c

    case "$c" in
        1)
            ufw allow "$WEB_PORT"/tcp >/dev/null
            for entry in "${PROTO_LIST[@]}"; do
                IFS=':' read -r proto port enabled <<< "$entry"
                if [ "$enabled" = "true" ]; then
                    if is_shared_meek_port_protocol "$proto"; then
                        echo -e "  ${C}○ Bỏ qua $proto (port $port không có listener, không cần mở firewall)${N}"
                        continue
                    fi
                    [[ "$proto" == *"QUIC"* ]] && ufw allow "$port"/udp >/dev/null \
                                               || ufw allow "$port"/tcp >/dev/null
                    echo -e "  ${G}✓ Đã mở port $port ($proto)${N}"
                fi
            done
            press_enter ;;
        2)
            ufw allow 22/tcp >/dev/null
            ufw --force enable
            echo -e "${G}  ✓ UFW đã bật${N}"; press_enter ;;
        3)
            ufw --force disable
            echo -e "${G}  ✓ UFW đã tắt${N}"; press_enter ;;
        0) return ;;
    esac
}

# ================================================================
# MENU 9: GỠ CÀI ĐẶT
# ================================================================
menu_uninstall() {
    header
    echo -e "${R}${BOLD}  [9] GỠ CÀI ĐẶT${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""
    echo -e "${R}  CẢNH BÁO: Xóa toàn bộ Psiphon Server & cấu hình!${N}"
    echo ""
    confirm "  Chắc chắn gỡ cài đặt?" || return
    confirm "  Xác nhận lần 2?" || return

    systemctl stop psiphond 2>/dev/null
    systemctl disable psiphond 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR" "$PANEL_DIR"
    rm -f "$LOG_FILE" /usr/local/bin/psiphon-panel

    echo ""
    echo -e "${G}  ✓ Gỡ cài đặt hoàn tất!${N}"
    press_enter
    exit 0
}

# ================================================================
# WEB DASHBOARD
# ================================================================
is_webpanel_installed() { [ -f "$WEBPANEL_DIR/app.py" ] && [ -f "$WEBPANEL_ENV" ]; }
is_webpanel_running() { systemctl is-active --quiet psiphon-dashboard 2>/dev/null; }

webpanel_badge() {
    if is_webpanel_running; then
        echo -e "${G}(đang chạy)${N}"
    elif is_webpanel_installed; then
        echo -e "${Y}(đã cài, chưa chạy)${N}"
    else
        echo -e "${R}(chưa cài)${N}"
    fi
}

# In URL truy cập thật (public hoặc qua SSH tunnel) tùy chế độ bind đã lưu
# trong systemd service, để dễ copy ngay sau khi cài/xem trạng thái.
print_webpanel_access_info() {
    local bind
    bind=$(grep -oP '(?<=-b )\S+' "$WEBPANEL_SERVICE_FILE" 2>/dev/null)
    echo ""
    if [[ "$bind" == 0.0.0.0:* ]]; then
        echo -e "  ${C}Link truy cập (copy thẳng vào trình duyệt):${N}"
        echo -e "  ${G}${BOLD}http://$SERVER_IP:$WEBPANEL_PORT${N}"
        echo -e "  ${Y}⚠ Đang mở public qua HTTP (không mã hoá). Chỉ nên dùng tạm/test,${N}"
        echo -e "  ${Y}  hoặc đặt sau Nginx + HTTPS nếu dùng lâu dài (xem webpanel/README.md).${N}"
    else
        echo -e "  ${C}Dashboard đang chạy nội bộ (an toàn, chưa public):${N} 127.0.0.1:$WEBPANEL_PORT"
        echo -e "  ${C}Truy cập bằng SSH tunnel từ máy cá nhân:${N}"
        echo -e "  ${G}${BOLD}ssh -L $WEBPANEL_PORT:127.0.0.1:$WEBPANEL_PORT root@$SERVER_IP${N}"
        echo -e "  rồi mở ${G}http://127.0.0.1:$WEBPANEL_PORT${N} trên trình duyệt máy mình."
    fi
}

install_web_dashboard() {
    header
    echo -e "${W}${BOLD}  CÀI ĐẶT WEB DASHBOARD${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""

    echo -e "${Y}  Cài python3-venv...${N}"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq python3 python3-venv python3-pip >/dev/null 2>&1

    echo -e "${Y}  [1/6] Tải mã dashboard...${N}"
    mkdir -p "$WEBPANEL_DIR/templates"
    local files=(app.py requirements.txt psiphon-dashboard.service templates/index.html templates/login.html)
    for f in "${files[@]}"; do
        if ! curl -fsSL "$WEBPANEL_BASE_URL/$f" -o "$WEBPANEL_DIR/$f"; then
            echo -e "${R}  ✗ Tải thất bại: $f (kiểm tra kết nối mạng / URL $WEBPANEL_BASE_URL)${N}"
            press_enter; return 1
        fi
    done
    echo -e "${G}  ✓ OK${N}"

    echo -e "${Y}  [2/6] Cập nhật psiphon-panel.sh lên bản mới nhất...${N}"
    if curl -fsSL "$PANEL_URL" -o /usr/local/bin/psiphon-panel.new; then
        mv /usr/local/bin/psiphon-panel.new /usr/local/bin/psiphon-panel
        chmod +x /usr/local/bin/psiphon-panel
    else
        echo -e "${Y}  ⚠ Không tải được bản mới, giữ nguyên bản hiện có.${N}"
    fi
    echo -e "${G}  ✓ OK (/usr/local/bin/psiphon-panel)${N}"

    echo -e "${Y}  [3/6] Cài Python venv + dependencies (có thể mất chút thời gian)...${N}"
    rm -rf "$WEBPANEL_DIR/venv"
    python3 -m venv "$WEBPANEL_DIR/venv" 2>/tmp/psiphon-venv-err.log
    if [ ! -x "$WEBPANEL_DIR/venv/bin/pip" ]; then
        # Ubuntu/Debian: gói "python3-venv" đôi khi không kéo theo đúng bản
        # "python3.X-venv" cần cho ensurepip -> venv tạo ra nhưng thiếu pip.
        # Dò đúng version python3 đang chạy rồi cài đúng gói đó.
        local pyver
        pyver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        echo -e "${Y}  venv thiếu ensurepip, thử cài python${pyver}-venv...${N}"
        apt-get install -y -qq "python${pyver}-venv" >/dev/null 2>&1
        rm -rf "$WEBPANEL_DIR/venv"
        python3 -m venv "$WEBPANEL_DIR/venv" 2>/tmp/psiphon-venv-err.log
    fi
    if [ ! -x "$WEBPANEL_DIR/venv/bin/pip" ]; then
        echo -e "${R}  ✗ Không tạo được venv (thiếu pip trong venv). Lỗi:${N}"
        sed 's/^/    /' /tmp/psiphon-venv-err.log
        echo -e "${Y}  Thử cài tay: apt install python${pyver:-3}-venv    rồi vào lại menu này.${N}"
        press_enter; return 1
    fi
    "$WEBPANEL_DIR/venv/bin/pip" install --quiet --upgrade pip
    if ! "$WEBPANEL_DIR/venv/bin/pip" install --quiet -r "$WEBPANEL_DIR/requirements.txt"; then
        echo -e "${R}  ✗ Cài dependencies thất bại.${N}"
        press_enter; return 1
    fi
    echo -e "${G}  ✓ OK${N}"

    echo -e "${Y}  [4/6] Đặt mật khẩu dashboard...${N}"
    local pw1 pw2
    while true; do
        read -rs -p "  Mật khẩu mới cho dashboard (>= 8 ký tự): " pw1; echo
        read -rs -p "  Nhập lại: " pw2; echo
        [ "$pw1" = "$pw2" ] || { echo -e "${R}  Không khớp, thử lại.${N}"; continue; }
        [ ${#pw1} -ge 8 ] || { echo -e "${R}  Cần >= 8 ký tự.${N}"; continue; }
        break
    done
    local pw_hash secret_key
    pw_hash=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$pw1")
    secret_key=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    unset pw1 pw2
    echo -e "${G}  ✓ OK${N}"

    echo -e "${Y}  [5/6] Chọn chế độ truy cập...${N}"
    echo -e "  ${C}Mặc định dashboard CHỈ chạy nội bộ (127.0.0.1) - an toàn, cần SSH tunnel để vào.${N}"
    confirm "  Mở public qua http://$SERVER_IP:$WEBPANEL_PORT luôn (KHÔNG mã hoá, chỉ nên dùng tạm)?" \
        && local bind="0.0.0.0:$WEBPANEL_PORT" || local bind="127.0.0.1:$WEBPANEL_PORT"

    cat > "$WEBPANEL_ENV" << EOF
DASHBOARD_PASSWORD_HASH=$pw_hash
DASHBOARD_SECRET_KEY=$secret_key
PANEL_SCRIPT_PATH=/usr/local/bin/psiphon-panel
EOF
    chmod 600 "$WEBPANEL_ENV"

    sed "s#-b 127\.0\.0\.1:8088#-b $bind#" "$WEBPANEL_DIR/psiphon-dashboard.service" > "$WEBPANEL_SERVICE_FILE"

    if [ "$bind" = "0.0.0.0:$WEBPANEL_PORT" ] && command -v ufw >/dev/null 2>&1; then
        ufw allow "$WEBPANEL_PORT"/tcp >/dev/null 2>&1
    fi

    echo -e "${Y}  [6/6] Khởi động service...${N}"
    systemctl daemon-reload
    systemctl enable --now psiphon-dashboard >/dev/null 2>&1
    sleep 1
    if is_webpanel_running; then
        echo -e "${G}  ✓ Dashboard đang chạy!${N}"
    else
        echo -e "${R}  ✗ Service không chạy được. Xem: journalctl -u psiphon-dashboard -n 50${N}"
        press_enter; return 1
    fi

    print_webpanel_access_info
    press_enter
}

change_webpanel_password() {
    header
    echo -e "${W}${BOLD}  ĐỔI MẬT KHẨU DASHBOARD${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""
    local pw1 pw2
    while true; do
        read -rs -p "  Mật khẩu mới (>= 8 ký tự): " pw1; echo
        read -rs -p "  Nhập lại: " pw2; echo
        [ "$pw1" = "$pw2" ] || { echo -e "${R}  Không khớp, thử lại.${N}"; continue; }
        [ ${#pw1} -ge 8 ] || { echo -e "${R}  Cần >= 8 ký tự.${N}"; continue; }
        break
    done
    local pw_hash
    pw_hash=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$pw1")
    unset pw1 pw2
    if grep -q "^DASHBOARD_PASSWORD_HASH=" "$WEBPANEL_ENV" 2>/dev/null; then
        sed -i "s#^DASHBOARD_PASSWORD_HASH=.*#DASHBOARD_PASSWORD_HASH=$pw_hash#" "$WEBPANEL_ENV"
    else
        echo "DASHBOARD_PASSWORD_HASH=$pw_hash" >> "$WEBPANEL_ENV"
    fi
    systemctl restart psiphon-dashboard
    echo -e "${G}  ✓ Đã đổi mật khẩu và restart dashboard.${N}"
    press_enter
}

uninstall_web_dashboard() {
    header
    confirm "  Gỡ hoàn toàn Web Dashboard (giữ nguyên psiphond)?" || return
    systemctl disable --now psiphon-dashboard >/dev/null 2>&1
    rm -f "$WEBPANEL_SERVICE_FILE" "$WEBPANEL_ENV"
    rm -rf "$WEBPANEL_DIR"
    systemctl daemon-reload
    echo -e "${G}  ✓ Đã gỡ Web Dashboard.${N}"
    press_enter
}

menu_web_dashboard() {
    while true; do
        header
        echo -e "${W}${BOLD}  WEB DASHBOARD${N}  $(webpanel_badge)"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        if is_webpanel_installed; then
            print_webpanel_access_info
            echo ""
            echo -e "  ${W}[1]${N} Cài lại / cập nhật dashboard"
            echo -e "  ${W}[2]${N} Đổi mật khẩu"
            echo -e "  ${W}[3]${N} Restart dashboard"
            echo -e "  ${W}[4]${N} Xem log dashboard"
            echo -e "  ${W}[9]${N} Gỡ dashboard"
        else
            echo -e "  ${Y}Chưa cài. Dashboard cho phép điều khiển server qua trình duyệt${N}"
            echo -e "  ${Y}(start/stop/restart, xem log, import verification key...).${N}"
            echo ""
            echo -e "  ${W}[1]${N} Cài đặt Web Dashboard"
        fi
        echo -e "  ${W}[0]${N} Quay lại"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r c
        case "$c" in
            1) install_web_dashboard ;;
            2) is_webpanel_installed && change_webpanel_password || press_enter ;;
            3) is_webpanel_installed && { systemctl restart psiphon-dashboard; echo -e "${G}  ✓ Đã restart${N}"; press_enter; } || press_enter ;;
            4) is_webpanel_installed && { journalctl -u psiphon-dashboard -n 50 --no-pager; press_enter; } || press_enter ;;
            9) is_webpanel_installed && uninstall_web_dashboard || press_enter ;;
            0) return ;;
        esac
    done
}

update_panel_self() {
    header
    echo -e "${W}${BOLD}  CẬP NHẬT PANEL${N}"
    echo -e "${C}  ─────────────────────────────────────────────────${N}"
    echo ""
    echo -e "${Y}  Đang tải bản mới nhất từ:${N} $PANEL_URL"
    if ! curl -fsSL "$PANEL_URL" -o /usr/local/bin/psiphon-panel.new; then
        echo -e "${R}  ✗ Tải thất bại (kiểm tra kết nối mạng).${N}"
        press_enter; return 1
    fi
    if ! bash -n /usr/local/bin/psiphon-panel.new 2>/tmp/psiphon-panel-update-err.log; then
        echo -e "${R}  ✗ File tải về lỗi cú pháp, HỦY cập nhật (giữ nguyên bản cũ):${N}"
        sed 's/^/    /' /tmp/psiphon-panel-update-err.log
        rm -f /usr/local/bin/psiphon-panel.new
        press_enter; return 1
    fi
    mv /usr/local/bin/psiphon-panel.new /usr/local/bin/psiphon-panel
    chmod +x /usr/local/bin/psiphon-panel
    echo -e "${G}  ✓ Đã cập nhật /usr/local/bin/psiphon-panel${N}"
    echo -e "${C}  Khởi động lại panel với bản mới...${N}"
    sleep 1
    exec /usr/local/bin/psiphon-panel
}

# ================================================================
# MENU CHÍNH
# ================================================================
main_menu() {
    while true; do
        load_config
        header
        echo -e "${W}${BOLD}  MENU CHÍNH${N}"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo ""
        echo -e "  ${W}[1]${N} Cài đặt Psiphon Server"
        echo -e "  ${W}[2]${N} Cấu hình Protocol, Port & Cloudflare Fronting"
        echo -e "  ${W}[3]${N} Quản lý Server  (start / stop / restart / log)"
        echo -e "  ${W}[4]${N} Xem & Export Server Entry"
        echo -e "  ${W}[5]${N} Cấu hình Firewall (UFW)"
        echo -e "  ${W}[6]${N} Giới hạn băng thông & psiphonAuth"
        echo -e "  ${W}[7]${N} Web Dashboard $(webpanel_badge)"
        echo -e "  ${W}[8]${N} Cập nhật Panel (tải bản mới nhất)"
        echo -e "${C}  ─────────────────────────────────────────────────${N}"
        echo -e "  ${W}[9]${N} Gỡ cài đặt"
        echo -e "  ${W}[0]${N} Thoát"
        echo ""
        echo -ne "  ${Y}Chọn: ${N}"
        read -r choice

        case "$choice" in
            1) menu_install ;;
            2) menu_config ;;
            3) menu_server ;;
            4) menu_entry ;;
            5) menu_firewall ;;
            6) menu_limit_auth ;;
            7) menu_web_dashboard ;;
            8) update_panel_self ;;
            9) menu_uninstall ;;
            0) echo ""; exit 0 ;;
        esac
    done
}

if [ "${PANEL_LIB_MODE:-0}" != "1" ]; then
    check_root
    main_menu
fi
