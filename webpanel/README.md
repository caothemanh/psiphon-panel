# Psiphon Panel — Web Dashboard

## Cài nhanh (khuyến nghị)

Cài ngay trong panel CLI, không cần lệnh/script riêng:

```
psiphon-panel → [7] Web Dashboard → [1] Cài đặt Web Dashboard
```

Panel sẽ hỏi mật khẩu, hỏi chế độ truy cập (chỉ nội bộ qua SSH tunnel, hay
mở public qua `http://IP_VPS:8088`), tự tải mã dashboard từ repo này, dựng
Python venv, tạo systemd service `psiphon-dashboard`, start — rồi in ngay
link (hoặc lệnh SSH tunnel) để bạn copy dùng luôn.

Vào lại `[7] Web Dashboard` bất kỳ lúc nào để xem lại link, đổi mật khẩu,
restart, xem log, hoặc gỡ dashboard.

### Cách khác: `install.sh` (nếu không dùng qua panel)

Nếu bạn deploy `webpanel/` độc lập (không thông qua menu panel — ví dụ tự
copy file lên VPS thủ công), dùng `install.sh` ở thư mục gốc repo:

```bash
sudo bash install.sh
```

Phần dưới đây là các bước THỦ CÔNG tương đương (dùng nếu muốn tự kiểm soát
từng bước, hoặc troubleshoot khi cài tự động gặp lỗi).

---

Giao diện web cho `psiphon-panel.sh`. Chỉ bọc lại UI — mọi hành động thật sự
(start/stop/restart, import verification key...) đều gọi lại đúng các hàm
bash đã có trong `psiphon-panel.sh` (source ở chế độ thư viện, không chạy
menu tương tác), nên không lệch bug so với bản CLI bạn vẫn dùng qua SSH.

**Tính năng:** trạng thái, start/stop/restart, log realtime (journalctl),
generate lại server (xoá + sinh mới config/entry), xem/copy/tải server
entry, sinh signing keypair (psiphonAuth), đặt giới hạn băng thông mặc
định, import verification key, xem AccessControlVerificationKeyRing +
traffic-rules.json hiện tại — đầy đủ song song với các thao tác trên CLI.
Còn lại ở CLI (chưa có trên web): bật/tắt từng protocol riêng lẻ và sửa
port, cấp/quản lý từng psiphonAuth token cho user, cấu hình firewall, gỡ
cài đặt. Nói mình biết nếu bạn muốn đưa nốt phần này lên web.

## ⚠️ Bảo mật — đọc trước khi deploy

Dashboard này chạy với quyền **root** và có toàn quyền điều khiển psiphond.
Bắt buộc:
1. Đặt mật khẩu mạnh (bước 3 bên dưới) — không có mật khẩu, ai vào được URL
   cũng vào được dashboard.
2. **Không** expose thẳng port 8088 ra Internet mà không có HTTPS. Chọn 1
   trong 2 cách ở bước 5.
3. Cân nhắc chặn thêm bằng UFW theo IP cố định nếu bạn luôn truy cập từ 1-2
   địa chỉ IP quen thuộc.

## Cài đặt

### 1. Copy file lên VPS

```bash
mkdir -p /opt/psiphon-dashboard
# copy toàn bộ nội dung thư mục webpanel/ (app.py, templates/, requirements.txt...)
# vào /opt/psiphon-dashboard/ trên VPS, ví dụ bằng scp:
#   scp -r webpanel/* root@VPS_IP:/opt/psiphon-dashboard/
```

Đảm bảo `psiphon-panel.sh` (bản đã vá — có `import_verification_key_core`,
`web_status_json`, guard `PANEL_LIB_MODE`) nằm ở 1 đường dẫn cố định trên
VPS, ví dụ `/root/psiphon-panel.sh`.

### 2. Cài Python deps

```bash
cd /opt/psiphon-dashboard
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

### 3. Tạo mật khẩu

```bash
cd /opt/psiphon-dashboard
python3 set_password.py
```

Lệnh này in ra dòng `DASHBOARD_PASSWORD_HASH=...`. Tạo file env:

```bash
cat > /etc/psiphon-dashboard.env << 'EOF'
DASHBOARD_PASSWORD_HASH=<dán hash từ bước trên>
DASHBOARD_SECRET_KEY=<chạy: python3 -c "import secrets; print(secrets.token_hex(32))">
PANEL_SCRIPT_PATH=/root/psiphon-panel.sh
EOF
chmod 600 /etc/psiphon-dashboard.env
```

### 4. Chạy qua systemd

```bash
cp /opt/psiphon-dashboard/psiphon-dashboard.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now psiphon-dashboard
systemctl status psiphon-dashboard --no-pager
```

Mặc định service bind vào `127.0.0.1:8088` — **chưa** truy cập được từ bên
ngoài (đúng ý, an toàn hơn). Xem bước 5 để expose ra ngoài đúng cách.

### 5. Truy cập từ bên ngoài (chọn 1 cách)

**Cách A — SSH tunnel (đơn giản nhất, không cần domain/TLS):**

Trên máy cá nhân:
```bash
ssh -L 8088:127.0.0.1:8088 root@VPS_IP
```
Rồi mở `http://127.0.0.1:8088` trên trình duyệt máy mình. Traffic được mã
hoá qua kênh SSH sẵn có, không cần thêm gì trên VPS.

**Cách B — Nginx reverse proxy + HTTPS (nếu muốn truy cập trực tiếp bằng domain):**

```nginx
server {
    listen 443 ssl;
    server_name dashboard.example.com;

    ssl_certificate     /etc/letsencrypt/live/dashboard.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dashboard.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
server {
    listen 80;
    server_name dashboard.example.com;
    return 301 https://$host$request_uri;
}
```
Dùng `certbot --nginx` để lấy chứng chỉ Let's Encrypt. Sau đó có thể thêm
`allow <IP của bạn>; deny all;` trong block `location /` nếu muốn giới hạn
thêm theo IP.

## Cấu trúc file

```
/opt/psiphon-dashboard/
├── app.py                  # Flask backend
├── requirements.txt
├── set_password.py         # tạo DASHBOARD_PASSWORD_HASH
├── psiphon-dashboard.service
└── templates/
    ├── login.html
    └── index.html
/etc/psiphon-dashboard.env   # mật khẩu + đường dẫn tới psiphon-panel.sh
/root/psiphon-panel.sh       # bản panel CLI đã vá (nguồn của mọi logic thật)
```

## Đổi mật khẩu sau này

Chạy lại `python3 set_password.py`, cập nhật `DASHBOARD_PASSWORD_HASH` trong
`/etc/psiphon-dashboard.env`, rồi `systemctl restart psiphon-dashboard`.
