# ⚡ Psiphon Server Panel

Cài đặt & quản lý **Psiphon Server** trên VPS với giao diện menu tương tác.  
Hỗ trợ Ubuntu 20.04 / 22.04 / Debian 10 / 11.

---

## 🚀 Cài đặt nhanh (1 lệnh)

```bash
bash <(curl -s https://raw.githubusercontent.com/caothemanh/psiphon-panel/main/psiphon-panel.sh)
```

---

## 🖥️ Web Dashboard (tùy chọn)

Ngoài menu CLI, panel có **Web Dashboard** — điều khiển server bằng trình
duyệt: start/stop/restart, xem log realtime, import verification key, xem
config hiện tại. Dashboard chỉ là lớp giao diện, mọi hành động thật sự đều
gọi lại đúng logic trong `psiphon-panel.sh`.

Cài ngay trong panel, không cần lệnh riêng:

```
psiphon-panel → [7] Web Dashboard → [1] Cài đặt Web Dashboard
```

Panel sẽ hỏi mật khẩu và chế độ truy cập (chỉ nội bộ / mở public qua IP),
tự tải mã dashboard, dựng venv, tạo systemd service, start — xong in ngay
link/lệnh SSH tunnel để bạn copy dùng luôn. Vào lại `[7]` bất kỳ lúc nào để
xem link, đổi mật khẩu, restart, xem log hoặc gỡ dashboard.

Chi tiết đầy đủ (bảo mật, expose qua domain/HTTPS...) xem
[`webpanel/README.md`](webpanel/README.md).

---

## 📋 Tính năng

| Menu | Tính năng |
|------|-----------|
| **[1] Cài đặt** | Tải psiphond, cài systemd service tự động |
| **[2] Cấu hình** | Bật/tắt từng protocol, sửa port riêng lẻ, generate server entry |
| **[3] Quản lý** | Start / Stop / Restart, xem log realtime, bật/tắt autostart |
| **[4] Server Entry** | Xem & export hex entry để copy vào app |
| **[5] Firewall** | Tự động mở đúng port với UFW |
| **[6] psiphonAuth** | Giới hạn băng thông + unlimit theo token (psiphonAuth) |
| **[7] Web Dashboard** | Cài/điều khiển dashboard web, copy link truy cập |
| **[8] Cập nhật Panel** | Tải bản mới nhất, tự khởi động lại |
| **[9] Gỡ cài đặt** | Xóa toàn bộ |

---

## 🔌 Protocol hỗ trợ

| Protocol | Port mặc định |
|----------|--------------|
| SSH | 3001 |
| OSSH | 3002 |
| FRONTED-MEEK-HTTP-OSSH | 80 |
| FRONTED-MEEK-OSSH | 443 |
| UNFRONTED-MEEK-OSSH | 8080 |
| UNFRONTED-MEEK-HTTPS-OSSH | 8443 |
| UNFRONTED-MEEK-SESSION-TICKET-OSSH | 8880 |
| TLS-OSSH | 8843 |
| QUIC-OSSH | 1194 |

---

## 📖 Hướng dẫn sử dụng

### Lần đầu cài đặt

```
[1] Cài đặt Psiphon Server     ← chạy đầu tiên
[2] Cấu hình Protocol & Port   ← chọn protocol, sửa port, bấm Generate
[4] Xem Server Entry            ← copy hex vào app
[3] Quản lý Server → [1]        ← khởi động server
```

### Generate lại server entry

```
[2] Cấu hình → [G] Generate
```

> ⚠️ Mỗi lần generate sẽ tạo **key mới hoàn toàn** → phải cập nhật lại Server Entry trong app.

---

## 📁 Cấu trúc file trên VPS sau cài đặt

```
/usr/local/psiphon/
├── psiphond                    # binary server
├── psiphond.config             # cấu hình server
├── psiphond-traffic-rules.config
├── psiphond-tactics.config
├── psiphond-osl.config
├── server-entry.dat            # entry gốc (generate sinh ra)
├── server-entry.dat.patched    # entry đã vá meekServerPort ← dùng cái này
└── patch_entry.py              # công cụ vá entry

/etc/psiphon-panel/
└── panel.conf                  # cấu hình panel (IP, port, protocol)

/etc/systemd/system/
└── psiphond.service            # service tự chạy khi reboot

/var/log/
└── psiphon.log                 # log server
```

---

## ❓ FAQ

**Q: Tại sao FRONTED-MEEK-HTTP không kết nối được?**  
A: `psiphond generate` bị thiếu field `meekServerPort` trong server entry — panel đã tự động vá lỗi này.

**Q: Có cần CDN để dùng FRONTED-MEEK không?**  
A: Không bắt buộc, nhưng nếu không có CDN thật thì traffic không được "fronted" thực sự — phù hợp để test nội bộ.

**Q: Thay đổi port có cần generate lại không?**  
A: Có — sau khi sửa port ở menu [2] phải bấm Generate lại để cập nhật config và server entry.
