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
queue của GUI hiện chỉ mới ở dạng code, chờ Xcode project ở M7.

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
không đủ chỗ. Mật khẩu chỉ giữ trong bộ nhớ, không bao giờ ghi vào file
hàng đợi.

Archive RAR giải nén được nhưng không tạo được — việc tạo RAR thuộc bản
quyền proprietary (điều này đúng với mọi ứng dụng nén trên macOS).

## Giấy phép

MIT (dự kiến). `7zz` đi kèm vẫn thuộc giấy phép LGPL của 7-Zip.
