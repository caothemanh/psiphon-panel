#!/usr/bin/env python3
"""Tạo hash mật khẩu để dán vào /etc/psiphon-dashboard.env (DASHBOARD_PASSWORD_HASH=...)."""
import getpass
import hashlib

pw = getpass.getpass("Nhập mật khẩu cho dashboard: ")
pw2 = getpass.getpass("Nhập lại: ")
if pw != pw2:
    raise SystemExit("Hai lần nhập không khớp.")
if len(pw) < 8:
    raise SystemExit("Mật khẩu nên dài tối thiểu 8 ký tự.")

print("\nDASHBOARD_PASSWORD_HASH=" + hashlib.sha256(pw.encode()).hexdigest())
print("\n-> Dán dòng trên vào /etc/psiphon-dashboard.env")
