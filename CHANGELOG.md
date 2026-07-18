# Changelog

## Unreleased (16)
- **Panel tự dò kiến trúc CPU để tải đúng binary `psiphond`/`psiphon-
  authgen`.** Trước đây chỉ có 1 tên file cố định (`psiphond`,
  `psiphon-authgen`), giả định amd64 - board ARM (VD Armbian, aarch64)
  tải về đúng file nhưng SAI kiến trúc, generate báo "Exec format error"
  rất khó hiểu. Thêm `detect_binary_arch()` (map `uname -m` →
  amd64/arm64), tự chọn URL đúng hậu tố kiến trúc
  (`psiphond-amd64`/`psiphond-arm64`...). Báo lỗi rõ ràng ngay từ đầu nếu
  kiến trúc không được hỗ trợ (chỉ có amd64/arm64), thay vì tải nhầm rồi
  mới báo lỗi mơ hồ lúc generate.
  - **Cần đổi quy ước ở repo `caothemanh/psiphond`:** đổi tên file đang
    lưu từ `psiphond`/`psiphon-authgen` (1 bản) sang 4 file riêng theo
    kiến trúc: `psiphond-amd64`, `psiphond-arm64`,
    `psiphon-authgen-amd64`, `psiphon-authgen-arm64` (khớp đúng tên
    artifact `build-psiphond.yml` đang xuất ra, chỉ bỏ phần `linux-` ở
    giữa tên).

## Unreleased (15)
- **Thêm đổi port cho CHÍNH Web Dashboard** (khác với port từng protocol
  psiphon, vốn đã đổi được từ trước) - card mới "Port của Web Dashboard"
  ở tab Nâng cao. Giải quyết đúng vấn đề port `8088` mặc định bị trùng với
  dịch vụ khác trên VPS.
  - Backend: `set_webpanel_port_core` - validate port, dò trước xem port
    mới có đang bị tiến trình KHÁC (không phải gunicorn của chính
    dashboard) chiếm không để báo lỗi sớm thay vì đổi xong mới fail-to-
    bind, sửa `-b host:port` trong systemd service (giữ nguyên phần host
    127.0.0.1/0.0.0.0, chỉ đổi số port), cập nhật lại rule UFW nếu đang ở
    chế độ public, lưu `WEBPANEL_PORT` vào `/etc/psiphon-dashboard.env` để
    các lần chạy panel sau đọc đúng port hiện tại (`load_config` đã có
    sẵn logic đọc override này từ trước).
  - Vì chính request đổi port đang được phục vụ bởi service SẮP bị
    restart, lên lịch restart TRỄ 2 giây chạy nền (không đợi response) để
    trình duyệt kịp nhận kết quả trước khi mất kết nối. Route mới
    `/api/set-webpanel-port`.
  - Frontend: xác nhận rõ trước khi đổi (nêu rõ sẽ mất kết nối tạm thời),
    sau khi đổi thành công tự đếm ngược 5 giây rồi chuyển hướng trình
    duyệt sang `http://<host>:<port_mới>/` - không cần tự gõ lại địa chỉ
    tay.
  - `web_status_json` trả thêm `webpanel_port` để hiển thị/prefill đúng
    port hiện tại đang dùng.

## Unreleased (14)
- **Thêm checkbox chọn nhiều token + xoá hàng loạt** trong bảng "Quản lý
  User (psiphonAuth Token)" trên web. Có checkbox từng dòng + "chọn tất
  cả" ở header, nút "🗑 Xoá đã chọn (N)" hiện số lượng đang chọn.
  - Backend: hàm mới `delete_auth_tokens_core` (nhận JSON array các
    AuthorizationID) - xoá đúng dòng khớp khỏi `tokens.log`, khỏi mảng
    `authorizations.json`, khỏi từng khối trong
    `authorizations-blocks.json`, và dọn key tương ứng trong
    `device-limits.json` nếu có. Route mới `/api/token/delete`.
  - **Cảnh báo quan trọng đã ghi rõ trong UI lẫn code**: thao tác này CHỈ
    dọn sổ theo dõi phía admin - psiphonAuth xác thực bằng chữ ký khoá
    (SigningKeyID + Signature), psiphond KHÔNG đọc các file này lúc chạy
    để kiểm tra token còn "tồn tại" hay không. Nghĩa là xoá ở đây KHÔNG
    thu hồi được token đã cấp - ai đã cầm chuỗi token đó vẫn kết nối được
    bình thường tới khi hết hạn tự nhiên. Muốn thu hồi thật sự, cách duy
    nhất là sinh lại signing keypair mới (vô hiệu hoá TOÀN BỘ token cũ,
    không chọn lọc được từng cái).

## Unreleased (13)
- Sửa câu hỏi ở menu `[8]` gây hiểu lầm: *"đồng bộ code mới nhất (giữ
  nguyên mật khẩu) luôn?"* dễ đọc thành "bấm y thì sẽ được hỏi đặt lại mật
  khẩu (nhưng giữ nguyên nếu muốn)". Thực ra nhánh này KHÔNG có bước hỏi
  mật khẩu nào cả - chỉ tải code + restart. Đổi câu chữ rõ ràng hơn: *"chỉ
  tải code + restart, KHÔNG đụng mật khẩu/cấu hình"*.

## Unreleased (12)
- **Sửa copy token/server entry không hoạt động trên di động.** Dashboard
  chạy `http://` thuần (không TLS) trên IP thật - `navigator.clipboard`
  chỉ hoạt động trên "secure context" (https hoặc localhost) nên trình
  duyệt di động (đặc biệt iOS Safari) thường không cho dùng API này qua
  http, và cách dự phòng cũ (`textarea` ẩn + `execCommand('copy')`) cũng
  hay fail trên mobile vì thiếu `focus()`/chọn vùng đúng cách trước khi
  copy. Viết lại `copyToClipboard()` dùng chung cho MỌI nút copy (server
  entry hex, token vừa cấp, token trong danh sách): luôn thử
  `navigator.clipboard` trước, fallback bằng textarea đặt trong viewport +
  `focus()` + `setSelectionRange()` (đúng cách iOS Safari cần), báo rõ
  "✓ Đã copy" hoặc "⚠ Bấm giữ để copy tay" nếu cả 2 cách đều fail thay vì
  im lặng không phản hồi gì.
- Gộp nút "Copy hex" (Server Entry) về dùng chung hàm `copyToClipboard()`
  thay vì code copy riêng (trước đây không có fallback tốt cho mobile).

## Unreleased (11)
- **Sửa: menu `[7] Cài lại / cập nhật dashboard` LUÔN bắt đặt lại mật khẩu
  + chọn lại chế độ public/private mỗi lần chạy**, kể cả khi chỉ định
  cập nhật CODE (không đổi gì khác) - rất bất tiện, và là lý do "web
  không tự cập nhật" phải "cài lại" nghe rất nặng. Giờ hàm này thực sự
  idempotent: nếu đã có mật khẩu/chế độ truy cập từ trước, mặc định GIỮ
  NGUYÊN (chỉ hỏi lại nếu người dùng chủ động chọn đặt lại), chỉ khi cài
  MỚI hoàn toàn mới hỏi như trước.
- **Menu `[8] Cập nhật Panel` giờ hỏi luôn có muốn đồng bộ code Web
  Dashboard không** (nếu đã cài) - chỉ tải lại `app.py`/`templates`, GIỮ
  NGUYÊN mật khẩu/venv/chế độ truy cập, rồi tự restart service. Không cần
  nhớ vào lại menu [7] mỗi lần muốn web dùng đúng code mới nhất.

## Unreleased (10)
- **Thêm quản lý Protocol/Port lên Web Dashboard + chia giao diện theo tab.**
  Trang web trước đây xếp hết các card theo 1 cột dài, càng thêm tính năng
  càng khó nhìn. Giờ chia làm 4 tab:
  - **Tổng quan**: Điều khiển server + Trạng thái.
  - **Protocol**: bảng bật/tắt + đổi port từng protocol (mới), Region,
    Generate, và xem/tải server entry - gom chung vì đều là các bước đi
    liền nhau khi đổi cấu hình protocol.
  - **psiphonAuth & User**: sinh keypair, giới hạn mặc định, import
    verification key, quản lý token/user.
  - **Nâng cao**: xem cấu hình JSON hiện tại, log realtime.
  - Backend: 3 hàm mới `web_protocol_list_core`, `set_protocol_state_core`,
    `set_protocol_port_core` - áp dụng đúng ràng buộc như CLI menu [2]
    (protocol dùng-chung-port yêu cầu protocol cha đang bật mới bật được;
    tắt protocol cha tự tắt theo các protocol con), cảnh báo xung đột port
    (`warn_port_conflicts`) và nhãn protocol thử nghiệm y hệt CLI. 3 route
    Flask mới `/api/protocols`, `/api/protocols/toggle`,
    `/api/protocols/set-port`.
  - Đổi protocol/port trên web KHÔNG tự generate lại - vẫn phải bấm
    "Generate lại server" (đúng ý nghĩa vốn có: đổi xong mới generate 1
    lần, tránh generate lãng phí mỗi lần đổi 1 field).

## Unreleased (9)
- **Thêm "Quản lý User" (psiphonAuth Token) lên Web Dashboard.** Trước đây
  web chỉ có "Sinh cặp khóa ký" (keypair) - phần cấp/quản lý token cho
  từng user hoàn toàn phải làm qua CLI menu [6]. Giờ thêm card "Quản lý
  User (psiphonAuth Token)":
  - Cấp token mới (ghi chú, số ngày hiệu lực, số thiết bị đồng thời) -
    trả về token dạng chuỗi thuần + dạng mảng JSON sẵn để dán vào config
    client, đều có nút copy riêng.
  - Bảng danh sách toàn bộ token đã cấp (ngày, ghi chú, hạn, số thiết bị
    HIỆN TẠI - đối chiếu sống với device-limits.json chứ không phải giá
    trị lúc cấp ban đầu, AuthID rút gọn).
  - Mỗi dòng sửa được số thiết bị đồng thời (hot-reload, không cần
    restart) và "Kick" (ngắt khẩn cấp thiết bị đang giữ token, không thu
    hồi token vĩnh viễn - đúng hành vi nút Kick ở CLI).
  - Backend: 4 hàm mới `issue_auth_token_core`, `list_auth_tokens_core`,
    `set_device_limit_core`, `kick_authorization_core` (tách theo đúng
    pattern các hàm `_core` khác - không hỏi gì, dùng chung logic với bản
    CLI tương tác để không lệch bug giữa 2 giao diện), 4 route Flask mới
    `/api/token/issue|list|set-devices|kick`.
  - Tiện sửa luôn: xoá 1 dòng `setInterval(refreshStatus, 6000)` bị lặp 2
    lần trong `index.html` (không phải bug nghiêm trọng, chỉ dư 1 interval
    vô ích).

## Unreleased (8)
- **Sửa bug "đã cập nhật panel nhưng fix vẫn không có tác dụng".** Bước
  `[2/6]` của `install_web_dashboard()` tự tải bản `psiphon-panel.sh` mới
  nhất và ghi đè `/usr/local/bin/psiphon-panel` trên đĩa, NHƯNG tiến trình
  bash đang chạy đã nạp toàn bộ hàm (kể cả chính hàm này) từ bản CŨ ngay
  lúc khởi động - ghi đè file không khiến tiến trình hiện tại dùng code
  mới. Hậu quả: các bước `[3/6]` trở đi trong CÙNG 1 lần chạy vẫn thực thi
  logic cũ y hệt trước khi "cập nhật", dù file trên đĩa đã đúng bản mới
  nhất (đây là lý do fix chọn Python >= 3.8 ở bản trước "không ăn thua" dù
  panel báo cập nhật thành công). Giờ nếu tải về bản THỰC SỰ khác (so bằng
  `cmp`), sẽ `exec` lại chính nó bằng bản mới trên đĩa (giống cách
  `update_panel_self` ở menu `[8]` vốn đã làm đúng từ trước) và tự động
  tiếp tục đúng ngay bước cài Web Dashboard đang dở dang, thay vì chạy tiếp
  bằng code cũ còn nằm trong bộ nhớ tiến trình.

## Unreleased (7)
- **Sửa lỗi cài dependencies thất bại trên VPS Python cũ.**
  `pip install Flask==3.0.3` báo `Could not find a version that satisfies
  the requirement...` trên các VPS Ubuntu cũ (18.04 trở xuống, mặc định
  `python3` là 3.6/3.7) - nhìn giống lỗi mạng/PyPI nhưng thực chất do
  Flask 3.x/gunicorn 22.x yêu cầu Python >= 3.8, pip tự lọc bỏ hết bản mới
  không tương thích. Thêm hàm `pick_python_bin()` (cả trong
  `install_web_dashboard()` và `install.sh`): tự dò interpreter `python3.8`
  → `python3.13` mới nhất có sẵn trên máy, nếu không có thì thử `apt-get
  install` thêm 1 bản mới hơn, dùng interpreter đó để tạo venv thay vì
  cứng `python3` mặc định. Nếu vẫn không tìm/cài được Python >= 3.8 (VD
  không có internet ra ngoài apt mirror), tự động hạ xuống dải version cũ
  hơn còn tương thích (`Flask>=2.0,<3`, `gunicorn>=20,<21`) thay vì fail
  cứng không cài được gì, kèm gợi ý nâng cấp Python khi có dịp.

## Unreleased (6)
- Mở rộng danh sách dọn dẹp ở `[9] Gỡ cài đặt`: rà lại toàn bộ script tìm
  mọi chỗ từng ghi file ra NGOÀI `$INSTALL_DIR`/`$PANEL_DIR`, phát hiện
  thêm 4 file bị bỏ sót ở lần sửa trước - đều nằm trong `/root`:
  `server-entry-export.txt` (export server entry thủ công ở menu Xem
  Entry), `psiphon-verification-key-export.json` (export verification key
  để copy sang VPS thứ 2), `authorizations.json` và
  `authorizations-blocks.json` (log token psiphonAuth đã cấp). Giờ cả 5
  file `/root/*` liên quan tới psiphon đều bị xoá khi gỡ cài đặt.

## Unreleased (5)
- **Sửa menu `[9] Gỡ cài đặt` bỏ sót Web Dashboard.** Trước đây chỉ gỡ
  psiphond (service, `$INSTALL_DIR`, `$PANEL_DIR`, `/usr/local/bin/
  psiphon-panel`) - nếu đã cài Web Dashboard thì service `psiphon-dashboard`
  vẫn chạy, `/opt/psiphon-dashboard` + `/etc/psiphon-dashboard.env` vẫn còn
  nguyên, dashboard vẫn truy cập được bình thường dù panel báo "gỡ hoàn
  tất". Giờ gỡ luôn Web Dashboard nếu phát hiện đã cài.
- Thêm `force_cleanup_psiphond` trước khi gỡ (thay vì chỉ `systemctl stop`)
  để không bỏ sót tiến trình `psiphond` mồ côi không do systemd quản lý.
- Dọn thêm các file rác nằm NGOÀI `$INSTALL_DIR`/`$PANEL_DIR` mà các bước
  generate/venv trước đó để lại: `/root/server-entry.dat`,
  `/tmp/psiphon-generate.log`, `/tmp/psiphon-venv-err.log`,
  `/tmp/psiphon-panel-update-err.log`.
- Thêm bước hỏi riêng: đóng các port UFW đã mở cho protocol/web/dashboard
  (không đụng port 22/SSH) - không tự làm ngầm vì có thể ảnh hưởng rule
  khác người dùng đang cần.

## Unreleased (4)
- **Sửa lỗi `SyntaxError: Unexpected token '<'` khi gọi API từ web.** Trước
  đây mọi handler JS gọi `fetch(...).json()` trực tiếp - nếu backend trả về
  HTML (404 do route chưa tồn tại trên bản app.py cũ đang chạy, hoặc trang
  lỗi 500 mặc định của Flask) thay vì JSON, `res.json()` sẽ throw lỗi parse
  rất khó hiểu, không rõ nguyên nhân thật. Giờ tất cả gọi qua 2 helper dùng
  chung `callApi()`/`postForm()`: đọc response dạng text trước, thử parse
  JSON, nếu fail thì trả về thông báo rõ ràng (có phân biệt 404 vs lỗi
  khác) thay vì để lỗi parse bắn thẳng ra UI.
- Dời ô nhập Region xuống DƯỚI nút "Generate lại server" (trước đặt ở
  trên, dễ nhầm là phải điền trước khi bấm generate mới thấy).

## Unreleased (3)
- **Thêm ô nhập Region ngay trên Web Dashboard.** Trước đó Region chỉ đặt
  được qua CLI (SSH), web chỉ báo lỗi và bắt người dùng tự SSH vào sửa. Giờ
  card "Tạo mới lại server" có sẵn ô nhập Region + nút "Đặt Region", gọi
  hàm mới `set_region_core` (validate 2 chữ cái, lưu config ngay, không cần
  restart vì Region chỉ nhúng vào server entry ở lần generate kế tiếp).
  `web_status_json` cũng trả thêm field `region` để dashboard hiển thị giá
  trị hiện tại trong bảng Trạng thái và tự điền sẵn vào ô nhập.

## Unreleased (2)
- **Region giờ bắt buộc khi generate.** Trước đây Region optional, dễ quên
  đặt, khiến server entry sinh ra không có field region. `do_generate` (CLI)
  giờ hỏi và validate (mã 2 chữ cái) ngay tại chỗ, không cho tiếp tục cho tới
  khi có Region hợp lệ. `do_generate_core` (dùng chung cho web dashboard,
  không có TTY để hỏi) sẽ chặn lại với `ERR: Chưa đặt Region...` nếu gọi khi
  chưa có Region - phải đặt trước qua CLI menu [2] > [R].
- **`install.sh`: sửa PANEL_DEST sai đường dẫn.** Trước đây cài panel vào
  `/root/psiphon-panel.sh` trong khi `PANEL_SCRIPT_PATH` mặc định và menu
  CLI [8] "Cập nhật Panel" đều dùng `/usr/local/bin/psiphon-panel`. Hậu quả:
  cài bằng `install.sh` xong, sau này cập nhật panel qua menu CLI sẽ cập
  nhật NHẦM file, dashboard vẫn chạy mãi bản cũ do `PANEL_SCRIPT_PATH` trỏ
  chỗ khác - đúng dạng bug "web dashboard gọi hàm không tồn tại / hành vi
  cũ" đã gặp trước đây. Giờ cả hai đường cài (menu CLI và `install.sh`) đều
  thống nhất dùng `/usr/local/bin/psiphon-panel`.
- `install.sh`: thêm fallback tạo venv giống hệt `install_web_dashboard()`
  trong CLI - tự dò và cài đúng gói `python3.X-venv` khi venv tạo ra thiếu
  `pip` (ensurepip), thay vì chỉ fail mơ hồ như trước.
- `install.sh`: đọc mật khẩu từ `/dev/tty` thay vì stdin mặc định - tránh
  trường hợp chạy kiểu `curl ... | sudo bash` (stdin bị curl chiếm) khiến
  `read` fail và script thoát câm nín giữa chừng do có `set -e`.

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
