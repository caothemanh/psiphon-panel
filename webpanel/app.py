#!/usr/bin/env python3
"""
Psiphon Panel - Web Dashboard
==============================
Giao diện web cho psiphon-panel.sh. KHÔNG viết lại logic quản trị server -
mọi hành động (start/stop/restart, import verification key...) đều gọi lại
đúng các hàm bash đã có trong psiphon-panel.sh (source dưới dạng thư viện,
PANEL_LIB_MODE=1) để không lệch bug với phiên bản CLI.

CẢNH BÁO BẢO MẬT:
- App này chạy với quyền root và có toàn quyền điều khiển psiphond
  (start/stop, sửa config, xem/import verification key...).
- Bắt buộc đặt DASHBOARD_PASSWORD (xem README) và KHÔNG expose thẳng ra
  Internet mà không có HTTPS + hạn chế IP truy cập (xem README).
"""

import os
import re
import json
import hmac
import hashlib
import secrets
import subprocess
import tempfile
from functools import wraps

from flask import Flask, request, session, jsonify, render_template, redirect, url_for

# ----------------------------------------------------------------------
# Cấu hình
# ----------------------------------------------------------------------
PANEL_SCRIPT_PATH = os.environ.get("PANEL_SCRIPT_PATH", "/root/psiphon-panel.sh")
DASHBOARD_PASSWORD_HASH = os.environ.get("DASHBOARD_PASSWORD_HASH", "")
SECRET_KEY = os.environ.get("DASHBOARD_SECRET_KEY") or secrets.token_hex(32)
CMD_TIMEOUT = 60  # giây, cho mỗi lệnh gọi vào psiphon-panel.sh

app = Flask(__name__)
app.secret_key = SECRET_KEY
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Strict",
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


# ----------------------------------------------------------------------
# Gọi lại hàm bash trong psiphon-panel.sh (PANEL_LIB_MODE=1 -> chỉ nạp hàm,
# không tự chạy menu tương tác). Args truyền qua argv, KHÔNG nội suy vào
# chuỗi lệnh, để tránh injection.
# ----------------------------------------------------------------------
def run_panel_func(func_name: str, *func_args: str, timeout: int = CMD_TIMEOUT):
    if not os.path.isfile(PANEL_SCRIPT_PATH):
        return {"ok": False, "returncode": -1, "output": f"Không tìm thấy script: {PANEL_SCRIPT_PATH}"}

    wrapper = (
        'export PANEL_LIB_MODE=1\n'
        f'source "{PANEL_SCRIPT_PATH}"\n'
        'load_config\n'
        f'{func_name} "$@"\n'
    )
    try:
        proc = subprocess.run(
            ["bash", "-c", wrapper, "bash", *func_args],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "returncode": -1, "output": f"Lệnh '{func_name}' quá thời gian chờ ({timeout}s)."}

    output = strip_ansi((proc.stdout or "") + (proc.stderr or "")).strip()
    return {"ok": proc.returncode == 0, "returncode": proc.returncode, "output": output}


def get_status():
    r = run_panel_func("web_status_json", timeout=20)
    if not r["ok"]:
        return {"error": r["output"] or "Không lấy được trạng thái"}
    try:
        return json.loads(r["output"])
    except json.JSONDecodeError:
        return {"error": "Phản hồi trạng thái không phải JSON hợp lệ: " + r["output"][:500]}


# ----------------------------------------------------------------------
# Auth
# ----------------------------------------------------------------------
def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("authed"):
            if request.path.startswith("/api/"):
                return jsonify({"error": "unauthorized"}), 401
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


@app.route("/login", methods=["GET", "POST"])
def login():
    if not DASHBOARD_PASSWORD_HASH:
        return (
            "DASHBOARD_PASSWORD_HASH chưa được cấu hình. "
            "Xem README để tạo mật khẩu trước khi dùng dashboard.", 500
        )
    error = None
    if request.method == "POST":
        pw = request.form.get("password", "")
        pw_hash = hashlib.sha256(pw.encode()).hexdigest()
        if hmac.compare_digest(pw_hash, DASHBOARD_PASSWORD_HASH):
            session.clear()
            session["authed"] = True
            session.permanent = False
            return redirect(url_for("index"))
        error = "Sai mật khẩu."
    return render_template("login.html", error=error)


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


# ----------------------------------------------------------------------
# Trang chính
# ----------------------------------------------------------------------
@app.route("/")
@login_required
def index():
    return render_template("index.html")


# ----------------------------------------------------------------------
# API: trạng thái
# ----------------------------------------------------------------------
@app.route("/api/status")
@login_required
def api_status():
    return jsonify(get_status())


# ----------------------------------------------------------------------
# API: điều khiển server
# ----------------------------------------------------------------------
@app.route("/api/server/start", methods=["POST"])
@login_required
def api_start():
    r = run_panel_func("do_start", timeout=30)
    return jsonify(r)


@app.route("/api/server/stop", methods=["POST"])
@login_required
def api_stop():
    r = run_panel_func("force_cleanup_psiphond", timeout=30)
    return jsonify(r)


@app.route("/api/server/restart", methods=["POST"])
@login_required
def api_restart():
    r = run_panel_func("do_restart", timeout=30)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: log realtime (đọc qua journalctl, vì psiphond mặc định log ra
# stdout -> journald khi LogFilename không được set trong psiphond.config)
# ----------------------------------------------------------------------
@app.route("/api/logs")
@login_required
def api_logs():
    try:
        lines = max(10, min(int(request.args.get("lines", 100)), 1000))
    except ValueError:
        lines = 100
    try:
        proc = subprocess.run(
            ["journalctl", "-u", "psiphond", "-n", str(lines), "--no-pager", "-o", "cat"],
            capture_output=True, text=True, timeout=15,
        )
        text = proc.stdout or proc.stderr
    except Exception as e:
        text = f"Không đọc được log: {e}"
    return jsonify({"lines": text.splitlines()})


# ----------------------------------------------------------------------
# API: import verification key
# ----------------------------------------------------------------------
@app.route("/api/import-key", methods=["POST"])
@login_required
def api_import_key():
    access_type = (request.form.get("access_type") or "").strip()
    do_restart_flag = "1" if request.form.get("restart") in ("1", "true", "on") else "0"

    tmp_path = None
    try:
        uploaded = request.files.get("key_file")
        pasted = (request.form.get("key_json") or "").strip()

        if uploaded and uploaded.filename:
            fd, tmp_path = tempfile.mkstemp(prefix="verify-key-", suffix=".json")
            os.close(fd)
            uploaded.save(tmp_path)
        elif pasted:
            try:
                json.loads(pasted)  # validate trước khi ghi file
            except json.JSONDecodeError as e:
                return jsonify({"ok": False, "output": f"JSON dán vào không hợp lệ: {e}"}), 400
            fd, tmp_path = tempfile.mkstemp(prefix="verify-key-", suffix=".json")
            with os.fdopen(fd, "w") as f:
                f.write(pasted)
        else:
            return jsonify({"ok": False, "output": "Cần upload file hoặc dán nội dung JSON."}), 400

        r = run_panel_func(
            "import_verification_key_core",
            tmp_path, access_type, do_restart_flag,
            timeout=45,
        )
        return jsonify(r)
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.remove(tmp_path)



# ----------------------------------------------------------------------
# API: đặt Region (bắt buộc trước khi generate)
# ----------------------------------------------------------------------
@app.route("/api/set-region", methods=["POST"])
@login_required
def api_set_region():
    region = (request.form.get("region") or "").strip()
    if not region:
        return jsonify({"ok": False, "output": "Cần nhập Region."}), 400
    r = run_panel_func("set_region_core", region, timeout=20)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: generate server (tạo mới lại server entry + config)
# ----------------------------------------------------------------------
@app.route("/api/generate", methods=["POST"])
@login_required
def api_generate():
    # Thao tác phá hoại (xoá config/entry cũ, sinh key mới) - bắt buộc
    # frontend phải gửi kèm confirm=1 (sau khi người dùng bấm xác nhận),
    # không chỉ dựa vào JS confirm() phía client.
    if request.form.get("confirm") != "1":
        return jsonify({"ok": False, "output": "Cần xác nhận trước khi generate (config cũ sẽ bị xoá)."}), 400
    r = run_panel_func("do_generate_core", timeout=90)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: xem / tải server entry
# ----------------------------------------------------------------------
@app.route("/api/server-entry")
@login_required
def api_server_entry():
    r = run_panel_func("web_server_entry_info", timeout=15)
    if not r["ok"]:
        return jsonify({"exists": False, "error": r["output"]})
    try:
        return jsonify(json.loads(r["output"]))
    except json.JSONDecodeError:
        return jsonify({"exists": False, "error": "Phản hồi không phải JSON hợp lệ"})


@app.route("/api/server-entry/download")
@login_required
def api_server_entry_download():
    r = run_panel_func("web_server_entry_info", timeout=15)
    try:
        data = json.loads(r["output"])
    except Exception:
        data = {}
    if not data.get("exists"):
        return jsonify({"error": "Chưa có server entry"}), 404
    from flask import Response
    return Response(
        data.get("hex", ""),
        mimetype="text/plain",
        headers={"Content-Disposition": "attachment; filename=server-entry.txt"},
    )


# ----------------------------------------------------------------------
# API: generate signing keypair (psiphonAuth)
# ----------------------------------------------------------------------
@app.route("/api/generate-keypair", methods=["POST"])
@login_required
def api_generate_keypair():
    do_restart_flag = "1" if request.form.get("restart") in ("1", "true", "on") else "0"
    force_overwrite = "1" if request.form.get("force_overwrite") in ("1", "true", "on") else "0"
    r = run_panel_func("generate_signing_keypair_core", do_restart_flag, force_overwrite, timeout=45)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: đặt giới hạn băng thông mặc định
# ----------------------------------------------------------------------
@app.route("/api/set-limit", methods=["POST"])
@login_required
def api_set_limit():
    kbps = (request.form.get("kbps") or "").strip()
    do_restart_flag = "1" if request.form.get("restart") in ("1", "true", "on") else "0"
    if not kbps.isdigit():
        return jsonify({"ok": False, "output": "KB/s phải là số nguyên >= 0."}), 400
    r = run_panel_func("set_default_limit_core", kbps, do_restart_flag, timeout=45)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: cấp psiphonAuth token mới cho 1 user
# ----------------------------------------------------------------------
@app.route("/api/token/issue", methods=["POST"])
@login_required
def api_token_issue():
    note = (request.form.get("note") or "").strip()
    days = (request.form.get("days") or "30").strip()
    devices = (request.form.get("devices") or "1").strip()
    if not days.isdigit():
        return jsonify({"ok": False, "error": "Số ngày phải là số nguyên."}), 400
    if not devices.isdigit():
        return jsonify({"ok": False, "error": "Số thiết bị phải là số nguyên >= 0."}), 400
    r = run_panel_func("issue_auth_token_core", note, days, devices, timeout=30)
    if not r["ok"]:
        return jsonify({"ok": False, "error": r["output"] or "Sinh token thất bại."}), 500
    try:
        return jsonify(json.loads(r["output"]))
    except json.JSONDecodeError:
        return jsonify({"ok": False, "error": r["output"] or "Phản hồi không phải JSON hợp lệ."}), 500


# ----------------------------------------------------------------------
# API: danh sách token đã cấp
# ----------------------------------------------------------------------
@app.route("/api/token/list")
@login_required
def api_token_list():
    r = run_panel_func("list_auth_tokens_core", timeout=20)
    if not r["ok"]:
        return jsonify({"ok": False, "tokens": [], "error": r["output"]})
    try:
        return jsonify(json.loads(r["output"]))
    except json.JSONDecodeError:
        return jsonify({"ok": False, "tokens": [], "error": "Phản hồi không phải JSON hợp lệ."})


# ----------------------------------------------------------------------
# API: sửa số thiết bị đồng thời của 1 token đã cấp
# ----------------------------------------------------------------------
@app.route("/api/token/set-devices", methods=["POST"])
@login_required
def api_token_set_devices():
    auth_id = (request.form.get("auth_id") or "").strip()
    devices = (request.form.get("devices") or "").strip()
    if not auth_id:
        return jsonify({"ok": False, "output": "Thiếu AuthorizationID."}), 400
    if not devices.isdigit():
        return jsonify({"ok": False, "output": "Số thiết bị phải là số nguyên >= 0."}), 400
    r = run_panel_func("set_device_limit_core", auth_id, devices, timeout=20)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: kick thiết bị đang giữ 1 token (ngắt khẩn cấp, không thu hồi token)
# ----------------------------------------------------------------------
@app.route("/api/token/kick", methods=["POST"])
@login_required
def api_token_kick():
    auth_id = (request.form.get("auth_id") or "").strip()
    if not auth_id:
        return jsonify({"ok": False, "output": "Thiếu AuthorizationID."}), 400
    r = run_panel_func("kick_authorization_core", auth_id, timeout=20)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: liệt kê protocol
# ----------------------------------------------------------------------
@app.route("/api/protocols")
@login_required
def api_protocols():
    r = run_panel_func("web_protocol_list_core", timeout=20)
    if not r["ok"]:
        return jsonify({"ok": False, "protocols": [], "error": r["output"]})
    try:
        return jsonify(json.loads(r["output"]))
    except json.JSONDecodeError:
        return jsonify({"ok": False, "protocols": [], "error": "Phản hồi không phải JSON hợp lệ."})


# ----------------------------------------------------------------------
# API: bật/tắt 1 protocol
# ----------------------------------------------------------------------
@app.route("/api/protocols/toggle", methods=["POST"])
@login_required
def api_protocols_toggle():
    proto = (request.form.get("proto") or "").strip()
    enabled = "true" if request.form.get("enabled") in ("1", "true", "on") else "false"
    if not proto:
        return jsonify({"ok": False, "output": "Thiếu tên protocol."}), 400
    r = run_panel_func("set_protocol_state_core", proto, enabled, timeout=20)
    return jsonify(r)


# ----------------------------------------------------------------------
# API: đổi port 1 protocol
# ----------------------------------------------------------------------
@app.route("/api/protocols/set-port", methods=["POST"])
@login_required
def api_protocols_set_port():
    proto = (request.form.get("proto") or "").strip()
    port = (request.form.get("port") or "").strip()
    if not proto:
        return jsonify({"ok": False, "output": "Thiếu tên protocol."}), 400
    if not port.isdigit():
        return jsonify({"ok": False, "output": "Port phải là số nguyên."}), 400
    r = run_panel_func("set_protocol_port_core", proto, port, timeout=20)
    return jsonify(r)


if __name__ == "__main__":
    # Chạy dev server, bind localhost mặc định (an toàn hơn). Production nên
    # dùng gunicorn qua systemd unit đi kèm (xem README) + reverse proxy TLS.
    host = os.environ.get("DASHBOARD_HOST", "127.0.0.1")
    port = int(os.environ.get("DASHBOARD_PORT", "8088"))
    app.run(host=host, port=port)
