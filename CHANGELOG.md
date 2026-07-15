# Changelog

## Unreleased
- Web Dashboard giờ có đủ các thao tác chính như CLI: **Generate lại server**,
  **xem/copy/tải server entry**, **sinh signing keypair (psiphonAuth)**, và
  **đặt giới hạn băng thông mặc định** — không chỉ xem/start/stop/restart/
  import key như trước. Mọi thao tác đều gọi lại đúng hàm "core" (không hỏi
  gì) đã tách ra từ logic CLI tương ứng (`do_generate_core`,
  `generate_signing_keypair_core`, `set_default_limit_core`,
  `web_server_entry_info`), nên không lệch bug so với bản CLI.
- Các thao tác phá hoại (generate xoá config cũ, ghi đè signing key) đều bắt
  buộc xác nhận ở CẢ frontend (confirm dialog) lẫn backend (tham số
  `confirm`/`force_overwrite` riêng), không chỉ dựa vào JS phía client.
- Thêm `[8] Cập nhật Panel` vào menu chính: tải bản mới nhất từ GitHub, kiểm
  tra cú pháp trước khi thay thế, tự khởi động lại. Trước đây lệnh
  `psiphon-panel` cache vĩnh viễn bản lúc cài đầu tiên, các bản vá sau đó
  không tự áp dụng cho tới khi cài lại từ đầu.
- `install_web_dashboard`: sửa venv - Ubuntu/Debian đôi khi thiếu đúng gói
  `python3.X-venv` cho ensurepip khiến venv tạo ra không có `pip`; giờ tự dò
  version và cài đúng gói, có fallback + thông báo lỗi rõ ràng.
- `install_web_dashboard`: bước cập nhật `psiphon-panel.sh` giờ LUÔN tải bản
  mới nhất thay vì chỉ tải khi file chưa tồn tại (tránh cài dashboard bằng
  logic panel đã cũ).
- Web Dashboard giờ cài được **ngay trong menu panel** (`[7] Web Dashboard`),
  không cần chạy `install.sh`/git clone thủ công nữa. Panel tự tải mã
  dashboard, dựng venv, hỏi mật khẩu + chế độ truy cập (nội bộ/public), tạo
  systemd service, rồi in sẵn link truy cập để copy.
- Thêm Web Dashboard (`webpanel/`) — điều khiển server qua trình duyệt
  (start/stop/restart, log realtime, import verification key, xem config).
- `psiphon-panel.sh`: thêm `import_verification_key_core` và `web_status_json`
  (dùng cho dashboard), guard `PANEL_LIB_MODE` để source được như thư viện.
- Sửa `do_restart` báo "thành công" giả khi tiến trình cũ chưa thực sự bị
  kill; giờ ưu tiên `systemctl restart` atomic + xác nhận PID mới trước khi
  báo OK.
- Sửa `inject_config.py` nuốt lỗi khi ghi `psiphond.config` (chỉ bắt
  `FileNotFoundError`, các lỗi khác làm config không được cập nhật nhưng
  panel vẫn báo thành công).

## v2.0.0
- Menu đầy đủ: cài đặt, cấu hình, quản lý, firewall, gỡ cài đặt
- Hỗ trợ 9 protocol với bật/tắt và sửa port riêng lẻ
- Tự động vá `meekServerPort` vào server entry sau khi generate
- Tích hợp UFW firewall tự động mở đúng port
- Systemd service tự động restart khi VPS reboot
- Export server entry ra file

## v1.0.0
- Script cơ bản: generate, start, stop, restart
