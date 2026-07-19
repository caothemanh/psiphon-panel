#!/usr/bin/env python3
"""Tạo hash mật khẩu để dán vào /etc/psiphon-dashboard.env (DASHBOARD_PASSWORD_HASH=...)."""
import hashlib

pw = input("Nhập mật khẩu cho dashboard: ")
pw2 = input("Nhập lại: ")
if pw != pw2:
    raise SystemExit("Hai lần nhập không khớp.")
if not pw:
    raise SystemExit("Mật khẩu không được để trống.")

print("\nDASHBOARD_PASSWORD_HASH=" + hashlib.sha256(pw.encode()).hexdigest())
print("\n-> Dán dòng trên vào /etc/psiphon-dashboard.env")
