# SeekZip

[English](README.md) | **Tiếng Việt** | [简体中文](README.zh-CN.md)

**Tìm thấy bên trong. Chỉ giải nén những gì bạn cần.**

Tài liệu: [Build từ con số 0](docs/BUILD_FROM_ZERO.vi.md) ·
[Kiến trúc](docs/ARCHITECTURE.vi.md) ·
[Ma trận kiểm thử](docs/TEST-MATRIX.vi.md) ·
[Bàn giao cho agent](docs/HANDOFF.vi.md) ·
[Nghiên cứu tham khảo](docs/REFERENCE.md)
(mỗi tài liệu đều có bản Tiếng Việt và 简体中文 với hậu tố `.vi.md` / `.zh-CN.md`)

Ứng dụng quản lý file nén native cho macOS trên Apple Silicon, miễn phí —
duyệt và xem trước nội dung archive trước khi giải nén, chỉ giải nén những
file bạn chọn, và tạo hoặc chỉnh sửa archive. Được build clean-room bằng
Swift/SwiftUI sau khi nghiên cứu các dự án tham khảo (xem
`docs/REFERENCE.md`); không sao chép code của bất kỳ ứng dụng bên thứ ba nào.

## Kiến trúc

Một engine, ba frontend:

```
            ┌─────────────┐
            │ SeekZipApp  │  SwiftUI GUI (browse, preview, queue)
            ├─────────────┤
 frontends  │ seekzip     │  CLI — scriptable, `--json`, stable exit codes
            ├─────────────┤
            │ seekzip-mcp │  MCP server (stdio) for AI assistants
            └──────┬──────┘
                   │
            ┌──────▼──────┐
            │SeekZipCore  │  engine wrapper, listing parser, path safety,
            │             │  queue, models — the only place logic lives
            └──────┬──────┘
                   │  Process (streaming, never loads archives into RAM)
            ┌──────▼──────┐
            │  7zz (7-Zip)│  bundled official macOS ARM binary
            └─────────────┘
```

Vì sao cần cả CLI *và* MCP, thay vì chỉ cho truy cập 7-Zip qua terminal?
Terminal thô cho AI và script văn bản không có cấu trúc, không chia sẻ được
trạng thái hàng đợi/password, và không có sẵn cơ chế chống zip-slip. CLI cho
ra JSON có cấu trúc và exit code ổn định (đồng thời là thứ chạy ma trận kiểm
thử headless trong CI); MCP server là một lớp schema mỏng trên cùng core đó,
để các trợ lý AI nhận được các tool an toàn, có kiểu dữ liệu rõ ràng
(`list_archive`, `extract_entries`, …) thay vì phải parse shell.

## Trạng thái

Khung v0.1: model của core, parser cho listing `7zz -slt`, kiểm tra an toàn
đường dẫn khi giải nén, CLI, khung MCP server, khung trình duyệt SwiftUI,
đặc tả ma trận kiểm thử đầy đủ (`docs/TEST-MATRIX.vi.md`), CI cho macOS.

M1 đã xanh: `swift build` + `swift test` + smoke test CLI pass trên CI
(macos-15). M2 đã xong: listing stream từ `7zz` (parser tăng dần, tiến độ,
hủy, `list --stream`). M3 đã xong: xem trước (text stream vào qua
`7zz e -so`, giới hạn 64 KB / 200 dòng; ảnh, PDF và file nhị phân giao cho
Quick Look) và archive lồng nhau (`list outer.zip inner.zip`,
`preview outer.zip "inner.zip!/file.txt"`). Code xem trước của GUI hiện
chỉ mới ở dạng code, chờ Xcode project ở M7. M4 đã xong: hàng đợi job bền
bỉ — chạy hàng loạt extract/create/test, tạm dừng/tiếp tục/hủy, tạo
archive qua tên tạm + đổi tên nguyên tử, kiểm tra dung lượng trống
trước, Ctrl-C hủy sạch — qua `seekzip queue` và MCP queue tools. Panel
queue của GUI hiện chỉ mới ở dạng code, chờ Xcode project ở M7. M5 đã
xong: hoàn thiện tạo/sửa — thêm, xóa và đổi tên entry trong archive
ZIP/7z/TAR (bản sao tạm + đổi tên nguyên tử, nên sửa lỗi không bao giờ
làm hỏng bản gốc), chuyển đổi định dạng (ZIP ↔ 7z ↔ TAR; không tạo
được RAR), checksum CRC-32/SHA-256 cho từng entry với lệnh `verify`,
và mật khẩu lưu trong Keychain của macOS (kênh còn lại là biến môi
trường `SEEKZIP_PASSWORD`, không bao giờ dùng tham số `-p`). Panel
sửa của GUI và cột CRC hiện chỉ mới ở dạng code, chờ Xcode project
ở M7. M6 đã xong: engine dự phòng XAD sau routing protocol —
`ArchiveEngine` với ma trận khả năng, `EngineRouter` (7zz trước,
fallback sang XAD khi lỗi/listing rỗng, XAD trước với định dạng legacy
như StuffIt/Zoo/ARC; 7z mã hoá luôn ở lại 7zz), XAD list/extract/test
qua `lsar`/`unar` (chỉ giải nén, extract qua staging nên lỗi không để
lại file dở, encoding tên file khôi phục được giữ trong metadata của
entry), CLI `--engine auto|7zz|xad` + `seekzip engines`, MCP thêm tham
số `engine` + tool `list_engines`, cài đặt engine của GUI (chỉ mới ở
dạng code, chờ Xcode project ở M7). `seekzip list/test/extract` báo
engine nào đã xử lý archive.

## Build (trên máy Mac)

```sh
swift build          # core + CLI + MCP (GUI cần Xcode đầy đủ, xem Package.swift)
swift test           # unit tests for parser and path safety
./Tests/Matrix/generate-matrix.sh   # build the edge-case fixture archives
```

## Hàng đợi

```sh
seekzip queue add extract big.zip ~/out   # xếp hàng; chưa chạy ngay
seekzip queue add create out.7z src --format 7z
seekzip queue run                         # chạy các job theo thứ tự
seekzip queue list                        # job đã lưu — còn nguyên sau khi khởi động lại app
seekzip queue pause <id>                  # SIGSTOP; resume tiếp tục tại chỗ
seekzip queue cancel <id>                 # dừng 7zz, dọn file tạm
```

Các job chạy lần lượt từng job một và được lưu ở
`~/Library/Application Support/SeekZip/queue.json`. Khi tạo archive,
7zz ghi vào thư mục tạm trước rồi mới đổi tên vào vị trí cuối khi xong,
nên job bị hủy hay lỗi cũng không để lại file dở dang. Giải nén và tạo
archive đều kiểm tra dung lượng trống trước và báo lỗi ngay khi ổ đích
không đủ chỗ. Mật khẩu không bao giờ ghi vào file hàng đợi — lấy từ
`SEEKZIP_PASSWORD` hoặc Keychain (xem bên dưới).

## Sửa, chuyển đổi, kiểm tra

```sh
seekzip add archive.zip newfile.txt --into docs   # thêm entry (ZIP/7z/TAR)
seekzip remove archive.zip old.txt                # xóa entry
seekzip rename archive.zip old.txt new.txt        # đổi tên (chỉ ZIP/7z)
seekzip convert archive.zip archive.7z            # chuyển ZIP → 7z (cả 7z → ZIP, TAR → 7z)
seekzip verify archive.zip [--sha256]             # kiểm tra lại CRC của từng entry (và SHA-256)
seekzip checksums archive.zip                     # CRC-32 của từng entry, lấy từ listing
```

Mọi thao tác sửa đều làm trên bản sao tạm trong cùng thư mục và chỉ
thay thế bản gốc bằng phép đổi tên nguyên tử sau khi bản đã sửa list
sạch — sửa lỗi thì bản gốc còn nguyên từng byte. Chuyển đổi giải nén ra
thư mục tạm rồi tạo lại archive; tên và nội dung entry được giữ nguyên,
còn chuyển *sang* RAR sẽ báo lỗi rõ ràng (không công cụ bên thứ ba nào
tạo được RAR). `verify` stream từng entry, băm nó (CRC-32, thêm SHA-256
với `--sha256`) rồi đối chiếu với CRC trong listing; entry hỏng được báo
ra và các entry còn lại vẫn được kiểm tra tiếp.

## Mật khẩu

```sh
SEEKZIP_PASSWORD=hunter2 seekzip list secret.zip  # biến môi trường (không bao giờ dùng tham số -p)
seekzip password store secret.zip                 # lưu vào Keychain của macOS (nhập mật khẩu, 2 lần)
seekzip password forget secret.zip                # quên mật khẩu đã lưu
```

Mật khẩu không bao giờ được truyền qua tham số dòng lệnh (nó sẽ hiện
trong danh sách process). CLI lấy mật khẩu từ `SEEKZIP_PASSWORD` hoặc
từ mật khẩu đã lưu — Keychain của macOS (`com.seekzip.passwords`) trong
app và trên CLI, chỉ dùng bộ nhớ trong trên các lần chạy test Linux.
Mật khẩu truyền trực tiếp luôn thắng mật khẩu đã lưu. MCP tools dùng
cùng trường `password` (`add_entries`, `remove_entries`,
`rename_entries`, `convert_archive`, `verify_archive`).

Archive RAR giải nén được nhưng không tạo được — việc tạo RAR thuộc bản
quyền proprietary (điều này đúng với mọi ứng dụng nén trên macOS).

## Giấy phép

MIT (dự kiến). `7zz` đi kèm vẫn thuộc giấy phép LGPL của 7-Zip.
